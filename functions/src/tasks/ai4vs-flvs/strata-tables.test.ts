import { Arm } from "./assignment-doc";
import {
  FULL_TIME_TABLE, GENDER_RACE_GRADE_MODULE_TABLE, findFullTimeStratum, fullTimeStratumKey,
} from "./strata-tables";

const SURNAMES = ["Bingler", "Hankamp", "Long", "Newlon", "Torres"];

describe("the full-time Gender x Race x Teacher table", () => {
  /**
   * All twenty values, in the source document's row order, so a single mistyped cell is caught
   * wherever it sits.
   */
  const EXPECTED_N1: Array<[string, string, string, Arm]> = [
    ["Female", "White",     "Bingler", "treatment"],
    ["Male",   "non-White", "Bingler", "control"],
    ["Male",   "White",     "Bingler", "treatment"],
    ["Female", "non-White", "Bingler", "control"],
    ["Female", "White",     "Hankamp", "control"],
    ["Male",   "non-White", "Hankamp", "treatment"],
    ["Male",   "White",     "Hankamp", "control"],
    ["Female", "non-White", "Hankamp", "treatment"],
    ["Female", "White",     "Long",    "treatment"],
    ["Male",   "non-White", "Long",    "control"],
    ["Male",   "White",     "Long",    "treatment"],
    ["Female", "non-White", "Long",    "control"],
    ["Female", "White",     "Newlon",  "control"],
    ["Male",   "non-White", "Newlon",  "treatment"],
    ["Male",   "White",     "Newlon",  "control"],
    ["Female", "non-White", "Newlon",  "treatment"],
    ["Female", "White",     "Torres",  "treatment"],
    ["Male",   "non-White", "Torres",  "control"],
    ["Male",   "White",     "Torres",  "treatment"],
    ["Female", "non-White", "Torres",  "control"],
  ];

  it.each(EXPECTED_N1)("stratum %s|%s|%s starts on %s", (gender, race, surname, n1) => {
    expect(findFullTimeStratum(gender, race, surname)?.n1).toBe(n1);
  });

  it("has 20 rows with 20 unique stratum keys", () => {
    expect(FULL_TIME_TABLE).toHaveLength(20);

    const keys = FULL_TIME_TABLE.map(row => fullTimeStratumKey(row));
    expect(new Set(keys).size).toBe(20);
  });

  it("gives each teacher four distinct Gender x Race cells", () => {
    for (const surname of SURNAMES) {
      const block = FULL_TIME_TABLE.filter(row => row.surname === surname);
      expect(block).toHaveLength(4);
      expect(new Set(block.map(row => `${row.gender}|${row.race}`)).size).toBe(4);
    }
  });

  it("starts each teacher's block on the source document's alternating seed", () => {
    const starts = SURNAMES.map(surname => FULL_TIME_TABLE.find(row => row.surname === surname)!.n1);

    expect(starts).toEqual(["treatment", "control", "treatment", "control", "treatment"]);
  });

  it("alternates within each teacher's block, and is NOT one continuous 20-row alternation", () => {
    for (const surname of SURNAMES) {
      const block = FULL_TIME_TABLE.filter(row => row.surname === surname);
      block.forEach((row, i) => {
        if (i > 0) {
          expect(row.n1).not.toBe(block[i - 1].n1);
        }
      });
    }

    // EVERY block boundary repeats, which is what makes this five blocks and not one 20-row
    // sequence. All four are asserted: 4/5, 8/9, 12/13 and 16/17.
    for (let i = 3; i < 19; i += 4) {
      expect(FULL_TIME_TABLE[i].n1).toBe(FULL_TIME_TABLE[i + 1].n1);
    }
  });

  it("splits 10 treatment to 10 control", () => {
    const treatment = FULL_TIME_TABLE.filter(row => row.n1 === "treatment");

    expect(treatment).toHaveLength(10);
    expect(FULL_TIME_TABLE.filter(row => row.n1 === "control")).toHaveLength(10);
  });

  /**
   * The guard for the one way surname keying can fail: two study teachers sharing a surname. It is
   * impossible among the current five, and this catches a future roster change that introduces it.
   * Asserting the two COUNTS ARE EQUAL is the real guard, because a sixth teacher sharing a surname
   * with an existing one leaves five distinct surnames but six distinct full names. The literal 5
   * is asserted as well, so a roster change is a deliberate edit here rather than a silent
   * widening.
   */
  it("maps surnames to teachers one-to-one", () => {
    const surnames = new Set(FULL_TIME_TABLE.map(row => row.surname));
    const fullNames = new Set(FULL_TIME_TABLE.map(row => row.teacherFullName));

    expect(surnames.size).toBe(fullNames.size);
    expect(surnames.size).toBe(5);
  });

  it("carries the PI's full teacher name on every row, ending in the row's surname", () => {
    for (const row of FULL_TIME_TABLE) {
      expect(row.teacherFullName.split(/\s+/).pop()).toBe(row.surname);
    }
  });
});

