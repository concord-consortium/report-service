# Log Reports: Optional Application Filter and Date-Range Warning

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-105

**Status**: **Closed**

## Overview

Add an optional application filter to the two log reports that read `logs_by_app_and_secure_key`, so
the generated Athena SQL constrains the `app` partition instead of enumerating all fifteen projected
values per learner, and warn the researcher when the projected partition count makes a run unlikely
to finish.

A log report over an assignment with a few hundred learners could not be run at all. It either failed
outright with a partition-limit error or timed out after thirty minutes, and in both cases the
researcher saw the word "Failed" with nothing to act on. The cause is that the query tells Athena
which learners to look at but not which application's logs, so Athena probes every application, year
and month combination for every learner. Both additions are additive: leaving the dropdown blank
produces exactly the query the server produced before, so no existing report changes behavior.

## Requirements

### The filter

- `ReportFilter` gains an `app` field defaulting to `nil`. It is **not** added to
  `@valid_filter_types` and **not** added to `@id_dimensions` in `report_json.ex:6`; it is a scalar,
  value-typed dimension serialized the way `state` is.
- `ReportFilter.from_form/2` reads it. The numbered filters are collected by a reduce, but every
  scalar is copied across by an explicit `Map.put`; without a fifth `Map.put` for `app` the field
  stays `nil` no matter what the form submits, and every test that goes through the struct directly
  would still pass.
- Blank (`nil` or `""`) means the pre-change behavior. The generated SQL must be byte-identical to
  the pre-change output for the same filter, verified against a captured baseline rather than
  asserted by shape.
- Set, it adds exactly one predicate, `log.app IN (...)`, to the `where` list in
  `get_athena_query/3`. Nothing else changes. The control is a multiple select, because one
  assignment's logs can span applications: measured on production, ten learners on a Dataflow
  assignment produced 1,053 CLUE events and 148 Dataflow events, so a single-valued filter would
  have silently dropped an eighth of that cohort's data.
- Every shape of "unset" is normalized in one place, `ReportFilter.app_list/1`, which returns `[]`
  for `nil`, `""` and `[]`, wraps a bare string, and drops empty entries. Guards cannot call a
  remote function, so without it the blank check is rewritten in each of the four modules that need
  it. It is identity on its own `[]`, and wrapping a bare string is what lets a run stored before
  the filter accepted several applications still load and render.
- The values are emitted through `ReportUtils.string_list_to_single_quoted_in/1`, the same helper
  the adjacent `secure_key IN (...)` clause uses, which escapes single quotes. The allowlist is
  still the primary defense; this is the second one.
- The submitted value must be validated against the allowed-value list in the query builder. A value
  not in the list is an error, not a silently dropped predicate: dropping it would produce the
  timeout the story exists to prevent, while reporting it makes a stale form or a hand-built API
  body visible. The error takes `get_athena_query/3`'s existing `{:error, message}` shape rather
  than raising, so it surfaces to the researcher the way "No learners found to match the requested
  filter(s)" already does.
- A filter carrying `app` for a report that does not declare the application filter is also an error,
  rejected where the filter is built rather than where it is consumed. The query-builder check alone
  cannot see this case: `get_athena_query/3` is reached only from the two student-actions modules, so
  an `app` on `teacher-actions` or a Portal report would be stored, serialized and silently ignored,
  which is the outcome the rule above exists to prevent. It is also visible, because the run page and
  the runs list both render the filter summary for every report type and would show an Application
  row for a filter that was never applied. A blank `app` stays acceptable on every report, including
  the ones with no control. REPORT-93's create endpoint honors the same rule.
- A test asserts the Elixir list still agrees with the DDL. Both DDL blocks in `server/README.md`
  carry `'projection.app.values'='...'` in a single parseable line and are byte-identical, so the
  test asserts the Elixir list against every occurrence and catches the two blocks drifting from
  each other as well.
- The same holds for the year and month ranges, and for the same reason. `'projection.year.range'`
  and `'projection.month.range'` are declared in the same two blocks in the same parseable form, and
  they are what produce the 444 that every partition estimate is built on. They live beside the
  application list, in one place, with the same agreement test, rather than being restated as
  literals in the estimate.
