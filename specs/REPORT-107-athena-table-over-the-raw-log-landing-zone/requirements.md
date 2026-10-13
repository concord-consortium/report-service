# Athena table over the raw log landing zone (`logs_by_hour`)

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-107
**Repo**: https://github.com/concord-consortium/report-service
**Implementation Spec**: [implementation.md](implementation.md)
**Status**: **In Development**

## Overview

Declare an Athena table, `logs_by_hour`, over the hourly folders where log events land about a minute after they happen. This makes recent log events queryable without waiting for the nightly refile. Document what a query on the table has to know about its data, so that REPORT-150's class-scoped recent-logs route can build on the table.

## Project Owner Overview

Every log report today reads a copy of the logs that is rebuilt once a night, so the newest event any report can see is between 2 and 26 hours old. The researcher dashboard's live log count (RIGSE-360) needs something fresher. The raw files that copy is built from already sit in S3, filed by hour and about a minute behind live, but no usable table reads them: the one table over them has no partitions, so every query reads all of history.

This story adds that table, proves on staging and then production that it returns the same events as the nightly copy, records what it costs to query an hour, a day and a month, and writes down the rules for querying it cheaply and correctly. It changes no report and adds no route. REPORT-150 builds the class-scoped route on top of it. It also documents the unused `logs_by_app` table in the README as a supported route, with its measured cost, since it is the only way to read the nightly copy without naming learners.

## Background

Log events reach S3 through the log-ingester stack (`cloud-formation/log-ingester.json`). API Gateway stamps each request with its receipt time in milliseconds and passes it to Firehose. A transform Lambda then assigns a random 21-character `id`, writes the receipt time to `timestamp`, and writes the client's own clock, in seconds, to `time` (falling back to the receipt time when the client sent none). Firehose buffers for 60 seconds or 64 MB, converts each buffer to Snappy Parquet using the Glue table `logs_by_time` as its schema, and writes it under `processed_logs_with_id/YYYY/MM/DD/HH/`, the UTC hour the buffer opened.

Each night at 02:00 UTC the partitioner (`partitioner/src/index.js`) copies the previous day's folder, `processed_logs_with_id/{Y}/{M}/{D}/`, hours included, and rewrites it as `logs_by_app_and_secure_key/{app}/{Y}/{M}/{secure_key}/{DD}_{n}.parquet`. Every report reads that copy through `logs_by_app_and_secure_key`, except teacher-actions, which reads `logs_by_time` (`teacher_actions_report.ex:37`).

`logs_by_time` is defined in CloudFormation, not hand-made (`log-ingester.json`, resource `LogIngesterLogsTable`). Glue on staging confirms that it has no partition keys and that its location is `s3://log-ingester-qa/processed_logs_with_id/`, so any query against it lists and reads every object since 2014. It is also the schema Firehose converts with, so it cannot be altered or dropped to add partitions without touching ingestion. The new table therefore sits beside it.

The README's two hand-made projected tables, `logs_by_app_and_secure_key` and `logs_by_app`, both point at the nightly copy. `logs_by_app` (app, year and month, with no secure-key level) is read by no server code (REPORT-105's spec says so too).

### Checked on staging (2026-10-13, read-only)

