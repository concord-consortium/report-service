import * as functions from "firebase-functions";
import { StepContext, StepResult } from "./types";
import { portalOidcFetch } from "../portal-api";

const DEFAULT_SUBJECT = "AI4VS: Student completed pre-test";
const MAX_SUBJECT_LENGTH = 200;

const STUDENT_FAILURE_MESSAGE =
  "Unable to send notification email. Please try again or contact your teacher.";

const sanitizeSubject = (subject: string): string => {
  return subject.replace(/[\r\n]+/g, " ").trim().slice(0, MAX_SUBJECT_LENGTH);
};

const buildEmailBody = (context: StepContext): string => {
  const { jobDoc, stepResults } = context;
  const { platform_id, platform_user_id, resource_link_id } = jobDoc;

  const lines: string[] = [
    'AI4VS "I\'m Done!" Pipeline Summary',
    "===================================",
    "",
    `Student: ${platform_id}/users/${platform_user_id}`,
    `Offering: ${resource_link_id}`,
    "",
    "Pipeline Results:",
  ];

  for (const [stepName, result] of Object.entries(stepResults)) {
    const text = result.summary ?? result.message ?? "completed";
    lines.push(`- ${stepName}: ${text}`);
  }

  return lines.join("\n");
};

export const sendEmail = async (context: StepContext): Promise<StepResult> => {
  const { jobPath, jobDoc } = context;
  const { platform_id, platform_user_id, resource_link_id } = jobDoc;

  // Validate required context fields
  if (!platform_id || !platform_user_id || !resource_link_id) {
    const missing = [
      !platform_id && "platform_id",
      !platform_user_id && "platform_user_id",
      !resource_link_id && "resource_link_id",
    ].filter(Boolean).join(", ");
    functions.logger.error(`send-email: missing required context fields: ${missing} for ${jobPath}`);
    return { success: false, message: STUDENT_FAILURE_MESSAGE };
  }

  // Build subject (with optional override from request)
  const rawSubject = jobDoc.jobInfo.request.email_subject;
  const subject = sanitizeSubject(
    typeof rawSubject === "string" && rawSubject.trim() ? rawSubject : DEFAULT_SUBJECT
  );

  const message = buildEmailBody(context);

  functions.logger.info(
    `send-email: sending email for user ${platform_user_id} at ${platform_id} (${jobPath})`
  );

  try {
    const response = await portalOidcFetch({
      portalUrl: platform_id,
      path: "/api/v1/emails/oidc_send",
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ subject, message }),
    });

    if (response.status >= 200 && response.status < 300) {
      functions.logger.info(`send-email: email sent successfully (${jobPath})`);
      return { success: true };
    }

    functions.logger.error(
      `send-email: Portal returned ${response.status} for ${jobPath}`,
      { status: response.status, data: response.data }
    );
    return { success: false, message: STUDENT_FAILURE_MESSAGE };
  } catch (error) {
    functions.logger.error(`send-email: request failed for ${jobPath}`, error);
    return { success: false, message: STUDENT_FAILURE_MESSAGE };
  }
};
