# Completion gate on the Blue and Orange "I'm Done" buttons

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-133

**Status**: **Closed**

## Overview

Add the existing `evaluate-completion` step to the front of the `fall-2026-blue` and `fall-2026-orange` pipelines, so the Blue curriculum and Orange post-test buttons refuse to lock a sequence until the student has answered the authored minimum number of questions, exactly as the Green pre-test button already does. REPORT-82 deferred the check on those two buttons because the threshold was the PI's to set; on 2026-09-02 she asked for it on both. The mechanism is reused unchanged; what changes is which buttons run it, plus a student-facing message when a button is misauthored without a threshold. The change has to be on production before real recruitment starts on 2026-09-21.

## Requirements

- **R1.** `PIPELINES["fall-2026-blue"]` becomes `evaluate-completion`, `lock-curriculum`, `send-email`.
- **R2.** `PIPELINES["fall-2026-orange"]` becomes `evaluate-completion`, `resolve-origin-class`, `lock-post-test`, `open-curriculum`, `send-email`.
- **R3.** In both, `evaluate-completion` is the first entry, matching Green: it makes no portal call and precedes the lock, so a failed check leaves the student unlocked and able to answer more and re-click. The relative order of the existing entries does not change; Orange's lock still precedes its open (REPORT-82 R6).
- **R4.** The step entry reuses the Green entry's `name` and `processingMessage` (`Checking your answers…`). `send-email` prints one line per `stepResults` key, so the Blue and Orange teacher notifications gain an `evaluate-completion: N of M questions completed` line.
- **R5.** `evaluateCompletion`'s counting and threshold logic is not modified. Consequences: `min_completed_questions` becomes required on the Blue and Orange buttons; the threshold is a single sequence-wide number (the PI's per-activity rule is translated into it at authoring time, sum over activities of `count - allowance`); the failure message can interpolate `${completed}` and `${min_completed_questions}` only.
- **R6.** `index.test.ts`'s `EXPECTED_HANDLERS` table asserts the new ordered handlers for both pilots, and a new `evaluate-completion.test.ts` covers the step directly: the absent and invalid parameter paths (student-facing message, error log carrying the detail, no Firestore read), the short count with an authored template (`expected: true`, both variables interpolated), the short count with no template (the default text), and the pass.
- **R7.** The harness's `fall-blue-curriculum` and `fall-orange-control` scenarios seed answers (`seedAnswers: true`) and carry an explicit `min_completed_questions: 4`, so they pass the gate. One refused scenario is added on Blue (`fall-blue-refused`, threshold 5 against four seeded answers): it fails with the authored message, writes no lock and sends no email, and the driver asserts all three. The stub records each `update_student_metadata` and `send_class_teachers` body to a file the way it records `add_to_class`, `run.js` removes all three records before every submit, and a failure scenario may declare `noLock` / `noEmail`, checked by the files' absence. Opt-in, so the lock and send failure scenarios are unchanged. The README's stage table and the scenario comments are updated.

