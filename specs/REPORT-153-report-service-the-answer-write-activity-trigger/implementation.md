# Implementation Plan: report-service: the answer-write activity trigger

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-153
**Requirements Spec**: [requirements.md](requirements.md)
**Status**: **In Development**

## Implementation Plan

The branch sits on `master` at `1c3df21`, which carries REPORT-143 (R14); if `master` has moved, rebase onto it first. Then five commits and a deploy to report-service-dev: a docs fix to REPORT-168's closed spec, and four for this story. The first two code commits touch only `functions/` and import REPORT-143's `PLATFORM_USER_ID` (`storage-policy.ts:3`); the third adds to REPORT-143's rules block (`firestore.rules:354`). Functions tests run on Node 22 with `npm test` and `npm run test:emulator`; the rules tests run in `tests/` under Node 18 with the emulator from the functions' firebase-tools 15 on Node 22, as REPORT-143's spec describes.

### REPORT-168's closed spec: what REPORT-169 does with a retrying run

**Summary**: A docs-only commit, separate from this story's code. `specs/REPORT-168-report-server-a-report-run-that-can-t-start-fails.md` says REPORT-169 makes cc-data stop waiting on a retrying run. REPORT-169 does the reverse: cc-data keeps waiting through a retry until the server fails the run under REPORT-168's R4 bound. It stops early only after four NOT_READY answers whose state, id and error are all null, which only servers without REPORT-168 send.

**Files affected**: `specs/REPORT-168-report-server-a-report-run-that-can-t-start-fails.md` (lines as at `1c3df21`, unchanged since `bfbda61`)
- Line 11: "makes cc-data stop waiting on a run that is retrying" becomes "makes cc-data stop waiting on a run that never starts".
- Line 43: "A client can stop early on a non-null `athena_query_error` with a null state." becomes "REPORT-169's cc-data keeps waiting through a retry (a non-null `athena_query_error` with a null state) until the run answers `failed`, and stops early only after four NOT_READY answers whose state, id and error are all null." The sentence after it, about older servers, stays.
- Line 69: "stop waiting on a retrying run" becomes "stop waiting on a run that never starts".

**Estimated diff size**: 3 lines

---

### The activity update, its path and its tests

**Summary**: A firebase-admin-only module that decides whether an answer write qualifies (R3, R4) and makes the one merge write (R2, R5), with the path helper and a single `CLASS_HASH`; `handleAnswerWrite` is the whole of what the trigger does. Unit tests cover every exclusion; emulator tests cover the write, the exclusions writing nothing, and concurrency (R10). Nothing is registered as a function yet, so this commit changes no deployed behavior.

**Files affected**:
- `functions/src/researcher-dashboard/firestore-paths.ts`: `CLASS_HASH` and `activityUserPath`
- `functions/src/researcher-dashboard/run-package.ts`, `derive-profile-route.ts`: import `CLASS_HASH`, delete their copies
- `functions/src/researcher-dashboard/activity.ts`: new, importing `PLATFORM_USER_ID` from REPORT-143's `storage-policy.ts`
- `functions/src/researcher-dashboard/activity.test.ts`: new
- `functions/src/researcher-dashboard/activity.emulator.test.ts`: new

**Estimated diff size**: ~230 lines

`firestore-paths.ts` gains:

```ts
// rigse's SecureRandom.hex(24); it becomes a Firestore path segment
export const CLASS_HASH = /^[0-9a-f]{48}$/

export const activityUserPath = (portal: string, classHash: string, platformUserId: string) =>
  `${root(portal)}/activity/${classHash}/users/${platformUserId}`
```

