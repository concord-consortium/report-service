# Orange opens Blue for flex Sharks only, and the completion count ignores CODAP models

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-136

**Status**: **Closed**

## Overview

Two corrections to the fall "I'm Done" pipeline, agreed with the PI on 2026-09-15 after REPORT-133 shipped: the Orange post-test button opens the Blue curriculum only for flex control students (a full-time control student's Blue stays closed until the researcher opens it after the EOC exam), and the completion gate counts only multiple-choice and open-response answers, so a CODAP model that saves state on page view no longer counts as an answered question. Ships as functions 1.8.2 with Blue's authored threshold moving from 209 to 203; needed before Orange is opened in January.

The study's full-time Sharks and Gators both take Florida's state End-of-Course exam, and the PI wants to compare their EOC scores with and without the Blue curriculum, so a full-time Shark must not get Blue until she opens it by hand after the exam. Flex students take no EOC, so a flex Shark who finishes Orange gets Blue opened automatically. Separately, a CODAP model with learner state saves an answer document the moment its page is viewed (verified on staging), and Blue holds twenty of them, so a student could satisfy twenty of Blue's required items by scrolling. The PI's rule is to count only multiple-choice and open-response questions, which also leaves out Blue's six drawing and drag-and-drop items.

## Requirements

### A. The Orange open step

- **R1.** `openTargetOffering` classifies the origin class word's program with `classifyFallProgram` as well as its arm. Blue is opened only for a control student whose word classifies as `FLEX_PROGRAM`.
- **R2.** A full-time control student is handled like a treatment student: success, no portal call, and the summary line `No activity to open for this student (full-time program; the researcher opens the curriculum after the EOC exam)`, which `send-email` renders into the teacher notification unchanged. It shares its opening phrase with the treatment line and names no sequence.
- **R3.** Treatment students of either program are unchanged: success, "No activity to open for this student", no portal call.
- **R4.** A word that classifies as neither program is a classified failure on either arm, with the step's own `STUDENT_FAILURE_MESSAGE` and the word logged at error, exactly as a word carrying neither arm suffix is. An unrecognized program prefix is never a default.
- **R5.** The step classifies the arm and the program before any branch and before any portal call, fails if either is undefined, and only then takes the treatment, full-time control, or open path.
- **R6.** `open-target-offering.test.ts` covers the full-time control case, the flex control case opening the target (the write-path and privacy tests run on a flex control word), the unclassifiable-program case on a treatment word and on a control word, and treatment on both programs; the harness fixture-agreement block pins the harness's control words to the programs their scenarios assume.
- **R7.** Harness: `fall-orange-control` is renamed `fall-orange-fulltime` and asserts that nothing was opened; `fall-orange-flex` launches from `fl-2026-section1-shark` and asserts the open. The direct-step `open-target-*` scenarios that expect the open move to the flex word, and `open-target-fulltime` is added. `run.js` gains an opt-in `expect.opened` read from the stub's lock record, which carries the offering id from the PUT path: an offering id asserts the last write was `locked: "false"` on that offering, `false` asserts the record exists with `locked: "true"`. The email line is not asserted by the harness.
- **R8.** REPORT-82's R6, R7 and R15e carry amendment notes pointing at this file.
- **R9.** The `ai4vs-status` tool's inverted-Blue expectation for full-time Sharks (unpushed `ai4vs-status-tool` branch) is out of scope here and noted for that branch. *(The staging check reproduced it: `status.js check` reports one problem, for student 432, which is the tool's expectation and not the pipeline.)*

### B. The completion count

- **R10.** `evaluateCompletion` counts an answer document only when its `question_type` is `multiple_choice` or `open_response` and it passes `answerIsCompleted`. Every other `question_type`, and a document with none, is not counted. `image_question` is excluded deliberately, matching the PI's words.
- **R11.** `answerIsCompleted` is not changed. The allowlist is the step's counting policy.
- **R12.** The step's info log line reports the counted number, the document total, the threshold, and how many documents the type filter ignored: `4 of 7 answer(s) completed (need 5; 2 ignored by question type)`.
- **R13.** `evaluate-completion.test.ts` covers the filter: a completed `iframe_interactive` document (inline and offloaded state) is not counted; `multiple_choice` and `open_response` documents that pass `answerIsCompleted` are; a completed `image_question_answer` document is not; a document with no `question_type` is not; an allowlisted type that fails `answerIsCompleted` is not.
- **R14.** Harness: `seed.js` writes the demographic answers in the activity player's multiple-choice shape and one CODAP-shaped `iframe_interactive` document per seeded scenario (parseable empty authored state, non-empty interactive state). `fall-blue-refused` (four countable answers plus the CODAP against a threshold of five) is what proves the exclusion.
- **R15.** `specs/REPORT-133-blue-orange-completion-gate.md` carries amendment notes at its Technical Notes authoring line and at its R7.
- **R16.** Authoring, on release day and not code: recount Blue from the published export with `count-questions.py` (per activity, embeddables whose authored `questionType` is `multiple_choice` or `open_response` and whose learner state is on, minus 2 per activity; 203 on the 2026-09-15 content) and edit `min_completed_questions` on the Blue button in place (ref_id 106611-MwInteractive). Green (106613, 59) and Orange (106612, 50) are recounted as a check and unchanged. Never delete and re-add a production button. The edit follows the production deploy in the same session. *(pending: production release)*