- **Layout.** `log-ingester-qa/processed_logs_with_id/` has years 2014 to 2026, with four zero-padded levels. From 2021-12-20 14:00 UTC onward, every object is a Firehose file named `log_ingester_qa-<n>-YYYY-MM-DD-HH-MM-SS-<uuid>.parquet` in its hour folder. **Before that, each day with data is a single file, `YYYY-MM-DD.parquet`, in the day's `00/` folder** (for example `2014/03/17/00/2014-03-17.parquet`). Staging has 1,567 such files, and many days have none (2018 has 53, 2019 has 99). Every object up to the last stream-version-5 Firehose file (`2022/12/10/03/`) carries a 2022-12-11 modification time, from the cloud-formation `add-log-id-to-parquet-files` migration. Firehose's own files resume at `2022/12/11/18/` as stream version 12, with the same 12 columns. The full listing holds no other object: every key is a day file or a Firehose file in its own hour folder.
- **Schema.** DuckDB `DESCRIBE` on a 2014 day file, a 2021 Firehose file and a 2026 Firehose file gives the same 12 columns, names and types in each: `id, session, username, application, activity, event, event_value` (varchar), `time` (bigint), `parameters, extras, run_remote_endpoint` (varchar), `timestamp` (bigint). This is the column list and order of `logs_by_time`, and the same set the partitioner writes. `id` is never null.
- **Hour boundaries.** On 2026-10-12 (300 objects, 6,564 rows), 23 rows (0.35% of the day) have a `timestamp` in the hour after their folder's hour. On 2026-10-06 (15,432 rows) the figure is 252 (1.6% of the day). Within one hour the share can be far higher: 11 of the 61 rows in `2026/10/12/23/`. The latest such row is 119.8 seconds after its object's name time. These are events from the first two minutes of an hour that went into a buffer opened in the previous hour. The last hour folder of 2026-10-12 held 11 events from 00:00 of the next day. No row's `timestamp` is earlier than its object's name time by more than 0.1 seconds, which is the name's one-second rounding.
- **Reconciliation.** The nightly copy of 2026-10-12 is three files (`Activity_Player`, `CLUE`, `CODAPV3`, all with secure key `none`, since no row that day had a `run_remote_endpoint`). It holds exactly the raw day's 6,564 rows: the `id` sets are equal in both directions. 2026-10-06, with 341 learner-keyed rows spread over seven nightly files, reconciles the same way (15,432 rows each, no `id` on one side only, no repeated `id`).
- **Convention 3 checked on both days (21,996 rows).** No row is in a folder more than one hour before its own `timestamp` hour, and none is in a folder after it. 275 are in the folder one hour before.
- **The cutover day.** On 2021-12-20 the `00/` day file covers 00:11 to 14:12 UTC, and the Firehose files start at 14:43. No row is in both.
- **Application names.** The raw `application` column holds the name the client sent (`Activity Player`). The nightly `app` partition holds the sanitized name (`Activity_Player`, with non-`[a-zA-Z0-9_-]` characters replaced by `_`), which is what `AthenaConfig.get_log_apps/0` lists.
- **Access.** The staging report-server user's policy (`report-server`, account 816253370536) already allows `s3:GetObject` and `s3:ListBucket` on all of `log-ingester-qa`, `glue:GetTable` on any table, and `athena:StartQueryExecution` and `athena:GetQueryExecution`. It does not allow `athena:GetQueryResults`.

## Requirements

### The table

- **R1.** An external table `logs_by_hour` exists in each environment's log database (`log_ingester_qa` on staging, `log_ingester_production` in production: the database `ReportQuery.get_log_db_name/0` names), over `s3://<bucket>/processed_logs_with_id/`.
- **R2.** Its columns are the 12 columns of the raw objects, in the order and with the types the staging check found (Background). Production objects are checked the same way before the production table is created, and if they differ, the table declares what is actually there.
- **R3.** It has one partition key, `dt string`, declared by partition projection of type `date`, with format `yyyy/MM/dd/HH`, an interval of one hour, a range from `2014/03/01/00` to `NOW`, and `storage.location.template` `s3://<bucket>/processed_logs_with_id/${dt}/`. No partitions are added by crawler or `MSCK REPAIR`.
- **R4.** `logs_by_time` is not altered, dropped or replaced. It stays the Firehose schema table.
- **R5.** The staging table is created and validated (R7, R8) before the production table is created.

### The README

- **R6.** `server/README.md` gains the `logs_by_hour` DDL for production, under "S3 Log Partitioning", next to the two existing tables. It says the staging variant changes only the bucket. It also says that the "recreate when applications change" note does not apply to this table, because the table has no `app` partition. The section's opening sentence ("the DDL to create the two tables") and that note are reworded to cover three tables.

### Validation and measurements

- **R7. Hour count.** For a closed hour on each environment, `SELECT count(*) FROM logs_by_hour WHERE dt = '<hour>'` returns within seconds and equals the row count DuckDB reads from that hour's objects.
- **R8. Day reconciliation.** For a closed day on each environment that has learner-keyed rows (a non-empty `run_remote_endpoint`), the rows of `logs_by_hour` with `dt` from `<day>/00` to `<day>/23` match the nightly copy's rows for that day (the files named `<DD>_<n>.parquet` under that year and month), compared by `id`. Any difference is explained in the README. The two staging days above already reconcile exactly. The production comparison runs through Athena, because the nightly copy's day is a file-name match and not a partition.
- **R9. Cost figures.** Bytes scanned and query time for `count(*)` over one closed hour, one closed day and one closed month in production are measured and recorded in the README, with the date measured. The same closed day is also measured with `count(DISTINCT run_remote_endpoint)`, because Athena can answer `count(*)` from Parquet metadata and so understate a query that reads a column, and this is the shape of query REPORT-150 runs (Doug, 2026-10-13).
- **R10. Pre-Firehose history.** The README states that before the Firehose cutover (2021-12-20 14:00 UTC on staging; the production date is read from the production listing), a whole day sits in its `00` hour, so hour-level filters on that history are wrong and only whole-day ranges are meaningful.

