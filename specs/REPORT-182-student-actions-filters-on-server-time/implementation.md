# Implementation Plan: Date ranges use the server's receipt time and include their last day

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-182
**Requirements Spec**: [requirements.md](requirements.md)
**Status**: **In Development**

## Implementation Plan

### Filter the log reports on `timestamp` and widen the partition bounds

**Summary**: R1, R2, R3, R5's SQL and estimate tests, R10 and R11. `ReportUtils.apply_log_start_date/3` and `apply_log_end_date/3` emit the `timestamp` bounds; `teacher-actions` already calls them, and `apply_date_range/3` now calls them too, so all three log reports share one definition of the bounds. `apply_date_range/3` keeps only the partition clauses, a day wider on each side, and `PartitionEstimate` counts months through the same function, so the two cannot drift. One commit: the estimate and the predicate have to change together or the form's warning is wrong.

**Files affected**:
- `server/lib/report_server/reports/report_utils.ex`: `apply_log_start_date/3` and `apply_log_end_date/3` emit `timestamp` bounds; `apply_log_date/4` (public, no outside caller) is replaced by a private `apply_log_date/5`.
- `server/lib/report_server/reports/report_query.ex`: `apply_date_range/3` rewritten; new public `partition_date/2`; `normalize_date/1` becomes private (its only outside caller moves to `partition_date/2`), and its "public so PartitionEstimate..." comment goes.
- `server/lib/report_server/reports/partition_estimate.ex`: `bound/2` becomes `bound/3`, reading `ReportQuery.partition_date/2`.
- `server/test/report_server/reports/report_utils_test.exs`: a new `describe` for the log date bounds.
- `server/test/report_server/report_query_test.exs`: `@date_clauses` split in two; new date-range tests.
- `server/test/report_server/reports/partition_estimate_test.exs`: expected counts and three test names updated; widening tests added.

**Estimated diff size**: ~180 lines

`report_utils.ex`, replacing `apply_log_start_date/3` through `apply_log_date/4` (`report_utils.ex:72-96`):

```elixir
  def apply_log_start_date(where, start_date, table_name \\ "log") do
    apply_log_date(where, start_date, 0, ">=", table_name)
  end

  def apply_log_end_date(where, end_date, table_name \\ "log") do
    apply_log_date(where, end_date, 1, "<", table_name)
  end

  # Log dates are UTC days of server receipt: `timestamp` is epoch milliseconds, and the end day is
  # included by bounding below the next day's midnight.
  defp apply_log_date(where, date, shift_days, cmp, table_name) do
    if String.length(date || "") > 0 do
      ms =
        date
        |> iso_date!()
        |> Date.from_iso8601!()
        |> Date.add(shift_days)
        |> DateTime.new!(~T[00:00:00], "Etc/UTC")
        |> DateTime.to_unix(:millisecond)

      ["#{table_name}.timestamp #{cmp} #{ms}" | where]
    else
      where
    end
  end
```

`report_query.ex`, replacing `apply_date_range/3` through the end of the module (the `get_athena_query/3` call site is unchanged; the module already aliases `ReportUtils`):

```elixir
  # The `year` and `month` partitions are the UTC day of the raw folder an event was written to,
  # which can differ from its `timestamp` day by minutes at the start of a day and by a fraction of
  # a second at the end, so the partition bounds are widened by a day on each side.
  defp apply_date_range(where, start_date, end_date) do
    start_clauses =
      case partition_date(start_date, :start) do
        {:ok, month} -> ["(log.year > #{month.year} OR (log.year = #{month.year} AND log.month >= #{month.month}))"]
        _ -> []
      end

    end_clauses =
      case partition_date(end_date, :end) do
        {:ok, month} -> ["(log.year < #{month.year} OR (log.year = #{month.year} AND log.month <= #{month.month}))"]
        _ -> []
      end

    (where ++ start_clauses ++ end_clauses)
    |> ReportUtils.apply_log_start_date(start_date)
    |> ReportUtils.apply_log_end_date(end_date)
  end

  @doc """
  The day whose month bounds a range's partitions: a day before the start, or a day after the end.

  Public so PartitionEstimate counts exactly the months apply_date_range/3 prunes to.
  """
  def partition_date(date_str, :start), do: shift_date(normalize_date(date_str), -1)
  def partition_date(date_str, :end), do: shift_date(normalize_date(date_str), 1)

  defp shift_date({:ok, date}, days), do: {:ok, Date.add(date, days)}
  defp shift_date(other, _days), do: other

  defp normalize_date(nil), do: nil
  defp normalize_date(""), do: nil
  defp normalize_date(date_str), do: Date.from_iso8601(date_str)
end
```

