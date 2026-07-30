# Offering-state pipeline step: lock a current offering and open a target offering

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-80
**Repo**: https://github.com/concord-consortium/report-service
**Implementation Spec**: [implementation.md](implementation.md)
**Status**: **In Development**

## Overview

Replace the shipped `lock-activity` step with a shared offering-state core and two thin steps over it,
so the pipeline can set a student's per-offering state either on the offering they launched from
(locking it behind them) or on another offering in the same class (opening it to them), the latter
resolved by its author-controlled name rather than by a database id and applied only to control
students. Every write carries both the `locked` and `active` flags, so the resulting state is
determined by the request rather than partly inherited.

## Project Owner Overview

In the fall study, clicking "I'm Done" has to change what a student can still get into. At the end of
the pre-test, the curriculum, and the post-test, the activity they just finished is locked behind
them, both to stop them going back to change answers and because the locked checkbox on the portal's
teacher progress roster is how the researcher knows who finished. Separately, control students get
the curriculum opened to them once they finish the post-test, since they were held out of it during
the study.

Today the pipeline can only lock the one activity the student clicked from. This story makes that
same operation able to point at a different activity in the student's class, and to open one as well as
lock one, where opening means both unlocking it and making sure the student can see it, since an
activity they cannot see is one they cannot reach however unlocked it is. The activity is named the way
an author names it, not by an internal id, because ids differ between the staging and production portals
and would have to be re-authored per environment.

## Background

### What the story asked for, and what a caller census cut

The Jira story was originally specified with three capabilities: lock the current offering, hide the
current offering, and open (unlock plus make visible) a different target offering, with the target
class resolved from a derived class word. A caller census on 29 July 2026, after the PI answered the
outstanding study-flow questions, found that only two of those have any caller in the fall flow:

- **lock-current: three callers.** The pre-test stage locks the pre-test, the curriculum stage locks
  the curriculum (PI-confirmed 29 July 2026), and the post-test stage locks the post-test. All three
  are the operation `lock-activity` already performs against the run's own offering.
- **open-target (unlock and make visible): one caller.** The post-test stage's control-only opening of
  the curriculum. Round 2 restored the "make visible" half of the original wording: the step writes
  `active: true` as well as `locked: false`, because an offering that is not visible is not reachable
  however unlocked it is (see R2).
- **hide-current: zero callers.** Nothing in the fall flow ever writes `active: false`. That is
  deliberate: control students must still *see* both sequences and be unable to run them. Note the
  visibility flag itself **is** written, on every call and always as `true` (R2); what has no caller is
  hiding. This sentence read "never writes the visibility flag" before Round 2 made the write
  unconditional.

The remaining target-resolution caller needs no class-word derivation either, because the curriculum
and the post-test both live in the treatment/control subclass the student launches the post-test
from. The target is therefore always in the origin class.

### Where this sits in the pipeline

`functions/src/tasks/ai4vs-flvs/` holds one file per pipeline step, each exporting a
`StepHandler` (`(context: StepContext) => Promise<StepResult>`). `index.ts` holds a `PIPELINES` map
whose entries are `{ name, processingMessage, handler }` and runs them as a flat, ordered, fail-fast
sequence. Only `spring-2026` is wired today; REPORT-82 owns the fall stage entries, so this story's
step ships as unreferenced production code the same way REPORT-81's two steps did.

REPORT-81 already publishes the student's origin class word on `StepResult.output.originClassWord`,
normalized to the portal's stored (lowercase, trimmed) form. REPORT-79 already ships
`lookupClassByWord`, which returns the class's full offering list.

## Requirements

### The write

