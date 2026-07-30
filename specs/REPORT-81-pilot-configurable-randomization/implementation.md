# Implementation Plan: Pilot-Configurable Randomization for the Fall Study

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-81

**Requirements Spec**: [requirements.md](requirements.md)

**Status**: **In Development**

## What was verified before this plan was written

Four assumptions were checked against running code rather than reasoned about, because each one
would have changed the module layout if it had come out the other way. All four are recorded here
with what was actually run, so a reviewer can tell a verified claim from an inferred one.

**1. The 20-row full-time transcription satisfies every property the acceptance criteria assert.**
A throwaway script drove the literal that appears in the "Add the two strata tables" step below
through all of them: 20 rows, 5 distinct surnames, 5 distinct full names, a surname-to-full-name
bijection, each surname equal to the last whitespace token of its full name, 4 distinct Gender x
Race cells per teacher, 20 unique stratum keys, 10 treatment and 10 control, per-block internal
alternation, block starts `treatment, control, treatment, control, treatment`, the 4/5 and 8/9
boundaries **not** alternating, and ER-5's per-cell seed tilt (`Female|White` and `Male|White` at
3:2, both non-White cells at 2:3). All passed. The literal in this plan is the literal that was
checked.

**2. The obvious pooled-key format collides with the per-class key.** The first format tried was
`ai4vs-flvs-assignments|pooled|<program>|<interactiveId>|<platform_id>`, on the reasoning that the
per-class key has a different segment count. It does not: both have five segments after the
namespace, so a per-class key whose `interactiveId` is `pooled` and whose `platform_id` is `flex`
hashes to exactly the same document id. The check caught it. The fix is a **separate namespace
prefix** rather than an extra segment, `ai4vs-flvs-assignments-pooled|...`, which differs from the
per-class prefix at the character right after `ai4vs-flvs-assignments` (`-` against `|`) for every
possible field value, so no collision is reachable at all. This is a contrived input rather than a
live risk, and that is the point: the segment-count argument was wrong, so the format that relied
on it is not the format to ship.

**3. The de-duplication walk behaves correctly inside a real transaction.** A throwaway
`*.emulator.test.ts` ran the proposed core against the Firestore emulator: a stratum change between
clicks returns the original arm and creates no second stratum; a re-click into a stratum whose
counter had already been advanced by another student leaves that counter untouched and the next
genuinely new student there still receives the arm it specified; a same-stratum re-click is
unchanged; three "sections" sharing a pooled scope alternate against each other; two full-time
classes on separate per-class scopes each start on their own seed; the early-return path commits as
a read-only transaction and leaves the document byte-identical; and a 24-stratum document is walked
successfully to find a student seeded in the last stratum. Seven tests, all passing.

**4. The shipped code really does double-assign, so the spring delta is measured rather than
assumed.** A second throwaway emulator test drove the **real, shipped** `getAlternatingAssignment`:
after `user-1` is assigned `treatment` under `Female|White|High|Mod1`, re-invoking with
`Female|White|High|Mod2` returns `control`, records the same student under both strata, and advances
Mod2's counter. That is SE-3's claim, now confirmed against a real transaction rather than a mock.

Both throwaway tests were deleted; the working tree is clean. Their content is folded into the real
tests in the steps below.

**Second verification round, 2026-07-29, after the self-review.** The three steps the first round had not
prototyped (the strata tables, `resolve-origin-class` and the fall step) were built as throwaways too, because
the two build-breaking findings from round one both came from compiling rather than reading. All three
typecheck under `strict` and their drafted tests pass: **5 new suites, 61 new tests, taking `jest src/tasks`
from 8 suites / 224 tests to 13 / 285.** Specifically confirmed: a full-time student assigns from Gender and
Race with **no Grade or Module answer documents present at all**; `ft-2026-bingler` reaches the row labelled
`Alyssa Bingler`; two teachers land on distinct per-class scopes with distinct seeds; three different
`(resource_link_id, context_id)` pairs collapse to one pooled scope; an unmapped gender choice yields
tell-your-teacher while a transport failure still yields the retry message; `portalTokenFetch` is never called;
and `readStepOutputField` skips absent and blank outputs and trims. `npm run lint` on all of it surfaced one
real defect in the drafted code, recorded as SE-I6. The harness fixture change was verified by running the
three `run-step` scenarios before and after it: 3/3 pass both ways. Everything was then deleted; the tree is
clean and the baseline is back to 224.

### The verification that dictated the module split

Getting finding 4 to run at all exposed a hard constraint that shapes this whole plan. Importing
today's `random-assignment.ts` into an emulator test fails **twice** over, for reasons unrelated to
the code under test:

- `firebase-functions` (imported for the logger) pulls in `firebase-admin/auth`, and jest 24's
  resolver cannot follow `firebase-admin`'s subpath exports: `Cannot find module
  'firebase-admin/auth' from 'identity.js'`.
- `firebase-client.ts` pulls in `firebase/auth`, which throws `ReferenceError: fetch is not
  defined` under this jest version's environment.

Neither chain is used by `getAlternatingAssignment`. The unit suite never notices because it mocks
both. So the emulator-backed criterion, which exists precisely because a mock cannot establish the
behaviour, can only be met by a module whose **entire** import chain is loadable without mocks.

That is why the assignment document gets its **own** module, `assignment-doc.ts`, importing nothing
but `crypto` and `firebase-admin`, rather than sharing one `random-assignment-core.ts` with the
demographic reading (which genuinely needs `firebase-functions` and `firebase-client`). The split is
not aesthetic tidiness: it is what makes the story's one load-bearing test able to import real
production code with zero mocking. A prominent header comment on the module says so, because adding
a single `import * as functions from "firebase-functions"` for a log line would silently break that
property.

## Implementation Plan

Nine steps: eight that carry the story's code, plus a CI job added last (finding DO-I1) because nothing in CI
has ever run this package's tests. The first three work on the assignment document (a pure move, then a signature change,
then the one behaviour change), so the reviewer of the behaviour change sees only the walk and its
tests. The next two extract the demographic reading and then retarget its tests, split so that the
extraction can land with the existing suite untouched and green as its evidence. The last three add
the fall-only pieces: the full-time table, the resolve step, and the fall step that composes
everything. Nothing depends on a later step.

Step sizes below are measured where a throwaway prototype was built (steps 4 and 5) and estimated
otherwise. Open Question 5 records the measurement.

Throughout: braces on every `if` and no single-line returns, matching the surrounding code.

---

### Move the assignment document into its own module

**Summary**: Create `assignment-doc.ts` holding `computeAssignmentDocId` and
`getAlternatingAssignment`, moved **verbatim** (still four positional identity arguments, still
per-stratum de-duplication), and import them into `random-assignment.ts`. Move their tests into
`assignment-doc.test.ts`. No behaviour change at all, so the diff is reviewable as a pure move, and
the module the emulator test needs now exists.

**Files affected**:
- `functions/src/tasks/ai4vs-flvs/assignment-doc.ts` (new) - the moved code plus the import-chain
  header comment
- `functions/src/tasks/ai4vs-flvs/random-assignment.ts` - delete the two functions, import them
- `functions/src/tasks/ai4vs-flvs/assignment-doc.test.ts` (new) - the `computeAssignmentDocId` and
  `getAlternatingAssignment` describe blocks moved from `random-assignment.test.ts`
- `functions/src/tasks/ai4vs-flvs/random-assignment.test.ts` - drop those two blocks

**Estimated diff size**: ~260 added, ~210 removed. Measured regions: the two functions are
`random-assignment.ts:219-279` (61 lines) and their tests are `random-assignment.test.ts:826-974`
(149 lines); the rest is the new module's header comment and a trimmed mock header.

`assignment-doc.ts`:

```ts
import { createHash } from "crypto";
import admin from "firebase-admin";

/**
 * The per-student assignment record at sources/{source_key}/jobs-task-data/{docId}, and the
 * transaction that alternates arms within a stratum.
 *
 * ⚠️ IMPORT CONSTRAINT, load-bearing: this module must import NOTHING but `crypto` and
 * `firebase-admin`. Its emulator-backed test (assignment-doc.emulator.test.ts) is the only place
 * the de-duplication is proven against a real Firestore transaction rather than a mocked
 * `runTransaction`, and it can only import real production code if the whole chain loads under
 * jest. Two chains do not:
 *   - `firebase-functions` -> `firebase-admin/auth`, which jest 24 cannot resolve (subpath exports)
 *   - `firebase-client` -> `firebase/auth`, which throws "ReferenceError: fetch is not defined"
 * Adding a logger import here to explain a failure would therefore silently cost the story its one
 * unmockable proof. Log in the calling step instead, which already has jobPath for attribution.
 *
 * The test_functions CI job runs the emulator suite on every push touching functions/**, so
 * breaking the property above fails a build rather than passing unnoticed. Run
 * `npm run test:emulator` locally before merging anything in this file.
 */

export type Arm = "treatment" | "control";

const ASSIGNMENT_NAMESPACE = "ai4vs-flvs-assignments";

export const computeAssignmentDocId = (
  interactiveId: string,
  platform_id: string,
  resource_link_id: string,
  context_id: string,
): string => {
  const input = `${ASSIGNMENT_NAMESPACE}|${interactiveId}|${platform_id}|${resource_link_id}|${context_id}`;
  return createHash("sha256").update(input).digest("hex");
};

export const getAlternatingAssignment = async (
  source_key: string,
  interactiveId: string,
  platform_id: string,
  resource_link_id: string,
  context_id: string,
  platform_user_id: string,
  stratumKey: string,
  n1Assignment: Arm,
): Promise<Arm> => {
  // ... body moved verbatim from random-assignment.ts:231-279 ...
};
```

`random-assignment.ts` loses lines 219-279 and gains:

```ts
import { Arm, computeAssignmentDocId, getAlternatingAssignment } from "./assignment-doc";
```

`computeAssignmentDocId` is used only inside `getAlternatingAssignment` and by tests, so
`random-assignment.ts` imports just `getAlternatingAssignment` and `Arm`. It is **not** re-exported
from `random-assignment.ts`: a pass-through export would be a seam nothing needs, and the one
external reader (`harness/im-done-local/run.js`) recomputes the hash itself rather than importing
it, which the next step documents rather than removes. Removing the duplication is deliberately **not** in this
plan: the harness is plain JS driving compiled output, and step 2 pins the formula with a test instead. Nothing
else in the repo reads the assignment document at all (verified: the only readers of `jobs-task-data` are the
step itself and `run.js:41-53`, and neither filters on `type`), which is what makes step 2's "both scopes write
the same `type`" safe.

`assignment-doc.test.ts` needs the `firebase-admin` transaction mock from
`random-assignment.test.ts:44-60` and nothing else, since the module under test has no other
dependency. That is the first visible payoff of the split: the new test file's header is 16 lines
where `random-assignment.test.ts`'s is 60.

---

### Replace the four positional identity arguments with an assignment scope

**Summary**: Introduce `AssignmentScope`, a `{ docId, fields }` pair the **step** computes and hands
to the core, with two constructors: `perClassScope` (byte-identical to today's key) and
`pooledProgramScope` (one document per program). The core gains no conditional and decides nothing;
it receives a document identity the way it already receives a strata table. No behaviour change for
spring or for full-time.

**Files affected**:
- `functions/src/tasks/ai4vs-flvs/assignment-doc.ts` - add the scope type and constructors, take a
  scope instead of four positional fields
- `functions/src/tasks/ai4vs-flvs/random-assignment.ts` - call `perClassScope(...)`
- `functions/src/tasks/ai4vs-flvs/assignment-doc.test.ts` - scope-identity tests, including the
  collision cases from verification finding 2
- `functions/src/tasks/ai4vs-flvs/random-assignment.test.ts` - the alternating-integration block's
  call shape

**Estimated diff size**: ~150 lines

```ts
/**
 * Which students share one balancing pool, and therefore one set of alternating counters.
 *
 * The core does not choose this and holds no per-program conditional: the step computes a scope
 * and passes it in. That is what keeps "randomize within teacher" (full-time, one document per
 * class) and "one group across all three sections" (flex, one document per program) from becoming
 * a mode flag inside the transaction.
 */
export interface AssignmentScope {
  /** Document id under sources/{source_key}/jobs-task-data/. */
  docId: string;
  /**
   * Identity fields recorded on the document so a reader can see what it pools. Written, never
   * read: nothing in this repo consumes them. Never put a real teacher name here.
   */
  fields: Record<string, string>;
}

/**
 * Pool per registration class: interactiveId | platform_id | resource_link_id | context_id.
 *
 * ⚠️ This input string is the SHIPPED key and must not change. Changing it re-keys every existing
 * assignment document, so students already assigned would be assigned again, under a fresh
 * document, and could land in the opposite arm while remaining enrolled in the first class. Two
 * things depend on the exact bytes: spring's live documents, and the second copy of this formula
 * in harness/im-done-local/run.js:41, which the harness uses to read back the assigned class.
 */
export const perClassScope = (
  interactiveId: string,
  platform_id: string,
  resource_link_id: string,
  context_id: string,
): AssignmentScope => ({
  docId: computeAssignmentDocId(interactiveId, platform_id, resource_link_id, context_id),
  fields: { interactiveId, platform_id, resource_link_id, context_id },
});

/**
 * Pool per program, across every class in it. Used by fall flex, where the PI confirmed all three
 * sections are one group (Trudi, 2026-07-29).
 *
 * ⚠️ `program` is persisted, both in this hash and in the document's fields. Callers pass a
 * year-qualified id ("fall-2026-flex") because the other two components do NOT distinguish cohorts:
 * interactiveId is the authored embeddable's ref_id, so it survives a new cohort on the same
 * activity, and platform_id is the portal. Unlike the per-class scope, nothing here re-keys itself
 * when the study runs again. See Open Question 4.
 *
 * ⚠️ The program is IN the key, and must be. resource_link_id is the offering id and an offering is
 * per class per activity, so excluding only context_id would still yield three flex documents;
 * excluding resource_link_id as well leaves interactiveId | platform_id, and one shared Green
 * button gives both programs the same interactiveId, so all eight classes would collapse into one
 * document and full-time's within-teacher balancing would silently stop meaning anything.
 *
 * ⚠️ Note the SEPARATE namespace prefix rather than an extra "pooled" segment inside the per-class
 * namespace. Verified during implementation planning: with an extra segment the two inputs have
 * equal segment counts, so a per-class key whose interactiveId is "pooled" and whose platform_id is
 * the program name hashes identically. A distinct prefix differs at a fixed byte for every possible
 * field value, so no collision exists to reason about.
 */
const POOLED_ASSIGNMENT_NAMESPACE = "ai4vs-flvs-assignments-pooled";

export const computePooledAssignmentDocId = (
  program: string,
  interactiveId: string,
  platform_id: string,
): string => {
  const input = `${POOLED_ASSIGNMENT_NAMESPACE}|${program}|${interactiveId}|${platform_id}`;
  return createHash("sha256").update(input).digest("hex");
};

