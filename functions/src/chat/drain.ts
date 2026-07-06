// Chat-tutor drain engine — the lock + drain + per-turn processing logic,
// separated from the trigger wiring in ../chat-tutor.ts. This module imports firebase-admin (+ the chat
// helpers), NOT firebase-functions, so the drain/lock/coalescing logic is unit-testable against the
// Firestore emulator with a fake OpenAI (importing firebase-functions would pull in its identity module,
// which the jest resolver can't load). ../chat-tutor.ts registers the onWrite trigger and calls in here.
import * as admin from "firebase-admin";

import { assemblePageContext, renderPageContext, OrientationHints } from "./chat-context";
import { getVisiblePages } from "./page-walk";
import { Activity, Page } from "./types";
import { resolveActivityUrl, defaultActivityUrl, getActivityResource } from "./fetch-activity";
import { getSimPromptFragments } from "./sim-prompts";
import {
  createOpenAIClient, createConversation, installDeveloperPrompt, createTutorResponse, TutorInputMessage,
} from "./openai";

// reclaim a lock whose owner crashed mid-drain, so a conversation can't wedge forever.
// INVARIANT: STALE_LOCK_MS must exceed the function's configured timeout (default 60s, no timeoutSeconds
// set), or a still-running slow drain could be reclaimed by a racing trigger → two concurrent drains. If
// timeoutSeconds is ever raised, raise this above it (or add a fencing token).
const STALE_LOCK_MS = 5 * 60 * 1000;
// One drain query page. NOTE: function-written assistant docs (kind filtered out in JS) carry a later
// serverTimestamp() than still-queued older messages, so during a deep backlog they ACCUMULATE ahead of
// the cursor (the cursor only ever points at a user/log doc) and can fill the whole limit(DRAIN_BATCH)
// window — an empty `pending` in a full window is therefore NOT proof the queue is empty. The idle branch
// handles this with an explicit window-saturation guard (scan past a full block instead of going idle),
// so correctness does not rest on any DRAIN_BATCH vs MAX_DRAIN_TURNS relationship.
const DRAIN_BATCH = 200;
// Safety valve against a pathological drain loop (see the throw at the end of processAndDrain).
const MAX_DRAIN_TURNS = 100;
// cap logs coalesced into one billed turn so a client log burst can't blow up the OpenAI
// request; the overflow drains as the next turn. Also bound the serialized envelope so arbitrary client
// `data` (up to the 1 MB Firestore doc cap) can't produce an oversized request.
const MAX_COALESCED_LOGS = 20;
const MAX_LOG_ENVELOPE_CHARS = 20_000;

type MsgSnap = admin.firestore.QueryDocumentSnapshot;
type ParentRef = admin.firestore.DocumentReference;
type MsgCol = admin.firestore.CollectionReference;

// A single processing unit = one OpenAI turn: a lone user message, or a coalesced run of logs.
interface Unit {
  kind: "user" | "log";
  docs: MsgSnap[];
}

export interface DrainContext {
  parentRef: ParentRef;
  messagesCol: MsgCol;
  params: { source: string; key: string; activityId: string; pageId: string };
  openai: ReturnType<typeof createOpenAIClient>;
  model: string;
  genericText: string;
}

// the owner fields the client's rules require on any doc it reads — copied off the
// triggering message onto function-written docs (assistant messages, function-created parent).
export function pickOwnerFields(data: any): Record<string, any> {
  if (data?.run_key) return { run_key: data.run_key };
  const out: Record<string, any> = {};
  if (data?.platform_user_id !== undefined) out.platform_user_id = data.platform_user_id;
  if (data?.platform_id !== undefined) out.platform_id = data.platform_id;
  if (data?.context_id !== undefined) out.context_id = data.context_id;
  return out;
}

// display-only orientation hints off the user message (undefined for a log-only turn).
function orientationHints(data: any): OrientationHints {
  return {
    sequenceTitle: data?.sequenceTitle,
    activityTitle: data?.activityTitle,
    activityIndex: data?.activityIndex,
    activityCount: data?.activityCount,
  };
}

