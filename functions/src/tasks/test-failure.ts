import { IJobDocument } from "./types";
import { markComplete, setProcessingMessage } from "./task-helpers";

const DEFAULT_PROCESSING_MESSAGE = "Checking your answers…";
const DEFAULT_MESSAGE = "Sorry, you haven't finished answering all the questions. Go back and check your answers. Then return here and click this button again.";
const DELAY_MS = 2000;

export const testFailure = async (jobPath: string, jobDoc: IJobDocument): Promise<void> => {
  const { request } = jobDoc.jobInfo;
  const processingMessage = request.processingMessage ?? DEFAULT_PROCESSING_MESSAGE;
  const message = request.message ?? DEFAULT_MESSAGE;

  await setProcessingMessage(jobPath, processingMessage);
  await new Promise(resolve => setTimeout(resolve, DELAY_MS));
  await markComplete(jobPath, "failure", { message });
};
