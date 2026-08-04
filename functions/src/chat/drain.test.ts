/**
 * @jest-environment node
 */
// Tests for the chat-tutor trigger internals.
//   - extractUnit (log coalescing + cap): PURE, always runs.
//   - processAndDrain + acquireLock: need the Firestore emulator + a FAKE OpenAI (no network, no spend).
//     They self-SKIP when FIRESTORE_EMULATOR_HOST is unset, and run under:
//       firebase emulators:exec --only firestore --project report-service-dev "npx jest chat-tutor"
import * as admin from "firebase-admin";
import { extractUnit, buildLogBatchEnvelope, processAndDrain, acquireLock, DrainContext } from "./drain";

// A minimal QueryDocumentSnapshot stand-in for extractUnit (it only calls .get("kind") + reads .id/.docs).
const fakeSnap = (id: string, kind: string) =>
  ({ id, get: (k: string) => (k === "kind" ? kind : undefined) } as any);

describe("extractUnit (coalescing)", () => {
  it("returns a lone user message as its own unit", () => {
    const u = extractUnit([fakeSnap("m1", "user"), fakeSnap("m2", "log")]);
    expect(u.kind).toBe("user");
    expect(u.docs.map(d => d.id)).toEqual(["m1"]);
  });

  it("coalesces a leading run of logs into one unit, stopping at the first non-log", () => {
    const u = extractUnit([fakeSnap("l1", "log"), fakeSnap("l2", "log"), fakeSnap("u1", "user")]);
    expect(u.kind).toBe("log");
    expect(u.docs.map(d => d.id)).toEqual(["l1", "l2"]);
  });

  it("caps a coalesced log run at MAX_COALESCED_LOGS (20) — overflow drains next turn", () => {
    const logs = Array.from({ length: 25 }, (_, i) => fakeSnap(`l${i}`, "log"));
    const u = extractUnit(logs);
    expect(u.kind).toBe("log");
    expect(u.docs).toHaveLength(20);
  });
});

// A fake snapshot whose .data() returns a log doc (buildLogBatchEnvelope reads .data()).
const fakeLogSnap = (data: any) => ({ data: () => data } as any);

describe("buildLogBatchEnvelope", () => {
  it("emits valid JSON for a normal log run", () => {
    const env = buildLogBatchEnvelope([fakeLogSnap({ action: "change", value: 3, data: { a: 1 } })]);
    expect(() => JSON.parse(env)).not.toThrow();
    expect(JSON.parse(env).type).toBe("activity_log");
  });

  it("stays valid JSON AND bounded when a huge `data` payload blows past the cap", () => {
    const env = buildLogBatchEnvelope([fakeLogSnap({ action: "change", data: { blob: "x".repeat(50_000) } })]);
    // must not cut mid-token: still parseable, and clearly marked as truncated + bounded.
    const parsed = JSON.parse(env);
    expect(parsed.type).toBe("activity_log_truncated");
    expect(env.length).toBeLessThan(50_000);
  });
});

// ---- emulator-backed drain/lock tests (fake OpenAI) ----
const HAS_EMULATOR = !!process.env.FIRESTORE_EMULATOR_HOST;
const describeEmu = HAS_EMULATOR ? describe : describe.skip;

const makeFakeOpenAI = () => {
  const calls = { responses: 0, conversations: 0, items: 0 };
  return {
    calls,
    conversations: {
      create: async () => { calls.conversations++; return { id: "conv_test" }; },
      items: { create: async () => { calls.items++; } },
    },
    responses: {
      create: async () => { calls.responses++; return { output_text: JSON.stringify({ userText: "a hint" }) }; },
    },
  };
};

