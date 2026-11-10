# Project researchers see only their project's permission-form students

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-195
**Repo**: https://github.com/concord-consortium/report-service
**Implementation Spec**: [implementation.md](implementation.md)
**Status**: **In Development**

## Overview

The report server lets an external project researcher see every student in their project's cohort classes, and keeps letting them in after their researcher access expires. This story makes it follow the portal's rule: a researcher sees a student only when the student holds a permission form from that project, and a researcher row whose expiration date has passed grants nothing. A researcher also sees only their own projects' forms in a student's permission-form names.

## Project Owner Overview

Projects whose IRB requires student permission (or an opt-out) cannot let an external researcher run their own reports today, because the report server shows them every student in the project's classes, consented or not. An internal project admin has to run the report and strip out the students the researcher may not see. Separately, a researcher whose access the portal has expired can still log in to the report server and pull that project's data.

After this story, a researcher's student-level reports, exports and filter choices include only students who hold one of that project's permission forms, the permission-form names shown for those students list only that project's forms, and expired researcher access stops working on the report server just as it already does on the portal. Project admins with no researcher role see exactly what they see today. A user who administers one project and researches another also gets the second project's consented students, and in their admin projects' classes keeps everything an admin sees today; on students reached only through the researcher project they get the researcher's hidden names, narrowed form names and student-only CLUE export. Teacher-level reports, which carry no student rows, are unchanged.

## Background

The Jira story carries the problem statement, the code references and the decided rule; this spec does not restate them. In short: `PortalDbs.get_allowed_project_ids` (`server/lib/report_server/portal_dbs.ex`) returns one project list whose kind depends on which role flag the stored user has, and every scoping site treats that list as "cohort classes of these projects". The portal's `Report::LearnerPolicy` (rigse `rails/app/policies/report/learner_policy.rb`) instead ORs two rules: a project admin sees learners in their projects' cohort classes, and a project researcher sees learners in their projects' cohort classes who also hold a permission form of one of those projects. rigse's `User#_project_user_researchers` drops a researcher row once `expiration_date` is not after today.

Reading the code against the story turned up three more facts that shape the requirements:

- **The lookup ignores a second role.** `get_allowed_project_ids` is a `cond` that returns the admin list as soon as the stored user has `portal_is_project_admin`, so a user who administers project A and researches project B gets only A today. The split lookup fixes that as a side effect: B's students become visible, under the researcher rule.
- **The lookup has more consumers than the reports.** Besides `LearnerBaseQuery` (every student-level report, the bulk export / attachment endpoint set, the CLUE export and a class's recent logs, all of which fetch learners through it), it feeds `DimensionScope` (filter options in the report form and the `filter-options` API, and label resolution in `ReportFilter.get_filter_values/2`, which is also the recent-logs class gate), the Teacher Status and Resource Metrics reports, and the package catalog's "administers a project package" check (`Packages.administers?/3`). Only the paths that yield students or their forms take the new rule; the others use the union of both lists.
- **Role flags are stored at login but the lookup is read live.** `Accounts` stores the three `@role_flags` on the report-server user when they log in (and `RecentLogs.Access` and the package catalog refresh them per request for portal access tokens). `get_allowed_project_ids` uses the stored flags only to decide whether to query `admin_project_users`, then reads the rows fresh. So the expiry check in the project query takes effect on the next request, while the one in `@role_flags` takes effect at the next login, when an expired-only researcher's `can_access_reports?` (`report_server_web/auth.ex`) becomes false.

Verified on a scratch copy of `test/support/portal_fixture.sql` in the docker MySQL (2026-11-10): the learner predicate in R4 gives project 900's admin learners 901, 903 and 904 and its researcher only 901 (the one student, 71, with project 900's form 11); a student holding only project 901's form stays out of a 900 researcher's results; and the R1 expiry predicate grants a row expiring tomorrow or with no date, and refuses one that expired yesterday or expires today. The R5 scopes, run the same way as `DimensionScope`'s option queries, give project 900's admin students 71 to 74 and forms 11, 12 and 13 (today's answer), and its researcher student 71 and form 11.

## Requirements

- **R1. Expired researcher rows grant nothing.** A researcher row in `admin_project_users` counts only when `is_researcher = 1 AND (expiration_date IS NULL OR expiration_date > CURDATE())`, in both the `is_project_researcher` role flag (`@role_flags`) and the researcher project lookup. This matches rigse's `expiration_date > Date.today`: a row expiring today is already expired. Admin rows have no expiry, as on the portal.
- **R2. One lookup, two lists.** The allowed-projects lookup returns, for a user with a project role, the project ids they administer and the project ids they research (live rows only, per R1), read in one query whatever the stored flags say about which role they hold. A project the user both administers and researches is in the admin list only, since the admin rule is the weaker one. A site admin is still `:all`, whatever project rows they also hold, so throughout this spec "holds a researcher project" means the lookup's researcher list is not empty, which a site admin's never is; a user with no project role flag, or whose rows are all expired or absent, is `:none`; a failed portal query is still `{:error, _}`, and every caller keeps its current handling of it.
- **R3. Project-level consumers see the union.** Every consumer that scopes something other than students (cohort, school, teacher and assignment scopes in `DimensionScope`, the Teacher Status and Resource Metrics reports, and the package catalog's project check) scopes by the union of the two lists, with today's rule. For an admin-only user this is exactly today's list.
- **R4. Learner scoping follows `Report::LearnerPolicy`.** In `LearnerBaseQuery`'s project scoping, a learner is visible when its assignment is in a cohort or the materials of any allowed project (today's assignment rule, over the union), and its class's teacher is in a cohort of a project that is either in the admin list, or in the researcher list with the learner's student holding a `portal_student_permission_forms` row whose `portal_permission_forms.project_id` is that same project. This applies to every report and endpoint built on `LearnerBaseQuery`: Student Answers, Student Actions (with and without metadata), Student Assignment Usage, Student Metadata, Student ID Mapping, the bulk export and attachment endpoint set, the CLUE export's learner rows and a class's recent logs.
- **R5. Student and form options and label resolution follow the same rule.** In `DimensionScope`, the `student` and `permission_form` scopes admit an entity through a researcher-only project only through a student R4 would let that researcher see: a student who holds that project's form, and, for `permission_form`, only that project's own forms signed by such a student (another project's form, even one a visible student also signed, is not offered). Through an admin project they admit what they admit today. The `class` scope keeps its cohort rule over the union: a researcher has access to their project's cohort classes, only not to the unconsented students in them, so a class with no consented students is offered and nameable, its reports and its recent logs come back empty, and the recent-logs class gate answers it with an empty list rather than 403. Because the filter options, the `filter-options` API and `ReportFilter.get_filter_values/2` all read `DimensionScope`, a researcher is neither offered nor able to name a student the report would leave out, and naming one gets the existing `:out_of_scope` answer.
- **R6. Teacher-level reports are unchanged in rule.** Teacher Status, Resource Metrics Summary and Resource Metrics Details keep their cohort and assignment scoping, over the union (R3). Their student counts are aggregates and are not narrowed by permission forms.
- **R7. README.** `server/README.md` says which students each kind of user sees: a site admin sees all, a project admin sees students in their projects' cohort classes, a project researcher sees only those of them who hold one of that project's permission forms, and expired researcher access grants nothing; teacher-level reports count students without that narrowing; for any caller other than a site admin who holds a researcher project, full permission-form names, CLUE group and class documents, and names show only in classes reached through one of their admin projects, and elsewhere the form names are narrowed to their projects' forms and the CLUE export holds student documents only (R10 to R12).
- **R8. Tests**, against the portal fixture (`:portal_db`), each able to fail when the rule it names is removed:
  - a researcher-only user's learners exclude a cohort-class student without the project's form and include one with it;
  - a student whose only form belongs to another project is excluded, including for a researcher on two projects when the form's project is the other one of theirs (the same-project rule of the first judgment call below, which the portal's independent check would admit);
  - a project admin of the same project still sees both students;
  - a user who administers project A and researches project B sees A's students without forms and B's only with B's forms;
  - a site admin who also holds a live researcher row gets `:all` from the lookup and every learner, unnarrowed;
  - the lookup returns no researcher project for a row that expired yesterday or expires today, and returns one for a row expiring tomorrow and for a null expiration; the `is_project_researcher` role flag agrees;
  - the `student` and `permission_form` scopes admit and exclude the same students for a researcher, and the `class` scope and the other scoped dimensions give a researcher what they give an admin of the same project;
  - a researcher's Student Metadata `permission_forms` value and Athena `permission_forms` list keep only their projects' forms, including a kept form that is not first in the stored list, and are NULL or empty when none is kept; a project admin's and a site admin's are unchanged; a user with both roles gets the full value on a learner of an admin-project class and the filtered value on a learner reached only through the researcher project; stored name and id lists of different lengths give NULL to a researcher;
  - a researcher filtering by another project's form id gets no learners and no student or class options outside their admin-project classes, and by their own project's form gets the students holding it; a user with both roles filtering by a foreign form still gets the matching learners, students and classes of their admin-project classes;
  - for a run owned by a researcher, the link-to-work step leaves the cell empty on a row whose `documentUid` is another user's in a class not reached through an admin project, and writes it on the learner's own document; for a run owned by a user with both roles, the admin-class test is read from the portal, not supplied by the test; an admin-owned run's links are unchanged; a run whose owner has no live project gets no link on another user's document;
  - a researcher-only caller's CLUE export owners are student owners only, with no `owners` call to the CLUE function; a project admin's include every class and group owner; a user with both roles gets class and group owners for an admin-project class and none for a class reached only through the researcher project;
  - for a user who administers one project and researches another, with `hide_names` off: Student Metadata, the Athena learner upload, the student filter options, the option search and the resolved student labels name a student of the admin project's classes and give the hidden form (student id, hashed username, user-id label) for a student reached only through the researcher project; that hidden form equals the `hide_names: true` output byte for byte in the CSV downloads (the run page's JSON download carries the rule-hidden `student_name` as the string `"76"` where `hide_names: true` gives the number `76`), the Athena pre-hidden username equals the MySQL hash, and nothing is hashed twice when `hide_names` is on; an admin-only caller's SQL is unchanged.
