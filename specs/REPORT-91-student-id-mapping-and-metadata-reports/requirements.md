# Student ID Mapping and Student Metadata Portal Reports

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-91
**Repo**: https://github.com/concord-consortium/report-service
**Implementation Spec**: [implementation.md](implementation.md)
**Status**: **In Development**

> The Jira ticket is the authoritative scope, and it already carries the verified code references
> for the existing surface (`LearnerData`, `ReportQuery`, `tree.ex`, the join-key rationale). This
> spec does not repeat them. What it does carry is the set of findings from the code dive and the
> throwaway SQL probes run while writing it, several of which **contradict the ticket's technical
> framing**. Those are called out as "Correction" in Technical Notes.

## Overview

Add two new reports to the report-server that answer the question "which students did this filter
select, and who are they?" without a researcher having to author or run an Athena query first.
**Student ID Mapping** returns one row per selected learner carrying only identifiers, including the
one string (`run_remote_endpoint`) that joins the Portal side of the world to the Firebase answer
and history records cc-data downloads. **Student Metadata** returns one row per the same learners
carrying the human-readable context (name, username, class, school, teachers, permission forms),
anonymized when hide-names is on. The two join 1:1 on `learner_id`, so a researcher can pull the
mapping, pull the answers cc-data already knows how to fetch, and enrich the result locally.

## Project Owner Overview

Today a researcher who wants a student's answers out of cc-data has to start from an Athena report,
because the Athena student reports are the only thing that emits the identifiers that tie a Portal
student to their stored work. That is a slow, expensive, and indirect path to what is really a
lookup: "give me the roster this filter selects." These two reports make that lookup a first-class
thing. They run live against the Portal database (seconds, not an Athena job), they are reachable
through the `/api/v1` surface that REPORT-88 shipped, and a single Student ID Mapping run doubles as
the handle cc-data uses to fetch those students' answers, history, and attachments.

The split into two reports is deliberate and privacy-driven: the mapping report carries no names at
all, so it can be handled freely, while the metadata report is the one that carries personally
identifying information and honors the existing hide-names control. Researchers who only need to
join data never have to request the report that carries names.

This story is the last report-service item in the Portal-report chain. The cc-data CLI work that
consumes these reports (REPORT-94) and the guidance that documents them (REPORT-95) follow.

## Background

REPORT-88 shipped the Portal half of the `/api/v1` surface: any non-`tbd` report whose module
declares `type: :portal` is automatically listed, shown, and downloadable through the API, with
`execution: "sync"` telling the client to expect a compute-on-request streamed CSV rather than a
presigned URL. It also shipped the `derives_learner_data` capability flag and routed all three bulk
endpoints (`/answers`, `/history`, `POST /attachments`) through `EndpointSet.derive_endpoint_set`,
which derives the learner set from the run's **stored `report_filter`**, not from any Athena result.

The consequence, verified in `endpoint_set.ex`, is that **the "Fetch model (Option A)" the ticket
describes is already shipped**. A `student-id-mapping` Portal run will be accepted by the three bulk
endpoints the moment the report module exists, with no further server work, because
`derives_learner_data` defaults to `true` and the report will carry learner-narrowing
`include_filters`. This story therefore contributes the two report modules and the shared query they
project from; it does not need to touch the API layer at all.

The shared query already exists in substance, and REPORT-105 has since moved it half of the way
here: `Athena.LearnerData.build_query/2` is now public and returns the filtered, user-scoped
`%ReportQuery{}` over the Portal DB's `report_learners` table, while `fetch/3` is that query plus
the Elixir post-processing it always had. Every column both new reports need is in that result
today, including `run_remote_endpoint`, which `LearnerData` constructs and which is already the
shipped join key between the Portal side and the Firebase side (the Athena student-answers report
joins `l.run_remote_endpoint = a.remote_endpoint`).

What does *not* carry over is `LearnerData`'s execution model, and this is the central technical
finding of the code dive. See Technical Notes.

## Requirements

### Both reports

- Two new report modules under `lib/report_server/reports/portal/`, declared `type: :portal`, with
  permanent slugs `student-id-mapping` and `student-metadata`.
- Both are registered in the existing `student-reports` tree group, alongside the three Athena
  student reports.
- Both declare `include_filters: [:cohort, :school, :teacher, :assignment, :class, :student,
  :permission_form]`, matching the sibling student reports and matching exactly the filter
  dimensions the shared learner query supports.
- Both are per-learner grain: one row per `learner_id`, meaning one student's participation in one
  offering. A student who did N assignments appears in N rows; a consumer groups back to one student
  via `user_id` / `primary_user_id`, which both reports carry.
- The two reports emit the same `learner_id` set for the same filter, and join 1:1 on it whenever
  `report_learners` holds one row per `learner_id`, which is what the portal's model guarantees but
  the schema does not enforce. A grain test asserts the property rather than assuming it.
- Both apply owner project scoping, so a researcher only ever sees learners inside their allowed
  projects, identically to the shared learner query today. A caller with zero allowed projects gets
  a zero-row (header-only) result, not an error and not an unscoped result.
- Each report's `get_query/2` returns a single `%ReportQuery{}` that renders to **one** SQL
  statement against the Portal MySQL database. No report may require a second query or an Elixir
  post-processing pass. (This is a hard contract, not a preference: see Technical Notes.)
- Both default to `learner_id` ascending, so repeated runs of the same filter produce the same row
  order, the web CSV and the API CSV agree, and the two reports' rows line up with each other.
- Both produce a correct row count in the web UI's row-count display, which wraps the query in
  `SELECT COUNT(*) FROM (…)` after discarding the select list.
- Both are reachable through `/api/v1` with no API-layer change: listed by `GET /reports`, shown,
  and downloaded as a streamed CSV with `execution: "sync"` and `report_type: null`.
- A `student-id-mapping` run is accepted by `/answers`, `/history` and `POST /attachments`. The
  learner set those endpoints derive is the report's rows **minus** any learner whose derived
  `source` is unusable, which `EndpointSet` drops; the report emits those rows and the bulk
  endpoints skip them. That divergence is a property of the shipped endpoint, not of these reports,
  and the mapping report's `runnable_url` column is what lets a consumer see which rows it affects.
  Acceptance holds **by construction**, not by anything this story adds: `EndpointSet` gates on
  `derives_learner_data`, which defaults to `true`, and derives the set from the run's stored
  `report_filter` through `LearnerData.fetch(..., allow_empty: true)`. So this story pins the report
  attributes that make it true and leaves the endpoint's own behavior to REPORT-88's tests, rather
  than restating them here where they would fail on someone else's change.
- Neither report declares the `enable_app_filter` form option REPORT-105 added. `app` constrains
  the partitioned Athena log table and has no meaning in a Portal query. Per that story's rule, a
  filter carrying `app` for a report that does not declare the option is rejected where the filter
  is built rather than stored and silently ignored: `check_app_supported/2` at submit today, and
  REPORT-93's create endpoint when it lands. `report_filter_json/1` still serializes the key for
  these runs, as `[]`. The rejection is REPORT-105's code and carries REPORT-105's test; what this
  story owns is only that neither report declares the option.
- Neither report pays for REPORT-105's submit-time learner count. `warning_applicable?/1` keys off
  `enable_app_filter`, so the partition-estimate task never starts for a Portal report and submit
  goes straight to creating the run. Like the rejection above, this follows from the absent option
  rather than from anything here, and it is REPORT-105's `warning_applicable?/1` that decides it.
- Zero matching learners is a success, not an error: a header-only CSV with `200`, matching the
  Portal download contract REPORT-88 established.

### Student ID Mapping (`student-id-mapping`)

- Identifiers only. No student name, no username, no class name, no school name, no teacher
  identity. `hide_names` has no effect on the output, and a test proves it rather than the spec
  asserting it, since this claim is the whole reason the report does not offer the control.
- Emits, as top-level columns (never `res_N_`-prefixed): `learner_id`, `user_id`,
  `primary_user_id`, `student_id`, `class_id`, `offering_id`, `runnable_url`, and
  `run_remote_endpoint`.
- `run_remote_endpoint` is byte-identical to the `remote_endpoint` the shipped Athena student
  reports emit for the same learner, and therefore to the record identity cc-data stores, so a local
  join succeeds. This holds for a learner with no `secure_key` too, where both sides produce the
  trailing-slash string rather than an empty cell.
- No raw `secure_key` column.
- Does not declare the `enable_hide_names` form option, because `hide_names` provably changes
  nothing in this report's output.

### Student Metadata (`student-metadata`)

- Join keys: `learner_id` (1:1 to the mapping report), `user_id`, `primary_user_id`, `student_id`,
  and `run_remote_endpoint`, so the report can also be joined straight to answers and history
  without going through the mapping report. Plus `class_id` and `school_id`, so a consumer can group
  by class or school without matching on a name string.
- Metadata: `student_name`, `username`, `class`, `school`, `permission_forms`, `last_run`, and five
  teacher columns named exactly as the Athena student-answers report names them, so the two report
  families concatenate: `teacher_user_ids`, `teacher_names`, `teacher_emails`, `teacher_districts`,
  `teacher_states`.