### Query conventions (the contract REPORT-150 builds on)

- **R11.** A "Querying recent logs" section in `server/README.md` states these conventions, each with the measured fact behind it:
  1. **Always give `dt` a lower bound.** The projection spans every hour since 2014, so a query with no `dt` predicate plans over more than 100,000 partition locations. An upper bound is optional, since Athena never projects hours after `NOW`.
  2. **Window on `timestamp`, not `time`.** `timestamp` is server receipt time in epoch milliseconds, the clock the folders follow. `time` is the client's clock in epoch seconds, and is only as right as the student's device. Every row has a `timestamp`: REPORT-182 counted no null or zero value in `logs_by_app` over staging's whole history (25.8M rows) and production's April of every year 2014 to 2026 (377.7M rows), and staging's raw 2014, 2020 and 2021 objects (216,539 rows, day files included) agree.
  3. **Pad the `dt` range by one hour on each side, then filter on `timestamp`.** An event can sit in the folder of the hour before its own, because a buffer opened at 15:59 holds events up to about two minutes into 16:00. To read events with `timestamp` in `[T1, T2)`, scan `dt` from `hour(T1) - 1h` to `hour(T2) + 1h`. The upper pad covers the sub-second rounding and costs at most one extra hour. A window that runs to now needs only the lower bound.
  4. **The current hour is partial**, and an hour folder can still receive objects for about two minutes after it ends.
  5. **The nightly copy of day D is exactly the raw folders `D/00` to `D/23`** (reconciled by `id` on two days, R8), so it holds the first two minutes of D+1 by `timestamp`. The partitioner files D under D's own `year` and `month`, so on a month's last day the first minutes of the next month sit in the earlier month's partition. D's nightly copy exists only after the partitioner's 02:00 UTC run for D finishes, and nothing marks that: it writes no completion marker and its Batch job has no retry, so a failed run leaves D missing until it is rerun, and a run still uploading leaves D partial. How a caller combines the two tables, and when it treats D's nightly copy as complete, is REPORT-150's to set.
  6. **Scope by row, not by prefix.** There is no `app` or `secure_key` level, so a learner or class filter (`run_remote_endpoint`, `username`) is a row predicate: a query reads every application's bytes for the hours in range, whatever the number of learners. That removes the per-learner prefix ceiling of `logs_by_app_and_secure_key`. The remaining limit is Athena's 262,144-byte query text.
  7. **`application` is the raw client value** (`Activity Player`), not the sanitized `app` partition value (`Activity_Player`) that `AthenaConfig` lists.

### `logs_by_app`

- **R12.** `logs_by_app` stays in the README and is documented as a supported route: for an app-scoped cohort with no learner bound, and for reading the nightly copy without a learner list (as R8 does). Its cost is measured on one closed app-month in production (bytes scanned, query time, planning time) against the same app-month through `logs_by_app_and_secure_key` with a bounded secure-key sample, and the README records both.
- **R13.** `athena_config_test.exs` stays green without changes. Its "agreement with the DDL in the README" tests count exactly two `projection.app.values` declarations and two of each `year`/`month` range, which the two kept `app`-partitioned tables still provide. Checked by running the test against a README with `logs_by_hour`'s DDL added: 14 tests, 0 failures, since the new DDL declares only `projection.dt.*`.

### Report-server's access

- **R14.** The production report-server user's IAM policies (`report-server-prod`) are read, and the spec's Technical Notes record what they allow for this table: `s3:GetObject` and `s3:ListBucket` on `log-ingester-production/processed_logs_with_id/`, `glue:GetTable`, and `athena:GetQueryResults`. The record sits beside staging's, which the Background already gives. No IAM changes; a gap is a fact for REPORT-150 (Doug, 2026-10-13).

## Technical Notes