- The allowed-value list lives in one place, read by the form, the query builder and the validation.
- The `{id, label}` pairs are server-owned and come from the same place, not from the template. The
  raw enum value is the id; the label is the value except for `none`, which carries its explanatory
  wording. REPORT-92's static-dimension work consumes this function directly, so the web form and
  every API client render the vocabulary identically from one definition. This is the only thing
  REPORT-92 needs from this story besides the wire name `app`. `README.md`'s "when new applications
  are added" note gains this list as a second thing to update.

### Where the control appears

- Only `student-actions` and `student-actions-with-metadata`, the two reports that read
  `logs_by_app_and_secure_key`. `teacher-actions` reads `logs_by_time`, which has no `app` partition,
  and must not show the control.
- Gating follows the existing `form_options` mechanism, the same way `enable_hide_names` is gated,
  rather than a slug check in the template.
- The control renders in the same block as the date range and hide-names controls, which is shown
  only once a first filter has a value.
- The control says what selecting does. Because an assignment's logs can span applications and the
  system cannot cheaply detect that, the control carries text stating that selecting some leaves the
  rest out, and that selecting none includes everything.
- The control carries a programmatic label. `.input type="select"` renders a label element bound to
  the input's id, but both `id` and `label` default to `nil`, so the existing filter-type select
  renders an empty label element and no accessible name. The new control passes both rather than
  copying that.
- The warning is a status message and must be announced. It appears asynchronously, after the click,
  on a page that has not otherwise changed, and it reports that the run was not created. The
  existing error area is a plain div with no `role` and no `aria-live`, so reusing it unchanged would
  leave a screen reader user with no announcement that the submit did not happen and none that the
  button is disabled. WCAG 2.2 SC 4.1.3.
- The blank option and the `none` value must read as different things. `none` is a real application
  value meaning "the log rows recorded no application", and a bare `none` sitting next to an
  unlabeled blank option reads as a second way to say "no filter", which would silently return the
  wrong rows. The component's `prompt` attribute carries wording that names the effect ("All
  applications"), and the enum value is labeled "none (no application recorded)". The submitted
  values stay the raw enum strings; only the display labels differ.

### Surfacing it

- `report_filter_json/1` includes `app`, so it appears on `GET /api/v1/reports/:id` and in the runs
  list. It serializes as a list, empty when unset, the way `filters` already does, so a client never
  has to handle both a string and an array. Deciding this before the field ships matters: once
  released, changing its type is a breaking change for cc-data and REPORT-93.
- The run page's filter summary shows the selected application. `app` needs its own row alongside
  Start Date and End Date, and it must be absent when blank, matching those rows.
- `report_filter_values` (the resolved-label map) needs no entry: the label is the value, so
  `ReportFilter.get_filter_values/2` is untouched. This is REPORT-93's server-derived-label rule
  holding trivially.

### The date-range warning

- `learners` is the count of **distinct** learners the report would include, matching what
  `LearnerData.fetch/3` would return for the same filter. This is a statement about what the warning
  means, not only about how it is built: the learner join fans out (it carries
  `LEFT JOIN portal_runs`), so a naive row count over it counts one row per learner run and
  overestimates badly. Measured on production against the twelve assignments matching
  `name LIKE '%Dataflow%'`: `COUNT(DISTINCT rl.learner_id)` gives 814 while
  `ReportQuery.get_count_sql/1` gives 4,971, a 6.11x fan-out. At that factor a cohort of roughly 150
  real learners would project past the partition limit and warn on a run that is fine.
- The projected partition count is `learners x apps x period_months`, where `apps` is the number of
  applications selected, or all 15 when none are, and `period_months` is **the number of
  `(year, month)` pairs the emitted date predicate admits**, not `years x months`.
- `period_months` counts only pairs the projection declares. A bound outside the projected range is
  clamped to it, so a start of 2000 counts from 2014 rather than inventing 168 months that no
  partition exists for, and a range lying entirely outside the projection admits nothing.
- The configurable threshold can only lower the warning. Above Athena's own limit it would suppress
  warnings for runs Athena is certain to reject, so it is capped at that limit.
