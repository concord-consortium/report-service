import * as functions from "firebase-functions";
import { IJobDocument } from "../types";
import { markComplete, setProcessingMessage } from "../task-helpers";
import { StepContext, StepHandler } from "./types";
import { evaluateCompletion } from "./evaluate-completion";
import { lockActivity } from "./lock-activity";
import { randomAssignment } from "./random-assignment";
import { sendEmail } from "./send-email";

interface PipelineStep {
  name: string;
  processingMessage: string;
  handler: StepHandler;
}

const PIPELINES: Record<string, PipelineStep[]> = {
  "spring-2026": [
    { name: "evaluate-completion", processingMessage: "Checking your answers\u2026", handler: evaluateCompletion },
    { name: "random-assignment", processingMessage: "Assigning you to a class\u2026", handler: randomAssignment },
    { name: "lock-activity", processingMessage: "Locking your pre-test\u2026", handler: lockActivity },
    { name: "send-email", processingMessage: "Notifying your teacher\u2026", handler: sendEmail },
  ],
};

export const ai4vsFlvs = async (jobPath: string, jobDoc: IJobDocument, firebaseJwt?: string): Promise<void> => {
  const { request } = jobDoc.jobInfo;

  // Validate required pilot parameter
  if (!request.pilot) {
    await markComplete(jobPath, "failure", {
      message: "Missing required field: request.pilot",
    });
    return;
  }

  // Validate JWT is present — this task requires an authenticated user (R7)
  if (!firebaseJwt) {
    await markComplete(jobPath, "failure", {
      message: "Missing Firebase JWT — authenticated user required for this task",
    });
    return;
  }

  const pipeline = PIPELINES[request.pilot];
  if (!pipeline) {
    await markComplete(jobPath, "failure", {
      message: `Unknown pilot: ${request.pilot}`,
    });
    return;
  }

  // Execute pipeline steps in order
  const stepContext: StepContext = { jobPath, jobDoc, firebaseJwt, stepResults: {} };
  for (const step of pipeline) {
    await setProcessingMessage(jobPath, step.processingMessage);

    const result = await step.handler(stepContext);
    if (!result.success) {
      await markComplete(jobPath, "failure", {
        message: result.message ?? `Step "${step.name}" failed`,
      });
      return;
    }

    stepContext.stepResults[step.name] = result;
    functions.logger.info(`ai4vs-flvs: step "${step.name}" completed successfully for ${jobPath}`);
  }

  const DEFAULT_COMPLETION_MESSAGE = "Done! Your teacher has been notified.";
  const customMessage = request.completion_message;
  const trimmed = typeof customMessage === "string" ? customMessage.trim() : "";
  const completionMessage = trimmed || DEFAULT_COMPLETION_MESSAGE;

  await markComplete(jobPath, "success", {
    message: completionMessage,
  });
};
