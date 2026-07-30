# Pilot-Configurable Randomization for the Fall Study

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-81

**Status**: **Closed**

## Overview

Make the "I'm Done" randomization step select its strata table and its demographic inputs from the student's program, resolved at run time from their class word, so that one shared pre-test button can randomize both fall cohorts correctly. This story also delivers the piece that resolves the class word in the first place, which the sibling fall stories depend on.

The fall study runs two programs, full-time and flex, and randomizes students in each into a treatment (Gator) or control (Shark) class when they finish the Green pre-test. The two programs balance their groups differently: flex balances on four demographic answers across the whole cohort, while full-time balances within each teacher's class on two. Before this story the pipeline had exactly one hardcoded table, built for the spring pilot. Because the PI wants a **single shared pre-test button** serving both programs, the button cannot be configured with which program it belongs to, so the system works that out for itself at the moment a student clicks, from the class word the student registered with. It has no visible effect on its own; it is the piece that makes the fall study's group assignment correct, and correct group assignment is what the study's validity rests on.

## Requirements

### Resolving the origin class word

- **A `resolve-origin-class` step** runs first in the fall pipelines. It obtains a teacher-scoped portal token via `getScopedPortalToken`, calls `resolveOriginOffering` with the run's `resource_link_id`, and publishes the resulting class word on `StepResult.output` as **`originClassWord`**, alongside the existing `destinationClassWord` field.
- The step **mints once**; steps that need the class word read it from `stepResults` rather than re-reading the offering. The existing per-run `tokenCache` means later steps needing the same scope reuse the token.
- **One pre-existing duplicate read is knowingly left in place.** `send-email` calls `resolveOriginOffering` itself to obtain the offering's `clazzId`, which it needs for `send_class_teachers`, so a fall stage containing both steps issues `GET /api/v1/offerings/:id` twice per run. The second call is cheap and reuses the cached token; removing it means either publishing `clazzId` alongside `originClassWord` and rewiring `send-email`, or having `send-email` reach into another step's output, both of which change a step this story does not otherwise touch. *(Tidy-up assigned to REPORT-82's stage wiring.)*
- **Consuming steps read the class word from `stepResults`, with no defensive ordering check.** Pipeline order is assumed correct: REPORT-82 is responsible for placing this step first in each stage, as it is for step order everywhere else, and a mis-ordered stage fails on the first harness run.
- **An absent `class_word` is a classified failure**, not a silent fallback, giving the tell-your-teacher message. REPORT-79 deliberately omitted the two-call fallback on the grounds that these pipelines only ever mint teacher tokens, so the teacher-gated field is always present; an absent one indicates a real anomaly.
- The class word is safe to log (authored, environment-stable, not PII, not a token). Tokens are never logged.

### Classifying the program

- **A classifier maps the origin class word prefix to a program**: `ft-2026-` to full-time, `fl-2026-` to flex, matched against the normalized (lowercased) form the portal stores.
- **The prefixes are year-qualified, like the program ids they return.** Corrected after review, which found that the bare `ft-` / `fl-` prefixes gave flex the opposite treatment to full-time for the same class of fault. Full-time has a second, strict gate (an unknown teacher surname is a classified failure before anything is written); with a bare prefix a mistyped or unexpected flex word would classify, consume an alternation slot in the pooled `fall-2026-flex` document, and only fail later at enrolment. The bare prefix also undid the year-qualification of the program ids at the front door: `fl-spring-2026-origin`, the word the local harness actually carries, was indistinguishable from `fl-2026-section1`. Year-qualifying keeps no per-section list in code, so a new fall-2026 flex section still classifies unchanged.
- **An unrecognised prefix is a classified failure** with a student-facing message, never a silent default to either program. Defaulting would silently randomize a student using the wrong table and corrupt the study arm they land in.
- The resolved program selects **three things and no more: the strata table, the demographic input set, and the assignment scope**. It must not select a pipeline, and this story does not change the pipeline dispatcher in `ai4vs-flvs/index.ts`.

### Demographic question matching

- **The question prompts and answer-choice labels live in two named configuration objects, one per pre-test**, rather than in module-level constants. Each object holds the four prompt substrings and the choice-label maps for one pre-test.
- **Selection is structural, not a lookup.** The spring step references spring's object; the fall step references the fall's. Nothing is keyed by `pilot` and nothing is resolved at run time: the pipeline already selects the step, and the step already knows its pre-test, so there is no key to miss and no key string for another story to match.
- **One fall object serves both programs.** A single shared Green pre-test means a single set of prompts and labels. What varies by program is the *dimension set* (full-time reads Gender and Race, flex reads all four), which is resolved from the class word and is a separate axis from wording.
- **The fall object is identical to spring's** prompts and choice labels, **confirmed by the PI on 2026-07-29**, recorded in code with that date and attribution so a reader knows it was verified rather than assumed.
- **Spring's object is unchanged**, so this story alters neither spring's prompts nor its choice labels. (Spring's *assignment* behaviour does change in one narrow case, because it shares the extracted core.)
- Matching semantics are unchanged: prompts by case-insensitive substring, choice labels by exact match after trim. Loose or fuzzy matching is explicitly rejected, because a mis-matched demographic silently places a student in the wrong stratum, corrupting a study arm rather than stopping the pipeline.

### The two tables

- **Flex** reuses the existing 24-row Gender x Race x Grade x Module table and reads all four demographic answers. Verified 2026-07-29: all 24 rows of the shipped table, including which arm each stratum starts on, match the PI's source document exactly.
- **Full-time** uses a 20-row Gender x Race x Teacher table, four strata per teacher across five teachers, reading **only** Gender and Race.

#### The full-time table (source of truth)

Read from the PI's randomization document on 2026-07-29 and transcribed **in the source document's row order**, which the alternation criteria depend on. `n1` is the arm the **first** student in a stratum receives; the second gets the opposite, alternating from there.

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

**Checked mechanically on 2026-07-29**: 20 rows, 5 distinct teachers, 5 distinct surnames, 4 strata per teacher, 10 treatment and 10 control, each teacher's block alternating internally, and the block boundaries **not** alternating, which is what makes this five blocks rather than one continuous sequence.

This table is reproduced here because its previous only copies were the PI's Google document (reachable only through a comment on a ticket being deleted) and an uncommitted single-machine oob scratch note. **This is the reference an implementer and a reviewer check against.**

**On the teachers' full names.** Reviewed and settled: **teacher names are not PII for this study's purposes; only student names are.** The repository is public and the table is committed deliberately, so `teacherFullName` stays on each row, where it keeps the transcription checkable against the PI's source document. The code needs only the surname, so the full name remains a documentation field rather than an input.

- **The starting arm alternates by teacher** (Bingler treatment, Hankamp control, Long treatment, Newlon control, Torres treatment). This is the source document's "Alternate n1" instruction and is preserved exactly.

#### Two mechanisms that look like one, and must not be merged

- **Within-teacher balancing comes from the assignment document, not from the table.** The document id includes `context_id`, so each class has its own strata and its own alternating counters. Within one full-time class only four of the twenty strata can occur (Gender x Race), so that class's students already alternate among themselves whatever the table's teacher column says.
- **The teacher column exists to set each teacher's starting arm**, which spreads the *leading edge* of every stratum across classes. Without it, all five classes would seed their `Female|White` cell identically, producing a systematic tilt across the cohort. The alternation **reduces** that tilt rather than cancelling it: with five teachers, an odd number, the best any cell can do is 3 to 2. `Female|White` and `Male|White` seed 3 treatment to 2 control and the two non-White cells seed 2 to 3, so the residue offsets across cells and the table is 10 to 10 overall. That is a property of the PI's design, not a defect to fix here.
- ⚠️ **Therefore the teacher dimension stays in the stratum key even though it appears redundant for balancing.** Removing it leaves within-class balance intact and every test passing while silently destroying the seed alternation.
- **A full-time student must not be required to answer the flex-only questions.** The step reads Grade and Module for flex students only.

### Assignment scope: which students share one balancing pool

The PI confirmed on 2026-07-29 that **all flex students are one group across all three sections**, and that full-time randomizes within teacher as before. Those are different pooling rules, so the assignment document's identity is program-dependent.

- **Full-time keeps today's key exactly**: `interactiveId | platform_id | resource_link_id | context_id`. **The shipped mechanism is untouched on this path.**
- **Flex uses a pooled key** that resolves to one document for the whole flex cohort, so the 24 strata fill across all three sections and alternation actually operates within each cell.
- **The scope is computed by the step and passed into the shared core.** The core does not decide it and holds no conditional; it receives a document identity the way it already receives a strata table.
- **Spring is unchanged.** Its step keeps the existing per-class key.

#### Two traps in the pooled key, both of which the obvious fix falls into

- ⚠️ **Excluding `context_id` alone does not pool flex.** `resource_link_id` **is the offering id**, and an offering is per class per activity, so the three flex sections reach the same Green activity through three different offerings. A key that drops only `context_id` still yields three documents.
- ⚠️ **But excluding both would collide the two programs.** Dropping `resource_link_id` and `context_id` leaves `interactiveId | platform_id`, and one shared Green button means full-time and flex share one `interactiveId`. All eight classes would land in one document, silently destroying full-time's within-teacher balancing. **The pooled key therefore includes the resolved program.**
- ⚠️ **The resolved program in the pooled key is year-qualified** (`fall-2026-flex`). Pooling removes a safety property the per-class key has for free: the per-class key contains the offering and the class, so a new cohort re-keys the document automatically, whereas the pooled key's three components are all stable across cohorts. An unqualified `flex` would silently land a later flex cohort in this study's document.

#### Accepted consequences of pooling

- **Document size.** The pooled flex document accumulates one entry per student per stratum rather than one per section: a few KB against Firestore's 1 MiB per-document limit.
- **Contention.** Every flex assignment transacts on one document instead of three. The worker is already serialized by `rateLimits: { maxConcurrentDispatches: 1 }`, so this changes throughput, not correctness.
- **The per-student de-duplication walk is unaffected.** It still walks at most 24 strata.

### Deriving the teacher stratum

- **The teacher stratum is derived from the origin class word, not from a demographic answer.**
- The PI's table keys on the teacher's **full name** while the class word carries only the **surname**. **The transcribed strata are keyed on the surname**, with the full name carried as a **field on each row** so the row is self-documenting.
- Surname keying rather than whole-class-word keying is deliberate: the design randomizes **within teacher**, not within class. These coincide today, but if a second section is ever added for one teacher, surname keying keeps that teacher's students balanced as a single pool.
- **A guard asserts the table holds exactly five distinct teacher keys**, so a future roster change introducing two teachers sharing a surname is caught rather than silently colliding.
- **A class word whose surname is not in the table is a classified failure**, never a silent miss.

### Structure: two thin steps over a shared core

- **The demographic reading, category mapping and alternating-assignment transaction are extracted into shared modules.** The spring step becomes "read demographics, assign, enrol by class id"; the fall step becomes "read demographics for the program's dimension set, assign from the program's table, publish the destination class word".
- **No step contains a mode conditional.** The pilot is an authored button parameter and always present, so `PIPELINES[request.pilot]` already selects a different step list.
- **The spring pipeline's orchestration is unchanged**, including the enrol-by-id path REPORT-83 migrated onto the minted token.

#### The one deliberate change to spring

- **Spring inherits the per-student de-duplication**, because that behaviour lives in the extracted core both steps call. The delta is exactly one reachable case: a spring student whose stratum changed between two clicks previously received a **second** assignment under the new stratum key, and now keeps their original arm.
- **Why this is correct rather than merely convenient**: `add_to_class` only adds, so a second assignment cannot move a student, it can only enrol them into a second class alongside the first, contaminating both arms. That argument is about the enrolment primitive, not about which cohort is running.
- **Blast radius is nil**: `spring-2026` is dormant.
- **The changed case is pinned by a test**, so it is recorded as intended behaviour rather than an incidental consequence of the extraction.

### Assignment behaviour

- **Assignment is de-duplicated per student, not per (stratum, student).** Inside the existing transaction, walk the document's strata for the student's `platform_user_id` and return the first assignment found. A student who already holds an arm keeps it and is **never issued a second one**.
- Stated precisely: on a document where a student already holds *two* arms, reachable only from a pre-REPORT-81 spring run, the arm returned is whichever stratum Firestore yields first. Checked on the emulator, map fields came back in insertion order so the first-written arm won, but that ordering is not a documented guarantee, and such a student is already enrolled in both classes.
- **Why**: the previous lookup indexed straight into the current stratum, so a student whose stratum changed between clicks was not found and was assigned again. That is reachable, because the pre-test is locked only *after* a successful run.
- **The walk must not write.** Returning early leaves the current stratum's `nextAssignment` counter untouched, so a re-clicking student never consumes a rotation slot in a stratum they are not counted in.
- **Cost and storage are unchanged.** At most 24 strata are walked on a document the transaction already reads in full. No new collection, no schema change, no flat index.
- ⚠️ **The de-duplication fixes the arm, not the destination, and one double-enrolment path stays open. It is same-arm for flex and cross-arm for full-time.** `destinationClassWord` is re-derived on every run from the origin class word resolved *that run*, so a student whose origin class changes between two clicks receives the new section's or teacher's destination word. Whether they also keep their **arm** depends on the scope, because the walk reaches only within one assignment document:
  - **Flex** pools across sections, so a section move reads the same document, the walk finds the student, and both destinations are in the **same arm**. No arm is contaminated; this is a roster-tidiness problem rather than a data-integrity problem, which is why it is accepted and stated rather than fixed.
  - **Full-time** keeps the per-class key, which includes `resource_link_id` and `context_id`. A move between two full-time classes changes both, so the walk reads a **different** document, does not find the student, and assigns them afresh from the new teacher's counters. That can be the **opposite** arm, leaving them enrolled in one teacher's `-gator` class and another's `-shark` class. This is genuine **cross-arm contamination**, the thing the walk exists to prevent.
- **Reachability of the full-time case is low but real**, and it is accepted rather than fixed. It needs a roster move between two full-time classes plus a re-completion of the Green pre-test; the re-completion is plausible because the answers query filters on `resource_link_id` and `context_id`, so the student has no answers in the new offering, and `lock-activity` locks per offering, so the new offering is unlocked. Closing it properly needs a program-wide student→arm index, which this story deliberately declined. **Operational consequence**: a mid-study move between full-time classes is not just a roster edit, it needs the student's prior assignment inspected first.
- **Accepted impurity**: a student who edits their answers after assignment stays counted in their original stratum's balance while their recorded demographics say another. This is strictly better than holding two assignments, and cannot be corrected retroactively in any case.
- Otherwise unchanged from spring: assignment remains **balanced within each stratum**, alternating treatment and control in arrival order from the table's starting arm, written in a transaction to `jobs-task-data`.

### Handing off the destination

- The step derives the destination class word as **origin class word + `-gator`** (treatment) or **`-shark`** (control) and publishes it as `output.destinationClassWord` for REPORT-79's `enroll-specified-class` step.
- ⚠️ **The suffixes are lowercase, and the origin class word arrives lowercase.** `Portal::Clazz` lowercases and strips `class_word` before validation on every save and `offerings#show` serves the stored value, so `FT-2026-Bingler` reaches this pipeline as `ft-2026-bingler`. The destination classes are created from the same spreadsheet and are stored lowercase too, so lowercase suffixes make the derived word byte-identical to the stored one; a mixed-case suffix would resolve only through MySQL's case-insensitive collation. **The `resolve-origin-class` step publishes the class word normalized to the portal's stored form**, which is the invariant the prefix classifier, the surname lookup and REPORT-80 and REPORT-82 all inherit.
- **No raw class ids** appear in code or authored configuration. The spring `treatment_class_id` / `control_class_id` request parameters are not used by the fall path.
- **This step performs no enrolment and no portal write.** Its only portal interaction is the read needed to resolve the origin class word.

### Failure handling and secrecy

- Portal failures route through the shared `classifyPortalFailure` / `messageForBucket` helpers to the same coarse student messages REPORT-83 established (reload / tell-your-teacher / generic).
- **The two new configuration failures both give the tell-your-teacher message**: an origin class word with neither an `ft-2026-` nor an `fl-2026-` prefix, and a full-time class word whose surname is absent from the table. Neither uses the generic bucket, which implies "try again" and would be false, since both are permanent until someone edits configuration.
- **The same rule applies to the fall path's other permanent failures.** A demographic answer the pre-test configuration cannot interpret, covering an unmapped choice label, an unknown choice id and a duplicated prompt, is an **authoring** fault and gives tell-your-teacher rather than the retry message. This is reachable and launch-likely: `mapToCategory` throws on an unmapped Gender choice, so any option the fall pre-test adds that the configuration lacks would otherwise dead-end every student who picks it behind an invitation to keep clicking. An unmatched flex stratum is treated the same way, though it is unreachable from data. A **transport** failure keeps the retry message, because there retrying is honest advice. **Spring is unchanged**: it keeps one generic message for both.
- **Both log at `error` level and include the offending value** (the unclassifiable class word, or the unmatched surname), which is what actually diagnoses the fault. Both are safe to log: authored, environment-stable, neither PII nor a token.
- No token value is ever logged, and no real teacher name reaches a log or a `StepResult`. `send-email` renders every prior step's `summary` into the teacher-notification email, so `summary` carries only non-PII display values.

## Technical Notes

- **Files.** `assignment-doc.ts` (the document identity and the alternating transaction), `demographics.ts` (the answer query, prompt matching, choice resolution and category mapping), `pre-tests.ts` (the two wording objects), `strata-tables.ts` (both transcribed tables), `fall-programs.ts` (the classifier, surname derivation and dimension sets), `resolve-origin-class.ts` and `fall-random-assignment.ts`, all under `functions/src/tasks/ai4vs-flvs/`. `random-assignment.ts` is reduced to the thin spring step.
- **The `assignment-doc.ts` import constraint is load-bearing.** The module imports nothing but `crypto` and `firebase-admin`, because its emulator-backed test is the only place the de-duplication is proven against a real Firestore transaction, and that test can only import real production code if the whole chain loads under jest. Two chains do not: `firebase-functions` pulls in `firebase-admin/auth`, which jest 24 cannot resolve through its subpath exports, and `firebase-client` pulls in `firebase/auth`, which throws `ReferenceError: fetch is not defined`. Adding a logger import for one log line would silently cost the story its one unmockable proof.
- **Demographic matching.** Each answer is found by searching the question prompt for a substring (`"your sex"`, `"race or ethnicity"`, `"grade are you in"`, `"Algebra 1 module"`), then the chosen answer text is matched **exactly after trim**. Gender accepts `Female` / `Male` / `Prefer not to answer`, **mapping the third to `Female`**; Grade accepts `6th` through `12th Grade` plus `Other`; Module matches two full titles and defaults everything else to `Other`; Race accepts `White` and reduces everything else to `non-White`.
- **The Gender collapse is carried forward deliberately.** A student who declines to state their sex is counted as **Female** for balancing. It is intentional in the shipped code and pinned by a test, but **no design rationale for the choice of bucket is recorded anywhere**. Two things bound it: the PI's full-time table has exactly four strata per teacher with no third gender row, so a binary is forced by the table rather than chosen by the code; and the collapse affects only which rotation bucket a student lands in, since the answer documents retain the real choice. It nevertheless matters more in the fall, where Gender x Race is the **entire** full-time stratification.
- **Rejected: alternating non-responders between Female and Male.** It would make a student's stratum depend on arrival order, breaking the property that stratum is a function of demographics alone.
- **Sequence-wide answer scope.** The answers query spans the whole sequence, since a multi-activity sequence shares one `resource_link_id`. This is what makes a duplicated demographic question hazardous: prompt matching throws when more than one answer matches.
- **Auth.** Reuses REPORT-83's `getScopedPortalToken` (teacher scope), `portalTokenFetch`, `classifyPortalFailure`, `messageForBucket`, and the per-run `tokenCache` on `StepContext`. The steps make no host check of their own and assume the `validatePortalHost` setup gate ran before the pipeline loop; they use `StepContext.portalOrigin` for portal calls, never the raw `jobDoc.platform_id`.
- **Class words (fixed configuration, not code).** Full-time origins `FT-2026-Bingler`, `-Hankamp`, `-Long`, `-Newlon`, `-Torres`; flex origins `FL-2026-Section1`, `-Section2`, `-Section3`. Each splits into `<origin>-Gator` and `<origin>-Shark`. ⚠️ **That is the spreadsheet's casing, which is not the casing the code sees**; match lowercase everywhere.
- **CI.** A `test_functions` job runs the lint pass, the unit suite and the emulator suite on every push touching `functions/**`. Before it, no CI job ran this package at all, so the import constraint above rested on an unenforced test. Two things about the job are not obvious and were both established by watching it run:
  - It deliberately does **not** run `npm run build`. `tsc` emits compiled copies of every test into `lib/`, and four of them fail on the same `firebase-admin/auth` resolution problem that shapes the module split; `lib/` is gitignored, so a CI checkout never has it.
  - It **pins a JDK**. The Firestore emulator is a Java process and firebase-tools 15 refuses to start it on a JDK older than 21, which the runner's default is. The pre-existing rules job escapes this only incidentally: it runs on node 18, where npm resolves an older firebase-tools with no such requirement. A local run does not surface it either, since a developer machine that can run the emulator already has a new enough JDK.
  - It takes **no global `firebase-tools` install**, corrected after review. `functions/package.json` carries `firebase-tools` as a devDependency, so `npm ci` installs it and `test:emulator`'s `npx firebase` prefers `node_modules/.bin`. The emulator version, and therefore the JDK requirement above, comes from the lockfile; a global install bought the job nothing and implied it controlled that version. The rules job keeps its own, since it invokes `firebase` bare. The job also enables the npm cache and the workflow's display name now names all three packages it runs, the filename being historical.
- **Local harness.** `functions/harness/im-done-local/` runs the pipeline against a stub portal. Its fixtures seeded mixed-case class words and the stub echoed them verbatim, so a local run saw `FL-spring-2026-origin` where production sends `fl-spring-2026-origin`. The stub now reproduces the portal's lowercasing rather than trusting the fixture, so a future fixture written in spreadsheet casing still produces the production shape.

## Out of Scope

- **Adding the fall pipelines and their stage wiring** (REPORT-82), including the stage-keyed `PIPELINES` entries and the control-only differential step. This story adds steps; it does not wire them into a pilot. **Naming the fall `pilot` values is therefore REPORT-82's call, and this story deliberately does not depend on it.**
- **The offering-state step** (REPORT-80), though it consumes this story's `originClassWord`.
- **Enrolment** itself (REPORT-79's `enroll-specified-class`), which this story hands off to.
- **The spring-2026 pipeline's behaviour**, with one deliberate exception: it inherits the per-student de-duplication from the shared core. Its orchestration, its enrol-by-class-id path, its demographic wording and its assignment document identity are all untouched.
- **Any portal (rigse) change.** This story consumes existing endpoints as they are.
- **Authoring the fall buttons and the Green pre-test activity**, which are done outside this repo.

## Not Yet Implemented

- **No `PIPELINES` entry for either new step.** `resolve-origin-class` and `fall-random-assignment` ship as unreferenced production code; `index.ts` is untouched. REPORT-82 owns the fall stages, their pilot keys and the step order, which is also why no program-level end-to-end harness run exists in this story: with no fall pipeline entry, `ai4vsFlvs` fails a fall job with "Unknown pilot" before any step runs.
- **The duplicate offering read in `send-email` is left in place.** A fall stage containing both `resolve-origin-class` and `send-email` issues `GET /api/v1/offerings/:id` twice per run. Recorded as a knowing choice; the tidy-up belongs with REPORT-82's stage wiring, where the step order is being decided anyway.
- **The stale `pilot: "fall-2026-fulltime"` in `harness/im-done-local/run-step.js` is not cleaned up.** It is inert (the driver calls one compiled step directly and `pilot` reaches only the mint's `description` string) but is the only fall pilot string in the tree. Cleanup belongs with REPORT-82.
- **The duplicated assignment-document hash formula in `harness/im-done-local/run.js` is documented, not removed.** The harness is plain JS driving compiled output; the formula is now pinned by a test against a direct sha256 of the shipped input string instead.
- **`portal-reads.ts`'s comment describing `PortalClass.teachers[]` as "real PII" is now out of step with this story's ruling** that teacher names are not PII for this study. It is existing code this story does not touch, so it was left alone rather than edited in passing.
- **Five pre-launch checks remain open**, four on `FALL_PRE_TEST` and one on the destination class words. None is a code dependency, and the four `FALL_PRE_TEST` ones bear on an object that ships as a copy of spring's wording pinned by a deep-equality test. If any comes back different, the correct response is one change that edits the object, updates its attribution comment and deletes the pin.

| Check | What breaks if it comes back different |
|---|---|
| Eyeball the authoring page for a **Module 3** choice | It falls to `Other` silently, putting those students in the `Other` module stratum rather than a Module 3 one the PI may have intended |
| Confirm the pre-test asks **all four** demographic questions | Full-time reads two, flex needs four; a pre-test authored for full-time alone tells every flex student to "complete" a question that does not exist |
| Confirm **no demographic question is duplicated** across the two Green activities | The answers query spans the whole sequence, and prompt matching throws on more than one match, which is an `unmappable` and gives tell-your-teacher |
| Confirm the **gender question's answer options** against `genderMap` | `mapToCategory` throws on an unmapped Gender choice. Any option the fall pre-test adds blocks every student who picks it. This is the launch-likely one |
| Resolve all **sixteen derived destination class words** (eight origin classes × two arms) through the class lookup on the staging portal | Nothing in this story establishes that the destination classes exist in the portal as `<origin>-gator` / `<origin>-shark`. The derivation is asserted against itself and against the spreadsheet convention, never against the portal. If the spreadsheet's destination words differ in any way the derivation cannot reproduce (a plural, an abbreviation, a different separator), every fall student is randomized **correctly**, holds an arm, and then fails at enrolment with tell-your-teacher. Same shape and blast radius as the gender-options check |

- **Self-registration on the eight origin class words is unconfirmed.** A class word is the portal's student self-registration key, and the eight real origin words are new to the repository on this branch, in this spec and in two test files, in a **public** repository. If self-registration is open on those classes, anyone holding a learner account can join a study registration class, complete the Green pre-test and be randomized into an arm. The consequence is **contaminated study data** rather than exposed data. This spec settled publicness for **teacher names** deliberately; it classified class words as "authored, environment-stable, not PII", which is true and does not address self-registration. **The check that decides everything else is whether self-registration is closed on those eight classes for the study's duration**; rotating the words is the fallback if it cannot be closed. Two limits worth stating: whether an arbitrary learner can join cannot be established from this repository, and the words are already published, so using placeholder words for anything added later is worth doing but retracts nothing from history.

## Decisions

### What are the fall Green pre-test's demographic questions and answer choices?
**Context**: The one question that could invalidate the whole story after it ships. The step finds each demographic answer by searching the question prompt for a hardcoded substring, then matches the chosen answer by exact text, and both sets of strings were spring's while the PI was building a **new** pre-test for the fall. Three failure modes, none of which appear before launch day: a reworded prompt tells a student to complete a question they did answer; a relabelled choice throws; a question duplicated across the two Green activities throws on multiple matches.
**Options considered**:
- A) Wait for the PI's confirmation before implementing the demographic-matching part.
- B) Build against spring's strings, and treat confirming them as a launch-blocking checklist item.
- C) Make the prompts and choice labels **authored parameters** on the button.
- D) Match more loosely (fuzzy or keyword matching) to tolerate rewording.
- E) Move the wording into a **config table in code**, seeded for the fall from spring's values.