- **R1.** A parameterized shared core, `applyOfferingState(context, { offeringId, locked, active })`,
  sets the per-student flags on a given offering via
  `PUT /api/v1/offerings/:id/update_student_metadata`, replacing the hardcoded `locked=true` write in
  `lock-activity.ts`. Two thin `StepHandler`s sit over it and take no configuration of their own:
  **`lockCurrentOffering`** (target `resource_link_id`, `locked: true`) and **`openTargetOffering`**
  (target resolved by name within the origin class, `locked: false`). The target offering name is an
  **exported** module constant whose value is **`"Blue Sequence for AI in Math (FLVS 26-27)"`**, the
  curriculum sequence; see [The study's three sequence names](#the-studys-three-sequence-names) for all
  three and for the pre-launch check the value requires. It is a constant rather than an authored
  request param.
  `offeringId` is typed `string | number`,
  since the two callers legitimately supply different forms (`resource_link_id` is a decimal string,
  `PortalOffering.id` a number); see [The id forms](#the-id-forms-platform_user_id-and-resource_link_id-are-bare-integers).
- **R1a.** The core returns a **discriminated outcome**: failure carrying a `PortalFailureBucket`
  **plus the portal's `status` and body when the write itself was rejected**, or
  **success carrying the `{active, locked}` the portal returned** (absent when the response had no
  body). It does **not** render student-facing copy.
  **AMENDED during implementation: the failure variant also carries `status` and `data`.** As
  originally written the failure variant carried the bucket alone, which was found to be
  insufficient by running the shipped suite against a literal implementation of it:
  `lock-activity.test.ts` asserts the step logs `Portal returned 403` with `{ status, data }`, and
  that diagnostic is reproducible only inside the core, where the response is seen. The observed
  failure was `Expected: StringContaining "Portal returned 403" ... Received: "lock-current-offering:
  portal write failed for ...", {"bucket": "tell_teacher"}`. Letting the core log it instead was
  rejected for the reason this requirement already gives for the success log: one shared prefix for
  both callers loses attribution on a stage that runs both. `status` is deliberately **absent for a
  failed mint**, because `mintScopedPortalToken` already logs its own failure and a step that logged
  "portal write failed" for a mint failure would name a request that was never issued; so "status is
  present" is exactly the signal a caller needs to distinguish the two. R16 is unaffected:
  `update_student_metadata` renders only `{active, locked}` and its error bodies carry no names. Each step maps the bucket to its
  own message via `messageForBucket`, consistent with R12 and with how every sibling step is written.
  `openTargetOffering` renders its own non-portal failures (no match, multiple matches, unclassifiable
  class word) through the same path, so one step has one way of producing a message.
  The success payload exists because **R20 puts the log on the step, not on the core**, and the response
  body is visible only inside the core. Threading it out is preferred over letting the core log, because
  every sibling step prefixes its log lines with its own step name and a shared core would emit one
  prefix for both callers, losing which of the two wrote on a stage that runs both. This keeps the core
  free of presentation concerns, which is the property R1a exists to establish.
- **R1b.** `openTargetOffering` classifies the arm **immediately after reading the `originClassWord`
  handoff and before any portal call**, returning the treatment no-op without minting or reading the
  class. Ordering is stated because the control-only conditional decision establishes only that the
  check is *free*, not where it runs, and a check placed after the class read would have every treatment
  student (roughly half the cohort) pay a `classes/info` read to do nothing, while needlessly holding the
  `metadata[]` array R16 exists to keep out of logs on a path with no use for it.
- **R2.** The write **always sends both `locked` and `active`**, never `locked` alone. See
  [Technical Notes](#the-two-flag-write-is-mandatory-not-defensive) for why this is a correctness
  requirement rather than a courtesy. **Both callers send `active: true`**, for different reasons that
  happen to agree:
  - `openTargetOffering` sends it **because visibility is the point**. An offering whose effective
    `active` is false is absent from the student's runnable list entirely
    (`clazz.rb:245` `student_visible_offerings`, `runnables_helper.rb:31`), so unlocking a hidden
    offering accomplishes nothing the student can see. "Open" means make reachable, which is how the
    story originally worded it ("unlock plus make visible"), so the step writes both flags to the
    state that makes the target usable rather than preserving a state that would defeat it.
  - `lockCurrentOffering` sends it because nothing in the study hides at class level and reading the
    student's current value would cost an extra `GET /api/v1/offerings/:id` on a path that makes no
    read at all.
  The shared core still takes `active` as an **explicit argument**, so a future caller that genuinely
  needs to write `false` (the deferred hide capability) needs no change to the core. Nothing in this
  story passes `false`.
- **R2a.** The write's resulting state is **fully determined by the request**, never partly inherited
  from whatever row already exists. Sending both flags is what buys that: for a student who already
  has a `user_offering_metadata` row with `active: false`, a PUT omitting `active` would leave the row
  hidden and the unlock pointless, since `update!` writes only the permitted keys it was given. So the
  step **neither reads nor echoes the student's current flags**, and specifically **does not read
  `metadata[]`**. Round 2 removed an earlier echo rule here; see
  the amendment on the `active`-value question for why, and note the consequence that this story reads
  no per-student state at all, only offering **names**, which is why nothing in it needs the class
  body's per-student rows.
- **R3.** The step is idempotent. Setting an offering to a state it is already in succeeds. The
  portal side of this is already true (`find_or_create_by` then `update!`); the requirement is that
  the step must not add a check that turns a no-op write into a failure.
- **R4.** The step performs no host check of its own. Like every sibling step it assumes the pipeline
  ran `validatePortalHost` before the loop and uses `StepContext.portalOrigin` for every portal call,
  never the raw `jobDoc.platform_id`.
- **R5.** Portal failures are classified through the existing `classifyPortalFailure` /
  `messageForBucket` path, so a 4xx gives tell-your-teacher and a 5xx or network fault gives the
  retryable message.

### Choosing the target offering

- **R6.** The target is either the offering the run launched from (`resource_link_id`) or another
  offering identified by an author-controlled name. **No raw offering id appears in authored
  configuration**, because ids differ across environments.
- **R7.** A named target is resolved within the student's origin class, by reading the class through
  the shipped `lookupClassByWord` helper and matching an offering in `offerings[]` by name. The class
  word comes from REPORT-81's `originClassWord` handoff, read from `stepResults` with no ordering
  guard, consistent with how `fall-random-assignment` reads it. Both the class read and the subsequent
  write use the **origin (unscoped) mint**: `classes#info` has no per-class authorization at all, and
  R10 establishes that the same origin token already authorizes the write, so the two calls share one
  cached token and the stage mints once as R11 requires. A `class_id`-scoped mint here would work but
  would add a second mint per run for no gain. `enroll-specified-class` sets the same precedent in a
  comment.
- **R7a.** The name comparison is **trimmed and case-insensitive**, and there is **no activity-URL
  fallback**. This is normalization, not fuzzy matching; R8's more-than-one-match rule is what keeps
  it safe. The comparison **skips any offering whose `name` is not a string**, rather than normalizing
  it. This is not defensive coding against our own configuration: `PortalOffering.name` is declared
  `string` but the wire can carry `null`, since `external_activities.name` is nullable with no presence
  validation (`schema.rb:289-292`, `external_activity.rb:117`), `Offering#name` delegates to it, and
  `lookupClassByWord` hardens the **class's** fields while passing each offering's through raw. Without
  the guard an unnamed **sibling** offering anywhere in the class throws a `TypeError` that the step's
  `catch` turns into the generic retryable message, failing every control student on a condition retry
  cannot fix, while the target itself is present and correctly named. Verified by throwaway test; see
  the Round 4 Senior Engineer finding.
- **R7b.** An absent `originClassWord` handoff, and a class word carrying neither arm suffix, are both
  **permanent classified failures returning the shared `TELL_TEACHER_MESSAGE`**, not the step's own
  generic message and not a default to either arm. Both log at error level: the first naming the
  likely cause (whether `resolve-origin-class` precedes this step in the stage), the second carrying
  the offending class word, which is authored, environment-stable and neither PII nor a token. This
  mirrors `fall-random-assignment.ts:61-77` exactly. **R12's per-step message is the generic-bucket
  fallback for portal failures only**; wiring and configuration failures use `TELL_TEACHER_MESSAGE`,
  because "try again" is false for anything permanent until someone edits code.
- **R7c.** The open path depends on the target offering **existing in the control subclass and being
  held out there by its `locked` flag rather than by absence**. **Confirmed 30 July 2026: the fall
  `-shark` subclasses will carry the curriculum offering, present but locked.** This is a study-setup
  fact the step cannot establish for itself, recorded here because the design rests on it: the per-student
  row this step writes wins over the class-level flag (four consumer sites, see
  [Technical Notes](#the-two-flag-write-is-mandatory-not-defensive)), so writing
  `locked: false, active: true` is exactly what makes a class-level locked target runnable for one
  student.
  Two things follow, both worth keeping visible. First, **a class-level locked offering is still returned
  by the read**: `classes/info` renders `clazz.teacher_visible_offerings`, which filters on
  `runnable.archived?` and nothing else (`clazz.rb:241`), so neither `locked` nor `active` hides the
  target from R7's name match. Second, the surviving absence risk is therefore **archival**, not
  assignment: archiving the curriculum's runnable would remove it from the read and turn every control
  student's post-test into an R8 no-match failure. That is the residual REPORT-82 should carry into its
  pre-launch checks.
  ⚠️ **Archival and a stale `TARGET_OFFERING_NAME` are indistinguishable from the outside**, which is
  what makes the log line load-bearing rather than merely helpful. Both surface as the same R8 no-match
  branch, at the same moment, for the same students, with the same student-facing message. The only
  thing that separates them is the `class_offering_names` list R8's error log carries: the target's name
  present in that list means the constant is right and the runnable was archived out of
  `teacher_visible_offerings`; the target's name absent, with a near-miss beside it, means the constant
  is stale. They have different owners and different fixes, so REPORT-82's pre-launch check should read
  that log line first rather than reasoning from the failure alone.
  Recorded for the reader, since the alternative was live until this was confirmed: had the curriculum
  instead been *unassigned* to the shark class, the name match would have resolved nothing, R8 would have
  failed **every control student** at the post-test, R10's structural guarantee would have had no target
  class to be about, and opening the activity would have meant *assigning* it, a portal operation this
  story neither implements nor scoped.
- **R8.** A target name that matches **no** offering is a permanent, classified failure, never a
  silent skip. A name that matches **more than one** offering is likewise a hard failure rather than
  a first-match guess: offering names are not unique in the portal, and guessing would lock or unlock
  an activity nobody chose.
- **R8b.** All three **target-resolution** failures (R8's no-match and multi-match, and R8a's
  self-target) return the step's **own** `STUDENT_FAILURE_MESSAGE`, not the shared
  `TELL_TEACHER_MESSAGE`. *(Amended after PR #407 review; the three previously returned the shared
  message.)*

  R7b's rule sends permanent configuration failures to the shared message, and the reason it gives is
  that a step's own message promises a retry a permanent fault cannot honour. That reason holds for
  `fall-random-assignment`, whose message says *"please try again"*. It does not hold here: this step's
  message promises no retry (R12), so the two messages both route the student to their teacher and
  differ **only** in the reassurance clause *"Your work has been saved"*, which is true on all three
  branches because a failed lock aborts the pipeline before this step runs. Applying the rule here
  therefore removes a true statement and buys nothing, and substitutes *"Something went wrong setting
  up your class"* for a student who is finishing a post-test.

  The no-match branch is what decides it. It is where R7c's archival risk and a stale
  `TARGET_OFFERING_NAME` both land, it fires for **every** control student at once, and it fires at the
  last event in the study, for students whose work did count.

  **R7b's branches are unchanged** and keep `TELL_TEACHER_MESSAGE`: an absent `originClassWord` handoff
  and a class word carrying neither suffix are mis-wired stages rather than portal misconfiguration, and
  on those branches nothing about the student's work is knowable, so the reassurance would be a guess.
  The rule R7b states is therefore narrowed to what it can support: **wiring** failures take the shared
  message; **portal-data** failures take the step's own, whenever that message makes no retry promise.
- **R8a.** A resolved target whose offering id equals the run's own `resource_link_id` is a permanent,
  classified failure (message per R8b), logged at error level with both ids and the target name. This is a **target-selection** rule, not the pre-write authorization check R10 forbids:
  it does not ask whether the write is permitted, it asks whether the step is about to undo the lock
  the stage just took. The failure mode it forecloses is a module constant naming the sequence the
  stage **locks** rather than the one it **opens**, which writes `locked: false` over the completion
  record the researcher's roster reads (R19), silently, returning success, and on the control arm only.
  It is singled out from R8's general wrong-name handling because it is the one wrong name that is
  **destructive rather than inert**, and because nothing else catches it: the constant is deliberately
  not injectable (see the RESOLVED question on how the step receives its target), so the unit fixtures
  and the harness stub are both configured **from** the constant and therefore agree with whatever
  value it holds. The usual "our own configuration fails on the first harness run" justification does
  not apply here, which is what distinguishes this from the defensive checks this spec otherwise
  declines.
  **R8a is complete, not merely well-motivated, and the argument is short enough to keep here.** The
  class the write lands in holds exactly **two** offerings: the post-test, which is the run's own
  `resource_link_id`, and the curriculum, which is the intended target (R7c, and the study-flow
  document's class table, which gives registration classes the pre-test only and both study classes the
  curriculum and the post-test). So every name that resolves at all resolves to one of those two: one is
  correct and the other is what R8a catches. Every other name matches nothing and takes R8's no-match
  exit. There is no third offering to name, and in particular **no reachable way to unlock the
  pre-test**, which is in a different class. Completeness is therefore a consequence of the class
  composition R7c records; if that composition ever changes, re-run this argument rather than assuming
  it. Compare as strings, per
  [The id forms](#the-id-forms-platform_user_id-and-resource_link_id-are-bare-integers):
  `resource_link_id` is a decimal string and `PortalOffering.id` is a number.
- **R9.** The shared core runs more than once in a stage, through **distinctly named steps**. Entry
  names must be unique within a pipeline; see the RESOLVED question on `stepResults` keying.

### Auth

- **R10.** The write acts as a minted teacher of the target offering's class, satisfied by the
  existing **origin (unscoped) mint**, which the portal resolves to a teacher of the origin class.
  This is a **structural** guarantee, not an observation about class layout: the target is selected
  from the `offerings[]` of the one class `originClassWord` names, so it cannot denote an offering
  outside the class the mint already authorizes. A wrong target name yields zero matches and an R8
  failure, never a cross-class write. **No pre-write authorization check is therefore needed, and
  none should be added.** R8a is not one: it compares the resolved target against the run's own
  offering, which is a question about *which* offering the step selected rather than about whether the
  acting teacher may write to it. The two are compatible because R10's guarantee is about the class
  boundary, and the case R8a catches is **inside** that boundary, where the mint is legitimately
  authorized and the write would legitimately succeed. This guarantee is exactly what the deferred class-word target-class
  derivation would remove: were a target class ever allowed to differ from the origin class, a
  `class_id`-scoped mint would become mandatory, with `oidc_mint`'s 422 "no teacher is shared between
  the origin class and the requested class" as the failure to classify. No cross-class mint is
  introduced by this story.
- **R11.** The step reuses `getScopedPortalToken` with the per-run `tokenCache`, so a stage running
  several offering-state steps mints once.

### Student-facing messaging

- **R12.** Each step carries its own `STUDENT_FAILURE_MESSAGE`, following the convention every other
  step in `ai4vs-flvs/` already uses. Neither may name the pre-test.
  - `lockCurrentOffering`: **"Unable to record that you finished this activity. Please try again or
    contact your teacher."** Retry is honest in the case that dominates: a lock the portal did not apply
    leaves the activity unlocked (R19a), so a re-click retries. It is **not** honest in R19a's stated
    exception, a landed write whose response was lost, where the student is locked out and cannot
    re-click; that is precisely what the second clause is for, and it is why the message routes to the
    teacher as well as to a retry rather than promising only a retry. The message **names what failed**
    rather than saying "unable to finish this
    activity", which was vague about whether the student's answers had been lost. Answers are saved
    continuously by the activity player and are never at risk from this step, so a message that reads as
    a failed submission is both false and counterproductive. Naming the recording is also honest about
    the consequence that matters (R19: the roster's locked checkbox *is* the completion record), and it
    keeps the house-style shape, "Unable to *what this step was doing*".
  - `openTargetOffering`: **"Your work has been saved. We could not open your other activity, so
    please tell your teacher."** No retry promise, because by the time it runs the student has been
    locked out by the preceding step and cannot re-click. The reassurance is **not speculative**: a
    failed lock aborts the pipeline before this step runs, so whenever this message is produced the
    completion has already been recorded on the roster. Without it the message is indistinguishable
    to the student from a failed submission, which prompts a re-click they are locked out of and a
    teacher contact that contradicts what the roster shows.
  - **Why only one of the two carries a reassurance clause.** The shapes differ deliberately, and the
    asymmetry is not an oversight carried over from Round 1. On the open path nothing needs redoing, so
    "Your work has been saved" is unambiguous and the message's only job is to route the student to
    their teacher. On the lock path something *does* need redoing, so the same clause would compete with
    the retry instruction and risk suppressing the re-click that R19a says is what heals the failure.
    The lock path solves the same misreading by being **specific** instead of reassuring.

### Verification

- **R13.** Unit tests cover: the two-flag body for lock and for unlock, the current-offering target,
  a named target resolving to the right offering id, trimmed and case-insensitive matching, the
  no-match and multiple-match failures, the treatment no-op, an unclassifiable class word, and each
  classified failure bucket. Added by the self-review: **R2a's determinism**, that the open path's body
  carries `active=true` even when the class body it just read reports the target as hidden or as
  carrying a contrary per-student row, which is what pins the Round 2 decision against a future
  reviewer reinstating an echo; **R7b's absent-handoff failure**, asserting the shared
  `TELL_TEACHER_MESSAGE` rather than the step's own; **R8a**, that a target resolving to the run's own
  offering fails with no `PUT` issued at all, asserted with the ids in their real forms (a decimal
  string `resource_link_id` against a numeric fixture offering id) so the comparison's coercion is
  covered too; and **R19a's assertable half**, that a failed write is issued **exactly once** and not
  retried, so the step leaves portal state untouched by anything it did after the failure. Reworded in
  Round 5: this case previously read "that a failed lock leaves the offering unlocked", which a unit
  test cannot assert, since it drives the step against a mocked `portalTokenFetch` and has no portal
  whose resulting state it could inspect. The one-write property is what the step actually controls and
  is the whole of its contribution to R19a; the rest of R19a is a portal fact, verified against rigse in
  the Technical Notes.
  Added by Round 5: **R16's no-match diagnostic**, that the no-match failure logs the class's offering
  **names**, driven against a multi-offering fixture, asserted alongside the existing R13b check that the
  same log carries no student or teacher name and no foreign `user_id`. The two assertions belong on one
  fixture because they are the two halves of R16 and it is their combination that is easy to get wrong.
  Added by Round 4: **R20's defensive read**, that a 2xx with a **null body** still returns success
  *and still emits the log*, which is the only shape that discriminates a bare property access from a
  guarded one (the existing 204 test pins the return value only, so it passes a step that throws in its
  log line); and **R7a's non-string name**, an unnamed **sibling** offering beside a correctly named
  target, asserting the target still resolves, since the null name is what the shipped mapper passes
  through into a field declared `string`.
- **R13a.** The migration **updates** `lock-activity.test.ts`'s existing exact-body assertion rather
  than adding a test beside it, and that assertion is a **build-breaking dependent**: it pins the whole
  request object including `body: "locked=true&user_id=27"`, so adding `active=true` fails it. Verified
  by making the change (`Tests: 1 failed, 10 passed`). No spring-**specific** assertion is needed, and
  one should not be added: after the migration both cohorts run one handler, differing only in entry
  `name` and `processingMessage`, so spring's write and the fall lock write are the same request already
  covered by R13's two-flag case. This requirement previously claimed the suite "would otherwise stay
  green through the change", inherited from REPORT-81's precedent where that was true; here the exact
  assertion makes it false, and the correction is kept visible because the wrong version invites writing
  a redundant test.
- **R13b.** A test asserts R16: driven against a class body carrying real teacher names and populated
  per-student metadata, neither the step's logger calls nor its `StepResult` contain any student or
  teacher name, **nor any `user_id` other than the acting student's own**, on the success, no-match and
  self-target paths. The `user_id` half is not redundant with the name half and cannot be folded into
  it: `metadata[]` contains **no names at all**, so a name-only assertion passes even if the entire
  array is dumped, which is precisely the leak R16's `metadata[]` clause exists to prevent. Use a
  sentinel `user_id` on the other students' rows so the assertion fails loudly rather than by absence.
  Follows the never-log-a-token precedent in `portal-api.test.ts`.
- **R14.** A harness scenario drives **`openTargetOffering`** twice against one `StepContext` via
  `harness/im-done-local/run-step.js`, following the precedent set for `enroll-specified-class`. That
  step is chosen over `lockCurrentOffering` because it carries everything new (the class read, name
  matching, arm classification, the handoff dependency) and
  because no wired pipeline reaches it until REPORT-82, which is the case `run-step.js` exists for.
  What running twice actually asserts is **safe re-entry**: the second run enters the step with a
  populated `tokenCache` and an **accumulated** `stepResults`, and the driver checks success and the
  summary on both runs. Nothing else verifies re-entry at all, which is why the shape is kept.
  **"Accumulated" is a third piece of driver work, not a description of what happens today.**
  `run-step.js` builds its context once (line 78) and never assigns into `context.stepResults`, where
  `index.ts:81` does exactly that after every step. So as it stands the only state differing between the
  two runs is the token cache, and whatever R14's seeding requirement puts in `stepResults` is identical
  on both. The driver must write each run's result back under the scenario's step name, which is one
  line, makes the claim above true, and makes the harness model the real runner rather than diverging
  from it. Stated because R14 has twice been corrected for claiming more than the harness delivers, and
  the cheap fix here is to make the harness deliver it. Two claims this
  requirement previously made are withdrawn, both corrected in Round 4. **Token reuse is manual
  inspection, not an assertion**, for the same reason R14a's absent `PUT` is: a cache hit shows up as the
  absence of a second mint line in the stub's stdout, a separate process, while `checkRun` inspects only
  the returned `StepResult`. Look at the mint-line count. And the run **does not exercise R3's
  idempotency**: the stub holds no state (`lockResponse` returns a hardcoded body and never records the
  request), so "the same values against unchanged stub state" is vacuous. R3's guarantee is the portal's
  `find_or_create_by` then `update!`, verified against rigse in the Technical Notes, which is the only
  evidence available and does not need the harness.
  This requires **driver work, not just a scenario**: `run-step.js` hardcodes the enroll step's module
  path (line 17), its export name (line 68), and `stepResults: {}` (line 40). It needs per-scenario step
  selection and the ability to **seed the `originClassWord` handoff**, without which R7b's
  absent-handoff failure fires on every `openTargetOffering` scenario, since this step takes its input
  from a handoff where the enroll step took its own from a request param. The harness README's
  "Extending it for the fall stories (REPORT-80/82)" section concludes that no plumbing changes are
  needed, which is true of the stub and misleading about the driver; fix that section while this story
  is in there.
- **R14a.** A separate scenario covers the **treatment no-op**, asserting success and a summary saying
  nothing was done. The absent `PUT` is **manual inspection, not an assertion**: `run-step.js` checks
  only the returned `StepResult`, and the stub's request log is a separate process (terminal 2 in the
  README's run instructions), which is the same limitation the README already records for everything it
  shows rather than asserts. The machine-checkable version lives at the unit level, where R13 asserts no
  `PUT` is issued for the treatment no-op and for R8a. What the scenario does assert is success and the
  did-nothing summary, which a step that had issued the write would not produce.
- **R15.** The harness stub must serve a class with **more than one offering**, so that a by-name
  match proves it selected the right offering rather than the only one. `stub-portal.js` currently
  serves exactly one offering per class, named `"Origin Offering"` / `"Destination Offering"` from
  `config.js`. One of the offerings it serves must be named **exactly the module constant**, or the
  by-name match resolves nothing and every `openTargetOffering` scenario fails.
  The fixture string stays a literal in `config.js`, beside the class words, and **a unit test asserts it
  equals the exported constant**. That gives the same rename protection as having the stub import the
  compiled constant, at none of the cost: `stub-portal.js` requires only `http`, `fs`, `./config` and
  `./scenarios` today, so importing from `lib/` would give the stub its first dependency on a build, in
  the process the README says to start **first**, with no equivalent of `run-step.js`'s
  `existsSync` guard and its "Run: `npm run build`" message. The desync risk is real and the operational
  cost is avoidable, so it moves to the unit level where every other check in this story lives.
  Note the limit that survives all of this: because the fixture is configured
  **from** the constant, the harness can prove the matching logic works but never that the constant
  names the right real-world activity, which is the gap R8a exists to contain.
- **R15a.** ~~The stub's target offering carries a populated `metadata[]`.~~ **Withdrawn in Round 2**,
  along with the echo it existed to make observable. Its fixture placed an `active: false` row on the
  harness student, a state the fall study never produces, purely so a correct echo and a
  default-to-`true` implementation could be told apart. With R2 sending `active: true` unconditionally
  there is nothing to tell apart, and the stub's `metadata: []` is both realistic and sufficient. The
  residual obligation is R13's determinism case, which is cheaper at the unit level than in the
  harness: the stub would have to serve a contrary row *and* the driver would have to surface the
  request body to assert the write ignored it, which is the same limitation R14a runs into.
- **R15b.** The stub must also serve a class whose **word carries the control (`-shark`) suffix**, and it
  is that class which carries the multi-offering list R15 requires. Otherwise every
  `openTargetOffering` scenario fails at R7b's suffix check, before the mint, the class read and the name
  match, and reports a passing tell-your-teacher while the matching logic R15 exists to prove never runs.
  Verified: the harness knows exactly two class words, `fl-spring-2026-origin` and `ft-fall-2026-a`, and
  **neither carries either arm suffix**. R14a's treatment scenario needs a third word ending `-gator`,
  which needs no class fixture at all, since R1b makes the arm check short-circuit before the class read.
- **R15c.** The stub's `update_student_metadata` must **log `active` alongside `locked`** and **echo the
  request's flags** instead of returning a hardcoded `{active: true, locked: true}`. Both are one-line
  changes and both are needed for the manual inspection R14 and R14a designate as their coverage: today
  `logFields`'s `lock` case omits `active`, so R2's two-flag write, the story's central correctness
  requirement, cannot be confirmed from the log however carefully it is read; and the hardcoded response
  makes R20's success log report `locked: true` for the open path's `locked: false` write, a diagnostic
  that states the opposite of what the step did, in the place a developer reads it first. Verified live
  against the running stub.
### Privacy

- **R16.** The step must never log, and never place in `StepResult.summary` or `message`, the
  `students[]` array from an offering read or the `teachers[]` array from a class read. Both carry
  **real names**: `offerings#show` anonymizes only when the caller lacks full access to student data,
  and a minted teacher of the class has it; `classes/info` anonymizes students but not teachers, a
  rule `portal-reads.ts` already documents for `PortalClass.teachers[]`. A step's `summary` names
  the offering and the flags it wrote, nothing else.
  **Clarified during implementation: this constrains what a `summary` may contain, and does not
  require that one exist.** `lockCurrentOffering` returns bare `{ success: true }` with no summary,
  as the shipped `lock-activity` does. It never reads the class, so it holds the offering **id** and
  not its **name**, and `send-email` already prints `Offering: <resource_link_id>` in its header, so
  the only summary available to it would repeat an id already on the page. Keeping the step silent
  also leaves spring's teacher-email line byte-identical (`- lock-activity: completed`, via
  `send-email.ts`'s `result.summary ?? result.message ?? "completed"`). `openTargetOffering` does
  carry a summary, because the class read gives it the name. Diagnostic logs carry the offering id, the
  offering name, and the resolved class word, all authored and environment-stable. This matters most
  on the R8 no-match branch, which is both the branch someone will reach for when diagnosing a
  launch-day failure and the one holding the whole class body.
  **On that branch the allowance explicitly extends to the class's offering *names***, and this is
  stated rather than left to be inferred, because the rest of this requirement is a prohibition and a
  conservative reader would otherwise log nothing off the class body at all. Without them the branch can
  only log "no offering named X in class Y", which is identical whether the constant is stale after a
  portal-side rename, the student launched from the wrong class, the target's runnable was archived out
  of `teacher_visible_offerings` (the residual R7c hands REPORT-82), or the class was built without the
  target. With them it reads "looked for X in class Y, which holds [A, B]", which separates all four at a
  glance and costs no second request. Names only, never the offering objects, which would drag
  `metadata[]` along; the names carry the same properties this requirement already accepts for the
  singular target name it permits, being authored, environment-stable, and neither PII nor a token.
  Also never log, and never place in a `StepResult`, an offering's **`metadata[]`**. It is a different
  category from the two arrays above and is called out separately for that reason: it carries no names,
  only integer `user_id`s and two booleans, so the concern is **scope** rather than identification.
  `classes/info` builds it with no user filter (`classes_controller.rb:151-153`), so it is every student
  in the class and their lock and visibility state, and the step holds it for every offering in the body
  it reads for the name match. One student's own id in a log line is established practice and R20
  requires it; the whole class's progress roster is not, and reaching it is an accident of dumping the
  class body while diagnosing an R8 no-match or an R8a self-target. Withdrawing R17 helps here, since an
  `unknown[]` is less inviting to interpolate than a typed row.

### Changes to files this story does not otherwise own

- **R17.** ~~`PortalOffering.metadata` is narrowed from `unknown[]` to the row shape `classes/info`
  returns.~~ **Withdrawn in Round 2.** Its only stated justification was type-checking R2a's lookup,
  and after that decision **nothing in this story reads `metadata[]`**, so the narrowing would be a
  change to a file this story does not own with no caller to justify it. Leaving the field `unknown[]`
  is also the mildly safer outcome for R16, since an opaque array is less inviting to interpolate into
  a diagnostic log than a typed one. Revisit if the deferred hide capability ever needs to read
  per-student state.
- **R18.** The arm-suffix literals move from the private `DESTINATION_SUFFIX` in
  `fall-random-assignment.ts` to `fall-programs.ts`, where the suffix-to-arm classifier also lives,
  and `fall-random-assignment` imports them from there. **Both directions must share one source of
  truth**: a divergence would classify a `-shark` student as treatment at the post-test stage and
  silently withhold the curriculum they are entitled to. This is the layering REPORT-81 established,
  shared modules owning class-word interpretation and step files importing from them rather than from
  each other. A test asserts the two directions round-trip. Note `fall-random-assignment`'s header
  already warns that these strings are data rather than labels.

### Failure severity

- **R19.** The two operations have **different failure severities**, and this asymmetry governs
  trade-offs elsewhere in the epic. A **failed lock is a data problem**: the researcher tracks
  completion from the portal's teacher progress roster, whose per-student locked checkbox is the
  completion record, and her manual post-test opening is gated on it, so an unlocked student reads as
  "not finished" and is passed over. A **failed open is an experience problem**: the student's
  completion is already recorded by the preceding lock, and the researcher opens sequences by hand
  regardless, so what is lost is automation and a correct-looking end to the student's session.
  Neither failure corrupts stored study data: assignment records, answers and enrolment are untouched
  by this step.
- **R19a.** A lock that **the portal did not apply** leaves the offering unlocked and therefore
  re-clickable, which is what makes that case self-healing. Every claim about the lock's recoverability
  rests on this. The step contributes to it by issuing **exactly one** write and never retrying, so a
  failure leaves portal state untouched by anything the step did after it.
  **The guarantee is not universal, and the exception matters because it lands in the retry bucket.**
  A write the portal *did* apply, whose response was then lost, leaves the offering **locked** while the
  step reports failure: a thrown fetch is classified `status: 0`, and `classifyPortalFailure` routes
  anything that is neither a 4xx nor a mint-422-expired to the generic bucket, which renders R12's
  "Please try again". A landed lock makes the activity unreachable (`offering_policy.rb:60-68` returns
  `!locked` for the student, `runnables_helper.rb:30-38` disables the run button), so the student cannot
  re-click and the retry advice is dead. There is no transport-level retry or timeout to change this
  (`portal-api.ts:25-34` is a bare `fetch`). The three ways to reach it are a proxy 502/504 after Rails
  committed, a dropped connection after the request was processed, and a function timeout.
  This is **accepted rather than fixed**: detecting it would need a read-back that R3 forbids, the
  outcome is bounded (the roster is correct, so the completion is recorded), and R12's second clause,
  "or contact your teacher", is what covers it. Recorded because R12's honesty argument cites R19a, and
  because REPORT-82's ticket already records the same end state as a known residual on a different path
  ("they cannot retry because they are locked out"), so the two stories should not disagree in writing.

### Observability

- **R20.** On success the step logs the `{active, locked}` the portal returned, alongside the offering
  id and the student's `user_id`. **The returned body is read defensively (`response.data?.active`),
  because a 2xx with no body is a supported success** and a bare property access on it raises inside
  the step's `try`, where the step's own `catch` converts it into a student-facing failure *after the
  write has already landed* (see the Round 4 Portal API finding, which reproduced exactly that). This
  is the one place in the story where a logging line can invert the outcome, so it is stated as a
  requirement rather than left to the implementer. The step does **not** compare that against what it requested: R3
  forbids adding a check that could turn a no-op write into a failure, the existing "any 2xx succeeds
  regardless of body" behaviour is deliberate and tested (a 204 with a null body passes today), and
  the one bug a comparison would catch, a silently dropped parameter under strong params, is already
  caught at build time by R13's exact-body assertion. The log exists so "was this student actually
  locked?" can be answered from our logs rather than only from the portal roster. The body carries two
  booleans and no names, so R16 is unaffected.

## Technical Notes

Everything in this section was verified against the rigse checkout at commit `6f4c49288` and, where
noted, by a throwaway jest test driven against the shipped helper. The throwaway was deleted after it
passed; its six assertions are reproduced as claims below.

### The endpoint

`PUT /api/v1/offerings/:id/update_student_metadata`, routed at `rails/config/routes.rb:399`,
implemented at `rails/app/controllers/api/v1/offerings_controller.rb:53`.

- **Authorization**: `authorize offering, :update?` resolves to
  `Portal::OfferingPolicy#update? -> class_teacher_or_admin? -> record.clazz.is_teacher?(user)`
  (`rails/app/policies/portal/offering_policy.rb:83,120,128`). A teacher who does not own the
  offering's class gets 403, asserted in
  `rails/spec/controllers/api/v1/offerings_controller_spec.rb:493`.
- **Permitted params**: `:active` and `:locked` only (`offerings_controller.rb:211`), plus `user_id`
  read directly and the offering id from the path.
- **Student membership**: the target user must be in `offering.clazz.students`, else 404 with
  `"student not found in the class"`.
- **Idempotency**: `UserOfferingMetadata.find_or_create_by(user_id:, offering_id:)` followed by
  `update!`. Re-sending identical values is a 200 no-op, so R3 needs nothing on the portal side.
- **`platform_user_id` is the portal user id**, in the bare integer form and never a URL. See
  [The id forms](#the-id-forms-platform_user_id-and-resource_link_id-are-bare-integers) below, which
  R2a's row lookup depends on. `lock-activity` already passes it straight through as `user_id` and the
  spring pilot shipped on that.

### The id forms: `platform_user_id` and `resource_link_id` are bare integers

Portal responses carry user identity in **two** forms side by side: `teachers[].id` and `students[].id`
are URLs (`"https://learn.concord.org/users/7"`) while `user_id` is the integer. Within a single
`classes/info` body both appear, on different fields. Only the integer form ever reaches
report-service as `platform_user_id`, and `metadata[]` rows carry only that form.

The portal sets it from `current_visitor.id` at launch
(`portal/offerings_controller.rb:68`, where `current_visitor` is `current_user || User.anonymous`),
echoes it as `user.id` in the JWT claim (`jwt_controller.rb:219`), and, decisively, resolves it with
`User.find_by(id: claims['platform_user_id'])` in `ForwardedFirebaseToken#verify`
(`forwarded_firebase_token.rb:35`), which `oidc_mint` calls before minting anything. A URL there
would fail **every** mint with `reason: "user_unresolved"` before any of this story's code ran, so the
pipeline's own working mints are a standing proof of the form. `resource_link_id` is the bare offering
id on the same basis: `@offering.id` at launch, `Portal::Offering.find_by(id:)` on the way back in
(`jwt_controller.rb:79`).

Verified against six real `spring-2026` job documents in `report-service-dev` (fake dev users on the
staging portal): every `platform_user_id` is a decimal string (`'27'`, `'199'`, `'408'`, `'419'`,
`'420'`, `'421'`) and `resource_link_id` is `'1194'`. Five of the six reached
`"Done! Your teacher has been notified."`, which `index.ts` emits only after all four spring steps
succeed, so the portal accepted that form on the live `update_student_metadata` write and
`User.find(params[:user_id])` takes a decimal string.

**Why this is recorded even though Round 2 deleted the lookup it was written for**: the write still
sends `user_id: String(platform_user_id)`, so the form matters for the request body; `resource_link_id`
is the offering id the lock path puts in the request path and that any same-offering guard would compare
against; and the number-versus-decimal-string boundary is the trap waiting for the next reader of
`metadata[]`. Whatever bridges it should coerce with `String()`. No URL parsing is needed anywhere, and
none should be added.

### The two-flag write is mandatory, not defensive

`user_offering_metadata` (`rails/db/schema.rb:1609`) defaults `active` to **true** and `locked` to
**false**. Every consumer resolves the effective state as "the row wins **if a row exists**", not
"if the value is non-null":

| Site | Flag |
|---|---|
| `app/policies/portal/offering_policy.rb:62` (student `show?`) | `locked` |
| `app/helpers/runnables_helper.rb:31` (student run button) | `locked` |
| `app/models/portal/offering.rb:52` (`active?`) | `active` |
| `app/models/portal/clazz.rb:251` (`student_visible_offerings`) | `active` |

So a PUT carrying only `locked` **creates a row whose `active` is the column default `true`**, which
silently overrides a class-level `active: false`. Row creation becomes a visibility side effect. This
is harmless while nothing in the study hides at class level, but it is a live trap the moment
anything does. The portal's own teacher UI works around exactly this and says so in a comment:

> `// note: when updating active or locked, we need to pass the other value as well`
> `// as it may be set based on the offering state in the UI and not yet set in the database`
> (`rails/react-components/src/library/components/common/offering-progress/offering-progress-row.tsx:35`)

**What Round 2 changed about this section's force.** The row-creation side effect above is a hazard for
a caller that wants to preserve visibility, and it is exactly what `openTargetOffering` now does *on
purpose*: making the target visible is the step's purpose, not a side effect of it. So for this story
the section no longer argues "send both flags to avoid accidentally forcing `true`". It argues the
strictly stronger point that survives either decision: **send both flags so the resulting state is
determined by the request rather than partly inherited.** The case that shows the difference is a
student who already has a row with `active: false`. There, omitting `active` leaves the row hidden
(`update!` writes only the keys it is handed) and the unlock accomplishes nothing, while sending
`active: true` makes the target reachable. Row creation and row update need the same body for the same
reason.

### Reading the class, and what already comes back

`GET /api/v1/classes/info?class_word=<word>` (`classes_controller.rb:58`) has **no `authorize`
call**, so any valid teacher token suffices, and it hardcodes `anonymize=true`. Its `get_info` body
(`classes_controller.rb:150`) renders each offering as:

```
{ id, name, active, locked, metadata: [{user_id, active, locked}, ...], url, external_url }
```

`lookupClassByWord` in `functions/src/tasks/portal-reads.ts` already maps all of that into
`PortalOffering` (`id`, `name`, `active`, `locked`, `metadata: unknown[]`, `offeringApiUrl`,
`activityUrl`). **Verified by throwaway test**: a three-offering `get_info` body round-trips through
the shipped helper with every field a by-name match needs; the by-name filter selects exactly one of
three; and both the activity URL and the offering API URL are present on the same body, so an
activity-URL fallback needs no extra call. So this story adds **no new portal surface at all**, and
after R17's withdrawal it needs **no change to `portal-reads.ts` either**: the by-name match lives in
the step. One caution the shipped mapper does impose on that match is recorded in R7a, namely that it
validates the class's own fields but passes each offering's `name` through raw, so the declared
`name: string` can be `null` on the wire.

Three cautions on that body:

1. **`metadata[]` is the whole class's rows, not this student's.** Verified by throwaway test. **No step
   in this story reads it** (R2a, R17), so this is recorded for the deferred hide capability and for
   R16, which forbids logging it. Any future consumer must filter by `user_id` and must do so across a
   type boundary: the row's `user_id` is a JSON number while `platform_user_id` is a decimal string, so
   the comparison has to coerce. That trap is what the Round 2 review found before the echo was
   removed, and it is worth keeping written down because the next reader of this array will hit it.
2. **`get_info` uses `clazz.teacher_visible_offerings`, which excludes offerings whose runnable is
   archived** (`clazz.rb:242`). An archived target is invisible to the name match, and R8 turns that
   into a tell-your-teacher failure rather than a silent no-op, which is the right outcome.
3. **There is no id-keyed equivalent that is cheaper.** `classes#info` requires `class_word`
   (`params.require`). `GET /api/v1/classes/:id` does exist and renders the same body, but it
   authorizes `api_show?` **and de-anonymizes student names** when the caller has full access, so it
   returns strictly more PII than `info` for no gain. This is why R7 resolves by word: it is the
   route with an existing helper, an existing handoff, and the least PII.

### Auth: why no cross-class mint is needed

`API::V1::OidcMintController#resolve_teacher` resolves a `teacher` mint with **no `class_id`** to the
least-privileged teacher of the **origin class**, and one with a `class_id` to a teacher shared
between the origin and target classes (422 if none). Since the surviving open-target caller's target
lives in the class the student launched the post-test from, the origin mint is already a teacher of
the target offering's class and `class_teacher?` passes. `lock-activity` already uses the origin
mint, so R10 is satisfied by the code as it stands.

### The step-parameterization problem, and the shape it resolves to

`StepHandler` takes only a `StepContext`; there is no per-entry configuration channel, and
`PipelineStep`'s shape has not changed since REPORT-64 created it. There is no
factory-returning-handler anywhere in `functions/src`.

REPORT-81 answered this same question for the randomization step and shipped the answer: **a
parameterized shared core with thin, zero-config named steps over it**. `readDemographics(request)`,
`getAlternatingAssignment(...)` and `perClassScope(...)` take arguments; `randomAssignment` and
`fallRandomAssignment` take none and simply supply them. Its recorded rationale applies verbatim
here: "the premise behind [in-place generalization], that a step must work out at run time which path
it is on, is false ... `PIPELINES[request.pilot]` already selects a different step list."

This story follows that shape. See the RESOLVED question below.

### The duplicate-name collision is real

`index.ts:81` does `stepContext.stepResults[step.name] = result`. Two pipeline entries sharing a
`name` lose the first result. That matters twice: `readStepOutputField` scans `stepResults` values,
and `send-email` builds the teacher email body as one line per step name
(`send-email.ts:30-33`), so the researcher's notification would silently lose a line. The post-test
stage runs this step twice, so this is not hypothetical.

### The study's three sequence names

The fall sequences follow one naming convention, `<Colour> Sequence for AI in Math (FLVS 26-27)`. All
three are recorded, not just the target, because R8a's whole subject is a constant naming the wrong one
of the pair in the study class, and a reviewer checking the constant needs to see what it could be
confused with.

| Name, verbatim | Authoring id | Role | Lives in |
|---|---|---|---|
| `Green Sequence for AI in Math (FLVS 26-27)` | 838 | pre-test | registration classes |
| `Blue Sequence for AI in Math (FLVS 26-27)` | 845 | curriculum | `-gator` and `-shark` study classes |
| `Orange Sequence for AI in Math (FLVS 26-27)` | 844 | post-test | `-gator` and `-shark` study classes |

`openTargetOffering`'s constant is **Blue**. `Orange` is the offering the post-test stage locks and is
therefore exactly what R8a exists to reject; `Green` is unreachable from the name match, since it is in a
different class (see R8a's completeness argument).

**The three sequences now exist and these names are read off authoring, not projected from a
convention.** Taken from `https://authoring.concord.org/api/v1/sequences/<id>.json` on 2026-07-30, ids
as tabled above. Their **contents are still in flux**; the **names are settled**, which is the only
property this story depends on.

**⚠️ Two of the three carry a trailing space**, `Blue` and `Orange`, verified with `od -c` rather than
read off a rendering, which is the one place a difference like this is visible. They are tabled trimmed,
and the constant is written trimmed, because **R7a already requires the comparison to be trimmed and
case-insensitive**, so the space is absorbed on both sides. This is worth recording rather than quietly
normalizing away: it is exactly the difference that survives every review, and if R7a's trim is ever
narrowed to an exact match, the constant breaks against a name that still looks identical.

**⚠️ The earlier projection was wrong in every component**, which is the point of reading the values
rather than deriving them. This section previously applied a `<Colour> Sequence (AI in Math Fall <year>)`
convention forward from the fall 2025 sequences and recorded `Blue Sequence (AI in Math Fall 2026)`. The
real names differ in the connective (`Sequence for AI in Math` rather than `Sequence (AI in Math`), in
the cohort token (`(FLVS 26-27)` rather than `Fall 2026`), and in the trailing space. Only the leading
colour survived. A constant built from the projection would have matched nothing.

**Residual, and it is not closed by the above**: these are **sequence titles from authoring**, whereas
R7 matches an **offering name from the portal**. An offering's name derives from its runnable, but that
the portal copies the title through unchanged is an inference, not something this repository or the
authoring API can establish. The pre-launch check below therefore stands as written, narrowed to that one
question rather than to the whole name.

Two consequences, both worth stating because the Q1 decision weighed a module constant against an
authored override on the assumption that a wrong constant was an unlikely mid-flight event. The
projection having been wrong in every component is the evidence that it is not: the constant was
already wrong, and would have stayed wrong through launch.

1. **The decision itself still holds.** An authored `target_offering_name` override does not help: fixing
   the name by editing the constant and deploying is the same work as authoring an override, and the
   override adds the second source of truth the Q1 decision declined. A hatch pays off only when a deploy
   is impossible, which is not this case.
2. **A pre-launch check is therefore mandatory rather than prudent, and belongs in REPORT-82's
   pre-launch checks beside R7c's archival residual.** Now narrowed by the names above, which close the
   authoring half: confirm the exported constant matches the **Blue offering's name as the portal serves
   it**, modulo the trim and case folding R7a applies. Reading the sequence title settles what authoring
   holds, not what `offerings#show` returns, and the two are the same only if the portal copies the
   runnable's name through unchanged. Nothing else can catch a mismatch: R15 records that the unit tests and the
   harness are both configured **from** the constant and so agree with whatever value it holds, and the
   only run-time signal is R8's no-match failure, which fires solely when a **control** student finishes
   the **post-test**, the last event in the study. A wrong constant is therefore invisible until the
   study is nearly over and then fails the entire control arm at once, which is the same shape and the
   same detection lag as the archival residual it sits beside.

### Files this story touches

Rewritten in Round 4 from the resolved decisions, having drifted out of step with them in six ways.

**New files**, following REPORT-81's core-in-its-own-module layout: `offering-state.ts` (the shared
core), `lock-current-offering.ts` and `open-target-offering.ts` (the two steps), plus their tests.

**Renamed away**: `functions/src/tasks/ai4vs-flvs/lock-activity.ts` and `lock-activity.test.ts`, as a git
rename. Not "likely renamed": the migration decision settles it.

**Edited**:
- `index.ts` (import and the `spring-2026` entry's handler).
- `index.test.ts` (`jest.mock("./lock-activity", ...)` is keyed on the module path, so this is
  **build-breaking**, not cosmetic; it takes all four orchestrator tests with it until repointed).
- `lock-current-offering.test.ts`'s inherited exact-body assertion (R13a: **updated**, not supplemented).
- `fall-programs.ts` (R18: receives the arm-suffix literals and the suffix-to-arm classifier) and
  `fall-random-assignment.ts` (R18: imports them from there instead of holding a private copy).
- `functions/harness/im-done-local/`: `config.js` (R15b's `-shark` and `-gator` class words, R15's fixture
  offering name), `stub-portal.js` (R15's multi-offering class, R15c's log and echo), `scenarios.js`
  (the `openTargetOffering` and treatment-no-op scenarios, **plus two edits to existing scenarios**, see
  below), and `run-step.js`, which is **driver work, not just a scenario**: per-scenario step selection,
  the ability to seed the `originClassWord` handoff, and the `stepResults` write-back, per R14.
- `scenarios.js`'s two **assertion-breaking** strings, called out separately because the additive work
  above hides them: `lock-server-error` and `lock-network` both assert
  `messageIncludes: "Unable to lock your pre-test"`, which R12 replaces, and `run.js:98` asserts that
  substring. After the migration these two plus `lock-forbidden` are the **only** end-to-end exercise of
  the migrated lock step, since R14 and R14a both drive `openTargetOffering`, so leaving them red would
  leave the migrated step with no working harness coverage at all. Their three
  `failsAt: "lock-activity"` labels are cosmetic by comparison (`run.js:109-111` prints `failsAt` rather
  than asserting it) and can ride along with the rename or not.
- `enroll-specified-class.ts:72`'s comment ("Like lock-activity / send-email, this step makes NO host
  check of its own"), cosmetic, listed so a reader can tell it was considered rather than missed.
- `functions/harness/im-done-local/README.md` (R14: its "Extending it for the fall stories
  (REPORT-80/82)" section concludes that no plumbing changes are needed, which is true of the stub and
  misleading about the driver).

**Deliberately not touched**, recorded so the rename is not over-scoped: `portal-reads.ts` (R17
withdrawn, and R7a's guard lives in the step), `send-email.test.ts`'s six `"lock-activity"` strings
(`stepResults` keys, and spring keeps that entry name), and `functions/README.md:77` (prose about the
emulator's OIDC token).

## Out of Scope

- **The hide / visibility capability**, meaning the ability to write `active: false`. No caller, and
  contraindicated by the study design rather than merely unused: control students must still see both
  sequences and be unable to run them. R2's two-flag write is not this. It writes `active: true` on
  every call, so it can only ever make a target reachable, never hide one; the core accepts `active`
  as an argument precisely so that adding a hide caller later needs no change to it. Note this is a
  narrower exclusion than it was before Round 2: the write is no longer "the flag the target already
  has" but an unconditional `true`, which for the open path is the point (see R2) and for the lock
  path is a side effect accepted on cost grounds (see the `active`-value question).
- **Class-word-based target-class derivation** (deriving a target class word by the `-Gator` /
  `-Shark` suffix convention and resolving a *different* class). The one surviving caller's target is
  in the origin class. The match-an-offering-by-name part is still in scope; only the class
  derivation is deferred.
- **Fall pipeline and stage wiring** (REPORT-82). This story ships the steps; it does not add a fall
  `PIPELINES` entry, does not name the fall pilot values, and does not decide step order. It does
  migrate the existing `spring-2026` entry onto the new step, which is a different thing.
- ~~**The control-only arm conditional.**~~ **Now in scope**, and lives inside `openTargetOffering`.
  REPORT-82 therefore does not add a separate differential step; see the RESOLVED question below.
- **Scheduled openings.** The researcher opens the post-test manually on fixed dates; no scheduler is
  built anywhere in this epic.
- **The duplicate `resolveOriginOffering` read in `send-email`.** Known, recorded on REPORT-81, and
  assigned to REPORT-82's stage wiring.

## Open Questions

### RESOLVED: How does the step receive its target and its `locked` value?

**Context**: `StepHandler` takes only a `StepContext`, so there is no per-entry configuration channel
today. Three callers want lock-current with `locked=true`; one wants open-target-by-name with
`locked=false`. Whichever channel is chosen also determines whether adding a fourth caller is a code
change or an authoring change.

**Options considered**:
- A) **Authored request params** (`target_offering_name`, `locked`) read from
  `jobDoc.jobInfo.request`, following `enroll-specified-class`, with **one** generalized step.
- B) **A step factory**: `offeringState({ target: "current" | { name: string }, locked: boolean })`
  returns a `StepHandler`, and `PIPELINES` entries call it.
- C) **Two thin named steps over a parameterized shared core**, mirroring the `randomAssignment` /
  `fallRandomAssignment` pair.
- D) B for the flags, A for the offering name.

**Decision**: **C, with the target offering name as a module constant.** The step library becomes a
parameterized core, `applyOfferingState(context, { offeringId, locked, active })`, plus
`lockCurrentOffering` (target `resource_link_id`, `locked: true`) and `openTargetOffering` (target
resolved by name within the origin class, `locked: false`), neither taking configuration.

**Why not A**: it cannot express the post-test stage. `request` is a single flat blob per launch
(`{ task: string } & Record<string, any>`), so one generalized step reading
`request.target_offering_name` twice reads the same value both times. Driven through a copy of
`index.ts`'s runner loop, both invocations opened the curriculum and **the post-test was never
locked**, which is the one write REPORT-82 cares most about, since the lock is the completion record
the researcher's roster reads. The only recovery is per-instance param keys, which requires the step
to know which instance it is; `StepContext` carries no step name. (A two-step variant of A does work,
but that is C with an authored name, which the module-constant choice below addresses.)

**Why not B**: it introduces a mechanism this codebase does not have, competing against one REPORT-81
deliberately chose, argued and shipped two commits earlier. B remains the better answer if the number
of distinct targets ever grows enough that a per-entry config line beats a per-target exported step.

**Why a module constant rather than an authored `target_offering_name` escape hatch**: the hatch
would be a plain override, not REPORT-79's precedence rule. That rule guards an authored param
against a **per-student runtime handoff**, where "authored wins" would silently defeat randomization
study-wide; a constant has no per-student derivation to defeat, so none of that machinery transfers.
The one real argument for a hatch is that `Portal::Offering#name` delegates to the runnable
(`portal/offering.rb:26`), so renaming the Blue sequence in the portal breaks the constant in all
eight subclasses at once, and the fix without a hatch is a deploy. It was judged not to carry:
because the post-test stage locks before it opens, a stale constant still records completion, so the
loss is the automatic control-only unlock plus a tell-your-teacher message, late in the study, with
time to deploy a one-line change. Against that, a hatch adds a second source of truth in an untyped
blob on a path nothing exercises, which is the same category of thing this story deferred `hide` and
class-word derivation for. Note the precedent hatch has zero production callers: only
`harness/im-done-local/run-step.js` sets `target_class_word`. Add the override when something needs
it, with a caller and a test that mean something.

**Recorded for the reader**: the constant's module carries a comment saying the value is the
runnable's name and that a portal-side rename requires a report-service deploy.

**AMENDED 30 July 2026: the constant names a resource that does not exist yet.** The fall 2026 sequences
have not been authored; the value comes from the naming convention applied forward, confirmed against the
fall 2025 sequences. See [The study's three sequence names](#the-studys-three-sequence-names).
**The decision above is unchanged**, and the reasoning that survives is the part about *cost*: an
override does not beat a one-line constant edit when a deploy is available, and it still adds the second
source of truth this decision declined. What the amendment changes is the emphasis. "With time to deploy
a one-line change" assumed someone would *know*, and nothing tells them: the fixtures are configured from
the constant, so the only signal is R8's no-match failure at the very last event in the study. The
mitigation is not the hatch, it is the pre-launch check now recorded in the Technical Notes for
REPORT-82 to carry.

---

### RESOLVED: How does a step that runs twice in one pipeline key its `stepResults` entry?

**Context**: `index.ts:81` is the single writer (`stepResults[step.name] = result`) and there are five
readers. Two entries sharing a name lose the first result silently, and `send-email` prints one line
per key, so the teacher email quietly loses a line.

**Options considered**:
- A) Require unique `name` values per entry and document the constraint; no code.
- B) A module-load uniqueness assertion over `PIPELINES`, throwing at cold start on a repeat.
- C) Leave it entirely to REPORT-82, which owns the stage arrays.

**Decision**: **A.** The Q1 shape removes every instance of this from the fall flow. Walking
REPORT-82's three stages, the pre-test and curriculum stages contain `lock-current` once and the
post-test stage contains `lock-current` and `open-target`, so no stage repeats a name. That is
structural rather than lucky: the collision existed only because one generalized step had to serve
both roles, and splitting the roles gave them distinct names.

**Why not B**: the standing principle, recorded in `types.ts` and in `enroll-specified-class`'s
header, is that our own pipeline wiring is assumed correct rather than checked with defensive
run-time code. This case has the one property that could earn an exception, since a duplicate name
does **not** fail loudly the way a mis-ordered stage does, but two things outweigh it: the decision
above removes the only known way to reach it, and the consequence is a missing line in an email
REPORT-82 explicitly demoted to secondary once the roster's locked checkbox became the completion
record. **Why not C**: the constraint is a real property of the step library this story builds, so it
belongs in this story's documentation even though REPORT-82 writes the arrays.

**Where it is written down**: alongside the one-producer-per-field invariant `types.ts` already
documents for `readStepOutputField`. The case that would revive this is a future stage needing two
open-targets (open both Blue and Orange), which would need a second constant and a second step, or a
duplicate name.

---

### RESOLVED: What `active` value does a lock-current write send?

**Context**: R2 requires both flags on every write, but the correct `active` value has to come from
somewhere. Nothing in the fall flow hides at class level, so in practice it is always `true`.

**Options considered**:
- A) Always send `active: true`.
- B) Echo the current effective value on both paths.
- C) `true` for lock-current, echoed for open-target.

**Decision**: **C.** The costs are not symmetric between the two callers, which is what decides it.
`openTargetOffering` must read the class anyway for the name match and the student's row is in that
body, so echoing is **free**. `lockCurrentOffering` makes no read at all today, so echoing would cost
an extra `GET /api/v1/offerings/:id` or a cross-story edit to REPORT-81's closed
`resolve-origin-class` step.

**Why not A**: a hardcoded `true` is not a missing capability, it is a latent wrong write. The
implementation note behind R2 exists precisely because creating a metadata row silently forces
`active: true`; hardcoding makes that deliberate rather than accidental without making it correct.
Where avoiding it is free, take it. **Why not B**: `resolve-origin-class` and `send-email` already
read the same offering twice per run, and a third read to preserve a flag nothing writes is a poor
trade. **The moment to revisit**: if REPORT-82 does the tidy-up it inherited (publishing `clazzId`
from `resolve-origin-class` so `send-email` stops re-reading), publishing the student's effective
`active` alongside it makes B free too.

**Note for the fall study**: A and C produce byte-identical writes, since nothing hides at class
level. The whole difference is robustness against a class-level hide the study design excludes.

**AMENDED IN ROUND 2: the decision is now A, `active: true` on both paths.** The reasoning above is
left standing because it is correct about *cost*, and wrong about *direction*, which is the more
interesting error to keep visible.

What it missed: the option-C split assigns the hardcoded `true` to `lockCurrentOffering`, where forcing
visibility is an unrelated side effect of locking, and assigns the echo to `openTargetOffering`, where
making the target visible **is the purpose of the step**. That is backwards. The Background records the
story's own original wording for open as "unlock plus make visible", and the portal makes the stakes
concrete: `student_visible_offerings` (`clazz.rb:245`) and `student_run_buttons`
(`runnables_helper.rb:31`) both resolve row-wins-else-offering, so an offering whose effective `active`
is false is **absent from the student's list entirely**. An echoed `false` would therefore have produced
a step that unlocks nothing reachable, returns **success**, and leaves no diagnostic, which is a worse
outcome than the loud failure R19 assumes when it classifies a failed open as merely an experience
problem.

So "a hardcoded `true` is a latent wrong write" holds for the lock path, where it stays accepted on the
cost grounds above, and inverts on the open path, where the hardcoded `true` is the correct write and
the echo was the latent wrong one.

**What the amendment buys beyond correctness.** Deleting the echo deletes: R2a's row lookup, its
mandatory `user_id` filter, the number-versus-decimal-string trap that filter introduced (found in
Round 2 and fixed before this amendment removed its subject), R15a's deliberately unrealistic stub
fixture, R17's type narrowing in a file this story does not own, and two of R13's cases. Both callers
become uniform, and **the story now reads no per-student state at all**, only offering names.

**Why B is now further away, not closer**: the "moment to revisit" above imagined REPORT-82 publishing
the student's effective `active` to make echoing free. That is no longer a thing to want. The core
still takes `active` explicitly, so the capability is preserved for a hide caller without any of the
reading machinery.

**PII constraint this introduces**: `GET /api/v1/offerings/:id` returns `students[]` with `active` and
`locked` already resolved server-side ("row if one exists, else the offering's value",
`api/v1/offering.rb:47-51`), but it anonymizes names only when the caller lacks full access, and a
minted teacher of the class **has** full access. So `students[]` carries real student names. Anything
reading it must never log it, the same rule `portal-reads.ts` already documents for
`PortalClass.teachers[]`. `classes/info`, which is what `openTargetOffering` actually reads, hardcodes
anonymization and so is the safer of the two.

---

### RESOLVED: Is offering-name matching exact, and is the activity-URL fallback in scope?

**Context**: O11 (decisions-log, 2026-07-21) recorded "match by `name` ... `external_url` fallback".
Three portal facts bear on it: `offering.name` delegates to the runnable
(`portal/offering.rb:26`), so it is a mutable label shared by every class using that activity; the
portal's own within-class offering dedup keys on the **activity URL**, not the name
(`offerings_controller.rb:151`); and there is no unique index on
`portal_offerings (clazz_id, runnable_id)` nor any name uniqueness, so duplicate names are possible.

**Options considered**:
- A) Exact match on the trimmed name, no fallback.
- B) As A, compared case-insensitively.
- C) Name primary, activity-URL fallback, as O11 recorded.
- D) Activity URL primary, name fallback, which is what the portal does for identity.