describeEmu("processAndDrain + acquireLock [emulator, fake OpenAI]", () => {
  let db: admin.firestore.Firestore;
  let n = 0;

  beforeAll(() => {
    if (!admin.apps.length) admin.initializeApp({ projectId: "report-service-dev" });
    db = admin.firestore();
  });

  // A fresh isolated per-page path per test. The activityId is unique per test too, NOT a shared "9":
  // getActivityResource caches the fetched activity at module level keyed by the resolved URL, which is
  // built from the activityId. A shared id let one test be served the previous test's stubbed activity,
  // whose page ids do not match, turning a would-be transient failure into a findPage skip.
  const freshPaths = () => {
    const i = n++;
    const pageId = `p-${i}`;
    const activityId = `a-${i}`;
    const parentRef = db.doc(`sources/s/chats/k/activities/${activityId}/pages/${pageId}`);
    return { parentRef, messagesCol: parentRef.collection("messages"), pageId, activityId };
  };

  // activityId is read back off the parent path, mirroring production where it is a path param.
  const ctxFor = (parentRef: any, messagesCol: any, openai: any, pageId: string): DrainContext => ({
    parentRef, messagesCol,
    params: { source: "s", key: "k", activityId: parentRef.path.split("/activities/")[1].split("/")[0], pageId },
    openai, model: "test-model", genericText: "generic",
  });

  const ts = (ms: number) => admin.firestore.Timestamp.fromMillis(ms);
  const BASE = 1_700_000_000_000;

  it("drains queued turns in order, coalesces logs into one OpenAI call, and settles to idle", async () => {
    const { parentRef, messagesCol, pageId } = freshPaths();
    // seed the parent already conversation-ready so processUnit skips createConversation + the activity
    // fetch (needsPrompt=false) — this isolates the drain/coalescing logic from the network.
    await parentRef.set({ run_key: "anon-run-0123456789", status: "generating",
      lockedAt: admin.firestore.FieldValue.serverTimestamp(), conversationId: "conv_test", promptInstalled: true });
    await messagesCol.doc("u1").set({ kind: "user", text: "q", createdAt: ts(BASE + 1), run_key: "anon-run-0123456789" });
    await messagesCol.doc("l1").set({ kind: "log", action: "change", createdAt: ts(BASE + 2), run_key: "anon-run-0123456789" });
    await messagesCol.doc("l2").set({ kind: "log", action: "change", createdAt: ts(BASE + 3), run_key: "anon-run-0123456789" });

    const openai = makeFakeOpenAI();
    await processAndDrain(ctxFor(parentRef, messagesCol, openai, pageId));

    // user turn (1 call) + the two logs coalesced into one turn (1 call) = 2 OpenAI calls, not 3.
    expect(openai.calls.responses).toBe(2);

    const after = (await parentRef.get()).data() as any;
    expect(after.status).toBe("idle");
    expect(after.lockedAt).toBeUndefined();            // lockedAt cleared on idle
    expect(after.lastProcessedMessageId).toBe("l2");   // cursor advanced to the last coalesced log

    // Only the USER turn produces a visible reply; the coalesced log turn is absorbed silently (no
    // unprompted feedback), so exactly ONE assistant doc is persisted, carrying the owner field.
    const assistants = (await messagesCol.where("kind", "==", "assistant").get()).docs.map(d => d.data());
    expect(assistants).toHaveLength(1);
    expect(assistants[0].run_key).toBe("anon-run-0123456789");
  });

  it("resumes from the persisted cursor (does not reprocess already-drained turns)", async () => {
    const { parentRef, messagesCol, pageId } = freshPaths();
    // u1 already processed (cursor points at it); only u2 is pending.
    await messagesCol.doc("u1").set({ kind: "user", text: "old", createdAt: ts(BASE + 1), run_key: "anon-run-0123456789" });
    await messagesCol.doc("u2").set({ kind: "user", text: "new", createdAt: ts(BASE + 2), run_key: "anon-run-0123456789" });
    await parentRef.set({ run_key: "anon-run-0123456789", status: "generating",
      conversationId: "conv_test", promptInstalled: true,
      lastProcessedCreatedAt: ts(BASE + 1), lastProcessedMessageId: "u1" });

    const openai = makeFakeOpenAI();
    await processAndDrain(ctxFor(parentRef, messagesCol, openai, pageId));

    expect(openai.calls.responses).toBe(1); // only u2, not u1
    expect((await parentRef.get()).data()!.lastProcessedMessageId).toBe("u2");
  });

  // Serve the activity from a stub instead of the network, so the skip test stays hermetic. The jest
  // env has no AbortController either, which fetchWithGuards needs, so provide a no-op one.
  const stubActivityFetch = (pageId: string) => {
    const activity = { version: 2, name: "stub", pages: [{ id: pageId, is_hidden: false, sections: [] }] };
    const g = global as any;
    const restore = { fetch: g.fetch, AbortController: g.AbortController };
    if (!g.AbortController) g.AbortController = class { signal = undefined; abort() { /* no-op */ } };
    g.fetch = async () => ({
      ok: true,
      status: 200,
      headers: { get: () => "application/json" },
      text: async () => JSON.stringify(activity),
    });
    return () => { g.fetch = restore.fetch; g.AbortController = restore.AbortController; };
  };

  // Regression for the production wedge on 2026-08-04: a client sent an activityUrl whose host is not
  // on AUTHORING_HOSTS, resolveActivityUrl threw, and because the cursor only advances on success the
  // poisoned doc stayed at the queue HEAD. Every later trigger re-failed on it, so a well-formed
  // message sent afterwards (by a FIXED client) was never reached. The conversation was bricked for
  // that page permanently.
  it("steps over a permanently-failing head message and still answers the ones queued behind it", async () => {
    const { parentRef, messagesCol, pageId, activityId } = freshPaths();
    // promptInstalled is deliberately NOT set: that is what forces composePageSystemPrompt (and so
    // resolveActivityUrl) to run, which is the only path that can throw a PermanentUnitError.
    await parentRef.set({ run_key: "anon-run-0123456789", status: "generating",
      lockedAt: admin.firestore.FieldValue.serverTimestamp(), conversationId: "conv_test" });
    // head: a disallowed host → PermanentUnitError, forever.
    await messagesCol.doc("bad").set({ kind: "user", text: "q1", createdAt: ts(BASE + 1),
      run_key: "anon-run-0123456789", activityId,
      activityUrl: "https://activity-player.concord.org/?activity=https%3A%2F%2Fauthoring.concord.org" });
    // behind it: a well-formed message that must NOT be blocked.
    await messagesCol.doc("good").set({ kind: "user", text: "q2", createdAt: ts(BASE + 2),
      run_key: "anon-run-0123456789", activityId,
      activityUrl: `https://authoring.concord.org/api/v1/activities/${activityId}.json` });

    const openai = makeFakeOpenAI();
    const restoreFetch = stubActivityFetch(pageId);
    try {
      // Must not throw: the whole point is that the poison pill no longer aborts the drain.
      await processAndDrain(ctxFor(parentRef, messagesCol, openai, pageId));
    } finally {
      restoreFetch();
    }

    const after = (await parentRef.get()).data() as any;
    expect(after.lastProcessedMessageId).toBe("good");   // cursor moved PAST the poison pill
    expect(after.lockedAt).toBeUndefined();              // lock released, conversation not wedged
    // A later success supersedes the skip: the tutor demonstrably works, so the conversation must NOT
    // be left in `error` or the client shows "tutor unavailable" directly above a good reply.
    expect(after.status).toBe("idle");
    expect(after.error).toBeUndefined(); // and the stale reason is cleared, not left to mislead

    // the queued-behind message really was answered
    const assistants = (await messagesCol.where("kind", "==", "assistant").get()).docs.map(d => d.data());
    expect(assistants).toHaveLength(1);
  });

  it("surfaces the failure when the skipped unit is the LAST thing that happened", async () => {
    const { parentRef, messagesCol, pageId, activityId } = freshPaths();
    await parentRef.set({ run_key: "anon-run-0123456789", status: "generating",
      lockedAt: admin.firestore.FieldValue.serverTimestamp(), conversationId: "conv_test" });
    // Only the poison pill: nothing queued behind it to prove the tutor still works.
    await messagesCol.doc("bad").set({ kind: "user", text: "q", createdAt: ts(BASE + 1),
      run_key: "anon-run-0123456789", activityId,
      activityUrl: "https://activity-player.concord.org/?activity=https%3A%2F%2Fauthoring.concord.org" });

    await processAndDrain(ctxFor(parentRef, messagesCol, makeFakeOpenAI(), pageId));

    const after = (await parentRef.get()).data() as any;
    expect(after.lastProcessedMessageId).toBe("bad");    // still unblocked for the next message
    expect(after.lockedAt).toBeUndefined();
    // the dropped turn is reported rather than silently swallowed as a healthy idle
    expect(after.status).toBe("error");
    expect(after.error).toMatch(/disallowed activity host/);
    expect((await messagesCol.where("kind", "==", "assistant").get()).empty).toBe(true);
  });

  // Regression for the single-in-flight invariant. acquireLock backs off ONLY while
  // status === "generating", so a skip that flipped status to "error" mid-drain (while still holding
  // the lock and still draining) would let a concurrent trigger win the lock and run a SECOND drain on
  // the same conversation. The skip must persist the reason + cursor and leave status alone.
  it("keeps status generating while skipping, so the lock is not released mid-drain", async () => {
    const { parentRef, messagesCol, pageId, activityId } = freshPaths();
    await parentRef.set({ run_key: "anon-run-0123456789", status: "generating",
      lockedAt: admin.firestore.FieldValue.serverTimestamp(), conversationId: "conv_test" });
    await messagesCol.doc("bad").set({ kind: "user", text: "q1", createdAt: ts(BASE + 1),
      run_key: "anon-run-0123456789", activityId,
      activityUrl: "https://activity-player.concord.org/?activity=https%3A%2F%2Fauthoring.concord.org" });
    await messagesCol.doc("next").set({ kind: "user", text: "q2", createdAt: ts(BASE + 2),
      run_key: "anon-run-0123456789", activityId,
      activityUrl: `https://authoring.concord.org/api/v1/activities/${activityId}.json` });

    // The unit AFTER the skip fails transiently, so the drain throws before reaching the idle commit.
    // That leaves the mid-drain state observable, which is exactly what this asserts.
    const openai = makeFakeOpenAI();
    openai.responses.create = async () => { throw new Error("503 upstream unavailable"); };

    const restoreFetch = stubActivityFetch(pageId);
    try {
      await expect(processAndDrain(ctxFor(parentRef, messagesCol, openai, pageId)))
        .rejects.toThrow(/503/);
    } finally {
      restoreFetch();
    }

    const after = (await parentRef.get()).data() as any;
    expect(after.status).toBe("generating");             // lock still held → no concurrent drain
    expect(after.lastProcessedMessageId).toBe("bad");    // the skip's cursor advance did persist
    expect(after.error).toMatch(/disallowed activity host/); // and so did the reason
  });

  it("does NOT skip a transient failure — it propagates and leaves the cursor put for a retry", async () => {
    const { parentRef, messagesCol, pageId } = freshPaths();
    await parentRef.set({ run_key: "anon-run-0123456789", status: "generating",
      conversationId: "conv_test", promptInstalled: true });
    await messagesCol.doc("u1").set({ kind: "user", text: "q", createdAt: ts(BASE + 1),
      run_key: "anon-run-0123456789" });

    // A transient OpenAI outage. Skipping this would silently swallow the student's message with no
    // reply and no error, so it must keep the old behaviour: throw, and leave the cursor alone.
    const openai = makeFakeOpenAI();
    openai.responses.create = async () => { throw new Error("503 upstream unavailable"); };

    await expect(processAndDrain(ctxFor(parentRef, messagesCol, openai, pageId)))
      .rejects.toThrow(/503/);

    const after = (await parentRef.get()).data() as any;
    expect(after.lastProcessedMessageId).toBeUndefined(); // cursor did NOT advance → u1 is retried
  });

  it("acquireLock is single-in-flight and reclaims a stale lock", async () => {
    const { parentRef } = freshPaths();
    const owner = { run_key: "anon-run-0123456789" };
    // first acquire wins (parent absent → also stamps owner fields)
    expect(await acquireLock(parentRef, owner)).toBe(true);
    expect((await parentRef.get()).data()!.run_key).toBe("anon-run-0123456789");
    // second acquire backs off while genuinely generating
    expect(await acquireLock(parentRef, owner)).toBe(false);
    // a stale lock (lockedAt far in the past) is reclaimed
    await parentRef.set({ lockedAt: ts(BASE) }, { merge: true });
    expect(await acquireLock(parentRef, owner)).toBe(true);
  });

  it("does NOT wrongly idle when the query window is saturated with accumulated assistant docs", async () => {
    // Regression: assistant docs (later serverTimestamp) accumulate ahead of the
    // cursor and can FILL the limit(DRAIN_BATCH=200) window; a pending message sitting behind them (position
    // 201+) must still be found + processed, not orphaned by a false "queue empty".
    const { parentRef, messagesCol, pageId } = freshPaths();
    const run = "anon-run-0123456789";
    // cursor already at u0 (processed); then 201 assistant docs; then ONE pending user beyond the window.
    await messagesCol.doc("u0").set({ kind: "user", text: "old", createdAt: ts(BASE), run_key: run });
    const seed = admin.firestore().batch();
    for (let i = 0; i < 201; i++) {
      seed.set(messagesCol.doc(`a${i}`), { kind: "assistant", userText: "x", createdAt: ts(BASE + 1 + i), run_key: run });
    }
    seed.set(messagesCol.doc("pending1"), { kind: "user", text: "reach me", createdAt: ts(BASE + 100000), run_key: run });
    await seed.commit();
    await parentRef.set({ run_key: run, status: "generating", conversationId: "conv_test",
      promptInstalled: true, lastProcessedCreatedAt: ts(BASE), lastProcessedMessageId: "u0" });

    const openai = makeFakeOpenAI();
    await processAndDrain(ctxFor(parentRef, messagesCol, openai, pageId));

    expect(openai.calls.responses).toBe(1); // the pending user behind the assistant block WAS reached
    const after = (await parentRef.get()).data() as any;
    expect(after.lastProcessedMessageId).toBe("pending1");
    expect(after.status).toBe("idle");
  });
});
