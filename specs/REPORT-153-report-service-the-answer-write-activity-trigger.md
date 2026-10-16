# report-service: the answer-write activity trigger

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-153

**Status**: **Closed**

## Overview

A Firestore trigger in report-service's project records, for every learner in a class, when they last saved an Activity Player answer and which assignments they changed, in one small document per learner. The researcher dashboard reads those documents to show how many students were active in the last few minutes and to re-run a package when the class's work has changed.

A researcher watching a class work wants the dashboard to notice new student work without reloading the page, and the PI's Analyze Class page (RIGSE-360) asks for counts that are live. Before this story nothing in report-service said "this student just did something": answers were stored, but there was no cheap, class-wide signal a browser could listen to. This story adds that signal for Activity Player classes (the Wildfire classes among them). CLUE classes get the same signal from CLUE-693, in CLUE's own database.

The number this makes possible is "students who saved work in the last N minutes". The PI agreed during the spike that save times are the "logged in" signal for RIGSE-360's live student count (Doug, 2026-10-13); a student reading or thinking writes nothing, and the page has to say so. The cost is one extra function run per answer save, which shows up under its own name in the Firebase console.

`final-design.md` section 14 designs the change signal: per-learner activity documents written by Firestore triggers, one in CLUE's project on history writes (CLUE-693) and one in report-service's project on answer writes (this story). RD-6 pass 1 builds on it (the app's listeners, the active-in-the-last-N-minutes count and the re-run loop), and REPORT-158 makes re-running visible in the Wildfire package. Nothing on the VM reads the `changed` map; it stays in the shape so both writers agree, and it is what a future incremental re-run would pass to the runner (RD-8). In a Wildfire class only this story writes the documents (Doug, 2026-10-09).

## Requirements

### The trigger

- **R1.** A 1st-gen Firestore function, `researcherDashboardActivity`, runs `onWrite` on `sources/{source}/answers/{answerId}` with retries on failure (`failurePolicy: true`), and is exported from `functions/src/index.ts`. It is separate from `createSyncDocAfterAnswerWritten`, does not read `settings/autoImporter`, and does not change that function.
- **R2.** For a write that qualifies (R3), it reads the learner's activity document (R4) and makes exactly one Firestore write, a merge `set` with no transaction: `lastActivityAt` and `changed.<resource_link_id>` set to the server's time, and `writeCount` incremented by one. The read exists only for R5's cap on `changed`: when the map already holds 500 keys and this write's key is not among them, the write sets `lastActivityAt` and `writeCount` alone.
- **R3.** A write qualifies only when all of these hold; otherwise the function returns without writing:
  - the answer exists after the write (a delete is not activity);
  - the answer after the write has non-empty `platform_id`, `platform_user_id`, `context_id` and `resource_link_id` (anonymous and incomplete answers belong to no class);
  - before the write the answer was absent, or had the same `context_id` and `platform_user_id` (a `move_student_work` move is not activity);
  - the answer changed: before and after differ in some field other than `created` and `interactive_state_history_id`, which the Activity Player sets afresh on every save (`activity-player/src/firebase-db.ts:557`), so a re-save of unchanged content is not activity. The comparison ignores key order at every depth and keeps Firestore's value types (`NaN` and the infinities, timestamps, references, bytes) distinct, so a re-save whose keys come back in another order is unchanged and a change between, say, `NaN` and `null` is not.
  An `import_run` write that passes these counts, since it is LARA's sync of the student's own save.
- **R4.** The activity document is `researcher_dashboard/{portal}/activity/{class_hash}/users/{uid}`, where `{portal}` is `portalSegment(platform_id)`, `{class_hash}` is the answer's `context_id`, and `{uid}` is `String(platform_user_id)`. Each segment, and the `changed` key, is checked before the write, and a write that fails a check is skipped and logged: `platform_id` must parse as a URL with a non-empty host of at most 253 characters, a DNS name's limit; `context_id` must be 48 lowercase hex characters, the `CLASS_HASH` pattern, which lives in `firestore-paths.ts` as the one copy `run-package.ts`, `derive-profile-route.ts` and the trigger use; `platform_user_id` must match REPORT-143's `PLATFORM_USER_ID` (a positive integer, `storage-policy.ts`), imported rather than copied; `resource_link_id` must be a positive integer too, since it is a portal offering id; and both ids are at most 18 digits, the bound the package catalog's identity grammar gives a portal id, since Firestore refuses a document id or field name over 1,500 bytes and a refused write would retry until the retry window closes. Admin-written answers (`import_run`, `move_student_work`) bypass the rules that pin the identity fields for learners, and no rule pins `resource_link_id` even for a learner, so the trigger cannot assume any of them.

### The document contract (for RD-6 pass 1, REPORT-158, CLUE-693)

- **R5.** The document has exactly three fields, and both writers write the same three:
  - `lastActivityAt` (Firestore timestamp): the server time at which the most recent qualifying write was recorded. Never set from a client clock.
  - `writeCount` (integer): incremented once per recorded write. A change signal, not an exact count: an at-least-once trigger delivery, or a retry of a delivery whose write landed, can count one save twice, so readers compare it for inequality and never do arithmetic on it.
  - `changed` (map of string to Firestore timestamp): for each key that changed, the server time it last changed. In report-service the key is the answer's `resource_link_id` (the portal offering id, `scope.json`'s `assignments[].offering_id`); in CLUE it is the document key CLUE-693 chooses. Entries are never removed. For a learner working in the Activity Player the map is bounded by the class's assignments (in CLUE, by the documents); the answer rules do not pin `resource_link_id`, so a learner writing answers by hand can add integer keys to their own document, and to no one else's. The map takes no new key once it holds 500 (concurrent writes can each add one past that), so such a document stays far below Firestore's 1 MiB limit, and `firestore.indexes.json` exempts `changed` from single-field indexing, since nothing queries it.
  No identity fields are stored: the path carries the portal, the class and the learner.
