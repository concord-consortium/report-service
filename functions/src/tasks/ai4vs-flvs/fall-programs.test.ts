import { computePooledAssignmentDocId } from "./assignment-doc";
import { findFullTimeStratum } from "./strata-tables";
import {
  FLEX_DIMENSIONS, FLEX_PROGRAM, FULL_TIME_DIMENSIONS, FULL_TIME_PROGRAM,
  classifyFallProgram, teacherSurnameFromClassWord,
} from "./fall-programs";

/** The study's real class words, as the portal stores them. */
const FULL_TIME_WORDS = [
  "ft-2026-bingler", "ft-2026-hankamp", "ft-2026-long", "ft-2026-newlon", "ft-2026-torres",
];
const FLEX_WORDS = ["fl-2026-section1", "fl-2026-section2", "fl-2026-section3"];

describe("the program ids", () => {
  /**
   * Pinned as literals because FLEX_PROGRAM is hashed into the pooled assignment document id, so a
   * rename silently re-keys every live flex assignment. Together with the pooled-key pin in
   * assignment-doc.test.ts this makes a rename two failing tests rather than a silent re-key.
   */
  it("are the year-qualified strings the pooled document id is built from", () => {
    expect(FULL_TIME_PROGRAM).toBe("fall-2026-full-time");
    expect(FLEX_PROGRAM).toBe("fall-2026-flex");
  });

  it("pins the pooled flex document id for known inputs", () => {
    expect(computePooledAssignmentDocId(FLEX_PROGRAM, "green", "https://learn.concord.org"))
      .toBe("1fb143d459b7463abfaf385e9c27cedfabfada26c226ef5e13b9dccc0e34b459");
  });
});

describe("classifyFallProgram", () => {
  it.each(FULL_TIME_WORDS)("classifies %s as full-time", (word) => {
    expect(classifyFallProgram(word)).toBe(FULL_TIME_PROGRAM);
  });

  it.each(FLEX_WORDS)("classifies %s as flex", (word) => {
    expect(classifyFallProgram(word)).toBe(FLEX_PROGRAM);
  });

  it("does not classify a word with neither prefix", () => {
    expect(classifyFallProgram("spring-2026-origin")).toBeUndefined();
    expect(classifyFallProgram("")).toBeUndefined();
  });

  /**
   * The prefixes are year-qualified, like the program ids they return. `fl-spring-2026-origin` is
   * the word the local harness actually carries, and it is what the negative case above reads as
   * covering but does not: that word has the `fl-` prefix, so a bare-prefix classifier would admit
   * a spring-era class into the pooled fall-2026-flex document.
   */
  it("does not classify a word from another cohort that shares the program prefix", () => {
    expect(classifyFallProgram("fl-spring-2026-origin")).toBeUndefined();
    expect(classifyFallProgram("ft-fall-2026-a")).toBeUndefined();
    expect(classifyFallProgram("fl-2027-section1")).toBeUndefined();
  });

  /**
   * The assertion that documents why resolve-origin-class normalizes rather than leaving each
   * consumer to cope: the spreadsheet's casing classifies as nothing at all.
   */
  it("does not classify the spreadsheet-cased form, which the portal never serves", () => {
    expect(classifyFallProgram("FT-2026-Bingler")).toBeUndefined();
    expect(classifyFallProgram("FL-2026-Section1")).toBeUndefined();
  });
});

describe("teacherSurnameFromClassWord", () => {
  it.each(FULL_TIME_WORDS)("takes the last hyphen segment of %s", (word) => {
    expect(word.endsWith(`-${teacherSurnameFromClassWord(word)}`)).toBe(true);
  });

  it("derives a surname that resolves to its table row", () => {
    const surname = teacherSurnameFromClassWord("ft-2026-bingler");

    expect(surname).toBe("bingler");
    expect(findFullTimeStratum("Female", "White", surname)?.teacherFullName).toBe("Alyssa Bingler");
  });

  it("resolves all five study class words to a table row", () => {
    for (const word of FULL_TIME_WORDS) {
      const surname = teacherSurnameFromClassWord(word);
      expect(findFullTimeStratum("Male", "non-White", surname)).toBeDefined();
    }
  });
});

describe("the dimension sets", () => {
  it("reads Gender and Race only for full-time, so the flex-only questions stay optional", () => {
    expect(FULL_TIME_DIMENSIONS).toEqual(["Gender", "Race"]);
  });

  it("reads all four for flex", () => {
    expect(FLEX_DIMENSIONS).toEqual(["Gender", "Grade", "Module", "Race"]);
  });
});
