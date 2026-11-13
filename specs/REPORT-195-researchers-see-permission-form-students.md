# Project researchers see only their project's permission-form students

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-195

**Status**: **Closed**

## Overview

The report server let an external project researcher see every student in their project's cohort classes, and kept letting them in after their researcher access expired. This story makes it follow the portal's rules: a researcher sees a student only when the student holds a permission form from that project, as the portal's learner policy does (or, when the project has no permission forms at all, every student its cohort classes reach, as the portal's Research Classes view shows them), and a researcher row whose expiration date has passed grants nothing. A researcher also sees only their own projects' forms in a student's permission-form names.

Project admins with no researcher role see exactly what they saw before. A user who administers one project and researches another also gets the second project's consented students. In their admin projects' classes they keep everything an admin sees; on students reached only through the researcher project they get the researcher's hidden names, narrowed form names, and a student-only CLUE export unless that project has no permission forms. Teacher-level reports, which carry no student rows, are unchanged.

## Requirements

- **R1. Expired researcher rows grant nothing.** A researcher row in `admin_project_users` counts only when `is_researcher = 1 AND (expiration_date IS NULL OR expiration_date > CURDATE())`, in both the `is_project_researcher` role flag (`@role_flags`) and the researcher project lookup. This matches rigse's `expiration_date > Date.today`: a row expiring today is already expired. Admin rows have no expiry, as on the portal.
- **R2. One lookup, two lists.** The allowed-projects lookup returns, for a user with a project role, the project ids they administer and the project ids they research (live rows only, per R1), read in one query whatever the stored flags say about which role they hold. A project the user both administers and researches is in the admin list only. A site admin is still `:all`, whatever project rows they also hold, so "holds a researcher project" means the lookup's researcher list is not empty, which a site admin's never is. A user with no project role flag, or whose rows are all expired or absent, is `:none`; a failed portal query is still `{:error, _}`.
- **R3. Project-level consumers see the union.** Every consumer that scopes something other than students (cohort, school, teacher and assignment scopes in `DimensionScope`, the Teacher Status and Resource Metrics reports, and the package catalog's project check) scopes by the union of the two lists, with the existing rule. For an admin-only user this is exactly the old list.
- **R4. Learner scoping follows `Report::LearnerPolicy`, except for projects with no forms.** In `LearnerBaseQuery`'s project scoping, a learner is visible when its assignment is in a cohort or the materials of any allowed project (over the union), and its class's teacher is in a cohort of a project that is either in the admin list, or in the researcher list with the learner's student holding a permission form of that same project, or that project having no permission forms. The no-forms exception departs from `Report::LearnerPolicy`: as of 2026-11-13, 100 of the 124 production projects have no forms, 20 of them have live researcher-only users with cohort classes, and the portal's Research Classes view already shows those researchers every student, anonymized. This applies to every report and endpoint built on `LearnerBaseQuery`: Student Answers, Student Actions (with and without metadata), Student Assignment Usage, Student Metadata, Student ID Mapping, the bulk export and attachment endpoint set, the CLUE export's learner rows and a class's recent logs.
- **R5. Student and form options and label resolution follow the same rule.** In `DimensionScope`, the `student` and `permission_form` scopes admit an entity through a researcher-only project only through a student R4 would let that researcher see, and for `permission_form` only that project's own forms. The `class` scope keeps its cohort rule over the union, so a class with no consented students is offered, its reports and recent logs come back empty, and the recent-logs class gate answers it with an empty list rather than 403. A researcher is neither offered nor able to name a student the report would leave out.
- **R6. Teacher-level reports are unchanged in rule.** Teacher Status, Resource Metrics Summary and Resource Metrics Details keep their cohort and assignment scoping over the union. Their student counts are aggregates and are not narrowed by permission forms.
- **R7. README.** `server/README.md` says which students each kind of user sees, including the per-class rule for callers holding a researcher project and the teacher-level reports' unnarrowed counts.
- **R8. Tests** against the portal fixture (`:portal_db`), each able to fail when the rule it names is removed: researcher, admin, mixed-role, two-project researcher, site admin with a researcher row, expiry boundaries, option scopes, form names (including a kept form that is not first, the empty case and mismatched list lengths), the named-form filter, the CLUE link guard (with the admin-class test read from the portal), the CLUE export owners, and per-class names across every output.
- **R9. Release notes.** The PR body states the behavior changes in a form the 1.13.1 release notes (REPORT-206) can take verbatim, and tells the reviewer why the story's "student, class, and any dimension that reaches students" was narrowed to `student` and `permission_form`. *(Not yet done: the PR is not open.)*
- **R10. A researcher sees only their projects' form names.** For a caller with a researcher project, the Student Metadata `permission_forms` column and the Athena `permission_forms` list (Student Answers, Student Actions with Metadata, Student Assignment Usage) list only forms whose project is one of the caller's projects. Student Metadata keeps the portal's stored text and order; the Athena list keeps the names `LearnerData` builds by id. A user with both roles sees the full column on a learner of an admin-project class. Site admins and admin-only callers are unchanged.
- **R11. A researcher's CLUE export holds class and group documents only where they see every student.** For a caller with a researcher project, `/clue/documents`, `/clue/history` and `/clue/content` keep the class owner and group owners only for classes whose every student they may see: classes reached through one of their admin projects or through a researcher project with no permission forms; every other class contributes its student owners only. A group or class document can hold the work of students without consent, which the export cannot tell apart.
- **R12. Names follow the portal's per-class rule.** A caller allowed names who also holds a researcher project sees a learner's name and username only when the learner's class teacher is in a cohort of one of their admin projects, as rigse's `User#has_full_access_to_student_data?` / `is_project_admin_for_clazz?` decide. Every other row carries the values `hide_names: true` produces, in Student Metadata, the Athena learner upload, the student filter options and their search, and the stored student labels.
- **R13. Staging check.** After the deploy to staging: a researcher-only account on a project with permission forms sees only that project's permission-form students in a Student Answers run and in the student filter options, and one on a project with no forms sees every student of its cohort classes there, with names hidden; an expired researcher account gets no project data; a project admin's results are unchanged. The results go in the PR. *(Not yet done: needs the staging deploy.)*
- **R14. A named permission form follows the same rule.** For a caller with a researcher project, a `permission_form` filter value matches a learner or a student only when the form's project is one of the caller's projects, or the class is reached through one of their admin projects: the learner's class in the learner query, the class through which an option reaches the student in the option cascades, and any of the student's classes for the student dimension itself. Another project's form id then tells a researcher nothing about which of their consented students hold it. The filter itself refuses no value it accepted before; label resolution (`ReportFilter.get_filter_values/2`) answers `:out_of_scope` for another project's form, under R5.
- **R15. A researcher's CLUE work links point only at work they may see.** The `clue_link_to_work` post-processing step writes a link for a researcher-project owner only when the row's `documentUid` is the learner's own user or the class is one whose every student the owner may see (reached through one of their admin projects or a researcher project with no permission forms). Owners who are site admins or hold admin projects only are unchanged; any other owner, including one with no live project, gets no links, so the step fails closed. Logged `parameters` are left as recorded.

## Technical Notes

- **Stored role flags and the live lookup.** Role flags are stored at login; `get_allowed_project_ids` uses them only to decide whether to query and reads the rows fresh. So the expiry check takes effect on the next request in the project query and at the next login in the flags.
- **Timezones.** `CURDATE()` is the MySQL session's date, rigse compares with Ruby's `Date.today`; both run in UTC.
- **Fan-out.** The consent condition is an `EXISTS` correlated on the row's own cohort join, so it adds no rows and leaves `LearnerBaseQuery.group_by/0` correct.
- **Empty lists.** Either list can be empty while the other is not; an empty list's branch is left out of the SQL rather than rendered as `IN ()`.
- **Package catalog.** The project-maintainer rule runs over the union: a user who administers A and researches B can now administer B's packages, and an expired researcher can no longer administer their project's packages.
- **Form names.** The portal stores a learner's forms as parallel comma lists `permission_forms` and `permission_forms_id` on `report_learners` (rigse `Report::Learner#update_permission_forms`). The narrowed column keeps the stored name at each position whose id is a visible form, via `JSON_TABLE` (MySQL 8.0.42 on production), and yields NULL when the two lists differ in length.
- **Admin-class check.** Every per-row "class reached through an admin project" check in a `LearnerBaseQuery` query reads one derived table of the admin projects' classes, `LEFT JOIN`ed on `rl.class_id`. On production, Student Metadata for a user who administers one project and researches another (9,927 learners) took 246 s with a correlated check per column, 134 s with the join, and 125 s with no per-row checks at all.
- **Collations.** The per-class student label's `CASE` mixes a `users` column (that table's collation) with `CAST(u.id AS CHAR)` (the connection's), so the whole `CASE` is cast to one collation; otherwise `LIKE` and the option cursor's comparison fail on a server whose default collation differs from the connection's, as CI's MySQL 8 default does.
- **Dashboard tokens.** `DashboardTokenController` takes role flags from rigse's signed claims, which already apply expiry.

## Out of Scope

- The portal's site-wide `manager` and `researcher` roles, which the report server does not recognize.
- Narrowing teacher-level reports' student counts by permission forms (R6).
- Re-checking stored role flags on every request. An expired researcher can stay authenticated (an API token may never expire); they get no project data from the next request, but their stored results stay downloadable.
- Athena-side data not reached through `LearnerBaseQuery`.
- Re-scoping stored results. Athena runs and post-processing jobs that finished before the deploy keep the students and form names they were built with; portal reports re-query on every download and follow the new rule at once. An export cursor in progress at the deploy, or at a researcher's expiry, finishes under its first page's scope.
- The run page's row count (scoped by the viewer) and rows (scoped by the run's owner).
- Teacher Actions, School Metrics and Summary Metrics by Subject Area, which apply no project scoping.
- Returning researchers the group documents whose members all consented, which needs group membership from the CLUE function (a follow-up).
- Filtering permission-form names for callers with no researcher role.
- Any change to rigse.

