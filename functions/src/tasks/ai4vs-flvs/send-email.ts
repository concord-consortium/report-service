import * as functions from "firebase-functions";
import { StepContext, StepResult, readStepOutputField } from "./types";
import { getScopedPortalToken, portalTokenFetch, classifyPortalFailure, messageForBucket } from "../portal-api";
import { resolveOriginOffering } from "../portal-reads";

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
    // The pilot names the stage (pre-test / curriculum / post-test). Four pipelines now render this
    // one body, and R14's authored email_subject is the only other thing that distinguishes them: an
    // omitted subject leaves a curriculum or post-test notification subject-lined "completed
    // pre-test", which nothing in code can detect. This line makes that recoverable after the fact.
    // It discloses nothing new: the pilot is an authored string, neither PII nor a token.
    `Stage: ${jobDoc.jobInfo.request.pilot}`,
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
  const { jobPath, jobDoc, firebaseJwt, stepResults, tokenCache, portalOrigin } = context;
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

  if (!firebaseJwt) {
    functions.logger.error(`send-email: missing Firebase JWT for ${jobPath}`);
    return { success: false, message: STUDENT_FAILURE_MESSAGE };
  }

  functions.logger.info(
    `send-email: sending email for user ${platform_user_id} at ${platform_id} (${jobPath})`
  );

  try {
    const tokenResult = await getScopedPortalToken({
      cache: tokenCache,
      portalUrl: portalOrigin,
      firebaseToken: firebaseJwt,
      tokenType: "teacher",
      pilot: String(jobDoc.jobInfo.request.pilot),
    });
    if (!tokenResult.ok || !tokenResult.token) {
      const mintBucket = classifyPortalFailure({ status: tokenResult.status, reason: tokenResult.reason });
      return { success: false, message: messageForBucket(mintBucket, STUDENT_FAILURE_MESSAGE) };
    }
    const token = tokenResult.token;

    // send_class_teachers needs the origin class_id, but this step holds only resource_link_id.
    // A stage that ran resolve-origin-class already paid for that read and published the id, so
    // take the handoff when it is there. The read below is RETAINED as a fallback and is NOT dead
    // code: spring-2026 has no resolve-origin-class step and neither does the fall curriculum
    // stage, so both reach it on every run.
    let classId = readStepOutputField(stepResults, "originClazzId");
    if (!classId) {
      const origin = await resolveOriginOffering(portalOrigin, token, String(resource_link_id));
      if (!origin.offering) {
        functions.logger.error(`send-email: offering-read failed for ${jobPath}`, { status: origin.status });
        const offeringBucket = classifyPortalFailure({ status: origin.status });
        return { success: false, message: messageForBucket(offeringBucket, STUDENT_FAILURE_MESSAGE) };
      }
      classId = String(origin.offering.clazzId);
    }

    const response = await portalTokenFetch({
      portalUrl: portalOrigin,
      path: "/api/v1/emails/send_class_teachers",
      method: "POST",
      token,
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ class_id: classId, subject, message }),
    });

    if (response.status >= 200 && response.status < 300 && response.data?.success === true) {
      functions.logger.info(`send-email: email sent successfully (${jobPath})`);
      return { success: true };
    }

    functions.logger.error(
      `send-email: Portal returned ${response.status} for ${jobPath}`,
      { status: response.status, data: response.data }
    );
    const bucket = classifyPortalFailure({ status: response.status, reason: response.data?.details?.reason });
    return { success: false, message: messageForBucket(bucket, STUDENT_FAILURE_MESSAGE) };
  } catch (error) {
    functions.logger.error(`send-email: request failed for ${jobPath}`, error);
    return { success: false, message: STUDENT_FAILURE_MESSAGE };
  }
};