### C. Release

- **R17.** Staging check on report-service-dev: one full-time Shark presses Orange and Blue stays locked; one flex Shark presses Orange and Blue is opened; one Blue press whose log line shows the count excluding a viewed CODAP document. Per-student unlock and job-document deletion, never the class-level offering PUT. *(done 2026-09-15; see Technical Notes)*
- **R18.** Functions 1.8.2: version bump, tag `report-service-v1.8.2`, `npm run buildinfo` before each deploy, `firebase deploy --only functions:taskWorker,functions:submitTask` to staging then production, verified from the deployed source zip. Rollback is a redeploy of the same two functions from tag `report-service-v1.8.1` plus restoring 209 on the Blue button. *(pending: production release)*
- **R19.** After production: republish the flowchart artifact the PI reviews (https://claude.ai/artifact/PRzAUCKqmpSKFKDNPakK6t) from `im-done-button/tools/build-flowchart.py` with the new Orange branch and the count rule, publishing with `url` set so the link stays the same; update decisions log rows O16 and O17 to shipped. *(pending: production release)*

## Technical Notes

- `functions/src/tasks/ai4vs-flvs/open-target-offering.ts`: both classifications precede the mint; `NOTHING_TO_OPEN_SUMMARY` and `FULL_TIME_CONTROL_SUMMARY` are exported and the second extends the first. The program branch reads a `Record<FallProgramId, string | undefined>` rather than testing one program for equality, so a program added to the union cannot compile without an entry (verified: `TS2741` at the record) instead of falling through to the open. `classifyFallProgram` and the program constants come from `fall-programs.ts`. The step's info line names the program, `fall-2026-full-time control student, nothing to open`.
- `functions/src/tasks/ai4vs-flvs/evaluate-completion.ts`: `COUNTED_QUESTION_TYPES` is exported and pinned by the test; the snapshot is mapped to plain answer objects once, then filtered by type and by `answerIsCompleted`.
- Answer-document fields, from the activity player and confirmed on staging: `type` is the interactive's `answerType` (`multiple_choice_answer`, `open_response_answer`, `interactive_state`, ...); `question_type` is the authored `questionType` or `iframe_interactive` when there is none, so a CODAP model is `iframe_interactive` however it is embedded. A CODAP saves within seconds of its page loading with no interaction (`mw_interactive_669`, 98,150 chars, nine seconds after load). An offloaded state (`__attachment__` pointer plus an `attachments` map) passes `answerIsCompleted` like an inline one.
- Counts on the 2026-09-15 published exports, from `count-questions.py` in the oob tools folder (which prints both rules per sequence): Green 59 / 59, Orange 50 / 50, Blue 209 / 203. Blue's 20 stateful `MwInteractive` non-questions are the CODAPs and were never in the authored count; its six `iframe_interactive` questions were, and are what the allowlist removes.
- Harness: `stub-portal.js` records every `update_student_metadata` call to `.last-lock.json` with the request's `locked` flag and the offering id from the path; the lock precedes the open, so the last record of an Orange run is the open's write when the open ran and the lock's when it did not. Both control-class fixtures carry a `blueOfferingId` (845 and 846). 35 scenarios, all passing against the emulator and the stub.
- `send-email.ts` renders `result.summary ?? result.message` per step, so the R2 line needs no email change. The job document keeps only the final result, so a step's summary line is observable from the function log, not from Firestore.
- Staging check, 2026-09-15, deployed from `1e1c8f3`: student 432 (Test Hankamp1, `ft-2026-hankamp-shark`) pressed Blue 1215 (`2 of 3 answer(s) completed (need 2; 1 ignored by question type)`, locked) then Orange 1216 (`full-time control student, nothing to open`, Orange locked, Blue 1215 still locked); student 434 (Test Flex1, `fl-2026-section1-shark`) pressed Orange 1232 with no answers (refused, `0 of 0`, nothing locked) and again after one multiple-choice and one open-response answer (`2 of 2`, Orange locked, `opened offering 1231`, Blue 1231 unlocked). Per-student rows were set through the `ai4vs-setup` admin client and stale job documents deleted by id.
- The Orange button's authored `completion_message` is `Done! Your teacher has been notified.`, so a full-time Shark is told nothing about a next activity.
- Staging: sequences 762 (Blue) and 763 (Orange); the full-time Sharks are 431 and 432; the flex Sharks 434 and 436; the staging buttons carry `min_completed_questions=2`.

## Out of Scope

- Any change to `answerIsCompleted`, `lockCurrentOffering`, `resolveOriginClass`, `sendEmail`, or the runner.
- The `ai4vs-status` tool and `verify-buttons.js` on the `ai4vs-status-tool` branch.
- Per-activity thresholds, naming the missing questions, or counting by `question_id` prefix (rejected: `mw_interactive_` is a proxy for direct-URL embedding, would miss a CODAP re-added as a library interactive and drop a real question pasted by URL).
- Choosing the authored numbers; they are computed from the export on release day.
- The Green stage, which runs no open and whose questions are all multiple choice.

## Not Yet Implemented

- **Production release** (R16, R18, R19): `chore: functions 1.8.2` on master, tag `report-service-v1.8.2`, `npm run buildinfo` and `firebase deploy --only functions:taskWorker,functions:submitTask --project report-service-pro`, verified from the deployed source zip (`build-info.json` names the merged commit, the compiled open step carries `FULL_TIME_CONTROL_SUMMARY`, the compiled count step the allowlist); then re-derive Blue's number with `count-questions.py` (Jie is editing Blue), edit `min_completed_questions` on Blue 845's button `106611-MwInteractive` in place and read it back with `verify-button.py`; regenerate and republish the flowchart; mark O16 and O17 shipped. Between the deploy and the button edit the gate is 209 against a countable base of 215, stricter than intended but satisfiable. Pending until the PR merges.
- **The `ai4vs-status` tool's inverted-Blue expectation for full-time Sharks** (R9): belongs to the `ai4vs-status-tool` branch.

## Decisions

### What does the teacher email say for a full-time control student?
**Context**: `send-email` renders the step's `summary` as `- open-curriculum: <summary>`; the teacher of a full-time Shark class reads this line for every Orange press, and the PI reads these emails.
**Options considered**:
- A) `No activity to open for this student (full-time program: ...)`, same opening phrase as the treatment line, the reason in the parenthetical.
- B) `Blue stays closed for full-time students until the researcher opens it`.
- C) Reuse the treatment line verbatim; neither the email nor a test could tell the two cases apart.

