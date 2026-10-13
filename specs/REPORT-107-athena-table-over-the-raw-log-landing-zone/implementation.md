# Implementation Plan: Athena table over the raw log landing zone (`logs_by_hour`)

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-107
**Requirements Spec**: [requirements.md](requirements.md)
**Status**: **In Development**

## Implementation Plan

Most of this story is operations: two tables created by hand and a set of measurements. Only the README is committed. The operational steps come first because the committed text quotes their results. Nothing here deploys report-server or touches a CloudFormation stack.

**Who runs what.** The implementing session runs every step from the CLI, including both `CREATE EXTERNAL TABLE` statements (Doug, 2026-10-13). Creating either table waits for Doug's go, and so does any production query that reads more than one day; a go request quotes the statement and its expected scan size. If the production account refuses the DDL, the session hands Doug the statement to run himself. Staging queries need no go, because staging holds about 1.5 MB a day. Read-only listing, Glue reads and DuckDB over a downloaded hour need none either. Each step marks which kind it is.

**Staging rehearses every production query.** Each production query runs first on staging with the identical SQL and the same kind of range (a closed hour, day and month, and an app-month). That proves the SQL, the helper and the `$path` day filter before production pays for them. Staging's bytes and timings say nothing about production's, so only production's figures go in the README.

**Credentials.** Staging is the `qa` profile (account 816253370536), and production is the default profile (account 612297603577). The `primary` workgroup in each account has no output location, so every CLI query passes one: `s3://concord-staging-report-data/report-107/` on staging and `s3://concord-report-data/report-107/` in production. Both prefixes are deleted at the end (cleanup step).

**A throwaway query helper**, kept in the scratchpad and never committed. It runs one statement, waits, and prints the result rows with the statistics R9 records:

```bash
# usage: athena_run <profile> <output-s3-prefix> <sql>
athena_run() {
  local profile=$1 out=$2 sql=$3 id state
  id=$(aws --profile "$profile" athena start-query-execution \
    --work-group primary --query-execution-context Database=report-service \
    --result-configuration "OutputLocation=$out" \
    --query-string "$sql" --query QueryExecutionId --output text) || return 1
  until state=$(aws --profile "$profile" athena get-query-execution --query-execution-id "$id" \
      --query QueryExecution.Status.State --output text) && [[ $state != QUEUED && $state != RUNNING ]]; do
    sleep 2
  done
  aws --profile "$profile" athena get-query-execution --query-execution-id "$id" \
    --query 'QueryExecution.{state:Status.State,reason:Status.StateChangeReason,scanned:Statistics.DataScannedInBytes,planning_ms:Statistics.QueryPlanningTimeInMillis,engine_ms:Statistics.EngineExecutionTimeInMillis,total_ms:Statistics.TotalExecutionTimeInMillis}'
  [[ $state == SUCCEEDED ]] && aws --profile "$profile" athena get-query-results --query-execution-id "$id" \
    --query 'ResultSet.Rows[].Data[].VarCharValue' --output text
}
```

Every statement reaches the helper through a quoted heredoc, so that the shell passes `${dt}`, `"$path"` and the double-quoted identifiers through unchanged:

```bash
athena_run qa s3://concord-staging-report-data/report-107/ "$(cat <<'SQL'
SELECT count(*) FROM "log_ingester_qa"."logs_by_hour" WHERE dt = '2026/10/06/15'
SQL
)"
```

Inside a double-quoted string, bash expands `${dt}` to nothing, which turns the DDL's `storage.location.template` into the table root for every hour, and expands `"$path"` to nothing, which breaks the reconciliation's filter.

The DuckDB side of R7 is the same throwaway pattern the spec's staging checks used: download an hour's objects into an empty scratchpad directory, then run

```bash
duckdb -csv -c "select count(*) from read_parquet('<dir>/*.parquet')"
```

---

### Read production's layout, schema and hour boundaries

**Summary**: Gives production's facts for R2, R10, R14 and convention 3 before any production table exists. Read-only; no go needed, no commit.

**Files affected**: none (results go into the README step).

**Estimated diff size**: 0 lines

