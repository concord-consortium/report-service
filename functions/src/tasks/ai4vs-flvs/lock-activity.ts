import * as functions from "firebase-functions";
import { StepContext, StepResult } from "./types";

export const lockActivity = async ({ jobPath }: StepContext): Promise<StepResult> => {
  functions.logger.info(`ai4vs-flvs: lock-activity stub called for ${jobPath}`);
  return { success: true, message: "lock-activity stub: success" };
};
