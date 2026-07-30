# Implementation Plan: Offering-state pipeline step

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-80
**Requirements Spec**: [requirements.md](requirements.md)
**Status**: **In Development**

## How this plan was produced

Every step below was **written, compiled and run** in the working tree before being transcribed here,
then reverted. The plan is a transcript of code that passed, not a design sketch. Final state of the
throwaway:

```
npm run build                 clean
npx jest src/tasks            Test Suites: 17 passed, Tests: 390 passed
node harness/.../run-all.js    28/28 scenarios passed
```

The 28 harness scenarios include the four whole-pipeline `lock-*` runs driven through the Firebase
emulator against the stub portal, which are the migrated step's only end-to-end coverage. The spring
path's two-flag write was confirmed on the wire in the stub's request log:

```
[stub] PUT /api/v1/offerings/im-done-offering-1/update_student_metadata -> 200 [lock]
       auth=Bearer <len=21> {"locked":"true","active":"true","user_id":"im-done-student-1"}
```

Two requirements-level corrections this exercise produced are recorded in Open Questions below
(the core's failure variant, and the lock step's summary). Both were found by running the shipped
suite rather than by reading it.

**Baseline note**: the requirements spec's Round 5 baseline of `12 suites / 298 tests` predates the
REPORT-81 merge. The tree's actual baseline before this work is **15 suites / 369 tests**.

---

## Implementation Plan

### Share the arm-suffix literals between the two directions

**Summary**: Moves `DESTINATION_SUFFIX` out of `fall-random-assignment.ts` into `fall-programs.ts`,
which already owns class-word interpretation, and adds the reverse `armFromClassWord` classifier
beside it. Ships first because it is self-contained, touches only REPORT-81 code, and both later
steps depend on it. Nothing else in this plan changes behaviour of an existing step.

**Files affected**:
- `functions/src/tasks/ai4vs-flvs/fall-programs.ts`: receives the constant and the new classifier
- `functions/src/tasks/ai4vs-flvs/fall-random-assignment.ts`: imports instead of holding a private copy
- `functions/src/tasks/ai4vs-flvs/fall-programs.test.ts`: the round-trip assertion, beside the existing `classifyFallProgram` cases

**Estimated diff size**: ~70 lines

Add to the top of `fall-programs.ts`:

```ts
import { Dimension } from "./demographics";
// Type-only, so tsc elides it and fall-programs.js gains no runtime require (verified: the
// compiled module has none at all). `import type` states that rather than leaving it to depend on
// tsconfig lacking isolatedModules, which would otherwise emit a require and drag
// assignment-doc's firebase-admin import into this pure-string module.
import type { Arm } from "./assignment-doc";
```

Append to `fall-programs.ts`:

```ts
/**
 * ⚠️ Lowercase, so a derived word is BYTE-IDENTICAL to what the portal stores. The destination
 * classes are created from the same spreadsheet as the origins, so "FT-2026-Bingler-Gator" is
 * stored as "ft-2026-bingler-gator". A mixed-case suffix on a lowercase origin would yield
 * "ft-2026-bingler-Gator", which resolves only through MySQL's case-insensitive utf8 collation. An
 * exact match is available for free, so study enrolment should not depend on a collation default.
 *
 * ⚠️ BOTH DIRECTIONS MUST SHARE THIS ONE SOURCE OF TRUTH. fall-random-assignment appends a suffix
 * to build the destination word; armFromClassWord below reads a suffix back to classify the arm at
 * the post-test stage. A divergence would classify a "-shark" student as treatment and silently
 * withhold the curriculum they are entitled to. This module owns class-word interpretation, so both
 * live here and step files import them rather than from each other.
 */
export const DESTINATION_SUFFIX: Record<Arm, string> = { treatment: "-gator", control: "-shark" };

/**
 * The reverse of DESTINATION_SUFFIX: classify a study class word back to its arm.
 *
 * `undefined` is a CLASSIFIED FAILURE for the caller, never a default to either arm, matching how
 * classifyFallProgram treats an unrecognized prefix. Defaulting would either open the curriculum to
 * a treatment student who was deliberately locked out of it, or withhold it from a control student.
 *
 * ⚠️ Expects a STUDY subclass word (one that carries a suffix). A registration word for a teacher
 * whose surname happened to be "gator" or "shark" would classify rather than returning undefined,
 * since the match is on the word's ending. Inert as wired (the only caller runs at the post-test
 * stage, which launches from a study subclass, and none of the study's surnames collide), and
 * recorded for the same reason teacherSurnameFromClassWord records its own hyphen assumption.
 */
export const armFromClassWord = (classWord: string): Arm | undefined => {
  const arms = Object.keys(DESTINATION_SUFFIX) as Arm[];
  return arms.find((arm) => classWord.endsWith(DESTINATION_SUFFIX[arm]));
};
```

In `fall-random-assignment.ts`, delete the private `DESTINATION_SUFFIX` block (its doc comment moves
verbatim to `fall-programs.ts` above) and extend the existing import:

```ts
import {
  classifyFallProgram, teacherSurnameFromClassWord, FULL_TIME_PROGRAM,
  FULL_TIME_DIMENSIONS, FLEX_DIMENSIONS, DESTINATION_SUFFIX,
} from "./fall-programs";
```

Append to the existing `fall-programs.test.ts`. It goes there rather than in a new file because it
tests `fall-programs`, and because that suite imports no step module and therefore needs **no
`firebase-functions` mock** (see the Open Question on that constraint):

```ts
describe("arm suffix round-trip", () => {
  const arms: Arm[] = ["treatment", "control"];

  // ⚠️ The two directions must agree or a "-shark" student is classified as treatment at the
  // post-test stage and silently withheld the curriculum they are entitled to.
  it("classifies back to the arm each suffix was built from", () => {
    arms.forEach((arm) => {
      expect(armFromClassWord(`ft-2026-bingler${DESTINATION_SUFFIX[arm]}`)).toBe(arm);
    });
  });

  it("returns undefined for a class word carrying neither suffix, rather than defaulting", () => {
    expect(armFromClassWord("ft-2026-bingler")).toBeUndefined();
    expect(armFromClassWord("fl-2026-section1")).toBeUndefined();
  });
});
```

**Verified**: build clean, full suite green, and `lib/tasks/ai4vs-flvs/fall-programs.js` contains
**zero** `require` calls after the move, so no runtime edge to `assignment-doc` and no
`firebase-admin` drag.

---

### Add the shared offering-state core

**Summary**: The parameterized write, with no caller yet. Discrete because it is the piece both
steps sit on and it introduces no behaviour change on its own. Reviewable against the portal
contract in isolation.

**Files affected**:
- `functions/src/tasks/ai4vs-flvs/offering-state.ts`: new
- `functions/src/tasks/ai4vs-flvs/types.ts`: R9's uniqueness constraint, recorded beside the invariant it sits next to

**Estimated diff size**: ~145 lines