1. **Glue.** Checked while speccing (2026-10-13), in every Glue database of both accounts. In production, `logs_by_time` has no partition keys and is over `s3://log-ingester-production/processed_logs_with_id/`, and `logs_by_app` and `logs_by_app_and_secure_key` exist (created 2025-06-10). In staging, the same three exist in `log_ingester_qa`. In both, no `logs_by_hour` exists and no other table reads `processed_logs_with_id/`. Before each `CREATE`, `aws glue get-table --name logs_by_hour` for that database is rerun to confirm the table is still absent.
2. **Cutover.** Production's equivalent of staging's 2021-12-20 14:00 UTC is the first hour folder holding a Firehose-named object. Find the last day file and the first Firehose file by listing month by month, then day by day, around them:

   ```bash
   B=s3://log-ingester-production/processed_logs_with_id
   for y in 2020 2021 2022; do for m in 01 02 03 04 05 06 07 08 09 10 11 12; do
     printf '%s/%s ' $y $m
     aws s3 ls $B/$y/$m/ --recursive | awk '{print $4}' \
       | awk '/\/[0-9]{4}-[0-9]{2}-[0-9]{2}\.parquet$/{d++} /log_ingester_production-/{f++} END{print "day-files=" d+0, "firehose=" f+0}'
   done; done
   ```

   The month where `day-files` stops and `firehose` starts is then listed by day to find the hour. Also check that the cutover day's `00/` file and its first Firehose file do not overlap in time, as on staging.
3. **One production hour.** Pick a closed school-day hour (a weekday, 15:00 UTC, in the last month). Download `$B/<Y>/<M>/<D>/15/` into an empty scratchpad directory. Then run:
   - `DESCRIBE SELECT * FROM read_parquet('<dir>/*.parquet')`, expecting the 12 columns of R2;
   - the count, which is R7's expected value for the production hour check;
   - the hour-boundary check below, over the 14:00, 15:00 and 16:00 folders (download all three, so it sees both edges of 15:00). Run from the directory holding the downloaded `<Y>/<M>/<D>/<HH>/` folders.

   ```sql
   WITH r AS (
     SELECT
       strptime(regexp_extract(filename, '(\d{4}/\d{2}/\d{2}/\d{2})/[^/]+$', 1), '%Y/%m/%d/%H') AS folder_hour,
       strptime(regexp_extract(filename, '-(\d{4}-\d{2}-\d{2}-\d{2}-\d{2}-\d{2})-[0-9a-f-]+\.parquet$', 1), '%Y-%m-%d-%H-%M-%S') AS name_time,
       make_timestamp("timestamp" * 1000) AS ts
     FROM read_parquet('*/*/*/*/*.parquet', filename = true)
   )
   SELECT
     count(*) AS rows,
     count(*) FILTER (WHERE date_trunc('hour', ts) = folder_hour + INTERVAL 1 HOUR) AS one_folder_early,
     count(*) FILTER (WHERE date_trunc('hour', ts) > folder_hour + INTERVAL 1 HOUR) AS more_than_one_early,
     count(*) FILTER (WHERE date_trunc('hour', ts) < folder_hour) AS later_folder,
     round(max(epoch_ms(ts) - epoch_ms(name_time)) / 1000.0, 1) AS max_lag_s,
     round(min(epoch_ms(ts) - epoch_ms(name_time)) / 1000.0, 1) AS min_lag_s
   FROM r;
   ```

   On staging's `2026/10/12/22` to `2026/10/13/00` it gives 136 rows, 11 one folder early, 0 more than one early, 0 in a later folder, and lags of 0.0 to 62.1 s. A 00:00 file copied into the 22:00 folder counts as more than one early, and a 22:00 file copied into the 00:00 folder counts as in a later folder. Production's firehose files are named `log_ingester_production-<n>-...`, which the `name_time` pattern also matches.
4. **Report-server's access (R14).** `aws iam list-attached-user-policies --user-name report-server-prod` and `list-user-policies`, then read the default version of each attached policy and each inline one. Record in requirements.md's Technical Notes whether they allow `s3:GetObject` and `s3:ListBucket` on `log-ingester-production/processed_logs_with_id/*` (or the whole bucket), `glue:GetTable`, and `athena:GetQueryResults`, replacing the "inferred for production" wording. Change no IAM: a gap is a fact for REPORT-150, not something this story fixes.

