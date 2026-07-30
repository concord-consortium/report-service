import * as functions from "firebase-functions";
import { StepContext, StepResult, readStepOutputField } from "./types";
import {
  getScopedPortalToken, classifyPortalFailure, messageForBucket, TELL_TEACHER_MESSAGE,
} from "../portal-api";
import { lookupClassByWord, PortalOffering } from "../portal-reads";
import { armFromClassWord } from "./fall-programs";
import { applyOfferingState } from "./offering-state";

/**
 * The curriculum sequence, opened to control students once they finish the post-test.
 *
 * ⚠️ THIS IS THE RUNNABLE'S NAME AS THE PORTAL SERVES IT. Portal::Offering#name delegates to the
 * runnable, and the portal's copy is a snapshot taken at publish time (ExternalActivitiesController
 * sets `name` from params on create and re-permits it on update), so it is not a live delegation to
 * the authoring title. Renaming the sequence in the portal breaks this in every subclass at once,
 * and the fix is a report-service deploy. There is deliberately no authored override, which would
 * add a second source of truth for no less work than editing this line.
 *
 * ⚠️ Written trimmed although the authored name carries a trailing space. The comparison below trims
 * both sides. Narrowing that to an exact match would break this against a name that still looks
 * identical.
 *
 * Exported so a test can assert the harness fixture holds the same string.
 */
export const TARGET_OFFERING_NAME = "Blue Sequence for AI in Math (FLVS 26-27)";

/**
 * ⚠️ A failed open is an experience problem rather than a data problem: the student's completion was
 * already recorded by the preceding lock, and the researcher opens sequences by hand regardless. No
 * retry promise, because by the time this runs the student has been locked out by that preceding
 * step and cannot re-click. The reassurance is guaranteed by control flow, since a failed lock
 * aborts the pipeline before this step runs.
 *
 * ⚠️ ONE PATH BELOW CONTRADICTS THAT, AND ONLY OUTSIDE A WIRED STAGE. An expired-token mint failure
 * routes through messageForBucket to the shared RELOAD_MESSAGE, which does say "click 'I'm Done'
 * again", and a test pins that. It is unreachable once a stage wires a lock ahead of this step: the
 * token cache is per-run with no expiry check (portal-api.ts), so a SUCCEEDED lock has already cached
 * the token this step would ask for, and a FAILED lock aborts before this step runs. It stays reachable
 * for a standalone invocation, which is how the harness drives this step today, and there the retry
 * advice is correct. The header rule governs the wired case; this is the exception, not a divergence.
 *
 * ⚠️ THIS MESSAGE COVERS THE TARGET-RESOLUTION FAILURES TOO (no match, several matches, self-target),
 * not only the retryable portal ones. Those three are permanent configuration faults, so the usual rule
 * would hand them the shared TELL_TEACHER_MESSAGE; here that rule buys nothing and costs the
 * reassurance. The rule exists because a step's own message typically promises a retry that a permanent
 * fault cannot honour, which is true of fall-random-assignment, whose message says "please try again".
 * This step's message promises no retry: both messages route the student to their teacher, and they
 * differ only in the "Your work has been saved" clause, which is TRUE on every one of these branches
 * because the preceding lock succeeded. The shared message would also tell a student finishing a
 * post-test that something went wrong "setting up your class", which is not what happened.
 *
 * The no-match branch is where this matters most: it is where a stale TARGET_OFFERING_NAME or an
 * archived runnable lands, it fires for EVERY control student at once, and it fires at the last event
 * in the study. Those students' work did count, and the message they get says so.
 *
 * The genuine wiring faults below (an absent handoff, an unclassifiable class word) keep
 * TELL_TEACHER_MESSAGE: they mean the stage is mis-wired rather than the portal misconfigured, and
 * nothing about the student's work is knowable from them.
 */
const STUDENT_FAILURE_MESSAGE =
  "Your work has been saved. We could not open your other activity, so please tell your teacher.";

const normalizeName = (name: string): string => name.trim().toLowerCase();

/**
 * ⚠️ Skips any offering whose name is not a string. PortalOffering.name is declared string but the
 * wire can carry null: external_activities.name is nullable with no presence validation,
 * Offering#name delegates to it, and lookupClassByWord hardens the class's own fields while passing
 * each offering's through raw. Without the guard a single unnamed SIBLING offering anywhere in the
 * class throws, and the catch below turns that into the retryable message, failing every control
 * student on a condition retry cannot fix while the target itself is present and correctly named.
 *
 * `normalizedTarget` is named for its contract: only the OFFERING's side is normalized in here, so a
 * caller handing in TARGET_OFFERING_NAME raw would match nothing and take the no-match exit, which is
 * the one failure this file works hardest to make loud.
 */