- **Where the DDL lives.** In `server/README.md`, like the other two hand-made tables, and applied by hand in the Athena console or CLI. `logs_by_time` lives in the log-ingester CloudFormation stack because Firehose needs it. `logs_by_hour` does not, and adding it there would mean updating the stack that runs ingestion.
- **The partition column is a string.** `dt` values look like `2026/10/13/16`. Range predicates (`dt >= '2026/10/13/15'`) compare lexically, which matches time order because every level is zero-padded. Athena's date projection prunes on equality, `IN` and range predicates over the formatted value. Athena generates projected dates in UTC ("Supported types for partition projection"), as Firehose names its folders.
- **Most projected hours are empty.** Athena's partition projection page says that when more than half of a table's projected partitions are empty, traditional partitions are recommended, since empty ones slow planning. On staging, 23,811 of the 110,634 hours from `2014/03/01/00` to 2026-10-13 17:00 hold an object (22%): 22,244 of the 42,196 since the cutover, and 622 of 720 in September 2026. The table keeps projection, because registering partitions means adding one every hour, and the empty share is high only over the pre-cutover years and quiet stretches. A query over a recent window projects mostly non-empty hours. A multi-year query pays for listing the empty ones.
- **`logs_by_app` is the only table that reads the nightly copy without a learner list.** `secure_key` on `logs_by_app_and_secure_key` is an `injected` projection, and Athena fails any query that does not give it a value ("Supported types for partition projection": "Queries on injected columns fail if a filter expression is not provided for each injected column"). So R8's production reconciliation, and any whole-app or whole-day read of the nightly copy, goes through `logs_by_app`, which is why R12 keeps it.
- **Reading the nightly copy by day in Athena.** `logs_by_app` with `year`/`month` bound and `regexp_like("$path", '/<DD>_[0-9]+\.parquet$')` selects one day's files. A `LIKE '%/<DD>\_%'` pattern would also match a secure-key folder whose name starts with `<DD>_`, because `%` crosses `/`. Whether Athena skips the other files' bytes on a `$path` predicate is measured, not assumed (R8, R9).
- **Database and permissions.** Report-server already queries `logs_by_time` over the same prefix, so its user can read the bucket. This is verified on staging (Background) and inferred for production from teacher-actions working there, until R14 reads production's policy. Queries run in the per-user workgroups `AthenaDB` creates, with `"report-service"` as the default database and the log database named explicitly.
- **For REPORT-150, not decided here.** The staging policy has no `athena:GetQueryResults`, so a route that reads a count synchronously either adds that action or reads the result CSV from the workgroup's output location, which the policy already allows. `ReportQuery.get_log_cols/0` already lists the 12 columns in this table's order. Firehose delivery is at least once and `id` is assigned before delivery, so a retried delivery can repeat a record under a new `id`. None was seen on either staging day. Staging learner traffic is sparse: 2026-10-12 had no row with a `run_remote_endpoint`, and October's nightly copy holds learner-keyed files on 8 of 12 days, so a staging check of a class-scoped count needs a day, or a run, with that class's learners.
- **Drift noticed, not fixed here.** Staging's `logs_by_app` and `logs_by_app_and_secure_key` project 8 apps (`Activity_Player,CLUE,CODAP,CODAPV3,Dataflow,GeniStarDev,portal-report,rigse-log`), while the README and `AthenaConfig` list the production 16. The README's IAM policy blocks omit the Athena, Glue and log-bucket statements the staging policy actually has.

## Out of Scope

- Wiring any report to `logs_by_hour`, including moving teacher-actions off `logs_by_time`. That follows once the conventions are validated.
- The class-scoped route, its authorization and its result reading (REPORT-150), and the app read of the count.
- Monitoring live sessions.
- Changing the partitioner, the Firehose stream or `logs_by_time`.
- Fixing the staging app-enum drift and the stale IAM policy blocks in the README.
- Deduplicating Firehose's at-least-once deliveries.

## Open Questions

### RESOLVED: Judgment call: where does the `logs_by_hour` DDL live?
**Context**: `logs_by_time` is in the log-ingester CloudFormation stack, and the other two tables are in the README.
**Options considered**:
- A) The README, applied by hand like `logs_by_app_and_secure_key`
- B) An `AWS::Glue::Table` in `log-ingester.json`

**Decision**: A. It matches the tables reports actually query, and avoids a stack update on the stack that runs ingestion for a table ingestion does not use.

### RESOLVED: Judgment call: one `date` key or four integer keys?
**Context**: Jira proposes one `dt` key. `logs_by_app_and_secure_key` uses integer `year`/`month`.
**Options considered**:
- A) `dt string` with date projection, hourly, range to `NOW`
- B) `year`, `month`, `day`, `hour` integer projections

**Decision**: A. One predicate expresses a window that crosses a day or month boundary. The projection never plans future hours or invalid dates. Convention 3's one-hour pad is a single subtraction.

