# Implementation Plan: Log Reports: Optional Application Filter and Date-Range Warning

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-105
**Requirements Spec**: [requirements.md](requirements.md)
**Status**: **In Development**

Steps are ordered so each compiles and its tests pass without the next one. The filter work (first
four steps) is independent of the warning work (last two), so they can land as separate PRs.

## Implementation Plan

### Single-source the projected application list

**Summary**: Put the DDL-derived projection facts, the fifteen `app` values and the year and month
ranges, in one place in Elixir, with tests that assert they still agree with the DDL in the README.
Nothing consumes them yet, so this stands alone.

**Files affected**:
- `server/lib/report_server/reports/athena/athena_config.ex` — the list, its accessor, and the
  `{label, value}` pairs REPORT-92's static-dimension step consumes
- `server/README.md` — extend the "when new applications are added" note at line 209
- `server/test/report_server/reports/athena/athena_config_test.exs` — new, the agreement tests

**Estimated diff size**: ~120 lines

The list follows the existing accessor shape in `athena_config.ex` (`get_output_bucket/0`,
`get_source_key/0`), with a config override so the deploy-window disagreement described in the
requirements spec can be closed without a code release. Note that the existing accessors call
`Keyword.get/2` on the result of `Application.get_env/2`, which raises when `:athena` is unset (as it
is in the test environment); the new one defaults to `[]` so it is usable from a plain unit test.

```elixir
# The projected values of the `app` partition on logs_by_app_and_secure_key. Must agree with
# 'projection.app.values' in the table DDL in server/README.md; athena_config_test.exs asserts it.
# Adding an application means recreating the Athena tables and updating both.
@log_apps ~w(Activity_Player CEASAR CLUE CODAP CollabSpace Dataflow DEVOPS GeniStarDev GRASP
             HASBot-Dashboard IS LARA-log-poc none portal-report rigse-log)

def get_log_apps() do
  Application.get_env(:report_server, :athena, [])
    |> Keyword.get(:log_apps, @log_apps)
end

# The other two projected partition columns, from the same DDL. PartitionEstimate reads these
# rather than restating them: 'projection.year.range' and 'projection.month.range' set the 444
# (year, month) pairs an unbounded query admits, which every estimate is built on.
@log_projection_years 2014..2050
@log_projection_months 1..12

def get_log_projection_years(), do: @log_projection_years
def get_log_projection_months(), do: @log_projection_months

# {label, value} for Phoenix.HTML.Form.options_for_select/2. REPORT-92's AppDimension
# reshapes these into the API's {id, label}; the wording lives here so the form and the
# API cannot disagree about what "none" means.
def app_options() do
  Enum.map(get_log_apps(), fn
    "none" -> {"none (no application recorded)", "none"}
    app -> {app, app}
  end)
end
```

`app_options/0` lives beside the value list rather than in the LiveView because REPORT-92's
static-dimension step consumes it to answer the discovery endpoint for `app`. That is what makes the
web form and every API client render the vocabulary from one definition.

The agreement test parses the README rather than restating the list, so it fails if either drifts.
Both DDL blocks in the README carry the list and are currently byte-identical, so the test asserts
against every occurrence and catches the two blocks diverging from each other as well:

```elixir
test "the Elixir app list agrees with every projection.app.values in the README DDL" do
  readme = File.read!(Path.join([__DIR__, "..", "..", "..", "..", "README.md"]))
  matches = Regex.scan(~r/'projection\.app\.values'='([^']*)'/, readme, capture: :all_but_first)

  assert length(matches) == 2, "expected both DDL blocks to declare the app projection"
  for [values] <- matches do
    assert String.split(values, ",") == AthenaConfig.get_log_apps()
  end
end
```

The year and month ranges get the same treatment in the same test file, for the same reason: they
are declared twice in the README (`'projection.year.range'='2014,2050'` at `:244` and `:288`,
`'projection.month.range'='1,12'` at `:248` and `:292`) and now a third time in Elixir, and they are
what make the 444. A DDL change to either silently moves every estimate in the feature.

```elixir
test "the projection ranges agree with every declaration in the README DDL" do
  readme = File.read!(Path.join([__DIR__, "..", "..", "..", "..", "README.md"]))

  for {property, range} <- [{"year", AthenaConfig.get_log_projection_years()},
                            {"month", AthenaConfig.get_log_projection_months()}] do
    matches =
      Regex.scan(~r/'projection\.#{property}\.range'='(\d+),(\d+)'/, readme, capture: :all_but_first)

    assert length(matches) == 2, "expected both DDL blocks to declare the #{property} range"
    for [first, last] <- matches do
      assert String.to_integer(first)..String.to_integer(last) == range
    end
  end
end
```

The length assertion is what keeps this from being a test that cannot fail: without it, a README edit
that removed the property entirely would leave `matches` empty and the `for` would assert nothing.

`app_options/0` gets its own test: every value appears exactly once, each pair's value is the raw
enum string, and `none` is the only entry whose label differs from its value. That last assertion
catches a future edit prettifying every label and silently changing what the form submits.

### Add the application dimension to the filter and the generated SQL

**Summary**: The struct field, the form-params bridge, and the predicate with its validation. This is
the change that fixes the reported failure; everything after it is surfacing.

**Files affected**:
- `server/lib/report_server/reports/report_filter.ex` — struct field and `from_form/2`
- `server/lib/report_server/reports/report_query.ex` — validation and predicate
- `server/test/report_server/report_query_test.exs` — SQL tests
- `server/test/report_server/report_filter_test.exs` — new, `from_form/2` coverage

**Estimated diff size**: ~150 lines

`report_filter.ex`: add `app: nil` to the end of the `defstruct` list, and a fifth `Map.put` in the
pipeline at lines 32-35. Do **not** touch `@valid_filter_types`: `app` is not a numbered filter.

```elixir
|> Map.put(:app, form.params["app"])
```

`report_query.ex`: `get_athena_query/3` gains `app` in its pattern match and validates before
building. The existing body is an `if`/`else` on `query_ids`; adding a second failure case makes a
`cond` the clearer shape:

```elixir
def get_athena_query(report_filter = %ReportFilter{start_date: start_date, end_date: end_date, app: app}, learner_data, learner_cols) do
  query_ids = learner_data |> Enum.map(&(&1.query_id))

  cond do
    # input validation before the data-dependent outcome: with both wrong, "no learners"
    # would send the researcher to fix the filter that is not the problem
    !valid_app?(app) ->
      {:error, "Unknown application filter: #{app}"}

    Enum.empty?(query_ids) ->
      {:error, "No learners found to match the requested filter(s)."}

    true ->
      # ... unchanged body, with one added pipe stage on the where list ...
      where = where
        |> apply_app(app)
        |> apply_date_range(start_date, end_date)

      {:ok, %ReportQuery{cols: cols, from: from, join: join, where: where}}
  end
end

defp valid_app?(app) when app in [nil, ""], do: true
defp valid_app?(app), do: app in AthenaConfig.get_log_apps()

defp apply_app(where, app) when app in [nil, ""], do: where
defp apply_app(where, app), do: where ++ ["log.app = '#{app}'"]
```

Placing `apply_app/2` before `apply_date_range/3` is what puts the predicate immediately before the
`secure_key` clause in the emitted SQL, because `get_sql/1` reverses the `where` list
(`report_query.ex:18`). This was confirmed against the running builder while writing the requirements
spec; it is cosmetic, but it keeps the two partition predicates adjacent.

`valid_app?/1` treating `nil` and `""` as valid, and `apply_app/2` treating them as no-ops, is the
same pair of guards written twice on purpose: the first says "this is not an error", the second says
"this emits nothing". Collapsing them would make an unknown value silently emit no predicate.

Tests. Every `get_athena_query/3` test must set the `:athena` application env or
`get_log_db_name/0` raises (`report_query.ex:133-135`); follow
`test/report_server/reports/athena/shared_queries_test.exs:24`. The baselines below are the exact
strings captured from the builder before the change:

- blank filter, no dates, `WHERE (log.secure_key IN ('KEY1','KEY2'))`
- blank filter, with dates, the full five-clause baseline in the requirements spec
- `app: ""` behaves as blank (this is what an unselected `select` submits)
- `app: "CLUE"` emits `WHERE (log.app = 'CLUE') AND (log.secure_key IN ('KEY1','KEY2'))`
- occurrence count of `"log.app"` in the emitted SQL is exactly 1, not `=~`
- `app: "NotAnApp"` returns `{:error, _}`, and so does `app: "CL'UE"`
- `from_form/2` with `%{"app" => "CLUE"}` in params yields `app: "CLUE"`; with the key absent, `nil`

### Serialize the filter and show it on the run page

**Summary**: Expose `app` through the API and the run page's filter summary. Depends on the struct
field from the previous step and nothing else.

**Files affected**:
- `server/lib/report_server_web/api/v1/report_json.ex` — one key in `report_filter_json/1`
- `server/lib/report_server_web/components/custom_components.ex` — a row in `report_filter_values/1`
- `server/test/report_server_web/api/v1/report_controller_test.exs` — `@filter_keys`

**Estimated diff size**: ~40 lines

`report_json.ex`: add `app: presence(report_filter.app)` to the `base` map (lines 40-47), next to
`state`. Do **not** add it to `@id_dimensions` (line 6); that list drives the `Enum.reduce` that
follows and is for integer-id dimensions.

The `presence/1` wrapper is not decoration. `start_date` and `end_date` already go through it
(`report_json.ex:43-44`, `:54-55`) because an untouched date input submits `""`, and an unselected
`select` submits `""` for the same reason. Verified by running the plan's own line unwrapped: a
filter carrying `%ReportFilter{app: "", start_date: "", end_date: ""}` serializes to
`start_date: nil`, `end_date: nil` and `app: ""`, so every run created with the dropdown left blank
would expose `"app": ""` on the API while its siblings expose `null`. `presence/1` is identity on
`nil`, so wrapping a field whose default is already `nil` changes nothing else.

`custom_components.ex`: a row in `report_filter_values/1` in the same style as the Start Date and End
Date rows, absent when blank:

```heex
<div class="table-row" :if={String.length(@report_filter.app || "") > 0}>
  <div class="table-cell capitalize font-bold">Application</div>
  <div class="table-cell pl-3"><%= @report_filter.app %></div>
</div>
```

It needs its own row rather than joining the `:for` over `@report_filter.filters`, because `app` is
never in that list. Note that `filters` comes back from the database as strings rather than atoms
(a JSON round-trip artifact confirmed while verifying the requirements spec), which is another reason
not to route a new scalar through that loop.

`@filter_keys` (`report_controller_test.exs:12-13`) gains `app`, **and a positive assertion on the
value is added alongside it**. The key-set assertion only catches a key the test does not know about:
adding `app` to the struct while forgetting `report_filter_json/1` leaves the serialized key set
unchanged and the whole suite green. Both directions were run to confirm it. So the step also needs

```elixir
assert filter["app"] == "CLUE"
```

in the populated-filter test and, in the empty-filter test, an assertion on a filter that carries
`""` rather than on a default-built struct:

```elixir
assert filter["app"] == nil   # on a %ReportFilter{app: ""}, not on %ReportFilter{}
```

Without the first, nothing fails if the field never reaches the API. Without the second being built
from `""`, the assertion passes on the struct default and cannot fail on the value the form actually
submits, which is the case `presence/1` exists to handle.

### Add the form control to the two log reports

**Summary**: The dropdown, gated to the reports that read `logs_by_app_and_secure_key`. This is the
step that makes the feature reachable.

**Files affected**:
- `server/lib/report_server/reports/tree.ex` — `form_options` on the two reports
- `server/lib/report_server_web/live/report_live/form.ex` — `get_form_options/2`, options assign,
  `check_app_supported/2` in `submit_form`
- `server/lib/report_server_web/live/report_live/form.html.heex` — the control
- `server/test/report_server_web/live/report_form_live_test.exs` — new

**Estimated diff size**: ~120 lines

`tree.ex`: extend the existing keyword list on `student-actions` (line 175) and
`student-actions-with-metadata` (line 182):

```elixir
form_options: [enable_hide_names: true, enable_app_filter: true]
```

