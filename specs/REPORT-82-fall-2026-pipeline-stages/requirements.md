# Fall-2026 pipeline stages (pre-test, curriculum, post-test)

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-82
**Repo**: https://github.com/concord-consortium/report-service
**Implementation Spec**: [implementation.md](implementation.md)
**Status**: **In Development**

## Overview

Wire the fall-2026 FLVS study's three "I'm Done" trigger points into `ai4vs-flvs`'s pipeline table as
three stage-keyed step arrays, composed from steps already shipped by REPORT-79, REPORT-80 and REPORT-81.
This is the story that makes the fall study runnable end to end; it adds no new step and no new portal
capability. Two shipped steps do change: R11 has `resolve-origin-class` publish the launch offering's
class id and `send-email` consume it instead of re-reading the offering.

## Project Owner Overview

The fall AI-in-Math randomised study has three points where a student presses "I'm Done": at the end of
the Green pre-test, at the end of the Blue curriculum, and at the end of the Orange post-test. Every
individual action behind those buttons has already been built (check the student finished, randomise
them, move them into their study class, lock an activity behind them, open an activity for them, notify
the teacher). What is missing is the wiring that says which of those actions runs at which button, and
in what order. This story supplies that wiring, names the three configuration values the buttons are
authored with, and proves the whole flow end to end against a stub portal for both the full-time and
the flex cohort.

Nothing here changes what the researcher or the students experience beyond making the buttons work.
Two judgement calls inside it do touch the study, and both are settled below with their reasoning
recorded. The first is the order of the two actions at the post-test button, which decides what a
control student is left with if the system fails halfway through; it is resolved in favour of recording
the completion first. The second is that the curriculum and post-test buttons apply **no completion
threshold**, because the number is the PI's to set and there was no time to ask before launch: the lock
those buttons take therefore records that a student pressed the button, not that they did the work.
That limitation and its compensating control are written up in R5b, and it is the one thing in this
story worth raising with the PI once launch pressure is off.

## Background

### Where this sits

`functions/src/tasks/ai4vs-flvs/index.ts` holds a flat table, `PIPELINES`, mapping an authored `pilot`
string to an ordered array of `{ name, processingMessage, handler }`. `ai4vsFlvs` validates `pilot` and
the forwarded Firebase JWT, runs `validatePortalHost`, builds one `StepContext` (carrying a per-run
portal-token cache and an accumulating `stepResults`), then runs the array in order and aborts on the
first `success: false`. There is one entry today, `spring-2026`.

Every step the fall stages need is already shipped and unit-tested on this branch's ancestry:

| Step module | Export | Shipped by | What it does |
|---|---|---|---|
| `evaluate-completion.ts` | `evaluateCompletion` | REPORT-62 | Counts the student's completed answers in this launch against `min_completed_questions`. Firestore only, no portal call. |
| `resolve-origin-class.ts` | `resolveOriginClass` | REPORT-81 | Reads the launch offering, publishes `originClassWord` (normalised lowercase) on `StepOutput`. |
| `fall-random-assignment.ts` | `fallRandomAssignment` | REPORT-81 | Classifies the program from `originClassWord`, randomises, publishes `destinationClassWord`. No portal write. |
| `enroll-specified-class.ts` | `enrollSpecifiedClass` | REPORT-79 | Resolves the destination class word and `add_to_class`es the student. |
| `lock-current-offering.ts` | `lockCurrentOffering` | REPORT-80 | Writes `locked: true, active: true` for this student on the launch offering. |
| `open-target-offering.ts` | `openTargetOffering` | REPORT-80 | Control-only: resolves the Blue curriculum by name inside the student's origin class and writes `locked: false, active: true`. No-ops for treatment. |
| `send-email.ts` | `sendEmail` | REPORT-67 | Renders one line per `stepResults` entry and posts it to `send_class_teachers`. |

### What this story therefore is, and is not

It is: three `PIPELINES` entries, the pilot strings that select them, one small handoff tidy-up, the
harness work needed to run a whole fall stage end to end, and a pre-launch checklist against the real
portal classes.

It is not: a new step, a new portal call, a change to the runner's *control flow*, or a per-program
pipeline. Three narrow edits to `index.ts` are in scope and are called out where they arise rather than
smuggled under this sentence: R8a's two log lines and the three new table entries themselves. (The
`export` on `PIPELINES` an earlier draft of R16 also claimed here shipped with REPORT-80 instead.) Both
cohorts run
the *same* three stages. The only program-dependent behaviour anywhere in the flow is inside
`fallRandomAssignment`, which resolves the program itself from the origin class word and uses it to
select three things and nothing else: the strata table, the demographic input set, and the assignment
scope. So `PIPELINES` stays keyed by a single authored string and the dispatcher is untouched.

### The study's shape, as the classes and sequences actually are

Eight registration classes: `ft-2026-bingler`, `-hankamp`, `-long`, `-newlon`, `-torres` (full-time,
one per teacher) and `fl-2026-section1`, `-section2`, `-section3` (flex, by last-name range). Each
splits into `<origin>-gator` (treatment) and `<origin>-shark` (control). All class words are stored
lowercase by the portal.

Three sequences, named as authoring holds them (REPORT-80 read these off
`authoring.concord.org/api/v1/sequences/<id>.json` on 2026-07-30; two carry a trailing space, absorbed
by the trimmed comparison):

| Name | Role | Lives in |
|---|---|---|
| `Green Sequence for AI in Math (FLVS 26-27)` | pre-test | the eight registration classes |
| `Blue Sequence for AI in Math (FLVS 26-27)` | curriculum | the sixteen `-gator` / `-shark` classes |
| `Orange Sequence for AI in Math (FLVS 26-27)` | post-test | the sixteen `-gator` / `-shark` classes |

That layout is what makes the stages self-locating. The Green button launches from a registration
class, so `resolveOriginClass` there yields `ft-2026-bingler` and `classifyFallProgram` can read the
program off its prefix. The Blue and Orange buttons launch from a *subclass*, so `resolveOriginClass`
there yields `ft-2026-bingler-shark` and `armFromClassWord` can read the arm off its suffix. Neither
stage needs the stored randomisation record, which is unaddressable from a later launch anyway.

### The three stages, per the PI

Settled with the PI on 2026-07-29 and unchanged since:

- **Pre-test (Green):** check completion, randomise within the program's table, enrol into the
  `-gator` / `-shark` subclass, lock Green, notify the teacher.