**Decision**: **E, with the fall object specified as identical to spring's**, which the PI subsequently **confirmed** ("Yes, they are the same", Trudi, 2026-07-29, Slack). Her one refinement, that "Other/not sure" may be grouped with a Module 4 option, needs no code change: the Module mapping already matches only the two full titles and defaults everything else to `Other`. **Amended during self-review: the objects are not keyed by pilot.** Open Question "in place or separate step" made the **step** the selector, so each step simply references its own wording object; a key would add a run-time lookup that can miss while selecting nothing the step does not already know, and would couple this story to a `pilot` string another story authors. **Why not C**: authoring means entering four prompt fragments and roughly fifteen choice labels into a `taskParams` blob, where a single typo fails silently for whichever students pick the mistyped choice. **Why not D**: loose matching trades a loud, diagnosable failure for a quiet wrong answer, and a mis-matched demographic silently places a student in the wrong stratum. **Why not A**: it idles the story against a roughly 15 August launch.

---

### Does the fall path modify `random-assignment.ts` in place, or ship as a separate step?
**Context**: The shipped spring step both randomizes **and** enrols, driven by `treatment_class_id` / `control_class_id` request parameters. The fall path must randomize and **not** enrol, deriving a destination class word for REPORT-79's enrol step instead.
**Options considered**:
- A) Generalise `random-assignment.ts` in place, taking the class-word path when the spring class-id parameters are absent.
- B) Add a wholly separate fall step, leaving the spring step untouched.
- C) Generalise in place and **remove** the spring enrol path, retiring `spring-2026`.
- D) **Extract the shared core** into shared modules, and keep two thin steps over it.