> **Amended by REPORT-136 (2026-09):** `fall-orange-control` is `fall-orange-fulltime`, joined by `fall-orange-flex`; both seed answers and pass the gate. See `specs/REPORT-136-orange-open-and-count-policy.md`.
- **R8.** Documentation stating that Blue and Orange run no completion check is updated: REPORT-82's R5a, R5b, entry-names table and R13 gain amendment notes, and the `index.ts` comments no longer describe the lock as recording only a button press.
- **R9.** Verified on staging before production, as a targeted run against one control student rather than a full phase 2 rerun: deploy `taskWorker` and `submitTask` to report-service-dev, unlock that student's Blue and Orange rows with `PUT /api/v1/offerings/:id/update_student_metadata` (never the class-level `PUT /api/v1/offerings/:id`, which rewrites every student's row), then on Blue and then Orange: press with no threshold authored (the R10 message, still unlocked, no email); author `min_completed_questions`, press with too few answers (the authored message with counts filled, still unlocked, no email); answer enough, press again (locked, teacher email carrying the `evaluate-completion` line, and for Orange on a control student, Blue opened). Finish with `status.js check --env staging` reporting no problems. Then deploy the same two functions to report-service-pro before 2026-09-21, with no functions version bump, `npm run buildinfo` before each selective deploy, and verification from the deployed source zip (`build-info.json` names the merged commit, `updateTime` is the deploy's, the compiled `index.js` lists `evaluate-completion` first for both stages). *(partial: the staging half was completed on 2026-09-14; the production deploy is pending. See Not Yet Implemented.)*
- **R10.** `min_completed_questions` stays required on every stage that runs the step, and an absent or invalid value stays a hard failure that reaches the lock on no stage. The student sees `Something went wrong checking your answers. Please tell your teacher.` instead of the internal parameter text, and the raw value is logged at error. `TELL_TEACHER_MESSAGE` is not reused (it says "setting up your class"). Green and spring inherit the same message.
- **R11.** Authoring rule: the Blue and Orange buttons are never authored without a `min_completed_questions` line, with the number taken from the published export on the day, nor without a `min_completed_questions_failure_message` worded for a sequence (`You have answered ${completed} of the ${min_completed_questions} questions needed. Please go back and answer the questions you skipped, then click I'm Done again.`). Blue may start at a deliberately loose number and be tightened later; editing a button's params keeps its `ref_id`. A Blue number that departs from the PI's rule (total minus 2 per activity, 212 on the 2026-09-14 export) is put to her before the button is authored, with the number, the rule it replaces and the reason, and her answer is recorded in the decisions log. *(not yet done: production authoring is pending. See Not Yet Implemented.)*

## Technical Notes

- `functions/src/tasks/ai4vs-flvs/index.ts`: `PIPELINES`. The entry-name uniqueness rule (one writer of `stepResults[step.name]`) holds: neither stage had an `evaluate-completion` entry before.
- `functions/src/tasks/ai4vs-flvs/evaluate-completion.ts`: the two parameter checks collapsed into one, since `Number(undefined)` and `Number(null)` both fail the integer test and the log line carries the raw value either way. `CHECK_FAILED_MESSAGE` is exported so the test pins the text rather than restating it.
- `functions/harness/im-done-local/`: `run.js` merges every scenario's request over `REQUEST`, which carries `min_completed_questions: 4`, so a harness scenario cannot reach the missing-parameter path by omitting the key; that path is the unit test's. The emulator does not reload `lib/` after a rebuild; restart it before re-running a scenario against changed compiled code.
- Authoring: the Blue and Orange buttons get `min_completed_questions` and `min_completed_questions_failure_message` alongside `pilot`, `email_subject` and `completion_message`. Counts from the 2026-09-14 production exports: Orange 844 is 36 + 16 = 52 questions; Blue 845 is 32 + 32 + 29 + 34 + 50 + 47 = 224 across six activities, with open-response items that save non-empty state when touched and around 19 non-question interactives that also write state, so Blue's count is looser than Orange's in both directions. Recount from the day's export at authoring time.

> **Amended by REPORT-136 (2026-09):** a learner-state interactive writes its answer document on page view, not on touch (a Blue CODAP saved within seconds of load with no click), and the step now counts only `multiple_choice` and `open_response` answers; Blue's threshold moved to the allowlist count minus 2 per activity. See `specs/REPORT-136-orange-open-and-count-policy.md`.
- Staging ids: 762 and 763 are the LARA **sequence** ids for Blue and Orange, and 687-MwInteractive / 688-MwInteractive their buttons. The portal **offerings** for the control class `ft-2026-bingler-shark` (574) are Blue 1211 and Orange 1212; on staging, offerings 762 and 763 are unrelated CLUE offerings. Read an offering before writing to it.
- A student who already has a successful job for a stage opens that page with the button disabled ("Done! Your teacher has been notified."); to re-press, delete that student's job documents for the stage (`sources/activity-player.concord.org/jobs`, filtered on `jobInfo.request.pilot` and `platform_user_id`), never the collection.
- Per-student unlock: `API::V1::OfferingsController#update_student_metadata` (`user_id`, `locked`) is authorized by `OfferingPolicy#update?` (`class_teacher_or_admin?`), so the `ai4vs-setup` admin client on the `ai4vs-status-tool` branch can call it. The class-level `#update` with `locked` iterates every `UserOfferingMetadata` row on the offering.
- `verify-buttons.js` / `buttons.js` (`functions/harness/ai4vs-sequences/`, on the unpushed `ai4vs-status-tool` branch) check authored `taskParams` keys per stage and need `min_completed_questions` added to the Blue and Orange expectations, on that branch.
- Deploy: `firebase deploy --only functions:taskWorker,functions:submitTask --project <project>`, dev first, then pro. `api` is not involved, so the `api` root's `buildInfo` keeps reporting the previous commit; the deployed zip is the check.

## Out of Scope

- Per-activity thresholds. Answer documents carry no activity field; bucketing by activity would mean fetching and walking the sequence export from the step.
- Naming the missing questions in the failure message.
- Any change to `evaluateCompletion` beyond R10, and any change to `lockCurrentOffering`, `openTargetOffering` or `sendEmail`.
- Choosing the authored numbers. They are computed from the published exports at authoring time and are not code.
- The staging checker (`verify-buttons.js`) update, which lives on another branch.

## Not Yet Implemented

The four code commits and the staging verification are done. On 2026-09-14, `taskWorker` and `submitTask` were deployed to report-service-dev from `29035f9`, and student 431 (Test Bingler2, control, `ft-2026-bingler-shark`) pressed Blue and then Orange through the three paths: the misauthored press showed the R10 message with the `(got undefined)` error line and no lock or email; the refused press showed `You have answered 0 of the 2 questions needed…` at warn with no lock or email; the passed press locked the stage and sent the teacher email carrying `evaluate-completion: 2 of 2 questions completed`, with the Orange pass reopening Blue. `status.js check --env staging` reported no problems. The staging buttons carry `min_completed_questions=2` and the sequence-worded failure message.

- **Production deploy** (R9, second half): merge to master, `npm run buildinfo`, `firebase deploy --only functions:taskWorker,functions:submitTask --project report-service-pro`, then verify from the deployed source zip. Pending; due before 2026-09-21.
- **Production authoring** (R11): put the Blue starting number, the PI's rule (212 on the 2026-09-14 export) and the reason for departing from it to the PI before Blue is authored, log her reply in the `im-done-button/decisions-log.md` oob file; recount both sequences from the authoring day's export; author both buttons with `min_completed_questions` and the sequence-worded failure message; press each once from a test student with too few answers as the authoring check. Pending; once the production deploy is live, a Blue or Orange button authored without the threshold lines fails every press.

## Decisions

### What happens when a Blue or Orange button is authored without `min_completed_questions`?
**Context**: Once the step runs on Blue and Orange, a button authored to the existing recipe (no threshold line) fails every press, before any Firestore read, with an internal parameter message the student sees. The PI had not yet given a Blue number.
**Options considered**:
- A) Keep the hard-fail; author every button with a number from the export, loose for Blue at first.
- B) Skip the check when the parameter is absent. Reopens the REPORT-82 R5b gap by omission and changes spring and Green too.
- C) Keep the hard-fail but return a student-facing message and log the detail.