- **All five are positionally aligned**: index *i* is the same teacher in every one of them. This is
  the report's contract, and it is the reason `teacher_districts` and `teacher_states` are derived
  from live joins rather than read from the denormalized `report_learners` columns, which carry one
  entry per *(teacher, school)* pair and so do not align with the teacher list.
- A teacher belonging to more than one school contributes **one** district and one state, and both
  come from **the same school**, the one with the lowest `portal_schools.id`. The column means "a
  district for this teacher", not "the district"; the Athena reports make the same arbitrary
  single-school choice, so the two families agree in kind even where they may disagree on which
  school. Naming the school is not a detail: choosing the district and the state independently (with
  `MIN()` over each) is deterministic and still emits pairs that exist nowhere in the data, which was
  measured on a fixture where it reported a NH teacher's district beside another school's MA.
- Every teacher named in `teachers_id` occupies a position in the district and state lists, whether
  or not a district can be found for them. A teacher with no school membership, and a teacher id with
  no `portal_teachers` row at all, each contribute an **empty** entry rather than no entry. This has
  to be built rather than assumed: `GROUP_CONCAT` skips NULL values, so an implementation that reads
  through `portal_teachers` and lets a missing district fall out silently shortens the list and
  misaligns every position after it.
- The alignment must not be silently breakable. `GROUP_CONCAT` truncates at
  `group_concat_max_len` (1024 bytes by default) by cutting mid-value and raising warning 1260,
  which nothing in the app currently inspects; a truncated list would misalign exactly the columns
  this contract is about. The query raises the limit **for itself**, with the per-statement optimizer
  hint `SELECT /*+ SET_VAR(group_concat_max_len=...) */`. `SET SESSION` is not an option: it is a
  second statement, which the one-statement contract forbids, and it would leak to every later query
  on that pooled connection. Asserting `num_warnings` instead is possible but weaker, and on the
  streamed download it has to be checked per batch rather than once.
- Every list-valued column in the report (the five teacher columns and `permission_forms`) uses a
  single separator, `","`, so a consumer has one splitting rule for the whole file and can zip the
  five teacher columns by index.
- `last_run` renders as an ISO-8601 string (`2026-05-01T10:00:00`), the same shape the Athena
  student reports emit, so the two can be compared without reformatting. An absent `last_run` is an
  empty cell.
- Declares the `enable_hide_names` form option, as the sibling student reports do, and no other.
  `enable_app_filter` belongs to the two log reports alone; see the `app` bullet under Both
  reports.
- When `hide_names` is on:
  - `student_name` carries the `student_id` value, under the column name `student_name`.
  - `username` carries a salted SHA-1 hash of the username.
  - Both substitutions produce **exactly the same value** as the shipped Athena student reports
    produce for the same learner under the same setting, so hide-names output from the two report
    families joins and compares.
- Anonymization is applied in the report's SQL, so it cannot be bypassed by any download path
  (web CSV, web JSON, or the API stream).
- Non-admin, non-project-admin callers have `hide_names` forced on at run creation. That
  enforcement currently exists only inside the report form's private `maybe_enforce_hide_names/2`,
  with no check at the persistence layer, so this report must not be the only thing standing between
  a researcher and a student name: the invariant is called out as a precondition REPORT-93's
  create-run endpoint has to satisfy, and the enforcement is made reachable from outside the
  LiveView rather than left private to it.

### Shared query

- The filtered, user-scoped learner base query is extracted into one place and used by both new
  reports and by the existing Athena learner path, so the filter semantics and the project scoping
  have a single source of truth. Both new reports project their own select lists onto that one base.
- The extraction lives in a neutral namespace, not under `Athena`, and takes the caller's select
  list as an argument.
- The extraction is behavior-preserving for every existing caller of the base query, which is no
  longer only the four Athena reports: REPORT-105 added `LearnerData.count/2` and `count_query/1`,
  which the report form runs at submit to project a log report's partition count, so a change to
  the base moves that estimate too. Generated SQL and results are unchanged for all of them.
  REPORT-105's `learner_data_test.exs` already pins `build_query/2` and `count_query/1` at the SQL
  level, so most of that guard exists rather than needing to be written.
- Both new reports collapse the base query's multiplied rows with `GROUP BY`, not with `DISTINCT`,
  so the web UI's row count is correct.
- The grouping is on `rl.id` **together with the primary keys of every joined table the select list
  reads from**: `u.id`, `ea.id` and `pl.id`. Enumerating them is not busywork, and the list is not
  obvious from the select list at a glance: `pl.id` is there because both reports build
  `run_remote_endpoint` from `pl.secure_key`, which is the column MySQL names in the error once the
  first two are added. Grouping on `rl.id` alone is accepted by MySQL only while the
  optimizer can still see the joins: as soon as the project scoping contributes its `1 = 0` clause,
  the impossible `WHERE` lets MySQL discard the joined tables and the select list is then rejected
  with `ERROR 1055` under `ONLY_FULL_GROUP_BY`. That is the zero-allowed-projects case two bullets
  up, so the narrower grouping turns the "header-only result, not an error" promise into a failed
  report on both the web page and the API download. Grouping on the joined primary keys satisfies the
  dependency through the grouping columns themselves, is accepted with the clause present, and still
  emits one row per learner.

### Documentation

- The two reports' column contracts are written down where a consumer will look, because the
  non-obvious parts are the ones a reader gets wrong: the per-learner grain and how to group back to
  a student; that all five teacher columns align by index and a multi-school teacher contributes one
  deterministically chosen district; that every list column separates on `","`; and that
  `run_remote_endpoint` is the join key
  to cc-data's stored `remote_endpoint`, with a learner lacking a `secure_key` yielding a
  trailing-slash form that joins to nothing.
- This is the contract REPORT-94 consumes and REPORT-95 describes to Claude, so it ships with the
  reports rather than with either of them.

### Testing

Split deliberately, because the existing suite executes no portal SQL at all: every shipped
portal-report test asserts on the generated SQL string, with a role-less user so no portal-DB call
happens. Three of the properties below are about *results* and cannot be asserted that way.

**SQL-shape tests** (no database, matching the existing portal-report tests):

- The emitted column set and column names for both reports.
- Project scoping absent for a super-admin, and the zero-allowed-projects clause present for a
  caller with no allowed projects.
- The hide-names substitutions present and absent, including that the `username` expression is the
  MySQL translation of the Athena one rather than any other hash spelling.
- The grouping carries the joined primary keys, not `rl.id` alone, and no `DISTINCT` collapse is
  used. Assert the joined keys are present rather than matching the whole string, so the test says
  what they are for.

**Result-level tests** (need a portal-DB fixture; see the Testing-infrastructure note below):

- The row count the web UI computes equals the number of rows the report emits, on a fixture where
  the underlying joins multiply rows.
- The per-learner grain: for a filter selecting one learner, each report emits exactly one row, and
  the two reports' `learner_id` sets are equal.
- The hide-names `username` value equals the digest the Athena expression produces for the same
  input and salt.
- Project scoping applied for a **project admin**, which is DB-backed by construction:
  `get_allowed_project_ids/1` queries the portal for that role, and `ReportUtils` calls `PortalDbs`
  directly with no seam.
- A caller with **no** allowed projects gets zero rows and no error, asserted by executing the
  statement rather than by matching its text, on both surfaces (`PortalDbs.query/4`, which the web
  run page uses, and `PortalDbs.stream_query/4`, which the API download uses) and for **both** roles
  that reach the clause: a role-less user, whose `get_allowed_project_ids/1` returns `:none` with no
  portal query, and a project admin whose lookup comes back empty, which returns `[]` from the
  database. They are different code paths into the same clause, and the second is the one that
  caught the grouping being enumerated short.
- `hide_names` changes nothing in the Student ID Mapping report: the generated SQL and the returned
  rows are identical with the flag set and unset.
- Teacher-column alignment on a fixture built to break it: all five columns split to the same number
  of entries, and index *i* names the same teacher in each, for a learner whose class has a teacher
  in two schools, a teacher in none, and a teacher id with no `portal_teachers` row.
- The district and the state at index *i* come from the same school, asserted on a teacher whose two
  schools have crossed districts and states, so picking each field independently produces a pair
  that the fixture can prove impossible.

The result-level tests are only as good as the fixture, and the second-pass review found three
defects that the first pass's fixture could not have caught. The fixture therefore has to carry: a
learner whose joins fan out; a teacher belonging to two schools whose districts and states are
crossed; a teacher with no school membership and a teacher id with no `portal_teachers` row; a
learner with a `NULL` `teachers_id`; and the project-scoping rows (`admin_project_users`,
`admin_cohorts`, `admin_cohort_items`, `admin_project_materials`) seeded so that one project admin
sees a strict subset of what a super-admin sees and another sees nothing. A scoping test whose
scoped and unscoped results are equal proves nothing.

**Both:**

- Every test asserts on a non-empty collection, or asserts its length first. A test that iterates a
  possibly-empty result asserts nothing.
- The story delivers whatever fixture or seam the result-level tests need; they are not deferred to
  a later story, because they are the tests that would catch the defects this spec's design notes
  are guarding against.

## Technical Notes