**Decision**: **D, and with no mode conditional anywhere.** The premise behind A, that a step must work out at run time which path it is on, is false: the pilot is an authored button parameter and always present, so `PIPELINES[request.pilot]` already selects a different step list. B was rejected on scale: a separate step would duplicate the prompt matching, choice resolution, category mapping, document identity and alternating transaction, roughly 280 of the file's 450 lines and the most subtle 280. C was rejected because removing spring's enrol breaks the path REPORT-83 migrated onto the mint, and spring cannot use `enroll-specified-class` either since it enrols by raw class id, so C amounts to retiring `spring-2026` outright.

---

### How is the surname in a class word mapped to the table's full teacher name?
**Context**: The table's teacher column holds `Alyssa Bingler`; the class word holds `FT-2026-Bingler`. Where the mapping lives changes what happens when the study adds a teacher.
**Options considered**:
- A) Key the transcribed table on the **surname** directly.
- B) Keep full names in the table and add an explicit surname-to-full-name map alongside it.
- C) Derive the surname from the full name at load time (last whitespace-separated token).
- E) Key the strata on the **whole origin class word**, needing no surname at all.

**Decision**: **A, with the teacher's full name kept as a field on each row rather than as a comment.** The strata key on the surname; the full name travels with the row so the transcription stays checkable against the PI's source document and a test can assert that `FT-2026-Bingler` resolves to the row labelled `Alyssa Bingler`. **Why not E**, which is otherwise simpler: the design randomizes *within teacher*, not within class, and those are identical only because there are five classes with one teacher each today. B was rejected for the two-structures-to-sync problem, C as fragile for no benefit. **Guard**: a test asserts the table contains exactly five distinct teacher keys, and that the surname and full-name counts are equal, which is what catches a sixth teacher sharing a surname.

