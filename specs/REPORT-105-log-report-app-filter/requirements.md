# Log Reports: Optional Application Filter and Date-Range Warning

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-105
**Repo**: https://github.com/concord-consortium/report-service
**Implementation Spec**: [implementation.md](implementation.md)
**Status**: **In Development**

> The Jira ticket is the authoritative scope and carries the production measurements, the rejected
> alternatives, and the fit with REPORT-92/93. This spec does not repeat them. It records what the
> code dive and the throwaway SQL harness added: three corrections to the ticket's stated premises,
> one security requirement the ticket does not raise, and the decisions those force.

## Overview

Add an optional application filter to the two log reports that read `logs_by_app_and_secure_key`, so
the generated Athena SQL constrains the `app` partition instead of enumerating all fifteen projected
values per learner, and warn the researcher when the projected partition count makes a run unlikely
to finish.

## Project Owner Overview

A log report over an assignment with a few hundred learners cannot be run today. It either fails
outright with a partition-limit error or times out after thirty minutes, and in both cases the
researcher sees the word "Failed" with nothing to act on. The cause is that the query tells Athena
which learners to look at but not which application's logs, so Athena probes every application, year
and month combination for every learner.

This story adds a dropdown letting the researcher say which application they want, which turns those
runs from impossible into seconds, and a warning that tells them before they wait when the filter
they have built is too broad to complete. Both are additive: leaving the dropdown blank produces
exactly the query the server produces today, so no existing report changes behavior.

## Background

`ReportQuery.get_athena_query/3` (`server/lib/report_server/reports/report_query.ex:91-131`) emits
one partition predicate, `log.secure_key IN (...)` (line 121). `apply_date_range/3`
(`report_query.ex:156-189`) adds `year`/`month` bounds only when the researcher set a date range.
`Clue.answer_sql/1` (`server/lib/report_server/clue.ex:204-207`) already constrains
`"log"."app" = 'CLUE'` and a `year` floor, with a comment at `clue.ex:236-243` describing this exact
failure mode.

The `app` projection is fifteen enum values, verified in the DDL at `server/README.md:240`:
`Activity_Player, CEASAR, CLUE, CODAP, CollabSpace, Dataflow, DEVOPS, GeniStarDev, GRASP,
HASBot-Dashboard, IS, LARA-log-poc, none, portal-report, rigse-log`. `year` projects 2014 to 2050
(37 values, `README.md:244`) and `month` 1 to 12 (`README.md:248`), so an unbounded query expands to
15 x 37 x 12 = 6,660 partition prefixes per learner and reaches Athena's 1,000,000 partition ceiling
at about 150 learners. The "when new applications are added these tables need to be recreated" note
is `README.md:209`.

`ReportFilter` (`server/lib/report_server/reports/report_filter.ex:8-12`) has no application
dimension in either the struct or `@valid_filter_types`.

### What the code dive corrected

Three of the ticket's stated premises did not survive the dive. Each changes what the story has to
build.

**The learner count is not in hand at submit time.** The ticket says `LearnerData.fetch/3` runs
before the Athena query is built, so the count is available when the researcher submits. It runs
later than that. `submit_form` (`server/lib/report_server_web/live/report_live/form.ex:214-238`)
creates the run and redirects; it never touches learner data. The fetch happens on the run page,
asynchronously: `show.ex:48` schedules `run_report/5`, which for an Athena run with no query id calls
`AthenaRunOps.start_query/1` (`show.ex:176-186`), which calls `report.get_query.()`
(`athena_run_ops.ex:18`), which is where `LearnerData.fetch_and_upload/2` finally runs
(`student_actions_report.ex:9`). By then the run row exists and the next step submits to Athena. So
the acceptance criterion "before the run is created" requires a **new** portal count query in
`submit_form`, not a reuse of work already being done. See the open question below.