- `period_months` must be derived the same way `apply_date_range/3` emits its bounds, because the
  ticket's `years x months` reading is wrong for any range that does not start in January and end in
  December. For 2024-09-01 to 2025-06-30 the predicate admits 10 pairs while `years x months`
  computes -4; for 2023-09-01 to 2025-06-30 it admits 22 against the same -4. A negative or zero
  count never crosses the threshold, so the warning would silently never fire on exactly the
  multi-year ranges it exists for. With no date range the two agree at 37 x 12 = 444.
- A range whose end precedes its start admits zero pairs. The warning must treat that as "no
  partitions" rather than dividing by it or reporting a negative count.
- The count runs at submit, before the run is created, so the warning precedes the run rather than
  appearing on one that already exists. It is computed asynchronously.
- Warn when the count exceeds Athena's 1,000,000 limit or a lower configurable threshold. The
  message names the learner count and shows the arithmetic.
- Warn, do not block. The researcher may know something the arithmetic does not.
- The threshold is configuration with a default, not a literal, so it can be lowered without a
  deploy of new code.

### Tests

Each test names the mutation it catches.

- Blank filter produces SQL byte-identical to a captured baseline, with and without a date range.
  Catches an `apply_app/2` clause that emits an empty or always-true predicate when unset.
- Empty string behaves as blank. Catches a `nil`-only guard, which is what the form actually submits
  against.
- A set filter adds exactly one `log.app` predicate, asserted by counting occurrences rather than by
  `=~`. Catches a predicate emitted once per learner or once per runnable URL.
- A value outside the allowed list is rejected. Catches validation that lives only in the form.
- The control is absent from `teacher-actions` and present on both student log reports. Catches
  gating that keys off the wrong thing.
- `@filter_keys` in the API controller test gains `app`, with positive assertions on the value
  alongside it, since the key-set assertion alone cannot fail when a field reaches the struct but
  never reaches the serializer.
- The app list agrees with every `projection.app.values` in the README, and the number of DDL blocks
  found is asserted first. Without that count, a README edit removing the property would leave
  nothing to compare and the test would pass while asserting nothing.
- The partition-count arithmetic is asserted at the boundary: just under the threshold does not warn,
  just over does. Catches an off-by-one and a warning that fires on every run.
- `period_months` is asserted for a partial-year range (2024-09-01 to 2025-06-30 is 10) and a
  multi-year one (2023-09-01 to 2025-06-30 is 22), not only for the no-range case. The no-range case
  alone cannot distinguish the correct count from `years x months`, since both give 444.
- `from_form/2` populates `app` from the submitted params. Catches the field being added to the
  struct, the JSON and the query builder while the form silently never sets it.
- The serialized `app` is `[]` for every shape of unset, asserted for `nil`, `""` and `[]` rather
  than only on a default-built struct. Catches the field reaching the API in whatever shape the
  form last happened to submit.
- A filter carrying `app` submitted against a report without the application filter creates no run.
  Catches validation that only ever runs inside the query builder.
- A submit whose partition count succeeds leaves the form alive. Catches the message plumbing around
  the count task dropping a message and crashing the LiveView.
- The projected year and month ranges agree with every declaration in the README. Catches the 444
  drifting out from under every estimate when the DDL changes.

## Technical Notes

- The `app` partition value is the **sanitized** application string. `sanitize()` in
  `partitioner/src/index.js` maps null or empty to the literal `none` and replaces every character
  outside `[a-zA-Z0-9_-]` with `_` before using it as the partition directory. So the enum values in
  the DDL are already in sanitized form and the filter compares against them directly; there is no
  un-sanitized display form to map back from.
- `none` being a real projected value is why the filter is optional rather than defaulted. A run
  whose rows landed under `none` would silently return nothing if the form defaulted to any named
  application.
- Adding the field changes what `EctoReportFilter.dump/1` writes for every new run. That is
  forward-compatible because `EctoReportFilter.load/1` uses `struct!/2`, which fills defaults for
  absent keys, and it is why the field must not later be renamed without a data migration.
- The API had no create endpoint at the time of writing (the reports routes are read-only), so
  "accepted by the REPORT-93 create endpoint" is a coordination note for that story. The wire name
  is `app`, fixed by this story, and REPORT-93 consumes it.

## Out of Scope

