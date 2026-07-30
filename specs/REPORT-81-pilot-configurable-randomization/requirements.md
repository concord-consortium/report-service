# Pilot-Configurable Randomization for the Fall Study

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-81

**Repo**: https://github.com/concord-consortium/report-service

**Implementation Spec**: [implementation.md](implementation.md)

**Status**: **In Development**

> ✅ **Both questions to the PI were answered on 2026-07-29 (Trudi, Slack). One of them grew this story.**
>
> **1. The pre-test's demographic wording: confirmed unchanged.** The step identifies a student's demographic
> answers by matching question wording and exact answer-choice labels, and this spec had *assumed* the fall
> Green pre-test reuses spring's. The PI confirmed it does. Her one refinement, that "Other/not sure" may be
> grouped with a Module 4 option, is already the shipped behaviour: everything that is not one of the two full
> module titles falls to `Other`. No code change follows. The wording still lives in a **named configuration
> object per pre-test**, so a later correction stays a one-object edit. See Open Question 1.
>
> **2. Flex balances across all three sections, not within each: this story grows.** The PI's answer was
> "Flex should be across ALL THREE SECTIONS. All flex kids are considered in the same group." The assignment
> document is currently keyed per class, so this requires a **program-dependent assignment scope**, a change
> to a shipped mechanism (`computeAssignmentDocId`). It is scoped into this story deliberately rather than
> slipped in (Doug, 2026-07-29), because the resolved program is already this story's product. ⚠️ The fix is
> **not** the one Self-Review ER-2 originally sketched: excluding `context_id` alone does not pool flex, and
> excluding enough to pool it would collide the two programs. See "Assignment scope" in the Requirements.

## Overview

Make the "I'm Done" randomization step select its strata table and its demographic inputs from the student's
program, resolved at run time from their class word, so that one shared pre-test button can randomize both
fall cohorts correctly. This story also delivers the piece that resolves the class word in the first place,
which the sibling fall stories depend on.

## Project Owner Overview

The fall study runs two programs, full-time and flex, and randomizes students in each into a treatment
(Gator) or control (Shark) class when they finish the Green pre-test. The two programs balance their groups
differently: flex balances on four demographic answers, while full-time balances within each teacher's class
on two. Today the pipeline has exactly one hardcoded table, built for the spring pilot.

Because the PI wants a **single shared pre-test button** serving both programs, the button cannot be
configured with which program it belongs to. The system therefore has to work that out for itself at the
moment a student clicks, from the class word the student registered with. This story teaches it to do that
and to pick the right balancing table as a result. It has no visible effect on its own; it is the piece that
makes the fall study's group assignment correct, and correct group assignment is what the study's validity
rests on.

## Background

The spring-2026 pipeline's `random-assignment` step (`functions/src/tasks/ai4vs-flvs/random-assignment.ts`)
does four things in sequence: reads four demographic answers from Firestore, maps them to a stratum, looks
up (or reuses) a treatment/control assignment for that stratum in a `jobs-task-data` transaction, and enrolls
the student in the resulting class using `treatment_class_id` / `control_class_id` request parameters. It
carries one baked-in 24-row table.

Three things change for the fall.

**Two programs, two tables (O6).** Flex reuses the existing 24-row Gender x Race x Grade x Module table and
reads all four demographic answers. Full-time uses a new 20-row Gender x Race x Teacher table, randomizes
*within* teacher, and reads only Gender and Race; the teacher comes from the student's class, not from an
answer.

**The program is resolved, never authored (O14).** A single Green button serves both cohorts, so there is no
`pilot=` parameter to distinguish them. The program is classified from the student's origin class word by
prefix, `FT-` or `FL-`. Following the DT-20 alignment review (2026-07-29), the resolved program selects a
**randomization table only**. It does not select a pipeline: both cohorts run identical stages, so
`PIPELINES` is keyed by stage and the pipeline dispatcher is unchanged.

**Nothing currently consumes the origin class word.** REPORT-79 shipped `resolveOriginOffering` in
`functions/src/tasks/portal-reads.ts` and defined `StepOutput` on `StepResult` carrying only
`destinationClassWord`. The read **does** have one caller already, `send-email` (`send-email.ts:85`), but it
uses only the `clazzId` half of the result and ignores `classWord`; REPORT-79's own spec is precise about
this, saying the class-word resolve "has no consumer yet". This story is first in the dependency order to need
the class word itself, needs it twice (teacher stratum, and deriving the `-Gator` / `-Shark` destination), and
REPORT-80 and REPORT-82's differential step need it after that. So this story owns producing it.

Enrollment is no longer this step's job. REPORT-79 delivered a separate `enroll-specified-class` step that
takes a destination class word from `output.destinationClassWord` and enrols against it, so the fall
randomization step derives and publishes the destination word rather than calling the portal itself.

## Requirements

### Resolving the origin class word

- **A `resolve-origin-class` step** runs first in the fall pipelines. It obtains a teacher-scoped portal token
  via `getScopedPortalToken`, calls `resolveOriginOffering` with the run's `resource_link_id`, and publishes
  the resulting class word on `StepResult.output` as **`originClassWord`**, alongside the existing
  `destinationClassWord` field.
- The step **mints once**; steps that need the **class word** read it from `stepResults` rather than re-reading
  the offering. The existing per-run `tokenCache` means later steps needing the same scope reuse the token.
- **One pre-existing duplicate read is knowingly left in place.** `send-email` calls `resolveOriginOffering`
  itself (`send-email.ts:85`) to obtain the offering's `clazzId`, which it needs for
  `send_class_teachers`. So a fall stage containing both steps issues `GET /api/v1/offerings/:id` twice per
  run. This is accepted rather than overlooked: the second call is cheap, reuses the cached token, and
  removing it means either publishing `clazzId` alongside `originClassWord` and rewiring `send-email`, or
  having `send-email` reach into another step's output. Both are changes to a step this story otherwise does
  not touch, so the tidy-up belongs with REPORT-82's stage wiring, where the step order is being decided
  anyway. Recorded so it is a choice on the record rather than a redundancy nobody noticed.
- **Consuming steps read the class word from `stepResults`, with no defensive ordering check.** Pipeline order
  is assumed correct (Doug, 2026-07-29): REPORT-82 is responsible for placing this step first in each stage,
  as it is for step order everywhere else, and a mis-ordered stage would fail on the first harness run. All
  three fall stages need the class word, so there is no case in which the step is present but unused.
- **An absent `class_word` is a classified failure**, not a silent fallback. REPORT-79 deliberately omitted
  the two-call fallback on the grounds that these pipelines only ever mint teacher tokens, so the
  teacher-gated field is always present; an absent one indicates a real anomaly and must surface as the
  tell-your-teacher message. REPORT-79's spec assigns this behaviour to the consuming story, which is this one.
- The class word is safe to log (authored, environment-stable, not PII, not a token). Tokens are never logged.

### Classifying the program

- **A classifier maps the origin class word prefix to a program**: `FT-` to full-time, `FL-` to flex.
- **An unrecognised prefix is a classified failure** with a student-facing message, never a silent default to
  either program. Defaulting would silently randomize a student using the wrong table and corrupt the study
  arm they land in.
- The resolved program selects **three things and no more: the strata table, the demographic input set, and
  the assignment scope** (see "Assignment scope" below). It must not select a pipeline, and this story must
  not change the pipeline dispatcher in `ai4vs-flvs/index.ts`.

### Demographic question matching

- **The question prompts and answer-choice labels move into two named configuration objects, one per
  pre-test**, out of the module-level constants they occupy today. Each object holds the four prompt
  substrings and the choice-label maps for one pre-test.
- **Selection is structural, not a lookup.** The spring step references spring's object; the fall step
  references the fall's. Nothing is keyed by `pilot` and nothing is resolved at run time, which is the same
  argument that makes a mode conditional unnecessary: the pipeline already selects the step, and the step
  already knows its pre-test. There is therefore no key to miss and no key string for another story to match.
- **Why not a pilot-keyed table** (which Open Question 1 originally chose): Open Question 2's decision D,
  taken the same day, made the step itself the selector, which leaves a keyed table adding a lookup that can
  miss while selecting nothing the step does not already know. The property Open Question 1 actually wanted,
  that a late correction to the fall pre-test's wording is a one-object edit rather than a redesign, is fully
  preserved by a named constant. See Self-Review finding SE-5.
- **One fall object serves both programs.** A single shared Green pre-test means a single set of prompts and
  labels. What varies by program is the *dimension set* (full-time reads Gender and Race, flex reads all
  four), which is resolved from the class word and is a separate axis from wording.
- **The fall object is specified as identical to spring's** prompts and choice labels, **confirmed by the PI
  on 2026-07-29** (see Open Question 1). It is recorded in code with that date and attribution, so a reader
  knows it was verified rather than assumed.
- **Spring's object is unchanged**, so this story alters neither spring's prompts nor its choice labels.
  (Spring's *assignment* behaviour does change in one narrow case, because it shares the extracted core; see
  "The one deliberate change to spring" below.)
- Matching semantics are unchanged: prompts by case-insensitive substring, choice labels by exact match after
  trim. Loose or fuzzy matching is explicitly rejected, because a mis-matched demographic silently places a
  student in the wrong stratum, corrupting a study arm rather than stopping the pipeline.

### The two tables

- **Flex** reuses the existing 24-row Gender x Race x Grade x Module table and reads all four demographic
  answers. Verified 2026-07-29: all 24 rows of the shipped `ASSIGNMENT_TABLE`, including which arm each
  stratum starts on, match the PI's source document exactly, so this table carries over unchanged.