**The value is interpolated, so it must be validated, not just quoted.** The prototype emitted
`log.app = 'CL'UE'` for the value `CL'UE`, breaking out of the string literal. `get_athena_query/3`
interpolates without escaping, in keeping with the rest of the module. Single-quoting is therefore
not sufficient on its own: the submitted value must be checked against the enum allowlist and
anything else rejected, server-side, in the query builder and not only in the form.

**`ReportFilterQuery` is not involved.** `app` is a static enum with no portal lookup, no project
scoping and no cascading, so it does not go through the filter-option machinery the ten existing
dimensions use. It is a plain form control like the date range, not an eleventh entry in
`@valid_filter_types`.

### What the throwaway harness verified

A prototype adding `app: nil` to the struct and an `apply_app/2` clause to `get_athena_query/3` was
built, run against a stub learner set, and deleted. It established:

- With `app` nil **or** the empty string the emitted SQL is byte-identical to the captured
  pre-change baseline, both with and without a date range. The empty-string case matters because an
  unselected HTML `select` submits `""`, not nil.
- With `app` set, exactly one `log.app = '<value>'` predicate is added, and because `get_sql/1`
  reverses the `where` list (`report_query.ex:18`) it lands immediately before the `secure_key`
  predicate, keeping the two partition predicates adjacent:
  `WHERE (log.app = 'CLUE') AND (log.secure_key IN ('KEY1','KEY2'))`.
- `EctoReportFilter.load/1` (`server/lib/report_server/types/ecto_report_filter.ex:12-18`) uses
  `struct!/2`, which fills defaults for absent keys. A `report_filter` row stored before this change
  loads with `app: nil`, so no migration or backfill is needed. The same `struct!/2` raises
  `key :app not found` on a stored key the struct lacks, which is the constraint on ever *removing*
  the field, not on adding it.
- `ReportQuery.get_log_db_name/0` (`report_query.ex:133-135`) uses `Keyword.get/3` and raises when
  the `:report_server, :athena` application env is unset, which it is in the test environment. Any
  new test of `get_athena_query/3` must set that env, following
  `test/report_server/reports/athena/shared_queries_test.exs:24`.

A second pass took the assumptions that had been reasoned to rather than run and ran them:

- **The corrected `period_months` count matches the real predicate.** The date clauses were emitted
  by `apply_date_range/3` itself, loaded into a MySQL table holding all 444 projected
  `(year, month)` pairs, and counted. The results are exactly the corrected arithmetic: no range 444,
  2024-09-01 to 2025-06-30 **10**, 2023-09-01 to 2025-06-30 **22**, a single month 1, and an
  inverted range 0. The ticket's `years x months` reading gives -4 for the two multi-year cases.
- **A filter carrying `app` survives a real database round trip.** A `%ReportFilter{app: "CLUE"}` was
  inserted through `Reports.create_report_run/1` and read back through
  `Reports.get_report_run_with_user!/1` with `app` intact, confirming the JSON column needs no
  migration and no backfill.
- **`report_filter_json/1` does not pick the field up on its own.** The same round trip showed the
  serialized key set unchanged and `app` absent: the map is built explicitly (`report_json.ex:40-52`)
  from `@id_dimensions` plus named scalars, so the field must be added by hand. This is what
  `@filter_keys` (`report_controller_test.exs:12-13`) will catch if it is missed.

## Requirements

### The filter

- `ReportFilter` gains an `app` field defaulting to `nil`. It is **not** added to
  `@valid_filter_types` and **not** added to `@id_dimensions` in `report_json.ex:6`; it is a scalar,
  value-typed dimension serialized the way `state` is (`report_json.ex:44`).
- `ReportFilter.from_form/2` reads it. The numbered filters are collected by the reduce at
  `report_filter.ex:19-29`, but every scalar is copied across by an explicit `Map.put` at
  `report_filter.ex:32-35`; without a fifth `Map.put` for `app` the field stays `nil` no matter what
  the form submits, and every test that goes through the struct directly would still pass.
- Blank (`nil` or `""`) means today's behavior. The generated SQL must be byte-identical to the
  pre-change output for the same filter, verified against a captured baseline rather than asserted
  by shape.