- **A generic year floor.** `Clue.year_floor/1` derives from learner `created_at` and is
  CLUE-specific. The existing date range already prunes `year` and `month`; a generic floor needs its
  own design.
- **Serving `app` from the REPORT-92 discovery endpoint.** There was nothing to extend:
  `POST /reports/filter-options` exists only in REPORT-92's spec, `master` has no such route, and
  REPORT-92 was `To Do` with implementation not scheduled before REPORT-105 shipped. The discovery
  work lives in REPORT-92, which now specifies a **static dimension** kind rather than a special case
  for `app`, on the expectation that other non-portal dimensions follow.
- **Deriving the application from `runnable_url` or `external_activities.tool_id`.** Rejected in the
  ticket, with the reasons; recorded so they are not re-proposed.
- **The pre-existing interpolation of `state` filter values.** State strings are interpolated into
  portal SQL without escaping. That is the same class of issue as the one this story avoids for
  `app`, but it is a separate surface, a separate database and a pre-existing condition. It should
  get its own ticket rather than widen this one.
- **`logs_by_app`.** The third table in the README is not read by any report module in the server.
- **Telling the researcher which applications their cohort actually used.** Multi-select lets them
  express the answer; nothing helps them find it. That fact lives only in the partitioned log table
  this story exists to avoid probing, and the portal cannot answer it because `app` is set by the
  logging client. Measured on production: the `GROUP BY log.app` query that answers it took 159
  seconds of engine time for ten learners while scanning zero bytes, and prefixes grow as
  `learners x 15 x 444`, so at about 150 learners it exceeds Athena's partition limit and cannot run
  at all. The partition path is `.../${app}/${year}/${month}/${secure_key}/`, so listing S3 by key
  is not a cheaper route either: `secure_key` is the deepest segment. Probing was close to linear at
  roughly 2.3 ms per prefix (4,440 prefixes in 10.0 s, 66,600 in 159.4 s), which puts sampling a
  single learner at about 15 seconds and makes that the only shape worth exploring if this is ever
  wanted. No ticket is filed; the numbers are here so one can be written from them.

## Not Yet Implemented

Every requirement above was implemented. These are the adjacent improvements the spec explicitly
declined to make, each recorded so the next engineer does not have to rediscover the reasoning:

- **Normalizing the date scalars to `nil` at the source.** `from_form/2` stores `start_date` and
  `end_date` as the raw `""` the form submits, and `presence/1` converts them at serialization.
  (`app` no longer takes this route: it is normalized by `ReportFilter.app_list/1` and serialized as
  a list.) Normalizing all of them on the way in is a real improvement, but it changes existing
  date behavior and belongs to its own ticket. Doing it for `app` alone was rejected: it would make
  `app` the only scalar normalized on the way in while still needing the `[nil, ""]` guards for
  values arriving from the API.
- **The existing filter-type select's missing accessible name.** It renders an empty label element
  because it passes neither `id` nor `label`. The new control passes both; the pre-existing gap is
  left alone.
- **The existing error area's missing status-message semantics.** The new partition warning carries
  `role="alert"`, but the general `@error` div keeps its pre-existing lack of `role`/`aria-live`.
  Widening this story to fix it was rejected.

## Decisions

### Where does the partition-count warning live, given the learner count is not free at submit?

**Context**: The acceptance criterion says the warning appears "before the run is created", but the
code dive established that no learner data has been fetched at that point: `submit_form` creates the
run and redirects, and the fetch happens later from `AthenaRunOps.start_query/1`. Producing a count
at submit means a new portal round-trip against the `report_learners` join. That query is the
expensive part of the report's portal half, and the warning is advisory. One further fact narrows
it: `start_query/1` is shared by the web run page and the API, so a warning raised there has no user
to confirm it on the API path.

**Options considered**:
- A) Count at submit. Add a count-only portal query to `submit_form`, show the warning, and require a
  second click to proceed. Matches the acceptance criterion exactly. Costs one portal round-trip on
  every log-report submit, including the small ones that never had a problem.
- B) Warn on the run page, before the Athena query is submitted. `start_query/1` already has the real
  learner list in hand, for free. The run row exists by then, and the shared API path has no user to
  confirm it.
- C) Count at submit, but only when the filter looks risky (no date range, or an assignment filter
  with no class/student narrowing), so the common small run pays nothing.