export const pooledProgramScope = (
  program: string,
  interactiveId: string,
  platform_id: string,
): AssignmentScope => ({
  docId: computePooledAssignmentDocId(program, interactiveId, platform_id),
  fields: { interactiveId, platform_id, program },
});
```

`getAlternatingAssignment`'s signature and write become:

```ts
export const getAlternatingAssignment = async (
  source_key: string,
  scope: AssignmentScope,
  platform_user_id: string,
  stratumKey: string,
  n1Assignment: Arm,
): Promise<Arm> => {
  const db = admin.firestore();
  const docRef = db.doc(`sources/${source_key}/jobs-task-data/${scope.docId}`);

  return db.runTransaction(async (tx) => {
    // ... unchanged read and dedup ...
    tx.set(docRef, {
      // `type` names the record kind, not the pooling rule, so both scopes write the same value
      // and an existing document's type field does not change.
      type: ASSIGNMENT_NAMESPACE,
      ...scope.fields,
      strata: { /* unchanged */ },
    }, { merge: true });

    return assignment;
  });
};
```

Tests in this step, which are the "Assignment scope" acceptance criteria that are checkable without
a running transaction:

```ts
it("keeps the shipped per-class document id byte-identical", () => {
  // Pinned against a direct sha256 of the shipped input string, not against perClassScope itself,
  // so a change to the formula fails here rather than agreeing with itself.
  const expected = createHash("sha256")
    .update("ai4vs-flvs-assignments|i1|https://learn.concord.org|off-1|ctx-1")
    .digest("hex");
  expect(perClassScope("i1", "https://learn.concord.org", "off-1", "ctx-1").docId).toBe(expected);
  expect(computeAssignmentDocId("i1", "https://learn.concord.org", "off-1", "ctx-1")).toBe(expected);
});

it("gives the three flex sections one pooled document and three per-class documents", () => {
  const sections = [["off-1", "ctx-1"], ["off-2", "ctx-2"], ["off-3", "ctx-3"]];
  const perClass = sections.map(([o, c]) => perClassScope("green", "p1", o, c).docId);
  expect(new Set(perClass).size).toBe(3);
  const pooled = sections.map(() => pooledProgramScope("fall-2026-flex", "green", "p1").docId);
  expect(new Set(pooled).size).toBe(1);
});

it("separates the two programs on one shared interactiveId", () => {
  expect(pooledProgramScope("fall-2026-flex", "green", "p1").docId)
    .not.toBe(pooledProgramScope("fall-2026-full-time", "green", "p1").docId);
});

it("cannot be collided by per-class fields chosen to forge the pooled input", () => {
  // The check that rejected the first pooled-key format. See verification finding 2.
  expect(pooledProgramScope("fall-2026-flex", "green", "p1").docId)
    .not.toBe(computeAssignmentDocId("pooled", "fall-2026-flex", "green", "p1"));
  expect(pooledProgramScope("fall-2026-flex", "green", "p1").docId)
    .not.toBe(computeAssignmentDocId("green", "p1", "pooled", "fall-2026-flex"));
});

it("pins the pooled key format against a direct hash of its input", () => {
  // Not against the constructor, so a changed key format fails here rather than agreeing with
  // itself. The program-id half of this pin lives in fall-programs.test.ts, which is where the
  // constant is defined; this file must not import it, since fall-programs.ts does not exist yet at
  // this step.
  const expected = createHash("sha256")
    .update("ai4vs-flvs-assignments-pooled|fall-2026-flex|green|https://learn.concord.org")
    .digest("hex");
  expect(pooledProgramScope("fall-2026-flex", "green", "https://learn.concord.org").docId).toBe(expected);
});
```

---

### De-duplicate per student, and prove it against a real transaction

**Summary**: Replace the direct index into `strata[stratumKey].users` with a walk over every
stratum, returning early and writing nothing. This is the story's one invented behaviour and its one
deliberate change to spring. It lands with the emulator test that is the only thing capable of
proving it, plus a mocked test pinning the changed spring case.

**Files affected**:
- `functions/src/tasks/ai4vs-flvs/assignment-doc.ts` - the walk
- `functions/src/tasks/ai4vs-flvs/assignment-doc.test.ts` - the changed case, mocked
- `functions/src/tasks/ai4vs-flvs/assignment-doc.emulator.test.ts` (new) - the real-transaction
  proof, no mocks

**Estimated diff size**: ~200 lines

The change inside the transaction, replacing the `users[platform_user_id]` lookup at
`random-assignment.ts:252-255`:

```ts
    // Per-student de-duplication, NOT per (stratum, student). A student who already holds an arm keeps
    // it and is never issued a second one.
    //
    // Precision, because "first assignment wins" is very slightly stronger than this loop: on a document
    // where a student ALREADY holds two arms (only reachable from a pre-REPORT-81 spring run, since this
    // walk prevents a second one from ever being written), the arm returned is whichever stratum Firestore
    // yields first. Checked on the emulator: map fields came back in insertion order, so the first-written
    // arm won, but that ordering is not a documented guarantee. Such a student is already enrolled in both
    // classes, so no choice here makes it worse. See finding SE-I5.
    //
    // The local harness has always read the document this way (run.js:47-53 walks every stratum looking for
    // the student), so this is the read shape the persisted structure already invited.
    //
    // Why the walk: the pre-test is locked only AFTER a successful run, so any failure between
    // assignment and lock returns the student to an unlocked pre-test where they can edit an answer
    // and click again. Indexing straight into the CURRENT stratum would not find them, and they
    // would be assigned a second time. Since add_to_class only adds and this pipeline can remove
    // nobody, that does not re-bucket the student: it enrolls them into a second class while
    // leaving them in the first, contaminating both arms invisibly.
    //
    // Returning here writes nothing, deliberately. The current stratum's nextAssignment counter is
    // left untouched, so a re-clicking student never consumes a rotation slot in a stratum they are
    // not counted in, and the next genuinely new student there still receives the arm it specifies.
    //
    // At most 24 strata (the widest table), on a document the transaction already read in full.
    // NOTE the loop variable is `candidate`, not `stratum`: the lines above it
    // (`const stratum = strata[stratumKey] || {}`) stay, and `stratum` here fails
    // `npm run lint` with "Shadowed name: 'stratum'" (tslint no-shadowed-variable).
    // Measured, not guessed: the drafted version errored, this one lints clean. See SE-I6.
    for (const candidate of Object.values<any>(strata)) {
      const existing = candidate?.users?.[platform_user_id];
      if (existing) {
        return existing as Arm;
      }
    }
```

`assignment-doc.emulator.test.ts` (six of the seven cases proven during planning, now against the
real module; the seventh, a same-stratum re-click, stays a unit test because a mock can establish it
and this file should hold only what a mock cannot. Note the total absence of `jest.mock`, which is
the whole point):

```ts
import { db, clearFirestore } from "../../test/emulator-setup";
import { getAlternatingAssignment, perClassScope, pooledProgramScope } from "./assignment-doc";

const SOURCE = "assignment-doc-emulator";

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

const readDoc = async (docId: string) =>
  (await db.doc(`sources/${SOURCE}/jobs-task-data/${docId}`).get()).data() as any;

beforeEach(async () => { await clearFirestore(); });

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
  // The pooled scope deliberately takes NO section input, so the collapse is shown by contrast rather
  // than by feeding the pairs in: the same three sections yield three distinct per-class documents and
  // one pooled document. That contrast, plus three students below, is what "different sections" means
  // here. Asserting two identical pooled literals alternate would prove only same-document alternation,
  // which is the next test's job.
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
```

The mocked companion, which pins the spring delta as intended behaviour so it cannot be read later
as an accident of the extraction (nothing covers this case today, so the change would otherwise land
with a green suite):

```ts
it("returns the first assignment when the student's stratum has changed (the spring delta)", async () => {
  mockTransactionGet.mockResolvedValue({
    exists: true,
    data: () => ({ strata: { "Female|White|High|Mod1": { nextAssignment: "control", users: { "user-1": "treatment" } } } }),
  });

  const result = await getAlternatingAssignment(
    "src", perClassScope("i1", "p1", "off-1", "ctx-1"), "user-1", "Female|White|High|Mod2", "control",
  );

  // Before this story the same input produced "control", a SECOND assignment under the new stratum.
  expect(result).toBe("treatment");
  expect(mockTransactionSet).not.toHaveBeenCalled();
});
```

`emulator-setup.ts` and the `test:emulator` script need no change: the script already matches
`--testPathPattern emulator`, and the unit run already ignores `\.emulator\.test\.`. Run with
`npm run test:emulator`.

**⚠️ This test runs only when a human runs it, and that is worth stating plainly given how much of this plan's
structure exists to make it possible.** Verified: no GitHub Actions job runs the functions package at all.
`firestore-and-query-creator-tests.yml` triggers on `functions/**` but its two jobs run `working-directory:
tests` (the Firestore rules suite) and `query-creator/create-query`; across all five workflow files,
`working-directory` is never `functions`. So neither the 224-test unit suite nor this emulator file is executed
by automation, and the import constraint that makes this file possible is unguarded.

Running `npm run test:emulator` before merging this branch is therefore a required manual step, not a nicety.
**A CI job is the real fix, and it is now in this story** (Doug, 2026-07-29): see "Add CI for the functions
package" below. Verified viable before committing to it: with `lib/` excluded, which is what a CI checkout looks
like since `lib/` is untracked, `npx jest` in `functions` is green at **18 suites, 310 passed, 4 skipped**, and
`npm run lint` and `tsc --noEmit` are clean.

---

### Extract the demographic reading, leaving the existing suite untouched

**Summary**: Move the answer query, prompt matching, choice resolution and category mapping into
`demographics.ts`, parameterised by a `PreTestConfig` (the prompts and choice labels) and by the
dimension set to read. `random-assignment.ts` becomes the thin spring step. The wording moves to
`pre-tests.ts` and the 24-row table to `strata-tables.ts`, so `random-assignment.ts` is left holding
orchestration only. Selection is structural: the step references its own wording object, so nothing
is keyed by pilot and nothing is resolved at run time.

**⚠️ No test file is edited in this step, and that is the point.** This whole extraction was built as
a throwaway before the plan was written and the full suite passed unmodified, 224 tests across 8
files. Landing it with the tests untouched makes that the reviewable evidence that the refactor
preserves behaviour. The tests are not absent, they cover the extracted code through the step; the
next step moves them down to the new seam. Two things this depends on, both verified:

- The existing tests mock `firebase/firestore`, `../../firebase-client` and `firebase-functions` **by
  module path**, and jest applies those mocks to every importer in the file's registry, so
  `demographics.ts` inherits them with no new mock.
- `random-assignment.test.ts:751` asserts the Firestore-throw log contains `"unexpected error"`, so
  `readDemographics`'s outer catch **must** read "unexpected error reading demographics". Any other
  wording fails that test.

**Files affected**:
- `functions/src/tasks/ai4vs-flvs/demographics.ts` (new, ~195 lines) - the `PreTestConfig` **type**
  and the reading, matching and mapping code
- `functions/src/tasks/ai4vs-flvs/pre-tests.ts` (new, ~21 lines) - the wording **data**, starting
  with `SPRING_PRE_TEST`; `FALL_PRE_TEST` joins it in the last step
- `functions/src/tasks/ai4vs-flvs/strata-tables.ts` (new, ~40 lines) - the 24-row table moved out of
  `random-assignment.ts`; the full-time table is added to it two steps later
- `functions/src/tasks/ai4vs-flvs/random-assignment.ts` - thin spring step, 450 -> ~211 lines

**Estimated diff size**: ~260 added, ~240 removed (measured on the prototype)

```ts
import * as functions from "firebase-functions";
import { collection, query, where, getDocs } from "firebase/firestore";
import { getClientFirestore } from "../../firebase-client";

export const DIMENSIONS = ["Gender", "Grade", "Module", "Race"] as const;
export type Dimension = typeof DIMENSIONS[number];

/**
 * One pre-test's question wording and answer-choice labels.
 *
 * There is one object per PRE-TEST and it is selected STRUCTURALLY: each step references its own,
 * because the pipeline already selected the step and the step already knows its pre-test. There is
 * deliberately no pilot-keyed table: a key would add a run-time lookup that can miss while
 * selecting nothing the step does not already know, and would couple this to a pilot string another
 * story authors. The property this shape exists for is that a late correction to one pre-test's
 * wording is a one-object edit. See requirements.md Open Question 1 and finding SE-5.
 *
 * What varies by PROGRAM is which dimensions are read, not the wording, and that is resolved at run
 * time from the class word. Two different axes, selected two different ways.
 */
export interface PreTestConfig {
  /** Identifies the pre-test in log lines. */
  label: string;
  /** Case-insensitive substring identifying each dimension's question prompt. */
  prompts: Record<Dimension, string>;
  /**
   * Choice label -> category, matched EXACTLY after trim. Loose matching is rejected: a mis-matched
   * demographic silently places a student in the wrong stratum, corrupting a study arm rather than
   * stopping the pipeline.
   *
   * ⚠️ Gender is binary in every stratum key because the PI's tables have no third gender row, so a
   * non-responder is counted as Female for BALANCING. The answer documents retain the real choice,
   * so analysis can still distinguish non-responders. Also note mapToCategory THROWS on an unmapped
   * gender choice, so any option the fall pre-test adds and this map lacks blocks every student who
   * picks it. See requirements.md, Technical Notes and finding ER-4.
   */
  genderMap: Record<string, string>;
  gradeMap: Record<string, string>;
  /** The two module titles matched explicitly; every other choice falls to "Other". */
  moduleLabels: { Mod1: string; Mod2: string };
  /** The one race label not reduced to "non-White". */
  raceWhiteLabel: string;
}

/**
 * The three failure kinds are separated by whether RETRYING CAN HELP, because that is the only
 * thing the student-facing message can usefully say.
 */
export type DemographicsOutcome =
  /**
   * One entry per REQUESTED dimension; unrequested dimensions are absent, which is why this is
   * Partial. ⚠️ Amended during implementation from `Record<Dimension, string>`: that shape promised
   * all four values while filling only the requested ones, so a caller reading an unrequested
   * dimension got `undefined` with no type-level signal, and the fall step's `String(Gender)` would
   * have interpolated the literal "undefined" into a persisted stratum key. The step now guards the
   * dimensions it requires before building a key; see the fall step below.
   */
  | { ok: true; categories: Partial<Record<Dimension, string>> }
  /** Answers the student has not given. Retrying helps once they answer; the step names them. */
  | { ok: false; kind: "incomplete"; missing: Dimension[] }
  /**
   * An answer this pre-test's configuration cannot interpret: a duplicated prompt, an unknown
   * choice id, or a choice label absent from a map. All AUTHORING faults, all PERMANENT until the
   * pre-test or this configuration is edited, so no amount of clicking fixes them.
   *
   * The distinction matters most for Gender, which throws rather than defaulting: if the fall
   * pre-test offers an option this config lacks, every student who picks it is blocked, and telling
   * them to try again would be false. Already logged here with the offending detail.
   */
  | { ok: false; kind: "unmappable" }
  /** A Firestore or transport failure. Genuinely transient, so retrying is honest advice. */
  | { ok: false; kind: "failed" };

export interface DemographicsRequest {
  /** Prefixes log lines, so a failure is attributed to the calling step. */
  logPrefix: string;
  jobPath: string;
  firebaseJwt: string;
  source_key: string;
  platform_id: string;
  resource_link_id: string;
  context_id: string;
  platform_user_id: string;
  preTest: PreTestConfig;
  /** Only these are read. A full-time student never has to answer the flex-only questions. */
  dimensions: readonly Dimension[];
}
```

`parseReportState` stays private and verbatim. `findAnswerByPrompt`, `resolveChoices` and
`mapToCategory` move verbatim except that the wording comes from `preTest` rather than from
module-level constants:

```ts
const findAnswerByPrompt = (
  answerDocs: Array<{ data: any }>,
  dimension: Dimension,
  preTest: PreTestConfig,
  logPrefix: string,
): { authoredState: any; interactiveState: any } => {
  const substring = preTest.prompts[dimension];
  // ... unchanged; `random-assignment:` in the warn line becomes `${logPrefix}:` ...
};