- Set, it adds exactly one predicate, `log.app = '<value>'`, to the `where` list in
  `get_athena_query/3`. Nothing else changes.
- The submitted value must be validated against the allowed-value list in the query builder. A value
  not in the list is an error, not a silently dropped predicate: dropping it would produce the
  timeout the story exists to prevent, while reporting it makes a stale form or a hand-built API
  body visible. The error takes `get_athena_query/3`'s existing `{:error, message}` shape
  (`report_query.ex:129`) rather than raising, so it surfaces to the researcher the way "No learners
  found to match the requested filter(s)" already does.
- A filter carrying `app` for a report that does not declare the application filter is also an error,
  rejected where the filter is built rather than where it is consumed. The query-builder check alone
  cannot see this case: `get_athena_query/3` is reached only from the two student-actions modules, so
  an `app` on `teacher-actions` or a Portal report is stored, serialized and silently ignored, which
  is the outcome the rule above exists to prevent. It is also visible, because the run page and the
  runs list both render the filter summary for every report type and would show an Application row
  for a filter that was never applied. A blank `app` stays acceptable on every report, including the
  ones with no control. REPORT-93's create endpoint honors the same rule.
- A test asserts the Elixir list still agrees with the DDL. The ticket asked for this only "if the
  DDL is ever checked into the repo in machine-readable form"; it already is. Both DDL blocks in
  `server/README.md` (`:240`, `:284`) carry `'projection.app.values'='...'` in a single parseable
  line, and the two are currently byte-identical, so the test can assert the Elixir list against
  every occurrence and catch the two blocks drifting from each other as well.
- The same holds for the year and month ranges, and for the same reason. `'projection.year.range'`
  (`README.md:244`, `:288`) and `'projection.month.range'` (`:248`, `:292`) are declared in the same
  two blocks in the same parseable form, and they are what produce the 444 that every partition
  estimate is built on. They live beside the application list, in one place, with the same agreement
  test, rather than being restated as literals in the estimate.
- The allowed-value list lives in one place, read by the form, the query builder and the validation.
- The `{id, label}` pairs are server-owned and come from the same place, not from the template. The
  raw enum value is the id; the label is the value except for `none`, which carries its explanatory
  wording. REPORT-92's static-dimension work consumes this function directly, so the web form and
  every API client render the vocabulary identically from one definition rather than each restating
  it. This is the only thing REPORT-92 needs from this story besides the wire name `app`.
  Today the list is duplicated between the two DDL blocks in the README (`README.md:240` and
  `README.md:284`) and nowhere in Elixir, so this story introduces the single source and a comment
  naming the DDL it must agree with. `README.md:209`'s "when new applications are added" note gains
  this list as a second thing to update.

### Where the control appears

- Only `student-actions` and `student-actions-with-metadata`, the two reports that read
  `logs_by_app_and_secure_key`. `teacher-actions` reads `logs_by_time`
  (`teacher_actions_report.ex:35`), which has no `app` partition, and must not show the control.
- Gating follows the existing `form_options` mechanism (`report.ex:5`, `tree.ex:175`, `tree.ex:182`),
  the same way `enable_hide_names` is gated, rather than a slug check in the template.
- The control renders in the same block as the date range and hide-names controls
  (`form.html.heex:86-101`), which is shown only once a first filter has a value.
- The control carries a programmatic label. `.input type="select"` renders
  `<.label for={@id}><%= @label %></.label>` (`core_components.ex:334`), but both `id` and `label`
  default to `nil` (`core_components.ex:271`, `:273`), so the existing filter-type select
  (`form.html.heex:42-46`) renders an empty label element and no accessible name. The new control
  passes both rather than copying that.
- The warning is a status message and must be announced. It appears asynchronously, after the click,
  on a page that has not otherwise changed, and it reports that the run was not created. The
  existing error area (`form.html.heex:119-120`) is a plain div with no `role` and no `aria-live`, so
  reusing it unchanged would leave a screen reader user with no announcement that the submit did not
  happen and none that the button is disabled. WCAG 2.2 SC 4.1.3.