`run-package.ts` deletes `const CLASS_HASH = …` and its comment and adds `CLASS_HASH` to its existing `./firestore-paths` import (tslint's `no-duplicate-imports` refuses a second import line); `derive-profile-route.ts` does the same with a new `import { CLASS_HASH } from "./firestore-paths"`.

`activity.ts`:

```ts
import admin from "firebase-admin"
import { activityUserPath, CLASS_HASH, portalSegment } from "./firestore-paths"
import { PLATFORM_USER_ID } from "./storage-policy"

type AnswerFields = Record<string, unknown>

export type Skip =
  | "deleted" | "no_class" | "moved" | "unchanged"
  | "bad_platform_id" | "bad_class_hash" | "bad_user_id" | "bad_resource_link_id"

export interface ActivityTarget { path: string; resourceLinkId: string }

const present = (v: unknown) => (typeof v === "string" && v !== "") || typeof v === "number"
// The Activity Player sets these afresh on every save, so they differ even when nothing else does
const PER_SAVE = ["created", "interactive_state_history_id"]
const content = (answer: AnswerFields) =>
  JSON.stringify(Object.fromEntries(Object.entries(answer).filter(([k]) => !PER_SAVE.includes(k))))
const sameContent = (before: AnswerFields, after: AnswerFields) => content(before) === content(after)
// A portal offering id; it becomes a key of the `changed` map, which no rule pins
const OFFERING_ID = /^[1-9][0-9]*$/

// Which learner's activity document an answer write updates, or why it updates none.
export function activityTarget(before: AnswerFields | undefined, after: AnswerFields | undefined):
  ActivityTarget | { skip: Skip } {
  if (!after) {
    return { skip: "deleted" }
  }
  const { platform_id, platform_user_id, context_id, resource_link_id } = after
  if (![platform_id, platform_user_id, context_id, resource_link_id].every(present)) {
    return { skip: "no_class" }
  }
  if (before && (before.context_id !== context_id || String(before.platform_user_id) !== String(platform_user_id))) {
    return { skip: "moved" }
  }
  if (before && sameContent(before, after)) {
    return { skip: "unchanged" }
  }
  let portal = ""
  try {
    portal = portalSegment(String(platform_id))
  } catch {
    // an unparseable URL leaves portal empty, as a hostless one ("foo:bar") does
  }
  if (portal === "") {
    return { skip: "bad_platform_id" }
  }
  if (!CLASS_HASH.test(String(context_id))) {
    return { skip: "bad_class_hash" }
  }
  if (!PLATFORM_USER_ID.test(String(platform_user_id))) {
    return { skip: "bad_user_id" }
  }
  if (!OFFERING_ID.test(String(resource_link_id))) {
    return { skip: "bad_resource_link_id" }
  }
  return {
    path: activityUserPath(portal, String(context_id), String(platform_user_id)),
    resourceLinkId: String(resource_link_id)
  }
}

// One write, no read: the three fields of the activity document contract.
export function recordActivity(db: admin.firestore.Firestore, target: ActivityTarget) {
  const now = admin.firestore.FieldValue.serverTimestamp()
  return db.doc(target.path).set({
    lastActivityAt: now,
    writeCount: admin.firestore.FieldValue.increment(1),
    changed: { [target.resourceLinkId]: now }
  }, { merge: true })
}

// Records an answer write's activity, or answers why it records none.
export async function handleAnswerWrite(
  db: admin.firestore.Firestore, before: AnswerFields | undefined, after: AnswerFields | undefined
): Promise<Skip | null> {
  const target = activityTarget(before, after)
  if ("skip" in target) {
    return target.skip
  }
  await recordActivity(db, target)
  return null
}
```

The `before.context_id !== context_id` check runs only when `before` exists, so a create always passes it. `content` serializes both snapshots without `created` and `interactive_state_history_id` (`activity-player/src/firebase-db.ts:557`, `createAnswerDoc`), so an Activity Player re-save of unchanged content compares equal. If two snapshots ever came back with their keys in different orders, the re-save would count as a change, which only over-reports.

**Tests** (`activity.test.ts`, no emulator. The answer fixture is built inline in the test file, with the fields `answerDoc` in `test/seed-helpers.ts` uses, a 48-hex `context_id` and a numeric `platform_user_id`: `seed-helpers.ts` imports `emulator-setup.ts`, which throws when `FIRESTORE_EMULATOR_HOST` is unset, so a unit test cannot import it):
- A create qualifies, with the path `researcher_dashboard/learn_concord_org/activity/<hash>/users/1234` for `platform_id: "https://learn.concord.org"`, and `resourceLinkId` the answer's `resource_link_id`.
- An update with a changed `report_state` and a new `created` qualifies.
- A collaborator's copy (`collaboration_owner_id` another user) qualifies, with the path under the collaborator's `platform_user_id`; so does a later save of that answer that keeps the copy's `collaboration_owner_id`.
- Each skip, one case apiece: a delete; an anonymous answer (`run_key`, no `platform_id`); each of the four class fields missing in turn, as one `it.each` table whose every row asserts `{ skip: "no_class" }` exactly (Jest refuses an empty `.each` table, so the table cannot silently test nothing; a row that only asserted some skip would pass when `present` checks fewer fields, since the later `bad_*` checks still refuse the row); a `context_id` changed by a move; a re-save whose only differences are `created` and `interactive_state_history_id` (`unchanged`); a `platform_id` that is not a URL; a `platform_id` that parses with an empty host (`"foo:bar"`); a `context_id` with a `/` in it; a `platform_user_id` of `"12/34"` and one of `"0123"`; a `resource_link_id` of `"__x__"`, which Firestore refuses as a field name.
- `run-package.test.ts` and `derive-profile-route.test.ts` pass unchanged, which is what shows the shared `CLASS_HASH` matches the copies it replaced.

**Tests** (`activity.emulator.test.ts`, importing `../test/emulator-setup` first; each test uses its own class hash, since `clearFirestore` clears only `sources`):
- One `recordActivity` creates the document with `writeCount: 1`, a `Timestamp` `lastActivityAt` and one `changed` key; a second for another assignment gives `writeCount: 2`, two keys, the first key's time unchanged and `lastActivityAt` strictly later (sequential emulator writes move it forward, Open Questions in requirements.md, so a constant would fail this).
- The document has exactly the keys `lastActivityAt`, `writeCount`, `changed` (R5).
- Through `handleAnswerWrite`, under a class hash of its own: a qualifying create writes its document, then a delete, an anonymous answer, a move and a re-save differing only in `created` each answer their skip and leave the class's `users` collection holding only that first document. The qualifying write first shows the path is the one being watched, so an empty result cannot come from looking in the wrong place; letting `unchanged` through fails it.
- 30 learners times 5 writes in parallel: no rejection, 30 documents, `writeCount`s summing to 150. A fixture returning the same value for every learner could not tell this from "last write wins", so each learner's count is asserted to be 5 as well.

---

### The trigger

**Summary**: Registers `researcherDashboardActivity` on answer writes with retries (R1), calling `handleAnswerWrite`, and logs each skip that indicates bad data. A thin file, as `chat-tutor.ts` is.

**Files affected**:
- `functions/src/researcher-dashboard/activity-trigger.ts`: new
- `functions/src/researcher-dashboard/index.ts`: re-export
- `functions/src/index.ts`: add to the imports and `module.exports`

**Estimated diff size**: ~40 lines

```ts
import admin from "firebase-admin"
import * as functions from "firebase-functions"
import { handleAnswerWrite, Skip } from "./activity"

const ANSWERS = "sources/{source}/answers/{answerId}"
const BAD_DATA = new Set<Skip>(["bad_platform_id", "bad_class_hash", "bad_user_id", "bad_resource_link_id"])

// The per-learner activity document the dashboard listens to, updated on every qualifying answer write.
// Retried on failure: a lost delivery of a lesson's last save would leave a result never marked behind.
export const researcherDashboardActivity = functions
  .runWith({ failurePolicy: true })
  .firestore.document(ANSWERS)
  .onWrite(async (change, context) => {
    const skip = await handleAnswerWrite(admin.firestore(), change.before.data(), change.after.data())
    if (skip && BAD_DATA.has(skip)) {
      functions.logger.warn("activity.skipped", { reason: skip, ...context.params })
    }
    return null
  })
```

`researcher-dashboard/index.ts` adds `export { researcherDashboardActivity } from "./activity-trigger"`; `functions/src/index.ts` imports it beside `deriveProfileWorker, researcherDashboard, researcherDashboardWatchdog` and adds it to `module.exports`. It runs as the project's default service account, like `createSyncDocAfterAnswerWritten`, and not as the dashboard's (that account exists so the runner stack's AWS roles trust only `researcherDashboard`; this function calls no AWS).

**Tests**: none beyond the previous step's; the decision and the write are `handleAnswerWrite`'s, tested there, and `BAD_DATA` is typed by `Skip`, so a renamed reason fails to compile. Retries are checked on the deployed function (R12). `npm run build` and `npm run lint` pass, and `firebase deploy`'s predeploy runs both.

---

### The rules and their tests

**Summary**: R7's move of `rdResearcherOfClass` to the `researcher_dashboard/{portal}` level and its activity block, and R9's emulator tests in their own file so REPORT-143's suite runs unedited (R8).

**Files affected**:
- `firestore.rules`: the block's header naming the activity documents and their writer, `rdResearcherOfClass(classHash)` after `rdIsResearcher()`, its two callers passing `classHash`, and the activity match after `match /classes/{classHash}`
- `tests/researcher-dashboard-activity-rules.test.js`: new

**Estimated diff size**: ~120 lines

The whole diff to `firestore.rules`, against `1c3df21` (its rules are `bfbda61`'s):

```diff
-    // Package results, and the status the researcher's MicroVM reports, read by the dashboard.
-    // Every client write needs researcher_dashboard_runner, a claim minted only into the VM's tokens.
-    // work/ holds the runner tokens for the queued run; the function writes it, vms/ and
-    // classes/{class_hash} with the Admin SDK. No delete, which write would include: a result is
-    // regenerated by running the package again.
+    // Package results, the status the researcher's MicroVM reports, and per-learner activity, read by
+    // the dashboard. Every client write needs researcher_dashboard_runner, a claim minted only into the
+    // VM's tokens. work/ holds the runner tokens for the queued run. work/, vms/ and classes/{class_hash}
+    // are written by the dashboard's functions, and activity/ by researcherDashboardActivity, with the
+    // Admin SDK. No delete, which write would include: a result is regenerated by running the package
+    // again.
     match /researcher_dashboard/{portal} {
@@
       function rdIsResearcher() {
         return rdAuthed() && request.auth.token.user_type == "researcher";
       }
+      function rdResearcherOfClass(classHash) {
+        return rdIsResearcher() && request.auth.token.class_hash == classHash;
+      }
@@
       match /classes/{classHash} {
-        function rdResearcherOfClass() {
-          return rdIsResearcher() && request.auth.token.class_hash == classHash;
-        }
-        allow get: if rdResearcherOfClass() && rdReadable();
+        allow get: if rdResearcherOfClass(classHash) && rdReadable();
@@
           function rdOwnScope() {
-            return rdResearcherOfClass() && rdTokenUserId() == platformUserId;
+            return rdResearcherOfClass(classHash) && rdTokenUserId() == platformUserId;
           }
@@
       }
+
+      // Per-learner activity, written only by researcherDashboardActivity with the Admin SDK. The class's
+      // researchers read and list it; the path and token are all the rule needs, since rdAuthed() already
+      // ties {portal} to the token's portal.
+      match /activity/{classHash}/users/{uid} {
+        allow get, list: if rdResearcherOfClass(classHash);
+      }
     }
   }
 }
```

**Tests** (`@firebase/rules-unit-testing` 1.x, one app per token shape built once, as REPORT-143's suite does. Documents are seeded with `initializeAdminApp` using plain `Date`s, since the admin app refuses the client SDK's `serverTimestamp()`. Each test uses a distinct learner id, since the tokens' `class_hash` is fixed when the apps are built):
- The class's researcher token gets a seeded document and lists the collection.
- A listener on an empty class's collection receives a snapshot with `empty` true, not an error.
- Refused get and list: a researcher token for another class, a researcher token for another portal, a learner and a teacher token for the class, an anonymous caller.
- Refused create, update and delete for the class's researcher token and its runner token (`researcher_dashboard_runner: true`). The runner token carries a fresh `auth_time`, as REPORT-143's suite builds its runner shapes, so `rdIsRunner()` holds for it and a write rule granted to runners would fail this case.
- A get of `activity/{classHash}` itself is refused.

The other-class cases are what fail if the `class_hash` clause is dropped, and the runner's create is what fails if `allow create: if rdIsRunner()` is added (both mutations checked against `bfbda61`'s rules, 2026-10-14), so those cases test R7 rather than the default denial. Removing the shared function's `class_hash` term fails both activity other-class cases and 4 tests in `researcher-dashboard-rules.test.js`, so each call site is pinned. The whole `tests/` suite (five files, 218 tests at `bfbda61`) passes with no test edited.

---

### The README

**Summary**: R11. One paragraph in the "Researcher Dashboard function" section of `functions/README.md`, and the function added to that section's deploy command.

**Files affected**: `functions/README.md`

**Estimated diff size**: ~15 lines

What it says: `researcherDashboardActivity` runs on every answer write, with retries, and maintains `researcher_dashboard/{portal}/activity/{class_hash}/users/{platform_user_id}` with `lastActivityAt`, `writeCount` and `changed` (each defined as in R5, `writeCount` as a change signal only); which writes it skips; that only the class's researcher tokens read it; that it costs one invocation per answer write, read as the function's execution count in the Cloud console beside `createSyncDocAfterAnswerWritten`. The section's deploy command (line 229 at `1c3df21`) gains `functions:researcherDashboardActivity`, so deploying the rules from it also deploys the trigger.

---

### Deploy to report-service-dev and check (R12)

Not a commit. After the PR is approved, and once the deployed rules are confirmed equal to `master`'s, so that this deploy ships only the rules diff above (the move of `rdResearcherOfClass` and the activity match): `firebase deploy --only functions:researcherDashboardActivity,firestore:rules --project report-service-dev`, with the functions' firebase-tools. Then a staging student in a staging class with an Activity Player assignment saves an answer, and the document appears under `researcher_dashboard/learn_portal_staging_concord_org/activity/<class_hash>/users/<id>` within seconds, read in the Firebase console. Production is lane 12's ops step.

## Open Questions

### RESOLVED: Judgment call: the logic lives in a firebase-admin-only module, the registration in a thin file
**Options considered**:
- A) `activity.ts` (logic) plus `activity-trigger.ts` (registration), as `chat/drain.ts` and `chat-tutor.ts` split it.
- B) One file, tested through `firebase-functions-test`.

**Decision**: A. The repository already tests triggers this way; `firebase-functions-test` is a devDependency (0.3.3) that no test uses.

### RESOLVED: Judgment call: only bad-data skips are logged
**Options considered**:
- A) Log only `bad_*` skips.
- B) Log every skip.

