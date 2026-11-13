# The cohort filter admits activities attached through the cohort's project materials

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-207
**Repo**: https://github.com/concord-consortium/report-service
**Implementation Spec**: [implementation.md](implementation.md)
**Status**: **In Development**

## Overview

When a report is filtered by a cohort, the report server keeps only learners on activities that are items of that cohort, so learners on activities attached to the cohort's project through its materials list silently drop out. This story makes the cohort filter admit both kinds of activity, in every report and filter option that offers it, without changing who may see what.

## Project Owner Overview

A portal project can attach an activity to itself in two ways: as an item of one of its cohorts, or on the project's materials list. The report server's permission check has accepted both since RIGSE-10, but its cohort filter still accepts only the first. A project admin, researcher or site admin who filters a report by cohort therefore gets no rows at all for a project that attaches everything through materials (M2Studio, High-Adventure Science, AI in Math, Neural Engineering and others), and a partial report for a project that mixes the two (StoryQ, InquirySpace, Geniventure, CMP Digital CLUE and others). Nothing on the report says rows are missing.

On production, 28 of the 35 cohorts ever used in a report filter belong to projects with materials-only activities, covering 173 of 194 cohort uses since December 2024; a cohort used in September 2026 left out 73% of its learners. After this fix a cohort-filtered report also covers the cohort's teachers' students on the project's materials, and the assignment list under a selected cohort shows the project's materials too. Reports filtered any other way do not change, and the rules for which students each kind of user may see (including REPORT-195's researcher rules) do not change.

## Background

The portal records a project's activities in two tables: `admin_cohort_items` rows with `item_type = 'ExternalActivity'` (an activity is an item of a cohort, which belongs to a project through `admin_cohorts.project_id`), and `admin_project_materials` rows with `material_type = 'ExternalActivity'` (an activity is on a project's materials list). A cohort's teachers are `admin_cohort_items` rows with `item_type = 'Portal::Teacher'`.

The caller's project scoping, `ReportUtils.scope_by_allowed_projects/6`, and the assignment option scope in `DimensionScope` both accept an activity reached either way (LEFT joins to `admin_cohort_items` and `admin_project_materials`, and a disjunction over the two project ids). The cohort filter does not: every cohort clause requires the activity to be an `admin_cohort_items` row of a selected cohort, through an inner join or a WHERE that turns a LEFT join inner. So an activity attached only through materials passes the scoping and then fails the filter.

Confirmed on this branch with throwaway tests against the portal fixture, where activity 803 is on project 900's materials and in no cohort. With an offering of 803 in class 601 and a learner on it (student 71, teachers 31 and 32, teacher 31 in cohort 1 of project 900):

| Caller | `class: [601]` | `cohort: [1]` | `cohort: [1], class: [601]` |
|---|---|---|---|
| project admin of 900 (555) | 901, 910 | 901, 903, 904 | 901 |
| researcher of 900 (557) | 901, 910 | 901 | 901 |
| site admin (560) | 901, 902, 910 | 901, 903, 904 | 901 |

Learner 910 is the one on 803. The Athena learner fetch (`LearnerData.fetch/3`) gives the same answer as Student ID Mapping. In the filter options, assignments under `cohort: [1]` are only `801` although `803` is offered with no narrowing, and cohorts under `assignment: [803]` are empty.

A throwaway prototype of the fix (one helper producing the predicate, used by `LearnerBaseQuery` and the two option cascades) added learner 910 to every `cohort` column above, for all three callers and in the Athena fetch, made the option cascades return 801 and 803 under cohort 1 and cohort 1 under 803, and kept learner 902 (activity 802, which no project holds) out under a cohort filter for the site admin.

## Requirements

- **R1. The rule.** A selected cohort admits a row when the row's teacher is an item of a selected cohort (unchanged) and the row's activity is either an `ExternalActivity` item of a selected cohort or an `ExternalActivity` material of the project of a selected cohort. The teacher side and the activity side are matched independently against the selected cohorts, as they are today; neither has to name the same cohort as the other.
- **R2. Every report that offers the cohort filter applies R1:**
  - the learner query `LearnerBaseQuery`, and with it Student ID Mapping, Student Metadata, the four Athena student reports (Assignment Usage by Student, Student Actions, Student Actions with Metadata, Student Answers) through `LearnerData`, and the bulk, attachments and CLUE exports through `EndpointSet.fetch_learners`;
  - Teacher Status, Summary Metrics by Assignment and Detailed Metrics by Assignment;
  - Teacher Actions' activity list (its teacher list already filters by teacher alone and is unchanged).
