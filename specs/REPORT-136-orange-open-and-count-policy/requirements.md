# Orange opens Blue for flex Sharks only, and the completion count ignores CODAP models

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-136
**Repo**: https://github.com/concord-consortium/report-service
**Implementation Spec**: [implementation.md](implementation.md)
**Status**: **In Development**

## Overview

Two corrections to the fall "I'm Done" pipeline, agreed with the PI on 2026-09-15 after REPORT-133 shipped: the Orange post-test button opens the Blue curriculum only for flex control students (a full-time control student's Blue stays closed until the researcher opens it after the EOC exam), and the completion gate counts only multiple-choice and open-response answers, so a CODAP model that saves state on page view no longer counts as an answered question. Ships as functions 1.8.2 with Blue's authored threshold moving from 209 to 203; needed before Orange is opened in January.

## Project Owner Overview

The study's full-time Sharks and Gators both take Florida's state End-of-Course exam, and the PI wants to compare their EOC scores with and without the Blue curriculum. A full-time Shark must therefore not get Blue until she opens it by hand after the exam. Flex students take no EOC, so a flex Shark who finishes Orange gets Blue opened automatically, as every Shark does today. Today's code opens Blue for every Shark, which would hand full-time Sharks the curriculum in January; after this change the pipeline reads the program from the student's class as it already does for the pre-test, opens Blue for flex Sharks only, and tells the teacher in the notification email why nothing was opened for a full-time Shark. A student is told nothing different.

Separately, the completion gate REPORT-133 put on Blue and Orange counts every saved answer document, and a CODAP model with learner state saves one the moment its page is viewed (verified on staging). Blue holds twenty of them, so a student could satisfy twenty of Blue's required items by scrolling. The PI's rule is to count only multiple-choice and open-response questions, which also leaves out Blue's six drawing and drag-and-drop items. Recounted from today's published content under that rule, Blue's authored number becomes 203 (from 209) and Green 59 and Orange 50 do not change; the Blue button is edited in place on release day, after the deploy.

## Background

REPORT-82 built the three fall stages. Its post-test stage (R6, R7) puts the control-only conditional inside `openTargetOffering`, which classifies the arm from the origin class word's `-gator` / `-shark` suffix and opens Blue for every control student. That followed the PI's 2026-07-29 answer ("true for the control students in both groups"), which she revised on 2026-09-15 (decisions log O16). `fall-programs.ts` already classifies the program from the `ft-2026-` / `fl-2026-` prefix for the pre-test's randomization; the open step does not use it. Both staging Orange passes on 2026-09-14 were full-time Sharks and both opened Blue.

REPORT-133 added `evaluate-completion` to the front of the Blue and Orange stages. The step counts every answer document under the launch context that passes `answerIsCompleted`, whose `interactive_state` branch treats any non-empty saved state as completed. The activity player sets an answer's `question_type` from the embeddable's authored `questionType`, and to `iframe_interactive` when there is none (activity-player `src/utilities/embeddable-utils.ts`), so a CODAP model is `iframe_interactive` however it is embedded, and Jie's planned question numbers on the Blue CODAPs change nothing. On 2026-09-15 a Blue CODAP page viewed with no click wrote `mw_interactive_669` (98,150 chars of state) nine seconds after load. The PI asked that CODAPs be ignored and confirmed that Blue's six drawing-tool and drag-and-drop questions (also `iframe_interactive`) stay out (decisions log O17). REPORT-133's closed spec describes those interactives as counting when touched; they count on view.

Neither change blocks the 2026-09-21 launch: nobody can press Orange until the PI opens it in January, and until this ships the Blue count leaks in the lenient direction only.

## Requirements

### A. The Orange open step

- **R1.** `openTargetOffering` classifies the origin class word's program with `classifyFallProgram` as well as its arm. Blue is opened only for a control student whose word classifies as `FLEX_PROGRAM`.
- **R2.** A full-time control student is handled like a treatment student: success, no portal call (no mint, no class read, no write), and the summary line `No activity to open for this student (full-time program; the researcher opens the curriculum after the EOC exam)`, which `send-email` renders into the teacher notification unchanged. It shares its opening phrase with the treatment line and names no sequence.
- **R3.** Treatment students of either program are unchanged: success, "No activity to open for this student", no portal call. Gators' behavior does not change.
- **R4.** A word that classifies as neither program is a classified failure on either arm, with the step's own `STUDENT_FAILURE_MESSAGE` and the word logged at error, exactly as a word carrying neither arm suffix is today. This follows the standing rule that an unrecognized program prefix is never a default.
- **R5.** The step classifies the arm and the program before any branch and before any portal call, fails if either is undefined, and only then takes the treatment, full-time control, or open path.
- **R6.** `open-target-offering.test.ts` covers: the full-time control case (success, the summary, no portal call), the flex control case opening the target (the existing write-path and privacy tests move to a flex control word), the unclassifiable-program case on a treatment word and on a control word, and treatment on both programs. The harness fixture-agreement block also pins the harness's control words to the programs their scenarios assume.
- **R7.** Harness: `fall-orange-control` is renamed `fall-orange-fulltime` (with its `FALL_CONTEXTS` key), still launches from `STUDY_CONTROL_CLASS` (`ft-2026-bingler-shark`), and asserts that nothing was opened; a new `fall-orange-flex` launches from `fl-2026-section1-shark` and asserts the open, matching the `fall-green-fulltime` / `fall-green-flex` pair. The direct-step `open-target-*` scenarios that expect the open move to the flex word, and a direct-step `open-target-fulltime` is added beside `open-target-treatment`. `run.js` gains an opt-in `expect.opened` read from the stub's lock record, which gains the offering id from the PUT path: an offering id asserts the last write was `locked: "false"` on that offering (the scenario declares its class fixture's Blue id), `false` asserts the record exists with `locked: "true"` (the lock ran and nothing after it wrote), so a "nothing opened" scenario cannot pass on code that opened, and an open of the wrong offering cannot pass either. The email line is not asserted by the harness: the unit test pins it and `send-email` renders it unchanged. README and comments updated.
- **R8.** REPORT-82's R6, R7 and R15e gain amendment notes in the form of the REPORT-133 amendments, pointing at this spec's closed file.
- **R9.** The `ai4vs-status` tool's inverted-Blue expectation for full-time Sharks (unpushed `ai4vs-status-tool` branch) is out of scope here and noted for that branch.

