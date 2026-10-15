# Date ranges use the server's receipt time and include their last day

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-182
**Repo**: https://github.com/concord-consortium/report-service
**Implementation Spec**: [implementation.md](implementation.md)
**Status**: **In Development**

## Overview

The three log reports (`student-actions`, `student-actions-with-metadata` and `teacher-actions`) select rows in a date range by the user's device clock. This change makes them select by the time the log server received each event, so a device with a wrong clock can no longer move its events onto the wrong day or out of the range. It also makes every report's date range include its last day, which the learner selection and `teacher-actions` drop today.

## Project Owner Overview

A researcher who pulls a log report for "September 1 to June 30" expects every event the server received in that window. Today the report decides by the clock on the student's Chromebook or tablet, which can be off by hours, days or years, so some events land outside the range or drop out of it. Every logged event already carries the server's own receipt time, so the report can use that instead.

Two other date bugs go with it. Every report first picks learners who started the activity in the range, and that check ignores anyone who started on the range's last day, so a one-day report finds almost no one. Teacher Actions misses nearly all of its last day the same way. Both are fixed here.

It also matters for the Researcher Dashboard: a nightly log run and the recent-logs route (REPORT-150) can then be cut at the same server instant. Counts at the edges of a range can differ from earlier runs of the same filter, for students whose device clock was wrong, and the release notes say so.

## Background

The log ingester (`cloud-formation/log-ingester.json`, the Firehose transform) writes two times on every event: `timestamp`, API Gateway's receipt time in epoch milliseconds, and `time`, the client's own clock in epoch seconds, which falls back to `timestamp / 1000` only when the client sends none. Activity Player sends its own clock, so `time` is nearly always the device's. Every row has `timestamp` (Doug did the timestamp work and backfilled it; confirmed by a count of `logs_by_app` on 2026-10-15, see Open Questions). The research behind this story is in global oob `streams/researcher-dashboard/log-cursor-and-dedup.md` and the landing tracker's "Hee-Sun Lee and Sam Gweon's variables" decision 4.

Today `ReportQuery.apply_date_range/3` (`server/lib/report_server/reports/report_query.ex:181-214` at `master` `ceaaf23`) emits, for a range `S` to `E`:

- partition pruning on the nightly copy's `log.year` and `log.month`: `(year > S.year OR (year = S.year AND month >= S.month))` and the mirror for `E`;
- a row filter on the client clock: `log.time >= <S 00:00:00 UTC, unix seconds>` and `log.time <= <E 23:59:59 UTC, unix seconds>`.

`get_athena_query/3` is called by both `StudentActionsReport` and `StudentActionsWithMetadataReport`, so both reports change together. `PartitionEstimate.period_months/2` counts the (year, month) pairs the same predicate admits, for the form's partition warning, and `normalize_date/1` is public so the two bound a range identically.

**The `year` and `month` partitions are server time, but folder time, not `timestamp`.** The nightly partitioner (`partitioner/src/index.js`) copies one raw folder day `processed_logs_with_id/YYYY/MM/DD` and files every row under that folder's `year` and `month` (`mergeSplitJsonToParquet` uses the run's date, not each row's). A raw folder is the UTC hour the Firehose buffer opened. REPORT-107 measured (its requirements.md, "Hour boundaries" and convention 5): up to 1.6% of an hour's rows carry a `timestamp` in the next hour, up to 119.8 s after their object's name time, and no row's `timestamp` is earlier than its object's name time by more than 0.1 s (the name's one-second rounding). So:

- events from the first two minutes of a month can sit in the previous month's partition;
- an event in the last fraction of a second of a month can, in principle, sit in the next month's partition.

Pruning on the start and end months exactly would drop those rows, which is why the pruning is widened by a day on each side.

**The date range also selects learners.** `LearnerData.fetch_and_upload` runs `LearnerBaseQuery.build/4`, which applies the same `start_date` and `end_date` to the portal's `portal_runs.start_time` (`report_utils.ex:37-55`). Its end bound is `run.start_time <= 'E'`, which MySQL compares as `E 00:00:00` (checked on a real `DATETIME NOT NULL` column, the type of rigse's `portal_runs.start_time`, on MySQL 5.7.42 and 8.0.39: a run at `2025-06-30 14:00:00` fails both a one-day range on `2025-06-30` and a range `2025-06-29` to `2025-06-30`; only a run at exactly midnight passes). rigse writes a `portal_runs` row each time a student presses Run (`Portal::Learner#update_last_run`), in UTC. So a learner whose only runs in the range started on its last day is not selected, and neither are their events; a one-day range selects almost no one. R8 fixes that bound for every report that shares it (Doug, 2026-10-15).