**Decision**: A, count at submit. It is the only option that satisfies the acceptance criterion as
written, and the cost turned out to be smaller than the question assumed. Generating both SQLs from
the same filter shows the count query is the fetch query with a different select: identical from
`FROM` onward, the same seven joins and the same `WHERE`, differing only in
`COUNT(DISTINCT rl.learner_id)` against sixteen columns, and skipping the two follow-up lookups the
full fetch performs. So the extra work is a cheaper duplicate of a query the run executes moments
later, paid only on log reports with the application filter enabled, and it leaves the API-shared
`start_query/1` path untouched. C was rejected rather than deferred: its appeal is that small runs
pay nothing, but it adds a second, fuzzier definition of "risky" beside the exact arithmetic, and the
partition formula had already proven easy to get wrong once.

---

### Does this story extend the REPORT-92 discovery endpoint for `app`?

**Context**: REPORT-92 specifies a generic filter-options endpoint, and `app` is a new dimension an
LLM assembling a filter would want to discover.

**Decision**: No, and this needed no call: there was nothing to extend.
`POST /reports/filter-options` existed only in REPORT-92's spec on an unlanded branch, `master` had
no such route, and REPORT-92 was `To Do` with implementation not scheduled before REPORT-105 shipped.
Doing it here would have meant building REPORT-92's endpoint inside REPORT-105. The action that
carries it: `app` goes into REPORT-92's spec as an eleventh, non-portal dimension while that story is
still open, and 92's "ten dimensions" wording is fixed there.

---

### Is an unrecognized application value an error or a silently-ignored filter?

**Context**: The Elixir value list and the recreated Glue table can disagree for the length of a
deploy, which is the one argument for ignoring an unknown value rather than rejecting it.

**Decision**: Error, returned as `{:error, message}` from `get_athena_query/3`. The codebase already
treats an out-of-vocabulary filter value this way: `get_filter_type!/2` rejects a filter type outside
`@valid_filter_types` rather than dropping it. Silently ignoring the predicate would produce exactly
the thirty-minute timeout this story exists to prevent, and would do it invisibly. The deploy-window
argument is answered by the list living in application config: the disagreement is closable by
configuration, without a code release. `raise` is the wrong shape even though `get_filter_type!/2`
uses it, because `get_athena_query/3` returns error tuples and the researcher should see this the way
they see "No learners found to match the requested filter(s)".

---

### `app` would never leave the form

**Context**: The spec had the struct gaining the field, the form gaining a control, and the query
builder gaining a predicate, with nothing connecting them.

**Decision**: `ReportFilter.from_form/2` copies every scalar across with an explicit `Map.put`, so a
fifth one for `app` is required. Without it the field is always `nil` in production while every test
that builds a `%ReportFilter{}` directly still passes. Added as a requirement and as a named test.

---

### The partition-count formula never fires on the ranges it exists for

**Context**: The ticket specifies `learners x apps x years x months`.

**Decision**: Count the `(year, month)` pairs the date predicate actually admits. The ticket's
reading is wrong for any range not aligned to whole calendar years: 2024-09-01 to 2025-06-30 admits
10 pairs against a computed -4, and 2023-09-01 to 2025-06-30 admits 22 against the same -4. A
negative count never crosses a threshold, so the warning would have been dead code for precisely the
multi-year cohort ranges that motivated the story, while still appearing to work in tests. The two
readings agree only when no date range is set (37 x 12 = 444), which is the case the ticket's
headline numbers were derived from.

---

### The new select would have no accessible name

**Context**: `.input type="select"` renders a label element bound to the input's id, but `id` and
`label` both default to `nil`, so the existing filter-type select emits an empty label.

**Decision**: Pass both `id` and `label` on the new control rather than copying the existing pattern.
The component already supports it. The existing control's own gap is left alone as pre-existing.

---

### `none` and blank are two different things that look like the same thing

**Context**: `none` is a real projected application value meaning the log rows recorded no
application, not an absence of filtering.

**Decision**: Use the component's `prompt` attribute for the blank option with wording that names the
effect ("All applications"), and label the enum value "none (no application recorded)". Presented as
a bare `none` next to an unlabeled blank option it reads as a second way to say "no filter", and
choosing it would quietly return a different and much smaller set of rows than the researcher
intended. Display labels only; the submitted values stay the raw enum strings the DDL uses.