- **Full-time** uses the 20-row Gender x Race x Teacher table, four strata per teacher across five teachers,
  reading **only** Gender and Race. **The table is reproduced in full below**, because this spec is its only
  committed copy (Self-Review QA-4).

#### The full-time table (source of truth)

Read from the PI's randomization document on 2026-07-29 and transcribed here **in the source document's row
order**, which the alternation criteria below depend on. `n1` is the arm the **first** student in a stratum
receives; the second gets the opposite, alternating from there.

| # | Gender | Race | Teacher | Surname (stratum key) | n1 |
|---|---|---|---|---|---|
| 1 | Female | White | Alyssa Bingler | Bingler | treatment |
| 2 | Male | non-White | Alyssa Bingler | Bingler | control |
| 3 | Male | White | Alyssa Bingler | Bingler | treatment |
| 4 | Female | non-White | Alyssa Bingler | Bingler | control |
| 5 | Female | White | Kayla Hankamp | Hankamp | control |
| 6 | Male | non-White | Kayla Hankamp | Hankamp | treatment |
| 7 | Male | White | Kayla Hankamp | Hankamp | control |
| 8 | Female | non-White | Kayla Hankamp | Hankamp | treatment |
| 9 | Female | White | Kristi Long | Long | treatment |
| 10 | Male | non-White | Kristi Long | Long | control |
| 11 | Male | White | Kristi Long | Long | treatment |
| 12 | Female | non-White | Kristi Long | Long | control |
| 13 | Female | White | Courtney Newlon | Newlon | control |
| 14 | Male | non-White | Courtney Newlon | Newlon | treatment |
| 15 | Male | White | Courtney Newlon | Newlon | control |
| 16 | Female | non-White | Courtney Newlon | Newlon | treatment |
| 17 | Female | White | Maria Torres | Torres | treatment |
| 18 | Male | non-White | Maria Torres | Torres | control |
| 19 | Male | White | Maria Torres | Torres | treatment |
| 20 | Female | non-White | Maria Torres | Torres | control |

**Checked mechanically on 2026-07-29** against the transcription above: 20 rows, 5 distinct teachers, 5
distinct surnames, 4 strata per teacher, 10 treatment and 10 control, each teacher's block alternating
internally, and the block boundaries between rows 4/5 and 8/9 **not** alternating, which is what makes this
five blocks rather than one continuous sequence.

**Why the table lives here and not only in the working notes.** Its previous only copy was the PI's Google
document, reachable only through a comment on QI-140, which is being deleted. It was then transcribed into
oob `im-done-button/qi-140-design.md` §4b, which is deliberately uncommitted, unversioned, single-machine
scratch. Reproducing it in this committed spec is what makes it survive. The oob copy remains the working
note; **this table is the reference an implementer and a reviewer check against.**

**On the teachers' full names.** Reviewed and settled (Doug, 2026-07-29): **teacher names are not PII for this study's purposes; only student names are.** The repository is public and the table is committed here deliberately, so `teacherFullName` stays on each row, where it keeps the transcription checkable against the PI's source document. The code needs only the surname (the stratum key, the lookup and the assignment document all use it alone), so the full name remains a documentation field rather than an input.
- **The starting arm alternates by teacher** in the full-time table (Bingler treatment, Hankamp control, Long
  treatment, Newlon control, Torres treatment). This is the source document's "Alternate n1" instruction and
  must be preserved exactly.

#### Two mechanisms that look like one, and must not be merged

- **Within-teacher balancing comes from the assignment document, not from the table.** The document id
  includes `context_id` (`computeAssignmentDocId`, `:221-229`), so each class has its own strata and its own
  alternating counters. Within one full-time class only four of the twenty strata can occur (Gender x Race),
  so that class's students already alternate among themselves whatever the table's teacher column says.
- **The teacher column exists to set each teacher's starting arm**, which spreads the *leading edge* of every
  stratum across classes. Without it, all five classes would seed their `Female|White` cell identically, so
  the first student in that cell in each class would receive the same arm, producing a systematic tilt across
  the cohort. The alternation **reduces** that tilt rather than cancelling it: with five teachers, an odd
  number, the best any cell can do is 3 to 2. Checked against the table, `Female|White` and `Male|White` seed
  3 treatment to 2 control, and the two non-White cells seed 2 to 3, so the residue offsets across cells and
  the table is 10 to 10 overall. That is a property of the PI's design, not a defect to fix here; it is stated
  so nobody later reads "balances the leading edge" as a stronger claim than the table can support.
- ⚠️ **Therefore the teacher dimension stays in the stratum key even though it appears redundant for
  balancing.** Removing it leaves within-class balance intact and every test passing while silently
  destroying the seed alternation. This note exists because that is an easy and invisible mistake to make.
- **A full-time student must not be required to answer the flex-only questions.** The step reads Grade and
  Module for flex students only. A full-time student who skipped them must still randomize successfully.

### Assignment scope: which students share one balancing pool

The PI confirmed on 2026-07-29 that **all flex students are one group across all three sections**, and that
full-time randomizes within teacher as before. Those are different pooling rules, so the assignment document's
identity becomes program-dependent.

- **Full-time keeps today's key exactly**: `interactiveId | platform_id | resource_link_id | context_id`
  (`computeAssignmentDocId`, `:221-229`). Each full-time class gets its own document and its own alternating
  counters, which is what delivers "randomize within teacher". **The shipped mechanism is untouched on this
  path.**
- **Flex uses a pooled key** that resolves to one document for the whole flex cohort, so the 24 strata fill
  across all three sections and alternation actually operates within each cell.
- **The scope is computed by the step and passed into the shared core.** The core does not decide it and holds
  no conditional; it receives a document identity the way it already receives a strata table.
- **Spring is unchanged.** Its step keeps the existing per-class key, so no spring document changes identity.

#### Two traps in the pooled key, both of which the obvious fix falls into

- ⚠️ **Excluding `context_id` alone does not pool flex.** `resource_link_id` **is the offering id**, and an
  offering is per class per activity (`Portal::Offering belongs_to :clazz, :runnable`). The three flex sections
  are three classes, so they launch the same Green activity through **three different offerings** and three
  different `resource_link_id` values. A key that drops only `context_id` still yields three documents.
  `resource_link_id` must be excluded too.
- ⚠️ **But excluding both would collide the two programs.** Dropping `resource_link_id` and `context_id`
  leaves `interactiveId | platform_id`, and O14's single shared Green button means full-time and flex share
  one `interactiveId`. All eight classes would land in one document, silently destroying full-time's
  within-teacher balancing. **The pooled key must therefore include the resolved program**, so flex pools
  within flex and full-time is unaffected.
- These are recorded because each is individually plausible and the second is invisible: it leaves every test
  passing and produces a cohort that looks balanced while full-time's teacher seeding has stopped meaning
  anything.
- ⚠️ **The resolved program in the pooled key is year-qualified** (`fall-2026-flex`), decided
  2026-07-29 during implementation planning. Pooling silently removes a safety property the per-class key
  has for free: the per-class key contains the offering and the class, so a new cohort re-keys the document
  automatically, whereas the pooled key's three components are all stable across cohorts. `interactiveId` is
  the authored embeddable's `ref_id`, a property of the **activity** rather than of the class or the year, and
  `platform_id` is the portal. So an unqualified `flex` would silently land a later flex cohort, or a second
  intake on the same activity, in this study's document: alternation counters would continue from wherever
  it left off instead of from the table's `n1`, the document would keep growing against the 1 MiB ceiling,
  and a student appearing twice would keep their original arm. This is a single RCT and probably will not be
  repeated, but the qualifier costs nothing and the failure would be silent. See implementation.md Open
  Question 4.

#### Accepted consequences of pooling

- **Document size.** The pooled flex document accumulates one entry per student per stratum rather than one
  per section. At the study's expected flex enrolment this is a few KB against Firestore's 1 MiB per-document
  limit, comfortable but no longer trivially bounded, so it is stated rather than assumed.
- **Contention.** Every flex assignment now transacts on one document instead of three. The worker is already
  serialized by `rateLimits: { maxConcurrentDispatches: 1 }` (`task-worker.ts:70-73`), so this changes
  throughput, not correctness. ⚠️ The flag matters: `maxInstances: 1`, cited here previously, bounds
  *instances* on a v2 function and would not on its own prevent concurrent dispatches to one instance. The
  conclusion is unchanged and better supported than it was. See implementation.md finding DO-I2.
- **The per-student de-duplication walk is unaffected.** It still walks at most 24 strata; only the `users`
  map within each stratum grows.

### Deriving the teacher stratum

- **The teacher stratum is derived from the origin class word, not from a demographic answer.**
- ⚠️ The PI's table keys on the teacher's **full name** (`Alyssa Bingler`) while the class word carries only
  the **surname** (`FT-2026-Bingler`). **The transcribed strata are keyed on the surname**, with the teacher's
  full name carried as a **field on each row** so the row is self-documenting and the transcription stays
  checkable against the source document.
- Surname keying rather than whole-class-word keying is deliberate: the design randomizes **within teacher**,
  not within class. These coincide today (five classes, one teacher each), but if a second section is ever
  added for one teacher, surname keying keeps that teacher's students balanced as a single pool.
- **A guard asserts the table holds exactly five distinct teacher keys**, so a future roster change that
  introduced two teachers sharing a surname would be caught rather than silently colliding.
