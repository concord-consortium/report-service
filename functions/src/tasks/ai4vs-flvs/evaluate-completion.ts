import * as functions from "firebase-functions";
import { collection, query, where, getDocs } from "firebase/firestore";
import { StepContext, StepResult } from "./types";
import { getClientFirestore } from "../../firebase-client";
import { answerIsCompleted } from "../answer-utils";

// Not TELL_TEACHER_MESSAGE: "setting up your class" is wrong for a misauthored button parameter.
export const CHECK_FAILED_MESSAGE =
  "Something went wrong checking your answers. Please tell your teacher.";

export const evaluateCompletion = async ({
  jobPath,
  jobDoc,
  firebaseJwt,
}: StepContext): Promise<StepResult> => {
  if (!firebaseJwt) {
    return { success: false, message: "missing Firebase JWT" };
  }

  const { source_key, platform_user_id, platform_id, resource_link_id, context_id } = jobDoc;

  if (!source_key || !platform_user_id || !platform_id || !resource_link_id || !context_id) {
    return {
      success: false,
      message: "missing required context fields (source_key, platform_user_id, platform_id, resource_link_id, context_id)",
    };
  }

  // Validate min_completed_questions before establishing Firestore connection
  const { request } = jobDoc.jobInfo;
  const rawMinCompleted = request.min_completed_questions;
  const minCompleted = Number(rawMinCompleted);
  if (!Number.isInteger(minCompleted) || minCompleted < 1) {
    functions.logger.error(
      `evaluate-completion: min_completed_questions is missing or not a positive integer (got ${JSON.stringify(rawMinCompleted)}) for ${jobPath}`
    );
    return { success: false, message: CHECK_FAILED_MESSAGE };
  }

  const { firestore, cleanup } = await getClientFirestore(firebaseJwt);
  try {
    // Query answers using client SDK — matches getAnswerDocsQuery() in activity-player.
    // This goes through Firestore security rules.
    const answersRef = collection(firestore, `sources/${source_key}/answers`);
    const q = query(
      answersRef,
      where("platform_id", "==", platform_id),
      where("resource_link_id", "==", resource_link_id),
      where("context_id", "==", context_id),
      where("platform_user_id", "==", platform_user_id),
    );

    const snapshot = await getDocs(q);

    // Count completed answers
    const completed = snapshot.docs.filter(doc => answerIsCompleted(doc.data())).length;

    functions.logger.info(
      `evaluate-completion: ${completed} of ${snapshot.size} answer(s) completed (need ${minCompleted}) for user ${platform_user_id} at ${jobPath}`
    );

    // Compare against threshold
    if (completed < minCompleted) {
      // Configurable failure message with template variables
      const defaultMessage = `You have completed ${completed} of ${minCompleted} required questions. Please answer more questions in this activity.`;
      const customTemplate = request.min_completed_questions_failure_message;
      let message = defaultMessage;
      if (customTemplate && typeof customTemplate === "string") {
        message = customTemplate
          .replace(/\$\{completed\}/g, String(completed))
          .replace(/\$\{min_completed_questions\}/g, String(minCompleted));
      }
      // `expected`: the student simply has not finished yet. Nothing has been written, they are not
      // locked, and answering another question and clicking again clears it, so the runner logs this
      // at warn rather than error.
      return { success: false, expected: true, message };
    }

    return {
      success: true,
      message: `${completed} of ${minCompleted} questions completed`,
    };
  } finally {
    try {
      await cleanup();
    } catch (cleanupErr) {
      functions.logger.warn("evaluate-completion: cleanup failed", cleanupErr);
    }
  }
};
