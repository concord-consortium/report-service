# Date ranges use the server's receipt time and include their last day

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-182

**Status**: **Closed**

## Overview

The three log reports (`student-actions`, `student-actions-with-metadata` and `teacher-actions`) selected rows in a date range by the user's device clock. They now select by the time the log server received each event, so a device with a wrong clock can no longer move its events onto the wrong day or out of the range. Every report's date range also includes its last day, which the learner selection and `teacher-actions` used to drop.

## Requirements

- **R1. Filter rows on `timestamp`.** For a range `S` to `E` (ISO dates, UTC days, both inclusive), the two Student Actions reports filter rows with `log.timestamp >= <S 00:00:00.000 UTC in epoch ms>` and `log.timestamp < <(E + 1 day) 00:00:00.000 UTC in epoch ms>`. No predicate on `log.time` remains. A range with only `S` or only `E` emits only that bound; no dates emits neither.
- **R2. Keep the partition pruning, widened by a day.** The `year`/`month` lower bound is the month of `S - 1 day`, and the upper bound is the month of `E + 1 day`, in the same clause shape as before. A range whose start is not the 1st and whose end is not the last day of a month prunes exactly as before.
- **R3. The partition estimate matches the predicate.** `PartitionEstimate.period_months/2` counts the months the widened predicate admits, still clamped to the projection, so the form's warning reports what Athena will probe.
- **R4. Say which clock the range uses.** On the forms of the three log reports only, beside the date inputs, text says the dates are the days the server received each event, in UTC, both days included. On the two Student Actions forms only, the note adds that only students who launched the activity on one of the dates (UTC) are included, so one who launched it earlier and kept working is left out. The server README's "Student Actions", "Student Actions with Metadata" and "Teacher Actions" descriptions say the same as their forms.
- **R5. Tests.** The generated SQL filters on `timestamp` with the exact millisecond bounds at both ends and contains no `log.time` predicate; start-only and end-only ranges emit one bound. The partition clauses widen into the previous month for a start on the 1st and into the next month for an end on a month's last day (including a year boundary), and do not widen mid-month. `period_months/2` agrees with the widened clauses. R4's text renders on the three log reports' forms and not on `student-answers`; the learner sentence renders on the two Student Actions forms and not on `teacher-actions`. Row inclusion is pinned through the SQL; row behavior was shown on a real SQL engine while speccing and on real data (see Decisions).
- **R6. Staging check.** A `student-actions` run for a date range on staging: the SQL Athena ran (read by the run's `athena_query_id` from the API's run JSON) shows the `timestamp` bounds and the widened partition clauses, every returned row's `timestamp` is inside the range, and the check reports how many rows have a client `time` outside it. *(Done at release on the deployed staging server; see Not Yet Implemented.)*
- **R7. Release note.** The release that carries this states: "Student Actions and Student Actions with Metadata now select log events by the day the server received them (UTC) rather than by the student device's clock. Counts at the edges of a date range can differ from earlier runs, for students whose device clock was wrong. Every report with a date range now includes runs started on its last day: before, the latest date matched only runs started at midnight, so a one-day range found no learners. Teacher Actions also selects log events by the server's receipt day and now includes its last day, which it previously cut off after the first second." *(Done at release; see Not Yet Implemented.)*
- **R8. The learner selection includes the end day.** `ReportUtils.apply_end_date/3` emits `run.start_time < '<E + 1 day>'` in place of `run.start_time <= 'E'`. This is shared by every report that takes a date range: the four log and answer reports through `LearnerBaseQuery`, Student ID Mapping, Student Metadata, and the portal metrics reports. A malformed end date still raises.
- **R9. Tests for R8.** `report_utils_test.exs` pins `run.start_time < '2026-02-02'` for an end date of `2026-02-01`, a month and year rollover, and a leap day; the SQL expectations in `learner_base_query_test.exs`, `detailed_metrics_by_school_report_test.exs` and `summary_metrics_by_subject_area_report_test.exs` move to the new bound.
- **R10. `teacher-actions` filters on `timestamp` and includes its end day.** `apply_log_start_date/3` and `apply_log_end_date/3` emit the same bounds as R1, and the Student Actions reports build their `timestamp` clauses through these two functions, so the bounds have one definition. A malformed date raises `ArgumentError` through `iso_date!/1` instead of being dropped; `nil` and `""` apply no bound. On staging it is checked by the SQL Athena ran alone (see Decisions).
- **R11. Tests for R10.** `report_utils_test.exs` pins both log bounds for a date, the end bound across a month, a year and a leap day, a one-day range (`>= 1751241600000` and `< 1751328000000` for `2025-06-30`), no bound for `nil` and `""`, and the raise for a value that is not a date.