- **R6.** A learner's document exists once they have made one qualifying write in that class; a class with no activity has no documents, and an empty collection is the answer "nobody yet". Nothing in this story deletes an activity document.

### The rules

- **R7.** `firestore.rules` has, inside REPORT-143's `match /researcher_dashboard/{portal}` block, a `match /activity/{classHash}/users/{uid}` allowing `get` and `list` to `rdResearcherOfClass(classHash)`: a token that passes REPORT-143's `rdIsResearcher()` and whose `class_hash` equals `{classHash}`. That function is REPORT-143's `rdResearcherOfClass()`, moved from `match /classes/{classHash}` to the `researcher_dashboard/{portal}` level and given the class hash as a parameter, so both matches call one copy of the condition. Nothing grants `create`, `update` or `delete`: only the function writes, with the Admin SDK. No rule matches `activity/{classHash}` itself.
- **R8.** REPORT-143's rules behave unchanged. The only edit to its block's rules is R7's move of `rdResearcherOfClass`: its two callers, `classes/{classHash}`'s `get` and `rdOwnScope()`, pass `classHash`, and REPORT-143's rules suite passes with no test edited.
- **R9.** Emulator tests in `tests/` assert: a researcher token for the class gets one document and lists the collection; a listener on the collection before any document exists receives an empty snapshot rather than an error; a researcher token for another class, a learner token and a teacher token for the class, and an anonymous caller are refused get and list; a researcher token whose `platform_id` is another portal's is refused; and every client token is refused create, update and delete, including a runner token with a fresh `auth_time`, for which REPORT-143's `rdIsRunner()` holds. Breaking the shared function's `class_hash` term fails tests on both the activity side and REPORT-143's classes side.

### Verification and operations

