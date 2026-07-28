# Implementation Plan: Mint Scoped Portal Tokens for the Pipeline's Portal Calls

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-83
**Requirements Spec**: [requirements.md](requirements.md)
**Status**: **In Development**

## Implementation Plan

The plan builds the reusable infrastructure first (token mint + per-run cache, the shared failure classifier, the `platform_id` allowlist), then cuts the three existing spring-2026 call sites over to it one at a time. Steps are ordered so nothing depends on a later step: the classifier (Step 2) precedes the `platform_id` check (Step 3) because the setup rejection reuses the classifier's shared tell-your-teacher message; the cutovers (Steps 4-6) depend on the infra (Step 1) and the classifier (Step 2). All new portal wiring lives in `functions/src/tasks/portal-api.ts` so the auth surface stays in one place.

Message discipline throughout: the classifier owns the two shared student messages (reload, tell-your-teacher); each step keeps its own existing generic message as the fallback for the generic bucket, so a plain retryable failure still reads step-specifically ("Unable to lock your pre-test...") while config/expiry failures get the shared coarse messages.

---

### Add scoped-token minting and a per-run token cache to the portal helper

**Summary**: Introduce the mint call (`oidc_mint`, OIDC-authed via the existing `portalOidcFetch`), the per-run token map keyed by scope + class, a cache-or-mint accessor, and a minted-token (`jwt_bearer_token`) fetch path. No call site changes yet, so this is a self-contained, independently testable infrastructure commit.

**Files affected**:
- `functions/src/tasks/portal-api.ts` — mint, cache, accessor, minted-token fetch; extract a shared request core.
- `functions/src/tasks/ai4vs-flvs/types.ts` — add the token-cache field to `StepContext`.
- `functions/src/tasks/ai4vs-flvs/index.ts` — initialize the empty cache once per run.
- `functions/src/tasks/portal-api.test.ts` — newly `jest.mock("firebase-functions", …)` (see the firebase-functions-mock fallout below); mint wiring, caching, cross-class second key, never-log.
- `functions/src/tasks/ai4vs-flvs/lock-activity.test.ts`, `send-email.test.ts`, `random-assignment.test.ts` — add `tokenCache` to each `StepContext` fixture in this commit (see the fixture fallout below) so the suite still compiles; the mint/classifier mock expansion lands later, with the cutover steps.

**Estimated diff size**: ~215 lines.

`portal-api.ts` additions (after the existing `portalOidcFetch`). First, refactor the shared `fetch` + JSON-parse core out of `portalOidcFetch` so the new minted-token path reuses it rather than duplicating it:

```ts
import * as functions from "firebase-functions";
// ...existing imports (GoogleAuth) unchanged...

// Shared transport: issue the request and parse a JSON body (null on non-JSON), returning { status, data }.
const performPortalRequest = async (
  url: string,
  method: string,
  headers: Record<string, string>,
  body?: string
): Promise<PortalResponse> => {
  const response = await fetch(url, { method, headers, body });
  const data = await response.json().catch(() => null);
  return { status: response.status, data };
};
```

`portalOidcFetch`'s tail becomes `return performPortalRequest(url, method, headers, body);` (auth-header logic unchanged). Then the minted-token path:

```ts
export interface PortalTokenRequestOptions {
  portalUrl: string;
  path: string;
  method: "GET" | "POST" | "PUT" | "PATCH" | "DELETE";
  /** The minted portal JWT. Sent as `Authorization: Bearer`. Opaque to report-service — never inspected or logged. */
  token: string;
  body?: string;
  headers?: Record<string, string>;
}

/**
 * Make a Portal request authenticated with a minted portal JWT (the jwt_bearer_token path),
 * as opposed to portalOidcFetch which mints a Google OIDC token.
 */
export const portalTokenFetch = async (options: PortalTokenRequestOptions): Promise<PortalResponse> => {
  const { portalUrl, path, method, token, body, headers: extraHeaders } = options;
  const headers: Record<string, string> = {
    ...(extraHeaders ?? {}),
    Authorization: `Bearer ${token}`,
  };
  return performPortalRequest(`${portalUrl}${path}`, method, headers, body);
};
```

Then the mint + cache:

```ts
// The pipeline only ever mints a teacher token; the portal also supports "learner", unused here.
export type TokenType = "teacher";

// Per-run cache. Key: `${tokenType}:${classId ?? "origin"}`. Created per run, never persisted.
export type PortalTokenCache = Map<string, string>;
export const createPortalTokenCache = (): PortalTokenCache => new Map();
const tokenCacheKey = (tokenType: TokenType, classId?: string): string => `${tokenType}:${classId ?? "origin"}`;

export interface MintTokenParams {
  portalUrl: string;
  /** The forwarded student Firebase custom token (StepContext.firebaseJwt), sent verbatim. */
  firebaseToken: string;
  tokenType: TokenType;
  /** Omitted => origin-class mint; set => cross-class mint for that class. */
  classId?: string;
  /**
   * Pipeline name (the pilot, e.g. "spring-2026"). The audit `description` is DERIVED from the token's
   * identity (pilot + scope) as `${pilot}:origin` | `${pilot}:class-${classId}`, NOT from the calling step.
   * Deriving it from the cache key (rather than passing a per-call step string) keeps the label a pure
   * function of the token, so a cached origin token shared by lock + notify always carries an accurate
   * `minted_for` instead of the label of whichever step happened to mint it first. Sanitized server-side;
   * never a secret.
   */
  pilot: string;
}

export interface MintTokenResult {
  ok: boolean;
  token?: string;
  status: number;
  /** details.reason when present (mint 422 forwarded-token failures). Only "expired" is terminal. */
  reason?: string;
}

/**
 * Mint a scoped portal token via POST /api/v1/jwt/oidc_mint, OIDC-authed.
 * SECURITY: the 201 success body carries a live bearer token — its body is NEVER logged here.
 */
export const mintScopedPortalToken = async (params: MintTokenParams): Promise<MintTokenResult> => {
  const { portalUrl, firebaseToken, tokenType, classId, pilot } = params;

  // Derive the audit label from the token's identity (pilot + scope), never the calling step, so a cached
  // origin token reused across steps always carries an accurate `minted_for`. e.g. "spring-2026:origin",
  // "spring-2026:class-12345".
  const description = classId === undefined ? `${pilot}:origin` : `${pilot}:class-${classId}`;

  const body: Record<string, string> = { firebase_token: firebaseToken, token_type: tokenType, description };
  if (classId !== undefined) {
    body.class_id = classId;
  }

  const response = await portalOidcFetch({
    portalUrl,
    path: "/api/v1/jwt/oidc_mint",
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });

  if (response.status === 201 && typeof response.data?.token === "string") {
    // Do NOT log response.data — it contains the token.
    return { ok: true, token: response.data.token, status: response.status };
  }

  // Failure bodies carry no token. details.reason present only for the mint's forwarded-token 422s.
  const reason = typeof response.data?.details?.reason === "string" ? response.data.details.reason : undefined;
  functions.logger.error("portal mint failed", { status: response.status, reason });
  return { ok: false, status: response.status, reason };
};

export interface GetTokenParams extends MintTokenParams {
  cache: PortalTokenCache;
}

/**
 * Return a cached scoped token for (tokenType, classId) or mint one on a miss and cache it.
 * The single path shared by this story's spring wiring and the sibling fall stories.
 */
export const getScopedPortalToken = async (params: GetTokenParams): Promise<MintTokenResult> => {
  const { cache, tokenType, classId } = params;
  const key = tokenCacheKey(tokenType, classId);
  const cached = cache.get(key);
  if (cached) {
    return { ok: true, token: cached, status: 200 };
  }
  const result = await mintScopedPortalToken(params);
  if (result.ok && result.token) {
    cache.set(key, result.token);
  }
  return result;
};
```

`ai4vs-flvs/types.ts` — add the cache to the run context:

```ts
import { PortalTokenCache } from "../portal-api";
// ...
export interface StepContext {
  jobPath: string;
  jobDoc: IJobDocument;
  firebaseJwt?: string;
  stepResults: Record<string, StepResult>;
  tokenCache: PortalTokenCache;
}
```

`ai4vs-flvs/index.ts` — initialize once per run (line 53):

```ts
const stepContext: StepContext = { jobPath, jobDoc, firebaseJwt, stepResults: {}, tokenCache: createPortalTokenCache() };
```

**Tests** (`portal-api.test.ts`, `fetch` mocked): mint sends `firebase_token`/`token_type`/`class_id` (only when supplied) OIDC-authed and returns `{ ok, token }` on `201 { token }`; the **derived** `description` is asserted (`"spring-2026:origin"` for an origin mint, `"spring-2026:class-<id>"` for a cross-class mint), confirming it is a function of the token's identity, not the caller; a second `getScopedPortalToken` with the same key does not re-`fetch` (cache hit); a different `classId` mints a second token (distinct key); a `422 { details: { reason } }` yields `{ ok: false, reason }`; and a spy on `functions.logger` asserts the raw token string appears in **no** log call on the success path (never-log).

**Run-level cache-dedup assertion lives here, not in `index.test.ts`** (see the notes-to-implementer under the final step): with `fetch` mocked, drive `getScopedPortalToken` for the origin key twice and a destination `classId` once against one shared cache, and assert exactly **two** `oidc_mint` `fetch` calls occurred and the origin key's second call returned the first mint's token (reused, no third mint). This is the cache-level proof of the "mint once per class, reuse across steps" AC; it does not require the pipeline's step handlers.

**Fixture fallout (do not miss):** making `tokenCache` a **required** `StepContext` field breaks compilation of every existing `StepContext` fixture. `lock-activity.test.ts` and `send-email.test.ts` build the literal in a `makeContext()` helper; `random-assignment.test.ts` builds it **inline** (its failing literal is the one near the end of the file, not a shared helper). Each fails with `TS2741: Property 'tokenCache' is missing` under ts-jest until it adds `tokenCache: createPortalTokenCache()` (and `firebaseJwt` where the cut-over step now destructures it). This is a compile-time break of the whole suite, not a per-test assertion change, so these three fixture edits must ride in **this** (Step 1) commit even though the mock expansion below waits for the cut-over steps. (Empirically reproduced: applying the Step 1 edits yields exactly three `TS2741` errors, one per file, and no other source-tree type errors.)