**Decision**: **B, with no fallback.**

**Why no fallback, against O11**: a fallback means two authored constants to maintain and it fires in
exactly one situation, the name having stopped matching, which is the portal-side rename this spec
identifies elsewhere. There a silent self-heal is worse than a loud failure: someone renamed a study
sequence mid-flight and that should not be discovered from a log nobody reads. The failure being
suppressed is low severity and late in the study, which is what lets it afford to be loud. REPORT-81
rejected loose matching on the same reasoning, that it "trades a loud, diagnosable failure for a
quiet wrong answer". **Why not D**, which is otherwise the cleanest since it uses the portal's own
identity key: it trades a human-readable constant for a long opaque URL whose stability across the
staging and production portals is **unverified** (no real study activity URL is recorded in the repo
or the working notes), and it leaves a reviewer unable to tell at a glance which activity a stage
targets.

**Why case-insensitive**: trimming plus case folding is normalization, not fuzzy matching, and R8's
more-than-one-match rule catches the only pathological case, two offerings differing solely by case,
which then fails loudly rather than being guessed at. The apparent counter-precedent, REPORT-81's
case-**sensitive** class-word decision, points the same way on inspection: it could be exact because
the portal normalizes class words to a stored form. The portal does no such normalization on offering
names, so there is no stored form to match against.