`teacher-actions` (line 194) is deliberately untouched: it reads `logs_by_time`
(`teacher_actions_report.ex:35`), which has no `app` partition.

`form.ex`: `get_form_options/2` (lines 339-343) gains the flag, and `handle_params/3` assigns the
option list for the template. Unlike `enable_hide_names` there is no permission dimension, so the
flag passes through directly:

```elixir
defp get_form_options(%Report{form_options: form_options}, user = %User{}) do
  %{
    enable_hide_names: allow_hide_names?(user) && Keyword.get(form_options, :enable_hide_names, false),
    enable_app_filter: Keyword.get(form_options, :enable_app_filter, false)
  }
end
```

`form.html.heex`: inside the `!blank?(@form.params["filter1"])` block (lines 86-109), alongside the
date range and hide-names controls:

```heex
<div :if={@form_options.enable_app_filter} class="mt-4">
  <.input
    type="select"
    id="app"
    label="Application"
    prompt="All applications"
    field={@form["app"]}
    options={@app_options}
  />
</div>
```

Passing `id` and `label` is what gives the control an accessible name: `.input type="select"` renders
`<.label for={@id}><%= @label %></.label>` (`core_components.ex:334`) but both attributes default to
`nil` (`core_components.ex:271`, `:273`), which is why the existing filter-type select at lines 42-46
emits an empty label. `prompt` renders the blank option through the component's own
`<option :if={@prompt} value="">` branch, keeping "All applications" visibly distinct from the `none`
value.

The wrapper carries `mt-4` only. The date row above it uses `flex items-center gap-4` because it
lays out four siblings on one line; `.input type="select"` renders a single element that already
stacks its own label above its select, so the flex classes would have nothing to act on.

`@app_options` is assigned once in `handle_params/3` from `AthenaConfig.app_options/0`, defined in the
first step. The LiveView holds no label logic of its own.

**The same flag gates acceptance, not just display.** `valid_app?/1` lives in `get_athena_query/3`,
which only the two student-actions modules call (`student_actions_report.ex:10`,
`student_actions_with_metadata_report.ex:10`). `teacher-actions` builds its own query
(`teacher_actions_report.ex:6-40`) and the Portal reports never reach it, so an `app` on any other
report is stored, serialized and ignored with no error. That is the silently-dropped filter the
requirements spec's resolved question rejects, displaced from the query builder to the report
boundary, and it is visible: `report_filter_values/1` renders on the run page
(`show.html.heex:7`) and in the runs list (`custom_components.ex:335`) for every report type, so the
new Application row would assert a filter that was never applied.

The form cannot produce this, because the control is gated, but `form_updated`
(`form.ex:97-113`) rebuilds the form from whatever `filter_form` params arrive and `from_form/2`
copies `app` across unconditionally, so a hand-built `phx-change` payload reaches it today. The
route that matters is REPORT-93's create endpoint, which this story is fixing the wire name for.

So `submit_form` rejects the combination where the report and the filter are both already in hand,
using the flag the step just added:

```elixir
defp check_app_supported(%ReportFilter{app: app}, _form_options) when app in [nil, ""], do: :ok
defp check_app_supported(_report_filter, %{enable_app_filter: true}), do: :ok
defp check_app_supported(_report_filter, _form_options) do
  {:error, "This report does not support an application filter."}
end
```

Clause order matters and is the same shape as `valid_app?/1`: a blank `app` is acceptable on every
report, including the ones that have no control, so the blank case is answered before the flag is
consulted. On `{:error, message}` the handler assigns `:error` and creates nothing, which is the
path `submit_form` already has for a failed insert (`form.ex:231-234`). REPORT-93 applies the same
rule when it adds the create endpoint; that is stated in the requirements spec so it is not
rediscovered there.

Tests use the existing LiveView harness (`log_in_conn/2` in `test/support/conn_case.ex:56`, as used
by `report_run_show_live_test.exs`):

- the control renders on `student-actions` and `student-actions-with-metadata`
- it does not render on `teacher-actions`
- submitting with an application selected stores it on the run's `report_filter`
- a filter carrying `app` submitted against `teacher-actions` creates no run and assigns the error,
  asserted by driving the params rather than the control, since the control is not rendered there.
  Catches the guard being written against the control's visibility instead of the submitted value
- a blank `app` submitted against `teacher-actions` creates the run as normal, which is what the
  first clause protects and what a flag-first ordering would break

### Compute the projected partition count

**Summary**: The arithmetic, as a pure module with no callers yet. Split out from the wiring because
it is identical under all three options in the requirements spec's open question, so it can be
written and tested now regardless of how that lands.

**Files affected**:
- `server/lib/report_server/reports/partition_estimate.ex` — new
- `server/test/report_server/reports/partition_estimate_test.exs` — new

**Estimated diff size**: ~120 lines

The one thing this module must get right is `period_months/2`: the count of `(year, month)` pairs the
date predicate admits, not `years x months`. It must be derived the same way `apply_date_range/3`
(`report_query.ex:156-189`) emits its bounds, and clamp at zero for an inverted range.

```elixir
# The projection bounds come from AthenaConfig, which holds every DDL-derived fact and has the
# test asserting they still match the README. Restating them here would put the number that
# produces 444 in two places.

# Athena refuses a query that could touch more than this many partitions. This is a fact
# about Athena; the warning threshold below is policy and defaults to it by reference, so
# the number appears exactly once.
@athena_partition_limit 1_000_000

def athena_partition_limit, do: @athena_partition_limit

def warning_threshold do
  Application.get_env(:report_server, :partition_warning_threshold) || @athena_partition_limit
end

def period_months(start_date, end_date) do
  years = AthenaConfig.get_log_projection_years()
  months = AthenaConfig.get_log_projection_months()

  {start_year, start_month} = to_ym(start_date, {years.first, months.first})
  {end_year, end_month} = to_ym(end_date, {years.last, months.last})
  max(end_year * 12 + end_month - (start_year * 12 + start_month) + 1, 0)
end

def projected_partitions(learner_count, app, start_date, end_date) do
  learner_count * app_count(app) * period_months(start_date, end_date)
end

# length/1, never a literal 15: adding an application to the projection must not
# leave the estimate silently low. Public because the warning message shows the
# arithmetic and must not re-derive this.
def app_count(app) when app in [nil, ""], do: length(AthenaConfig.get_log_apps())
def app_count(_app), do: 1

# an absent or unparseable bound falls back to the projection's edge, so a half-open range runs to it
defp to_ym(bound, default) do
  case ReportQuery.normalize_date(bound) do
    {:ok, date} -> {date.year, date.month}
    _ -> default
  end
end
```

