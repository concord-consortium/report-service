# Fall-2026 pipeline stages (pre-test, curriculum, post-test)

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-82
**Repo**: https://github.com/concord-consortium/report-service
**PR**: https://github.com/concord-consortium/report-service/pull/408

**Status**: **Closed**

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

It is outside the repo deliberately: the re-run trigger above outlives the story, and a checklist file
inside the spec folder would stop existing when that folder collapsed into this summary. ⚠️ **The full
tickable text is reproduced under [Pre-launch checklist (R17)](#pre-launch-checklist-r17) below**, which
is the copy-at-close half of that decision: the repo keeps the reasoning, the gist keeps the run log.

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

## Pre-launch checklist (R17)

⚠️ **Copied here deliberately.** R17's re-run trigger ("after any portal-side change to them") outlives
the story, and this file is what survives it. The tickable copy with its run log is a secret gist at
https://gist.github.com/dougmartin/2b07c5b6794eebbcc0c743e94b06ec41; this is the canonical text.

Run **against the real fall classes once they exist, and re-run after any portal-side change to them**,
with the result recorded on REPORT-82. It is a checklist rather than code because every item is
portal-side state the pipeline cannot establish for itself, and because each failure is invisible until
a student clicks and then affects a whole arm at once.

The first two items have the longest detection lag and cannot be caught any other way:

- [ ] `TARGET_OFFERING_NAME` matches the Blue offering's name **as the portal serves it**, modulo the
  trim and case folding the match applies. Reading the authoring sequence title settled what authoring
  holds; that the portal copies a runnable's name through unchanged is an inference. Nothing else can
  catch a mismatch: the unit fixtures and the harness stub are both configured *from* the constant, and
  the only run-time signal is a no-match failure that fires solely when a control student finishes the
  post-test, the last event in the study.
- [ ] The Blue sequence is present in every `-shark` class and **not archived**. Archived removes it from
  the class read and turns every control student's post-test into a permanent tell-your-teacher.
- [ ] **The three sequences carry the right initial class-level state, per arm.** A separate item from
  presence, and the one whose failure is a research-validity problem rather than an error message:

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
  after a write of ours.
- [ ] All eight registration class words and all sixteen subclass words exist and match
  `<origin>-gator` / `<origin>-shark` exactly, lowercase.
- [ ] The five full-time surnames in the class words match the strata table's surname keys
  (`bingler`, `hankamp`, `long`, `newlon`, `torres`); an unrecognised surname is a classified failure
  before anything is written.
- [ ] `AI4VS-Teacher` is a teacher on every registration class *and* every subclass, which both the
  cross-class mint at enrolment and `send_class_teachers` depend on.
- [ ] Each of the three buttons authors the pilot value for its stage (R2, and the value is authored
  rather than derived, so nothing checks it); the pre-test button authors `min_completed_questions`; and
  the curriculum and post-test buttons each author an `email_subject` (R14), without which their
  notifications are subject-lined "Student completed pre-test".
- [ ] **The pre-test button does NOT author `target_class_word`** (R13). Unlike the three above, this one
  has a code guard behind it: `enroll-specified-class.ts:44-60` treats an authored word that differs
  from the randomisation handoff as a hard configuration error with its own log line, so a violation
  fails loudly rather than routing the cohort into one class. It is on the checklist anyway because
  the guard fires on a student's click, and this is the only place it can be caught before one. It is
  listed for the pre-test button only: neither of the other two stages contains an enrol step, so the
  parameter is inert there and no guard exists to fire.

## Not Yet Implemented

Everything specified was implemented and verified. The items below were deliberately deferred or left
out, each with its reason.

- **A completion threshold on the curriculum and post-test stages** — descoped during the spec (see the
  decision below). The threshold is the PI's to set and there was no time to ask before launch. Adding
  it later is one entry at the front of the stage array plus an authored `min_completed_questions`; the
  threshold, not the mechanism, is what is missing. The residual is written up as R5b: on those two
  stages the lock records that the student *pressed the button*, not that they did the work, which on
  the treatment arm means a student can be counted as having received the intervention without it.
  **Worth raising with the PI once launch pressure is off; she has not been told the button applies no
  threshold.**
- **Rewording `send-email`'s post-lock failure message** (R18b) — recorded rather than fixed. *"Unable to
  send notification email. Please try again or contact your teacher."* cannot be acted on by a student
  who is already locked out of the activity whose button they pressed. Not fixed here because the string
  is live on `spring-2026`, where it has the same defect, so rewording it is a change to a running
  pilot's copy made mid-study, for a message that appears only when the notification fails after
  everything else has succeeded. In every case where it is reachable the completion is already on the
  roster, so a student who follows the advice loses nothing. The obvious follow-up the next time
  `send-email` is opened for any other reason.
- **The pre-launch checklist run** (R17, above) — not code, and not runnable until the real fall classes
  exist. Nothing makes a future portal-side change trigger a re-run; that remains a human commitment.
- **Closing the cross-class-move hole in full-time's per-class assignment scope** — out of scope, recorded
  on REPORT-81. A student moved between two full-time classes who re-completes the pre-test can be
  assigned afresh from the new teacher's counters and land in the opposite arm. Needs a program-wide
  student-to-arm index.

## Implementation divergences

Five places where the delivered code differs from the implementation plan as written. None changes what
any requirement delivers.

1. **`TREATMENT_CLASS_WORD` is derived rather than re-declared.** The plan kept it as its own string
   literal beside `FALL_FT_TREATMENT_CLASS`, which would put `"ft-2026-bingler-gator"` in `config.js`
   twice. It is `FALL_FT_TREATMENT_CLASS.word`, with the fall classes declared above it.
2. **The fall scenarios reference the config fixtures instead of repeating their words and ids**, which
   is how `happy`'s own declarations are written and removes the one place a fixture and a scenario
   could drift apart.
3. **`send-email.ts` posts `class_id: classId` rather than `class_id: String(classId)`.** Once the R11
   handoff branch lands, `classId` is a string on both paths, so the wrapper was a no-op.
4. **`run.js` fails a success scenario that declares neither `expect.assignedClassWord` nor
   `expect.noAssignment`.** The plan's two branches are opt-in, and its own analysis explains that
   omitting a declaration is silent rather than loud: the scenario reports PASS while verifying nothing
   beyond its completion text. Declaring `happy`'s expectations in the driver commit fixes that for
   `happy` only and leaves the hazard live for the next stage scenario anyone adds.
5. **The README correction is wider than the plan's step**, which scoped itself to the scenario list, the
   stickiness section, and the claim that the fall steps run only as direct-step scenarios. Two further
   claims were made false by the driver commit and were corrected in the same pass: that `run.js` asserts
   **three** things per scenario (it now asserts up to four), together with its caveat that a run does
   not prove "that exact `clazz_id` reached the portal", which the enrolment assertion now disproves; and
   the Files section's description of `TREATMENT_CLASS_WORD` as fixture-free.

## Verification as delivered

- `npx jest`: **26 suites, 491 passed, 4 skipped (495 total)**, the exact total the plan derived per step
  from a 484 baseline.
- `npm run lint` and `npm run build`: clean.
- The harness on the emulator against the stub portal: **31/31 scenarios**, over six consecutive runs
  (28 pre-existing plus the three fall stages).
- The post-test run makes one mint, one `GET offerings/:id`, one `GET classes/info`, two `PUT`s and one
  `POST send_class_teachers`, with **no second offering read**, which is R11/R12 working end to end.
- The two pre-test scenarios carry the **same** seeded answers and land in **opposite** arms (full-time →
  `ft-2026-bingler-gator`, flex → `fl-2026-section1-shark`).
- Three new assertions were checked to be falsifiable rather than vacuous, by breaking each and watching
  it fail: the ordered-handler test, the assignment document id formula, and the declaration guard.
## Decisions

Every question resolved while specifying and implementing this story, with the options that were on the
table and why the chosen one won. Requirements decisions first, then implementation decisions.

### What are the three pilot values called?

**Context**: The dispatcher stays unchanged only if the pilot string itself encodes the stage (R1). The
name reaches three places: whoever authors the buttons types it into `taskParams`, it is interpolated
into the portal mint's audit `description`, and it appears in our logs. The study is discussed with the
PI exclusively in colours, and the portal's own sequences are named `Green/Blue/Orange Sequence for AI in
Math (FLVS 26-27)`, so the author configuring the Blue button is looking at the word "Blue" while they do
it. Against that, "Blue means curriculum" is not guessable by anyone who has not read the study design.

**Options considered**:
- A) `fall-2026-green`, `fall-2026-blue`, `fall-2026-orange` — the study's and the portal's vocabulary.
- B) `fall-2026-pre-test`, `fall-2026-curriculum`, `fall-2026-post-test` — self-describing with no study context.
- C) `fall-2026-green-pre-test` and friends — both, at the cost of length.

**Decision**: **A** (Doug, 2026-07-30). The authoring surface and every conversation with the PI are in
colours, and a second vocabulary would have to be translated at each of them; B's readability is bought
back for one comment line in `index.ts`, which R2 requires. C was declined as length for no additional
information. Two things this settles beyond the strings: the value is authored per button rather than
derived, so R17 has to confirm each button carries the right one; and `resolve-origin-class.test.ts`'s
existing `fall-2026-green` fixture stops being an unowned guess and becomes the real name.

---

### How are the pipeline entries named, given that the teacher sees them?

**Context**: `send-email` renders `- <entry name>: <summary>` for every step, so entry names are copy in
the researcher's notification, not just internal identifiers. `lockCurrentOffering` returns no summary,
so its line renders as `- <entry name>: completed` and the name is the entire content of that line.

**Options considered**:
- A) Per-stage labels: `lock-pre-test`, `lock-curriculum`, `lock-post-test`, `open-curriculum`.
- B) Uniform handler-shaped labels: `lock-current` and `open-target` in every stage. One name per handler, at the cost of an email line that does not say what was locked.
- C) A's labels plus a `summary` added to `lockCurrentOffering`, so the line carries the offering too.

**Decision**: **A**, per-stage labels. Free, and the only one of the three that makes the teacher email
say what happened. It is exactly the latitude REPORT-80 reserved when it kept spring's `lock-activity`
over the renamed handler. C buys little for a portal read the step deliberately does not make. R10a's
processing messages were settled alongside it, being the same kind of copy.

---

### At the post-test stage, does the lock run before the open, or after?

**Context**: Raised by REPORT-80 and deliberately left here. The runner is fail-fast, so whichever step
fails aborts the stage and suppresses the teacher email either way. After a successful lock the student's
run button is genuinely disabled, so "they can click again" is false once the lock lands. Under lock-then-open,
a failed open leaves a control student locked out with their completion recorded, unable to retry. Under
open-then-lock, a failed open leaves them unlocked with nothing recorded: a retry is real, but the
completion the researcher reads off the roster is missing, and that is the state her manual opening is
gated on.

**Options considered**:
- A) Keep `lock` then `open`. Record the residual and move on.
- B) Reorder to `open` then `lock`, and revisit REPORT-80's R12 message, whose reassurance clause stops being guaranteed.
- C) Reorder *and* soften the message to something true under either order.

**Decision**: **A** (Doug, 2026-07-30). What tips it is which failures are actually retryable:
`openTargetOffering` has five failure branches and three are permanent until someone edits code or portal
state. So open-first buys retryability that does not apply to the most likely failure, and pays for it
with the completion record. A also leaves REPORT-80's shipped copy true as written.

**Consequences recorded rather than fixed**: a control student whose open fails is locked out with their
completion recorded, cannot retry, and their teacher is not emailed (fail-fast aborts before
`send-email`); the recovery is the researcher opening Blue by hand, which she does on a schedule anyway.
And this is now a **dependency of the order**: if a future change reorders these two steps, REPORT-80's
R12 message must be revisited in the same edit.

---

### Does the curriculum stage check completion before locking?

**Context**: The Jira lists `evaluate-completion` only in the pre-test stage, but the PI's whole reason
for the curriculum button is gating: *"it is important for me to know who completed the Blue and who
didn't. Because I will not unlock the Orange (on the specific date) for those who have not"*. Without a
check, a student who opens Blue and immediately presses "I'm Done" is locked out and recorded as complete,
which is the exact record she filters on. The step is reusable as-is, since a sequence shares one
`resource_link_id`. The cost is a defensible `min_completed_questions` for Blue, which someone must choose.

**Options considered**:
- A) Add `evaluateCompletion` first in the curriculum stage, with `min_completed_questions` on the Blue button.
- B) Leave the stage as lock-then-email, per the Jira. The lock records "pressed the button", and the researcher applies her own judgement.
- C) Ask the PI whether a Blue completion threshold exists and what it is, before deciding.

**Decision**: **B** (Doug, 2026-07-30). C was the recommendation, but it is the only option that leaves
the story blocked on an answer from the PI and there was no time for that round trip before launch. The
same reasoning applies to the post-test stage. **Explicitly revisable, and cheaply.** See "Not Yet
Implemented" for the residual, which is a research-data limitation rather than a UX one.

---

### What subject line do the curriculum and post-test emails carry?

**Context**: `send-email`'s default subject is the literal `AI4VS: Student completed pre-test`, correct
for spring and the fall pre-test and wrong for the other two stages. `email_subject` is an authored
override, so a correctly authored button has no problem; the failure mode is a Blue or Orange button
authored without one, which quietly mislabels every notification from that stage. Nothing in code can
detect it, because the parameter is legitimately optional.

**Options considered**:
- A) Require `email_subject` on the curriculum and post-test buttons, and add it to R17's checklist. No code change.
- B) Give the pipeline entry an optional default subject that `sendEmail` falls back to before the module default.
- C) Change the module default to something stage-neutral, e.g. `AI4VS: Student completed an activity`.

**Decision**: **A**. R17 already exists and this is one more line in it, whereas B adds a second
subject-resolution path to a live step for a value that has to be written by hand either way. C is
rejected outright: it would degrade spring's accurate subject to serve fall buttons that are
mis-authored. Revisit B if a fall stage is ever added without a button-authoring step.

---

### Do the curriculum and post-test stages get end-to-end harness scenarios too?

**Context**: R15 inherits two pre-test scenarios from REPORT-81. REPORT-80 covers `openTargetOffering`
through `run-step.js`, which drives one compiled step with a hand-built context. Nothing then exercises
the post-test stage as a *stage*: `stepResults` accumulation across four entries, R9's entry-name
uniqueness, and the teacher email rendering a lock line beside an open line.

**Options considered**:
- A) The two inherited pre-test scenarios only. Smallest scope; matches the Jira.
- B) Add a post-test control scenario (resolve, lock, open, email in one run).
- C) All four stages-by-arm, plus curriculum.

**Decision**: **B** (R15e). The post-test stage is the only one whose wiring can fail *silently*: a
duplicate entry name there drops a line of the researcher's email rather than throwing, so no other test
would notice. C is declined: a treatment post-test run and a curriculum run each add a scenario whose
only untested content is a step already covered in isolation.

---

### Is the `clazzId` tidy-up (R11, R12) in scope for this story?

**Context**: Assigned here by REPORT-81 and re-confirmed by REPORT-80, on the reasoning that it touches
`send-email`, a step neither of them otherwise modified, and that the stage wiring is where step order is
being decided anyway. It saves exactly one `GET /api/v1/offerings/:id` per run on two stages. It is not a
correctness fix: both reads use the same cached token and the same endpoint.

**Options considered**:
- A) Do it, with the R12 fallback.
- B) Defer it. Record it as a known duplicate read and leave `send-email` untouched.

**Decision**: **A**. Two prior stories assigned it here for the same reason, and deferring it a third
time means a second round of review on `send-email` for fifteen lines. Recorded plainly: this is the one
requirement in the story that could be dropped with no consequence beyond a redundant portal read, so if
implementation scope tightens, drop this rather than R15's harness work.

---

### Should the pre-test scenarios assert the enrolment itself, or only the assignment document?

**Context**: R15 says the two pre-test scenarios "assert the destination class the student was actually
enrolled in rather than only the completion text". Reading the arm back from the persisted assignment
document and deriving the word proves the strata-to-class mapping and that *some* enrolment succeeded,
but not that that exact class reached the portal.

**Options considered**:
- A) Keep the assignment-document read-back. The gap is pre-existing, documented, and the same for spring.
- B) Have the stub record the last `add_to_class` body to a file and have `run.js` assert the `clazz_id`. Closes the gap for the fall scenarios and for `happy` at once.
- C) B, but for all portal calls, so any scenario can assert any request body.

**Decision**: **B** (Doug, 2026-07-30), scoped to `add_to_class` only. What settled it is a property of
the read-back that R15d did not state: it reads an **arm** and recomposes the word from harness constants,
then compares that to a literal in the same file, so both sides are harness values and the word the
*pipeline* computed is never observed. Combined with R15b's deliberate decision to give all four subclass
words a `classes/info` fixture, a pipeline that appended the **wrong suffix** would resolve a real class,
enrol successfully, and pass. C was declined as the same mechanism generalised, which nothing else needs
and which invites scenarios that assert request shapes the unit tests already own. Recording the
`send_class_teachers` body instead was rejected too: it would make scenarios depend on rendered
teacher-facing copy, which R10 expects to keep changing.

---

### Where does the R17 pre-launch checklist live as a working artifact?

**Context**: R17 is a task with a result to be recorded on the ticket, but the plan's last step produces
no file. The checklist existed only as prose inside requirements.md, which is not a thing anyone can tick
off, and the story closes into a summary that may not carry it.

**Options considered**:
- A) A `checklist.md` in the spec folder, ticked off in a commit when it is run.
- B) A Jira comment on REPORT-82 posted when the classes exist.
- C) Leave it in requirements.md R17 and record only the outcome on the ticket.
- D) A secret gist, linked from R17 and from the ticket, copied into the closed spec summary at close.

**Decision**: **D** (Doug, 2026-07-30), at
https://gist.github.com/dougmartin/2b07c5b6794eebbcc0c743e94b06ec41. A was ruled out on a property of
this repo rather than on preference: closed specs collapse to a single file, so a `checklist.md` inside
the folder stops existing at close, while R17's re-run trigger outlives the story. The gist is **secret**
(unlisted, not private), which was checked rather than assumed: this repo is public, so the class words
and the teacher surnames in `strata-tables.ts` are already openly published, and the gist adds no
exposure that does not already exist. ⚠️ What D does **not** solve: nothing makes a future portal-side
change trigger a re-run. That remains a human commitment. *(The checklist text is reproduced in full
above, which is the copy-at-close half of this decision.)*

---

### Is the commit split right, particularly the four harness steps?

**Context**: The plan is nine steps, of which four are harness plumbing (config, stub, seed, driver) that
add capability nothing uses until the fifth adds the scenarios. An earlier draft of this question claimed
those four commits "cannot be judged by running anything, only by reading", which is false and was the
whole argument for collapsing them: each has a real acceptance check (the config fixtures add unit-test
pins; the stub identities are checked by `open-target-happy`, whose discriminating fixture that commit
moves; the seeding by `happy` still passing, which the collection-clearing change could break; the driver
by `happy` passing with its read-back and enrolment assertion active).

**Options considered**:
- A) Keep the split as planned. Each commit is small and reviewable; the harness stays green throughout.
- B) Collapse the four plumbing commits plus the scenarios into one commit (~590 lines).
- C) Collapse config+stub into one and seed+driver+scenarios into another.

**Decision**: **A** (Doug, 2026-07-30), with the stale-pilot cleanup moved to **first**. The split is not
four unreviewable commits followed by a payoff, it is four commits that each keep a green suite green. B
would fold the Orange-offering-id change, the answers-collection clearing and the driver rewrite into one
commit, and a broken `open-target-happy` would then have to be bisected inside it rather than attributed
to the commit that moved the id. The reorder is separate and minor: the pilot cleanup is inert and spans
four files across both trees, so as a middle commit it would add noise to the diffs on either side of it.

---

### Spec-review findings that changed the specification

Resolved during four rounds of requirements self-review and one round of implementation self-review. Each
was verified against code or against the `rigse` checkout before being written down; those that turned out
to be properties the design already had are omitted here as they produced no change.

**On the wiring and the runner**

- **`index.test.ts` breaks when fall steps are added to `index.ts`, and not cosmetically.** The file mocks
  each step module by path; the fall stages import four more. Recorded as R16a. A later round corrected
  its *reason*: the breaking chain is `fall-random-assignment` → `demographics` → `firebase-client` →
  `firebase/auth` throwing `ReferenceError: fetch is not defined`, **not** `firebase-admin`
  (`assignment-doc` loads fine). Exactly one of the four imports is build-breaking, not four, and a
  developer following the original wording would have gone looking for an Admin SDK failure that does not
  exist.
- **The existing `lock-current-offering` mock hardcodes spring's entry name** (`stepResultsSnapshots["lock-activity"]`).
  R10 gives that handler three further names, so the key is wrong for three of the four pipelines and
  silently collides once more than one pipeline is driven in a file. Added as R16b, separate from R16a
  because it is an edit to an existing mock rather than an added one. *(In implementation the key became
  the **pilot**: the entry name is not reachable from a handler, since the runner passes only
  `StepContext`, and deriving it from what has accumulated in `stepResults` picks spring's name every
  time.)*
- **R16's duplicate-name assertion could not be written against `index.ts` as it stood**, because
  `PIPELINES` was module-private and `ai4vsFlvs` was the only export. Both alternatives were checked and
  rejected: driving a pipeline and reading the `stepResults` snapshot **cannot** see a duplicate, since
  collapsing is exactly what a duplicate does; reconstructing the name list from the per-iteration log
  works but only for pilot strings the test hardcodes, which turns "a property of the table" into "a
  property of four known pilots". R16 therefore required the export. **Superseded in this story's favour**:
  PR #407's reviewer reached the same conclusion independently on REPORT-80, so the export and the
  duplicate-name `it.each` both shipped there, and R16 was rewritten to add only the ordered-handler
  assertion.
- **Nothing in a run's logs said which of the three stages it was.** With one pilot a log prefix identified
  the run; three stages over the same step modules made it ambiguous, and the only `ai4vs-flvs:` line in
  the loop is the *success* line, so a stage failing at its first entry emitted nothing naming the stage.
  Triage would have meant joining each log line back to its job document through `jobPath`, on the day
  three brand-new buttons go live. Added as **R8a**, with R8 narrowed to say the runner's *control flow*
  is not modified, so the exception is explicit rather than a contradiction.
- **The new `StepOutput` field was required but never named**, and its producer not pinned, which
  `StepOutput`'s one-producer-per-field invariant cannot state. R11 now names `originClazzId`.

**On the harness**

- **R15a's per-scenario launch context had to be additive**, or it would break the four `open-target`
  scenarios REPORT-80 had just shipped, since the stub gives the control class an Orange offering whose id
  *is* `CONTEXT.resource_link_id`.
- **R15a pinned that id for a reason that is not true, and the wrong reason blocked R15e.** The stated
  reason was REPORT-80's self-target guard; that guard compares the offering matching the **Blue** target
  name (id `845`) against `resource_link_id` and never looks at the Orange id at all. The real reason is
  name-match discrimination. This was not a footnote: R15e wants the Orange id to follow the post-test
  scenario's own `resource_link_id`, and the false rationale forbade exactly that edit.
- **R15a's isolation argument is full-time's only.** `pooledProgramScope` takes program, `interactiveId`
  and `platform_id` and nothing else, so giving the flex scenario its own launch context changes its
  document id not at all. Flex is separated from spring by the pooled namespace prefix and by
  `FLEX_PROGRAM` being in the hash. The consequence: the flex assignment document is **per program, not
  per scenario**, so R15f's reset instruction has to say deleting it resets every flex scenario at once.
- **R15b under-specified the stub fixture in two ways.** `class_word` is not the only hardcoded field:
  `clazz_id` and `clazz_hash` come off the same single fixture, so a per-scenario word alone would leave a
  post-test run reporting one origin class while `send-email` posts to another — and the scenario would
  not catch it, because R12's fallback reads the same wrong value from the same response. All three fields
  move together. Separately, `TREATMENT_CLASS_WORD`'s "needs no class fixture" comment becomes false in
  the same edit, since the pre-test scenario enrols into that word.
- **R15b's fixture list added two class words nothing reads and omitted one a flipped arm needs.** The two
  registration words are looked up by no step (the origin is resolved through `offerings#show`), and
  listing them alongside the load-bearing ones implies `classes/info` is how the origin is resolved.
  `fl-2026-section1-gator` was added for the arm a sticky assignment can flip to, which would otherwise
  surface as a `classes#info` 400 with nothing naming the missing fixture.
- **The two fixture sets are therefore not the same set**, which the implementation review had to settle:
  the registration words need an `offerings#show` identity even though they need no `classes/info` entry.
  Resolved as a **separate identity map** (`ORIGIN_IDENTITY_BY_WORD`, a superset of `CLASSES_BY_WORD`)
  rather than folding them in, which keeps R15b's claim literally true rather than merely commented, plus
  a loud 500 for a declared word with no fixture: a silent fallback to the spring class would have made
  both pre-test scenarios fail as "unclassifiable origin class word", a pipeline-shaped message for a
  fixture-shaped fault.
- **`run.js` asserted an assignment on every successful run**, so R15e's post-test scenario would have
  failed by construction: it makes no assignment, so the read-back returns `undefined`. R15d now makes the
  read-back per-scenario rather than implied by success.
- **R15d said a scenario declares a class *word*, but the document stores an *arm*.** Three different
  values were in play (stored arm, today's display name, declared word) and the spec named none of them.
  Settled on the **word**, derived as `originWord + DESTINATION_SUFFIX[arm]`, retiring
  `CLASS_BY_ASSIGNMENT`. *(A later round corrected the justification: this does **not** exercise the
  pipeline's suffix round trip, since both sides of the comparison are harness values. What protects the
  duplicated constants is the unit-test pin, and what observes the pipeline is the enrolment assertion.)*
- **R15d's "the same constant" is not reachable from `run.js`**, which requires nothing from `lib/`. The
  repo had already faced this exact choice and decided the other way, duplicating `TARGET_OFFERING_NAME`
  as a literal with a written rationale and pinning it with a unit test. R15d now duplicates the suffixes
  and `FLEX_PROGRAM` the same way. It had also under-counted: the flex read-back needs `FLEX_PROGRAM`, a
  second constant the requirement never named, whose rename is a data migration.
- **R15c's per-scenario answers all landed on the same four Firestore documents.** The document id was
  built from the source key alone, and seeding is a single run that must hold every scenario's answers at
  once: three scenarios by four answers gave **4 documents, not 12**, last writer wins. The failure is
  silent and misattributed, reporting "completed 0 of 4 required questions" and every demographic skipped,
  both of which read as a pipeline fault.
- **A fall scenario's assigned arm is sticky across re-runs**, which is correct (it is what R18 asserts)
  but from outside means editing the answers and re-running yields the old arm with nothing explaining
  why. R15f requires the README to say so and name the document to delete. Deliberately not automated: a
  driver that cleared the assignment every run would destroy the property R18 exists to demonstrate.
- **`happy`'s read-back declaration belonged to no commit**, so the rewritten check would have been
  silently skipped and `happy` would have lost its assignment verification outright while still reporting
  PASS. It moved into the driver commit, which also made that commit's acceptance check falsifiable rather
  than vacuous.
- **`expect.enrolledClassId` compared a number fixture against the string the enrol step posts.** The two
  enrolling steps disagree on the type they post and the two declaring scenarios on the type they hold, so
  a `===` comparison would pass for `happy` and fail for both fall scenarios — on the one assertion added
  to close a real gap, where the temptation on a red run is to delete it. Stringified on both sides.

**On the study and the people in it**

- **Without a completion gate, the treatment arm's intervention-received flag is a button press.** The
  original write-up understated this: Blue *is* the intervention, so a treatment student who clicks
  immediately is locked out of the curriculum, appears complete on the roster, is therefore in the set the
  PI opens the post-test for, and is counted as treated having received none of it. Control's equivalent
  is milder. R5b now states the treatment case explicitly and names the compensating control.
- **Treatment students were shown a processing message for a step that does nothing.** *"Opening your
  other activity…"* promised something that does not happen for roughly half the cohort, and it is the
  last thing many of them see before the completion message. Changed to *"Checking for your other
  activity…"*, true on both arms and consistent with REPORT-80's failure copy for the same step. The
  rejected alternative was a stage-level conditional, which R8 forbids.
- **R17 verified that Blue is *present* and explicitly waved through the state the control arm depends
  on.** "Locked is fine and is the expected state" meant an unlocked Blue in a `-shark` class passed the
  check — which is the intervention reaching the control arm, a larger research-validity failure than the
  R5b threshold gap and, unlike it, with no compensating control. R17 gained an initial-state item
  covering all three sequences in both arms, owned by the PI, with the Blue/`-shark` cell flagged as
  inferred rather than confirmed.
- **The pre-launch checklist had no owner and no time relative to launch.** "Executed before the study
  opens" is not a commitment anyone holds. R17 became a task on this story, run against the real classes
  once they exist and re-run after any portal-side change, with the result recorded on the ticket.
- **After the lock, `send-email`'s failure message tells the student to do something they cannot.**
  Recorded as a residual rather than fixed; see "Not Yet Implemented".
- **"Must not be authored" claimed a consequence that only exists on one stage.** `target_class_word` is
  load-bearing on the pre-test stage, where an existing guard hard-fails an authored word that differs
  from the handoff; neither other stage contains an enrol step, so it is inert there. Listing it
  identically across all three implied a guard that does not exist. R13's table now distinguishes them,
  and R17 gained a bullet for the pre-test rule, which was otherwise the one authoring rule in the story
  with no landing place a button author would meet.

**On the specification itself**

- **R3's "the only fall pilot string in the tree" was false, and R2a's cleanup three-quarters undone.** A
  tree-wide grep found the stale `fall-2026-fulltime` in **four** places, three of them in shipped unit
  tests and one of those an **assertion** rather than a fixture. The claim was inherited verbatim from
  REPORT-81's spec, which is where it was first wrong. Left as scoped, it would have kept a
  program-shaped pilot value in three source files — exactly the precedent R2a says must not exist, since
  a developer copying a fixture still starts from it.
- **R3 asked a single hardcoded literal to be two different stage values at once.** `buildContext` is
  shared by every run-step scenario, and those scenarios span two stages. Added as R3a: the pilot joins
  the per-scenario step selection `scenarios.js` already carries.
- **The file list omitted `run-step.js` and attributed its edit to `config.js`**, which contains no fall
  pilot value at all. Minor as a document defect, load-bearing as a work estimate.
- **The Overview and Background still described the story an earlier round stopped writing**, claiming no
  step logic changes (R11 and R12 change two steps) and no runner change (R8a adds two log lines). Both
  rewritten.
- **The implementation plan's test totals were wrong in two places, and the two disagreed with each
  other.** Both said 492, which could not both be right since steps that add tests fall between them.
  Re-derived once, by measurement rather than projection, into a per-step table ending at 495. It matters
  because the number was written as the acceptance gate for the whole story: a developer who lands the
  work and sees 494 has to decide whether they added something they should not have.
- **The implementation plan's `index.test.ts` edit list omitted the eight handler imports** the
  ordered-handler assertion needs; the file imports none of them today, so the table does not compile
  until they are added. Mechanical, but the one edit in that step that is build-breaking rather than
  additive, in a plan whose value is that it can be typed in as written.
- **A test description named a mock `send-email.test.ts` does not have.** That file does not mock
  `resolveOriginOffering`; it mocks the transport and lets the real function run over it, so the thing an
  assertion can count is fetch calls whose path matches `/api/v1/offerings/`. The difference between a
  test that can be written from the plan and one that cannot.