// Locate the current page within the fetched activity by its stable id (the {pageId} path param is
// authoritative). A miss means the page was hidden/removed since the client loaded it — throw
// (→ status:"error", visible + self-healing) rather than silently grounding the tutor on the wrong page.
function findPage(activity: Activity, pageId: string): Page {
  const pages = getVisiblePages(activity);
  const found = pages.find(p => String(p.id) === String(pageId));
  if (!found) throw new Error(`no visible page matches pageId ${pageId}`);
  return found;
}

// Compose the full page system prompt = generic tutor prompt + orientation + page body + sim fragment(s).
// (This is what the client's removed tutor-prompt.ts::composeTutorSystemPrompt did; the server owns it now.)
function composePagePrompt(genericText: string, pageContextText: string, simFragments: string[]): string {
  const parts = [genericText.trim(), pageContextText.trim()];
  const sims = simFragments.map(s => s.trim()).filter(Boolean);
  if (sims.length > 0) {
    parts.push(["Guidance for the interactive(s) on this page:", ...sims].join("\n\n"));
  }
  return parts.join("\n\n");
}

// wrap forwarded logs as delimited developer-role telemetry so student-authored fields inside
// are DATA, not instructions. A coalesced run goes in as one batch envelope.
function buildLogBatchEnvelope(docs: MsgSnap[]): string {
  const events = docs.map(d => {
    const x = d.data();
    return {
      type: "activity_log",
      interactive_id: x.interactive_id,
      interactive_url: x.interactive_url,
      action: x.action,
      value: x.value,
      data: x.data,
    };
  });
  const json = JSON.stringify(events.length === 1 ? events[0] : { type: "activity_log_batch", events });
  // bound the request size — arbitrary client `data` (up to the 1 MB Firestore doc cap) must
  // not produce an oversized OpenAI request.
  return json.length > MAX_LOG_ENVELOPE_CHARS ? json.slice(0, MAX_LOG_ENVELOPE_CHARS) + "…[truncated]" : json;
}

// Take the next processing unit off the ordered pending list: a lone user message, or the leading run of
// coalesced logs. (Logs adjacent in the pending list are combined into one billed turn.) The
// coalesced run is capped at MAX_COALESCED_LOGS so a log burst can't fan into one huge turn — the overflow
// drains as the next turn. Exported for unit tests of the coalescing logic.
export function extractUnit(pending: MsgSnap[]): Unit {
  const first = pending[0];
  if (first.get("kind") === "user") return { kind: "user", docs: [first] };
  const logs: MsgSnap[] = [];
  for (const d of pending) {
    if (d.get("kind") !== "log") break;
    logs.push(d);
    if (logs.length >= MAX_COALESCED_LOGS) break;
  }
  return { kind: "log", docs: logs };
}

// fetch + assemble the page, then compose the developer-item page prompt. Only called on the first
// turn (when the developer item is not yet installed), so later turns skip the fetch entirely.
async function composePageSystemPrompt(ctx: DrainContext, unit: Unit): Promise<string> {
  const { params, genericText } = ctx;
  const userData = unit.kind === "user" ? unit.docs[0].data() : undefined;
  // a user message supplies + must justify its activityUrl (validated); a log-first turn has no
  // client URL, so fall back to the trusted default authoring host (no client input → no SSRF surface).
  const safeUrl = userData?.activityUrl
    ? resolveActivityUrl({
        activityUrl: String(userData.activityUrl),
        messageActivityId: String(userData.activityId),
        paramActivityId: params.activityId,
      })
    : defaultActivityUrl(params.activityId);
  const activity = await getActivityResource(safeUrl);
  const page = findPage(activity, params.pageId);
  const pageCtx = assemblePageContext(activity, page, orientationHints(userData ?? {}));
  const pageText = renderPageContext(pageCtx);
  const simFragments = getSimPromptFragments(page);
  return composePagePrompt(genericText, pageText, simFragments);
}

// The side effects of processing one unit, for the caller to commit atomically with the cursor advance.
interface UnitResult {
  // the assistant doc to write, or null for a silent (userText:null) log reply that need not be persisted
  assistant: Record<string, any> | null;
  // parent-doc fields to persist this turn (conversationId + promptInstalled, only once they're earned)
  parentUpdate: Record<string, any>;
}