R9 requires that a stage running the core more than once does so through **distinctly named**
pipeline entries, and the resolved decision on `stepResults` keying places that constraint
"alongside the one-producer-per-field invariant `types.ts` already documents for
`readStepOutputField`". It is not there today, and nothing else in this plan would put it there.
This commit is its home, because this is where the library gains a core with more than one caller.
Append to `readStepOutputField`'s doc comment:

```ts
 * ⚠️ RELATED CONSTRAINT, on the writer rather than this reader: pipeline entry `name` values must
 * be UNIQUE within a pipeline. index.ts's `stepResults[step.name] = result` is the single writer,
 * so two entries sharing a name silently lose the first result, and send-email prints one line per
 * key, so the teacher's notification quietly loses a line too. This matters now that one shared
 * core (offering-state.ts) is reached through several named steps: a stage may run lock-current and
 * open-target together, and they must not be named alike. No run-time assertion guards this, on the
 * standing principle that our own pipeline wiring is assumed correct rather than checked.
```

```ts
import { StepContext } from "./types";
import {
  getScopedPortalToken, portalTokenFetch, classifyPortalFailure, PortalFailureBucket,
} from "../portal-api";

/**
 * The `{active, locked}` the portal echoes back from update_student_metadata
 * (`render json: metadata.as_json(only: [:active, :locked])`). Two booleans, no names, so a
 * caller may log it (R20) without reopening R16.
 *
 * Optional because a 2xx with NO body is a supported success on this path and is pinned by a
 * shipped test. Callers must read through the optional rather than off a bare `returned`.
 */
export interface PortalOfferingFlags {
  active?: boolean;
  locked?: boolean;
}

export interface ApplyOfferingStateParams {
  /**
   * `string | number` because the two callers legitimately supply different forms:
   * `resource_link_id` is a decimal string, `PortalOffering.id` is a JSON number. Both
   * interpolate into the request path correctly.
   */
  offeringId: string | number;
  locked: boolean;
  active: boolean;
}

/**
 * A discriminated outcome rather than a StepResult: the core does NOT render student-facing
 * copy. Each caller maps the bucket to its own STUDENT_FAILURE_MESSAGE via messageForBucket,
 * which is what every sibling step in this directory already does, and what lets
 * open-target-offering render its non-portal failures (no match, multiple matches,
 * unclassifiable class word) through that same single path.
 */
export type OfferingStateOutcome =
  | { ok: true; returned?: PortalOfferingFlags }
  | {
      ok: false;
      bucket: PortalFailureBucket;
      /**
       * The portal's status and body for a failed WRITE, so the caller can log the same
       * `Portal returned <status>` diagnostic the shipped step logged, under its own step prefix.
       *
       * Absent for a failed MINT, which is deliberate rather than an omission: mintScopedPortalToken
       * already logs its own failure, and a caller that logged "portal write failed" for a mint
       * failure would name a request that was never issued. So "status is present" means "the write
       * was attempted and rejected", which is exactly what the caller needs to distinguish.
       *
       * Safe to log: update_student_metadata renders only {active, locked}, and its error bodies
       * carry no names.
       */
      status?: number;
      data?: any;
    };

/**
 * Set one student's per-offering state via PUT /api/v1/offerings/:id/update_student_metadata.
 *
 * ⚠️ BOTH FLAGS ARE ALWAYS SENT, and that is a correctness requirement rather than a courtesy.
 * `user_offering_metadata` defaults `active` to true and `locked` to false, and all four portal
 * consumers resolve the effective state as "the row wins IF A ROW EXISTS", not "if the value is
 * non-null" (offering_policy.rb:62, runnables_helper.rb:31, offering.rb:52, clazz.rb:251). So a
 * PUT carrying only `locked` writes only that key, leaving any pre-existing `active: false` row
 * hidden and an unlock pointless. Sending both makes the resulting state fully determined by the
 * request rather than partly inherited. The portal's own teacher UI works around exactly this and
 * says so (offering-progress-row.tsx:34-35).
 *
 * `active` is an explicit argument, not a hardcoded true, so a future hide caller needs no change
 * here. Nothing in this story passes false.
 *
 * This core makes NO host check of its own: like every step in this directory it assumes the
 * pipeline ran validatePortalHost before the loop, and it calls the portal at
 * StepContext.portalOrigin, never at the raw jobDoc.platform_id.
 *
 * It also does NOT log. The logging convention here is per-step (every sibling prefixes its lines
 * with its own step name), and a shared core would emit one prefix for both callers, losing which
 * of the two wrote on a stage that runs both. The response body is therefore threaded out on the
 * success variant for the caller to log.
 */
export const applyOfferingState = async (
  context: StepContext,
  { offeringId, locked, active }: ApplyOfferingStateParams,
): Promise<OfferingStateOutcome> => {
  const { jobDoc, firebaseJwt, tokenCache, portalOrigin } = context;
  const { platform_user_id } = jobDoc;
  const pilot = String(jobDoc.jobInfo.request.pilot);

  // Type narrowing, not a defensive check: both callers validate firebaseJwt first (and log which
  // field was missing), so this is unreachable in a wired pipeline. It returns a bucket rather
  // than asserting non-null so the core has no `!` in it.
  if (!firebaseJwt) {
    return { ok: false, bucket: PortalFailureBucket.TellTeacher };
  }

  // The write acts as a minted teacher of the offering's class, which the ORIGIN (unscoped) mint
  // already satisfies: oidc_mint resolves a no-class_id teacher mint to a teacher of the origin
  // class, and both callers' targets are inside that class. Shared per-run cache, so a stage
  // running several offering-state steps mints once.
  const tokenResult = await getScopedPortalToken({
    cache: tokenCache, portalUrl: portalOrigin, firebaseToken: firebaseJwt, tokenType: "teacher", pilot,
  });
  if (!tokenResult.ok || !tokenResult.token) {
    return { ok: false, bucket: classifyPortalFailure({ status: tokenResult.status, reason: tokenResult.reason }) };
  }

  const response = await portalTokenFetch({
    portalUrl: portalOrigin,
    path: `/api/v1/offerings/${offeringId}/update_student_metadata`,
    method: "PUT",
    token: tokenResult.token,
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      locked: String(locked),
      active: String(active),
      user_id: String(platform_user_id),
    }).toString(),
  });

  if (response.status >= 200 && response.status < 300) {
    // Any 2xx succeeds regardless of body, which is deliberate and pinned by a shipped test. The
    // body is read through a guard because a 2xx with a null body would otherwise raise inside the
    // caller's try, turning a write that ALREADY LANDED into a student-facing failure.
    const data = response.data;
    return { ok: true, returned: data ? { active: data.active, locked: data.locked } : undefined };
  }

  return {
    ok: false,
    bucket: classifyPortalFailure({ status: response.status, reason: response.data?.details?.reason }),
    status: response.status,
    data: response.data,
  };
};
```

**Key ordering detail**: `URLSearchParams` preserves insertion order, so the body is
`locked=...&active=...&user_id=...`. That exact string is what the next step's inherited assertion
pins, so the key order is part of the contract, not incidental.

---

### Migrate the shipped lock step onto the core