## Technical Notes

- The log ingester (`cloud-formation/log-ingester.json`, the Firehose transform) writes `timestamp`, API Gateway's receipt time in epoch milliseconds, and `time`, the client's clock in epoch seconds (falling back to `timestamp / 1000` only when the client sends none). Every row has `timestamp` (Doug's backfill; counted 0 null and 0 zero on staging's whole history and production's April of every year, 2026-10-15).
- **The `year` and `month` partitions are folder time, not `timestamp`.** The nightly partitioner (`partitioner/src/index.js`) files every row of a raw folder day under that day's `year` and `month`. A raw folder is the UTC hour the Firehose buffer opened, and REPORT-107 measured rows up to 119.8 s past their object's name time and none more than 0.1 s before it. So events from a month's first two minutes can sit in the previous month's partition, and in principle an event in a month's last fraction of a second can sit in the next one. That is why the pruning widens by a day on each side.
- MySQL compares a DATETIME with a date-only string at that day's midnight (checked on 5.7.42 and 8.0.39), which is why `run.start_time <= 'E'` dropped the end day. rigse writes a `portal_runs` row, in UTC, each time a student presses Run.
- `teacher-actions` reads `logs_by_time` (`processed_logs_with_id/`, unpartitioned); the Student Actions reports read `logs_by_app_and_secure_key`. `time` and `timestamp` are `bigint`, so integer literals compare directly. The `time` column stays in the output; only the filter moved.
- Worked bounds for `2024-09-01` to `2025-06-30`: `log.timestamp >= 1725148800000`, `log.timestamp < 1751328000000`; partitions `2024-08` to `2025-07` (12 months, against 10 before).
- `ReportQuery.partition_date/2` is the one function that gives a range's widened month, used by both `apply_date_range/3` and `PartitionEstimate`.
- Report-server stores no run SQL, and the run page shows the Athena query id only for a failed run (`custom_components.ex:140-165`). The id is in the API's run JSON (`athena_query_id`, `report_json.ex:32`).
- The clean cut for REPORT-150: a run ending on day `E` holds rows with `timestamp < (E + 1) 00:00 UTC`.
- **Checked on real data before release (local server, 2026-10-21).** Staging: one-day `student-actions` for class 590 selected 3 learners (0 under the old bound), and the run's SQL showed the `timestamp` bounds with every row inside the day; a one-day `teacher-actions` run's SQL showed the new bounds. Production: one-day `student-actions` for class 90310 selected 5 learners (0 under the old bound), with every returned row inside the day. Neither environment had rows whose client `time` fell outside the range.

## Out of Scope

- **Which learners a range selects.** The range still selects learners with a run started in it (R8 fixes only its end day). A learner who launched before the range and kept working into it is not selected; the two Student Actions forms say so (R4).
- The cursor for REPORT-150's route and dedup of overlapping log pulls by `id` (REPORT-150, REPORT-152).
- The legacy query-creator Lambda's user log report (`query-creator/create-query/steps/aws.js:614-619`), which still filters `logs_by_time` on `time`.
- cc-data documentation of the two clocks.
- Re-running or rewriting existing report runs: earlier runs keep their results.

## Not Yet Implemented

- **R6, the staging check on the deployed staging server**: done at release, not in a commit. The same checks passed against staging and production data from a local server before release (Technical Notes).
- **R7, the release note**: goes in the GitHub release for the report-server version that carries this.

## Decisions

### Exclusive next-midnight end bound or inclusive 23:59:59.999
**Context**: Jira said "the end of the end day". Both are the same set for integer milliseconds.
**Options considered**:
- A) `timestamp < (E + 1) 00:00:00.000`
- B) `timestamp <= E 23:59:59.999`

**Decision**: A. No magic `.999`, and it is the same half-open form REPORT-107's conventions use (`[T1, T2)`).

---

### Widen the pruning on both sides or only the start
**Context**: The start side is measured; the end side is a sub-second rounding case, and widening it adds a month for any range ending on a month's last day.
**Options considered**:
- A) Widen both sides by a day.
- B) Widen only the start.

