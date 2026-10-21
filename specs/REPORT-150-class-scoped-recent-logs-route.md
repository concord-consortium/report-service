# The class-scoped recent-logs route

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-150

**Status**: **Closed**

## Overview

report-server gains one route, `GET /api/v1/classes/:class_id/recent-logs`, that answers a class's log events from the last day or two, about two minutes behind live, read from REPORT-107's `logs_by_hour` table. It serves cc-data (packages reading fresh logs, through REPORT-152's command), the Researcher Dashboard page can call it with its access token, and it refuses any class the caller's grants do not reach. The rows have the same shape the Student Actions report produces, so an analysis reads them the way it reads a nightly log run, and every read is recorded in the data-access audit log.

## Requirements

**The route**

- **R1.** `GET /api/v1/classes/:class_id/recent-logs`, `class_id` the portal's integer class id; a non-positive or non-integer id is 400 `BAD_REQUEST`.
- **R2.** Two credentials, each with its existing checks: an API token (`Bearer ccd_…`, checked as `AuthPlug` does), or the portal's scoped access token verified as the catalog does with capability `class:researcher-read`, accepted only when its `context` is `{"type": "class", "id": <class_id>}` (another class or no class is 403). Role flags for an access-token caller are read from the portal on each request. No or bad credential is 401 `NOT_AUTHENTICATED`.
- **R3.** On every request the class must be one `DimensionScope` resolves for the caller's allowed projects (a portal admin reaches every class), else 403 `FORBIDDEN` without saying whether the class exists. A portal that cannot be asked is 503.
- **R4.** The learners are those `LearnerData.fetch/3` returns for a filter naming only this class, as the caller, with no date bound. A class with no learners is 200 with no rows.
- **R5.** Each row has the 13 `student-actions` columns in their order (`id`, `session`, `application`, `activity`, `event`, `event_value`, `time`, `parameters`, `extras`, `run_remote_endpoint`, `timestamp`, `user_id`, `primary_user_id`), no `username`. `time`, `timestamp`, `user_id` and `primary_user_id` are integers, the rest strings; an empty field is `null`. Ordered by `timestamp`, then `id`.
- **R6.** The window (R8) is the route's whole reach; rows have `since <= timestamp < until`. With no parameters `since` is `window_start` and there is no `until`. Optional `start` and `end` (epoch ms, non-negative, at most 13 digits) narrow it; a bound before `window_start`, `end` not after `start`, or a malformed value is 400 naming `window_start` and pointing earlier days at a Student Actions run. A cursor with `start` or `end` is 400.
- **R7.** The query follows REPORT-107's conventions: `logs_by_hour` in the configured log database, `dt` bounded below at the hour of `since` minus one hour and, with an `until`, above at its hour plus one; filtered on `timestamp`, never `time`; scoped by row to the learners' `run_remote_endpoint`; no `application` filter.

**The window, the cursor and the seam with the nightly copy**

- **R8.** `window_start` is 00:00 UTC of the day before the query's UTC date (a 24 to 48 hour window). The day before it is `nightly_through`, the last day left to the nightly copy; with REPORT-182, a `student-actions` run ending on it meets the route's rows at `timestamp = window_start` with no gap. A combining caller whose run named applications filters the route's rows by the raw `application` value.
- **R9.** A response to a request with no `end` carries `next_cursor`: opaque, version 1 holding the class id and `since = query_started_at - 10 minutes`, never derived from the rows. A cursor read has no `until`. Responses overlap by design and the caller dedups by `id`. A cursor for another class, an unknown version or an undecodable one is 400; one whose `since` is before the current `window_start` is 410 `EXPIRED_CURSOR`.
- **R10.** *(Withdrawn 2026-10-21: no count-only form, since its one consumer, RD-12's live log count, was dropped.)*

**The response**

- **R11.** 200 with JSON `{class_id, window_start, nightly_through, since, until, query_started_at, latest_timestamp, count, rows, next_cursor}`; times in epoch ms, `until` `null` when unbounded, `nightly_through` an ISO date, `latest_timestamp` the largest row `timestamp` or `null`. `count`, `latest_timestamp` and `next_cursor` follow `rows` in the body.
- **R12.** Rows stream from the Athena result as they are read. Streaming starts only after the query succeeds and the audit row is written; a failure after the first byte ends the body early as invalid JSON, and the caller retries.
- **R13.** Errors use `ErrorHelpers.render_error/4`. An Athena failure or a query not finished within 60 seconds is 503; report-server stops waiting but does not stop the query (no `athena:StopQueryExecution`). A class whose learners push the query past Athena's 262,144-byte limit (about 2,100 learners) is 422 `UNPROCESSABLE`.
- **R14.** At most a configured number of requests (default 4, `RECENT_LOGS_MAX_CONCURRENT`) wait on or stream these queries per server; beyond that is 503 at once. A query left running after R13's timeout holds no slot.

**Reading Athena**

- **R15.** The query runs in the caller's own Athena workgroup with report-server's AWS credentials, and the result is read from the query's S3 output location, not `athena:GetQueryResults`. No IAM change.
- **R16.** An access-token caller is resolved to its report-server user row by portal and portal user id, created on first use and refreshed from the portal's user row on every use (role flags, names, email), so the workgroup and audit row match that user's report runs.

**Audit**

- **R17.** Before the first row, a fail-closed `data_access_log` row: event `recent_logs_read`, source `api`, data type `recent_logs`, the caller, the class in `report_filter`, `since` in `cursor`, the learners' endpoints in `endpoint_set`. A failed write is 500 with no rows. A migration makes `report_run_id` nullable for this event, applied before the image serves traffic; the audit page shows such a row with its class in place of a run link.

**Cross-origin**

- **R18.** Browser requests from `PACKAGES_CORS_ORIGINS` are answered through `CatalogCors`, with an `OPTIONS` preflight route; other origins are refused as the catalog refuses them.

**Documentation and checks**

- **R19.** `server/README.md` documents the route: credentials, window and nightly seam (including the partitioner assumption and its remedy), `start`/`end`, the cursor and overlap, the resume rule (from the last `query_started_at` minus ten minutes, never the largest `timestamp`), the error codes and the audit event. The catalog's "only routes with CORS" sentence is corrected.
- **R20.** Tests pin the generated SQL as a string (padded `dt` bounds, `timestamp` bounds, learner join, no `time` or `application` predicate, the 13 columns) across midnight UTC, a cursor's `since` and `start` with `end`; the cursor round-trip and every R6 and R9 refusal; each credential's R2 and R3 refusals; the 503s of R13 and R14, the 422, and the audit row and its fail-closed path, against stubbed Athena and S3.
- **R21.** Staging check, on Doug's go, after the staging release *(not yet run; see Not Yet Implemented)*: rows at or after `since`, a new action visible within two minutes plus query time, the cursor's overlap and new rows, an hour-wide `start`/`end`, 400 for a `start` before `window_start`, reconciliation by `id` against a `student-actions` run for yesterday taken after its nightly copy exists, 403 outside the grants, and the dashboard's access token from its origin.

## Technical Notes

- **Code it builds on.** `ReportQuery.get_log_cols/1` (with `remove_username: true`) and `get_minimal_learner_cols/0` return `{expression, alias}` tuples; `LearnerBaseQuery.build/4` scopes learners to allowed projects and, for a filter naming one class, does not repeat a learner; `DimensionScope` decides which classes a caller may name; `HideNames` does not touch the 13 columns.
- **Athena execution.** `AthenaDB.query/3` checks the query-size limit, ensures the per-user workgroup (named from portal server, portal user id and email, which is why R16 resolves a stored user: a claims-built `%User{}` has no email and gets a different workgroup), and starts the query. `AthenaQueryPoller.wait_for/2` gained `:timeout_ms` and `:interval_ms`. `Aws.get_file_stream/1` streams the result CSV.
- **Inline learners.** The SQL joins an inline `VALUES` table of learners rather than the uploaded `learners` table, so a read writes nothing to S3; about 123 bytes per learner, hence the 422 near 2,100 learners. Athena accepted the `JOIN (VALUES ...) AS learner (...)` form (staging `EXPLAIN`, 0 bytes scanned).
- **IAM (read 2026-10-21).** Staging `report-server-staging` and production `report-server-prod` (both v7) allow `glue:GetTable` on `*`, `athena:StartQueryExecution`, `GetQueryExecution`, `GetWorkGroup`, `CreateWorkGroup`, read on the log bucket and read/write on the report bucket's `workgroup-output/`. Neither allows `GetQueryResults` or `StopQueryExecution`. The README's policy blocks still omit these statements (known drift, left alone).
- **Cost.** The class filter is a row predicate, so a read scans every application's bytes for its hours: about 170 MB per production day (REPORT-107), so up to two days on a first call and about two hours on a cursor call.
- **Streaming on Bandit.** A raise after the first chunk closes the connection with no terminating chunk, so R12's truncated body holds. An S3 failure mid-stream arrives as an exit from ExAws's linked `Task.async_stream` task, which kills the request process past any `rescue` or `after`; the limiter's monitor frees the slot.
- **Migration.** A column-only `modify :report_run_id, :"bigint unsigned", null: true`; the `references(...)` form fails on MySQL ("Duplicate foreign key constraint name"). Once a `recent_logs_read` row exists the migration cannot be rolled back (MySQL 1138); roll back the image only, whose audit page renders a `nil` run as an empty link.
- **Release.** The migration runs before the image serves traffic (README "Deploying", step 3), and `PACKAGES_CORS_ORIGINS` must include the dashboard's origin on each stack.

## Out of Scope

- The cc-data command, its `id`-keyed store and its persisted cursor (REPORT-152).
- Deduplicating log rows across overlapping log runs and recent-log pulls (REPORT-192, cc-data-cli), and deduplicating in the route: a row repeated under the same `id` is the caller's, and one repeated under a new `id` is undetectable (REPORT-107).
- A completion marker for the nightly copy, or any change to the partitioner, Firehose or the log tables.
- Reading days before `window_start` (a Student Actions run over the nightly copy covers them).
- Caching answers between requests.
- Moving `teacher-actions` or the Student Actions reports onto `logs_by_hour`.
- Scopes other than a class (a cohort; final design 15.1).

## Not Yet Implemented

- R21's staging check: runs on Doug's go after the staging release that carries the route, with the dashboard's access token for a class with that day's activity.

## Decisions

### Recent window only, or everything?
**Context**: once cc-data uses the route in a package re-run, no logs may be missed.
**Options considered**:
- A) The fixed recent window only.
- B) An optional `start` reaching further back (7 days proposed) from `logs_by_hour`.
- C) A whole-history count for `count_only` only.

