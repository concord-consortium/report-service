/**
 * @jest-environment node
 */
// Fetch-hardening unit tests — pure, no emulator/network (global.fetch is stubbed).
//
// The deployed function runs on Node 22, which provides fetch / AbortController / TextEncoder /
// TextDecoder as globals. The jest-24 sandbox predates them, so polyfill the ones the code-under-test
// touches (fetch itself is stubbed per-test; the trivial AbortController is enough since the stub
// ignores the abort signal). TextEncoder/Decoder come from Node's `util`.
// eslint-disable-next-line @typescript-eslint/no-var-requires
import { TextEncoder as NodeTextEncoder, TextDecoder as NodeTextDecoder } from "util";
const g = global as any;
g.TextEncoder = g.TextEncoder ?? NodeTextEncoder;
g.TextDecoder = g.TextDecoder ?? NodeTextDecoder;
g.AbortController = g.AbortController ?? class { public signal = {}; public abort() { /* no-op */ } };

import {
  AUTHORING_HOSTS,
  resolveActivityUrl,
  defaultActivityUrl,
  parseActivityResource,
  fetchWithGuards,
  getActivityResource,
  clearActivityCache,
} from "./fetch-activity";

describe("resolveActivityUrl", () => {
  const base = { messageActivityId: "9", paramActivityId: "9" };

  it("accepts an allowlisted https authoring URL and returns the canonical single-activity URL", () => {
    const url = resolveActivityUrl({ ...base, activityUrl: "https://authoring.concord.org/activities/9" });
    expect(url).toBe("https://authoring.concord.org/api/v1/activities/9.json");
  });

  it("builds the fetch URL from the trusted host + PATH id, ignoring the raw client path", () => {
    // even a weird client path resolves to the canonical api URL for the path-param id
    const url = resolveActivityUrl({ ...base, activityUrl: "https://authoring.concord.org/anything/here?x=1" });
    expect(url).toBe("https://authoring.concord.org/api/v1/activities/9.json");
  });

  it("rejects a non-https URL", () => {
    expect(() => resolveActivityUrl({ ...base, activityUrl: "http://authoring.concord.org/activities/9" }))
      .toThrow(/https/);
  });

  it("rejects a host not on the allowlist (SSRF guard)", () => {
    expect(() => resolveActivityUrl({ ...base, activityUrl: "https://169.254.169.254/latest/meta-data" }))
      .toThrow(/disallowed activity host/);
    expect(() => resolveActivityUrl({ ...base, activityUrl: "https://evil.example.com/activities/9.json" }))
      .toThrow(/disallowed activity host/);
  });

  it("rejects a non-URL string", () => {
    expect(() => resolveActivityUrl({ ...base, activityUrl: "not a url" })).toThrow(/invalid activityUrl/);
  });

  it("rejects a message activityId that disagrees with the path param", () => {
    expect(() => resolveActivityUrl({
      activityUrl: "https://authoring.concord.org/activities/9",
      messageActivityId: "42",
      paramActivityId: "9",
    })).toThrow(/activityId mismatch/);
  });

  it("defaultActivityUrl uses the first allowlisted host (log-first path, no client input)", () => {
    expect(defaultActivityUrl("9")).toBe(`https://${AUTHORING_HOSTS[0]}/api/v1/activities/9.json`);
  });
});

describe("parseActivityResource shape checks", () => {
  it("rejects a non-JSON content-type", () => {
    expect(() => parseActivityResource({ contentType: "text/html", body: "{}" })).toThrow(/non-JSON/);
  });

  it("rejects invalid JSON", () => {
    expect(() => parseActivityResource({ contentType: "application/json", body: "{not json" }))
      .toThrow(/not valid JSON/);
  });

  it("rejects JSON that is not a LARA resource (no pages, not v1)", () => {
    expect(() => parseActivityResource({ contentType: "application/json", body: JSON.stringify({ foo: 1 }) }))
      .toThrow(/not a LARA resource/);
  });

  it("passes a v2 resource through unchanged", () => {
    const v2 = { version: 2, name: "A", pages: [] };
    const out: any = parseActivityResource({ contentType: "application/json; charset=utf-8", body: JSON.stringify(v2) });
    expect(out.version).toBe(2);
    expect(out.name).toBe("A");
  });

  it("runs a v1 resource through convertLegacyResource", () => {
    const v1 = { version: 1, name: "Legacy", pages: [], plugins: [] };
    const out: any = parseActivityResource({ contentType: "application/json", body: JSON.stringify(v1) });
    expect(out.version).toBe(2); // convert bumps version to 2
  });
});