- The blank option and the `none` value must read as different things. `none` is a real application
  value meaning "the log rows recorded no application" (`partitioner/src/index.js:26`), and a bare
  `none` sitting next to an unlabeled blank option reads as a second way to say "no filter", which
  would silently return the wrong rows. Use the component's `prompt` attribute
  (`core_components.ex:286`) for the blank option with wording that names the effect ("All
  applications"), and label the enum value as something like "none (no application recorded)". The
  submitted values stay the raw enum strings; only the display labels differ.

### Surfacing it

- `report_filter_json/1` includes `app`, so it appears on `GET /api/v1/reports/:id` and in the runs
  list. It is serialized through the same `presence/1` the dates use, so a blank filter reports
  `null` rather than `""`. An unselected `select` submits `""`, exactly as an untouched date input
  does, and the two must not disagree about how they report "not set".
- The run page's filter summary shows the selected application. `report_filter_values/1`
  (`custom_components.ex:253-279`) renders the numbered filters from `@report_filter.filters` and
  then a fixed row per scalar; `app` needs its own row alongside Start Date and End Date, and it must
  be absent when blank, matching those rows.
- `report_filter_values` (the resolved-label map) needs no entry: the label is the value, so
  `ReportFilter.get_filter_values/2` is untouched. This is what the ticket means by REPORT-93's
  server-derived-label rule holding trivially.

### The date-range warning

- `learners` is the count of **distinct** learners the report would include, matching what
  `LearnerData.fetch/3` would return for the same filter. This is a statement about what the
  warning means, not only about how it is built: the learner join fans out (it carries
  `LEFT JOIN portal_runs`, `learner_data.ex:53`), so a naive row count over it counts one row per
  learner run and overestimates without bound.
- The projected partition count is `learners x apps x period_months`, where `apps` is 1 when the
  application filter is set and 15 otherwise, and `period_months` is **the number of `(year, month)`
  pairs the emitted date predicate admits**, not `years x months`.
- `period_months` must be derived the same way `apply_date_range/3` (`report_query.ex:156-189`)
  emits its bounds, because the ticket's `years x months` reading is wrong for any range that does
  not start in January and end in December. Enumerating the predicate shows why: for
  2024-09-01 to 2025-06-30 the predicate admits 10 pairs, while `years x months` computes
  `2 x (6 - 9 + 1)` = -4; for 2023-09-01 to 2025-06-30 it admits 22 against a computed -4. A
  negative or zero count never crosses the threshold, so the warning would silently never fire on
  exactly the multi-year ranges it exists for. With no date range the two agree at 37 x 12 = 444,
  which is why the ticket's headline numbers (15 x 444 = 6,660 prefixes per learner, a ceiling near
  150 learners) are right and reproduce exactly.
- A range whose end precedes its start admits zero pairs. The warning must treat that as "no
  partitions" rather than dividing by it or reporting a negative count.
- The count runs at submit, before the run is created, so the warning precedes the run rather than
  appearing on one that already exists. It is computed asynchronously: `PortalDbs.query/4` is
  synchronous with a five-minute timeout (`portal_dbs.ex:9`) and must not block the click handler.
- Warn when the count exceeds Athena's 1,000,000 limit or a lower configurable threshold. The
  message names the learner count and shows the arithmetic.
- Warn, do not block. The researcher may know something the arithmetic does not.
- The threshold is configuration with a default, not a literal, so it can be lowered without a
  deploy of new code.

### Tests

Each test below names the mutation it catches.

- Blank filter produces SQL byte-identical to a captured baseline, with and without a date range.
  Catches an `apply_app/2` clause that emits an empty or always-true predicate when unset.
- Empty string behaves as blank. Catches a `nil`-only guard, which is what the form actually submits
  against.
- A set filter adds exactly one `log.app` predicate, asserted by counting occurrences rather than by
  `=~`. Catches a predicate emitted once per learner or once per runnable URL.