---

### `@filter_keys` cannot catch the omission the plan said it catches

**Context**: The plan claimed the exact-key-set assertion in the API controller test would fail if
the field reached the struct but not the JSON.

**Decision**: It is the other way round, confirmed by running both directions: struct field added
with the serializer untouched gives 519 tests and 0 failures, while the serializer emitting `app`
with `@filter_keys` untouched gives 2 failures. `report_filter_json/1` builds its map from an
explicit literal plus `@id_dimensions`, so a new struct field never reaches it by itself and the key
set never changes. The assertion guards against an *undeclared* key, not a *missing* one. Fixed by
adding positive assertions on the value in both the populated and empty filter tests.

---

### No half-open date range in the named test cases

**Context**: The two date inputs are independent, so a researcher can set only one.

**Decision**: Add both half-open cases as named values: start-only from 2024-09-01 is 316 months,
end-only to 2025-06-30 is 138. Both were run against the proposed `period_months/2`.

---

### The plan put a five-minute blocking query in a click handler

**Context**: `submit_form` was written to call the count inline, and `PortalDbs.query/4` is
synchronous with a five-minute timeout.

**Decision**: Start the count as a supervised task, gate the button on a checking state the way
`@downloading` gates the download button, and fall through to creating the run if the count fails so
an advisory cannot become an outage. The reasoning at the time was that the count could grow with the
cohort against a five-minute timeout, so the inline worst case was a LiveView frozen with no
feedback, introduced by the feature meant to save the researcher from waiting.

**Measured afterwards**: on production, an 814-learner cohort (the twelve assignments matching
`name LIKE '%Dataflow%'`) counted in 109 ms over an SSH tunnel, so for a cohort of that size an
inline call would have been imperceptible and the freeze this decision guarded against did not
materialize. The decision stands on the argument below rather than on this one: an inline call cannot
render a checking state at all. Nothing larger has been measured, so how the count behaves on the
several-thousand-learner cohorts the ticket cites is still unknown.

---

### The estimate module had two sources for the application count

**Context**: The step's code block declared a literal `15` while its own prose said the value must be
derived from the configured list.

**Decision**: Remove the attribute and derive the value in place from the list length. One of the two
is wrong the moment an application is added to the projection, and the literal is the one that would
be read.

---

### The `cond` reported the wrong error when both branches applied

**Context**: As first written, the empty-learners check was tested before the application validation.

**Decision**: Reorder so input validation precedes the data-dependent outcome. A run with an
unrecognized application *and* no matching learners reported "No learners found to match the
requested filter(s)" and sent the researcher to fix the filter that was not broken.

---

### The count task's completion crashes the form LiveView

**Context**: The plan added exactly one `handle_info/2` clause, guarded on the task ref, and cited
the run page's task spawn as the pattern. Verified by running: `Task.Supervisor.async_nolink`
delivers the result and then a `:DOWN` message, suppressed only by `Process.demonitor(ref, [:flush])`.
Verified by reading the LiveView channel source: when the view module exports `handle_info/2`,
LiveView calls it directly, so an unmatched message raises. The permissive debug-log fallback applies
only to a module that exports no `handle_info/2` at all.

**Options considered**:
- A) Keep the supervised task and complete the message handling.
- B) Run the count inline, removing the crash surface entirely.
- C) Run it inline with a short query timeout, bounding the freeze.

**Decision**: A. A success clause on its own would crash the form on every successful count, losing
the filter the researcher just built, worst on the large cohorts the feature exists for. The
`{ref, {:error, _}}` and `{:DOWN, ...}` clauses, the `demonitor` calls, and the initialization of the
task assigns are all required. B was rejected because an inline call cannot report progress at all:
an assign made before a blocking call never reaches the client, so the researcher would click Run
Report and see nothing. C was rejected because no defensible timeout value could be chosen without a
production measurement, and a timeout would skip the warning precisely on the cohorts that need it.
The measurement has since been taken for one cohort: 814 learners counted in 109 ms, which any
plausible timeout would have cleared.

---

### The validation cannot be reached from any report except the two log reports