// Process one unit: ensure the conversation + developer item exist, call OpenAI, and RETURN the resulting
// writes (assistant doc + parent updates). The caller commits them in ONE batch together with the cursor
// advance, so a crash between the reply and the cursor can't leave a duplicate assistant doc.
async function processUnit(ctx: DrainContext, unit: Unit): Promise<UnitResult> {
  const { parentRef, openai, model } = ctx;
  const triggerData = unit.docs[0].data();
  const ownerFields = pickOwnerFields(triggerData);

  // Per-conversation state is read fresh each turn (no in-memory state).
  const parent = (await parentRef.get()).data() ?? {};
  let conversationId: string | undefined = parent.conversationId;
  if (!conversationId) {
    // do NOT persist conversationId yet — only after the developer item + first response succeed.
    conversationId = await createConversation(openai);
  }
  // "set prompt once" is gated on promptInstalled (not on conversationId existing), so a
  // crash mid-setup re-writes the developer item next turn instead of running context-blind.
  const needsPrompt = !parent.promptInstalled;
  if (needsPrompt) {
    const composed = await composePageSystemPrompt(ctx, unit);
    await installDeveloperPrompt(openai, conversationId, composed);
  }

  const input: TutorInputMessage[] = unit.kind === "user"
    ? [{ role: "user", content: String(triggerData.text ?? "") }]
    : [{ role: "developer", content: buildLogBatchEnvelope(unit.docs) }];

  const { userText } = await createTutorResponse(openai, { model, conversationId, input });

  // only NOW (developer item written + response succeeded) is conversationId + promptInstalled
  // earned; the caller persists them (batched with the cursor) so they commit atomically after success.
  const parentUpdate: Record<string, any> = {};
  if (needsPrompt || !parent.conversationId) {
    parentUpdate.conversationId = conversationId;
    parentUpdate.promptInstalled = true;
  }

  // Only a USER turn ever produces a visible reply. A log turn is absorbed for
  // context only and its output is DROPPED — a hard backstop behind the prompt's "logs → userText:null", so
  // the tutor can never surface an unprompted message even if the model slips and returns text. A
  // user turn stamps owner fields so the client's onSnapshot (studentWorkRead) can read the reply, and writes
  // even a userText:null assistant doc so the client's "awaiting" indicator clears.
  const assistant = unit.kind === "user"
    ? { kind: "assistant", userText, createdAt: admin.firestore.FieldValue.serverTimestamp(), ...ownerFields }
    : null;

  return { assistant, parentUpdate };
}

