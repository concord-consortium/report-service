import { FALL_PRE_TEST, SPRING_PRE_TEST } from "./pre-tests";

/**
 * ⚠️ This test is EXPECTED to be deleted or amended one day. If the fall wording legitimately
 * diverges, update FALL_PRE_TEST, update its attribution comment to say what changed and on whose
 * word, and then remove this. It exists so those two edits cannot be separated.
 */
it("keeps the fall pre-test wording identical to spring's (PI-confirmed 2026-07-29)", () => {
  const { label: springLabel, ...spring } = SPRING_PRE_TEST;
  const { label: fallLabel, ...fall } = FALL_PRE_TEST;

  expect(fall).toEqual(spring);
  // The labels are deliberately different; they identify the pre-test in log lines.
  expect(fallLabel).not.toBe(springLabel);
});