**Summary**: Renames `lock-activity` to `lock-current-offering` as a git rename, rewrites it over
the core, repoints spring's pipeline entry, and updates the three dependents the rename breaks. One
code path after this, so spring gains the two-flag write. This is the step that changes shipped
behaviour, and it is deliberately separated from the new open step so a regression here is
bisectable.

**Files affected**:
- `functions/src/tasks/ai4vs-flvs/lock-activity.ts` → `lock-current-offering.ts` (git rename, then rewritten)
- `functions/src/tasks/ai4vs-flvs/lock-activity.test.ts` → `lock-current-offering.test.ts` (git rename, two assertions updated)
- `functions/src/tasks/ai4vs-flvs/index.ts`: import and the `spring-2026` entry's handler
- `functions/src/tasks/ai4vs-flvs/index.test.ts`: **build-breaking**: `jest.mock` is keyed on the module path
- `functions/harness/im-done-local/scenarios.js`: **assertion-breaking**: two `messageIncludes` strings
- `functions/src/tasks/ai4vs-flvs/enroll-specified-class.ts:72`: cosmetic comment reference

**Estimated diff size**: ~200 lines

New `lock-current-offering.ts` (the context validation is carried over from `lock-activity.ts`
unchanged; only the write and the logging move):

```ts
import * as functions from "firebase-functions";
import { StepContext, StepResult } from "./types";
import { messageForBucket } from "../portal-api";
import { applyOfferingState } from "./offering-state";

/**
 * ⚠️ A FAILED LOCK IS A DATA PROBLEM, not merely a bad experience. The researcher tracks
 * completion from the portal's teacher progress roster, whose per-student locked checkbox IS the
 * completion record, and her manual opening of the next sequence is gated on it. A student whose
 * lock failed reads as "not finished" and is passed over. That asymmetry (compare
 * open-target-offering, where a failure costs only automation) is why this message keeps its
 * retry instruction.
 */
const STUDENT_FAILURE_MESSAGE =
  "Unable to record that you finished this activity. Please try again or contact your teacher.";

/**
 * Lock the offering this run launched from, behind the student who just finished it.
 *
 * Serves all three fall stages (pre-test, curriculum, post-test) and the spring pilot, so the
 * message deliberately does NOT name the pre-test. It names what failed ("record that you
 * finished") rather than saying "unable to finish this activity", which was vague about whether
 * the student's answers had been lost: answers are saved continuously by the activity player and
 * are never at risk from this step, so a message reading as a failed submission is both false and
 * counterproductive.
 *
 * Makes NO host check of its own (see offering-state.ts) and issues EXACTLY ONE write with no
 * retry, so a failure leaves portal state untouched by anything this step did after it.
 */
export const lockCurrentOffering = async (context: StepContext): Promise<StepResult> => {
  const { jobPath, jobDoc, firebaseJwt } = context;
  const { platform_id, platform_user_id, resource_link_id } = jobDoc;

  if (!platform_id || !platform_user_id || !resource_link_id) {
    const missing = [
      !platform_id && "platform_id",
      !platform_user_id && "platform_user_id",
      !resource_link_id && "resource_link_id",
    ].filter(Boolean).join(", ");
    functions.logger.error(`lock-current-offering: missing required context fields: ${missing} for ${jobPath}`);
    return { success: false, message: STUDENT_FAILURE_MESSAGE };
  }

  if (!firebaseJwt) {
    functions.logger.error(`lock-current-offering: missing Firebase JWT for ${jobPath}`);
    return { success: false, message: STUDENT_FAILURE_MESSAGE };
  }

  functions.logger.info(
    `lock-current-offering: locking offering ${resource_link_id} for user ${platform_user_id} at ${platform_id} (${jobPath})`
  );

  try {
    const outcome = await applyOfferingState(context, {
      offeringId: resource_link_id,
      locked: true,
      // Nothing in the study hides at class level, and reading the student's current value would
      // cost an extra GET /api/v1/offerings/:id on a path that makes no read at all.
      active: true,
    });

    if (!outcome.ok) {
      // `status` is present only when the write itself was rejected; a failed mint has already
      // logged itself, so this does not claim a request that was never issued.
      if (outcome.status !== undefined) {
        functions.logger.error(
          `lock-current-offering: Portal returned ${outcome.status} for ${jobPath}`,
          { status: outcome.status, data: outcome.data }
        );
      }
      return { success: false, message: messageForBucket(outcome.bucket, STUDENT_FAILURE_MESSAGE) };
    }

    // R20: answers "was this student actually locked?" from our own logs rather than only from
    // the portal roster. Read through the optional: a 2xx with no body is a supported success, and
    // a bare property access here would raise inside this try AFTER the write had already landed.
    functions.logger.info(
      `lock-current-offering: successfully locked offering ${resource_link_id} for user ${platform_user_id} ` +
      `(portal returned active=${outcome.returned?.active} locked=${outcome.returned?.locked}) (${jobPath})`
    );
    // No summary: the step never reads the class, so it holds no offering NAME, and send-email
    // already prints the offering id in its header. An id-only summary would be redundant there.
    return { success: true };
  } catch (error) {
    functions.logger.error(`lock-current-offering: request failed for ${jobPath}`, error);
    return { success: false, message: STUDENT_FAILURE_MESSAGE };
  }
};
```

`index.ts`, two lines. Spring keeps its entry **name** and processing message, so its teacher-email
line and the string a spring student sees are both unmoved:

```diff
-import { lockActivity } from "./lock-activity";
+import { lockCurrentOffering } from "./lock-current-offering";
...
-    { name: "lock-activity", processingMessage: "Locking your pre-test…", handler: lockActivity },
+    { name: "lock-activity", processingMessage: "Locking your pre-test…", handler: lockCurrentOffering },
```

`index.test.ts`, the build-breaking dependent. The mock is keyed on the module path, so the rename
takes all four orchestrator tests with it until repointed. The `stepResults` snapshot key stays
`"lock-activity"` because that is the pipeline **entry name**, which spring keeps:

```diff
-const mockLockActivity = jest.fn();
+const mockLockCurrentOffering = jest.fn();
...
-jest.mock("./lock-activity", () => ({
-  lockActivity: (ctx: StepContext) => {
+jest.mock("./lock-current-offering", () => ({
+  lockCurrentOffering: (ctx: StepContext) => {
     stepResultsSnapshots["lock-activity"] = { ...ctx.stepResults };
-    return mockLockActivity(ctx);
+    return mockLockCurrentOffering(ctx);
   },
 }));
```

`lock-current-offering.test.ts`, **two** assertion updates and no new test. The exact-body assertion
is **updated rather than supplemented**: no spring-specific case is needed, because after the
migration both cohorts run one handler and spring's write is the same request the fall lock issues.

```diff
-        body: "locked=true&user_id=27",
+        body: "locked=true&active=true&user_id=27",
```

```diff
-      expect(result.message).toContain("Unable to lock your pre-test");
+      expect(result.message).toContain("Unable to record that you finished this activity");
```

`scenarios.js`, the assertion-breaking strings. `run.js:98` asserts `messageIncludes`, so these two
go red without the edit, and after the migration they are the migrated step's **only** end-to-end
coverage:

```diff
   "lock-server-error": {
-    expect: { ..., messageIncludes: "Unable to lock your pre-test" },
+    expect: { ..., messageIncludes: "Unable to record that you finished this activity" },
   "lock-network": {
-    expect: { ..., messageIncludes: "Unable to lock your pre-test" },
+    expect: { ..., messageIncludes: "Unable to record that you finished this activity" },
```

The three `failsAt: "lock-activity"` labels are correct untouched: `failsAt` is printed rather than
asserted (`run.js:109-111`), and spring keeps that entry name either way. `send-email.test.ts`'s six
`"lock-activity"` strings are `stepResults` keys, so they also stay correct untouched.

Finally, `enroll-specified-class.ts:72`, cosmetic:

```diff
- * principle is why the consuming steps in REPORT-81 read `originClassWord` ... Like lock-activity /
+ * ... Like lock-current-offering /
```

**Verified**: the inherited suite passes with exactly the two edits above and no others.
`lock-server-error`, `lock-network`, `lock-forbidden` and `happy` all pass end to end through the
emulator, and the happy run's PUT carries both flags.

---

### Add the open-target-offering step

**Summary**: The whole of the new capability: the handoff read, arm classification, the class read,
by-name matching, the self-target guard and the two-flag unlock. Ships as unreferenced production
code, the same way REPORT-81's two steps did; REPORT-82 wires it.

**Files affected**:
- `functions/src/tasks/ai4vs-flvs/open-target-offering.ts`: new (~237 lines)
- `functions/src/tasks/ai4vs-flvs/open-target-offering.test.ts`: new (~326 lines)

**Estimated diff size**: ~563 lines. Over the ~500 guideline; see the Open Question on splitting.

The step, in the order the requirements fix: validate context, read the handoff, classify the arm
(**before any portal call**), mint, read the class, match, self-target guard, write.