**Confirmed available but deliberately unused**: a multi-activity sequence is one `ExternalActivity`
with a `url` (one offering, one `resource_link_id`, per O1), so `external_url` is populated for
exactly the offerings this story targets. The fallback is technically possible; it is declined, not
unavailable.

---

### RESOLVED: Does the control-only conditional live in this step or in REPORT-82's differential step?

**Context**: REPORT-82 says the runner stays flat and fail-fast, so "encode the conditional inside a
step", and describes a step that reads the arm from the `-Gator` / `-Shark` suffix of the origin class
word and does nothing for treatment. That wording predates the step-shape decision above, so it does
not settle ownership on its own.

**Options considered**:
- A) **REPORT-82 owns it.** This story ships an unconditional `openTargetOffering`; REPORT-82 adds a
  differential step that checks the arm and delegates.
- B) **This story owns it.** `openTargetOffering` classifies the arm and no-ops for treatment.

**Decision**: **B.**

**Why the "keep study semantics out of it" objection no longer applies**: after the step-shape
decision, `openTargetOffering` is already fall-study-specific, since it carries a module constant
naming this study's curriculum sequence. The reusable primitive is `applyOfferingState`, which stays
clean either way. B therefore contaminates nothing generic; it lets the study-specific step express
its study semantics beside the constant it already holds.

**The arm check is free here and only here**: R7 already requires this step to read `originClassWord`
to resolve the target class, so classifying the arm inspects a string it is holding. A separate
wrapper would re-read the same handoff for no other purpose.

**Study-integrity argument**: an unconditional `openTargetOffering` unlocks the curriculum for
treatment students, who completed it and were deliberately locked out at the curriculum stage so they
cannot go back and change answers. A ships that hazard as a standalone step and relies on REPORT-82
always wrapping it; B makes the unsafe form unrepresentable.

**Consequences**:
- **REPORT-82 loses its separate differential step.** Its post-test stage becomes `lock-current` then
  `open-target`, with the conditional inside the latter. This needs recording on that story.
- **The suffix literals must be shared, not retyped.** `fall-random-assignment.ts:23` holds a private
  `DESTINATION_SUFFIX: Record<Arm, string> = { treatment: "-gator", control: "-shark" }` for the
  forward direction. The suffix-to-arm classifier is new; it belongs in `fall-programs.ts` beside
  `classifyFallProgram`, and it must consume that same constant, which means exporting it from a file
  REPORT-81 shipped.
- **A class word with neither suffix is a classified failure**, not a default to either arm, matching
  how `classifyFallProgram` treats an unrecognized prefix.
- **A treatment no-op still returns success** with a summary saying it did nothing, since that is
  what `send-email` renders.

---

### RESOLVED: What happens to the shipped `lock-activity` step and the `spring-2026` pipeline?

**Context**: `spring-2026` is the only wired pipeline and it contains
`{ name: "lock-activity", processingMessage: "Locking your pre-test…", handler: lockActivity }`.
REPORT-81 recorded that spring is dormant, so blast radius is nil, but the step name appears in the
teacher email body and the processing message is what a spring student sees.

**Options considered**:
- A) **Migrate spring onto the generalized step**, keeping its entry name and processing message
  unchanged so the student-visible and email-visible strings do not move. One code path, and the
  spring path gains the R2 two-flag write.
- B) Leave `lock-activity` untouched and add the generalized step beside it. Two code paths doing the
  same PUT, and the R2 correctness fix does not reach spring.
- C) Migrate spring **and** re-word its processing message, on the grounds that a generalized step
  should not say "pre-test". Changes a string a real (dormant) pilot shows.

**Decision**: **A.** REPORT-81 faced this call and recorded the reasoning when it changed spring's
de-duplication behavior: "`spring-2026` is dormant, so the blast radius is nil, and the change is made
because the argument is about the enrolment primitive rather than about which cohort is running."
Substitute "offering-state primitive" and it holds unchanged. Its attached condition carries over
too: **the changed case gets its own test**, because the existing suite would otherwise stay green
through a behavior change.

**Why not B**: it leaves two code paths issuing the same PUT, and the R2 fix, which exists because a
`locked`-only write silently forces `active: true`, would not reach the one pipeline that has run
against real students. **Why not C**: "Locking your pre-test…" is accurate for spring, and it is a
processing tick shown mid-flight rather than a failure string, so there is nothing to correct.

**Naming**: spring keeps the entry name `lock-activity` while the fall stages use `lock-current`. Two
labels over one handler is fine after the `stepResults` decision above, which makes the entry name
explicitly a label rather than the handler's identity, and holding spring's label steady keeps its
teacher-email line stable.

**Coupling to surface, not discover**: with no per-entry config, the student-facing failure message
belongs to the step rather than the entry, so migrating spring means spring inherits the message
decision below and "Unable to lock your pre-test" goes away for spring as well.

**Files**: `offering-state.ts` (shared core), `lock-current-offering.ts` and
`open-target-offering.ts` (the two steps), following REPORT-81's core-in-its-own-module layout.
`lock-activity.ts` and its test go away as a git rename.

**Dependents to update**: `index.ts`'s import and entry; `lock-activity.test.ts`'s body assertion
(gains `active=true`); the `failsAt: "lock-activity"` label in three harness scenarios (cosmetic, as
the README records that `failsAt` is printed rather than asserted); the two harness scenarios that
**do** assert `messageIncludes: "Unable to lock your pre-test"`; the `lock-activity` reference in
`enroll-specified-class.ts:72`; and **`index.test.ts:36`'s `jest.mock("./lock-activity", ...)`**, which
is keyed on the **module path** and so is a **build-breaking** dependent rather than a cosmetic one. A
throwaway reproduction gave `Test suite failed to run: Cannot find module`, with `Tests: 0 total`, so
the rename takes all four orchestrator tests with it until the mock is repointed. Note the six
`"lock-activity"` references in `send-email.test.ts` are `stepResults` keys rather than module paths,
and spring keeps that entry name, so they are correctly left alone; the mention in `functions/README.md`
is prose about the emulator's OIDC token and is harmless either way.

---

### RESOLVED: What does the student see when an offering-state step fails?

**Context**: R12 requires the message stop naming the pre-test, but the replacement wording depends
on what the student is meant to do.

**Options considered**:
- A) One generic retryable message for every offering-state failure.
- B) A per-operation message (locking vs opening).
- C) A generic message plus a header note about the roster consequence.

**Decision**: **B, with the retry promise dropped on the open path, plus C's header note.**

**Why B is the house style rather than a departure**: every step in `ai4vs-flvs/` already carries its
own `STUDENT_FAILURE_MESSAGE` in one shape, "Unable to *what this step was doing*. Please try again or
contact your teacher.", handed to `messageForBucket` as the generic-bucket fallback
(`resolve-origin-class`, `enroll-specified-class`, both randomization steps, `send-email`). After the
step-shape decision there are two steps, so one message each follows the convention; a single shared
message would be the departure.

**The wording, and why the two differ**: a failed lock is self-healing, which REPORT-82 states
directly, "the activity stays unlocked and the student can click again", so retry is honest advice. A
failed open is not: under REPORT-82's post-test order (lock, then the control-only open, then email)
the student has just been locked out of the activity whose button they clicked and cannot re-click.
REPORT-82 already noted this residual and classified it as cosmetic, which it is, but "please try
again" is copy that cannot come true.

