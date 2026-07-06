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

  // A fresh isolated per-page path per test.
  const freshPaths = () => {
    const pageId = `p-${n++}`;
    const parentRef = db.doc(`sources/s/chats/k/activities/9/pages/${pageId}`);
    return { parentRef, messagesCol: parentRef.collection("messages"), pageId };
  };

  const ctxFor = (parentRef: any, messagesCol: any, openai: any, pageId: string): DrainContext => ({
    parentRef, messagesCol,
    params: { source: "s", key: "k", activityId: "9", pageId },
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