// Minimal fake Response helpers for fetchWithGuards.
function textResponse(body: string, opts: { ok?: boolean; status?: number; contentType?: string } = {}) {
  return {
    ok: opts.ok ?? true,
    status: opts.status ?? 200,
    headers: { get: (h: string) => (h.toLowerCase() === "content-type" ? (opts.contentType ?? "application/json") : null) },
    text: async () => body,
    // no `body` stream → readBodyWithCap falls back to text()
  };
}

function streamResponse(chunks: Uint8Array[], opts: { contentType?: string } = {}) {
  let i = 0;
  return {
    ok: true,
    status: 200,
    headers: { get: (h: string) => (h.toLowerCase() === "content-type" ? (opts.contentType ?? "application/json") : null) },
    body: {
      getReader: () => ({
        read: async () => (i < chunks.length ? { done: false, value: chunks[i++] } : { done: true, value: undefined }),
        cancel: async () => undefined,
      }),
    },
  };
}

describe("fetchWithGuards", () => {
  const realFetch = (global as any).fetch;
  afterEach(() => { (global as any).fetch = realFetch; });

  it("returns content-type + capped body (text fallback path)", async () => {
    (global as any).fetch = jest.fn(async () => textResponse('{"ok":true}', { contentType: "application/json" }));
    const out = await fetchWithGuards("https://authoring.concord.org/x.json", { timeoutMs: 1000, maxBytes: 1000 });
    expect(out.contentType).toContain("application/json");
    expect(out.body).toBe('{"ok":true}');
  });

  it("throws on a non-2xx status", async () => {
    (global as any).fetch = jest.fn(async () => textResponse("nope", { ok: false, status: 404 }));
    await expect(fetchWithGuards("https://authoring.concord.org/x.json", { timeoutMs: 1000, maxBytes: 1000 }))
      .rejects.toThrow(/404/);
  });

  it("enforces the size cap on the text fallback path", async () => {
    (global as any).fetch = jest.fn(async () => textResponse("x".repeat(50), { contentType: "application/json" }));
    await expect(fetchWithGuards("https://authoring.concord.org/x.json", { timeoutMs: 1000, maxBytes: 10 }))
      .rejects.toThrow(/size cap/);
  });

  it("enforces the size cap while STREAMING (aborts mid-stream)", async () => {
    const chunk = new Uint8Array(8);
    (global as any).fetch = jest.fn(async () => streamResponse([chunk, chunk, chunk])); // 24 bytes
    await expect(fetchWithGuards("https://authoring.concord.org/x.json", { timeoutMs: 1000, maxBytes: 10 }))
      .rejects.toThrow(/size cap/);
  });

  it("streams a small body under the cap", async () => {
    const enc = new TextEncoder();
    (global as any).fetch = jest.fn(async () => streamResponse([enc.encode('{"a":'), enc.encode("1}")]));
    const out = await fetchWithGuards("https://authoring.concord.org/x.json", { timeoutMs: 1000, maxBytes: 1000 });
    expect(out.body).toBe('{"a":1}');
  });
});

describe("getActivityResource cache", () => {
  const realFetch = (global as any).fetch;
  afterEach(() => { (global as any).fetch = realFetch; clearActivityCache(); });

  it("fetches once and serves the cache within the TTL", async () => {
    const v2 = { version: 2, name: "Cached", pages: [] };
    const spy = jest.fn(async () => textResponse(JSON.stringify(v2), { contentType: "application/json" }));
    (global as any).fetch = spy;
    const url = "https://authoring.concord.org/api/v1/activities/9.json";
    const a = await getActivityResource(url, { ttlMs: 60000 });
    const b = await getActivityResource(url, { ttlMs: 60000 });
    expect((a as any).name).toBe("Cached");
    expect(b).toBe(a); // same cached object
    expect(spy).toHaveBeenCalledTimes(1);
  });

  it("re-fetches after the TTL expires", async () => {
    const spy = jest.fn(async () => textResponse(JSON.stringify({ version: 2, name: "X", pages: [] }), { contentType: "application/json" }));
    (global as any).fetch = spy;
    const url = "https://authoring.concord.org/api/v1/activities/9.json";
    await getActivityResource(url, { ttlMs: 0 }); // ttl 0 → always stale
    await getActivityResource(url, { ttlMs: 0 });
    expect(spy).toHaveBeenCalledTimes(2);
  });
});