**Decision**: A (2026-09-15). Same opening phrase as the treatment line, the reason in the parenthetical, no sequence name.

---

### What happens to a `-shark` word with neither program prefix?
**Context**: `classifyFallProgram` returns `undefined` for a word that is not `ft-2026-` or `fl-2026-`. Before this change such a word opened Blue (the arm alone decided). A study subclass word always carries a prefix, so this is a placement fault, the same category as a word with neither arm suffix.
**Options considered**:
- A) Classified failure: the step's own `STUDENT_FAILURE_MESSAGE`, the word logged at error, nothing opened.
- B) Open Blue, as before. Lenient toward the student, silent about the fault.
- C) Success, nothing opened, with a summary saying the program was unrecognized.

**Decision**: A (2026-09-15). Every caller of `classifyFallProgram` treats an unrecognized prefix as a classified failure, never a default. The self-review added that both classifications precede every branch and either `undefined` fails on either arm, so a treatment word with a bad prefix fails as loudly as a control one.

---

### Scenario names for the two Orange cases
**Options considered**:
- A) Keep `fall-orange-control` for the full-time case; add `fall-orange-flex-control`.
- B) Rename to `fall-orange-fulltime` and add `fall-orange-flex`, matching the `fall-green-fulltime` / `fall-green-flex` pair.

**Decision**: B (2026-09-15).

---

### Shape of the seeded harness answers
**Context**: The seed's demographic answers were `type: "interactive_state"` with no `question_type`; under R10 every gated scenario would count zero.
**Options considered**:
- A) Add `question_type: "multiple_choice"` only; the documents keep a shape the activity player never writes for a multiple-choice question.
- B) Write the real multiple-choice shape (`type`, `question_type`, `answer.choice_ids`, `report_state`).

