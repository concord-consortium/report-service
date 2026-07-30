import { PreTestConfig } from "./demographics";

/**
 * The spring-2026 pre-test's wording. Neither these prompts nor these choice labels change when
 * the fall pre-test's object is added beside this one.
 */
export const SPRING_PRE_TEST: PreTestConfig = {
  label: "spring-2026 Green pre-test",
  prompts: {
    Gender: "your sex",
    Grade: "grade are you in",
    Module: "Algebra 1 module",
    Race: "race or ethnicity",
  },
  genderMap: { "Female": "Female", "Male": "Male", "Prefer not to answer": "Female" },
  gradeMap: {
    "9th Grade": "High", "10th Grade": "High", "11th Grade": "High", "12th Grade": "High",
    "6th Grade": "Mid", "7th Grade": "Mid", "8th Grade": "Mid", "Other": "Mid",
  },
  moduleLabels: {
    Mod1: "Module 1: One-Variable Equations and Inequalities",
    Mod2: "Module 2: Two-Variable Linear Functions",
  },
  raceWhiteLabel: "White",
};

/**
 * The fall Green pre-test's wording.
 *
 * ✅ Identical to spring's prompts and choice labels, CONFIRMED BY THE PI (Trudi, 2026-07-29,
 * Slack): "Yes, they are the same". Recorded with the date and attribution so a reader knows this
 * was verified rather than assumed, and pinned by a test that fails if the two diverge, so whoever
 * changes this has to update this comment in the same edit. Her one refinement, that "Other/not
 * sure" may be grouped with a Module 4 option, is already the behaviour here: the Module mapping
 * matches only the two full titles and everything else falls to "Other".
 *
 * A separate object from SPRING_PRE_TEST on purpose, not an alias: one shared Green pre-test serves
 * both fall programs, so a late correction to the fall wording must be a one-object edit that
 * cannot reach spring.
 */
export const FALL_PRE_TEST: PreTestConfig = {
  label: "fall-2026 Green pre-test",
  prompts: {
    Gender: "your sex",
    Grade: "grade are you in",
    Module: "Algebra 1 module",
    Race: "race or ethnicity",
  },
  genderMap: { "Female": "Female", "Male": "Male", "Prefer not to answer": "Female" },
  gradeMap: {
    "9th Grade": "High", "10th Grade": "High", "11th Grade": "High", "12th Grade": "High",
    "6th Grade": "Mid", "7th Grade": "Mid", "8th Grade": "Mid", "Other": "Mid",
  },
  moduleLabels: {
    Mod1: "Module 1: One-Variable Equations and Inequalities",
    Mod2: "Module 2: Two-Variable Linear Functions",
  },
  raceWhiteLabel: "White",
};
