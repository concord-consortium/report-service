import { IJobDocument } from "../types";

export type StepResult = { success: boolean; message?: string; summary?: string };

export interface StepContext {
  jobPath: string;
  jobDoc: IJobDocument;
  firebaseJwt?: string;
  stepResults: Record<string, StepResult>;
}

export type StepHandler = (context: StepContext) => Promise<StepResult>;