**firebase-functions-mock fallout (do not miss):** today `portal-api.ts` imports **only** `google-auth-library`, so `portal-api.test.ts` imports the real module and never mocks `firebase-functions`. This step adds `import * as functions from "firebase-functions"` (the mint's `functions.logger.error`) to `portal-api.ts`, so `portal-api.test.ts` now transitively loads the **real** firebase-functions SDK, which fails to resolve under jest (`Cannot find module 'firebase-admin/auth' from 'identity.js'`) and the **suite fails to run at all** (`Tests: 0 total`), distinct from the `TS2741` compile break above. Fix: `portal-api.test.ts` must add `jest.mock("firebase-functions", () => ({ logger: { info: jest.fn(), error: jest.fn(), warn: jest.fn() } }))` (the same full-module mock the three step-test files already use). This mock is doubly required: the never-log test also needs a spy-able `functions.logger`. (Empirically reproduced: without the mock the suite errors at load; with it, the module imports and the classifier / `validatePortalHost` cases pass.) Note the `moduleNameMapper` already maps `firebase-functions/params` to the real `lib/params/index.js`, so `defineString` is fine unmocked; only the bare `firebase-functions` root import needs the mock.

**Test env isolation (portal-api.test.ts):** this file will host both the mint tests (whose real `portalOidcFetch` **reads** `process.env.FUNCTIONS_EMULATOR`, throwing if it is `"true"` with no `PORTAL_OIDC_TOKEN`) and the new `validatePortalHost` loopback tests (which **set** `FUNCTIONS_EMULATOR="true"` and `TRUSTED_PORTAL_HOSTS`). Save and restore both env vars per describe block (the existing `describe("portalOidcFetch")` already models this: capture `originalEnv`, `process.env = { ...originalEnv }` + `delete FUNCTIONS_EMULATOR` in `beforeEach`, restore in `afterAll`) so a loopback test cannot leak the emulator flag into a later mint test and cause an order-dependent failure.

**Mock fallout (same three files):** each step test currently does `jest.mock("../portal-api", () => ({ portalOidcFetch }))`, a full-module replacement exposing only `portalOidcFetch`. Once the cut-over steps import `getScopedPortalToken` / `portalTokenFetch` / `classifyPortalFailure` / `messageForBucket` from `../portal-api`, that factory must expand: mock `getScopedPortalToken` and `portalTokenFetch`, but preserve the **real** `classifyPortalFailure` / `messageForBucket` (e.g. spread `...jest.requireActual("../portal-api")`, then override the two minted-token entry points) since the new reload / tell-teacher / generic bucket assertions depend on their real output. Leaving the narrow mock makes those exports `undefined`, so the mint call throws into the step's outer `catch` (yielding the generic message) and every bucket-specific assertion fails. This is distinct from the `tokenCache` compile break above: it fails at runtime, per-file, once the imports land.

---

### Add the shared portal-failure classifier

**Summary**: One classifier mapping an HTTP status (+ optional `details.reason`) to a coarse bucket, plus a helper turning a bucket into the student message (shared text for reload/tell-teacher; caller-supplied fallback for generic). Reused by the mint, enroll, lock, notify, and the notify offering-read. Bucketing is by HTTP status: any 4xx is a non-retryable client/config/authorization error → tell-your-teacher (the downstream `403` is the thin Pundit shape with no `details`, so status, not `details.reason`, decides it), except `details.reason === "expired"`, the one terminal case that instead asks for a reload.

**Files affected**:
- `functions/src/tasks/portal-api.ts` — bucket enum, `classifyPortalFailure`, `messageForBucket`, exported messages.
- `functions/src/tasks/portal-api.test.ts` — each bucket, including the network/throw path.

**Estimated diff size**: ~130 lines.

```ts
export enum PortalFailureBucket {
  Reload = "reload",            // mint 422 details.reason "expired": session expired, reload + click again
  TellTeacher = "tell_teacher", // config/authorization: tell your teacher (unretryable)
  Generic = "generic",          // retryable/unknown: caller's own "try again or contact your teacher"
}

export const RELOAD_MESSAGE =
  "Your session may have expired. Please reload the activity and click “I’m Done” again.";
export const TELL_TEACHER_MESSAGE =
  "Something went wrong setting up your class. Please tell your teacher.";

export interface PortalCallOutcome {
  /** HTTP status, or 0 for a thrown/network error (no response). */
  status: number;
  /** details.reason if present (mint 422 forwarded-token failures only). */
  reason?: string;
}

/**
 * Classify a failed (or thrown) portal call. Buckets by HTTP status; only mint-422-expired is terminal.
 * After the expired check, ANY 4xx is a client/config/authorization error retry cannot fix and maps to
 * tell-your-teacher: 400 (ParameterMissing, or send_class_teachers' error() default of 400 for an
 * unresolvable class_id), 401 (mint require_api_user! before require_token_minter!), 403 (mint auth /
 * downstream Pundit denial / offering-read api_show? denial), 404 (offering-read unresolved), non-expired
 * 422. Everything else (2xx-non-success, 5xx, network/throw with status 0) is generic-retryable.
 */
export const classifyPortalFailure = (outcome: PortalCallOutcome): PortalFailureBucket => {
  const { status, reason } = outcome;
  if (status === 422 && reason === "expired") {
    return PortalFailureBucket.Reload;
  }
  if (status >= 400 && status < 500) {
    return PortalFailureBucket.TellTeacher;
  }
  return PortalFailureBucket.Generic;
};

export const messageForBucket = (bucket: PortalFailureBucket, genericFallback: string): string => {
  switch (bucket) {
    case PortalFailureBucket.Reload: {
      return RELOAD_MESSAGE;
    }
    case PortalFailureBucket.TellTeacher: {
      return TELL_TEACHER_MESSAGE;
    }
    default: {
      return genericFallback;
    }
  }
};
```

Because a thrown `fetch` produces no `{ status, data }`, each call site keeps its existing `try/catch`; the `catch` classifies with `{ status: 0 }`, landing in the generic bucket exactly as today.

**Tests** (`portal-api.test.ts`): `422`+`expired` → reload; `400`, `422`+other-reason, `422`+no-reason, `401`, `403`, `404` → tell-teacher; `200` (2xx-non-success), `500`, and `{ status: 0 }` (thrown) → generic; `messageForBucket` returns the shared strings for reload/tell-teacher and the fallback for generic.

---

### Validate `platform_id` against a trusted-host allowlist at run setup

**Summary**: Add a `defineString`-backed host allowlist and a validator mirroring `chat/fetch-activity.ts` (parse as URL, require https, allowlist the hostname), and call it once in `index.ts` before the pipeline loop so it structurally gates every portal call (mint, enroll, lock, notify, offering-read). On failure the run ends at setup: no Firebase token forwarded, no mint attempted, rejected host logged (host only).

**Files affected**:
- `functions/src/tasks/portal-api.ts` — `TRUSTED_PORTAL_HOSTS` param + `validatePortalHost`.
- `functions/src/tasks/ai4vs-flvs/index.ts` — the setup check before the loop.
- `functions/src/tasks/ai4vs-flvs/index.test.ts` — rejection AC.

**Estimated diff size**: ~100 lines.

`portal-api.ts`:

```ts
import { defineString } from "firebase-functions/params";

// Comma-separated trusted portal hostnames, per-environment (e.g. "learn.concord.org" in prod,
// "learn.portal.staging.concord.org" in staging). Read at runtime via .value().
const trustedPortalHosts = defineString("TRUSTED_PORTAL_HOSTS");
const parseTrustedHosts = (): string[] => trustedPortalHosts.value().split(",").map(h => h.trim()).filter(Boolean);

export interface PortalHostValidation {
  ok: boolean;
  /** The rejected hostname/host, for logging only. Never contains a token. */
  host?: string;
}

// Loopback hosts that may use http, for local full-stack dev (a locally-run portal on http://localhost).
const LOOPBACK_HOSTS = new Set(["localhost", "127.0.0.1", "[::1]"]);
const isEmulator = (): boolean => process.env.FUNCTIONS_EMULATOR === "true";

/**
 * Validate a client-supplied platform_id as a trusted portal base URL.
 * Mirrors chat/fetch-activity.ts resolveActivityUrl: parse as URL, require https, allowlist the hostname.
 *
 * Dev carve-out: http is permitted ONLY for a loopback host AND only in the emulator. The hostname must
 * still be present in TRUSTED_PORTAL_HOSTS (only the emulator .env.local lists localhost), so no deployed
 * project can ever accept localhost: prod/staging never list it, and the http relaxation is emulator-gated.
 */
export const validatePortalHost = (platformId: unknown): PortalHostValidation => {
  if (typeof platformId !== "string" || !platformId) {
    return { ok: false };
  }
  let url: URL;
  try {
    url = new URL(platformId);
  } catch {
    return { ok: false };
  }
  const httpLoopbackOk = url.protocol === "http:" && LOOPBACK_HOSTS.has(url.hostname) && isEmulator();
  if (url.protocol !== "https:" && !httpLoopbackOk) {
    return { ok: false, host: url.host };
  }
  if (!parseTrustedHosts().includes(url.hostname)) {
    return { ok: false, host: url.hostname };
  }
  return { ok: true, host: url.hostname };
};
```

**Validate-only, not URL-rebuild (intentional; where this deviates from the precedent).** The cited precedent `resolveActivityUrl` (`chat/fetch-activity.ts`) not only allowlists `u.hostname` but then *rebuilds* the fetch URL from the trusted host + a fixed path ("never the raw client string"). `validatePortalHost` deliberately does less: it validates and returns `{ ok, host }`, and the call sites keep using the raw `platform_id` as `portalUrl` (`portalUrl: platform_id`). This is safe because the allowlist is an **exact** `hostname` match (`parseTrustedHosts().includes(url.hostname)`), and `fetch` parses the same string with the same WHATWG URL semantics, so the host the token is sent to is exactly the validated, allowlisted host: a `platform_id` like `https://learn.concord.org@evil.com` resolves to `hostname = "evil.com"` and is rejected, and `https://learn.concord.org.evil.com` is rejected as an inexact match. The one residual difference from the rebuild approach is that a `platform_id` carrying a **port, path, or query** (`https://learn.concord.org:8443`, `.../foo`, `...?x=1`) passes the gate and survives into the concatenated `${platform_id}${path}` URL rather than being stripped, but the blast radius is bounded to the trusted host (a wrong port/path on that host → a failed request, not a token sent elsewhere). Real LTI `platform_id`s are always a clean origin (`https://learn.concord.org`, as in the fixtures). If a future requirement needs the port/path/query stripped too, canonicalize to `https://${url.hostname}` in `validatePortalHost` and thread that base to the call sites; it is not needed for the token-exfiltration property this gate exists to guarantee.

`index.ts` — insert after the `firebaseJwt` guard and pilot/pipeline lookup, immediately before constructing `stepContext` / the loop (so it precedes `evaluate-completion`, which is harmless since that step only reads Firestore, and every outbound portal call is downstream of here):

```ts
// Gate every outbound portal call in this run: reject an untrusted/non-https platform_id at setup,
// before any Firebase token is forwarded and before any mint is attempted.
const hostCheck = validatePortalHost(jobDoc.platform_id);
if (!hostCheck.ok) {
  functions.logger.error(`ai4vs-flvs: rejected untrusted platform_id for ${jobPath}`, { host: hostCheck.host });
  await markComplete(jobPath, "failure", { message: TELL_TEACHER_MESSAGE });
  return;
}
```

`TELL_TEACHER_MESSAGE` is exported from `portal-api.ts` (defined in the classifier step above) and imported here so the setup-rejection message matches the classifier's bucket.

**Config is a hard, fail-closed deploy precondition.** With `TRUSTED_PORTAL_HOSTS` unset or empty the allowlist is empty and the gate rejects **every** run at setup (100% failure), so the param must be set for each project before this story deploys. Params live in the git-tracked per-project files: add `TRUSTED_PORTAL_HOSTS=learn.concord.org` to `functions/.env.report-service-pro` and `TRUSTED_PORTAL_HOSTS=learn.portal.staging.concord.org` to `functions/.env.report-service-dev` (both committed alongside the existing `AUTHORING_HOST`/`OPENAI_MODEL` entries), and `TRUSTED_PORTAL_HOSTS=learn.portal.staging.concord.org,localhost,127.0.0.1` to the gitignored emulator `functions/.env.local`. Because rollout is manual with no alerting, this belongs in the Rollout-sequencing precondition list (requirements.md), not just the Open-Question resolution: a forgotten param silently breaks every student. The `.env.<project>` edits should ride in the same commit as the gate so the config is not a separate memory step.

**Reuse across future pipelines (security).** `validatePortalHost` is a pure, exported helper, so the REPORT-82 fall pipelines reuse the *validation* directly. The setup **gate** (validate -> log host -> `markComplete` tell-teacher -> return) is per-pipeline because it couples to `markComplete` and to the pipeline's own early-return; it must be included in every portal-calling pipeline's setup, and is recorded as a required setup step in the fall-pipeline handoff (Out of Scope, requirements.md) so a new pipeline cannot silently omit the token-exfiltration gate. Extracting a shared `assertTrustedPortalHost(jobPath, jobDoc)` wrapper is deferred to when the second consumer (REPORT-82) actually lands, rather than guessed at now.

**Tests**: `validatePortalHost` unit tests (`portal-api.test.ts`) covering the allowlist and the loopback carve-out: a listed `https:` host passes; an un-listed host and a non-URL fail; `http://` on a non-loopback host fails; `http://localhost:3000` passes only when `localhost` is in `TRUSTED_PORTAL_HOSTS` **and** `FUNCTIONS_EMULATOR === "true"`, and fails if either condition is absent (emulator off, or localhost not listed), proving no deployed project can accept localhost. These read the param via `defineString(...).value()`, so each test sets `process.env.TRUSTED_PORTAL_HOSTS` for the case it exercises.

Run-level tests (`index.test.ts`): with `process.env.TRUSTED_PORTAL_HOSTS` set to a known host, a `jobDoc.platform_id` on an un-listed host and an `http://` host each fail the run at setup with the tell-your-teacher message. Because `index.test.ts` **mocks all four step handlers**, the correct rejection assertion is that the first step handler (`mockRandomAssignment`/`mockEvaluateCompletion`) was **never called** and `markComplete` was called with `"failure"` + `TELL_TEACHER_MESSAGE` (not "assert `fetch` was never called" — `fetch` is never reached in this file regardless), and that the logged object carries `host` but no token; a trusted `platform_id` proceeds into the pipeline.

**Existing-suite fallout (do not miss):** the pre-existing `index.test.ts` tests all use `platform_id: "https://learn.concord.org"` and never set `TRUSTED_PORTAL_HOSTS`. Once the gate lands, an unset param resolves to `""` (verified: `defineString(...).value()` returns `""` in jest), so the empty allowlist rejects every fixture and all pre-existing tests fail at setup with the tell-your-teacher message. Add a `beforeEach` in `index.test.ts` that sets `process.env.TRUSTED_PORTAL_HOSTS = "learn.concord.org"` (matching the fixtures' host) so the happy-path tests still exercise the pipeline; the same applies to any other test that drives `ai4vsFlvs` end-to-end.

---

### Cut the enroll step over to a cross-class minted token

**Summary**: Replace the enroll's `portalOidcFetch` with a cross-class mint (`classId = destination clazz_id`) + `portalTokenFetch` to the unchanged `add_to_class`, JSON body byte-identical to today. Classify mint and enroll failures.

**Files affected**:
- `functions/src/tasks/ai4vs-flvs/random-assignment.ts` — destructure `tokenCache`; swap the enroll call.
- `functions/src/tasks/ai4vs-flvs/random-assignment.test.ts` — cross-class mint + minted-token auth + buckets.

**Estimated diff size**: ~110 lines.

`random-assignment` already destructures and validates `firebaseJwt`; add `tokenCache`. Replace the enroll block (currently `random-assignment.ts:396-419`) with:

```ts
// Cross-class mint: enroll must act as a teacher SHARED between the origin and destination classes
// (add_to_class authorizes update_roster? on the destination AND student :show?). A study with no
// shared teacher yields a mint 422 -> tell-your-teacher.
const tokenResult = await getScopedPortalToken({
  cache: tokenCache,
  portalUrl: platform_id,
  firebaseToken: firebaseJwt,
  tokenType: "teacher",
  classId: String(classId),
  pilot: String(jobDoc.jobInfo.request.pilot), // audit label derived by getScopedPortalToken as `${pilot}:class-${classId}`
});
if (!tokenResult.ok || !tokenResult.token) {
  const mintBucket = classifyPortalFailure({ status: tokenResult.status, reason: tokenResult.reason });
  return { success: false, message: messageForBucket(mintBucket, STUDENT_FAILURE_MESSAGE) };
}

const response = await portalTokenFetch({
  portalUrl: platform_id,
  path: "/api/v1/students/add_to_class",
  method: "POST",
  token: tokenResult.token,
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ user_id: String(platform_user_id), clazz_id: String(classId) }),
});

if (response.status >= 200 && response.status < 300 && response.data?.success === true) {
  functions.logger.info(`random-assignment: successfully enrolled user ${platform_user_id} in ${className} (${jobPath})`);
  return { success: true, summary: `Assigned to ${className}` };
}

functions.logger.error(`random-assignment: Portal enrollment failed for ${jobPath}`, { status: response.status, data: response.data });
const bucket = classifyPortalFailure({ status: response.status, reason: response.data?.details?.reason });
return { success: false, message: messageForBucket(bucket, STUDENT_FAILURE_MESSAGE) };
```

The outer `try/catch` (thrown → `STUDENT_FAILURE_MESSAGE`) and the `finally` Firestore cleanup are unchanged; optionally route the `catch` through `classifyPortalFailure({ status: 0 })` for consistency (still generic).

**Tests** (expand the `../portal-api` mock per Step 1's Mock-fallout note): mint is called with `class_id = destination` and `description`; `add_to_class` is sent with `Authorization: Bearer <minted>` and the JSON body unchanged; a mint `422 expired` → reload message and no `add_to_class` call; an enroll `403` → tell-teacher; a `2xx` with `success !== true` → the step's generic message.

---

### Cut the lock step over to the origin-class minted token

**Summary**: Add the `firebaseJwt` (and `tokenCache`) destructure to `lockActivity`, mint the origin-class token (default mint, no `class_id`), and `portalTokenFetch` the `update_student_metadata` PUT with the body still `application/x-www-form-urlencoded` via `URLSearchParams` (byte-compatible with today). Classify failures.

**Files affected**:
- `functions/src/tasks/ai4vs-flvs/lock-activity.ts` — destructure `firebaseJwt`/`tokenCache`; mint + swap auth.
- `functions/src/tasks/ai4vs-flvs/lock-activity.test.ts` — origin mint + form-urlencoded preserved + buckets.

**Estimated diff size**: ~90 lines.

`lockActivity` signature becomes `({ jobPath, jobDoc, firebaseJwt, tokenCache }: StepContext)`. After the existing required-field validation, add a `firebaseJwt` guard (defensive; `index.ts` already guarantees it), then:

```ts
const tokenResult = await getScopedPortalToken({
  cache: tokenCache,
  portalUrl: platform_id,
  firebaseToken: firebaseJwt,
  tokenType: "teacher",
  pilot: String(jobDoc.jobInfo.request.pilot), // origin mint (no classId) => audit label `${pilot}:origin`
});
if (!tokenResult.ok || !tokenResult.token) {
  const mintBucket = classifyPortalFailure({ status: tokenResult.status, reason: tokenResult.reason });
  return { success: false, message: messageForBucket(mintBucket, STUDENT_FAILURE_MESSAGE) };
}

const response = await portalTokenFetch({
  portalUrl: platform_id,
  path: `/api/v1/offerings/${resource_link_id}/update_student_metadata`,
  method: "PUT",
  token: tokenResult.token,
  headers: { "Content-Type": "application/x-www-form-urlencoded" },
  body: new URLSearchParams({ locked: "true", user_id: String(platform_user_id) }).toString(),
});
```

Success stays `status 2xx`; on non-2xx, `classifyPortalFailure({ status: response.status, reason: response.data?.details?.reason })` with `STUDENT_FAILURE_MESSAGE` as the generic fallback.

**Tests** (expand the `../portal-api` mock per Step 1's Mock-fallout note): mint called with no `class_id` (origin key); the PUT carries `Authorization: Bearer <minted>` and the unchanged `locked=true&user_id=...` form body; buckets as above.

---

### Cut the notify step over to `send_class_teachers` with an offering-read

**Summary**: Add the `firebaseJwt`/`tokenCache` destructure (with a defensive `firebaseJwt` guard after the existing required-field validation, matching lock, since `MintTokenParams.firebaseToken` is `string` while `StepContext.firebaseJwt` is `string | undefined`), mint the origin-class token, resolve the origin `class_id` via `GET /api/v1/offerings/:resource_link_id` (`clazz_id`) with that token, then `send_class_teachers` `{ class_id, subject, message }` as JSON with the same token. The origin mint here shares the `"origin"` cache key with lock. Classify the mint, the offering-read, and the send.

**Every mint-calling step must narrow `firebaseJwt` first.** `getScopedPortalToken` takes `firebaseToken: string`, but each step receives `StepContext.firebaseJwt: string | undefined`, so a step that passes it through without a guard fails to compile (`TS2345`, verified under this repo's ts-jest). Enroll already has this guard (`random-assignment.ts:302-305`); lock adds it (Step 5); send-email adds it here (below). `index.ts` guarantees a non-empty `firebaseJwt` at run setup, so the per-step guard is defensive/type-narrowing, not a new runtime gate.

**Files affected**:
- `functions/src/tasks/ai4vs-flvs/send-email.ts` — destructure `firebaseJwt`/`tokenCache`; mint + offering-read + endpoint/body switch.
- `functions/src/tasks/ai4vs-flvs/send-email.test.ts` — endpoint switch + class_id resolution + minted-token auth + buckets.

**Estimated diff size**: ~140 lines.

Subject handling (existing `email_subject` override + `DEFAULT_SUBJECT` + `sanitizeSubject`) and `buildEmailBody` are unchanged. Replace the `oidc_send` block with:

```ts
// Defensive: index.ts already guarantees firebaseJwt, but narrow string | undefined -> string
// for the mint (matches lock-activity; without this the getScopedPortalToken call fails to compile).
if (!firebaseJwt) {
  functions.logger.error(`send-email: missing Firebase JWT for ${jobPath}`);
  return { success: false, message: STUDENT_FAILURE_MESSAGE };
}

const tokenResult = await getScopedPortalToken({
  cache: tokenCache,
  portalUrl: platform_id,
  firebaseToken: firebaseJwt,
  tokenType: "teacher",
  pilot: String(jobDoc.jobInfo.request.pilot), // origin mint => `${pilot}:origin`; cache HIT reuses lock's token (no 3rd mint)
});
if (!tokenResult.ok || !tokenResult.token) {
  const mintBucket = classifyPortalFailure({ status: tokenResult.status, reason: tokenResult.reason });
  return { success: false, message: messageForBucket(mintBucket, STUDENT_FAILURE_MESSAGE) };
}
const token = tokenResult.token;

// Resolve the origin class_id from the offering (send_class_teachers needs class_id; we hold resource_link_id).
const offeringResp = await portalTokenFetch({
  portalUrl: platform_id,
  path: `/api/v1/offerings/${resource_link_id}`,
  method: "GET",
  token,
});
const classId = offeringResp.data?.clazz_id;
const offeringOk = offeringResp.status >= 200 && offeringResp.status < 300 && classId !== undefined && classId !== null;
if (!offeringOk) {
  functions.logger.error(`send-email: offering-read failed for ${jobPath}`, { status: offeringResp.status });
  const offeringBucket = classifyPortalFailure({ status: offeringResp.status, reason: offeringResp.data?.details?.reason });
  return { success: false, message: messageForBucket(offeringBucket, STUDENT_FAILURE_MESSAGE) };
}

const response = await portalTokenFetch({
  portalUrl: platform_id,
  path: "/api/v1/emails/send_class_teachers",
  method: "POST",
  token,
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ class_id: String(classId), subject, message }),
});
if (response.status >= 200 && response.status < 300 && response.data?.success === true) {
  functions.logger.info(`send-email: email sent successfully (${jobPath})`);
  return { success: true };
}
functions.logger.error(`send-email: Portal returned ${response.status} for ${jobPath}`, { status: response.status, data: response.data });
const bucket = classifyPortalFailure({ status: response.status, reason: response.data?.details?.reason });
return { success: false, message: messageForBucket(bucket, STUDENT_FAILURE_MESSAGE) };
```

**Tests** (expand the `../portal-api` mock per Step 1's Mock-fallout note): mint (origin key) → offering-read on `resource_link_id` returning `{ clazz_id }` → `send_class_teachers` with `{ class_id, subject, message }` and `Authorization: Bearer <minted>`; an offering-read `403`/`404` → tell-teacher and no send; a send `403` → tell-teacher; a `2xx` with `success !== true` → generic. Assert the endpoint is `send_class_teachers` (not `oidc_send`) and the body is JSON.

---

### Reconcile `ai4vs-flvs/index.test.ts` with the gate (and where the dedup assertion actually lives)

**Summary**: `index.test.ts` `jest.mock()`s all four step handlers and asserts only on `stepResults` accumulation and completion messages; it never exercises real `fetch`, the mint, or the token cache. So there are **no** portal-call/`fetch` expectations in this file to update for the mint/offering-read/endpoint changes, and the run-level cache-dedup assertion **cannot** run here while the handlers are mocked. This step is therefore limited to the two `index.test.ts` changes already specified in the `platform_id`-gate step (Step 3): the `beforeEach` that sets `process.env.TRUSTED_PORTAL_HOSTS` so the pre-existing tests stay green, and the new untrusted-`platform_id` rejection tests. It is called out separately only to make the reconciliation explicit; fold it into Step 3's commit.

**Where the "mint called exactly twice, origin token reused" AC is proven**: at the **cache level in `portal-api.test.ts`** (Step 1's run-level cache-dedup assertion), not here. That proof needs only `getScopedPortalToken` + a mocked `fetch`, so it does not require un-mocking the pipeline. Re-creating it at the pipeline level would mean replacing this file's whole mocking strategy (un-mock all four handlers, then mock `fetch` + Firestore + `GoogleAuth` for one real run) — a genuine integration test, deliberately **not** taken on here. If an end-to-end run-level dedup check is ever wanted, add it as a separate, explicitly-scoped `*.emulator.test.ts`-style integration test rather than bending this unit file.

**Files affected**:
- `functions/src/tasks/ai4vs-flvs/index.test.ts` (the Step 3 changes; no separate portal-call expectations exist).

**Estimated diff size**: covered by Step 3 (~0 additional).

---

## Open Questions

### RESOLVED: Should `404` bucket to tell-your-teacher for every call site, or only the offering-read?
**Context**: `classifyPortalFailure` maps `404` → tell-teacher uniformly. The requirements only name the offering-read `404` explicitly. A `404` on enroll/lock is unusual (a missing class/offering), and tell-teacher is a defensible read of it, but a case could be made that a non-offering `404` belongs in the generic bucket.
**Options considered**:
- A) Uniform `404` → tell-teacher (current draft). Simplest; treats any 404 as an unresolvable-resource config problem.
- B) `404` → tell-teacher only for the offering-read; generic elsewhere. Requires passing a per-call-site flag into the classifier.

**Decision**: **A (uniform `404` → tell-your-teacher).** Across this pipeline a `404` only ever means a missing class/offering: lock's `update_student_metadata` and the offering-read both `.find` the offering (→ `404` if absent), and an enroll `404` would mean the destination class does not exist; all three are config/launch problems a student cannot fix by retrying, so tell-your-teacher is the semantically correct message. The mint and `send_class_teachers` do not emit `404` (they use `422`/`400`/`401`/`403`). Option B adds a per-call-site flag for a case that does not meaningfully differ. Matches the current draft; no code change.

### RESOLVED: `TRUSTED_PORTAL_HOSTS` value format and emulator config
**Context**: The draft reads a comma-separated hostname list from a single `defineString`. Need the concrete per-project values and the emulator/`.env` entry.
**Options considered**:
- A) Comma-separated single param (current draft): prod `"learn.concord.org"`, staging `"learn.portal.staging.concord.org"`, emulator via `.env.local`. Include `learn.staging.concord.org`/aliases if the study ever uses them.
- B) Reuse an existing portal-host config if one already exists per project rather than a new param.

**Decision**: **A, one host per environment (confirmed with Doug: these are the only two portal hosts; the old "ngss" host was retired, so no aliases).** Set `TRUSTED_PORTAL_HOSTS` per report-service project: prod (`report-service-pro`) → `"learn.concord.org"`; dev/staging (`report-service-dev`) → `"learn.portal.staging.concord.org"`; emulator `.env.local` → `"learn.portal.staging.concord.org,localhost,127.0.0.1"` (the staging host matches the Tier-1/2 probes; the loopback entries enable local full-stack dev per the carve-out decision below, and are listed only here, never in a deployed project). Kept as a single comma-separated `defineString` even though the deployed environments list exactly one host, so a future host can be added by config without a code change. Environments do not cross (a prod report-service is never launched from the staging portal or vice versa), so each deployed project allows only its own paired host, which is the tightest safe setting. The comma-split parser already tolerates a one- or multi-element list.

### RESOLVED: Fold the generic-bucket fallback per step, or unify to one message?
**Context**: The draft keeps each step's existing generic message as the generic-bucket fallback (step-specific), while reload/tell-teacher are shared. An alternative is one unified generic message across all steps.
**Options considered**:
- A) Per-step generic fallback (current draft): preserves "Unable to lock your pre-test..." etc.
- B) One shared generic message everywhere: fully coarse, loses step context.

**Decision**: **A (keep per-step generic fallback).** The step-specific constants already exist and only surface for the *generic* (retryable) bucket, where "which step failed" is useful context for the teacher the student then talks to; the coarse shared messages stay reserved for the expiry/config buckets. Collapsing to one string is strictly less informative at no real savings. Matches the current draft; no code change.

### RESOLVED: Support a localhost portal for local full-stack dev
**Context**: Not needed for this story (staging is already updated and the emulator points at it), but Doug foresees future work where staging cannot be updated and a locally-run portal (`http://localhost:PORT` rigse) must be exercised end-to-end. As first drafted, `validatePortalHost` would block that: it hard-required `https:`, and `localhost` was not allowlisted.
**Options considered**:
- A) No localhost support: local dev always points the emulator at the staging portal (matches the `fetch-activity.ts` authoring precedent, which has no localhost entry and requires https).
- B) Narrow, dev-only carve-out: permit `http:` for loopback hosts, emulator-gated, with loopback still required in `TRUSTED_PORTAL_HOSTS`.

