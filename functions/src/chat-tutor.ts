// Per-page AI chat tutor trigger.
//
// A 1st-gen Firestore onWrite trigger (matching auto-importer.ts's runWith/firestore.document style;
// registered in index.ts's module.exports object) on the per-page messages subcollection:
//
//   /sources/{source}/chats/{key}/activities/{activityId}/pages/{pageId}/messages/{messageId}
//
//   - self-trigger guard: act only on kind:"user" (student message) or kind:"log" (telemetry);
//     ignore our own kind:"assistant" writes and deletes.
//   - per-conversation single-in-flight lock (acquireLock) + drain (processAndDrain), both in
//     ./chat/drain.ts (firebase-admin only, so that logic is emulator-testable without firebase-functions).
//
// This file is deliberately thin: it owns only the trigger registration + params/secret + path parsing,
// and delegates every Firestore/OpenAI step to ./chat/drain.
import * as functions from "firebase-functions";
import { defineSecret, defineString } from "firebase-functions/params";
import * as admin from "firebase-admin";

import { CHAT_GENERIC_PROMPT } from "./chat/generic-prompt";
import { createOpenAIClient } from "./chat/openai";
import { DrainContext, acquireLock, processAndDrain, pickOwnerFields } from "./chat/drain";

// Only the API key is a true secret (defineSecret). OPENAI_MODEL stays a defineString
// param (server-side config, re-confirm the flagship as it advances). The generic tutor prompt is a
// SOURCE CONSTANT (./chat/generic-prompt), not a param: it is server-side either way (the function never
// ships to the browser), so a param bought no secrecy — only a split source-of-truth and awkward
// multi-line .env escaping. See the note in generic-prompt.ts.
const openaiKey = defineSecret("OPENAI_API_KEY");
const openaiModel = defineString("OPENAI_MODEL");

const MESSAGES =
  "sources/{source}/chats/{key}/activities/{activityId}/pages/{pageId}/messages/{messageId}";

export const chatTutorOnWrite = functions
  .runWith({ secrets: [openaiKey] })
  .firestore.document(MESSAGES)
  .onWrite(async (change, context) => {
    const doc = change.after.data();
    if (!doc) return null; // delete → ignore
    const kind = doc.kind;
    // self-trigger guard: only user messages + logs start/continue a turn; ignore our own
    // assistant writes (and any other kind).
    if (kind !== "user" && kind !== "log") return null;

    const db = admin.firestore();
    const { source, key, activityId, pageId } = context.params as Record<string, string>;
    const parentRef = db.doc(
      `sources/${source}/chats/${key}/activities/${activityId}/pages/${pageId}`);
    const messagesCol = parentRef.collection("messages");
    const ownerFields = pickOwnerFields(doc);

    // acquire the per-conversation lock (compare-and-set idle→generating) with stale reclaim.
    const acquired = await acquireLock(parentRef, ownerFields);
    if (!acquired) return null;

    const ctx: DrainContext = {
      parentRef,
      messagesCol,
      params: { source, key, activityId, pageId },
      openai: createOpenAIClient(openaiKey.value()),
      model: openaiModel.value(),
      genericText: CHAT_GENERIC_PROMPT,
    };

    try {
      await processAndDrain(ctx);
    } catch (e: any) {
      // Record the error (status:"error" self-heals — acquire proceeds on anything != "generating") and
      // re-throw only to surface it in the function logs. This trigger must run with the
      // DEFAULT no-retry policy: with retries enabled, a deterministic failure (e.g. a bad activityUrl)
      // would re-acquire and re-drain forever, burning fetch/OpenAI. Do not enable failurePolicy/retries.
      // Accepted risk: the cursor only advances past a unit on success, so a queue-HEAD message that
      // fails deterministically (removed page / bad client activityUrl) re-fails each trigger and blocks
      // later messages in THAT one conversation — bounded, and it does surface status:"error" (not a silent
      // stall). Transient failures self-heal on the next message; a poison-pill skip is a future item.
      await parentRef.set({ status: "error", error: String(e?.message || e) }, { merge: true });
      throw e;
    }
    return null;
  });