- **Curriculum (Blue):** lock Blue, notify the teacher. It opens **nothing**. *"NO. We are going to
  open the post-test on a specified date"*, because she gates that opening on Blue completion and does
  it by hand. The lock is what records completion (the portal's teacher progress roster renders a
  per-student `locked` checkbox), so the button's job is to record and report. Locking applies to
  **both** arms, not just treatment: the pipelines are keyed by stage rather than by arm, her stated
  reason (don't let them revise answers) applies to control's answers too, and a uniform column on the
  roster beats one where a control student's blank checkbox means "not applicable" rather than "not
  done".
- **Post-test (Orange):** lock Orange, and for control students only, open Blue. Confirmed for both
  programs: *"YES. This is true for the control students in both groups."* Notify the teacher.

### Verification performed while writing this spec

Everything below was checked against code rather than inferred.

1. **The duplicate offering read is real.** A throwaway test ran `resolveOriginClass` then `sendEmail`
   over one `StepContext` with `portalTokenFetch` mocked, and counted two
   `GET /api/v1/offerings/678` calls. The same test confirmed `clazz_id` is present in the *first*
   response alongside `class_word`, so publishing it costs no extra call.
2. **A duplicate pipeline entry name silently drops a result and an email line.** Driving
   `index.ts`'s accumulation loop over a two-entry stage that named both entries alike left one
   `stepResults` key and rendered one email line, the second overwriting the first.
3. **A locked offering's run button is genuinely disabled for the student**, so "the student can just
   click again" is false after a successful lock: `runnables_helper.rb:30-38` resolves the per-student
   `UserOfferingMetadata.locked` over the offering's own flag and sets `href` to `javascript:void(0)`.
   This is what makes the post-test ordering question below a real trade-off rather than a stylistic
   one.
4. **A class-level locked or inactive offering is still returned by the class read**, so the Blue
   target is visible to the by-name match while being unrunnable:
   `Portal::Clazz#teacher_visible_offerings` (`clazz.rb:241`) filters on `runnable.archived?` and
   nothing else. Archival, not locking, is the risk to the open path.
5. **A fall end-to-end harness scenario that reuses the existing harness context would collide with
   the spring `happy` scenario's assignment document.** `perClassScope` hashes
   `interactiveId | platform_id | resource_link_id | context_id`, all four of which the harness holds
   in one shared `CONTEXT`, so the two produce the identical document id (verified: both
   `8f77e38c5fed…`). `getAlternatingAssignment` de-duplicates per student and the harness has one
   student, so whichever scenario ran first would hand its arm to the second, and `run-all.js` runs
   `happy` first. A fall scenario therefore needs its own `resource_link_id` and `context_id`.
6. **The harness's existing demographic answers discriminate the two programs.** They are
   Female / 10th Grade / Module 1 / White. Under full-time (`Gender`, `Race`, teacher `bingler`) the
   stratum's `n1` is **treatment**; under flex (`Female|White|High|Mod1`) it is **control**. So the two
   end-to-end scenarios land in *opposite* arms from identical seeded answers, which is a much stronger
   assertion than either run alone: it can only pass if the resolved program actually selected a
   different table.
7. **The suffix round-trip holds for every study word.** `classifyFallProgram` returns full-time for
   `ft-2026-bingler`, flex for `fl-2026-section1`, and `undefined` for both of the harness's legacy
   words (`fl-spring-2026-origin`, `ft-fall-2026-a`); `armFromClassWord` reads back `treatment` /
   `control` from every derived destination.
8. **Baseline**: `npx jest` on this branch before any change reports **26 suites, 480 passed, 4 skipped
   (484 total)**. Re-measured after rebasing onto master at `a31794c` (the REPORT-80 merge), which added
   the 480th test: R16's duplicate-entry-name assertion. Rounds 1 to 3 recorded 479 against the
   pre-merge branch, and an earlier note than those said 481 across 27, which did not reproduce. The 27th
   suite is `assignment-doc.emulator.test.ts`, which the jest config excludes via its
   `\.emulator\.test\.` ignore pattern and which runs separately under `npm run test:emulator`, so a
   regression check should compare against the 26-suite number unless the emulator run is included
   deliberately.

## Requirements

### The pilot values and the dispatcher

**R1.** `PIPELINES` gains exactly three entries, keyed by an authored pilot string that **encodes the
stage**. `ai4vsFlvs`'s dispatcher (`PIPELINES[request.pilot]`) is unchanged, and no portal call happens
before a pipeline is selected. There is no separate `stage` request parameter, and there is no fall
pipeline keyed by program.

**R2.** The three pilot values are, settled below:

| Stage | Pilot value | Launched from |
|---|---|---|
| Pre-test | `fall-2026-green` | `Green Sequence for AI in Math (FLVS 26-27)`, in a registration class |
| Curriculum | `fall-2026-blue` | `Blue Sequence for AI in Math (FLVS 26-27)`, in a `-gator` / `-shark` class |
| Post-test | `fall-2026-orange` | `Orange Sequence for AI in Math (FLVS 26-27)`, in a `-gator` / `-shark` class |

`index.ts` carries a comment mapping each colour to its role, since the colour is the study's and the
portal's vocabulary but not self-describing to a reader without the study design.

**R2a.** No program-shaped pilot value is permissible: one shared Green button serves both cohorts, so
a value such as `fall-2026-fulltime` would label every flex student as full-time. This is not a
hypothetical: it is the value R3 replaces, in all four places it currently appears.

**R3.** Every occurrence of the stale `fall-2026-fulltime` is replaced with the R2 value for the stage
that occurrence represents. There are **four**, three of them in shipped unit tests rather than in the
harness:

| Location | Kind | Becomes |
|---|---|---|
| `harness/im-done-local/run-step.js:55` | fixture, shared by every run-step scenario | per scenario, see R3a |
| `src/tasks/ai4vs-flvs/enroll-specified-class.test.ts:59` | fixture | `fall-2026-green` |
| `src/tasks/ai4vs-flvs/enroll-specified-class.test.ts:100` | **assertion** on the mint call | `fall-2026-green` |
| `src/tasks/ai4vs-flvs/open-target-offering.test.ts:105` | fixture | `fall-2026-orange` |

All four are inert as behaviour (`pilot` reaches only the mint's audit `description`), so this is a
precedent cleanup rather than a fix. It is worth doing completely because R2a's rule is the kind that is
followed by copying the nearest example: a developer starting a new fall step test today copies
`fall-2026-fulltime` from `enroll-specified-class.test.ts`, which is the one shape R2a forbids. The tree
is currently split, since `resolve-origin-class.test.ts:44,81` and `fall-random-assignment.test.ts:78`
already use `fall-2026-green`.

⚠️ The `enroll-specified-class.test.ts:100` occurrence is an **assertion**, not a fixture: it pins the
value the mint is called with. It changes with line 59 or the test fails.

*(An earlier draft of this requirement, and REPORT-81's spec at
`specs/REPORT-81-pilot-configurable-randomization.md:187` where the claim originated, both said the
harness occurrence was "the only fall pilot string in the tree". A tree-wide grep says otherwise.)*

**R3a.** `run-step.js`'s pilot becomes **per scenario**, because one literal cannot be stage-correct for
all of them. `run-step.js:55` sits inside `buildContext`, which is shared, and the run-step scenarios span
two stages: `enroll-happy` / `enroll-unknown-word` / `enroll-lookup-forbidden` drive
`enrollSpecifiedClass`, a pre-test step, while the four `open-target-*` scenarios drive
`openTargetOffering`, a post-test step. A scenario therefore declares its pilot in `scenarios.js`
alongside the `stepModule` / `stepExport` / `stepName` it already declares, and `buildContext` takes it as
an argument. `OPEN_TARGET_STEP` carries `fall-2026-orange` for all four of its scenarios; the enroll
scenarios default to `fall-2026-green`.

### The three stage arrays

**R4. Pre-test stage.** In order: `evaluateCompletion`, `resolveOriginClass`, `fallRandomAssignment`,
`enrollSpecifiedClass`, `lockCurrentOffering`, `sendEmail`.

Four ordering constraints, each with a reason:
- `evaluateCompletion` is first because it is the gate and it makes no portal call. A student who has
  not finished costs no mint and no portal read, and gets the "please complete N of M" message with a
  real retry available (nothing has been written and they are not yet locked).
- `resolveOriginClass` precedes `fallRandomAssignment`, which reads `originClassWord` from the handoff
  with no ordering guard.
- `enrollSpecifiedClass` follows `fallRandomAssignment`, which publishes `destinationClassWord`.
- `lockCurrentOffering` follows `enrollSpecifiedClass`, so a failed enrolment leaves the student
  unlocked and able to re-click. Reversing them would lock a student out of the activity whose button
  they pressed while their study-class membership had not been written.

**R5. Curriculum stage.** In order: `lockCurrentOffering`, `sendEmail`. It opens nothing. Lock then
email is the standard order, matching the pre-test stage: the lock is the completion record the
researcher reads off the roster, so recording it first has the milder failure. Lock-then-fail-to-email
loses only a courtesy message; email-then-fail-to-lock leaves the roster showing a finished student as
unfinished, which is exactly the state her manual post-test opening is gated on.

**R5a.** Neither the curriculum nor the post-test stage runs `evaluateCompletion`. Settled below: the
step would work unchanged (it already spans a whole sequence, which shares one `resource_link_id`), but
a defensible `min_completed_questions` for Blue and Orange is the PI's to set and there is no time to
ask before launch. Adding the check later is one entry at the front of the stage array plus an authored
threshold; the threshold, not the mechanism, is what is missing.

**R5b.** The consequence, recorded as a research-data limitation rather than a defect, because the
treatment arm's case is sharper than "the roster may be optimistic":

- **Treatment** students run Green, then Blue, then Orange, and **Blue is the intervention**. One who
  opens Blue and immediately clicks "I'm Done" is locked out of the curriculum, appears complete on the
  roster, and is therefore in the set the PI opens the post-test for. They then take the post-test
  having received none of the intervention, and the analysis counts them as treated.
- **Control** students run Green, then Orange, then Blue. An immediate click on Orange records an empty
  post-test and opens Blue early, which is their expected next activity in any case, so the cost is a
  wasted post-test rather than a mislabelled condition.

The compensating control is the PI's own judgement, which she has said she intends to apply
(*"I don't think I will allow students to take the Orange post who haven't taken the WHOLE blue"*): she
inspects answer data and opens the post-test by hand rather than trusting the roster alone. **She has
not been told the button applies no threshold**, which is worth raising with her once launch pressure is
off, alongside the two things O9/O10 already decided without her (a true percentage is not derivable
from the answers collection, and the missing-activity prompt is authored copy rather than a computed
list).

**R6. Post-test stage.** In order: `resolveOriginClass`, `lockCurrentOffering`, `openTargetOffering`,
`sendEmail`. `resolveOriginClass` is required because `openTargetOffering` reads `originClassWord` from
the handoff to classify the arm and to resolve the target's class.

**The lock precedes the open**, settled below against the alternative. The lock is the completion record
the roster shows, and `openTargetOffering`'s likely failures are permanent rather than transient, so
opening first would buy a retry that mostly does not apply while risking the record that does. This
order is also what makes REPORT-80's open-path failure copy true: *"Your work has been saved"* is
guaranteed by control flow only while a failed lock aborts before the open runs. Reordering these two
steps therefore requires REPORT-80's R12 to be revisited in the same change.

**R7.** The story adds **no differential step**. The control-only conditional lives inside
`openTargetOffering`, which classifies the arm from the `-gator` / `-shark` suffix and returns success
with a "nothing to open" summary for treatment students before making any portal call.

**R8.** The runner's **control flow** is not modified. No branching primitive, no `when(context)`
predicate, no optional or continue-on-failure step. Each stage is a flat, ordered, fail-fast array.

**R8a.** Two log lines are added to `ai4vsFlvs`, which is the one exception to R8 and is not a control-flow
change: the selected pilot is logged once before the loop, and the failing step's `name` is logged on the
failure path.

The reason is that this story is what makes a log prefix ambiguous. With one pilot, `lock-current-offering:
Portal returned 403` identified the run. With three stages over the same step modules it does not, and
`index.ts`'s only `ai4vs-flvs:` line in the loop is the **success** line, so a stage that fails at its
first entry emits nothing that names the stage:

| Stage | First entry | What a failure there logs |
|---|---|---|
| Pre-test | `evaluate-completion` | `evaluate-completion: …`, shared with no other stage |
| Curriculum | `lock-curriculum` | `lock-current-offering: …`, shared with **both** other stages |
| Post-test | `resolve-origin-class` | `resolve-origin-class: …`, shared with the pre-test |

Without these two lines, recovering the stage means joining each log line back to its job document through
`jobPath` to read `request.pilot`. That is a manual per-incident step, and the incident to plan for is
three brand-new buttons going live at once. Neither line logs a token or any student PII: the pilot is an
authored string and the step name is ours.

### Entry names

**R9.** Entry `name` values are **unique within each stage array**. `index.ts` keys `stepResults` by
`step.name` and `send-email` renders one line per key, so a collision silently loses both a step result
and a line of the teacher's notification.

Nothing checks this **at run time**, deliberately, under the standing principle that our own pipeline
wiring is assumed correct rather than guarded with defensive code. It is checked **at test time**: the
`it.each` assertion over the exported `PIPELINES` shipped with REPORT-80 and enumerates the table, so the
three fall stages are covered the moment their entries are added, with no edit to that test (R16). This
story's own contribution is therefore only writing the arrays correctly; the backstop already exists.

That matters because the harness cannot substitute for it. A duplicate name does not fail a harness run:
the pipeline completes, the student sees the success message, and the only symptom is a teacher email one
line short. R15's runs prove the stages work, not that they are named correctly.

**R10.** Entry names are treated as labels rather than as handler identities (REPORT-80 settled this
when it kept spring's `lock-activity` label over the renamed `lockCurrentOffering` handler). They are
**teacher-visible**: `send-email` prints `- <entry name>: <summary>` for every step. The fall stages
therefore label by **what was acted on**, not by which handler ran, so a stage that runs
`lockCurrentOffering` and `openTargetOffering` together produces two lines that each say which sequence
they mean:

| Stage | Entry names, in order |
|---|---|
| Pre-test | `evaluate-completion`, `resolve-origin-class`, `random-assignment`, `enroll-class`, `lock-pre-test`, `send-email` |
| Curriculum | `lock-curriculum`, `send-email` |
| Post-test | `resolve-origin-class`, `lock-post-test`, `open-curriculum`, `send-email` |

`lockCurrentOffering` therefore appears under three different entry names across the three stages,
which is exactly the latitude REPORT-80 reserved when it kept spring's `lock-activity`.

**R10a.** Each entry carries a `processingMessage`, which is what the student sees while that step runs.
The pre-test stage reuses spring's wording wherever the step is the same:

| Entry | Processing message |
|---|---|
| `evaluate-completion` | `Checking your answers…` |
| `resolve-origin-class` | `Looking up your class…` |
| `random-assignment` | `Assigning you to a class…` |
| `enroll-class` | `Adding you to your class…` |
| `lock-pre-test` | `Locking your pre-test…` |
| `lock-curriculum` | `Locking this activity…` |
| `lock-post-test` | `Locking your post-test…` |
| `open-curriculum` | `Checking for your other activity…` |
| `send-email` | `Notifying your teacher…` |

`open-curriculum` says **checking** rather than **opening** because roughly half the cohort is treatment
and the step returns immediately for every one of them without making a portal call, so "opening" would
promise something that does not happen. "Checking" is true on both arms, and still shares its noun with
REPORT-80's failure copy for the same step (*"We could not open your other activity"*), so a control
student who sees both sees one consistent phrase. The rejected alternative is a stage-level conditional,
which R8 forbids.

### The `clazzId` handoff tidy-up

**R11.** `resolveOriginClass` additionally publishes the launch offering's `clazz_id` on `StepOutput` as
**`originClazzId`**, a string (`resolveOriginOffering` types it `number | string`, and
`readStepOutputField` reads strings). `sendEmail` consumes it when present instead of issuing its own
`GET /api/v1/offerings/:id`.

`resolveOriginClass` is the sole producer of `originClazzId`, which is the invariant
`readStepOutputField` relies on: it returns the first non-blank value across the run's step outputs, and
the one-producer-per-field rule is what makes that unambiguous. The field carries the doc comment its
siblings carry, stating that producer and that the value is a database id rather than PII or a token, so
it is safe to log.

**R12.** `sendEmail` **retains** its own read as a fallback for when the handoff is absent. The
`spring-2026` pipeline has no `resolveOriginClass` step and must keep working unchanged, and the
curriculum stage (R5) has none either.

Both reads use the same origin (unscoped) teacher token from the same per-run cache and hit the same
endpoint, so this is a saved round trip rather than a behaviour change: verified above, two
`GET /api/v1/offerings/678` calls in one stage today, and the `clazz_id` needed is already in the first
response.

### Authored parameters

**R13.** The parameters each stage's button authors are:

| Stage | Required | Optional | `target_class_word` |
|---|---|---|---|
| Pre-test | `task`, `pilot`, `min_completed_questions` | `min_completed_questions_failure_message`, `email_subject`, `completion_message` | **Must not be authored** (enforced) |
| Curriculum | `task`, `pilot`, `email_subject` | `completion_message` | Inert (no enrol step reads it) |
| Post-test | `task`, `pilot`, `email_subject` | `completion_message` | Inert (no enrol step reads it) |

`min_completed_questions` is required on the pre-test stage: `evaluateCompletion` fails the run if it
is absent or not a positive integer.

`target_class_word` must not be authored on the **pre-test** stage: a button carrying a fixed word *and*
wired to randomisation would route every student to that one class, silently defeating the study.
`enrollSpecifiedClass` already hard-fails on an authored word that differs from the handoff, so this is
a documented authoring rule backed by an existing guard rather than new code.

It is listed for the other two stages only so an author is not left wondering. Neither contains an enrol
step, so the parameter is read by nothing there. It is inert rather than guarded, and no guard is added:
there is no failure to prevent.

**R14.** `email_subject` is **required** on the curriculum and post-test buttons. `send-email`'s
module-level default is the literal `AI4VS: Student completed pre-test`, which is accurate for spring
and for the fall pre-test and wrong for the other two stages. The parameter is legitimately optional in
code, so nothing can detect an omission; it is enforced by R17's pre-launch checklist instead. The
module default is **not** changed, because it is correct where it currently applies.

### Verification

**R15.** Two end-to-end harness scenarios run a whole pre-test stage through the emulator and the stub
portal, one full-time and one flex, and assert the destination class the student was actually enrolled
in rather than only the completion text. With the harness's existing seeded answers these land in
**opposite arms** (full-time → `ft-2026-bingler-gator`, flex → `fl-2026-section1-shark`), which is what
proves the resolved program selected a different strata table.

**R15a.** Each fall scenario carries its **own** `resource_link_id` and `context_id`. Verified above:
reusing the shared harness context puts a full-time run in the same assignment document as the spring
`happy` scenario, where the per-student de-duplication hands it spring's arm and the scenario silently
stops testing what it claims to. This also generalises: a curriculum or post-test scenario launches
from a *different offering* than the pre-test one, so per-scenario launch context is the shape the
harness needs anyway.

⚠️ **That isolation argument is full-time's only.** `pooledProgramScope` takes `program`,
`interactiveId` and `platform_id` and nothing else, so neither `resource_link_id` nor `context_id`
reaches the flex document id: giving the flex scenario its own pair changes which document it writes not
at all. Flex is separated from spring by the pooled key's distinct namespace prefix
(`ai4vs-flvs-assignments-pooled`) and by `FLEX_PROGRAM` being in the hash, which is sufficient today and
was designed to be. The consequence to hold on to is that the flex assignment document is **per program,
not per scenario**: any second flex scenario ever added shares it, and R15f's reset instruction has to say
so.

⚠️ **This is an addition, not an edit.** `config.js`'s shared `CONTEXT` keeps its current values and
fall scenarios carry overrides. Changing `CONTEXT.resource_link_id` would break the four `open-target`
scenarios REPORT-80 just shipped: `stub-portal.js:66` gives the control class an Orange offering whose id
*is* `im-done-offering-1`, so that the by-name match has to *discriminate against* the offering the
student launched from rather than picking the only one available. That is the property
`open-target-happy` exercises, and it is what `stub-portal.js:63-64`'s own comment says the id is for.

⚠️ **It is specifically not there to exercise REPORT-80's R8a self-target guard**, and saying otherwise
(as an earlier draft of this requirement did) forecloses a fixture change R15e wants. The guard at
`open-target-offering.ts:183` compares `String(targetOffering.id)` to `String(resource_link_id)`, and
`targetOffering` is whatever matched the **Blue** target name, which is id `845` in this fixture. The
Orange offering's id is never compared to anything. The guard is reached only by
`open-target-offering.test.ts:215`, which gets there by giving the *target-named* offering the run's own
id, a shape no harness scenario reproduces and none is expected to.

The consequence for R15e: its post-test scenario carries its own `resource_link_id`, and
`studyControlClassInfo`'s **Orange** offering id follows it, so the class contains the offering the
student launched from, as the real study class does. Checked that this does not disturb
`open-target-happy`, which depends on the target's *name* and not on the Orange offering's id.

**R15b.** The harness gains the fixtures the fall stages resolve against: `classes/info` entries for the
words something actually looks up, and an `offerings#show` response that is per scenario.

Which words those are, traced against the callers rather than assumed. `classes/info` is read by exactly
two steps, and the **origin** class is not resolved through it at all (`resolveOriginClass` uses
`offerings#show`):

| Word | Read by | Why |
|---|---|---|
| `ft-2026-bingler-gator` | `enrollSpecifiedClass` | full-time pre-test destination |
| `fl-2026-section1-shark` | `enrollSpecifiedClass` | flex pre-test destination |
| `ft-2026-bingler-shark` | `openTargetOffering` | post-test origin; already present as `STUDY_CONTROL_CLASS` |
| `fl-2026-section1-gator` | `enrollSpecifiedClass` | see below |

The two **registration** words (`ft-2026-bingler`, `fl-2026-section1`) need no `classes/info` entry: no
step looks them up. They are deliberately not added, so the fixture set does not imply the origin is
resolved through this endpoint.

⚠️ **They do need an `offerings#show` identity, and the two fixture sets are therefore not the same
set.** A fall pre-test launches from a registration class, so `resolveOriginClass` reads exactly those
two words through `offerings#show`, and every downstream decision (program, strata table, destination
word) hangs off the class word it publishes. Serving the `offerings#show` identity out of the
`classes/info` fixture map would either force the registration words into that map, undoing the
paragraph above, or leave them unresolvable. The implementation spec keeps them as a separate
identity-only pair, and requires an unresolvable declared origin word to fail loudly: a fallback to
the shared origin class makes the run fail as "unclassifiable origin class word", which reads as a
pipeline fault rather than a missing fixture.

`fl-2026-section1-gator` is there for the flipped arm. The assignment is sticky (R15f), so an edited
`ANSWERS` or an un-reset pooled document can land the flex scenario in treatment, whose destination has no
fixture; that surfaces as a `classes#info` 400 and the generic tell-your-teacher message, with nothing
naming the missing fixture. Full-time's flipped destination is `ft-2026-bingler-shark`, which exists
already, so only the flex arm has this hole.

Per scenario means the **whole class identity**, not just the word. `stub-portal.js:176` currently serves
`clazz_id`, `clazz_hash` and `class_word` all read off the single `ORIGIN_CLASS` fixture (id `90210`, word
`fl-spring-2026-origin`). Making only `class_word` scenario-aware would leave a post-test run reporting
origin class `ft-2026-bingler-shark` while `send-email` posts the teacher notification to class `90210`,
and **the scenario would not catch it**, because R12's fallback reads the same wrong value from the same
stub response, so the handoff and the fallback agree on being wrong. All three fields move together.

This also retires a comment. `config.js:66-68` documents `TREATMENT_CLASS_WORD` (`ft-2026-bingler-gator`)
as deliberately fixture-free, on the grounds that "the arm check short-circuits before any portal call, so
nothing ever looks this word up". True of `openTargetOffering`, and no longer true of the harness: the
full-time pre-test scenario enrols into that word, so `enrollSpecifiedClass` resolves it and it gains the
`classes/info` fixture above. The comment is corrected in the same edit.

**R15c.** `seed.js` seeds each fall scenario's answers under that scenario's `resource_link_id` and
`context_id`, since `evaluateCompletion` and `readDemographics` both filter on them.

**The answer document ids must carry the scenario too**, and today they do not. `seed.js:26` builds
`` `${CONTEXT.source_key}-ans-${answer.key}` ``: four fixed ids, independent of scenario, written with
`.set()`. `run-all.js:3` and the README both say to seed **once**, so one `seed.js` run has to hold every
scenario's answers at the same time. Verified by reproducing the formula over three launch contexts: three
scenarios × four answers yields **4 documents, not 12**, each written three times, last writer wins.

The failure is silent and points at the wrong thing. The two losing scenarios have no answers under their
own `resource_link_id`/`context_id`, so `evaluateCompletion` counts zero and reports "You have completed 0
of 4 required questions" while `readDemographics` reports every question skipped: both read as a pipeline
fault. `seed.js` therefore loops over the scenarios that need answers rather than over one `ANSWERS` set,
and qualifies the document id with the scenario.

**R15d.** `run.js`'s assignment read-back becomes **per-scenario rather than implied by success**. Today
it reads the persisted assignment and compares it to a single `EXPECTED_CLASS` whenever a scenario
expects success (`run.js:100-105`), which is hardcoded to the pre-test shape: a post-test scenario
(R15e) makes no assignment, so `readAssignedClass()` returns `undefined` and the scenario reports FAIL on
a run in which every step succeeded. A scenario therefore declares either the destination class word it
expects or that it makes no assignment, and `run.js` checks accordingly.

**The declared value is the class word, and `run.js` derives it.** Naming this precisely because three
different values are in play and only one of them is stored. The document holds an **arm**
(`strata[key].users[platform_user_id]` is `"treatment"` or `"control"`); `run.js:19,52` maps that arm to a
display **name** (`FL-spring-2026-SHARK`) through `CLASS_BY_ASSIGNMENT` before comparing to
`EXPECTED_CLASS`; and a class **word** is the lowercase portal-stored form. The read-back therefore
composes the scenario's origin word with the arm's `-gator` / `-shark` suffix, which retires
`CLASS_BY_ASSIGNMENT`, a hand-maintained arm-to-name table that exists only to serve this comparison.

⚠️ **This read-back observes the arm and nothing else, and an earlier draft of this requirement
overclaimed it.** That draft said composing the word "makes the read-back exercise the same
`DESTINATION_SUFFIX` round trip the pipeline uses". It does not: both sides of the comparison are
harness values (the scenario's origin word plus the harness's duplicated suffix table, against a
literal in the same file), so the destination word the *pipeline* computed is never seen. What
protects the duplicated constants from drifting is the unit-test pin below, not the harness run. The
consequence is sharpened by this requirement's own fixture decision in R15b: all four subclass words
have a `classes/info` fixture, deliberately, so a pipeline that appended the **wrong suffix** would
resolve a real class, enrol successfully, and pass the scenario. The compensating check is stated in
the implementation spec: the stub records the `add_to_class` body and the scenario asserts the
`clazz_id` the pipeline actually enrolled into, which is the only assertion in a harness run that
observes a destination decision rather than restating one.

**The suffixes are duplicated into `config.js` and pinned by a unit test, not imported from `lib/`.**
Naming the mechanism because the two options are not equivalent and this repo has already chosen between
them. `run.js` requires `fs`, `crypto`, `./config`, `./scenarios` and `firebase-admin`, and nothing from
`lib/`; only `run-step.js` imports compiled code, and it carries an `existsSync` guard
(`run-step.js:84-87`) so a missing build prints "run `npm run build`" instead of a raw `MODULE_NOT_FOUND`.
An import is technically available (`fall-programs.ts`'s two imports are both type-only and elided, so the
compiled module has no runtime `require`), but `config.js:59-64` faced this exact choice for
`TARGET_OFFERING_NAME`, duplicated the literal with a written rationale about not giving a harness file a
build dependency, and pinned the duplicate at `open-target-offering.test.ts:348`. The same pattern applies
here, which keeps `run.js` free of the guard an import would oblige it to carry.

That declaration also carries the scope, which the read-back needs: full-time uses the per-class document
id, flex uses the pooled one. `run.js` holds a second copy of the per-class hash formula today; the pooled
one is a second formula, not a variant of it, and it needs a **second** constant besides the suffixes:
`FLEX_PROGRAM` (`"fall-2026-flex"`), which is hashed into the pooled document id. `fall-programs.ts:14`
warns that this string is data whose rename is a migration, so the harness copy is pinned by the same
test as the suffixes rather than left to drift.

**R15e.** A third end-to-end scenario runs the **post-test stage for a control student**: resolve,
lock, open, email in one pipeline run. It is the only stage where two offering-state steps coexist, so
it is the only place R9's entry-name uniqueness actually bites, and the only end-to-end exercise of the
teacher email rendering a lock line beside an open line. `run-step.js` already covers
`openTargetOffering` in isolation with a hand-built context; this covers it as a stage.

**R15f.** The harness README records that a fall scenario's assigned arm is **sticky** across re-runs,
and names the `sources/<source_key>/jobs-task-data/<docId>` document to delete to start over, **for both
formulas**: the full-time scenario's document is per scenario (the per-class hash over its own
`resource_link_id` and `context_id`), while the flex scenario's is the pooled one, keyed on the program
and shared by every flex scenario, so deleting it resets all of them at once (R15a). The
stickiness is correct (it is what R18 asserts) but from outside it means editing the demographic answers
and re-running yields the *old* arm with nothing on screen explaining why. Deliberately not automated: a
driver that cleared the assignment on every run would destroy the one property R18 exists to
demonstrate.

**R16.** A unit test covers the wiring the harness cannot: that each of the three pilot values selects
the expected ordered handler list. This is the only assertion R16 still adds.

**✅ The duplicate-entry-name half of this requirement, and the `PIPELINES` export it needed, both
shipped in REPORT-80** (commit `9b8600c`, merged as PR #407), where the reviewer raised the same gap
independently. `index.ts:28` now exports the table, carries the uniqueness constraint as a comment above
it, and `index.test.ts:67` asserts it:

```ts
it.each(Object.entries(PIPELINES))("gives every step in %s a distinct name", (_pilot, steps) => {
  const names = steps.map(step => step.name);
  expect(new Set(names).size).toBe(names.length);
});
```

That form is what this requirement asked for and needs **no change** when the fall stages land:
`it.each` enumerates the table, so the three new entries are asserted the moment they are added, and a
fifth pipeline added later is asserted without anyone remembering to. Nothing in this story touches that
test. R9's uniqueness rule is therefore already backed by a check rather than by care alone, which is
what R9 now records.

**Why the export was necessary, kept because it is the reasoning a later reader will want.** `PIPELINES`
was a module-private `const` and `ai4vsFlvs` was `index.ts`'s only export, so the table could not be
enumerated from a test. Both alternatives were checked and rejected. Driving each pipeline and reading
the `stepResults` snapshot **cannot** see a duplicate, for exactly the reason the rule exists: a
duplicate is what collapses, and running the accumulation loop over two entries named alike yields one
key for two steps and one rendered email line instead of two. Reconstructing the name list from
`index.ts`'s per-iteration `step "<name>" completed successfully` log does work, and would also satisfy
the ordered-handler-list assertion, but it can only cover pilot strings the test hardcodes, which turns
"a property of the table" into "a property of four known pilots" and leaves a fifth pipeline silently
unasserted.

**R16a.** `index.test.ts` mocks each step module **by path** and imports `./index` afterwards. It mocks
four modules today, which is every handler `PIPELINES` currently reaches; the fall stages import four
more. All four are mocked, but for the record only **one** of them has to be, and not for the reason it
would be natural to assume. Each was required in isolation under jest with `firebase-functions` mocked as
this file mocks it:

| Newly imported module | Unmocked under jest |
|---|---|
| `resolve-origin-class` | loads OK |
| `open-target-offering` | loads OK |
| `enroll-specified-class` | loads OK |
| `fall-random-assignment` | **throws `ReferenceError: fetch is not defined`** |

The chain is `fall-random-assignment` → `demographics` → `../../firebase-client` → `firebase/auth`, which
is the second of the two jest-hostile chains `assignment-doc.ts`'s own header already names, and it is why
`evaluate-completion` is mocked today. It is **not** `firebase-admin`: `assignment-doc` was checked
directly and loads fine, so the Admin SDK is not what breaks this file. That one module is
**build-breaking rather than additive**, failing the whole suite file rather than one assertion, which is
the same shape REPORT-80 hit when it renamed `lock-activity.ts` out from under this file's mock. The other
three are mocked by convention, to keep every handler in the table stubbed from one place.

**R16b.** The existing `lock-current-offering` mock needs an **edit**, not just company.
`index.test.ts:36-42` writes its snapshot under a hardcoded `stepResultsSnapshots["lock-activity"]`,
which is spring's entry name. R10 gives that same handler three further names (`lock-pre-test`,
`lock-curriculum`, `lock-post-test`), so the key is wrong for three of the four pipelines and, being a
single shared key, silently collides when more than one pipeline is driven in the file. The snapshot key
becomes per-invocation (an appended list, or keyed off the run's current entry name) rather than a
literal.

**R17.** A pre-launch checklist, run **against the real fall classes once they exist and re-run after
any portal-side change to them**, with its result recorded on the ticket. It is this story's task, not
a standing suggestion: it is a checklist rather than code because every item is portal-side state the
pipeline cannot establish for itself, and because each failure is invisible until a student clicks and
then affects a whole arm at once.

📋 **The tickable copy lives in a secret gist**, with a run log:
https://gist.github.com/dougmartin/2b07c5b6794eebbcc0c743e94b06ec41

It is outside the repo deliberately. This spec folder collapses into a single closed summary when the
story closes, while the re-run trigger above outlives the story, so a checklist file inside the folder
would stop existing before its last use. ⚠️ **When REPORT-82 is closed, this checklist must be copied
into the closed spec summary**, so the repo keeps the reasoning and the gist keeps the run log. The
requirement text below stays canonical; the gist is the working copy.

The first two items have the longest detection lag and cannot be caught any other way:

- `TARGET_OFFERING_NAME` matches the Blue offering's name **as the portal serves it**, modulo the trim
  and case folding the match applies. Reading the authoring sequence title settled what authoring
  holds; that the portal copies a runnable's name through unchanged is an inference. Nothing else can
  catch a mismatch: the unit fixtures and the harness stub are both configured *from* the constant, and
  the only run-time signal is a no-match failure that fires solely when a control student finishes the
  post-test, the last event in the study.
- The Blue sequence is present in every `-shark` class and **not archived**. Archived removes it from the
  class read and turns every control student's post-test into a permanent tell-your-teacher.
- **The three sequences carry the right initial class-level state, per arm.** This is a separate item from
  presence, and it is the one whose failure is a research-validity problem rather than an error message:

  | Sequence | `-gator` (treatment) | `-shark` (control) |
  |---|---|---|
  | Blue (curriculum) | open, or treatment cannot receive the intervention | **locked**, until `openTargetOffering` unlocks it per student after the post-test |
  | Orange (post-test) | locked, until the PI opens it by hand on her date | locked, same |

  Blue unlocked in a `-shark` class means control students can take the curriculum before the post-test,
  which puts the intervention into the control arm. Unlike R5b's threshold gap, this one has **no
  compensating control**: the PI's manual check is of Blue completion data, which is exactly what a
  contaminated control student would now have.

  **Owner: the PI**, who manages sequence opening by hand and therefore owns every cell of the table
  above. This item verifies her setup; it does not establish it, and nothing in the pipeline can.

  ⚠️ Her commitment on record covers the **Orange** row only (*"NO. We are going to open the post-test on
  a specified date"*, 2026-07-29). The **Blue / `-shark`** cell is inferred from the same manual practice
  and has never been put to her, so it is the cell to confirm first when this checklist is run, and the
  one to re-confirm after any portal-side change. It is called out rather than assumed because it is the
  only cell whose failure is silent: an unlocked Blue in a `-shark` class produces no error, no log line
  and no failed run, and `openTargetOffering` still reports success when it unlocks something already
  unlocked.

  Class-level state is what governs here, because a newly enrolled student holds no per-student row until
  our pipeline writes one. Verified against `rigse` at `6f4c49288`: `runnables_helper.rb:30-33` reads
  `locked = offering.locked` and overrides from `UserOfferingMetadata` only `if metadata.present?`;
  `clazz.rb:245-259` (`student_visible_offerings`) applies the same fallback to `active`; and
  `offerings_controller.rb`'s `update_student_metadata` uses `find_or_create_by`, so the row exists only
  after a write of ours. The harness already encodes the required state as a fixture (`stub-portal.js:67`
  gives the control class Blue with `locked: true`, commented as "what the open path exists to undo");
  nothing until now checked the real classes against it.
- All eight registration class words and all sixteen subclass words exist and match
  `<origin>-gator` / `<origin>-shark` exactly, lowercase.
- The five full-time surnames in the class words match the strata table's surname keys
  (`bingler`, `hankamp`, `long`, `newlon`, `torres`); an unrecognised surname is a classified failure
  before anything is written.
- `AI4VS-Teacher` is a teacher on every registration class *and* every subclass, which both the
  cross-class mint at enrolment and `send_class_teachers` depend on.
- Each of the three buttons authors the pilot value for its stage (R2, and the value is authored rather
  than derived, so nothing checks it); the pre-test button authors `min_completed_questions`; and the
  curriculum and post-test buttons each author an `email_subject` (R14), without which their
  notifications are subject-lined "Student completed pre-test".
- **The pre-test button does NOT author `target_class_word`** (R13). Unlike the three above, this one
  has a code guard behind it: `enroll-specified-class.ts:44-60` treats an authored word that differs
  from the randomisation handoff as a hard configuration error with its own log line, so a violation
  fails loudly rather than routing the cohort into one class. It is on the checklist anyway because
  the guard fires on a student's click, and this is the only place it can be caught before one. It is
  listed for the pre-test button only: neither of the other two stages contains an enrol step, so the
  parameter is inert there and no guard exists to fire.

### Idempotency

**R18.** Every state-changing step in every stage is safe to re-run, which is already true of each and
is asserted rather than added here:

| Step | Re-run behaviour |
|---|---|
| `evaluateCompletion` | Read-only. |
| `fallRandomAssignment` | A Firestore transaction de-duplicates per student; a student who holds an arm keeps it. |
| `enrollSpecifiedClass` | `add_to_class` is server-side idempotent; an already-enrolled student still returns `success: true`. |
| `lockCurrentOffering` | Writes the same `{locked: true, active: true}` row. |
| `openTargetOffering` | Writes the same `{locked: false, active: true}` row; the treatment no-op makes no call at all. |
| `sendEmail` | **Not** idempotent: a second run sends a second email. Pre-existing on the spring pipeline and accepted; the failure mode is a duplicate notification, not wrong state. |

**R18a.** A note that follows from verification item 3 rather than a requirement: a stage that fails
*after* its lock reports failure to a student who is by then locked out and cannot retry, even though
their completion is already recorded on the roster. That is cosmetic rather than a data problem for the
pre-test and curriculum stages. It is the substance of the post-test ordering question below.

**R18b.** One consequence of R18a is a message that is actively false, and it is **recorded rather than
fixed**. `sendEmail` runs last in all three stages and its student-facing string is *"Unable to send
notification email. Please try again or contact your teacher."* By the time a student can see it they
have been locked out of the activity whose button they pressed, so "please try again" cannot be acted
on. REPORT-80 reworded both offering-state messages for precisely this reason and did not reach
`sendEmail`.

Not fixed here because the string is live on `spring-2026`, where it has the same defect, so rewording
it is a change to a running pilot's copy made mid-study for a message that appears only when the
notification fails after everything else has succeeded. In every case where it is reachable the
completion is already on the roster, so a student who follows the advice loses nothing. This is the
obvious follow-up the next time `sendEmail` is opened for any other reason.

## Technical Notes

### The dispatcher needs no change, and why that is load-bearing

Runtime program resolution was once expected to force a portal round trip before a pipeline could be
chosen. It does not, because the resolved program never selects a pipeline. `ai4vsFlvs` can keep
validating `pilot`, looking up `PIPELINES[request.pilot]`, and running `validatePortalHost` before any
step, which keeps the token-exfiltration gate ahead of everything, including the first mint.

### What a fall stage costs in portal calls

Per run, with the R11 tidy-up applied, and noting that `getScopedPortalToken` caches per run so an
unscoped teacher token is minted once:

- **Pre-test**: 1 unscoped mint, 1 `GET offerings/:id` (origin class word + clazz id), 1
  `GET classes/info` (destination), 1 scoped mint (destination class), 1 `POST add_to_class`, 1
  `PUT update_student_metadata`, 1 `POST send_class_teachers`.
- **Curriculum**: 1 unscoped mint, 1 `PUT update_student_metadata`, 1 `GET offerings/:id`
  (send-email's fallback), 1 `POST send_class_teachers`.
- **Post-test, treatment**: 1 unscoped mint, 1 `GET offerings/:id`, 1 `PUT`, no call at all for the
  open step, 1 `POST send_class_teachers`.
- **Post-test, control**: as above plus 1 `GET classes/info` and a second `PUT`.

The arm check inside `openTargetOffering` runs before its mint and its class read, which is why roughly
half the cohort pays nothing for it.

### What the teacher notification discloses, and why that is already the case

Adding `resolveOriginClass` to the post-test stage (R6) puts `- resolve-origin-class: Origin class
ft-2026-bingler-shark` into the notification email, and the suffix is the student's study arm. This is
not new disclosure. REPORT-80 already ships two lines carrying the same fact from the same email,
`Opened Blue Sequence for AI in Math (FLVS 26-27)` on control and `No activity to open for this student`
on treatment, both deliberately. The recipient is `send_class_teachers` on the offering's own class,
which at this stage is the `-gator` or `-shark` subclass, so every recipient is a teacher of a
single-arm class and is unblinded by the class membership itself. No student PII is added: the new line
carries a class word, which is authored, environment-stable, and neither PII nor a token.

### Why the assignment record is not consulted at the post-test stage

`computeAssignmentDocId` hashes `interactiveId | platform_id | resource_link_id | context_id`. The
pre-test launch (Green offering, registration class) and the post-test launch (Orange offering,
subclass) differ on both `resource_link_id` and `context_id`, so the stored assignment is not
addressable from the later job. The arm is instead read from the class word the student launched from,
which is only possible because Blue and Orange live exclusively in the subclasses.

### The `-gator` / `-shark` suffixes are one source of truth

`DESTINATION_SUFFIX` lives in `fall-programs.ts` and serves both directions: `fallRandomAssignment`
appends a suffix to build the destination word, `armFromClassWord` reads one back. A divergence would
classify a `-shark` student as treatment and silently withhold the curriculum they are entitled to. A
shipped test asserts the round trip; verification item 7 re-confirmed it against every study word.

### Files this story touches

- `functions/src/tasks/ai4vs-flvs/index.ts`: three `PIPELINES` entries and their imports, and R8a's two
  log lines. The `export` on `PIPELINES` is already there (REPORT-80).
- `functions/src/tasks/ai4vs-flvs/index.test.ts`: R16's ordered-handler-list assertion, R16a's four new
  module mocks
  (of which the `fall-random-assignment` one is **build-breaking rather than additive**, since unmocked it
  throws `fetch is not defined` through `demographics` → `firebase-client`), and R16b's edit to the
  existing lock mock's hardcoded snapshot key.
- `functions/src/tasks/ai4vs-flvs/types.ts`: the `StepOutput` field R11 adds.
- `functions/src/tasks/ai4vs-flvs/resolve-origin-class.ts` (+ test): publish the clazz id.
- `functions/src/tasks/ai4vs-flvs/send-email.ts` (+ test): consume the handoff, keep the fallback.
- `functions/src/tasks/ai4vs-flvs/enroll-specified-class.test.ts`: R3's stale pilot value, at a fixture
  (`:59`) **and at an assertion** (`:100`).
- `functions/src/tasks/ai4vs-flvs/open-target-offering.test.ts`: R3's stale pilot value at a fixture
  (`:105`), plus R15d's pin on the harness's duplicated suffixes and `FLEX_PROGRAM`, beside the
  `TARGET_OFFERING_NAME` pin already at `:348`.
- `functions/harness/im-done-local/config.js`: fall class fixtures, per-scenario launch contexts, and the
  `DESTINATION_SUFFIX` / `FLEX_PROGRAM` duplicates R15d pins.
- `functions/harness/im-done-local/scenarios.js`: the three end-to-end fall scenarios, and R3a's
  per-scenario pilot for the run-step scenarios.
- `functions/harness/im-done-local/run-step.js`: R3's stale pilot value at `:55`, replaced by R3a's
  per-scenario one threaded through `buildContext`.
- `functions/harness/im-done-local/stub-portal.js`: a per-scenario `offerings#show` class identity, and
  the control class's Orange offering id following the post-test scenario (R15a).
- `functions/harness/im-done-local/seed.js`: per-scenario answer seeding, including per-scenario answer
  document ids (R15c).
- `functions/harness/im-done-local/run.js`: per-scenario request and expectations, the pooled
  assignment-document formula, and the retirement of `CLASS_BY_ASSIGNMENT`.
- `functions/harness/im-done-local/README.md`: the fall stages now run end to end, not only as
  direct-step scenarios.

## Out of Scope

- **Any per-program pipeline.** Both cohorts run the same three stages.
- **Any change to the pipeline runner**, including branching, conditional steps, or continue-on-failure.
- **A differential step.** REPORT-80's `openTargetOffering` owns the control-only conditional.
- **Scheduled opening.** The researcher opens the post-test by hand on fixed dates, gated on Blue
  completion, and has said she wants to keep that judgement. No scheduler is built anywhere in this
  epic. (Trudi's comment on this ticket asks whether the script sets that date; the answer is no, and
  she has already said she will do it by hand.)
- **Percentage-based or activity-naming completion feedback.** `min_completed_questions` is an absolute
  count and its failure message is an authored string; the answers collection has no total-questions
  denominator.
- **Authoring / question-interactives changes.** The button stays a thin dispatcher over an opaque
  `task` plus free-form `taskParams`.
- **Any change to the `spring-2026` pipeline's behaviour.** It is live; R12 exists to keep it that way.
- **Closing the cross-class-move hole in full-time's per-class assignment scope.** A student moved
  between two full-time classes who re-completes the pre-test can be assigned afresh from the new
  teacher's counters and land in the opposite arm. Recorded on REPORT-81, needs a program-wide
  student-to-arm index, and remains an operational item.

## Open Questions

### RESOLVED: What are the three pilot values called?

**Context**: The dispatcher stays unchanged only if the pilot string itself encodes the stage (R1). The
name reaches three places: whoever authors the buttons types it into `taskParams`, it is interpolated
into the portal mint's audit `description` (`${pilot}:origin`), and it appears in our logs. The study is
discussed with the PI exclusively in colours, and the portal's own sequences are named
`Green/Blue/Orange Sequence for AI in Math (FLVS 26-27)`, so the author configuring the Blue button is
looking at the word "Blue" while they do it. Against that, "Blue means curriculum" is not guessable by
anyone who has not read the study design, and this ticket's own title uses the roles.

**Options considered**:
- A) `fall-2026-green`, `fall-2026-blue`, `fall-2026-orange` — the study's and the portal's vocabulary.
- B) `fall-2026-pre-test`, `fall-2026-curriculum`, `fall-2026-post-test` — self-describing to a reader
  with no study context.
- C) `fall-2026-green-pre-test` and friends — both, at the cost of length.

**Decision**: **A** (Doug, 2026-07-30). `fall-2026-green`, `fall-2026-blue`, `fall-2026-orange`. The
authoring surface and every conversation with the PI are in colours, and a second vocabulary would have
to be translated at each of them; B's readability is bought back for one comment line in `index.ts`,
which R2 requires. C was declined as length for no additional information.

Two things this settles beyond the strings themselves: the value is authored per button rather than
derived, so R17's pre-launch checklist has to confirm each button carries the right one; and
`resolve-origin-class.test.ts` already uses `fall-2026-green` as a fixture value, which now stops being
an unowned guess and becomes the real name.

---

### RESOLVED: How are the pipeline entries named, given that the teacher sees them?

**Context**: `send-email` renders `- <entry name>: <summary>` for every step, so entry names are copy in
the researcher's notification, not just internal identifiers. REPORT-80 established that an entry name
is a label rather than a handler identity when it kept spring's `lock-activity` over the renamed
`lockCurrentOffering`. `lockCurrentOffering` returns no summary, so its line renders as
`- <entry name>: completed` and the name is the entire content of that line. Uniqueness within a stage
is required either way (R9).

**Options considered**:
- A) Per-stage labels: `lock-pre-test`, `lock-curriculum`, `lock-post-test`, `open-curriculum`. The
  email says which activity was locked.
- B) Uniform handler-shaped labels: `lock-current` and `open-target` in every stage. One name per
  handler across the codebase, at the cost of an email line that does not say what was locked.