- **A class word whose surname is not in the table is a classified failure**, consistent with how an
  unmatched stratum is handled today (`random-assignment.ts:376-382`), never a silent miss.

### Structure: two thin steps over a shared core

- **The demographic reading, category mapping and alternating-assignment transaction are extracted into a
  shared module.** The spring step becomes "read demographics, assign, enrol by class id"; the fall step
  becomes "read demographics for the program's dimension set, assign from the program's table, publish the
  destination class word".
- **No step contains a mode conditional.** The pilot is an authored button parameter and always present, so
  `PIPELINES[request.pilot]` already selects a different step list: spring's list holds the spring step, the
  fall lists hold the fall step. Nothing is inferred from a missing parameter.
- **The spring pipeline's orchestration is unchanged**, including the enrol-by-id path REPORT-83 migrated onto
  the minted token. Its one behavioural delta is the shared core's de-duplication scope, stated next.

#### The one deliberate change to spring

- **Spring inherits the per-student de-duplication**, because that behaviour lives in the extracted core both
  steps call. This is intended, not incidental. The delta is exactly one reachable case: a spring student
  whose stratum changed between two clicks previously received a **second** assignment under the new stratum
  key, and now keeps their original arm. Nothing else about spring changes.
- **Why this is correct rather than merely convenient.** ER-1's decisive argument is that `add_to_class` only
  adds: a second assignment cannot move a student, it can only enrol them into a second class alongside the
  first, contaminating both arms. That argument is about the enrolment primitive, not about which cohort is
  running, so it applies to spring identically. Preserving spring's current behaviour would be preserving the
  defect and calling it a contract.
- **Blast radius is nil**: `spring-2026` is dormant (Doug, 2026-07-29). The change is being made because it is
  right, not because it is urgent.
- **The changed case must be pinned by a test**, so it is recorded as intended behaviour rather than left as
  an incidental consequence of the extraction. No test covers it today
  (`random-assignment.test.ts:900` covers only a *same-stratum* re-click), so the change would otherwise land
  with a fully green suite.
- Rejected: parameterizing the core with a per-pilot dedup scope to keep spring bit-identical. That requires
  the mode conditional this story explicitly forbids, and doubles the test matrix to protect a path nobody
  wants.

### Assignment behaviour

- **Assignment is de-duplicated per student, not per (stratum, student).** Inside the existing transaction,
  walk the document's strata for the student's `platform_user_id` and return the first assignment found. Only
  a student found nowhere falls through to the assignment logic. **First assignment wins, permanently**: a
  student's arm is fixed at the first click that gets past the completion check, and later edits to their
  demographic answers change their recorded demographics but never their class.
- Stated precisely, because the walk is very slightly weaker than that sentence: a student who already holds
  an arm keeps it and is **never issued a second one**. On a document where a student already holds *two*
  arms, reachable only from a pre-REPORT-81 spring run, the arm returned is whichever stratum Firestore
  yields first. Checked on the emulator, map fields came back in insertion order so the first-written arm
  won, but that ordering is not a documented guarantee, and such a student is already enrolled in both
  classes, so no behaviour here improves or worsens their case. See implementation.md finding SE-I5.
- **Why**: today's lookup indexes straight to `strata[currentStratum].users[...]`
  (`random-assignment.ts:245-258`), so a student whose stratum changes between clicks is not found and is
  assigned again. That is reachable, because the pre-test is locked only *after* a successful run: any failure
  between assignment and lock (an enrol error, an expired mint) returns the student to an unlocked pre-test
  where they can edit an answer and click again. The consequence is not a misplaced student but a student
  holding **two** assignments, and since `add_to_class` only adds and this pipeline has no way to remove
  anyone, re-bucketing cannot move a student, it can only enrol them into a **second** class while leaving
  them in the first, contaminating both arms invisibly.
- **The walk must not write.** Returning early leaves the current stratum's `nextAssignment` counter
  untouched, so a re-clicking student never consumes a rotation slot in a stratum they are not counted in, and
  the next genuinely new student in that stratum still receives the arm the counter specifies.
- **Cost and storage are unchanged.** The record already exists at
  `sources/{source_key}/jobs-task-data/{docId}` and already survives reloads, second clicks, redelivery and
  cold starts. This changes only which lookup is performed against a document the transaction already reads in
  full. At most 24 strata are walked. No new collection, no schema change, and no flat index (a second
  structure to keep consistent is not worth optimising a 24-key scan).
- ⚠️ **The de-duplication fixes the arm, not the destination, and one same-arm double-enrolment path stays
  open.** ER-1's argument is that `add_to_class` only adds, so a second assignment enrols a student into a
  second class alongside the first and contaminates both arms. The walk closes that. But
  `destinationClassWord` is re-derived on every run from the origin class word resolved *that run*, so a
  student whose origin class changes between two clicks keeps their arm (correct) and receives the new
  section's or teacher's destination word. If the first click's enrolment had already succeeded and the run
  then failed before `lock-activity`, which is the same "enrolled but not locked" window ER-1 relies on, they
  end up enrolled in two destination classes. **Both are in the same arm**, so no arm is contaminated and
  study validity is intact; this is a roster-tidiness problem for a teacher rather than a data-integrity
  problem for the PI, which is why it is accepted and stated rather than fixed. **Rejected**: persisting the
  destination word beside the arm and reusing it, which would put a second value in the assignment document
  and make a legitimate mid-study class change unfollowable. See implementation.md finding ER-I1.
- **Accepted impurity**: a student who edits their answers after assignment stays counted in their original
  stratum's balance while their recorded demographics say another. This is strictly better than holding two
  assignments, and it cannot be corrected retroactively in any case, since the original stratum's rotation
  counter was already advanced.

- Otherwise unchanged from spring: assignment remains **balanced within each stratum**, alternating treatment
  and control in arrival order from the table's starting arm, and the persisted per-student assignment
  continues to live in `jobs-task-data`, written in a transaction.

### Handing off the destination

- The step derives the destination class word as **origin class word + `-gator`** (treatment) or **`-shark`**
  (control) and publishes it as `output.destinationClassWord` for REPORT-79's `enroll-specified-class` step
  to resolve and enrol against.
- ⚠️ **Corrected 2026-07-29 during implementation planning: the suffixes are lowercase, and the origin class
  word arrives lowercase.** This requirement previously said the derived word matches "the class-words
  spreadsheet's casing", which the portal makes impossible. `Portal::Clazz` lowercases and strips
  `class_word` before validation on every save (rigse `app/models/portal/clazz.rb:28-30`), and
  `offerings#show` serves the stored value (`app/models/api/v1/offering.rb:98`), so `FT-2026-Bingler` reaches
  this pipeline as `ft-2026-bingler`. The destination classes are created from the same spreadsheet and are
  therefore stored lowercase too, so lowercase suffixes make the derived word byte-identical to the stored
  one; a mixed-case suffix would resolve only through MySQL's case-insensitive collation. **The
  `resolve-origin-class` step publishes the class word normalized to the portal's stored form**, which is the
  invariant the prefix classifier, the surname lookup and REPORT-80 and REPORT-82 all inherit. See
  implementation.md Open Question 1, which records how the drafted case-sensitive version failed all eight
  of the study's class words.
- **No raw class ids** appear in code or authored configuration. The spring `treatment_class_id` /
  `control_class_id` request parameters are not used by the fall path.
- **This step performs no enrolment and no portal write.** Its only portal interaction is the read needed to
  resolve the origin class word.

### Failure handling and secrecy

- Portal failures route through the shared `classifyPortalFailure` / `messageForBucket` helpers to the same
  coarse student messages REPORT-83 established (reload / tell-your-teacher / generic).
- **The two new configuration failures both give the tell-your-teacher message**: an origin class word with
  neither an `ft-` nor an `fl-` prefix, and a full-time class word whose surname is absent from the table.
  Neither uses the generic bucket, which implies "try again" and would be false, since both are permanent
  until someone edits configuration.
- **The same rule is applied to the fall path's other permanent failures** (added 2026-07-29 during
  implementation planning; see implementation.md Open Question 2). A demographic answer the pre-test
  configuration cannot interpret, which covers an unmapped choice label, an unknown choice id and a
  duplicated prompt, is an **authoring** fault and gives tell-your-teacher rather than the retry message.
  This matters because it is reachable and launch-likely: `mapToCategory` throws on an unmapped Gender
  choice, so any option the fall pre-test adds that the configuration lacks would otherwise dead-end every
  student who picks it behind an invitation to keep clicking (finding ER-4). An unmatched flex stratum is
  treated the same way, though it is unreachable from data, since the 24 rows are exactly the cross product
  of the categories the mapping can emit. A **transport** failure keeps the retry message, because there
  retrying is honest advice. **Spring is unchanged**: it keeps one generic message for both.
- **Both log at `error` level and include the offending value** (the unclassifiable class word, or the
  unmatched surname), which is what actually diagnoses the fault. Both are safe to log: authored,
  environment-stable, neither PII nor a token. Error level matches REPORT-79's precedent for
  study-validity failures.
- No token value is ever logged, and no real teacher name reaches a log or a `StepResult`. `send-email`
  renders every prior step's `summary` into the teacher-notification email, so `summary` carries only
  non-PII display values.

## Acceptance Criteria