## Not Yet Implemented

- The PR body carrying the release-note paragraph and the reviewer note (R9): written when the PR is opened.
- The staging check (R13): runs after the deploy to staging, with the results added to the PR.

## Decisions

### Must the form belong to the same project as the cohort?
**Context**: `Report::LearnerPolicy` checks the cohort project and the form project against the researcher's list independently; the story says "that same project".
**Options considered**:
- A) Same project.
- B) The portal's independent check.

**Decision**: A. The story states it, it is the stricter reading for IRB consent, and the two differ only for a researcher on two projects.

---

### What does a researcher see on a project with no permission forms?
**Context**: `Report::LearnerPolicy` requires a form of the project, so a researcher on a project with none sees no students. As of 2026-11-13, 100 of the 124 production projects have no forms, and 20 of them have live researcher-only users with cohort classes, while the portal's Research Classes view shows those researchers every student, anonymized.
**Options considered**:
- A) The strict rule everywhere: no forms, no students.
- B) A project with no `portal_permission_forms` rows admits every student its cohort classes reach; a project with any form keeps the strict rule.

**Decision**: B. Names stay hidden and form names stay narrowed, as for any researcher project. The test is whether the project has any form row, archived ones included, so it changes with the portal's own data: deleting a project's last form (which also deletes every student's signature of it) widens its researchers to every cohort student, and adding its first form narrows them to none until students sign. That is accepted: after a deletion the strict rule would show those researchers nobody, and Research Classes already shows them everyone. Since such a class has no student outside the researcher's view, its CLUE class and group documents and its classmates' work links are theirs too (R11, R15); names still follow the admin-class rule.

---

### Which list governs the assignment restriction?
**Context**: A learner's assignment must be in a cohort or the materials of an allowed project.
**Options considered**:
- A) Independent, over the union.
- B) Paired per project with the teacher's cohort project.