- **R9. Release notes.** The PR body states the behavior changes in a form the 1.13.1 release notes (REPORT-206) can take verbatim: researchers' reports, exports and filter options now include only students with their project's permission forms; for any caller other than a site admin who holds a researcher project, outside the classes their admin projects reach, permission-form names list only their projects' forms and CLUE exports no longer include group or class documents; a researcher's permission-form filter matches only their projects' forms outside their admin-project classes; a researcher's CLUE link-to-work column links only to work they may see; expired researcher access no longer grants new report-server data or package administration (results already stored stay downloadable to their owner, per Out of Scope); Athena results created before the release keep their original students and should be re-run; and a user who administers one project and researches another now gets the second project's students and packages under the researcher rule, with names only in their admin projects' classes. It also tells the reviewer that the story's "student, class, and any dimension that reaches students" was narrowed to `student` and `permission_form` on purpose, and why (R5).
- **R10. A researcher sees only their projects' form names.** For a caller whose allowed projects include a researcher project, the Student Metadata report's `permission_forms` column and the `permission_forms` list `Athena.LearnerData` uploads for the Athena reports that output it (Student Answers, Student Actions with Metadata and Student Assignment Usage) list only forms whose project is one of the caller's allowed projects (admin or researcher). In Student Metadata the kept names are the portal's own stored text in the portal's stored order; the Athena list keeps the names `LearnerData` already builds by form id. Either way a kept value is a subset of what a project admin sees. A site admin and a user with only admin projects see the column unchanged, as on the portal, whose project-admin access does not rest on consent. A user with both roles sees the full column on a learner whose class teacher is in a cohort of one of their admin projects (the per-class test of R12) and the filtered column on every other learner.
- **R11. A researcher's CLUE export holds only student documents.** For a caller with a researcher project, `/clue/documents`, `/clue/history` and `/clue/content` keep the class owner and the group owners only for classes whose teacher is in a cohort of one of the caller's admin projects (the per-class test of R12); every other class contributes its student owners only. A group owner is added for every group of the run's offerings whatever its members, and a group or class document can hold work and `/clue/history` `entry_uid`s of students without consent, which the export cannot tell apart. Project admins with no researcher role and site admins keep every class and group owner, so a researcher-only caller gets student owners only. The one package that reads the export (`clue-dataflow-systematicity` in cc-data-studies) already reads only user-owned documents.
- **R12. Names follow the portal's per-class rule.** A caller who may see names (`HideNames.allowed?/1`: a site admin or a project admin) and who also holds a researcher project sees a learner's name and username only when the learner's class teacher is in a cohort of one of the caller's admin projects, as rigse's `User#has_full_access_to_student_data?` / `is_project_admin_for_clazz?` decide per class. Every other row carries the same hidden values `hide_names: true` produces. This covers every output names reach: the Student Metadata columns, the learner data uploaded for the Athena reports, the student filter options and their search, and the resolved student labels stored on a run. A student label is shown when the student is in any such class. Site admins and admin-only callers are unchanged, `hide_names` stays the caller's choice, and researcher-only callers are still forced to hidden.
- **R13. Staging check.** After the deploy to staging, as the story's Done-when asks: a researcher-only account sees only permission-form students in a Student Answers run and in the student filter options; an expired researcher account gets no project data; a project admin's results are unchanged. The results go in the PR.
- **R14. A named permission form follows the same rule.** For a caller with a researcher project, a `permission_form` filter value matches a learner (in every report and endpoint built on `LearnerBaseQuery`) or a student (wherever filter options narrow by form) only when the form's project is one of the caller's projects, or the learner's class (for options, one of the student's classes) is reached through one of the caller's admin projects (R12's per-class test). Another project's form id then matches nothing a researcher sees only through consent, so filtering by it tells them nothing about which of their students hold it. Callers with no researcher project are unchanged, and no endpoint refuses a value it accepted before.
- **R15. A researcher's CLUE work links point only at work they may see.** The `clue_link_to_work` post-processing step, for a run whose owner holds a researcher project, writes a link only when the row's `documentUid` is the row's own learner's user, or the learner's class is reached through one of the owner's admin projects (R12's per-class test); otherwise it leaves the cell empty. A CLUE log row can name a classmate's document the student viewed, and the link opens it in CLUE's researcher view. The logged `parameters` are left as recorded. Runs whose owner is a site admin or holds admin projects only are unchanged. Any other owner, including one whose lookup gives no live project (an expired researcher), gets no links in that column, so the step fails closed.

## Technical Notes

- **Timezones.** `CURDATE()` is the MySQL session's date; rigse compares with Ruby's `Date.today`, the portal host's date. The fixture MySQL runs in UTC and rigse sets `config.time_zone = 'UTC'`; if the portal RDS or host ran in another zone the two could disagree for part of one day around an expiry. Not worth more than this note.
- **Fan-out.** The learner query already joins every cohort of the teacher (`aci_teacher_a`); R4's permission-form condition is an `EXISTS` subquery correlated on `rl.student_id` and `ac_teacher_a.project_id`, so it adds no rows and leaves `LearnerBaseQuery.group_by/0` correct.
- **Empty lists.** Either list can be empty while the other is not. An `IN ()` is a MySQL syntax error, so an empty list's branch is left out of the SQL, not rendered empty.
- **Package catalog.** `Packages.administers?/3` and the publish/change paths keep their project-maintainer rule over the union. Consequences of R1 and R2 there, both intended: a user who is admin of A and researcher on B can now administer B's packages too, and an expired researcher can no longer administer their project's packages.
- **Form names (R10).** The portal stores a learner's forms as two parallel comma lists on `report_learners` (rigse `Report::Learner#update_permission_forms`): `permission_forms` (each `"<project>: <form>"`, or the bare form name for a form with no project, commas inside a name replaced with spaces) and `permission_forms_id`, in the same order. The Student Metadata filter keeps the name at each position whose id is a visible form; rebuilding the string from the join tables does not reproduce the stored text (order differs, and it picks up join rows the stored string omits; checked on the fixture). If the two lists ever differ in length the filter yields NULL rather than misaligning. `LearnerData` already looks names up by id, so it only adds a project condition to that lookup.
- **Dashboard tokens.** `DashboardTokenController` takes the role flags from rigse's signed claims, which rigse already computes with expiry, so R1 changes nothing there.

## Out of Scope

- The portal's site-wide `manager` and `researcher` roles, which `Report::LearnerPolicy` treats as "see all" and the report server does not recognize. Unchanged.
- Narrowing teacher-level reports' student counts by permission forms (R6).
- Re-checking stored role flags on every request. `Auth.can_access_reports?` reads the flags stored at login, for cookie sessions and API tokens alike, and an API token may never expire, so an expired researcher can stay authenticated; R1's live project query gives them no project data from the next request, but their stored results below stay downloadable.
- Athena-side (log and answer) data that is not reached through `LearnerBaseQuery`. Every student report reaches it through that query's learners.
- Re-scoping stored results. Athena runs and post-processing jobs that finished before the deploy keep the students and form names they were built with, served as stored by the run and job downloads (API and web) and read by new post-processing jobs on those runs; R4 and R10 apply to runs whose query starts after the deploy. Portal reports re-query on every download, so they follow the new rule at once. Likewise an answers, history or CLUE export cursor keeps the endpoint set or owners frozen on its first page, and each page renews its one-hour expiry, so an export in progress at the deploy (or at a researcher's expiry) finishes under the scope it started with.
- The run page's row count is scoped by the viewer and its rows by the run's owner (`report_run_live/show.ex`); unchanged.
- Teacher Actions, School Metrics and Summary Metrics by Subject Area apply no project scoping and carry no student rows; unchanged.
- Returning researchers the group documents whose members all consented. That needs group membership from the CLUE function (collaborative-learning) and is a follow-up.
- Filtering permission-form names for callers with no researcher role. A project admin's access does not depend on consent, and the portal shows them the full list.
- Any change to rigse.

## Open Questions

### RESOLVED: Judgment call: must the form belong to the same project as the cohort?
**Context**: `Report::LearnerPolicy` checks the cohort project and the form project against the researcher's project list independently, so a researcher on both B and C sees a student in a B cohort class who holds only a C form. The story says the form must belong to "that project" / "that same project".
**Options considered**:
- A) Same project: the form's project equals the cohort's project.
- B) Portal's independent check: any of the researcher's projects.