- `lockCurrentOffering`: **"Unable to record that you finished this activity. Please try again or contact
  your teacher."** Reworded off "pre-test" because it now serves all three stages, and spring inherits
  it. (Round 2 replaced "Unable to finish this activity" with the current wording: it was vague about
  what had failed, which invited the reading that the student's answers were lost. See R12.)
- `openTargetOffering`: **"Your work has been saved. We could not open your other activity, so please
  tell your teacher."** Worded to stay true even if REPORT-82 reorders the stage, where it would be
  conservative rather than wrong. (Reworded by the Round 1 Student findings, which added the
  work-was-saved clause and dropped "next" in favour of "other". This bullet recorded the pre-finding
  string, "Unable to open your next activity. Please tell your teacher.", until Round 2 caught the
  divergence from R12. R12 is authoritative.)

Bucket routing is unchanged for both: 4xx to tell-your-teacher, mint-expiry to reload.

**Header note (from C)**: record on `lockCurrentOffering` that a failed lock leaves the researcher's
roster under-reporting completion, since that is the consequence worth knowing and it is not visible
from the code.

**Flagged for REPORT-82, not decided here**: putting the **open before the lock** at the post-test
stage would make both failure modes retryable, since the student would not yet be locked out and the
open is idempotent, and it would stop a failed open from suppressing the teacher email as the current
order does. That is a step-ordering call that interacts with REPORT-82's recorded reasoning for
lock-first at the curriculum stage, so it belongs on that story.

## Self-Review (Round 1)

Six lenses, run against the requirements after all seven design questions were resolved. Findings are
ordered by role, most consequential first within each.

### Security and Privacy Engineer

#### RESOLVED: The PII constraint is recorded as a rationale, not as a requirement
**Resolution**: added **R16** (a Privacy section) and **R13b** (its test). The sharper half of the
risk, noted while resolving: `summary` is rendered into an email to a human, so a summary naming
students would put real names into a message with a routing path this story does not control.

The `active`-value decision records that `GET /api/v1/offerings/:id` returns `students[]` carrying
**real** student names for a minted teacher of the class, and that `classes/info` returns real
**teacher** names (a rule `portal-reads.ts` already documents for `PortalClass.teachers[]`). But no
numbered requirement forbids logging those arrays or placing them in `StepResult.summary`, which
`send-email` renders into the teacher-notification email. Every other PII rule in this codebase lives
where it can be enforced and tested. Suggested resolution: add a requirement, and a test, that the
step logs neither array and that its `summary` carries only the offering name and the flags.

#### RESOLVED: Why the origin mint cannot be escalated by a mis-set constant is not stated
**Resolution**: R10 rewritten to state the guarantee as structural, to forbid adding a pre-write
authorization check (which would contradict the standing no-defensive-runtime-code principle), and to
mark the boundary the deferred class-word derivation would cross.

R10 asserts the origin mint suffices because the target is in the origin class. What makes that safe
is stronger and worth writing down: the target is *looked up within* the class the origin mint already
authorizes, so a wrong constant can only fail to match, never reach an offering in another class. As
written, R10 reads like an assumption a reader has to trust rather than a structural guarantee.

---

### Senior Engineer

#### RESOLVED: The shared core's signature cannot produce the classified message R12 requires
**Resolution**: added **R1a**. The core returns a bucket rather than taking a message, chosen over
passing `failureMessage` into the core because `openTargetOffering` has non-portal failure modes that
never reach the core and would otherwise render some messages itself and delegate others. Cost
accepted: `lockCurrentOffering` gains a three-line bucket-to-message map, which is what every sibling
step already looks like.

R1 gives the core as `applyOfferingState(context, { offeringId, locked, active })`, but R12 puts the
student-facing message on each step, and classification happens where the portal response is seen,
inside the core. As specified the core cannot call `messageForBucket(bucket, STUDENT_FAILURE_MESSAGE)`
because it does not have the message. Either the core takes the fallback message as a parameter, or
it returns the bucket and lets the step render. Suggested resolution: pick one and state it in R1.

#### RESOLVED: R2 does not state the fallback when the student has no metadata row
> **Superseded by Round 2.** The echo this finding specified was removed; there is no fallback because
> there is no read. R2a now states a determinism property instead. The observation about `metadata[]`
> carrying every student's row survives in the Technical Notes.

**Resolution**: added **R2a**. Sharpened beyond the original finding with two things it had not
stated: `metadata[]` carries every student's row so filtering by `user_id` is mandatory (an
unfiltered read copies another student's visibility state onto this one), and the two portal reads
differ in form, `classes/info` raw versus `offerings#show` pre-resolved, so the fallback must not be
applied twice if the read is ever switched.

R2 says `openTargetOffering` passes "the student's current effective value". The rule is only spelled
out in the Technical Notes: the row if one exists, else the offering's own `active`. Since this is the
exact distinction the two-flag requirement exists to protect, R2 should carry it rather than leave the
reader to reconstruct it.

#### RESOLVED: Behavior on an absent `originClassWord` is unspecified
**Resolution**: added **R7b**, mirroring `fall-random-assignment.ts:61-77`, and settling which message
each failure class uses (per-step message for portal failures, shared `TELL_TEACHER_MESSAGE` for
wiring and configuration failures).

**Surfaced while resolving, for REPORT-82**: `lockCurrentOffering` needs no class read, so the
curriculum stage can be lock plus email with **no `resolve-origin-class` step at all**. That makes one
sentence of `fall-random-assignment`'s header comment stale, the claim that "every fall stage needs
the class word, so there is no case in which resolve-origin-class is present but unused". The
no-ordering-guard decision itself is unaffected, since the reasoning holds for stages that do include
the resolve.

R7 says the handoff is read with no ordering guard, consistent with `fall-random-assignment`, but does
not say what happens when it is absent, which is the mis-wired-stage case. The sibling step treats it
as a classified failure rather than a default. Suggested resolution: state it, so REPORT-82 does not
have to infer it while ordering stages.

#### RESOLVED: Two implementation obligations appear only in prose
> **Superseded in part by Round 2.** R17 is withdrawn: nothing in the story reads `metadata[]` any
> more, so narrowing its type would touch a file this story does not own with no caller to justify it.
> R18 stands unchanged.

**Resolution**: added **R17** and **R18**. R18 was strengthened during review from "export the
constant" to "move it to `fall-programs.ts`": steps should not import from each other, and
`fall-programs.ts` is the module that already owns class-word interpretation. The correctness stake
was also made explicit, since a forward/reverse divergence silently withholds the curriculum from a
control student.

Narrowing `PortalOffering.metadata` off `unknown[]`, and exporting `DESTINATION_SUFFIX` from
`fall-random-assignment.ts` so the arm-to-suffix and suffix-to-arm directions share one source of
truth. Both are needed to satisfy R2 and the arm conditional respectively, and both touch files this
story does not otherwise own. They should be requirements.

#### RESOLVED: R7 does not say which token reads the class
**Resolution**: folded into R7. Worth the line because of its interaction with R11: naming the origin
mint for both calls forecloses the plausible fork where an implementer reaches for a `class_id`-scoped
mint for the write, which would work but would mint twice per run and quietly undercut R11.

`enroll-specified-class` uses the origin (unscoped) mint for `classes/info` and says so in a comment,
because the endpoint has no per-class authorization. R7 leaves it implicit.

---

### Education Researcher

#### RESOLVED: The completion-record consequence is a code comment, not an acceptance criterion
**Resolution**: added **R19** and **R19a**, but not in the form the finding proposed. Promoting "the
lock must succeed" to a requirement would have been a wish rather than a constraint, since the system
already does everything available to it. What was actually missing was the **severity model** the
spec's own decisions silently assume (Q7's differing messages, REPORT-82's step ordering), which a
future trade-off between the two paths needs in order to be weighed, plus the one genuinely testable
property, R19a's re-clickability, on which every self-healing claim depends.

The lock is what the researcher's teacher progress roster shows, and her manual post-test opening is
gated on it, so a failed lock under-reports completion. The spec routes this into a step header note.
For a study whose validity rests on knowing who finished, it belongs among the requirements or
acceptance criteria, where it constrains behavior rather than merely informing a reader.

---

### QA Engineer

#### RESOLVED: R15's stub upgrade is insufficient to exercise the echo path
> **Superseded by Round 2.** R15a is withdrawn along with the echo. The stub's `metadata: []` is now
> both realistic and sufficient. R15 itself (a class with more than one offering) still stands, since
> name matching still needs it.

**Resolution**: added **R15a**. The sharp form of the problem, found while resolving: against today's
stub the correct R2a echo and the wrong default-to-`true` implementation write the same value, so the
harness cannot tell them apart. The fixture also has to place the `active: false` row on the harness
student and a contrary row on another `user_id`, so the same scenario covers R2a's mandatory
`user_id` filtering.

R15 requires the stub to serve a class with more than one offering, which proves name matching. It
does not require any offering to carry a **per-student metadata row**; `stub-portal.js` serves
`metadata: []` today. Without a row, the `openTargetOffering` echo introduced by R2 is exercised only
on its no-row fallback, and the case the two-flag rule exists for is never driven.

#### RESOLVED: R14 predates the two-step shape
**Resolution**: R14 rewritten to name `openTargetOffering` and to state what the second run actually
proves (token reuse **and** R3's idempotency end to end, which no other verification covers), plus
**R14a** for the treatment no-op, whose point is an absent `PUT` and therefore needs its own scenario
rather than a branch of the repeat.

R14 says "the step" runs twice under `run-step.js`, written when there was one. The open path is the
one carrying resolution, arm classification and the echo, so it is the one that needs the harness; the
lock path is closer to what already ships.

---

### Student

#### RESOLVED: The open-path failure message implies the student's work did not count
**Resolution**: R12 rewritten. The reassurance is guaranteed by control flow rather than assumed, since
a failed lock aborts the pipeline before the open runs. The cost being avoided is behavioural, not
tonal: a student who reads this as a failed submission re-clicks, finds themselves locked out, and
reports a contradiction the teacher then has to reconcile against a roster that already says they
finished.

"Unable to open your next activity. Please tell your teacher." arrives immediately after a successful
lock, so the student has finished and been recorded, but sees only an error where the completion
message would be, and cannot re-click. That reads as "my submission failed". A clause confirming the
work was saved would cost nothing and would prevent avoidable teacher contacts.

#### RESOLVED: "your next activity" is inaccurate for the student who sees it
**Resolution**: no further change. The wording adopted for the previous finding says "your **other**
activity", dropping "next" entirely, which is accurate for the only student who ever sees it. Recorded
for the reader: the message deliberately does **not** name the sequence. "We could not open the Blue
sequence" would be clearer but puts the study's internal colour-coding in front of a student and would
thread the module constant into the copy, reintroducing the coupling the constant exists to contain.
Vagueness costs the student nothing here, since they are being told to talk to their teacher, who has
the roster and the logs.

The only student who ever sees this message is a control student finishing the post-test, for whom the
curriculum being opened is the sequence they were held out of, not the next thing in their path.

---

### Portal API reviewer

#### RESOLVED: The response body is discarded where it could be a post-condition
**Resolution**: the strict post-condition is **declined**, the diagnostic half is **taken** as **R20**.
Declined because R3 forbids a check that could turn a no-op write into a failure, because the "any 2xx
succeeds regardless of body" behaviour is deliberate and tested rather than an oversight, and because
the one bug it would catch (a dropped parameter under strong params) is already caught at build time
by R13's exact-body assertion.

`update_student_metadata` renders the resulting `{active, locked}`. The shipped step treats any 2xx as
success regardless of body, pinned by an existing test. Echoing back a comparison would turn "the
portal accepted the request" into "the portal is now in the state we asked for", which is what R3's
idempotency claim actually asserts. Raised for an explicit accept-or-decline rather than left as an
unexamined inheritance.

## Self-Review (Round 2)

Eight lenses, run against the requirements after Round 1's findings were all resolved. Three of the
lenses are new (Release and Build Engineer, Spec Editor, Implementer Reading Cold), chosen so the
round is not a re-run of Round 1 over settled ground.

**Every finding below was verified against code before it was written down**, against the rigse
checkout at commit `6f4c49288` and this repo's working tree, and two were verified by throwaway jest
tests that were deleted after they passed. The verification is recorded with each finding, because
what makes a finding actionable here is the evidence, not the assertion. Claims that turned out to be
**correct** on inspection are listed at the end of the section rather than dropped, so a later reader
does not re-litigate them.

### Senior Engineer

#### RESOLVED: R2a's identity comparison has no stated type contract, and both required verifications pass a broken implementation
**Resolution**: **R2a** now states the comparison as coerced on both sides with the reason attached,
**R13** now requires the one fixture combination that discriminates (string `platform_user_id` against
a numeric row `user_id`), the `classes/info` caution notes the type boundary, and a new Technical Notes
subsection, [The id forms](#the-id-forms-platform_user_id-and-resource_link_id-are-bare-integers),
records the contract so this is not re-derived.

**Superseded in part by the next finding**, which removed the echo this trap lived in. The fix was
applied first and then deleted with its subject. What survives, and is why this stays in the log: the
number-versus-decimal-string boundary between `metadata[]` rows and `platform_user_id` is now recorded in
the Technical Notes for the next reader of that array, and the id-form contract below was established
here.

**Sharpened during resolution, by a question worth recording**: the reviewer's premise that
`platform_user_id` might arrive as a URL (`https://portal/users/27`), the form the portal *does* use
for `teachers[].id` and `students[].id`, was checked and **refuted**, which matters because it would
have made `String()` coercion useless and demanded a parsing rule. Five portal sites set or consume the
field as a bare `users.id`, the decisive one being
`User.find_by(id: claims['platform_user_id'])` in `ForwardedFirebaseToken#verify`, which `oidc_mint`
calls before minting: a URL would fail every mint with `reason: "user_unresolved"`, so the pipeline's
working mints already prove the form. Six live `spring-2026` job documents in `report-service-dev`
confirm it (`'27'`, `'199'`, `'408'`, `'419'`, `'420'`, `'421'`), and five of them completed the whole
spring pipeline, so the shipped `update_student_metadata` write is proven against that form on a real
portal. **The two forms are both real; they simply live on different fields.**

R2a says to find "the `metadata[]` row whose `user_id` equals `platform_user_id`". The two sides are
not the same type, and nothing says to normalize them.

**Verified.** The portal side is an integer: `classes_controller.rb:152` renders
`{ user_id: m.user_id, ... }` straight off `user_offering_metadata.user_id`, declared
`t.integer "user_id", null: false` (`schema.rb:1610`), so it arrives as a JSON number, and the shipped
`lookupClassByWord` passes `metadata` through untouched. The report-service side is `any`: `platform_user_id`
reaches steps through `IJobDocument`'s `[key: string]: any` index signature (`tasks/types.ts:25`), so
the compiler checks nothing, and everywhere else in this repo that types the field at all types it
`string` (`api/bulk-read.ts:21`, `shared/s3-answers.ts:16`, `auto-importer.ts:29`). `lock-activity`
already coerces with `String(platform_user_id)` when it builds the write body, which is the shape of
the fix.

A throwaway jest test drove the shipped `lookupClassByWord` against a `get_info` body carrying this
student's row (`active: false`) and another student's contrary row, then applied R2a as literally
worded. With a production-shaped `"27"`, strict equality misses the row and the resolved value is the
class-level `true` rather than the student's own `false`. **That is precisely the silent visibility
side effect R2 exists to prevent, reintroduced through the type system rather than through a hardcoded
default**, and it is the failure mode R2a's own text calls out as the one that "must not be shortened
to a default of `true`".

The sharp part is that neither verification the spec requires can see it:

- **R13's unit test cannot.** The fixture convention in the sibling suites is a *numeric*
  `platform_user_id`: `lock-activity.test.ts:29` uses `27`, `index.test.ts:61` uses `12345`, and
  `portal-reads.test.ts` already writes `metadata: [{ user_id: 9, ... }]`. A test written to that
  convention compares number to number, so the strict and coerced implementations agree.
- **R14 / R15a's harness run cannot.** `CONTEXT.platform_user_id` is `"im-done-student-1"`
  (`config.js:57`), so an R15a row keyed on the harness student is string against string, and the two
  implementations agree again. The harness matches production only by accident of its own fixture's id
  type, and the accident falls the wrong way.

So the requirement, the unit test and the end-to-end harness can all be satisfied while the one
production path is wrong. Suggested resolution: state the comparison in R2a as coerced on both sides
(`String(row.user_id) === String(platform_user_id)`), and give R13 a case whose `platform_user_id` is
a **string** while the fixture row's `user_id` is a **number**, which is the only shape that
discriminates.

---

### Education Researcher

#### RESOLVED: The R2a echo makes a class-level hidden target a silent successful no-op, and "open" has quietly stopped meaning "make visible"
**Resolution**: the echo is **removed**. `openTargetOffering` sends `active: true`, restoring the
story's original "unlock plus make visible" and making both callers uniform. Recorded as an amendment
on the `active`-value question rather than by rewriting its decision, so the log shows what was
believed and why it changed. **R2** now carries the per-caller reasoning, **R2a** is rewritten to the
determinism property (send both flags so the state is set rather than inherited, which still matters for
a pre-existing hidden row), **R13**'s echo cases are replaced by one determinism case, **R15a** and
**R17** are withdrawn with their reasons recorded, and the hide exclusion in Out of Scope plus the
caller census in Background are corrected, since both described the write as preserving the flag the
target already has.

**Sharpened during resolution**: the finding as first written said the echo was a hazard under a config
the study excludes. The stronger form, found while re-reading the decision it challenged, is that the
resolved split was **inverted with respect to purpose**: the hardcoded `true` went to the path where
forcing visibility is an unrelated side effect, and the echo went to the path whose entire job is to
make the target reachable. Under the real study config every variant is byte-identical, so this was a
design inversion rather than a live defect, which is exactly the kind of thing that survives a first
review round.

**Note on ordering**: this finding partly subsumes Round 2's first, which fixed a type trap inside the
echo that this decision then deleted. The findings were ordered by consequence rather than by
dependency. The trap's write-up is kept because the type boundary it documents still waits for the next
reader of `metadata[]`.

**Verified.** The portal resolves student visibility row-wins-else-offering in both places that matter:
`clazz.rb:245` (`student_visible_offerings`, which is the list the student sees at all) and
`runnables_helper.rb:31` (which disables the run link). An offering whose effective `active` is false
is **absent from the student's list entirely**, so unlocking it changes nothing they can see or reach.

R2a echoes whatever the effective value is. If the control class ever has the curriculum hidden at
class level, which is the intuitive way a researcher or teacher would hold control students out of it,
`openTargetOffering` writes `locked: false, active: false`, returns **success**, and the student still
sees nothing. No log records that the open accomplished nothing, and R19 classifies a failed open as
merely an experience problem on the assumption that it fails *visibly*.

The Background records the story as originally specifying open as "unlock **plus make visible**". The
caller census cut `hide-current` for having no caller, and Out of Scope excludes the hide capability on
the grounds that control students must still see both sequences. Between them, "open" was reduced from
unlock-plus-reveal to unlock-only, and that reduction is nowhere recorded as a decision. Q3's note even
frames the echo as robustness "against a class-level hide the study design excludes", without noticing
that for the *open* path the same hide is not a state to be preserved but the exact thing the step
exists to undo.

Under the study's actual configuration (class-level `active: true`, per Out of Scope) the echo and a
hardcoded `true` are byte-identical, so this is not a live defect. It is an unrecorded narrowing of
what the step promises, on the one path where the promise is the point. Suggested resolution: record
the narrowing explicitly, and decide whether `openTargetOffering` should log or summarize distinctly
when it writes `active: false`, since that is the case where it reports success without having opened
anything.

---

### Portal API reviewer

#### RESOLVED: Nothing prevents the target name resolving to the run's own offering, which would silently erase the completion record
**Resolution**: added **R8a**, worded as a target-selection rule rather than an authorization check, plus
a clause in **R10** stating why the two are compatible (R10 guards the class boundary; R8a's case is
inside it, where the mint is legitimately authorized and the write would legitimately succeed), and a
case in **R13**.

**What decided it, against this spec's own preference for not checking our own configuration at run
time**: the justification for that preference, recorded in `enroll-specified-class`'s header and
`types.ts`, is that our own wiring "fails on the first harness run". Verified that it does not hold
here, and structurally rather than by accident. The target name is a module constant that the Q1
decision deliberately made non-injectable, so the harness stub and the unit fixtures must both be
configured **from** that constant in order to match at all. They therefore agree with any value it
holds, including one naming the offering the stage locks. Nothing but a human comparing the constant
against the portal catches it, and the consequence is the destructive-and-silent case rather than the
inert one R8 already covers.

R8 covers a name matching no offering and a name matching more than one. R10 covers the target being
outside the class the mint authorizes. Neither covers the target resolving to **the offering this run
launched from**, which is the offering `lockCurrentOffering` locked moments earlier in the same stage.

**Verified as reachable and as silent.** The write path is per-offering by id, and the completion record
the researcher reads is the per-student locked flag on the teacher progress roster
(`offering-progress-row.tsx`, whose per-student checkbox posts to this same endpoint). A constant
naming the post-test sequence rather than the curriculum sequence resolves to exactly one offering, in
the right class, and the write succeeds: `locked: false` over the lock that had just been recorded.
The step returns success, `send-email` reports success, and the roster shows the student as not
finished. It fires on the control arm only, which is the arm whose completion the researcher is
waiting on to open the post-test by hand.

This is not the class-confusion case R10 forecloses, and it is not a portal authorization question:
the acting teacher legitimately owns both offerings. It is a same-class, same-teacher,
wrong-offering write, between two author-named sequences that sit side by side in one class, so a
constant naming the wrong one of the pair is the plausible cause rather than an exotic one. R19a's
self-healing claim does not cover it either, since the lock succeeded and was then reversed.

> **Corrected in Round 5.** This paragraph read "the **three** fall sequences live in one class". The
> study class holds **two**, the curriculum and the post-test; the pre-test lives in the registration
> class and cannot be in the study class, since a student keeps both memberships and would otherwise see
> it twice. The correction strengthens R8a rather than weakening it: with two offerings in the class,
> R8a plus the intended target exhaust every name that resolves, which makes R8a complete rather than a
> partial mitigation. That argument now lives in R8a itself.

The guard is a comparison the step already has both sides of: `resource_link_id` is in `StepContext`
and the resolved offering id is in hand (both need R2a's coercion, since one is a string and the other
a number). Against that, the spec's standing principle is that our own configuration is assumed correct
rather than checked at run time, and R10 explicitly forbids adding a pre-write check. Raised for an
explicit accept or decline in the same spirit as Round 1's response-body finding, rather than left
unexamined: the distinguishing property, and the same one that nearly earned the duplicate-name
assertion an exception, is that this failure is silent and destructive rather than loud.

---

### Security and Privacy Engineer

#### RESOLVED: R16 enumerates `students[]` and `teachers[]` but omits `metadata[]`, the one array this story requires the step to read
**Resolution**: **R16** extended, deliberately as a **separate** clause with a different rationale
rather than by adding `metadata[]` to the existing list. The two existing arrays are forbidden because
they carry real names; `metadata[]` carries none, so the concern there is **scope**, one student's id
being established practice while the whole class's progress roster is not. Keeping the rationales
distinct is what makes the requirement defensible rather than a blanket "log nothing".

**Found while resolving, and the more useful half of this finding**: **R13b as written could not have
caught the leak.** It asserted that no student or teacher **name** appears in the logs or the
`StepResult`, and `metadata[]` contains no names, so the entire array could be dumped with the test
still green. R13b now also asserts that no `user_id` other than the acting student's own appears, with
a sentinel on the other rows so it fails loudly, and covers the self-target branch R8a added.

**Calibration, recorded so this is not over-read later**: this was reported as the weaker of the privacy
findings and it stayed weaker on inspection. Withdrawing R17 in the previous finding lowered the risk
further by leaving the field `unknown[]`; adding R8a raised it slightly by adding a second branch a
developer will want to dump context on. It is worth a requirement because the step demonstrably holds
the array, not because a leak was likely.

**Verified.** `get_info` builds each offering's metadata as
`UserOfferingMetadata.where(offering_id: offering.id).map { |m| { user_id:, active:, locked: } }`
(`classes_controller.rb:151-153`), with **no user filter**. So the array is every student in the class,
their real portal user ids, and each one's visibility and lock state, which is a per-student progress
roster. R2a's own text already notes the array carries every student's row, but only as a correctness
caution about filtering, not as a disclosure one.

R16 forbids logging `students[]` (anonymized names) and `teachers[]` (real names) and says the summary
carries only the offering and the flags. `metadata[]` is named in neither list, and it is the array
this story adds a reason to hold: R17 narrows it from `unknown[]` to a typed row shape, which makes it
the most convenient thing in the body to interpolate into a diagnostic. The exposure lands on the R8
no-match branch, which R16 itself identifies as both the branch someone reaches for on launch day and
the one holding the whole class body.

Suggested resolution: extend R16 to name `metadata[]` alongside the other two, and let R20's success
log stand as the deliberate exception, since it carries this student's two booleans and their own
`user_id` rather than the class's.

---

### Release and Build Engineer

#### RESOLVED: `index.test.ts`'s module-path mock is missing from "Dependents to update", and it fails the whole suite file rather than one assertion
**Resolution**: added to the dependents list, marked **build-breaking** to distinguish it from the
cosmetic labels and single assertions that make up the rest of that list. The `send-email.test.ts` and
`functions/README.md` mentions are recorded there too, as deliberately **not** requiring changes, so the
rename is not over-scoped in the other direction.

The `spring-2026` migration question's dependents list names `index.ts`'s import and entry,
`lock-activity.test.ts`'s body assertion, three harness `failsAt` labels, two harness
`messageIncludes` strings, and the comment in `enroll-specified-class.ts:72`. It does not name
`index.test.ts`.

**Verified.** `index.test.ts:36` does `jest.mock("./lock-activity", () => ({ lockActivity: ... }))`, a
mock keyed on the **module path**, which the planned git rename invalidates. A throwaway test
reproducing that shape against a nonexistent path produced
`Test suite failed to run: Cannot find module './lock-activity-renamed-away'`, with
`Tests: 0 total`. So the consequence is all four orchestrator tests failing to run, at the file level,
not a single assertion needing an edit. That is a different class of dependent from everything else on
the list, all of which are cosmetic labels or single assertions.

Also verified, and deliberately **not** a finding: `send-email.test.ts`'s six `"lock-activity"`
references (lines 116, 123, 198, 203, 208, 213) are `stepResults` record keys, not module paths, and
the migration decision keeps spring's entry name `lock-activity`, so they stay correct untouched. That
is worth recording so the rename is not over-scoped.

Suggested resolution: add `index.test.ts`'s mock to the dependents list, noting it is a build-breaking
dependent rather than a cosmetic one.

---

### QA Engineer

#### RESOLVED: R14a's "no `PUT` reaching the stub" is not something the harness can assert
**Resolution**: **R14a** reworded to call the absent `PUT` manual inspection, matching how the harness
README classifies every other unasserted observation, and to point the machine-checkable form at R13,
where a unit assertion of "no `PUT` issued" costs nothing. The stub-reports-to-driver alternative was
considered and declined: it is a harness capability this story would have to build and own, and the two
things it would buy (the treatment no-op and R8a) are both already covered at the unit level.

R14a says the treatment no-op scenario asserts success, a summary saying nothing was done, and no
`PUT` reaching the stub, on the grounds that "the absence is directly observable, since the stub logs
every request it receives".

**Verified that the absence is observable but not assertable.** `run-step.js`'s `checkRun` (line 47)
inspects only the returned `StepResult`: `result.success` and a substring of `summary` or `message`.
The stub is a **separate process** whose request log goes to its own stdout, described in the README's
run instructions as terminal 2 while `run-step.js` prints in terminal 3, and the README states the
distinction outright: "Everything else the harness exercises is **shown in the logs for manual
inspection**, not asserted". `run-all.js` drives every scenario and prints a pass/fail summary built
from the drivers' exit codes, so a scenario whose real content is an absent request passes vacuously
there.

The other two thirds of R14a (success, and a summary saying nothing was done) are genuinely assertable
and do most of the work, since a step that had issued the write would not produce that summary.
Suggested resolution: either reword R14a so the `PUT` absence is stated as manual inspection, matching
how the README classifies every other unasserted observation, or give the stub a way to report what it
received to the driver, which is a harness capability this story would then own.

---

#### RESOLVED: R14 understates the harness change, and the step it names cannot run under `run-step.js` as it stands
**Resolution**: **R14** now states the driver work (per-scenario step selection plus a seeded
`originClassWord`) and names the README section to fix, since the spec inherited its framing from there.

**Found while verifying finding 3, and added to R15**: nothing required the stub to serve an offering
**named the module constant**, so as previously specified the by-name match would have resolved nothing
and every `openTargetOffering` scenario would have failed. R15 now requires it, and prefers the stub
import the compiled constant so a rename cannot desync the fixture from the step. The same edit records
the limit that follows from configuring the fixture out of the constant: the harness can prove the
matching logic, never the constant's real-world correctness.

R14 says a scenario drives `openTargetOffering` twice via `run-step.js` "following the precedent set
for `enroll-specified-class`", and the files list says `run-step.js` gets "a scenario for the new
step". Both read as an additive change to `scenarios.js`.

**Verified that it is a structural change to the driver.** `run-step.js` is single-step by
construction: `COMPILED_STEP` is a hardcoded path to `enroll-specified-class.js` (line 17), the require
destructures `{ enrollSpecifiedClass }` by name (line 68), and the call site names it (line 82).
Beyond dispatch, `buildContext` hardcodes `stepResults: {}` (line 40) and threads a
`target_class_word` request param that `openTargetOffering` does not read. Since R7b makes an absent
`originClassWord` handoff a permanent classified failure, **every `openTargetOffering` scenario would
fail on the handoff check** until the driver can seed `stepResults`, which is the one input this step
depends on and the enroll step never needed (it takes its word from a request param instead).

The harness README's own "Extending it for the fall stories (REPORT-80/82)" section has the same blind
spot, telling a reader to add stub behavior only if the endpoint is new, add a scenario, and point
`config.js` at the new pilot, then concluding "No portal plumbing changes are needed". True of the
stub, and misleading about the driver. Suggested resolution: state the driver work in R14 (per-scenario
step selection plus a seeded handoff), and fix the README section while this story is in it, since the
spec inherited its framing from there.

---

### Spec Editor

#### RESOLVED: R12 and the messaging decision record two different `openTargetOffering` strings
**Resolution**: the decision's bullet now carries R12's wording, with a parenthetical recording the
superseded string and which Round 1 finding moved it, so the rationale and the string travel together
instead of the log contradicting the requirement.

**Verified by reading the spec against itself.** R12 gives "Your work has been saved. We could not open
your other activity, so please tell your teacher." The RESOLVED messaging question's second bullet
still gives "Unable to open your next activity. Please tell your teacher." Round 1's Student findings
are what moved the wording, and the second of them records the final choice as saying "your **other**
activity, dropping 'next' entirely", so R12 is authoritative and the decision block was simply not
updated when the finding was applied.

It matters because the decision log is where an implementer looks for the rationale behind a string,
and here it hands them a different string with reasoning attached that no longer matches. The
`lockCurrentOffering` bullet beside it is still correct. Suggested resolution: update the bullet to
R12's wording and note that the reassurance clause came from the Round 1 Student finding, so the
rationale and the string travel together.

---

### Student

#### RESOLVED: The lock-path message did not get the reassurance the open path did, and reads the same way to the student
**Resolution**: the message becomes **"Unable to record that you finished this activity. Please try again
or contact your teacher."**, and R12 now records why only the open path carries a reassurance clause.

**The finding was right about the problem and wrong about the fix**, which is worth recording because the
wrong fix is the tempting one. Adding "Your work has been saved" to the lock path would have been
self-contradictory from the student's side: on that path something genuinely does need redoing, so a
reassurance competes with the retry instruction and risks suppressing the re-click that R19a identifies as
what heals the failure. The open path can carry it precisely because nothing needs redoing there. The real
defect was **vagueness**: "Unable to finish this activity" never said what failed, and that is what
invited the data-loss reading. Naming the recording fixes it without a reassurance, keeps the
house-style shape R12 requires, stays true for spring (locking the pre-test is recording that the student
finished it), and costs nothing, since the migration already had to edit the two harness scenarios that
assert the old string.

Round 1 found that the open-path message implied the student's work had not counted, and fixed it with
"Your work has been saved." The lock message was not revisited and still opens "Unable to finish this
activity."

A student's answers are saved continuously by the activity player, independently of this pipeline, so a
failed lock loses the completion record, not the work. "Unable to finish this activity" invites the same
misreading Round 1 rejected for the open path: that the submission failed. The counter-argument is that
the two cases are not symmetric, since the lock path's retry advice is honest (R19a) and actionable,
and leading with reassurance could blunt the instruction to click again, which is the thing that
actually heals it.

This is a judgment call about copy rather than a verified defect, and it is recorded as the weakest
finding in the round. Suggested resolution: either accept the asymmetry on the reasoning above and
record why, or reword to carry both, for example "Your work has been saved, but we could not finish
this activity. Please try again or contact your teacher."

---

### Verified correct, no change proposed

Recorded so a later reader does not re-check them. All against rigse `6f4c49288`.

- **The endpoint's authorization chain.** `update? -> class_teacher_or_admin? -> class_teacher? ->
  record.clazz.is_teacher?(user)` (`offering_policy.rb:83,120,128`), and the 403 for a teacher who does
  not own the class is asserted at `offerings_controller_spec.rb:493`, as the Technical Notes claim.
- **Permitted params, membership check, idempotency and the rendered body.**
  `permit(:active, :locked)`, the 404 `"student not found in the class"`,
  `find_or_create_by(...)` then `update!`, and `render json: metadata.as_json(only: [:active, :locked])`
  (`offerings_controller.rb:53-66,211`). R3 needs nothing portal-side and R20's log has a body to read.
- **The two-flag write's premise.** `active` defaults true and `locked` false
  (`schema.rb:1612-1613`), with a unique index on `(user_id, offering_id)`, and all four consumers
  resolve row-wins-if-a-row-exists (`offering_policy.rb:62`, `runnables_helper.rb:31`,
  `offering.rb:52`, `clazz.rb:251`). The workaround comment R2 quotes is at
  `offering-progress-row.tsx:34-35`, one line off the cited number.
- **R10's structural guarantee.** `oidc_mint_controller#resolve_teacher` with no `class_id` resolves to
  the least-privileged teacher of `result.origin_clazz`, which comes from the forwarded student token's
  origin offering, so at the post-test stage the mint is a teacher of the subclass the student launched
  from. The `class_id` branch is what yields the 422 "No teacher is shared..." the spec quotes.
- **The form-encoded `locked=false` write**, which is this story's only `false` boolean over the wire, on
  the open path. (Retitled in Round 4: this entry read "`active=false`", a write R2 means the story never
  makes, which risked the whole verification being read as belonging to the deferred hide capability.)
  `update_student_metadata` relies on ActiveRecord's implicit cast of the string rather than the explicit
  `params[:active] == 'true'` its sibling action uses (`offerings_controller.rb:42-45`), and rigse's own
  spec round-trips `active: false, locked: true` through the action as stringified params and asserts both
  landed (`offerings_controller_spec.rb:469,505-516`). The cast is therefore proven for whichever flag
  carries the `false`, which also pre-clears the deferred hide caller.
- **The `enroll-specified-class.ts:72` reference** in the dependents list is exactly where the spec
  says, and `functions/README.md:77` carries a third `lock-activity` mention (prose about the emulator's
  OIDC token) that is harmless either way.

## Self-Review (Round 3)

A consistency pass over the Round 2 edits, as the review cycle requires, rather than a fresh set of
lenses. Two of the three items are about damage Round 2 itself did; the third is the only new finding.

#### RESOLVED: Round 2 falsified a Background bullet it did not update
**Resolution**: corrected, with a note recording the prior wording.

The caller census read "**hide-current: zero callers.** Nothing in the fall flow ever writes the
visibility flag." True before Round 2, false after it: R2 now writes `active` on **every** call. What
survives is the narrower and still-important claim that nothing ever writes `active: false`. The Out of
Scope bullet was updated for this and the Background one was missed, which is the ordinary hazard of a
decision that touches a spec in six places.

---

#### RESOLVED: The Overview and Project Owner Overview understated the write after Round 2
**Resolution**: both updated. The Overview described the story as setting "a student's per-offering
`locked` flag" when it now always writes both flags, and the Project Owner Overview said "to unlock as
well as lock" when opening now means unlock **and** make visible. Both sections are rewritten at
finalization anyway, but leaving them inaccurate in the meantime is how a reader forms the wrong model of
the story before reaching the requirements.

---

#### RESOLVED: "Held out" names no mechanism, and the two candidate mechanisms have opposite consequences
**Resolution**: **confirmed 30 July 2026 that the fall `-shark` subclasses will carry the curriculum
offering, present but locked**, which is the branch the design already assumed. **R7c** records it as a
named dependency rather than an assumption, together with two consequences that only became worth stating
once the branch was known: that a class-level locked offering is still returned by `classes/info`, since
`teacher_visible_offerings` filters on `runnable.archived?` and nothing else (`clazz.rb:241`), so the flag
does not hide the target from the name match; and that the surviving absence risk is therefore
**archival** rather than assignment, which is what REPORT-82 should carry into its pre-launch checks. The
refuted branch is kept in R7c because it explains why the requirement exists.

Added as **R7c**. The Project Owner Overview says control students "were held out of [the curriculum]
during the study" without saying how, and the whole open path depends on the answer:

- **Held out by a class-level `locked: true`** on the curriculum offering in the shark class: the design
  works exactly as specified, since the per-student row wins over the class-level flag.
- **Held out by the curriculum not being assigned to the shark class at all**: there is no offering to
  resolve. R7's name match finds nothing, R8 fails every control student at the post-test, and opening
  the activity would require assigning it, which this story does not implement. R10's structural
  guarantee also loses its subject, since there is no target inside the authorized class.

The spec asserts the arrangement only in passing, and on the wrong kind of evidence: the caller census
establishes what the callers need, not how the fall classes are built. **This cannot be resolved from
code**, which is why it is recorded as a precondition with the failure mode attached and flagged for the
PI rather than assumed in either direction. The reason it is worth a requirement rather than a note: the
failure is silent until launch day and then hits the entire control arm at once, and the fix at that
point is a portal-side class rebuild, not a deploy.

## Self-Review (Round 4)

Eleven lenses. Six produced findings; the five that produced none are recorded at the end with what was
checked and refuted, so a later reader does not re-run them. Two lenses are new to this round
(Test Infrastructure Engineer, and Implementer Reading Cold actually exercised rather than merely
listed as Round 2 did); Portal API reviewer is deliberately re-run because it found the sharpest issue
in each of the first two rounds.

**Every finding was verified against code before it was written down**, against the rigse checkout at
commit `6f4c49288` (the same commit the Technical Notes cite, confirmed) and this repo's working tree.
Three were verified by throwaway jest runs and one by driving the harness stub over HTTP; all were
deleted or reverted after they passed, and the working tree was confirmed clean. Where a verification
produced output worth pinning, the output is quoted rather than summarized.

### Portal API reviewer

#### RESOLVED: R20's success log turns the pinned "any 2xx succeeds regardless of body" case into a student-facing failure, after the write has already landed
**Resolution**: **R20** now requires the defensive read explicitly, with the reason attached, and **R13**
gains the one case that discriminates: a 2xx with a null body must return success **and still emit the
log**. The existing 204 test pins only the return value, so it passes a step that throws in its log line,
which is why the new case says "and still emits the log" rather than reusing it as-is. R20 was chosen over
dropping the log entirely: the diagnostic answers "was this student actually locked?" from our own logs,
which is worth keeping, and the fix is one `?.`.

R20 requires that "on success **the step logs the `{active, locked}` the portal returned**". It cites, as
one of its three reasons for not *comparing* that body against the request, the fact that "the existing
'any 2xx succeeds regardless of body' behaviour is deliberate and tested (a 204 with a null body passes
today)". So R20 knows the body can be null, uses that knowledge to decline a comparison, and then
requires a read of two fields off it without saying the read must tolerate a null body.

**Verified, and the consequence is worse than a bad log line.** `lock-activity.test.ts:84-89` pins
`mockPortalTokenFetch.mockResolvedValue({ status: 204, data: null })` against
`expect(result).toEqual({ success: true })`. A throwaway patch implemented R20 the way it is worded,
interpolating `response.data.active` and `response.data.locked` into the existing success log, and ran the
shipped suite. Result: `Tests: 1 failed, 10 passed`, and the failure is not a log assertion:

```
    - Expected
    + Received
      Object {
    -   "success": true,
    +   "message": "Unable to lock your pre-test. Please try again or contact your teacher.",
    +   "success": false,
      }
```

The `TypeError` is raised **inside the step's `try`**, so the step's own `catch` swallows it and converts
it into `{ success: false, message: STUDENT_FAILURE_MESSAGE }`. The ordering is what makes this
consequential: the `PUT` has already succeeded on the portal when the log line throws. So the completion
record **is** on the researcher's roster (R19), the student is told the recording failed and to try again,
`index.ts:74-79` aborts the pipeline so `send-email` never runs, and at the post-test stage
`openTargetOffering` never runs either. R19a's self-healing claim inverts here: because the write is
idempotent (R3), a re-click succeeds and then throws again, so the student loops permanently against a
roster that already says they finished. It fires on **every** student on **every** stage, not on an edge
arm, and it is the one failure mode in this story where the portal state and the student-facing message
disagree.

Note this is a defect the spec would ship rather than a wording problem: R13's exact-body assertion does
not cover it (it pins the request), and R20's own rationale is what makes a reader confident the response
body is safe to touch. Suggested resolution: state in R20 that the log reads the returned flags
**defensively** (`response.data?.active`), and give R13 a case asserting that a 2xx with a null body still
returns success **with the log emitted**, which is the only shape that discriminates. The existing 204
test is the natural home; it currently proves the return value and not the log.

---

#### RESOLVED: Round 2's verified-correct entry is titled for an `active=false` write this story never makes, orphaning the one verification that covers the `false` it does send
**Resolution**: the entry is retitled to name `locked=false` as the story's only `false` over the wire,
keeping the `active: false` round-trip as the supporting evidence and noting that it also pre-clears the
deferred hide caller. The corrected line references were checked while editing
(`offerings_controller_spec.rb:469,505-516`).

Round 2's "Verified correct, no change proposed" list, whose stated purpose is that "a later reader does
not re-check them", carries an entry headed **"The form-encoded `active=false` write. This story's first
`false` boolean over the wire."**

**Verified against the spec's own decisions.** R2 requires `active: true` on both callers, Out of Scope
excludes writing `active: false`, and the `active`-value amendment states outright that "nothing in this
story passes `false`" for that flag. The `false` this story does put on the wire is **`locked=false`**, on
the open path. So the entry's title names a write the story does not perform, while the flag that actually
needs the reassurance goes unnamed.

The substance underneath it is sound and worth keeping: `update_student_metadata` does
`metadata.update!(student_offering_metadata_strong_params(params))` with `params.permit(:active, :locked)`
(`offerings_controller.rb:53-66,211`), relying on ActiveRecord's implicit cast of the string `"false"`,
where its sibling `update` action four lines above uses an explicit `params[:locked] == 'true'`. Confirmed
that rigse's own spec round-trips it: `update_params` is
`{ id:, user_id:, active: false, locked: true }` (`offerings_controller_spec.rb:469`) and the action's spec
asserts both values landed after the `PUT` (`offerings_controller_spec.rb:505-516`), reaching the action as
stringified params. The cast is therefore proven for whichever flag carries the `false`.

Why it is worth an edit rather than a shrug: a reader who searches this story for the `active=false` write
will not find one, and the natural conclusion is that the note belongs to the deferred hide capability and
does not apply yet. That discards the only recorded evidence that the form-encoded `"false"` this story
**does** send casts correctly. Suggested resolution: retitle to name `locked=false` as the story's first
`false` over the wire, and keep the `active: false` round-trip as the supporting evidence it is, noting it
also pre-clears the deferred hide caller.

---

### Senior Engineer

#### RESOLVED: A null offering name reaches R7a's match through a field the type system declares `string`, and one unnamed sibling offering fails the whole control arm with the wrong message class
**Resolution**: **R7a** now requires the comparison to skip any offering whose `name` is not a string,
with the wire-versus-type evidence attached so it does not read as defensive coding against our own
configuration, and **R13** gains the unnamed-sibling case. The class-read Technical Note records the
mapper's validation asymmetry for the next reader.

**Deliberately fixed step-side only, not in the mapper.** Narrowing `PortalOffering.name` to
`string | undefined` would fix it for every future consumer, and it is arguably the more correct change
since the declared type is currently false. It is declined for now on R17's precedent: `portal-reads.ts`
is a file this story does not own, and the step-side guard is sufficient for the one caller that exists.
Noted as the thing to revisit if a second consumer ever matches on offering names, because at that point
the asymmetry stops being one step's problem.

R7a requires the name comparison be "trimmed and case-insensitive". `PortalOffering.name` is declared
`name: string` in `portal-reads.ts`, so an implementer writing `o.name.trim().toLowerCase()` is writing
what the types say is safe.

**Verified end to end; the type is a lie at the wire boundary.** `Portal::Offering#name` delegates to the
runnable (`portal/offering.rb:26`), the runnable's column is `t.string "name"` with **no `null: false`**
(`schema.rb:289-292`), and `ExternalActivity` carries **no presence validation** on it (its only custom
validation is `validate :valid_url`, `external_activity.rb:117`). `get_info` renders `:name => offering.name`
straight through (`classes_controller.rb:156`). On our side `lookupClassByWord` validates the **class's**
`id`, `name` and `class_word` through `isUsableId` / `isNonBlankString` and coerces `active` and `locked`
with `!!`, but maps `name: o.name` **raw**, so a JSON `null` lands in a field typed `string`.

A throwaway jest test drove the shipped `lookupClassByWord` against a `get_info` body holding one unnamed
offering and one correctly named target. All three assertions passed:

1. the null survives the mapper (`offerings.map(o => o.name)` is `[null, "  Blue Sequence  "]`);
2. R7a's normalization applied as written **throws `TypeError`**;
3. guarding the non-string resolves the match correctly to the intended offering id.

Assertion 3 is what makes this consequential rather than academic: **the cause is a sibling offering, not
the target.** Any single unnamed offering anywhere in the control subclass breaks the match for every
control student, even though the target itself is present and correctly named. And the failure takes the
wrong exit: the `TypeError` lands in the step's `catch`, which returns the generic retryable message, so
the student is told to "try again" for a condition no number of retries can fix, where R8 and R7b both
require a permanent tell-your-teacher. Blast radius is the whole control arm at the post-test, which is
the same radius R7c was promoted to a requirement for.

This is the pattern `lookupClassByWord`'s own doc comment already establishes ("type-boundary hardening
rather than a live defect ... it exists so the two reads in this file agree"), applied one level down: the
class's fields are hardened and the offerings' are not. Suggested resolution: state in R7a that the
comparison skips any offering whose `name` is not a string, and add an R13 case with an unnamed sibling
beside a correctly named target, asserting the target still resolves. Whether to narrow
`PortalOffering.name` to `string | undefined` is a change to a file this story does not own and should be
weighed against R17's withdrawal; the step-side guard needs no such change and is sufficient.

---

#### RESOLVED: R1a's success variant cannot carry what R20 requires the step to log, and the house logging convention makes the obvious workaround lossy
**Resolution**: **R1a**'s success variant now carries the returned `{active, locked}`, absent when the
response had no body, which also gives the previous finding's defensive read an obvious home. Chosen over
moving the log into the core because the per-step log prefix is universal across all six siblings and a
shared core would emit one prefix for both callers, losing attribution on the stage that runs both. **R1**
now types `offeringId` as `string | number`, the smaller instance of the same gap.

R1a fixes the core's return type: "a **discriminated outcome**, success or failure carrying a
`PortalFailureBucket`". The success variant carries nothing. R20 requires that "**the step** logs the
`{active, locked}` the portal returned", and that body is visible only inside the core, which is where
`portalTokenFetch` is called.

**Verified as a genuine fork rather than a nit.** The response body reaches no caller under R1a as
written, so an implementer must either thread it out on the success variant or move the log into the core.
Moving it into the core loses information, because the logging convention here is universal and
per-step: all six sibling steps prefix every log line with their own step name
(`resolve-origin-class:`, `enroll-specified-class:`, `fall-random-assignment:`, `send-email:`,
`lock-activity:`, `random-assignment:`, each confirmed by grep). A log emitted from a shared
`applyOfferingState` would read `offering-state:` for both callers, so the one question R20 exists to
answer from our logs, "was this student actually locked?", could no longer be attributed to the lock step
rather than the open step, on a stage that runs both.

This is the same category as the Round 1 Senior Engineer finding that created R1a in the first place: the
core's signature could not produce the classified message R12 required. R20 was added in that same round,
by the Portal API reviewer, and the two were never reconciled. Suggested resolution: extend R1a's success
variant to carry the returned flags (which also gives the previous finding's defensive read one obvious
home), or state that the core takes a log label from its caller and owns the log. The first is preferable
because it keeps the core free of presentation concerns, which is the property R1a was written to
establish.

Recorded while resolving, as a smaller instance of the same gap: R1's signature does not state
`offeringId`'s type, and the two callers supply different ones (`resource_link_id` is a decimal string,
`PortalOffering.id` is a number). Both interpolate into the request path correctly, so unlike the above
this is not a defect, but the type is worth pinning in the signature since R8a already depends on the
distinction.

---

### QA Engineer

#### RESOLVED: Both things R14 says the second run "proves" are outside what the harness can observe, and one is the identical error Round 2 corrected in R14a
**Resolution**: **R14** now claims only what the driver asserts, safe re-entry with a populated
`tokenCache` and `stepResults`, which is the reason worth keeping the run-twice shape for and which no
other verification covers. Token reuse is demoted to manual inspection alongside R14a's absent `PUT`, with
the mint-line count named as the thing to look at, and the end-to-end idempotency claim is withdrawn in
favour of the portal-side `find_or_create_by` verification the Technical Notes already hold. Both
withdrawals are recorded in R14 rather than silently deleted, since the run-twice shape survives and a
reader needs to know why.

R14 states that running `openTargetOffering` twice "proves two things, not one: the second run reuses both
cached tokens, and it rewrites the same values against unchanged stub state, which exercises **R3's
idempotency end to end** rather than inferring it from the portal's `find_or_create_by`."

**Verified that neither claim holds, for two different reasons.**

**Token reuse is observable but not assertable**, which is word for word the defect Round 2's QA lens
found in R14a's "no `PUT` reaching the stub" and corrected there. `run-step.js`'s `checkRun` (lines 47-53)
inspects only `result.success` and a substring of `result.summary` or `result.message`. A cache hit
manifests as the **absence of a second mint line** in the stub's stdout: `mintCounter` is module state in
the stub process (`stub-portal.js:15,101-103`), and the stub is a separate process whose log the README
places in terminal 2 while the driver prints in terminal 3. The README already classifies this category:
"Everything else the harness exercises is **shown in the logs for manual inspection**, not asserted"
(README:48). Round 2 fixed the neighbouring requirement and left this one standing.

**The idempotency claim is stronger than the harness can ever support, and this half is new.** The stub
holds **no state at all**: `lockResponse` (`stub-portal.js:133-144`) returns a hardcoded 200 body and never
consults or records the request. Confirmed live by starting the stub and issuing the open path's own write:

```
$ curl -X PUT .../api/v1/offerings/556/update_student_metadata -d "locked=false&active=true&user_id=..."
{"active":true,"locked":true}
```

The stub answers an unlock with `locked: true`. So "it rewrites the same values against unchanged stub
state" is trivially true and proves nothing: there is no state to be unchanged. The second run establishes
only that the step does not crash on re-entry. R3's real guarantee is exactly the portal's
`find_or_create_by` then `update!`, which the spec elsewhere verifies against rigse and which a stateless
stub cannot stand in for, so the claim to test it "end to end rather than inferring it from
`find_or_create_by`" is backwards: inference from the portal source is the *only* evidence available, and
it is already recorded.

Why this matters beyond tidiness: R14 is one of only two harness requirements, and both of its stated
justifications for the run-twice shape are unsound, which invites a reviewer to drop the second run as
redundant. It is still worth keeping, for a reason R14 does not give: a second run re-enters the step with
a **populated** `tokenCache` and a populated `stepResults`, which is the only place any verification
exercises re-entry at all. Suggested resolution: reword R14 to claim what the driver asserts (success and
summary on both runs, and therefore safe re-entry), demote token reuse to manual inspection alongside
R14a's `PUT` absence with the mint-line count named as the thing to look at, and drop the end-to-end
idempotency claim in favour of pointing at the portal-side verification the Technical Notes already hold.

---

#### RESOLVED: R13a's stated reason is the opposite of what happens, and after the rename its content is already in R13
**Resolution**: **R13a** is rewritten to say the true and useful thing: the inherited exact-body assertion
is **updated** rather than supplemented, it is a **build-breaking** dependent, and no spring-specific
assertion is needed because the migration leaves one code path. Kept as a requirement rather than deleted,
with the false rationale recorded, precisely because the wrong version invites writing the redundant test.

R13a: "Spring's changed write is asserted by its own test, since the migration adds `active=true` to a
body the existing suite pins exactly **and would otherwise stay green through the change**."

**Verified by making the change and running the suite.** The two halves of that sentence contradict each
other, and the code settles it against the second: `lock-activity.test.ts:68-75` asserts the request with
`toHaveBeenCalledWith` on a **whole object literal**, including `body: "locked=true&user_id=27"`. Adding
`active: "true"` to the step's `URLSearchParams` and running the file gives
`Tests: 1 failed, 10 passed`, on exactly that assertion:

```
    -   "body": "locked=true&user_id=27",
    +   "body": "locked=true&active=true&user_id=27",
```

So the suite goes **red**, not green. It is a build-breaking dependent, which is how the migration
question's own "Dependents to update" list correctly describes it ("`lock-activity.test.ts`'s body
assertion (gains `active=true`)"). R13a inherited its rationale verbatim from REPORT-81's precedent
("the changed case gets its own test, because the existing suite would otherwise stay green through a
behavior change"), where it was true because that change was not pinned by an exact assertion. Here it is.

The second half of the problem is that R13a has no residual content. Both cohorts run **one** handler
after the migration, spring's entry differing only in its `name` and `processingMessage`, so "spring's
changed write" and the fall lock write are the same request and the same assertion, which R13's first
bullet ("the two-flag body for lock and for unlock") already requires. Suggested resolution: fold R13a
into R13 as a note that the existing exact-body assertion must be **updated** rather than supplemented,
and record that this is a build-breaking dependent so it is not mistaken for a new test to write. If R13a
survives as a separate requirement it should say the thing that is actually true and useful, that no
spring-specific assertion is needed because the migration leaves one code path.

---

### Test Infrastructure Engineer

#### RESOLVED: No class word the harness serves carries an arm suffix, so every `openTargetOffering` scenario fails at R7b before it ever reaches the name match R15 was strengthened to enable
**Resolution**: added **R15b**, requiring a `-shark`-suffixed class word to carry the multi-offering list
and noting that R14a's treatment scenario needs a `-gator` word which needs no class fixture at all, since
**R1b** (added by the Implementer Reading Cold finding below) makes the arm check short-circuit before the
class read. The two findings resolve into each other, which is why the fixture consequence is stated in
both.

R14 requires the driver to be able to "**seed the `originClassWord` handoff**", and R15 requires the stub
to serve a multi-offering class with one offering "named **exactly the module constant**". Neither says
anything about the class **word** that gets seeded, and R7b makes "a class word carrying neither arm
suffix" a permanent classified failure returning `TELL_TEACHER_MESSAGE`.

**Verified against the fixtures.** The harness knows exactly two class words, `fl-spring-2026-origin` and
`ft-fall-2026-a` (`config.js:50-51`), and `CLASSES_BY_WORD` is keyed on precisely those two
(`stub-portal.js:57-60`). Checked both against `DESTINATION_SUFFIX`
(`fall-random-assignment.ts:23`, `{ treatment: "-gator", control: "-shark" }`):

```
  fl-spring-2026-origin -> arm UNCLASSIFIABLE (R7b permanent failure)
  ft-fall-2026-a        -> arm UNCLASSIFIABLE (R7b permanent failure)
```

So a scenario that seeds either existing word fails on the suffix check, before the mint, before the class
read, and before the name match. The harness would report a passing tell-your-teacher failure while the
by-name matching R15 exists to prove is never executed. R14a needs a **second** word besides that, ending
`-gator`, since the treatment no-op is selected by the suffix; that one needs no class fixture at all if
the arm check short-circuits (see the Implementer Reading Cold finding below), which is worth stating so
the fixture work is not over-scoped.

This is Round 2's R15 gap one level up. That round found that nothing required an offering named the
constant, "so as previously specified the by-name match would have resolved nothing and every
`openTargetOffering` scenario would have failed". The same sentence is true today of the class word, and
the fixture that satisfies R15 cannot be reached without it. Suggested resolution: extend R15 to require
a class whose word carries the **control** (`-shark`) suffix, carrying the multi-offering list including the
constant-named offering, and note that R14a additionally needs a `-gator` word. Worth adding for the same
reason R15 records its own limit: the harness can prove the classifier and the matcher agree with the
fixtures, never that either names the right real-world thing.

---

#### RESOLVED: The stub can neither display nor honour the two-flag write, so R2 is invisible to the manual inspection R14a designates and R20's harness log contradicts the open path
**Resolution**: added **R15c**, requiring the stub to log `active` alongside `locked` and to echo the
request's flags rather than hardcoding them. Both are one-line changes. Having the stub persist per-student
rows was again declined, as Round 2 declined it: that is a harness capability this story would own, and
echoing the request is not that.

R14a's resolution deliberately routes what the driver cannot assert to "manual inspection, matching how
the harness README classifies every other unasserted observation". R2, the two-flag write, is this story's
central correctness requirement.

**Verified live**, by starting the stub and issuing the exact write `openTargetOffering` makes:

```
$ curl -X PUT .../api/v1/offerings/556/update_student_metadata -d "locked=false&active=true&user_id=im-done-student-1"
{"active":true,"locked":true}

[stub] PUT /api/v1/offerings/556/update_student_metadata -> 200 [lock] auth=Bearer <len=4> {"locked":"false","user_id":"im-done-student-1"}
```

Two distinct problems, both one-line fixes:

1. **`active` is absent from the request log.** `logFields`'s `lock` case returns
   `{ locked: body.locked, user_id: body.user_id }` (`stub-portal.js:206`). So the single most important
   thing to eyeball, that both flags went out on every call, is the one field the log omits, and manual
   inspection cannot confirm R2 no matter how carefully it is performed.
2. **The response ignores the request.** `lockResponse`'s default is a hardcoded
   `{ active: true, locked: true }` (`stub-portal.js:142`). Since R20 logs "the `{active, locked}` the
   portal returned", the open path's success log in the harness will read `locked: true` for a write that
   requested `locked: false`, which is a diagnostic that says the opposite of what the step did. The
   harness is where a developer reads that log line for the first time, and R20 deliberately declines to
   compare, so nothing catches the contradiction.

Note the interaction with the previous finding's `find_or_create_by` point: making the stub echo the
request body is also the cheapest thing that would let a second run mean anything, since it is the
minimum state a re-write can be observed against. Suggested resolution: add `active` to the `lock` case of
`logFields`, and have `lockResponse`'s success branch echo the request's `locked` and `active` rather than
hardcoding them. Both belong to R15's stub work. Whether to go further and have the stub persist per-student
rows is a harness capability this story would then own, which Round 2 already considered and declined for
the same reason; echoing the request is not that, and it costs one line.

---

### Implementer Reading Cold

#### RESOLVED: Nothing requires the arm check to short-circuit before the mint and the class read, so half the fall cohort can pay two portal calls to do nothing
**Resolution**: added **R1b**, stating the ordering as a requirement rather than a note, since it also
settles R15b's fixture question (a `-gator` scenario needs no class in the stub) and keeps the
`metadata[]` array out of a path with no use for it.

The control-only conditional question resolves that `openTargetOffering` owns the arm check, and argues
"**the arm check is free here and only here**: R7 already requires this step to read `originClassWord` to
resolve the target class, so classifying the arm inspects a string it is holding." That establishes the
check costs nothing extra. It does not establish **where in the step it runs**, and the spec never orders
the seven things the step does (read the handoff, classify the arm, mint, read the class, match the name,
compare against `resource_link_id` per R8a, write).

**Verified as unconstrained by anything else in the spec or the verifications.** R14a asserts success and
a did-nothing summary for the treatment path, both of which a late check produces identically to an early
one, and R13's treatment no-op case asserts no `PUT` is issued, which a late check also satisfies. So an
implementer who classifies the arm after the class read (a natural reading, since R7 introduces the class
read as the way the target is resolved and the arm check is described as a by-product of the same string)
ships a step that mints, issues `GET /api/v1/classes/info`, holds the whole class body including every
offering's `metadata[]`, and then returns a no-op, for **every treatment student at the post-test stage**.
The mint itself is free by R11, since `lockCurrentOffering` ran first in the same stage and the token is
cached, so the real cost is one class read per treatment student, roughly half the cohort, plus needlessly
holding the array R16 exists to keep out of logs on a path that has no use for it.

Low severity, which is why it is recorded here rather than as a numbered requirement on its own: nothing
is incorrect, and the cost is one GET on a path that runs once per student per stage. It is worth a
sentence because the fix is free at authoring time and awkward later, and because it removes the fixture
question the previous finding raises: if the arm check precedes the class read, R14a's `-gator` scenario
needs no class in `CLASSES_BY_WORD` at all. Suggested resolution: state in the control-only conditional
decision, or in R1's description of `openTargetOffering`, that the arm check runs **immediately after the
handoff read and before any portal call**, and note the fixture consequence for R14a.

---

#### RESOLVED: R15's preferred "import the compiled constant" gives `stub-portal.js` its first dependency on a build, and R1 never says the constant is exported
**Resolution**: **R15** now keeps the fixture string as a literal in `config.js` with a **unit test
asserting it equals the exported constant**, which is the fallback this finding proposed rather than its
first suggestion. On reflection it is not a fallback but the better answer: it gives identical rename
protection, keeps `stub-portal.js` buildless, and puts the check where every other verification in this
story lives, so the `existsSync`-guard machinery is not needed at all. **R1** now says the constant is
exported, which the unit test requires just as the import would have.

R15 prefers "having the stub **import the compiled constant** over retyping the string, so a rename cannot
silently desync the fixture from the step", and dismisses the cost on the grounds that "the harness already
requires a build for `run-step.js` and `run-all.js`, so that dependency is not new in kind".

**Verified that it is new in kind for the one process it lands on.** `stub-portal.js` requires exactly
`http`, `fs`, `./config` and `./scenarios` (lines 10-13): no compiled code, and therefore no build. Nor
does `run-all.js`, which shells out through `execFileSync` and requires only `./scenarios`; its build
dependency is transitive, through the driver it invokes. That driver handles the missing-build case
deliberately and well, guarding with `fs.existsSync(COMPILED_STEP)` and exiting 2 with
`Missing ${COMPILED_STEP}. Run: npm run build` (`run-step.js:63-66`). A bare `require` at the top of
`stub-portal.js` has no such guard and would throw `MODULE_NOT_FOUND`, and `lib/` is absent from a fresh
checkout (confirmed: it does not exist in the working tree). The ordering makes it land badly: the README's
run instructions start the stub in terminal 2, before the driver in terminal 3, so the first symptom of an
unbuilt tree becomes a stack trace from the process a developer starts first, replacing a clear
"Run: npm run build".

Also, and smaller: R1 calls the target name "a module constant" and the Q1 decision says "the constant's
module carries a comment", but nothing says it is **exported**, which R15's import requires. An
implementer following R1 alone would reasonably write an unexported `const`.

Suggested resolution: keep the import, since the desync it prevents is the more expensive failure, but
require the same `existsSync` guard and "Run: npm run build" message the driver already uses, and state in
R1 that the constant is exported. If that is judged too much machinery for a fixture string, the fallback
is to keep the literal in `config.js` beside the class words and have a **unit** test assert it equals the
exported constant, which catches a rename at the same place everything else in this story is verified and
leaves the stub buildless.

---

### Spec Editor

#### RESOLVED: "Files this story touches" is stale in six ways and contradicts two resolved decisions outright
**Resolution**: the subsection is **rewritten from the resolved decisions** rather than patched, and
grouped into new / renamed away / edited / deliberately-not-touched, so the last group stops the rename
being over-scoped in the other direction. The duplicate dead `metadata`-narrowing sentence in the
class-read subsection is replaced with the R7a caution that subsection is now the right home for. Done now
rather than at finalization, since finalization rewrites only the two overviews.

The Technical Notes' closing subsection predates Rounds 2 and 3 and was not updated by either. Round 3 was
a consistency pass that caught two Round 2 falsifications (a Background bullet and the two overviews) and
did not reach this one.

**Verified by reading the spec against itself.** The section currently reads:
`lock-activity.ts` (generalized, likely renamed), its test, `portal-reads.ts` (narrow `metadata`, add the
by-name match if it belongs there), `stub-portal.js` and `scenarios.js`, `run-step.js` (a scenario for the
new step). Against the resolved decisions:

1. **"narrow `metadata`" is dead.** R17 is withdrawn, and R2a states the story "reads no per-student state
   at all". The same dead instruction appears a second time in the class-read subsection: "the only change
   to `portal-reads.ts` is narrowing `metadata` from `unknown[]` if the step needs to read it."
2. **"`run-step.js` (a scenario for the new step)" contradicts R14**, which was rewritten in Round 2
   specifically to say this is "**driver work, not just a scenario**" and to name the three hardcoded
   things that have to change. The files list still carries the framing R14 was corrected away from.
3. **"likely renamed" is settled**, not likely: the migration decision names `offering-state.ts`,
   `lock-current-offering.ts` and `open-target-offering.ts`, with `lock-activity.ts` going away as a git
   rename.
4. **`fall-programs.ts` and `fall-random-assignment.ts` are missing**, both required by R18.
5. **`index.ts` and `index.test.ts` are missing**, the latter being the one dependent Round 2 flagged as
   **build-breaking** rather than cosmetic.
6. **The harness README is missing**, whose "Extending it for the fall stories (REPORT-80/82)" section R14
   requires be fixed (confirmed present at README:121-131, and it does conclude "No portal plumbing changes
   are needed"). `config.js` is missing too, which the arm-suffix finding above adds to the list.

It matters because this is the section an implementer sizes the work from, and every omission is
work that a resolved requirement elsewhere already mandates. Suggested resolution: rewrite the subsection
from the resolved decisions rather than patching it, and delete the second dead `metadata`-narrowing
sentence in the class-read subsection. Worth doing before finalization rather than at it, since the
Overview rewrite at finalization will not touch Technical Notes.

---

### Verified correct, no change proposed

Recorded so a later reader does not re-run these. Against rigse `6f4c49288` and this repo's working tree.

- **R18's move does not create an import cycle.** Expected one, since `DESTINATION_SUFFIX` is typed
  `Record<Arm, string>` and `Arm` lives in `assignment-doc.ts` while `fall-programs.ts` is the destination.
  Refuted twice over: `assignment-doc.ts` imports nothing from `fall-programs.ts` (its `pooledProgramScope`
  takes `program: string`, deliberately untyped by program id), so the edge is one-way; and `Arm` is used
  only in type position, so TypeScript elides the import entirely and no runtime edge is added either.
  `fall-programs.ts` also stays free of `firebase-admin`, which `assignment-doc.ts` imports, for the same
  reason.
- **The treatment no-op summary does not leak arm assignment to the teacher.** Checked because
  `send-email` renders every step's `summary` into the teacher-notification email, so a no-op line reading
  "nothing to open" would identify the student's arm. It is not a new disclosure: `fall-random-assignment`
  already returns `summary: "Assigned to ${destinationClassWord}"`, and the destination word carries the
  `-gator` / `-shark` suffix, so the email exposes the arm today. Teachers are not blinded, and the
  `-shark` and `-gator` subclasses are visible to them in the portal regardless.
- **The roster's locked checkbox stays a coherent completion record in both arms.** Checked because the
  open path deliberately unlocks an activity the control student has **not** completed, against R19's rule
  that the locked flag *is* the completion record. It holds at every point: treatment students' curriculum
  is locked at the curriculum stage (completed), control students' curriculum is unlocked at the post-test
  stage (not completed, correctly reading as unfinished) and then locked when they finish it at the
  curriculum stage. "Curriculum locked" means "finished the curriculum" throughout, for both arms.
- **The endpoint's student-membership check is satisfied on the open path.**
  `update_student_metadata` 404s unless the target user is in `offering.clazz.students`
  (`offerings_controller.rb:57-60`). The open path's target is selected from the `offerings[]` of the origin
  class (R7, R10), which is the subclass the student launched the post-test from and was enrolled into by
  REPORT-79's step, so membership holds structurally rather than by luck. The same structural argument as
  R10's, applied to a different check.
- **R20's logged body carries no names, so it does not reopen R16.** The action renders
  `metadata.as_json(only: [:active, :locked])` (`offerings_controller.rb:66`), confirmed against the stub's
  shape too. Two booleans, no `students[]`, no `metadata[]`.
- **The rigse checkout the Technical Notes cite is the one on disk.** `git log` in
  `/home/doug/projects/rigse` gives `6f4c49288`, so every line reference in Rounds 1 through 3 was
  re-checkable and the ones re-checked this round all matched.

## Self-Review (Round 5)

Ten lenses. Five produced findings. One lens is new to this round (**Launch-Day Responder**, which asks
what the logs and the two failure strings let a human do at 9am on launch day, rather than whether the
step is correct); the rest are re-runs, weighted toward **Spec Editor**, because Round 4 made roughly a
dozen edits and, unlike Round 2, received no consistency pass afterwards.

**Every finding below was verified against code before it was written down**, against the rigse checkout
at commit `6f4c49288` (re-confirmed as the one on disk) and this repo's working tree. The shipped suite
was run first to establish a baseline: `Test Suites: 12 passed`, `Tests: 298 passed`. Where the evidence
is a shipped test rather than a throwaway, the shipped test is cited, since it is stronger: it cannot be
lost when the throwaway is deleted.

**Two study-flow sources were consulted this round, and their precedence matters.** Rounds 1 through 4
verified against code in two repos; this round also read *AI in Math: "I'm Done" Button Flow* (Doug
Martin for Trudi Lord, 29 July 2026) and the REPORT-80 and REPORT-82 Jira tickets. The flow document is
a **question** document: its Q1 through Q5 are asks, phrased as "that is what will be built, unless you
say otherwise". **The PI's answers live in REPORT-82's ticket**, under "Update, 29 July 2026: PI
answers", and where the two disagree the ticket wins. Reading the flow document's proposals as settled
produced one confidently-argued and entirely wrong finding this round, retracted below in
"Checked and refuted". Its **setup** facts (the class table, which sequence lives in which class, which
class each stage launches from) were not superseded by her answers and are good evidence; its
**proposed behaviour** was.

**Nothing in this round changes what the story builds.** The caller census, R1's shape, R1b's
control-only check and R7c are all confirmed correct against the tickets. The five findings are a false
sentence about class composition, a requirement that overstates a recoverability guarantee, and three
documentation or verification defects.

**Playwright was not applicable and was not used.** This story is Cloud Functions code with no browser
UI of its own. Its only user-visible surface is two strings the activity player renders, and its only
browser-reachable dependency is the portal's teacher progress roster, which lives in rigse behind a
staging login; driving that would verify rigse's UI rather than anything this spec decides. The
portal-side facts this round rests on (what a `locked` offering does to a student's view and run
button) were verified in rigse source instead, which is where the behaviour is decided.

### Education Researcher

#### RESOLVED: R8a's plausibility rests on there being three offerings in the class; there are two, which makes R8a provably complete rather than merely justified

**Resolution**: the Round 2 sentence is corrected in place, with a note recording what it said and why
the correction strengthens rather than weakens R8a, and the completeness argument is moved up into
**R8a** itself, where it now states the two-offering case analysis and ties completeness to the class
composition R7c records.

Round 2's Portal API finding, which created R8a, argues its plausibility this way: "It is a same-class,
same-teacher, wrong-offering write, and **the three fall sequences live in one class** with
author-controlled names, so a constant typo among them is the plausible cause rather than an exotic
one."

**That sentence is false, and the truth is better for R8a.** The study-flow document's class table gives
registration classes "Green only" and both study classes "Blue and Orange", and states the reason as a
design constraint rather than an accident: "A student stays in their registration class after being
added to a study class. **That's why Blue and Orange must live only in the study classes.**" Green, the
pre-test, is therefore never in the class the write lands in, and cannot be, since a student who kept
both memberships would otherwise see the pre-test twice. Nothing in the PI's 29 July answers touches
this: those answers changed what the curriculum-stage button does, not where the sequences live.

So at the post-test stage the class holds exactly **two** offerings: Orange, the post-test, which is the
run's own `resource_link_id`, and Blue, the curriculum, which is the intended target. **Every** name that
resolves at all resolves to one of those two, so R8a plus the intended target exhaust the space, and R8's
no-match rule covers everything else. R8a is not merely a guard against a plausible typo; it is the
complete second half of a two-element case analysis, and the only wrong name that resolves is the one it
catches.

**Why correcting it matters in both directions.** A reader who believes the class holds three sequences
will read R8a as a partial mitigation and may widen it, most naturally by reaching for a guard against a
constant naming the pre-test, which is unreachable: the pre-test is not in the class, and a name that
matches nothing takes R8's no-match exit. A reader who instead notices the sentence is false may conclude
R8a is unjustified and drop it, since a typo among three names is the only argument recorded for it. Both
readings are wrong, and both are invited by one sentence that does not match the study setup. It survived
because Round 2 wrote it as colour on a finding rather than as a claim about class composition, and
Round 3's consistency pass did not reach it.

Suggested resolution: correct the sentence in the Round 2 finding to name the two offerings, and move the
completeness argument up into **R8a** itself, where it belongs and where it is stronger than what R8a
currently says for itself. Note beside it that completeness follows from the class composition R7c
records, so if that composition ever changes the argument has to be re-run.

---

### Checked and refuted, no change proposed

Two candidates were developed far enough to be written up before the evidence that killed them was
found. They are recorded with that evidence so a later round does not re-raise them, and because the
second one is a warning about which document to trust.

- **The post-test's launch class is unrecorded as a precondition.** Raised because R7b's arm check
  depends on the post-test being launched from the `-gator` / `-shark` study class rather than the
  registration class, and R7c records the curriculum's placement without mentioning the post-test's.
  **Refuted as a gap**: the fact is true and already recorded where it is actionable. The study-flow
  document states it ("At the pre-test the student launches from their registration class ... At the
  post-test they launch from their Gator or Shark class"), and REPORT-82's ticket carries both the
  mechanism and the reason no fallback exists: "The step determines the arm from the class word of the
  offering the student launched from, which ends in -Gator or -Shark ... It must not try to read the
  stored randomization assignment: that record is keyed on the pre-test launch (offering plus class
  context) and the post-test launch differs on both, so it is not addressable from this job." That
  matches what was independently verified here in `assignment-doc.ts:64-72,110-116`, where both scopes
  hash the pre-test's `interactiveId` and `resource_link_id`. Background's assertion in this spec is
  therefore consistent with the story that owns the wiring, and adding it to R7c would duplicate rather
  than fix.

- **The caller census misses a second open-target caller (the curriculum stage opening the post-test).**
  Raised on the strength of the study-flow document's **Q1**, which quotes the PI's randomization
  document ("When the treatment students complete the Blue Sequence, the I'm Done button will be used to
  trigger unlocking the Orange Sequence for them") and says "That is what will be built, unless you say
  otherwise". **Refuted decisively**: she said otherwise. REPORT-82's ticket records the answer under
  "Update, 29 July 2026: PI answers", headed "**The curriculum-stage button locks the curriculum and does
  not open the post-test (PI answers, supersedes two requirements above)**", quoting her: "**NO. We are
  going to open the post-test on a specified date.**" The same section supersedes "Curriculum stage: open
  the post-test" in both the full-time and the flex flow, records the compensating lock ("For treatment,
  the blue should lock"), and states the knock-on for this story explicitly: "this removes the use case
  that motivated the open-target capability ... Its remaining confirmed consumers are lock-current at the
  pre-test and post-test stages, and the control-only unlock at the post-test stage." That is this
  spec's caller census exactly: three lock callers, one open caller. **The census is correct and needs no
  change.**

  **The lesson, which is the reason this is written up rather than deleted.** The study-flow document is
  a **question** document, written to be answered. Its Q1 through Q5 are asks, and its prose states
  Doug's intended build "unless you say otherwise". Reading its proposed answers as settled facts
  inverts its purpose. **The Jira tickets carry the answers**, and REPORT-82's 29 July update is where
  the PI's answers to that document live. A future round consulting the flow document must consult
  REPORT-82's update alongside it, and where they disagree the ticket wins. The document's *setup* facts
  (the class table, which sequence lives in which class, which class each stage launches from) were not
  superseded by her answers and remain good evidence, which is why the R8a finding above still stands on
  them.

---

### Portal API reviewer

#### RESOLVED: R19a is false in exactly the failure bucket that tells the student to try again, and R13's test for it cannot be written as worded

**Resolution**: **R19a** is rewritten to scope the guarantee to a write the portal did not apply, to
state the lost-response exception with its classification path and the rigse evidence that the student
is locked out, and to accept it rather than fix it, since detecting it needs the read-back R3 forbids.
**R12**'s lock bullet now says retry is honest in the dominant case and names the exception as what its
second clause exists for. **R13**'s R19a case becomes the assertable half, one write and no retry, with
the reason the portal-state half is not a unit concern recorded so it is not re-added.

R19a states, without qualification, that "a failed lock must leave the offering **unlocked and
therefore re-clickable**, which is what makes it self-healing", and R12 leans on it directly: "Retry is
honest here: a failed lock leaves the activity unlocked (R19a), so a re-click retries."

**Verified false for the lost-response case, which is the case that gets the retry advice.** There is
no retry and no timeout anywhere in the transport: `performPortalRequest` is a bare
`await fetch(...)` whose thrown error propagates to the step's `catch` (`portal-api.ts:25-34`). A throw
is classified with `status: 0`, and `classifyPortalFailure` sends anything that is not a 4xx and not a
mint-422-expired to `PortalFailureBucket.Generic` (`portal-api.ts:176-185`), which
`messageForBucket` renders as the step's own retryable message. Both halves are pinned by the shipped
suite rather than by a throwaway: `lock-activity.test.ts:149-156` asserts the generic message on a 500
and `lock-activity.test.ts:182-194` asserts it on a thrown fetch.

So the three ways the response can be lost after the write has landed on the portal, a proxy 502/504
after Rails committed, a connection dropped after the request was processed, and a Cloud Functions
timeout, all arrive in the bucket whose copy is "Please try again".

**And after a landed write the student cannot try again**, which is what turns a bad message into dead
advice. rigse resolves student access row-wins-else-offering in both places that matter: the student
policy's `show?` ends `return !locked` under the comment "if the offering is locked, the student cannot
see it" (`offering_policy.rb:60-68`), and the run button's `href` becomes `javascript:void(0)` with a
`disabled` class (`runnables_helper.rb:30-38`). A successfully locked offering is unreachable, which is
the whole point of locking it; the defect is that the student is told to re-enter it.

The consequence is bounded but real, and it is the one case where all three signals disagree: the
roster says finished, the student is told the recording failed and to retry, and the retry is
impossible. The message's second clause ("or contact your teacher") is what saves it, which is an
argument for the wording R12 already chose, not for R19a's absolute form.

**REPORT-82's ticket already records the same mechanism as a known residual**, which is worth citing
because it means the two stories currently disagree in writing. Its 29 July update, arguing for
lock-before-email at the curriculum stage, ends: "One residual worth knowing rather than fixing: a
failure at any step after the lock reports failure to the student even though their completion is by
then recorded, and **they cannot retry because they are locked out**. That is cosmetic rather than a
data problem, since the roster is correct." That residual is about a *later step* failing after a
successful lock; this finding is about the lock's own response being lost. The path differs and the
resulting state is identical, and REPORT-82 has the honest version while R19a has the absolute one.

**The second half is that R13's verification cannot exist as worded.** R13 requires a unit test
asserting "**R19a**, that a failed lock leaves the offering unlocked, which nothing asserts today and
on which every self-healing claim rests". A unit test drives the step with a mocked
`portalTokenFetch`; it has no portal and therefore no offering whose resulting state it could assert.
This is the same category of error Round 2 corrected in R14a ("no `PUT` reaching the stub" is not
something the harness can assert) and Round 4 corrected again in R14, arriving this time at the unit
level. What a unit test **can** assert, and what is worth asserting, is that a failed write is issued
exactly once and not retried, so the step contributes nothing beyond the single `PUT` whose outcome is
unknown.

Suggested resolution: qualify R19a to the case it is true for, a write the portal did not apply, and
state the exception, a landed write whose response was lost, which leaves the student locked out
holding retry advice. Keep R12's wording, whose "or contact your teacher" clause already covers the
exception, and record that as the reason it is worded that way. Replace R13's R19a case with the
assertable property (one `PUT`, no retry, failure returned) and say why the portal-state half is not a
unit concern.

---

### Spec Editor

#### RESOLVED: Round 4's rewrite of "Files this story touches" dropped two dependents the migration decision enumerates, one of them the migrated step's only end-to-end coverage

**Resolution**: both added to "Files this story touches", the two `messageIncludes` strings as their
own bullet marked **assertion-breaking** (parallel to `index.test.ts`'s **build-breaking** marking) and
carrying the reason they matter, that they are the migrated step's only end-to-end coverage after the
migration; `enroll-specified-class.ts:72` added as cosmetic, so a reader can see it was considered. The
three `failsAt` labels are named in the same bullet as explicitly cosmetic.

Round 4's Spec Editor finding rewrote "Files this story touches" from the resolved decisions, on the
stated grounds that "this is the section an implementer sizes the work from, and every omission is work
that a resolved requirement elsewhere already mandates". The rewrite fixed the six staleness items it
enumerated and lost two entries the migration question's own "Dependents to update" list carries.

**Verified by reading the two lists against each other and against the harness.**

1. **The two harness scenarios that assert the lock message.** `scenarios.js:85` (`lock-server-error`)
   and `scenarios.js:90` (`lock-network`) both carry
   `messageIncludes: "Unable to lock your pre-test"`, and `run.js:98` **asserts** it
   (`const messageOk = typeof message === "string" && message.includes(expect.messageIncludes)`).
   R12 replaces that string, so both scenarios fail until they are updated. The rewritten files list
   mentions `scenarios.js` only for additive work: "(the `openTargetOffering` and treatment-no-op
   scenarios)".
   **This is worse than a missing line, because of what those scenarios are.** R14 and R14a are the
   story's only harness requirements and both drive `openTargetOffering`. The three `lock:` scenarios
   (`lock-forbidden`, `lock-server-error`, `lock-network`) are driven by `run.js` through the whole
   spring pipeline, so after the migration they become the **only** end-to-end exercise of the step
   being migrated. The files list currently has an implementer editing the harness for the new step
   while leaving the migrated step's own coverage red.
2. **`enroll-specified-class.ts:72`.** Confirmed present and exactly as the dependents list describes:
   a prose comment reading "Like lock-activity / send-email, this step makes NO host check of its
   own". Cosmetic, but it appears in **neither** the rewritten Edited list nor the
   "Deliberately not touched" list, which is the list that exists to stop the rename being
   over-scoped in the other direction. A reader of the rewritten section cannot tell whether it was
   considered.

Also absent, and genuinely cosmetic, so noted here rather than argued: the three
`failsAt: "lock-activity"` labels (`scenarios.js:80,85,90`). `failsAt` is printed and not asserted
(`run.js:109-111`), exactly as the dependents list says, so this one costs nothing if missed.

Suggested resolution: add both to the rewritten section, marking the two `messageIncludes` strings as
**assertion-breaking** in the same way `index.test.ts` is marked **build-breaking**, and put
`enroll-specified-class.ts:72` in whichever of the two lists is correct. The general lesson is worth a
line too: the rewrite replaced a list rather than merging into it, which is how entries that were right
in the old one were lost.

---

### Launch-Day Responder

#### RESOLVED: R16's diagnostic allowance is a closed list, and on the branch R16 itself calls the launch-day branch it permits nothing that identifies the fault

**Resolution**: **R16**'s allowance now extends explicitly to the class's offering **names** on the
no-match branch, with the four causes it separates spelled out, the names-not-objects limit stated so
`metadata[]` is not dragged along, and the reason the extension has to be explicit (the rest of the
requirement is a prohibition, so silence reads as a ban). **R13** gains a case asserting the no-match log
carries them, deliberately on the same fixture as R13b's privacy assertions.

R16 ends with a positive allowance: "Diagnostic logs carry the offering id, the offering name, and the
resolved class word, all authored and environment-stable." It then names where this matters most:
"This matters most on the R8 no-match branch, which is both the branch someone will reach for when
diagnosing a launch-day failure and the one holding the whole class body."

The two sentences do not fit together. **On the no-match branch there is no resolved offering**, so two
of the three permitted fields do not exist. What an implementer can log within the allowance is the
name being looked for and the class word, which produces a line of the form "no offering named X in
class Y". That line is true and useless: it is byte-identical whether the constant is stale after a
portal-side rename, the student launched from the wrong class, the target's runnable was archived out
of `teacher_visible_offerings`, or the subclass was built without the curriculum. Those four have
different owners and different fixes, and R7c already flags archival as the residual REPORT-82 should
carry into pre-launch checks, so distinguishing them is exactly what launch day needs.

**The field that distinguishes them is the class's offering names, and R16 neither permits nor forbids
it.** `get_info` renders each offering as `{ id, name, active, locked, metadata, url, external_url }`
(`classes_controller.rb:150-165`), and `name` delegates to the runnable
(`portal/offering.rb:26`), so it is an authored activity title with the same properties R16 accepts for
the singular offering name it does permit: authored, environment-stable, neither PII nor a token.
Logging the list turns the useless line into "looked for X in class Y, which holds [A, B, C]", which
separates all four causes at a glance and needs no second request.

**Why the omission is not neutral.** R16's surrounding text is a prohibition on interpolating the class
body, and the array immediately beside `name` in that body is `metadata[]`, which R16 forbids by name
in its own clause. An implementer reading the whole requirement conservatively, which is how a privacy
requirement should be read, will log nothing off the class body at all. The requirement's shape
therefore actively discourages the one safe field, on the one branch it identifies as the diagnostic
branch.

One caveat that belongs in the resolution rather than against it: offering names are teacher-authorable
in general, even though the study's are authored by the curriculum team, so the allowance should be
stated deliberately rather than left to be inferred. That is an argument for writing it down, which is
this finding.

Suggested resolution: extend R16's allowance to name the class's offering **names** (not the offering
objects, which would drag `metadata[]` along) as permitted on the R8 no-match branch, with the
reasoning attached, and give R13's no-match case an assertion that the log carries them. Keep the
`metadata[]` prohibition exactly as it is; the two clauses are compatible and the contrast is what
makes the allowance defensible.

---

### Test Infrastructure Engineer

#### RESOLVED: R14's surviving justification still claims a re-entry property the driver does not produce, because `run-step.js` never writes back into `stepResults`

**Resolution**: **R14** takes the second option, since it is the better one: the claim stands and the
driver is made to earn it. `stepResults` accumulation is added as a third piece of driver work beside
per-scenario step selection and the seeded handoff, with the observation that `run-step.js` builds its
context once and never writes back where `index.ts:81` does, and that this also makes the harness model
the real runner.

Round 4 rewrote R14 to "claim only what the driver asserts", withdrawing the token-reuse and
end-to-end-idempotency claims. What survived is: "What running twice actually asserts is **safe
re-entry**: the second run enters the step with a populated `tokenCache` and populated `stepResults`,
and the driver checks success and the summary on both runs."

**Verified that half of that is not a property of the second run.** `run-step.js` builds the context
once, before the loop (`const context = buildContext(scenario.targetClassWord, createPortalTokenCache())`,
line 78), and the loop body is `const result = await enrollSpecifiedClass(context)` (line 82). It
**never** assigns into `context.stepResults`, which is what `index.ts:81` does in the real runner. So
whatever the driver seeds under R14's new seeding requirement is present identically on run 1 and run
2, and `stepResults` cannot distinguish them. The only state that actually differs between the two runs
is the token cache, which `getScopedPortalToken` populates on the first mint
(`portal-api.ts:208-220`).

This is small, and it is recorded as the weakest finding in the round: the run-twice shape survives
regardless, the driver's assertions are unchanged, and nothing ships differently. It is worth a line
because R14 has now been corrected twice for claiming more than the harness delivers, and the residual
claim would be the third instance if left standing. It is also cheap to make true rather than to soften:
having the driver write each run's result into `context.stepResults` under the scenario's step name is
one line, matches what `index.ts` does, and would make the second run genuinely a re-entry with
accumulated state.

Suggested resolution: either narrow the claim to the token cache, which is the only state that differs,
or add the write-back to the driver work R14 already requires and keep the claim, which is the better
answer since it also makes the harness model the real runner more closely.

