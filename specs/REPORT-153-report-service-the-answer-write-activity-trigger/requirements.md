# report-service: the answer-write activity trigger

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-153
**Repo**: https://github.com/concord-consortium/report-service
**Branch**: `REPORT-153-report-service-the-answer-write`, on `master` at `1c3df21`, which carries REPORT-143 and REPORT-170 (R14)
**Implementation Spec**: [implementation.md](implementation.md)
**Status**: **In Development**

## Overview

A new Firestore trigger in report-service's project records, for every learner in a class, when they last saved an Activity Player answer and which assignments they changed, in one small document per learner. The researcher dashboard reads those documents to show how many students were active in the last few minutes and to re-run a package when the class's work has changed.

## Project Owner Overview

A researcher watching a class work wants the dashboard to notice new student work without reloading the page, and the PI's Analyze Class page (RIGSE-360) asks for counts that are live. Today nothing in report-service says "this student just did something": answers are stored, but there is no cheap, class-wide signal a browser can listen to. This story adds that signal for Activity Player classes (the Wildfire classes among them). CLUE classes get the same signal from CLUE-693, in CLUE's own database.

The number this makes possible is "students who saved work in the last N minutes". The PI agreed during the spike that save times are the "logged in" signal for RIGSE-360's live student count (Doug, 2026-10-13); a student reading or thinking writes nothing, and the page has to say so. The cost is one extra function run per answer save, which shows up under its own name in the Firebase console.

## Background

`final-design.md` section 14 designs the change signal: per-learner activity documents written by Firestore triggers, one in CLUE's project on history writes (CLUE-693) and one in report-service's project on answer writes (this story), each maintaining `activity/{class_hash}/users/{uid}` with `lastActivityAt`, a counter, and a small map of the keys that changed to the time each last changed. RD-6 pass 1 builds on it (the app's listeners, the active-in-the-last-N-minutes count and the re-run loop), and REPORT-158 makes re-running visible in the Wildfire package. RD-6 pass 2 is the app's listener on CLUE-693's documents; nothing on the VM reads the `changed` map, which stays in the shape so both writers agree and the class-activity page (`final-design.md` 15.2) can read it. In a Wildfire class only this story writes the documents (Doug, 2026-10-09).

**What the code says, checked against the story and the design.**

- **Answers already have a trigger.** `createSyncDocAfterAnswerWritten` (`functions/src/auto-importer.ts`) is a 1st-gen `onWrite` on `sources/{syncSource}/answers/{answerId}` that feeds the S3 parquet sync. It is gated by `settings/autoImporter.watchAnswers`, hashes before and after to skip unchanged writes, and copies an owner's answer to each collaborator through `handleCollaborativeUrl`. This story adds a second function on the same path rather than a branch in that one (R1).
- **The Jira text's decisive reason ("only the writer knows the class") is CLUE's, not report-service's.** An Activity Player answer carries its class: `context_id` is on every logged-in answer, and the rules already require it to equal the learner token's `class_hash` on create and forbid changing it on update (`learnerOwnerCreate`, `notChangingIdentifyingProps`). A researcher token can already read a class's answers (`researcherOfContext`). What a browser cannot get from the answers is a cheap signal: listening to a class's answers would stream every full answer document, `report_state` included (up to Firestore's 1 MiB per document), on every save; answers carry no server timestamp (`created` is the client's `toUTCString()`); and there is no class-wide view across `sources/*`. The trigger is justified by those three, and by matching CLUE's documents so the app reads one shape.
- **Both triggers write the same shape, not the same documents.** CLUE-693 writes in CLUE's Firebase project and this story in report-service's; they are two databases, and the app holds a Firestore handle per project (`final-design.md` 15.2). RD-6 pass 1 reads report-service's collection for an Activity Player class and, once CLUE-693 lands, CLUE's collection for a CLUE class, and a mixed class would union the two by `uid`. That is why R4 fixes `uid` as the portal user id, the one identifier both writers have.
- **The path sits under REPORT-143's tree.** REPORT-143 (merged to `master` as `bfbda61`; closed spec `specs/REPORT-143-vm-endpoints-and-watchdog.md`) puts every dashboard document under `researcher_dashboard/{portal}` (`firestore.rules:354`) and gives that block a portal check (`rdAuthed`, `:358`: the token's `platform_id` host, split into labels, equals `{portal}` split on `_`) that the rest of its rules build on. A root-level `activity/{class_hash}` would sit outside that check and mix portals in one collection. So the documents live at `researcher_dashboard/{portal}/activity/{class_hash}/users/{uid}`: the story's `activity/{class_hash}/users/{uid}` under report-service's existing prefix. `{portal}` is `portalSegment(platform_id)` from `functions/src/researcher-dashboard/firestore-paths.ts`.
- **The changed-keys map is keyed by assignment.** An answer's `resource_link_id` is the portal offering id, which is `scope.json`'s `assignments[].offering_id` (`final-design.md` 10) and what a package chunks its Student Answers runs by. It is the granularity an incremental pull would re-fetch at, and it is bounded by the class's assignments (8 to 14 in a real classroom, `plan.md`).
- **Not every answer write is a student's.** `move_student_work` rewrites `context_id` from one class to another with the Admin SDK; `handleCollaborativeUrl` writes copies of a collaboration owner's answer into each collaborator's answer documents, and those count as the collaborator's activity (the decision below); `import_run` is LARA's runtime answer sync: `SubmitDirtyAnswersJob` sends a student's own saves through `ReportService::RunSender` (lara `app/services/submit_dirty_answers_job.rb:8`, `run_sender.rb:19-26`), so its writes are a student's work. Anonymous answers (`run_key`, no `platform_id`) belong to no class. R3 says which count.
- **No story added metrics.** The Jira "Done when" says the cost is "visible in the metrics the stacks story added". No such metrics exist: `final-design.md` 16 records that the stack defines no alarms and that the function and the runner publish no metrics, only structured logs (Doug, 2026-09-25). What makes this story's cost visible is that it is a function of its own, so Cloud Functions' per-function execution count (`cloudfunctions.googleapis.com/function/execution_count`) reports its invocations by name with no code (R11).