describe("findFullTimeStratum", () => {
  it("matches a surname derived from the portal's lowercased class word", () => {
    const stratum = findFullTimeStratum("Female", "White", "bingler");

    expect(stratum?.teacherFullName).toBe("Alyssa Bingler");
    expect(stratum?.n1).toBe("treatment");
  });

  it("returns undefined for a surname absent from the table", () => {
    expect(findFullTimeStratum("Female", "White", "nobody")).toBeUndefined();
  });

  it("returns undefined for a Gender outside the table's two categories", () => {
    expect(findFullTimeStratum("Nonbinary", "White", "bingler")).toBeUndefined();
  });

  it("matches Gender and Race exactly, unlike the surname, which is case-folded", () => {
    // The categories come from mapToCategory, which emits them verbatim, so nothing normalizes
    // them here. Only the surname arrives from outside, via the class word.
    expect(findFullTimeStratum("female", "White", "bingler")).toBeUndefined();
    expect(findFullTimeStratum("Female", "White", "BINGLER")?.surname).toBe("Bingler");
  });
});

describe("fullTimeStratumKey", () => {
  it("keys on the matched row's canonical values, not on the caller's input", () => {
    const stratum = findFullTimeStratum("Female", "White", "BINGLER")!;

    expect(fullTimeStratumKey(stratum)).toBe("Female|White|Bingler");
  });
});

describe("the flex Gender x Race x Grade x Module table", () => {
  /**
   * Additive, not moved. random-assignment.test.ts keeps its end-to-end it.each over the same 24
   * strata, which drives randomAssignment from seeded answer docs and asserts the resulting class
   * name. That is the test proving a stratum RESOLVES; this one pins the table's literal contents
   * so a mistyped cell is caught where it sits, the same division of labour the 20-row table gets.
   */
  const EXPECTED_FLEX: Array<[string, Arm]> = [
    ["Female|White|High|Mod2", "treatment"],
    ["Male|non-White|High|Mod2", "control"],
    ["Male|White|Mid|Mod2", "treatment"],
    ["Female|White|High|Mod1", "control"],
    ["Female|White|Mid|Mod1", "treatment"],
    ["Female|non-White|High|Mod1", "control"],
    ["Male|White|High|Mod2", "treatment"],
    ["Female|White|Mid|Other", "control"],
    ["Male|non-White|High|Mod1", "treatment"],
    ["Female|White|Mid|Mod2", "control"],
    ["Female|non-White|High|Mod2", "treatment"],
    ["Female|White|High|Other", "control"],
    ["Female|non-White|High|Other", "treatment"],
    ["Male|White|High|Other", "control"],
    ["Female|non-White|Mid|Mod2", "treatment"],
    ["Male|non-White|High|Other", "control"],
    ["Male|White|Mid|Other", "treatment"],
    ["Male|non-White|Mid|Other", "control"],
    ["Female|non-White|Mid|Other", "treatment"],
    ["Male|non-White|Mid|Mod2", "control"],
    ["Male|White|Mid|Mod1", "treatment"],
    ["Male|White|High|Mod1", "control"],
    ["Female|non-White|Mid|Mod1", "treatment"],
    ["Male|non-White|Mid|Mod1", "control"],
  ];

  it.each(EXPECTED_FLEX)("stratum %s starts on %s", (key, n1) => {
    expect(GENDER_RACE_GRADE_MODULE_TABLE[key]).toBe(n1);
  });

  it("holds exactly the 24 strata the category mappings can emit", () => {
    const expected = new Set<string>();
    for (const gender of ["Female", "Male"]) {
      for (const race of ["White", "non-White"]) {
        for (const grade of ["High", "Mid"]) {
          for (const module of ["Mod1", "Mod2", "Other"]) {
            expected.add(`${gender}|${race}|${grade}|${module}`);
          }
        }
      }
    }

    expect(new Set(Object.keys(GENDER_RACE_GRADE_MODULE_TABLE))).toEqual(expected);
  });

  it("splits 12 treatment to 12 control", () => {
    const arms = Object.values(GENDER_RACE_GRADE_MODULE_TABLE);

    expect(arms.filter(arm => arm === "treatment")).toHaveLength(12);
    expect(arms.filter(arm => arm === "control")).toHaveLength(12);
  });
});
