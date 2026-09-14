# Completion gate on the Blue and Orange "I'm Done" buttons

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-133
**Repo**: https://github.com/concord-consortium/report-service
**Implementation Spec**: [implementation.md](implementation.md)
**Status**: **In Development**

## Overview

Add the existing `evaluate-completion` step to the front of the `fall-2026-blue` and `fall-2026-orange`
pipelines, so the Blue curriculum and Orange post-test buttons refuse to lock a sequence until the
student has answered the authored minimum number of questions, exactly as the Green pre-test button
already does.

## Project Owner Overview

The fall AI-in-Math study has three "I'm Done" buttons. Today only the Green pre-test button checks
that the student answered enough questions before it acts; the Blue and Orange buttons lock the
sequence and email the teacher the moment they are pressed, so a student who opens Blue and clicks
straight through is recorded as having completed the curriculum. REPORT-82 deferred the check on those
two buttons because the threshold was the PI's to set. On 2026-09-02 the PI asked for it on both:
"We do want the I'm done button to count the questions and alert the kids if they missed anything,
especially for orange."

This story turns the check on for Blue and Orange. The mechanism already exists and is reused
unchanged; what changes is which buttons run it. The numbers each button requires are taken from the
published sequences and typed into the buttons separately, and the change has to be on production
before real recruitment starts on 2026-09-21.

## Background

`ai4vs-flvs` (`functions/src/tasks/ai4vs-flvs/index.ts`) dispatches each button press to an ordered
step array in `PIPELINES`, keyed by the authored `pilot`. The fall entries today:

| Pilot | Steps |
|---|---|
| `fall-2026-green` | `evaluate-completion`, `resolve-origin-class`, `random-assignment`, `enroll-class`, `lock-pre-test`, `send-email` |
| `fall-2026-blue` | `lock-curriculum`, `send-email` |
| `fall-2026-orange` | `resolve-origin-class`, `lock-post-test`, `open-curriculum`, `send-email` |

`evaluateCompletion` (`evaluate-completion.ts`) queries the student's answer documents for the launch
(`platform_id`, `resource_link_id`, `context_id`, `platform_user_id`), counts those that pass
`answerIsCompleted`, and compares the count against `request.min_completed_questions`. It makes no
portal call. It hard-fails when the parameter is absent or not a positive integer, and returns
`{ success: false, expected: true }` with the authored (or default) failure message when the count is
short, which the runner logs at warn and which leaves nothing written and the student unlocked.
Because one `resource_link_id` spans every activity in a sequence, the count is already
sequence-wide, so the step works unchanged on Blue and Orange.

REPORT-82's R5a settled that Blue and Orange run no completion check, and R5b recorded the
consequence: the lock records that the student pressed the button, not that they did the work, and a
treatment student who clicks through Blue is counted as treated. R5b also said the PI had not been
told, and that it was worth raising once launch pressure was off. It was raised on 2026-09-02 and she
asked for the gate, with the threshold expressed as each activity's question total minus an allowance
(minus 1 for Orange, minus 2 for Blue; on 2026-09-10 she chose minus 2 per activity for Green).

Nothing on production has been through a Blue or Orange stage yet: report-service-pro runs master
`cb3e512` with the three fall pipelines, no button is authored on any production sequence, and real
recruitment starts 2026-09-21.

## Requirements

**R1.** `PIPELINES["fall-2026-blue"]` becomes `evaluate-completion`, `lock-curriculum`, `send-email`.

**R2.** `PIPELINES["fall-2026-orange"]` becomes `evaluate-completion`, `resolve-origin-class`,
`lock-post-test`, `open-curriculum`, `send-email`.

**R3.** In both, `evaluate-completion` is the **first** entry, matching Green: it makes no portal call,
and it precedes the lock so a failed check leaves the student unlocked and able to answer more and
re-click. The relative order of the existing entries does not change; in particular Orange's lock
still precedes its open (REPORT-82 R6).

**R4.** The step entry reuses the Green entry's `name` (`evaluate-completion`) and `processingMessage`
(`Checking your answers…`). `send-email` prints one line per `stepResults` key, so the teacher
notification for Blue and Orange gains an `evaluate-completion: N of M questions completed` line.

**R5.** `evaluateCompletion`'s counting and threshold logic is not modified (R10 changes only the
message on a misauthored parameter). Consequences that follow from reusing it:
- `min_completed_questions` becomes **required** on the Blue and Orange buttons; a button without it
  fails every press (R10).
