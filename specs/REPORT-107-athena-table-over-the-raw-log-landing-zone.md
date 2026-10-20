# Athena table over the raw log landing zone (`logs_by_hour`)

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-107

**Status**: **Closed**

## Overview

Declare an Athena table, `logs_by_hour`, over the hourly folders where log events land about a minute after they happen. This makes recent log events queryable without waiting for the nightly refile. Document what a query on the table has to know about its data, so that REPORT-150's class-scoped recent-logs route can build on the table. The story changes no report and adds no route; its committed output is `server/README.md`, and `logs_by_hour` was created by hand in staging and production from the DDL there.

## Requirements

All requirements were met. The measured figures are in `server/README.md` ("Querying recent logs").

**The table**

- **R1.** An external table `logs_by_hour` exists in each environment's log database (`log_ingester_qa` on staging, `log_ingester_production` in production, the database `ReportQuery.get_log_db_name/0` names), over `s3://<bucket>/processed_logs_with_id/`. *(Created 2026-10-20 in both.)*
- **R2.** Its columns are the 12 columns of the raw objects: `id, session, username, application, activity, event, event_value` (string), `time` (bigint), `parameters, extras, run_remote_endpoint` (string), `timestamp` (bigint), the order and types of `logs_by_time`. *(Production's objects were checked first and match.)*
- **R3.** One partition key, `dt string`, by partition projection of type `date`, format `yyyy/MM/dd/HH`, interval one hour, range `2014/03/01/00,NOW`, `storage.location.template` `s3://<bucket>/processed_logs_with_id/${dt}/`. No crawler or `MSCK REPAIR`.
- **R4.** `logs_by_time` is not altered, dropped or replaced. It stays the Firehose schema table.
- **R5.** The staging table is created and validated (R7, R8) before the production table is created.

**The README**

- **R6.** `server/README.md` gains the production `logs_by_hour` DDL under "S3 Log Partitioning", next to the two existing tables. The staging variant changes only the bucket. The section's opening sentence and the "recreate when applications change" note are reworded to cover three tables, and the note says `logs_by_hour` needs no change.

**Validation and measurements**

- **R7. Hour count.** For a closed hour in each environment, `count(*)` with `dt = '<hour>'` returns within seconds and equals DuckDB's count of that hour's objects. *(Staging 2026/10/06/15: 1,155. Production 2026/10/14/15: 180,763, 1.1 s.)*
- **R8. Day reconciliation.** For a closed day with learner-keyed rows in each environment, the rows with `dt` from `<day>/00` to `<day>/23` match the nightly copy's files for that day (`<DD>_<n>.parquet`, read through `logs_by_app`), compared by `id`. *(Staging 2026-10-06 and 2026-10-12, production 2026-10-14 with 1,849,364 rows: no `id` on one side only and none repeated.)*
- **R9. Cost figures.** Bytes scanned and query time for `count(*)` over one closed hour, day and month in production, plus `count(DISTINCT run_remote_endpoint)` over the day, are recorded in the README with the date measured. *(`count(*)` scans 0 bytes, answered from Parquet metadata; the column-reading day query scanned 2.35 MB.)*
- **R10. Pre-Firehose history.** The README states that before the Firehose cutover (2022-01-01 00:00 UTC in production, 2021-12-20 14:00 UTC on staging) each day with data is one file in its `00` hour folder, so only whole-day ranges are meaningful there.

**Query conventions** (the contract REPORT-150 builds on)

- **R11.** A "Querying recent logs" section in the README states these conventions, each with its measured fact:
  1. **Always give `dt` a lower bound.** Without one, a query plans over more than 100,000 projected hours. Athena never projects hours after `NOW`.
  2. **Window on `timestamp`, not `time`.** `timestamp` is server receipt time in epoch milliseconds, the clock the folders follow; `time` is the client's clock in seconds, falling back to receipt time when the client sends none. Every row has a `timestamp`.
  3. **Pad the `dt` range by one hour on each side, then filter on `timestamp`.** An event can sit one folder early (up to about two minutes into the next hour); in the measured hours none sat more than one early or in a later folder.
  4. **The current hour is partial**, and a folder can receive objects for about two minutes after its hour ends.
  5. **The nightly copy of day D is exactly the raw folders `D/00` to `D/23`.** It is filed under D's own `year` and `month`, and by `timestamp` it can hold events from the first two minutes of D+1, and miss some from the first two minutes of D, which sit in D-1's copy. So at a month's end the first minutes of the next month sit in the earlier month. It exists only after the 02:00 UTC partitioner run for D finishes, which writes no completion marker and has no retry. How a caller combines the two tables, and when it treats D as complete, is REPORT-150's to set.
  6. **Scope by row, not by prefix.** There is no `app` or `secure_key` level, so a learner or class filter is a row predicate and a query reads every application's bytes for its hours. The limit is Athena's 262,144-byte query text, not a prefix count.
  7. **`application` is the raw client value** (`Activity Player`), not the sanitized `app` value (`Activity_Player`) that `AthenaConfig` lists.

**`logs_by_app`**

- **R12.** `logs_by_app` stays in the README as a supported route: an app-scoped cohort with no learner bound, and the only way to read the nightly copy without a learner list (as R8 does). Its cost on one closed app-month in production is recorded against the same month through `logs_by_app_and_secure_key` with a bounded secure-key sample, as `count(*)` and as `count(DISTINCT session)`. *(CLUE, September 2026, against 20 learner keys: planning 0.5 s or less, about 40 bytes scanned per row on both.)*
- **R13.** `athena_config_test.exs` stays green without changes, since the new DDL declares only `projection.dt.*`. *(14 tests, 0 failures.)*

**Report-server's access**

- **R14.** The production report-server user's IAM is read and recorded (Technical Notes). No IAM change; a gap is a fact for REPORT-150.

## Technical Notes

- **Where the data comes from.** API Gateway stamps each request with its receipt time; a Firehose transform Lambda assigns a random 21-character `id`, writes receipt time to `timestamp` and the client clock to `time` (receipt time in seconds when the client sends none). Firehose buffers 60 s or 64 MB and writes Snappy Parquet under `processed_logs_with_id/YYYY/MM/DD/HH/`, the UTC hour the buffer opened, using `logs_by_time` as its schema (`cloud-formation/log-ingester.json`, `LogIngesterLogsTable`). The partitioner (`partitioner/src/index.js`) copies each day nightly into `logs_by_app_and_secure_key/{app}/{Y}/{M}/{secure_key}/{DD}_{n}.parquet`.
- **Where the DDL lives.** In `server/README.md`, applied by hand, like the other two hand-made tables. `logs_by_time` is in the log-ingester stack because Firehose needs it; adding `logs_by_hour` there would mean updating the stack that runs ingestion.
- **The partition column is a string** (`2026/10/13/16`). Range predicates compare lexically, which is time order because every level is zero-padded. Athena generates projected dates in UTC.
- **Most projected hours are empty.** On staging, 22% of the hours since 2014/03/01 hold an object, against 622 of 720 (86%) in September 2026. Athena recommends traditional partitions above half empty, but registering one every hour is worse; a recent window projects mostly non-empty hours.
- **Staging layout.** Day files (`YYYY-MM-DD.parquet` in `00/`) up to 2021-12-20 14:00 UTC, Firehose files after; many pre-cutover days have none. Objects through `2022/12/10/03/` carry a 2022-12-11 modification time from the `add-log-id-to-parquet-files` migration; Firehose's own files resume at `2022/12/11/18/` as stream version 12, with the same 12 columns.
- **Production layout** (read 2026-10-19). Cutover 2022-01-01 00:00 UTC; the last day file ends 23:59:44 and the first Firehose file starts 00:01:29, with no shared `id`. Over 2026-10-14's 14, 15 and 16 hour folders (576,743 rows), 1,984 sat one folder early, none more, and the largest lag behind an object's name time was 60.1 s (staging: 119.8 s).
- **Reading the nightly copy by day.** `logs_by_app` with `year`/`month` bound and `regexp_like("$path", '/<DD>_[0-9]+\.parquet$')`. A `LIKE '%/<DD>\_%'` pattern also matches a secure-key folder starting `<DD>_`, because `%` crosses `/`. Production's reconciliation scanned 88 MB of an October holding 19.6 GB, so the `$path` predicate skips the other files. `secure_key` on `logs_by_app_and_secure_key` is `injected`, and Athena fails a query that does not bind it, which is why `logs_by_app` is the learner-free reader.
- **Permissions.** Staging's `report-server` policy (user `report-server-staging`) allows `s3:GetObject`/`ListBucket` on all of `log-ingester-qa`, `glue:GetTable`, and `athena:StartQueryExecution`/`GetQueryExecution`. Production's `report-server-prod` (one attached policy, v7) allows `s3:GetObject`, `ListBucket` and `GetBucketLocation` on all of `log-ingester-production`; `glue:GetTable` and `GetDatabase`; `athena:StartQueryExecution`, `GetQueryExecution`, `GetWorkGroup`, `CreateWorkGroup` and `TagResource`; and read and write on `concord-report-data`. Neither allows `athena:GetQueryResults`, so a synchronous count route either adds it or reads the result CSV from the output location.
- **For REPORT-150.** `ReportQuery.get_log_cols/0` already lists the 12 columns in this order. Firehose is at least once. A retried S3 delivery repeats a record under the same `id`, which the reconciliation's repeated-id count would catch (none on the reconciled days). A re-invoked transform or a client resend repeats it under a new `id`, which no check here detects. Staging learner traffic is sparse, so a class-scoped staging check needs a day with that class's learners.
- **Athena SQL gotchas.** Athena does not materialize a `WITH` query, so a side named in several subqueries is scanned once per mention; tag each side, `UNION ALL` and group by `id` instead. `NOT IN` counts 0 whenever the other side holds a null. `EXPLAIN` and `EXPLAIN (TYPE IO)` print a bare `TableScan` and cannot show projection pruning; compare a column-reading query's bytes scanned with the listed bytes of the hours in range.
- **Drift noticed, not fixed.** Staging's two `app`-partitioned tables project 8 apps against the README's and `AthenaConfig`'s 16. The README's IAM policy blocks omit the Athena, Glue and log-bucket statements the staging policy has.

## Out of Scope

- Wiring any report to `logs_by_hour`, including moving teacher-actions off `logs_by_time`.
- The class-scoped route, its authorization and its result reading (REPORT-150), and the app read of the count.
- Monitoring live sessions.
- Changing the partitioner, the Firehose stream or `logs_by_time`.
- Fixing the staging app-enum drift and the stale IAM policy blocks in the README.
- Deduplicating Firehose's at-least-once deliveries.

## Decisions

### Where does the `logs_by_hour` DDL live?
**Options considered**: the README, applied by hand; an `AWS::Glue::Table` in `log-ingester.json`.
**Decision**: the README. It matches the tables reports query and avoids updating the ingestion stack for a table ingestion does not use.

### One `date` key or four integer keys?
**Options considered**: `dt string` with hourly date projection to `NOW`; `year`/`month`/`day`/`hour` integer projections.
**Decision**: `dt`. One predicate expresses a window across a day or month boundary, the projection never plans future hours or invalid dates, and the one-hour pad is a single subtraction. Athena's Firehose example uses this exact declaration, and the staging `CREATE` confirmed it.

### Does this story add Elixir helpers for the conventions?
**Decision**: no. Wiring is out of scope, and a `dt`-range helper with no caller is code nothing exercises; REPORT-150 writes it with its first caller.

### Keep or remove `logs_by_app`?
**Options considered**: keep if a closed app-month passes a cost threshold; remove regardless; keep regardless and document its cost.
**Decision**: keep regardless (Doug, 2026-10-13). It is the only learner-free reader of the nightly copy, and removing its DDL would hide a Glue table without dropping it. The measurement decides only what the README says it costs.

### What do the cost tables measure?
**Decision**: `count(*)` for hour, day and month, plus a column-reading query (Doug, 2026-10-13), because Athena answers `count(*)` from Parquet metadata. Measured, `count(*)` scanned 0 bytes on every table, so the `logs_by_app` measurement gained `count(DISTINCT session)` on both tables as well.

### Does R11 prescribe how REPORT-150 combines the tables?
**Decision** (Doug, 2026-10-19): no. R11 holds only facts about the table's data and cost; combining the tables and deciding completeness are REPORT-150's.

### A caller cannot tell when the nightly copy of a day is complete
**Context**: The partitioner uploads with one `aws s3 cp --recursive`, writes no marker, and its Batch job has no retry.
**Options considered**: prescribe a margin (for example D+2 00:00 UTC); state the gap as a fact; add a completion marker in a follow-up.
**Decision**: state the fact (Doug, 2026-10-13). REPORT-150 sets the rule.