const mapToCategory = (dimension: Dimension, choiceTexts: string[], preTest: PreTestConfig): string => {
  switch (dimension) {
    case "Gender": {
      const category = preTest.genderMap[choiceTexts[0]];
      if (!category) {
        throw new Error(`Unmapped Gender choice: "${choiceTexts[0]}"`);
      }
      return category;
    }
    // Grade unchanged in shape, reading preTest.gradeMap
    case "Module": {
      // Default fallback: anything that is not one of the two titles -> Other. This is what makes
      // the PI's "group Other/not sure with Module 4" refinement need no code change.
      const text = choiceTexts[0];
      if (text === preTest.moduleLabels.Mod1) {
        return "Mod1";
      }
      if (text === preTest.moduleLabels.Mod2) {
        return "Mod2";
      }
      return "Other";
    }
    case "Race": {
      const hasOnlyWhite = choiceTexts.length === 1 && choiceTexts[0] === preTest.raceWhiteLabel;
      return hasOnlyWhite ? "White" : "non-White";
    }
  }
};
```

The new public entry point owns the Firestore client, the query and the cleanup, so both steps get
an identical query rather than two copies of it:

```ts
/**
 * Query the student's answers and resolve each requested dimension to its category.
 *
 * The answers query spans the whole SEQUENCE, because a multi-activity sequence shares one
 * resource_link_id. That is what makes a demographic question duplicated across the two Green
 * activities hazardous: findAnswerByPrompt throws when more than one answer matches a prompt.
 */
export const readDemographics = async (request: DemographicsRequest): Promise<DemographicsOutcome> => {
  const { logPrefix, jobPath, firebaseJwt, source_key, platform_id, resource_link_id } = request;
  const { context_id, platform_user_id, preTest, dimensions } = request;

  let firestoreCleanup: (() => Promise<void>) | undefined;
  try {
    const { firestore, cleanup } = await getClientFirestore(firebaseJwt);
    firestoreCleanup = cleanup;

    const answersRef = collection(firestore, `sources/${source_key}/answers`);
    const q = query(
      answersRef,
      where("platform_id", "==", platform_id),
      where("resource_link_id", "==", resource_link_id),
      where("context_id", "==", context_id),
      where("platform_user_id", "==", platform_user_id),
    );
    const snapshot = await getDocs(q);
    const answerDocs = snapshot.docs.map(doc => ({ data: doc.data() }));

    const categories: Record<Dimension, string> = {} as any;
    const missing: Dimension[] = [];

    for (const dim of dimensions) {
      try {
        const { authoredState, interactiveState } = findAnswerByPrompt(answerDocs, dim, preTest, logPrefix);
        const choiceTexts = resolveChoices(authoredState, interactiveState, dim);
        categories[dim] = mapToCategory(dim, choiceTexts, preTest);
      } catch (error: any) {
        if (error.isMissingAnswer) {
          missing.push(dim);
        } else {
          // Everything thrown by the three resolvers is an authoring fault, so this whole inner
          // catch is `unmappable`; only the outer catch below is a retryable `failed`.
          functions.logger.error(`${logPrefix}: ${error.message} for ${jobPath} (${preTest.label})`);
          return { ok: false, kind: "unmappable" };
        }
      }
    }

    if (missing.length > 0) {
      functions.logger.error(
        `${logPrefix}: missing or incomplete answers for ${missing.join(", ")} for user ${platform_user_id} at ${jobPath}`,
      );
      return { ok: false, kind: "incomplete", missing };
    }

    return { ok: true, categories };
  } catch (error) {
    // ⚠️ The words "unexpected error" are LOAD-BEARING: random-assignment.test.ts:750 asserts the
    // Firestore-throw log contains them. Any other wording fails that test, which is exactly what
    // makes this step's "no test file is edited" claim true. Measured, not reasoned: with "failed to
    // read demographics" the suite is 223/224. See Open Question 5 and finding SE-I1.
    functions.logger.error(`${logPrefix}: unexpected error reading demographics for ${jobPath}`, error);
    return { ok: false, kind: "failed" };
  } finally {
    try {
      if (firestoreCleanup) {
        await firestoreCleanup();
      }
    } catch (cleanupErr) {
      functions.logger.warn(`${logPrefix}: cleanup failed`, cleanupErr);
    }
  }
};
```

One deliberate, behaviour-visible difference from today: the client Firestore instance is now
cleaned up as soon as the answers have been read, instead of after the enrollment call at the end of
the step. That releases the client sooner and is strictly narrower; the enrollment path never used
it. Worth naming rather than leaving as a silent side effect of the move.

`pre-tests.ts` holds the wording data, and `random-assignment.ts` reduces to orchestration. The
type lives in `demographics.ts` with the code that consumes it; the data lives here with the other
transcribed authored content, the way `strata-tables.ts` holds the transcribed tables:

```ts
// pre-tests.ts
import { PreTestConfig } from "./demographics";

/**
 * The spring-2026 pre-test's wording. Unchanged by REPORT-81: this story alters neither spring's
 * prompts nor its choice labels.
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
```

**The exact shape of the edit, because a line range does not capture it.** Line 326 *is* the `try {`, and the
`catch`/`finally` pair at `:438-449` sits outside the replaced region. So: **keep** the outer `try/catch`
wrapping everything from `readDemographics` through the enrollment tail, **delete** the `finally` block and the
`let firestoreCleanup` declaration (cleanup now lives inside `readDemographics`), and leave the catch's
`unexpected error` wording alone. Measured: removing the outer `try/catch` altogether fails exactly two tests,
`Portal enrollment > fails on network error (fetch throws)` and
`alternating assignment integration > returns student-friendly error when transaction fails`, both of which
assert `logger.error(stringContaining("unexpected error"), any(Error))` about the enrollment and transaction
tail rather than about demographics. See finding SE-I2.

```ts
// random-assignment.ts, inside randomAssignment: the body of the existing try block, replacing the
// demographic-reading region (:324-388). The try/catch stays; only the finally goes.
  const demographics = await readDemographics({
    logPrefix: "random-assignment", jobPath, firebaseJwt,
    source_key: String(source_key), platform_id: String(platform_id),
    resource_link_id: String(resource_link_id), context_id: String(context_id),
    platform_user_id: String(platform_user_id),
    preTest: SPRING_PRE_TEST, dimensions: DIMENSIONS,
  });
  if (!demographics.ok) {
    if (demographics.kind === "incomplete") {
      return {
        success: false,
        message: `Please complete the following question(s) before continuing: ${demographics.missing.join(", ")}.`,
      };
    }
    // Spring keeps ONE message for both remaining kinds, exactly as it does today. The fall step
    // distinguishes them; spring is deliberately not changed, so its only delta stays the dedup.
    return { success: false, message: STUDENT_FAILURE_MESSAGE };
  }

  const { Gender, Race, Grade, Module } = demographics.categories;
  const stratumKey = `${Gender}|${Race}|${Grade}|${Module}`;
  const n1Assignment = GENDER_RACE_GRADE_MODULE_TABLE[stratumKey];
  if (!n1Assignment) {
    functions.logger.error(
      `random-assignment: no matching stratum for ${stratumKey} for user ${platform_user_id} at ${jobPath}`,
    );
    return { success: false, message: STUDENT_FAILURE_MESSAGE };
  }

  const assignment = await getAlternatingAssignment(
    String(source_key),
    perClassScope(String(interactiveId), String(platform_id), String(resource_link_id), String(context_id)),
    String(platform_user_id), stratumKey, n1Assignment,
  );
```

The enrollment tail (mint, `add_to_class`, classify, summary) is untouched, including the enrol-by-id
path REPORT-83 migrated onto the minted token.

`strata-tables.ts` is created here holding only the 24-row table, moved verbatim, so
`random-assignment.ts` is emptied of data in one step. The full-time table is added beside it two
steps later, which keeps this step free of anything fall-specific and avoids a forward dependency in
either direction.

---

### Retarget the tests to the new seam

**Summary**: Move the prompt matching, choice resolution, category mapping, race reduction and
missing-answer blocks out of `random-assignment.test.ts` and into `demographics.test.ts`, testing
`readDemographics` directly instead of through the step, and lift the shared answer-doc fixtures into
their own module so the two test files use one copy. Purely mechanical: no production file changes.

Split from the previous step because combining them would have put ~690 added lines in one commit,
and because editing the tests alongside the extraction destroys the evidence that the extraction
preserved behaviour. Here the two are separable without leaving anything uncovered, since the
previous step's suite already exercises every line of `demographics.ts` through the step.

**Files affected**:
- `functions/src/tasks/ai4vs-flvs/answer-doc-fixtures.ts` (new, ~121 lines) - `makeAnswerDoc` and
  `makeStandardAnswerDocs` lifted from `random-assignment.test.ts:65-185`, now shared by both test
  files rather than duplicated. Note the filename deliberately avoids `.test.`/`.spec.`, so jest's
  `testRegex` does not treat a fixture module as a suite.
- `functions/src/tasks/ai4vs-flvs/demographics.test.ts` (new, ~320 lines) - the moved blocks, plus
  the `unmappable` / `failed` split: an unmapped choice, an unknown choice id and a duplicated prompt
  each return `unmappable`, while a throwing `getDocs` returns `failed`
- `functions/src/tasks/ai4vs-flvs/random-assignment.test.ts` - keeps the step-level blocks (request
  validation, enrollment, the 24 strata end to end, alternating integration), losing ~275 lines

**Estimated diff size**: ~440 added, ~275 removed, all mechanical

The `unmappable` / `failed` assertions are the only genuinely new tests here. Everything else is the
same case list, rewritten to call `readDemographics` with a `PreTestConfig` rather than to call
`randomAssignment` and infer the mapping from the resulting class name. That is the point of the
move: a mapping bug now fails a test that names the mapping, instead of one that names an enrollment.

---

### Add the full-time strata table

**Summary**: Add the new 20-row full-time Gender x Race x Teacher table to `strata-tables.ts`, beside
the 24-row table moved there two steps earlier, plus the integrity tests that make a mistyped cell
fail loudly. Both tables are transcriptions of the PI's source documents, so having them side by side
is what lets one reviewer check both against requirements.md in one sitting.

**Files affected**:
- `functions/src/tasks/ai4vs-flvs/strata-tables.ts` - add the full-time table beside the 24-row one
- `functions/src/tasks/ai4vs-flvs/strata-tables.test.ts` (new) - integrity tests for both tables. **No test
  file is edited**: the 24-row pins here are additive, and `random-assignment.test.ts` keeps its end-to-end
  24-stratum block exactly as the previous step leaves it (finding QA-I1)

**Estimated diff size**: ~200 lines

```ts
// strata-tables.ts, added below the GENDER_RACE_GRADE_MODULE_TABLE moved here earlier. That table's
// header records what it is: the arm the FIRST student in each stratum receives, shared by the
// spring step and the fall FLEX program because they are the same 24 strata from the same source
// document, verified 2026-07-29 against the PI's document row by row.

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
   * Reviewed 2026-07-29 (Doug): teacher names are NOT PII for this study; only student names are. This
   * field is nevertheless never logged, never placed in a StepResult and never written to the assignment
   * document, for the simpler reason that nothing needs it: the stratum key, the lookup and the class word
   * all carry the surname alone. Student names never reach this pipeline at all.
   */
  teacherFullName: string;
  /** The arm the FIRST student in this stratum receives. */
  n1: Arm;
}

/**
 * Transcribed 2026-07-29 from the PI's randomization document, IN THE SOURCE DOCUMENT'S ROW ORDER,
 * which the alternation properties depend on. requirements.md reproduces the same table and is the
 * committed reference to check this against; the oob working note is a scratch copy, not the source.
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
 *
 * ⚠️ Amended during implementation from `(stratum, gender, race)`: the row already carries its own
 * gender and race, so the extra parameters could disagree with the row they came from. The
 * canonical-source argument that motivates taking the surname from the row applies identically to
 * the other two components.
 */
export const fullTimeStratumKey = (stratum: FullTimeStratum): string =>
  `${stratum.gender}|${stratum.race}|${stratum.surname}`;

// The LOOKUP is keyed on the lowercased surname, because the class word arrives in the portal's
// stored (lowercased) form while the rows carry the readable "Bingler" for review against the PI's
// document. Two different jobs: display casing in the table, match casing in the index.
const FULL_TIME_BY_KEY = new Map(
  FULL_TIME_TABLE.map(row => [`${row.gender}|${row.race}|${row.surname.toLowerCase()}`, row]),
);

/** `surname` is expected lowercase (as derived from the normalized class word). */
export const findFullTimeStratum = (
  gender: string,
  race: string,
  surname: string,
): FullTimeStratum | undefined => FULL_TIME_BY_KEY.get(`${gender}|${race}|${surname.toLowerCase()}`);
```

`strata-tables.test.ts` carries the acceptance criteria for the transcription. All twenty `n1`
values are asserted individually, so a single mistyped cell is caught wherever it sits, and the five
block starts are asserted separately, which is what catches an entire teacher's block transcribed
with inverted polarity (the likeliest error given the alternating layout, and the one the per-cell
assertions would flag without explaining):

```ts
const EXPECTED_N1: Array<[string, string, string, Arm]> = [
  ["Female", "White",     "Bingler", "treatment"],
  // ... all twenty, in source order ...
];

it.each(EXPECTED_N1)("stratum %s|%s|%s starts on %s", (gender, race, surname, n1) => {
  expect(findFullTimeStratum(gender, race, surname)?.n1).toBe(n1);
});

it("has 20 rows with 20 unique stratum keys", () => { /* ... */ });

it("starts each teacher's block on the source document's alternating seed", () => {
  const starts = ["Bingler", "Hankamp", "Long", "Newlon", "Torres"]
    .map(s => FULL_TIME_TABLE.find(r => r.surname === s)!.n1);
  expect(starts).toEqual(["treatment", "control", "treatment", "control", "treatment"]);
});

it("alternates within each teacher's block, and is NOT one continuous 20-row alternation", () => {
  for (const surname of ["Bingler", "Hankamp", "Long", "Newlon", "Torres"]) {
    const block = FULL_TIME_TABLE.filter(r => r.surname === surname);
    expect(block).toHaveLength(4);
    block.forEach((row, i) => {
      if (i > 0) {
        expect(row.n1).not.toBe(block[i - 1].n1);
      }
    });
  }
  // EVERY block boundary repeats, which is what makes this five blocks and not one 20-row sequence.
  // All four are asserted, not just the first two: verified 4/5, 8/9, 12/13 and 16/17 all repeat.
  for (let i = 3; i < 19; i += 4) {
    expect(FULL_TIME_TABLE[i].n1).toBe(FULL_TIME_TABLE[i + 1].n1);
  }
});

it("splits 10 treatment to 10 control", () => { /* ... */ });

/**
 * The guard for the one way surname keying can fail: two study teachers sharing a surname. It is
 * impossible among the current five, and this is what catches a future roster change that
 * introduces it. Asserting the two COUNTS ARE EQUAL is the real guard, because a sixth teacher
 * sharing a surname with an existing one leaves five distinct surnames but six distinct full names.
 * The literal 5 is asserted as well, so a roster change is a deliberate edit here rather than a
 * silent widening.
 */
it("maps surnames to teachers one-to-one", () => {
  const surnames = new Set(FULL_TIME_TABLE.map(r => r.surname));
  const fullNames = new Set(FULL_TIME_TABLE.map(r => r.teacherFullName));
  expect(surnames.size).toBe(fullNames.size);
  expect(surnames.size).toBe(5);
});