- C) A's labels plus a `summary` added to `lockCurrentOffering`, so the line carries the offering as
  well. Touches a REPORT-80 file and needs the offering's name, which that step deliberately does not
  read.

**Decision**: **A**, per-stage labels. It is free, it is the only one of the three that makes the
teacher email say what happened, and it is exactly the latitude REPORT-80 reserved when it kept
spring's `lock-activity` over the renamed handler. C buys little for a portal read the step
deliberately does not make. Written up as R10, with the full name table, and R10a's processing
messages settled alongside it since they are the same kind of copy.

---

### RESOLVED: At the post-test stage, does the lock run before the open, or after?

**Context**: Raised by REPORT-80 and deliberately left here. The runner is fail-fast, so whichever step
fails aborts the stage and suppresses the teacher email either way. Verified above: after a successful
lock the student's run button is genuinely disabled (`runnables_helper.rb:30-38`), so "they can click
again" is false once the lock lands.

Under **lock then open**, a failed open leaves a control student locked out of the post-test with their
completion recorded on the roster, unable to retry, told to see their teacher, and their teacher not
emailed. The failure message REPORT-80 ships, *"Your work has been saved. We could not open your other
activity, so please tell your teacher"*, is guaranteed true by control flow: a failed lock aborts before
the open runs, so whenever that message appears the completion really is recorded.