### Correction: a Portal report must be a single SQL statement, so `LearnerData.fetch` cannot be the base

The ticket says both reports "project from the same filtered, user-scoped portal-DB query that
`Athena.LearnerData.fetch` already implements." `fetch/3` is not a query; it is a three-query Elixir
pipeline (the learner query, then `get_teacher_map`, then `get_permission_form_map`), which then
builds `run_remote_endpoint` in Elixir and groups the result by `runnable_url`.

**REPORT-105 has since made the first half of the correction true in code.** It split the query
construction out of `fetch/3` into a public `build_query/2` so that its partition estimate could
count the same learners a report covers, and added `count/2` and `count_query/1` on top. So the
statement "there is a query in there, it is just not `fetch/3`" is now a fact about the code rather
than a finding, and what remains for this story is narrower: move `build_query/2`'s body to a
neutral namespace and let the caller supply `cols`.

Every consumer of a `type: :portal` report calls `report.get_query.(filter, user)` and then
`ReportQuery.get_sql/1,2`, and runs the resulting single statement:

- the API download streams it with `MyXQL.stream` (`report_controller.ex`, `portal_download/4`),
- the web run executes it directly (`report_run_live/show.ex`, `run_report/5`),
- the web row count wraps it in `ReportQuery.get_count_sql/1`,
- the web column sort rewrites its `order_by` with `ReportQuery.add_sort_columns/2`.

There is no seam anywhere for a second query or an Elixir post-processing pass. So the correct
shared base is **the `%ReportQuery{}` construction and filter application** now living in
`build_query/2` (the `from`, the join set, the project scoping, and the seven filter dimensions),
extracted so the caller supplies its own `cols`. `build_query/2` then becomes a delegation, `fetch/3`
and `count/2` keep working through it unchanged, and each new report is the base query plus its own
select list. Per the ticket's namespace note, the extracted base belongs in a neutral namespace
rather than under `Athena`.

One property of `build_query/2` carries over and is worth stating, because its name denies it: it is
not a pure builder. With `exclude_internal` set it runs its own portal query through
`get_internal_teacher_ids/1` to resolve the ids, so the extracted `build/4` can fail before it
produces any SQL, and both new reports inherit that whenever a researcher checks the box.

### Correction: `get_teacher_map` and `get_permission_form_map` are not needed

The ticket calls re-expressing these in MySQL "the biggest hidden-effort item." It is not an item at
all. `report_learners` is a denormalized table maintained by the portal
(`rigse/rails/app/models/report/learner.rb`, `update_teacher_info_fields` and
`update_permission_forms`) and already carries every value those two helpers rebuild:

| `report_learners` column | Contents | Athena student-answers equivalent |
| --- | --- | --- |
| `teachers_id` | `", "`-joined `Portal::Teacher` ids | `teacher_user_ids` (same ids) |
| `teachers_name` | `", "`-joined teacher names | `teacher_names` |
| `teachers_district` | `", "`-joined district names, one per *(teacher, school)* | **not used**: does not align with the teacher list, so `teacher_districts` is derived live |
| `teachers_state` | `", "`-joined states, one per *(teacher, school)* | **not used**, for the same reason |
| `teachers_email` | `", "`-joined emails | `teacher_emails` |
| `permission_forms` | `","`-joined `fullname`s | `permission_forms` |

`Portal::PermissionForm#fullname` is `"#{project.name}: #{name}"`, which is character-for-character
what `get_permission_form_map` builds. So the Student Metadata report reads these columns directly
and needs no second query, no `GROUP_CONCAT`, and no promotion of the two private helpers.

One divergence from the Athena reports comes with this, accepted rather than fixed (see the
resolved question on sourcing, below). A second one, the district and state grain, was **not**
accepted: it is the reason those two columns are derived from live joins instead. Both are:
the list separator is `", "` here versus `","` in the Athena output, and `teachers_district` /
`teachers_state` list **every** school a teacher belongs to, where `get_teacher_map` picks one
arbitrarily via a `LEFT JOIN` whose last row wins. That second divergence turned out to have a
consequence the first pass missed, and is why those two columns are derived live rather than read;
see the Self-Review.

### Verified: `hide_names` translates exactly into MySQL, but not naively

`ReportQuery`'s Presto expression is `TO_HEX(SHA1(CAST(('<salt>' || username) AS VARBINARY)))`.

- **`HEX(SHA1(...))` is the wrong translation.** MySQL's `SHA1()` already returns a 40-character
  lowercase hex *string*, so wrapping it in `HEX()` double-encodes to 80 characters. Verified on
  MySQL 8.0.39.
- **`UPPER(SHA1(CONCAT('<salt>', <username col>)))` is the right translation.** Verified against an
  independent `sha1sum` of the same input: both produce the identical uppercase 40-character digest,
  so a hidden username from this report joins to a hidden username from the Athena reports.
- `student_name` under hide-names is the portal `student_id` value in both engines.
- The salt is `Application.get_env(:report_server, :athena)[:hide_username_hash_salt]`, app-level
  configuration rather than anything Athena-specific, so a Portal report can read it. It is
  interpolated into SQL as a bare single-quoted literal today; in MySQL, unlike Presto, a backslash
  inside a string literal is an escape character, so the literal must be escaped for MySQL rather
  than copied from the Athena code path.
- Without `HIDE_USERNAME_HASH_SALT` configured the salt is randomized per boot, so hashes are not
  stable across restarts. That is pre-existing and out of scope here, but it means hash-stability
  tests must pin the salt rather than read the ambient config.

### Verified: `DISTINCT` gives a wrong row count, `GROUP BY` on the `report_learners` primary key is correct

The learner query's join set multiplies rows: it joins `portal_teacher_clazzes` (once per teacher on
the class) and `LEFT JOIN portal_runs` (once per run). `LearnerData` collapses this with a
`DISTINCT` on the first select column.

`ReportQuery.get_count_sql/1` builds its count by **discarding the select list** and substituting
`1 AS qrow`, so a `DISTINCT`-based collapse is discarded with it. Probed on MySQL 8.0.39 with a
fixture of one learner, two teachers on the class, and two runs:

| Query | Rows |
| --- | --- |
| raw joined rows | 4 |
| `SELECT DISTINCT …` | 1 |
| `get_count_sql` over the `DISTINCT` query | **4** (wrong) |
| `get_count_sql` over a `GROUP BY` query | **1** (correct) |

So the new reports must collapse with `GROUP BY`, not `DISTINCT`.

REPORT-105 hit the same fan-out from the other side and reached the same conclusion independently,
which is worth recording because it turns a fixture probe into a production measurement.
`LearnerData.count/2` deliberately avoids `get_count_sql/1` for exactly the reason above, and its
docstring says so; measured against the twelve assignments matching `name LIKE '%Dataflow%'`,
`COUNT(DISTINCT rl.learner_id)` gives 814 where `get_count_sql/1` gives 4,971, a 6.11x fan-out. That
is the failure the new reports avoid by grouping: with `GROUP BY rl.id` in the query,
`get_count_sql/1` is correct for them, which is why they can use the web UI's row count and
`LearnerData` cannot.