- **R3. Filter options follow R1 in both directions.** With a cohort selected, the assignment options include activities on the selected cohorts' projects' materials lists. With an assignment selected, the cohort options include the cohorts whose project lists that assignment as a material. This holds for the report form and for the filter-option API, which share `ReportFilterQuery`.
- **R4. One definition.** Every place in R2 and R3 builds the activity side of R1 from one shared function, so the rule cannot drift between reports. No cohort-activity join to `admin_cohort_items` remains in those places.
- **R5. No duplicated rows.** Admitting an activity through both routes, or through several selected cohorts, does not repeat a row or change a count. (Today's inner join on `aci_assignment` fans out per matching cohort item and relies on each report's grouping; the new predicate is a WHERE condition, which cannot add rows, so R5 holds by construction and needs no test of its own.)
- **R6. Nothing else changes.** Reports filtered by class, teacher, school, assignment, permission form or student, with no cohort, return what they return today. The caller's project scoping, and REPORT-195's rules for researchers (consent by permission form, projects with no forms, names, CLUE documents), are untouched: in every report that has project scoping, a cohort filter can only narrow what the caller already sees, never widen it. (Teacher Actions reads only teacher log events and has no project scoping to preserve; see Out of Scope.)
- **R7. Tests that can fail:**
  - The portal fixture gains cohort 6 of project 900, holding teacher 31 and no activity, so project 900's materials are its only route to 801 and 803. Under today's rule it admits nothing. It also gains an `Investigation` item 803 in cohort 2 and an `Investigation` material 802 of project 901, so a rule that stops checking `item_type` or `material_type` admits a wrong activity.
  - DB tests on the fixture: under `cohort: [6]`, Student ID Mapping gives the project admin of 900 and the site admin learners 901, 903 and 904, and the researcher of 900 learner 901 (REPORT-195's consent rule still applies); the Athena learner fetch gives the project admin and the researcher the same. For the site admin, learner 902 (on 802, which no project holds, in teacher 31's class 601) stays out under `cohort: [6]`, and under `cohort: [5]` (project 904, whose teacher 36 reaches class 604) the learners on 801 stay out, because 801 is neither an item of cohort 5 nor a material of 904. These two are the cases where the teacher side passes and only the activity side can drop the row.
  - DB tests for both option cascades in R3, replacing the assertion that pins today's `[[801, "Activity One"]]`, as a project admin of 900: assignments under cohort 6 are 801 and 803, and under cohort 3 only 801; cohorts under assignment 803 are cohorts 1 and 6, and under 802 none. 801 and 803 are all of that caller's assignments and cohorts 1 and 6 all of its cohorts, so the cohort 3 and 802 cases are the ones that fail when a cascade ignores the selection.
  - The shared predicate itself is run against the fixture for an item-only activity (801 under cohort 3), materials-only ones (801 and 803 under cohort 6), and ones reached neither way (802 under cohort 6, anything under cohorts 2 and 5). Read from the cohort's side, unscoped: 803 admits cohorts 1 and 6 (not cohort 2, whose 803 is an `Investigation`), 801 cohorts 1, 3, 4 and 6, and 802 none.
  - Teacher Actions runs on the fixture (which gains `report_learners.runnable_id`, the one column it lacks): under cohort 6 its activity list holds 801's URL. Teacher Status and both resource metrics reports are checked at the SQL level to use the shared predicate, because they select columns and tables the fixture does not have (`po.created_at`, `run.start_time`, grade levels).
- **R8. Docs.** The server README's "Who sees which students" section states what a cohort filter keeps.

## Technical Notes