**Decision** (Doug, 2026-10-21): A, with optional `start` and `end` inside the window. Earlier days come from a Student Actions run over the nightly copy; `wildfire-simulation-use`'s whole-history log run, fetched after 03:00 UTC, always reaches `window_start`, and REPORT-192 removes the overlap. A day the partitioner failed to copy and a row delivered after its day left the window are not covered, by choice.

---

### One route for both credentials, with the class in the path
**Options considered**: one route accepting either credential, the access token's `context` required to match; two routes, the access-token one taking its class from the token.
**Decision**: one route. cc-data's API token names no class, and a second route for the same rows would be a second contract to keep in step; the match is one comparison.

---

### A count-only form
**Options considered**: rows only; a `count_only` flag for RD-12's polling page.
**Decision**: `count_only` was chosen, then withdrawn on 2026-10-21 when RD-12 was re-scoped to activity numbers and stopped using the route (Doug). The route answers rows only.

---

### Audit the route
**Options considered**: no audit row, as for `GET /reports/:id`; a fail-closed row per answer with rows.
**Decision**: audit. The route hands out student rows outside any report run, and every other such path is audited fail closed.

---

### The nightly rule assumes the partitioner run succeeded
**Context**: the partitioner has no retry and writes no marker, so a failed run for `nightly_through` leaves a silent gap.
**Options considered**:
- A) Keep R8 and document that a failed run is an operations failure to rerun.
- B) Start the window two days back (about 50% more bytes per first call).
- C) Check the nightly copy on every request and move the window back when it is missing.