The naive `GROUP BY rl.learner_id` is rejected by MySQL 8's default `ONLY_FULL_GROUP_BY`
(`ERROR 1055`), because `learner_id` is not a unique key of `report_learners`. `GROUP BY rl.id` (the
table's primary key) is accepted, and MySQL's functional-dependency analysis follows the equality
joins on primary keys so that columns from `portal_learners`, `users`, `external_activities` and
`portal_offerings` remain selectable. Both new reports' full candidate select lists were probed
under `ONLY_FULL_GROUP_BY` and run clean with `GROUP BY rl.id`.

### Verified: `run_remote_endpoint` in SQL

`CONCAT('https://<portal_server>/dataservice/external_activity_data/', pl.secure_key)` reproduces
the Elixir construction. Two notes:

- `secure_key` is nullable in the portal schema. `CONCAT` with a `NULL` argument yields `NULL`,
  whereas the Elixir interpolation yields a trailing-slash string. Neither joins to anything, but
  the two paths differ, so the report should pick one deliberately.
- The scheme is hardcoded `https://` in the existing Elixir construction. A `http://localhost:3000`
  dev portal therefore yields a `https://localhost:3000/...` endpoint that will not match a Firebase
  `remote_endpoint` written with `http://`. This is pre-existing and affects the shipped Athena
  reports identically.

### Verified: no LiveView work

The ticket's scope line says "add LiveView entries and tests." There is no per-report LiveView
registry: `tree.ex` is the only place a report is declared, and the form, run, and download views are
generic over `%Report{}`. The only per-slug special case anywhere in the web layer is
`post_processing.ex`'s backwards-compatibility mapping for `student-answers`, which does not apply
here. Registering the two reports in `tree.ex` is the whole of the wiring.

### `source` / `source_key`

`SourceKey.from_runnable_url/1` (`answersSourceKey` query parameter, else host, with the
offline host remapped) can be re-expressed in MySQL with nested `SUBSTRING_INDEX` calls; a probe
reproduced the Elixir result on all four shapes tested. It is not exact: `URI.decode_query/1`
percent-decodes the parameter value and `SUBSTRING_INDEX` does not, so a percent-encoded
`answersSourceKey` would diverge. Note that the bulk endpoints derive `source` server-side in
`EndpointSet`, so the CLI does not need this column to fetch; and `remote_endpoint` is unique per
learner, so a local join does not need it either.

### Existing behavior worth carrying forward or deliberately not

- `LearnerData.fetch/3` errors with "No learners were found matching the filters you selected." on
  an empty result unless `allow_empty: true`. The Portal SQL path has no such check and would return
  a header-only CSV, which is the contract REPORT-88 settled on for Portal downloads.
- `ReportQuery.update_query/2` returns `{:error, "Cannot run query with no filters"}` when both the
  join and where accumulators are empty. For a super-admin (no project scoping) running with no
  filters, both new reports will hit this and the API returns a clean `422`, matching every other
  Portal report.
- The web UI offers CSV **and JSON** download for Portal reports; the API is CSV only. Both new
  reports inherit that.

### Testing infrastructure the result-level tests need

The suite has no portal-DB fixture and no seam for `PortalDbs.query/4`. The `portal_db` seam
REPORT-88 added stubs only `stream_query/4`, and its own docstring says it "deliberately does not
stub `get_allowed_project_ids`/`query`", keeping the query-build path DB-free by seeding a
super-admin run. Every shipped portal-report test is `ExUnit.Case, async: true` asserting on a
normalized SQL string with a role-less `%User{}`.

The gap is smaller than it looks. `config/test.exs` already points the app's Ecto repo at the local
MySQL 8 the repo's `docker-compose.yml` starts (`localhost:3406`, `root`/`xyzzy`), so a real MySQL is
present in the test environment. `PortalDbs` resolves a portal server's credentials from a
`<SERVER>_DB` environment variable and hardcodes `database: "portal"`, so a fixture portal server can
be pointed at that same MySQL by setting one variable, provided the fixture tables live in a schema
named `portal`. That, plus the handful of tables the learner base query touches
(`report_learners`, `portal_learners`, `users`, `portal_offerings`, `external_activities`,
`portal_student_clazzes`, `portal_teacher_clazzes`, `portal_runs`), is what the result-level tests
need.

### Checked and cleared: `run_remote_endpoint` is an identifier, not a capability

Worth recording because it is the first question a reviewer asks about a report whose defining column
is a URL containing an unguessable per-learner key, and because the Project Owner Overview leans on
the mapping report carrying nothing sensitive. The portal route the endpoint names
(`POST /dataservice/external_activity_data/:id_or_key`) resolves to
`Dataservice::ExternalActivityDataController`, whose actions are both `head :ok` and whose own
comment says the endpoint "doesn't do anything at this point, as answers are handled by Firestore
and Athena. However, the API endpoint URLs are still used to identify students." So the string grants
nothing: holding it does not read or write any data, and the report-service bulk endpoints derive
their own authorized endpoint set from the run rather than trusting a caller-supplied one. It is a
per-student identifier, and the report should be handled as such, but it is not a bearer token.

### Checked and cleared: REPORT-106 changes nothing for either report

REPORT-106 persists Athena's `StateChangeReason` on the run and surfaces it, and it lands in files
this story reads, so it was checked rather than assumed. Nothing in it reaches a Portal report:

- `ReportJSON.show/1` gains `athena_query_id` and `athena_query_error`, both always `nil` for a
  `type: :portal` run. The API contract these reports rely on, `execution: "sync"` with
  `report_type: null`, is unchanged. The run body's key set is now guarded by `@run_keys` in
  `report_controller_test.exs`, so a test of this story's that asserts on the run body goes through
  that guard rather than restating the key set beside it.
- The run page's failure block is inside `report_header/1`'s `report.type == :athena` branch, so a
  Portal run never renders it.
- The `NOT_READY` body that grew two keys is in `athena_download/2`. `portal_download/4` is selected
  before it and never reaches it, so the header-only-CSV contract for zero learners is untouched.

One thing to carry into the rebase rather than into the design: REPORT-105 and REPORT-106 both edit
`report_json.ex`, `custom_components.ex` and `report_controller_test.exs` in the same regions, so
they conflict with each other. Whichever order they merge in is the base this story rebases onto.

### End-to-end rehearsal of both reports

Before any implementation spec, both reports were assembled as throwaway code far enough to produce
their **real** SQL through `ReportQuery.get_sql/1` and `get_count_sql/1` and run it against the
fixture, and both were registered in `tree.ex` to see what the API actually derives. **The rehearsal
ran on the pre-REPORT-105 base.** Nothing below depends on what that story changed, since it moved
the learner query without altering the join set, the filters or the columns, but the numbers were
measured on that base and the extraction is against a different starting point now. Everything the
requirements assert held; the throwaway code was deleted rather than committed. What the rehearsal
settles, beyond the individual probes recorded above:

- **The whole chain composes.** `%ReportQuery{cols: …, group_by: "rl.id", order_by: [{"learner_id",
  :asc}]}` renders to one legal statement, returns exactly one row for a learner whose joins fan out
  to four, and its `get_count_sql/1` wrapper returns `1` rather than `4`. The `group_by` field
  survives into the count wrapper, which is what makes the web row count correct.
- **Both reports are API-visible with no API-layer change.** Registered in the `student-reports`
  group they appear in `Tree.api_report_slugs()` and not in `athena_report_slugs()`, and the values
  `ReportJSON` derives are `execution: "sync"` and `report_type: null`. `derives_learner_data`
  defaults to `true`, so the three bulk endpoints accept them.
- **The full suite stays green** with both registered. The tree-consistency test passes, though it
  is not coverage for these reports: it asserts only inside a branch that any report carrying
  learner-narrowing `include_filters` skips, so both new reports pass through it untouched. The
  count taken at the time, 519 tests, is stale:
  REPORT-105 and REPORT-106 each add a substantial suite, so re-measure on the head commit rather
  than quoting this number.
- **`run_remote_endpoint` is byte-identical to the Elixir construction in both cases.** For a present
  key both produce `https://<portal>/dataservice/external_activity_data/SECUREKEY123`; for a `NULL`
  key, `COALESCE(pl.secure_key, '')` and Elixir's interpolation of `nil` both produce the
  trailing-slash string, character for character.
- **The null edges behave as specified.** A learner with a `NULL` `external_activities.url` emits a
  `NULL` `runnable_url`, which is exactly the row `EndpointSet` drops from the bulk endpoints, so
  that divergence is reachable in practice and not theoretical. A learner whose `teachers_district`
  was never assigned emits an empty cell while `teacher_names` and `teacher_emails` populate,
  confirming the independent per-column failure mode behind the teacher-column rename. A `NULL`
  `last_run` renders as an empty cell.
- **The two scoping edges resolve as documented, and one of them was checked wrongly.** A role-less
  caller yields `… AND (1 = 0)` rather than `IN ()`, and a super-admin with no filters at all yields
  `{:error, "Cannot run query with no filters"}`, the clean `422`. The first was read as a string and
  called "valid SQL constraining to zero rows"; it is not, with the grouping this rehearsal used. See
  the second-pass Self-Review, which runs it. With the grouping the requirements now specify, the
  statement executes and returns zero rows on both surfaces.

### Verification environment

A DuckDB probe (the same engine cc-data queries with) compared the two teacher-column naming options
under `UNION ALL BY NAME`, on a fixture of one Athena-family row and one Portal-family row for the
same two teachers where one belongs to two schools; it is what decided that question. A local MySQL
8.0.39 (the repo's `docker-compose.yml` dev database) with a hand-built minimal
`report_learners` / `portal_learners` / `users` / `portal_offerings` / `external_activities` /
`portal_student_clazzes` / `portal_teacher_clazzes` / `portal_runs` fixture was used for the row
count, `ONLY_FULL_GROUP_BY`, hash, endpoint-construction and source-derivation probes above. The
fixture is throwaway and is not part of this story's deliverables. The Elixir test suite runs with
placeholder values for the four required runtime environment variables.

## Out of Scope

- Any change to the `/api/v1` layer. REPORT-88 already admits `type: :portal` reports to listing,
  show, download and the three bulk endpoints; these reports are picked up by that mechanism.
- The cc-data CLI changes that consume these reports (REPORT-94) and the skill/MCP guidance that
  documents the workflow (REPORT-95).
- Any change to the Athena student reports' column sets or output.
- The hardcoded `https://` scheme in `run_remote_endpoint`, and the randomized fallback salt, both
  pre-existing and both affecting the shipped Athena reports identically.
- A live cross-check that `run_remote_endpoint` matches a real Firebase record byte for byte. The
  Firebase side is written by the data-service, outside both repos; the in-code evidence is that the
  same construction is already the shipped join key in the student-answers report.
- Aggregate or roll-up variants of either report. Both are strictly per-learner.

## Open Questions

All ten questions raised while drafting were resolved against the code and against probes on a local
MySQL 8.0.39; none of them turned out to need a project-owner call. They are kept here as RESOLVED
with their rationale, because several of them are the reason a requirement above reads the way it
does.

### RESOLVED: How should Student Metadata name and shape its teacher columns?
**Context**: The ticket names a single `teachers` column. The shipped Athena student-answers report
emits five: `teacher_user_ids`, `teacher_names`, `teacher_districts`, `teacher_states`,
`teacher_emails`. The denormalized `report_learners` columns line up 1:1 with those five.
**Options considered**:
- A) Five columns named exactly as the Athena reports name them.
- B) One `teachers` column, as the ticket says.
- C) Five columns under new names.

