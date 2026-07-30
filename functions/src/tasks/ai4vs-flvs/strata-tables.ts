import { Arm } from "./assignment-doc";

/**
 * The Gender x Race x Grade x Module table, all 24 strata. The value is the arm the FIRST student
 * in each stratum receives; the second gets the opposite, alternating from there.
 *
 * Shared by the spring step and the fall flex program because they are the same 24 strata from the
 * same source document, verified 2026-07-29 against the PI's document row by row.
 *
 * Key format: "Gender|Race|Grade|Module".
 */
export const GENDER_RACE_GRADE_MODULE_TABLE: Record<string, Arm> = {
  "Female|White|High|Mod2": "treatment",
  "Male|non-White|High|Mod2": "control",
  "Male|White|Mid|Mod2": "treatment",
  "Female|White|High|Mod1": "control",
  "Female|White|Mid|Mod1": "treatment",
  "Female|non-White|High|Mod1": "control",
  "Male|White|High|Mod2": "treatment",
  "Female|White|Mid|Other": "control",
  "Male|non-White|High|Mod1": "treatment",
  "Female|White|Mid|Mod2": "control",
  "Female|non-White|High|Mod2": "treatment",
  "Female|White|High|Other": "control",
  "Female|non-White|High|Other": "treatment",
  "Male|White|High|Other": "control",
  "Female|non-White|Mid|Mod2": "treatment",
  "Male|non-White|High|Other": "control",
  "Male|White|Mid|Other": "treatment",
  "Male|non-White|Mid|Other": "control",
  "Female|non-White|Mid|Other": "treatment",
  "Male|non-White|Mid|Mod2": "control",
  "Male|White|Mid|Mod1": "treatment",
  "Male|White|High|Mod1": "control",
  "Female|non-White|Mid|Mod1": "treatment",
  "Male|non-White|Mid|Mod1": "control",
};

/**
 * One row of the full-time Gender x Race x Teacher table: four strata per teacher across five
 * teachers.
 */
export interface FullTimeStratum {
  gender: "Female" | "Male";
  race: "White" | "non-White";
  /**
   * The stratum key component, and the surname as it appears in the origin class word
   * (FT-2026-<surname>). Keyed on the surname rather than the whole class word because the design
   * randomizes WITHIN TEACHER, not within class: those coincide today (five classes, one teacher
   * each), but a second section for one teacher must stay one pool.
   */
  surname: string;
  /**
   * The PI's full teacher name, carried as a field so the row is self-documenting and this
   * transcription stays checkable against her source document.
   *
   * Never logged, never placed in a StepResult and never written to the assignment document, for
   * the simple reason that nothing needs it: the stratum key, the lookup and the class word all
   * carry the surname alone.
   */
  teacherFullName: string;
  /** The arm the FIRST student in this stratum receives. */
  n1: Arm;
}

/**
 * Transcribed 2026-07-29 from the PI's randomization document, IN THE SOURCE DOCUMENT'S ROW ORDER,
 * which the alternation properties depend on.
 *
 * ⚠️ The teacher dimension stays in the stratum key even though it looks redundant for balancing.
 * Two mechanisms are at work and must not be merged. Within-teacher BALANCING comes from the
 * assignment document being per class (only four of these strata can occur inside one class, so
 * those students already alternate among themselves). What the teacher column does is set each
 * teacher's STARTING arm, which spreads the leading edge of every stratum across classes. Remove
 * the teacher dimension and within-class balance is intact and every test still passes, while the
 * seed alternation is silently destroyed. With five teachers, an odd number, the seed REDUCES the
 * per-cell tilt rather than cancelling it: White cells seed 3:2 and non-White cells 2:3, offsetting
 * across cells for 10:10 overall. That is the PI's design, not a defect to fix here.
 */
export const FULL_TIME_TABLE: FullTimeStratum[] = [
  { gender: "Female", race: "White",     surname: "Bingler", teacherFullName: "Alyssa Bingler",  n1: "treatment" },
  { gender: "Male",   race: "non-White", surname: "Bingler", teacherFullName: "Alyssa Bingler",  n1: "control" },
  { gender: "Male",   race: "White",     surname: "Bingler", teacherFullName: "Alyssa Bingler",  n1: "treatment" },
  { gender: "Female", race: "non-White", surname: "Bingler", teacherFullName: "Alyssa Bingler",  n1: "control" },
  { gender: "Female", race: "White",     surname: "Hankamp", teacherFullName: "Kayla Hankamp",   n1: "control" },
  { gender: "Male",   race: "non-White", surname: "Hankamp", teacherFullName: "Kayla Hankamp",   n1: "treatment" },
  { gender: "Male",   race: "White",     surname: "Hankamp", teacherFullName: "Kayla Hankamp",   n1: "control" },
  { gender: "Female", race: "non-White", surname: "Hankamp", teacherFullName: "Kayla Hankamp",   n1: "treatment" },
  { gender: "Female", race: "White",     surname: "Long",    teacherFullName: "Kristi Long",     n1: "treatment" },
  { gender: "Male",   race: "non-White", surname: "Long",    teacherFullName: "Kristi Long",     n1: "control" },
  { gender: "Male",   race: "White",     surname: "Long",    teacherFullName: "Kristi Long",     n1: "treatment" },
  { gender: "Female", race: "non-White", surname: "Long",    teacherFullName: "Kristi Long",     n1: "control" },
  { gender: "Female", race: "White",     surname: "Newlon",  teacherFullName: "Courtney Newlon", n1: "control" },
  { gender: "Male",   race: "non-White", surname: "Newlon",  teacherFullName: "Courtney Newlon", n1: "treatment" },
  { gender: "Male",   race: "White",     surname: "Newlon",  teacherFullName: "Courtney Newlon", n1: "control" },
  { gender: "Female", race: "non-White", surname: "Newlon",  teacherFullName: "Courtney Newlon", n1: "treatment" },
  { gender: "Female", race: "White",     surname: "Torres",  teacherFullName: "Maria Torres",    n1: "treatment" },
  { gender: "Male",   race: "non-White", surname: "Torres",  teacherFullName: "Maria Torres",    n1: "control" },
  { gender: "Male",   race: "White",     surname: "Torres",  teacherFullName: "Maria Torres",    n1: "treatment" },
  { gender: "Female", race: "non-White", surname: "Torres",  teacherFullName: "Maria Torres",    n1: "control" },
];

/**
 * The PERSISTED stratum key, built entirely from the matched row ("Female|White|Bingler"), never
 * from the caller's input. It is a Firestore document key that outlives any run, so it must not
 * vary with how the portal happens to case a class word, and it cannot describe a row other than
 * the one that was matched.
 */
export const fullTimeStratumKey = (stratum: FullTimeStratum): string =>
  `${stratum.gender}|${stratum.race}|${stratum.surname}`;

// The LOOKUP is keyed on the lowercased surname, because the class word arrives in the portal's
// stored (lowercased) form while the rows carry the readable "Bingler" for review against the PI's
// document. Two different jobs: display casing in the table, match casing in the index.
const FULL_TIME_BY_KEY = new Map(
  FULL_TIME_TABLE.map(row => [`${row.gender}|${row.race}|${row.surname.toLowerCase()}`, row]),
);

/** `surname` is expected lowercase, as derived from the normalized class word. */
export const findFullTimeStratum = (
  gender: string,
  race: string,
  surname: string,
): FullTimeStratum | undefined => FULL_TIME_BY_KEY.get(`${gender}|${race}|${surname.toLowerCase()}`);