**Decision**: A. The story states it and its tests ("a form from a different project doesn't count"); it is the stricter reading, which is the safe one for IRB consent; and the two differ only for a user researching two projects where a student is in one's cohort and holds only the other's form.

### RESOLVED: Judgment call: which list governs the assignment restriction?
**Context**: Today a learner's assignment must be in a cohort or the materials of an allowed project, checked independently of the teacher's cohort project.
**Options considered**:
- A) Keep it independent, over the union of both lists.
- B) Pair it per project with the teacher's cohort project.

**Decision**: A. It leaves an admin-only user's results byte-for-byte unchanged (the story's "project admin's results are unchanged"), and pairing would be a new restriction nobody asked for.

### RESOLVED: Judgment call: how do class and permission-form options treat a researcher-only project?
**Context**: The story names student and class and "any dimension that reaches students". A class or a form is not student data itself, but offering a class with no visible students leads to an empty report.
**Options considered**:
- A) `class` and `permission_form` reach a researcher-only project only through a visible student.
- B) Narrow `student` and `permission_form`; `class` keeps its cohort scope.
- C) Narrow class options only, and resolve a named class by cohort.

**Decision**: B (Doug, 2026-11-10). Consent gates a researcher's access to students, not to the cohort classes their project already reaches, so a class with no consented students is the researcher's class with no visible students: empty, not refused. A forms option names a consented student's own consent, so it narrows with the students. C would need a second class rule (offered versus allowed) for no gain. The story's wording listed `class`; the PR body says why it is left out (R9).

