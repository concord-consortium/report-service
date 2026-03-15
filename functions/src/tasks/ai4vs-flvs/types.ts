import { IJobDocument } from "../types";

export type StepResult = { success: boolean; message?: string };
export type StepHandler = (jobPath: string, jobDoc: IJobDocument) => Promise<StepResult>;
