import * as functions from "firebase-functions";
import { IJobDocument } from "../types";
import { markComplete, setProcessingMessage } from "../task-helpers";
import { StepContext, StepHandler } from "./types";
import { createPortalTokenCache, validatePortalHost, TELL_TEACHER_MESSAGE } from "../portal-api";
import { evaluateCompletion } from "./evaluate-completion";
import { lockCurrentOffering } from "./lock-current-offering";
import { randomAssignment } from "./random-assignment";
import { sendEmail } from "./send-email";
import { resolveOriginClass } from "./resolve-origin-class";
import { fallRandomAssignment } from "./fall-random-assignment";
import { enrollSpecifiedClass } from "./enroll-specified-class";
import { openTargetOffering } from "./open-target-offering";

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
  // The fall-2026 study's three "I'm Done" trigger points. The colour is the study's and the
  // portal's vocabulary (the sequences are named Green/Blue/Orange Sequence for AI in Math), but it
  // is not self-describing: green = pre-test, blue = curriculum, orange = post-test.
  //
  // BOTH cohorts run these same three stages. The only program-dependent behaviour in the study is
  // inside fall-random-assignment, which resolves the program from the origin class word itself, so
  // this table stays keyed by stage and never by program. A pilot value such as "fall-2026-fulltime"
  // is forbidden: one shared Green button serves both cohorts.
  "fall-2026-green": [
    { name: "evaluate-completion", processingMessage: "Checking your answers\u2026", handler: evaluateCompletion },
    { name: "resolve-origin-class", processingMessage: "Looking up your class\u2026", handler: resolveOriginClass },
    { name: "random-assignment", processingMessage: "Assigning you to a class\u2026", handler: fallRandomAssignment },
    { name: "enroll-class", processingMessage: "Adding you to your class\u2026", handler: enrollSpecifiedClass },
    // Lock AFTER the enrol, so a failed enrolment leaves the student unlocked and able to re-click.
    { name: "lock-pre-test", processingMessage: "Locking your pre-test\u2026", handler: lockCurrentOffering },
    { name: "send-email", processingMessage: "Notifying your teacher\u2026", handler: sendEmail },
  ],
  // Opens NOTHING. The PI opens the post-test by hand on a fixed date, gated on Blue completion
  // data she inspects herself. The lock IS the completion record she reads off the roster, so this
  // stage's whole job is to record and report, and it applies to both arms.
  "fall-2026-blue": [
    { name: "lock-curriculum", processingMessage: "Locking this activity\u2026", handler: lockCurrentOffering },
    { name: "send-email", processingMessage: "Notifying your teacher\u2026", handler: sendEmail },
  ],
  // \u26a0\ufe0f The lock PRECEDES the open, and that order is load-bearing rather than incidental:
  // open-target-offering's "Your work has been saved" copy is guaranteed true only while a failed
  // lock aborts before the open runs. Reordering these two requires that message to be revisited in
  // the same change.
  "fall-2026-orange": [
    { name: "resolve-origin-class", processingMessage: "Looking up your class\u2026", handler: resolveOriginClass },
    { name: "lock-post-test", processingMessage: "Locking your post-test\u2026", handler: lockCurrentOffering },
    // "Checking" rather than "Opening": roughly half the cohort is treatment and the step returns
    // immediately for every one of them without a portal call, so "opening" would promise something
    // that does not happen. True on both arms.
    { name: "open-curriculum", processingMessage: "Checking for your other activity\u2026", handler: openTargetOffering },
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

  // Three stages now run over the SAME step modules, so a step-name log prefix no longer identifies
  // the run. The only ai4vs-flvs line in the loop is the success line, so without these a stage that
  // fails at its first entry emits nothing naming the stage, and recovering it means joining the log
  // back to the job document through jobPath. Neither line carries a token or any student PII: the
  // pilot is an authored string and the step name is ours.
  functions.logger.info(`ai4vs-flvs: running pilot ${request.pilot} for ${jobPath}`);

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
      // ⚠️ warn rather than error for a step that declares its failure expected (see StepResult.expected).
      // A student who clicks before answering enough questions is not an operational fault, and it is by
      // far the most frequent way a run stops; logging it at error level would make error volume on all
      // four pilots a count of ordinary student behaviour.
      const failureLine = `ai4vs-flvs: pilot ${request.pilot} failed at step "${step.name}" for ${jobPath}`;
      if (result.expected) {
        functions.logger.warn(failureLine);
      } else {
        functions.logger.error(failureLine);
      }
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
