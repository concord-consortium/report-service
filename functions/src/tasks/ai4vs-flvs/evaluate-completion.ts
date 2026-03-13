import * as functions from "firebase-functions";
import { collection, query, where, getDocs } from "firebase/firestore";
import { StepContext, StepResult } from "./types";
import { getClientFirestore } from "../../firebase-client";

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

    functions.logger.info(
      `evaluate-completion: found ${snapshot.size} answer(s) for user ${platform_user_id} in ${source_key} at ${jobPath}`
    );

    // For this experiment, simply log that we successfully read the answers
    // and return success. A real implementation would check completeness.
    if (snapshot.empty) {
      return {
        success: false,
        message: `evaluate-completion: no answers found for user ${platform_user_id}`,
      };
    }

    return {
      success: true,
      message: `evaluate-completion: found ${snapshot.size} answer(s) via client SDK`,
    };
  } finally {
    try {
      await cleanup();
    } catch (cleanupErr) {
      functions.logger.warn("evaluate-completion: cleanup failed", cleanupErr);
    }
  }
};
