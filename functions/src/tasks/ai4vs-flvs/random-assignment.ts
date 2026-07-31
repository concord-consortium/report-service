import * as functions from "firebase-functions";
import { StepContext, StepResult } from "./types";
import { getScopedPortalToken, portalTokenFetch, classifyPortalFailure, messageForBucket } from "../portal-api";
import { getAlternatingAssignment, perClassScope } from "./assignment-doc";
import { DIMENSIONS, readDemographics } from "./demographics";
import { SPRING_PRE_TEST } from "./pre-tests";
import { GENDER_RACE_GRADE_MODULE_TABLE } from "./strata-tables";

const STUDENT_FAILURE_MESSAGE =
  "Unable to complete your assignment. Please try again or contact your teacher.";

/** Class names (baked in). Portal class IDs come from request params. */
const CLASS_NAMES: Record<string, string> = {
  treatment: "FL-spring-2026-GATOR",
  control: "FL-spring-2026-SHARK",
};

export const randomAssignment = async ({
  jobPath,
  jobDoc,
  firebaseJwt,
  tokenCache,
  portalOrigin,
}: StepContext): Promise<StepResult> => {
  // Validate request parameters first
  const { request } = jobDoc.jobInfo;
  const treatmentClassId = String(request.treatment_class_id ?? "").trim();
  const controlClassId = String(request.control_class_id ?? "").trim();

  if (!treatmentClassId || !controlClassId) {
    const missing = [
      !treatmentClassId && "treatment_class_id",
      !controlClassId && "control_class_id",
    ].filter(Boolean).join(", ");
    functions.logger.error(`random-assignment: missing required request parameters: ${missing} for ${jobPath}`);
    return { success: false, message: STUDENT_FAILURE_MESSAGE };
  }

  if (!firebaseJwt) {
    functions.logger.error(`random-assignment: missing Firebase JWT for ${jobPath}`);
    return { success: false, message: STUDENT_FAILURE_MESSAGE };
  }

  const { source_key, platform_user_id, platform_id, resource_link_id, context_id, interactiveId } = jobDoc;

  if (!source_key || !platform_user_id || !platform_id || !resource_link_id || !context_id || !interactiveId) {
    const missing = [
      !source_key && "source_key",
      !platform_user_id && "platform_user_id",
      !platform_id && "platform_id",
      !resource_link_id && "resource_link_id",
      !context_id && "context_id",
      !interactiveId && "interactiveId",
    ].filter(Boolean).join(", ");
    functions.logger.error(`random-assignment: missing required context fields: ${missing} for ${jobPath}`);
    return { success: false, message: STUDENT_FAILURE_MESSAGE };
  }

  try {
    const demographics = await readDemographics({
      logPrefix: "random-assignment", jobPath, firebaseJwt,
      source_key: String(source_key), platform_id: String(platform_id),
      resource_link_id: String(resource_link_id), context_id: String(context_id),
      platform_user_id: String(platform_user_id),
      preTest: SPRING_PRE_TEST, dimensions: DIMENSIONS,
    });
    if (!demographics.ok) {
      if (demographics.kind === "incomplete") {
        return {
          success: false,
          // A skipped question, not a fault: `expected` keeps the runner's failure line at warn. It
          // changes no message and no behaviour on this live pilot, and readDemographics's own
          // error-level line for the same event is untouched.
          expected: true,
          message: `Please complete the following question(s) before continuing: ${demographics.missing.join(", ")}.`,
        };
      }
      // Spring keeps ONE message for both remaining kinds. The fall step distinguishes them.
      return { success: false, message: STUDENT_FAILURE_MESSAGE };
    }

    const { Gender, Race, Grade, Module } = demographics.categories;
    const stratumKey = `${Gender}|${Race}|${Grade}|${Module}`;
    const n1Assignment = GENDER_RACE_GRADE_MODULE_TABLE[stratumKey];
    if (!n1Assignment) {
      functions.logger.error(
        `random-assignment: no matching stratum for ${stratumKey} for user ${platform_user_id} at ${jobPath}`
      );
      return { success: false, message: STUDENT_FAILURE_MESSAGE };
    }

    const assignment = await getAlternatingAssignment(
      String(source_key),
      perClassScope(String(interactiveId), String(platform_id), String(resource_link_id), String(context_id)),
      String(platform_user_id), stratumKey, n1Assignment,
    );

    const className = CLASS_NAMES[assignment];
    const classId = assignment === "treatment" ? treatmentClassId : controlClassId;

    // Enroll in Portal class
    functions.logger.info(
      `random-assignment: enrolling user ${platform_user_id} in class ${className} (${classId}) at ${platform_id} (${jobPath})`
    );

    // Enroll acts as a teacher shared between the origin and destination classes, so mint a
    // cross-class teacher token scoped to the destination class.
    const tokenResult = await getScopedPortalToken({
      cache: tokenCache,
      portalUrl: portalOrigin,
      firebaseToken: firebaseJwt,
      tokenType: "teacher",
      classId: String(classId),
      pilot: String(jobDoc.jobInfo.request.pilot),
    });
    if (!tokenResult.ok || !tokenResult.token) {
      const mintBucket = classifyPortalFailure({ status: tokenResult.status, reason: tokenResult.reason });
      return { success: false, message: messageForBucket(mintBucket, STUDENT_FAILURE_MESSAGE) };
    }

    const response = await portalTokenFetch({
      portalUrl: portalOrigin,
      path: "/api/v1/students/add_to_class",
      method: "POST",
      token: tokenResult.token,
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        user_id: String(platform_user_id),
        clazz_id: String(classId),
      }),
    });

    if (response.status >= 200 && response.status < 300 && response.data?.success === true) {
      functions.logger.info(
        `random-assignment: successfully enrolled user ${platform_user_id} in ${className} (${jobPath})`
      );
      return { success: true, summary: `Assigned to ${className}` };
    }

    functions.logger.error(
      `random-assignment: Portal enrollment failed for ${jobPath}`,
      { status: response.status, data: response.data }
    );
    const bucket = classifyPortalFailure({ status: response.status, reason: response.data?.details?.reason });
    return { success: false, message: messageForBucket(bucket, STUDENT_FAILURE_MESSAGE) };
  } catch (error) {
    functions.logger.error(`random-assignment: unexpected error for ${jobPath}`, error);
    return { success: false, message: STUDENT_FAILURE_MESSAGE };
  }
};