**Decision**: A. It leaves an admin-only user's results unchanged; pairing would be a new restriction nobody asked for.

---

### How do class and permission-form options treat a researcher-only project?
**Context**: The story names student, class and "any dimension that reaches students".
**Options considered**:
- A) Narrow `class` and `permission_form` through visible students.
- B) Narrow `student` and `permission_form`; `class` keeps its cohort scope.
- C) Narrow class options only, and resolve a named class by cohort.

**Decision**: B (Doug). Consent gates a researcher's students, not the cohort classes their project reaches, so a class with no consented students is empty, not refused, and the recent-logs class gate stays an empty list rather than 403.

---

### Is a user with no live rows `:none` or an empty pair of lists?
**Options considered**:
- A) `:none`.
- B) A distinct empty shape.

**Decision**: A. No caller treated `[]` differently from `:none`; one spelling removes a branch at every site.

---

### Filter the permission-form names column for researchers?
**Context**: Student Metadata and the Athena list showed every project's form names. Production had 84 students holding forms from two or more projects, one pair of them projects whose names identify an ethnic group.
**Options considered**:
- A) Out of scope, with a follow-up.
- B) Filter for callers with a researcher project.
- C) Filter for admins too.

**Decision**: B (R10). A researcher's access rests on one project's consent; a project admin's does not, and the portal shows admins the full list.