- **R10.** Tests show, against the Firestore emulator: one qualifying write creates the document with all three fields; a second write in another assignment adds a second `changed` key and keeps the first; an answer write that R3 excludes, run through the same function the trigger calls, writes nothing; and concurrent writes from a class of 30 learners, several each, produce 30 documents whose `writeCount`s sum to the writes made, with no write failing. The emulator does not enforce Firestore's per-document write rate, so this proves the merge and the sharding, not the production limit; one document per learner is what keeps a class under it.
- **R11.** `functions/README.md` documents the function, the document contract (R5), the rules (R7), and where its cost is read: Cloud Functions' execution count for `researcherDashboardActivity`, one invocation per answer write, beside `createSyncDocAfterAnswerWritten`'s. It adds `functions:researcherDashboardActivity` to the dashboard's existing deploy command rather than giving a second one.
- **R12.** Deployed to report-service-dev with its rules, the function's event trigger has retries on (`gcloud functions describe researcherDashboardActivity` shows `eventTrigger.failurePolicy.retry`), and a staging student saving an answer in an Activity Player assignment produces the document within a few seconds, read in the Firebase console or with the Admin SDK. The student then reloads the page without changing anything, and the document's `writeCount` is unchanged: an interactive that re-posts its unchanged state on load is a re-save R3 does not count. The browser's read is R9's, since no deployed app reads the collection until RD-6 pass 1. *(Passed on report-service-dev, 2026-10-16: see Rollout.)*
- **R13.** No change to answers, their rules, the S3 sync, `createSyncDocAfterAnswerWritten` or the AI chat trigger.
- **R14.** R7 sits inside REPORT-143's block and reuses its functions, and the trigger imports REPORT-143's `PLATFORM_USER_ID` (`storage-policy.ts:3`). The branch was built on `master` at `1c3df21`, which carries REPORT-143 (`bfbda61`) and REPORT-170.

## Technical Notes