- **Code locations** (the same on master and on REPORT-195's branch):
  - `server/lib/report_server/reports/learner_base_query.ex` `apply_filters/3`: `join admin_cohort_items aci_assignment ... aci_assignment.item_id = po.runnable_id` plus `aci_assignment.admin_cohort_id in (...)`.
  - `server/lib/report_server/reports/portal/teacher_status_report.ex`, `resource_metrics_summary_report.ex`, `resource_metrics_details_report.ex` `apply_filters/3`: the same pattern on `ea.id` (Teacher Status repeats `aci_assignment.item_id = ea.id` in its WHERE).
  - `server/lib/report_server/reports/athena/teacher_actions_report.ex` `get_activities/2`: LEFT joins whose WHERE makes them inner.
  - `server/lib/report_server/reports/report_filter_query.ex` `@secondary_filter_config`: `cohort.assignment` (cohort options under assignments: `:cohort_items_assignment`, `aci_assignment.item_id IN`) and `assignment.cohort` (assignment options under cohorts: `:cohort_items_assignment_ref` = `DimensionScope.cohort_join(:from_assignment)`, `aci_cohort.admin_cohort_id IN`). Both join patterns become unused and go.
  - For contrast, `report_utils.ex` `scope_by_allowed_projects/6` and `dimension_scope.ex`'s `assignment` scope already accept materials.
- **Shape of the predicate.** `<activity> IN (the selected cohorts' ExternalActivity items) OR <activity> IN (the ExternalActivity materials of the selected cohorts' projects)`, two uncorrelated subqueries. For cohort options under an assignment, the mirror: `admin_cohorts.id IN (cohorts holding the assignment as an item) OR admin_cohorts.project_id IN (projects holding it as a material)`. Both directions live in one module (R4). A WHERE condition adds no rows, which gives R5.
- **Existing tests that move** (measured with the prototype and the cohort 6 rows; the other 1554 of 1558 pass): `learner_base_query_test.exs` snapshots the exact cohort SQL, and `report_filter_query_db_test.exs` "a scoped caller can narrow assignments by cohort" asserts `[[801, "Activity One"]]`; both pin today's rule. Cohort 6 itself moves two enumerations: `report_filter_query_db_test.exs` "scoping keeps another project's cohort out" (project 900's cohorts become 1 and 6) and `portal_fixture_test.exs` "the project scoping rows give one project admin a subset and another nothing" (teacher 31 now appears under two cohorts). No existing test asserts what either cohort/assignment cascade returns (the legal-SQL test only runs them), or covers Teacher Status's cohort clause, the resource metrics reports' or Teacher Actions'.
- **REPORT-195.** This branch is stacked on `REPORT-195-researchers-on-projects-without-forms` (PR #448), and both ship in 1.13.1. REPORT-195 decides which students a researcher sees from the teacher's cohort project (`ac_teacher_a.project_id` in `scope_by_allowed_projects/6`), which this story does not touch: the cohort filter is an extra WHERE predicate beside the scoping, so it can only remove rows the scoping admits.
- **Cost, measured.** A synthetic portal on MySQL 8.0.39 with rigse's indexes on the five tables (864,000 `report_learners`, 72,000 offerings, 300 cohorts in 60 projects, 6,000 activities), filtering two cohorts whose teachers reach 177,408 learners, about four times production's largest cohort:

  | Activity side | Time | Learners |
  |---|---|---|
  | today's inner join on `aci_assignment` (item only) | 0.04 s | 1,188 |
  | teacher side alone, no activity side | 0.20 s | 177,408 |
  | `IN (...) OR IN (...)` | 0.19 s | 3,528 |
  | `EXISTS (...) OR EXISTS (...)` (correlated) | 1.3 to 1.5 s | 3,528 |
  | `IN (... UNION ...)` | 1.4 to 1.5 s | 3,528 |

  The `IN ... OR IN ...` form costs what the teacher side already costs, because MySQL materializes each subquery once. The correlated `EXISTS` form, which the story's AI instructions suggest, runs once per teacher-reached row and is about 7 times slower; the `UNION` form is not materialized either. Today's join is faster only because it reads the cohort's few activity items first, which is what drops the materials. The production portal runs MySQL 8.0.42 (REPORT-195's check).
- **Stored results.** Portal reports (Student ID Mapping, Student Metadata, Teacher Status and both resource metrics reports) are computed on every read, so their existing runs pick up the fix with no action. An Athena run keeps the rows it was computed with: a cohort-filtered one made before the release has to be duplicated. Its bulk, attachments and CLUE exports are not stored: `EndpointSet.fetch_learners` reads the learners from the run's filter on every request, so they pick up the fix at once and, until the run is duplicated, hold learners its CSV lacks. For Teacher Actions the change can go either way: an empty activity list drops the `log.activity` clause, so a cohort selection whose teachers have no offering of an activity the selection admits gives the cohorts' teachers' events on every activity. Today that happens whenever the selected cohorts' teachers offered none of those cohorts' items (cohort 6 on the fixture, although project 900 holds 801 as an item of cohort 1); after the fix the list also takes their projects' materials, so such a run narrows to the admitted activities when the teachers offered any of them, and still holds every activity when they offered none (cohort 5 on the fixture, run). The release notes say all three.

## Out of Scope

- **Project scoping for Teacher Actions.** Its teacher and activity lists read the whole portal for any caller. That is deliberate: the report server protects student data, and Teacher Actions returns only teacher log events.
- Teacher Actions' teacher list, and every other cohort clause that reaches teachers (`admin_cohort_items` with `item_type = 'Portal::Teacher'`), are correct and unchanged.
- Re-running or correcting stored results of earlier cohort-filtered runs.
- The `Investigation` cohort items `server/docs/cohort-schema.md` mentions: there are seven on production and they point at no rows.

## Open Questions

### RESOLVED: Judgment call: must the activity's cohort match the teacher's cohort?
**Context**: With several cohorts selected, R1 could require the activity to be admitted by the same cohort the teacher is in, or match each side against the selection independently.
**Options considered**:
- A) Independent, as today's item rule is: teacher in any selected cohort, activity admitted by any selected cohort.
- B) Same cohort: pair the teacher's cohort with the activity's cohort or that cohort's project.

