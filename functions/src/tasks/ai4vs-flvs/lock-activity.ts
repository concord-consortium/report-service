import * as functions from "firebase-functions";
import { IJobDocument } from "../types";
import { StepResult } from "./types";

export const lockActivity = async (jobPath: string, _jobDoc: IJobDocument): Promise<StepResult> => {
  functions.logger.info(`ai4vs-flvs: lock-activity stub called for ${jobPath}`);
  return { success: true, message: "lock-activity stub: success" };
};