**Decision**: A. Deletes, moves and re-saves are expected on every class and would add a log line per answer write; the bad-data skips mean a writer is putting malformed identifiers on answers and are worth seeing.

## Self-Review

Roles: commit reviewer, test writer, operator, security engineer. Each finding was checked against the code or the throwaway build before it was written down.

### Test writer

#### RESOLVED: A planned length assertion on the skip table was true by construction
The plan asserted that the four-field table had four entries, which is a constant asserting itself and fails on no mutation. Jest's `it.each` already throws on an empty table (checked in a throwaway build, where the table ran four cases), so the assertion was dropped and the plan says why the table cannot pass empty.

### Commit reviewer

No finding. The activity step builds, lints and passes alone; the trigger step adds only the registration; the rules step changes only `firestore.rules` and `tests/` and is the one step that needs REPORT-143's block (R14); the README step changes only `functions/README.md`.

### Operator

No finding. `firebase deploy --only functions:researcherDashboardActivity,firestore:rules` deploys this function alone; a 1st-gen Firestore trigger needs no Eventarc setup, as `createSyncDocAfterAnswerWritten` and `chatTutorOnWrite` show. Deploying `firestore:rules` ships every rules change on the branch's base that is not yet deployed, so the deploy section first confirms the deployed rules equal `master`'s.

### Security Engineer

No finding. The skip log carries only `source`, `answerId` and the reason, no answer content; the function writes nothing from the answer except the validated path segments and the validated `resource_link_id` as a map key.

### Operator (second pass)

#### RESOLVED: The staging check named the wrong portal segment
Staging's `platform_id` is `https://learn.portal.staging.concord.org` (`functions/.env.report-service-dev`, `functions/README.md`, and `PORTAL = "learn_portal_staging_concord_org"` in `run-package.test.ts:16`), so the document lands under `learn_portal_staging_concord_org`, not `learn_staging_concord_org`. Fixed in the deploy section.

### Commit reviewer (second pass)

#### RESOLVED: The first judgment call's reason was false
`firebase-functions-test` ^0.3.3 is in `functions/package.json`'s devDependencies (installed, imported by no file in `src/`). The decision stands on the repository's existing split; the reason is corrected.