---

### What should a student see when their class word cannot be classified or its teacher is unknown?
**Context**: Two new failure modes with no precedent message. Both mean the study is mis-configured rather than that the student did anything wrong, and both should stop the pipeline rather than guess.
**Options considered**:
- A) Both use the existing tell-your-teacher message.
- B) A distinct message naming the misconfiguration.
- C) Different treatment for each: unknown prefix as tell-your-teacher, unknown teacher as generic.

**Decision**: **A, both to the existing tell-your-teacher message.** It matches the precedent REPORT-79 set, telling a teacher is genuinely the only useful action available, and it adds no new student-facing string for two engineering failures a student cannot distinguish or act on either way. B was rejected because the actionable detail belongs in the **log**. C was rejected because the generic bucket implies "try again", which is false here: both failures are permanent until someone edits configuration. **Logging requirement**: error level, not info, carrying the offending value, since that is what diagnoses the fault.

---

### Should the `resolve-origin-class` step be a pipeline step at all, or a helper the steps call?
**Context**: A step publishes `originClassWord` once for every later step to reuse via `stepResults`, but adds a processing tick the student sees and must be placed first in every stage.
**Options considered**:
- A) A pipeline step, publishing `originClassWord` on `StepOutput`.
- B) A lazily-cached helper that any step calls, memoised on `StepContext` like the token cache.
- C) A step, with a processing message folded into the next action.

