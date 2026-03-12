import { IJobDocument } from "./types";
import { markComplete, setProcessingMessage } from "./task-helpers";

const DEFAULT_PROCESSING_MESSAGE = "Submitting your work…";
const DEFAULT_MESSAGE = "Great! Your teacher will be notified that you have submitted your work.";
const DELAY_MS = 2000;

export const testSuccess = async (jobPath: string, jobDoc: IJobDocument): Promise<void> => {
  const { request } = jobDoc.jobInfo;
  const processingMessage = request.processingMessage ?? DEFAULT_PROCESSING_MESSAGE;
  const message = request.message ?? DEFAULT_MESSAGE;

  await setProcessingMessage(jobPath, processingMessage);
  await new Promise(resolve => setTimeout(resolve, DELAY_MS));
  await markComplete(jobPath, "success", { message });
};
