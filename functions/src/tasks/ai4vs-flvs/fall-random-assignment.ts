import * as functions from "firebase-functions";
import { StepContext, StepResult, readStepOutputField } from "./types";
import { TELL_TEACHER_MESSAGE } from "../portal-api";
import { readDemographics } from "./demographics";
import { FALL_PRE_TEST } from "./pre-tests";
import { Arm, getAlternatingAssignment, perClassScope, pooledProgramScope } from "./assignment-doc";
import { GENDER_RACE_GRADE_MODULE_TABLE, findFullTimeStratum, fullTimeStratumKey } from "./strata-tables";
import {
  classifyFallProgram, teacherSurnameFromClassWord, FULL_TIME_PROGRAM,
  FULL_TIME_DIMENSIONS, FLEX_DIMENSIONS, DESTINATION_SUFFIX,
} from "./fall-programs";

const STUDENT_FAILURE_MESSAGE =
  "Unable to complete your assignment. Please try again or contact your teacher.";

/**
 * Randomize a fall student and publish their destination class word.
 *
 * The resolved program selects exactly THREE things and no more: the strata table, the demographic
 * input set, and the assignment scope. It does NOT select a pipeline; both cohorts run identical
 * stages, so PIPELINES stays keyed by stage and the dispatcher is untouched.
 *
 * This step performs NO enrolment and no portal write. It derives the destination class word and
 * hands it to the enroll-specified-class step. No raw class ids appear here: the spring
 * treatment_class_id / control_class_id parameters are not used on this path.
 */