- **Why a trigger, when answers already carry their class.** An Activity Player answer carries `context_id`, which the rules pin to the learner token's `class_hash`, and a researcher token can already read a class's answers. What a browser cannot get from the answers is a cheap signal: listening to a class's answers would stream every full answer document, `report_state` included (up to Firestore's 1 MiB per document), on every save; answers carry no server timestamp (`created` is the client's `toUTCString()`); and there is no class-wide view across `sources/*`. The Jira text's reason ("only the writer knows the class") is CLUE's, not report-service's.
- **Two databases, one shape.** CLUE-693 writes in CLUE's Firebase project and this story in report-service's. RD-6 pass 1 reads report-service's collection for an Activity Player class and CLUE's for a CLUE class, and a mixed class would union the two by `uid`, which is why `uid` is the portal user id, the one identifier both writers have. CLUE's `{portal}` prefix is its own choice (`authed/{portal}/…`); what it must match is R5's fields and R4's meaning of `{class_hash}` and `{uid}`.
- **No story added metrics.** The Jira "Done when" says the cost is "visible in the metrics the stacks story added". No such metrics exist: the stack defines no alarms and the function and runner publish only structured logs (`final-design.md` 16). A function of its own makes the cost visible through Cloud Functions' per-function execution count, with no code.
- **Files.** `functions/src/researcher-dashboard/firestore-paths.ts` (`activityUserPath` and `CLASS_HASH`); `activity.ts` (the qualifying check and the write, firebase-admin only, so it is emulator-testable without `firebase-functions`, as `chat/drain.ts` is) with `activity.test.ts` and `activity.emulator.test.ts`; `activity-trigger.ts` (the registration, a thin file as `chat-tutor.ts` is); `functions/src/researcher-dashboard/index.ts` and `functions/src/index.ts`; `firestore.rules`; `tests/researcher-dashboard-activity-rules.test.js`; `functions/README.md`.
- **Merge semantics.** A merge `set` with a nested object updates only the nested keys given, so `changed: {<id>: serverTimestamp()}` adds or replaces one key and keeps the rest. `FieldValue.increment` and `serverTimestamp` are both valid inside a merge `set`, `increment` on an absent field starts from zero, and a key containing a dot stays one key.
- **Contention.** One document per learner, so a class's writes are spread across its learners. A learner's document is written at most at that learner's answer-save rate; Firestore's soft limit of about one sustained write per second per document is a limit on that rate, not on the class. The write is not transactional, so concurrent writes to one document do not retry against each other.
- **Collaborators.** In a collaboration session the Activity Player saves the owner's answer with `collaborators_data_url` and `collaboration_owner_id` (`activity-player/src/firebase-db.ts:575-577`), and `handleCollaborativeUrl` (`auto-importer.ts:325`) copies it with the Admin SDK into each collaborator's answer for that question, under the collaborator's `platform_user_id` and the same `context_id`. rigse offers collaborators only from the offering's class, so a copy credits a student of that class. A collaborator's later solo save is a merge `set` that leaves the copy's `collaboration_owner_id` in place (`firebase-db.ts:524`), so nothing in the answer tells a copy from the collaborator's own edit, and the trigger counts both. Copies are made inside `createSyncDocAfterAnswerWritten`, so collaborators show active during a shared session only while `settings/autoImporter.watchAnswers` is on; their own saves count either way.
- **Ordering and retries.** Trigger deliveries are unordered and may repeat. `lastActivityAt` takes the server time of the delivery that writes it, and may trail the student's save by the trigger's latency, normally seconds. 1st-gen Firestore triggers are not retried by default, so a failed delivery of a lesson's last save would leave a result never marked behind; R1 turns retries on. No skip path throws, so bad data cannot loop, and a retried write only records a later `lastActivityAt` or counts a save twice, both over-reports. A failure that persists retries until the platform's retry window ends.
- **Reads, for RD-6 pass 1.** The collection is small (one document per active learner), so the app should listen to the whole `users` collection and compute "active in the last N minutes" against its own clock on a timer, rather than query `lastActivityAt >= cutoff`: a query's cutoff is fixed when the listener attaches, so it would keep counting learners who went quiet. `lastActivityAt` is the server's clock and the window is computed on the researcher's, so RD-6 pass 1 should state how it handles skew (for example by measuring against the newest `lastActivityAt` it has seen, or tolerating a few minutes). For the re-run comparison, the safe input is the maximum `lastActivityAt` (or the `changed` map) across the class, never a sum of `writeCount`s.
- **Rules evaluation for `list`.** The R7 condition reads only the token and the path, never `resource.data`, so a plain collection listener passes without a filter. `rdAuthed()` already ties `{portal}` to the token's portal, so no `platform_id` on the document is needed.
- **Who can read.** A researcher token for the class. RD-4's class runner token is a researcher token with the runner claim, so the rule admits it too, but nothing on the VM reads these documents. Teachers and learners cannot: a learner seeing classmates' activity would be a disclosure the dashboard does not need.
- **The identifier formats R4 checks are rigse's.** `Portal::Clazz#generate_class_hash` sets `SecureRandom.hex(24)` (48 lowercase hex), the learner token's `platform_user_id` is the portal user's integer id, which the answer carries, and the Activity Player writes `resource_link_id` as `offeringData.id.toString()` (`activity-player/src/portal-api.ts:428`).
- **Local emulator runs.** The trigger runs as the App Engine default service account, not `researcher-dashboard@<project>`, since it calls no AWS. `npm run test:emulator` ignores `functions/lib/`, so a build's compiled test copies do not run against the same emulator, and the activity emulator tests clear the `activity` tree before each test.

## Out of Scope

- CLUE's trigger and rules (CLUE-693), and the app's listeners, count and re-run loop (RD-6 pass 1).
- Activity from `interactive_state_histories`, plugin states or the object store: an answer save accompanies each, and answers are what a package reads.
- Teacher-facing activity views, and the `class-activity` page of `final-design.md` 15.2.
- Pruning or expiring activity documents.
- A metric, alarm or kill-switch setting; the function is turned off by deleting it.
- Changing Jira's "Done when" text to drop "the metrics the stacks story added"; this spec records the correction.

## Rollout

**Deploying.** Firebase refuses to deploy a function with a failure policy unless `--force` is passed, and `--force` on `firestore:indexes` also deletes every deployed index the file does not list. So the trigger and the Firestore config go in two commands, with the functions' firebase-tools, after confirming the deployed rules and indexes equal `master`'s:

```
firebase deploy --only firestore:rules,firestore:indexes --project <project> --non-interactive
firebase deploy --only functions:researcherDashboardActivity --project <project> --non-interactive --force
```

`functions/build-info.json` must exist first (`npm run buildinfo`), since loading `lib/index.js` requires it.

**report-service-dev, 2026-10-16, from `933649b`.** The deployed rules equaled `master`'s. The deployed indexes held the 27 composites `master` lists plus three no file lists (one on `answers`, two on `answers_async`), and Doug chose to deploy with them left in place, which the first command above does. `gcloud functions describe` showed the function `ACTIVE` with `eventTrigger.failurePolicy.retry`, on `document.write` for `sources/{source}/answers/{answerId}`, running as the App Engine default account. On the staging portal, test student `tstudentone` (user 27) opened the class's Wildfire fixture (offering 1254) and edited an open response. Eight seconds after the edit, `researcher_dashboard/learn_portal_staging_concord_org/activity/dca466d3fcb3322466b467c98c4d307c1871608cd9096e82/users/27` held exactly `lastActivityAt`, `writeCount: 1` and `changed: {"1254": …}`. Reopening page 1 from the portal's Run link and reloading it left `writeCount` at 1, and the function log showed no execution after the save: on this fixture a page load posts no answer writes. A browser reload of the Activity Player lands on the activity's index page, since the player drops `page=` from its URL; reopening from the Run link is what reloads page 1.

## Not Yet Implemented

- **Production**: lane 12's ops step, deployed as above.
- **The `unchanged` comparison on deployed snapshots**: the staging reload produced no answer write, so the comparison has run only on emulator snapshots. `report_state` is a JSON string, so an interactive that re-serializes unchanged state in another key order would count as activity; a production fixture whose interactive re-posts on load would show whether that happens.

## Decisions

### Where do the activity documents live in report-service's Firestore?
**Options considered**: A) `researcher_dashboard/{portal}/activity/{class_hash}/users/{uid}`, inside REPORT-143's tree, reusing its portal check; B) `activity/{class_hash}/users/{uid}` at the root, outside REPORT-143's block, needing its own portal check and holding every portal's classes in one collection.
**Decision**: A (Doug, 2026-10-11). The story's `activity/{class_hash}/users/{uid}` is the suffix under each project's own prefix (R4, R7).