---

### What does a researcher's CLUE export hold?
**Context**: The export added a class owner per class and a group owner per group of the run's offerings, whoever the members were.
**Options considered**:
- A) Out of scope.
- B) Student owners only, outside admin-project classes.
- C) Keep a group only when every member is visible (needs CLUE function changes).

**Decision**: B (R11, Doug). The only package that reads the export uses user-owned documents only; C is the follow-up.

---

### How are names shown to a user holding both roles?
**Context**: `HideNames.allowed?/1` decided per user from the project-admin flag, so the split lookup would have named that user's researcher-project students. Production had 10 such users who are not site admins.
**Options considered**:
- A) Leave it.
- B) Hide names for any caller with a researcher project.
- C) Per class, as the portal does.

**Decision**: C (R12, Doug). It matches the portal; B would take names away on their own admin projects.

---

### Per caller or per class for every consent-bound output?
**Options considered**:
- A) Form names and CLUE owners per caller.
- B) Per class for all, with the name rule's admin-class check.
- C) Per class for form names only.

**Decision**: B (Doug). Admin access governs the classes it reaches, as on the portal, and consent governs the rest.

---

### Stored Athena results built before the release
**Decision**: Accepted as they are (Doug), named in Out of Scope and the release notes, which advise re-running them.

---

### A named permission form revealed which consented students hold another project's form
**Context**: Filtering by a foreign form id matched learners and students whose rows no longer named that form.
**Options considered**:
- A) Apply the per-class rule where rows are produced, in the learner query and every option cascade.
- B) Refuse out-of-scope ids wherever a filter is accepted (an API contract change).
- C) Accept it, with a follow-up.

**Decision**: A (R14, Doug). It closes every path, stored runs included, with no contract change.

---

### CLUE log rows pointing at classmates' documents
**Context**: CLUE logs a viewed document's `documentUid`, so `clue_link_to_work` built `researcher=true` links into other students' work.
**Options considered**:
- A) Out of scope.
- B) Link only the learner's own document or an admin-project class's; leave `parameters` as logged.
- C) B, and strip other users' uids and titles from `parameters`.