**Decision**: **A, the step.** The two options are closer than they appear (both perform one portal read and one mint per run, and both add one field to a shared type), so the step wins on three counts: it is **visible in `PIPELINES`**, a failure is **attributed to `resolve-origin-class`** rather than surfacing inside whichever step happened to call first, and it uses **`stepResults`, which already exists** instead of adding a second memo channel. The helper's one structural advantage, laziness, does not apply, since all three fall stages need the class word. A module-level memo keyed by `jobPath` was rejected outright: Cloud Functions reuse warm instances, so it would leak across runs and serve a stale class word. **Amended during self-review: the guarded accessor originally attached to this decision is dropped**, under the standing principle that our own pipeline ordering is assumed correct rather than checked with defensive run-time code.

---

### Should a student who changes a demographic answer between clicks be assigned twice?
**Context**: The shipped lookup de-duplicated **within a stratum**, so a student whose stratum changed between two clicks was not found under the new key and was assigned again, possibly to the opposite arm. The window is real: the pre-test is locked only **after** a successful run, so any failure between assignment and lock returns the student to an unlocked pre-test where they can change an answer and click again.
**Options considered**:
- A) Keep per-(stratum, student) de-duplication and accept the double assignment.
- B) De-duplicate **per student**, walking the document's strata inside the existing transaction.

