// Server-side activity fetch + cache + legacy convert, with SSRF/content-swap hardening.
//
// The activityUrl + activityId ride on an ANONYMOUS-writable message doc, so the function is a confused
// deputy unless it validates them before fetching. Hardening:
//   - require https + an AUTHORING_HOSTS allowlist (reject arbitrary/internal/metadata hosts);
//   - treat the PATH activityId (context.params) as authoritative and assert the message's copy matches;
//   - build the fetch URL from the trusted host + path activityId (never the raw client string);
//   - guard the fetch with a timeout, a streamed size cap, a content-type check, and a minimal
//     version/pages shape check before convert/assembly.
// version===1 resources are run through the lifted convertLegacyResource; v2 pass through. Results are
// cached by URL (module-level, per-instance) with a TTL so a mid-pilot author edit self-heals.
import { convertLegacyResource } from "./convert";
import { Activity } from "./types";

// Only these hosts may be fetched (the authoring hosts). https is also required.
export const AUTHORING_HOSTS = ["authoring.concord.org", "authoring.lara.staging.concord.org"];

// Fetch guardrails (defaults).
const FETCH_TIMEOUT_MS = 8000;
const FETCH_MAX_BYTES = 5_000_000; // ~5 MB — real single-activity payloads are ~125–140 KB
// cache TTL so a warm instance re-fetches after an author edit instead of serving stale forever.
const CACHE_TTL_MS = 5 * 60 * 1000;

export interface FetchGuardOptions {
  timeoutMs: number;
  maxBytes: number;
}

export interface FetchedBody {
  contentType: string;
  body: string;
}

// Validate the client-supplied fetch target and return the SAFE canonical activity URL to fetch.
// Throws on a non-URL, non-https, disallowed host, or an activityId that disagrees with the path param.
export function resolveActivityUrl(params: {
  activityUrl: string;
  messageActivityId: string;
  paramActivityId: string;
}): string {
  const { activityUrl, messageActivityId, paramActivityId } = params;
  let u: URL;
  try {
    u = new URL(activityUrl);
  } catch (e) {
    throw new Error("invalid activityUrl");
  }
  if (u.protocol !== "https:") throw new Error("activityUrl must use https");
  if (!AUTHORING_HOSTS.includes(u.hostname)) throw new Error(`disallowed activity host: ${u.hostname}`);
  if (String(messageActivityId) !== String(paramActivityId)) throw new Error("activityId mismatch");
  // Path param is authoritative — build the URL from the trusted host + path id, not the raw client string.
  return `https://${u.hostname}/api/v1/activities/${encodeURIComponent(paramActivityId)}.json`;
}

// The canonical fetch URL for the default authoring host, for the log-first path where no user
// message (and so no client activityUrl) exists yet. The host is a trusted constant, so there is no
// client-controlled input here and no SSRF surface.
export function defaultActivityUrl(paramActivityId: string): string {
  return `https://${AUTHORING_HOSTS[0]}/api/v1/activities/${encodeURIComponent(paramActivityId)}.json`;
}

// Read a Response body enforcing a hard byte cap, streaming when a reader is available (real fetch) and
// falling back to text() otherwise (test stubs). Throws if the cap is exceeded.
async function readBodyWithCap(resp: Response, maxBytes: number): Promise<string> {
  const body: any = (resp as any).body;
  if (body && typeof body.getReader === "function") {
    const reader = body.getReader();
    const decoder = new TextDecoder();
    let total = 0;
    let text = "";
    // eslint-disable-next-line no-constant-condition
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      if (value) {
        total += value.byteLength;
        if (total > maxBytes) {
          await reader.cancel();
          throw new Error("resource exceeds size cap");
        }
        text += decoder.decode(value, { stream: true });
      }
    }
    text += decoder.decode();
    return text;
  }
  const fallback = await resp.text();
  if (fallback.length > maxBytes) throw new Error("resource exceeds size cap");
  return fallback;
}

// Thin fetch wrapper: AbortController timeout + streamed size cap. Returns the content-type and
// the (capped) body text. Rejects on a non-2xx status.
export async function fetchWithGuards(url: string, opts: FetchGuardOptions): Promise<FetchedBody> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), opts.timeoutMs);
  try {
    const resp = await fetch(url, { signal: controller.signal, redirect: "error" });
    if (!resp.ok) throw new Error(`activity fetch failed: ${resp.status}`);
    const contentType = resp.headers.get("content-type") || "";
    const body = await readBodyWithCap(resp, opts.maxBytes);
    return { contentType, body };
  } finally {
    clearTimeout(timer);
  }
}

// Parse + validate a fetched body into an Activity (converting a v1 legacy resource). Separated from the
// network so it is unit-testable. Throws on non-JSON, invalid JSON, or a non-LARA shape.
export function parseActivityResource(fetched: FetchedBody): Activity {
  if (!fetched.contentType.includes("application/json")) throw new Error("non-JSON resource");
  let raw: any;
  try {
    raw = JSON.parse(fetched.body);
  } catch (e) {
    throw new Error("resource is not valid JSON");
  }
  if (typeof raw !== "object" || raw === null || !("pages" in raw || raw.version === 1)) {
    throw new Error("not a LARA resource");
  }
  return (raw.version === 1 ? convertLegacyResource(raw) : raw) as Activity;
}

interface CacheEntry {
  resource: Activity;
  fetchedAt: number;
}
const activityCache = new Map<string, CacheEntry>();

// Fetch (or serve cached) the converted Activity for an already-resolved, allowlisted URL.
export async function getActivityResource(
  safeUrl: string,
  opts: { ttlMs?: number; guards?: FetchGuardOptions } = {}
): Promise<Activity> {
  const ttlMs = opts.ttlMs ?? CACHE_TTL_MS;
  const cached = activityCache.get(safeUrl);
  if (cached && Date.now() - cached.fetchedAt < ttlMs) {
    return cached.resource;
  }
  const guards = opts.guards ?? { timeoutMs: FETCH_TIMEOUT_MS, maxBytes: FETCH_MAX_BYTES };
  const fetched = await fetchWithGuards(safeUrl, guards);
  const resource = parseActivityResource(fetched);
  activityCache.set(safeUrl, { resource, fetchedAt: Date.now() });
  return resource;
}

// Test/maintenance seam — clear the per-instance cache.
export function clearActivityCache(): void {
  activityCache.clear();
}