### RESOLVED: Judgment call: does this story add Elixir helpers for the conventions?
**Context**: REPORT-150 will need a function that turns a time window into a `dt` range.
**Options considered**:
- A) No code; the conventions are documented, and REPORT-150 writes the helper with its first caller
- B) Add a `dt`-range helper to `ReportQuery` now

**Decision**: A. Jira puts wiring out of scope, and a helper with no caller is code nothing exercises.

### RESOLVED: Low confidence: does Athena accept `yyyy/MM/dd/HH` as a date projection format with an hourly interval and a `NOW` bound?
**Context**: The DDL has not been run, and running it means creating a table, which waits for Doug.
**Options considered**:
- A) Rely on Athena's documented Firehose example and confirm by creating the staging table as the implementation's first step
- B) Create a scratch table during speccing to settle it now

**Decision**: A. Athena's "Amazon Data Firehose example" for partition projection (docs.aws.amazon.com/athena/latest/ug/partition-projection-kinesis-firehose-example.html) is this exact declaration: a `STRING` key of type `date`, format `yyyy/MM/dd/HH`, range `<start>,NOW`, interval 1 `HOURS`, and a template ending `${datehour}/`. Its companion page shows range predicates on the string (`datehour >= '2020/12/15/00' AND datehour < '2021/02/03/15'`) being pruned to the hours inside the projection range, and says Athena never generates hours after `NOW`. Creating the staging table (R5) is the confirmation.

### RESOLVED: Low confidence: production's Firehose cutover date and hour-boundary behavior
**Context**: Only staging was listed and read. Production carries more traffic per buffer, and Jira's numbers are from 2026-09-03.
**Options considered**:
- A) Re-check in production before writing the README: list the production prefix to find the cutover, and repeat the hour-boundary DuckDB check on one production hour's objects
- B) Accept staging's figures for both environments

**Decision**: A. Both checks are a listing and a download of one hour (a few MB), with no Athena cost. The README's figures (R10, convention 3) are production's where the two differ. If a production event lands more than one folder hour before its own hour, convention 3's pad widens to match.

### RESOLVED: Low confidence: the rule for keeping or removing `logs_by_app`
**Context**: R12 named two outcomes but not the threshold between them. Stage 4 found that `logs_by_app` is the only table that reads the nightly copy without a learner list (Technical Notes), and R8's production reconciliation depends on it.
**Options considered**:
- A) Keep it if a closed app-month `count(*)` plans and finishes in under a minute, and reads no more bytes than that app's share of the month. Otherwise remove it
- B) Remove it regardless, since `logs_by_hour` covers unbounded cohorts
- C) Keep it regardless, and document its use and measured cost

**Decision**: C (Doug, 2026-10-13). It is the only learner-free reader of the nightly copy, and removing its DDL would hide a Glue table without dropping it. The measurement decides only what the README says it costs.

## Self-Review

Roles: Senior Engineer (data correctness), REPORT-150's engineer (the consumer of the conventions), QA Engineer, Technical Writer.

### Senior Engineer

#### RESOLVED: The nightly seam crosses a month as well as a day
Convention 5 said the nightly copy of day D includes the first minutes of D+1. The partitioner writes D's rows under D's folder `year` and `month` (`mergeSplitJsonToParquet` uses the run's `year` and `month`, not each row's), so on a month's last day those minutes sit in the earlier month's partition. A caller that picks the nightly partition from `timestamp` would miss them. Convention 5 now says so.

### REPORT-150's engineer

#### RESOLVED: Staging days can have no learner-keyed rows
The only reconciled day (2026-10-12) had no `run_remote_endpoint` at all, so R8 on staging proved nothing about secure-keyed files, and REPORT-150 could pick a staging day with nothing to count. A second day, 2026-10-06 (341 keyed rows), was reconciled and added to Background. R8 now requires a day with keyed rows, and the REPORT-150 note says staging learner traffic is sparse.

### QA Engineer

#### RESOLVED: The hour-boundary figure rested on one quiet day
0.35% on 2026-10-12 understated it: 2026-10-06 has 1.6%, with the same two-minute ceiling. Background gives both. The pad in convention 3 is unchanged, since it depends on the ceiling, not the rate.

### Technical Writer

#### RESOLVED: The README's opening sentence counts the tables
"Here is the DDL to create the two tables" and the "when new applications are added these tables need to be recreated" note both become wrong when a third table is added. R6 now covers rewording them.