**Context**: `valid_app?/1` lives in `get_athena_query/3`, which only the two student-actions modules
call. An `app` on any other report would be stored, serialized and ignored with no error, and the run
page and runs list would show an Application row for a filter that was never applied.

**Options considered**:
- A) Document `app` as inert on other reports.
- B) Reject where the filter meets the report.
- C) Gate the new run-page row on the report supporting the filter.

**Decision**: B. `check_app_supported/2` in `submit_form`, keyed off the same `enable_app_filter`
flag that gates the control, and the requirements spec states it as a rule REPORT-93's create
endpoint must honor. A was rejected because both surfaces would still display a filter that was never
applied; C was rejected because it hides the symptom while the value still round-trips through the
API.

---

### `build_query/2` is not a pure SQL builder

**Context**: The plan described the extraction as pure and the count as a strictly cheaper duplicate
of the fetch. The extracted region calls `get_internal_teacher_ids/1`, which runs its own portal
query.

**Decision**: Correct the contract. With `exclude_internal` set the extracted function issues a query
of its own, so the count is two round trips and can fail before any SQL is built. The design is
unchanged.

---

### `app` skips `presence/1`, and the named test cannot catch it

**Context**: `report_filter_json/1` runs the dates through `presence/1`, which maps `""` to `nil`.
The plan added `app` raw. Verified by running: a filter carrying `%ReportFilter{app: "",
start_date: "", end_date: ""}` serializes the dates to `nil` and `app` to `""`, and the plan's named
assertion passes only because it builds a default struct whose `app` is already `nil`.

**Options considered**:
- A) `presence/1` at serialization, matching the sibling scalars.
- B) Normalize `""` to `nil` in `from_form/2`, at the source.
- C) Normalize all four scalars at the source and drop `presence/1`.

**Decision**: A, plus rebuilding the empty-filter assertion around a filter carrying `""` so it can
fail. B was rejected because `from_form/2` stores the dates raw too, so it would make `app` the only
scalar normalized on the way in while still needing the `[nil, ""]` guards for values arriving from
the API. C is a real improvement and belongs to its own ticket.

**Superseded** when the filter became multi-valued: `app` is normalized by
`ReportFilter.app_list/1` and serialized as a list, empty when unset, so it no longer goes through
`presence/1` at all. The dates still do, and option C still stands for them.

---

### The projection bounds are a second source of truth with no agreement test

**Context**: The estimate hardcoded the first year, last year and month count, while the README
declares all of them twice in the same parseable form the app list is asserted against.

**Decision**: Move them next to the app list and test them the same way. `AthenaConfig` owns the year
and month ranges, the estimate reads them instead of restating them, and a second agreement test
asserts both against every declaration in the README. A DDL change to either otherwise moves the 444
that every estimate is built on.

---

### "A ceiling of 150 learners" is off by one, and the boundary test inherits it

**Context**: Verified by running: 150 learners unfiltered with no date range projects 999,000
partitions, under the 1,000,000 limit. 151 is the first count that exceeds it, at 1,005,660.

**Decision**: Keep "about 150" as prose and pin the measured edge in the test. The threshold test uses
150 and 151 so it pins the real boundary rather than a rounded one.

---

### The warning is a status message with nothing to announce it

**Context**: The warning is assigned asynchronously into a page that has not otherwise changed, and
the existing error area carries no `role` and no `aria-live`. WCAG 2.2 SC 4.1.3.

**Decision**: `role="alert"` on the warning container and `aria-busy` on the Run Report button while
the count is in flight. Assertive rather than polite because the warning interrupts an action the
researcher initiated and reports that it did not happen. The existing `@error` div keeps its
pre-existing gap.

---

### The recorded rationale for going async is wrong about the current handler

**Context**: The first-round finding described a synchronous portal query in `submit_form` as new. It
is not: the handler already calls `ReportFilter.get_filter_values/2`, which queries the portal on
every submit of every report.

**Decision**: Reword to cost. `get_filter_values/2` is an id lookup whose cost does not grow with the
cohort, while the count runs the learner join and so scales with it, and the settling argument is
that an inline call cannot report progress at all. The
"non-log reports pay nothing" claim is scoped to the new count only, since every submit already pays
for `get_filter_values/2`.
