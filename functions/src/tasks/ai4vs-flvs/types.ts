import { IJobDocument } from "../types";
import { PortalTokenCache } from "../portal-api";

/**
 * Machine-readable handoff between pipeline steps. Unlike `summary`/`message`, which
 * send-email renders into the teacher-notification email body, `output` is never rendered
 * into any human-facing sink, so it is the only safe carrier for values a later step
 * consumes (e.g. a resolved destination class word).
 */
export interface StepOutput {
  /** Class word the enroll step should resolve and enroll into. */
  destinationClassWord?: string;
}

export type StepResult = {
  success: boolean;
  message?: string;
  summary?: string;
  output?: StepOutput;
};

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