The date parser is `ReportQuery.normalize_date/1`, promoted from private to public rather than
copied here. The estimate is only correct if it bounds a range exactly as `apply_date_range/3` does,
so the two reading the same function is the property that keeps them from drifting; a second copy
alongside a comment saying it mirrors the first is the shape that drifts. `nil` and `""` are both
"no bound" there, which is what the form submits.

One `to_ym/2` serves both ends. Separate `floor_ym`/`ceil_ym` wrappers would have identical bodies,
and the `years.first`/`years.last` arguments at the call site already say which end is which.

Deriving `period_months/2` from a month ordinal rather than from `years x months` is what makes the
partial-year cases correct, and it is worth stating why the naive form is wrong: for 2024-09-01 to
2025-06-30 the predicate admits 10 pairs while `years x months` computes `2 x (6 - 9 + 1)` = -4, and
a negative count never crosses a threshold, so the warning would never fire on exactly the multi-year
ranges the story exists for.

Tests, with the values verified against the real emitted predicate in a SQL engine while writing the
requirements spec:

- no range: 444 months (37 x 12), so 6,660 prefixes per learner unfiltered, reproducing the ticket's
  headline number. The learner ceiling is 150: measured, 150 learners project 999,000 partitions,
  which is under the limit, and 151 is the first count over it at 1,005,660. The ticket's "about
  150" is right as prose and wrong as a boundary, so these are the two values the threshold test
  below uses
- 2024-09-01 to 2025-06-30: **10**
- 2023-09-01 to 2025-06-30: **22**
- a single month: 1
- an inverted range: 0
- half-open ranges, which the form allows because the two date inputs are independent
  (`form.html.heex:90-93`): start only, 2024-09-01 to the end of the projection, is 316; end only,
  the start of the projection to 2025-06-30, is 138
- setting the application divides the count by the length of the app list, not by a literal 15

The partial-year and multi-year cases are the load-bearing ones. A test that only covers the no-range
case cannot distinguish the correct implementation from `years x months`, since both give 444.

### Warn at submit when the projected partition count is too high

**Summary**: Count the learners, compute the estimate, and warn without blocking.

> Trigger point decided 2026-09-04: count at submit, before the run is created. The alternatives
> (warning from `AthenaRunOps.start_query/1`, or guarding the count behind a risk heuristic) were
> considered and rejected in the requirements spec.

**Files affected**:
- `server/lib/report_server/reports/athena/learner_data.ex` — extract `build_query/2`, add `count/2`
- `server/lib/report_server_web/live/report_live/form.ex` — `submit_form` two-phase confirm
- `server/lib/report_server_web/live/report_live/form.html.heex` — the warning and confirm button
- `server/test/report_server/reports/athena/learner_data_test.exs` — the count SQL

**Estimated diff size**: ~200 lines

**The count must not go through `get_count_sql/1`.** Running it against the `LearnerData` query shape
showed it replaces the column list with `{"1", "qrow"}` and so drops the `DISTINCT rl.learner_id`
that `fetch/3` relies on (`learner_data.ex:28`). With `LEFT JOIN portal_runs run`
(`learner_data.ex:53`) in the join set, the result counts one row per learner run, overestimating the
learner count by an unbounded factor and firing the warning on runs that are fine. Use a dedicated
count column over the same `from`/`join`/`where` instead:

```elixir
def count(report_filter = %ReportFilter{}, user = %User{}) do
  with {:ok, portal_query} <- build_query(report_filter, user),
       {:ok, sql} <- ReportQuery.get_sql(count_query(portal_query)),
       {:ok, result} <- PortalDbs.query(user.portal_server, sql) do
    {:ok, result.rows |> List.first() |> List.first()}
  end
end

def count_query(portal_query = %ReportQuery{}) do
  %{portal_query | cols: [{"COUNT(DISTINCT rl.learner_id)", "learner_count"}]}
end
```

`count_query/1` is split out and public so the shape can be asserted without a database: the tests
build a query, swap the columns, and compare the generated SQL against the fetch query's.

`build_query/2` is everything in `fetch/3` from the `portal_query` literal (line 26) through
`ReportQuery.update_query/2` (line 124), extracted unchanged and returning `{:ok, %ReportQuery{}}`.
`fetch/3` then calls it and continues from `get_sql`. No filter logic moves or changes, so the
existing `fetch/3` behavior is preserved by construction, and the extraction is what lets one
definition of "which learners" serve both the report and the estimate.

It is not, however, a pure builder, and its contract should say so: the extracted region calls
`get_internal_teacher_ids(user.portal_server)` (`learner_data.ex:94-98`), which runs a portal query
of its own (`report_utils.ex:151-162`). With `exclude_internal` set, `count/2` is therefore two
round trips rather than one, and it can fail with a database error before any SQL is built. The
`with` chain already handles that, since `build_query/2` returns a tagged tuple, but "a strictly
cheaper duplicate of the fetch" is true of the common case only.

`submit_form` becomes two-phase, and **the count runs as a supervised task rather than inline**.
The reason is cost, not novelty: `submit_form` already makes a synchronous portal query on every
submit of every report, at `form.ex:217`, where `ReportFilter.get_filter_values/2` runs
`PortalDbs.query/2` (`report_filter.ex:75`). That one is an id lookup over the ids already chosen and
its cost does not grow with the cohort. The count runs the learner join and is slowest for exactly
the large cohorts the warning exists for, against a five-minute default timeout
(`portal_dbs.ex:9`).

What settles it is that an inline call cannot report progress at all. Verified by running: an assign
made before a blocking call in `handle_event/3` never reaches the client, because the LiveView
process serializes everything behind the blocked handler, so a "checking" state assigned before the
query is only ever rendered after it returns. Inline means the researcher clicks Run Report and the
page does nothing, with no way to say why. The codebase already has the pattern for the alternative:
the run page runs its portal row count through `assign_async` (`show.ex:47`) and its downloads
through `Task.Supervisor.async_nolink` (`show.ex:243-251`).