### B. The completion count

- **R10.** `evaluateCompletion` counts an answer document only when its `question_type` is `multiple_choice` or `open_response` and it passes `answerIsCompleted`. Every other `question_type`, and a document with none, is not counted. `image_question` is excluded deliberately, matching the PI's words (no image questions exist in the three sequences).
- **R11.** `answerIsCompleted` is not changed. The allowlist is the step's counting policy.
- **R12.** The step's info log line reports the counted number, the document total, the threshold, and how many documents the type filter ignored, in the form `4 of 7 answer(s) completed (need 5; 2 ignored by question type)`, so a refused Blue student's shortfall is explainable from the log.
- **R13.** `evaluate-completion.test.ts` covers the filter: a completed `iframe_interactive` document (CODAP-shaped `interactive_state` with a non-empty state, and with attachments) is not counted; `multiple_choice` and `open_response` documents that pass `answerIsCompleted` are; a completed `image_question_answer` document is not; a document with no `question_type` is not; an allowlisted type that fails `answerIsCompleted` is not.
- **R14.** Harness: `seed.js` writes the demographic answers in the activity player's multiple-choice shape (`type: "multiple_choice_answer"`, `question_type: "multiple_choice"`, `answer.choice_ids`, plus the `report_state` the demographics reader parses), since without a `question_type` every gated scenario counts zero, and one CODAP-shaped `iframe_interactive` document per seeded scenario (`type: "interactive_state"`, a parseable empty authored state and a non-empty interactive state, so `readDemographics` skips it silently and `answerIsCompleted` accepts it). `fall-blue-refused` (four countable answers plus the CODAP against a threshold of five) is what proves the exclusion: it passes on today's code and refuses on the new code.
- **R15.** `specs/REPORT-133-blue-orange-completion-gate.md` gains an amendment note at its Technical Notes authoring line, stating that a learner-state interactive counts on page view and that this story excludes them from the count, and one at its R7, where `fall-orange-control` is named, giving the renamed scenario and its flex pair.
- **R16.** Authoring, on release day and not code: recount Blue from the published export with `count-questions.py` (per activity, embeddables whose authored `questionType` is `multiple_choice` or `open_response` and whose learner state is on, minus the PI's 2 per activity; 203 on the 2026-09-15 content) and edit `min_completed_questions` on the Blue button in place (ref_id 106611-MwInteractive). Green and Orange are recounted under the same rule as a check, not to change them: their buttons (106613, 59 and 106612, 50) are unchanged. Never delete and re-add a production button. The edit follows the production deploy in the same session: between the two the gate is 209 against a countable base of 215, stricter than intended but satisfiable.

### C. Release

- **R17.** Staging check on report-service-dev after deploying `taskWorker` and `submitTask` there: one full-time Shark (431 Test Bingler2 or 432 Test Hankamp1) presses Orange and Blue stays locked, the job succeeds, and the teacher email carries the R2 line; one flex Shark (one of the `fl-2026-` test students that landed in a `-shark` section) presses Orange and Blue is opened; one Blue press whose log line shows the count excluding a viewed CODAP document. Per-student unlock and job-document deletion per the phase 2 runbook; never the class-level offering PUT.
- **R18.** Functions 1.8.2: version bump, tag `report-service-v1.8.2`, `npm run buildinfo` before each deploy, `firebase deploy --only functions:taskWorker,functions:submitTask` to staging then production, verified from the deployed source zip (`build-info.json` names the merged commit; the compiled step carries the program check and the allowlist). Rollback is a redeploy of the same two functions from tag `report-service-v1.8.1` plus restoring 209 on the Blue button.
- **R19.** After production: republish the flowchart artifact the PI reviews (https://claude.ai/artifact/HVZdysz5StDibKe5gps4Cc) from `im-done-button/tools/build-flowchart.py` with the new Orange branch and the count rule, publishing with `url` set so the link stays the same; update decisions log rows O16 and O17 to shipped.

## Technical Notes

- `functions/src/tasks/ai4vs-flvs/open-target-offering.ts`: the arm check sits before the mint; the program check joins it. `classifyFallProgram` and `FLEX_PROGRAM` / `FULL_TIME_PROGRAM` come from `fall-programs.ts`, already imported for `armFromClassWord`.
- `functions/src/tasks/ai4vs-flvs/evaluate-completion.ts:56` is the one counting line; `answerIsCompleted` (`functions/src/tasks/answer-utils.ts`) has no other non-test caller today.
- Answer-document fields, from the activity player and confirmed on staging documents (2026-09-15, student 432): `type` is the interactive's `answerType` (`multiple_choice_answer`, `open_response_answer`, `interactive_state`, ...); `question_type` is the authored `questionType` or `iframe_interactive`. The CODAP `mw_interactive_669` is `type: "interactive_state"`, `question_type: "iframe_interactive"`, with an empty-string authored state and 102 KB of interactive state; a multiple-choice answer is `type: "multiple_choice_answer"`, `question_type: "multiple_choice"`, `answer: { choice_ids: [...] }` (`question_id: managed_interactive_10867`, a library interactive). `platform_user_id` is a string. An offloaded state (`__attachment__` pointer plus an `attachments` map) passes `answerIsCompleted` like an inline one.
- `functions/harness/im-done-local/`: `seed.js` writes `type: "interactive_state"` with no `question_type`; `stub-portal.js` records every `update_student_metadata` call to `.last-lock.json` with the request's `locked` flag, so the last record of an Orange run is the open's write (`locked: "false"`) when the open ran and the lock's (`locked: "true"`) when it did not; `FALL_FLEX_CONTROL_CLASS` (`fl-2026-section1-shark`, id 30012) is a `classes/info` fixture with no offerings and needs its Orange (id = the new scenario's `resource_link_id`) and a locked Blue with an id distinct from 845; `scenarios.js` validates `expect` keys at require time, so `opened` joins `EXPECT_KEYS`. 33 scenarios today.
- `functions/src/tasks/ai4vs-flvs/open-target-offering.test.ts` uses `ft-2026-bingler-shark` as `CONTROL_WORD` for every write-path and privacy test.
- `send-email.ts` renders `result.summary ?? result.message` per step, so the R2 line needs no email change. The lock and the open both write through `applyOfferingState` to `PUT /api/v1/offerings/:id/update_student_metadata` (`offering-state.ts:96`), the route the stub records.
- `count-questions.py` in the oob tools folder (edited 2026-09-15) loads all three exports and prints each sequence's PI-rule number under both counting rules, every stateful `questionType` and the gate's `ALLOW` types only; the second is the number to author. Today's exports: Green 59 / 59, Orange 50 / 50, Blue 209 / 203.
- The Orange button's authored `completion_message` is `Done! Your teacher has been notified.`, so a full-time Shark is told nothing about a next activity.
- Staging: sequences 762 (Blue) and 763 (Orange); the full-time Sharks are 431 and 432 in `ft-2026-bingler-shark` / `ft-2026-hankamp-shark`; student 432's Blue is offering 1215 and holds 2 multiple-choice answers plus the CODAP document, so its press is the R17 count check (`2 of 3 answer(s) completed (need 2; 1 ignored by question type)`); a student with a successful job on a stage has the button disabled until that job document is deleted.

## Out of Scope

- Any change to `answerIsCompleted`, `lockCurrentOffering`, `resolveOriginClass`, `sendEmail`, or the runner.
- The `ai4vs-status` tool and `verify-buttons.js` on the `ai4vs-status-tool` branch.
- Per-activity thresholds, naming the missing questions, or counting by `question_id` prefix (rejected: `mw_interactive_` is a proxy for direct-URL embedding, would miss a CODAP re-added as a library interactive and drop a real question pasted by URL).
- Choosing the authored numbers; they are computed from the export on release day.
- The Green stage, which runs no open and whose questions are all multiple choice.

## Open Questions

### RESOLVED: 1. What does the teacher email say for a full-time control student?
**Context**: `send-email` renders the step's `summary` as `- open-curriculum: <summary>`. Treatment students get "No activity to open for this student". The teacher of a full-time Shark class reads this line for every Orange press; the PI also reads these emails.
**Options considered**:
- A) `No activity to open for this student (full-time program: Blue opens after the EOC exam)`
- B) `Blue stays closed for full-time students until the researcher opens it`
- C) Reuse the treatment line verbatim. Then neither the email nor a test can tell the two cases apart.

