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
