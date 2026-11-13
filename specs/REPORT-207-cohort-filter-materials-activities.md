# The cohort filter admits activities attached through the cohort's project materials

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-207

**Status**: **Closed**

## Overview

When a report was filtered by a cohort, the report server kept only learners on activities that are items of that cohort, so learners on activities attached to the cohort's project through its materials list silently dropped out. This story makes the cohort filter admit both kinds of activity, in every report and filter option that offers it, without changing who may see what.

A portal project can attach an activity to itself in two ways: as an item of one of its cohorts, or on the project's materials list. The permission check accepted both since RIGSE-10, but the cohort filter accepted only the first, so projects that attach everything through materials (M2Studio, High-Adventure Science, AI in Math, Neural Engineering and others) got empty cohort-filtered reports, and projects that mix the two (StoryQ, InquirySpace, Geniventure, CMP Digital CLUE and others) got partial ones. On production, 28 of the 35 cohorts ever used in a report filter belong to projects with materials-only activities, covering 173 of 194 cohort uses since December 2024. Reports filtered any other way, and the rules for which students each kind of user may see (including REPORT-195's researcher rules), do not change.

## Requirements

- **R1. The rule.** A selected cohort admits a row when the row's teacher is an item of a selected cohort (unchanged) and the row's activity is either an `ExternalActivity` item of a selected cohort or an `ExternalActivity` material of the project of a selected cohort. The teacher side and the activity side are matched independently against the selected cohorts; neither has to name the same cohort as the other.
- **R2. Every report that offers the cohort filter applies R1:**
  - the learner query `LearnerBaseQuery`, and with it Student ID Mapping, Student Metadata, the four Athena student reports (Assignment Usage by Student, Student Actions, Student Actions with Metadata, Student Answers) through `LearnerData`, and the bulk, attachments and CLUE exports through `EndpointSet.fetch_learners`;
  - Teacher Status, Summary Metrics by Assignment and Detailed Metrics by Assignment;
  - Teacher Actions' activity list (its teacher list already filters by teacher alone and is unchanged).
- **R3. Filter options follow R1 in both directions.** With a cohort selected, the assignment options include activities on the selected cohorts' projects' materials lists. With an assignment selected, the cohort options include the cohorts whose project lists that assignment as a material. This holds for the report form and for the filter-option API, which share `ReportFilterQuery`.
- **R4. One definition.** Every place in R2 and R3 builds the activity side of R1 from one shared module, `ReportServer.Reports.CohortFilter`. No cohort-activity join to `admin_cohort_items` remains in those places.
- **R5. No duplicated rows.** Admitting an activity through both routes, or through several selected cohorts, does not repeat a row or change a count. The predicate is a WHERE condition, which cannot add rows, so this holds by construction.
- **R6. Nothing else changes.** Reports filtered by class, teacher, school, assignment, permission form or student, with no cohort, return what they returned before. The caller's project scoping and REPORT-195's researcher rules are untouched: in every report that has project scoping, a cohort filter can only narrow what the caller already sees. Teacher Actions reads only teacher log events and has no project scoping to preserve.
- **R7. Tests that can fail.** The portal fixture gains cohort 6 of project 900 (teacher 31, no activity, so project 900's materials are its only route to 801 and 803), two `Investigation` decoy rows whose ids collide with activities, and `report_learners.runnable_id`. DB tests cover the learner paths (project admin, researcher, site admin; Student ID Mapping and the Athena fetch), the activity-side negatives where the teacher side passes (learner 902 under cohort 6, cohort 5's learners on 801), both option cascades including cases that fail when a cascade ignores the selection, the predicate itself from both sides, and Teacher Actions' activity list. *(Teacher Status and both resource metrics reports are checked at the SQL level only, because they select columns the fixture lacks.)*
- **R8. Docs.** The server README's "Who sees which students" section states what a cohort filter keeps.

## Technical Notes