**Program resolution**
- The `resolve-origin-class` step publishes the student's origin class word as `originClassWord`, and a later
  step in the same run obtains it from `stepResults` without performing an offering read of its own to get it.
  (`send-email`'s separate read for `clazzId` is pre-existing and out of scope; see the Requirements note.)
- A class word beginning `ft-` resolves to full-time and one beginning `fl-` to flex, matched against the
  normalized (lowercased) form the portal stores and `resolve-origin-class` publishes.
- A class word with neither prefix stops the pipeline with the tell-your-teacher message and an **error** log
  containing the offending class word.

**The full-time table**
- All **twenty** strata resolve to an assignment; none falls through as unmatched.
- **All twenty `n1` values match the transcription**, asserted individually, so a single mistyped cell is
  caught wherever it sits.
- **The five block starts are asserted separately**: Bingler treatment, Hankamp control, Long treatment,
  Newlon control, Torres treatment. This catches an entire teacher's block transcribed with inverted polarity,
  which is the most plausible transcription error given the table's alternating layout, and which the
  per-cell assertions would flag without explaining.
- Within a teacher's block the four strata alternate; the sequence is **not** one continuous alternation down
  all twenty rows.
- A full-time student is assigned using Gender and Race only, and succeeds without Grade or Module answers.
- A full-time class word whose surname is absent from the table stops the pipeline with the tell-your-teacher
  message and an **error** log containing the unmatched surname.
- A demographic choice the fall configuration cannot map stops the pipeline with the **tell-your-teacher**
  message, not the retry message, and logs the offending label; a transport failure still gives the retry
  message.
- `ft-2026-bingler` resolves to the strata labelled `Alyssa Bingler`.

**The flex table**
- All twenty-four existing strata continue to resolve, with each stratum's starting arm unchanged from the
  shipped table.
- A flex student is assigned using all four demographic answers.

**Assignment scope**
- **Two flex students in *different* sections, with identical demographics, receive opposite arms.** This is
  the criterion that proves pooling: it fails under both the current per-class key and the insufficient
  "exclude `context_id` only" key, because in each of those the two students seed separate counters and both
  receive the table's `n1`.
- Two flex students in the **same** section with identical demographics also receive opposite arms, so pooling
  does not break within-section alternation.
- **Two full-time students in different classes, with identical demographics, both receive their teacher's
  seed arm** and do not alternate against each other. This is the guard against the collision trap: it fails
  if the pooled key is applied to full-time.
- A full-time student's assignment document identity is **unchanged from the shipped key**, asserted directly
  against `computeAssignmentDocId`, so the untouched-mechanism claim is verified rather than assumed.
- A `spring-2026` student's assignment document identity is likewise unchanged.

**Assignment behaviour**
- A student assigned once and clicking again receives **the same** assignment.
- A student whose stratum **changes** between clicks still receives their original assignment, and the new
  stratum's rotation counter is **not** advanced by that second click.
- Within a stratum, consecutive new students alternate arms starting from the table's value.

**Handoff and scope**
- The step publishes `destinationClassWord` as the origin class word plus `-gator` or `-shark`,
  byte-identical to the form the portal stores, and makes no portal write of its own.
- The `resolve-origin-class` step publishes the class word normalized to the portal's stored form, so a
  mixed-case or space-padded `class_word` in the response still yields `ft-2026-bingler`.
- The `spring-2026` pipeline's orchestration is unchanged, including its enrol-by-class-id path, and its
  demographic prompts and choice labels are unchanged.
- **The spring step's one behavioural delta is asserted, not assumed**: a `spring-2026` student who already
  holds an assignment under one stratum, and whose demographics then place them in another, receives **their
  original arm**, and the second stratum's rotation counter is not advanced. Before this story the same
  input produced a second, opposite assignment.
- No token value and no real teacher name appears in any log or in a returned `StepResult`.

**Emulator-backed proof of the shared core**
- The per-student de-duplication is exercised against a **real Firestore transaction on the emulator**, not a
  mock: a student is assigned, their stratum is then changed, they are re-assigned, and the original arm is
  returned while the second stratum's rotation counter is left unadvanced. This calls the extracted core
  directly and needs no pipeline.
- **Why this one cannot be a unit test.** The existing suite mocks `runTransaction` wholesale
  (`random-assignment.test.ts:44-59`), so a mocked test asserts only that the walk was written as intended,
  never that it behaves correctly inside a real transaction. This is the single behaviour the story invents,
  and it is the one a mock cannot establish.
- **Program-level end-to-end runs are REPORT-82's**, since they prove stage wiring rather than this story's
  core; see Out of Scope and Self-Review finding QA-3.

## Technical Notes

- **Files.** `functions/src/tasks/ai4vs-flvs/random-assignment.ts` (450 lines) holds the current step and its
  baked-in table; `random-assignment.test.ts` (974 lines) covers it thoroughly, including a case per stratum.
  The origin read is `resolveOriginOffering` in `functions/src/tasks/portal-reads.ts`. `StepOutput` is in
  `functions/src/tasks/ai4vs-flvs/types.ts`.
- **Demographic matching, as it exists today.** `DIMENSION_CONFIGS` (`:22-27`) finds each answer by searching
  the question prompt for a substring: `"your sex"`, `"race or ethnicity"`, `"grade are you in"`,
  `"Algebra 1 module"`. `mapToCategory` (`:186-217`) then matches the chosen answer text **exactly after
  trim**: `GENDER_MAP` accepts `Female` / `Male` / `Prefer not to answer`, **mapping the third to `Female`**
  (`:33`), so Gender is binary in every stratum key; `GRADE_MAP` accepts `6th` through `12th Grade` plus
  `Other`; Module matches two full titles and defaults everything else to `Other`; Race accepts `White` and
  reduces everything else to `non-White`. **All of this is spring's wording.**
- **The Gender collapse is carried forward deliberately, and is worth stating plainly** (Self-Review ER-4).
  A student who declines to state their sex is counted as **Female** for balancing. It is intentional in the
  shipped code, pinned by a test (`random-assignment.test.ts:383`), but **no design rationale for the choice
  of bucket is recorded anywhere**, in this repo or in the working notes. Two things bound it: the PI's
  full-time table has exactly four strata per teacher (Gender x Race) with no third gender row, so a binary is
  forced by the table rather than chosen by the code; and the collapse affects only which rotation bucket a
  student lands in, since the answer documents retain the real choice and later analysis can still distinguish
  non-responders. It nevertheless matters more in the fall than it did in spring: Gender x Race is the
  **entire** full-time stratification (four cells), where spring spread the same students across
  twenty-four.
- **Rejected: alternating non-responders between Female and Male** to stop them inflating one side. It would
  make a student's stratum depend on arrival order, breaking the property that stratum is a function of
  demographics alone.
- **Sequence-wide answer scope (O1).** The answers query spans the whole sequence, since a multi-activity
  sequence shares one `resource_link_id`. This is what makes a duplicated demographic question hazardous:
  `findAnswerByPrompt` throws when more than one answer matches a prompt substring (`:151-153`).
- **Auth.** Reuse REPORT-83's `getScopedPortalToken` (teacher scope), `portalTokenFetch`,
  `classifyPortalFailure`, `messageForBucket`, and the per-run `tokenCache` on `StepContext`. The step makes
  no host check of its own and assumes the `validatePortalHost` setup gate ran before the pipeline loop; it
  uses `StepContext.portalOrigin` for portal calls, never the raw `jobDoc.platform_id`.
- **Class words (fixed configuration, not code).** Full-time origins `FT-2026-Bingler`, `-Hankamp`, `-Long`,
  `-Newlon`, `-Torres`; flex origins `FL-2026-Section1`, `-Section2`, `-Section3`. Each splits into
  `<origin>-Gator` and `<origin>-Shark`. ⚠️ **That is the spreadsheet's casing, which is not the casing the
  code sees.** The portal lowercases every class word on save, so this pipeline receives
  `ft-2026-bingler` and derives `ft-2026-bingler-gator`. Match lowercase everywhere; see the correction under
  "Handing off the destination".
- **Local harness.** `functions/harness/im-done-local/` runs the pipeline against a stub portal. Its
  `config.js` seeds demographic answers using **spring's prompts and choice labels**, so new fixtures are
  needed for the fall strata, and the harness is the natural place to prove full-time randomization without a
  real portal.
- **Sequencing: ✅ satisfied. REPORT-79 merged to `master` on 2026-07-29** (PR #405), so this story branches
  from `master` and the contingency below never had to be used. `StepOutput`, `resolveOriginOffering` and
  `enroll-specified-class` are all on `master` now; `portal-reads.ts` exists and is no longer branch-only.
  _Original decision, kept because it explains why the order mattered:_ the intended order was REPORT-79
  first, then the shared-core extraction, and if REPORT-79 had not merged, the work would branch from
  **REPORT-79's branch rather than from `master`**, because extracting a shared core underneath a type still
  in review invites a painful rebase. `random-assignment.ts` had also been modified recently by REPORT-83's
  mint cutover, so it was moving on two fronts.
- **One thing to re-read before extracting, because it landed after this spec was written.** REPORT-79's
  merge included a review fix (`aa15607`) that added success-body validation to `lookupClassByWord` and
  widened `PortalClass.id` to `number | string`. Neither affects this story's design, but the enrol step's
  header comment now also records why two disagreeing `destinationClassWord` handoffs resolve by pipeline
  order rather than failing. That is the same "our own pipeline wiring is assumed correct" principle this
  spec applies when consuming steps read `originClassWord` from `stepResults` with no ordering guard, so keep
  the two consistent if either is revisited.
- **Upstream context.** DT-20 alignment review, 2026-07-29, recorded in oob `im-done-button/`
  (`dt-20-alignment-review.md`, `decisions-log.md`, `qi-140-design.md` §4b for the transcribed table).

## Out of Scope

- **Adding the fall pipelines and their stage wiring** (REPORT-82), including the stage-keyed `PIPELINES`
  entries and the control-only differential step. This story adds steps; it does not wire them into a pilot.
  **Naming the fall `pilot` values is therefore REPORT-82's call, and this story deliberately does not depend
  on it** (see SE-5). Cleaning up the stale `pilot: "fall-2026-fulltime"` in
  `harness/im-done-local/run-step.js:34`, a name `qi-140-design.md:157` dropped on 2026-07-29, belongs with
  that work; it is inert today but is the only fall pilot string in the tree.
- **The offering-state step** (REPORT-80), though it consumes this story's `originClassWord`.
- **Enrolment** itself (REPORT-79's `enroll-specified-class`), which this story hands off to.
- **The spring-2026 pipeline's behaviour**, with one deliberate exception: it inherits the per-student
  de-duplication from the shared core (see "The one deliberate change to spring"). Its orchestration, its
  enrol-by-class-id path, its demographic wording and its assignment document identity are all untouched.
- **Any portal (rigse) change.** This story consumes existing endpoints as they are.
- **Authoring the fall buttons and the Green pre-test activity**, which are done outside this repo.

## Self-Review

_Requirements-only review, 2026-07-29. Roles: Education Researcher, Senior Engineer, QA Engineer, Product
Manager. WCAG skipped (no UI); Performance skipped (one added portal read per run)._

### Education Researcher

#### RESOLVED: ER-1. A student who changes a demographic answer between clicks can be assigned twice

**Resolution (Doug, 2026-07-29): applied.** De-duplication is now specified per student, implemented as a walk
of the document's strata inside the existing transaction, returning early and writing nothing. See
"Assignment behaviour" in the Requirements. The decisive argument is not study-design purity but that
`add_to_class` only adds: re-bucketing cannot move a student, only enrol them into a second class alongside
the first. Note the framing correction made during review: this is **stratified alternation**, not
randomization, since demographics select the bucket and arrival order within the bucket selects the arm, so
two students with identical demographics receive opposite arms. No new storage; the record already exists in
`jobs-task-data`.

_Original finding:_

`getAlternatingAssignment` de-duplicates **within a stratum**: it reads
`strata[stratumKey].users[platform_user_id]` and returns early only if that student appears **under that
stratum key** (`random-assignment.ts:245-258`). If a student's stratum changes between two clicks, the lookup
under the new key finds nothing and they are assigned again, possibly to the opposite arm, after which
`enroll-specified-class` would enrol them into a **second** subclass, leaving them in both Gator and Shark.

The window is narrow but real: the pre-test is locked only **after** a successful run, so any failure between
assignment and lock (an enrol error, a portal blip) returns the student to an unlocked pre-test where they can
change an answer and click again. The spec currently claims assignment is "deterministic per student
(idempotent)", which is only true while the stratum is stable.

Suggested resolution: state the requirement as de-duplication **per student**, not per (stratum, student), so
that once a student has an assignment it is returned regardless of what their answers say later. This is
pre-existing spring behaviour, but this story is where the claim is being made.

---

#### RESOLVED: ER-2. Flex is balanced within each section, which may weaken balance rather than strengthen it

**Resolution (Trudi, 2026-07-29, Slack): pool all flex students.** Her answer to Q4 was "Flex should be across
ALL THREE SECTIONS. All flex kids are considered in the same group." Scoped into this story rather than split
out (Doug, 2026-07-29), because the resolved program is already this story's product and a separate story
would have to re-derive it. See "Assignment scope" in the Requirements.

⚠️ **The fix is not the one this finding proposed.** Verification during implementation planning showed the
suggested resolution below, a key excluding `context_id`, is **insufficient and, if pushed further, actively
dangerous**:

- `resource_link_id` **is the offering id**, and an offering is per class per activity
  (`Portal::Offering belongs_to :clazz, :runnable`). The three flex sections are three classes, so they reach
  the same Green activity through three different offerings. Excluding only `context_id` still leaves three
  documents, so the change would appear to be made while pooling nothing.
- Excluding `resource_link_id` **as well** leaves `interactiveId | platform_id`, and O14's single shared Green
  button gives both programs the same `interactiveId`. That merges all eight classes into one document and
  silently destroys full-time's within-teacher balancing, with every test still passing.

The resolution is therefore a **program-dependent assignment scope**: full-time keeps the shipped key
untouched, flex pools within flex. Recorded at length because the halfway version of this change is both
plausible and invisible.

_Original finding:_

The assignment document id hashes `interactiveId | platform_id | resource_link_id | context_id`
(`computeAssignmentDocId`, `:221-229`), and `context_id` is the class. So **each registration class gets its
own document and its own alternating counters**.

For full-time this is exactly right and delivers "randomize within teacher" for free: within one class only
four of the twenty strata apply (Gender x Race), so each class alternates across four cells.

For flex it may work against the design. All 24 strata apply within a single section, so the effective cells
become 24 **per section**, 72 across the three sections. If a section has, say, 60 students spread over 24
cells, many cells hold one or two students, alternation barely operates, and each near-empty cell resolves to
whichever arm the table seeds it with. That trades balance on the four demographics for balance within
section, which nobody asked for.

Suggested resolution: confirm with the PI whether flex should balance **across the whole flex cohort** or
**within each section**. If cohort-wide, the assignment document for flex needs a key that excludes
`context_id`, which is a change to a shipped mechanism and should be scoped explicitly.

---

#### RESOLVED: ER-3. The teacher key's real job is the seed, not the balancing, and that is easy to refactor away

**Resolution (Doug, 2026-07-29): applied, documentation only, no behaviour change.** The Requirements now
separate the two mechanisms under "Two mechanisms that look like one, and must not be merged", stating that
within-teacher balancing comes from the per-class assignment document, that the teacher column exists to set
each teacher's starting arm and so balance the leading edge of every stratum across classes, and that the
teacher dimension must therefore stay in the stratum key despite appearing redundant. The failure mode being
guarded against is specifically an *invisible* one: removing it leaves within-class balance intact and every
test green.

_Original finding:_

Because assignment documents are per class and full-time classes are one per teacher, "randomize within
teacher" is delivered by the **document key**, not by the teacher column in the table. What the teacher column
actually does is set **which arm each teacher's strata start on** (Bingler treatment, Hankamp control, and so
on), which is the PI's "Alternate n1" instruction.

Anyone later noticing that the teacher dimension appears redundant for balance could remove it and be right
about balance while silently destroying the seed alternation. The spec requires preserving the alternating
seed but does not explain why the teacher key exists at all.

Suggested resolution: state the two mechanisms separately in the requirements, so the reason the teacher key
exists survives a future refactor.

---

#### RESOLVED: ER-4. "Prefer not to answer" is counted as Female, and the spec's wording hides it

**Resolution (Doug, 2026-07-29): applied, documented rather than changed, plus one checklist addition.**
Technical Notes now states the collapse explicitly instead of listing the three accepted labels as though they
were three categories, records that no rationale for the bucket is written down anywhere, and notes why the
choice is bounded (the PI's table has no third gender row, and the answer documents retain the real choice, so
only balancing is affected, not the recorded data). Open Question 1's launch checklist gains the gender
options question.

**The bucket question is deliberately not being re-opened with the PI.** Her table forces a binary, spring
already ran on this mapping, and the recorded data is unharmed, so it would add a fourth outstanding item for
little gain. **The options question is different and was added**, because it is a hard launch blocker with a
student-blocking failure mode and costs nothing to answer alongside the pre-test wording already owed.

**Rejected: alternating non-responders between the two buckets.** It would make a student's stratum depend on
arrival order, breaking the property that stratum is a function of demographics alone.

_Original finding:_

`random-assignment.ts:33` maps `"Prefer not to answer"` to `Female`. It is intentional, not a slip: a test
pins it at `random-assignment.test.ts:383`. But the spec's Technical Notes said only that `GENDER_MAP`
"accepts `Female` / `Male` / `Prefer not to answer`", which reads as three categories, while every stratum key
in both tables carries only `Female` or `Male`. A reader had no way to find the collapse short of opening the
file.

It matters more in the fall than in spring: Gender is one of four dimensions across 24 spring cells, but
Gender x Race is the **entire** full-time stratification, four cells per teacher, so the same students load
into two of four cells rather than twelve of twenty-four.

**Searched and not found:** any recorded rationale. `current-architecture.md:125` and `decisions-log.md:74`
both record the behaviour as observed code; neither records a decision, a reason, or an attribution to the PI.

A sharper adjacent risk surfaced while verifying this: `mapToCategory` **throws** on an unmapped Gender choice
(`:192`), producing the generic retry message (`:350-358`), so any new gender option in the fall pre-test
blocks every student who picks it. Folded into Open Question 1's checklist.

---

#### RESOLVED: ER-5. ER-3 credits the teacher seed with cancelling a tilt it can only reduce

**Resolution (Doug, 2026-07-29): applied, wording only, no behaviour change.** The Requirements now say the
per-teacher seed **spreads** and **reduces** the leading-edge tilt rather than cancelling it, and state the
arithmetic that bounds it.

_Original finding:_

ER-3's resolution says the per-teacher seed alternation exists to cancel a systematic tilt across the cohort.
Checked against the transcribed table, it cannot cancel it: with **five** teachers, an odd number, no cell's
seed can split evenly. `Female|White` and `Male|White` seed 3 treatment to 2 control, and the two non-White
cells seed 2 to 3, so the residues offset across cells and the table is 10 to 10 overall, but each individual
cell remains tilted.

This is a property of the PI's design rather than a defect to fix here. It is worth stating because "balances
the leading edge" is a stronger claim than the mechanism supports, and a later reader taking it literally
might conclude something is wrong with the transcription.

---

### Senior Engineer

#### WITHDRAWN: SE-1. The guarded accessor depends on a step name that nothing pins down

**Withdrawn (Doug, 2026-07-29).** The finding presupposed the guarded accessor, which has itself been dropped
under the standing principle that our own pipeline ordering is assumed correct rather than checked with
defensive code. With no accessor there is no step name for it to depend on. Q5's substantive decision, a step
rather than a memoised helper, is unaffected.

_Original finding:_

The accessor reads the class word out of `stepResults`, which is keyed by **step name** (`index.ts:81`). Its
guard therefore has to know the producer's name. If REPORT-82 registers the step as `resolve-origin-class` in
one stage and anything else in another, the guard fires on a correctly ordered pipeline.

Suggested resolution: require the step name to be an exported constant shared by producer, accessor and
pipeline definitions, rather than a string literal repeated in four places.

---

#### RESOLVED: SE-2. The shared-core extraction lands on a file that two other stories are moving

**Resolution (Doug, 2026-07-29): applied, and since satisfied.** Technical Notes stated the order as a
decision rather than an observation: REPORT-79 merges first, then the extraction begins; if it had not merged
when implementation started, the work would branch from REPORT-79's branch rather than from `master`.
**REPORT-79 merged to `master` later the same day (PR #405), so the contingency was never needed** and this
story branches from `master`.

_Original finding:_

Extracting the core touches `random-assignment.ts`, which REPORT-83 modified recently (the mint cutover) and
which sits alongside the `StepOutput` type REPORT-79 introduces in an **unmerged** PR. This story also extends
that type. The spec notes the sequencing in Technical Notes but does not say what to do about it.

Suggested resolution: state the intended order explicitly, that REPORT-79 merges before this story's
extraction begins, and that if it does not, the extraction is done on a branch rebased onto REPORT-79 rather
than onto master.

---

#### RESOLVED: SE-3. ER-1's de-duplication changes spring, and two requirements assert it does not

**Resolution (Doug, 2026-07-29): applied, option A.** Spring inherits the per-student de-duplication, and the
two claims were amended to name the delta rather than deny it. The Requirements gain "The one deliberate
change to spring", and the Acceptance Criteria now assert the changed case explicitly instead of asserting
that nothing changed. `spring-2026` is dormant, so the blast radius is nil; the change is made because ER-1's
argument (`add_to_class` only adds, so a second assignment contaminates two arms) is about the enrolment
primitive rather than about which cohort is running, and therefore applies to spring identically.

**Rejected: parameterizing the shared core with a per-pilot dedup scope** to keep spring bit-identical. It
requires the mode conditional the Structure section forbids, and doubles the test matrix to protect a path
nobody wants. Also rejected: deferring ER-1 to its own story, which would ship the fall path with the known
double-enrolment behaviour.

_Original finding:_

The spec places the alternating-assignment transaction in the shared module ("Structure: two thin steps over a
shared core") and specifies per-student de-duplication as a property of that transaction ("Assignment
behaviour"). The spring step calls the same core, so spring inherits the change. But the Structure section
claimed "The spring pipeline's behaviour is unchanged" and the Acceptance Criteria repeated it as a testable
claim, so the spec asserted something its own design makes false.

**Verified against the shipped code, not inferred.** Driving the real `getAlternatingAssignment` with a
document in which `user-1` already holds `treatment` under `Female|White|High|Mod1`, then re-invoking with
stratum `Female|White|High|Mod2`: today it returns `control` and writes, consuming `Mod2`'s rotation slot;
under the specified walk it returns `treatment` and writes nothing. Same inputs, different outputs, so the
acceptance criterion as written was false.

The existing suite would not have caught it: the only de-duplication test
(`random-assignment.test.ts:900`) covers a **same-stratum** re-click, so nothing pinned the changed case and
the change would have landed with a green suite.

Suggested resolution: decide whether spring inherits the fix, and make the requirements and criteria say what
was decided either way.

---

#### RESOLVED: SE-4. Background says the origin read has no caller; it has one, and the fall stage reads the offering twice

**Resolution (Doug, 2026-07-29): applied, correction plus one accepted redundancy recorded.** Background now
says the read has **no consumer of the class word**, which is what REPORT-79's own spec says, rather than no
caller. The duplicate offering read is documented as a knowing choice with its tidy-up assigned to REPORT-82,
rather than left as a redundancy nobody noticed.

_Original finding:_

Background stated that REPORT-79 shipped `resolveOriginOffering` "as a reusable read with no caller". It has
one: `send-email.ts:85` calls it for the offering's `clazzId`, which `send_class_teachers` needs. REPORT-79's
spec is precise about this ("has no consumer yet", meaning of the class word); this spec's paraphrase was not.

The consequence is not cosmetic. A fall stage containing both the new `resolve-origin-class` step and
`send-email` issues `GET /api/v1/offerings/:id` **twice per run**, which sits awkwardly against this spec's
claim that the step "mints once" and that downstream steps read from `stepResults` "rather than re-reading the
offering". Removing the second read means either publishing `clazzId` alongside `originClassWord` and rewiring
`send-email`, or letting `send-email` reach into another step's output; both touch a step this story otherwise
leaves alone, so the tidy-up belongs with REPORT-82's stage wiring.

---

#### RESOLVED: SE-5. The wording table is keyed by a `pilot` string that does not exist and that another story owns

**Resolution (Doug, 2026-07-29): applied, by removing the key rather than naming it.** The wording moves into
two named configuration objects, one per pre-test, each referenced directly by its own step. Open Question 1's
decision E is amended accordingly, and the "two axes" note now distinguishes structural selection (wording)
from run-time resolution (program).

**How the finding changed under examination, which is why the resolution is not what was first proposed.**
The original finding argued the fall needed three pilot keys (green / blue / orange) and that two would miss.
That was wrong: only the green stage randomizes, so only one key would ever be looked up. What survived
scrutiny was the coupling, not the miss. Then the coupling itself dissolved: Open Question 2's decision D had
already made the step the selector, so the table needs no key at all. Three candidate keys were considered
and all three are now moot: `fall-2026-green` (fits the stage-keyed scheme but encodes a stage the wording
does not vary by), `fall-2026-fulltime` (encodes a **program**, which O14 proves cannot be authored, since one
shared button serves both cohorts), and `fall-2026` (honest about the axis, but only correct if REPORT-82
keys `PIPELINES` on a separate `stage` param, a dispatcher change this story puts out of scope).

_Original finding:_

Open Question 1 specifies the wording table as "keyed by pilot", justified by `pilot` being authored and
always present. Open Question 2 leans on the same fact for step selection. Both are true of **spring**.
Neither says what the fall `pilot` value is, and REPORT-81 would have had to hardcode it as a table key.

**Verified.** A search across the repository and the whole working-notes set finds **no** fall pilot string
anywhere; `PIPELINES` (`ai4vs-flvs/index.ts:17-24`) holds exactly one entry, `spring-2026`. The naming is not
merely unwritten but recently reversed: `qi-140-design.md:157`, dated 2026-07-29, drops the
`fall-2026-fulltime` / `fall-2026-flex` split in favour of stage keys. Meanwhile REPORT-79's open PR already
ships the dropped name at `harness/im-done-local/run-step.js:34`. That instance is **inert** rather than
broken (the driver calls one compiled step directly, and `pilot` reaches only the mint's `description`
string), but it is currently the only fall pilot string in the tree and reads as precedent. A config-table
miss also had no specified behaviour, where every comparable case in this spec is a classified failure.

Suggested resolution: decide the fall pilot key and how the two stories stay agreed on it.

---

### QA Engineer

#### RESOLVED: QA-1. No acceptance criteria, and the testable claims are the subtle ones

**Resolution (Doug, 2026-07-29): applied, with a correction.** An Acceptance Criteria section was added. The
draft finding referred to "five seeds", which was imprecise: the full-time table carries **twenty** `n1`
values, one per stratum. What is five is the **pattern**, namely which arm each teacher's block of four
starts on (Bingler treatment, Hankamp control, Long treatment, Newlon control, Torres treatment), with the
remaining fifteen following by alternation within each block. It is deliberately **not** one continuous
alternation down all twenty rows: each teacher's block flips relative to the previous one. The criteria
therefore assert **all twenty values individually** and **the five block starts separately**, the latter
catching an entire teacher's block transcribed with inverted polarity, which is the likeliest transcription
error given the alternating layout.

_Original finding:_

The spec states requirements but no acceptance criteria, and the claims hardest to verify are precisely the
ones a reader would assume are covered: that all twenty full-time strata resolve, that each teacher's strata
**start on the arm the source document specifies**, that alternation continues correctly from that seed, and
that a re-click returns the existing assignment. The existing suite has a case per stratum for the 24 flex
rows, so the pattern exists; nothing yet requires the equivalent for the 20 new ones.

Suggested resolution: add explicit acceptance criteria, including one asserting the per-teacher seed, since
that is the single value most likely to be transcribed wrongly and the least likely to be noticed if it is.

---

#### RESOLVED: QA-2. The local harness cannot exercise the fall path as specified

**Resolution (Doug, 2026-07-29): applied, then narrowed by QA-3.** Three harness acceptance criteria were
added: a full-time student end to end, a flex student end to end, and a re-run asserting the same assignment
is returned. **QA-3 subsequently found that the first two contradicted this story's Out of Scope**, and moved
them to REPORT-82. The third is retained and strengthened into an emulator-backed test of the extracted core,
which is the criterion that mattered: it is the only place the de-duplication is proven against a real
Firestore transaction rather than a mock.

_Original finding:_

`functions/harness/im-done-local/config.js` seeds demographic answers using spring's prompts and choice
labels, and drives the `spring-2026` pilot. Nothing in the spec requires fall fixtures, so the harness would
silently continue proving only the spring path while the fall path ships untested end to end.

Suggested resolution: require a fall harness scenario covering at least one full-time student (verifying the
teacher stratum resolves from the class word) and one flex student, plus a re-click proving idempotency.

---

#### RESOLVED: QA-3. The harness criteria QA-2 added contradict this story's Out of Scope

**Resolution (Doug, 2026-07-29): applied, option D.** The two program-level end-to-end criteria move to
REPORT-82, which owns the stage wiring they actually prove. The re-run criterion stays and is strengthened
into an emulator-backed test of the extracted core, called directly, needing no pipeline. This keeps the scope
boundary SE-5 had just cleaned up while refusing to let the one behaviour this story invents ship proven only
against mocks.

**Rejected: pulling a minimal fall `PIPELINES` entry into this story** to make the end-to-end criteria
reachable. It would hand REPORT-82 a pilot key to inherit and possibly rename, reintroducing precisely the
coupling SE-5 removed. Also rejected: generalizing `run-step.js` into a step driver, which keeps the boundary
but cannot exercise a Firestore transaction at all, since that driver runs without the emulator; and dropping
the criteria outright, which would leave the shared-core extraction proven only against mocks.

_Original finding:_

Three of the four Harness criteria required a fall scenario to run a student **end to end** against the stub
portal. Out of Scope assigns the fall pipelines and their stage wiring to REPORT-82, stating that this story
"adds steps; it does not wire them into a pilot". Both cannot hold.

**Verified.** `ai4vsFlvs` resolves `PIPELINES[request.pilot]` and fails the job with "Unknown pilot"
(`ai4vs-flvs/index.ts:45-51`) before any step runs, and `PIPELINES` holds one entry. So with no fall entry
there is no end-to-end fall run, only a rejection. The existing single-step driver is not a fallback either:
`harness/im-done-local/run-step.js:17` hardcodes `enroll-specified-class.js` as the step it runs, and builds
its `StepContext` by hand without the emulator.

The re-run criterion was the load-bearing one and the reason the finding matters rather than being pedantry:
the unit suite mocks `runTransaction` (`random-assignment.test.ts:44-59`), so the de-duplication cannot be
proven by a unit test at all.

Suggested resolution: decide which side of the boundary moves, the criteria or the scope, and make the two
sections agree.

---

#### RESOLVED: QA-4. The 20-row table's only durable copy is an uncommitted scratch file on one machine

**Resolution (Doug, 2026-07-29): applied.** The full table is now reproduced in this spec under "The
full-time table (source of truth)", in the source document's row order, with each teacher's full name and the
surname used as the stratum key. The transcription was checked mechanically before being committed.

_Original finding:_

The spec said the full-time table "is transcribed in the working design notes (oob
`im-done-button/qi-140-design.md` §4b)" and did not contain it. That chain has no durable link in it:

- The PI's Google document was, by the design notes' own account, the **only** copy, reachable only through a
  comment on QI-140, **which is being deleted**.
- The oob transcription that replaced it is deliberately uncommitted scratch. Verified: there is no `.git`
  anywhere under the oob root, so it is unversioned, unbacked-up and local to one machine.

So the one hard-won artifact this story depends on, the thing the design notes call "the one hard blocker on
REPORT-81 and it is now closed", was one `rm` away from being gone, and the committed spec pointed at it
rather than holding it.

A second, smaller consequence: the acceptance criterion "within a teacher's block the four strata alternate"
is not checkable from the spec alone, because alternation is a property of the source document's **row
order**, which the spec did not record. Reproducing the table in order fixes both problems at once.

Suggested resolution: put the table in the committed spec, in source order, and treat the oob copy as a
working note rather than the reference.

---

### Product Manager

#### RESOLVED: PM-1. REPORT-80 now depends on this story, and Jira does not say so

**Resolution (Doug, 2026-07-29): applied in Jira.** The `REPORT-81 blocks REPORT-80` link was created and
verified from both issues. The dependency did not exist when the link graph was corrected on 2026-07-28; it
was created by the Gap 3 decision that assigned the resolve step to this story. Note for future edits: the
`acli` success line printed the pair **backwards**, so the direction was confirmed with
`workitem view --fields issuelinks` rather than the confirmation output. Also recorded in oob
`decisions-log.md` and `stories.md`.

_Original finding:_

This story publishes `originClassWord`, and REPORT-80's offering-state step consumes it to resolve its default
target class. The Jira dependency graph, corrected on 2026-07-28, records `REPORT-79 → REPORT-80` and
`REPORT-79 → REPORT-81` but **no `REPORT-81 → REPORT-80` link**, because that dependency did not exist until
the Gap 3 decision on 2026-07-29 assigned the resolve step here.

Suggested resolution: add the `REPORT-81 blocks REPORT-80` link, so that anyone picking up REPORT-80 does not
start it expecting the class word to already exist.

---

## Open Questions

### RESOLVED: 1. What are the fall Green pre-test's demographic questions and answer choices?

**Context**: This is the one question that can invalidate the whole story after it ships. The step finds each
demographic answer by searching the question prompt for a hardcoded substring, then matches the chosen answer
by exact text. Both sets of strings are spring's. The PI's own document says she will build a **new** pre-test
activity for the fall. Three distinct failure modes, none of which appear before launch day:

- A **reworded prompt** makes `findAnswerByPrompt` throw `isMissingAnswer` (`:146-150`), so the student is
  told *"Please complete the following question(s)"* for a question they **did** answer.
- A **relabelled choice** makes `mapToCategory` throw, giving the generic failure message.
- A **question duplicated across the two Green activities** makes `findAnswerByPrompt` throw on
  `matches.length > 1` (`:151-153`), because the answers query spans the whole sequence (O1).

There is also a constraint the shared button creates: because one Green pre-test serves both cohorts, it must
ask **all four** demographic questions. Full-time reads only Gender and Race, but flex needs Grade and Module
too, so a pre-test authored for full-time alone would silently break flex randomization.

Sent to the PI on 2026-07-29 as Q3 of the schematic at
https://claude.ai/code/artifact/c1848058-8db0-4aef-84d5-66bd63073cdf , phrased so that sending the pre-test
itself is the easiest reply.

**Options considered**:
- A) Wait for the PI's confirmation before implementing the demographic-matching part of this story.
- B) Build against spring's strings, and treat confirming them as a launch-blocking checklist item.
- C) Make the prompts and choice labels **authored parameters** on the button.
- D) Match more loosely (fuzzy or keyword matching) to tolerate rewording.
- E) Move the wording into a **pilot-keyed config table in code**, seeded for the fall from spring's values.