**Decision**: A. A school-year range probes 12 months against 10, so with every application selected the learner count at Athena's partition limit drops from 6,250 to 5,208. The form's warning stays exact, and a report that silently drops an in-range row is the failure this story exists to remove.

---

### How the row-inclusion test is met
**Context**: The server's test suite has no SQL engine for Athena queries; tests pin the generated SQL as a string.
**Options considered**:
- A) Pin the SQL in ExUnit, and show row behavior on a real SQL engine while speccing plus the staging check.
- B) Add an in-Elixir evaluator of the predicate.
- C) Add DuckDB to the server's test dependencies.

**Decision**: A. B tests a re-implementation, not the SQL Athena runs; C adds a native extension to the dependencies and CI for one predicate. The pinned strings fail on every mutation tried.

---

### The learner selection drops learners whose only runs started on the end day
**Context**: `run.start_time <= 'E'` compares as `E 00:00:00`; shared by every report with a date range.
**Options considered**:
- A) A backlog story.
- B) Fix it in REPORT-182 and rewrite the Jira story to cover it.
- C) Leave it.

**Decision**: B (Doug, 2026-10-15): R8 and R9.

---

### `teacher-actions` keeps the client clock and drops its end day
**Context**: It filtered `logs_by_time` on `log.time` and ended at `time <= <E 00:00:00>`, keeping only the end day's first second.
**Options considered**:
- A) A backlog story.
- B) Add it to REPORT-182.
- C) Leave it.

**Decision**: B (Doug, 2026-10-15): R10 and R11, covered by the form note and the release note.

---

### When to check that no row lacks `timestamp`
**Context**: A row with a null `timestamp` would drop out of every range under R1.
**Options considered**:
- A) At the staging check.
- B) Before implementation.

**Decision**: B, on Doug's go (2026-10-15): over `logs_by_app`, staging's whole history (25.8 million rows) and production's April of every year (377.7 million rows) had 0 null and 0 zero. `logs_by_time` was not counted: Doug did the backfill and declined that count (2026-10-19), and no null or zero check was added to the code.

---

### The form note described only the event filter
**Context**: For Student Actions the range also selects learners by run start, so a learner who launched before the range and worked in it is absent.
**Options considered**:
- A) Leave the note as it is.
- B) A learner sentence on the two Student Actions forms and their README lines only.
- C) The sentence on all three log reports.

**Decision**: B (Doug, 2026-10-19), through a second form option, `run_start_learners`. Not C: `teacher-actions` selects no learners.

---

### How R6 reads the SQL Athena ran
**Context**: The run page shows the query id only for a failed run, and no report-run field stores the SQL.
**Options considered**:
- A) Read the run page.
- B) Take `athena_query_id` from the API's run JSON and read the query text from Athena.

**Decision**: B. R6 also requires every returned row's `timestamp` inside the range and reports how many rows have a client `time` outside it, so it has an observable pass condition.

---

### Check `teacher-actions` on staging by its SQL alone
**Context**: Staging's `logs_by_time` (`s3://log-ingester-qa/processed_logs_with_id/`) holds no objects, and production's is unpartitioned, so a row check returns nothing on staging and scans the whole table on production.
**Options considered**:
- A) A one-day `teacher-actions` run returning that day's events.
- B) The SQL Athena ran shows the `timestamp` bounds.

**Decision**: B (Doug, 2026-10-21). The bounds are the shared functions R11 pins and R6's row check exercises; the Jira description matches.

---

### One function for the widened month, shared by the predicate and the estimate
**Context**: The widening has to agree in two modules.
**Options considered**:
- A) A public `ReportQuery.partition_date/2` both call.
- B) Duplicate the `Date.add` in `PartitionEstimate` and assert agreement in a test.

**Decision**: A. The agreement is structural, and `normalize_date/1` lost its only outside caller and became private.

---

### A dedicated form option rather than keying off the report type
**Context**: The note belongs on the three log reports, which are also the three `api_report_type: :log` reports.
**Options considered**:
- A) `server_time_dates: true` on the three reports.
- B) Show the note for every `:log` report.

**Decision**: A. Which clock a report's dates use follows from its query, not its API type, and it matches how the form's other per-report options are declared. The learner sentence gets its own option, `run_start_learners`, rather than riding on `enable_app_filter`.
