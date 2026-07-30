import { Dimension } from "./demographics";

/**
 * The two fall programs. Resolved at run time from the student's origin class word, never authored:
 * a single shared Green pre-test button serves both cohorts, so there is no request parameter that
 * could distinguish them.
 *
 * ⚠️ These strings are DATA, not labels. FLEX_PROGRAM is hashed into the pooled assignment document
 * id (pooledProgramScope), so once one flex student holds an arm, changing it re-keys the document:
 * every assigned student is treated as new, counters restart from n1, and students can be assigned
 * a second, opposite arm while still enrolled in the first class. A test pins the resulting document
 * id so a rename fails loudly. Renaming is a data migration, not a refactor.
 *
 * ⚠️ They carry the YEAR deliberately. The per-class scope re-keys itself for a new cohort, because
 * it includes the offering and the class, but the pooled key is built from interactiveId,
 * platform_id and this string, all three of which survive a new cohort on the same authored activity
 * (interactiveId is the embeddable's ref_id, a property of the ACTIVITY). Without the year, a later
 * flex cohort would silently continue fall-2026's alternation counters and accumulate in its
 * document.
 */
export const FULL_TIME_PROGRAM = "fall-2026-full-time";
export const FLEX_PROGRAM = "fall-2026-flex";
export type FallProgramId = typeof FULL_TIME_PROGRAM | typeof FLEX_PROGRAM;

// ⚠️ LOWERCASE, and that is not a style choice. The portal stores every class word lowercased
// (Portal::Clazz downcases before validation) and offerings#show serves the stored value, so the
// spreadsheet's "FT-2026-Bingler" reaches us as "ft-2026-bingler". resolve-origin-class normalizes
// to that stored form, and these prefixes match it exactly. The mixed-case prefixes fail against
// all eight of the study's class words.
const FULL_TIME_PREFIX = "ft-";
const FLEX_PREFIX = "fl-";

/**
 * Classify the origin class word's prefix. Expects the normalized (lowercased, trimmed) word that
 * resolve-origin-class publishes.
 *
 * `undefined` is a CLASSIFIED FAILURE for the caller, never a default to either program: defaulting
 * would randomize the student from the wrong table and corrupt the study arm they land in.
 */
export const classifyFallProgram = (originClassWord: string): FallProgramId | undefined => {
  if (originClassWord.startsWith(FULL_TIME_PREFIX)) {
    return FULL_TIME_PROGRAM;
  }
  if (originClassWord.startsWith(FLEX_PREFIX)) {
    return FLEX_PROGRAM;
  }
  return undefined;
};

/**
 * Full-time reads Gender and Race ONLY; the teacher comes from the class word, not from an answer.
 * A full-time student who skipped the flex-only questions must still randomize successfully.
 */
export const FULL_TIME_DIMENSIONS: readonly Dimension[] = ["Gender", "Race"];
export const FLEX_DIMENSIONS: readonly Dimension[] = ["Gender", "Grade", "Module", "Race"];

/**
 * ft-2026-bingler -> bingler. The last hyphen segment of the normalized origin class word, so the
 * result is lowercase and findFullTimeStratum keys on the same form.
 *
 * ⚠️ This encodes an assumption about the class-word format: `<prefix>-<year>-<surname>`, with a
 * surname that is a SINGLE hyphen-free token. It holds for all five study words (bingler, hankamp,
 * long, newlon, torres) and all three flex words. It would mis-derive a hyphenated surname:
 * `ft-2026-van-dyke` yields `dyke`, not `van-dyke`, and the five-distinct-surnames guard does NOT
 * catch that. If the roster ever gains such a teacher, match the word's trailing text against the
 * table's known surnames instead of splitting on a hyphen.
 */
export const teacherSurnameFromClassWord = (originClassWord: string): string =>
  originClassWord.slice(originClassWord.lastIndexOf("-") + 1).trim();