**Decision**: **E, with the fall object specified as identical to spring's for now** (Doug, 2026-07-29). The
wording moves out of module-level constants into a per-pre-test configuration object. The fall object is
specified as the same prompts and choice labels spring uses. If the PI's reply says otherwise, the change is
one object, localised and testable, rather than a refactor or a redesign.

**Amended during self-review (Doug, 2026-07-29): the wording objects are not keyed by pilot.** E originally
specified a **pilot-keyed config table**, on the reasoning that `pilot` is authored and always present so the
keying costs no new authoring. Open Question 2's decision D, taken the same day, made the **step** the
selector: spring's step and the fall step are separate functions, so each simply references its own wording
object. A key adds a run-time lookup that can miss while selecting nothing the step does not already know,
and it would have coupled this story to a `pilot` string REPORT-82 authors and that nothing has yet named.
E's substance is unchanged, and so is the property it was chosen for: a late correction to the fall wording
remains a one-object edit. See Self-Review finding SE-5.

**Why not C**: authoring would mean entering four prompt fragments and roughly fifteen choice labels into a
`taskParams` blob, where a single typo fails silently for whichever students pick the mistyped choice. Too
error-prone to hand to an author. **Why not D**: loose matching trades a loud, diagnosable failure for a quiet
wrong answer, and a mis-matched demographic silently places a student in the wrong stratum, which corrupts the
study arm rather than stopping the pipeline. **Why not A**: it idles the story against a roughly 15 August
launch. **B** is what E does, with the seam added that makes a late correction cheap.

