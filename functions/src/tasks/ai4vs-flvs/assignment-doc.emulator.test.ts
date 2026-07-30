import { db, clearFirestore } from "../../test/emulator-setup";
import { getAlternatingAssignment, perClassScope, pooledProgramScope } from "./assignment-doc";

/**
 * Why this file exists rather than another mocked case: the unit suite mocks `runTransaction`
 * wholesale, so a mocked test can assert only that the walk was WRITTEN as intended, never that it
 * behaves correctly inside a real transaction. Two properties are only observable here: that the
 * early-return path commits at all as a read-only transaction, and that it leaves the other
 * stratum's counter unadvanced in the persisted document.
 *
 * This imports real production code with no mocks, which is possible only because assignment-doc.ts
 * imports nothing but crypto and firebase-admin. See that module's import-constraint comment.
 */

const SOURCE = "assignment-doc-emulator";

const readDoc = async (docId: string) =>
  (await db.doc(`sources/${SOURCE}/jobs-task-data/${docId}`).get()).data() as any;

beforeEach(async () => {
  await clearFirestore();
});

it("returns the original arm when the stratum changes, and does not create the new stratum", async () => {
  const scope = perClassScope("i1", "p1", "off-1", "ctx-1");

  expect(await getAlternatingAssignment(SOURCE, scope, "user-1", "Female|White|High|Mod1", "treatment"))
    .toBe("treatment");
  expect(await getAlternatingAssignment(SOURCE, scope, "user-1", "Female|White|High|Mod2", "control"))
    .toBe("treatment");

  const data = await readDoc(scope.docId);
  expect(Object.keys(data.strata)).toEqual(["Female|White|High|Mod1"]);
  expect(data.strata["Female|White|High|Mod1"].users).toEqual({ "user-1": "treatment" });
});

it("leaves an already-advanced counter untouched, and the next new student still gets its arm", async () => {
  const scope = perClassScope("i1", "p1", "off-1", "ctx-1");
  await getAlternatingAssignment(SOURCE, scope, "user-1", "S1", "treatment");
  await getAlternatingAssignment(SOURCE, scope, "user-2", "S2", "treatment");
  expect((await readDoc(scope.docId)).strata.S2.nextAssignment).toBe("control");

  // user-1 re-clicks having moved into S2. The walk must not consume S2's rotation slot.
  expect(await getAlternatingAssignment(SOURCE, scope, "user-1", "S2", "treatment")).toBe("treatment");

  const after = await readDoc(scope.docId);
  expect(after.strata.S2.nextAssignment).toBe("control");
  expect(after.strata.S2.users).toEqual({ "user-2": "treatment" });
  expect(await getAlternatingAssignment(SOURCE, scope, "user-3", "S2", "treatment")).toBe("control");
});

it("commits the early-return path as a read-only transaction, leaving the document unchanged", async () => {
  const scope = perClassScope("i1", "p1", "off-1", "ctx-1");
  await getAlternatingAssignment(SOURCE, scope, "user-1", "S1", "treatment");
  const before = await readDoc(scope.docId);

  await getAlternatingAssignment(SOURCE, scope, "user-1", "S1", "treatment");

  expect(await readDoc(scope.docId)).toEqual(before);
});

// The three flex sections, as the step sees them: three offerings, three classes, ONE program.
const FLEX_SECTIONS = [["off-1", "ctx-1"], ["off-2", "ctx-2"], ["off-3", "ctx-3"]];

it("pools the three sections into one document, so students in different sections alternate", async () => {
  // The pooled scope deliberately takes NO section input, so the collapse is shown by contrast
  // rather than by feeding the pairs in: the same three sections yield three distinct per-class
  // documents and one pooled document. That contrast, plus three students below, is what
  // "different sections" means here.
  const perClass = FLEX_SECTIONS.map(([o, c]) => perClassScope("green", "p1", o, c));
  const scopes = FLEX_SECTIONS.map(() => pooledProgramScope("fall-2026-flex", "green", "p1"));
  expect(new Set(scopes.map(s => s.docId)).size).toBe(1);
  expect(new Set(perClass.map(s => s.docId)).size).toBe(3);

  // One student per section, identical demographics, arriving in section order.
  expect(await getAlternatingAssignment(SOURCE, scopes[0], "flex-s1", "Female|White|High|Mod1", "treatment"))
    .toBe("treatment");
  expect(await getAlternatingAssignment(SOURCE, scopes[1], "flex-s2", "Female|White|High|Mod1", "treatment"))
    .toBe("control");
  expect(await getAlternatingAssignment(SOURCE, scopes[2], "flex-s3", "Female|White|High|Mod1", "treatment"))
    .toBe("treatment");

  // All three landed in ONE document, which is what "one group across all three sections" means.
  const data = await readDoc(scopes[0].docId);
  expect(Object.keys(data.strata["Female|White|High|Mod1"].users)).toHaveLength(3);
});

it("keeps within-section alternation intact under pooling", async () => {
  const scope = pooledProgramScope("fall-2026-flex", "green", "p1");

  expect(await getAlternatingAssignment(SOURCE, scope, "flex-a", "Female|White|High|Mod1", "treatment"))
    .toBe("treatment");
  expect(await getAlternatingAssignment(SOURCE, scope, "flex-b", "Female|White|High|Mod1", "treatment"))
    .toBe("control");
});

it("keeps full-time classes separate: each teacher's cell starts on its own seed", async () => {
  const bingler = perClassScope("green", "p1", "off-b", "ctx-b");
  const hankamp = perClassScope("green", "p1", "off-h", "ctx-h");

  expect(await getAlternatingAssignment(SOURCE, bingler, "ft-a", "Female|White|Bingler", "treatment"))
    .toBe("treatment");
  expect(await getAlternatingAssignment(SOURCE, hankamp, "ft-b", "Female|White|Hankamp", "control"))
    .toBe("control");
  expect(await getAlternatingAssignment(SOURCE, bingler, "ft-c", "Female|White|Bingler", "treatment"))
    .toBe("control");
});

it("walks a full 24-stratum document", async () => {
  const scope = perClassScope("i1", "p1", "off-1", "ctx-1");
  for (let n = 0; n < 24; n++) {
    await getAlternatingAssignment(SOURCE, scope, `user-${n}`, `S${n}`, "treatment");
  }
  expect(Object.keys((await readDoc(scope.docId)).strata)).toHaveLength(24);

  // The student seeded in the LAST stratum is still found when they re-click under the first.
  expect(await getAlternatingAssignment(SOURCE, scope, "user-23", "S0", "control")).toBe("treatment");
});