A malformed date now raises in `apply_log_date/5` rather than leaving the range unbounded. For the Student Actions reports the learner query (`apply_run_date`) already raises on the same dates first. `teacher-actions` has no learner query, but `check_dates/1` refuses bad dates on every create path and an Athena run calls `get_query` only when it starts, so no stored run that worked before can reach the raise.

`partition_estimate.ex`:

```elixir
    max(min(bound(end_date, :end, last), last) - max(bound(start_date, :start, first), first) + 1, 0)
  ...
  # an absent or unparseable bound falls back to the projection's edge, so a half-open range runs to it
  defp bound(date, side, default) do
    case ReportQuery.partition_date(date, side) do
      {:ok, parsed} -> ordinal(parsed.year, parsed.month)
      _ -> default
    end
  end
```

The `period_months/2` doc ("The number of (year, month) pairs the emitted date predicate admits") stays true and stays as is.

**Tests, `report_utils_test.exs`**, a new `describe "the log date bounds"`:

- "a date bounds `timestamp` from its midnight to the next": `apply_log_start_date([], "2025-06-30") == ["log.timestamp >= 1751241600000"]` and `apply_log_end_date([], "2025-06-30") == ["log.timestamp < 1751328000000"]`, so a one-day range covers the whole day.
- "the end bound crosses a month, a year and a leap day": `"2026-01-31"` gives `< 1769904000000`, `"2025-12-31"` gives `< 1767225600000`, `"2024-02-28"` gives `< 1709164800000`.
- "the table name is honored": `apply_log_start_date([], "2025-06-30", "l") == ["l.timestamp >= 1751241600000"]`.
- "an absent bound is not applied": `nil` and `""` leave `["w"]` for both.
- "a value that is not a date is refused": the same payloads as the run-date test raise `ArgumentError` for both functions.

**Tests, `report_query_test.exs`.** `get_sql/1` reverses the where list, so the emitted order is end partition, start partition, the filter clauses, then start and end `timestamp`:

```elixir
    @partition_clauses "((log.year < 2025 OR (log.year = 2025 AND log.month <= 7))) AND " <>
                         "((log.year > 2024 OR (log.year = 2024 AND log.month >= 8)))"
    @timestamp_clauses "(log.timestamp >= 1725148800000) AND (log.timestamp < 1751328000000)"
```

The three existing date-range tests expect `WHERE #{@partition_clauses} AND #{@secure_key_clause} AND #{@timestamp_clauses}`, with `(log.app IN ('CLUE')) AND ` before the secure key clause in the application case. New tests in the `get_athena_query/3` describe:

- "a date range filters on the server's receipt time, never the client clock": `refute sql =~ ~r/log\.time\b/` (the `\b` keeps `log.timestamp` from matching).
- "a start-only range emits its lower bounds alone": `%ReportFilter{start_date: "2024-09-01"}` gives exactly `WHERE ((log.year > 2024 OR (log.year = 2024 AND log.month >= 8))) AND #{@secure_key_clause} AND (log.timestamp >= 1725148800000)`.
- "an end-only range emits its upper bounds alone": `end_date: "2025-06-30"` gives `WHERE ((log.year < 2025 OR (log.year = 2025 AND log.month <= 7))) AND #{@secure_key_clause} AND (log.timestamp < 1751328000000)`.
- "a range across a year widens into the neighboring years": `2025-01-01` to `2025-12-31` gives `((log.year < 2026 OR (log.year = 2026 AND log.month <= 1))) AND ((log.year > 2024 OR (log.year = 2024 AND log.month >= 12)))`, the secure key clause, then `(log.timestamp >= 1735689600000) AND (log.timestamp < 1767225600000)`.
- "a mid-month range does not widen": `2025-03-15` to `2025-03-20` gives `log.month <= 3` and `log.month >= 3` on 2025, then `(log.timestamp >= 1741996800000) AND (log.timestamp < 1742515200000)`.

Each pins whole strings, so dropping the widening, using `<=` at the end, or bounding the end at the end day's own midnight fails at least one.

**Tests, `partition_estimate_test.exs`.** Expected values from the throwaway run (see Verification):

