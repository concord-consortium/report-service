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

  const response = await fetch(url, {
    method,
    headers,
    body,
  });

  const data = await response.json().catch(() => null);

  return { status: response.status, data };
};