---

### A separate function, or a branch in `createSyncDocAfterAnswerWritten`?
**Options considered**: A) a new function on the same path; B) the activity write added to the existing trigger, costing no extra invocation.
**Decision**: A. B couples the dashboard to the S3 sync's settings gate and failure path, and hides the cost inside an existing function's count; A's cost is one invocation per answer write, visible by name (R11).

---

### Identity fields on the document?
**Options considered**: A) three fields only, the path carrying the portal, class and learner; B) also `platform_id`, `context_id`, `platform_user_id`, as answers have.
**Decision**: A. No rule or reader needs them, and both writers would have to agree on three more names, one of which (`context_id` against `class_hash`) is already spelled two ways across the two projects.

---

### Which writes count?
**Options considered**: A) exclude deletes, moves, anonymous answers and identical re-saves, and count collaborators' copies; B) also exclude collaborators' copies (`collaboration_owner_id` not equal to `platform_user_id`); C) record every answer write that names a class.
**Decision**: A (Doug, 2026-10-16, for the copies). The count is "students who did something", and a teacher's move is not that. Collaborators work together at one machine and the portal treats the work as theirs. B would also skip every later solo save by a collaborator, since that save keeps the copy's `collaboration_owner_id`.

---

### Does a merge `set` with `increment`, `serverTimestamp` and a nested map key behave as R2 assumes?
**Decision**: Yes, on the Firestore emulator (firebase-tools 15.24.0, firebase-admin 10.0.0, 2026-10-11): the first write created `writeCount: 1`, one `changed` key and a `Timestamp` `lastActivityAt`; a second to another key gave `writeCount: 2`, kept the first key's time and moved `lastActivityAt` forward; a dotted key stayed one key; and 150 concurrent writes from 30 learners produced 30 documents summing to 150.