| Test | Old | New |
|---|---|---|
| partial-year `2024-09-01` to `2025-06-30` | 10 | 12 |
| multi-year `2023-09-01` to `2025-06-30` | 22 | 24 |
| single month `2024-03-01` to `2024-03-31` | 1 | 3 (rename: "a whole month also admits the months either side") |
| start-only `2024-09-01` | 316 | 317 |
| end-only `2025-06-30` | 138 | 139 |
| entirely before, `2000-01-01` to `2013-12-31` | 0 | 1 (rename: "a range ending just before the projection admits only its first month") |
| entirely after, `2051-01-01` to `2060-12-31` | 0 | 1 (rename: "a range starting just after the projection admits only its last month") |

Add "a mid-month range admits only its own months": `period_months("2024-03-02", "2024-03-30") == 1`, and two ranges that sit fully outside the projection by more than a day still give 0 (`"2000-01-01"` to `"2013-12-30"`, and `"2051-01-02"` to `"2060-12-31"`), so the clamp stays covered. The `projected_partitions` threshold tests (`694` learners, `"CLUE"`, school year) stay under the limit and need no change.

---

### Say on the form that the dates are server receipt days

**Summary**: R4 and R5's form test. A `server_time_dates` form option on the three log reports, a note under the date inputs tied to them with `aria-describedby`, a `run_start_learners` form option that adds the learner sentence on the two Student Actions reports, and the README lines.

**Files affected**:
- `server/lib/report_server/reports/tree.ex`: `server_time_dates: true, run_start_learners: true` added to the `form_options` of `student-actions` and `student-actions-with-metadata`, and `form_options: [server_time_dates: true]` added to `teacher-actions` (which has none today).
- `server/lib/report_server_web/live/report_live/form.ex`: `get_form_options/2` adds `server_time_dates: Keyword.get(form_options, :server_time_dates, false)` and `run_start_learners: Keyword.get(form_options, :run_start_learners, false)`.
- `server/lib/report_server_web/live/report_live/form.html.heex`: the note, its learner sentence and the `aria-describedby`.
- `server/test/report_server_web/live/report_form_live_test.exs`: four tests.
- `server/README.md`: the Student Actions, Student Actions with Metadata and Teacher Actions lines.

**Estimated diff size**: ~55 lines

`form.html.heex`, the date block:

```heex
      <div class="mt-4 flex items-center gap-4">
        <span class="font-bold">Include dates:</span>
        <label for="start_date" class="whitespace-nowrap">Earliest date:</label>
        <.input type="date" id="start_date" field={@form["start_date"]}
          aria-describedby={@form_options.server_time_dates && "date_range_note"} />
        <label for="end_date" class="whitespace-nowrap">Latest date:</label>
        <.input type="date" id="end_date" field={@form["end_date"]}
          aria-describedby={@form_options.server_time_dates && "date_range_note"} />
      </div>
      <p :if={@form_options.server_time_dates} id="date_range_note" class="mt-1 text-sm text-gray-600">
        Dates are the days the log server received each event, in UTC. Both dates are included.
        <span :if={@form_options.run_start_learners}>Students are included only if they launched the activity on one of these dates (UTC), so a student who launched it earlier and kept working is left out.</span>
      </p>
```

`.input`'s `:rest` is `:global`, which admits `aria-*`; a `false` value omits the attribute. The learner sentence sits inside the note, so `aria-describedby` reads it too.

README, under "Student Reports" and "Teacher Reports":

```markdown
- **Student Actions**: Low-level log event stream for learners including model-level interactions. The date range selects events by the day the log server received them (UTC), not the student device's clock. It also selects students: only those who launched the activity on a day in the range (UTC) are included, so a student who launched it earlier and kept working is left out.
- **Student Actions with Metadata**: Student actions plus portal metadata (student, teacher, class, school info). Its date range works as Student Actions' does.
```

and under "Teacher Reports":

```markdown
- **Teacher Actions**: Log events for teacher actions in activities and dashboards. The date range selects events by the day the log server received them (UTC), not the teacher's device clock.
```

Tests, in a new `describe "the date range note"`, each after `choose_first_filter(view)` (the date inputs render only once a first filter is set):

- "renders on student-actions, names the learner selection, and ties both date inputs to it": `has_element?(view, "#date_range_note", "received each event")`, `has_element?(view, "#date_range_note", "launched the activity on one of these dates")`, and `has_element?(view, "#start_date[aria-describedby=date_range_note]")` and the same for `#end_date`.
- "renders on student-actions-with-metadata with the learner sentence": the note with the learner sentence is present.
- "renders on teacher-actions without the learner sentence, which selects no learners": `has_element?(view, "#date_range_note", "received each event")` and `refute has_element?(view, "#date_range_note", "launched the activity")`.
- "does not render on student-answers, whose dates select learners by run start": `has_element?(view, "#start_date")`, `refute has_element?(view, "#date_range_note")` and `refute has_element?(view, "#start_date[aria-describedby]")`.