- **Shape of the predicate.** `<activity> IN (the selected cohorts' ExternalActivity items) OR <activity> IN (the ExternalActivity materials of the selected cohorts' projects)`, two uncorrelated subqueries (`CohortFilter.activity_in_cohorts/2`). For cohort options under an assignment, the mirror, `CohortFilter.cohort_admits_activities/2`: `admin_cohorts.id IN (cohorts holding the assignment as an item) OR admin_cohorts.project_id IN (projects holding it as a material)`.
- **Cost, measured** on a synthetic portal (MySQL 8.0.39, rigse's indexes, 864,000 `report_learners`, two cohorts whose teachers reach 177,408 learners, about four times production's largest cohort): the old item-only join 0.04 s; the teacher side alone 0.20 s; `IN ... OR IN ...` 0.19 s; correlated `EXISTS ... OR EXISTS ...` 1.3 to 1.5 s; `IN (... UNION ...)` 1.4 to 1.5 s. MySQL materializes each uncorrelated subquery once, so the chosen form costs what the teacher side already costs. Production runs MySQL 8.0.42.
- **Filter-option cascades.** A `@secondary_filter_config` entry's `where` is either a prefix that the selected ids' IN list completes or a 1-arity function of the selected ids; the two cohort/assignment cascades use functions (`ReportFilterQuery.assignment_in_cohorts/1`, `cohort_admits_assignments/1`), and the IN list is built only for a prefix.
- **REPORT-195.** The branch is stacked on REPORT-195's follow-up branch and both ship in 1.13.1. REPORT-195 decides which students a researcher sees from the teacher's cohort project; the cohort filter is an extra WHERE predicate beside that scoping.
- **Stored results and release notes.** Portal reports are computed on every read, so existing runs pick up the fix. An Athena run keeps the rows it was computed with and must be duplicated; its bulk, attachments and CLUE exports re-read learners from the run's filter on every request, so until it is duplicated they may hold learners its CSV lacks. For Teacher Actions, an empty activity list drops the `log.activity` clause, so a cohort selection whose teachers offered none of the admitted activities gives the cohorts' teachers' events on every activity; the fix narrows such runs when the teachers offered any project material, and leaves them unchanged when they offered none. The 1.13.1 release note text: "Filtering a report by cohort now includes learners on activities that are on the cohort's project's materials list, not only those that are items of the cohort. Portal reports pick this up the next time they are opened. An Athena report filtered by cohort before 1.13.1 may be missing learners; duplicate it to get the full set. Its bulk, attachments and CLUE exports already include them, so until it is duplicated they may hold learners its CSV does not. A Teacher Actions run filtered by a cohort that holds no activities of its own may have held the cohort's teachers' events on every activity; a duplicate holds only the activities on the cohort's project's materials, unless the teachers assigned none of them."

## Out of Scope

- **Project scoping for Teacher Actions.** Its teacher and activity lists read the whole portal for any caller. That is deliberate: the report server protects student data, and Teacher Actions returns only teacher log events.
- Teacher Actions' teacher list, and every other cohort clause that reaches teachers (`admin_cohort_items` with `item_type = 'Portal::Teacher'`), are correct and unchanged.
- Re-running or correcting stored results of earlier cohort-filtered runs.
- The `Investigation` cohort items `server/docs/cohort-schema.md` mentions: there are seven on production and they point at no rows.

## Decisions

### Must the activity's cohort match the teacher's cohort?
**Context**: With several cohorts selected, R1 could require the activity to be admitted by the same cohort the teacher is in, or match each side against the selection independently.
**Options considered**:
- A) Independent, as the old item rule was: teacher in any selected cohort, activity admitted by any selected cohort.
- B) Same cohort: pair the teacher's cohort with the activity's cohort or that cohort's project.

**Decision**: A. The old clauses matched the teacher and the activity against the selection separately, and the story asks only to widen the activity side. B would also change results for item-only activities with two cohorts selected.

---

### Does a cohort admit all of its project's materials, or only those its own teachers assigned?
**Context**: A project with several cohorts shares one materials list, so every one of its cohorts admits every material.
**Options considered**:
- A) All of the project's materials; the teacher side already limits rows to the cohort's teachers.
- B) Something narrower, which the portal has no data for: materials are not recorded per cohort.

**Decision**: A. The teacher side keeps a cohort's report to its own teachers' classes, so the shared list adds no other cohort's learners.

---