**Decision**: **B.** The decisive argument is not study-design purity but that `add_to_class` only adds: re-bucketing cannot move a student, only enrol them into a second class alongside the first, contaminating both arms. Note the framing correction made during review: this is **stratified alternation**, not randomization, since demographics select the bucket and arrival order within the bucket selects the arm. No new storage; the record already exists in `jobs-task-data`.

---

### Does spring inherit the de-duplication fix, given that both steps share the extracted core?
**Context**: The spec originally claimed "the spring pipeline's behaviour is unchanged" while specifying a shared core whose de-duplication spring necessarily inherits, so the spec asserted something its own design made false. **Verified against the shipped code**: driving the real transaction with a document in which `user-1` already holds `treatment` under one stratum, then re-invoking under another, returned `control` and wrote, consuming the second stratum's rotation slot; under the walk it returns `treatment` and writes nothing.
**Options considered**:
- A) Spring inherits the fix, and the claims are amended to name the delta.
- B) Parameterize the core with a per-pilot dedup scope to keep spring bit-identical.
- C) Defer the de-duplication to its own story.

**Decision**: **A.** `spring-2026` is dormant, so the blast radius is nil, and the change is made because the argument is about the enrolment primitive rather than about which cohort is running. B was rejected because it requires the mode conditional the design explicitly forbids and doubles the test matrix to protect a path nobody wants; C was rejected because it would ship the fall path with the known double-enrolment behaviour. The changed case is asserted by a test, since the only existing de-duplication test covered a *same-stratum* re-click and the change would otherwise have landed with a fully green suite.

---

### Should flex balance within each section or across the whole cohort?
**Context**: The assignment document id includes `context_id`, so each registration class gets its own document and its own alternating counters. For full-time that is exactly right. For flex it may work against the design: all 24 strata apply within a single section, so many cells hold one or two students, alternation barely operates, and each near-empty cell resolves to whichever arm the table seeds it with.
**Options considered**:
- A) Keep the per-class key for both programs.
- B) Pool all flex students across the three sections.

**Decision**: **B**, on the PI's answer (Trudi, 2026-07-29): "Flex should be across ALL THREE SECTIONS. All flex kids are considered in the same group." Scoped into this story rather than split out, because the resolved program is already this story's product and a separate story would have to re-derive it. ⚠️ **The fix is not the one the finding originally proposed**: excluding `context_id` alone leaves three documents, because `resource_link_id` is the offering id and the three sections are three classes; and excluding `resource_link_id` as well would merge all eight classes into one document on the shared `interactiveId`, silently destroying full-time's within-teacher balancing with every test still passing. The resolution is a **program-dependent assignment scope**.

---

### Are `"full-time"` and `"flex"` the right program strings to commit to?
**Context**: The program string is hashed into the pooled flex document id, so it is persisted data rather than a label.
**Options considered**:
- A) Plain `"full-time"` / `"flex"`.
- B) Year-qualified `"fall-2026-full-time"` / `"fall-2026-flex"`.
- C) The `FT` / `FL` class-word prefixes.
- D) Keep `"flex"` as the program id and add a separate `FLEX_POOL_KEY` constant for the persisted identity.

**Decision**: **B.** `interactiveId` is the authored embeddable's `ref_id`, a property of the **activity** rather than of the class or the year, and `platform_id` is the portal, so the pooled key's three components are all stable across cohorts where the per-class key re-keys itself automatically. An unqualified `"flex"` would silently land a later flex cohort in the fall-2026 document: counters would continue from wherever fall left off rather than from the table's `n1`, the document would grow across years against the 1 MiB ceiling, and a student appearing in both cohorts would keep their original arm. D is arguably the more precise factoring, since the two strings have different lifetimes, but it adds a second concept for a study that will most likely run once. **Kept from D**: a test pinning the pooled document id for known inputs, so a rename fails loudly instead of silently re-keying live assignments.