---

### Does R7's `list` pass for a plain collection listener under REPORT-143's helpers?
**Decision**: Yes, on `bfbda61`'s rules with R7's block (2026-10-14): an empty-collection listener received an empty snapshot; the class's researcher got and listed; another class, another portal, a learner, a teacher and an anonymous caller were refused; every client write was refused, including a fresh runner's; and `activity/{classHash}` itself was refused. With the `class_hash` clause removed, or `allow create: if rdIsRunner()` added, the matching cases failed, so they test R7 rather than the default denial.

---

### Share `rdResearcherOfClass` with REPORT-143's classes match, or copy its condition?
**Options considered**: A) repeat the condition in the activity match, leaving REPORT-143's block untouched; B) move `rdResearcherOfClass` to the `researcher_dashboard/{portal}` level as `rdResearcherOfClass(classHash)` and call it from both matches; C) nest the activity documents under `classes/{classHash}`, changing the path RD-6 pass 1 and CLUE-693 use.
**Decision**: B (Doug, 2026-10-14). The function reads only `classHash`, `request.auth` and, through `rdIsResearcher()`, `{portal}`, all visible at the block level. REPORT-143's suite passes unchanged with the move.

---

### Do the Activity Player's re-saves compare unchanged through the deployed trigger?
**Context**: R3's `unchanged` check compares snapshots, so a comparison that depended on key order would count a re-save whose keys came back in another order, and the module's tests build their snapshots by hand.
**Decision**: They do, in the functions emulator (firebase-tools 15, demo project, 2026-10-16) on Activity Player-shaped merge `set`s: a create wrote the three fields; a `resource_link_id` of `"__x__"` wrote nothing and logged `activity.skipped`; a re-save with new `created` and `interactive_state_history_id`, and the same re-save with its keys reversed, each left `writeCount` at 1; a content change made it 2; a move to another `context_id` wrote nothing. Two Admin SDK reads of the stored answer returned its keys in different orders, but the trigger's before and after compared equal, so the emulator's event snapshots come in a stable order. Since the stability of that order is not promised, the comparison ignores key order at every depth, arrays kept in order, so a reordered snapshot compares unchanged whatever order production delivers (CodeRabbit's review of #440); a unit test with reordered top-level and nested keys pins it. It began as `JSON.stringify` over sorted keys, which Copilot's second review of #440 showed turns `NaN` and the infinities into `null`, so a change between them and `null` compared unchanged; it is now a type-preserving deep comparison (`Object.is` for scalars, Firestore's `isEqual` for timestamps, references and geopoints, `Buffer.equals` for bytes), with a unit test for each value type in both directions. The emulator run was repeated on `933649b`, after the review fixes, with 10 of 10 checks passing: the original six, plus a reserved portal host skipped and logged, a re-save keeping `NaN` not counted, a change from `NaN` to `null` counted, and a full `changed` map taking no new key while still counting the write.

---

### The trigger builds a document path from answer fields the Admin SDK can write unchecked
**Decision**: Each segment is checked (R4): `import_run` and `move_student_work` bypass the learner rules, so a `context_id` containing `/` would change the path's depth. A `platform_id` with an empty host (`"foo:bar"`) is refused, since `portalSegment` returns an empty segment and `db.doc` throws. `resource_link_id` must be a positive integer, since no rule pins it and `"__x__"` made the merge `set` fail with `Invalid reserved name`. The user id uses REPORT-143's stricter `PLATFORM_USER_ID` rather than a looser digits copy, which accepted `"0123"`. Copilot's review of #440 added length bounds: a learner could write a 1,501-digit `resource_link_id`, past Firestore's 1,500-byte field-name limit, and an Admin-written `platform_user_id` or a URL host (Node's parser accepts thousands of characters) could pass the document-id limit, each making the write fail and retry rather than skip. Both ids are capped at 18 digits and the host at 253 characters, with boundary tests on each side. Ethan McElroy's review of #440 added the reserved-id case: a host such as `__x__` becomes a portal segment Firestore refuses as a document id, so a segment matching `__.*__` is skipped too.

---

### One `CLASS_HASH`
**Decision**: The pattern was defined in `run-package.ts` and `derive-profile-route.ts`; it moves to `firestore-paths.ts` and all three import it, rather than the trigger adding a third copy.

---

### What R12 and R10 can show
**Decision**: Staging checks that the document exists; the browser's read is covered by R9's emulator tests, since no deployed app reads the collection before RD-6 pass 1 and minting a researcher token by hand needs the dashboard's scoped access token. R10 says the concurrency test proves the merge and the sharding, not the production write-rate limit, which the emulator does not enforce.

---

### Logic in a firebase-admin-only module, registration in a thin file?
**Options considered**: A) `activity.ts` plus `activity-trigger.ts`, as `chat/drain.ts` and `chat-tutor.ts` split it; B) one file, tested through `firebase-functions-test`.
**Decision**: A, the repository's existing split; `firebase-functions-test` is a devDependency no test uses.

