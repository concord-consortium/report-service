import * as functions from "firebase-functions";
import { collection, query, where, getDocs } from "firebase/firestore";
import { StepContext, StepResult } from "./types";
import { getClientFirestore } from "../../firebase-client";
import { answerIsCompleted } from "../answer-utils";

export const evaluateCompletion = async ({
  jobPath,
  jobDoc,
  firebaseJwt,
}: StepContext): Promise<StepResult> => {
  if (!firebaseJwt) {
    return { success: false, message: "evaluate-completion: missing Firebase JWT" };
  }

  const { source_key, platform_user_id, platform_id, resource_link_id, context_id } = jobDoc;

  if (!source_key || !platform_user_id || !platform_id || !resource_link_id || !context_id) {
    return {
      success: false,
      message: "evaluate-completion: missing required context fields (source_key, platform_user_id, platform_id, resource_link_id, context_id)",
    };
  }

  // Validate min_completed_questions before establishing Firestore connection
  const { request } = jobDoc.jobInfo;
  const rawMinCompleted = request.min_completed_questions;
  if (rawMinCompleted === undefined || rawMinCompleted === null) {
    return {
      success: false,
      message: "evaluate-completion: request is missing required parameter min_completed_questions",
    };
  }
  const minCompleted = Number(rawMinCompleted);
  if (!Number.isInteger(minCompleted) || minCompleted < 1) {
    return {
      success: false,
      message: `evaluate-completion: min_completed_questions must be a positive integer, got: ${JSON.stringify(rawMinCompleted)}`,
    };
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
      return { success: false, message };
    }

    return {
      success: true,
      message: `evaluate-completion: ${completed} of ${minCompleted} questions completed`,
    };
  } finally {
    try {
      await cleanup();
    } catch (cleanupErr) {
      functions.logger.warn("evaluate-completion: cleanup failed", cleanupErr);
    }
  }
};
