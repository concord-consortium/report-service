import * as functions from "firebase-functions";
import { IJobDocument } from "../types";
import { StepResult } from "./types";

export const sendEmail = async (jobPath: string, _jobDoc: IJobDocument): Promise<StepResult> => {
  functions.logger.info(`ai4vs-flvs: send-email stub called for ${jobPath}`);
  return { success: true, message: "send-email stub: success" };
};