**`teacher-actions` has both problems.** It reads `logs_by_time` (no partitions) and filters through `ReportUtils.apply_log_start_date/3` and `apply_log_end_date/3` (`report_utils.ex:72-96`, their only caller), which emit `log.time >= <S 00:00:00>` and `log.time <= <E 00:00:00>`: the client clock, and an end bound that keeps only the end day's first second (a throwaway test printed a one-day range as `log.time <= 1751241600 AND log.time >= 1751241600`). No test covers either function. R10 moves it to the same `timestamp` bounds (Doug, 2026-10-15).

## Requirements

- **R1. Filter rows on `timestamp`.** For a range `S` to `E` (ISO dates, UTC days, both inclusive), the two Student Actions reports filter rows with `log.timestamp >= <S 00:00:00.000 UTC in epoch ms>` and `log.timestamp < <(E + 1 day) 00:00:00.000 UTC in epoch ms>`. No predicate on `log.time` remains. A range with only `S` or only `E` emits only that bound, as today; no dates emits neither.
- **R2. Keep the partition pruning, widened by a day.** The `year`/`month` lower bound is the month of `S - 1 day`, and the upper bound is the month of `E + 1 day`, in the same clause shape as today. A range whose start is not the 1st and whose end is not the last day of a month prunes exactly as today.
- **R3. The partition estimate matches the predicate.** `PartitionEstimate.period_months/2` counts the months the widened predicate admits, still clamped to the projection, so the form's warning (`form.ex:341-353`) reports what Athena will probe.
- **R4. Say which clock the range uses.** On the forms of the three log reports only, beside the date inputs, text says the dates are the days the server received each event, in UTC, both days included. The other reports' forms do not show it (their dates select learners or runs by run start). On the two Student Actions forms only, the note adds that the dates also select students: only students who launched the activity on one of the dates (UTC) are included, so one who launched it earlier and kept working is left out (`teacher-actions` selects no learners, so its note does not say this; Doug, 2026-10-19). The server README's "Student Actions", "Student Actions with Metadata" and "Teacher Actions" descriptions say the same as their forms.
- **R5. Tests.**
  - The generated SQL filters on `timestamp` with the exact millisecond bounds at both ends (start-of-day `>=`, next-midnight `<`) and contains no `log.time` predicate; start-only and end-only ranges emit one bound.
  - The partition clauses widen into the previous month for a start on the 1st and into the next month for an end on a month's last day (including a year boundary), and do not widen mid-month.
  - `period_months/2` agrees with the widened clauses for those cases.
  - R4's text renders on the three log reports' forms and not on `student-answers`, an Athena report whose dates only select learners; the learner sentence renders on the two Student Actions forms and not on `teacher-actions`. `report_form_live_test.exs` already mounts each of these.
  - Row inclusion: a row whose client `time` is outside the range but whose `timestamp` is inside it is included, and the reverse is excluded. The committed tests pin the SQL whose bounds decide this; the row behavior is shown by running the emitted predicate against such rows (see the Judgment call below) and by the staging check.