**Note the two axes, which are selected differently**: **question wording** varies by **pre-test** (spring's
versus the fall's), and both cohorts share one Green pre-test under O14, so wording is identical for flex and
full-time; the step that runs already determines it, so nothing selects it at run time. **Which dimensions
are read** varies by **program** (flex all four, full-time Gender and Race only), and that *is* resolved at
run time, from the class word. Wording is structural; program is resolved.

**✅ Confirmed by the PI (Trudi, 2026-07-29, Slack), so the assumption is now verified rather than assumed.**
Asked as Q3 of the schematic at https://claude.ai/code/artifact/c1848058-8db0-4aef-84d5-66bd63073cdf . Her
answer: "Yes, they are the same", with a link to the fall pre-test's authoring page, plus one refinement,
"I think you can group 'Other/not sure' with Module 4". **That refinement requires no code change**: the
Module mapping already matches only the two full module titles and defaults everything else, including both a
Module 4 choice and "Other/not sure", to `Other` (`:204-210`). The fall configuration object is therefore
specified as identical to spring's on the PI's confirmation, not on assumption.

**Three residual checklist items remain**, none of them code dependencies:
- **Eyeball the linked authoring page** to confirm there is no *Module 3* choice that she would want treated
  like Mod1 or Mod2 rather than falling to `Other`. Her wording addresses Module 4 only.
- **Confirm the pre-test asks all four demographic questions**, since full-time reads two but flex needs four
  and one pre-test serves both.
- **Confirm no demographic question is duplicated** across the two Green activities: the answers query spans
  the whole sequence (O1) and `findAnswerByPrompt` throws on more than one match (`:151-153`).

⚠️ **Added to that checklist during self-review (ER-4): the gender question's answer options specifically.**
`mapToCategory` **throws** on an unmapped Gender choice (`:192`), which `randomAssignment` turns into the
generic "please try again" message (`:350-358`). So if the fall pre-test's gender question offers any option
spring's did not, for example `Non-binary` or `Prefer to self-describe`, **every student choosing it is
blocked from the pipeline entirely**, by a message inviting a retry that can never succeed. Gender is the
dimension most likely to gain options in a newly authored activity, and the failure is silent until a student
hits it. This is a specific instance of the general risk above, called out separately because it is the one
most likely to occur and it degrades to a student-blocking dead end rather than a diagnosable error.

---

### RESOLVED: 2. Does the fall path modify `random-assignment.ts` in place, or ship as a separate step?

**Context**: The shipped spring step both randomizes **and** enrols, driven by `treatment_class_id` /
`control_class_id` request parameters. The fall path must randomize and **not** enrol, deriving a destination
class word for REPORT-79's enrol step instead.

**Options considered**:
- A) Generalise `random-assignment.ts` in place, taking the class-word path when the spring class-id
  parameters are absent.