- The threshold is a single sequence-wide number. The PI's per-activity rule is translated into that
  number when the button is authored (sum over activities of `count - allowance`); the step cannot
  enforce the per-activity shape.
- The failure message can interpolate `${completed}` and `${min_completed_questions}` only; it cannot
  name the missing questions.

**R6.** `index.test.ts`'s `EXPECTED_HANDLERS` table asserts the new ordered handlers for both pilots,
and a new `evaluate-completion.test.ts` covers the step directly, which nothing does today: the absent
and invalid parameter paths (student-facing message, error log carrying the detail, no Firestore
read), the short count with an authored template (`expected: true`, both template variables interpolated),
the short count with no template (the default text, which spring students see), and the pass.

**R7.** The local harness's whole-pipeline scenarios `fall-blue-curriculum` and `fall-orange-control`
(`functions/harness/im-done-local/scenarios.js`) seed answers (`seedAnswers: true`) so they pass the
gate and keep proving their stages end to end. They already submit `min_completed_questions: 4`
through the shared `REQUEST`; the explicit line is added to their `request` for legibility, matching
the Green scenarios. One refused-path
scenario is added on Blue (`min_completed_questions` above the four seeded answers): it fails with the
authored message, writes no lock and sends no email, and the driver asserts all three. To make the
last two observable, the stub records each `update_student_metadata` and `send_class_teachers` body
to a file the way it already records `add_to_class` (`.last-enroll.json`), `run.js` removes all three
before every submit, and a failure scenario may declare `noLock` / `noEmail`, which `run.js` checks by
the files' absence. Opt-in per scenario, so the existing lock and send failure scenarios, which reach
those routes on purpose, are unchanged. The harness README's stage table and the
scenario comments that say those stages need no answers are updated.

**R8.** Documentation that states Blue and Orange run no completion check is updated: REPORT-82's
R5a/R5b and R13 table gain a note pointing here (the spec is closed, so a short amendment rather than
a rewrite), and the `functions/src/tasks/ai4vs-flvs/index.ts` comments above the two entries no
longer describe the lock as recording only a button press.

**R9.** The change is verified on staging before production, as a targeted run against one phase 2
student rather than a full phase 2 rerun. Deploy `taskWorker` and `submitTask` to report-service-dev,
pick a **control** (`-shark`) student from the phase 2 roster, and unlock that student's Blue and
Orange rows with `PUT /api/v1/offerings/:id/update_student_metadata` (`user_id`, `locked: false`)
through the `ai4vs-setup` admin session, never with the class-level `PUT /api/v1/offerings/:id`,
which rewrites every student's row on the offering. Then, in this order, on Blue (762) and then
Orange (763):
- press the button before a threshold is authored: the R10 message, still unlocked, no email;
- author `min_completed_questions` on the button, press with too few answers: the authored failure
  message with the counts filled in, still unlocked, no email;
- answer enough, press again: locked, teacher email carrying the `evaluate-completion` line, and for
  Orange on a control student, Blue opened.
Finish with `status.js check --env staging` reporting no problems. Then deploy the same two functions
to report-service-pro, before 2026-09-21. No functions version bump: the prior bumps were whole-repo
releases and `api`, which serves the version, is not part of this deploy. Each selective deploy is
preceded by `npm run buildinfo` on the merged master commit, since `firebase deploy --only` does not
run it and the gitignored `build-info.json` otherwise still names `cb3e512`. The production deploy is
verified the way the 2026-09-01 check was, from the deployed source zip: its `build-info.json` names
the merged commit, the functions' `updateTime` is the deploy's, and the compiled
`lib/tasks/ai4vs-flvs/index.js` lists `evaluate-completion` first for `fall-2026-blue` and
`fall-2026-orange`. The `api` root's `buildInfo` is not the check; it keeps reporting `cb3e512`.

**R10.** `min_completed_questions` stays **required** on every stage that runs the step, and an
absent or invalid value stays a hard failure that reaches the lock on no stage. What changes is what
the student sees: instead of the internal `request is missing required parameter
min_completed_questions` / `must be a positive integer, got: …` text, the step returns a
student-facing message in the style of the portal steps' `TELL_TEACHER_MESSAGE`
("Something went wrong checking your answers. Please tell your teacher."), and logs the parameter
detail at error so the fault is diagnosable from the function log. `TELL_TEACHER_MESSAGE` itself is
not reused: it says "setting up your class", which is wrong for this fault. Green and spring inherit
the same message, since the step is shared.

