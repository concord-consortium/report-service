import * as functions from "firebase-functions";
import { StepContext, StepResult } from "./types";
import { portalOidcFetch } from "../portal-api";

const STUDENT_FAILURE_MESSAGE =
  "Unable to lock your pre-test. Please try again or contact your teacher.";

export const lockActivity = async ({
  jobPath,
  jobDoc,
}: StepContext): Promise<StepResult> => {
  const { platform_id, platform_user_id, resource_link_id } = jobDoc;

  // Validate required context fields
  if (!platform_id || !platform_user_id || !resource_link_id) {
    const missing = [
      !platform_id && "platform_id",
      !platform_user_id && "platform_user_id",
      !resource_link_id && "resource_link_id",
    ].filter(Boolean).join(", ");
    functions.logger.error(`lock-activity: missing required context fields: ${missing} for ${jobPath}`);
    return { success: false, message: STUDENT_FAILURE_MESSAGE };
  }

  functions.logger.info(
    `lock-activity: locking offering ${resource_link_id} for user ${platform_user_id} at ${platform_id} (${jobPath})`
  );

  try {
    const response = await portalOidcFetch({
      portalUrl: platform_id,
      path: `/api/v1/offerings/${resource_link_id}/update_student_metadata`,
      method: "PUT",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        locked: "true",
        user_id: String(platform_user_id),
      }).toString(),
    });

    if (response.status >= 200 && response.status < 300) {
      functions.logger.info(
        `lock-activity: successfully locked offering ${resource_link_id} for user ${platform_user_id} (${jobPath})`
      );
      return { success: true };
    }

    functions.logger.error(
      `lock-activity: Portal returned ${response.status} for ${jobPath}`,
      { status: response.status, data: response.data }
    );
    return { success: false, message: STUDENT_FAILURE_MESSAGE };
  } catch (error) {
    functions.logger.error(`lock-activity: request failed for ${jobPath}`, error);
    return { success: false, message: STUDENT_FAILURE_MESSAGE };
  }
};
