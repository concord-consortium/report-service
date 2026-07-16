import { Request, Response } from "express";
import admin from "firebase-admin";
import { getDoc } from "./helpers/paths";

interface MetaReq { items: Array<{ collection: "answers" | "history"; source: string; doc_id: string; name: string }>; }

const subFor = (c: string) => (c === "history" ? "interactive_state_history_states" : "answers");

const GETALL_CHUNK = 300;   // match bulk-read's chunkedGetAll — getAll/batchGet has a per-call ceiling

export default async function fetchAttachmentMeta(req: Request, res: Response) {
  try {
    const { items } = req.body as MetaReq;
    if (!Array.isArray(items)) { return res.error(400, "items must be an array"); }
    if (items.length > 500) { return res.error(400, "too many items"); }
    for (const it of items) {
      for (const k of ["collection", "source", "doc_id", "name"] as const) {
        if (typeof it[k] !== "string" || it[k].length === 0) { return res.error(400, `item.${k} must be a non-empty string`); }
      }
      if (it.source.includes("/") || it.doc_id.includes("/")) { return res.error(400, "source/doc_id must not contain '/'"); }
      if (it.collection !== "answers" && it.collection !== "history") { return res.error(400, "bad collection"); }
    }

    const refs = items.map((it) => getDoc(`/sources/${it.source}/${subFor(it.collection)}/${it.doc_id}`));
    const snaps: FirebaseFirestore.DocumentSnapshot[] = [];
    for (let i = 0; i < refs.length; i += GETALL_CHUNK) {
      snaps.push(...(await admin.firestore().getAll(...refs.slice(i, i + GETALL_CHUNK))));
    }

    const results = items.map((it, i) => {
      const snap = snaps[i];
      if (!snap || !snap.exists) { return { doc_id: it.doc_id, name: it.name, meta: null }; }
      const d = snap.data() as any;
      const att = d.attachments && d.attachments[it.name];
      if (!att || !att.publicPath) { return { doc_id: it.doc_id, name: it.name, meta: null }; }
      // authz key = the DOC's learner (remote_endpoint), NOT folder.ownerId (run-with-others legitimately differs).
      return {
        doc_id: it.doc_id, name: it.name,
        meta: { publicPath: att.publicPath, contentType: att.contentType ?? null, remote_endpoint: d.remote_endpoint ?? null },
      };
    });
    return res.success({ results });
  } catch (e) {
    return res.error(500, "fetch_attachment_meta failed");
  }
}