```ts
import * as functions from "firebase-functions";
import { StepContext, StepResult, readStepOutputField } from "./types";
import {
  getScopedPortalToken, classifyPortalFailure, messageForBucket, TELL_TEACHER_MESSAGE,
} from "../portal-api";
import { lookupClassByWord, PortalOffering } from "../portal-reads";
import { armFromClassWord } from "./fall-programs";
import { applyOfferingState } from "./offering-state";

/**
 * The curriculum sequence, opened to CONTROL students once they finish the post-test.
 *
 * ⚠️ THIS IS THE RUNNABLE'S NAME AS THE PORTAL SERVES IT, not a label. Portal::Offering#name
 * delegates to the runnable (portal/offering.rb:26), and the portal's copy is a SNAPSHOT taken at
 * publish time: API::V1::ExternalActivitiesController sets `name` from `params.require(:name)` on
 * create and re-permits it on update, so it is not a live delegation to the authoring title.
 * Renaming the sequence in the portal therefore breaks this constant in every subclass at once,
 * and the fix is a report-service deploy. There is deliberately no authored override: a hatch
 * would add a second source of truth in an untyped blob, and fixing the name by editing this line
 * is the same work as authoring one.
 *
 * ⚠️ Written TRIMMED although the authored name carries a trailing space. The comparison below
 * trims both sides, so the space is absorbed. If that trim is ever narrowed to an exact match,
 * this constant breaks against a name that still looks identical.
 *
 * Exported so a unit test can assert the harness fixture in config.js holds the same string; the
 * stub cannot import it without gaining a dependency on a build.
 */
export const TARGET_OFFERING_NAME = "Blue Sequence for AI in Math (FLVS 26-27)";

/**
 * ⚠️ A FAILED OPEN IS AN EXPERIENCE PROBLEM, not a data problem: the student's completion was
 * already recorded by the preceding lock, and the researcher opens sequences by hand regardless,
 * so what is lost is automation. Hence no retry promise, which would be copy that cannot come
 * true: by the time this runs the student has been locked out by the preceding step and cannot
 * re-click. The reassurance is guaranteed by control flow rather than assumed, because a failed
 * lock aborts the pipeline before this step runs.
 */
const STUDENT_FAILURE_MESSAGE =
  "Your work has been saved. We could not open your other activity, so please tell your teacher.";

/** Trimmed and case-insensitive. Normalization, not fuzzy matching; the multiple-match rule below
 * is what keeps that safe. */
const normalizeName = (name: string): string => name.trim().toLowerCase();

/**
 * ⚠️ Skips any offering whose `name` is not a string. This is NOT defensive coding against our own
 * configuration: PortalOffering.name is DECLARED string but the wire can carry null, since
 * external_activities.name is nullable with no presence validation (schema.rb:289-292,
 * external_activity.rb:117), Offering#name delegates to it, and lookupClassByWord hardens the
 * CLASS's fields while passing each offering's through raw. Without the guard a single unnamed
 * SIBLING offering anywhere in the class throws a TypeError that the step's catch turns into the
 * generic retryable message, failing every control student on a condition retry cannot fix, while
 * the target itself is present and correctly named.
 */
const matchesTargetName = (offering: PortalOffering, target: string): boolean =>
  typeof offering.name === "string" && normalizeName(offering.name) === target;

/**
 * Open the curriculum to a control student: unlock it AND make it visible.
 *
 * "Open" means make REACHABLE. An offering whose effective `active` is false is absent from the
 * student's runnable list entirely (clazz.rb:245 student_visible_offerings, runnables_helper.rb:31),
 * so unlocking a hidden offering accomplishes nothing they can see. That is why this step writes
 * `active: true` alongside `locked: false` rather than preserving a state that would defeat it.
 *
 * The target is resolved BY NAME within the student's origin class, never by a database id: ids
 * differ between the staging and production portals and would have to be re-authored per
 * environment. That resolution is also what makes the origin mint sufficient without any
 * pre-write authorization check: the target is selected from the offerings[] of the one class
 * originClassWord names, so it cannot denote an offering outside the class the mint already
 * authorizes. A wrong name yields zero matches and a classified failure, never a cross-class write.
 */
export const openTargetOffering = async (context: StepContext): Promise<StepResult> => {
  const { jobPath, jobDoc, firebaseJwt, tokenCache, portalOrigin, stepResults } = context;
  const { platform_id, platform_user_id, resource_link_id } = jobDoc;
  const pilot = String(jobDoc.jobInfo.request.pilot);

  if (!platform_id || !platform_user_id || !resource_link_id) {
    const missing = [
      !platform_id && "platform_id",
      !platform_user_id && "platform_user_id",
      !resource_link_id && "resource_link_id",
    ].filter(Boolean).join(", ");
    functions.logger.error(`open-target-offering: missing required context fields: ${missing} for ${jobPath}`);
    return { success: false, message: STUDENT_FAILURE_MESSAGE };
  }
  if (!firebaseJwt) {
    functions.logger.error(`open-target-offering: missing Firebase JWT for ${jobPath}`);
    return { success: false, message: STUDENT_FAILURE_MESSAGE };
  }

  // Read the handoff rather than re-reading the offering, with no ordering guard, exactly as
  // fall-random-assignment does. An absent value can only mean a mis-wired stage, which is
  // permanent until someone edits code, so "try again" would be false: the shared
  // TELL_TEACHER_MESSAGE, not this step's own retryable one.
  const originClassWord = readStepOutputField(stepResults, "originClassWord");
  if (!originClassWord) {
    functions.logger.error(
      `open-target-offering: no originClassWord handoff (is resolve-origin-class first in this stage?) for ${jobPath}`,
    );
    return { success: false, message: TELL_TEACHER_MESSAGE };
  }

  // ⚠️ THE ARM CHECK RUNS BEFORE ANY PORTAL CALL, and the ordering is load-bearing rather than
  // stylistic. Roughly half the fall cohort is treatment; a check placed after the class read
  // would have every one of them pay a classes/info read to do nothing, while needlessly holding
  // the metadata[] array (the whole class's progress roster) on a path with no use for it.
  const arm = armFromClassWord(originClassWord);
  if (!arm) {
    // Safe to log the offending word: authored, environment-stable, not PII, not a token.
    functions.logger.error(
      `open-target-offering: unclassifiable origin class word for ${jobPath}`,
      { origin_class_word: originClassWord },
    );
    return { success: false, message: TELL_TEACHER_MESSAGE };
  }
  if (arm === "treatment") {
    // Treatment students completed the curriculum and were deliberately locked out of it at the
    // curriculum stage so they cannot go back and change answers. Opening it to them would
    // undo that. Success with a did-nothing summary, since send-email renders this line.
    functions.logger.info(`open-target-offering: treatment student, nothing to open (${jobPath})`);
    return { success: true, summary: "No activity to open for this student" };
  }

  const target = normalizeName(TARGET_OFFERING_NAME);

  try {
    // classes#info has no per-class authorization at all, so the ORIGIN (unscoped) mint suffices,
    // and it is the same token the write below needs. One cached token, one mint per stage. A
    // class_id-scoped mint here would work but would add a second mint per run for no gain.
    const originToken = await getScopedPortalToken({
      cache: tokenCache, portalUrl: portalOrigin, firebaseToken: firebaseJwt, tokenType: "teacher", pilot,
    });
    if (!originToken.ok || !originToken.token) {
      const mintBucket = classifyPortalFailure({ status: originToken.status, reason: originToken.reason });
      return { success: false, message: messageForBucket(mintBucket, STUDENT_FAILURE_MESSAGE) };
    }

    const lookup = await lookupClassByWord(portalOrigin, originToken.token, originClassWord);
    if (!lookup.class) {
      functions.logger.error(
        `open-target-offering: class lookup failed for ${jobPath}`,
        { status: lookup.status, class_word: originClassWord },
      );
      const lookupBucket = classifyPortalFailure({ status: lookup.status });
      return { success: false, message: messageForBucket(lookupBucket, STUDENT_FAILURE_MESSAGE) };
    }

    const matches = lookup.class.offerings.filter((offering) => matchesTargetName(offering, target));

    if (matches.length === 0) {
      // ⚠️ The class's offering NAMES are logged deliberately, and they are the whole diagnostic
      // value of this branch. Without them the line reads "no offering named X in class Y", which
      // is identical whether the constant is stale after a portal-side rename, the student
      // launched from the wrong class, the target's runnable was archived out of
      // teacher_visible_offerings, or the class was built without the target. Those four have
      // different owners and different fixes. NAMES ONLY, never the offering objects, which would
      // drag metadata[] (every student in the class and their lock state) into a log line.
      functions.logger.error(
        `open-target-offering: no offering matched the target name for ${jobPath}`,
        {
          target_name: TARGET_OFFERING_NAME,
          class_word: originClassWord,
          class_offering_names: lookup.class.offerings.map((offering) => offering.name),
        },
      );
      return { success: false, message: TELL_TEACHER_MESSAGE };
    }

    if (matches.length > 1) {
      // Offering names are not unique in the portal, and guessing a first match would unlock an
      // activity nobody chose.
      functions.logger.error(
        `open-target-offering: target name matched ${matches.length} offerings for ${jobPath}`,
        {
          target_name: TARGET_OFFERING_NAME,
          class_word: originClassWord,
          matched_offering_ids: matches.map((offering) => offering.id),
        },
      );
      return { success: false, message: TELL_TEACHER_MESSAGE };
    }

    const targetOffering = matches[0];

    // ⚠️ TARGET-SELECTION RULE, not an authorization check. It does not ask whether the write is
    // permitted (it is; the acting teacher owns both offerings); it asks whether this step is
    // about to undo the lock the stage just took. The failure it forecloses is a constant naming
    // the sequence the stage LOCKS rather than the one it OPENS, which would write locked:false
    // over the completion record the researcher's roster reads, silently, returning success, on
    // the control arm only. The study class holds exactly two offerings (the post-test, which is
    // this run's own resource_link_id, and the curriculum), so this plus the intended target
    // exhaust every name that resolves at all. Compared as strings: resource_link_id is a decimal
    // string and PortalOffering.id is a JSON number.
    if (String(targetOffering.id) === String(resource_link_id)) {
      functions.logger.error(
        `open-target-offering: target resolved to this run's own offering; refusing to unlock it for ${jobPath}`,
        {
          target_name: TARGET_OFFERING_NAME,
          target_offering_id: targetOffering.id,
          resource_link_id,
        },
      );
      return { success: false, message: TELL_TEACHER_MESSAGE };
    }

    const outcome = await applyOfferingState(context, {
      offeringId: targetOffering.id,
      locked: false,
      // Visibility IS the point here: an offering that is not visible is not reachable however
      // unlocked it is. Unconditional, never echoed from the class body.
      active: true,
    });

    if (!outcome.ok) {
      if (outcome.status !== undefined) {
        functions.logger.error(
          `open-target-offering: Portal returned ${outcome.status} for ${jobPath}`,
          { status: outcome.status, data: outcome.data }
        );
      }
      return { success: false, message: messageForBucket(outcome.bucket, STUDENT_FAILURE_MESSAGE) };
    }

    functions.logger.info(
      `open-target-offering: opened offering ${targetOffering.id} for user ${platform_user_id} ` +
      `(portal returned active=${outcome.returned?.active} locked=${outcome.returned?.locked}) (${jobPath})`
    );
    // summary is rendered into the teacher-notification email: the offering name and the flags
    // written, and nothing off the class body beyond that.
    return { success: true, summary: `Opened ${targetOffering.name} (unlocked and visible)` };
  } catch (error) {
    functions.logger.error(`open-target-offering: unexpected error for ${jobPath}`, error);
    return { success: false, message: STUDENT_FAILURE_MESSAGE };
  }
};
```

The test file follows the sibling convention (mock `getScopedPortalToken` / `portalTokenFetch`, keep
the real classifier, mock the logger). Two fixture choices carry the weight:

- `platform_user_id` is the **string** `"27"` and the target offering's id is the **number** `845`,
  which is the only combination that exercises the self-target comparison's coercion.
- Every offering carries a populated `metadata[]` including a **sentinel** `user_id: 999999` for
  another student, and the class carries a **real teacher name**, so the privacy assertions fail
  loudly rather than by absence.

```ts
const offering = (id: any, name: any, extra: Record<string, any> = {}) => ({
  id,
  name,
  active: true,
  locked: true,
  // ⚠️ classes/info builds metadata with NO user filter, so it is every student in the class.
  // The sentinel id below must never reach a log line or a StepResult.
  metadata: [
    { user_id: 27, active: true, locked: true },
    { user_id: 999999, active: false, locked: true },
  ],
  url: `http://portal/api/v1/offerings/${id}`,
  external_url: `http://portal/activities/${id}`,
  ...extra,
});