- A value outside the allowed list is rejected. Catches validation that lives only in the form.
- The control is absent from `teacher-actions` and present on both student log reports. Catches
  gating that keys off the wrong thing.
- `@filter_keys` in `test/report_server_web/api/v1/report_controller_test.exs:12-13` gains `app`.
  That test asserts the exact key set of the serialized filter, so it fails loudly if the field is
  added to the struct but not to `report_filter_json/1`, and it must be updated deliberately rather
  than by deleting the assertion.
- The app list agrees with every `projection.app.values` in the README, and the number of DDL blocks
  found is asserted first. Without that count, a README edit removing the property would leave
  nothing to compare and the test would pass while asserting nothing.
- The partition-count arithmetic is asserted at the boundary: just under the threshold does not warn,
  just over does. Catches an off-by-one and a warning that fires on every run.
- `period_months` is asserted for a partial-year range (2024-09-01 to 2025-06-30 is 10) and a
  multi-year one (2023-09-01 to 2025-06-30 is 22), not only for the no-range case. The no-range case
  alone cannot distinguish the correct count from `years x months`, since both give 444.
- `from_form/2` populates `app` from the submitted params. Catches the field being added to the
  struct, the JSON and the query builder while the form silently never sets it, which every
  struct-level test would miss.
- The serialized `app` is `null` for a filter carrying `""`, asserted on a filter built with `""`
  rather than on a default-built struct. Catches the omission of `presence/1`, which a
  default-built struct cannot, because the struct default is already `nil`.
- A filter carrying `app` submitted against a report without the application filter creates no run.
  Catches validation that only ever runs inside the query builder.
- A submit whose partition count succeeds leaves the form alive. Catches the message plumbing around
  the count task dropping a message and crashing the LiveView, which no test of the arithmetic can
  see.
- The projected year and month ranges agree with every declaration in the README. Catches the 444
  drifting out from under every estimate when the DDL changes.

## Technical Notes

- The `app` partition value is the **sanitized** application string. `sanitize()`
  (`partitioner/src/index.js:169-171`) maps null or empty to the literal `none` (`index.js:26`) and
  replaces every character outside `[a-zA-Z0-9_-]` with `_` before using it as the partition
  directory (`index.js:190-191`). So the enum values in the DDL are already in sanitized form and the
  filter compares against them directly; there is no un-sanitized display form to map back from.
- `none` being a real projected value is why the filter is optional rather than defaulted. A run
  whose rows landed under `none` would silently return nothing if the form defaulted to any named
  application.
- Adding the field changes what `EctoReportFilter.dump/1` writes for every new run (`app` is now a
  key in the stored map). That is forward-compatible by the `struct!/2` behavior above, and it is why
  the field must not later be renamed without a data migration.
- The API has no create endpoint today (`router.ex:60-71` is read-only for reports), so "accepted by
  the REPORT-93 create endpoint" is a coordination note for that story, not code here. The wire name
  is `app`, fixed by this story, and REPORT-93 consumes it.

## Out of Scope

- **A generic year floor.** `Clue.year_floor/1` (`clue.ex:244-254`) derives from learner
  `created_at` and is CLUE-specific. The existing date range already prunes `year` and `month`; a
  generic floor needs its own design.
- **Serving `app` from the REPORT-92 discovery endpoint.** There is nothing here to extend:
  `POST /reports/filter-options` exists only in REPORT-92's spec, `router.ex:60-71` has no such route
  on `master`, and REPORT-92 is `To Do` with implementation not scheduled before REPORT-105 ships.
  Building it inside this story would mean building REPORT-92's endpoint. Decided 2026-09-04: the
  discovery work lives in REPORT-92, which now specifies a **static dimension** kind rather than a
  special case for `app`, on the expectation that other non-portal dimensions follow. What this
  story owes it is below.
- **Deriving the application from `runnable_url` or `external_activities.tool_id`.** Rejected in the
  ticket, with the reasons; recorded here so they are not re-proposed.