export const fallRandomAssignment = async (context: StepContext): Promise<StepResult> => {
  const { jobPath, jobDoc, firebaseJwt, stepResults } = context;
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
    functions.logger.error(`fall-random-assignment: missing required context fields: ${missing} for ${jobPath}`);
    return { success: false, message: STUDENT_FAILURE_MESSAGE };
  }
  if (!firebaseJwt) {
    functions.logger.error(`fall-random-assignment: missing Firebase JWT for ${jobPath}`);
    return { success: false, message: STUDENT_FAILURE_MESSAGE };
  }

  // Read the handoff rather than re-reading the offering. No ordering guard: pipeline order is
  // assumed correct, and every fall stage needs the class word, so there is no case in which
  // resolve-origin-class is present but unused. An absent value can therefore only mean a
  // mis-wired stage, which fails on the first harness run; it is handled because the type is
  // optional, not as a defence against our own wiring.
  const originClassWord = readStepOutputField(stepResults, "originClassWord");
  if (!originClassWord) {
    functions.logger.error(
      `fall-random-assignment: no originClassWord handoff (is resolve-origin-class first in this stage?) for ${jobPath}`,
    );
    return { success: false, message: TELL_TEACHER_MESSAGE };
  }

  const program = classifyFallProgram(originClassWord);
  if (!program) {
    // Safe to log the offending word: authored, environment-stable, not PII, not a token. Error
    // level and tell-your-teacher, not the generic bucket: this is permanent until someone edits
    // configuration, so "try again" would be false.
    functions.logger.error(
      `fall-random-assignment: unclassifiable origin class word for ${jobPath}`,
      { origin_class_word: originClassWord },
    );
    return { success: false, message: TELL_TEACHER_MESSAGE };
  }

  // Derived ONCE. The program selects exactly three things, and every one of them is read off these
  // two constants: a second `program === FULL_TIME_PROGRAM` beside each use would be four
  // expressions that must agree, with nothing checking that they do. In particular the dimension set
  // requested below and the dimension set the guard checks must be the SAME value, or the guard is
  // comparing two derivations of it rather than the read against the request.
  const isFullTime = program === FULL_TIME_PROGRAM;
  const dimensions = isFullTime ? FULL_TIME_DIMENSIONS : FLEX_DIMENSIONS;

  const demographics = await readDemographics({
    logPrefix: "fall-random-assignment", jobPath, firebaseJwt,
    source_key: String(source_key), platform_id: String(platform_id),
    resource_link_id: String(resource_link_id), context_id: String(context_id),
    platform_user_id: String(platform_user_id),
    preTest: FALL_PRE_TEST,
    dimensions,
  });
  if (!demographics.ok) {
    if (demographics.kind === "incomplete") {
      // Carried forward from spring verbatim, including that the message names internal dimension
      // labels ("Gender", "Race") rather than the questions as worded. Deliberate here rather than
      // inherited: keeping one message shape across both steps is worth more than better copy on a
      // path that only fires when a student genuinely skipped a question, and full-time can only
      // ever name Gender or Race. Revisit with a student-facing label per dimension on
      // PreTestConfig if the fall run shows students getting stuck here.
      return {
        success: false,
        message: `Please complete the following question(s) before continuing: ${demographics.missing.join(", ")}.`,
      };
    }
    if (demographics.kind === "unmappable") {
      // Permanent until the pre-test or FALL_PRE_TEST is edited, so the generic bucket would be a
      // lie: it says "try again", and no number of retries can map a choice this config lacks. The
      // most likely instance is a gender option the fall pre-test added, which would otherwise
      // dead-end every student who picks it behind an invitation to keep clicking.
      return { success: false, message: TELL_TEACHER_MESSAGE };
    }
    return { success: false, message: STUDENT_FAILURE_MESSAGE };
  }
  const { Gender, Race, Grade, Module } = demographics.categories;

  // readDemographics fills only the dimensions it was asked for, so absence here means the
  // dimension set and the table this branch consults have gone out of step. Named rather than
  // interpolated, because "undefined" reaching a stratum key would be diagnosed only by the
  // resulting lookup miss, and a persisted key containing it would outlive the run.
  const unresolved = dimensions.filter(dimension => !demographics.categories[dimension]);
  if (unresolved.length > 0) {
    functions.logger.error(
      `fall-random-assignment: ${program} resolved no category for ${unresolved.join(", ")} for ${jobPath}`,
    );
    return { success: false, message: TELL_TEACHER_MESSAGE };
  }

  let stratumKey: string;
  let n1Assignment: Arm;
  if (isFullTime) {
    const surname = teacherSurnameFromClassWord(originClassWord);
    const stratum = findFullTimeStratum(Gender!, Race!, surname);
    if (!stratum) {
      // The surname is what diagnoses the fault, and it is safe to log for the same reasons as the
      // class word. The teacher's FULL name never reaches a log or a StepResult.
      functions.logger.error(
        `fall-random-assignment: no full-time stratum for ${Gender}|${Race} for ${jobPath}`,
        { teacher_surname: surname, origin_class_word: originClassWord },
      );
      return { success: false, message: TELL_TEACHER_MESSAGE };
    }
    stratumKey = fullTimeStratumKey(stratum);
    n1Assignment = stratum.n1;
  } else {
    stratumKey = `${Gender}|${Race}|${Grade}|${Module}`;
    const flexN1 = GENDER_RACE_GRADE_MODULE_TABLE[stratumKey];
    if (!flexN1) {
      // Unreachable from data: the 24 rows are exactly the cross product of what the category
      // mapping can emit. Reaching it means the category maps or FLEX_DIMENSIONS were changed and
      // this table was not, which is permanent, so tell-your-teacher rather than the retry message.
      functions.logger.error(
        `fall-random-assignment: no matching flex stratum for ${stratumKey} for user ${platform_user_id} at ${jobPath}`,
      );
      return { success: false, message: TELL_TEACHER_MESSAGE };
    }
    n1Assignment = flexN1;
  }

  // Full-time keeps the SHIPPED per-class key, which is what delivers "randomize within teacher".
  // Flex pools across all three sections, which the PI confirmed is one group.
  const scope = isFullTime
    ? perClassScope(String(interactiveId), String(platform_id), String(resource_link_id), String(context_id))
    : pooledProgramScope(program, String(interactiveId), String(platform_id));

  try {
    const assignment = await getAlternatingAssignment(
      String(source_key), scope, String(platform_user_id), stratumKey, n1Assignment,
    );
    // ⚠️ The DESTINATION is not sticky: it is re-derived from whatever origin class word this run
    // resolved. A student whose origin class changes between two clicks gets the new section's or
    // teacher's destination word, so if the first click's enrolment had already succeeded they end
    // up in two destination classes. Not persisted alongside the arm on purpose: that would make a
    // legitimate class change unfollowable.
    //
    // ⚠️ Whether the ARM is sticky across that move depends on the SCOPE, and the two programs
    // differ:
    //   - FLEX pools across sections, so a section move reads the same document, the walk finds the
    //     student, and both destinations are in the same arm. Roster tidiness, not data integrity.
    //   - FULL-TIME keeps the per-class key, which includes resource_link_id and context_id. A move
    //     between two full-time classes changes both, so the walk reads a DIFFERENT document, does
    //     not find the student, and assigns them afresh from the new teacher's counters. That can
    //     be the opposite arm, leaving them enrolled in one teacher's -gator class and another's
    //     -shark class: cross-arm contamination, which is exactly what the walk exists to prevent.
    // Reachability is low but real: it needs a roster move between full-time classes plus a
    // re-completion of the Green pre-test, and the re-completion is plausible because the answers
    // query filters on resource_link_id and context_id (so the student has no answers in the new
    // offering) and the lock step locks per offering (so the new offering is unlocked). Closing it
    // needs a program-wide student->arm index, which this story declined; a mid-study move between
    // full-time classes is therefore an operational item needing the prior assignment inspected,
    // not just a roster edit.
    const destinationClassWord = `${originClassWord}${DESTINATION_SUFFIX[assignment]}`;
    functions.logger.info(
      `fall-random-assignment: ${program} student assigned to ${destinationClassWord} (${jobPath})`,
    );
    return {
      success: true,
      summary: `Assigned to ${destinationClassWord}`,
      output: { destinationClassWord },
    };
  } catch (error) {
    functions.logger.error(`fall-random-assignment: assignment transaction failed for ${jobPath}`, error);
    return { success: false, message: STUDENT_FAILURE_MESSAGE };
  }
};