**Decision**: A. Today's clauses match `aci_teacher.admin_cohort_id` and `aci_assignment.admin_cohort_id` against the selection separately, and the story asks only to widen the activity side. B would also change results for item-only activities with two cohorts selected, which R6 forbids.

### RESOLVED: Judgment call: does a cohort admit all of its project's materials, or only those its own teachers assigned?
**Context**: A project with several cohorts shares one materials list, so under R1 every one of its cohorts admits every material.
**Options considered**:
- A) All of the project's materials; the teacher side of R1 already limits rows to the cohort's teachers.
- B) Something narrower, which the portal has no data for: materials are not recorded per cohort.

**Decision**: A. The teacher side keeps a cohort's report to its own teachers' classes, so the shared list adds no other cohort's learners.

### RESOLVED: Judgment call: test the teacher-level reports by running them, or at the SQL level?
**Context**: Teacher Status and the resource metrics reports select `po.created_at`, `run.start_time` and grade-level tables, which the fixture lacks; Teacher Actions lacks only `report_learners.runnable_id`.
**Options considered**:
- A) Run the shared predicate against the fixture once, and assert each report's SQL uses it.
- B) Extend the fixture schema until every report runs on it.

**Decision**: A for the three portal reports, and a fixture run for Teacher Actions, since one nullable column is all it needs (measured: the full suite stays green with it). The rule lives in one function, so one DB test of it plus a usage check per report catches a report that stops using it.

### RESOLVED: Judgment call: how the fixture gets a learner whose activity reaches a cohort only through materials
**Context**: The story's AI instructions suggest an offering of 803 with a learner. Measured: a learner on 803 in class 601 breaks 20 existing tests that read class 601's learners; one in a new class 606 with a new teacher and student breaks 20 others that enumerate classes, teachers and students.
**Options considered**:
- A) A new learner on 803.
- B) A new cohort 6 of project 900 holding teacher 31 and no activity, so 801 and 803 reach it only through project 900's materials.

**Decision**: B. It exercises the same rule (an activity admitted by a cohort only through its project's materials) with the fixture's existing learners, and moves two existing tests instead of twenty.

### RESOLVED: should Teacher Actions get project scoping?
**Context**: Teacher Actions applies no project scoping, so any project admin or researcher (the users the report server admits besides site admins, `ReportServerWeb.Auth`) can read any teacher's log events on any activity with it. It was noticed while tracing this story's code and is outside a cohort-filter fix.
**Options considered**:
- A) File a follow-up story to scope Teacher Actions like the other reports, and leave it out here.
- B) Fold it into this story.
- C) Leave it, as intended behavior for teacher-level log data.

**Decision**: C (Doug). The lack of scoping is intended: the report server filters out student data, and Teacher Actions reads only teacher log events.

## Self-Review

Roles: Senior Engineer, QA Engineer, Security Engineer, Performance Engineer, Education Researcher. Each finding below was checked against the code and fixture before it was written, and fixed in place.

### QA Engineer

#### RESOLVED: the "cohort of another project" learner test could not fail
R7 had a learner-level test that cohort 2 does not admit 803. Cohort 2 has no teacher items, so its teacher side drops every learner and the test would pass with the activity side deleted. R7 now uses cohort 5 for the learner-level negative (its teacher 36 reaches class 604, whose learners are on 801, which is neither an item of cohort 5 nor a material of project 904), and keeps cohort 2 for the predicate-level and option tests, where no teacher side applies.

#### RESOLVED: R5 had no test, and needs none
Every learner path groups or selects `DISTINCT`, so a fan-out would not show in them. The predicate as specified is a WHERE condition over uncorrelated subqueries, which cannot add rows, so R5 now says it holds by construction. R7's predicate test still selects without `DISTINCT`, which keeps it honest if the predicate is ever rewritten as a join.