**Decision**: A (2026-09-15). Same opening phrase as the treatment line, the reason in the parenthetical, no sequence name.

---

### RESOLVED: 2. What happens to a `-shark` word with neither program prefix?
**Context**: `classifyFallProgram` returns `undefined` for a word that is not `ft-2026-` or `fl-2026-`. Today such a word opens Blue (the arm alone decides). A study subclass word always carries a prefix, so this is a placement fault, the same category as a word with neither arm suffix.
**Options considered**:
- A) Classified failure: the step's own `STUDENT_FAILURE_MESSAGE`, the word logged at error, nothing opened. Matches the arm branch. (Recommended)
- B) Open Blue, as today. Lenient toward the student, silent about the fault.
- C) Success, nothing opened, with a summary saying the program was unrecognized.

**Decision**: A (2026-09-15). The standing convention: every caller of `classifyFallProgram` treats an unrecognized prefix as a classified failure, never a default (recorded in the oob note on non-study class words). The notify-only path for non-study words is a separate story.

---

### RESOLVED: 3. Scenario names for the two Orange cases
**Context**: `fall-orange-control` today proves the open. After this change it proves the no-open (full-time) case, and a second scenario proves the open (flex). The names appear in the README table and the summary output.
**Options considered**:
- A) Keep `fall-orange-control` for the full-time case; add `fall-orange-flex-control`.
- B) Rename to `fall-orange-fulltime` and add `fall-orange-flex`, matching the `fall-green-fulltime` / `fall-green-flex` pair. Renaming also renames its `FALL_CONTEXTS` key and the stub's Orange offering id reference. (Recommended)