### RESOLVED: Low confidence: should a user with no live rows be `:none`, or an empty pair of lists?
**Context**: R2 normalizes "no live project rows" to `:none`, which removes today's separate `[]` shape and its handling in `EndpointSet`, `DimensionScope` and `ReportUtils`. That is a shape change every consumer of the lookup sees.
**Options considered**:
- A) `:none`, one spelling for "no project data".
- B) Keep an empty result as a distinct shape.

**Decision**: A. No caller treats `[]` differently from `:none` today: `EndpointSet.fetch_learners/2` answers `{:ok, []}` for both, and `DimensionScope` and `ReportUtils` both render `1 = 0` for both. Two spellings of one state is a second branch at every site; one spelling deletes those branches.

## Self-Review

Roles: Security Engineer, Education Researcher (IRB), QA Engineer, Senior Engineer, Operator.

### Security Engineer

#### RESOLVED: a researcher was offered other projects' permission forms
R5 as first written admitted any form signed by a visible student. Student 71 in the fixture signed forms 11 (project 900), 12 and 13 (project 901), so a 900 researcher would have been offered 901's form names. R5 now admits only the researcher project's own forms.

### Operator

#### RESOLVED: the story's release-notes condition had no requirement
The story's Done-when asks the release notes to call out both changes; this repo keeps no changelog and the notes are written in the release story, so R9 asks the PR body to carry the wording.