If any of the following holds, update requirements.md before continuing:
- production's columns differ (R2);
- an event lands more than one folder hour early, or any lands in a later folder (convention 3);
- the cutover days overlap (R10).

---

### Create and validate the staging table

**Summary**: R1, R3, R5 and R7/R8 on staging, plus the rehearsal of every production query. **Needs Doug's go** for the `CREATE` only; the queries are staging-sized. No commit.

**Files affected**: none.

**Estimated diff size**: 0 lines

The DDL, with staging's bucket (the production text differs in the database name and the two bucket names):

```sql
CREATE EXTERNAL TABLE `log_ingester_qa`.`logs_by_hour`(
  `id` string,
  `session` string,
  `username` string,
  `application` string,
  `activity` string,
  `event` string,
  `event_value` string,
  `time` bigint,
  `parameters` string,
  `extras` string,
  `run_remote_endpoint` string,
  `timestamp` bigint)
PARTITIONED BY (
  `dt` string)
ROW FORMAT SERDE
  'org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe'
STORED AS INPUTFORMAT
  'org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat'
OUTPUTFORMAT
  'org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat'
LOCATION
  's3://log-ingester-qa/processed_logs_with_id/'
TBLPROPERTIES (
  'projection.enabled'='true',
  'projection.dt.type'='date',
  'projection.dt.format'='yyyy/MM/dd/HH',
  'projection.dt.range'='2014/03/01/00,NOW',
  'projection.dt.interval'='1',
  'projection.dt.interval.unit'='HOURS',
  'storage.location.template'='s3://log-ingester-qa/processed_logs_with_id/${dt}/'
)
```

The column list, SerDe and formats are those of `logs_by_app_and_secure_key` in the README, so the three tables read alike.

1. Run the DDL through `athena_run qa s3://concord-staging-report-data/report-107/`, in the heredoc form above. Then `aws --profile qa glue get-table --database-name log_ingester_qa --name logs_by_hour` shows the projection parameters as written.
2. **R7.** `SELECT count(*) FROM "log_ingester_qa"."logs_by_hour" WHERE dt = '2026/10/06/15'` equals DuckDB's count of `processed_logs_with_id/2026/10/06/15/`. Record the total time.
3. **R8.** Reconcile 2026-10-06 (the staging day with learner-keyed rows) by `id`:

   ```sql
   WITH raw AS (
     SELECT id FROM "log_ingester_qa"."logs_by_hour"
     WHERE dt BETWEEN '2026/10/06/00' AND '2026/10/06/23'
   ), nightly AS (
     SELECT id FROM "log_ingester_qa"."logs_by_app"
     WHERE year = 2026 AND month = 10 AND regexp_like("$path", '/06_[0-9]+\.parquet$')
   ), sides AS (
     SELECT id, 1 AS r, 0 AS n FROM raw
     UNION ALL
     SELECT id, 0 AS r, 1 AS n FROM nightly
   ), by_id AS (
     SELECT id, sum(r) AS r, sum(n) AS n FROM sides GROUP BY id
   )
   SELECT
     sum(r) AS raw_rows,
     sum(n) AS nightly_rows,
     count_if(n = 0) AS raw_only_ids,
     count_if(r = 0) AS nightly_only_ids,
     count_if(r > 1 OR n > 1) AS repeated_ids
   FROM by_id
   ```

   Each side is scanned once: Athena does not materialize a `WITH` query, so a form that names `raw` or `nightly` in several subqueries reads that table once per mention. The expected values are the DuckDB figures already in requirements.md: 15,432 rows on each side, and 0 for each of the three id counts. That day's seven nightly files are all under `Activity_Player`, `CLUE` and `CODAPV3`, which are inside staging's 8-value `app` enum. On another day, a nightly app folder outside the enum would show its ids in `raw_only_ids`, explained by naming the folder.
