# Student ID Mapping and Student Metadata Portal Reports

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-91

**Status**: **Closed**

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

Compressed to what a future reader needs; the source spec carries the probes behind each.

- **A Portal report is one SQL statement.** Every consumer calls `get_query`, then `get_sql`, and
  runs the result: the API streams it, the web run executes it, the row count wraps it, the column
  sort rewrites its `order_by`. There is no seam for a second query or an Elixir post-processing
  pass, which is why `LearnerData.fetch/3` could not be the shared base and its `%ReportQuery{}`
  construction had to be extracted instead.
- **The denormalized `report_learners` columns already carry the teacher and permission-form values**
  `get_teacher_map` and `get_permission_form_map` rebuild, so neither helper had to be re-expressed
  in MySQL. The exceptions are `teachers_district` and `teachers_state`, which the portal writes one
  entry per *(teacher, school)* pair, so they do not align with the teacher list and are derived
  live instead.
- **`hide_names` translates into MySQL exactly, but not naively.** MySQL's `SHA1()` already returns
  lowercase hex, so `UPPER(SHA1(...))` matches Presto's `TO_HEX(SHA1(CAST(... AS VARBINARY)))` while
  `HEX(SHA1(...))` double-encodes. The salt literal needs its backslashes escaped for MySQL, which
  Presto does not need.
- **`DISTINCT` gives a wrong row count and `GROUP BY` gives the right one.** `get_count_sql/1`
  discards the select list, so a `DISTINCT`-based collapse is discarded with it: on a learner whose
  joins fan out to four rows the count returns 4, not 1. REPORT-105 measured the same fan-out on
  production at 6.11x. The grouping must also carry the joined tables' primary keys; see the
  decision on `ERROR 1055`.
- **`run_remote_endpoint` in SQL** is `CONCAT('https://<portal>/dataservice/external_activity_data/',
  COALESCE(pl.secure_key, ''))`, byte-identical to the Elixir construction including the
  trailing-slash form for a learner with no `secure_key`.
- **No LiveView work.** `tree.ex` is the only place a report is declared; the form, run and download
  views are generic over `%Report{}`. Registering the two reports is the whole of the wiring.
- **REPORT-105 and REPORT-106 interactions.** REPORT-105 split the learner query out of `fetch/3`
  into `build_query/2` and added `count/2` plus a partition estimate that calls it, so the extraction
  has three callers to keep working. Neither new report declares `enable_app_filter`, so a filter
  carrying `app` is rejected at submit and the submit-time learner count never runs for them.
  REPORT-106 was checked file by file and reaches nothing here: its run-page block is inside the
  `type: :athena` branch, and the `NOT_READY` body it extended is in `athena_download/2`, which
  `portal_download/4` is selected before and never reaches.
- **The suite had never executed portal SQL.** Every shipped portal-report test asserts on a
  generated string with a role-less user. `PortalDbs` resolves credentials from a `<SERVER>_DB`
  variable and hardcodes `database: "portal"`, so the fixture names a test-only portal server
  pointed at the MySQL the Repo already uses, and creates the database through a plain MyXQL
  connection because the pool cannot connect until it exists.
- **`run_remote_endpoint` is an identifier, not a capability.** The portal route it names resolves to
  a controller whose actions are both `head :ok`; holding the string reads and writes nothing, and
  the bulk endpoints derive their own authorized endpoint set from the run.

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

## Not Yet Implemented

- **A guard on malformed `teachers_id` input to `JSON_TABLE`.** The teacher district and state
  columns expand `rl.teachers_id` with `JSON_TABLE`, which raises `ERROR 3141` on anything that is
  not a bare comma-separated id list, failing the whole report rather than one row. The portal writes
  the column as `ts.map{|t| t.id}.join(", ")`, so the shape holds in practice; the failure mode is
  recorded rather than guarded, and a guard is the change to make if it is ever observed.
- **A live cross-check of `run_remote_endpoint` against a real Firebase record.** Out of scope by
  decision: the Firebase side is written by the data-service, outside both repos, and the same
  construction is already the shipped join key in the student-answers report.

## Decisions

Every question raised while specifying and reviewing this story, compressed to its rationale. The
source spec carries the probes and measurements behind each.

### Requirements decisions