## Requirements

### The trigger

- **R1.** A new 1st-gen Firestore function, `researcherDashboardActivity`, runs `onWrite` on `sources/{source}/answers/{answerId}` with retries on failure (`failurePolicy: true`), and is exported from `functions/src/index.ts`. It is separate from `createSyncDocAfterAnswerWritten`, does not read `settings/autoImporter`, and does not change that function.
- **R2.** For a write that qualifies (R3), it makes exactly one Firestore write, a merge `set` of the learner's activity document (R4) with no read first and no transaction: `lastActivityAt` and `changed.<resource_link_id>` set to the server's time, and `writeCount` incremented by one.
- **R3.** A write qualifies only when all of these hold; otherwise the function returns without writing:
  - the answer exists after the write (a delete is not activity);
  - the answer after the write has non-empty `platform_id`, `platform_user_id`, `context_id` and `resource_link_id` (anonymous and incomplete answers belong to no class);
  - before the write the answer was absent, or had the same `context_id` and `platform_user_id` (a `move_student_work` move is not activity);
  - the answer changed: before and after differ in some field other than `created` and `interactive_state_history_id`, which the Activity Player sets afresh on every save (`activity-player/src/firebase-db.ts:557`), so a re-save of unchanged content is not activity.
  An `import_run` write that passes these counts, since it is LARA's sync of the student's own save.
- **R4.** The activity document is `researcher_dashboard/{portal}/activity/{class_hash}/users/{uid}`, where `{portal}` is `portalSegment(platform_id)`, `{class_hash}` is the answer's `context_id`, and `{uid}` is `String(platform_user_id)`. Each segment, and the `changed` key, is checked before the write, and a write that fails a check is skipped and logged: `platform_id` must parse as a URL with a non-empty host; `context_id` must be 48 lowercase hex characters, the `CLASS_HASH` pattern `run-package.ts` and `derive-profile-route.ts` each define today, which moves to `firestore-paths.ts` as the one copy all three use; `platform_user_id` must match REPORT-143's `PLATFORM_USER_ID` (a positive integer, `storage-policy.ts`), imported rather than copied; `resource_link_id` must be a positive integer too, since it is a portal offering id. Admin-written answers (`import_run`, `move_student_work`) bypass the rules that pin the identity fields for learners, and no rule pins `resource_link_id` even for a learner, so the trigger cannot assume any of them.