**Decision**: **A**, later narrowed by the self review to the three columns that are genuinely
per-teacher, and later reopened: the district and state columns keep the Athena names too, but are
derived from live joins so that they align. The reasoning below is unchanged.

The single-`teachers`-column precedent (`ReportQuery.get_learner_cols/1`, used
by `student-actions-with-metadata`) works only because Athena can carry an array of structs in one
column; MySQL cannot, so B would have to invent a serialization that nothing else in the system
reads. Reusing the student-answers names makes the two report families concatenable and comparable,
and keeps `teacher_emails` available, which is the only teacher join key the aggregate Portal
reports expose. C loses that for nothing.

---

### RESOLVED: Should the teacher and permission-form values come from the denormalized columns or a live re-query?
**Context**: `report_learners` is a denormalized cache the portal maintains
(`rigse/rails/app/models/report/learner.rb`). Reading it keeps each report a single statement.
Reproducing `get_teacher_map`'s live semantics in MySQL needs `FIND_IN_SET` joins plus
`GROUP_CONCAT`, with a `group_concat_max_len` truncation risk.
**Options considered**:
- A) Read the denormalized columns; document the divergences.
- B) Read the denormalized columns, normalizing the list separator to `","`.
- C) Rebuild from live joins with `GROUP_CONCAT` for exact parity.

**Decision**: **B for the names, emails, ids and permission forms; C for district and state.**
The split was made later, when the review found the district/state grain breaks positional
alignment and the project owner confirmed the per-teacher district is information that matters. See
the Self-Review item on teacher-column alignment for the reversal and its evidence. The reasoning
below stands for the four columns that kept the denormalized source.

The deciding fact is that the shared learner query *already* reads
`student_name`, `username`, `class_name` and `school_name` from this same denormalized table; only
the teacher and permission-form names are re-queried live. Sourcing the rest from the cache is
therefore consistent with existing behavior rather than a new compromise, and C's added complexity
buys parity that is unattainable anyway (see below).

The normalization in B is not cosmetic: the portal joins the teacher lists with `", "` and the
permission-form list with `","`, so reading the columns raw would give **one report two different
list separators**. Normalizing to `","` gives the file one splitting rule and, as a side effect,
matches the Athena reports' `array_join(..., ',')`. The replacement is safe because the portal's
`escape_comma` rewrites any comma inside a value to a space before joining, so `", "` only ever
appears as a separator.

Two divergences from the Athena reports remain and are accepted, not fixed:
- The denormalized district and state columns enumerate **every** school a teacher belongs to, so
  they carry one entry per *(teacher, school)* pair and do not align with the teacher list. That is
  why this report derives those two live instead: joining `teachers_id` through `portal_teachers`,
  `portal_school_memberships`, `portal_schools` and `portal_districts`, and ordering the
  `GROUP_CONCAT` by `FIND_IN_SET(pt.id, teachers_id)` yields one entry per teacher in the teacher
  list's own order.
- `teacher_names` is Ruby's `User#name`, which falls back to the login when both name parts are
  blank; `get_teacher_map`'s `CONCAT(first_name, ' ', last_name)` yields `" "` in that case.

---

### RESOLVED: Should Student ID Mapping emit a `source` (or `source_key`) column?
**Context**: The ticket lists it as nice-to-have. A MySQL derivation with nested `SUBSTRING_INDEX`
calls was probed and reproduced `SourceKey.from_runnable_url/1` on all four URL shapes tested.
**Options considered**:
- A) Omit it; `runnable_url` is emitted, so a consumer can derive it correctly client-side.
- B) Emit it, accepting the divergence.
- C) Emit it and change `SourceKey.from_runnable_url/1` to match the SQL.

**Decision**: **A**. Nothing needs the column: the bulk endpoints derive `source` server-side in
`EndpointSet`, and `remote_endpoint` alone is unique per learner, so a local join does not need it.
Against that, the SQL derivation does not percent-decode where `URI.decode_query/1` does, so the
column would be right almost always and quietly wrong occasionally, which is the worst property a
join key can have. C would fix the divergence by dragging the shipped bulk-endpoint derivation into
this story's blast radius to serve a column nobody asked for.

---

### RESOLVED: What is each report's default row order?
**Context**: A deterministic order is needed so repeated runs agree and the streamed API CSV matches
the web CSV, which is a REPORT-88 contract.
**Options considered**:
- A) `learner_id` ascending for both.
- B) `class`, then `username`, mirroring the Athena student-answers ordering.
- C) `runnable_url`, then `learner_id`.

**Decision**: **A**. It is unique by construction, so the order is total rather than merely
deterministic, and it makes the 1:1 join between the two reports line up row for row, which is
exactly the use these reports exist for. B is not unique and orders by a column the mapping report
does not have; C orders by a column the metadata report does not have.

---

### RESOLVED: Should Student Metadata carry `class_id`, `offering_id`, `school_id` and `runnable_url` as well?
**Context**: The ticket has the metadata report emit `class` and `school` *names* but not their ids,
so a consumer cannot group by school without matching on a name string.
**Options considered**:
- A) Add `class_id`, `school_id`, `offering_id` and `runnable_url`.
- B) Keep the ticket's set exactly; a consumer joins to the mapping report for ids.
- C) Add only `school_id` and `class_id`.

**Decision**: **C**. The ticket already has this report carry `run_remote_endpoint` redundantly with
the mapping report, specifically so it can stand alone as a join dimension; `school_id` and
`class_id` serve that same stated intent and remove a name-string join, which is the failure mode
this whole story exists to eliminate. `offering_id` and `runnable_url` do not: they identify the
assignment, not the student context this report describes, and they are already in the mapping
report a consumer joins on `learner_id`.

---

### RESOLVED: Does `report_learners` guarantee one row per `learner_id`, and does it matter?
**Context**: `ONLY_FULL_GROUP_BY` forces `GROUP BY rl.id` (the primary key) rather than
`GROUP BY rl.learner_id`. The two are equivalent only if `report_learners` holds at most one row per
`learner_id`, which the portal schema's non-unique index does not enforce.
**Options considered**:
- A) Assume uniqueness and add a test that asserts the grain.
- B) Defend in the query, grouping over a subquery already reduced to one row per `learner_id`.
- C) Check production data first.

**Decision**: **A**. The portal models the relationship as `has_one :report_learner` on
`Portal::Learner` and only ever creates one through `super || create_report_learner!`, so a duplicate
would be an anomaly, not a supported state. B would add a subquery layer to every run of both
reports to defend against that anomaly, and it would not help anyway: if duplicates existed, the
existing `DISTINCT`-based learner query would already be silently collapsing them, so these reports
would merely be the first thing to make the corruption visible, which is the right outcome. C is not
worth blocking on, and per the standing rule against scanning production, is not a check to run
casually.

---

### RESOLVED: Should Student ID Mapping declare the `enable_hide_names` form option?
**Context**: The ticket says both reports set it, and that `hide_names` is a no-op for the mapping
report.
**Options considered**:
- A) Omit it on the mapping report; declare it on the metadata report only.
- B) Declare it on both, for consistency with the sibling student reports.

**Decision**: **A**. `enable_hide_names` controls only whether the checkbox is *shown*, and only to
admins and project admins (`form.ex`, `allow_hide_names?/1`); everyone else has `hide_names` forced
on regardless. Declaring it on a report where it provably changes nothing puts a privacy control in
front of an admin that does not do what it appears to do, which is worse than an inconsistency.

---

### RESOLVED: Where does the extracted shared learner base query live, and what is its shape?
**Options considered**:
- A) A new `ReportServer.Reports.LearnerBaseQuery` exposing `build(report_filter, user, cols)`.
- B) Make the existing private query construction public on `LearnerData`.
- C) Extract only the filter application, leaving each caller its own `from` and join set.

**Decision**: **A**, in a neutral namespace per the ticket's own note. `LearnerData.fetch/3` keeps
its column list and its Elixir post-processing and calls the extracted base, so the shipped Athena
reports keep byte-identical SQL and the change is reviewable as a pure move. B leaves Portal
reports calling into the `Athena` namespace, which is the misfiling the ticket asks to correct. C
leaves the join set duplicated in three places, and the join set is exactly what determines the
row multiplication and the project scoping, so it is the part that most needs one owner.

**B is now half of the status quo**, which strengthens A rather than reopening the question:
REPORT-105 made the query construction public as `build_query/2` because its partition estimate
needed it, but left it under `Athena`. So the misfiling the ticket names is real and shipped, and
this story's move is now the only thing that corrects it. The decision is unchanged; what changed is
that the extraction has three callers to keep working (`fetch/3`, `count/2`, and the report form's
count task through the `:learner_data` seam) rather than one.

---