---

### How strictly should the teacher surname be matched against the table?
**Context**: Drafted as a slip-tolerance trade-off. ⚠️ **It was not one: the case-sensitive version was broken against real data and would have failed every fall student in both programs on launch day.** `Portal::Clazz` runs `before_validation :class_word_lowercase` and `:class_word_strip` on create and on every update, and `offerings#show` serves the stored value, so `resolveOriginOffering` returns `ft-2026-bingler`, never the spreadsheet's `FT-2026-Bingler`. Driven against the eight real class words as the portal stores them, the drafted classifier returned `undefined` for **8 of 8**.
**Options considered**:
- A) Exact and case-sensitive, as drafted.
- B) Case-insensitive comparisons at each consumer.
- C) Normalize once at the producer, so every consumer matches exactly.

**Decision**: **C, plus lowercase destination suffixes and a harness fixture fix.** `resolve-origin-class` publishes `classWord.trim().toLowerCase()`, so `originClassWord` is by contract always in the portal's stored form. **Why C over B**: `originClassWord` is consumed by this story, by REPORT-80 and by REPORT-82, so normalizing at the single producer makes the invariant something those stories inherit, where scattered case-insensitive comparisons would let each reintroduce the bug independently. **Two knock-on corrections**: the destination suffixes become `-gator` / `-shark`, since a mixed-case suffix on a lowercase origin yields a mongrel that resolves only through MySQL's implicit `utf8_general_ci` collation; and the persisted stratum key uses the table's canonical values rather than the input's, since it is a Firestore document key that outlives any run.

---

### Should an unmatched **flex** stratum give the generic message or tell-your-teacher?
**Context**: The fall step gives tell-your-teacher for an unclassifiable class word and an unknown surname, but the drafted code funnelled an unmatched flex stratum into the generic retry message. **The deep dive moved the target.** Enumerating what the category mapping can emit gives 2 x 2 x 2 x 3 = 24 keys and the shipped table is exactly those 24, so the flex branch is unreachable from data. What the enumeration exposed instead is a **reachable** branch with the same defect: `mapToCategory` throws on an unmapped gender or grade choice, which the drafted code answered with "please try again".
**Options considered**:
- B) Change the flex branch only.
- C) Change spring to match.
- D) Change the flex branch **and** split the outcome type so an authoring failure is distinguished from a transport failure.

**Decision**: **D.** `DemographicsOutcome` gains an `unmappable` member (a duplicated prompt, an unknown choice id, or a choice label absent from a map: all authoring faults, all permanent) alongside `failed` (Firestore or transport, genuinely retryable). The existing try/catch structure already separated them exactly, so the split costs a type member and one branch. **Spring is unchanged**, mapping both to its existing generic message. **Why not C**: it buys consistency on a path nobody runs and spends the spring blast radius this story has carefully limited to one delta. **Why not B alone**: it fixes only the branch that cannot be reached while leaving the one that can.

---

### Where should the two `PreTestConfig` objects live?
**Context**: The repo has no shared configuration module: every step keeps its constants private at module scope, so "each step owns its object" matched convention.
**Options considered**:
- A) Each step owns its own object privately.
- B) Both objects in one `pre-tests.ts`, each step importing its own by name.
- C) Either layout, plus a test pinning their current equality.

**Decision**: **B, plus C's pinning test.** Two things outweigh the convention. First, this plan already breaks it deliberately for exactly this reason: `strata-tables.ts` exists so both transcribed tables sit side by side, and the pre-test configs are the same kind of artifact, transcribed authored content whose correctness is judged against something outside the repo. Second, the drift argument is weak and **reviewability** is the real axis: the claim to check is "the fall object is identical to spring's, per the PI's confirmation", which under A is a two-file diff compared by eye and under B is two adjacent literals. The step remains the selector, since each still names its own object by import. **The pinning test's value is the forcing function**: when the wording does diverge, it fails and whoever edits the object has to update the attribution comment in the same change. It is deliberately a test that will one day be deleted, and it is named so that this is obvious.

---

### Is the seven-step commit sequence the right granularity?
**Context**: Whether seven steps was too fine, given that the first three all touch one small module.
**Options considered**:
- B) Merge the first three assignment-document steps.
- C) Reorder so the extraction comes first.
- D) Split the demographics extraction into "extract" and "retarget the tests".

**Decision**: **D, eight steps** (nine with the CI job added later). **Measured rather than estimated**: the extraction was built as a throwaway and the full suite run **with no test file edited at all**, 8 suites / 224 tests passing. Splitting production from its tests is right here against the usual rule, because the measurement shows the tests do cover the extracted code, just through the step, and "224 tests pass, no test file touched" is the strongest evidence available that a refactor preserved behaviour. Editing the tests in the same commit destroys that evidence. Merging steps 1 to 3 was rejected because step 1 unavoidably edits tests (they import the two functions from `./random-assignment`, and no pass-through re-export is added), so merged they come to roughly 600 added lines with the one behaviour change buried in the middle. Reordering was measured as free and pointless.

---

### Should the `teacherFullName` field be committed to a public repository?
**Context**: The five real teachers' full names ship in a field the code never reads, in a world-readable repository, and are reproduced in the spec. The field is read by exactly one test and by a human comparing the transcription to the PI's document; the stratum key, the lookup, every log line and the assignment document all use the surname only, which is already public in the class word.
**Options considered**:
- A) Keep surnames only in the repo and hold the mapping in the uncommitted working note.
- B) Keep the field and record the decision.

**Decision**: **B. Teacher names are not PII for this study; only student names are.** The finding's premise is rejected on the owner's call, so `teacherFullName` stays on every row and the table stays reproduced in the spec. The row comment is corrected: it had asserted "Real teacher names are PII", which is the wrong reason for a warning still worth keeping on the narrower ground that nothing needs the field. Student names never reach this pipeline at all. The related finding, that logging a class word and a surname identifies a teacher as precisely as a full name does within a five-teacher study, is **withdrawn** under the same ruling.

---

