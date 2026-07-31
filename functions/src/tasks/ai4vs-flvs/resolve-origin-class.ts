import * as functions from "firebase-functions";
import { StepContext, StepResult } from "./types";
import {
  getScopedPortalToken, classifyPortalFailure, messageForBucket, TELL_TEACHER_MESSAGE,
} from "../portal-api";
import { resolveOriginOffering } from "../portal-reads";

const STUDENT_FAILURE_MESSAGE =
  "Unable to look up your class. Please try again or contact your teacher.";

/**
 * Resolve the student's origin class word once per run and publish it for the later steps.
 *
 * Mints ONCE: steps that need the class word read it from stepResults rather than re-reading the
 * offering, and the per-run tokenCache means a later step needing the same scope reuses the token.
 *
 * The offering's clazzId is published alongside the class word, from the same response, so a stage
 * containing this step spares send-email its own GET /api/v1/offerings/:id. send-email keeps that
 * read as a fallback for the stages that have no resolve-origin-class.
 *
 * Like the other steps here this makes NO host check of its own: it assumes the pipeline ran
 * validatePortalHost before the loop and uses StepContext.portalOrigin for every portal call, never
 * the raw jobDoc.platform_id.
 */
export const resolveOriginClass = async (context: StepContext): Promise<StepResult> => {
  const { jobPath, jobDoc, firebaseJwt, tokenCache, portalOrigin } = context;
  const { resource_link_id } = jobDoc;
  const pilot = String(jobDoc.jobInfo.request.pilot);

  if (!resource_link_id) {
    functions.logger.error(`resolve-origin-class: missing required context field: resource_link_id for ${jobPath}`);
    return { success: false, message: STUDENT_FAILURE_MESSAGE };
  }
  if (!firebaseJwt) {
    functions.logger.error(`resolve-origin-class: missing Firebase JWT for ${jobPath}`);
    return { success: false, message: STUDENT_FAILURE_MESSAGE };
  }

  try {
    // The offering read needs only an origin-class teacher token, so this is the unscoped mint.
    const token = await getScopedPortalToken({
      cache: tokenCache, portalUrl: portalOrigin, firebaseToken: firebaseJwt, tokenType: "teacher", pilot,
    });
    if (!token.ok || !token.token) {
      const mintBucket = classifyPortalFailure({ status: token.status, reason: token.reason });
      return { success: false, message: messageForBucket(mintBucket, STUDENT_FAILURE_MESSAGE) };
    }

    const origin = await resolveOriginOffering(portalOrigin, token.token, String(resource_link_id));
    if (!origin.offering) {
      functions.logger.error(`resolve-origin-class: offering-read failed for ${jobPath}`, { status: origin.status });
      const offeringBucket = classifyPortalFailure({ status: origin.status });
      return { success: false, message: messageForBucket(offeringBucket, STUDENT_FAILURE_MESSAGE) };
    }

    // Normalized to the portal's STORED form, which is the contract every consumer inherits.
    // Portal::Clazz lowercases and strips class_word before validation on every save, and
    // offerings#show serves the stored value, so this is a no-op against real portal data. It is
    // done here rather than compared case-insensitively downstream so that "originClassWord is in
    // the portal's stored form" is an invariant every consumer inherits from one place, instead of
    // each of them having to remember it.
    const classWord = origin.offering.classWord?.trim().toLowerCase();
    if (!classWord) {
      // A classified failure, not a fallback. class_word is teacher-gated and these pipelines only
      // ever mint teacher tokens, so an absent one indicates a real anomaly rather than a
      // permissions shortfall. Error level: everything downstream (the teacher stratum, the
      // destination class) depends on this value, so the blast radius is the student's study arm.
      functions.logger.error(
        `resolve-origin-class: offering ${resource_link_id} returned no class_word for ${jobPath}`,
      );
      return { success: false, message: TELL_TEACHER_MESSAGE };
    }

    functions.logger.info(`resolve-origin-class: resolved origin class word ${classWord} for ${jobPath}`);
    // summary is display-only (send-email renders it into the teacher email); a class word is
    // authored, environment-stable, and neither PII nor a token, so it is safe here.
    return {
      success: true,
      summary: `Origin class ${classWord}`,
      output: { originClassWord: classWord, originClazzId: String(origin.offering.clazzId) },
    };
  } catch (error) {
    functions.logger.error(`resolve-origin-class: unexpected error for ${jobPath}`, error);
    return { success: false, message: STUDENT_FAILURE_MESSAGE };
  }
};