### RESOLVED: How is `run_remote_endpoint` rendered when `secure_key` is `NULL`?
**Context**: `portal_learners.secure_key` is nullable. The Elixir construction interpolates `nil` as
`""` and yields a trailing-slash string; MySQL `CONCAT` with a `NULL` argument yields `NULL`.
**Options considered**:
- A) Let it be `NULL`.
- B) Match the Elixir construction's trailing-slash string.
- C) Exclude learners with no `secure_key` from both reports.

**Decision**: **B**, via `COALESCE(pl.secure_key, '')`. This is not really a free choice: the
requirement that `run_remote_endpoint` be byte-identical to what the Athena student reports emit for
the same learner has to hold for every learner, and A breaks it for exactly this one. In practice
the case is near-theoretical (`Portal::Learner` defaults `secure_key` to a random UUID on create, and
`Portal::Learner`'s own helpers guard with `secure_key.present?`, which is why the column is
nullable at all), which is also why C is wrong: silently dropping learners from a roster report to
tidy up an anomaly hides it.

---

### RESOLVED: Should `last_run` be formatted, and how do datetimes render in the CSV?
**Context**: `report_learners.last_run` is a MySQL `DATETIME`.
**Options considered**:
- A) Cast to a string in SQL to match the Athena reports.
- B) Leave it as the driver decodes it and document the shape.
- C) Confirm the rendered value first, then decide.

**Decision**: **C**, then **A**. Probed: MyXQL decodes the column to a `NaiveDateTime`, which the
Portal CSV encoder renders as `2026-05-01 10:00:00` (a space), while the Athena reports carry the
same value through `Jason` into the learners JSON and emit `2026-05-01T10:00:00` (a `T`). So the
divergence is real. `DATE_FORMAT(rl.last_run, '%Y-%m-%dT%H:%i:%s')` reproduces the Athena string
exactly and leaves `NULL` as `NULL`, which the encoder renders as an empty cell, matching Athena's
null. Verified on MySQL 8.0.39.

## Self-Review, second pass (post-REPORT-105, verified against a live MySQL 8)

Run after the story was rebased onto REPORT-105, with every finding checked by building the
proposed SQL and executing it against a fixture portal schema on MySQL 8.4 rather than by reading.
Roles: Database Engineer, Security & Privacy Engineer, QA Engineer, Performance Engineer, and
Education Researcher. Three of the five findings contradict statements this spec makes, and all
three were found by running the case rather than by inspecting the generated string, which is the
same gap the first pass's QA finding was about.

The fixture: one class, two teachers, a learner whose joins fan out to six rows, a second learner
carrying the null edges, and a third whose teacher list names a teacher with no school membership
and a teacher id with no `portal_teachers` row. The first teacher belongs to two schools whose
districts and states are deliberately crossed (`Dist W` is in NH, `Dist Y` is in MA).

### Database Engineer

#### RESOLVED: a caller with zero allowed projects gets ERROR 1055, not a header-only CSV

The requirement says "A caller with zero allowed projects gets a zero-row (header-only) result, not
an error and not an unscoped result", and the first pass's rehearsal recorded "a role-less caller
yields `... AND (1 = 0) GROUP BY rl.id`, valid SQL constraining to zero rows". The SQL is not valid.

`ReportUtils.scope_by_allowed_projects/5` emits `1 = 0` for `:none` and for `[]`. With that clause
present, MySQL 8 recognizes the impossible `WHERE`, discards the joined tables, and then rejects the
select list under `ONLY_FULL_GROUP_BY`, because with the join gone `u.primary_account_id` is no
longer functionally dependent on the grouping column. Both new reports select
`COALESCE(u.primary_account_id, u.id)`, and the mapping report also selects `ea.url`, so both hit
it. Minimal reproduction, run on MySQL 8:

```sql
-- succeeds
SELECT rl.learner_id, COALESCE(u.primary_account_id, u.id)
  FROM report_learners rl JOIN users u ON (u.id = rl.user_id) GROUP BY rl.id;

-- ERROR 1055: ... 'portal.u.primary_account_id' ... is not functionally dependent
SELECT rl.learner_id, COALESCE(u.primary_account_id, u.id)
  FROM report_learners rl JOIN users u ON (u.id = rl.user_id) WHERE (1 = 0) GROUP BY rl.id;
```

Verified through the real code path as well, on both surfaces: `PortalDbs.query/4` returns
`{:error, "Expression #2 of SELECT list is not in GROUP BY clause ..."}` and
`PortalDbs.stream_query/4`, which is what the API download uses, raises `MyXQL.Error (1055)` out of
`prepare_declare!`. So the web page shows an error and the API download fails, for the one caller
class the requirement singles out.

**This is introduced by this story, not inherited.** The same `1 = 0` against the shipped Athena
learner query succeeds: it collapses with `DISTINCT` and no `GROUP BY`, and `ONLY_FULL_GROUP_BY`
does not apply. The defect is a property of the grouping decision, which is why nothing in the
existing suite covers it.

Who reaches it: `get_allowed_project_ids/1` returns `:none` for any user who is not an admin, a
project admin, or a project researcher, so this is every ordinary portal user, not an exotic case.

**Verified remedy**: put the joined tables' primary keys in the grouping, `GROUP BY rl.id, u.id,
ea.id`. Functional dependency then holds through the grouping columns themselves rather than
through joins the optimizer may discard, so the statement is accepted with `1 = 0` present, and on
real data it still emits exactly one row per learner (2 rows for the fixture whose joins fan out to
6). `ANY_VALUE()` around each join-dependent column also works and was verified, but it suppresses
the check everywhere rather than satisfying it, so it is the weaker option.

**Resolution**: the Shared query requirements now specify the grouping as `rl.id` plus the primary
keys of the joined tables the select list reads, with the reason, and the zero-project case moves to
the result-level tests so a string assertion cannot pass for it again. Verified after the change:
the role-less caller returns zero rows through `PortalDbs.query/4` and through
`PortalDbs.stream_query/4`.

---

#### RESOLVED: for a teacher in more than one school, the district and the state can come from different schools

The requirement says a multi-school teacher "contributes **one** district and one state, chosen
deterministically", and the implementation chooses with `MIN(pd.name)` and `MIN(pd.state)`. Those
are two independent aggregates over the same group, so the district and the state need not describe
the same school. Verified on the crossed fixture, where Ann Teach belongs to `Dist W` (NH) and
`Dist Y` (MA):

| column | emitted |
| --- | --- |
| `teacher_names` | `Ann Teach,Bob Teach` |
| `teacher_districts` | `Dist W,Dist Y` |
| `teacher_states` | `MA,MA` |

Ann is reported as `Dist W` in `MA`. `Dist W` is in NH, and no school in the fixture pairs them. The
value is deterministic, as promised, and also impossible, which the requirement does not
contemplate. It is worse than the misalignment this column pair was derived live to avoid: a
researcher who groups by state attributes a NH teacher to MA, and the row cannot be recognized as
wrong from inside the file.

**Verified remedy**: choose the school once and read both fields from it, for example
`SUBSTRING_INDEX(GROUP_CONCAT(pd.name ORDER BY ps.id SEPARATOR '\t'), '\t', 1)` and the same over
`pd.state`. On the same fixture that yields `Dist W,Dist Y` with `NH,MA`, which is coherent per
teacher and still deterministic. The requirement should also say which school is chosen (lowest
`portal_schools.id`) rather than only that the choice is deterministic.

**Resolution**: the requirement now says both fields come from the same school and names it. The
implementation picks the school row once with `ORDER BY ps.id LIMIT 1` and reads both fields from
it, so coherence holds by construction rather than by two aggregates happening to agree. Verified:
`Dist W` now carries `NH`.

---

#### RESOLVED: the alignment contract fails for a teacher with no school and for a stale teacher id

The requirement says "A teacher with no school membership contributes an empty entry, preserving the
alignment." Verified false. `GROUP_CONCAT` skips NULL values rather than emitting an empty one, and
the subquery is driven by `portal_teachers` rather than by the teacher id list, so a teacher id with
no `portal_teachers` row contributes no row at all. On the third fixture learner, whose
`teachers_id` is `31, 33, 34` where 33 has no school membership and 34 has no teacher row:

| column | entries |
| --- | --- |
| `teacher_user_ids` | `31,33,34` (3) |
| `teacher_names` | `Ann Teach,Cid Teach,Gone Teach` (3) |
| `teacher_districts` | `Dist W` (1) |
| `teacher_states` | `MA` (1) |

Index 1 and index 2 have no district entry, so a consumer zipping the five columns silently pairs
the wrong teacher with the wrong district as soon as the missing teacher is not last. This is the
exact failure mode the live derivation exists to prevent, reintroduced through a different door.

**Verified remedy**: drive the list from the id string instead of from `portal_teachers`, and
coalesce the missing value, which keeps one entry per listed teacher including the unknown ones:

```sql
SELECT GROUP_CONCAT(COALESCE(d.district, '') ORDER BY jt.pos SEPARATOR ',')
  FROM JSON_TABLE(CONCAT('[', REPLACE(rl.teachers_id, ' ', ''), ']'),
                  '$[*]' COLUMNS (pos FOR ORDINALITY, tid INT PATH '$')) jt
  LEFT JOIN (<one row per teacher, district and state from the lowest-id school>) d ON d.tid = jt.tid