**Decision**: B (2026-09-15). Matches the Green pair; the rename touches the scenario, its `FALL_CONTEXTS` key, the stub's Orange offering id reference and the README table.

---

### RESOLVED: 4. Shape of the seeded harness answers
**Context**: The seed's demographic answers are `type: "interactive_state"` with a `report_state` the demographics reader parses. Under R10 they need a `question_type`. The real activity player writes a multiple-choice answer as `type: "multiple_choice_answer"`, `question_type: "multiple_choice"`, `answer: { choice_ids }`, plus the same `report_state`.
**Options considered**:
- A) Add `question_type: "multiple_choice"` only. Smallest change; the documents keep a shape the activity player never writes for a multiple-choice question.
- B) Write the real multiple-choice shape (`type`, `question_type`, `answer.choice_ids`, `report_state`). The seed then models production documents, and `answerIsCompleted`'s multiple-choice branch is what the harness exercises. (Recommended)

**Decision**: B (2026-09-15). The seed models what the activity player writes, and the multiple-choice branch of `answerIsCompleted` is what the harness exercises.

---

### RESOLVED: 5. Should the harness also assert the teacher email line?
**Context**: R7's `expect.opened` observes the open through the stub's lock record. The email body is not recorded: `.last-send.json` holds the class id and subject only. The R2 line is pinned by the unit test and rendered by `send-email` unchanged, so the whole-pipeline scenario would be re-asserting composition.
**Options considered**:
- A) `opened` only. (Recommended)
- B) Also record the send body in the stub and add an opt-in `expect.emailIncludes`.

