import * as functions from "firebase-functions";
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
  functions.logger.error("portal mint failed", { status: response.status, reason });
  return { ok: false, status: response.status, reason };
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