it("carries the PI's full teacher name on every row, ending in the row's surname", () => {
  for (const row of FULL_TIME_TABLE) {
    expect(row.teacherFullName.split(/\s+/).pop()).toBe(row.surname);
  }
});

it("keeps all 24 flex strata resolvable with their shipped starting arms", () => {
  // ADDITIVE, not moved. random-assignment.test.ts:530-588 keeps its end-to-end it.each over the same 24
  // strata, which drives randomAssignment from seeded answer docs and asserts the resulting class name.
  // That is the test proving a stratum RESOLVES (prompt matching, choice resolution, category mapping and
  // key construction all included); this one pins the table's literal contents so a mistyped cell is
  // caught where it sits, the same division of labour the 20-row table gets. See finding QA-I1.
  expect(Object.keys(GENDER_RACE_GRADE_MODULE_TABLE)).toHaveLength(24);
  expect(GENDER_RACE_GRADE_MODULE_TABLE["Female|White|High|Mod2"]).toBe("treatment");
  // ... all 24 pinned, transcribed from the table moved in the extraction step ...
});
```

---

### Add the resolve-origin-class step

**Summary**: A step that mints an origin-scoped teacher token, reads the student's offering, and
publishes the origin class word on `StepResult.output` as `originClassWord`. Add that field to
`StepOutput` and a small shared reader for handoff fields. An absent `class_word` is a classified
failure with the tell-your-teacher message, not a silent fallback.

**Files affected**:
- `functions/src/tasks/ai4vs-flvs/types.ts` - `originClassWord` on `StepOutput`, plus
  `readStepOutputField`
- `functions/src/tasks/ai4vs-flvs/resolve-origin-class.ts` (new)
- `functions/src/tasks/ai4vs-flvs/resolve-origin-class.test.ts` (new)
- `functions/harness/im-done-local/stub-portal.js` - lowercase the class words the stub serves, so
  it reproduces the portal's contract instead of echoing its fixtures
- `functions/harness/im-done-local/config.js` - lowercase `ORIGIN_CLASS.word` and
  `DESTINATION_CLASS.word`

**Estimated diff size**: ~270 lines

`types.ts`:

```ts
export interface StepOutput {
  /** Class word the enroll step should resolve and enroll into. */
  destinationClassWord?: string;
  /**
   * The student's ORIGIN class word (the class they registered in), published by
   * resolve-origin-class. The fall randomization step needs it twice, for the teacher stratum and
   * to derive the -Gator / -Shark destination, and REPORT-80 and REPORT-82 need it after that.
   *
   * Safe to log: authored, environment-stable, neither PII nor a token.
   */
  originClassWord?: string;
}

/**
 * First non-blank value of `field` across the run's step outputs.
 *
 * Record iteration is insertion order, which is pipeline order, and the invariant is one producer
 * per FIELD. Consuming steps therefore read a handoff with NO ordering guard: our own pipeline
 * wiring is assumed correct rather than checked with defensive run-time code, REPORT-82 owns step
 * order as it does everywhere else, and a mis-ordered stage fails on the first harness run. The
 * same principle is recorded at length in enroll-specified-class's header.
 *
 * enroll-specified-class keeps its own local scan rather than calling this: its version is
 * entangled with the authored-parameter precedence rule and its conflict error, so folding the two
 * together would rewrite a step this story otherwise does not touch. Deliberate, not overlooked.
 */
export const readStepOutputField = (
  stepResults: Record<string, StepResult>,
  field: keyof StepOutput,
): string | undefined => {
  for (const result of Object.values(stepResults)) {
    const value = result.output?.[field];
    if (typeof value === "string" && value.trim()) {
      return value.trim();
    }
  }
  return undefined;
};
```

`resolve-origin-class.ts`:

```ts
import * as functions from "firebase-functions";
import { StepContext, StepResult } from "./types";
import {
  getScopedPortalToken, portalTokenFetch, classifyPortalFailure, messageForBucket, TELL_TEACHER_MESSAGE,
} from "../portal-api";
import { resolveOriginOffering } from "../portal-reads";

const STUDENT_FAILURE_MESSAGE =
  "Unable to look up your class. Please try again or contact your teacher.";

/**
 * Resolve the student's origin class word once per run and publish it for the later steps.
 *
 * Mints ONCE: steps that need the class word read it from stepResults rather than re-reading the
 * offering, and the per-run tokenCache means a later step needing the same scope reuses the token.
 *
 * ⚠️ One pre-existing duplicate read is knowingly left in place. send-email calls
 * resolveOriginOffering itself for the offering's clazzId, which send_class_teachers needs, so a
 * stage containing both steps issues GET /api/v1/offerings/:id twice per run. Removing it means
 * either publishing clazzId here and rewiring send-email, or having send-email reach into another
 * step's output; both change a step this story does not otherwise touch, so the tidy-up belongs
 * with REPORT-82's stage wiring, where the step order is being decided anyway.
 *
 * Like the other steps here this makes NO host check of its own: it assumes the pipeline ran
 * validatePortalHost before the loop and uses StepContext.portalOrigin for every portal call, never
 * the raw jobDoc.platform_id.
 */
export const resolveOriginClass = async (context: StepContext): Promise<StepResult> => {
  const { jobPath, jobDoc, firebaseJwt, tokenCache, portalOrigin } = context;
  const { resource_link_id } = jobDoc;
  const pilot = String(jobDoc.jobInfo.request.pilot);

  if (!resource_link_id) {
    functions.logger.error(`resolve-origin-class: missing required context field: resource_link_id for ${jobPath}`);
    return { success: false, message: STUDENT_FAILURE_MESSAGE };
  }
  if (!firebaseJwt) {
    functions.logger.error(`resolve-origin-class: missing Firebase JWT for ${jobPath}`);
    return { success: false, message: STUDENT_FAILURE_MESSAGE };
  }

  try {
    // The offering read needs only an origin-class teacher token, so this is the unscoped mint.
    const token = await getScopedPortalToken({
      cache: tokenCache, portalUrl: portalOrigin, firebaseToken: firebaseJwt, tokenType: "teacher", pilot,
    });
    if (!token.ok || !token.token) {
      const mintBucket = classifyPortalFailure({ status: token.status, reason: token.reason });
      return { success: false, message: messageForBucket(mintBucket, STUDENT_FAILURE_MESSAGE) };
    }

    const origin = await resolveOriginOffering(portalOrigin, token.token, String(resource_link_id));
    if (!origin.offering) {
      functions.logger.error(`resolve-origin-class: offering-read failed for ${jobPath}`, { status: origin.status });
      const offeringBucket = classifyPortalFailure({ status: origin.status });
      return { success: false, message: messageForBucket(offeringBucket, STUDENT_FAILURE_MESSAGE) };
    }

    // Normalized to the portal's STORED form, which is the contract every consumer inherits.
    // Portal::Clazz lowercases and strips class_word before validation on every save
    // (rigse app/models/portal/clazz.rb:28-30), and offerings#show serves the stored value
    // (app/models/api/v1/offering.rb:98), so this is a no-op against real portal data. It is done
    // here rather than compared case-insensitively downstream so that "originClassWord is in the
    // portal's stored form" is an invariant this story, REPORT-80 and REPORT-82 all inherit from one
    // place, instead of three consumers each having to remember it.
    const classWord = origin.offering.classWord?.trim().toLowerCase();
    if (!classWord) {
      // A classified failure, not a fallback. class_word is teacher-gated and these pipelines only
      // ever mint teacher tokens, so an absent one indicates a real anomaly rather than a
      // permissions shortfall. Error level: everything downstream (the teacher stratum, the
      // destination class) depends on this value, so the blast radius is the student's study arm.
      functions.logger.error(
        `resolve-origin-class: offering ${resource_link_id} returned no class_word for ${jobPath}`,
      );
      return { success: false, message: TELL_TEACHER_MESSAGE };
    }

    functions.logger.info(`resolve-origin-class: resolved origin class word ${classWord} for ${jobPath}`);
    // summary is display-only (send-email renders it into the teacher email); a class word is
    // authored, environment-stable, and neither PII nor a token, so it is safe here.
    return { success: true, summary: `Origin class ${classWord}`, output: { originClassWord: classWord } };
  } catch (error) {
    functions.logger.error(`resolve-origin-class: unexpected error for ${jobPath}`, error);
    return { success: false, message: STUDENT_FAILURE_MESSAGE };
  }
};
```

Tests follow `enroll-specified-class.test.ts`'s shape (mock `getScopedPortalToken` and
`portalTokenFetch`, mock `../portal-reads`, keep the real classifier and messages): the happy path
publishes `originClassWord` and mints unscoped; a 403 read gives tell-your-teacher; a 500 read gives
the generic message; a mint reporting `expired` gives the reload message; a 200 with no `class_word`
gives tell-your-teacher and logs at error with the offering id; no token value appears in any log
argument. Plus a `readStepOutputField` unit: it skips a step whose output is absent, skips a blank
value, takes the first non-blank in insertion order, and trims.

Two tests specifically for the normalization, since it is the fix for a defect that would have
reached production:

```ts
it("publishes the class word in the portal's stored form", async () => {
  // The portal always stores lowercase, so this is a no-op on real data. Asserted anyway, because
  // it is what lets every consumer match exactly instead of case-insensitively.
  mockResolveOriginOffering.mockResolvedValue({ status: 200, offering: { clazzId: 90210, classWord: "  FT-2026-Bingler  " } });
  const result = await resolveOriginClass(makeContext());
  expect(result.output?.originClassWord).toBe("ft-2026-bingler");
});

it("treats a whitespace-only class word as absent", async () => {
  mockResolveOriginOffering.mockResolvedValue({ status: 200, offering: { clazzId: 90210, classWord: "   " } });
  const result = await resolveOriginClass(makeContext());
  expect(result.success).toBe(false);
  expect(result.message).toBe(TELL_TEACHER_MESSAGE);
});
```

**The harness fixture fix.** `config.js:47-48` seeds mixed-case class words and the stub echoes them
verbatim, so a local run sees `FL-spring-2026-origin` where production sends
`fl-spring-2026-origin`. That is a fixture asserting a contract the portal does not honour, and it is
exactly the fidelity gap that would have let this story's defect pass locally and fail on launch day.
Two changes, and the second matters more than the first:

```js
// config.js
const ORIGIN_CLASS = { id: 90210, word: "fl-spring-2026-origin", name: "FL-spring-2026-origin" };
const DESTINATION_CLASS = { id: 30001, word: "ft-fall-2026-a", name: "FT-fall-2026-A" };
```

Note `name` keeps its display casing: the portal lowercases `class_word` only, and `name` is what
`send-email` renders, so the two must not be conflated.

```js
// stub-portal.js: model the portal's behaviour rather than trusting the fixture.
// Portal::Clazz lowercases and strips class_word before validation on every save
// (rigse app/models/portal/clazz.rb:28-30), so a stub that echoes a mixed-case fixture is
// asserting a contract the portal does not honour.
const storedClassWord = (word) => String(word).trim().toLowerCase();

const classInfoFor = ({ id, word, name }, offering) => ({
  // ...
  class_hash: `stub-${storedClassWord(word)}-hash`,
  class_word: storedClassWord(word),
  // ...
});

const CLASSES_BY_WORD = {
  [storedClassWord(ORIGIN_CLASS.word)]: classInfo,
  [storedClassWord(DESTINATION_CLASS.word)]: destinationClassInfo,
};

// The lookup is case-insensitive because portal_clazzes is charset utf8 with no explicit collation
// (so utf8_general_ci), which is why student self-registration accepts a typed word in any case.
const classesInfoResponse = (behavior, classWord) => {
  if (behavior === "forbidden") {
    return { status: 403, body: punditForbidden };
  }
  const found = CLASSES_BY_WORD[storedClassWord(classWord)];
  // ... unchanged
};
```

With the stub downcasing, a future fixture written in spreadsheet casing still produces the
production shape, so the gap cannot silently reopen. The existing `enroll-happy`,
`enroll-unknown-word` and `enroll-lookup-forbidden` scenarios keep passing:
`enroll-specified-class` resolves whatever word it is given through the same case-insensitive
lookup, and `enroll-unknown-word` still matches no class.

---

### Add the fall randomization step

**Summary**: The step this story exists for. Resolve the program from the origin class word, read
that program's dimension set with the fall pre-test's wording, look up its table, assign under its
scope, and publish the `-Gator` / `-Shark` destination class word. No enrolment and no portal write.

**Files affected**:
- `functions/src/tasks/ai4vs-flvs/fall-programs.ts` (new) - classifier, surname derivation,
  dimension sets
- `functions/src/tasks/ai4vs-flvs/pre-tests.ts` - add `FALL_PRE_TEST` beside `SPRING_PRE_TEST`
- `functions/src/tasks/ai4vs-flvs/fall-random-assignment.ts` (new) - the step
- `functions/src/tasks/ai4vs-flvs/pre-tests.test.ts` (new) - the equality pin
- `functions/src/tasks/ai4vs-flvs/fall-programs.test.ts` (new)
- `functions/src/tasks/ai4vs-flvs/fall-random-assignment.test.ts` (new)

**Estimated diff size**: ~450 lines

```ts
// fall-programs.ts
import { Dimension } from "./demographics";

/**
 * The two fall programs. Resolved at run time from the student's origin class word, never authored:
 * a single shared Green pre-test button serves both cohorts, so there is no request parameter that
 * could distinguish them.
 *
 * ⚠️ These strings are DATA, not labels. FLEX_PROGRAM is hashed into the pooled assignment document
 * id (pooledProgramScope), so once one flex student holds an arm, changing it re-keys the document:
 * every assigned student is treated as new, counters restart from n1, and students can be assigned a
 * second, opposite arm while still enrolled in the first class. A test pins the resulting document
 * id so a rename fails loudly. Renaming is a data migration, not a refactor.
 *
 * ⚠️ They carry the YEAR deliberately. The per-class scope re-keys itself for a new cohort, because
 * it includes the offering and the class, but the pooled key is built from interactiveId,
 * platform_id and this string, all three of which survive a new cohort on the same authored activity
 * (interactiveId is the embeddable's ref_id, a property of the ACTIVITY). Without the year, a later
 * flex cohort would silently continue fall-2026's alternation counters and accumulate in its
 * document. See Open Question 4.
 */
export const FULL_TIME_PROGRAM = "fall-2026-full-time";
export const FLEX_PROGRAM = "fall-2026-flex";
export type FallProgramId = typeof FULL_TIME_PROGRAM | typeof FLEX_PROGRAM;

// ⚠️ LOWERCASE, and that is not a style choice. The portal stores every class word lowercased
// (Portal::Clazz downcases before validation) and offerings#show serves the stored value, so the
// spreadsheet's "FT-2026-Bingler" reaches us as "ft-2026-bingler". resolve-origin-class normalizes
// to that stored form, and these prefixes match it exactly. Verified against all eight of the
// study's class words: the mixed-case prefixes failed 8 of 8.
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
 * ⚠️ This encodes an assumption about the class-word format: `<prefix>-<year>-<surname>`, with a surname
 * that is a SINGLE hyphen-free token. Verified against all five study words (bingler, hankamp, long,
 * newlon, torres) and all three flex words. It would mis-derive a hyphenated surname:
 * `ft-2026-van-dyke` yields `dyke`, not `van-dyke`. Note this is the same two-word-surname fragility
 * requirements.md Open Question 3 rejected option C for, arrived at from the other end, and the
 * five-distinct-surnames guard does NOT catch it. If the roster ever gains such a teacher, match the
 * word's trailing text against the table's known surnames instead of splitting on a hyphen. See
 * finding SE-I4.
 */