export async function processAndDrain(ctx: DrainContext): Promise<void> {
  const { parentRef, messagesCol } = ctx;
  const db = admin.firestore();
  const FieldPath = admin.firestore.FieldPath;

  // order on (createdAt, __name__) so the cursor is deterministic even when coalesced logs
  // share a serverTimestamp() millisecond; range-only (no kind filter) so it needs NO composite index —
  // `kind` is filtered in JS below. A brand-new message committing in the
  // SAME createdAt millisecond as the cursor doc but with a lexically-smaller random auto-id would sort
  // before the cursor and be skipped; astronomically unlikely for the pilot, a monotonic client sequence
  // would remove it (deferred).
  const afterCursorQuery = (cursor: MsgSnap | null) => {
    let q: admin.firestore.Query = messagesCol
      .orderBy("createdAt")
      .orderBy(FieldPath.documentId())
      .limit(DRAIN_BATCH);
    if (cursor) q = q.startAfter(cursor);
    return q;
  };
  const isPending = (d: MsgSnap) => {
    const k = d.get("kind");
    return k === "user" || k === "log";
  };

  // Load the persisted cursor so a cold start / re-trigger continues where the last invocation stopped.
  const p0 = (await parentRef.get()).data() ?? {};
  let lastSnap: MsgSnap | null = null;
  if (p0.lastProcessedMessageId) {
    const cursorSnap = await messagesCol.doc(p0.lastProcessedMessageId).get();
    if (cursorSnap.exists) lastSnap = cursorSnap as MsgSnap;
  }

  for (let i = 0; i < MAX_DRAIN_TURNS; i++) {
    const batch = await afterCursorQuery(lastSnap).get();
    const pending = batch.docs.filter(isPending);

    if (pending.length === 0) {
      // Window saturated with non-pending (assistant) docs? A FULL window with no pending doc is not proof
      // the queue is empty — a genuinely-pending message could sit at position DRAIN_BATCH+1 behind the
      // accumulated assistant docs. So don't idle: advance the IN-MEMORY scan cursor past this block (do
      // NOT persist it — an assistant-doc cursor would skip older-timestamped pending messages) and keep
      // scanning until a partial window proves the tail is reached.
      if (batch.docs.length === DRAIN_BATCH) {
        lastSnap = batch.docs[batch.docs.length - 1];
        continue;
      }
      // atomic idle: re-read the after-cursor query INSIDE the transaction; commit idle only if it
      // is still empty (and not saturated). A message committed into the range forces the idle-commit to
      // serialize/retry, so a message that arrives while its own trigger backs off on "generating" is never
      // orphaned. The txn is self-contained (read + conditional write, then commit) — never held open
      // across an external write.
      const wentIdle = await db.runTransaction(async (tx) => {
        const check = await tx.get(afterCursorQuery(lastSnap));
        if (check.docs.length === DRAIN_BATCH) return false; // saturated race → keep draining, don't idle
        const stillPending = check.docs.filter(isPending);
        if (stillPending.length > 0) return false;
        tx.set(parentRef, {
          status: "idle",
          lockedAt: admin.firestore.FieldValue.delete(),
        }, { merge: true });
        return true;
      });
      if (wentIdle) return;
      continue; // a message landed during the check → keep draining
    }

    const unit = extractUnit(pending);
    const { assistant, parentUpdate } = await processUnit(ctx, unit);

    const last = unit.docs[unit.docs.length - 1];
    lastSnap = last;
    // commit the assistant doc + earned parent state + cursor advance in ONE batch: either all
    // land or none, so a crash between the reply and the cursor can't duplicate the assistant doc (a
    // pre-commit crash re-processes the unit but wrote nothing — only a possible OpenAI re-bill remains,
    // the documented replay risk).
    const writeBatch = db.batch();
    if (assistant) writeBatch.set(messagesCol.doc(), assistant);
    writeBatch.set(parentRef, {
      ...parentUpdate,
      lastProcessedCreatedAt: last.get("createdAt"),
      lastProcessedMessageId: last.id,
    }, { merge: true });
    await writeBatch.commit();
  }

  // Pathological drain length. Throw so the catch sets status:"error" (self-heals — acquire proceeds on
  // anything != "generating"); the persisted cursor means the next trigger continues in order.
  throw new Error("chat drain exceeded MAX_DRAIN_TURNS");
}

// acquire the per-conversation lock: compare-and-set idle→generating in a transaction, reclaiming
// a stale lock (owner crashed mid-drain). Returns true if this invocation won the lock. Exported so the
// single-in-flight + stale-reclaim behavior is testable against the emulator.
export async function acquireLock(
  parentRef: ParentRef, ownerFields: Record<string, any>
): Promise<boolean> {
  const db = admin.firestore();
  return db.runTransaction(async (tx) => {
    const p = await tx.get(parentRef);
    const status = p.data()?.status ?? "idle";
    const lockedAtMs = p.data()?.lockedAt?.toMillis?.() ?? 0;
    const stale = Date.now() - lockedAtMs > STALE_LOCK_MS;
    if (status === "generating" && !stale) return false; // genuinely busy → back off; the busy run drains
    // status/lockedAt are FUNCTION-OWNED (Admin write, bypasses rules). If the parent doesn't
    // exist yet, also stamp owner fields so the client can READ it (status indicator / reload).
    const ownerInit = p.exists ? {} : ownerFields;
    tx.set(parentRef, {
      status: "generating",
      lockedAt: admin.firestore.FieldValue.serverTimestamp(),
      ...ownerInit,
    }, { merge: true });
    return true;
  });
}