**Decision**: A plus C (2026-09-14). R10 and R11.

---

### How much of staging does the pre-production check cover?
**Context**: Staging's Blue and Orange buttons existed with no threshold line, and the eight phase 2 students sat finished, with Blue and Orange locked per student and few or no answers on either. Neither stage randomizes, so no assignment or job documents are involved.
**Options considered**:
- A) One student, both stages, all three paths (misauthored, refused, passed), after unlocking only that student's rows.
- B) Full phase 2 rerun of all eight students after the full reset.
- C) Unit tests and the local harness only.

**Decision**: A (2026-09-14). R9.

---

### The default refusal message says "in this activity" while the count spans the whole sequence
**Context**: `evaluateCompletion`'s default failure text ends "Please answer more questions in this activity." Green never shows it because its button authors a message; the Blue and Orange recipes authored none, so a refused Blue student would read "in this activity" while the shortfall may sit in any of six activities.
**Decision**: R11 requires an authored, sequence-worded failure message on Blue and Orange. No code change; spring's default stays.

---

### `evaluate-completion.ts` had no unit test, and R10 changes it
**Context**: The step's only coverage was the mocked handler in `index.test.ts`; parameter validation, the short-count path and the message interpolation were asserted nowhere.
**Decision**: R6 gains `evaluate-completion.test.ts` covering the absent and invalid parameter paths, the short count with and without a template, and the pass. The no-template case was added in round 2 so deleting the default message cannot pass.

---

### The harness had no refused-path scenario for any fall stage
**Context**: The two stage scenarios can only ever prove the pass; the behavior this story adds is the refusal, and the seeded set of four answers reaches it for free with a threshold of five.
**Decision**: R7 gains one refused scenario on Blue (the step is shared by every stage that runs it).

---

### R7's refused scenario promised assertions the harness driver could not make
**Context**: `run.js` asserted `status` and `messageIncludes` only; the stub recorded only `add_to_class`, so neither a lock nor a send left any trace the driver could read. For this scenario the interesting fact is that nothing downstream ran.
**Options considered**:
- A) Add the same file channel the enrol check uses for the lock and send routes, and let a failure scenario declare `noLock` / `noEmail`.
- B) Narrow R7 to what is asserted and leave "no lock, no email" to the stub's terminal.

