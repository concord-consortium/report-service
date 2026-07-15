import { Request, Response } from "express";
import admin from "firebase-admin";
import { getPath, getCollection, getDoc } from "./helpers/paths";
import {
  reconstructTimestamp, validateHistoryCursor, validateAnswersCursor, HistoryCursor, AnswersCursor,
} from "./helpers/bulk-cursor";

const { FieldPath } = admin.firestore;
const HISTORY_BATCH = 300;   // metadata docs per query
const GETALL_CHUNK = 300;    // state docs per getAll
// A history batch performs up to 2*batch reads (metadata query + state-doc getAll) but only the metadata
// query is sized against the remaining budget, so the effective read ceiling per call is read_limit +
// HISTORY_BATCH; bounded and non-runaway (the loop re-checks reads >= remReads at the top).

// Soft response-byte budget (~8 MB) under the ~10 MB gen1 response cap. No single item can exceed the
// Firestore 1 MiB doc limit, so the budget always admits at least one item -> forward progress guaranteed.
const RESPONSE_BYTE_BUDGET = 8 * 1024 * 1024;

const itemBytes = (item: any) => Buffer.byteLength(JSON.stringify(item), "utf8");

type LtiTuple = { platform_id: string; platform_user_id: string; resource_link_id: string };
type SourceEndpoint = { remote_endpoint: string; source: string; lti_tuple?: LtiTuple | null };

interface BulkRequest {
  collection: "answers" | "history";
  source_endpoints: SourceEndpoint[];   // ordered slice from the current endpoint index onward
  inner_cursor: AnswersCursor | HistoryCursor | null;
  limit: number;
  endpoint_limit: number;
  read_limit: number;
}

interface EndpointRead {
  items: any[];
  innerCursor: AnswersCursor | HistoryCursor | null; // null iff exhausted
  exhausted: boolean;
  reads: number;                                     // raw docs counted toward read_limit
  bytes: number;                                     // serialized size of the returned items
  touched?: { remote_endpoint: string; lti_tuple: LtiTuple } | null;
}

async function chunkedGetAll(refs: FirebaseFirestore.DocumentReference[]) {
  const out: FirebaseFirestore.DocumentSnapshot[] = [];
  for (let i = 0; i < refs.length; i += GETALL_CHUNK) {
    const chunk = refs.slice(i, i + GETALL_CHUNK);
    out.push(...(await admin.firestore().getAll(...chunk)));
  }
  return out;
}

// ANSWERS: ordered by __name__ (doc id); 1 returned item == 1 raw doc read.
export async function readAnswersEndpoint(ep: SourceEndpoint, start: AnswersCursor | null,
                                          remItems: number, remReads: number, remBytes: number): Promise<EndpointRead> {
  const path = await getPath(ep.source, "answers");
  const base = () => getCollection(path).where("remote_endpoint", "==", ep.remote_endpoint).orderBy(FieldPath.documentId());

  const cap = Math.max(0, Math.min(remItems, remReads));
  if (cap === 0) { return { items: [], innerCursor: start, exhausted: false, reads: 0, bytes: 0 }; }

  let q = base();
  if (start) { q = q.startAfter(start.docId); }
  const snap = await q.limit(cap).get();
  const reads = snap.size;

  const items: any[] = [];
  let bytes = 0;
  let trimmed = false;
  let lastIncludedId = start ? start.docId : null;
  for (const d of snap.docs) {
    const item = { ...d.data(), id: d.id };
    const sz = itemBytes(item);
    if (items.length >= 1 && bytes + sz > remBytes) { trimmed = true; break; }
    items.push(item);
    bytes += sz;
    lastIncludedId = d.id;
  }

  if (trimmed) {
    // ended on the byte cap mid-fetch: a next doc provably exists (the one we didn't include), no lookahead
    return { items, innerCursor: { docId: lastIncludedId as string }, exhausted: false, reads, bytes };
  }

  if (snap.size < cap) {
    return { items, innerCursor: null, exhausted: true, reads, bytes };   // short read = natural end
  }

  // exactly `cap` docs, all included -> next-doc unknown; one-doc lookahead (counts toward read_limit)
  let la = base();
  if (lastIncludedId) { la = la.startAfter(lastIncludedId); }
  const laSnap = await la.limit(1).get();
  if (laSnap.empty) { return { items, innerCursor: null, exhausted: true, reads: reads + laSnap.size, bytes }; }
  return { items, innerCursor: { docId: lastIncludedId as string }, exhausted: false, reads: reads + laSnap.size, bytes };
}