---

### Which skips are logged?
**Options considered**: A) only the `bad_*` skips; B) every skip.
**Decision**: A. Deletes, moves and re-saves are expected on every class and would add a log line per answer write; the bad-data skips mean a writer is putting malformed identifiers on answers.

---

### The four-field skip table
**Decision**: One `it.each` table whose every row asserts `{ skip: "no_class" }` exactly; Jest refuses an empty `.each` table, so it cannot silently test nothing, and a planned length assertion was dropped as true by construction.

---

### Bound the `changed` map, at the cost of a read per write?
**Context**: no rule pins `resource_link_id`, so a learner writing answers by hand could add keys without limit. Each key was indexed, and past Firestore's index-entry or 1 MiB limit every write to that learner's document would fail and retry for days; the researcher's listener also downloads the whole document on every change (Ethan McElroy's review of #440).
**Options considered**: A) keep R2's single blind write and accept the risk; B) read the document first and add no new key once `changed` holds 500, without a transaction; C) B in a transaction.
**Decision**: B, with `changed` exempt from indexing. A class has 8 to 14 assignments, so 500 never binds an Activity Player learner. The read costs one document read per counted write. Without a transaction, concurrent writes by one learner can each add a key past the cap, which only overshoots it by the number in flight; a transaction would make one learner's concurrent saves retry against each other for no gain.

---

### Departures from the plan, made during implementation
**Decision**: The rules test seeds documents with plain `Date`s, since the admin app refuses the client SDK's `serverTimestamp()`, and uses a distinct learner id per test rather than a distinct class hash, since the token apps are built once with a fixed `class_hash`. The `researcher_dashboard` block's header comment in `firestore.rules` also names the activity documents and `researcherDashboardActivity` as their Admin SDK writer. The unit tests add a move to another learner and numeric identifiers to the planned cases. The README names the account the trigger runs as. After review, the `unchanged` comparison is a type-preserving deep comparison that ignores key order rather than a serialized string, `activity-trigger.ts` has a unit test of its registration and of which skips it logs, and `npm run test:emulator` ignores `functions/lib/`.
