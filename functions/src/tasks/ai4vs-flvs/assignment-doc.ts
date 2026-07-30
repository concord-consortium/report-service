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
 * in harness/im-done-local/run.js, which the harness uses to read back the assigned class.
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
 * ⚠️ Note the SEPARATE namespace prefix rather than an extra "pooled" segment inside the per-class
 * namespace. With an extra segment the two inputs have equal segment counts, so a per-class key
 * whose interactiveId is "pooled" and whose platform_id is the program name hashes identically. A
 * distinct prefix differs at a fixed byte for every possible field value, so no collision exists to
 * reason about.
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

/**
 * Pool per program, across every class in it. Used by fall flex, where the PI confirmed all three
 * sections are one group (Trudi, 2026-07-29).
 *
 * ⚠️ `program` is persisted, both in this hash and in the document's fields. Callers pass a
 * year-qualified id ("fall-2026-flex") because the other two components do NOT distinguish cohorts:
 * interactiveId is the authored embeddable's ref_id, so it survives a new cohort on the same
 * activity, and platform_id is the portal. Unlike the per-class scope, nothing here re-keys itself
 * when the study runs again.
 *
 * ⚠️ The program is IN the key, and must be. resource_link_id is the offering id and an offering is
 * per class per activity, so excluding only context_id would still yield three flex documents;
 * excluding resource_link_id as well leaves interactiveId | platform_id, and one shared Green
 * button gives both programs the same interactiveId, so all eight classes would collapse into one
 * document and full-time's within-teacher balancing would silently stop meaning anything.
 */
export const pooledProgramScope = (
  program: string,
  interactiveId: string,
  platform_id: string,
): AssignmentScope => ({
  docId: computePooledAssignmentDocId(program, interactiveId, platform_id),
  fields: { interactiveId, platform_id, program },
});

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
    const doc = await tx.get(docRef);
    const data = doc.data() || {};
    const strata = data.strata || {};
    const stratum = strata[stratumKey] || {};

    // Per-student de-duplication, NOT per (stratum, student). A student who already holds an arm
    // keeps it and is never issued a second one.
    //
    // Precision, because "first assignment wins" is very slightly stronger than this loop: on a
    // document where a student ALREADY holds two arms (only reachable from a run predating this
    // walk, since the walk prevents a second one from ever being written), the arm returned is
    // whichever stratum Firestore yields first. Checked on the emulator: map fields came back in
    // insertion order, so the first-written arm won, but that ordering is not a documented
    // guarantee. Such a student is already enrolled in both classes, so no choice here makes it
    // worse.
    //
    // Why the walk: the pre-test is locked only AFTER a successful run, so any failure between
    // assignment and lock returns the student to an unlocked pre-test where they can edit an answer
    // and click again. Indexing straight into the CURRENT stratum would not find them, and they
    // would be assigned a second time. Since add_to_class only adds and this pipeline can remove
    // nobody, that does not re-bucket the student: it enrolls them into a second class while
    // leaving them in the first, contaminating both arms invisibly.
    //
    // ⚠️ The walk's reach is bounded by the SCOPE, so it protects a student only for as long as
    // they keep resolving to the same document. A caller passing perClassScope loses the student on
    // a class change (resource_link_id and context_id both move), and they are assigned afresh from
    // the new class's counters, possibly into the opposite arm. pooledProgramScope has no such
    // window within its program. The de-duplication is therefore per (scope, student), and the
    // residual cross-arm case for the per-class callers is accepted and recorded at the call site;
    // closing it would need a scope-independent student->arm index.
    //
    // Returning here writes nothing, deliberately. The current stratum's nextAssignment counter is
    // left untouched, so a re-clicking student never consumes a rotation slot in a stratum they are
    // not counted in, and the next genuinely new student there still receives the arm it specifies.
    //
    // At most 24 strata (the widest table), on a document the transaction already read in full.
    // The loop variable is `candidate` rather than `stratum` because `stratum` above is in the same
    // function scope and tslint's no-shadowed-variable rejects the shadow.
    for (const candidate of Object.values<any>(strata)) {
      const existing = candidate?.users?.[platform_user_id];
      if (existing) {
        return existing as Arm;
      }
    }

    // Determine assignment: use nextAssignment if set, otherwise n1
    const users = stratum.users || {};
    const assignment: Arm = stratum.nextAssignment || n1Assignment;
    const opposite: Arm = assignment === "treatment" ? "control" : "treatment";

    // Write back. `type` names the record kind, not the pooling rule, so both scopes write the
    // same value and an existing document's type field does not change.
    tx.set(docRef, {
      type: ASSIGNMENT_NAMESPACE,
      ...scope.fields,
      strata: {
        ...strata,
        [stratumKey]: {
          nextAssignment: opposite,
          users: { ...users, [platform_user_id]: assignment },
        },
      },
    }, { merge: true });

    return assignment;
  });
};