// HISTORY: keyed by LTI tuple; ordered by (created_at, __name__); post-filtered to remote_endpoint.
export async function readHistoryEndpoint(ep: SourceEndpoint, start: HistoryCursor | null,
                                          remItems: number, remReads: number, remBytes: number): Promise<EndpointRead> {
  // derive/cache the LTI tuple (the `answers ... limit 1` read does NOT count toward read_limit)
  let tuple = ep.lti_tuple ?? null;
  let touched: EndpointRead["touched"] = null;
  if (!tuple) {
    const ansPath = await getPath(ep.source, "answers");
    const ansSnap = await getCollection(ansPath).where("remote_endpoint", "==", ep.remote_endpoint).limit(1).get();
    if (ansSnap.empty) { return { items: [], innerCursor: null, exhausted: true, reads: 0, bytes: 0, touched: null }; }
    const a = ansSnap.docs[0].data();
    tuple = { platform_id: a.platform_id, platform_user_id: a.platform_user_id, resource_link_id: a.resource_link_id };
    touched = { remote_endpoint: ep.remote_endpoint, lti_tuple: tuple };
  }

  const metaPath = await getPath(ep.source, "interactive_state_histories");
  const statePathPrefix = await getPath(ep.source, "interactive_state_history_states");
  const metaBase = () => getCollection(metaPath)
    .where("platform_id", "==", tuple!.platform_id)
    .where("platform_user_id", "==", tuple!.platform_user_id)
    .where("resource_link_id", "==", tuple!.resource_link_id)
    .orderBy("created_at").orderBy(FieldPath.documentId());

  const items: any[] = [];
  let reads = 0;
  let bytes = 0;
  let cursor: HistoryCursor | null = start;
  let exhausted = false;
  let hitItemCap = false;   // broke mid-batch on the item cap
  let hitByteCap = false;   // broke mid-batch on the byte cap

  while (true) {
    if (items.length >= remItems || reads >= remReads) { exhausted = false; break; }
    const batch = Math.max(1, Math.min(HISTORY_BATCH, remReads - reads));
    let q = metaBase();
    if (cursor) { q = q.startAfter(reconstructTimestamp(cursor), cursor.docId); }
    const metaSnap = await q.limit(batch).get();
    reads += metaSnap.size;
    if (metaSnap.size === 0) { exhausted = true; break; }

    const stateRefs = metaSnap.docs.map((d) => getDoc(`${statePathPrefix}/${d.id}`));
    const stateDocs = await chunkedGetAll(stateRefs);
    reads += stateDocs.length;

    for (let i = 0; i < metaSnap.size; i++) {
      if (items.length >= remItems) { hitItemCap = true; break; } // stop AT the item cap; doc i is untouched
      const metaDoc = metaSnap.docs[i];
      const meta = metaDoc.data() as any;
      const state = stateDocs[i];

      // compute the item (if any) this doc yields before touching the cursor
      let item: any = null;
      let sz = 0;
      if (state.exists) {
        const sd = state.data() as any;
        if (sd.remote_endpoint === ep.remote_endpoint) {   // filter to the authorized endpoint (1:many tuple)
          item = {
            ...sd,
            history_id: metaDoc.id,
            created_at: meta.created_at.toDate().toISOString(), // raw Timestamp -> ISO on the wire
            answer_id: meta.answer_id,
            question_id: meta.question_id,
          };
          sz = itemBytes(item);
        }
      }

      // byte cap: stop BEFORE consuming this doc so resume re-reads it (no gap)
      if (item && items.length >= 1 && bytes + sz > remBytes) { hitByteCap = true; break; }

      // consume: advance the cursor for EVERY consumed doc (even filtered/missing), push if it yielded an item
      cursor = { seconds: meta.created_at.seconds, nanoseconds: meta.created_at.nanoseconds, docId: metaDoc.id };
      if (item) { items.push(item); bytes += sz; }
    }

    if (hitItemCap || hitByteCap) { exhausted = false; break; } // more docs provably remain after the cursor
    if (metaSnap.size < batch) { exhausted = true; break; }      // short read = natural end (whole batch consumed)
    // full batch, all consumed, caps not yet hit -> loop; caps re-checked at top
  }

  // Stopped on a read/endpoint cap with next-doc unknown -> definitive lookahead (never guess `true`).
  // Skipped when we broke mid-batch on an item/byte cap (a next doc was already read this batch).
  if (!exhausted && !hitItemCap && !hitByteCap && cursor) {
    const laSnap = await metaBase().startAfter(reconstructTimestamp(cursor), cursor.docId).limit(1).get();
    reads += laSnap.size;
    if (laSnap.empty) { exhausted = true; }
  }

  return { items, innerCursor: exhausted ? null : cursor, exhausted, reads, bytes, touched };
}