**R11.** Authoring rule: the Blue and Orange buttons are never authored without a
`min_completed_questions` line, with the number taken from the published export on the day, nor
without a `min_completed_questions_failure_message` worded for a sequence, since the step's default
says "in this activity" while the count spans every activity:
`You have answered ${completed} of the ${min_completed_questions} questions needed. Please go back and answer the questions you skipped, then click I'm Done again.` Blue may
start at a deliberately loose number and be tightened later; editing a button's params keeps its
`ref_id`. A Blue number that departs from the PI's rule (total minus 2 per activity, 212 on today's
export) is put to her before the button is authored, with the number, the rule it replaces and the
reason (97 open responses that would nearly all have to be answered; 20 stateful non-question
interactives that count), and her answer is recorded in the decisions log. Enforcing the rule in `verify-buttons.js` is a change on the `ai4vs-status-tool` branch.

## Technical Notes

- `functions/src/tasks/ai4vs-flvs/index.ts`: `PIPELINES`. The entry-name uniqueness rule (one writer
  of `stepResults[step.name]`) is satisfied: neither stage has an `evaluate-completion` entry today.
- `functions/src/tasks/ai4vs-flvs/index.test.ts`: `EXPECTED_HANDLERS`, and the mocked
  `evaluate-completion` snapshot tests, which currently drive `spring-2026`.
- `functions/harness/im-done-local/scenarios.js`: `fall-blue-curriculum` (launches from a `-gator`
  class, `seedAnswers` absent) and `fall-orange-control` (launches from a `-shark` class, comment says
  "it needs no answers at all"). The pre-test scenarios seed answers with `seedAnswers: true` and use
  `min_completed_questions: 4`; the seeded set is shared, so the same approach works if the seeded
  answers are written under each scenario's own `resource_link_id` / `context_id`. `run.js` merges
  every scenario's request over `REQUEST`, which already carries `min_completed_questions: 4`, so a
  harness scenario cannot reach the missing-parameter path by omitting the key; that path is the unit
  test's (R6).
- Authoring: the Blue and Orange buttons get a `min_completed_questions` line and, optionally, a
  `min_completed_questions_failure_message`, alongside `pilot`, `email_subject` and
  `completion_message`. Editing a button's params does not change its `ref_id`, so thresholds can be
  revised after authoring without orphaning assignments. Counts from today's production exports:
  Orange 844 is 36 + 16 = 52 questions; Blue 845 is 32 + 32 + 29 + 34 + 50 + 47 = 224 across six
  activities. Blue has open-response items that save non-empty state when touched, and 19 or so
  non-question interactives that also write state, so its count is looser than Orange's in both
  directions.
- `verify-buttons.js` / `buttons.js` (`functions/harness/ai4vs-sequences/`) exist only on the
  unpushed `ai4vs-status-tool` branch. They check authored `taskParams` keys against per-stage
  expectations and will need `min_completed_questions` added to the Blue and Orange expectations, on
  that branch.
- Per-student unlock on staging (R9): `API::V1::OfferingsController#update_student_metadata` is
  authorized by `OfferingPolicy#update?` (`class_teacher_or_admin?`), so the signed-in admin client in
  `functions/harness/ai4vs-setup/client.js` (on the `ai4vs-status-tool` branch) can call it for one
  `user_id`. The class-level `#update` with `locked` iterates every `UserOfferingMetadata` row on the
  offering, which is what `setup.js state` and the phase 2 runbook's reset sweep rely on and exactly
  what a one-student check must avoid.
- Deploy: `firebase deploy --only functions:taskWorker,functions:submitTask --project <project>`,
  dev first, then pro. `api` is not involved.

## Out of Scope

- Per-activity thresholds. Answer documents carry no activity field; bucketing by activity would mean
  fetching and walking the sequence export from the step. Not before the 21st.
- Naming the missing questions in the failure message.
- Any change to `evaluateCompletion` beyond R10, and any change to `lockCurrentOffering`,
  `openTargetOffering` or `sendEmail`.
- Choosing the authored numbers. They are computed from the published exports at authoring time and
  are not code.
- The staging checker (`verify-buttons.js`) update, which lives on another branch.

## Open Questions

<!-- Requirements-focused questions only (scope, acceptance criteria, business rules).
     Implementation questions go in implementation.md. -->

### RESOLVED: What happens when a Blue or Orange button is authored without `min_completed_questions`?
**Context**: Once the step runs on Blue and Orange, a button authored to the existing recipe (no
threshold line) fails every press, before any Firestore read, with an internal parameter message the
student sees. Verified with a throwaway unit test against `evaluateCompletion`. The PI has not yet
given a Blue number.
**Options considered**:
- A) Keep the hard-fail; author every button with a number from the export, loose for Blue at first.
- B) Skip the check when the parameter is absent. Reopens the REPORT-82 R5b gap by omission and
  changes spring and Green too.