**Decision**: **B, built now for future use.** `validatePortalHost` permits `http:` only when the hostname is loopback (`localhost` / `127.0.0.1` / `[::1]`) **and** `FUNCTIONS_EMULATOR === "true"`, and the hostname must still appear in `TRUSTED_PORTAL_HOSTS`. This is safe by construction on three independent counts, all of which must fail simultaneously to expose a deployed project: (1) deployed projects never list `localhost` in `TRUSTED_PORTAL_HOSTS`, so the allowlist rejects it regardless of protocol; (2) the `http:` relaxation is gated on `FUNCTIONS_EMULATOR`, so even a mis-configured deployed allowlist could not accept `http://localhost`; (3) over `https:` a deployed project would still reject `localhost` via the allowlist. So the exception can only ever matter on a developer's own machine running the emulator, where forwarding the token to their own loopback portal is the intended behavior and carries no exfiltration risk. Documented as a dev-only affordance; the loopback entries live solely in the emulator `.env.local` (see the `TRUSTED_PORTAL_HOSTS` decision).

## Self-Review

Multi-role review of the implementation spec. Every finding was verified against the actual report-service code before being recorded; the two test-breakage findings (1, 2) were proven empirically by applying the spec's Step 1 + Step 3 edits to the real source, running the existing suites, observing the failures, and reverting. Roles used: QA Engineer, DevOps Engineer, Cross-Repo Contract / Security Engineer, Senior Engineer. Educational-research and accessibility roles skipped (no learner-facing UI change).