**Decision**: A. A failed run already leaves that day missing from every log report, with an existing remedy; B only moves the edge and C doubles the work for a rare event. The README states the assumption and the remedy.

---

### report-server's Glue and Athena reach for `logs_by_hour`
**Options considered**: read both IAM policies before implementation; find out at R21.
**Decision**: read them, on Doug's go (2026-10-21). Both allow what the route uses; no IAM change.

---

### Inline learners instead of the uploaded `learners` table
**Options considered**: `LearnerData.fetch_and_upload/2` and the `"report-service"."learners"` join `student-actions` uses; an inline `VALUES` table.
**Decision**: inline, so polling writes nothing to S3 and the query depends only on `logs_by_hour`. The cost is the 422 above about 2,100 learners, against tens to a few hundred in real classes (a 35-student class with 14 assignments is 490).

---

### Trino's `VALUES` alias syntax on Athena
**Options considered**: one staging `EXPLAIN` before the controller step; find out at R21.
**Decision**: the `EXPLAIN`, on Doug's go; it succeeded with 0 bytes scanned. The fallback, a `WITH ... AS (VALUES ...)` clause, was not needed.

---

### The access-token caller's user row is refreshed on every call
**Decision**: stated in R16. `Accounts.find_or_create_user/1` also updates an existing row, including the role flags API tokens are checked against; the refreshed values are the portal's current ones, and minting a dashboard VM token already rewrites the same row. A portal user with a blank required field is refused (401) before a row is created that every later update would reject.