### The document contract (for RD-6 pass 1, REPORT-158, CLUE-693)

- **R5.** The document has exactly three fields, and both writers write the same three:
  - `lastActivityAt` (Firestore timestamp): the server time at which the most recent qualifying write was recorded. Never set from a client clock.
  - `writeCount` (integer): incremented once per recorded write. A change signal, not an exact count: an at-least-once trigger delivery, or a retry of a delivery whose write landed, can count one save twice, so readers compare it for inequality and never do arithmetic on it.
  - `changed` (map of string to Firestore timestamp): for each key that changed, the server time it last changed. In report-service the key is the answer's `resource_link_id` (the portal offering id, `scope.json`'s `assignments[].offering_id`); in CLUE it is the document key CLUE-693 chooses. Entries are never removed. For a learner working in the Activity Player the map is bounded by the class's assignments (in CLUE, by the documents); the answer rules do not pin `resource_link_id`, so a learner writing answers by hand can add integer keys to their own document, and to no one else's.
  No identity fields are stored: the path carries the portal, the class and the learner.
- **R6.** A learner's document exists once they have made one qualifying write in that class; a class with no activity has no documents, and an empty collection is the answer "nobody yet". Nothing in this story deletes an activity document.

### The rules

- **R7.** `firestore.rules` gains, inside REPORT-143's `match /researcher_dashboard/{portal}` block, a `match /activity/{classHash}/users/{uid}` allowing `get` and `list` to `rdResearcherOfClass(classHash)`: a token that passes REPORT-143's `rdIsResearcher()` (`firestore.rules:373`) and whose `class_hash` equals `{classHash}`. That function is REPORT-143's `rdResearcherOfClass()` (`firestore.rules:410`), moved from `match /classes/{classHash}` to the `researcher_dashboard/{portal}` level and given the class hash as a parameter, so both matches call one copy of the condition. Nothing grants `create`, `update` or `delete`: only the function writes, with the Admin SDK. No rule matches `activity/{classHash}` itself.
- **R8.** REPORT-143's rules behave unchanged. The only edit to its block is R7's move of `rdResearcherOfClass`: its two callers, `classes/{classHash}`'s `get` and `rdOwnScope()`, pass `classHash`, and REPORT-143's rules suite passes with no test edited.
- **R9.** Emulator tests in `tests/` assert: a researcher token for the class gets one document and lists the collection; a listener on the collection before any document exists receives an empty snapshot rather than an error; a researcher token for another class, a learner token and a teacher token for the class, and an anonymous caller are refused get and list; a researcher token whose `platform_id` is another portal's is refused; and every client token is refused create, update and delete, including a runner token with a fresh `auth_time`, for which REPORT-143's `rdIsRunner()` holds. Breaking the shared function's `class_hash` term fails tests on both the activity side and REPORT-143's classes side.

### Verification and operations