#### How should Student Metadata name and shape its teacher columns?
**Context**: The ticket named a single `teachers` column; the Athena student-answers report emits five.
**Options**: one `teachers` column; five under the Athena names; five under new names.
**Decision**: Five under the Athena names, so the two report families concatenate and compare. A single column would need a serialization nothing else in the system reads, because MySQL cannot carry an array of structs the way Athena can.

#### Should the teacher and permission-form values come from the denormalized columns or a live re-query?
**Context**: `report_learners` caches them; reproducing `get_teacher_map` live needs `FIND_IN_SET` joins and `GROUP_CONCAT`.
**Options**: read the cache; read it and normalize the separator; rebuild live.
**Decision**: Read the cache and normalize the separator to `","` for ids, names, emails and permission forms; derive district and state live. The shared query already reads `student_name`, `username`, `class_name` and `school_name` from the same cache, so reading the rest is consistent rather than a new compromise. District and state are the exception because the portal writes them one entry per *(teacher, school)* pair, which does not align with the teacher list.

#### Should Student ID Mapping emit a `source` or `source_key` column?
**Context**: Listed as nice-to-have. A MySQL derivation reproduced `SourceKey.from_runnable_url/1` on the shapes probed.
**Options**: omit it; emit it; emit it and change the shipped derivation to match.
**Decision**: Omit. Nothing needs it (the bulk endpoints derive `source` server-side, and `remote_endpoint` alone is unique per learner), and the SQL derivation does not percent-decode where `URI.decode_query/1` does, so the column would be right almost always and quietly wrong occasionally, which is the worst property a join key can have.

#### What is each report's default row order?
**Context**: A deterministic order is needed so repeated runs agree and the streamed API CSV matches the web CSV.
**Options**: `learner_id` ascending; class then username; `runnable_url` then `learner_id`.
**Decision**: `learner_id` ascending for both. It is unique by construction, so the order is total rather than merely deterministic, and it makes the 1:1 join between the two reports line up row for row.

#### Should Student Metadata carry `class_id`, `offering_id`, `school_id` and `runnable_url` as well?
**Context**: The ticket had it emit `class` and `school` names but not their ids, so a consumer could not group by school without matching on a name string.
**Options**: add all four; add none; add `school_id` and `class_id` only.
**Decision**: `school_id` and `class_id` only. They remove a name-string join, which is the failure mode this story exists to eliminate. `offering_id` and `runnable_url` identify the assignment rather than the student context and are already in the mapping report.

#### Does `report_learners` guarantee one row per `learner_id`, and does it matter?
**Context**: `ONLY_FULL_GROUP_BY` forces grouping on the primary key rather than on `learner_id`, and the two are equivalent only under a uniqueness the schema does not enforce.
**Options**: assume it and test the grain; defend in the query with a subquery; check production data.
**Decision**: Assume and test. The portal models it as `has_one` and only ever creates one, so a duplicate is an anomaly rather than a supported state; defending would add a subquery layer to every run, and if duplicates existed the shipped `DISTINCT`-based query would already be collapsing them silently.

#### Should Student ID Mapping declare the `enable_hide_names` form option?
**Context**: The ticket said both reports set it, and that `hide_names` is a no-op for the mapping report.
**Options**: omit it there; declare it on both for consistency.
**Decision**: Omit. The option controls only whether the checkbox is shown, and only to admins; declaring it on a report where it provably changes nothing puts a privacy control in front of an admin that does not do what it appears to do. A test pins the no-op, since that claim is the whole justification.

#### Where does the extracted shared learner base query live, and what is its shape?
**Context**: The Portal reports need the filtered, user-scoped query that lived under `Athena`.
**Options**: a new neutral module taking the caller's select list; make the existing construction public on `LearnerData`; extract only the filter application.
**Decision**: A new `ReportServer.Reports.LearnerBaseQuery` taking `cols`. REPORT-105 had already made the construction public as `build_query/2` but left it under `Athena`, so the misfiling the ticket names was real and shipped. Extracting only the filters would leave the join set duplicated in three places, and the join set is what determines the row multiplication and the scoping.

#### How is `run_remote_endpoint` rendered when `secure_key` is `NULL`?
**Context**: `CONCAT` with a `NULL` argument yields `NULL`; the Elixir construction yields a trailing-slash string.
**Options**: let it be `NULL`; match the Elixir string; exclude those learners.
**Decision**: Match, via `COALESCE(pl.secure_key, '')`. Byte-identity with the Athena reports has to hold for every learner. Excluding them would silently drop rows from a roster report to tidy up an anomaly.