### Test the teacher-level reports by running them, or at the SQL level?
**Context**: Teacher Status and the resource metrics reports select `po.created_at`, `run.start_time` and grade-level tables, which the fixture lacks; Teacher Actions lacked only `report_learners.runnable_id`.
**Options considered**:
- A) Run the shared predicate against the fixture once, and assert each report's SQL uses it.
- B) Extend the fixture schema until every report runs on it.

**Decision**: A for the three portal reports, and a fixture run for Teacher Actions, since one nullable column is all it needs. The rule lives in one function, so one DB test of it plus a usage check per report catches a report that stops using it.

---

### How does the fixture get a learner whose activity reaches a cohort only through materials?
**Context**: The story's AI instructions suggested an offering of 803 with a learner. Measured: a learner on 803 in class 601 broke 20 existing tests that read class 601's learners; one in a new class with a new teacher and student broke 20 others that enumerate classes, teachers and students.
**Options considered**:
- A) A new learner on 803.
- B) A new cohort 6 of project 900 holding teacher 31 and no activity, so 801 and 803 reach it only through project 900's materials.

**Decision**: B. It exercises the same rule with the fixture's existing learners, and moves two existing tests instead of twenty.

---

### Should Teacher Actions get project scoping?
**Context**: Teacher Actions applies no project scoping, so any project admin or researcher can read any teacher's log events on any activity with it. It was noticed while tracing this story's code.
**Options considered**:
- A) File a follow-up story to scope Teacher Actions like the other reports.
- B) Fold it into this story.
- C) Leave it, as intended behavior for teacher-level log data.

**Decision**: C (Doug). The lack of scoping is intended: the report server filters out student data, and Teacher Actions reads only teacher log events.

---

### The predicate's shape
**Context**: The story's AI instructions suggested correlated `EXISTS` subqueries. REPORT-195 had measured a per-row correlated subquery in Student Metadata at 246 s against a 300 s timeout.
**Options considered**:
- A) `EXISTS (...) OR EXISTS (...)`, correlated on the activity.
- B) `IN (...) OR IN (...)`, uncorrelated.
- C) `IN (... UNION ...)`.

**Decision**: B. Benchmarked at 0.19 s against 1.3 to 1.5 s for A and C on a cohort four times production's largest (see Technical Notes).

---

### Tests that could not fail
**Context**: Several planned tests passed under the mutation they were meant to catch.
**Options considered**:
- A) Keep them as written.
- B) Replace each with a case that fails under its mutation, or drop it.

**Decision**: B. A learner-level negative on cohort 2 (no teacher items) was moved to cohort 5; option tests run as a project-900 admin gained cohort 3 and assignment 802 cases, since 801/803 and cohorts 1/6 are everything that caller sees; two `Investigation` decoy rows make the `item_type` and `material_type` checks testable; and a two-cohort predicate case that passed with a rule reading only one cohort was dropped.

---

### Which existing runs change, and how
**Context**: The release note first said every earlier cohort-filtered run must be re-run.
**Options considered**:
- A) Tell users to re-run every cohort-filtered report.
- B) Say per kind of run what changes.

**Decision**: B. Portal runs are computed on every read; only Athena runs need a duplicate, and their exports change at once; Teacher Actions runs can narrow rather than grow (see Technical Notes).

---

### A function-valued `where` in the cascade config, or a special case in `apply_secondary_filters/5`?
**Context**: Every cascade `where` was a prefix the IN list completes; the two cohort/assignment cascades need a whole predicate built from the ids.
**Options considered**:
- A) Let a config `where` be a 1-arity function of the selected ids, as a remote capture.
- B) Match the two `{primary, secondary}` pairs by name in `apply_secondary_filters/5`.

**Decision**: A. The config stays the one place that says how each pair narrows. The final review moved the IN-list construction into a two-clause helper, so the function path no longer builds an IN list it does not use.

---

### One commit or four?
**Context**: The rule, the learner query, the options and the teacher-level reports could ship as one commit.
**Options considered**:
- A) Four: the rule with its first user, the options, the remaining reports, the README.
- B) One commit.

**Decision**: A. Each step is green on its own, and the reviewer sees the rule's tests before the call sites that depend on them.
