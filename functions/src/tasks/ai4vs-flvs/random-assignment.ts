import * as functions from "firebase-functions";
import { IJobDocument } from "../types";
import { StepResult } from "./types";

export const randomAssignment = async (jobPath: string, _jobDoc: IJobDocument): Promise<StepResult> => {
  functions.logger.info(`ai4vs-flvs: random-assignment stub called for ${jobPath}`);
  return { success: true, message: "random-assignment stub: success" };
};
