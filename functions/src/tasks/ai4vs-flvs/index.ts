import * as functions from "firebase-functions";
import { IJobDocument } from "../types";
import { markComplete, setProcessingMessage } from "../task-helpers";
import { StepContext, StepHandler } from "./types";
import { createPortalTokenCache, validatePortalHost, TELL_TEACHER_MESSAGE } from "../portal-api";
import { evaluateCompletion } from "./evaluate-completion";
import { lockCurrentOffering } from "./lock-current-offering";
import { randomAssignment } from "./random-assignment";
import { sendEmail } from "./send-email";

interface PipelineStep {
  name: string;
  processingMessage: string;
  handler: StepHandler;
}

/**
 * \u26a0\ufe0f Entry `name` values must be UNIQUE WITHIN a pipeline. The loop below is the single writer of
 * `stepResults[step.name]`, so two entries sharing a name silently lose the first result, and
 * send-email prints one line per key, so the teacher's notification quietly loses a line too. Nothing
 * enforces this at run time and a harness run would not catch it: the pipeline completes, the student
 * sees success, and only the email is short. A test in index.test.ts asserts it across every entry
 * here, which is why this table is exported.
 *
 * The hazard arrives with any stage that reaches one shared core through several named steps, as
 * offering-state.ts is reached by both lock-current-offering and open-target-offering.
 */
export const PIPELINES: Record<string, PipelineStep[]> = {
  "spring-2026": [
    { name: "evaluate-completion", processingMessage: "Checking your answers\u2026", handler: evaluateCompletion },
    { name: "random-assignment", processingMessage: "Assigning you to a class\u2026", handler: randomAssignment },
    // The ENTRY name stays "lock-activity" although the module and handler were renamed to
    // lock-current-offering. It is deliberate and not a leftover: send-email prints one line per
    // stepResults key, so renaming it changes the wording of a live pilot's teacher email, and the
    // processingMessage beside it is a string spring students actually see.
    { name: "lock-activity", processingMessage: "Locking your pre-test\u2026", handler: lockCurrentOffering },
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

  // Reject an untrusted or non-https platform_id before forwarding any token or attempting a mint.
  const hostCheck = validatePortalHost(jobDoc.platform_id);
  if (!hostCheck.ok) {
    functions.logger.error(`ai4vs-flvs: rejected untrusted platform_id for ${jobPath}`, { host: hostCheck.host });
    await markComplete(jobPath, "failure", { message: TELL_TEACHER_MESSAGE });
    return;
  }

  // Execute pipeline steps in order. hostCheck.origin is set whenever hostCheck.ok is true.
  const stepContext: StepContext = {
    jobPath,
    jobDoc,
    firebaseJwt,
    stepResults: {},
    tokenCache: createPortalTokenCache(),
    portalOrigin: hostCheck.origin!,
  };
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