### Education Researcher

#### RESOLVED: Student Metadata's `permission_forms` column lists every project's forms
`StudentMetadataReport` selects `rl.permission_forms` verbatim and `LearnerData` maps every form id a learner holds, so a project A researcher saw, for each consented student, the names of other projects' forms. A production check (2026-11-10) found 84 students holding forms from two or more projects, one pair of them projects whose name identifies an ethnic group, so the column can disclose a protected attribute across a consent boundary.
**Options considered**:
- A) Leave it out of scope and propose a follow-up.
- B) Filter it for callers with a researcher project in this story.
- C) Filter it for admins too.

**Decision**: B, as R10. A researcher's access rests on one project's consent, so other projects' consent records are outside it; a project admin's does not, and the portal shows admins the full list, so C would change a policy nobody asked to change.

### Privacy Engineer (route audit)

#### RESOLVED: the CLUE export returned group and class documents to researchers
A route audit found that `clue_export_controller.ex`'s `derive_owners` adds a class owner per class with a visible student and a group owner per group of the run's offerings, whoever its members are (`Clue.Scope.class_owners/1`, `group_owners/2`).
**Options considered**:
- A) Out of scope, with a follow-up.
- B) Student owners only for callers with a researcher project.
- C) Keep a group only when every member is a visible student (needs CLUE function changes).

**Decision**: B, as R11 (Doug, 2026-11-10): nothing that reads the export uses group or class documents. C is the follow-up in Out of Scope.

#### RESOLVED: a user with both roles would see researcher-project students by name
`HideNames.allowed?/1` decides names per user from the project-admin flag. Once the split lookup gives a user who administers A and researches B the consented students of B, that flag would show those students by name, where a researcher-only user and the portal both hide them. Production had 10 such users who are not site admins (2026-11-10).
**Options considered**:
- A) Leave it.
- B) Hide names for any caller with a researcher project.
- C) Per class, as the portal does.