- B) Add a wholly separate fall step, leaving the spring step untouched, following REPORT-79's precedent.
- C) Generalise in place and **remove** the spring enrol path, retiring `spring-2026` in this story.
- D) **Extract the shared core** (demographic reading, category mapping, the alternating-assignment
  transaction) into a shared module, and keep two thin steps over it: spring's assigns and enrols by id, the
  fall one assigns and publishes a destination class word.

**Decision**: **D, and with no mode conditional anywhere.** The premise behind A, that a step must work out at
run time which path it is on, is false: **the pilot is an authored button parameter and always present**
(spring's button authors `pilot: "spring-2026"`, and the fall buttons author their own key, Doug 2026-07-29).
`PIPELINES[request.pilot]` therefore already selects a different **step list**, so spring's list holds the
spring step and the fall lists hold the fall step. Nothing needs to be inferred from a missing parameter.

B was rejected on scale: REPORT-79's precedent involved duplicating ~15 lines of orchestration, whereas here
a separate step would duplicate `parseReportState`, `findAnswerByPrompt`, `resolveChoices`, `mapToCategory`,
`computeAssignmentDocId` and `getAlternatingAssignment`, roughly 280 of the file's 450 lines and the most
subtle 280. C was rejected because removing spring's enrol does not merely retire a dormant pipeline, it
breaks the one REPORT-83 migrated onto the mint; spring cannot use `enroll-specified-class` either, since it
enrols by raw class id rather than class word, so C amounts to retiring `spring-2026` outright, a bigger
decision than this story should take.

Consistency note: what is authored is the **pilot / stage**, never the **program**. Full-time versus flex is
still resolved from the origin class word inside the fall step, so O14 is untouched.

Consequence for the test suite: most of `random-assignment.test.ts`'s 974 lines exercise the extracted core
(prompt matching, choice resolution, category mapping, the 24 strata, the alternating transaction), so it
retargets to the shared module rather than being rewritten or duplicated.

---

### RESOLVED: 3. How is the surname in a class word mapped to the table's full teacher name?

**Context**: The table's teacher column holds `Alyssa Bingler`; the class word holds `FT-2026-Bingler`. The
mapping has to exist somewhere, and where it lives changes what happens when the study adds a teacher.

**Options considered**:
- A) Key the transcribed table on the **surname** directly (`Bingler`).
- B) Keep full names in the table and add an explicit surname-to-full-name map alongside it. Two structures
  to keep in sync.