- **R10.** Tests show, against the Firestore emulator: one qualifying write creates the document with all three fields; a second write in another assignment adds a second `changed` key and keeps the first; an answer write that R3 excludes, run through the same function the trigger calls, writes nothing; and concurrent writes from a class of 30 learners, several each, produce 30 documents whose `writeCount`s sum to the writes made, with no write failing. The emulator does not enforce Firestore's per-document write rate, so this proves the merge and the sharding, not the production limit; one document per learner is what keeps a class under it.
- **R11.** `functions/README.md` documents the function, the document contract (R5), the rules (R7), and where its cost is read, and adds `functions:researcherDashboardActivity` to the dashboard's existing deploy command (line 229 at `1c3df21`) rather than giving a second one: Cloud Functions' execution count for `researcherDashboardActivity`, one invocation per answer write, beside `createSyncDocAfterAnswerWritten`'s.
- **R12.** Deployed to report-service-dev with its rules, the function's event trigger has retries on (`gcloud functions describe researcherDashboardActivity` shows `eventTrigger.failurePolicy.retry`), and a staging student saving an answer in an Activity Player assignment produces the document within a few seconds, read in the Firebase console or with the Admin SDK. The student then reloads the page without changing anything, and the document's `writeCount` is unchanged: an interactive that re-posts its unchanged state on load is a re-save R3 does not count. The browser's read is R9's, since no deployed app reads the collection until RD-6 pass 1.
- **R13.** No change to answers, their rules, the S3 sync, `createSyncDocAfterAnswerWritten` or the AI chat trigger.
- **R14.** R7 sits inside REPORT-143's block and reuses its functions, and the trigger imports REPORT-143's `PLATFORM_USER_ID` (`storage-policy.ts:3`). REPORT-143 is on `master` (`bfbda61`), and the branch is rebased onto `master` at `1c3df21`, which adds REPORT-170 and changes none of the files this spec cites. If `master` moves before the first implementation step, the branch is rebased again first; it holds only spec commits and is unpushed, so a rebase rewrites nothing anyone else holds.

## Technical Notes

- **Files**: `functions/src/researcher-dashboard/firestore-paths.ts` (an `activityUserPath` beside the others, and `CLASS_HASH`, imported by `run-package.ts` and `derive-profile-route.ts` in place of their copies), a new `functions/src/researcher-dashboard/activity.ts` (the qualifying check and the update, firebase-admin only, as `chat/drain.ts` is, so the logic is emulator-testable without `firebase-functions`), which imports `PLATFORM_USER_ID` from REPORT-143's `storage-policy.ts`, its tests, `functions/src/index.ts`, `firestore.rules`, a new rules test file in `tests/`, `functions/README.md`.
- **Merge semantics.** A merge `set` with a nested object updates only the nested keys given, so `changed: {<id>: serverTimestamp()}` adds or replaces one key and keeps the rest. `FieldValue.increment` and `serverTimestamp` are both valid inside a merge `set`, and `increment` on an absent field starts from zero, and a key containing a dot stays one key. All three were run against the emulator (Open Questions).
- **Contention.** One document per learner, so a class's writes are spread across its learners. A learner's own document is written at most at that learner's answer-save rate; Firestore's soft limit of about one sustained write per second per document is a limit on that rate, not on the class. The write is not transactional, so concurrent writes to one document do not retry against each other.
- **Collaborators.** In a collaboration session the Activity Player saves the owner's answer with `collaborators_data_url` and `collaboration_owner_id` (`activity-player/src/firebase-db.ts:575-577`), and `handleCollaborativeUrl` (`auto-importer.ts:325`) copies it with the Admin SDK into each collaborator's answer for that question, under the collaborator's `platform_user_id` and the same `context_id`. rigse offers collaborators only from the offering's class (`collaborations_controller.rb:25`), so a copy credits a student of that class. A collaborator's later solo save is a merge `set` that leaves the copy's `collaboration_owner_id` in place (`firebase-db.ts:524`), so nothing in the answer tells a copy from the collaborator's own edit, and the trigger counts both. Copies are made inside `createSyncDocAfterAnswerWritten`, so collaborators show active during a shared session only while `settings/autoImporter.watchAnswers` is on; their own saves count either way.
- **Ordering.** Trigger deliveries are unordered and may repeat. `lastActivityAt` takes the server time of the delivery that writes it, so it can only move forward (or stand still) except across a clock-skewed server, which Firestore does not have; it may trail the student's save by the trigger's latency, normally seconds. 1st-gen Firestore triggers are not retried by default, so a failed delivery of a lesson's last save would leave a result never marked behind; R1 turns retries on. No skip path throws, so bad data cannot loop, and a retried write only records a later `lastActivityAt` or counts a save twice, both over-reports. A failure that persists, such as a bug in the write, retries until the platform's retry window ends rather than failing once.
- **Reads, for RD-6 pass 1.** The collection is small (one document per active learner), so the app should listen to the whole `users` collection and compute "active in the last N minutes" against its own clock on a timer, rather than query `lastActivityAt >= cutoff`: a query's cutoff is fixed when the listener attaches, so it would keep counting learners who went quiet. A time-window query would need only the automatic single-field index. `lastActivityAt` is the server's clock and the window is computed on the researcher's, so a skewed laptop clock shifts the window by the skew; RD-6 pass 1 should state how it handles that (for example by measuring against the newest `lastActivityAt` it has seen, or tolerating a few minutes). For the re-run comparison, the safe input value is the maximum `lastActivityAt` (or the `changed` map) across the class, never a sum of `writeCount`s.
- **Rules evaluation for `list`.** The R7 condition reads only the token and the path, never `resource.data`, so a plain collection listener passes without a filter. Because `rdAuthed()` already ties `{portal}` to the token's portal, there is no `platform_id` on the document for a rule to check, and none is needed.
- **Who can read.** A researcher token for the class. RD-4's class runner token is a researcher token with the runner claim, so the rule admits it too, but nothing on the VM reads these documents, and R9 does not pin that read. Teachers and learners cannot: a learner seeing classmates' activity would be a disclosure the dashboard does not need.
- **The identifier formats R4 checks are rigse's.** `Portal::Clazz#generate_class_hash` sets `SecureRandom.hex(24)` (48 lowercase hex, `rails/app/models/portal/clazz.rb:302`), and the learner token's `platform_user_id` is the portal user's integer id (`jwt_controller.rb`), which the answer carries as its `platform_user_id`. The Activity Player writes `resource_link_id` as `offeringData.id.toString()` (`activity-player/src/portal-api.ts:428`). Read 2026-10-11.
- **CLUE-693.** Its `{portal}` prefix inside CLUE's project is its own choice (CLUE's tree is `authed/{portal}/…`); what it must match is R5's fields and R4's meaning of `{class_hash}` and `{uid}`.