- **The pre-existing interpolation of `state` filter values.** `report_filter.ex:65` interpolates
  state strings into portal SQL without escaping, reached from `get_filter_value/2`
  (`form.ex`-side, `report_filter.ex:102-111`), which does not coerce `:state` values. That is the
  same class of issue as the one this story must avoid for `app`, but it is a separate surface, a
  separate database and a pre-existing condition. It should get its own ticket rather than widen
  this one.
- **`logs_by_app`.** The third table in the README (`README.md:257`) is not read by any report module
  in the server.

## Open Questions

### RESOLVED: Where does the partition-count warning live, given the learner count is not free at submit?

**Context**: The acceptance criterion says the warning appears "before the run is created", but the
code dive established that no learner data has been fetched at that point (`form.ex:214-238` creates
the run and redirects; the fetch happens later, from `AthenaRunOps.start_query/1`). Producing a
count at submit time means a new portal round-trip against the `report_learners` join in
`LearnerData.fetch/3` (`learner_data.ex:24-132`), wrapped in `ReportQuery.get_count_sql/1`
(`report_query.ex:31-36`). That query is the expensive part of the report's portal half, and the
warning is advisory. This is a genuine trade between an extra wait on every log-report submit and
warning later than the criterion asks for.

One further fact narrows it: `AthenaRunOps.start_query/1` is shared by the web run page
(`show.ex:177`) and the API (`report_controller.ex:40` and `:59`, via `ensure_current/1`). A warning
raised there has no user to confirm it on the API path, so option B means either warning-and-
proceeding (which is not a confirmation) or diverging the two paths. Option A leaves `start_query/1`
untouched.

**Options considered**:
- A) Count at submit. Add a count-only portal query to `submit_form`, show the warning, and require a
  second click to proceed. Matches the acceptance criterion exactly. Costs one portal round-trip on
  every log-report submit, including the small ones that never had a problem.
- B) Warn on the run page, before the Athena query is submitted. `start_query/1` already has the real
  learner list in hand, for free. The run row exists by then, so the warning would appear on a run
  that is about to start rather than before it is created, and the shared API path has no user to
  confirm it.
- C) Count at submit, but only when the filter looks risky (no date range, or an assignment filter
  with no class/student narrowing), so the common small run pays nothing.

**Decision**: A, count at submit (decided 2026-09-04). It is the only option that satisfies the
acceptance criterion as written, and the cost turned out to be smaller than the question assumed.
Generating both SQLs from the same filter shows the count query is the fetch query with a different
select: identical from `FROM` onward, the same seven joins and the same `WHERE`, differing only in
`COUNT(DISTINCT rl.learner_id)` against sixteen columns, and skipping the two follow-up lookups
(`get_teacher_map/2`, `get_permission_form_map/2`) the full fetch performs. So the extra work is a
strictly cheaper duplicate of a query the run executes moments later, paid only on log reports with
the application filter enabled, and it leaves the API-shared `start_query/1` path untouched.

C was rejected rather than deferred. Its appeal is that small runs pay nothing, but it adds a second,
fuzzier definition of "risky" beside the exact arithmetic. The partition formula has already proven
easy to get wrong once; introducing a heuristic whose job is to avoid computing it invites the two to
disagree, and the disagreement would be silent.

### RESOLVED: Does this story extend the REPORT-92 discovery endpoint for `app`?