4. **Convention 1, observed.** `SELECT count(DISTINCT session) FROM "log_ingester_qa"."logs_by_hour" WHERE dt >= '<yesterday>/00'` succeeds, and its `scanned` is no more than the listed bytes of the hours since then (`aws --profile qa s3 ls --recursive --summarize` over yesterday's and today's day prefixes, a few MB). A scan in the GB means the projection did not prune: staging's whole prefix is about 20 GB. Neither `EXPLAIN` nor `EXPLAIN (TYPE IO)` shows which projected partitions a query reads, so the check is the scan, not the plan. The query reads a column because `count(*)` can be answered from Parquet footers and so would not show the difference. Do not run a query with no `dt` predicate.

5. **Rehearsal.** Run the production step's R9 queries (hour, day, the last closed month, and the column-reading day query) and the `logs_by_app` step's two queries on staging, with staging's database and a staging app and month. Each must succeed. Record whether the reconciliation's `scanned` was near the day's bytes or the month's, which predicts the production reconciliation's cost. These figures go nowhere but the go requests.

If the DDL is refused, stop and bring the error to Doug. The fallback in requirements.md's resolved question is four integer keys, and that changes R3 and convention 3's wording.

---

### Create the production table and measure it

**Summary**: R1, R5 and R7 to R9 in production. **Needs Doug's go** for the `CREATE`, the month measurement and the reconciliation; the hour and day queries read one day or less. No commit.

**Files affected**: none.

**Estimated diff size**: 0 lines

1. Run the DDL with `log_ingester_production` and `log-ingester-production` in place of the staging names, using the default profile and `s3://concord-report-data/report-107/`. If it is refused for lack of permission, hand Doug the statement and continue once he has run it.
2. **R7.** `count(*)` for the hour downloaded in the first step equals its DuckDB count.
3. **R9.** Each of these is run once and its `scanned` and `total_ms` are recorded, with the date measured:
   - hour: `SELECT count(*) FROM "log_ingester_production"."logs_by_hour" WHERE dt = '<Y>/<M>/<D>/15'`
   - day: `... WHERE dt BETWEEN '<Y>/<M>/<D>/00' AND '<Y>/<M>/<D>/23'`
   - month: `... WHERE dt BETWEEN '<Y>/<M>/01/00' AND '<Y>/<M>/<last>/23'`, on the last closed month. Expected scan: the month's Parquet bytes, which the listing in the first step gives (`aws s3 ls --recursive --summarize`); that figure is quoted to Doug with the go request.

   Athena can answer `count(*)` from Parquet row-group metadata, so its bytes scanned may understate a real query. R9 therefore also records `SELECT count(DISTINCT run_remote_endpoint) ... WHERE <day>` for the day, which reads a column and is the shape of query REPORT-150 will run.
4. **R8.** The reconciliation query from the staging step, against production and the same closed day. Its nightly side reads that month of `logs_by_app` across every app in the enum, filtered on `$path`. Record whether `scanned` is near the day's bytes (the `$path` predicate skipped the other files) or near the month's. Any nonzero `raw_only_ids`, `nightly_only_ids` or `repeated_ids` are grouped by `application` (and `$path` for the nightly side) to explain them. App folders outside the 16-value enum are the expected cause.

---

### Measure `logs_by_app`

**Summary**: R12's measurement. **Needs Doug's go**: it reads a closed app-month. No commit.

**Files affected**: none.

**Estimated diff size**: 0 lines

On the last closed month and one application (CLUE, which REPORT-36 already reads this way):

1. `SELECT count(*) FROM "log_ingester_production"."logs_by_app" WHERE app = 'CLUE' AND year = <Y> AND month = <M>`. Record `scanned`, `planning_ms`, `engine_ms` and `total_ms`. Planning time is the one the documentation warns about, since Athena lists every secure-key directory under the month.
2. The same count through `logs_by_app_and_secure_key` with `secure_key IN (<20 keys>)`, the keys taken from `aws s3 ls s3://log-ingester-production/logs_by_app_and_secure_key/CLUE/<Y>/<M>/`. This is the bounded sample R12 compares against. Record the same four figures.
3. These figures go into the README's `logs_by_app` paragraph; they do not decide whether it stays (requirements.md, R12).