---

### Reuse `PortalDownloadLimiter` with a name rather than a new module
**Options considered**: a new module duplicating the semaphore; renaming the module; a `:name` option.
**Decision**: the `:name` option: one semaphore implementation, no churn in the Portal download path, and the moduledoc names each instance.

---

### Decide the credential by the `ccd_` prefix
**Options considered**: try the API token, then the access token, for every bearer; branch on the prefix.
**Decision**: the prefix, read from `Accounts.api_token_prefix/0`. Every API token starts with it and no JWT can (a JWT starts `eyJ`), so a bad token is checked once.

---

### Bounds capped at 13 digits
**Context**: an oversized `start`, `end` or cursor `s` made the `dt` bound raise, a 500 rather than a 400.
**Decision**: refuse values above 13 digits (year 2286) as 400, and answer every bound refusal with the message that names `window_start`.

---

### R14 caps requests, not running queries
**Context**: a timed-out query keeps running in Athena while its request's slot is freed.
**Decision**: R14 promises a per-server cap on requests and says so, rather than a cap on Athena queries report-server cannot enforce without `StopQueryExecution`.

---

### Rows as ordered objects
**Context**: `Jason.encode!/1` of a 13-key map emits keys alphabetically, against R5's column order.
**Decision**: `RecentLogs.row/1` returns a `Jason.OrderedObject`, with a test on the encoded order.

---

### Audit failure tested through a config seam
**Context**: forcing an insert failure with DDL inside the SQL sandbox commits implicitly on MySQL.
**Decision**: the controller reads its audit module from `:audit_log` config, as it reads `:athena_db` and `:aws_file_store`, and the test installs `AuditLogFailingStub`.