export default async function bulkRead(req: Request, res: Response) {
  try {
    const body = req.body as BulkRequest;
    const { collection, source_endpoints, inner_cursor, limit, endpoint_limit, read_limit } = body;

    if (collection !== "answers" && collection !== "history") { return res.error(400, "invalid collection"); }
    if (!Array.isArray(source_endpoints)) { return res.error(400, "source_endpoints must be an array"); }

    // Each cap must be an integer in [1, max]. >= 1 guards forward progress (a limit:0 no-progress page); the
    // upper bound bounds worst-case work for a malformed/leaked-bearer direct call (Elixir sends 500/250/5000).
    const CAP_MAX: Record<string, number> = { limit: 2000, endpoint_limit: 10000, read_limit: 100000 };
    for (const [name, v] of [["limit", limit], ["endpoint_limit", endpoint_limit], ["read_limit", read_limit]] as const) {
      if (!Number.isInteger(v) || v < 1) { return res.error(400, `${name} must be an integer >= 1`); }
      if (v > CAP_MAX[name]) { return res.error(400, `${name} must be <= ${CAP_MAX[name]}`); }
    }

    // Validate every endpoint OBJECT (not just that the outer value is an array): an undefined source /
    // remote_endpoint would reach Firestore and throw -> uncaught 500. `source` must also not contain "/"
    // (it is a collection-path segment; a slash breaks getCollection arity). remote_endpoint is only a query
    // VALUE, so a slash there is harmless.
    const isNonEmptyStr = (v: unknown): v is string => typeof v === "string" && v.length > 0;
    for (const ep of source_endpoints) {
      if (!ep || typeof ep !== "object") { return res.error(400, "each source_endpoint must be an object"); }
      if (!isNonEmptyStr((ep as any).source) || (ep as any).source.includes("/")) {
        return res.error(400, "source_endpoint.source must be a non-empty string with no '/'");
      }
      if (!isNonEmptyStr((ep as any).remote_endpoint)) {
        return res.error(400, "source_endpoint.remote_endpoint must be a non-empty string");
      }
      const t = (ep as any).lti_tuple;
      if (t !== undefined && t !== null) {
        if (typeof t !== "object" ||
            !isNonEmptyStr(t.platform_id) || !isNonEmptyStr(t.platform_user_id) || !isNonEmptyStr(t.resource_link_id)) {
          return res.error(400, "source_endpoint.lti_tuple must be null/absent or {platform_id, platform_user_id, resource_link_id} strings");
        }
      }
    }

    if (collection === "answers") { validateAnswersCursor(inner_cursor); }
    else { validateHistoryCursor(inner_cursor); }

    const items: any[] = [];
    const touched: Array<NonNullable<EndpointRead["touched"]>> = [];
    let reads = 0;
    let bytesUsed = 0;
    let endpointsWalked = 0;
    let stopOffset = 0;
    let stopCursor: EndpointRead["innerCursor"] = null;
    let stopExhausted = true;

    for (let offset = 0; offset < source_endpoints.length; offset++) {
      const ep = source_endpoints[offset];
      const start = offset === 0 ? inner_cursor : null;
      const remItems = limit - items.length;
      const remReads = read_limit - reads;
      const remBytes = RESPONSE_BYTE_BUDGET - bytesUsed;

      const r = collection === "answers"
        ? await readAnswersEndpoint(ep, start, remItems, remReads, remBytes)
        : await readHistoryEndpoint(ep, start as HistoryCursor | null, remItems, remReads, remBytes);

      items.push(...r.items);
      reads += r.reads;
      bytesUsed += r.bytes;
      if (r.touched) { touched.push(r.touched); }
      endpointsWalked++;
      stopOffset = offset;
      stopCursor = r.innerCursor;
      stopExhausted = r.exhausted;

      if (!r.exhausted) { break; }                     // hit a cap mid-endpoint -> resume same endpoint
      if (items.length >= limit) { break; }            // item cap, endpoint exhausted -> advance +1
      if (reads >= read_limit) { break; }              // read cap
      if (endpointsWalked >= endpoint_limit) { break; } // endpoint cap (empty-mid-export page lands here)
    }

    return res.success({
      items,
      stop_endpoint_offset: stopOffset,
      inner_cursor: stopCursor,
      endpoint_exhausted: stopExhausted,
      touched_endpoints: touched,
    });
  } catch (e: any) {
    if (e && e.badRequest) { return res.error(400, e.message); }
    console.error(e);
    return res.error(500, e && e.toString ? e.toString() : "bulk_read failed");
  }
}