- C) Derive the surname from the full name at load time (last whitespace-separated token).
- E) Key the strata on the **whole origin class word** (`FT-2026-Bingler`), needing no surname at all.

**Decision**: **A, with the teacher's full name kept as a field on each row rather than as a comment.** The
strata key on the surname; the full name travels with the row so it is self-documenting, so the transcription
stays checkable against the PI's source document, and so a test can assert that `FT-2026-Bingler` resolves to
the row labelled `Alyssa Bingler`.

**Why the surname and not the whole class word (E), which is otherwise simpler**: the design randomizes
*within teacher*, not within class. Those are identical today (five classes, one teacher each), but if a
second section is ever added for one teacher, surname keying keeps that teacher's students balanced as a
single pool, which is the stated intent; class-word keying would silently split them into two pools, each
starting independently from the table's seed. C was rejected as fragile for no benefit, deriving a key that
could simply be written down and breaking on a two-word surname. B was rejected for the two-structures-to-sync
problem.

**Guard**: the only way surname keying fails is two study teachers sharing a surname, which is impossible
among the current five. A startup or test-time assertion that the table contains exactly five distinct teacher
keys catches it if the roster ever changes.

---

### RESOLVED: 4. What should a student see when their class word cannot be classified or its teacher is unknown?

**Context**: Two new failure modes have no precedent message: an origin class word with neither an `FT-` nor
an `FL-` prefix, and a full-time class word whose surname is absent from the table. Both mean the study is
mis-configured rather than that the student did anything wrong, and both should stop the pipeline rather than
guess. The existing vocabulary is the three REPORT-83 buckets (reload / tell-your-teacher / generic).

**Options considered**:
- A) Both use the existing tell-your-teacher message, matching how a mis-authored class word already behaves.
- B) A distinct message naming the misconfiguration.
- C) Different treatment for each: unknown prefix as tell-your-teacher, unknown teacher as generic.

**Decision**: **A, both to the existing tell-your-teacher message.** It matches the precedent REPORT-79 set,
where a class word that fails to resolve gives exactly this message; telling a teacher is genuinely the only
useful action available to a student in this state; and it adds no new student-facing string for two
engineering failures a student cannot distinguish or act on either way.

B was rejected because the actionable detail belongs in the **log**, not on a student's screen. C was
rejected because the generic bucket implies "try again", which is false here: both failures are permanent
until someone edits configuration, so the generic message would have students clicking repeatedly to no
effect.

**Logging requirement (applies to both cases).** Log at **error** level, not info: these are study-validity
failures, and REPORT-79 set that precedent by logging its destination-word conflict at error precisely
because the blast radius was the whole study. The log line must carry the offending value, since that is what
actually diagnoses the fault: the unclassifiable class word, or the surname with no table entry. Both are safe
to log, being authored, environment-stable, and neither PII nor a token.

---

### RESOLVED: 5. Should the `resolve-origin-class` step be a pipeline step at all, or a helper the steps call?

**Context**: The design notes (§4b) name it as a step, and a step publishes `originClassWord` once for every
later step to reuse via `stepResults`. But a step that only performs a read adds a `setProcessingMessage`
tick the student sees, and REPORT-82 must remember to place it first in every stage.

**Options considered**:
- A) A pipeline step, as the design notes specify, publishing `originClassWord` on `StepOutput`.
- B) A lazily-cached helper that any step calls, memoised on `StepContext` like the token cache.
- C) A step, with a processing message folded into the next action.

**Decision**: **A, the step.** Consuming steps read `originClassWord` from `stepResults` directly.

**Amended during self-review (Doug, 2026-07-29): the guarded accessor originally attached to this decision is
dropped.** Its only purpose was to turn a mis-ordered pipeline into a legible error, and the standing
principle is that our own pipeline ordering is assumed correct rather than checked defensively at run time.
REPORT-82 owns step order here as it does everywhere else, and a mis-ordered stage fails on the first harness
run. This also retires finding SE-1, which was about pinning down the step name the accessor would have needed.

**Why the step, having first leaned the other way.** The two options are far closer than they appear: both
perform exactly one portal read and one mint per run, and both add exactly one field to a shared type (the
step adds `originClassWord` to `StepOutput`; the helper would add a memo slot to `StepContext`). Given that,
the step wins on three counts: it is **visible in `PIPELINES`**, so a stage definition shows that the class
word is resolved; a failure is **attributed to `resolve-origin-class`** rather than surfacing inside whichever
step happened to call first; and it uses **`stepResults`, which already exists**, instead of adding a second
memo channel beside `tokenCache`.

The helper's one structural advantage, laziness, **does not apply here**: all three fall stages need the class
word (green for the teacher stratum and the destination, blue for REPORT-80's target class, orange for that
plus the `-Gator` / `-Shark` suffix), so the step never does wasted work. Its remaining advantage was ordering
safety, which any harness run of a fall stage surfaces immediately in any case.

A module-level memo keyed by `jobPath` was considered and rejected outright: Cloud Functions reuse warm
instances, so it would leak across runs and serve a stale class word.

This also keeps `qi-140-design.md` §4b and the built code in agreement, since the design notes already
specify a step.