/** Route the single mocked fetch by method, so the class read and the write are both covered. */
const routeFetch = (offerings: any[], writeResponse: any = { status: 200, data: { active: true, locked: false } }) =>
  mockPortalTokenFetch.mockImplementation(({ method }: any) =>
    method === "PUT" ? Promise.resolve(writeResponse) : Promise.resolve({ status: 200, data: classBody(offerings) }),
  );

const putCalls = () => mockPortalTokenFetch.mock.calls.filter(([opts]) => opts.method === "PUT");
/** Everything the step logged or returned, as one string, for the privacy assertions. */
const allLoggedText = (result: StepResult) =>
  JSON.stringify([mockLoggerInfo.mock.calls, mockLoggerError.mock.calls, result]);
```

The 17 cases, all passing:

| Group | Case | Pins |
|---|---|---|
| the write | sends BOTH flags, unlocking and revealing the named target | R2, exact body `locked=false&active=true&user_id=27` |
| | matches the target name trimmed and case-insensitively | R7a |
| | writes active=true even when the class reports the target hidden with a contrary row | R2a determinism, against reinstating an echo |
| | still succeeds AND still logs when a 2xx carries a null body | R20's defensive read |
| target selection | fails permanently when no offering matches, logging the class's offering names | R8, R16's allowance |
| | fails rather than guessing when more than one offering matches | R8 |
| | refuses to unlock the run's own offering, comparing a string id against a numeric one | R8a |
| | resolves the target past an unnamed sibling offering | R7a's non-string guard |
| arm classification | does nothing for a treatment student, before any portal call | R1b (asserts no mint AND no fetch) |
| | fails permanently on a class word carrying neither arm suffix | R7b |
| | fails with the SHARED tell-teacher message when the handoff is absent | R7b, asserts it is not the step's own message |
| portal failures | 403 write / 500 write / expired mint | R5, R12, R19a's one-write property |
| privacy | no teacher name and no foreign user_id on success, no-match, self-target | R13b |

**Verified, including that the tests are not vacuous.** Mutating the two guards Round 4 found breaks
exactly the intended tests and nothing else:

- dropping `typeof offering.name === "string"` fails only *resolves the target past an unnamed
  sibling offering*
- replacing the guarded body read with `{ active: data.active }` fails only *still succeeds AND
  still logs when a 2xx carries a null body*

---

### Extend the harness to reach the open path

**Summary**: Driver, fixtures, stub and scenarios. Last because it consumes the exported constant
and the compiled step. Three of these are driver changes rather than scenario additions, which is
the thing the harness README previously got wrong.

**Files affected**:
- `functions/harness/im-done-local/config.js`: the control and treatment class words, the fixture name
- `functions/harness/im-done-local/stub-portal.js`: multi-offering class, echo the write, log `active`
- `functions/harness/im-done-local/run-step.js`: per-scenario step selection, seeded handoff, write-back
- `functions/harness/im-done-local/scenarios.js`: four open-target scenarios
- `functions/harness/im-done-local/README.md`: correct the "Extending it for the fall stories" section
- `functions/src/tasks/ai4vs-flvs/open-target-offering.test.ts`: the fixture-agreement assertions

**Estimated diff size**: ~190 lines

`config.js` gains three exports. The name is a **literal**, not an import of the compiled constant,
because `stub-portal.js` requires only `http`, `fs`, `./config` and `./scenarios` today, and it is
the process the README tells you to start **first**:

```js
// The fall CONTROL subclass. Its word must carry the "-shark" arm suffix, or open-target-offering
// short-circuits on the arm check before the mint, the class read and the name match, and the
// scenario reports a passing tell-your-teacher while the matching logic it exists to prove never
// runs. Neither class word above carries either suffix.
const STUDY_CONTROL_CLASS = { id: 30002, word: "ft-2026-bingler-shark", name: "FT-2026-Bingler-Shark" };

// ⚠️ Must equal TARGET_OFFERING_NAME exported by open-target-offering.ts, or the by-name match
// resolves nothing and every open-target scenario fails. Kept as a LITERAL rather than importing
// the compiled constant, because stub-portal.js requires only http/fs/./config/./scenarios today:
// importing from lib/ would give the stub its first dependency on a build, in the process the
// README says to start FIRST, with no equivalent of run-step.js's existsSync guard and its
// "Run: npm run build" message. A unit test asserts the two strings are equal instead, which gives
// the same rename protection at the level where every other check in this story lives.
const TARGET_OFFERING_NAME = "Blue Sequence for AI in Math (FLVS 26-27)";

// The treatment subclass word. Needs NO class fixture: the arm check short-circuits before any
// portal call, so nothing ever looks this word up.
const TREATMENT_CLASS_WORD = "ft-2026-bingler-gator";
```

`stub-portal.js`: `classInfoFor` takes a **list** of offerings, and the new class holds two, one of
them the run's own `resource_link_id` so the self-target guard's negative case is exercised too:

```js
const studyControlClassInfo = classInfoFor(STUDY_CONTROL_CLASS, [
  { id: "im-done-offering-1", name: "Orange Sequence for AI in Math (FLVS 26-27)", locked: false },
  { id: 845, name: TARGET_OFFERING_NAME, locked: true },
]);
```

and two one-line fixes that make the manual inspections actually readable:

```diff
-      return { status: 200, body: { active: true, locked: true } };
+      // ECHO the request's flags rather than hardcoding {active: true, locked: true}. ...
+      return { status: 200, body: { active: body.active === "true", locked: body.locked === "true" } };
```

```diff
-      return { locked: body.locked, user_id: body.user_id };
+      return { locked: body.locked, active: body.active, user_id: body.user_id };
```

`run-step.js`, the three driver changes:

```js
// Per-scenario step selection. A scenario names the compiled module, the export and the pipeline
// entry name it is written back under; the enroll defaults keep the original scenarios unchanged.
const stepFor = (scenario) => ({
  module: `${LIB}/tasks/ai4vs-flvs/${scenario.stepModule || "enroll-specified-class"}.js`,
  exportName: scenario.stepExport || "enrollSpecifiedClass",
  name: scenario.stepName || "enroll-specified-class",
});

// Seed the handoff a step takes its input from. open-target-offering reads originClassWord out of
// stepResults where enroll-specified-class took its word from a request param, so without this
// every open-target scenario fails the absent-handoff check before reaching anything it tests.
const seedStepResults = (scenario) =>
  scenario.seedOriginClassWord
    ? {
        "resolve-origin-class": {
          success: true,
          summary: `Origin class ${scenario.seedOriginClassWord}`,
          output: { originClassWord: scenario.seedOriginClassWord },
        },
      }
    : {};