Under **open then lock**, a failed open leaves the student unlocked with nothing recorded. A retry is
real, which the message denies; and the completion the researcher reads off the roster is missing, which
is the state her manual opening is gated on.

What tips it is which failures are actually retryable. `openTargetOffering` has five failure branches
and three of them are permanent until someone edits code or portal state: no offering matched the target
name, more than one matched, and the target resolved to the run's own offering. All three return
tell-your-teacher. Only a failed mint and a rejected write are transient. So open-first buys
retryability that does not apply to the most likely failure, and pays for it with the completion record.

**Options considered**:
- A) Keep `lock` then `open`, as REPORT-80 assumed. Record R18a's residual and move on.
- B) Reorder to `open` then `lock`, and revisit REPORT-80's R12 message, whose reassurance clause stops
  being guaranteed.
- C) Reorder *and* soften the message to something true under either order.

**Decision**: **A** (Doug, 2026-07-30). Keep `lock` then `open`. The dominant open-path failures are
permanent, so the retry B and C buy is mostly theoretical, while the completion record they risk is what
the researcher actually reads. A also leaves REPORT-80's shipped copy true as written, so nothing in
REPORT-80 is reopened.

**Consequences recorded rather than fixed**, so a later reader does not re-litigate this from the
symptom:
- R18a's residual applies here in its sharpest form: a control student whose open fails is locked out
  with their completion recorded, cannot retry, and their teacher is not emailed (fail-fast aborts
  before `send-email`). The recovery is the researcher opening Blue by hand, which she is doing on a
  schedule anyway.
