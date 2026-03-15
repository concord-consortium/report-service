import * as functions from "firebase-functions";
import { IJobDocument } from "../types";
import { markComplete, setProcessingMessage } from "../task-helpers";
import { StepHandler } from "./types";
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
    { name: "lock-activity", processingMessage: "Locking your pre-test\u2026", handler: lockActivity },
    { name: "random-assignment", processingMessage: "Assigning you to a class\u2026", handler: randomAssignment },
    { name: "send-email", processingMessage: "Notifying your teacher\u2026", handler: sendEmail },
  ],
};

export const ai4vsFlvs = async (jobPath: string, jobDoc: IJobDocument): Promise<void> => {
  const { request } = jobDoc.jobInfo;

  // Validate required pilot parameter
  if (!request.pilot) {
    await markComplete(jobPath, "failure", {
      message: "Missing required field: request.pilot",
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
  for (const step of pipeline) {
    await setProcessingMessage(jobPath, step.processingMessage);

    const result = await step.handler(jobPath, jobDoc);
    if (!result.success) {
      await markComplete(jobPath, "failure", {
        message: result.message ?? `Step "${step.name}" failed`,
      });
      return;
    }

    functions.logger.info(`ai4vs-flvs: step "${step.name}" completed successfully for ${jobPath}`);
  }

  await markComplete(jobPath, "success", {
    message: "Task completed (stub mode \u2014 no real actions performed).",
  });
};