- C) Keep the hard-fail but return a student-facing message and log the detail.

**Decision**: A plus C (2026-09-14). R10 and R11.

### RESOLVED: How much of staging does the pre-production check cover?
**Context**: Staging's Blue (762) and Orange (763) buttons exist with no threshold line, and the eight
phase 2 students sit finished, with Blue and Orange locked per student and few or no answers on
either. Neither stage randomizes, so no assignment or job documents are involved.
**Options considered**:
- A) One student, both stages, all three paths (misauthored, refused, passed), after unlocking only
  that student's rows.
- B) Full phase 2 rerun of all eight students after the full reset.
- C) Unit tests and the local harness only.

**Decision**: A (2026-09-14). R9.

## Self-Review

### Senior Engineer / Student

#### RESOLVED: The default refusal message says "in this activity" while the count spans the whole sequence
`evaluateCompletion`'s default failure text is `You have completed N of M required questions. Please
answer more questions in this activity.` Green never shows it because §5c authors
`min_completed_questions_failure_message`; today's Blue and Orange recipes author no message, so a
student refused on Blue reads "in this activity" while the shortfall may sit in any of six activities.
Suggested resolution: extend R11 so the Blue and Orange buttons also author a failure message worded
for a sequence (nothing in code changes; spring's default stays as it is).
**Resolution**: Resolved 2026-09-14: R11 now requires an authored, sequence-worded failure message on Blue and Orange. No code change.

---

### QA Engineer

#### RESOLVED: `evaluate-completion.ts` has no unit test, and R10 changes it
The step's only coverage is the mocked handler in `index.test.ts`; the parameter validation, the
short-count path and the message interpolation are asserted nowhere, and the messages R10 rewrites
would change with nothing failing. Suggested resolution: a requirement for
`evaluate-completion.test.ts` covering the absent and invalid parameter paths (student-facing message,
error log carrying the detail, no Firestore read), the short count (`expected: true`, both template
variables filled), and the pass.
**Resolution**: Resolved 2026-09-14: folded into R6.

#### RESOLVED: The harness has no refused-path scenario for any fall stage
`fall-blue-curriculum` and `fall-orange-control` will only ever prove the pass. The behavior this story
adds is the refusal, and the harness can reach it for free: the seeded answers are four, so a scenario
with `min_completed_questions: 5` must fail with the authored message, write no lock and send no
email. Suggested resolution: add one refused scenario to R7 (Blue is enough; the step is shared).
**Resolution**: Resolved 2026-09-14: folded into R7, one refused scenario on Blue.

---

### DevOps Engineer

No findings. Verified: zero commits under `functions/` between the deployed `cb3e512` and today's
master, so the production deploy carries exactly this branch. Deploying to dev makes staging's two
unthresholded buttons fail every press until the line is authored, which R9 uses deliberately.

---

### Education Researcher

No findings beyond what R5, R10 and R11 already record: the Blue lock comes to mean "did the work"
rather than "pressed the button", which is the PI's stated intent, a refused Orange press does not open
Blue for a control student until the post-test is done, which is what "especially for orange" asked
for, and the count is sequence-wide with Blue's stateful non-question items inflating it, which the
loose starting number absorbs.

---

## Self-Review, round 2 (2026-09-14)

Each finding below was checked against the code, the harness, the live sequence exports, the portal
source and the oob working notes before it was written. Candidates that did not survive that check
are not listed.

### QA Engineer

#### RESOLVED: R7's refused scenario promises two assertions the harness driver cannot make
R7 says the refused Blue scenario "fails with the authored message, writes no lock and sends no
email". `run.js` asserts `status` and `messageIncludes` and nothing else on a failure scenario;
`expect.failsAt` is printed, never checked; and the stub records only `add_to_class`
(`LAST_ENROLL_FILE`), so neither a lock (`update_student_metadata`) nor a send
(`send_class_teachers`) leaves any trace the driver can read. Every existing failure scenario has
the same limit, but for those the interesting fact is the message; for this one the interesting
fact is that nothing downstream ran. Suggested resolution: either narrow R7 to what is asserted
(failure status and the authored message, with "no lock, no email" left to the stub's terminal), or
add the same file channel the enrol check uses for the lock and send routes and let a failure
scenario declare `noLock` / `noEmail`, which `run.js` then asserts by the files' absence.
**Resolution**: Resolved 2026-09-14, option A: R7 now requires the lock and send records and the `noLock` / `noEmail` assertions.

#### RESOLVED: R6's new test should also pin the default refusal text
The pass, the short count with an authored template, and the two parameter faults are listed; the
short count with **no** template is not. That branch is the text spring students see today, and
R10's rewrite sits next to it. One more case, so deleting the default message cannot pass.
**Resolution**: Resolved 2026-09-14: folded into R6.

---

### DevOps Engineer

#### RESOLVED: R9's per-student unlock has no documented lever, and the documented one unlocks everyone
R9 rests on unlocking one student's Blue and Orange rows. The only lever the runbooks and
`setup.js state` use is `PUT /api/v1/offerings/:id` with `locked`, and the portal's
`API::V1::OfferingsController#update` rewrites **every** `UserOfferingMetadata` row on the offering
to match, so running it would erase the other seven students' phase 2 end state that
`status.js check` asserts. The per-student route exists:
`PUT /api/v1/offerings/:id/update_student_metadata` with `user_id` and `locked`, authorized by
`OfferingPolicy#update?` (`class_teacher_or_admin?`), so the `ai4vs-setup` admin session can call it
for the one student. Suggested resolution: R9 names that call and forbids the class-level PUT for
this step. Two adjacent details worth writing down while there: the student has to be a **control**
(`-shark`) student, or the "Blue opened" check and `check`'s inverted-Blue expectation cannot both
hold; and Blue must be run before Orange, as R9 already orders it, or Orange's open step reverts the
Blue lock the Blue pass just wrote.
**Resolution**: Resolved 2026-09-14: R9 names `update_student_metadata` and the control-student constraint; Technical Notes record the policy and the class-level hazard.