## Out of Scope

- CLUE's trigger and rules (CLUE-693), and the app's listeners, count and re-run loop (RD-6 pass 1).
- Activity from `interactive_state_histories`, plugin states or the object store: an answer save accompanies each, and answers are what a package reads.
- Teacher-facing activity views, and the `class-activity` page of `final-design.md` 15.2.
- Pruning or expiring activity documents.
- A metric, alarm or kill-switch setting; the function is turned off by deleting it.
- Changing Jira's "Done when" text to drop "the metrics the stacks story added"; this spec records the correction.

## Open Questions

### RESOLVED: Where do the activity documents live in report-service's Firestore?
**Context**: The story, CLUE-693 and the plan name `activity/{class_hash}/users/{uid}`. RD-6 pass 1 builds its listener path from the answer, and CLUE-693 copies the shape. REPORT-143 puts everything else the dashboard reads under `researcher_dashboard/{portal}` with a portal check its rules build on.
**Options considered**:
- A) `researcher_dashboard/{portal}/activity/{class_hash}/users/{uid}`: inside REPORT-143's tree, reusing its portal check; the story's path becomes the suffix under each project's own prefix.
- B) `activity/{class_hash}/users/{uid}` at the root, as written: a top-level collection outside REPORT-143's block, which then needs its own portal check (or none), and holds every portal's classes in one collection.

**Decision**: A (Doug, 2026-10-11, stage 8). `researcher_dashboard/{portal}/activity/{class_hash}/users/{uid}`, inside REPORT-143's tree and its portal check; the story's `activity/{class_hash}/users/{uid}` is the suffix under each project's own prefix. Recorded in R4 and R7.

### RESOLVED: Judgment call: a separate function rather than a branch in `createSyncDocAfterAnswerWritten`
**Options considered**:
- A) A new function on the same path.
- B) Add the activity write to the existing trigger, costing no extra invocation.

**Decision**: A. B couples the dashboard to the S3 sync's settings gate and failure path, and hides the cost inside an existing function's count; A's cost is one invocation per answer write, which the story accepts and R11 makes visible by name.

### RESOLVED: Judgment call: no identity fields on the document
**Options considered**:
- A) Three fields only; the path carries the portal, class and learner.
- B) Also store `platform_id`, `context_id`, `platform_user_id`, as answers do.