---

### End every report's run-date bound at the next day

**Summary**: R8 and R9. `apply_end_date/3` bounds `portal_runs.start_time` below the day after the end date, so runs started at any time on the end day select their learner. One shared function, so every report with a date range changes in this commit. Independent of the two steps above: it shares `report_utils.ex` and `report_utils_test.exs` with the first step but none of its functions or tests.

**Files affected**:
- `server/lib/report_server/reports/report_utils.ex`: `apply_end_date/3` and a private `next_day/1`.
- `server/test/report_server/reports/report_utils_test.exs`: the end-bound expectation and new cases.
- `server/test/report_server/reports/learner_base_query_test.exs`: two SQL strings, `<= '2026-06-30'` to `< '2026-07-01'`.
- `server/test/report_server/reports/portal/detailed_metrics_by_school_report_test.exs` and `summary_metrics_by_subject_area_report_test.exs`: `<= '2023-12-31'` to `< '2024-01-01'`, three assertions each.

**Estimated diff size**: ~40 lines

`report_utils.ex`:

```elixir
  # MySQL compares a DATETIME with a date-only string at that day's midnight, so the end day is
  # included by bounding below the next day.
  def apply_end_date(where, end_date, table_name \\ "run") do
    apply_run_date(where, end_date && next_day(end_date), "<", table_name)
  end

  defp next_day(""), do: ""
  defp next_day(date), do: date |> iso_date!() |> Date.from_iso8601!() |> Date.add(1) |> Date.to_iso8601()
```

`iso_date!/1` runs before the shift, so a malformed end date still raises the same `ArgumentError` rather than being shifted or dropped; `nil` and `""` still apply no bound.

Tests, `report_utils_test.exs`:

- "an ISO date is applied to both ends": the end expectation becomes `["run.start_time < '2026-02-02'"]`.
- "the end bound is the next day across a month, a year and a leap day": `"2026-01-31"` gives `'2026-02-01'`, `"2025-12-31"` gives `'2026-01-01'`, `"2024-02-28"` gives `'2024-02-29'`.
- "an absent bound is not applied" gains the end side: `apply_end_date(["w"], nil)` and `apply_end_date(["w"], "")` are `["w"]`.
- "a value that is not a date is refused rather than interpolated" is unchanged and still covers `apply_end_date/3`.

Restoring `<=` or dropping the shift fails the first two; returning a bound for `""` fails the third.

---

### Staging check and release note (no commit)

**Summary**: R6 and R7, done at release, not in a commit.