So the first click starts the count asynchronously and puts the form in a checking state; the result
arrives as a message and either creates the run or assigns the warning. The confirm path is a
separate event so the warning cannot be skipped by a re-render:

```elixir
def handle_event("submit_form", _params, socket) do
  # ... build report_filter as today, then check_app_supported/2 from the previous step ...
  if warning_applicable?(report, socket) do
    {:noreply, socket |> assign(:checking_partitions, true) |> start_count_task(report_filter)}
  else
    create_run(socket, report_filter)
  end
end

def handle_info({ref, {:ok, learner_count}}, socket) when ref == socket.assigns.count_task_ref do
  Process.demonitor(ref, [:flush])
  # estimate, then either create_run/2 or assign the warning
end

# the estimate is advisory: a failed count creates the run rather than blocking it
def handle_info({ref, {:error, error}}, socket) when ref == socket.assigns.count_task_ref do
  Process.demonitor(ref, [:flush])
  Logger.error("Partition estimate failed: #{inspect(error)}")
  create_run(socket, socket.assigns.pending_report_filter)
end

# and so does a crashed one
def handle_info({:DOWN, ref, :process, _pid, reason}, socket) when ref == socket.assigns.count_task_ref do
  Logger.error("Partition estimate crashed: #{inspect(reason)}")
  create_run(socket, socket.assigns.pending_report_filter)
end

def handle_event("submit_form_confirmed", _params, socket) do
  # ... same report_filter, straight to create_run/2 ...
end
```

**All three message clauses are load-bearing, and so are the `demonitor` calls.** Verified by
running: `Task.Supervisor.async_nolink` delivers `{ref, result}` and then
`{:DOWN, ref, :process, pid, :normal}`, and only `Process.demonitor(ref, [:flush])` suppresses the
second. Verified by reading `phoenix_live_view/lib/phoenix_live_view/channel.ex:522-536`: when the
view module exports `handle_info/2`, LiveView calls `view.handle_info(msg, socket)` directly, so an
unmatched message raises `FunctionClauseError`. The permissive debug-log fallback applies only to a
module that exports no `handle_info/2` at all, which is `form.ex` today. A success clause on its own
would therefore crash the form on every successful count, losing the filter the researcher just
built, and it would do it worst on the large cohorts this feature exists for. `show.ex:104-133` is
the whole pattern; the spawn half at `:243-251` is only where it starts.

`count_task_ref`, `checking_partitions` and `pending_report_filter` are initialized in
`handle_params/3` alongside the other assigns (`form.ex:42-62`), the way `show.ex:24-25` initializes
`downloading` and `download_task_ref`. Without that the guards have no key to compare against and a
stray message falls through to the same crash.

`pending_report_filter` is what the confirm path and both fall-through paths create the run from,
rather than re-deriving it from `@form`. The form keeps changing under `form_updated` while the count
is in flight, so re-deriving would create a run from a filter the warning never described.

The Run Report button is disabled while `@checking_partitions` is true, matching how `@downloading`
gates the download button. A count that fails or times out falls through to creating the run rather
than blocking it: the estimate is advisory, and a broken advisory must not become an outage.

The count is reached through the `:learner_data` seam the codebase already uses
(`endpoint_set.ex:64`, with `ReportServer.LearnerDataStub` in test support), so the warning paths are
testable without a portal. The stub gains a `count/2` alongside its existing `fetch/3`.

The application-filter flag is what decides whether to count, so no count query runs and no async
task starts for a report without it. That is the new work only: every submit already pays
for `get_filter_values/2` (`form.ex:217`), and this step does not change that. The message names the
learner count and shows the arithmetic with its terms labeled, so the researcher can see which one
to change: *"This report covers 694 learners. Athena would need to check 694 learners x 15
applications x 444 months = 4,622,040 partitions, over the 1,000,000 limit. Selecting an
application, or narrowing the date range, will reduce it. You can run it anyway."* The threshold is
named rather than Athena's limit, so a configured lower one reads correctly.

**The warning has to be announced, not just rendered.** It arrives asynchronously, after the click,
into a page that has not otherwise changed, and it reports that the submit did not do what the
researcher asked for. `form.html.heex:119-120` renders `@error` as a plain
`<div class="mt-2 text-red-500" :if={@error}>`, with no `role` and no `aria-live`, so reusing that
area as-is gives a screen reader user nothing: no announcement that the run was not created, and no
announcement that the button is now disabled. That is WCAG 2.2 SC 4.1.3 Status Messages.

Render the warning in a container carrying `role="alert"`, which is announced without moving focus
and is the assertive choice because it interrupts an action the researcher initiated, and give the
checking state something observable by setting `aria-busy` on the Run Report button while
`@checking_partitions` is true. The existing `@error` div is left alone: its gap is pre-existing and
belongs to its own change.

The threshold is read through `PartitionEstimate.warning_threshold/0`, which falls back to the
Athena limit when nothing is configured. **No default is written into `config.exs`**: an unset key
means "use the Athena limit", so the number is defined in exactly one place. Lowering it is then a
one-line config addition:

```elixir
# optional; omit to use Athena's own 1,000,000 partition limit
config :report_server, :partition_warning_threshold, 250_000
```

Verified by running: with no config the threshold equals the Athena limit, and with a lower value
configured the threshold moves while `athena_partition_limit/0` does not.

Tests:

- the count SQL contains `COUNT(DISTINCT rl.learner_id)` and no bare `COUNT(*)`, which is what
  catches a later refactor routing it back through `get_count_sql/1`
- `build_query/2` still selects `DISTINCT rl.learner_id` and still carries the filter into the
  `WHERE`. The extraction itself is verified by the diff being a pure move: the head and the closing
  `with` change and the filter-building body is untouched, so `fetch/3`'s SQL is unchanged by
  construction rather than by a pinned string
- just under the threshold creates the run with no warning; just over assigns the warning and creates
  nothing. With no threshold configured those two values are 150 and 151 learners unfiltered with no
  date range, which is the measured edge: 999,000 partitions against 1,005,660
