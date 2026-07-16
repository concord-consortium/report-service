import { clearFirestore } from "../test/emulator-setup";
import { seedAnswer, seedHistory } from "../test/seed-helpers";
import bulkRead, { readAnswersEndpoint, readHistoryEndpoint } from "./bulk-read";

const BIG = 8 * 1024 * 1024;
const SOURCE = "example.com";
const LTI = { platform_id: "p1", platform_user_id: "u1", resource_link_id: "r1" };

const answersEp = (remote_endpoint: string) => ({ remote_endpoint, source: SOURCE });
const historyEp = (remote_endpoint: string) => ({ remote_endpoint, source: SOURCE, lti_tuple: LTI });

function mockRes() {
  const res: any = {};
  res.error = jest.fn((s: number, m: any) => { res._status = s; res._message = m; return res; });
  res.success = jest.fn((p: any) => { res._payload = p; return res; });
  return res;
}

beforeEach(async () => { await clearFirestore(); });

describe("readAnswersEndpoint", () => {
  it("paginates in __name__ order and resumes at the cursor with no gap/dup", async () => {
    for (const id of ["a1", "a2", "a3"]) {
      await seedAnswer({ ...LTI, source: SOURCE, remote_endpoint: "re-1", question_id: "q1", answer_id: id });
    }

    const p1 = await readAnswersEndpoint(answersEp("re-1"), null, 2, 100, BIG);
    expect(p1.items.map((i) => i.id)).toEqual(["a1", "a2"]);
    expect(p1.exhausted).toBe(false);
    expect(p1.innerCursor).toEqual({ docId: "a2" });

    const p2 = await readAnswersEndpoint(answersEp("re-1"), p1.innerCursor as any, 2, 100, BIG);
    expect(p2.items.map((i) => i.id)).toEqual(["a3"]);
    expect(p2.exhausted).toBe(true);
    expect(p2.innerCursor).toBeNull();
  });

  it("only returns the queried endpoint's answers", async () => {
    await seedAnswer({ ...LTI, source: SOURCE, remote_endpoint: "re-1", question_id: "q1", answer_id: "a1" });
    await seedAnswer({ ...LTI, source: SOURCE, remote_endpoint: "re-2", question_id: "q1", answer_id: "a2" });

    const r = await readAnswersEndpoint(answersEp("re-1"), null, 100, 100, BIG);
    expect(r.items.map((i) => i.id)).toEqual(["a1"]);
  });

  it("trims a page to the byte budget (always >=1 item) and resumes with no gap", async () => {
    for (const id of ["a1", "a2", "a3"]) {
      await seedAnswer({ ...LTI, source: SOURCE, remote_endpoint: "re-1", question_id: "q1", answer_id: id });
    }

    // a tiny budget forces trimming; the first item is always included (progress backstop)
    const p1 = await readAnswersEndpoint(answersEp("re-1"), null, 100, 100, 50);
    expect(p1.items.map((i) => i.id)).toEqual(["a1"]);
    expect(p1.exhausted).toBe(false);
    expect(p1.innerCursor).toEqual({ docId: "a1" });

    const p2 = await readAnswersEndpoint(answersEp("re-1"), p1.innerCursor as any, 100, 100, 50);
    expect(p2.items.map((i) => i.id)).toEqual(["a2"]);
  });

  it("passes the double-encoded report_state through untouched", async () => {
    await seedAnswer({
      ...LTI, source: SOURCE, remote_endpoint: "re-1", question_id: "q1", answer_id: "a1",
      interactiveState: { answerText: "hello" },
    });
    const r = await readAnswersEndpoint(answersEp("re-1"), null, 100, 100, BIG);
    const inner = JSON.parse(JSON.parse(r.items[0].report_state).interactiveState);
    expect(inner).toEqual({ answerText: "hello" });
  });
});