- **R6. Staging check.** A `student-actions` run for a date range on staging: the SQL Athena ran (read by the run's Athena query id, from the API's run JSON) shows the `timestamp` bounds and the widened partition clauses, and every returned row's `timestamp` is inside the range. The check also reports how many returned rows have a client `time` outside the range, which may be zero on staging's data.
- **R7. Release note.** The release that carries this states both behavior changes: "Student Actions and Student Actions with Metadata now select log events by the day the server received them (UTC) rather than by the student device's clock. Counts at the edges of a date range can differ from earlier runs, for students whose device clock was wrong. Every report with a date range now includes runs started on its last day: before, the latest date matched only runs started at midnight, so a one-day range found no learners. Teacher Actions also selects log events by the server's receipt day and now includes its last day, which it previously cut off after the first second."
- **R8. The learner selection includes the end day.** `ReportUtils.apply_end_date/3` emits `run.start_time < '<E + 1 day>'` in place of `run.start_time <= 'E'`, so a run started at any time on `E` selects its learner. This is shared by every report that takes a date range: the four log and answer reports through `LearnerBaseQuery` (Student Actions, Student Actions with Metadata, Student Answers, Assignment Usage by Student), Student ID Mapping and Student Metadata, and the portal metrics reports (teacher status, summary metrics by subject area, detailed metrics by school, resource metrics summary and details). A malformed end date still raises, as `apply_run_date`'s guard does today.
- **R9. Tests for R8.** `report_utils_test.exs` pins `run.start_time < '2026-02-02'` for an end date of `2026-02-01`, including a month and year rollover (`2025-12-31` gives `'2026-01-01'`) and a leap day; the existing SQL expectations in `learner_base_query_test.exs`, `detailed_metrics_by_school_report_test.exs` and `summary_metrics_by_subject_area_report_test.exs` move to the new bound.
- **R10. `teacher-actions` filters on `timestamp` and includes its end day.** `apply_log_start_date/3` emits `<table>.timestamp >= <S 00:00:00.000 UTC ms>` and `apply_log_end_date/3` emits `<table>.timestamp < <(E + 1 day) 00:00:00.000 UTC ms>`, the same bounds as R1. The Student Actions reports build their `timestamp` clauses through these same two functions, so the bounds have one definition. A malformed date raises `ArgumentError` through the existing `iso_date!/1` guard instead of being dropped (today an impossible but well-shaped date such as `2025-13-01` is dropped silently, widening the report, and other shapes raise `MatchError`); `nil` and `""` still apply no bound.
- **R11. Tests for R10.** `report_utils_test.exs` pins both log bounds for a date, the end bound across a month, a year and a leap day, a one-day range (`>= 1751241600000` and `< 1751328000000` for `2025-06-30`), no bound for `nil` and `""`, and the raise for a value that is not a date.

## Technical Notes