**Decision**: C, as R12 (Doug, 2026-11-10). It matches the portal, and B would take names away from those users on their own admin projects. Built as throwaway code: the full suite stayed green and no existing test changes, because no fixture user holds both roles.

#### RESOLVED: stored Athena results predate the rule
The run and job downloads serve stored files without re-scoping. **Decision**: A (Doug, 2026-11-10): accepted, named in Out of Scope and the release notes (R9).

### Senior Engineer

#### RESOLVED: R5's class rule turned recent logs' "empty, not refused" into a refusal for researchers
`RecentLogs.Access.learners/2` gates a class with `ReportFilter.get_filter_values/2`, which reads the `class` scope, and its tests pin "a class in the researcher's grants with no learners is empty, not refused". With `class` narrowed by consent, that class answered 403 (built and run on 2026-11-10).

**Decision**: B. `class` keeps its cohort scope (R5 and the judgment call above), so the gate and its tests are unchanged.

### Self-review round 1

Roles: Product Manager, Education Researcher (IRB), Security Engineer, Release Manager.

#### RESOLVED: "Project admins see exactly what they see today" was false for mixed-role admins
The overview said project admins were unchanged; a user holding both roles is affected on students reached through the researcher project, so the Project Owner Overview, R7, R9 and Out of Scope now distinguish admins with no researcher role.

#### RESOLVED: R9 omitted two behavior changes the plan's PR body carried
Mixed-role users gaining their researcher project's students (R2) and the package-catalog consequences in Technical Notes are release-note changes; R9 now lists them.

#### RESOLVED: mixed-role callers: per caller or per class?
The form-names filter and the CLUE owner rule were per caller, so a user holding both roles lost the full form list and group and class documents on their own admin projects, which is what the per-class name rule was chosen to avoid.
**Options considered**:
- A) Keep both per caller.
- B) Per class for both, with the name rule's admin-class check.
- C) Per class for the form names only.

**Decision**: B (Doug, 2026-11-10). One rule for all three outputs: admin access governs the classes it reaches, as on the portal, and consent governs the rest.

### Self-review round 2

Roles: Technical Writer (release notes), Data Pipeline Engineer (Athena upload), Integration Engineer (CLUE export).

#### RESOLVED: R9's release note contradicted Out of Scope on expired researchers
R9 said expired access "no longer grants report-server data", while Out of Scope (and `Reports.get_api_report_run/2`, which checks only ownership) keeps an expired researcher's stored results downloadable through a still-valid API token. R9 now says "new" data and names the exception.

### Self-review round 3

Roles: Privacy Reviewer, Operator / On-call, Database Reviewer. Performance, on a synthetic portal with rigse's indexes (200,000 students, 400,000 learners): the consent and admin-class `EXISTS` and the narrowed form names are each an index lookup per row, and a 100,000-student mixed caller's options page takes 1.8 s against 1.1 s today, inside the 5 s budget. No change needed.

#### RESOLVED: R10 named two of the three Athena reports that output `permission_forms`
Student Assignment Usage reads the same uploaded learner file (`SharedQueries` selects `permission_forms` in both its resource and no-resource SQL), and the Athena names are built by id rather than read from the stored text. R10 now names all three and says which names each path keeps.

#### RESOLVED: R8's "byte for byte" did not hold for the JSON download
The rule's `CASE` makes the hidden `student_name` a `varchar` where `hide_names: true` selects the `int` `rl.student_id` (checked with `CREATE TABLE ... AS SELECT`), so `report_run_live/show.ex`'s JSON download differs in type while the CSV bytes match. R8 now scopes the claim to the CSV downloads and states the JSON difference.

#### RESOLVED: no test could tell the same-project rule from the portal's
Every planned researcher holds one researcher project, so a consent check over the whole researcher list passes every R8 case. R8 now asks for a two-project researcher; the plan adds one (fixture user 569, see the learner step).