- **Where to look first.** Staging's log database is `ATHENA_LOG_DB_NAME` on the `report-service-qa` stack's task definition (`config/runtime.exs:179` defaults to `log_ingester_production`; `config/dev.exs:111` uses `log_ingester_qa`), and the Athena account is the one report-server's `SERVER_ACCESS_KEY_ID` belongs to. Read both from the stack and its template in `~/projects/cloud-formation` before any query.
- **The run:** on the staging report-server with this build, a `student-actions` run for a class with recent logs (for example class 590) and a range of a few days ending yesterday. Take the run's `athena_query_id` from the API's run JSON (cc-data `reports_list`; the run page shows the id only for a failed run), then read its SQL from Athena (`aws athena get-query-execution --query-execution-id <id>` in that account) and check the `timestamp` bounds and widened partition clauses. Download the CSV and check every row's `timestamp` is inside the range; report how many rows have a `time` outside it.
- **Release note (R7):** the text in the requirements spec, in the GitHub release for the report-server version that carries this.
- **R8 on staging:** a one-day `student-actions` run for a day on which a test student launched the activity selects that student (before, it selected no one).
- **R10 on staging:** a one-day `teacher-actions` run for a day with teacher log events returns that day's events, with every row's `timestamp` inside it (before, only events from the day's first second).

## Verification

- **Throwaway build of the whole plan, every named test included (deleted).** All three steps' code and tests on `bfbda61`: the full server suite passes (0 failures) and `mix compile --warnings-as-errors` is clean. Re-run on `ceaaf23` after the rebase (no `server/` change between them): the code alone again compiles clean and fails only the 10 tests that pin the old date SQL and month counts, plus the 8 that pin the old run-date string (`report_utils_test.exs` 1, `learner_base_query_test.exs` 1, each metrics report test 3).
- **Mutations against those tests,** each caught (re-measured on the whole-plan build below):

  | Mutation | Failures |
  |---|---|
  | log end bound at the end day's own midnight | 8 |
  | log end bound `<=` for `<` | 8 |
  | log bounds on `time` instead of `timestamp` | 11 |
  | run-date end bound back to `<= 'E'` | 9 (2 in `report_utils_test.exs`, plus the 7 moved expectations) |
  | no partition widening at the start | 10 |
  | no partition widening at the end | 10 |
  | `server_time_dates` removed from `tree.ex` | 3 (the three rendering tests) |
  | `run_start_learners` removed from `tree.ex` | 2 (the two Student Actions tests) |
  | `run_start_learners` added to `teacher-actions` | 1 |
  | `next_day("")` returning a date | 1 |

- **The whole plan with the learner sentence (throwaway, deleted), on `ceaaf23`:** all three steps' code and every named test: `mix compile --warnings-as-errors` is clean and the full suite runs 1321 tests, 0 failures, 7 skipped. The code alone fails 18 tests (the 10 and 8 above). The implemented branch, with every named test including both fully-outside `period_months` cases, runs 1323.
- **The form step with the learner sentence (throwaway, deleted), on `ceaaf23`:** compiles clean with `--warnings-as-errors`; `report_form_live_test.exs` passes 38 tests, and the full suite 1309 tests, 0 failures, 7 skipped. The three form-option rows in the table above were measured on this build.
- **MySQL's comparison** was checked on a real `DATETIME NOT NULL` column on 5.7.42 and 8.0.39: `<= '2025-06-30'` keeps only runs up to `00:00:00` that day, and `< '2025-07-01'` keeps the whole day and nothing of Jul 1.
- **One unrelated intermittent failure seen once:** `report_form_live_test.exs` "creates the run when the control was left blank" failed on the first run right after a recompile and passed in 20 reruns of the file and in every full-suite run since. It waits on the learner-count task with `assert_redirect/1`'s default timeout; nothing in this plan touches that path.
- **Bounds and widening (throwaway Elixir and DuckDB, deleted):** recorded in the requirements spec's Technical Notes.

## Open Questions

### RESOLVED: Judgment call: one function for the widened month, shared by the predicate and the estimate
**Context**: The widening has to agree in two modules, and today they share only `normalize_date/1`.
**Options considered**:
- A) A public `ReportQuery.partition_date/2` both call.
- B) Duplicate the `Date.add` in `PartitionEstimate` and assert agreement in a test.

**Decision**: A. The agreement is then structural, and `normalize_date/1` loses its only outside caller and becomes private.

### RESOLVED: Judgment call: a dedicated form option rather than keying off the report type
**Context**: The note belongs on the three log reports, which are also the three `api_report_type: :log` reports, and `enable_app_filter` marks two of them.
**Options considered**:
- A) `server_time_dates: true` on the three reports.
- B) Show the note for every `:log` report.

**Decision**: A. Which clock a report's dates use follows from its query, not its API type; an explicit option keeps the form honest if a log report ever filters differently, and it matches how the form's other per-report options are declared. The learner sentence gets its own option, `run_start_learners`, for the same reason, rather than riding on `enable_app_filter`, which marks the same two reports today.

## Self-Review

Roles: Commit Reviewer, Test Writer, Operator, Senior Engineer, WCAG Accessibility Expert. Findings that did not survive a check against the code or the throwaway build are not recorded.

### Operator

#### RESOLVED: The staging precondition named a database and AWS profile it had not checked
The Athena database comes from `ATHENA_LOG_DB_NAME` on the stack and the account from report-server's own credentials, neither of which this spec read. The step now says where to read both before querying.

### Self-review, second pass

Roles: QA Engineer, Operator, Performance Engineer, Test Writer, Commit Reviewer, WCAG Accessibility Expert. The whole plan was rebuilt as throwaway code on `ceaaf23` to check each claim.

#### RESOLVED: R6 and the staging step assumed the run page shows the Athena query id
It shows it only for a failed run (`custom_components.ex:140-165`). Both now take `athena_query_id` from the API's run JSON.

#### RESOLVED: The widening's partition cost was given as one extra month
A school-year range gains two (12 against 10); the requirements' judgment call now gives the cost at Athena's limit.

#### RESOLVED: The run-date mutation count and the whole-plan suite count were not measured on the current plan
Restoring `<= 'E'` fails 9 tests, not 2; the whole plan with the learner sentence runs 1323 tests on the implemented branch, 0 failures. Both are in Verification.