- Files: `server/lib/report_server/reports/report_query.ex` (`apply_date_range/3`), `server/lib/report_server/reports/report_utils.ex` (the log and run date bounds), `server/lib/report_server/reports/partition_estimate.ex`, `server/lib/report_server_web/live/report_live/form.html.heex` (and the form options in `form.ex:499-505` / the reports' `form_options` in `tree.ex:172-185` and `:208-213`), `server/README.md`, tests in `server/test/report_server/report_query_test.exs`, `server/test/report_server/reports/partition_estimate_test.exs`, `server/test/report_server/reports/report_utils_test.exs` and `server/test/report_server_web/live/report_form_live_test.exs`, plus the run-date expectations in `learner_base_query_test.exs` and the two metrics report tests.
- Column types on `logs_by_app_and_secure_key`: `time` and `timestamp` are `bigint`, `year` and `month` are `int` partitions (server README DDL). Integer literals compare directly.
- Worked bounds for the existing test range `2024-09-01` to `2025-06-30`: `log.timestamp >= 1725148800000`, `log.timestamp < 1751328000000`; partitions from `2024-08` to `2025-07` (12 months, against 10 today).
- The `time` column stays in the output unchanged; only the filter moves.
- **Checked while speccing (DuckDB, throwaway).** The proposed predicate for the worked range, run over seven inline rows, keeps exactly: a row with client `time` before the start and `timestamp` inside; a row timestamped 00:01 on Sep 1 but filed under August; the last millisecond of Jun 30, filed under June and under July. It drops: client `time` inside with `timestamp` 1 ms before the start; `timestamp` exactly Jul 1 00:00:00.000; client `time` inside with `timestamp` after the end. Without the widening, the August-filed and July-filed rows are dropped.
- **Checked after R10 was added (throwaway build, deleted).** With R1 to R3 and R10 built together, the Student Actions SQL for the worked range reads `... AND (log.timestamp >= 1725148800000) AND (log.timestamp < 1751328000000)` after the partition and secure key clauses, and the whole server suite fails only the 10 tests that pin the old date SQL and month counts. A malformed date given to `apply_log_start_date/3` raises `ArgumentError`. For the Student Actions reports the learner query runs `iso_date!/1` on the same dates first, so a stored run with a bad date already failed and fails the same way now. `teacher-actions` has no learner query, so such a run would now raise where it ran unbounded; none can reach it, because `check_dates/1` has refused bad dates on every create path (form, API, duplicate) since REPORT-93 and an Athena run calls `get_query` only when it starts (`athena_run_ops.ex:128`).
- **Checked before implementation planning (throwaway Elixir, `Date.add/2` and `DateTime.to_unix(:millisecond)`).** The proposed clause builder gives the bounds above for the worked range; `2025-01-01` to `2025-12-31` widens to `2024-12` and `2026-01` across both year boundaries; `2025-03-15` to `2025-03-20` stays on March alone; a leap day `2024-02-29` alone gives `timestamp` from 1709164800000 to before 1709251200000 and months 2 to 3; start-only and end-only give one side each. The existing `report_query_test.exs`, `partition_estimate_test.exs` and `report_form_live_test.exs` pass at `ceaaf23` (77 tests, 1 skipped) with dummy env vars.
- Report-server does not store a run's SQL (`report_run.ex` fields), and the run page shows the Athena query id only for a failed run (`custom_components.ex:140-165`). The id is in the API's run JSON (`athena_query_id`, `report_json.ex:32`), which cc-data's `reports_list` reads; R6 reads the query text from Athena by that id.
- The clean cut for REPORT-150: a run ending on day `E` holds rows with `timestamp < (E + 1) 00:00 UTC`. Rows from a folder day's first two minutes past midnight belong to the next day under this filter. How REPORT-150 joins its recent rows to a nightly run, and how cc-data deduplicates by `id`, are settled in REPORT-150's and REPORT-152's specs.

## Out of Scope

- **Which learners a range selects.** The range still selects learners with a run started in it (R8 fixes only its end day). A learner who launched before the range and kept working into it is not selected; that is the filter's meaning, not this story's to change. The two Student Actions forms now say so (R4).
- The cursor for REPORT-150's route and dedup of overlapping log pulls by `id` (REPORT-150, REPORT-152).
- The legacy query-creator Lambda's user log report (`query-creator/create-query/steps/aws.js:614-619`, launched from the portal as an external report), which still filters `logs_by_time` on `time`.
- cc-data documentation of the two clocks (no cc-data doc states which clock the server filters on today).
- Re-running or rewriting existing report runs: earlier runs keep their results.

## Open Questions

### RESOLVED: Judgment call: exclusive next-midnight end bound or inclusive 23:59:59.999
**Context**: Jira says "the end of the end day". Both are the same set for integer milliseconds.
**Options considered**:
- A) `timestamp < (E + 1) 00:00:00.000`
- B) `timestamp <= E 23:59:59.999`

**Decision**: A. It has no magic `.999`, and it is the same half-open form REPORT-107's conventions use (`[T1, T2)`), so the route and the report read alike.

### RESOLVED: Judgment call: widen the pruning on both sides or only the start
**Context**: The start side is measured (events from a month's first two minutes sit in the previous month's partition). The end side is a sub-second rounding case. Widening the end adds a whole month of partitions for any range ending on a month's last day, which school-year ranges usually do.
**Options considered**:
- A) Widen both sides by a day (Jira's wording).
- B) Widen only the start.

**Decision**: A. A school-year range (Sep 1 to Jun 30) probes two extra months per learner, 12 against 10, so with every application selected the learner count at Athena's partition limit drops from 6,250 to 5,208. The form's warning stays exact (R3), and a report that silently drops an in-range row is the failure this story exists to remove.

### RESOLVED: Judgment call: how the row-inclusion test is met
**Context**: Jira asks for a test that a row with client `time` outside and `timestamp` inside the range is included, and the reverse excluded. The server's test suite has no SQL engine for Athena queries: tests pin the generated SQL as a string.
**Options considered**:
- A) Pin the SQL in ExUnit, and show row behavior by running the emitted predicate against such rows in a real SQL engine during speccing, plus the staging check.
- B) Add an in-Elixir evaluator of the predicate to the test suite.
- C) Add DuckDB to the server's test dependencies to execute the WHERE clause.