- the confirm event creates the run, and creates it from the filter the count was run against rather
  than from a form mutated since. Catches the confirm path re-deriving from `@form`
- a report without `enable_app_filter` runs no count query and never warns
- with no threshold configured the warning fires at the Athena limit, and a configured lower
  threshold moves it. Catches the number being duplicated into config and the two drifting.
- a count that errors still creates the run, so the advisory cannot become an outage
- **a count that succeeds leaves the LiveView alive.** Drive a full submit through the LiveView test
  harness and assert the view is still mounted afterwards, not only that the run was created. This
  is the test that catches the missing `:DOWN` clause and the missing `demonitor`, and it is the one
  a unit test of the estimate cannot catch, because the crash is in the message plumbing rather than
  in the arithmetic
- a count that crashes still creates the run, exercising the `:DOWN` path with a real task failure
- the warning container carries `role="alert"`, and the Run Report button carries `aria-busy` while
  the count is in flight

### Update the README

**Summary**: The prose the change invalidates.

**Files affected**:
- `server/README.md` — the note at line 209

**Estimated diff size**: ~5 lines

The "when new applications are added these tables need to be recreated on AWS" note gains the Elixir
list as a second thing to update, and names the test that will fail if it is forgotten. It says the
same for the year and month ranges, since those are mirrored in Elixir now as well and a DDL change
to either moves every partition estimate. Folding this into the first step is also reasonable; it is
called out separately so it is not lost.

## Open Questions

None. The one open question is a requirements decision and lives in
[requirements.md](requirements.md); the step it affects is marked above.

## Self-Review

Roles: the reviewer who has to read the resulting commits, the engineer who has to write the named
tests, the engineer who has to operate the result, and a senior engineer on the code itself. Every
finding below was checked by building the proposed code and running it, not by reading the plan; the
plan's own claims about behavior were re-derived rather than trusted. What survived unchanged is
listed at the end.

### The engineer who has to write the tests

#### RESOLVED: `@filter_keys` cannot catch the omission the plan said it catches

The plan claimed the exact-key-set assertion at `report_controller_test.exs:12-13` "fails if the
field reaches the struct but not the JSON". It is the other way round, confirmed by running both
directions against the real suite:

- struct field added, `report_filter_json/1` untouched: **519 tests, 0 failures**. Nothing notices.
- `report_filter_json/1` emitting `app`, `@filter_keys` untouched: **2 failures**.

`report_filter_json/1` builds its map from an explicit literal plus `@id_dimensions`
(`report_json.ex:40-52`), so a new struct field never reaches it by itself and the key set never
changes. The assertion guards against an *undeclared* key, not a *missing* one. Left as written, the
step could ship the field to the database and the form while the API silently never exposes it, with
a green suite. Fixed by adding positive assertions on the value in both the populated and empty
filter tests.

#### RESOLVED: no half-open date range in the named cases

The two date inputs are independent (`form.html.heex:90-93`), so a researcher can set only one, and
the estimate behaves very differently: start-only from 2024-09-01 is 316 months, end-only to
2025-06-30 is 138. Both were run against the proposed `period_months/2`. Added as named cases.

### The engineer who has to operate the result

#### RESOLVED: the plan put a five-minute blocking query in a click handler

`submit_form` was written to call `LearnerData.count/2` inline. `PortalDbs.query/4` is synchronous
with a five-minute timeout (`portal_dbs.ex:9`), and the count is slowest for precisely the large
cohorts the warning exists for, so the plan's worst case was a LiveView frozen for five minutes with
no feedback, introduced by the feature meant to save the researcher from waiting. The codebase
already solves this twice on the run page, with `assign_async` (`show.ex:47`) and
`Task.Supervisor.async_nolink` (`show.ex:243-251`). Rewritten to start the count as a task, gate the
button on a checking state the way `@downloading` gates the download button, and fall through to
creating the run if the count fails, so an advisory cannot become an outage.

### Senior Engineer

#### RESOLVED: the estimate module had two sources for the application count

The step's code block declared `@apps_when_unfiltered 15` while its own prose two paragraphs later
said the value must be `length(AthenaConfig.get_log_apps())`. One of the two is wrong the moment an
application is added to the projection, and the literal is the one that would be read. Removed the
attribute, derived the value in place, and moved the reason into a comment beside it.

#### RESOLVED: the `cond` reported the wrong error when both branches applied

As first written, `Enum.empty?(query_ids)` was tested before `valid_app?(app)`, so a run with an
unrecognized application *and* no matching learners reported "No learners found to match the
requested filter(s)" and sent the researcher to fix the filter that was not broken. Verified by
running. Reordered so input validation precedes the data-dependent outcome.

### Verified and left unchanged

These were checked by building them, and needed no change:

- The `cond` restructuring of `get_athena_query/3` compiles under `--warnings-as-errors`, preserves
  the existing no-learners error, emits the baseline SQL unchanged when the filter is blank or empty,
  emits exactly one predicate when set, and rejects `NotAnApp`, `CL'UE` and `CLUE' OR '1'='1`.
- The whole existing suite (519 tests) passes with the filter change applied, so the new field
  disturbs nothing, including the audit log's stored `report_filter`.
- `get_log_apps/0` returns the fifteen values with `:athena` unset (the test environment), with
  `:athena` set but carrying no `:log_apps`, and returns the override when one is configured.
- The README agreement test works exactly as written: it finds both DDL blocks and both agree with
  the Elixir list.
- `period_months/2` reproduces all five values previously verified against the real predicate in a
  SQL engine (444, 10, 22, 1, 0) and the ticket's headline numbers (6,660 prefixes per learner, a
  ceiling of 150 learners).

## Self-Review: second round (2026-09-04)

Roles: Senior Engineer, QA Engineer, WCAG Accessibility Expert, Performance Engineer. This round was
run against the code rather than against the plan. The suite was captured green at 519 tests, the
plan's first four steps were built as a throwaway prototype (struct field, `from_form` bridge,
`AthenaConfig.get_log_apps/0` and `app_options/0`, the `cond` restructuring with `valid_app?/1` and
`apply_app/2`, and `PartitionEstimate`), a pre-change SQL baseline was captured from the running
builder, 18 verification tests were run against the prototype, and the prototype was then reverted
and the suite re-confirmed at 519. Findings that did not survive that process are listed at the end.

