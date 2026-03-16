import { IJobDocument } from "../types";

export type StepResult = { success: boolean; message?: string };

export interface StepContext {
  jobPath: string;
  jobDoc: IJobDocument;
  firebaseJwt?: string;
}

export type StepHandler = (context: StepContext) => Promise<StepResult>;