**Decision**: No, and this needed no call: there is nothing to extend. `POST /reports/filter-options`
exists only in REPORT-92's spec on an unlanded branch, `master`'s `router.ex:60-71` has no such
route, and REPORT-92 is `To Do` in Jira with implementation not scheduled before REPORT-105 ships
(sprint plan: 105 implements Sep 4; 92's own implementation is not in the plan ahead of it). Doing it
here would mean building REPORT-92's endpoint inside REPORT-105. Recorded in Out of Scope with the
action that carries it: `app` goes into REPORT-92's spec as an eleventh, non-portal dimension while
that story is still open, and 92's "ten dimensions" wording is fixed there.

### RESOLVED: Is an unrecognized application value an error or a silently-ignored filter?

**Decision**: Error, returned as `{:error, message}` from `get_athena_query/3`. The codebase already
treats an out-of-vocabulary filter value this way: `get_filter_type!/2` (`report_filter.ex:96-98`)
rejects a filter type outside `@valid_filter_types` rather than dropping it. Silently ignoring the
predicate would produce exactly the thirty-minute timeout this story exists to prevent, and would do
it invisibly. The one argument for ignoring, that the Elixir list and the recreated Glue table can
disagree for the length of a deploy (`README.md:209`), is already answered by the ticket's own
requirement that the list live in application config: the disagreement is closable by configuration,
without a code release. `raise` is the wrong shape here even though it is what `get_filter_type!/2`
uses, because `get_athena_query/3` returns error tuples (`report_query.ex:129`) and the researcher
should see this the way they see "No learners found to match the requested filter(s)".

## Self-Review

Roles: Senior Engineer, Performance Engineer, WCAG Accessibility Expert, Education Researcher, QA
Engineer. Each finding below was checked against the code before being written; one candidate did
not survive and is recorded at the end.

### Senior Engineer

#### RESOLVED: `app` would never leave the form

The spec had the struct gaining the field, the form gaining a control, and the query builder gaining
a predicate, with nothing connecting them. `ReportFilter.from_form/2` collects the numbered filters
in a reduce (`report_filter.ex:19-29`) but copies every scalar across with an explicit `Map.put`
(`report_filter.ex:32-35`, four of them today). Without a fifth for `app` the field is always `nil`
in production while every test that builds a `%ReportFilter{}` directly still passes. Added as a
requirement and as a named test.

### Performance Engineer

#### RESOLVED: the partition-count formula never fires on the ranges it exists for

The ticket specifies `learners x apps x years x months`. Enumerating the `(year, month)` pairs that
`apply_date_range/3` (`report_query.ex:156-189`) actually admits shows that reading is wrong for any
range not aligned to whole calendar years: 2024-09-01 to 2025-06-30 admits 10 pairs against a
computed `2 x (6 - 9 + 1)` = -4, and 2023-09-01 to 2025-06-30 admits 22 against the same -4. A
negative count never crosses a threshold, so the warning would be dead code for precisely the
multi-year cohort ranges that motivated the story, while still appearing to work in tests. The two
readings agree only when no date range is set (37 x 12 = 444), which is the case the ticket's
headline numbers were derived from, and those reproduce exactly. Requirement rewritten to count
admitted pairs, with tests naming the partial-year and multi-year values.

### WCAG Accessibility Expert

#### RESOLVED: the new select would have no accessible name

`.input type="select"` renders `<.label for={@id}><%= @label %></.label>` (`core_components.ex:334`),
but `id` and `label` both default to `nil` (`core_components.ex:271`, `:273`), so the existing
filter-type select (`form.html.heex:42-46`) emits an empty label and no accessible name. Copying that
pattern would ship a screen-reader-opaque control. The component already supports the fix; the
requirement now says to pass both. The existing control's own gap is left alone as pre-existing.

### Education Researcher

#### RESOLVED: `none` and blank are two different things that look like the same thing

`none` is a real projected application value meaning the log rows recorded no application
(`partitioner/src/index.js:26`, `README.md:240`), not an absence of filtering. Presented as a bare
`none` next to an unlabeled blank option it reads as a second way to say "no filter", and choosing it
would quietly return a different and much smaller set of rows than the researcher intended. The
requirement now calls for a `prompt` naming the effect ("All applications") and a label for the enum
value that says what it means. Display labels only; the submitted values stay the raw enum strings
the DDL uses.

### Dropped after verification

- **"The spec's form tests need a LiveView harness that does not exist."** False. `log_in_conn/2`
  exists (`test/support/conn_case.ex:56`) and `test/report_server_web/live/report_run_show_live_test.exs`
  already mounts a LiveView as a logged-in user. `test/report_server_web/live/report_live_test.exs`
  covers only the login redirect, which made the harness look absent, but the tests this spec names
  are writable against the existing support code.