#### Should `last_run` be formatted, and how do datetimes render in the CSV?
**Context**: `report_learners.last_run` is a MySQL `DATETIME`.
**Options**: cast in SQL; leave it to the driver and document the shape.
**Decision**: Cast. MyXQL decodes it to a `NaiveDateTime` that the Portal CSV encoder renders with a space, while the Athena reports emit a `T`; `DATE_FORMAT(rl.last_run, '%Y-%m-%dT%H:%i:%s')` reproduces the Athena string exactly and leaves `NULL` as an empty cell.

### Decisions from the first review pass

#### The hide-names invariant had no enforcement point outside the report form
`maybe_enforce_hide_names/2` and `allow_hide_names?/1` were private to the form LiveView, with no other caller anywhere, and nothing at the persistence layer would reject a run stored with `hide_names: false` by a researcher. This report is the first `type: :portal` report to emit a student name, so the rule moved to `ReportServer.Reports.HideNames`, reachable by the create-run endpoint REPORT-93 adds.

#### Three testing requirements specified assertions the suite could not make
No portal-report test executed SQL, and there was no portal-DB fixture. The Testing section split into SQL-shape and result-level tests, and the story delivers the fixture rather than deferring it: `config/test.exs` already pointed at a local MySQL, so the gap was one schema and one environment variable.

#### The project-admin scoping test is DB-backed by construction
`get_allowed_project_ids/1` queries the portal for that role, and `ReportUtils` calls `PortalDbs` by hardcoded module reference with no seam, so that case moved to the result-level list while the two DB-free cases stayed SQL-shape.

#### The bulk-endpoint learner set is a subset of the report's rows, not exactly it
`EndpointSet.to_endpoints/1` drops any learner whose derived `source` is nil, empty, or contains a slash, and `external_activities.url` is nullable, so the drop is reachable. The requirement states the set as the report's rows minus what the endpoint drops, and notes that `runnable_url` is what lets a consumer identify those rows.

#### The 1:1 join requirement was stated unconditionally
The design collapses on the `report_learners` primary key, which equals a per-`learner_id` grain only under an assumption the schema does not enforce. The requirement is now conditioned on that property and paired with a test that asserts it.

#### Two of the five teacher columns were not positionally aligned with the other three
The portal writes `teachers_district` and `teachers_state` one entry per *(teacher, school)* pair while the other three are one per teacher, so a consumer pairing `teacher_names[i]` with `teacher_districts[i]` would silently attribute a teacher to a colleague's district. Renaming the two columns was chosen first and then reversed: the per-teacher district is information that matters and cannot be recovered locally, because the portal flattens the inner and outer lists with the same separator. Both columns are derived from live joins instead, keeping the Athena names.

### Decisions from the second review pass, run against a live MySQL 8

#### A caller with zero allowed projects got `ERROR 1055`, not a header-only CSV
The project scoping emits `1 = 0`; MySQL then discards the joined tables as an impossible `WHERE`, and `ONLY_FULL_GROUP_BY` rejects the select list. Both surfaces failed: `PortalDbs.query/4` returned an error and `stream_query/4` raised. The grouping is now `rl.id` plus the primary key of every joined table the select list reads (`u.id`, `ea.id`, `pl.id`), which satisfies the dependency through the grouping columns themselves. The shipped Athena query is unaffected: it collapses with `DISTINCT` and no `GROUP BY`.

#### For a teacher in more than one school, the district and state could come from different schools
`MIN(pd.name)` and `MIN(pd.state)` are independent aggregates, so a teacher in `Dist W` (NH) and `Dist Y` (MA) was reported in `Dist W`, `MA`, a pair that exists nowhere in the data. The school is now chosen once with `ORDER BY ps.id LIMIT 1` and both fields read from that row, so coherence holds by construction rather than by two aggregates agreeing.

#### The alignment contract failed for a teacher with no school and for a stale teacher id
`GROUP_CONCAT` skips NULLs, and the subquery was driven by `portal_teachers`, so a teacher with no school membership and an id with no teacher row both vanished from the list rather than holding an empty position: three names against one district. The lists are now driven from `teachers_id` itself through `JSON_TABLE`, with `COALESCE` keeping the position.