export const teacherSurnameFromClassWord = (originClassWord: string): string =>
  originClassWord.slice(originClassWord.lastIndexOf("-") + 1).trim();
```

```ts
// pre-tests.ts, added beside SPRING_PRE_TEST

/**
 * The fall Green pre-test's wording.
 *
 * ✅ Specified as IDENTICAL to spring's prompts and choice labels, CONFIRMED BY THE PI (Trudi,
 * 2026-07-29, Slack): "Yes, they are the same". Recorded with the date and attribution so a reader
 * knows this was verified rather than assumed, and pinned by a test in pre-tests.test.ts that fails
 * if the two diverge, so whoever changes this has to update this comment in the same edit. Her one
 * refinement, that "Other/not sure" may be grouped with a Module 4 option, is already the behaviour
 * here: the Module mapping matches only the two full titles and everything else falls to "Other".
 *
 * A separate object from SPRING_PRE_TEST on purpose, not an alias: one shared Green pre-test serves
 * both fall programs, so a late correction to the fall wording must be a one-object edit that
 * cannot reach spring.
 */
export const FALL_PRE_TEST: PreTestConfig = {
  label: "fall-2026 Green pre-test",
  // ... the same prompts, genderMap, gradeMap, moduleLabels and raceWhiteLabel as SPRING_PRE_TEST,
  // written out in full rather than spread from it, so the two can diverge by editing one literal.
};
```

```ts
// pre-tests.test.ts

/**
 * Pins the PI's 2026-07-29 confirmation that the fall Green pre-test reuses spring's wording.
 *
 * ⚠️ This test is EXPECTED to be deleted or amended one day. If the fall wording legitimately
 * diverges, update FALL_PRE_TEST, update its attribution comment to say what changed and on whose
 * word, and then remove this. It exists so those two edits cannot be separated.
 */
it("keeps the fall pre-test wording identical to spring's (PI-confirmed 2026-07-29)", () => {
  const { label: _springLabel, ...spring } = SPRING_PRE_TEST;
  const { label: _fallLabel, ...fall } = FALL_PRE_TEST;
  expect(fall).toEqual(spring);
  // The labels are deliberately different; they identify the pre-test in log lines.
  expect(FALL_PRE_TEST.label).not.toBe(SPRING_PRE_TEST.label);
});
```

```ts
// fall-random-assignment.ts
import * as functions from "firebase-functions";
import { StepContext, StepResult, readStepOutputField } from "./types";
import { TELL_TEACHER_MESSAGE } from "../portal-api";
import { readDemographics } from "./demographics";
import { FALL_PRE_TEST } from "./pre-tests";
import { getAlternatingAssignment, perClassScope, pooledProgramScope, Arm } from "./assignment-doc";
import { GENDER_RACE_GRADE_MODULE_TABLE, findFullTimeStratum, fullTimeStratumKey } from "./strata-tables";
import {
  classifyFallProgram, teacherSurnameFromClassWord, FULL_TIME_PROGRAM,
  FULL_TIME_DIMENSIONS, FLEX_DIMENSIONS,
} from "./fall-programs";

const STUDENT_FAILURE_MESSAGE =
  "Unable to complete your assignment. Please try again or contact your teacher.";

/**
 * ⚠️ Lowercase, so the derived word is BYTE-IDENTICAL to what the portal stores. The destination
 * classes are created from the same spreadsheet as the origins, so "FT-2026-Bingler-Gator" is stored
 * as "ft-2026-bingler-gator". A mixed-case suffix on a lowercase origin would yield
 * "ft-2026-bingler-Gator", which resolves only through MySQL's case-insensitive utf8 collation. An
 * exact match is available for free, so study enrolment should not depend on a collation default.
 */
const DESTINATION_SUFFIX: Record<Arm, string> = { treatment: "-gator", control: "-shark" };

/**
 * Randomize a fall student and publish their destination class word.
 *
 * The resolved program selects exactly THREE things and no more: the strata table, the demographic
 * input set, and the assignment scope. It does NOT select a pipeline; both cohorts run identical
 * stages, so PIPELINES stays keyed by stage and the dispatcher is untouched.
 *
 * This step performs NO enrolment and no portal write. It derives the destination class word and
 * hands it to REPORT-79's enroll-specified-class step. No raw class ids appear here: the spring
 * treatment_class_id / control_class_id parameters are not used on this path.
 */