**Decision**: A. No rule reads them (R7 checks the path and token), no reader needs them, and both writers would have to agree on three more names, one of which (`context_id` against `class_hash`) is already spelled two ways across the two projects.

### RESOLVED: Judgment call: which writes count
**Options considered**:
- A) Exclude deletes, moves, anonymous answers and identical re-saves, and count collaborators' copies (R3).
- B) Also exclude collaborators' copies (`collaboration_owner_id` not equal to `platform_user_id`).
- C) Record every answer write that names a class.

**Decision**: A (Doug, 2026-10-16, for the copies). The count is "students who did something", and a teacher's move is not that student doing something. Collaborators work together at one machine and the portal treats the work as theirs, so a copy counts. B would also skip every later solo save by a collaborator, since that save keeps the copy's `collaboration_owner_id` (Technical Notes, Collaborators), and telling the two apart would rest on incidental fields such as the copy's `remote_endpoint`.

### RESOLVED: Low confidence: a merge `set` with `increment`, `serverTimestamp` and a nested map key behaves as R2 assumes
**Context**: R2's single write depends on merge semantics for the nested `changed` map and on `increment` starting from an absent field.

**Decision**: It does. Run against the Firestore emulator (firebase-tools 15.24.0, firebase-admin 10.0.0, 2026-10-11, throwaway script deleted): the first write created `writeCount: 1`, one `changed` key and a `Timestamp` `lastActivityAt`; a second write to another key gave `writeCount: 2`, kept the first key's time unchanged and moved `lastActivityAt` forward; a key containing a dot was stored as one key, not split into a path; and 150 concurrent writes from 30 learners (5 each) all succeeded and produced 30 documents whose `writeCount`s summed to 150.

### RESOLVED: Low confidence: R7's `list` passes for a plain collection listener with REPORT-143's `rdIsResearcher()`
**Context**: The rule reads only the token and path; whether the emulator accepts an unfiltered `list` and an empty-collection listener under REPORT-143's helpers had to be run with REPORT-143's block applied.

**Decision**: It does. `master`'s rules at `bfbda61` with R7's block inside REPORT-143's, against the emulator (2026-10-14, throwaway; first run 2026-10-11 against REPORT-143's spec): a listener on the empty collection received an empty snapshot; the class's researcher token got and listed; another class, another portal, a learner, a teacher and an anonymous caller were refused; every create, update and delete was refused, including a runner token with a fresh `auth_time`; and `activity/{classHash}` itself was refused. With the `class_hash` clause removed, the two other-class cases failed, and with `allow create: if rdIsRunner()` added, the runner's create failed, so those cases test R7 rather than the default denial.

### RESOLVED: Low confidence: the Activity Player's re-saves compare unchanged through the deployed trigger
**Context**: R3's `unchanged` check compares serialized snapshots, so a re-save whose keys came back in another order would count. The module's tests build their snapshots by hand.

**Decision**: They do compare unchanged. The registered function ran in the functions emulator (firebase-tools 15, demo project, 2026-10-16, throwaway script) on Activity Player-shaped merge `set`s. A create wrote the document with the three fields. A `resource_link_id` of `"__x__"` wrote nothing and logged `activity.skipped`. A re-save with a new `created` and `interactive_state_history_id`, and the same re-save with its keys reversed, each left `writeCount` at 1. A content change made it 2, and a move to another `context_id` wrote nothing. Two Admin SDK reads of the stored answer returned its keys in different orders, but the trigger's before and after compared equal, so the emulator's event snapshots come in a stable order. On production, R12's page-reload check exercises the same comparison if the interactive re-posts on load.

### RESOLVED: Judgment call: share `rdResearcherOfClass` with REPORT-143's classes match rather than copy its condition
**Options considered**:
- A) Repeat `rdIsResearcher() && request.auth.token.class_hash == classHash` in the activity match, leaving REPORT-143's block untouched.
- B) Move `rdResearcherOfClass` to the `researcher_dashboard/{portal}` level as `rdResearcherOfClass(classHash)` and call it from both matches.
- C) Nest the activity documents under `classes/{classHash}`, which changes the path RD-6 pass 1 and CLUE-693 use.