#### The two teacher columns were dependent subqueries re-executed per row
`EXPLAIN` showed a full scan of `portal_teachers` and `portal_school_memberships` with a hash join, per outer row, twice. The rewrite keys the lookup on `psm.member_type` and `psm.member_id`, which production indexes as `member_type_id_index`, so the plan is a `ref` lookup and the per-row cost is bounded by the teachers on one class.

#### The scoping case that fails was listed as a SQL-shape test
A string assertion is exactly what passed while the server rejected the statement, which is how the `ERROR 1055` defect survived the first pass. The zero-project case moved to the result-level tests, executed on both surfaces and for both roles that reach the clause: a role-less user (`:none`, no portal query) and a project admin whose lookup returns `[]`.

#### The truncation guard needed a mechanism, and one of the two options does not exist
`SET SESSION` is a second statement, which the one-statement contract forbids, and it would leak across the pooled connection. The per-statement hint `SELECT /*+ SET_VAR(group_concat_max_len=...) */` works and leaves the session value untouched, so the metadata report raises the ceiling for its own statement. `num_warnings` is available on `%MyXQL.Result{}` and is asserted as a test rather than used as the mechanism.

#### The tree-consistency test the spec leaned on cannot fail for either new report
It asserts only inside a branch that any report carrying learner-narrowing `include_filters` skips, so both new reports pass through it untouched. The claim is kept as a fact and no longer offered as coverage; the API-surface test this story adds is what pins the two reports.

#### The hide-names findings and hash parity were re-verified on the post-REPORT-105 base
Both functions were still private in the form, and the salt-escaping divergence reproduced exactly. Hash parity was executed rather than compared as strings: `UPPER(SHA1(CONCAT('<salt>', rl.username)))` returns the same digest as `:crypto.hash(:sha, salt <> username) |> Base.encode16()`.

### Implementation decisions

#### The extraction test called something the step did not define
A module attribute is compile-time and not callable from another module, and copying the sixteen columns into the test would prove that a copy equals a copy. `LearnerData` gained a `learner_cols/0` accessor so the test passes the real list.

#### The extraction is byte-identical on the post-REPORT-105 base
Re-run after the rebase, since REPORT-105 changed what the extraction moves: the SQL `LearnerBaseQuery.build/4` produces was diffed against `LearnerData.build_query/2`'s across three filter shapes and two roles, and all six statements matched.

#### `{:ok, skip: true}` from `setup_all` does not skip anything
ExUnit does not skip on a context key, so the tests ran and failed on the connection, which is the failure mode the mechanism was meant to prevent. The harness uses `@moduletag :portal_db` with the exclusion decided at boot in `test_helper.exs`.

#### The fixture cannot bootstrap itself, and its reachability gate was not a gate
`PortalDbs.has_db_connection?/1` only checks that the environment variable is set, so it returns true on a machine with no database running. And `PortalDbs` hardcodes `database: "portal"`, so its pool cannot connect until that schema exists and the fixture's own `CREATE DATABASE` cannot go through it. `reachable?/0` runs a real query, and the database is created through a plain MyXQL connection.

#### The salt escaping broke hide-names parity for a salt containing a backslash
MySQL treats a backslash inside a string literal as an escape character and Presto does not, so escaping only the quotes silently changes what gets hashed: the two spellings produce different digests with no error, and the symptom is that hidden usernames from the two report families stop joining. `LearnerHideNames` escapes backslashes before quotes.

#### The grouping lives on the base query, not in both reports
Both reports needed the same grouping string, and two copies that must agree is the shape this repo's reviewers flag. The value is determined by the base query's join set, so `LearnerBaseQuery.group_by/0` owns it, with a test asserting the value and that every alias in it is one the base actually joins.

#### `AthenaConfig.get_hide_username_hash_salt/0` crashed outside prod
`:athena` is configured under `config_env() == :prod` and in `dev.exs` only, so the getter ran `Keyword.get(nil, ...)` the first time a test reached it, which the metadata report does through `LearnerHideNames`. It now defaults the missing config the way the log-projection getters beside it already do.

#### Each report needs two test files
The result-level tests are `async: false` (they share one portal database and one global salt) and tagged `:portal_db` so they are excluded when that database is unreachable, while the SQL-shape tests stay `async: true` and DB-free. Splitting by module is what lets both properties hold.

#### The form calls the hide-names rule directly rather than through delegations
Leaving one-line private delegations in the LiveView would keep a local name that no longer carries logic and could drift from the shared rule, so all four sites that build a filter from form params call `HideNames` directly.