export const fallRandomAssignment = async (context: StepContext): Promise<StepResult> => {
  const { jobPath, jobDoc, firebaseJwt, stepResults } = context;
  const { source_key, platform_user_id, platform_id, resource_link_id, context_id, interactiveId } = jobDoc;

  if (!source_key || !platform_user_id || !platform_id || !resource_link_id || !context_id || !interactiveId) {
    const missing = [
      !source_key && "source_key", !platform_user_id && "platform_user_id",
      !platform_id && "platform_id", !resource_link_id && "resource_link_id",
      !context_id && "context_id", !interactiveId && "interactiveId",
    ].filter(Boolean).join(", ");
    functions.logger.error(`fall-random-assignment: missing required context fields: ${missing} for ${jobPath}`);
    return { success: false, message: STUDENT_FAILURE_MESSAGE };
  }
  if (!firebaseJwt) {
    functions.logger.error(`fall-random-assignment: missing Firebase JWT for ${jobPath}`);
    return { success: false, message: STUDENT_FAILURE_MESSAGE };
  }

  // Read the handoff rather than re-reading the offering. No ordering guard: pipeline order is
  // assumed correct, and every fall stage needs the class word, so there is no case in which
  // resolve-origin-class is present but unused. An absent value can therefore only mean a
  // mis-wired stage, which fails on the first harness run; it is handled because the type is
  // optional, not as a defence against our own wiring.
  const originClassWord = readStepOutputField(stepResults, "originClassWord");
  if (!originClassWord) {
    functions.logger.error(
      `fall-random-assignment: no originClassWord handoff (is resolve-origin-class first in this stage?) for ${jobPath}`,
    );
    return { success: false, message: TELL_TEACHER_MESSAGE };
  }

  const program = classifyFallProgram(originClassWord);
  if (!program) {
    // Safe to log the offending word: authored, environment-stable, not PII, not a token. Error
    // level and tell-your-teacher, not the generic bucket: this is permanent until someone edits
    // configuration, so "try again" would be false.
    functions.logger.error(
      `fall-random-assignment: unclassifiable origin class word for ${jobPath}`,
      { origin_class_word: originClassWord },
    );
    return { success: false, message: TELL_TEACHER_MESSAGE };
  }

  const demographics = await readDemographics({
    logPrefix: "fall-random-assignment", jobPath, firebaseJwt,
    source_key: String(source_key), platform_id: String(platform_id),
    resource_link_id: String(resource_link_id), context_id: String(context_id),
    platform_user_id: String(platform_user_id),
    preTest: FALL_PRE_TEST,
    dimensions: program === FULL_TIME_PROGRAM ? FULL_TIME_DIMENSIONS : FLEX_DIMENSIONS,
  });
  if (!demographics.ok) {
    if (demographics.kind === "incomplete") {
      // Carried forward from spring VERBATIM, including that the message names internal dimension
      // labels ("Gender", "Race") rather than the questions as worded. Deliberate here rather than
      // inherited: keeping one message shape across both steps is worth more than better copy on a
      // path that only fires when a student genuinely skipped a question, and full-time can only ever
      // name Gender or Race. Revisit with a student-facing label per dimension on PreTestConfig if the
      // fall run shows students getting stuck here. See finding ST-I1.
      return {
        success: false,
        message: `Please complete the following question(s) before continuing: ${demographics.missing.join(", ")}.`,
      };
    }
    if (demographics.kind === "unmappable") {
      // Permanent until the pre-test or FALL_PRE_TEST is edited, so the generic bucket would be a
      // lie: it says "try again", and no number of retries can map a choice this config lacks. The
      // most likely instance is a gender option the fall pre-test added, which would otherwise dead
      // -end every student who picks it behind an invitation to keep clicking.
      return { success: false, message: TELL_TEACHER_MESSAGE };
    }
    return { success: false, message: STUDENT_FAILURE_MESSAGE };
  }
  const { Gender, Race, Grade, Module } = demographics.categories;

  // Added during implementation, with the Partial above. readDemographics fills only the dimensions
  // it was asked for, so absence here means the dimension set and the table this branch consults
  // have gone out of step. Named rather than interpolated, because "undefined" reaching a stratum
  // key would be diagnosed only by the resulting lookup miss, and a persisted key containing it
  // would outlive the run. Unreachable from data, like the flex branch's unmatched stratum, and
  // classified the same way.
  const required = program === FULL_TIME_PROGRAM ? FULL_TIME_DIMENSIONS : FLEX_DIMENSIONS;
  const unresolved = required.filter(dimension => !demographics.categories[dimension]);
  if (unresolved.length > 0) {
    functions.logger.error(
      `fall-random-assignment: ${program} resolved no category for ${unresolved.join(", ")} for ${jobPath}`,
    );
    return { success: false, message: TELL_TEACHER_MESSAGE };
  }

  let stratumKey: string;
  let n1Assignment: Arm;
  if (program === FULL_TIME_PROGRAM) {
    const surname = teacherSurnameFromClassWord(originClassWord);
    const stratum = findFullTimeStratum(Gender!, Race!, surname);
    if (!stratum) {
      // The surname is what diagnoses the fault, and it is safe to log for the same reasons as the
      // class word. The teacher's FULL name never reaches a log or a StepResult.
      functions.logger.error(
        `fall-random-assignment: no full-time stratum for ${Gender}|${Race} for ${jobPath}`,
        { teacher_surname: surname, origin_class_word: originClassWord },
      );
      return { success: false, message: TELL_TEACHER_MESSAGE };
    }
    // Keyed on the matched row, not on the derived surname or the caller's categories.
    stratumKey = fullTimeStratumKey(stratum);
    n1Assignment = stratum.n1;
  } else {
    stratumKey = `${Gender}|${Race}|${Grade}|${Module}`;
    const flexN1 = GENDER_RACE_GRADE_MODULE_TABLE[stratumKey];
    if (!flexN1) {
      // Unreachable from data: the 24 rows are exactly the cross product of what mapToCategory can
      // emit. Reaching it means the category maps or FLEX_DIMENSIONS were changed and this table
      // was not, which is permanent, so tell-your-teacher rather than the retry message. Spring's
      // equivalent branch keeps its generic message and is not touched.
      functions.logger.error(
        `fall-random-assignment: no matching flex stratum for ${stratumKey} for user ${platform_user_id} at ${jobPath}`,
      );
      return { success: false, message: TELL_TEACHER_MESSAGE };
    }
    n1Assignment = flexN1;
  }

  // Full-time keeps the SHIPPED per-class key, which is what delivers "randomize within teacher".
  // Flex pools across all three sections, which the PI confirmed is one group.
  const scope = program === FULL_TIME_PROGRAM
    ? perClassScope(String(interactiveId), String(platform_id), String(resource_link_id), String(context_id))
    : pooledProgramScope(program, String(interactiveId), String(platform_id));

  try {
    const assignment = await getAlternatingAssignment(
      String(source_key), scope, String(platform_user_id), stratumKey, n1Assignment,
    );
    // ⚠️ The ARM is sticky (the dedup walk returns it), the DESTINATION is not: it is re-derived from
    // whatever origin class word this run resolved. A student whose origin class changes between two
    // clicks therefore keeps their arm and gets the new section's or teacher's destination word. If the
    // first click's enrolment had already succeeded, they end up in two destination classes. Both are
    // in the SAME arm, so no arm is contaminated and study validity is intact; it is a roster tidiness
    // problem, not a data-integrity one. Not persisted alongside the arm on purpose: that would make a
    // legitimate class change unfollowable. See finding ER-I1.
    const destinationClassWord = `${originClassWord}${DESTINATION_SUFFIX[assignment]}`;
    functions.logger.info(
      `fall-random-assignment: ${program} student assigned to ${destinationClassWord} (${jobPath})`,
    );
    return {
      success: true,
      summary: `Assigned to ${destinationClassWord}`,
      output: { destinationClassWord },
    };
  } catch (error) {
    functions.logger.error(`fall-random-assignment: assignment transaction failed for ${jobPath}`, error);
    return { success: false, message: STUDENT_FAILURE_MESSAGE };
  }
};
```

Tests, covering the remaining acceptance criteria. `fall-programs.test.ts` is small and pure:
`ft-` and `fl-` classify, an unprefixed word does not, and `teacherSurnameFromClassWord` returns
`bingler` from `ft-2026-bingler`.

`fall-programs.test.ts` pins the two program ids as literals
(`expect(FLEX_PROGRAM).toBe("fall-2026-flex")`), which is the half of the pooled-document pin that
`assignment-doc.test.ts` deliberately could not make: together they assert that live flex assignments
keep the document id they were written under, so a rename shows up as two failing tests rather than
as a silent re-key. It also pins the casing contract directly, using the study's real class words:
all five `ft-2026-<surname>` words classify as full-time and resolve to their table row, all three
`fl-2026-section<n>` words classify as flex, and the spreadsheet-cased `FT-2026-Bingler` does **not**
classify, which is the assertion that documents why `resolve-origin-class` normalizes rather than
leaving each consumer to cope.

`fall-random-assignment.test.ts` mocks the same way `random-assignment.test.ts` does, plus a mock of
`./assignment-doc` so the scope passed to `getAlternatingAssignment` can be asserted:

- a full-time student is assigned from Gender and Race only, **succeeds with no Grade or Module
  answer docs present**, and receives their teacher's seed arm;
- `ft-2026-bingler` resolves to the row labelled `Alyssa Bingler`;
- two full-time students in different classes with identical demographics both receive their
  teacher's seed and do not alternate against each other, asserted through the scope handed to the
  core (the guard against the collision trap);
- a full-time class word whose surname is absent stops the pipeline with tell-your-teacher and an
  **error** log containing the surname;
- a flex student is assigned using all four dimensions, and the scope handed to the core is the
  pooled one, identical across three different `resource_link_id` / `context_id` pairs (the
  criterion that fails under both the current per-class key and the insufficient "exclude
  `context_id` only" key);
- a class word with neither prefix stops the pipeline with tell-your-teacher and an error log
  containing the word;
- the destination word is the origin word plus `-gator` or `-shark`, byte-identical to the form the
  portal stores, and is published on `output.destinationClassWord`;
- an unmapped gender choice gives **tell-your-teacher**, not the retry message, and logs the
  offending label at error (the reachable, launch-likely case from Open Question 2);
- a Firestore or transport failure still gives the **retry** message, so the split is asserted in
  both directions rather than only the new one;
- `portalTokenFetch` is never called, proving the step makes no portal write of its own;
- no log argument and no returned `StepResult` field contains any of the five full teacher names
  (asserted against the sentinel `Alyssa`, mirroring `enroll-specified-class.test.ts`'s
  `TEACHER_NAME_SENTINEL` approach).

Cross-section alternation itself is proven in `assignment-doc.emulator.test.ts`, where a real
transaction can show it; here the assertion is that the step hands the core the right scope.

**Not in this step, and not in this story**: registering either new step in `PIPELINES`. The fall
stages, their pilot keys and the step order are REPORT-82's, so `index.ts` is untouched and both new
steps are unreferenced production code until that story wires them. Harness fixtures are likewise
out of scope: QA-3 moved the program-level end-to-end runs to REPORT-82, and the stale
`pilot: "fall-2026-fulltime"` in `harness/im-done-local/run-step.js:34` is cleaned up there too.

---

### Add CI for the functions package

**Summary**: Add one job to the workflow that already triggers on `functions/**` so that the lint pass, the unit
suite and **the emulator suite** all run on every push. Scoped into this story deliberately (Doug, 2026-07-29):
this plan constrains `assignment-doc.ts`'s entire import list to keep one emulator test able to import real
production code, and until this job exists nothing anywhere enforces that. Finding DO-I1.

**Files affected**:
- `.github/workflows/firestore-and-query-creator-tests.yml` - add a `test_functions` job beside the existing
  rules and query-creator jobs

**Estimated diff size**: ~18 lines

```yaml
  test_functions:
    name: Functions Lint, Unit and Emulator Tests
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: '22'
      - run: npm install -g firebase-tools
      - run: npm ci
        working-directory: functions
      - run: npm run lint
        working-directory: functions
      - run: npm test
        working-directory: functions
      - run: npm run test:emulator
        working-directory: functions
```

Each line was checked rather than copied from another project:

- **Node 22** matches `functions/package.json`'s `engines.node`. The two existing jobs pin 18, which is right
  for their packages and wrong for this one. `actions/checkout@v4` / `setup-node@v4` rather than the v2/v1 the
  file currently uses, which run on a deprecated runner.
- **`npm ci`** works: `functions/package-lock.json` exists.
- **`npm run lint` and `npm test` are green on `master`**, at 18 suites / 310 passed / 4 skipped.
- **`npm run test:emulator` works from `functions/`** with no extra `-c` flag: the Firebase CLI walks up to the
  repository's `firebase.json`. Confirmed by running it, including against a throwaway
  `*.emulator.test.ts` added for this review. It needs no credentials, exactly like the existing rules job.
- **⚠️ Do NOT add `npm run build` ahead of the test steps.** `tsc` emits compiled copies of every `*.test.ts`
  into `lib/`, jest's `testRegex` then matches them, and four of them fail on jest 24's inability to resolve
  `firebase-admin/auth` through `firebase-admin`'s subpath exports, the same resolution failure that shapes
  this plan's module split. Observed: 36 suites with 4 failing after a build, against 18 suites all passing
  without one. CI never has `lib/` because it is gitignored, so simply not building keeps the job green.
- **Optional, and worth it**: add `"/lib/"` to `jest.testPathIgnorePatterns` in `functions/package.json` so a
  developer who has run `npm run build` locally does not get four spurious failures from stale compiled tests.
  Verified: with `lib/` present, the ignore takes the run from 4 failing suites to 18 passing. Note it does
  **not** affect `test:emulator`, whose inline `--testPathIgnorePatterns` replaces the config value entirely.

---

## Before launch, not a code step

Four checks from requirements.md Open Question 1 remain open. None is a code dependency, and none is covered by
any step above, so they are collected here where an implementer will actually see them (finding PM-I1). All four
bear on `FALL_PRE_TEST`, which ships as a copy of spring's wording **pinned by a test asserting the two are
deep-equal**. If any check comes back different, the correct response is one change that edits the object,
updates its attribution comment and deletes the pin.

| Check | What breaks if it comes back different |
|---|---|
| Eyeball the linked authoring page for a **Module 3** choice | It would fall to `Other` silently, putting those students in the `Other` module stratum rather than a Module 3 one the PI may have intended |
| Confirm the pre-test asks **all four** demographic questions | Full-time reads two, flex needs four; a pre-test authored for full-time alone tells every flex student to "complete" a question that does not exist |
| Confirm **no demographic question is duplicated** across the two Green activities | The answers query spans the whole sequence, and `findAnswerByPrompt` throws on `matches.length > 1`, which is now an `unmappable` and gives tell-your-teacher |
| Confirm the **gender question's answer options** against `genderMap` | `mapToCategory` throws on an unmapped Gender choice. Any option the fall pre-test adds blocks every student who picks it. This is the launch-likely one (ER-4) |

---

## What shipped differently from this plan

Recorded 2026-07-30, after implementation. Every step above landed as written except for the following,
each of which came out of running the code or reviewing it rather than from re-reading the plan. The
code blocks above have been amended in place, so this list is the index rather than the detail.

| Change | Why |
|---|---|
| `fullTimeStratumKey(stratum)` rather than `(stratum, gender, race)` | The row already carries its gender and race, so the extra parameters could disagree with the row they came from. The canonical-source argument for taking the surname from the row applies identically to the other two. |
| `DemographicsOutcome.categories` is `Partial<Record<Dimension, string>>` | The total type promised four values while filling only the requested ones. Under it, the fall step's `String(Gender)` would have interpolated the literal `"undefined"` into a persisted stratum key on a full-time read of a flex dimension. |
| The fall step guards its required dimensions before building a key | The consequence of the `Partial` above. Unreachable from data, exactly like the flex branch's unmatched stratum, and classified the same way (tell-your-teacher, error log). |
| `"/lib/"` added to `jest.testPathIgnorePatterns` in step 7, not step 9 | Step 7 is where the harness fixture change is verified, and the `run-step` driver requires `npm run build`. Once `lib/` exists, jest picks up the compiled test duplicates and four fail. The plan had it as an optional extra on the CI step; it is needed two steps earlier. |
| One extra step-level test in `random-assignment.test.ts` pinning spring's assignment document id | The criterion "a `spring-2026` student's assignment document identity is likewise unchanged" had no home in any step's test list. It is pinned against a direct sha256 of the shipped input string, matching how the per-class id is pinned in `assignment-doc.test.ts`. |
| `random-assignment.test.ts` also loses its `cleanup` describe block | The plan named the matching, mapping and missing-answer blocks. Cleanup moved with them for the same reason: it now tests `readDemographics`, which owns the client Firestore lifetime, so leaving it would have been a duplicate of `demographics.test.ts`'s. |
| One extra step-level test pinning that spring gives an `unmappable` read the same generic message as a `failed` one | Spring's "one message for both remaining kinds" was asserted nowhere, so a later change making spring match the fall step's split would have passed. |

Two things the plan predicted and that held exactly: `readDemographics`'s outer catch had to say
`unexpected error reading demographics` (the extraction landed with **no test file edited** and 231 tests
green), and the de-duplication walk's loop variable had to be `candidate` rather than `stratum` or tslint's
`no-shadowed-variable` fails the build.

---

## Open Questions

### RESOLVED: 1. How strictly should the teacher surname be matched against the table?

**Decision (Doug, 2026-07-29): C, normalize once at the producer, plus B's lowercase suffixes, and
fix the harness fixture.** `resolve-origin-class` publishes `classWord.trim().toLowerCase()`, so
`originClassWord` is by contract always in the portal's stored form. Everything downstream then
matches exactly against lowercase and holds no case-insensitive comparison of its own. The
destination suffixes become `-gator` and `-shark`. The harness stub is corrected to reproduce the
portal's lowercasing rather than echoing whatever a fixture supplies.

**⚠️ This is not the slip-tolerance trade-off the question was originally drafted as. The
case-sensitive version was broken against real data, and would have failed every fall student in
both programs on launch day.**

**What the deep dive found, in rigse** (`~/projects/rigse/rails`):

- `app/models/portal/clazz.rb:28-30` runs `before_validation :class_word_lowercase` (which is
  `self.class_word.downcase!`) and `before_validation :class_word_strip`, on create and on every
  update. **Every class word in the portal is stored lowercased and stripped.**
- `app/models/api/v1/offering.rb:98` serves the **stored** value:
  `self.class_word = offering.clazz.class_word if can_read_class_word?(...)`. So
  `resolveOriginOffering` returns `ft-2026-bingler`, never the spreadsheet's `FT-2026-Bingler`.

Driven against the eight real class words as the portal stores them, the drafted classifier returns
`undefined` for **8 of 8**: `"ft-2026-bingler".startsWith("FT-")` is false, so every fall student
would take the "unclassifiable origin class word" branch and be told to see their teacher. The
surname mismatch is the second failure standing behind the first.

**Two knock-on corrections this forces:**

- **The destination suffix casing.** requirements.md specified `origin + "-Gator"` "matching the
  class-words spreadsheet's casing". That is now impossible: with a lowercase origin it yields the
  mongrel `ft-2026-bingler-Gator`, while the destination class, created from the same spreadsheet,
  is stored as `ft-2026-bingler-gator`. Lowercase suffixes make the derived word byte-identical to
  the stored one. Mixed case would *probably* still resolve, because `portal_clazzes` is
  `charset: "utf8"` with no explicit collation (so `utf8_general_ci`, case-insensitive) and student
  self-registration corroborates that in production, passing the student's typed word straight to
  `find_by_class_word` with no downcasing (`students_controller#check_class_word`,
  `student_registration.rb:25`). Study enrolment should not rest on an implicit collation default
  when an exact match is available for free.
- **The persisted stratum key uses the table's canonical surname**, `Female|White|Bingler`, taken
  from the matched row rather than from the input. The key is a Firestore document key that outlives
  any given run, so it must not vary with the portal's casing.

**Why C over B (case-insensitive comparisons everywhere)**: `originClassWord` is consumed by this
story, by REPORT-80 and by REPORT-82's differential step. Normalizing at the single producer makes
"always in the portal's stored form" an invariant those stories inherit, where scattered
case-insensitive comparisons would let each of them reintroduce the bug independently. The published
value is then not verbatim what the portal returned, which is worth one comment, but since the portal
lowercases it is verbatim in practice.

_Original question: whether the surname match should be exact and case-sensitive (as drafted),
case-insensitive after trim, or exact with a test pinning the five known class words._

---

### RESOLVED: 2. Should an unmatched **flex** stratum give the generic message or tell-your-teacher?

**Decision (Doug, 2026-07-29): D.** The fall flex unmatched stratum gives tell-your-teacher, **and**
`DemographicsOutcome` is split so that an authoring failure (`unmappable`, permanent) is
distinguished from a transport failure (`failed`, retryable), with the fall step giving
tell-your-teacher for the first and the retry message only for the second. **Spring is unchanged**:
it maps both to its existing generic message, so its only delta remains the agreed de-duplication.

**The deep dive moved the target.** Enumerating what `mapToCategory` can emit (Gender and Grade throw
on an unmapped choice rather than inventing a category, Module defaults to `Other`, Race is a
hardcoded binary) gives 2 x 2 x 2 x 3 = 24 keys, and the shipped table is **exactly** those 24: no
reachable stratum is absent and no row is unreachable. The full-time table is likewise a complete
2 x 2 x 5. So:

| Branch | Reachable from portal or answer data? | Permanent? |
|---|---|---|
| Unknown full-time surname | **Yes**: a new teacher, a renamed class, or an origin word that is really a destination word | yes |
| Unmatched flex stratum | **No.** Only a code change to the category maps, or a wrong `FLEX_DIMENSIONS` leaving a category undefined (`Female\|White\|undefined\|Mod1`) | yes |
| Unmatched full-time Gender x Race under a valid surname | **No**, the 20 rows are a full cross product | yes |

The original inconsistency was therefore real but close to cosmetic, since nothing can reach the
flex branch from data. What the enumeration exposed instead is a **reachable** branch with the same
defect: `mapToCategory` throws on an unmapped gender or grade choice, which the drafted code funnels
into `kind: "failed"` and answers with the generic retry message. That is ER-4's launch-day risk. If
the fall Green pre-test's gender question offers any option spring's did not, every student who picks
it is blocked permanently by a message inviting a retry that can never succeed.

The two were conflated only because `kind: "failed"` covered both the per-dimension resolution
errors (thrown by `findAnswerByPrompt` on a duplicated prompt, by `resolveChoices` on an unknown
choice id, and by `mapToCategory` on an unmapped label: all authoring faults, all permanent) and the
outer catch (a Firestore or transport error, genuinely retryable). The existing try/catch structure
already separates them exactly, so the split costs a type member and one branch.

**Why not C** (changing spring too): it buys consistency on a path nobody runs and spends the spring
blast radius this story has carefully limited to one delta. **Why not B alone**: it fixes only the
branch that cannot be reached while leaving the one that can.

_Original question: whether the fall flex unmatched stratum should keep spring's generic message or
use tell-your-teacher, and whether spring should change with it._

---

### RESOLVED: 3. Where should the two `PreTestConfig` objects live?

**Decision (Doug, 2026-07-29): B, plus C's pinning test.** Both objects live in one `pre-tests.ts`,
each step imports its own by name, and a test asserts they are currently deep-equal apart from
`label`.

**What the survey found, including a correction to the question's own premise.** The repo has no
shared configuration module: every step keeps its constants private at module scope
(`STUDENT_FAILURE_MESSAGE` in three steps, `MAX_SUBJECT_LENGTH` in `send-email`, and all of
`random-assignment.ts`'s wording constants). So option A did match convention. Two things outweigh
that.

First, **this plan already breaks that convention deliberately, for exactly this reason**:
`strata-tables.ts` exists so the 24-row and 20-row tables sit side by side, because both are
transcriptions of an external source document and are checked as a unit against requirements.md. The
pre-test configs are the same kind of artifact, roughly 20 lines each of transcribed authored content
whose correctness is judged against something outside the repo (the PI's Slack confirmation). Putting
them together is consistent with a decision this plan has already made rather than a new exception.

Second, **the drift argument the question leaned on is weak, and reviewability is the real axis.**
Working through who would ever edit either object: spring's is dormant and the spec forbids changing
its wording, so nothing will touch it; the fall object is edited only when the PI's wording turns out
to differ, which is an intended edit rather than drift. Accidental divergence is close to impossible
under any option. What is not free is the review: the claim to check on this PR is "the fall object is
identical to spring's, per the PI's confirmation", which under A is a two-file diff of twenty lines
compared by eye, and under B is two adjacent literals.

SE-5's property is untouched, since each step still names its own object by import and neither step
imports the other, so the step remains the selector and nothing is resolved at run time.

**The pinning test is added** because requirements.md asks for the fall wording to be "recorded in
code with that date and attribution, so a reader knows it was verified rather than assumed", and an
executable assertion is a stronger record than a comment. Its value is the forcing function: when the
wording does diverge, the test fails and whoever edits the object has to update the attribution
comment in the same change. It is deliberately a test that will one day be deleted, and it is named
so that this is obvious.

_Original question: whether each step should own its object, whether both belong in one file, and
whether to pin their current equality with a test._

---

### RESOLVED: 4. Are `"full-time"` and `"flex"` the right program strings to commit to?

**Decision (Doug, 2026-07-29): B, year-qualified program ids.** `FallProgramId` is
`"fall-2026-full-time" | "fall-2026-flex"`, declared as two exported constants so the literals live
in one place and the branches read by name. Rationale, in Doug's words: this is a single RCT and
probably will not be repeated, but it might be, and the cost of the qualifier now is nothing.

**What the deep dive found, and why this stopped being a naming question.** `interactiveId` is the
authored embeddable's `ref_id` (`managed-interactive.tsx:388` passes `embeddable.ref_id` into
`buildJobContext`, which sends it as `interactiveId`). It is a property of the **authored activity**,
not of the class, the offering or the year. That makes the two scopes behave differently across
cohorts:

| Scope | Key components | Re-keys for a new cohort? |
|---|---|---|
| Full-time (per-class) | `interactiveId \| platform_id \| resource_link_id \| context_id` | **Yes, automatically.** `resource_link_id` is the offering and `context_id` is the class, so new classes give a fresh document. |
| Flex (pooled) | `interactiveId \| platform_id \| program` | **No.** All three are stable if the same Green activity is reused. |

So an unqualified `"flex"` would silently land a later flex cohort in the fall-2026 document:
alternation counters would continue from wherever fall left off rather than from the table's `n1`,
the document would grow across years against the 1 MiB ceiling, and a student appearing in both
cohorts would keep their original arm through the dedup walk. Nobody would have decided any of that.
The same applies within the study if a second intake ever launches on the same activity in January.
**Pooling quietly removes a safety property the per-class key has for free, and the year in the
program id restores it.**

**Why not D** (keeping `"flex"` as the program id and adding a separate `FLEX_POOL_KEY` constant for
the persisted identity): it is arguably the more precise factoring, since the two strings have
different lifetimes, but it adds a second concept for a study that will most likely run once. One
year-qualified id is simpler to hold in the head, and the immutability warning lives on it directly.

**Kept from D**: a test pinning the pooled document id for known inputs, so a later rename of the
program id fails loudly instead of silently re-keying live assignments.

_Original question: whether to use `"full-time"` / `"flex"`, year-qualified variants, or the `FT` /
`FL` class-word prefixes._

---

### RESOLVED: 5. Is the seven-step commit sequence the right granularity?

**Decision (Doug, 2026-07-29): D, eight steps.** The demographics extraction splits into "extract,
with the existing suite untouched and green" and "retarget the tests to the new seam". Everything
else keeps the drafted order.

**Measured rather than estimated.** The extraction was actually built as a throwaway: `demographics.ts`
(195 lines) and `pre-tests.ts` (21 lines) written, `random-assignment.ts` rewritten as the thin spring
step (450 -> 241 lines, and ~211 once the 24-row table also moves), typechecking clean under `strict`.
Then the full suite was run **with no test file edited at all**:

```
Test Suites: 8 passed, 8 total
Tests:       224 passed, 224 total
```

That result is not automatic, and it constrains the implementation: the existing tests mock
`firebase/firestore`, `../../firebase-client` and `firebase-functions` **by module path**, and jest
applies those mocks to every importer in the file's registry, so `demographics.ts` inherits them. It
also depends on one wording choice, since `random-assignment.test.ts:751` asserts the Firestore-throw
log contains `"unexpected error"`: `readDemographics`'s outer catch must say **"unexpected error
reading demographics"**. With the wording originally drafted here ("failed to read demographics"),
that test fails. Recorded because it is a real constraint, not a stylistic preference.

**Why step 4 had to split.** The production side is about 250 added lines, but retargeting the tests
adds roughly 440 more (mock header ~45, the shared `makeAnswerDoc` / `makeStandardAnswerDocs`
fixtures 121, and the matching, mapping and missing-answer blocks 275) while removing ~275 from
`random-assignment.test.ts`. Around 690 added lines in one commit, well past the ~500 guideline.

**Why splitting production from its tests is right here, against the usual rule.** The usual
objection is that it yields a commit whose tests do not cover the new code. The measurement shows
that is not the case: the tests fully cover the extracted code, just through the step rather than
directly. And "224 tests pass, no test file touched" is the strongest evidence available that a
refactor preserved behaviour, which is precisely what the reviewer of an extraction wants. Editing
the tests in the same commit would destroy that evidence. The 4a commit message should state the
result for that reason.

**Why the same argument does not rescue merging steps 1 to 3** (the original option B): step 1
unavoidably edits tests, since they import `computeAssignmentDocId` and `getAlternatingAssignment`
from `./random-assignment` (`random-assignment.test.ts:63`) and this plan deliberately adds no
pass-through re-export. Merged, the three come to roughly 600 added lines with the one behaviour
change buried in the middle. **Reordering** (option C) was also measured as free and pointless: the
extraction is fully independent of the assignment-document work, so moving it first buys nothing.

_Original question: whether seven steps was too fine, given that the first three all touch one small
module._

---

## Self-Review

_Implementation-spec review, 2026-07-29. Roles: Senior Engineer, QA Engineer, DevOps / Release Engineer,
Security / Privacy Engineer, Education Researcher, Student, Product Manager. WCAG skipped (no UI);
Performance folded into DevOps and Education Researcher._

**Every finding below was verified against running code before it was written.** A throwaway prototype of the
extraction step was built and the suite run against it; a throwaway `assignment-doc.ts` was driven against the
Firestore emulator; the full-time table and the class-word classifier were driven through a script. What was
run is recorded with each finding. The prototype was deleted and the working tree is clean: `npx jest src/tasks`
is back to 8 suites / 224 tests passing.

### Senior Engineer

#### RESOLVED: SE-I1. The drafted `readDemographics` catch wording fails the existing suite, and the plan contains both the right answer and the wrong one

**Resolution (Doug, 2026-07-29): applied.** The code block now uses `unexpected error reading demographics`
and carries a comment saying the wording is load-bearing, with the measurement (223/224 with the drafted
wording) on the spot rather than only in Open Question 5.

_Original finding:_

The extraction step's headline claim is that **no test file is edited and the suite stays green**. As drafted,
that is false. The code block writes:

```ts
functions.logger.error(`${logPrefix}: failed to read demographics for ${jobPath}`, error);
```

while Open Question 5 says, correctly, that the wording **must** be `"unexpected error reading demographics"`
because `random-assignment.test.ts:750-753` asserts the Firestore-throw log contains `"unexpected error"`.

**Verified by building it.** The extraction was implemented exactly as drafted (`demographics.ts` 210 lines,
`pre-tests.ts` 22 lines, `random-assignment.ts` 450 to 240 lines, `tsc --noEmit` clean) and the suite run with
no test file touched:

```
● randomAssignment › Firestore errors › returns failure when Firestore query throws
  Expected: StringContaining "unexpected error", Any<Error>
  Received: "random-assignment: failed to read demographics for sources/test-source/jobs/test-job-123", ...
Tests: 1 failed, 223 passed
```

Changing only that string to OQ5's wording gives `Test Suites: 8 passed, Tests: 224 passed`, which is exactly
the measurement OQ5 reports. So OQ5's prose is right and the code block a reader will copy is wrong.

Suggested resolution: change the code block to `unexpected error reading demographics`, and add a one-line
comment on that catch saying the wording is load-bearing, so the constraint travels with the code rather than
living only in an Open Question 200 lines away.

---

#### RESOLVED: SE-I2. The step-4 line range removes the outer `try`, which two tests require, and leaves the `finally` dangling

**Resolution (Doug, 2026-07-29): applied.** The step now states the resulting shape instead of a line range:
keep the outer `try/catch` around the body through the enrollment tail, delete the `finally` and the
`firestoreCleanup` declaration, and the two tests that depend on the retained catch are named.

_Original finding:_

The step says it replaces `random-assignment.ts:324-388`. Line 326 **is** the `try {`, and lines 438-449 (the
`catch` that logs `"unexpected error"` and the `finally` that calls `firestoreCleanup`) are never mentioned.
The step separately says the client Firestore cleanup now happens inside `readDemographics`, so the `finally`
and its `let firestoreCleanup` must go. An implementer following the range literally gets either a syntax
error or a `finally` referencing a variable that no longer exists.

**Verified both ways.** With the outer `try/catch` retained and only the `finally` deleted, the suite is green
(224). With the outer `try/catch` removed, exactly two tests fail:

```
● randomAssignment › Portal enrollment › fails on network error (fetch throws)
● randomAssignment › alternating assignment integration › returns student-friendly error when transaction fails
```

Both assert `logger.error(stringContaining("unexpected error"), any(Error))`, and both are about the
**enrollment and transaction** tail, not about demographics, so the outer handler has to stay.

Suggested resolution: state the resulting shape explicitly rather than as a line range: keep the outer
`try/catch` wrapping the body from `readDemographics` to the enrollment tail, delete the `finally` block and
the `firestoreCleanup` declaration, and note that two tests depend on the retained catch.

---

#### RESOLVED: SE-I3. "Which the next step addresses" promises a harness fix no step delivers

**Resolution (Doug, 2026-07-29): applied, wording plus two corroborations.** "Which the next step addresses"
becomes "documents rather than removes", with the reason the duplication is kept. The observation that
`run.js:47-53` has always walked every stratum is folded into step 3 as corroboration for the walk, and the
fact that nothing reads the document's `type` is recorded where step 2 relies on it.

_Original finding:_

Step 1 says `computeAssignmentDocId` is not re-exported because "the one external reader
(`harness/im-done-local/run.js`) recomputes the hash itself rather than importing it, **which the next step
addresses**". Step 2 does not address it: it documents the duplication in `perClassScope`'s comment and leaves
the second copy of the formula in place. **Verified**: no step's Files-affected list includes `run.js`, and
`run.js:41-42` still hardcodes the sha256 input.

That is a defensible outcome (the harness is plain JS driving compiled output, and the formula is now pinned by
a test), but the sentence invites a reviewer to look for a fix and find none.

Two things worth folding in while this is being reworded. First, `run.js:47-53` **already walks every stratum**
looking for the student, so the harness has been doing the per-student read this story is adding to production
all along; that is a useful piece of corroboration for step 3. Second, nothing in the repo reads the assignment
document's `type` or identity fields (**verified**: the only readers of `jobs-task-data` are the step itself and
`run.js`, and neither filters on `type`), which is what makes step 2's "both scopes write the same `type`" safe.

Suggested resolution: reword to "which the next step documents rather than removes", and add the two
corroborating observations where they help.

---

#### RESOLVED: SE-I4. The surname derivation reintroduces exactly the fragility Open Question 3 rejected option C for

**Resolution (Doug, 2026-07-29): applied, documented rather than changed.** The function's comment now names
the format assumption it encodes, shows the `ft-2026-van-dyke` mis-derivation, notes that the
five-distinct-surnames guard does not catch it, and records what to do if the roster ever gains a hyphenated
surname. The hyphen split is kept: it is correct for all eight of the study's class words.

_Original finding:_

`teacherSurnameFromClassWord` takes everything after the **last** hyphen. requirements.md Open Question 3
rejected option C (derive the surname from the full name's last whitespace token) as "fragile for no benefit,
deriving a key that could simply be written down and breaking on a two-word surname". The chosen derivation
breaks on the same case from the other end.

**Verified against the study's real class words and against hyphenated variants:**

```
ft-2026-bingler   -> full-time / surname=bingler     (all five resolve)
fl-2026-section1  -> flex      / surname=section1    (all three classify)
ft-2026-van-dyke  -> surname=dyke        <-- wrong
ft-2026-smith-jones -> surname=jones     <-- wrong
```

Also verified, and worth keeping in the spec because it is the evidence for the whole normalization decision:
the spreadsheet-cased words classify **0 of 8**.

This is safe for the current roster and the guard test would not catch it (a hyphenated surname in the table
would still be one distinct surname, and `split(/\s+/).pop()` on "Maria Van Dyke" gives "Dyke", which the class
word would render as `van-dyke`). So it is a latent, roster-change-triggered fault, not a live one.

Suggested resolution: one comment on the function naming the assumption it encodes, that a class word is
`<prefix>-<year>-<single-token surname>`. Optionally, make the lookup match the class word's trailing text
against the table's known surnames instead of splitting on a hyphen, which removes the assumption for about the
same number of lines.

---

#### RESOLVED: SE-I5. "First assignment wins, permanently" is not what the walk guarantees on a legacy document

**Resolution (Doug, 2026-07-29): applied, wording only.** Both specs now say a student who holds an arm keeps
it and is never issued a second one, with the legacy two-arm case and its emulator-observed ordering recorded
as a known imprecision that cannot be made worse.

_Original finding:_

The walk returns the first match found while iterating `Object.values(strata)`. On a document where a student
already holds **two** arms, which is precisely what today's shipped code produces, "first assignment wins"
becomes "whichever stratum Firestore yields first wins".

**Verified on the emulator.** A document was seeded with one student under two strata, deliberately inserted so
that the first-written stratum sorts last:

```
PROBE key order from Firestore: ["Zeta|stratum|written|first","Alpha|stratum|written|second"]
=> walk returned: treatment   (the first-WRITTEN arm, not the lexicographically first)
```

So insertion order was preserved and the intended arm came back, but Firestore does not document map-field
ordering, and this is not something the code asserts. The case is unreachable in practice (`spring-2026` is
dormant, and the fall path's dedup prevents a second assignment from ever being written), so this is a wording
precision point rather than a defect.

Suggested resolution: keep the behaviour, and soften the claim to "returns the student's existing arm and never
issues a second one", noting that a pre-existing double-assigned document (only reachable from a pre-REPORT-81
spring run) resolves to one of the two arbitrarily, and that the student is already enrolled in both classes in
that case, so nothing is made worse.

---

#### RESOLVED: SE-I6. The drafted de-duplication walk fails `npm run lint`

Found in the second verification round, by running `npm run lint` (tslint, a real script in this package) over
the prototyped steps:

```
ERROR: src/tasks/ai4vs-flvs/assignment-doc.ts:49:16 - Shadowed name: 'stratum'
```

The step says it replaces "the `users[platform_user_id]` lookup at `random-assignment.ts:252-255`", so
`const stratum = strata[stratumKey] || {}` at `:249` **stays**, and the walk's `for (const stratum of ...)`
lands in the same function scope. tslint's `no-shadowed-variable` rejects it. The shipped code is currently
lint-clean, so this would be a new error introduced by the story, and it would fail the CI job DO-I1 adds.

**Resolution (Doug, 2026-07-29): applied.** The loop variable is renamed to `candidate`, with a comment saying
why, and the step notes the measurement. Verified: renaming makes `npm run lint` pass, and the rest of the
drafted production code across all eight code steps is lint-clean as drafted. The only other lint errors in the
round were in test files I wrote for the prototype (tslint wants multiple imports from one module combined),
which is a convention worth knowing when writing the real test files but not a defect in the plan.

---

### QA Engineer

#### RESOLVED: QA-I1. Steps 5 and 6 disagree about where the 24-stratum coverage lives, and step 6 edits a file it does not list

**Resolution (Doug, 2026-07-29): applied, keeping the end-to-end coverage.** The 24-stratum `it.each` stays in
`random-assignment.test.ts` as step 5 says; `strata-tables.test.ts`'s version is explicitly additive, with a
comment drawing the division of labour (one proves a stratum resolves, the other pins the literals). Step 6's
"no test file is edited" is now stated in its file list, and "moved from" is gone.

_Original finding:_

Step 5 says `random-assignment.test.ts` "keeps the step-level blocks (request validation, enrollment, **the 24
strata end to end**, alternating integration)". Step 6's `strata-tables.test.ts` then contains:

```ts
it("keeps all 24 flex strata resolvable with their shipped starting arms", () => {
  // ... the full 24 pinned, moved from random-assignment.test.ts's "all 24 assignment strata" ...
```

while step 6's Files-affected list names only `strata-tables.ts` and `strata-tables.test.ts`. Both cannot hold:
either the block stays in `random-assignment.test.ts` (step 5) or it is moved out of it (step 6, which would
then have to list that file).

**Verified what would be lost.** The existing block (`random-assignment.test.ts:530-588`) is an `it.each` over
all 24 strata that drives `randomAssignment` end to end from seeded answer documents and asserts the resulting
class name. A table-contents assertion is strictly weaker: it pins the literal but not that a
`Female|White|High|Mod2` student actually reaches GATOR through prompt matching, choice resolution, category
mapping and key construction. The requirements criterion is "all twenty-four existing strata continue to
**resolve**", which the end-to-end form proves and the literal form does not.

Suggested resolution: keep the end-to-end 24 in `random-assignment.test.ts` as step 5 says, make
`strata-tables.test.ts`'s version an additive pin of the literals (mirroring what the 20-row table gets), and
strike "moved from" from step 6.

---

#### RESOLVED: QA-I2. The emulator test called "pools sections" does not vary the section, so the criterion it is pointed at is not proven there

**Resolution (Doug, 2026-07-29): applied, the test now varies the section.** Both scopes are built from the
three sections' real `(resource_link_id, context_id)` pairs, the one-pooled-versus-three-per-class ids are
asserted, all three students land in one document, and within-section alternation is split into its own test so
each criterion has exactly one home.

_Original finding:_

The test builds its two "sections" as:

```ts
const a = pooledProgramScope("fall-2026-flex", "green", "p1");
const b = pooledProgramScope("fall-2026-flex", "green", "p1");
```

These are the same value. **Verified**: `expect(a.docId).toBe(b.docId)` passes, so the test is
indistinguishable from the same-section alternation case sitting beside it, and it is that *other* criterion it
actually proves. Nothing in the test represents a section at all, which is unavoidable given the design (the
pooled scope deliberately excludes `resource_link_id` and `context_id`), and that is exactly why the test as
named cannot carry the claim.

The "different sections" criterion is in fact covered, twice: by the step-2 unit test asserting three distinct
per-class ids against one pooled id, and by the step-8 assertion that the step hands the core the same pooled
scope for three different `(resource_link_id, context_id)` pairs. So this is a labelling and traceability
problem, not a coverage hole.

**Verified that the rest of the emulator file is sound**: all seven drafted cases were run against the real
emulator and all pass (`Test Suites: 5 passed, Tests: 45 passed` for the whole emulator run, including the
repo's existing two files).

Suggested resolution: either derive both scopes from the three sections' real `(resource_link_id, context_id)`
pairs through the same call the step makes, so the test demonstrates that differing section inputs collapse to
one document, or rename it to what it proves ("two students in one pooled document alternate") and point the
"different sections" criterion at the two tests that do prove it.

---

#### RESOLVED: QA-I3. The alternation test asserts two of the four block boundaries

**Resolution (Doug, 2026-07-29): applied.** The boundary assertion loops over all four boundaries, matching
the claim in its comment.

_Original finding:_

The test comment says "The 4/5 and 8/9 boundaries repeat, which is what makes this five blocks not one
sequence", and asserts those two. **Verified**: all four boundaries repeat.

```
boundaries: 4/5:REPEATS  8/9:REPEATS  12/13:REPEATS  16/17:REPEATS
```

Harmless, because `EXPECTED_N1` pins all twenty values individually (also verified: 20 rows, 5 surnames, 5 full
names, 20 unique keys, 10/10 split, block starts `treatment, control, treatment, control, treatment`, per-cell
seed tilt 3:2 / 3:2 / 2:3 / 2:3, and `full name last token === surname` for all 20). But the assertion covers
less than the sentence claims.

Suggested resolution: loop the boundary assertion over all four, which is the same number of lines and matches
the claim.

---

### DevOps / Release Engineer

#### RESOLVED: DO-I1. Nothing in CI runs the functions suite, so the story's one load-bearing proof runs only when a human remembers

**Resolution (Doug, 2026-07-29): applied as (a), the CI job is in this story.** A new step, "Add CI for the
functions package", adds a `test_functions` job running lint, the unit suite and **the emulator suite** on every
push touching `functions/**`. The module header still records that the import constraint is load-bearing, but it
is now enforced rather than merely documented. Every line of the job was verified: node 22 matches
`engines.node`, `npm ci` has a lockfile, lint and `npx jest` are green on `master` at 18 suites / 310 passed / 4
skipped, and `npm run test:emulator` runs from `functions/` with no credentials and no extra config flag. One
trap is recorded with it: adding `npm run build` before the test steps makes jest pick up compiled duplicates
from `lib/`, four of which fail on the same `firebase-admin/auth` resolution problem that shapes this plan's
module split.

_Original finding:_

The plan constrains `assignment-doc.ts`'s **entire** import list, and puts a prominent header comment on the
module to defend it, so that one emulator test can import real production code. The requirements call that test
"the single behaviour the story invents, and the one a mock cannot establish".

**Verified: no CI job runs it, and no CI job runs the functions unit suite either.**
`.github/workflows/firestore-and-query-creator-tests.yml` triggers on `functions/**`, but its two jobs run
`working-directory: tests` (the Firestore rules suite) and `working-directory: query-creator/create-query`.
Across all five workflow files, `working-directory` is only ever `server`, `tests`, `query-creator/create-query`
or `researcher-reports`. There is no job in `functions`, so neither `npm test` nor `npm run test:emulator` is
ever executed by automation.

This is pre-existing (the repo's two existing `*.emulator.test.ts` files share the gap, and the 224-test unit
suite is in the same position), so fixing CI is arguably not this story's job. What is this story's job is not
resting an architectural constraint on an unenforced test without saying so. As drafted, someone can add
`import * as functions from "firebase-functions"` to `assignment-doc.ts` for one log line, break the property
the header comment defends, and see nothing fail anywhere.

Suggested resolution, in preference order: (a) add a small CI job running `npm ci && npm test` plus
`emulators:exec --only firestore 'jest --testPathPattern emulator'` in `functions`, mirroring the existing rules
job, which is a handful of YAML lines and covers the unit suite too; or (b) if that is out of scope, say in the
step that the proof is manual-run-only, name `npm run test:emulator` as a pre-merge action for this branch, and
note in the header comment that nothing automated enforces it.

---

#### RESOLVED: DO-I2. The contention argument cites the weaker of the two available flags

**Resolution (Doug, 2026-07-29): applied.** requirements.md now cites
`rateLimits: { maxConcurrentDispatches: 1 }` and notes explicitly why `maxInstances: 1` alone would not have
supported the claim.

_Original finding:_

requirements.md says "The worker is already single-concurrency (`maxInstances: 1`), so this changes throughput,
not correctness." **Verified**: the serialization actually comes from `rateLimits: { maxConcurrentDispatches: 1 }`
(`task-worker.ts:70-73`). On a v2 function, `maxInstances` bounds instances, not in-instance concurrency, so on
its own it would not serialize anything.

The conclusion is unchanged and in fact better supported than stated. Only the citation is wrong.

Suggested resolution: cite `rateLimits.maxConcurrentDispatches: 1` (with `maxInstances: 1` alongside it), so
the claim rests on the flag that actually delivers it.

---

### Security / Privacy Engineer

#### RESOLVED: SEC-I1. Five real teachers' full names are being committed to a public repository, in a field the code never reads

**Resolution (Doug, 2026-07-29): not an issue. Teacher names are not PII for this study; only student names
are.** The finding's premise is rejected on the owner's call, so `teacherFullName` stays on every row and the
table stays reproduced in requirements.md. requirements.md records the decision in one line so the question is
not re-opened by the next reader, and `strata-tables.ts`'s row comment is corrected: it had asserted "Real
teacher names are PII", which is now the wrong reason for a warning that is still worth keeping on the narrower
ground that nothing needs the field. Student names never reach this pipeline at all.

_Note for a future reader, not changed here:_ `portal-reads.ts:17-22` still describes `PortalClass.teachers[]`
as "real PII". That comment is now out of step with this ruling. It is existing code this story does not touch,
so it is left alone rather than edited in passing.

_Original finding:_

`strata-tables.ts` carries `teacherFullName` on all 20 rows, with a warning never to log it, never to place it
in a `StepResult`, and never to write it to the assignment document. It is then committed to a world-readable
file, and the same 20 names are reproduced in requirements.md.

**Verified.** `gh repo view concord-consortium/report-service` reports `"isPrivate": false, "visibility":
"PUBLIC"`. The names are already in this branch's committed history (8 occurrences in commit `62f255b`), but
`git ls-remote --heads origin REPORT-81-pilot-configurable-randomization` is **empty** and the branch is
`ahead 2` of `origin/master`, so **nothing has been pushed yet and the decision is still fully reversible.**

What the field buys, precisely: it is read by exactly one test (`teacherFullName.split(/\s+/).pop() === surname`,
which passes for all 20 rows) and by a human comparing the transcription to the PI's document. The stratum key,
the lookup, every log line and the assignment document all use the **surname** only, which is already public in
the class word.

So the marginal exposure is the five **first** names, published against the study's teachers, on a repository
that is indexed and mirrored. That is a small increment over the surname, and it is not nothing: the spec
elsewhere treats teacher names as PII strictly enough to forbid them from a log line that only Concord staff can
read, which is a much smaller audience than GitHub.

Suggested resolution: make this an explicit decision rather than a by-product of "self-documenting rows".
Either (a) keep surnames only in the repo and hold the surname-to-full-name mapping in the oob working note,
with the row comment pointing there, which keeps the transcription checkable for anyone who has the note and
removes the public exposure; or (b) keep the field and record the decision, that the surname is already public
in the class word, that first names add little, and that the PI was asked. Option (a) costs the one test
asserting the surname is the full name's last token, which exists only to check the field being removed.

---

#### RESOLVED: SEC-I2. The spec says class words are "not PII" and then logs both the class word and the teacher's surname

**Resolution (Doug, 2026-07-29): withdrawn, same ruling as SEC-I1.** With teacher names outside the PII
boundary, "authored, environment-stable, neither PII nor a token" is an accurate justification for logging a
class word and a surname, and the scope-rule rewording this finding prompted has been reverted in both specs.
The finding is kept on the record because the reasoning is what established that the class word identifies a
teacher at surname level, which is worth knowing even though it is not a problem.

_Original finding:_

The two new failure logs carry `origin_class_word: "ft-2026-bingler"` and `teacher_surname: "bingler"`, each
justified as "authored, environment-stable, neither PII nor a token". Within a five-teacher study, either value
identifies the teacher as precisely as the full name does. The logging is right, since the offending value is
what diagnoses the fault, but the justification claims more than it can.

Suggested resolution: restate as what it is: surname-level identification of a teacher is accepted in internal
Cloud Logging because it is the only thing that diagnoses these two faults, while first names and full names are
not logged at all. That keeps the distinction the spec is actually drawing (log scope, not "is or is not PII")
and stays consistent with SEC-I1 whichever way it goes.

---

### Education Researcher

#### RESOLVED: ER-I1. The dedup fixes the arm but the destination class word is re-derived on every click, so one double-enrolment path stays open

**Resolution (Doug, 2026-07-29): applied, accepted and documented.** requirements.md gains a bullet under
"Assignment behaviour" saying the dedup fixes the arm and not the destination, naming the window, and stating
that both destinations are in the same arm so validity is intact. The fall step's destination derivation
carries the same note. Persisting the destination beside the arm is recorded as rejected, since it would make a
legitimate mid-study class change unfollowable.

_Original finding:_

ER-1's argument, quoted throughout both specs, is that `add_to_class` only adds, so a second assignment
"cannot move a student, it can only enrol them into a second class alongside the first, **contaminating both
arms**". The walk closes that. What it does not close is the destination.

The arm is now sticky, but `destinationClassWord` is computed fresh each run as
`originClassWord + suffix`, and `originClassWord` comes from the offering **at that moment**. A student whose
origin class changes between two clicks therefore keeps their arm (correct) and gets a **different destination
class word** (also arguably correct), so if the first click's enrolment succeeded and the run then failed before
`lock-activity`, the second click enrols them into a second destination class.

Reachability, checked against the pipeline: `lock-activity` runs after randomization and enrolment
(`index.ts:18-23` for spring, and the fall stages inherit the ordering), so the "enrolled but not locked"
window the spec already relies on for ER-1 is the same window here. Section or teacher changes mid-study are
plausible in an online school, which is exactly why the design keys on teacher rather than class.

**Severity is genuinely lower than ER-1's**, and that is the point of stating it: both destination classes are
in the **same arm**, so no arm is contaminated and the study's validity is intact. The student is in two
sections' Gator classes, which is a roster tidiness problem for a teacher rather than a data-integrity problem
for the PI.

Suggested resolution: one paragraph in requirements.md under "Assignment behaviour" saying the dedup fixes the
**arm**, not the destination, that a mid-study origin change therefore yields a second same-arm enrolment, and
that this is accepted because it cannot cross arms. Optionally note the cheap alternative that was not chosen
(persisting the destination word alongside the arm and reusing it), and why: it would put a second value in the
assignment document and make a legitimate class change unfollowable.

---

### Student

#### RESOLVED: ST-I1. The "please complete these questions" message names internal dimension labels, and the fall step is new code inheriting it

**Resolution (Doug, 2026-07-29): applied, recorded as a deliberate carry-forward.** The fall step's
`incomplete` branch now says the dimension-label wording is inherited on purpose, why one message shape across
both steps is worth more than better copy on this path, and what would change it (a student-facing label per
dimension on `PreTestConfig`) if the fall run shows students getting stuck.

_Original finding:_

The message is built from `Dimension` names, so a student sees "Please complete the following question(s)
before continuing: **Gender, Race**." Those are internal category names, not the questions asked. "Gender"
labels a question worded "What is your sex?", and "Module" labels "Which Algebra 1 module...". A student cannot
reliably map "Gender" back to a question they skipped.

This is carried forward verbatim from spring (`random-assignment.ts:363-371`), and the plan reproduces it in
both steps. It is called out because the **fall step is new code**: it is the moment where the choice becomes a
decision rather than an inheritance, and because full-time reads only two dimensions, a full-time student's
message can only ever name "Gender" or "Race", the two most likely to be misread as something other than a
question.

Suggested resolution: either record it as a deliberate carry-forward in the spec (so it is a decision on the
record and not an oversight), or add a student-facing label per dimension to `PreTestConfig`, roughly four
strings per pre-test, and use those in the message. Not a launch blocker either way.

---

### Product Manager

#### RESOLVED: PM-I1. The four residual launch-checklist items have no owner in the implementation plan

**Resolution (Doug, 2026-07-29): applied.** A "Before launch, not a code step" section now sits ahead of the
Open Questions, listing all four checks against what breaks if each comes back different, and tying them to the
`FALL_PRE_TEST` equality pin that has to be deleted in the same change if any of them moves.

_Original finding:_

requirements.md Open Question 1 leaves four items that are launch blockers rather than code dependencies:
eyeball the linked authoring page for a Module 3 choice, confirm the pre-test asks all four demographic
questions, confirm no demographic question is duplicated across the two Green activities, and confirm the
gender question's answer options against `genderMap`.

**Verified**: none of the four appears anywhere in implementation.md (no match for "checklist", "eyeball" or
"authoring page"), and no step, note or task owns them. The CI step added under DO-I1 is not one either: it
runs the suite, which cannot check what a pre-test asks a student.

They matter to this plan specifically because `FALL_PRE_TEST` ships as a copy of spring's wording **pinned by a
test asserting the two are deep-equal**. If any checklist item comes back different, that test fails, and the
correct response is to edit the object, update its attribution comment and delete the pin, in one change.
That is a good forcing function, but only if someone runs the checks. Right now the checklist lives in a
resolved Open Question in the other file, which is the least likely place an implementer will look.

Suggested resolution: add a short "Before launch, not a code step" section at the end of the plan listing the
four checks, each naming what breaks if it comes back different (a reworded prompt gives a student a "complete
this question" message for a question they answered; a new gender option blocks every student who picks it; a
duplicated prompt throws on `matches.length > 1`). Alternatively put them on the Jira ticket, and link to them
from the step that adds `FALL_PRE_TEST`.

---