**Decision**: B (Doug, 2026-10-14). The function reads only `classHash`, `request.auth` and, through `rdIsResearcher()`, `{portal}`, all visible at the block level, and nothing from `resource` or `request.resource`. Checked against the emulator on `bfbda61`'s rules (2026-10-14, throwaway): all five suites in `tests/` pass unchanged (218 tests) with the move alone and with R7's block added. With the `class_hash` term removed from the shared function, 4 of REPORT-143's tests and both activity other-class cases fail.

## Self-Review

Roles: Senior Engineer, Security Engineer, QA Engineer, DevOps Engineer, and the two consumers (RD-6 pass 1's author, CLUE-693's author). Each finding below was checked against the code before it was written down; each had one defensible fix, applied in place.

### Security Engineer

#### RESOLVED: The trigger builds a document path from answer fields that the Admin SDK can write unchecked
The learner rules pin `context_id` and `platform_user_id` to the token, but `import_run` and `move_student_work` write answers with the Admin SDK (`api/import-run.ts`, `api/move-student-work.ts`), so a malformed `context_id` containing `/` would change the path's depth, and `db.doc` either throws or writes somewhere else. Fixed in R4: each segment is checked (`CLASS_HASH` for the class, digits for the learner, a URL for the portal), and a failing write is skipped and logged.

### Senior Engineer

#### RESOLVED: R4's class check would be a third copy of `CLASS_HASH`
`/^[0-9a-f]{48}$/` is already defined twice, in `run-package.ts:76` and `derive-profile-route.ts:9`. Fixed in R4 and Technical Notes: it moves to `firestore-paths.ts` and all three import it.

### QA Engineer

#### RESOLVED: R12's researcher read could not be performed on staging
No deployed app reads the activity collection before RD-6 pass 1, and minting a researcher Firebase token by hand needs the dashboard's scoped access token. Fixed in R12: staging checks the document exists; the browser's read is covered by R9's emulator tests.

#### RESOLVED: R10's concurrency test overstated what the emulator proves
The emulator does not enforce the per-document write rate. Fixed in R10: it says the test proves the merge and the sharding, not the production limit.

### DevOps Engineer

#### RESOLVED: R14 left implementation waiting on an unscheduled merge
REPORT-143's PR might not have merged before this story's implementation. It merged as `bfbda61`, so R14 rebases onto `master`.

### RD-6 pass 1's author

#### RESOLVED: The window is computed on a different clock from the one that stamps `lastActivityAt`
`lastActivityAt` is server time; "active in the last N minutes" runs on the researcher's laptop. Fixed in Technical Notes: RD-6 pass 1 has to say how it handles skew.

### Security Engineer (second pass)

#### RESOLVED: A `platform_id` with no host passed R4's URL check and made the write throw
`new URL("foo:bar").host` and `new URL("file:///etc").host` are `""`, so `portalSegment` returns an empty segment and `db.doc` throws "Paths must not contain //" instead of skipping (throwaway emulator run of the spec's `activityTarget` and `recordActivity`). Fixed in R4: the host must be non-empty.

#### RESOLVED: `resource_link_id` is learner-controlled and became a map key unchecked
`learnerOwnerCreate` and `notChangingIdentifyingProps` (`firestore.rules:44-77`) never check `resource_link_id`: a throwaway rules run let a learner create answers with `"__x__"` and a 200-character string and change it on update. Run through the spec's code, `"__x__"` made the merge `set` fail with `INVALID_ARGUMENT: Invalid reserved name`, and any other string became a `changed` key. Fixed in R4 (`resource_link_id` must be a positive integer, which the Activity Player always writes) and R5 (the bound holds for Activity Player writes, not for a learner writing by hand).

### Senior Engineer (second pass)

#### RESOLVED: R4's digits check was a second, looser copy of REPORT-143's `PLATFORM_USER_ID`
REPORT-143's `PLATFORM_USER_ID = /^[1-9][0-9]*$/` (`storage-policy.ts:3`) is the stricter check; R4's `/^[0-9]+$/` also accepts `"0"` and `"0123"`, which the throwaway run wrote as learner `0123`. Fixed in R4 and R14: the trigger imports REPORT-143's pattern.