### QA Engineer

#### RESOLVED: The new `platform_id` gate and required `tokenCache` field break every existing test in the suite, and the spec does not flag it
**Resolution**: Applied. Step 1's Tests bullet now spells out the `tokenCache` fixture fallout (the `makeContext` helpers must add `tokenCache: createPortalTokenCache()` or the suites fail to compile with `TS2741`), and Step 3's Tests bullet now adds a `beforeEach` setting `process.env.TRUSTED_PORTAL_HOSTS = "learn.concord.org"` in the pre-existing `index.test.ts` so its tests still exercise the happy path instead of bailing at the gate.

Empirically proven (applied the Step 1 + Step 3 edits to `types.ts`, `portal-api.ts`, `index.ts`, ran the suites, reverted):
- **`index.test.ts`: all 11 tests fail at runtime.** The gate calls `validatePortalHost(jobDoc.platform_id)`, which reads `defineString("TRUSTED_PORTAL_HOSTS").value()`. Verified (throwaway test) that an unset param resolves to `""` in jest, so the allowlist is empty and `https://learn.concord.org` (every fixture's `platform_id`) is rejected. The run bails at setup with `TELL_TEACHER_MESSAGE` before the mocked step handlers ever run, so every `stepResults`/completion-message assertion fails.
- **`lock-activity.test.ts`, `send-email.test.ts`, `random-assignment.test.ts`: the whole suite fails to compile.** `makeContext()` builds a `StepContext` literal with no `tokenCache`; making `tokenCache` a required field yields `TS2741: Property 'tokenCache' is missing` under ts-jest, so the file never runs.

Why it matters: Step 3 only says "with `TRUSTED_PORTAL_HOSTS` set to a known host" for the *new* rejection tests, and Step 1 does not mention the fixture fallout. As written, the plan lands a red suite. Suggested resolution: (a) Step 3 adds a `beforeEach` that sets `process.env.TRUSTED_PORTAL_HOSTS` (to `learn.concord.org`) in `index.test.ts` and anywhere else that drives `ai4vsFlvs`; (b) Step 1 explicitly calls out that every `StepContext` fixture (`makeContext` in the three step tests) must add `tokenCache: createPortalTokenCache()` (and `firebaseJwt` where the step now requires it) or the suites will not compile.

#### RESOLVED: Step 7's "oidc_mint called exactly twice" cache-dedup assertion is not achievable in `index.test.ts` as structured
**Resolution**: Applied (option a). The run-level cache-dedup assertion was moved to `portal-api.test.ts` (Step 1), where it needs only `getScopedPortalToken` + a mocked `fetch` (drive the origin key twice + a class key once against one cache; assert exactly two mints and the origin token reused). The final step was rewritten to state that `index.test.ts` has no `fetch` expectations to update (it mocks all handlers) and that a pipeline-level end-to-end dedup, if ever wanted, is a separate integration test, deliberately not taken on here.

Verified by reading `index.test.ts`: it `jest.mock()`s all four step handlers (`evaluate-completion`, `random-assignment`, `lock-activity`, `send-email`) and asserts only on `stepResults` accumulation and completion messages. It never exercises real `fetch`, the mint, or the cache. So Step 7's premise ("If `index.test.ts` asserts end-to-end on the pipeline's portal calls, update its `fetch` expectations") is false: there are no portal-call expectations to update. And the added "across one successful run, `oidc_mint` is called exactly twice ... origin token reused by lock and notify" assertion cannot run while the handlers are mocked out. Why it matters: the run-level dedup AC would ship unverified, or Step 7 silently balloons into un-mocking every handler and mocking `fetch` + Firestore + `GoogleAuth`. Suggested resolution: either (a) move the dedup assertion down to `portal-api.test.ts` at the cache level (call `getScopedPortalToken` twice on the origin key + once on a class key; assert exactly two `fetch`/mint calls and a reused token), or (b) add one dedicated integration-style test that runs the real handlers with mocked transport, and state that cost explicitly; and drop the false "update its `fetch` expectations" clause.

### DevOps Engineer

#### RESOLVED: The gate is fail-closed on an unset/empty `TRUSTED_PORTAL_HOSTS`, but that is not a listed deploy precondition
**Resolution**: Applied. Step 3 now names the concrete committed files (`functions/.env.report-service-pro` -> `learn.concord.org`; `functions/.env.report-service-dev` -> `learn.portal.staging.concord.org`; emulator `functions/.env.local` -> staging + loopback), states the fail-closed 100%-failure behavior, and directs the param into the Rollout-sequencing precondition list (requirements.md) with the `.env` edits riding in the gate's commit. requirements.md Rollout sequencing updated with the precondition bullet.

Verified: with the param unset, `validatePortalHost` rejects every host, so 100% of runs fail at setup. Params are set in the git-tracked `.env.report-service-dev` / `.env.report-service-pro` files (and the gitignored emulator `.env.local`); a deploy that forgets to add `TRUSTED_PORTAL_HOSTS` to the committed file for that project silently breaks every student's pipeline. The Open Question resolution names the per-project values, but Rollout sequencing (requirements.md) lists only RIGSE-352 + the client opt-in as hard preconditions, and the story adds no alerting ("watch the logs manually"). Why it matters: a fail-closed config with no alert is exactly the kind of omission a manual rollout misses until students hit it. Suggested resolution: add "`TRUSTED_PORTAL_HOSTS` present in the deployed env (`.env.<project>`)" to the Rollout sequencing precondition list, and have Step 3 name the concrete files so the config edit is part of the commit, not a separate memory step.

### Cross-Repo Contract / Security Engineer

#### RESOLVED: Per-class token caching means `minted_for` attributes notify's calls to the lock step, under-delivering per-step audit attribution
**Resolution**: Applied. The `description` is now derived from the token's identity (pilot + scope) rather than the calling step: `${pilot}:origin` | `${pilot}:class-${classId}`, computed inside `mintScopedPortalToken` from the cache key, so a cached origin token shared by lock + notify always carries an accurate `minted_for`. Call sites pass `pilot` instead of a per-step `description` string (removing the divergent-label footgun and shrinking Steps 4/5/6). Two mints per run still, so Step 7's "exactly twice" holds; requirements.md bullets 61/78 updated from "pipeline + step" to "pipeline + scope".

Verified from the proposed `getScopedPortalToken` + the pipeline order (`random-assignment` → `lock-activity` → `send-email`): the cache key is `(tokenType, classId)`, so `lock-activity` mints the origin token first with `description = "spring-2026/lock-activity"`, and `send-email` (also origin class) is a cache hit that reuses it. The notify step therefore issues its offering-read and `send_class_teachers` under a token whose `minted_for` claim (and the portal's single mint-log entry) says `lock-activity`, not `send-email`. Step 7's own "exactly twice" assertion confirms send-email produces no mint of its own. Why it matters: requirements.md's security bullet promises the `description`/`minted_for` "tie downstream calls to a specific step," which is only true per-class-token, not per-step, whenever two steps share a class (lock + notify in spring). Suggested resolution: reconcile the specs. Recommend (a): state that audit attribution is per-class-token granularity (lock and notify share one origin token and its `minted_for`), and soften the requirement wording accordingly. Option (b) (put the step in the cache key so notify mints its own origin token) restores per-step attribution but adds a third mint and contradicts Step 7 - not recommended.

### Senior Engineer

#### RESOLVED: The `platform_id` security control lives in the pipeline's `index.ts`, so each future portal-calling pipeline must remember to re-add it
**Resolution**: Applied. Step 3 now notes `validatePortalHost` is a pure, exported helper the REPORT-82 fall pipelines reuse directly, and that the setup gate (validate -> log -> `markComplete` -> return) is a required per-pipeline setup step recorded in the fall-pipeline handoff so a new pipeline cannot silently omit it. A shared `assertTrustedPortalHost` wrapper is deferred until the second consumer actually lands (rather than guessed at now), since it would couple `portal-api.ts` to `markComplete`.

Verified `executeTask` (`task-worker.ts`) is the shared router for all task handlers, and the gate is placed in `ai4vs-flvs/index.ts` (pipeline-specific). That is correct for this story (the `success`/`failure` test handlers have no `platform_id` and make no portal call, so the gate cannot simply move into `executeTask`). But requirements.md scopes this infra as the shared foundation the REPORT-82 fall pipelines consume, and a new portal-calling pipeline that forgets its own gate silently reintroduces the token-exfiltration surface the control exists to close. Why it matters: a security control that must be re-added by hand in each new pipeline is one omission away from a regression. Suggested resolution: extract the gate as a small exported helper (e.g. `assertTrustedPortalHost(jobDoc) -> {ok, host}`) in `portal-api.ts` and note in the spec that every portal-calling pipeline's setup must call it; add it to the "new pipeline" checklist referenced by the fall stories.

#### RESOLVED (minor, consistency): The classifier routes any 4xx to tell-your-teacher, which is broader than the requirements' "non-2xx → generic" catch-all wording
**Resolution**: Applied. requirements.md's error-handling prose was tightened so the coarse buckets read as "any non-expired 4xx -> tell-your-teacher; 2xx-non-success / 5xx / network -> generic," matching both `classifyPortalFailure` and the acceptance criterion.

`classifyPortalFailure` maps every non-expired 4xx to tell-your-teacher. requirements.md's error-handling bullet lists "Non-2xx / 5xx / network / other ... → generic" as the catch-all, while the acceptance criterion lists generic as "other / 5xx / network / enroll-2xx-non-success." For the realistic enroll/lock 4xx (403/404) tell-your-teacher is the intended and better message, and the AC wording is consistent with the classifier; only the looser prose bullet reads as if a bare non-2xx should be generic. Why it matters: minor doc inconsistency that could confuse an implementer or reviewer comparing the classifier to the prose. Suggested resolution: tighten the requirements prose to "any non-expired 4xx → tell-your-teacher; 2xx-non-success / 5xx / network → generic" so it matches the classifier and the AC, or add one sentence to the classifier summary noting it intentionally buckets all 4xx as config/authorization.

---

### Code-verified review pass (2026-07-28, implementation spec)

A fresh multi-role pass over the implementation spec, verifying every candidate against the actual report-service source before recording it, and settling the load-bearing runtime/type assumptions with throwaway tests run under the repo's real jest/ts-jest config (then deleted; tree left clean). Confirmed sound and not re-raised: `defineString(...).value()` returns `""` unset and reads `process.env` live at call time (so Step 3's `beforeEach` strategy and the fail-closed claim hold); ts-jest enforces type diagnostics (so the `tokenCache` `TS2741` break is real); the real `portal-api` module imports cleanly without a `google-auth-library` mock (so `index.test.ts` transitively loading it after Step 3 is fine).

#### RESOLVED: Step 6 (send-email) was missing the `firebaseJwt` narrowing guard that Step 5 (lock) includes (Senior Engineer)
**Resolution**: Applied. `MintTokenParams.firebaseToken` is `string` while `StepContext.firebaseJwt` is `string | undefined`; a throwaway confirmed this repo's ts-jest fails the file on that `string | undefined -> string` assignment (`TS2345`). Enroll already guards (`random-assignment.ts:302-305`) and lock adds the guard (Step 5), but Step 6's shown code went straight into `getScopedPortalToken({ firebaseToken: firebaseJwt, ... })` with no guard, so as written it would not compile. Step 6 now adds the same defensive guard before the mint and states once ("Every mint-calling step must narrow `firebaseJwt` first") that this narrowing is required in each mint-calling step, defensive of `index.ts`'s run-setup guarantee.

#### RESOLVED: The three step-test files mock `../portal-api` too narrowly to survive the cutover (QA Engineer)
**Resolution**: Applied. Verified `lock-activity.test.ts:6-9`, `send-email.test.ts:5-8`, and `random-assignment.test.ts:23-26` each do `jest.mock("../portal-api", () => ({ portalOidcFetch }))`, a full-module replacement. Once the cut-over steps import `getScopedPortalToken` / `portalTokenFetch` / `classifyPortalFailure` / `messageForBucket`, those exports become `undefined` under the narrow mock, so the mint call throws into each step's outer `catch` and the new reload / tell-teacher bucket assertions fail. The spec flagged the `tokenCache` `TS2741` compile break and the `index.test.ts` `beforeEach`, but not this mock restructuring. Step 1's Fixture-fallout block now has a "Mock fallout" note (mock the two minted-token entry points, keep the real classifier via `jest.requireActual`), and Steps 4/5/6's Tests bullets back-reference it.

#### RESOLVED (documented, not changed): `validatePortalHost` validates the host but call sites reuse the raw `platform_id` as the base URL, unlike the cited precedent (Security / Senior Engineer)
**Resolution**: Documented. Verified the precedent `resolveActivityUrl` (`chat/fetch-activity.ts:43-52`) rebuilds the URL from the trusted host + fixed path ("never the raw client string"), whereas `validatePortalHost` validates-only and the call sites keep `portalUrl: platform_id`. Confirmed this is **not** a token-exfiltration hole: the allowlist is an exact `hostname` match and `fetch` parses the same string with the same WHATWG URL semantics, so the token can only reach the allowlisted host (`...@evil.com` → `hostname evil.com` rejected; `...concord.org.evil.com` rejected). The only residual difference from the rebuild approach is that a port/path/query in `platform_id` survives into the concatenated URL (blast radius bounded to the trusted host: a wrong port/path there → a failed request, not exfiltration), and real LTI `platform_id`s are clean origins. Chose to document the intentional validate-only choice in Step 3 (with the canonicalize-to-`https://${hostname}` path noted for a future requirement) rather than add URL-rebuild churn across all four call sites and their tests, since it is unnecessary for the exfiltration property the gate guarantees.

### Applied-and-run verification pass (2026-07-28, cutover compiled end-to-end)

This pass went further than the earlier ones: rather than compiling only Step 1 + Step 3, it applied the **full** edit set (Steps 1-6: the `portal-api.ts` infra + classifier + gate, the `StepContext.tokenCache` field, the `index.ts` init + gate, and all three cut-over step handlers) to the real source, ran `npx tsc --noEmit` and the affected jest suites, then reverted the source tree (left clean; only the two spec files remain modified). Load-bearing assumptions were also re-settled with throwaway tests run under the repo's real jest/ts-jest and then deleted.

Confirmed sound and **not** re-raised: the Steps 4/5/6 cut-over code is type-sound (full apply compiles with **zero** source-tree type errors; the only `tsc` errors are the three predicted `TS2741` fixture breaks); `defineString(...).value()` live-reads `process.env` and returns `""` unset under firebase-functions v4 (so the `beforeEach` strategy and the fail-closed gate hold); `index.test.ts` fails all 11 tests at the gate with `TRUSTED_PORTAL_HOSTS` unset (so its `beforeEach` is mandatory); the classifier buckets and the `https://learn.concord.org@evil.com` → `hostname evil.com` rejection behave as specified. Three findings surfaced and were applied (below).

#### RESOLVED: Adding the `firebase-functions` import to `portal-api.ts` makes `portal-api.test.ts` fail to run (0 tests) (QA / test-infra)
**Resolution**: Applied. Empirically reproduced: today `portal-api.ts` imports only `google-auth-library`, so `portal-api.test.ts` imports the real module and never mocks `firebase-functions`. Step 1 adds `import * as functions from "firebase-functions"` (the mint's `functions.logger.error`), so the test now transitively loads the real SDK, which fails under jest with `Cannot find module 'firebase-admin/auth' from 'identity.js'` and the whole suite errors at load (`Tests: 0 total`), distinct from the `TS2741` compile break. Every other step-test file already `jest.mock("firebase-functions", …)`, which is why they dodge it; the earlier "Code-verified" note only checked the `google-auth-library` angle for `index.test.ts` (a file that already mocks firebase-functions), so this gap was real. Proved the fix by adding the full-module logger mock and re-running: the module loads and the classifier / `validatePortalHost` cases pass. Step 1's Files-affected list and a new "firebase-functions-mock fallout" block now require `portal-api.test.ts` to add `jest.mock("firebase-functions", () => ({ logger: { info, error, warn } }))`, and note the mock is doubly required for the never-log spy.

#### RESOLVED: `portal-api.test.ts` mixes env-reading and env-setting blocks with no isolation (QA / test-hygiene)
**Resolution**: Applied. The file will host both the mint tests (real `portalOidcFetch` **reads** `process.env.FUNCTIONS_EMULATOR`, throwing if `"true"` with no `PORTAL_OIDC_TOKEN`) and the new `validatePortalHost` loopback tests (which **set** `FUNCTIONS_EMULATOR="true"` + `TRUSTED_PORTAL_HOSTS`), so without per-block save/restore a loopback test can leak the emulator flag into a later mint test (order-dependent failure). Step 1 now carries a "Test env isolation" note pointing at the existing `describe("portalOidcFetch")` block as the model (`originalEnv` capture, `process.env = { ...originalEnv }` + `delete FUNCTIONS_EMULATOR` in `beforeEach`, restore in `afterAll`).

#### RESOLVED (consistency): Step 1's Files-affected list omitted the three step-test fixtures it must patch in the same commit (QA)
**Resolution**: Applied. Reproduced that making `tokenCache` required yields one `TS2741` per step-test file at compile time, so those three fixture edits must land in the Step 1 commit to keep the suite green; Step 1's Files-affected list now includes them. Also corrected a factual detail: `random-assignment.test.ts` builds its failing `StepContext` **inline** (near the end of the file), not via a `makeContext` helper like the other two, so the Fixture-fallout wording no longer implies all three use `makeContext`.

### Security-only narrow pass (2026-07-28) — no new findings

A single-dimension Security Engineer pass over the implementation spec, each property checked against the real source and the one load-bearing control exercised with an adversarial throwaway (run, then deleted; tree left clean). **No new defects surfaced.** Recorded here as a verification log:

- **Exfiltration gate is complete.** Grepped every `portalUrl` in all three step handlers: each is `jobDoc.platform_id` (the exact field the gate validates); there is no second host field. `platform_id` is otherwise used only as a Firestore query value and a hash input (`random-assignment.ts:227,331`), never as a network host. `submit-task.ts` whitelists `platform_id` as a context **key** but never validates its **value** (confirmed `ALLOWED_CONTEXT_KEYS` copies it verbatim), so the run-setup gate is the sole value check, and it precedes the loop where every portal call (and the only forwarding of the Firebase token, via the mint) lives. Firestore reads sign into Google, not `platform_id`.
- **`validatePortalHost` withstands an adversarial battery** (all rejected): userinfo/credential embedding (`…concord.org@evil.com`, `user:…@evil.com`), suffix/prefix/substring lookalikes (`…concord.org.evil.com`, `evil-learn.concord.org`, trailing-dot FQDN), non-https / non-URL / wrong-type inputs, IDN/unicode homograph (Cyrillic `е` → punycode ≠ allowlist), and `localhost` in a deployed project (rejected regardless of scheme because the deployed allowlist omits it). The emulator carve-out is confirmed triple-gated: `http://localhost` passes **only** with `FUNCTIONS_EMULATOR=true` AND `localhost` listed; dropping either rejects. The documented residual (a port/path/query on the trusted host survives into the concatenated URL) reproduced exactly and stays bounded to the trusted host.
- **Never-log holds at every site in the proposed code.** The mint logs `{ status, reason }` only and never its `201 { token }` body; `getScopedPortalToken` logs nothing; enroll/lock/send failure logs carry `{ status, data }` whose failure bodies hold no token; the offering-read logs `status` only; the gate logs `host` only (never the full `platform_id`, never the JWT); the outer `catch` blocks log network errors, which under undici do not embed request headers/body, so neither the forwarded Firebase token (mint request body) nor the minted token leaks.
- **Wrong-recipient email is fail-safe.** A divergence between the token's origin class and the `resource_link_id`-resolved `class_id` yields a portal `class_teacher?` denial (`403` → tell-your-teacher), never an email to the wrong class — the safety rests on the portal's authorization, not on report-service trusting its own resolution (already captured as the notify origin-class invariant).

Pre-existing, out-of-scope observation (not a finding for this story): `resource_link_id` is interpolated into portal request paths without encoding (pre-existing in lock; the offering-read adds a second identical use). It is bounded to the trusted host post-gate and carries the same trust report-service already places in `resource_link_id` today, so it is unchanged by this story; any hardening belongs to a separate input-validation effort, not here.

<!-- Phase 3 Step 2: process each issue one at a time with the user, mark OPEN -> RESOLVED. Re-run the pass after changes. -->
<!-- Verification artifacts (throwaway tests + the applied-and-reverted edit run) are described inline; source tree was left clean. -->