### Senior Engineer

#### RESOLVED: the count task's completion crashes the form LiveView

The plan adds exactly one `handle_info/2` clause to `form.ex`, guarded on `count_task_ref`, and
cites `show.ex:243-251` as the pattern. That is the half of the pattern that spawns the task. The
half that receives it is `show.ex:104-133`, which has three clauses (success, `{ref, {:error, _}}`,
and `{:DOWN, ref, :process, _pid, reason}`) and calls `Process.demonitor(ref, [:flush])` in each
result path.

Verified by running: `Task.Supervisor.async_nolink` delivers `{ref, result}` and then
`{:DOWN, ref, :process, pid, :normal}`, and the `:DOWN` is suppressed only by the `demonitor` call.
Verified by reading `deps/phoenix_live_view/lib/phoenix_live_view/channel.ex:522-536`: when the view
module exports `handle_info/2`, LiveView calls `view.handle_info(msg, socket)` directly, so an
unmatched message raises `FunctionClauseError`. The debug-log fallback applies only to a module that
exports no `handle_info/2` at all, which is `form.ex` today (it has none).

So as written, every successful count crashes the form LiveView immediately after the count returns,
the researcher loses the filter they built, and the failure is worst on exactly the large-cohort runs
the warning exists for. Add the error and `:DOWN` clauses, call `Process.demonitor(ref, [:flush])` on
the result paths, and initialize `count_task_ref` and `checking_partitions` in `handle_params/3`
alongside the other assigns (`form.ex:42-62`) so the guards have something to compare against.

**Decision**: keep the supervised task and complete the message handling (decided 2026-09-04). The
`{ref, {:error, _}}` and `{:DOWN, ...}` clauses, the `Process.demonitor(ref, [:flush])` calls, and
the `handle_params/3` initialization of `count_task_ref`, `checking_partitions` and
`pending_report_filter` are now in the step. Running the count inline was considered and rejected:
it removes the crash surface but cannot report progress at all, since an assign made before a
blocking call never reaches the client, so the researcher would click Run Report and see nothing.
Bounding an inline count with a short `PortalDbs.query` timeout was also rejected, because the count
is slowest for the large cohorts the warning exists for, so the timeout would skip the warning
exactly when it matters, and no defensible timeout value can be chosen without a production
measurement.

#### RESOLVED: the validation cannot be reached from any report except the two log reports

`valid_app?/1` lives in `get_athena_query/3`, which is called only from `student_actions_report.ex:10`
and `student_actions_with_metadata_report.ex:10` (verified by grep). `teacher-actions` builds its own
query (`teacher_actions_report.ex:6-40`) and the Portal reports never reach it. An `app` value set on
any other report is therefore stored, serialized and ignored without an error, which is precisely the
silently-dropped-filter outcome the requirements spec's resolved question rejects, displaced from the
query builder to the report boundary.

The web form cannot produce this, because the control is gated. The API can, and this story fixes the
wire name specifically so that REPORT-93's create endpoint can accept it. Either validate where the
filter is built rather than where it is consumed, or state in the spec that `app` is inert on
non-log reports and say why that is acceptable, so the next person does not have to rediscover which
of the two rules applies.

**Decision**: reject where the filter meets the report (decided 2026-09-04). `check_app_supported/2`
in `submit_form`, keyed off the same `enable_app_filter` flag that gates the control, is in the form
step, and the requirements spec states it as a rule REPORT-93's create endpoint must honor. Merely
documenting `app` as inert elsewhere was rejected because both the run page and the runs list would
still display an Application row for a filter that was never applied; gating only that row was
rejected because it hides the symptom while the value still round-trips through the API.

#### RESOLVED: `build_query/2` is not a pure SQL builder

The plan describes the extraction as "a pure extraction: no filter logic moves or changes", and
`count/2` as "a strictly cheaper duplicate of a query the run executes moments later". The extracted
region includes `learner_data.ex:94-98`, which calls `get_internal_teacher_ids(user.portal_server)`,
and that runs its own portal query (`report_utils.ex:151-162`).

So with `exclude_internal` set, `build_query/2` issues a query of its own: `count/2` becomes two
portal round trips, not one, and it can fail with a database error before any SQL is built. The
design is unaffected, but the contract for the extracted function should say that it queries, since
that is what makes the difference between one round trip and two.

### QA Engineer

**Decision**: correct the contract (decided 2026-09-04). The step now says the extracted function
queries when `exclude_internal` is set, that `count/2` is two round trips in that case, and that it
can fail before any SQL is built. The design is unchanged.

#### RESOLVED: `app` skips `presence/1`, and the named test cannot catch it

`report_filter_json/1` runs `start_date` and `end_date` through `presence/1`, which maps `""` to
`nil` (`report_json.ex:43-44`, `:54-55`). The plan adds `app: report_filter.app` raw, next to
`state`.

Verified by running, with the plan's own line applied: a filter carrying
`%ReportFilter{app: "", start_date: "", end_date: ""}` serializes to `start_date: nil`,
`end_date: nil`, and `app: ""`. An unselected `select` submits `""`, which the plan states itself, so
every run created with the dropdown left blank exposes `"app": ""` on the API while its sibling
scalars expose `null`.

The plan's named test is `assert filter["app"] == nil` in the empty-filter test. That passes, because
that test builds a `%ReportFilter{}` directly and the struct default is `nil`. It cannot fail on the
value the form actually produces. Use `app: presence(report_filter.app)`, and assert the empty case
against a filter carrying `""` so the test is capable of failing.

**Decision**: `presence/1` at serialization, matching the sibling scalars (decided 2026-09-04).
`app: presence(report_filter.app)`, and the empty-filter assertion is now made against a filter
carrying `""` rather than a default-built struct, so it can fail. Normalizing at the source was
rejected: `from_form/2` stores `start_date` and `end_date` raw too, so it would make `app` the only
scalar normalized on the way in while still needing the `[nil, ""]` guards for values arriving from
the API. Normalizing all four at the source is a real improvement and belongs to its own ticket.