#### RESOLVED: R9 does not say how the production deploy is versioned or verified
Both previous production deploys of the task functions were preceded by a `chore: functions 1.x.0`
bump (1.7.0 on 2026-07-26, 1.8.0 on 2026-08-08, the latter being the `cb3e512` production runs). R9
deploys `taskWorker` and `submitTask` only, so the `api` root's `buildInfo.commit`, which is the
recorded way to read the deployed commit, keeps reporting `cb3e512` after this ships. Suggested
resolution: R9 states whether the version is bumped, and names the post-deploy check that actually
observes the new code (a press on a production button once one is authored, or the function's
deploy timestamp in the console), rather than the `api` root.
**Resolution**: Resolved 2026-09-14, option A: no bump; `npm run buildinfo` before each selective deploy; verification from the deployed zip, recorded in R9.

---

### Senior Engineer

#### RESOLVED: R7 implies the Blue and Orange scenarios lack `min_completed_questions` today; they do not
`run.js` builds each request as `{ ...REQUEST, ...scenario.request }` and `REQUEST` carries
`min_completed_questions: 4`, so `fall-blue-curriculum` and `fall-orange-control` already submit the
parameter (checked by evaluating the merged request). What they lack is `seedAnswers`, and without
it the gated stage refuses with "0 of 4", not with the missing-parameter message. Two consequences
for R7's wording: the change is "seed answers" and the explicit `min_completed_questions` line is
for legibility, matching the Green scenarios; and the misauthored-parameter path cannot be reached
in the harness by omitting the key, since `REQUEST` always supplies one, which is why R6 puts that
path in the unit test rather than R7.
**Resolution**: Resolved 2026-09-14: R7 reworded around `seedAnswers`; Technical Notes record the `REQUEST` default.

---

### Product Manager / Education Researcher

#### RESOLVED: R11's "deliberately loose" Blue number departs from the PI's rule with no requirement to tell her
Her rule is "total minus 2 for each activity" (2026-09-02). Today's export gives Blue six activities
and 224 questions, so her rule yields 212. R11 authorizes shipping something looser, and the reason
(97 open responses that must nearly all be answered, 20 stateful CODAP-style interactives that count
without being questions) is ours, argued in the worklist and recorded nowhere as having been put to
her. Out of Scope says the numbers are not code, which is right, but the decision to deviate from a
stated rule is a study decision, not an authoring detail. Suggested resolution: R11 gains one line
that the Blue starting number, the rule it replaces and the reason go to the PI before the button is
authored, and that her reply is logged in the decisions log. No code change.
**Resolution**: Resolved 2026-09-14, option A: R11 requires the deviation to be put to the PI before Blue is authored and her answer logged.