const matchesTargetName = (offering: PortalOffering, normalizedTarget: string): boolean =>
  typeof offering.name === "string" && normalizeName(offering.name) === normalizedTarget;

/**
 * Open the curriculum to a control student: unlock it AND make it visible.
 *
 * Opening means making reachable. An offering whose effective active is false is absent from the
 * student's runnable list entirely, so unlocking a hidden offering accomplishes nothing they can
 * see, which is why this writes both flags rather than preserving a state that would defeat it.
 *
 * The target is resolved by name within the student's origin class, never by a database id, because
 * ids differ between the staging and production portals and would have to be re-authored per
 * environment. That resolution is also what makes the origin mint sufficient with no pre-write
 * authorization check: the target is selected from the offerings of the one class originClassWord
 * names, so it cannot denote an offering outside the class the mint already authorizes, and a wrong
 * name yields zero matches rather than a cross-class write.
 */
export const openTargetOffering = async (context: StepContext): Promise<StepResult> => {
  const { jobPath, jobDoc, firebaseJwt, tokenCache, portalOrigin, stepResults } = context;
  const { platform_id, platform_user_id, resource_link_id } = jobDoc;
  const pilot = String(jobDoc.jobInfo.request.pilot);

  if (!platform_id || !platform_user_id || !resource_link_id) {
    const missing = [
      !platform_id && "platform_id",
      !platform_user_id && "platform_user_id",
      !resource_link_id && "resource_link_id",
    ].filter(Boolean).join(", ");
    functions.logger.error(`open-target-offering: missing required context fields: ${missing} for ${jobPath}`);
    return { success: false, message: STUDENT_FAILURE_MESSAGE };
  }
  if (!firebaseJwt) {
    functions.logger.error(`open-target-offering: missing Firebase JWT for ${jobPath}`);
    return { success: false, message: STUDENT_FAILURE_MESSAGE };
  }

  // Read the handoff rather than re-reading the offering, with no ordering guard, as
  // fall-random-assignment does. An absent value can only mean a mis-wired stage, so the shared
  // tell-teacher message rather than this step's own: nothing about the student's work is knowable
  // here, and "your work has been saved" would be a guess about a stage that never ran a lock.
  const originClassWord = readStepOutputField(stepResults, "originClassWord");
  if (!originClassWord) {
    functions.logger.error(
      `open-target-offering: no originClassWord handoff (is resolve-origin-class first in this stage?) for ${jobPath}`,
    );
    return { success: false, message: TELL_TEACHER_MESSAGE };
  }

  // ⚠️ The arm check runs before any portal call. Roughly half the fall cohort is treatment, and a
  // check placed after the class read would have every one of them pay a classes/info read to do
  // nothing, while needlessly holding the whole class's per-student metadata on a path with no use
  // for it.
  const arm = armFromClassWord(originClassWord);
  if (!arm) {
    // Safe to log the offending word: authored, environment-stable, not PII, not a token.
    functions.logger.error(
      `open-target-offering: unclassifiable origin class word for ${jobPath}`,
      { origin_class_word: originClassWord },
    );
    return { success: false, message: TELL_TEACHER_MESSAGE };
  }
  if (arm === "treatment") {
    // Treatment students completed the curriculum and were deliberately locked out of it so they
    // cannot go back and change answers. Success with a summary saying nothing was done, since
    // send-email renders this line.
    functions.logger.info(`open-target-offering: treatment student, nothing to open (${jobPath})`);
    return { success: true, summary: "No activity to open for this student" };
  }

  const target = normalizeName(TARGET_OFFERING_NAME);

  try {
    // classes#info has no per-class authorization, so the origin (unscoped) mint suffices, and it is
    // the same token the write needs. One cached token, one mint per stage.
    const originToken = await getScopedPortalToken({
      cache: tokenCache, portalUrl: portalOrigin, firebaseToken: firebaseJwt, tokenType: "teacher", pilot,
    });
    if (!originToken.ok || !originToken.token) {
      const mintBucket = classifyPortalFailure({ status: originToken.status, reason: originToken.reason });
      return { success: false, message: messageForBucket(mintBucket, STUDENT_FAILURE_MESSAGE) };
    }

    const lookup = await lookupClassByWord(portalOrigin, originToken.token, originClassWord);
    if (!lookup.class) {
      functions.logger.error(
        `open-target-offering: class lookup failed for ${jobPath}`,
        { status: lookup.status, class_word: originClassWord },
      );
      const lookupBucket = classifyPortalFailure({ status: lookup.status });
      return { success: false, message: messageForBucket(lookupBucket, STUDENT_FAILURE_MESSAGE) };
    }

    const matches = lookup.class.offerings.filter((offering) => matchesTargetName(offering, target));

    if (matches.length === 0) {
      // ⚠️ The class's offering NAMES are the whole diagnostic value of this branch. Without them the
      // line is identical whether the constant is stale after a portal-side rename, the student
      // launched from the wrong class, the target's runnable was archived out of
      // teacher_visible_offerings, or the class was built without the target, and those have
      // different owners and different fixes. Names only, never the offering objects, which would
      // drag every student in the class and their lock state into a log line.
      functions.logger.error(
        `open-target-offering: no offering matched the target name for ${jobPath}`,
        {
          target_name: TARGET_OFFERING_NAME,
          class_word: originClassWord,
          class_offering_names: lookup.class.offerings.map((offering) => offering.name),
        },
      );
      return { success: false, message: STUDENT_FAILURE_MESSAGE };
    }

    if (matches.length > 1) {
      // Offering names are not unique in the portal, and a first-match guess would unlock an
      // activity nobody chose.
      functions.logger.error(
        `open-target-offering: target name matched ${matches.length} offerings for ${jobPath}`,
        {
          target_name: TARGET_OFFERING_NAME,
          class_word: originClassWord,
          matched_offering_ids: matches.map((offering) => offering.id),
        },
      );
      return { success: false, message: STUDENT_FAILURE_MESSAGE };
    }

    const targetOffering = matches[0];

    // ⚠️ A target-selection rule, not an authorization check: it asks whether this step is about to
    // undo the lock the stage just took, not whether the write is permitted. The failure it
    // forecloses is a constant naming the sequence the stage LOCKS rather than the one it opens,
    // which would write locked:false over the completion record the roster reads, silently,
    // returning success, on the control arm only. The study class holds exactly two offerings, so
    // this plus the intended target exhaust every name that resolves at all. Compared as strings:
    // resource_link_id is a decimal string and PortalOffering.id is a JSON number.
    if (String(targetOffering.id) === String(resource_link_id)) {
      functions.logger.error(
        `open-target-offering: target resolved to this run's own offering; refusing to unlock it for ${jobPath}`,
        {
          target_name: TARGET_OFFERING_NAME,
          target_offering_id: targetOffering.id,
          resource_link_id,
        },
      );
      return { success: false, message: STUDENT_FAILURE_MESSAGE };
    }

    const outcome = await applyOfferingState(context, {
      offeringId: targetOffering.id,
      locked: false,
      // Visibility is the point here, so this is unconditional rather than echoed from the class
      // body: an offering that is not visible is not reachable however unlocked it is.
      active: true,
    });

    if (!outcome.ok) {
      if (outcome.status !== undefined) {
        functions.logger.error(
          `open-target-offering: Portal returned ${outcome.status} for ${jobPath}`,
          { status: outcome.status, data: outcome.data }
        );
      }
      return { success: false, message: messageForBucket(outcome.bucket, STUDENT_FAILURE_MESSAGE) };
    }

    functions.logger.info(
      `open-target-offering: opened offering ${targetOffering.id} for user ${platform_user_id} ` +
      `(portal returned active=${outcome.returned?.active} locked=${outcome.returned?.locked}) (${jobPath})`
    );
    // summary is rendered into the teacher-notification email, so it carries the offering name and
    // the flags written and nothing else off the class body. The constant rather than the matched
    // offering's own name, since matching is case-insensitive and trimmed: the portal's value can
    // differ in case and padding, which would reach the email verbatim.
    return { success: true, summary: `Opened ${TARGET_OFFERING_NAME} (unlocked and visible)` };
  } catch (error) {
    functions.logger.error(`open-target-offering: unexpected error for ${jobPath}`, error);
    return { success: false, message: STUDENT_FAILURE_MESSAGE };
  }
};