- REPORT-80's R12 open-path message and its "guaranteed by control flow" rationale stand unmodified.
- This is now a **dependency of the order**, not a free choice: if a future change reorders these two
  steps, REPORT-80's R12 must be revisited in the same edit, because its reassurance clause stops being
  guaranteed the moment the lock no longer precedes the open.

---

### RESOLVED: Does the curriculum stage check completion before locking?

**Context**: The Jira lists `evaluate-completion` only in the pre-test stage, so R5 as written locks Blue
on any click. But the PI's whole reason for the curriculum button is gating: *"it is important for me to
know who completed the Blue and who didn't. Because I will not unlock the Orange (on the specific date)
for those who have not"*. Without a check, a student who opens Blue and immediately presses "I'm Done"
is locked out of the curriculum and recorded on the roster as having completed it, which is the exact
record she filters on. The step is reusable as-is: it counts completed answers within the launch's
`resource_link_id`, and a sequence shares one, so it already spans the whole Blue sequence. The cost is
that it needs a defensible `min_completed_questions` for Blue, which someone has to choose, and a wrong
value either lets students through or strands them.

**Options considered**:
- A) Add `evaluateCompletion` first in the curriculum stage, with `min_completed_questions` authored on
  the Blue button like the Green one.
- B) Leave the curriculum stage as lock-then-email, per the Jira. The lock records "pressed the button",
  and the researcher applies her own judgement from the reports.
- C) Ask the PI whether a Blue completion threshold exists and what it is, before deciding.

**Decision**: **B** (Doug, 2026-07-30). No completion check on the curriculum or post-test stages. C was
the recommendation but it is the only option that leaves the story blocked on an answer from the PI, and
there is no time for that round trip before launch. The same reasoning applies to the post-test stage,
which is likewise lock-and-report with no gate.

**This is explicitly revisable, and cheaply.** Adding the check later is one entry at the front of the
stage array plus a `min_completed_questions` value on the button; no step changes, no new capability,
and the pre-test stage already proves the wiring. The threshold, not the mechanism, is what is missing.

**The residual, stated plainly because it is a research-data limitation rather than a UX one:** on the
curriculum and post-test stages the lock records that the student *pressed the button*, not that they
did the work. A student who opens Blue and immediately clicks "I'm Done" is locked out of it and appears
on the teacher progress roster as complete, which is the record the PI filters on when she opens Orange
by hand. She retains her own judgement over that filter and can inspect the reports, which is the
compensating control; she has not been told the button applies no threshold. Worth raising with her when
the launch pressure is off, alongside the two things O9/O10 already decided without her (a true
percentage is not derivable, and the missing-activity pop-up is authored copy rather than a computed
list).

---

### RESOLVED: What subject line do the curriculum and post-test emails carry?

**Context**: `send-email`'s default subject is the literal `AI4VS: Student completed pre-test`, correct
for spring and for the fall pre-test and wrong for the other two stages. `email_subject` is an authored
override, so a correctly authored button has no problem; the failure mode is a Blue or Orange button
authored without one, which quietly mislabels every notification from that stage. Nothing in the code
can detect it, because the parameter is legitimately optional.

**Options considered**:
- A) Require `email_subject` on the curriculum and post-test buttons, and add it to R17's pre-launch
  checklist. No code change.
- B) Give the pipeline entry an optional default subject that `sendEmail` falls back to before the
  module-level default, so each stage carries its own correct wording with no authoring dependency.
  A small addition to the `PipelineStep` shape.
- C) Change the module default to something stage-neutral, e.g. `AI4VS: Student completed an activity`.
  Touches spring's live behaviour, where the current subject is accurate.

**Decision**: **A**, require it and check it. R17 already exists and this is one more line in it,
whereas B adds a second subject-resolution path to a live step for a value that has to be written by
hand either way. C is rejected outright: it would degrade spring's accurate subject to serve fall
buttons that are mis-authored. Written up as R14, with the required-parameter change in R13's table and
the check in R17. Revisit B if a fall stage is ever added without a button-authoring step.

---

### RESOLVED: Do the curriculum and post-test stages get end-to-end harness scenarios too?

**Context**: R15 inherits two scenarios from REPORT-81, both pre-test. REPORT-80 covers
`openTargetOffering` through `run-step.js`, which drives one compiled step directly against the stub
with a hand-built context. Nothing then exercises the post-test stage as a *stage*: the accumulation of
`stepResults` across four entries, the entry-name uniqueness R9 requires, and the teacher email's
rendering of a lock line beside an open line are all only asserted by unit tests. Once R15a gives each
scenario its own launch context, adding a third and fourth scenario is mostly fixture work.

**Options considered**:
- A) The two inherited pre-test scenarios only. Smallest scope; matches the Jira.
- B) Add a post-test control scenario (resolve, lock, open, email in one run). It is the only stage
  where two offering-state steps coexist, which is where R9 actually bites.
- C) All four stages-by-arm: pre-test full-time, pre-test flex, post-test control, post-test treatment,
  plus curriculum.

**Decision**: **B**, add a post-test control scenario (R15e). The post-test stage is the only one whose
wiring can fail *silently*: a duplicate entry name there drops a line of the researcher's email rather
than throwing, so no other test would notice. Once R15a gives each scenario its own launch context, the
marginal cost is fixture work. C is declined: a treatment post-test run and a curriculum run each add a
scenario whose only untested content is a step already covered in isolation.

---

### RESOLVED: Is the `clazzId` tidy-up (R11, R12) in scope for this story?

**Context**: It was assigned here by REPORT-81 and re-confirmed by REPORT-80, on the reasoning that it
touches `send-email`, a step neither of them otherwise modified, and that the stage wiring is where step
order is being decided anyway. It saves exactly one `GET /api/v1/offerings/:id` per run on the pre-test
and post-test stages, verified above. It is not a correctness fix: both reads use the same cached token
and the same endpoint. Against doing it: `send-email` is live on spring, and R12's fallback exists
solely so it stays that way, which is a branch that will be exercised only by spring for the life of the
study.

**Options considered**:
- A) Do it, with the R12 fallback.
- B) Defer it. Record it as a known duplicate read and leave `send-email` untouched.

**Decision**: **A**, do it with the R12 fallback. Two prior stories assigned it here for the same
reason, that the stage wiring is where step order is being decided anyway, and deferring it a third
time means a second round of review on `send-email` for fifteen lines. Recorded plainly: this is the
one requirement in the story that could be dropped with no consequence beyond a redundant portal read,
so if implementation scope tightens, drop this rather than R15's harness work.

## Self-Review (Round 1)

Seven lenses, nine findings. Each was checked against code before being written down; where a finding
turned out to be a property the design already had, it is recorded as verified rather than dropped, so a
later reader can tell it was considered.

### Senior Engineer

#### RESOLVED: Adding fall steps to `index.ts` breaks `index.test.ts`, and not cosmetically

`index.test.ts` mocks each step module by path and imports `./index` afterwards. It currently mocks four
modules, which is every handler `PIPELINES` reaches. The fall stages import four more, and one of them,
`fall-random-assignment.ts`, transitively imports `assignment-doc.ts`, which imports `firebase-admin` at
module scope. An unmocked import therefore drags the Admin SDK into the orchestrator's test file, which
is the same failure shape REPORT-80 hit when it renamed `lock-activity.ts` out from under this file's
mock: it fails the whole suite file rather than one assertion.

**Resolution**: recorded as **R16a**, and `index.test.ts` moved into "Files this story touches" as
build-breaking rather than additive.

---

#### RESOLVED: The new `StepOutput` field is required but never named, and its producer is not pinned

R11 says `resolveOriginClass` publishes the clazz id "as a string" without naming the field. The field
name is the contract two steps agree on, and `StepOutput`'s header documents an invariant of exactly one
producer per field, which a spec that leaves the name open cannot state.

**Resolution**: **R11** now names the field `originClazzId`, states the one-producer invariant for
it,
and requires the doc comment that carries that invariant for the sibling fields.

---

#### RESOLVED: After the lock, `send-email`'s failure message tells the student to do something they cannot