**Decision**: A. B tests a re-implementation, not the SQL Athena runs. C adds a native extension to the server's dependencies and CI (neither has a SQL engine today; `report-server.yml` runs `mix test` only) for one predicate. The pinned strings fail on every mutation tried (7 to 10 failures per bound), and the row behavior is shown on a real engine and on staging.

### RESOLVED: The learner selection drops learners whose only runs started on the end day
**Context**: `run.start_time <= 'E'` compares as `E 00:00:00`, so end-day runs never select their learner. Shared by every report with a date range.
**Options considered**:
- A) A backlog story for every report.
- B) Fix it in REPORT-182, retitling and rewriting the Jira story to cover it.
- C) Leave it.

**Decision**: B (Doug, 2026-10-15). R8 and R9. A throwaway change to `apply_end_date/3` failed exactly the 8 tests that pin the old string (in `report_utils_test.exs`, `learner_base_query_test.exs` and the two metrics report tests) and nothing else in the suite.

### RESOLVED: `teacher-actions` keeps the client clock and drops its end day
**Context**: `teacher-actions` filters `logs_by_time` on `log.time` and ends at `time <= <E 00:00:00>`, so it misses nearly all of the end day. Outside the story's original Jira scope.
**Options considered**:
- A) A backlog story moves it to `timestamp` with the same bounds.
- B) Add it to REPORT-182.
- C) Leave it.

**Decision**: B (Doug, 2026-10-15). R10 and R11, with the form note (R4) and release note (R7) covering it. With R8 every other report includes its end day, so leaving `teacher-actions` would keep the one known instance.

### RESOLVED: When to check that no row lacks `timestamp`
**Context**: "Every row has `timestamp`" came from Doug's backfill and needed an Athena read to confirm. A row with a null `timestamp` would drop out of every range under R1.
**Options considered**:
- A) At the staging check, as the implementation plan's precondition.
- B) Now, before implementation.

**Decision**: B, run on Doug's go (2026-10-15), over `logs_by_app` (the same files as `logs_by_app_and_secure_key`, partitioned without `secure_key`), counting null and zero `timestamp` per year:
- **Staging, all of history** (`log_ingester_qa`, 2015 to 2026, 25.8 million rows, 200 MB scanned): 0 null, 0 zero.
- **Production, April of every year** (`log_ingester_production`, 2014 to 2026, 377.7 million rows, 2.86 GB scanned): 0 null, 0 zero.

Rows written since the transform Lambda carry `timestamp` by construction (`cloud-formation/log-ingester.json` lines 159 and 168 to 173), and the backfilled years show none missing. `logs_by_time`, which `teacher-actions` reads, is a separate copy (`processed_logs_with_id/`) and was not counted: Doug did the backfill and declined that count (2026-10-19).

## Self-Review

Roles: Senior Engineer, QA Engineer, Education Researcher, DevOps Engineer, Performance Engineer. Findings that did not survive a code check are not recorded.

### QA Engineer

#### RESOLVED: R6 said the run page shows the SQL
It does not: the run page shows only the Athena query id, and no report-run field holds the SQL. R6 now reads the query text from Athena by that id.

#### RESOLVED: R6 had no observable pass condition for "returns rows by server receipt time"
R6 now requires every returned row's `timestamp` to be inside the range, and reports how many have a client `time` outside it.

### Education Researcher

#### RESOLVED: The form note and README describe only the event filter
For Student Actions the range also selects learners with a run started in it (`learner_base_query.ex:128-129`), so a learner who launched before the range and worked in it is absent. Decision B (Doug, 2026-10-19): a learner sentence on the two Student Actions forms and their README lines only, through a second form option (R4). Not C: `teacher-actions` selects no learners.

### QA Engineer (second pass)

#### RESOLVED: R4 and R5 called `student-answers` a portal report
It is an Athena report (`athena/student_answers_report.ex:2`) whose dates only select learners; R4 and R5 now say so.

#### RESOLVED: R10 said a malformed date is dropped silently today
Only an impossible but well-shaped date is dropped; `abc` or `2025-06` raises `MatchError` from `String.split` (throwaway run of the current function). R10 now says both.

#### RESOLVED: The stored-run note did not hold for `teacher-actions`
It has no learner query, so the "already failed" reasoning does not apply; the Technical Notes now say why no stored run can reach the new raise.