```

Verified output for the same learner: `Dist W,,` and `NH,,`, three positions against three names.
An empty `teachers_id` yields `[]`, zero rows, and an empty cell.

**Resolution**: the requirement now states the empty-position rule for both causes (no school
membership, and no `portal_teachers` row) and says why it has to be built rather than assumed. A
`NULL` `teachers_id` is handled with `COALESCE(rl.teachers_id, '')` before the `CONCAT`, since
`CONCAT` with `NULL` yields `NULL` and `JSON_TABLE(NULL)` is not the empty list. Verified across all
four fixture learners: every one of the five teacher columns splits to the same number of
entries.

Its cost, also verified and worth stating in the spec rather than discovering later: `JSON_TABLE`
raises `ERROR 3141` on malformed JSON, so a `teachers_id` that is not a bare comma-separated id list
fails the whole report rather than one row. The portal builds the column as `ts.map{|t| t.id}.join(", ")`
(verified in `rigse/rails/app/models/report/learner.rb`), so the shape is sound in practice, but the
report should either guard the input or accept a documented failure mode.

---

### Performance Engineer

#### RESOLVED: the two teacher columns are dependent subqueries, re-executed per row

`EXPLAIN` on the proposed metadata query, verified on MySQL 8:

```
1 PRIMARY            rl           ALL
2 DEPENDENT SUBQUERY <derived3>   ALL
3 DEPENDENT DERIVED  pt           index   Using where; Using temporary
3 DEPENDENT DERIVED  psm          ALL     Using where; Using join buffer (hash join)
```

`FIND_IN_SET(pt.id, ...)` is not sargable, so the derived table scans `portal_teachers` and
`portal_school_memberships` in full, it is marked `DEPENDENT`, so it re-runs for every outer row,
and the report emits two of them (districts and states). Cost grows as rows x 2 x
(portal_teachers + portal_school_memberships), against the 120 second ceiling
`PORTAL_DOWNLOAD_TIMEOUT_MS` sets on the streamed download REPORT-88 shipped. Nothing here has been
measured on production data, so the finding is the plan shape, not a number.

Both remedies above fold into one that also fixes this: compute district and state once per teacher
in a single derived table and join it, rather than correlating per row. The requirement that each
report be one statement does not forbid a join.

**Resolution**: folded into the same rewrite. The per-teacher lookup is now keyed on
`psm.member_type` and `psm.member_id`, which production indexes as `member_type_id_index`, so
`EXPLAIN` reports a `ref` lookup on that index where it previously reported a full scan of
`portal_school_memberships` with a hash join and an index scan of `portal_teachers`. The remaining
per-row work is bounded by the number of teachers on the learner's class rather than by the size of
either table. Still unmeasured on production data, which is the honest state of it.

### QA Engineer

#### RESOLVED: the scoping case that fails is listed as a SQL-shape test

The Testing section puts "Project scoping absent for a super-admin and constrained to zero rows for
a caller with no allowed projects" under **SQL-shape tests (no database)**. A string assertion is
exactly what passed while the statement itself is rejected by the server, which is how the first
finding above survived the first pass and its rehearsal. The zero-project case has to execute.

The same applies to the two alignment findings: the first pass's fixture had every teacher in
exactly one school and every teacher id resolvable, so the alignment test it specifies would have
passed against all three defects.

**Resolution**: the zero-project case moves to the result-level list, and the Testing section now
states the fixture shape the result-level tests need, since the fixture is what does the
catching.

#### RESOLVED: the truncation guard needs a mechanism the spec has not chosen, and one of the two options does not exist

The requirement says the query "either raises the limit for itself or asserts no truncation warning
was returned". Verified, in order:

- Truncation is real and silent in the result: with `group_concat_max_len` at 10 the column comes
  back as `Dist W,Dis`, cut mid-value, with warning 1260 raised twice.
- `%MyXQL.Result{}` does carry `num_warnings` (0 on a clean run of the real report SQL), so the
  assertion option is available on `PortalDbs.query/4`. On the streamed API path the reducer
  receives each `%MyXQL.Result{}` batch, so the check has to run per batch rather than once.
- "Raises the limit for itself" cannot be `SET SESSION`: that is a second statement, which the
  one-statement contract forbids, and it would leak to every later query on that pooled connection.
  The mechanism that does work, verified, is the per-statement optimizer hint
  `SELECT /*+ SET_VAR(group_concat_max_len=1048576) */ ...`, after which the session value is still
  1024.

**Resolution**: the requirement now names the optimizer hint and says why `SET SESSION` is not
available.

#### RESOLVED: the tree-consistency test the spec leans on cannot fail for either new report

The rehearsal records "The tree-consistency test passes because both carry learner-narrowing
`include_filters`". Verified in `tree_test.exs`: the test iterates every report and asserts only
inside `if Enum.all?(@learner_narrowing, &(&1 not in report.include_filters))`. Both new reports
take the false branch, so the test skips them entirely. The statement is true and carries no
evidence; it should not be cited as coverage.

**Resolution**: the rehearsal note keeps the fact and no longer offers it as coverage. Nothing is
added to `tree_test.exs`: it belongs to REPORT-88 and is doing its own job. The API-surface test
this story adds is what pins the two reports.

### Security & Privacy Engineer

#### RESOLVED: the two hide-names findings from the first pass still hold on the post-105 base

Re-verified rather than assumed, since REPORT-105 restructured the handler around them.
`maybe_enforce_hide_names/2` and `allow_hide_names?/1` are still `defp` in `report_live/form.ex`,
now called from the second `submit_form` clause, and a repo-wide grep still finds no other caller.
The salt escaping reproduces exactly: with a salt of `sa\lt`, the naive quote-only escaping hashes
to `9E90B470...` and the correctly escaped literal to `4B5BDEC5...`, matching what the first pass
recorded. No change.

#### RESOLVED: hash parity and the anonymization substitutions hold against the real code

Executed rather than compared as strings: `UPPER(SHA1(CONCAT('<salt>', rl.username)))` returns
`78968E29F9C171FDEB666ADF8446FE8F553E732C` for the fixture learner, byte-identical to
`:crypto.hash(:sha, salt <> "stu.one") |> Base.encode16()`, and `student_name` under hide-names
returns the `student_id` value. Both substitutions are in the SQL, so no download path can bypass
them.

### Education Researcher

#### RESOLVED: the failure mode the column rename was rejected for is back in a worse form

The first pass rejected naming these columns `teacher_school_districts` on the grounds that a
renamed column is only a hint, and chose live derivation so that index *i* means the same teacher in
all five columns. Two of the three findings above are that index *i* does not, and that where it
does, the district and state can describe different schools. Until they are fixed, the report makes
a stronger promise than the denormalized columns did while being wrong in a way that is harder to
notice: `Dist W` with `MA` looks like data, where `three districts against two names` at least looks
like a mismatch.

Nothing here argues against the live derivation. Both remedies keep it.

**Resolution**: closed by the two fixes above. Verified on the crossed fixture: all five teacher
columns carry one entry per listed teacher, and index *i* names the same teacher with a district and
a state that belong to the same school.

## Self-Review

Multi-role review of this spec, run after it was written. Roles: Senior Engineer, Security &
Privacy Engineer, QA Engineer, Database Engineer, Education Researcher, and API Consumer (cc-data).
Every issue below was checked against the code before being written down; candidates that did not
survive the check were dropped rather than recorded. Two that were dropped are worth naming so they
are not re-raised: ordering by a select alias under `GROUP BY rl.id` was probed and is accepted by
MySQL 8 with `ONLY_FULL_GROUP_BY` for every column both reports emit, including the web UI's
click-to-sort path; and `run_remote_endpoint` was checked for capability semantics and cleared (see
Technical Notes).

### Security & Privacy Engineer

#### RESOLVED: the hide-names invariant has no enforcement point outside the report form
The spec asserted that "non-admin, non-project-admin callers already have `hide_names` forced on at
run creation," and used that to conclude a researcher can never produce an un-anonymized run. The
claim is true today and false soon, which is the worst combination for a privacy control.

Verified: `maybe_enforce_hide_names/2` and `allow_hide_names?/1` are both `defp` in
`report_live/form.ex`, and a repo-wide grep finds no other caller or equivalent anywhere in `lib/`.
The `ReportRun` changeset casts `report_filter` and validates only `user_id` and `report_slug`, so
nothing at the persistence layer would reject a run stored with `hide_names: false` by a researcher.
REPORT-93 adds a create-run API endpoint, which by construction does not go through the LiveView and
cannot call a private function in it.

This matters more for this story than for any before it: `student-metadata` is the first
`type: :portal` report to emit student names, so it is the first place the Portal download path can
serve them. **Resolution**: the requirement is restated to name the invariant as a precondition
REPORT-93 must satisfy, and to require the enforcement be reachable from outside the LiveView rather
than left private to it.

### QA Engineer

#### RESOLVED: three Testing requirements specify assertions the suite cannot make
The Testing section asked for a row-count test "on a fixture where the underlying joins multiply
rows", a grain test, and a test pinning the hide-names username "to the value the Athena reports
produce". All three are result-level assertions.

Verified: no portal-report test executes SQL. All four are `ExUnit.Case, async: true` asserting on a
normalized SQL string, and `test/support/portal_dbs_stub.ex` stubs only `stream_query/4`, its
docstring stating it "deliberately does not stub `get_allowed_project_ids`/`query`". There is no
portal-DB fixture in the repo.

**Resolution**: the Testing section is split into SQL-shape tests and result-level tests, and a
Technical Note records what the result-level ones need. The gap turned out to be smaller than it
first appeared, which is why the tests are kept rather than dropped: `config/test.exs` already points
the app's Ecto repo at the same local MySQL 8 the repo's `docker-compose.yml` starts, and
`PortalDbs` takes a portal server's credentials from a `<SERVER>_DB` environment variable, so the
fixture is a schema named `portal` plus one variable.

#### RESOLVED: the project-admin scoping test is DB-backed by construction
The spec asked for a single SQL-shape test covering scoping "for a project admin, absent for a
super-admin, and constrained to zero rows for a caller with no allowed projects". The first of those
three cannot be DB-free.

Verified: `get_allowed_project_ids/1` returns `:all` for a super-admin and `:none` for a role-less
user with no query, but for `portal_is_project_admin` it runs `SELECT DISTINCT project_id FROM
admin_project_users …` against the portal. `ReportUtils.apply_allowed_project_ids_filter/5` calls
`ReportServer.PortalDbs.get_allowed_project_ids/1` by hardcoded module reference, with no
`Application.get_env` seam; the seam that does exist (`EndpointSet.allowed_project_ids_source/0`)
serves only the bulk path. The shipped `teacher_status_report_test.exs` avoids this deliberately,
with a comment noting the role-less user "returns `:none` with no portal-DB call".

**Resolution**: the project-admin case moved to the result-level list; the two DB-free cases stay as
SQL-shape tests.

### Senior Engineer / API Consumer (cc-data)

#### RESOLVED: the bulk-endpoint learner set is a subset of the report's rows, not "exactly" it
The spec claimed the learner set `/answers`, `/history` and `/attachments` derive "is exactly the set
of rows the report emits".

Verified false. `EndpointSet.to_endpoints/1` filters every derived endpoint, dropping any whose
`source` is `nil`, empty, or contains a `/`, with a comment explaining that such a source "would make
Node build a bad path and silently miss data". `derive_source/1` returns `nil` for a non-binary
`runnable_url`, and `external_activities.url` is nullable in the portal schema (`t.text "url"`, no
`null: false`), so the drop is reachable rather than theoretical; an `answersSourceKey` containing a
slash reaches it too.

**Resolution**: the requirement now states the set as the report's rows minus what `EndpointSet`
drops, and notes that the mapping report's `runnable_url` column is what lets a consumer identify
the affected rows. No change to either report is needed; the divergence belongs to the shipped
endpoint.

### Database Engineer

#### RESOLVED: the 1:1 join requirement was stated unconditionally, but the design cannot guarantee it
"The two reports join 1:1 on `learner_id` for any filter" is absolute, while the design collapses on
`GROUP BY rl.id`, the `report_learners` primary key. The two are equivalent only under an assumption
the resolved question on grain explicitly acknowledges is not enforced: the portal indexes
`learner_id` non-uniquely.

**Resolution**: the requirement is conditioned on the uniqueness property and paired with the grain
test that asserts it, so it states something testable instead of something assumed. This is a
wording fix, not a design change; the resolved decision to group on the primary key stands.

### Education Researcher

#### RESOLVED: two of the five teacher columns were not positionally aligned with the other three
The decision to source teacher metadata from the denormalized `report_learners` columns accepted one
divergence from the Athena reports (district and state enumerate every school a teacher belongs to,
rather than one). Checking the portal's generator showed that divergence has a second-order effect
the resolution missed: it breaks positional alignment *within this report*.

Verified in `rigse/rails/app/models/report/learner.rb`: `teachers_name`, `teachers_email` and
`teachers_id` are each `ts.map{ … }.join(", ")`, one entry per teacher. `teachers_district` and
`teachers_state` are `ts.map{ |t| t.schools.map{ … }.join(", ")}.join(", ")`, one entry per
*(teacher, school)* pair, flattened into the same flat list. Two teachers where one belongs to two
schools yields two names and three districts. The Athena reports do not have this problem: their
five columns all come from `array_join(transform(arbitrary(teachers), teacher -> teacher.<field>),
',')`, one entry per teacher, so index *i* is the same teacher in all five.

Why it matters: the whole reason for adopting the Athena column names was that a consumer could
treat the two report families interchangeably. A column that carries per-teacher values in one
family and per-school values in the other, under the same name, is worse than a differently-named
column, because the mismatch is invisible until a researcher pairs `teacher_names[i]` with
`teacher_districts[i]` and silently attributes a teacher to a colleague's district.

**Options considered**:
- A) Keep the three aligned columns under the Athena names, and emit the other two as
  `teacher_school_districts` / `teacher_school_states`, documented as per-school and not aligned.
  Parity is preserved where it is real and not claimed where it is not.
- B) Keep all five Athena names and document the caveat. Maximum concatenability, and the trap stays.
- C) Derive district and state per teacher with live joins, restoring true alignment, at the cost of
  the query complexity the resolved sourcing question declined.

**Decision**: **C**, after the project owner ruled that the per-teacher district is information
that matters. A was the original decision and its reasoning is kept below, because the probe that
drove it is the same evidence that now argues for C: the failure it demonstrates is real, and
renaming only made it less likely rather than impossible. What changed is the realization that A's
consolation prize, a set-level district, is not recoverable into the per-teacher answer by any local
post-processing, since the portal flattens the per-school and per-teacher lists with the same
separator and the grouping is lost.

C derives both columns per teacher from live joins and keeps the Athena names, so all five align.
The original comparison, which still stands as the argument against B:

The two options were compared empirically rather than argued, because the whole question is what a
consumer sees. cc-data unions report CSVs across runs with `UNION ALL BY NAME`, so both report
families land in one `reports` view; a DuckDB probe modelled one Athena-family row and one
Portal-family row for the same two teachers, where the first teacher belongs to two schools:

Under **B**, the two rows merge into one `teacher_districts` column and a consumer pairing
`teacher_names[i]` with `teacher_districts[i]` gets, for the same teacher "Bob Teach", `Dist Y` from
the Athena row and `Dist W` from the Portal row. `Dist W` is the *first* teacher's second school.
The answer is wrong, plausible, silent, and differs by which report the row came from.

Under **A**, the same union yields two columns and the Portal row's `teacher_districts` is `NULL`.
That is DuckDB's documented `UNION ALL BY NAME` behavior and precisely what the cc-data guidance
already teaches Claude to expect: "a column present in only some runs is NULL for the rows of runs
that lack it (not an error, no misalignment)." The mismatch becomes visible at the moment of the
union instead of surfacing as a wrong district in a results table.

Two further facts, both verified in `rigse/rails/app/models/report/learner.rb`, confirm these are not
the same kind of column as the other three and should not be dressed as if they were:

- A teacher with no school membership contributes an **empty entry** to the list, so the list can be
  shorter *and* contain blanks, not merely longer.
- Each field is assigned inside `update_field`, whose body is wrapped in a bare `rescue` that only
  logs. A teacher whose school has no district raises inside the block, so `teachers_district` is
  never assigned and stays `NULL` for that learner, while `teachers_name` and `teachers_email`,
  computed in their own `update_field` calls, populate normally. The Athena path has no equivalent
  failure mode: `get_teacher_map`'s `LEFT JOIN portal_districts` yields a `NULL` field inside a
  present row.

**Superseded by C, after the project owner's input.** A was chosen on the assumption that a
set-level district was worth keeping and that a consumer needing a per-teacher one could derive it.
Neither held:

- **The information is important**, so a column that answers "which districts appear" and cannot be
  attributed to a teacher is not a smaller version of the answer, it is a different and much weaker
  one.
- **It cannot be derived locally.** The flattening is lossy: `Dist X,Dist W,Dist Y` cannot be
  reassembled, because the portal joins the inner per-school list and the outer per-teacher list
  with the same separator, so the grouping is gone. `teacher_user_ids` gives the ids, but nothing in
  the report or in cc-data's local data maps those to districts.
- **A was mitigation, not a guard.** A renamed column is a hint; nothing stops a reader zipping it
  anyway, and when they do the answer is exactly as wrong as under B.

So the two columns are derived per teacher from live joins, keeping the Athena names, which is the
only option where the information exists in a usable form. Its costs are stated in the requirements:
a deterministic single-school pick per teacher, more query complexity, and a truncation guard.

**Verified on MySQL 8.0.39.** With two teachers where the first belongs to two schools, the
denormalized columns give three districts against two names; the derived ones give
`Dist W,Dist Y` against `Ann Teach,Bob Teach` and `31,32`, aligned. The naive DuckDB query a
consumer would write over the misaligned version pairs "Bob Teach" with the first teacher's second
district and emits a third row with a NULL teacher, padding silently rather than erroring.