**Decision**: A (2026-09-15). `opened` observes the decision; the line's text is pinned by the unit test.

---

### RESOLVED: 6. Does the count log line report what the type filter excluded?
**Context**: Today: `evaluate-completion: 4 of 7 answer(s) completed (need 5)`, where 7 is the snapshot size. After R10 a Blue student with many viewed CODAPs will show a count well below the document total, and the first question when a student is refused will be why.
**Options considered**:
- A) `evaluate-completion: 4 of 7 answer(s) completed (need 5; 2 ignored by question type)`. One extra number, computed from the same snapshot. (Recommended)
- B) Leave the line as it is.

**Decision**: A (2026-09-15). One extra number from the same snapshot.

## Self-Review

### Senior Engineer

#### RESOLVED: Classify the program and the arm together, and fail on either
R1 to R5 read as "arm first, then program for control only". A treatment word with a bad prefix (`f-2026-bingler-gator`) would then succeed silently while the same fault on a control word fails loudly. Resolved (2026-09-15): both classifications precede every branch and either `undefined` is the failure, on either arm; R4 and R5 reworded, R6 gains the treatment-word case.

---

### QA Engineer

#### RESOLVED: `expect.opened` should observe which offering was opened
The stub's lock record carries `locked`, `active` and `user_id` but not the offering id from the PUT path, so `opened: true` would pass on an open that unlocked the wrong offering. Resolved: the record gains the offering id from the path; `opened: true` asserts `locked: "false"` and the id of the class fixture's Blue offering; `opened: false` asserts the record exists with `locked: "true"` (the lock ran, and nothing after it wrote).

#### RESOLVED: R13 has no `image_question` case
R10 excludes it deliberately; R13 should pin that. Resolved: a completed `image_question_answer` document is one of R13's not-counted cases.

#### RESOLVED: the seeded CODAP document must not trip the demographics reader
`readDemographics` parses every document's `report_state` and warns on an unparseable `authoredState`; a faithful CODAP document (empty authored state) would add a warning to every Green run. Resolved: the seeded document carries a parseable empty authored state and a non-empty interactive state, so the reader skips it silently and `answerIsCompleted` accepts it.

---

### Education Researcher

#### RESOLVED: what a full-time Shark is told after Orange
The Orange button's authored `completion_message` is `Done! Your teacher has been notified.` (verified in the staging authoring and `verify-button.py`), so a full-time Shark is told nothing about a next activity. No change; noted in Technical Notes.

---

### Teacher

No finding beyond the email line settled in question 1: the teacher of a full-time Shark class reads the same email shape as before, with one line explaining why nothing was opened.

---

### DevOps Engineer

#### RESOLVED: order of the production deploy and the Blue button edit
Between the deploy and the edit, Blue's threshold is 209 against a countable base of 215, so the gate is stricter than intended but still satisfiable; with the edit first it is 203 against a base that still counts CODAPs. Resolved: deploy first, then edit the button in the same session; R16 says so.

#### RESOLVED: rollback
Resolved: R18 names it: redeploy `taskWorker` and `submitTask` from tag `report-service-v1.8.1` and restore 209 on the Blue button.