**Decision**: B (R15, Doug).

---

### What does the link guard do for an owner with no live project access?
**Context**: An external review found the first guard let every link through for `:none`, the value an expired researcher's lookup returns, and such a researcher can still start a job on a stored run.
**Options considered**:
- A) Fail closed: only site admins and admin-only owners link freely, a researcher owner gets the per-row check, anything else gets no links.
- B) Refuse to start any job for `:none`.
- C) Both.

**Decision**: A (Doug). The check sits where the link is written whatever started the job, and B would block every post-processing step on stored runs the spec keeps readable.

---

### One expression for the student label
**Context**: The option list, its search and the stored labels each built the student label separately, so a hidden name could have stayed searchable.
**Options considered**:
- A) One public `ReportFilter.student_label_expr/2` used by all three.
- B) Share only a `CASE` wrapper.
- C) Copy the `CASE` into both modules with a test.

**Decision**: A (Doug). Display and search cannot disagree; the option text gains the stored label's `TRIM`.

---

### Site admins who also hold a researcher row
**Context**: The lookup returns `:all` for a site admin before reading project rows, but some prose said "any caller holding a researcher role". Four of the 14 production users holding both roles are site admins.
**Decision**: Define "holds a researcher project" once (the lookup's researcher list is not empty, which a site admin's never is), use it everywhere, and pin it with a fixture site admin who has a researcher row.

---

### Keep the name `get_allowed_project_ids`?
**Decision**: Yes. The name is also the stub contract and the `:allowed_project_ids_source` config key; renaming changes no behavior.

---

### Split the lookup's shape change from the learner rule?
**Decision**: Yes. The shape change is mostly mechanical test churn and reviews best alone; the intermediate state never deploys.

---

### A NULL `is_admin` dropped a live researcher project
**Decision**: The project-roles query reads `MAX(COALESCE(apu.is_admin, 0) = 1)`, since rigse's column is nullable.

---

### Where the CLUE export reads the admin-class test
**Decision**: From the `in_admin_class` column `LearnerData` already selects, so the export needs no portal query of its own and fails closed when the column is missing.

---

### Pre-hiding names on the Athena path
**Decision**: Done in `LearnerData.fetch/3`'s row mapping, with the same uppercase SHA-1 digest the MySQL and Presto paths produce, only when `hide_names` is off (so nothing is hashed twice), and leaving a NULL username nil.

---

### Admin-only callers' SQL
**Decision**: An admin-only struct renders the bare `IN`, so an admin-only caller's learner and option SQL is byte-identical to the previous behavior, pinned by the golden option SQL test.

---

### Correlated admin-class checks doubled a large Student Metadata run
**Context**: A production check found a mixed-role run took 246 s against a 300 s timeout: the check ran once per row in three columns. Uncorrelated `IN` subqueries were no faster (256 s).
**Decision**: `LearnerBaseQuery` joins a derived table of the admin projects' classes once and the checks read it (134 s, identical output). Queries not built on `LearnerBaseQuery` keep the correlated form.

---

### Which class the named-form exception checks in option cascades
**Context**: A PR review found that, for a student in both an admin-project class and a researcher-only class, class options narrowed by a foreign form offered the researcher-only class, because the exception checked any of the student's classes; the report for that class and form was then empty.
**Decision**: Each cascade checks the class it matched the student through (`psc.clazz_id`), as the learner query checks the row's class; the student dimension keeps any of the student's classes, as its labels do. A fixture student enrolled in both kinds of class pins it.

---

### The report form's cached project grants
**Context**: The report form looked the caller's projects up once when it mounted, so a researcher whose row expired while the form was open kept their option lists until a reload.
**Decision**: The form looks the projects up on each option query, so expiry takes effect at once there as it does for runs.

---

### `get_permission_form_map` arity
**Decision**: It stays `/2` and carries each form's project; the row mapping does the filtering. The spec was corrected to match.
