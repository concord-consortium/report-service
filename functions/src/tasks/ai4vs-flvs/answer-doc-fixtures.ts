/**
 * Shared answer-document fixtures for the demographic tests.
 *
 * Deliberately not named *.test.ts / *.spec.ts, so jest's testRegex does not treat a fixture
 * module as a suite.
 */

/** Build a mock Firestore answer doc with the given prompt and selected choices. */
export const makeAnswerDoc = (
  prompt: string,
  choices: Array<{ id: string; content: string }>,
  selectedChoiceIds: string[],
) => ({
  data: () => ({
    report_state: JSON.stringify({
      authoredState: JSON.stringify({ prompt, choices }),
      interactiveState: JSON.stringify({ selectedChoiceIds }),
    }),
  }),
});

export interface AnswerDocOverrides {
  genderChoice?: string;
  gradeChoice?: string;
  moduleChoice?: string;
  raceChoices?: string[];
}

/**
 * Resolve an override label to its choice id, throwing at the FIXTURE rather than letting the
 * failure surface from inside readDemographics.
 *
 * A bare `map[label]` yields `undefined` for a misspelled override, which reaches production code
 * and reports `Choice ID "undefined" not found` — the code under test blamed for a caller's typo.
 * A `?? fallback` is the converse hazard, and worse: a misspelled Module label would silently
 * become the valid `Other/not sure` choice, so the test passes while testing something else.
 */
const choiceId = (dimension: string, map: Record<string, string>, label: string): string => {
  const id = map[label];
  if (!id) {
    throw new Error(
      `answer-doc-fixtures: unknown ${dimension} choice "${label}". Known: ${Object.keys(map).join(", ")}`,
    );
  }
  return id;
};

/** Standard demographic answer docs for a "happy path" student. */
export const makeStandardAnswerDocs = (overrides?: AnswerDocOverrides) => {
  const gender = overrides?.genderChoice ?? "Female";
  const grade = overrides?.gradeChoice ?? "10th Grade";
  const module = overrides?.moduleChoice ?? "Module 1: One-Variable Equations and Inequalities";
  const races = overrides?.raceChoices ?? ["White"];

  const genderIdMap: Record<string, string> = { Female: "c1", Male: "c2", "Prefer not to answer": "c3" };
  const gradeIdMap: Record<string, string> = {
    "6th Grade": "g6", "7th Grade": "g7", "8th Grade": "g8", "9th Grade": "g9",
    "10th Grade": "g10", "11th Grade": "g11", "12th Grade": "g12", "Other": "gO",
  };
  const moduleIdMap: Record<string, string> = {
    "Module 1: One-Variable Equations and Inequalities": "m1",
    "Module 2: Two-Variable Linear Functions": "m2",
    "Module 3: Systems of Two Linear Equations": "m3",
    "Other/not sure": "mO",
  };
  const raceIdMap: Record<string, string> = {
    White: "rW", "Black or African American": "rB",
    "Hispanic or Latino": "rH", "Prefer to not answer": "rP",
  };

  return {
    docs: [
      makeAnswerDoc(
        "<p>What is your sex?</p>",
        [
          { id: "c1", content: "Female" },
          { id: "c2", content: "Male" },
          { id: "c3", content: "Prefer not to answer" },
        ],
        [choiceId("Gender", genderIdMap, gender)],
      ),
      makeAnswerDoc(
        "<p>What grade are you in?</p>",
        [
          { id: "g6", content: "6th Grade" }, { id: "g7", content: "7th Grade" },
          { id: "g8", content: "8th Grade" }, { id: "g9", content: "9th Grade" },
          { id: "g10", content: "10th Grade" }, { id: "g11", content: "11th Grade" },
          { id: "g12", content: "12th Grade" }, { id: "gO", content: "Other" },
        ],
        [choiceId("Grade", gradeIdMap, grade)],
      ),
      makeAnswerDoc(
        "<p>Which Algebra 1 module are you currently working on?</p>",
        [
          { id: "m1", content: "Module 1: One-Variable Equations and Inequalities" },
          { id: "m2", content: "Module 2: Two-Variable Linear Functions" },
          { id: "m3", content: "Module 3: Systems of Two Linear Equations" },
          { id: "mO", content: "Other/not sure" },
        ],
        [choiceId("Module", moduleIdMap, module)],
      ),
      makeAnswerDoc(
        "<p>What is your race or ethnicity? (Select all that apply)</p>",
        [
          { id: "rW", content: "White" },
          { id: "rB", content: "Black or African American" },
          { id: "rH", content: "Hispanic or Latino" },
          { id: "rP", content: "Prefer to not answer" },
        ],
        races.map(r => choiceId("Race", raceIdMap, r)),
      ),
    ],
  };
};