describe("readHistoryEndpoint", () => {
  const seedSnap = (history_id: string, seconds: number, nanoseconds: number, remote_endpoint = "re-1") =>
    seedHistory({
      ...LTI, source: SOURCE, remote_endpoint, question_id: "q1",
      answer_id: `ans-${history_id}`, history_id, created_at: { seconds, nanoseconds },
    });

  it("orders by (created_at, __name__), converts created_at to ISO, and reports touched on first derive", async () => {
    // an answer doc is required so the reader can derive the LTI tuple when the ep carries none
    await seedAnswer({ ...LTI, source: SOURCE, remote_endpoint: "re-1", question_id: "q1", answer_id: "a1" });
    await seedSnap("h1", 1000, 0);
    await seedSnap("h2", 2000, 0);

    // derive the tuple (no lti_tuple on the ep) -> touched reported
    const r = await readHistoryEndpoint(answersEp("re-1"), null, 100, 100, BIG);
    expect(r.items.map((i) => i.history_id)).toEqual(["h1", "h2"]);
    expect(typeof r.items[0].created_at).toBe("string");
    expect(r.items[0].created_at).toBe(new Date(1000 * 1000).toISOString());
    expect(r.touched).toEqual({ remote_endpoint: "re-1", lti_tuple: LTI });
  });

  it("does not skip a full-precision tie across a page boundary", async () => {
    // two snapshots at the SAME second with sub-second precision; the cursor must carry {seconds, nanoseconds}
    await seedSnap("h1", 1000, 133_000_000);
    await seedSnap("h2", 1000, 133_000_000);

    const p1 = await readHistoryEndpoint(historyEp("re-1"), null, 1, 100, BIG);
    expect(p1.items.map((i) => i.history_id)).toEqual(["h1"]);
    expect(p1.exhausted).toBe(false);

    const p2 = await readHistoryEndpoint(historyEp("re-1"), p1.innerCursor as any, 1, 100, BIG);
    expect(p2.items.map((i) => i.history_id)).toEqual(["h2"]);
  });

  it("post-filters to the authorized remote_endpoint (shared tuple, 1:many)", async () => {
    await seedSnap("h1", 1000, 0, "re-1");
    await seedSnap("h2", 2000, 0, "re-2");   // same LTI tuple, different learner endpoint

    const r = await readHistoryEndpoint(historyEp("re-1"), null, 100, 100, BIG);
    expect(r.items.map((i) => i.history_id)).toEqual(["h1"]);
  });

  it("returns EXACTLY limit items and resumes at limit+1 with no gap/dup", async () => {
    for (let i = 1; i <= 5; i++) { await seedSnap(`h${i}`, 1000 + i, 0); }

    const p1 = await readHistoryEndpoint(historyEp("re-1"), null, 2, 1000, BIG);
    expect(p1.items.map((i) => i.history_id)).toEqual(["h1", "h2"]);
    expect(p1.exhausted).toBe(false);

    const p2 = await readHistoryEndpoint(historyEp("re-1"), p1.innerCursor as any, 2, 1000, BIG);
    expect(p2.items.map((i) => i.history_id)).toEqual(["h3", "h4"]);
  });

  it("trims a history page to the byte budget (always >=1 item) and resumes with no gap", async () => {
    for (let i = 1; i <= 3; i++) { await seedSnap(`h${i}`, 1000 + i, 0); }

    const p1 = await readHistoryEndpoint(historyEp("re-1"), null, 100, 1000, 50);
    expect(p1.items.map((i) => i.history_id)).toEqual(["h1"]);
    expect(p1.exhausted).toBe(false);

    const p2 = await readHistoryEndpoint(historyEp("re-1"), p1.innerCursor as any, 100, 1000, 50);
    expect(p2.items.map((i) => i.history_id)).toEqual(["h2"]);
  });

  it("proves endpoint_exhausted via lookahead when a cap is hit exactly at the end", async () => {
    await seedSnap("h1", 1000, 0);
    await seedSnap("h2", 2000, 0);

    const r = await readHistoryEndpoint(historyEp("re-1"), null, 2, 1000, BIG);
    expect(r.items.map((i) => i.history_id)).toEqual(["h1", "h2"]);
    expect(r.exhausted).toBe(true);
    expect(r.innerCursor).toBeNull();
  });
});

describe("bulkRead handler", () => {
  it("returns an empty-mid-export page (endpoint cap) with a non-null resume via a first empty endpoint", async () => {
    await seedAnswer({ ...LTI, source: SOURCE, remote_endpoint: "re-2", question_id: "q1", answer_id: "a1" });

    const res = mockRes();
    await bulkRead({
      body: {
        collection: "answers",
        source_endpoints: [answersEp("re-empty"), answersEp("re-2")],
        inner_cursor: null,
        limit: 500,
        endpoint_limit: 1,   // stop after walking the first (empty) endpoint
        read_limit: 5000,
      },
    } as any, res);

    expect(res._payload.items).toEqual([]);
    expect(res._payload.endpoint_exhausted).toBe(true);
    expect(res._payload.stop_endpoint_offset).toBe(0);
  });

  it("stops walking endpoints once the response-byte budget is spent (aggregate across exhausted endpoints)", async () => {
    // Each endpoint holds ONE large answer (~1 MB serialized) and is therefore exhausted after its first
    // item — the per-endpoint byte trim never fires (an endpoint's first item is always admitted), so only
    // the walk-loop bytesUsed check can stop the chain before it blows past the ~8 MB budget.
    const endpointCount = 10;
    const bigState = "x".repeat(1_000_000);
    const endpoints = [];
    for (let i = 0; i < endpointCount; i++) {
      const remote_endpoint = `re-big-${i}`;
      await seedAnswer({
        ...LTI, source: SOURCE, remote_endpoint, question_id: "q1", answer_id: `big-${i}`,
        interactiveState: bigState,
      });
      endpoints.push(answersEp(remote_endpoint));
    }

    const res = mockRes();
    await bulkRead({
      body: {
        collection: "answers",
        source_endpoints: endpoints,
        inner_cursor: null,
        limit: 500,
        endpoint_limit: 250,
        read_limit: 5000,
      },
    } as any, res);

    // ~1 MB/item crosses the 8 MB budget on the 9th item -> the walk must stop early, not serve all 10
    const p1 = res._payload;
    expect(p1.items.length).toBeLessThan(endpointCount);
    expect(p1.items.length).toBeGreaterThanOrEqual(1);
    const stop = p1.stop_endpoint_offset;
    expect(stop).toBe(p1.items.length - 1);           // one item per endpoint, all walked endpoints exhausted
    expect(p1.endpoint_exhausted).toBe(true);
    expect(p1.inner_cursor).toBeNull();

    // resume from the next endpoint (as Elixir does: index + off + 1) -> the remainder arrives with no gap/dup
    const res2 = mockRes();
    await bulkRead({
      body: {
        collection: "answers",
        source_endpoints: endpoints.slice(stop + 1),
        inner_cursor: null,
        limit: 500,
        endpoint_limit: 250,
        read_limit: 5000,
      },
    } as any, res2);

    const gotIds = [...p1.items, ...res2._payload.items].map((i: any) => i.id).sort();
    expect(gotIds).toEqual(Array.from({ length: endpointCount }, (_, i) => `big-${i}`).sort());
  });
});