`send-email`'s student-facing string is *"Unable to send notification email. Please try again or contact
your teacher."* It runs last in all three stages, so by the time a student can see it they have been
locked out of the activity whose button they pressed (verified: `runnables_helper.rb:30-38` disables the
run button off the per-student `locked` row). "Please try again" is therefore false wherever it appears
in a fall stage. REPORT-80 reworded both offering-state messages for exactly this reason and did not
reach `send-email`.

**Resolution**: recorded as a residual on **R18a** rather than fixed. The string is shipped and live
on
`spring-2026`, where it has the same defect, so rewording it is a change to a running pilot's copy made
mid-study for a message that only appears when the notification fails after everything else succeeded.
The completion is recorded on the roster in every case where this string is reachable, so the student
following the advice loses nothing. Flagged as the obvious follow-up if `send-email` is touched again.

---

### QA Engineer

#### RESOLVED: R15a's per-scenario launch context must be additive, or it breaks REPORT-80's shipped scenarios

R15a requires each fall scenario to carry its own `resource_link_id` and `context_id`. Read as an edit to
`config.js`'s shared `CONTEXT`, it would break the four `open-target` scenarios REPORT-80 just shipped:
`stub-portal.js` gives the control class an Orange offering with id `im-done-offering-1`, which is
`CONTEXT.resource_link_id`, precisely so that REPORT-80's R8a self-target guard is exercised against a
realistic pair.

**Resolution**: **R15a** now says the shared `CONTEXT` is unchanged and fall scenarios carry
*overrides*,
and names the stub fixture that depends on the current value.

---

#### RESOLVED: A fall scenario's assigned arm is sticky across harness re-runs, which will read as a bug

`getAlternatingAssignment` de-duplicates per student, and the harness has one student per scenario, so
re-running a fall scenario returns the arm from the first run. That is the correct behaviour and is what
R18 asserts, but from the outside it means editing `config.js`'s demographic answers and re-running
produces the *old* arm, with nothing on screen explaining why.

**Resolution**: **R15f** requires the harness README to say so and to name the document to delete to
start over. Deliberately not automated: a driver that cleared the assignment on every run would destroy
the one property R18 exists to demonstrate.

---

### Education Researcher

#### RESOLVED: Without a completion gate, the treatment arm's intervention-received flag is a button press

R5a records that on the curriculum and post-test stages the lock means "pressed the button" rather than
"did the work". The write-up understated what that costs on the treatment arm specifically. Treatment
students run Green then Blue then Orange, and Blue *is* the intervention. A treatment student who opens
Blue and immediately clicks "I'm Done" is locked out of the curriculum, appears complete on the roster,
and is therefore in the set the PI opens the post-test for. They then take the post-test having received
none of the intervention, and the analysis counts them as treated. Control's equivalent is milder: an
immediate click on Orange records an empty post-test and opens Blue early, which is their expected next
activity anyway.

**Resolution**: **R5a** now states the treatment case explicitly, names the compensating control
(the PI
inspects answer data and said she would check *"the WHOLE blue"*, and she opens Orange by hand), and
records that she has not been told the button applies no threshold. The decision itself is unchanged:
the threshold is hers to set and there is no time to ask before launch.

---

### Student

#### RESOLVED: Treatment students are shown a processing message for a step that does nothing

R10a set `open-curriculum`'s processing message to *"Opening your other activity…"*. Roughly half the
cohort is treatment, and for every one of them the step returns immediately having made no portal call,
so the message promises something that will not happen. It is also the last thing many of them see
before the completion message, since `send-email` follows.

**Resolution**: **R10a** changes it to *"Checking for your other activity…"*, which is true on both
arms
and still consistent with REPORT-80's failure copy for the same step (*"We could not open your other
activity"*). Rejected alternative: a stage-level conditional, which R8 forbids.

---

### Release and Build Engineer

#### RESOLVED: The pre-launch checklist has no owner and no time relative to launch

R17 is the only defence against four failure modes that are invisible until a student clicks and then
take out a whole arm at once. As written it says the checklist "is executed before the study opens",
which is not a commitment anyone holds.

**Resolution**: **R17** now names the checklist as a pre-launch task on this story, to be run
against the
real classes once they exist and re-run after any portal-side change to them, with its result recorded on
the ticket. The two items with the longest detection lag (the Blue offering's name, and Blue not being
archived in the `-shark` classes) are marked as the ones that cannot be caught any other way.

---

### Security and Privacy Engineer

#### RESOLVED (verified, no change): The post-test notification email discloses the student's study arm

Adding `resolveOriginClass` to the post-test stage (R6) puts `- resolve-origin-class: Origin class
ft-2026-bingler-shark` into the teacher notification, and the suffix is the arm. Checked whether this is
new: it is not. REPORT-80 already ships two lines that disclose the same thing from the same email,
`Opened Blue Sequence for AI in Math (FLVS 26-27)` for control and `No activity to open for this student`
for treatment, and both were deliberate. The recipient is `send_class_teachers` on the offering's own
class, which at this stage is the `-gator` or `-shark` subclass, so every recipient is already a teacher
of a single-arm class and is unblinded by the class membership itself. No student PII is added: the new
line carries a class word, which is authored, environment-stable, and neither PII nor a token.

**Resolution**: no change. Recorded so the next reviewer does not re-raise it.

---

### Portal API reviewer

#### RESOLVED (verified, no change): The per-stage pilot values change the mint's audit description

`mintScopedPortalToken` builds `description` as `${pilot}:origin` or `${pilot}:class-${classId}`, so the
three stages now produce three distinct audit strings (`fall-2026-green:origin` and so on) where a single
`fall-2026` value would have produced one. Checked that nothing keys on the description: it is written to
the portal's audit trail and never parsed. The effect is an improvement, since a portal-side audit can
now tell which trigger point a mint came from.

**Resolution**: no change. Noted in R2 as a property worth keeping if the pilot values are ever
revisited.

## Self-Review (Round 2)

Re-run against the requirements as amended by Round 1. Two findings, one of them a concrete gap in the
harness work R15e adds.

### QA Engineer

#### RESOLVED: `run.js` asserts an assignment on every successful run, so R15e's post-test scenario fails by construction

`run.js:100-105` reads the persisted assignment back and compares it to `EXPECTED_CLASS` whenever a
scenario expects success. The post-test stage performs **no** randomisation and writes no assignment
document, so `readAssignedClass()` returns `undefined`, the comparison fails, and R15e's scenario reports
FAIL on a run in which every step succeeded. Round 1 added R15e without noticing that the driver's
success path is hardcoded to the pre-test shape.

**Resolution**: **R15d** now covers it. The assignment read-back is per-scenario rather than implied
by
success: a scenario declares the destination class word it expects, or declares that it makes no
assignment, and `run.js` checks accordingly. This subsumes the pooled-versus-per-class formula split
R15d already required, since the scenario has to say which scope it used in order to be read back at all.

---

### Spec Editor

#### RESOLVED: "Must not be authored" claims a consequence that only exists on one stage

R13's table lists `target_class_word` under "must not be authored" for all three stages. The rule is real
and load-bearing on the pre-test stage, where `enrollSpecifiedClass` hard-fails on an authored word that
differs from the randomisation handoff, which is what stops one authored word routing the whole study
into a single class. Neither of the other two stages contains an enrol step, so an authored
`target_class_word` there is inert: it is read by nothing. Listing it identically across all three
implies a guard that does not exist and invites a reader to go looking for it.

**Resolution**: **R13**'s table now distinguishes the pre-test rule (enforced, with the guard named)
from
the other two stages (inert, listed so an author is not left wondering).

## Self-Review (Round 3)

Eight lenses. Every finding below was checked by running code (throwaway jest files, since deleted) or
by reading the exact line, before it was written down. Two candidate findings were killed by that check
and are recorded at the end so they are not raised again.

### Senior Engineer

#### RESOLVED: R16a names the wrong import chain, and overstates how many steps break the test file

R16a says `fall-random-assignment.ts` "transitively imports `assignment-doc.ts`, which imports
`firebase-admin` at module scope", and concludes that "every newly imported step therefore needs a mock,
or the Admin SDK is dragged into the orchestrator's test file".

Both halves are wrong. Each of the four newly imported modules was required in isolation, in its own
jest file, with `firebase-functions` mocked exactly as `index.test.ts` mocks it:

| Module | Result |
|---|---|
| `./assignment-doc` | **loaded OK** |
| `./resolve-origin-class` | loaded OK |
| `./open-target-offering` | loaded OK |
| `./enroll-specified-class` | loaded OK |
| `./fall-random-assignment` | **THREW: `fetch is not defined`** |
| `./demographics` | THREW: `fetch is not defined` |
| `./evaluate-completion` | THREW: `fetch is not defined` |

So `firebase-admin` is not the problem: `assignment-doc` loads fine. The breaking chain is
`fall-random-assignment` -> `./demographics` -> `../../firebase-client` -> `firebase/auth`, which throws
`ReferenceError: fetch is not defined` under jest 24. That is the second of the two chains
`assignment-doc.ts`'s own header already names, and it is also why `evaluate-completion` is mocked today.

Consequences for the requirement: exactly **one** of the four new imports is build-breaking, not four;
the fix a developer should reach for is a mock of `fall-random-assignment` (or of `demographics`), not
anything to do with the Admin SDK; and a developer who follows R16a as written goes looking for a
firebase-admin failure that does not exist.

(An earlier version of this check ran all seven requires in one file and reported `fall-random-assignment`
as loading OK. That was jest's module registry returning the partially-populated exports of a module that
had already thrown. The per-file runs above are the accurate ones.)

**Resolution**: **R16a** rewritten. It now carries the per-module table above, names the
`demographics` → `firebase-client` → `firebase/auth` chain and the `fetch is not defined` symptom, states
that `assignment-doc` loads fine so the Admin SDK is not the cause, and keeps the other three mocks as a
convention rather than a necessity. The `index.test.ts` bullet in "Files this story touches" was corrected
to match.

---

### QA Engineer

#### RESOLVED: R16's duplicate-name assertion cannot be written against `index.ts` as it stands

R16 requires a unit test asserting "that no stage array contains a duplicate entry name (asserted across
every entry in `PIPELINES`, including `spring-2026`, since the rule is a property of the table rather
than of the fall stages)".

Verified: `index.ts` exports `ai4vsFlvs` and nothing else (`Object.keys(require("./index"))` returns
`["ai4vsFlvs"]`). `PIPELINES` is a module-private `const` at `index.ts:17`. A test therefore cannot
enumerate the table, so "across every entry in `PIPELINES`" is not expressible: the best a test can do is
hardcode the four pilot strings, which means a fifth pipeline added later is silently unasserted, and that
is exactly the property-of-the-table guarantee R16 is asking for.

Verified separately that the obvious workaround does not work either. Driving `ai4vsFlvs` and reading the
`stepResults` snapshot cannot see a duplicate, because a duplicate is precisely what collapses: running
`index.ts:81`'s accumulation loop over two entries named alike yields **1** key for 2 steps, the second
overwriting the first, and `send-email` renders **1** line instead of 2.

There is one indirect signal that does work: `index.ts:82` logs `ai4vs-flvs: step "<name>" completed
successfully` once per loop iteration, so a duplicate emits the name twice. A test driving each pilot with
every step mocked to succeed can reconstruct the ordered name list from `logger.info` and check it for
duplicates. That also satisfies R16's first assertion (the ordered handler list). But it only covers
pipelines the test explicitly drives, and it needs every step to succeed.

**Resolution**: **R16** now requires `PIPELINES` to be exported, and records why the two
alternatives were
rejected (the `stepResults` route cannot see a duplicate at all; the `logger.info` route works but only
over hardcoded pilot strings, which weakens the guarantee below what the requirement claims). The export is
named in "Files this story touches".

**Superseded 2026-07-30, in this story's favour.** PR #407's reviewer reached the same conclusion
independently on REPORT-80, so the export and the `it.each` duplicate-name assertion both shipped there
(`9b8600c`). R16 was rewritten to record that, and now adds only the ordered-handler-list assertion. The
finding above stands as the reasoning for why the export was the right mechanism; it is simply no longer
this story's work.

---

#### RESOLVED: R16a misses that the existing `lock-current-offering` mock hardcodes spring's entry name

`index.test.ts:36-42` mocks the lock module and writes its snapshot under a hardcoded key:

```ts
jest.mock("./lock-current-offering", () => ({
  lockCurrentOffering: (ctx: StepContext) => {
    // Keyed on the pipeline ENTRY name, which spring keeps as "lock-activity", not the module name.
    stepResultsSnapshots["lock-activity"] = { ...ctx.stepResults };
```

R10 gives the same handler three different entry names across the fall stages (`lock-pre-test`,
`lock-curriculum`, `lock-post-test`). The mock's key is therefore wrong for three of the four pipelines,
and because it is a single shared key it silently collides if more than one pipeline is driven in a file.
R16a treats `index.test.ts` as needing four *added* mocks; this is an *edit* to an existing one.

**Resolution**: added as **R16b**, separate from R16a because it is an edit to an existing mock
rather
than an added one. The snapshot key becomes per-invocation rather than the hardcoded `"lock-activity"`.

---

#### RESOLVED: R15a's per-scenario launch context gives the flex scenario no isolation at all

R15a requires each fall scenario to carry its own `resource_link_id` and `context_id`, with the stated
reason that reusing the shared `CONTEXT` collides with the spring `happy` scenario's assignment document.