```

and in the run loop, the write-back that makes the second run a real re-entry:

```js
  for (const run of [1, 2]) {
    console.log(`\nrun ${run}: entering with stepResults [${Object.keys(context.stepResults).join(", ")}]`);
    const result = await handler(context);
    // Write the result back the way index.ts:81 does, so run 2 is a real re-entry with
    // accumulated state rather than a repeat of run 1's inputs.
    context.stepResults[step.name] = result;
```

Four scenarios: `open-target-happy` (control, resolves among two offerings), `open-target-treatment`
(no portal call at all), `open-target-lookup-forbidden`, `open-target-write-error`.

The fixture-agreement assertions join `open-target-offering.test.ts`, which already imports
`TARGET_OFFERING_NAME` and already mocks `firebase-functions`:

```ts
describe("harness fixture agreement", () => {
  it("serves an offering named exactly the exported target constant", () => {
    expect(harnessConfig.TARGET_OFFERING_NAME).toBe(TARGET_OFFERING_NAME);
  });

  it("serves a control class word that classifies as the control arm", () => {
    expect(armFromClassWord(harnessConfig.STUDY_CONTROL_CLASS.word)).toBe("control");
    expect(armFromClassWord(harnessConfig.TREATMENT_CLASS_WORD)).toBe("treatment");
  });
});
```

**Verified, including the two manual inspections the requirements designate.** All four scenarios
pass on both runs, and the write-back shows up in the driver's own output
(`run 1: entering with stepResults [resolve-origin-class]`, then
`run 2: entering with stepResults [resolve-origin-class, open-target]`). In the stub's log:

- **token reuse**: `open-target-happy` shows **one** mint across both runs; run 2's `classes/info`
  has no preceding mint line.
- **the two-flag write**, now legible because `active` was added to the log:
  `{"locked":"false","active":"true","user_id":"im-done-student-1"}`, against offering **845**, not
  the run's own `im-done-offering-1`, so the by-name match picked the right one of two.
- **the absent PUT**: `open-target-treatment` produces **no stub lines at all**, not merely no PUT.
- **R20's log now agrees with the write**: `portal returned active=true locked=false`. Before the
  echo fix it read `locked=true` for a `locked=false` write.

---

## Cross-reference against the requirements

Every numbered requirement mapped to the step that satisfies it. Steps are referred to by their
short names: **suffix** (share the arm-suffix literals), **core**, **migrate**, **open**, **harness**.

| Req | Step | How |
|---|---|---|
| R1 | core, migrate, open | `applyOfferingState(context, {offeringId, locked, active})`; two zero-config steps over it; `offeringId` typed `string \| number`; the target name an exported module constant |
| R1a | core | discriminated outcome; no student-facing copy in the core. **Amended**: failure also carries `status`/`data` |
| R1b | open | arm classified immediately after the handoff read, before mint or class read; asserted by a test that no fetch **and** no mint occur |
| R2 | core | both flags on every write; `active` an explicit argument |
| R2a | core, open | state set by the request; no read of `metadata[]` anywhere; determinism test drives a contrary row |
| R3 | core | no read-back and no equality check added; portal-side `find_or_create_by` untouched |
| R4 | core | no host check; `portalOrigin` used for every call |
| R5 | core, migrate, open | `classifyPortalFailure` / `messageForBucket` on every failure path |
| R6 | open | target by name; no offering id in authored config |
| R7 | open | `lookupClassByWord` on `originClassWord`, origin unscoped mint shared with the write |
| R7a | open | trimmed, case-insensitive, no URL fallback, non-string names skipped |
| R7b | open | absent handoff and unclassifiable word both `TELL_TEACHER_MESSAGE` at error level |
| R7c | harness | stub's control class carries the curriculum **present but locked** |
| R8 | open | no-match and multiple-match both permanent failures |
| R8a | open | self-target guard, compared as strings, before any write |
| R9 | **core** | **the constraint is recorded in `types.ts`** beside the one-producer-per-field invariant (added by this pass) |
| R10 | open | no pre-write authorization check; the structural guarantee is stated in the step header |
| R11 | core, open | one `tokenCache`, unscoped key `teacher:origin` shared by the class read and the write |
| R12 | migrate, open | the two messages, each as its step's generic-bucket fallback |
| R13 | migrate, open | all 14 listed cases; see the case table in the open step |
| R13a | migrate | the inherited exact-body assertion **updated**, not supplemented; no spring-specific test |
| R13b | open | privacy assertions on success, no-match and self-target, with a sentinel `user_id` |
| R14 | harness | `open-target-happy` twice, per-scenario step selection, seeded handoff, `stepResults` write-back |
| R14a | harness | `open-target-treatment`, asserting success and the did-nothing summary |
| R15 | harness | multi-offering class, one named exactly the constant, plus the equality test |
| R15b | harness | `-shark` word carries the multi-offering list; `-gator` word needs no class fixture |
| R15c | harness | stub logs `active` and echoes the request's flags |
| R16 | open | no `students[]`, `teachers[]` or `metadata[]` logged; offering **names** logged on the no-match branch. **Clarified**: constrains a summary's content, does not require one |
| R18 | suffix | literals moved to `fall-programs.ts`, round-trip test |
| R19 | migrate | the severity asymmetry recorded in the step header |
| R19a | migrate, open | exactly one write, no retry; asserted at the unit level |
| R20 | migrate, open | the returned flags logged, read defensively; null-body case asserted |

**Withdrawn requirements confirmed not implemented**: R15a (the stub metadata fixture) and R17
(narrowing `PortalOffering.metadata`). `portal-reads.ts` is untouched, as the requirements' own
"Deliberately not touched" list requires.

**Orphan check**: one piece of the plan traces to no numbered requirement, the `status`/`data` on
the core's failure variant. It exists to preserve a diagnostic the shipped step already logged, and
it is the subject of the R1a amendment rather than new scope.

**Commit sizes**: 70, 145, 200, 563, 190. One over the ~500 guideline, resolved below.

**Ordering**: no step depends on a later one. `suffix` and `core` are both consumed by `open`;
`harness` consumes the constant `open` exports. Each commit builds and passes on its own.

### What this pass changed

1. **R9 had no implementation at all.** The resolved decision on `stepResults` keying says the
   uniqueness constraint is written down "alongside the one-producer-per-field invariant `types.ts`
   already documents". Verified that `types.ts` says nothing about entry-name uniqueness, and that
   the requirements' own "Files this story touches" list omits `types.ts`, so the obligation was
   dropped by both documents rather than by one. Now assigned to the core step. It is the only
   requirement this pass found unimplemented.
2. **Two tests were in the wrong file**, which the coverage table made visible: a new
   `offering-state.test.ts` that tested nothing in `offering-state.ts`. Redistributed, and the file
   dropped.

## Open Questions

### RESOLVED: The core's failure variant carries only a bucket, which loses a shipped diagnostic

**Context**: R1a specifies the core returns "failure carrying a `PortalFailureBucket`". Implementing
that literally and running the inherited suite produced a real failure:

```
● lockCurrentOffering › Portal error responses › returns the tell-teacher message on 403
    Expected: StringContaining "Portal returned 403", ObjectContaining {"status": 403}
    Received: "lock-current-offering: portal write failed for ...", {"bucket": "tell_teacher"}
```

The shipped `lock-activity` logs `Portal returned ${status}` with `{ status, data }`. A bucket-only
outcome cannot reproduce that, because the status is visible only inside the core.

**Options considered**:
- A) Accept the loss and update the assertion to check the bucket.
- B) Let the core log the failure, with a shared prefix.
- C) Carry `status` and `data` on the failure variant; each step logs under its own prefix.

**Decision**: **C**, and the inherited assertion then passes untouched. B is rejected for the same
reason R1a already rejects core-side success logging: one prefix for both callers loses attribution
on a stage that runs both. A discards a diagnostic that costs nothing to keep.

`status` is deliberately **absent for a mint failure**, because `mintScopedPortalToken` already logs
its own, and a step that logged "portal write failed" for a mint failure would name a request that
was never issued. So "status is present" means "the write was attempted and rejected". Privacy is
unaffected: `update_student_metadata` renders only `{active, locked}`, and its error bodies carry no
names. **This is an amendment to R1a and should be reflected there.**

---

### RESOLVED: Does `lockCurrentOffering` return a summary?

**Context**: R16 says "The step's `summary` names the offering and the flags it wrote". The shipped
step returns bare `{ success: true }`, and `send-email` renders `result.summary ?? result.message ??
"completed"` as one line per step.

**Decision**: **No summary on the lock path.** The step never reads the class, so it holds no
offering **name**, only an id, and `send-email` already prints `Offering: <resource_link_id>` in its
header. A summary of "Locked offering 1194" would be a redundant id in a human-facing email. Keeping
`{ success: true }` also leaves spring's email line byte-identical (`- lock-activity: completed`).
`openTargetOffering` does carry a summary, because it has the name. R16 is satisfied either way: it
constrains what a summary may contain, not that one must exist.

---

### RESOLVED: How does the core satisfy the compiler on `firebaseJwt`?

**Context**: `StepContext.firebaseJwt` is optional; `getScopedPortalToken` needs a `string`. Both
steps validate it first (and log which field was missing), so by the time the core runs it is
present, but the compiler does not know that.

**Decision**: the core guards and returns `{ ok: false, bucket: TellTeacher }`. Rejected: a non-null
assertion (`firebaseJwt!`), which hides the narrowing; and adding `firebaseToken` to the params
object, which deviates from R1's stated signature. The guard is **type narrowing, not a defensive
check**, and is unreachable in a wired pipeline; the code comment says so, so it is not mistaken for
the run-time checking of our own wiring that this codebase declines elsewhere.

---

### RESOLVED: Where the two new tests live (cross-reference pass)

**Context**: as first drafted, both the R18 round-trip assertion and the R15 fixture-agreement
assertion went into a new `offering-state.test.ts`. The cross-reference pass found that file
contained **no tests of `offering-state.ts`**, was created one commit before the module it is named
after, and needed a `firebase-functions` mock only because of what had been put in it.

**Decision**: the file is dropped. The round-trip assertion goes in the existing
`fall-programs.test.ts`, which is what it tests and which needs no mock; the fixture-agreement
assertion goes in `open-target-offering.test.ts`, which already imports the constant and already
mocks the logger. The core itself keeps no dedicated test file: it is exercised through both callers,
which is where R13 places every case.

---

### RESOLVED: Any test importing a step module must mock `firebase-functions`

**Context**: `offering-state.test.ts` imports the step for its exported constant and asserts no
logging, so it initially had no logger mock. The suite then failed to run at all:

```
● Test suite failed to run
    Cannot find module 'firebase-admin/auth' from 'identity.js'
```

**Decision**: mock `firebase-functions` in any test file that imports a step, whether or not it
asserts on logs. This is the constraint `assignment-doc.ts`'s header records, met from the other
direction: the step imports `firebase-functions`, whose chain reaches `firebase-admin/auth`, which
jest 24 cannot resolve. The comment in the test file records it so the next person does not
rediscover it as a mysterious module-resolution error.

---

### RESOLVED: Should the open-target step be split into two commits?

**Context**: that step is ~563 lines (237 production, 326 test), over the ~500-line guideline. The
other four steps are 70, 135, 200 and 190.

**Options considered**:
- A) **Leave it as one commit.** The overrun is entirely test code, the step is one coherent unit,
  and splitting the tests out would create a commit where new production code lands untested.
- B) Split the test file, keeping the four "the write" cases with the step and moving target
  selection, arm classification, portal failures and privacy to a follow-up commit.
- C) Split the production code by extracting name matching into its own module with its own test.

**Decision**: **A.** The guideline is about reviewability, and a reviewer reads this step as one
thing; the test file is mechanical and repetitive rather than dense. C is the worst option: the
matcher is 3 lines and its own comment is longer than the code. B is rejected because it would land
new production code with only a quarter of its tests, which is a worse property than an over-long
commit.

---

### RESOLVED: Should step ordering put the harness before or after the open step?

**Context**: as planned, the open step (fourth) ships before the harness work (fifth) that can
exercise it. So there is one commit in which `openTargetOffering` exists with unit tests but no
harness scenario. The reverse order is not possible as written: the harness scenarios import the
step and the fixture-agreement test imports its exported constant, so the harness commit would not
build.

**Options considered**:
- A) **Keep the order.** Unit tests cover the step fully at that commit; the harness adds end-to-end
  confidence in the next one.
- B) Merge steps four and five into one commit, so the step never lands without harness coverage.
  That commit would be ~750 lines.

**Decision**: **A**, since every commit in the plan builds and passes on its own, which is the
property that matters for bisecting. The intermediate state is not a gap in coverage: the step's
unit tests land in the same commit as the step, and what the harness adds in the next commit is
end-to-end confidence rather than first coverage.

---

## Residual carried to REPORT-82

Unchanged by this plan and repeated here because it is the one thing implementation cannot close:
**the exported constant has never been checked against a portal-served offering name.** There are no
fall classes on staging or production yet, so there is nothing to read. The rigse evidence found
while writing this plan makes the check mandatory rather than prudent: `ExternalActivity.name` is set
from `params.require(:name)` at publish time and re-permitted on update
(`api/v1/external_activities_controller.rb:14,42,78`), so the portal holds a **snapshot copied at
publish**, not a live delegation to the authoring title. Reading
`authoring.concord.org/api/v1/sequences/845.json` therefore cannot settle it at any point.

Once the `-shark` classes exist, one request settles it, and it also confirms R7c's "present but
locked" in the same body:

```
GET /api/v1/classes/info?class_word=<a fall -shark word>   # with a teacher token
```

Compare the target's `name` against `TARGET_OFFERING_NAME` modulo trim and case folding. Nothing
else catches a mismatch: the unit fixtures and the harness stub are both configured **from** the
constant, so they agree with whatever value it holds, and the only run-time signal is the no-match
failure, which fires solely when a control student finishes the post-test, the last event in the
study.
