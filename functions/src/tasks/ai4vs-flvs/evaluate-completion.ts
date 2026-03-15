import * as functions from "firebase-functions";
import { IJobDocument } from "../types";
import { StepResult } from "./types";

export const evaluateCompletion = async (jobPath: string, _jobDoc: IJobDocument): Promise<StepResult> => {
  functions.logger.info(`ai4vs-flvs: evaluate-completion stub called for ${jobPath}`);
  return { success: true, message: "evaluate-completion stub: success" };
};
