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
 * ⚠️ NOTHING AUTOMATED ENFORCES THIS YET. No CI job runs the functions suite, unit or emulator (the
 * workflow that triggers on functions/** runs the tests/ rules suite and query-creator, never this
 * package), so breaking the property above fails no build. Run `npm run test:emulator` by hand
 * before merging anything in this file.
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
  const db = admin.firestore();
  const docId = computeAssignmentDocId(interactiveId, platform_id, resource_link_id, context_id);
  const docRef = db.doc(`sources/${source_key}/jobs-task-data/${docId}`);

  return db.runTransaction(async (tx) => {
    const doc = await tx.get(docRef);
    const data = doc.data() || {};
    const strata = data.strata || {};
    const stratum = strata[stratumKey] || {};
    const users = stratum.users || {};

    // Dedup: if user already assigned, return cached assignment
    if (users[platform_user_id]) {
      return users[platform_user_id] as Arm;
    }

    // Determine assignment: use nextAssignment if set, otherwise n1
    const assignment: Arm = stratum.nextAssignment || n1Assignment;
    const opposite: Arm = assignment === "treatment" ? "control" : "treatment";

    // Write back
    tx.set(docRef, {
      type: ASSIGNMENT_NAMESPACE,
      interactiveId,
      platform_id,
      resource_link_id,
      context_id,
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