#### RESOLVED: a named permission form still told a researcher which consented students hold another project's form
R10 hides other projects' form names, but the `permission_form` filter still matches any form id. On the fixture, researcher 563 (on 902) filtering learners by form 12 (project 901) gets learner 905, and the student options narrowed by form 12 give student 76: both say student 76 holds 901's form, which R10 cuts from 76's row. Three paths accept a foreign id: the filter-options API (which by design checks no narrowing value), the report form's `create_run` (which logs `{:error, :out_of_scope, _}` and creates the run anyway, so R5's "naming one gets `:out_of_scope`" holds only for the API), and stored runs. The leak is membership of a form id the report server never names, but form ids are small sequential integers.
**Options considered**:
- A) For a caller with a researcher project, a named form matches a narrowed row (outside their admin-project classes, R12's per-class test) only when the form's project is one of theirs, in `LearnerBaseQuery`'s `permission_form` filter and in every option-cascade join through `pspf`.
- B) Refuse out-of-scope ids wherever a filter is accepted: `create_run` as the API already does, and the filter-options API's narrowing values (a contract change for that endpoint).
- C) Accept it for this story and record a follow-up.

**Decision**: A, as R14 (Doug, 2026-11-10): the same per-class rule as the column, applied where the rows are produced, so every path closes, stored runs included, with no API contract change.

### Self-review round 4

Roles: Adversarial Researcher (every input a researcher controls), Whole-Plan Builder, Spec Clarity Reviewer. Checked on a scratch copy of the fixture with every planned addition.

#### RESOLVED: export cursors issued before the deploy kept the old scope
`BulkExport.freeze/5` stores the answers and history endpoint set and the CLUE owners on the first page, and `Exports.fetch_for_page/4` renews the one-hour expiry on every page, so an export in progress at the deploy or at a researcher's expiry finishes under its first page's scope. Out of Scope now names it beside stored results, under the same decision.

#### RESOLVED: R8 tested R14's option rule on the student dimension only
Without R14's condition, researcher 563 narrowing class options by form 12 gets class 604 and teacher options get teacher 36 (on the fixture), so a condition added to the `student` cascade alone passed every test. R8 now asks for class options too.

#### RESOLVED: a consented student's CLUE log rows pointed at classmates' documents
**Context**: CLUE logs a viewed document's `documentUid`, `documentKey` and `documentTitle` (`VIEW_SHOW_COMPARISON_DOCUMENT`, collaborative-learning `getDocumentIdentityParams`), so a consented student's Student Actions rows carry another student's uid and document title in `parameters`, and the `clue_link_to_work` post-processing step builds a `researcher=true` link with that student as `targetUserId`. Whether CLUE opens it is the portal's and CLUE's decision; the link is the report server's. This is R11's boundary reached through the log stream.
**Options considered**:
- A) Out of Scope: the row is the consented student's own action, and access to the linked document is decided elsewhere.
- B) For a caller with a researcher project, `clue_link_to_work` builds a link only when `documentUid` is the row's own user or the class is reached through an admin project (R12's test); `parameters` stay as logged, named in Out of Scope.
- C) B, and also strip other users' uids and titles from `parameters` for such callers.

**Decision**: B, as R15 (Doug, 2026-11-10): the report server builds no researcher link into unconsented work; logged event data is left as recorded.

#### RESOLVED: process narrative in the self-review preambles
Round 3's preamble here and the four in implementation.md described how the checks were run; each is now one line keeping its conclusion.

### Self-review round 5

Roles: Whole-Plan Builder, Test Writer (mutation). The whole plan was built as throwaway code; the requirements held, and two R8 cases were too narrow to catch a broken mixed-role path.

#### RESOLVED: R8's R14 case checked a mixed caller's learners only
A mixed caller's option path could break (an SQL error, or no admin branch) with every R8 case green. R8 now asks for their students and classes too.

#### RESOLVED: R8's R15 case could pass without the portal's admin-class answer
Every planned link test supplied `in_admin_class` itself. R8 now asks for a mixed-owner case whose admin-class test comes from the portal.

