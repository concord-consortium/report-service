import * as functions from "firebase-functions";
import { StepContext, StepResult } from "./types";

export const sendEmail = async ({ jobPath }: StepContext): Promise<StepResult> => {
  functions.logger.info(`ai4vs-flvs: send-email stub called for ${jobPath}`);
  return { success: true, message: "send-email stub: success" };
};