### Round 2 (2026-10-13)

Roles: Technical Writer, Performance Engineer, REPORT-150's engineer.

#### Technical Writer

##### RESOLVED: The layout bullet overstated the day files and the migration date
A full listing of staging's `processed_logs_with_id/` (257,276 keys) shows that "each day is a single file" holds only for days with data (1,567 day files, with whole years mostly empty), and that "every object up to 2022" carries the migration's modification time only up to `2022/12/10/03/`: objects from `2022/12/11/18/` on are Firehose's own, as stream version 12 (`head-object` on both sides of the switch, and DuckDB `DESCRIBE` on two version 5 files and the first version 12 file, all with the 12 columns). The bullet now says both, and that the listing holds nothing but day files and Firehose files.

#### Performance Engineer

##### RESOLVED: Athena recommends against projection when most partitions are empty
Athena's partition projection page recommends traditional partitions when more than half of the projected partitions are empty, and the same staging listing finds 78% of the projected hours empty. Technical Notes now give the figures and why projection stays: the empty share sits in history that convention 8 already routes to the nightly copy's tables, and registered partitions would need a job adding one every hour. No requirement changes.

#### REPORT-150's engineer

##### RESOLVED: A caller cannot tell when the nightly copy of a day is complete
Convention 5 says the nightly copy of day D exists only after the partitioner's 02:00 UTC run for D has finished, but nothing a caller can read says that it has. The partitioner (`partitioner/src/index.js`) uploads its files with one `aws s3 cp --recursive` and writes no completion marker, and its Batch job (`partitioner/template.yml`) has no retry, so a failed run leaves D absent from the nightly copy until someone reruns it, and a run still uploading leaves it partial. On staging every 2026 day with raw objects up to 2026-10-12 has nightly files, so no failure has been seen. A caller that switches to the nightly copy for D at a fixed hour would silently undercount on a day the run failed or ran late. This changes the contract convention 5 hands REPORT-150, so it is left for Doug.
**Options considered**:
- A) Convention 5 adds that there is no completion signal, and that a caller treats the nightly copy of D as available only from a stated margin (for example D+2 00:00 UTC), reading `logs_by_hour` for every later folder day
- B) Convention 5 states the gap as a fact and leaves the rule to REPORT-150
- C) A follow-up story adds a completion marker to the partitioner (out of scope here, since this story does not change the partitioner)

**Decision**: B (Doug, 2026-10-13). Convention 5 now states the gap, and the run's 02:00 UTC timing, which puts it after the US school day since every researcher is in the US. REPORT-150 sets the rule.

### Round 3 (2026-10-19, at base `ceaaf23`)

Roles: REPORT-150's engineer, Senior Engineer (data correctness), Operator (the partitioner), Technical Writer. Rechecked with no change: `teacher_actions_report.ex:37`, the README's "S3 Log Partitioning" sentences R6 quotes, the partitioner's 02:00 UTC default and absent `RetryStrategy` after REPORT-184, and R13 (14 tests, 0 failures against a README with the DDL added).

#### REPORT-150's engineer

##### RESOLVED: Convention 5 prescribed REPORT-150's seam, and convention 8 its table routing
Convention 5 said to split the two tables on the folder day, "never on `timestamp`", which contradicted REPORT-182's exact `timestamp < (E + 1) 00:00 UTC` cut (with `logs_by_hour` read from one hour earlier, 135 of 135 staging rows; without that hour, 124). Convention 8 routed callers among three tables.

**Decision** (Doug, 2026-10-19): R11 holds only facts about `logs_by_hour`'s data and cost that a query needs. Convention 5 keeps the folder-day, month-boundary and no-completion-marker facts; how to combine the tables and when D is complete are REPORT-150's. Convention 8 is dropped: cost is in R9, `logs_by_app`'s role in R12.

#### Senior Engineer

##### RESOLVED: Convention 2 did not say that every row has a `timestamp`
A window on `timestamp` silently drops rows where it is null. Convention 2 now cites REPORT-182's counts (0 null or zero on `logs_by_app`, staging all history and production April 2014 to 2026) and a DuckDB count of staging's raw 2014, 2020 and 2021 objects (216,539 rows, 0 null or zero).

#### Technical Writer

##### RESOLVED: The hour-boundary percentages read as per hour
REPORT-182 quotes them as "up to 1.6% of an hour's rows", but they are shares of a day; `2026/10/12/23/` alone has 11 of 61 (18%). Background now says "of the day" and gives that hour.