That reason is correct for full-time, which uses `perClassScope(interactiveId, platform_id,
resource_link_id, context_id)`. It does not hold for flex. Verified at `assignment-doc.ts:108-115`:
`pooledProgramScope(program, interactiveId, platform_id)` takes **three** inputs and neither
`resource_link_id` nor `context_id` is among them. Giving the flex scenario its own pair therefore changes
its assignment document id not at all.

Two things follow. R15a's rationale reads as if it covers both scenarios and it covers one. And R15f, which
tells the README to name "the `sources/<source_key>/jobs-task-data/<docId>` document to delete to start
over", implies one document per scenario: for flex the id comes from a different formula and a different
namespace prefix (`ai4vs-flvs-assignments-pooled`), and that one document is shared by every flex scenario
that ever exists, so deleting it resets all of them at once.

No collision exists today (the two namespace prefixes differ at a fixed byte, deliberately, per
`assignment-doc.ts:76-81`), so this is a correctness-of-the-spec issue rather than a bug in the plan.

**Resolution**: **R15a** gains a warning block saying the isolation argument is full-time's only,
that
flex is separated instead by the pooled namespace prefix and `FLEX_PROGRAM`, and that the flex document is
per program rather than per scenario. **R15f** now names both formulas and says deleting the flex document
resets every flex scenario at once.

---

#### RESOLVED: R15b under-specifies the stub fixture in two ways

R15b says the harness gains `classes/info` entries for four class words and "an `offerings#show` response
whose `class_word` is the *scenario's* origin class word rather than today's single hardcoded one".

First, `class_word` is not the only hardcoded field. `stub-portal.js:176` serves
`{ clazz_id: classInfo.id, clazz_hash: classInfo.class_hash, class_word: classInfo.class_word, ... }`, all
four off `ORIGIN_CLASS` (id `90210`, word `fl-spring-2026-origin`). Making only `class_word` per-scenario
leaves a post-test run reporting origin class `ft-2026-bingler-shark` while `send-email` posts to class
`90210`. R11 makes this newly load-bearing, since `originClazzId` is now a published handoff. It would not
be caught by the scenario either, because R12's fallback reads the same wrong value from the same stub
response, so handoff and fallback agree on being wrong.

Second, `config.js:66-68` currently documents `TREATMENT_CLASS_WORD` (`ft-2026-bingler-gator`) as
deliberately fixture-free: "Needs no class fixture: the arm check short-circuits before any portal call, so
nothing ever looks this word up." R15 makes the full-time pre-test scenario enrol into exactly that word,
so `enrollSpecifiedClass` does look it up and R15b does add the fixture. The comment becomes false in the
same edit.

**Resolution**: **R15b** now requires the whole class identity (`clazz_id`, `clazz_hash`,
`class_word`) to
move together per scenario, states explicitly that the scenario cannot catch a mismatch because R12's
fallback reads the same wrong value, and records that `TREATMENT_CLASS_WORD`'s "needs no class fixture"
comment is corrected in the same edit.

---

#### RESOLVED: R15d says a scenario declares a class *word*, but the document stores an *arm*

R15d has a scenario "declare either the destination class word it expects or that it makes no assignment",
and `run.js` check accordingly. The persisted document holds neither a word nor a name: `assignment-doc.ts`
writes `strata[key].users[platform_user_id] = "treatment" | "control"`, and `run.js:19,52` maps that arm to
a display **name** through `CLASS_BY_ASSIGNMENT` before comparing to `EXPECTED_CLASS`.

So a driver that checks a declared *word* needs a third derivation: arm, plus the scenario's origin word,
plus `DESTINATION_SUFFIX`. That is fine, and arguably better than today's name table because it exercises
the same suffix constant the pipeline uses, but the spec should say which of the three the scenario
declares (arm, word, or name), because they are three different values and only one of them is what is
stored.

**Resolution**: **R15d** now names all three values (stored arm, today's display name, declared
word) and
settles on the **word**, derived by `run.js` as `originWord + DESTINATION_SUFFIX[arm]`. Chosen over the
smaller arm-only option because it makes the read-back exercise the same `DESTINATION_SUFFIX` round trip
the Technical Notes already call one source of truth, and retires `CLASS_BY_ASSIGNMENT`, a second
hand-maintained arm-to-name table.

---

### Operations / Incident Responder

#### RESOLVED: nothing in a run's logs says which of the three stages it was

Before this story there was one pilot, so a log prefix identified the run unambiguously. This story puts
three stages live at once over the *same* step modules, and the logs do not distinguish them.

Verified: no `logger.info` / `logger.error` / `logger.warn` call anywhere in `functions/src/tasks/ai4vs-flvs/`
or in `portal-api.ts` / `task-helpers.ts` interpolates `pilot`. The pilot reaches the portal's mint audit
`description` (`${pilot}:origin`), which is the portal's log, not ours.

Verified further that the orchestrator's failure path logs nothing at all. `index.ts:74-79` calls
`markComplete(..., "failure", ...)` and returns; the only `ai4vs-flvs:` log line in the loop is the
**success** line at `index.ts:82`. So on a failing run the stage-identifying evidence is the sequence of
preceding success lines, which do carry R10's stage-specific entry names.

That leaves the stages whose failure is at step 1 with no stage-identifying output whatsoever:

- **Curriculum** fails at `lock-curriculum`, its first entry. Log output is
  `lock-current-offering: Portal returned 403 for sources/.../jobs/<id>`, a prefix shared with the pre-test
  and post-test locks.
- **Post-test** fails at `resolve-origin-class`, its first entry, whose prefix is shared with the pre-test.

Triage on launch day ("the Blue button is failing") therefore requires joining each log line back to its
job document through `jobPath` to recover the pilot. That is possible but it is a per-incident manual step,
on the day when three brand-new buttons go live at once.

This is in tension with R8 and with "Files this story touches", which scopes `index.ts` to "three
`PIPELINES` entries and their imports". A log line is not a control-flow change, so it does not violate R8's
letter (no branching, no predicate, no continue-on-failure), but it is an edit to the runner the spec
currently says it is not making, so it needs a decision rather than being assumed in.

**Resolution**: added as **R8a**, with R8 narrowed to say the runner's *control flow* is not
modified so
the exception is explicit rather than a contradiction. The two lines log the selected pilot before the loop
and the failing step's name on the failure path. Chosen over recording the triage cost because the cost
lands on whoever is paged during a three-button launch, and the fix is two lines that change no behaviour.
`index.ts` in "Files this story touches" was updated.

---

### Portal API reviewer

#### RESOLVED (verified, no change): the per-stage portal call counts are correct