---

### Document `logs_by_hour` and querying recent logs

**Summary**: R6, R9's figures, R10 and R11, in one README commit. It is the story's deliverable for REPORT-150, and does not wait on the `logs_by_app` measurement.

**Files affected**:
- `server/README.md`: the "S3 Log Partitioning" section

**Estimated diff size**: ~120 lines

1. The section's first sentence becomes "Here is the DDL for the three log tables." The bucket sentence stays.
2. The existing NOTE about recreating tables when applications change gains a first sentence that scopes it: "This applies to the two tables partitioned by `app`; `logs_by_hour` has no `app` partition and needs no change when applications are added."
3. After the `logs_by_app` block, inside the same fenced block (so the file still has one DDL listing), the production `logs_by_hour` DDL: the staging DDL above with the production bucket in `LOCATION` and `storage.location.template`, and without the database prefix, matching the other two.
4. A new `## Querying recent logs` heading after the fenced block, holding:
   - one paragraph on what the table is: hourly folders, written by Firehose about a minute behind live, in UTC, with the folder being the hour the buffer opened;
   - R11's seven conventions as a numbered list, each with its measured fact, worded as in requirements.md, with production's figures where the first step found they differ;
   - a "Before the Firehose cutover" paragraph (R10) with both environments' cutover times;
   - a "Measured cost" table (R9): hour, day, month and the column-reading day query, each with bytes scanned, total time and the date measured;
   - a "Reconciliation" paragraph (R8): the closed day checked in each environment and the outcome, with any difference explained.

`athena_config_test.exs` needs no change for this commit. It counts `projection.app.values`, `projection.year.range` and `projection.month.range` declarations, and the new DDL declares only `projection.dt.*`. Checked by running it against a README with the new DDL added: 14 tests, 0 failures.

---

### Document `logs_by_app` in the README

**Summary**: R12. One commit, after the `logs_by_app` measurement.

**Files affected**:
- `server/README.md`: a "`logs_by_app`" paragraph under "Querying recent logs". It says what the table is for (an app-scoped cohort with no learner bound, and reading the nightly copy without a learner list, as R8's reconciliation does) and gives its measured cost beside the bounded secure-key sample's.

**Estimated diff size**: ~15 lines

`athena_config_test.exs` is unaffected: the README still declares the `app`, `year` and `month` projections twice.

---

### Clean up

**Summary**: Deletes the measurement output. No go needed beyond the earlier ones; no commit.

**Files affected**: none.

**Estimated diff size**: 0 lines

- `aws --profile qa s3 rm --recursive s3://concord-staging-report-data/report-107/` and `aws s3 rm --recursive s3://concord-report-data/report-107/`.
- Delete the scratchpad's downloaded objects and the `athena_run` helper.
- Both `logs_by_hour` tables stay: they are the deliverable.

## Open Questions

### RESOLVED: Judgment call: run the measurements from the CLI in `primary`, or through report-server's per-user workgroups?
**Context**: Report-server runs every query in a workgroup it creates per user.
**Options considered**:
- A) The CLI, in each account's `primary` workgroup with an explicit output prefix
- B) A report-server run, so the measurement goes through the same path REPORT-150 will use

**Decision**: A. No report reads `logs_by_hour` yet (wiring is out of scope), and Athena's scan and timing figures do not depend on the workgroup. The output prefix keeps the results apart from report output and is deleted at the end.

### RESOLVED: Judgment call: one README commit or two?
**Context**: The `logs_by_app` paragraph needs its own app-month measurement.
**Options considered**:
- A) Two commits: `logs_by_hour` and its conventions, then the `logs_by_app` paragraph
- B) One commit holding both

**Decision**: A. The first commit is what REPORT-150 needs, and it should not wait on a measurement it does not use.

### RESOLVED: Judgment call: what does R9's cost table measure?
**Context**: Athena can answer `count(*)` over Parquet from metadata, so its bytes scanned can understate a real query.
**Options considered**:
- A) `count(*)` for hour, day and month, plus one column-reading query for a day
- B) Only `count(*)`, as Jira's acceptance criteria phrase it