#### RESOLVED: the projection bounds are a second source of truth with no agreement test

`PartitionEstimate` hardcodes `@projection_first_year 2014`, `@projection_last_year 2050` and a
twelve-month year. The README carries `'projection.year.range'='2014,2050'` at `:244` and `:288` and
`'projection.month.range'='1,12'` at `:248` and `:292`, in the same two DDL blocks the app list is
asserted against and in the same single-line parseable form.

The plan tests the app list against the README and leaves these untested, so a DDL change to the year
range moves 444, and 444 is the number every estimate and every named test value is built on. This is
the same duplication the first step exists to remove, one property over. Extend the agreement test to
the year and month ranges: it is three more lines against a file the test already reads.

**Decision**: move them next to the app list and test them the same way (decided 2026-09-04).
`AthenaConfig` now owns `get_log_projection_years/0` and `get_log_projection_months/0`,
`PartitionEstimate` reads them instead of restating 2014, 2050 and 12, and a second agreement test
asserts both ranges against every declaration in the README.

#### RESOLVED: "a ceiling of 150 learners" is off by one, and the boundary test inherits it

Verified by running: 150 learners unfiltered with no date range projects 150 x 15 x 444 = 999,000
partitions, which is under Athena's 1,000,000 limit. 151 learners is the first count that exceeds it,
at 1,005,660.

Both specs say "a ceiling of about 150 learners", which is fine as prose, but the implementation
spec's "Verified and left unchanged" list records "a ceiling of 150 learners" as a number confirmed by
running, and the plan separately names a boundary test asserting that just under the threshold does
not warn and just over does. Use 150 and 151 as those two values, so the test pins the real edge
rather than a rounded one.

### WCAG Accessibility Expert

**Decision**: keep "about 150" as prose and pin the measured edge in the test (decided 2026-09-04).
The threshold test uses 150 learners at 999,000 partitions and 151 at 1,005,660, and the step's test
list states both numbers.

#### RESOLVED: the warning is a status message with nothing to announce it

The warning is assigned asynchronously, after the click, into a page that has not otherwise changed.
`form.html.heex:119-120` renders `@error` as a plain `<div class="mt-2 text-red-500" :if={@error}>`
with no `role` and no `aria-live`, and the plan reuses that area without adding one.

A sighted user sees the warning appear and the Run Report button change state. A screen reader user
gets nothing at all: no announcement that the submit did not run, and no announcement that the button
is now disabled while the count is in flight. This is WCAG 2.2 SC 4.1.3 Status Messages, and it is
the one requirement the accessibility review in the requirements spec did not reach, because that
round only looked at the select.

Render the warning inside a container carrying `role="status"` so it is announced without moving
focus, and give the checking state something a screen reader can observe, either `aria-busy` on the
button or an accessible name that changes with the state.

### Performance Engineer

**Decision**: `role="alert"` on the warning container and `aria-busy` on the Run Report button while
the count is in flight (decided 2026-09-04). Assertive rather than polite because the warning
interrupts an action the researcher initiated and reports that it did not happen. The existing
`@error` div keeps its pre-existing gap; widening this story to fix it was rejected.

#### RESOLVED: the recorded rationale for going async is wrong about the current handler

The plan's first-round finding says it "put a five-minute blocking query in a click handler", as
though a synchronous portal query in `submit_form` were new. It is not: `form.ex:217` already calls
`ReportFilter.get_filter_values/2`, which runs `PortalDbs.query/2` at `report_filter.ex:75`, on every
submit of every report.

The async decision is still correct, but for a reason the spec does not state. `get_filter_values/2`
is an id lookup over the ids already chosen and its cost does not grow with the cohort, while the
count runs the learner join and is slowest for exactly the large cohorts the warning targets. Record
that as the reason, because the stated one invites a reviewer to check `submit_form`, find the
existing blocking query, and conclude the constraint is not real.

The same correction applies to "a report without `enable_app_filter` runs no count query and never
warns, so non-log reports pay nothing". That is true of the new count only. Every submit already pays
for `get_filter_values/2`.

### Dropped after verification

Each of these was a candidate finding that the code or a run contradicted:

- **"The predicate lands in the wrong place because `apply_app/2` runs before `apply_date_range/3`."**
  False, and the plan's reasoning is right. Captured from the running builder: with no dates the
  emitted clause order is `WHERE (log.app = 'CLUE') AND (log.secure_key IN ('KEY1','KEY2'))`, and with
  a date range the two partition predicates stay adjacent, because `get_sql/1` reverses the `where`
  list (`report_query.ex:18`).
- **"`app: ""` will not produce byte-identical SQL."** False. Both `nil` and `""` reproduce the
  captured pre-change baseline exactly, with and without a date range.
- **"The README agreement test does not work as written."** False. Run verbatim, it finds both DDL
  blocks and both agree with the Elixir list. The values are comma-separated with no whitespace, so
  the plain `String.split(values, ",")` is right.
- **"`@filter_keys` will catch a missing `report_filter_json/1` change."** Already recorded as
  resolved in the first round, and re-confirmed both directions: struct field alone leaves the suite
  green at 519, and adding the JSON key without updating `@filter_keys` produces exactly 2 failures.
- **"`period_months/2`'s named values are wrong."** False. All seven reproduce: 444, 10, 22, 1, 0,
  316 (start only) and 138 (end only).
- **"The `app` value can still break out of the string literal."** False. `NotAnApp`, `CL'UE` and
  `CLUE' OR '1'='1` are all rejected with `{:error, _}`, and the app error is returned ahead of the
  no-learners error when both apply.
- **"The form bridge will not carry `app` into `form.params`."** False. `form_updated`
  (`form.ex:97-113`) rebuilds the form from the whole `filter_form` params map, so `app` rides along
  the way `start_date` does, and `from_form/2` with the added `Map.put` reads `"CLUE"`, `""` and a
  missing key as `"CLUE"`, `""` and `nil` respectively.

**Decision**: reworded to cost (decided 2026-09-04). The step now states that `submit_form` already
runs a synchronous portal query at `form.ex:217`, that the count differs by growing with the cohort,
and that the settling argument is that an inline call cannot report progress. The "non-log reports
pay nothing" claim is now scoped to the new count.