**Decision**: B (2026-09-15). The seed models what the activity player writes, and the multiple-choice branch of `answerIsCompleted` is what the harness exercises. The seeded CODAP document carries a parseable empty authored state (`{}` rather than the empty string a real CODAP carries) so `readDemographics` skips it silently instead of warning on every pre-test run.

---

### Should the harness also assert the teacher email line?
**Options considered**:
- A) `expect.opened` only; the line's text is pinned by the unit test and `send-email` renders it unchanged.
- B) Also record the send body in the stub and add an opt-in `expect.emailIncludes`.

**Decision**: A (2026-09-15). `opened` observes the decision; the whole-pipeline scenario would otherwise be re-asserting composition.

---

### Does the count log line report what the type filter excluded?
**Options considered**:
- A) `4 of 7 answer(s) completed (need 5; 2 ignored by question type)`, one extra number from the same snapshot.
- B) Leave the line as it was.

**Decision**: A (2026-09-15). A refused Blue student with many viewed CODAPs will show a count well below the document total, and the first question will be why.

---

### `expect.opened` observes which offering was opened
**Context**: The stub's lock record carried `locked`, `active` and `user_id` but not the offering id, so `opened: true` would have passed on an open that unlocked the wrong offering.
**Decision**: The record gains the offering id from the PUT path; the scenario declares its class fixture's Blue id (`opened: FALL_FLEX_CONTROL_CLASS.blueOfferingId`) rather than `true`, since the scenario is the one place that knows its class; `false` asserts the lock's own record is the last one, so a run that skipped the lock fails too.

---

### Order of the production deploy and the Blue button edit
**Context**: Between the deploy and the edit, Blue's threshold is 209 against a countable base of 215, stricter than intended but satisfiable; with the edit first it would be 203 against a base that still counts CODAPs.
**Decision**: Deploy first, then edit the button in the same session.

---

### Where the `NOTHING_TO_OPEN_SUMMARY` constant lives
**Options considered**:
- A) Both summaries exported from `open-target-offering.ts`, the full-time one extending the treatment one, the test asserting equality.
- B) Keep the treatment literal inline and write the full-time line out in full, two strings that must agree on their opening phrase with nothing checking.

**Decision**: A (2026-09-15). One source for the shared phrase.

---

### `count-questions.py` had no `ALLOW` and did not load Green
**Context**: The release step told the reader to narrow a constant the script did not have, and the script printed no Green number.
**Options considered**:
- A) Edit the script in the oob tools folder now: an `ALLOW` set at the counting line, Green loaded with its minus-2 rule, both rules printed per sequence.
- B) Leave the script and describe the edit for release day.
- C) A second script with the allowlist rule.

**Decision**: A (2026-09-15). Release day re-runs a script that already produced 203 / 50 / 59.

---

### Amendments and README passages the change invalidates
**Decision**: The self-review found REPORT-82 R15e and REPORT-133 R7 quoting the old contract, and the harness README's Scenarios section naming the old scenario; all three joined the plan (R8, R15, and the harness commit's README edits).

---

### Making the program branch exhaustive rather than an equality test
**Context**: Raised on PR #427 by emcelroy as optional hardening. The branch was `if (program === FULL_TIME_PROGRAM) return nothing-to-open`, with everything else falling through to the open. `FallProgramId` has two members, so it was correct; a third program added later would have compiled clean and silently opened the curriculum to a control student of that program, which is the one fault the study cannot undo.
**Options considered**:
- A) `Record<FallProgramId, string | undefined>` mapping each program to its no-open summary, matching the `Record<Arm, string>` pattern `fall-programs.ts` already uses; an incomplete record does not compile.
- B) A `switch` with a `default: assertNever(program)`, which also fails to compile but needs a helper the repo does not have.
- C) Leave it; not a current bug.

**Decision**: A (2026-09-16). All three shapes were compiled against a union carrying a third program: today's `if` compiled clean, the record failed with `TS2741`, the switch failed with `TS2345`. The record needs no new helper and keeps each program's summary beside the program, so a third one has to declare its own line or say explicitly that it opens.

---

### Review-driven departures from the plan
**Decision**: Recorded in the source spec's "As built" section: named snapshot helpers and a shorter table comment in the count test; `open-target-fulltime`'s comment matches `open-target-treatment`'s; the stub's `record` comment names the offering id and `locked` flag the `opened` assertion reads; American spelling in the rewritten pipelines comment; each answer document converted once in the count; the two control-class fixture comments trimmed to two lines.