**Decision**: A, and R9 now names the extra query (Doug, 2026-10-13). It costs one more day's read, and gives REPORT-150 the figure for the query it will actually run.

## Self-Review

Roles: Operator (running the steps as written), Senior Engineer (the SQL), Commit reviewer, Test writer.

### Operator

#### RESOLVED: The query helper and its output prefix work as written
`athena_run` was run on staging with `SHOW CREATE TABLE log_ingester_qa.logs_by_time`. It needed no go, because it scans 0 bytes. It succeeded in the `primary` workgroup with the explicit output prefix, printed the statistics (scanned 0, total 852 ms) and the result, and wrote two objects under `s3://concord-staging-report-data/report-107/`, which were then deleted. The output also confirms, from Athena itself, that `logs_by_time` has no `PARTITIONED BY`. No change was needed. The cutover script's `awk` was checked with GNU Awk 5.1, whose `{4}` intervals it relies on.

### Senior Engineer

#### RESOLVED: The `$path` day filter could match a secure-key folder
The reconciliation selected a day's nightly files with `"$path" LIKE '%/06\_%.parquet'`. `%` matches across `/`, so `.../CLUE/2026/10/06_abc/12_0.parquet` matches as well as `.../abc123/06_0.parquet` (checked in DuckDB). None of staging's 90,659 secure-key folder names starts with two digits and an underscore, so it has not happened yet. The pattern is now `regexp_like("$path", '/06_[0-9]+\.parquet$')`, which anchors on the file name. The requirements' Technical Notes changed to match.

#### RESOLVED: The staging reconciliation's expected result depended on the enum
`logs_by_app` on staging projects only 8 apps. The plan said "0 on each side" without checking that 2026-10-06's nightly files are all inside them. They are (`Activity_Player` 5, `CLUE` 1, `CODAPV3` 1), so the expectation stands, and the step now says why.

### Commit reviewer

No finding. The two commits are independent, and neither changes what `athena_config_test.exs` counts (run against the first).

### Test writer

No finding. No automated test changes. `athena_config_test.exs` reads the README, and stage 4 ran it against a README with the new DDL added.


### Round 2 (2026-10-13)

Roles: Operator, Senior Engineer (Athena SQL), QA Engineer.

#### Operator

##### RESOLVED: Double-quoted SQL loses `${dt}` and `"$path"`
The plan ran the DDL as `athena_run ... "<DDL>"`. Bash expands `${dt}` inside double quotes, so the DDL's `storage.location.template` became `s3://log-ingester-qa/processed_logs_with_id//`, and `regexp_like("$path", ...)` became `regexp_like(, ...)` (both shown by printing the argument the helper would receive). The helper section now passes every statement through a quoted heredoc, which was then used for the review's own Athena calls on staging and reached Athena intact. The DDL's parenthetical also now says the production text differs in the database name as well as the buckets.

#### Senior Engineer

##### RESOLVED: The reconciliation read each side three times
`EXPLAIN` of the reconciliation's shape on staging (with `logs_by_app` standing in for `logs_by_hour`, 0 bytes scanned) showed five table scans, because Athena does not materialize a `WITH` query and `raw` and `nightly` were each named in three subqueries. The production go request would have understated the scan by about three times. The query now tags each side, unions them and groups by `id`, and the same `EXPLAIN` shows one scan per side. It also counts repeated ids, which the old form could not see, and it has no `NOT IN`, which counts 0 whenever the other side holds a null `id`. A DuckDB fixture (raw `a,b,c,c`, nightly `a,b,d`) gives 4, 3, 1, 1, 1 for the five columns.

#### QA Engineer

##### RESOLVED: `EXPLAIN` cannot show that the projection pruned
The convention 1 check expected `EXPLAIN` to show the query reading only the hours since a lower bound. On staging, both `EXPLAIN` and `EXPLAIN (TYPE IO)` of `logs_by_app` with `app`, `year` and `month` predicates print a bare `TableScan` and an empty `columnConstraints` list, so the check could not fail. It is now a column-reading query whose `scanned` is compared with the listed bytes of the hours in range.