**Decision**: A. The stub's three record files are one map keyed by route so the stub writes them from one place and `run.js` clears them from one loop. Verified: with the gate moved behind the lock in the compiled pipeline, `fall-blue-refused` fails on `lock: REACHED the stub`.

---

### R7 implied the Blue and Orange scenarios lacked `min_completed_questions`; they did not
**Context**: `run.js` builds each request as `{ ...REQUEST, ...scenario.request }` and `REQUEST` carries `min_completed_questions: 4`. What the scenarios lacked was `seedAnswers`, and without it the gated stage refuses with "0 of 4", not with the missing-parameter message.
**Decision**: R7 reworded around `seedAnswers`, with the explicit threshold line added for legibility; the misauthored-parameter path belongs to the unit test, since the harness cannot reach it by omitting the key.

---

### R9's per-student unlock had no documented lever, and the documented one unlocks everyone
**Context**: The only lever the runbooks used was `PUT /api/v1/offerings/:id` with `locked`, which rewrites every `UserOfferingMetadata` row on the offering and would erase the other seven students' phase 2 end state.
**Decision**: R9 names `update_student_metadata` and forbids the class-level PUT for this step. The student must be a control (`-shark`) student, or the "Blue opened" check and the cross check's inverted-Blue expectation cannot both hold; and Blue must run before Orange, or Orange's open step reverts the Blue lock the Blue pass just wrote.

---

### How is the production deploy versioned and verified?
**Context**: Both previous production deploys of the task functions were preceded by a `chore: functions 1.x.0` bump. This deploy is `taskWorker` and `submitTask` only, so the `api` root's `buildInfo.commit`, the recorded way to read the deployed commit, keeps reporting the previous commit.
**Options considered**:
- A) No bump; `npm run buildinfo` before each selective deploy; verify from the deployed zip.
- B) Bump and deploy `api` too.

**Decision**: A. The prior bumps were whole-repo releases; `functions/src/index.ts` requires `build-info.json` at load, so `buildinfo` is also what keeps the upload loadable.

---

### R11's "deliberately loose" Blue number departs from the PI's rule
**Context**: Her rule is "total minus 2 for each activity" (2026-09-02), which yields 212 on the 2026-09-14 export. Shipping something looser is a study decision, and the reason (97 open responses that must nearly all be answered, around 20 stateful interactives that count without being questions) had been recorded nowhere as having been put to her.
**Decision**: R11 requires the Blue starting number, the rule it replaces and the reason to go to the PI before the button is authored, with her reply logged in the decisions log. No code change.

---

### R11 had no implementation step
**Context**: The plan covered R1 through R10 but nothing carried the PI conversation or the production authoring, and once the deploy is live a Blue or Orange button authored the old way fails every press.
**Decision**: A fifth, non-code step "Author the production Blue and Orange buttons" was added after the deploy step, rather than trimming the requirement.

---

### REPORT-82 has two more tables that state the old first entries
**Context**: Beyond R5a, R5b and R13, the log-prefix table's "First entry" column and R10's entry-names table state the contract R1 and R2 change.
**Decision**: One more amendment note under R10's entry-names table, covering both.

---

### A harness README count goes stale with the fifth fall scenario
**Decision**: "Four scenarios run a whole fall pipeline" becomes "Five". The intro's "three fall pipeline scenarios" counts the scenarios that run `enroll-specified-class` or `open-target-offering` (the two Green stages and Orange), which the refused scenario does not, so it stays three; and the success bucket's "four whole-pipeline fall stages" stays, since the refused scenario has its own bucket.

---

### `status.js check` lists the refused presses; it does not count them
**Context**: The plan's step 4 said the refused presses "do not surface" in the check. They do, in the Failures table; `problemCount` sums the portal and cross-check problems only, and the per-stage cross check keeps the latest success.
**Decision**: Step 4 reworded so the Failures rows are expected. Confirmed on 2026-09-14: four rows listed, "No problems found."

---

### The constant's doc comment
**Context**: Code review found the five-line TSDoc on `CHECK_FAILED_MESSAGE` longer than needed and unlike its `portal-api.ts` siblings.
**Decision**: One line naming the rejected alternative (`TELL_TEACHER_MESSAGE`), declared the way `RELOAD_MESSAGE` is; the plan's listings were synced to the committed text.
