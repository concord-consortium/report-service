import * as functions from "firebase-functions";
import { StepContext, StepResult } from "./types";
import {
  getScopedPortalToken, portalTokenFetch, classifyPortalFailure, messageForBucket, TELL_TEACHER_MESSAGE,
} from "../portal-api";
import { lookupClassByWord } from "../portal-reads";

const STUDENT_FAILURE_MESSAGE =
  "Unable to enroll you in your class. Please try again or contact your teacher.";

/**
 * Destination class word: an authored `target_class_word` request param, or the preceding
 * step's `output.destinationClassWord` handoff. Exactly ONE upstream step (the randomization
 * step) is expected to set `destinationClassWord`; the scan takes the first that does (Record
 * iteration is insertion = pipeline order). Never a raw clazz_id — no db ids in the authored
 * config.
 *
 * Precedence is deliberately NOT "authored silently wins". `target_class_word` is a per-launch
 * request param, so a button authored with a fixed word AND wired to randomization would route
 * EVERY student to the one authored class, silently defeating randomization for the whole
 * study. There is no intended "authored overrides randomization" use case, so an authored word
 * that DIFFERS from a present handoff is a hard configuration error, not a silent preference.
 * An authored word EQUAL to the handoff is not a conflict.
 */
type DestinationWordResolution =
  | { ok: true; word: string }
  | { ok: false; reason: "missing" | "conflict" };

const resolveDestinationWord = (context: StepContext, jobPath: string): DestinationWordResolution => {
  const authoredRaw = context.jobDoc.jobInfo.request.target_class_word;
  const authored = typeof authoredRaw === "string" && authoredRaw.trim() ? authoredRaw.trim() : undefined;

  let handoff: string | undefined;
  for (const result of Object.values(context.stepResults)) {
    const handedOff = result.output?.destinationClassWord;
    if (typeof handedOff === "string" && handedOff.trim()) {
      handoff = handedOff.trim();
      break;
    }
  }

  if (authored && handoff && authored !== handoff) {
    functions.logger.error(
      `enroll-specified-class: conflicting destination words (authored target_class_word differs from the handoff destinationClassWord); refusing to guess for ${jobPath}`,
    );
    return { ok: false, reason: "conflict" };
  }

  const word = authored ?? handoff;
  if (!word) {
    return { ok: false, reason: "missing" };
  }
  return { ok: true, word };
};

/**
 * Enroll the student into an author-specified (or handed-off) class, resolved by class word at
 * run time. Like lock-activity / send-email, this step makes NO host check of its own: it
 * assumes the consuming pipeline ran validatePortalHost at setup before the pipeline loop, and
 * it uses the validated, normalized base URL that gate produced (StepContext.portalOrigin) for
 * every portal call, never the raw jobDoc.platform_id. That gate is the token-exfiltration
 * guard and must not be dropped when this step is wired into a pipeline.
 */
export const enrollSpecifiedClass = async (context: StepContext): Promise<StepResult> => {
  const { jobPath, jobDoc, firebaseJwt, tokenCache, portalOrigin } = context;
  const { platform_id, platform_user_id } = jobDoc;
  const pilot = String(jobDoc.jobInfo.request.pilot);

  if (!platform_id || !platform_user_id) {
    const missing = [!platform_id && "platform_id", !platform_user_id && "platform_user_id"]
      .filter(Boolean).join(", ");
    functions.logger.error(`enroll-specified-class: missing required context fields: ${missing} for ${jobPath}`);
    return { success: false, message: STUDENT_FAILURE_MESSAGE };
  }
  if (!firebaseJwt) {
    functions.logger.error(`enroll-specified-class: missing Firebase JWT for ${jobPath}`);
    return { success: false, message: STUDENT_FAILURE_MESSAGE };
  }

  const destination = resolveDestinationWord(context, jobPath);
  if (!destination.ok) {
    if (destination.reason === "conflict") {
      // A study-wide authoring mistake, not a transient error and not something to guess through.
      return { success: false, message: TELL_TEACHER_MESSAGE };
    }
    functions.logger.error(`enroll-specified-class: no destination class word (param or handoff) for ${jobPath}`);
    return { success: false, message: STUDENT_FAILURE_MESSAGE };
  }
  const destinationWord = destination.word;

  try {
    // Any teacher token can read classes/info, so use the origin (unscoped) mint here.
    const originToken = await getScopedPortalToken({
      cache: tokenCache, portalUrl: portalOrigin, firebaseToken: firebaseJwt, tokenType: "teacher", pilot,
    });
    if (!originToken.ok || !originToken.token) {
      const originMintBucket = classifyPortalFailure({ status: originToken.status, reason: originToken.reason });
      return { success: false, message: messageForBucket(originMintBucket, STUDENT_FAILURE_MESSAGE) };
    }

    const lookup = await lookupClassByWord(portalOrigin, originToken.token, destinationWord);
    if (!lookup.class) {
      // Safe to log the attempted word: authored, environment-stable, not PII, not a token.
      functions.logger.error(
        `enroll-specified-class: class lookup failed for ${jobPath}`,
        { status: lookup.status, class_word: destinationWord },
      );
      const lookupBucket = classifyPortalFailure({ status: lookup.status });
      return { success: false, message: messageForBucket(lookupBucket, STUDENT_FAILURE_MESSAGE) };
    }
    const destinationClassId = String(lookup.class.id);

    // Enroll acts as a teacher shared between the origin and destination classes, so mint a
    // cross-class teacher token scoped to the destination class.
    const enrollToken = await getScopedPortalToken({
      cache: tokenCache, portalUrl: portalOrigin, firebaseToken: firebaseJwt, tokenType: "teacher",
      classId: destinationClassId, pilot,
    });
    if (!enrollToken.ok || !enrollToken.token) {
      const enrollMintBucket = classifyPortalFailure({ status: enrollToken.status, reason: enrollToken.reason });
      return { success: false, message: messageForBucket(enrollMintBucket, STUDENT_FAILURE_MESSAGE) };
    }

    // Server-side idempotent: an already-enrolled student still returns { success: true }.
    functions.logger.info(
      `enroll-specified-class: enrolling user ${platform_user_id} into ${lookup.class.name} (${destinationClassId}) at ${platform_id} (${jobPath})`,
    );
    const response = await portalTokenFetch({
      portalUrl: portalOrigin,
      path: "/api/v1/students/add_to_class",
      method: "POST",
      token: enrollToken.token,
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ user_id: String(platform_user_id), clazz_id: destinationClassId }),
    });

    if (response.status >= 200 && response.status < 300 && response.data?.success === true) {
      functions.logger.info(`enroll-specified-class: enrolled user ${platform_user_id} into ${lookup.class.name} (${jobPath})`);
      // summary is display-only (rendered into the teacher email); a non-PII class name is fine.
      return { success: true, summary: `Enrolled in ${lookup.class.name}` };
    }

    functions.logger.error(
      `enroll-specified-class: Portal enrollment failed for ${jobPath}`,
      { status: response.status, data: response.data },
    );
    const bucket = classifyPortalFailure({ status: response.status, reason: response.data?.details?.reason });
    return { success: false, message: messageForBucket(bucket, STUDENT_FAILURE_MESSAGE) };
  } catch (error) {
    functions.logger.error(`enroll-specified-class: unexpected error for ${jobPath}`, error);
    return { success: false, message: STUDENT_FAILURE_MESSAGE };
  }
};
