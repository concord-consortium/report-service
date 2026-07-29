import * as functions from "firebase-functions";
import { defineString } from "firebase-functions/params";
import { GoogleAuth } from "google-auth-library";

export interface PortalRequestOptions {
  /** Portal base URL, used as both the host and OIDC audience (e.g., "https://learn.concord.org") */
  portalUrl: string;
  /** Request path (e.g., "/api/v1/offerings/123/update_student_metadata") */
  path: string;
  /** HTTP method */
  method: "GET" | "POST" | "PUT" | "PATCH" | "DELETE";
  /** Request body — will be sent as-is. Caller is responsible for encoding. */
  body?: string;
  /** Additional headers (Content-Type, etc.) */
  headers?: Record<string, string>;
}

export interface PortalResponse {
  status: number;
  data: any;
}

const auth = new GoogleAuth();

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

/**
 * Make an OIDC-authenticated request to the Portal.
 *
 * In production: uses GoogleAuth to obtain an ID token with the portal URL as audience.
 * In the emulator: uses the PORTAL_OIDC_TOKEN environment variable.
 */
export const portalOidcFetch = async (options: PortalRequestOptions): Promise<PortalResponse> => {
  const { portalUrl, path, method, body, headers: extraHeaders } = options;
  const url = `${portalUrl}${path}`;

  let authHeader: string;

  if (process.env.FUNCTIONS_EMULATOR === "true") {
    const token = process.env.PORTAL_OIDC_TOKEN;
    if (!token) {
      throw new Error(
        "PORTAL_OIDC_TOKEN environment variable is required when running in the emulator. " +
        "Generate one with: gcloud auth print-identity-token " +
        "--impersonate-service-account=<service-account> --audiences=<portal-url>"
      );
    }
    authHeader = `Bearer ${token}`;
  } else {
    const client = await auth.getIdTokenClient(portalUrl);
    const tokenResponse = await client.getRequestHeaders();
    authHeader = tokenResponse.Authorization;
  }

  const headers: Record<string, string> = {
    ...(extraHeaders ?? {}),
    Authorization: authHeader,
  };

  return performPortalRequest(url, method, headers, body);
};

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

export type TokenType = "teacher";

/** Per-run cache. Key: `${tokenType}:${classId ?? "origin"}`. Created per run, never persisted. */
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
  /** Pipeline name (the pilot). The audit description is derived from the token's scope, not the calling step. */
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
    return { ok: true, token: response.data.token, status: response.status };
  }

  const reason = typeof response.data?.details?.reason === "string" ? response.data.details.reason : undefined;
  // `description` identifies which mint (origin vs class-scoped) failed without threading jobPath through.
  functions.logger.error("portal mint failed", { status: response.status, reason, description });
  return { ok: false, status: response.status, reason };
};

export enum PortalFailureBucket {
  Reload = "reload",
  TellTeacher = "tell_teacher",
  Generic = "generic",
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
 * Any other 4xx is a client/config/authorization error retry cannot fix and maps to tell-your-teacher.
 * Everything else (2xx-non-success, 5xx, network/throw with status 0) is generic-retryable.
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

export interface GetTokenParams extends MintTokenParams {
  cache: PortalTokenCache;
}

/**
 * Return a cached scoped token for (tokenType, classId) or mint one on a miss and cache it.
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

const trustedPortalHosts = defineString("TRUSTED_PORTAL_HOSTS");
// Hostnames arrive lowercase from url.hostname, so lowercase the configured allowlist too.
const parseTrustedHosts = (): string[] =>
  trustedPortalHosts.value().split(",").map(h => h.trim().toLowerCase()).filter(Boolean);

export interface PortalHostValidation {
  ok: boolean;
  /** The host (with port when present), for logging only. Never contains a token. */
  host?: string;
  /** The normalized origin to use verbatim as the portal base URL. Set only when ok. */
  origin?: string;
}

const LOOPBACK_HOSTS = new Set(["localhost", "127.0.0.1", "[::1]"]);
const isEmulator = (): boolean => process.env.FUNCTIONS_EMULATOR === "true";

/**
 * Validate a client-supplied platform_id as a trusted portal base URL and normalize it to a bare origin.
 *
 * Requirements: parses as a URL; is https (or http on a loopback host under the emulator); carries no
 * userinfo, path, query, or fragment beyond a bare origin (a lone trailing slash is allowed); carries no
 * explicit port under https (a port is permitted only for the emulator loopback case); and its hostname is
 * listed in TRUSTED_PORTAL_HOSTS.
 *
 * Returns `url.origin` (scheme + host [+ port], no trailing slash) so callers use a clean base URL rather
 * than joining a raw platform_id onto an API path. That guards against a trailing-slash platform_id
 * ("https://host/" -> "https://host//api/...") or a query-carrying one ("https://host?x=1") producing a
 * broken URL. `platform_id` is still used verbatim as an identity value elsewhere (assignment doc IDs,
 * answer queries), so this rejects rather than silently normalizes, keeping the HTTP and identity views
 * of platform_id from diverging.
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
  // A port is allowed only for the emulator loopback case; a deployed https portal must use the default port.
  if (url.port && !httpLoopbackOk) {
    return { ok: false, host: url.host };
  }
  // Reject embedded userinfo: a bare origin has no username/password, and while url.origin already strips it,
  // "https://user:pass@learn.concord.org" is not a bare origin and never a real LTI platform_id.
  if (url.username || url.password) {
    return { ok: false, host: url.host };
  }
  // Require a bare origin: reject any path, query, or fragment (a lone trailing slash parses to pathname "/").
  if (url.pathname !== "/" || url.search || url.hash) {
    return { ok: false, host: url.host };
  }
  if (!parseTrustedHosts().includes(url.hostname)) {
    return { ok: false, host: url.host };
  }
  return { ok: true, host: url.host, origin: url.origin };
};
