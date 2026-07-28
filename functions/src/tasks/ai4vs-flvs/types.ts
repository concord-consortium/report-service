import { IJobDocument } from "../types";
import { PortalTokenCache } from "../portal-api";

export type StepResult = { success: boolean; message?: string; summary?: string };

export interface StepContext {
  jobPath: string;
  jobDoc: IJobDocument;
  firebaseJwt?: string;
  stepResults: Record<string, StepResult>;
  tokenCache: PortalTokenCache;
}

export type StepHandler = (context: StepContext) => Promise<StepResult>;