### Security Engineer

#### RESOLVED: "a cohort filter can never widen what the caller sees" is not true of Teacher Actions
Teacher Actions applies no project scoping, so the wider activity side adds activities to its log query with no scoping beneath to bound them. R6 now limits the claim to the reports that have project scoping and points at Out of Scope, which records why Teacher Actions has none.

### Performance Engineer

#### RESOLVED: the predicate's per-row cost was not addressed
REPORT-195 measured a per-row correlated subquery in Student Metadata at 246 s against a 300 s timeout. An `OR` of two `EXISTS` is evaluated per row too. Technical Notes now say why it should be cheap (indexed lookups on rows the teacher side has already narrowed) and that stage 4 measures it.

#### RESOLVED: the predicate's shape was chosen without measuring it
Stage 4's benchmark (Technical Notes, Cost) showed the correlated `EXISTS` form 7 times slower than `IN ... OR IN ...` on a cohort four times production's largest. Technical Notes now specify the `IN` form.

### Self-review round 1

#### QA Engineer

##### RESOLVED: R7 claimed an option test proves cohort 2 is excluded
The option tests run as a project admin of 900, so cohort 2 (project 901) is out by scoping whatever the rule says. R7 now pins cohort 2's exclusion on the unscoped predicate test, and adds the cohort 3 and 802 option cases, the only ones that fail when a cascade ignores the selection (checked by mutation; see implementation.md).

##### RESOLVED: R7 claimed an Athena assertion the test does not make
R7 said the Athena learner fetch is checked for the site admin; the test checks it for the project admin and the researcher only. R7 now says so.

##### RESOLVED: nothing could catch a rule that ignores `item_type` or `material_type`
Every non-activity row in the fixture had an id far from the activity ids, so dropping either type check left every DB test green. R7 adds two decoy rows of other types that collide with 802 and 803.

### Self-review round 2

#### Spec Editor

##### RESOLVED: the Project Owner Overview promised class-filter parity, which R7 contradicts
For a site admin, `class: [601, 602]` gives learners 901 to 904 while `cohort: [6]` gives 901, 903 and 904: 902's activity 802 is in no project, and R7 requires it to stay out (run on the fixture). The sentence now says what the fix adds rather than claiming parity.

##### RESOLVED: Technical Notes said no test covers the cohort/assignment cascades' SQL
The "narrowing one dimension by another generates legal SQL" test runs all 90 pairs, both cascades included, as implementation.md says; what no test does is assert their results. Reworded.

#### Test Writer

##### RESOLVED: R7 listed a two-cohort predicate case that cannot fail
Cohorts 1 and 6 each admit exactly 801 and 803, so `activities([1, 6])` passes with a rule that reads only the first or only the last selected cohort (run: only the SQL snapshot fails), and a WHERE predicate cannot repeat a row, so selecting without `DISTINCT` pins nothing either. The test is dropped and R7 lists the cases that remain; R5 stays met by construction.

#### Operator

##### RESOLVED: "Stored results" said every earlier run must be re-run
Portal runs are computed on every read (`ReportController.portal_download/4`, the run page, the `PORTAL_DUPLICATE_UNNECESSARY` error), so only Athena runs keep stale rows. Technical Notes now say so.

##### RESOLVED: Teacher Actions' earlier runs could hold more, not fewer, events
On today's code `cohort: [6]` gives Teacher Actions only `log.username IN ('131@...')` (run on the fixture): an empty activity list drops the activity clause. Such runs held the cohort's teachers' events on every activity, and the fix narrows them. Technical Notes and the release notes now say so.


### Self-review round 3

#### Operator

##### RESOLVED: "Stored results" left out the exports of an existing Athena run
`EndpointSet.fetch_learners` reads a run's learners from its stored filter on every request, so an old cohort-filtered run's bulk, attachments and CLUE exports pick up the fix at once and disagree with its stored CSV until it is duplicated. Technical Notes and the release note now say so.

##### RESOLVED: the Teacher Actions note tied the old widening to materials-only projects and promised the fix ends it
The empty activity list comes from a selection whose teachers offered none of the cohorts' admitted activities: cohort 6 shows it on today's code although project 900 holds 801 as an item of cohort 1, and with the fix built, `cohort: [5]` still gives only the `log.username` clause (run on the fixture). Technical Notes and the release note now state the condition and the remaining case.