### Should the destination class word be persisted alongside the arm?
**Context**: The de-duplication walk makes the **arm** sticky *within one assignment document*, but `destinationClassWord` is re-derived on every run from the origin class word resolved that run. A student whose origin class changes between two clicks therefore receives a different destination word, so if the first click's enrolment had succeeded and the run then failed before `lock-activity`, they end up enrolled in two destination classes.
**Options considered**:
- A) Accept and document it.
- B) Persist the destination word beside the arm and reuse it.

**Decision**: **A**, on the flex case, which is what this decision was reasoned about. For **flex** the two destinations are in the **same arm**, because pooling means a section move reads the same document and the walk returns the original arm. Severity is genuinely lower than the arm case, and that is the point of stating it: no arm is contaminated and the study's validity is intact, so it is a roster-tidiness problem for a teacher rather than a data-integrity problem for the PI. B was rejected because it would put a second value in the assignment document and make a legitimate mid-study class change unfollowable.

**Correction made after review: the "same arm" premise does not hold for full-time**, whose per-class scope includes `resource_link_id` and `context_id`. A move between two full-time classes re-keys the document, so the walk cannot find the student and reassigns them, possibly into the opposite arm and therefore into two classes in **different** arms. A still stands, because persisting the destination word does not fix that either: the defect is in the **scope** of the de-duplication, not in the destination derivation, and closing it needs the program-wide student→arm index this story declined. What changes is the claim, not the decision. Recorded at the call site, in the walk's comment block, and as an operational item on the study: a mid-study move between full-time classes needs the prior assignment inspected. Note the flip side, which is a real property of pooling and worth keeping: **flex is immune by construction**, because every section resolves to one document.

---

### Should the "please complete these questions" message name internal dimension labels?
**Context**: The message is built from `Dimension` names, so a student sees "Gender, Race" rather than the questions as worded. It is carried forward verbatim from spring, but the fall step is **new code**, which is where an inheritance becomes a decision, and full-time reads only two dimensions so a full-time student's message can only ever name the two most likely to be misread.
**Options considered**:
- A) Record it as a deliberate carry-forward.
- B) Add a student-facing label per dimension to `PreTestConfig` and use those.

**Decision**: **A.** Keeping one message shape across both steps is worth more than better copy on a path that only fires when a student genuinely skipped a question. B is the revisit if the fall run shows students getting stuck here. Not a launch blocker either way.

---

### Should this story fix the missing CI coverage for the functions package?
**Context**: The plan constrains `assignment-doc.ts`'s **entire** import list, and puts a prominent header comment on the module to defend it, so that one emulator test can import real production code. **Verified: no CI job ran it, and none ran the functions unit suite either.** The workflow that triggers on `functions/**` runs the Firestore rules suite and query-creator; across all five workflow files, `working-directory` was never `functions`. As drafted, someone could add a logger import for one log line, break the property the header comment defends, and see nothing fail anywhere.
**Options considered**:
- A) Add a CI job running lint, the unit suite and the emulator suite.
- B) Say in the plan that the proof is manual-run-only and name `npm run test:emulator` as a pre-merge action.

**Decision**: **A**, scoped into this story. The pre-existing gap is arguably not this story's job, but resting an architectural constraint on an unenforced test without saying so is. Every line of the job was verified before committing to it: node 22 matches `engines.node` where the two existing jobs pin 18 for their own packages, `npm ci` has a lockfile, and `npm run test:emulator` runs from `functions/` with no credentials and no extra config flag. **One trap is recorded with it**: adding `npm run build` before the test steps makes jest pick up compiled duplicates from `lib/`, four of which fail on the same `firebase-admin/auth` resolution problem that shapes the module split.

---

### Where should the harness's mixed-case class-word fixtures be fixed?
**Context**: `config.js` seeded mixed-case class words and the stub echoed them verbatim, so a local run saw `FL-spring-2026-origin` where production sends `fl-spring-2026-origin`. That is a fixture asserting a contract the portal does not honour, and it is exactly the fidelity gap that would have let this story's casing defect pass locally and fail on launch day.
**Options considered**:
- A) Lowercase the fixtures only.
- B) Lowercase the fixtures **and** make the stub model the portal's lowercasing.

**Decision**: **B**, and the second change matters more than the first: with the stub downcasing, a future fixture written in spreadsheet casing still produces the production shape, so the gap cannot silently reopen. `name` keeps its display casing, since the portal lowercases `class_word` only and `name` is what `send-email` renders. The lookup is case-insensitive because `portal_clazzes` is charset `utf8` with no explicit collation, which is why student self-registration accepts a typed word in any case. Verified by running the three `run-step` scenarios before and after: 3/3 pass both ways.

---

### Implementation deltas found by building the code

Four changes came out of running or reviewing the code rather than from the plan, and are recorded here because each one changes an interface the plan specified.

**`fullTimeStratumKey` takes only the matched row**, not `(stratum, gender, race)`. The row already carries its own gender and race, so the extra parameters could disagree with the row they came from; the canonical-source argument for taking the surname from the row applies identically to the other two components.

**`DemographicsOutcome.categories` is `Partial<Record<Dimension, string>>`**, not a total record. The total type promised four values while filling only the requested ones, so a caller reading an unrequested dimension got `undefined` with no type-level signal, and the fall step's `String(Gender)` would have interpolated the literal `"undefined"` into a **persisted** stratum key on a full-time read. The fall step now guards the dimensions its branch requires before building a key, classified like the flex branch's unmatched stratum: unreachable from data, permanent, tell-your-teacher.

**`"/lib/"` was added to jest's `testPathIgnorePatterns` two steps earlier than planned**, because the harness `run-step` driver requires `npm run build` and jest then picks up the compiled test duplicates.

**Three tests were added for criteria the plan's test lists left without a home**: spring's assignment document identity pinned against a direct sha256 of the shipped input string (the load-bearing one, since nothing asserted the "unchanged for spring" claim), spring giving an `unmappable` read the same generic message as a `failed` one, and the flex destination word asserted as an exact string rather than against its own lowercased form.

Two things the plan predicted held exactly: `readDemographics`'s outer catch had to say `unexpected error reading demographics` for the extraction to land with no test file edited, and the de-duplication walk's loop variable had to be `candidate` rather than `stratum` or tslint's `no-shadowed-variable` fails the build.
