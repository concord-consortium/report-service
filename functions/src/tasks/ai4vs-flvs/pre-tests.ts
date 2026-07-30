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
