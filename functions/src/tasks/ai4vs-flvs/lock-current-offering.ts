import * as functions from "firebase-functions";
import { StepContext, StepResult } from "./types";
import { messageForBucket } from "../portal-api";
import { applyOfferingState } from "./offering-state";

/**
 * ⚠️ A FAILED LOCK IS A DATA PROBLEM, not just a bad experience. The researcher tracks completion
 * from the portal's teacher progress roster, whose per-student locked checkbox IS the completion
 * record, and her manual opening of the next sequence is gated on it, so a student whose lock
 * failed reads as "not finished" and is passed over.
 */
const STUDENT_FAILURE_MESSAGE =
  "Unable to record that you finished this activity. Please try again or contact your teacher.";

/**
 * Lock the offering this run launched from, behind the student who just finished it.
 *
 * Serves the spring pilot and all three fall stages, so the message does not name the pre-test. It
 * names what failed rather than saying "unable to finish this activity", which was vague about
 * whether the student's answers had been lost; answers are saved continuously by the activity
 * player and are never at risk from this step.
 *
 * Makes no host check of its own, and issues exactly one write with no retry, so a failure leaves
 * portal state untouched by anything this step did after it.
 */
export const lockCurrentOffering = async (context: StepContext): Promise<StepResult> => {
  const { jobPath, jobDoc, firebaseJwt } = context;
  const { platform_id, platform_user_id, resource_link_id } = jobDoc;

  if (!platform_id || !platform_user_id || !resource_link_id) {
    const missing = [
      !platform_id && "platform_id",
      !platform_user_id && "platform_user_id",
      !resource_link_id && "resource_link_id",
    ].filter(Boolean).join(", ");
    functions.logger.error(`lock-current-offering: missing required context fields: ${missing} for ${jobPath}`);
    return { success: false, message: STUDENT_FAILURE_MESSAGE };
  }

  if (!firebaseJwt) {
    functions.logger.error(`lock-current-offering: missing Firebase JWT for ${jobPath}`);
    return { success: false, message: STUDENT_FAILURE_MESSAGE };
  }

  functions.logger.info(
    `lock-current-offering: locking offering ${resource_link_id} for user ${platform_user_id} at ${platform_id} (${jobPath})`
  );

  try {
    const outcome = await applyOfferingState(context, {
      offeringId: resource_link_id,
      locked: true,
      // Nothing in the study hides at class level, and reading the student's current value would
      // cost an extra GET on a path that otherwise makes no read at all.
      active: true,
    });

    if (!outcome.ok) {
      if (outcome.status !== undefined) {
        functions.logger.error(
          `lock-current-offering: Portal returned ${outcome.status} for ${jobPath}`,
          { status: outcome.status, data: outcome.data }
        );
      }
      return { success: false, message: messageForBucket(outcome.bucket, STUDENT_FAILURE_MESSAGE) };
    }

    // Lets "was this student actually locked?" be answered from our logs rather than only from the
    // portal roster.
    functions.logger.info(
      `lock-current-offering: successfully locked offering ${resource_link_id} for user ${platform_user_id} ` +
      `(portal returned active=${outcome.returned?.active} locked=${outcome.returned?.locked}) (${jobPath})`
    );
    // No summary: this step never reads the class, so it holds the offering id and not its name,
    // and send-email already prints the id in its header.
    return { success: true };
  } catch (error) {
    functions.logger.error(`lock-current-offering: request failed for ${jobPath}`, error);
    return { success: false, message: STUDENT_FAILURE_MESSAGE };
  }
};