Technical Notes' "What a fall stage costs in portal calls" was re-derived step by step against the code
rather than re-read. All four rows check out, including that the pre-test's single unscoped mint is shared
by `resolveOriginClass`, `enrollSpecifiedClass`'s `classes/info` read, `applyOfferingState` and
`sendEmail` through the per-run `tokenCache`, and that the pre-test's *second* mint is the class-scoped one
`enrollSpecifiedClass` needs for `add_to_class`. The claim that R11 removes exactly one
`GET /api/v1/offerings/:id` from the pre-test and post-test stages, and none from the curriculum stage
(which has no `resolveOriginClass`, so R12's fallback runs), also holds.

**Resolution**: no change. Recorded so the next reviewer does not re-derive it.

---

### Candidates checked and dropped

Recorded so they are not raised again, and because in both cases the design turned out to be right for a
reason the spec does not state.

- **"Per-scenario `context_id` (R15a/R15c) will break the answers query, because `seed.js` mints one learner
  token with `class_hash: CONTEXT.context_id`."** False. `firestore.rules:44-48`'s `learnerOwner(res)` checks
  `platform_user_id` and `platform_id` only, with an explicit comment that "this conditional is used in read
  rules, which do not require a matching context_id". Checked `submit-task.ts` as well: it whitelists
  context keys (`submit-task.ts:99-109`) and validates only `source_key`, never comparing `context_id` to a
  token claim. A fall scenario may carry any `context_id` without re-seeding the token.
- **"Verification item 6's opposite-arms claim is too good to be true."** It holds. Full-time
  `Female|White|bingler` is `FULL_TIME_TABLE[0]`, `n1: "treatment"` (`strata-tables.ts:87`), giving
  `ft-2026-bingler-gator`. Flex `Female|White|High|Mod1` is `"control"`
  (`strata-tables.ts:22`), giving `fl-2026-section1-shark`. Opposite arms from identical seeded answers, as
  R15 claims.

## Self-Review (Round 4)

Six lenses: Senior Engineer, QA Engineer, Release / Pre-launch Engineer, Education Researcher, Portal API
reviewer, Spec Editor. Security/Privacy, Student and Teacher were dropped as lenses this round, since
Rounds 1 and 3 closed both with verified-no-change findings and this round's amendments touch neither.

Every finding below was verified before it was written: the runtime claims by throwaway jest files and
node scripts (since deleted), the portal claims against the `rigse` checkout at `6f4c49288`. Findings that
did not survive verification are recorded at the end.

Re-measured baseline, unchanged from Round 3: `npx jest` reports **26 suites, 479 passed, 4 skipped
(483 total)**. *(That was the pre-rebase number. REPORT-80 merged later the same day and added one test,
so verification item 8 now records 480. The measurements in this section are left as taken.)*

### Senior Engineer

#### RESOLVED: R3's "the only fall pilot string in the tree" is false, and R2a's cleanup is three-quarters undone

R3 says `run-step.js:55`'s `pilot: "fall-2026-fulltime"` "is the only fall pilot string in the tree", and
R2a calls that value "the stale string R3 removes". Neither holds. A tree-wide grep finds it in **four**
places, three of them in shipped unit tests:

| Location | Kind |
|---|---|
| `functions/harness/im-done-local/run-step.js:55` | fixture (R3's only target) |
| `functions/src/tasks/ai4vs-flvs/enroll-specified-class.test.ts:59` | fixture |
| `functions/src/tasks/ai4vs-flvs/enroll-specified-class.test.ts:100` | **assertion** on the mint call |
| `functions/src/tasks/ai4vs-flvs/open-target-offering.test.ts:105` | fixture |

The claim was inherited verbatim from REPORT-81's own spec
(`specs/REPORT-81-pilot-configurable-randomization.md:187`), which is where it was first wrong.

Two consequences. R3 as scoped leaves a program-shaped pilot value in three source files, one of it
asserted, which is exactly the precedent R2a says must not exist; a developer copying a fixture from
`enroll-specified-class.test.ts` still starts from `fall-2026-fulltime`. And the pinned assertion at
`:100` means the string is not merely decorative there: whoever changes it changes a passing test.

Note the contrast with `resolve-origin-class.test.ts:44,81` and `fall-random-assignment.test.ts:78`, which
already use `fall-2026-green`. So the tree is currently split between the two conventions and R3 does not
say so.

**Resolution**: **R3** rewritten as a four-row table naming every occurrence and the R2 value each
becomes, with the `enroll-specified-class.test.ts:100` one flagged as an assertion rather than a
fixture. The "only fall pilot string" claim is dropped and its origin in REPORT-81's spec is
recorded. **R2a** no longer describes the cleanup as a single edit. The two unit-test files are
added to "Files this story touches".


---

#### RESOLVED: R3 asks a single hardcoded literal to be two different stage values at once

R3 requires the run-step pilot to become "the R2 value matching whatever stage the scenario represents
(`fall-2026-orange` for the open-target scenarios, which are post-test)". But `run-step.js:55` sits inside
`buildContext`, which is shared by **every** run-step scenario, and those scenarios span two stages:

- `enroll-happy`, `enroll-unknown-word`, `enroll-lookup-forbidden` drive `enrollSpecifiedClass`, a
  **pre-test** step (`fall-2026-green`).
- `open-target-happy`, `open-target-treatment`, `open-target-lookup-forbidden`, `open-target-write-error`
  drive `openTargetOffering`, a **post-test** step (`fall-2026-orange`).

Setting the literal to `fall-2026-orange` mislabels the three enroll scenarios; setting it to
`fall-2026-green` mislabels the four open-target ones. Satisfying R3 as written means threading a
per-scenario pilot through `scenarios.js` into `run-step.js`, which is a different and larger edit than
"is replaced with".

Low blast radius (R3 itself records that `pilot` reaches only the mint's `description` here), but the
requirement is not implementable as literally worded.

**Resolution**: added as **R3a**. A run-step scenario declares its pilot in `scenarios.js` beside
the `stepModule` / `stepExport` / `stepName` it already declares, and `buildContext` takes it as an
argument; `OPEN_TARGET_STEP` carries `fall-2026-orange` and the enroll scenarios default to
`fall-2026-green`.


---

#### RESOLVED: "Files this story touches" omits `run-step.js` and attributes its edit to `config.js`

The file list names `config.js` as carrying "fall class fixtures, per-scenario launch contexts, **the R3
pilot value**". `config.js` contains no fall pilot value: its `REQUEST.pilot` is `spring-2026`, and the
string R3 targets is at `run-step.js:55`. `run-step.js` does not appear in the list at all.

Minor as a document defect, load-bearing as a work estimate: `run-step.js` is the file R3 actually edits,
and under the finding above it is the file that needs the per-scenario plumbing.


**Resolution**: "Files this story touches" corrected. `run-step.js` is listed with the edit it
actually carries, and `config.js`'s entry now names the fixtures and constants it really holds.

### QA Engineer

#### RESOLVED: R15c's per-scenario answers all land on the same four Firestore documents

R15c requires `seed.js` to seed "each fall scenario's answers under that scenario's `resource_link_id` and
`context_id`". It does not mention the document **id**, which `seed.js:26` builds as
`` `${CONTEXT.source_key}-ans-${answer.key}` ``: four fixed ids (`im-done-local-ans-gender`, `-grade`,
`-module`, `-race`), independent of scenario, written with `.set()`.

`run-all.js:3` and the README both say to seed **once** before running scenarios, so one `seed.js` run has
to hold every scenario's answers simultaneously. Reproduced with a node script against the real `config.js`
and `seed.js` formula: three launch contexts × four answers produced **4 distinct document ids, not 12**,
each written three times, last writer wins.

The failure is silent and misattributed. The two losing scenarios have no answers under their own
`resource_link_id`/`context_id`, so `evaluateCompletion` counts zero and fails with "You have completed 0 of
4 required questions", and `readDemographics` reports the student skipped every question. Both read as a
pipeline fault rather than a seeding fault.

Suggested resolution: R15c also requires the answer document id to carry the scenario, and `seed.js` to
loop over the scenarios rather than over one `ANSWERS` set.

**Resolution**: **R15c** now requires the answer document id to carry the scenario and `seed.js` to
loop over the scenarios that need answers, with the reproduced 12-to-4 collapse and the misleading
"0 of 4 required questions" symptom recorded so the next reader does not diagnose it as a pipeline
fault.


---

#### RESOLVED: R15a pins the stub's Orange offering id for a reason that is not true, and the wrong reason blocks R15e

R15a's second warning block says `CONTEXT.resource_link_id` must not change because "`stub-portal.js` gives
the control class an Orange offering whose id *is* `im-done-offering-1`, deliberately, so that REPORT-80's
R8a self-target guard is exercised against a realistic pair rather than against two ids that could never
collide."

The guard cannot fire on that pair. `open-target-offering.ts:183` compares `String(targetOffering.id)` to
`String(resource_link_id)`, and `targetOffering` is the offering that matched **the Blue target name**,
which in `stub-portal.js:67` has id `845`. The Orange offering's id is never compared to anything. Verified
that the guard is exercised only by `open-target-offering.test.ts:215`, which reaches it by giving the
*target-named* offering the run's own id (`1194`), a shape no harness scenario reproduces; no harness
scenario expects the "own offering" message.

`stub-portal.js:63-64` states the actual reason in its own comment: the Orange offering is the one "the
student launched from ... so a correct match must not select it". That is name-match discrimination, not
the self-target guard.

This is not merely a wrong footnote. R15e adds an end-to-end post-test scenario, and R15a gives it its own
`resource_link_id`. The realistic fixture then wants `studyControlClassInfo`'s Orange offering id to track
*that* scenario's `resource_link_id`, so the class contains the offering the student launched from. R15a's
stated rationale forbids exactly that edit, on a ground that does not exist. Checked: making the Orange id
follow the post-test scenario would **not** break `open-target-happy`, which depends on the target's *name*
and not on the Orange offering's id.

**Resolution**: **R15a**'s warning block rewritten. It now gives the real reason (the by-name match
must discriminate against the launch offering), states explicitly that the self-target guard is not
what the id is for and is reached only by `open-target-offering.test.ts:215`, and unblocks the R15e
fixture: the post-test scenario carries its own `resource_link_id` and the control class's Orange
offering id follows it.


---

#### RESOLVED: R15d's "the same constant" is not reachable from `run.js`, and the repo already chose the opposite pattern

R15d says `run.js` composes the expected class word from the scenario's origin word and
`DESTINATION_SUFFIX[arm]`, "which is deliberately the same constant `fallRandomAssignment` uses to build the
word and `armFromClassWord` uses to read it back", explicitly so the assertion is not "a second
hand-maintained arm-to-name table".

`run.js` requires `fs`, `crypto`, `./config`, `./scenarios` and `firebase-admin`, and nothing from `lib/`.
Only `run-step.js` imports compiled code, and it carries an `existsSync` guard (`run-step.js:84-87`) so a
missing build prints "run `npm run build`" instead of a raw `MODULE_NOT_FOUND`.

The import is technically available: `fall-programs.ts`'s two imports are both type-only and elided, so
compiled `fall-programs.js` has no runtime `require`, and the README's setup already requires a build for
`run.js` runs because the emulator serves `lib/`. But this repo has already faced exactly this choice and
decided the other way: `config.js:59-64` duplicates `TARGET_OFFERING_NAME` as a literal rather than
importing it, with a written rationale about not giving a harness file a build dependency, and pins the
duplicate with a unit test at `open-target-offering.test.ts:348`.

R15d asserts the import approach without acknowledging that precedent or requiring the `existsSync` guard
that would come with it. It also under-counts: the flex read-back needs `FLEX_PROGRAM` (`"fall-2026-flex"`)
for the pooled document id, a second constant R15d never names, and `fall-programs.ts:14` warns that string
is hashed data whose rename is a migration.

Suggested resolution: R15d names which of the two patterns it wants. The duplicate-and-pin one matches the
file's existing precedent and needs no new build coupling; the import one needs the guard and should say so.

**Resolution**: **R15d** now names the mechanism instead of asserting shared identity. The suffixes
are duplicated into `config.js` and pinned by a unit test, matching `TARGET_OFFERING_NAME`'s
documented precedent at `config.js:59-64` / `open-target-offering.test.ts:348`, and `FLEX_PROGRAM`
is named as the second constant the pooled read-back needs and pinned the same way.
`CLASS_BY_ASSIGNMENT` is still retired.


---

#### RESOLVED: R15b's fixture list adds two class words nothing reads and omits one a flipped arm needs

R15b requires `classes/info` entries for "`ft-2026-bingler` + `ft-2026-bingler-gator` and
`fl-2026-section1` + `fl-2026-section1-shark`". Traced every `classes/info` caller:

- `enrollSpecifiedClass` looks up the **destination** word: `ft-2026-bingler-gator`, `fl-2026-section1-shark`. Needed.
- `openTargetOffering` looks up the **origin** word, post-test only: `ft-2026-bingler-shark`, which already exists as `STUDY_CONTROL_CLASS`.
- `resolveOriginClass` resolves the origin through `offerings#show`, not `classes/info`.

So the two **registration** class words (`ft-2026-bingler`, `fl-2026-section1`) are looked up by nothing.
Harmless as fixtures, but listing them alongside the two that are load-bearing implies `classes/info` is how
the origin is resolved, which is the read R15b's own second paragraph is about correcting.

The omission is the other direction: the assignment is sticky (R15f), so an edited `ANSWERS` or a
non-reset document can flip the flex scenario to treatment, whose destination `fl-2026-section1-gator` has
no fixture. That surfaces as a `classes#info` 400 and the generic tell-your-teacher message, with nothing
naming the missing fixture. Full-time's flipped destination (`ft-2026-bingler-shark`) happens to exist
already, so only one of the two arms has this hole.


**Resolution**: **R15b** now traces the fixture list against the two `classes/info` callers, states
that the registration words are deliberately absent because nothing looks them up, and adds
`fl-2026-section1-gator` for the arm the sticky assignment can flip to.

### Release / Pre-launch Engineer

#### RESOLVED: R17 verifies that Blue is *present* and explicitly waves through the state the control arm depends on

R17's second item reads: "The Blue sequence is present in every `-shark` class and **not archived**. Locked
is fine and is the expected state; archived removes it from the class read."

That item verifies what the **open path** needs. It does not verify what the **study** needs, and the
parenthetical actively waves it through: an unlocked Blue in a `-shark` class passes this check, and an
unlocked Blue in a `-shark` class means control students can take the curriculum before the post-test.
That is the intervention reaching the control arm, which is a larger research-validity failure than the
R5b threshold gap already recorded, and unlike R5b it has no compensating control: the PI's manual
inspection is of Blue **completion** data, which is precisely what a contaminated control student would
now have.

Verified against `rigse` that class-level state is what governs a newly enrolled student, because they hold
no per-student row:

- `app/helpers/runnables_helper.rb:30-33`: `locked = offering.locked`, overridden by
  `UserOfferingMetadata` only `if metadata.present?`.
- `app/models/portal/clazz.rb:245-259` (`student_visible_offerings`): same fallback for `active`.
- `app/controllers/api/v1/offerings_controller.rb` (`update_student_metadata`): `find_or_create_by`, so the
  row exists only after our pipeline writes it.

The harness already encodes the required state as a fixture: `stub-portal.js:67` gives the control class
Blue with `locked: true`, commented "the curriculum present but locked, which is what the open path exists
to undo". Nothing verifies the real classes match it.

The same gap applies to the other two sequences, and R17 has no item for either: Orange must be locked in
both `-gator` and `-shark` classes until the PI opens it on her date (Out of Scope commits to that being
manual), and Blue must be open in every `-gator` class or treatment students cannot receive the
intervention at all.

Suggested resolution: R17 gains an initial-state item covering all three sequences in both arms, and the
existing Blue item drops "Locked is fine and is the expected state" in favour of requiring it.


**Resolution**: **R17** gains an initial-state item covering all three sequences in both arms, with
the `rigse` verification of why class-level state governs a newly enrolled student, and the existing
Blue item drops "Locked is fine and is the expected state". **Settled (Doug, 2026-07-30):** a checklist
item, owned by the PI, since she manages sequence opening by hand. R17 records the ownership, and records
that her commitment on record (2026-07-29) covers the **Orange** row only, so the Blue / `-shark` cell is
inferred from the same practice rather than confirmed and is the one to put to her first when the
checklist is run.

### Spec Editor

#### RESOLVED: the Overview and Background still describe the story Round 3 stopped writing

Two summary claims were left behind when later rounds widened the scope.

**Overview**: "composed entirely from steps already shipped ... it adds no new portal capability and no new
step logic." R11 and R12 change two steps' logic: `resolveOriginClass` publishes a new `StepOutput` field,
and `sendEmail` gains a handoff-with-fallback branch that the RESOLVED question itself sizes at "fifteen
lines".

**Background**, "What this story therefore is, and is not": "It is not: a new step, a new portal call, a
runner change, or a per-program pipeline." R8a adds two log lines to `ai4vsFlvs` and R16 adds an `export` to
the same file, both edits to the runner. Round 3 narrowed **R8** to "the runner's *control flow* is not
modified" precisely so R8a would not contradict it, but the Background sentence above R8 was not narrowed
with it.

The requirements are consistent; the two paragraphs a reader meets first are not, and both are the ones
Phase 5 rewrites anyway.


**Resolution**: both rewritten. The **Overview** now says two shipped steps change and names R11;
the **Background**'s "it is not" sentence is narrowed to the runner's *control flow*, matching R8's
Round 3 narrowing, and lists the three `index.ts` edits that are in scope.

### Portal API reviewer

#### RESOLVED (verified, no change): the two portal claims Round 1 inferred both hold against `rigse`

Re-checked at `6f4c49288` rather than re-read:

- Verification item 3 (a locked offering's run button is genuinely disabled) holds:
  `runnables_helper.rb:30-38` resolves per-student `UserOfferingMetadata.locked` over `offering.locked` and
  sets `href` to `javascript:void(0)`, plus a `disabled` class and a "locked by your teacher" title.
- Verification item 4 (a locked or inactive offering is still returned by the class read) holds:
  `Portal::Clazz#teacher_visible_offerings` (`clazz.rb:241`) filters on `runnable.archived?` only, and
  `classes_controller.rb`'s `get_info` maps that collection, serving `active` and `locked` as fields
  rather than as filters.

One property worth recording rather than acting on: `get_info` also serves, per offering, a `metadata`
array of `{user_id, active, locked}` for **every** student in the class. `open-target-offering.ts:149-156`
already logs offering **names** only, with a comment giving exactly this reason, and `portal-reads.ts`
holds the array as `unknown[]`. No change needed; recorded so the next reviewer does not re-raise it.

**Resolution**: no change.

### Candidates checked and dropped

- **"R16a's import table is wrong."** It is right. Re-ran each require in isolation under jest with
  `firebase-functions` mocked and `jest.resetModules()` between each: `assignment-doc`,
  `resolve-origin-class`, `open-target-offering` and `enroll-specified-class` load; `fall-random-assignment`,
  `demographics`, `evaluate-completion`, `firebase-client` and `index` all throw
  `ReferenceError: fetch is not defined`. `Object.keys(require("./index"))` is `["ai4vsFlvs"]`, confirming
  R16's export requirement. A first attempt without the reset reported `demographics` and
  `evaluate-completion` as loading, which is the same jest module-registry artifact Round 3 already
  documented, in the opposite direction.
- **"The fall scenarios need re-seeded learner tokens, because `seed.js` mints `class_hash: CONTEXT.context_id`."**
  Already dropped in Round 3 and re-confirmed here from the other end: `submit-task.ts:98-108` whitelists
  context keys but passes `request` through whole, and never compares `context_id` to a token claim.
- **"The harness's seeded answers will not match `FALL_PRE_TEST`."** They do. `pre-tests.ts:41-59`'s fall
  prompts and choice labels are identical to spring's, and `config.js`'s four `ANSWERS` prompts match all
  four.
- **"Verification item 8's baseline is stale."** Re-measured this round: 26 suites, 479 passed, 4 skipped,
  483 total. Unchanged.
