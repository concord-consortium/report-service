import * as functions from "firebase-functions";
import { StepContext, StepResult } from "./types";

export const randomAssignment = async ({ jobPath }: StepContext): Promise<StepResult> => {
  functions.logger.info(`ai4vs-flvs: random-assignment stub called for ${jobPath}`);
  return { success: true, message: "random-assignment stub: success" };
};
