import { IJobDocument } from "../types";
import { PortalTokenCache } from "../portal-api";

export type StepResult = { success: boolean; message?: string; summary?: string };

export interface StepContext {
  jobPath: string;
  jobDoc: IJobDocument;
  firebaseJwt?: string;
  stepResults: Record<string, StepResult>;
  tokenCache: PortalTokenCache;
  /**
   * The validated, normalized portal base URL (origin) from validatePortalHost. Steps use this for
   * outbound portal HTTP calls instead of the raw jobDoc.platform_id, which is kept only as an identity value.
   */
  portalOrigin: string;
}

export type StepHandler = (context: StepContext) => Promise<StepResult>;
