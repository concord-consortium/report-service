# The class-scoped recent-logs route

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-150
**Repo**: https://github.com/concord-consortium/report-service
**Implementation Spec**: [implementation.md](implementation.md)
**Status**: **In Development**

## Overview

report-server gains one route that answers a class's log events from the last day or two, about two minutes behind live, read from REPORT-107's `logs_by_hour` table. It serves cc-data (packages reading fresh logs, through REPORT-152's command), and the Researcher Dashboard page can call it with its access token, and it refuses any class the caller's grants do not reach.

## Project Owner Overview

Every log a researcher sees today comes from a nightly copy, so it is between 2 and 26 hours old: an analysis run during a lesson cannot see what students did in that lesson. The Wildfire analyses want to read the model runs and Hazbot clicks of the class period that just ended.

This story is the server half. It adds a route that returns the class's recent log rows, in the same shape the Student Actions report already produces, so an analysis reads them the way it reads a nightly log run. The cc-data command that reads the rows is its own story (REPORT-152). The route runs as the researcher asking, sees only what that researcher's project grants reach, and is recorded in the data-access audit log like every other read of student data.

## Background

- **Why logs are stale.** Firehose writes each event to `processed_logs_with_id/YYYY/MM/DD/HH/` about a minute after receipt (60-second buffers, up to two minutes measured). The partitioner copies each UTC day into `logs_by_app_and_secure_key/` at 02:00 UTC the next day, and every log report reads that copy. REPORT-107 declared `logs_by_hour` over the hourly folders in staging (`log_ingester_qa`) and production (`log_ingester_production`) and documented in `server/README.md` "Querying recent logs" seven conventions a query on it must follow, the measured costs, and the fact that nothing marks a nightly day complete (convention 5). Its closed spec leaves the class route, its authorization, its result reading, combining the tables and the completeness rule to this story (`specs/REPORT-107-athena-table-over-the-raw-log-landing-zone.md`, Decisions).
- **Decided scope (Doug).** 2026-10-13: the route returns the class's recent rows, not only a count, so packages read logs about two minutes old; the cc-data command is REPORT-152's. 2026-10-14: the rows are the same full rows the log reports return (the `student-actions` columns, `parameters` and `extras` included); the cursor starts from `log-cursor-and-dedup.md` (global oob, `streams/researcher-dashboard/`): an opaque versioned cursor, the server's query start minus a settle margin, never the largest `timestamp` returned; dedup by `id` is the caller's; on 2026-10-21 Doug made it a cc-data-cli story of its own, REPORT-192 (a view with one row per `id`), not package SQL and not part of REPORT-152. Whether the route reads only a recent window or everything is for this spec's stage 8. Recorded in the stream's `landing-tracker.md` item 9.2.
- **REPORT-182** (PR #443, merged to `master` as `162c0d4`) moves the three log reports onto `timestamp` and includes each range's last day: a `student-actions` run ending on day E holds exactly the rows with `timestamp < (E + 1) 00:00 UTC`. That is the clean seam this route's window starts from.
- **Final design, sections 11 and 13.** The route belongs in report-server behind the existing token checks, never as an Athena query run from the runner under its execution role. A package runs as the researcher, and two researchers with different grants may see different rows for one class. The dashboard holds the portal's scoped access token (RS256, `typ: at+jwt`, `aud` naming report-server, `scope` listing `class:researcher-read class:researcher-run packages:read profile`, `context` `{"type": "class", "id": <int>}`); a capability is a ceiling, and the action runs its own check on every call. The runner VM and cc-data hold an ordinary report-server API token.
- **Consumers.** REPORT-152 (the cc-data command, which keeps rows in a store keyed by `id` with the cursor per dataset and class). RD-12 was to show a live log count from this route; on 2026-10-21 it was re-scoped to the class's activity numbers and no longer reads it (Doug).

## Requirements

### The route

- **R1. One route, `GET /api/v1/classes/:class_id/recent-logs`.** `class_id` is the portal's integer class id on the caller's portal. A non-positive or non-integer id is 400 `BAD_REQUEST`.
- **R2. Two credentials, the existing checks for each.**
  - An API token (`Authorization: Bearer ccd_…`), checked as `AuthPlug` checks it today (unrevoked, unexpired, and `Auth.can_access_reports?`). This is cc-data's and the runner VM's credential.
  - The portal's scoped access token, verified as the catalog verifies it (`PortalToken.verify_access_token/3`) with the capability `class:researcher-read`, and only when its `context` is `{"type": "class", "id": <class_id>}` for the class in the path. A token whose context names another class, or no class, is 403 `FORBIDDEN`. The caller's role flags are read from the portal on each request (as `Packages.reader/1` does), not from report-server's stored copy.
  - No credential, or one that fails verification, is 401 `NOT_AUTHENTICATED`.
- **R3. The class must be within the caller's grants.** On every request, the class must be one `DimensionScope` resolves for the caller's allowed projects (`PortalDbs.get_allowed_project_ids/2`; a portal admin reaches every class). Otherwise the answer is 403 `FORBIDDEN` with a message that does not say whether the class exists. A portal that cannot be asked is 503 `SERVICE_UNAVAILABLE`.
- **R4. Which learners.** The class's learners are those `LearnerData.fetch/3` returns for a filter naming only this class, as the caller, with no date bound: the same learners a `student-actions` run filtered to that class alone selects, including its project scoping. A class with no learners answers 200 with no rows.
- **R5. The rows.** Each row has exactly the 13 columns a `student-actions` CSV has, in its order: `id`, `session`, `application`, `activity`, `event`, `event_value`, `time`, `parameters`, `extras`, `run_remote_endpoint`, `timestamp`, `user_id`, `primary_user_id`. No `username` column, as in `student-actions`. `time`, `timestamp`, `user_id` and `primary_user_id` are integers (the last two are the learner columns `ReportQuery.get_minimal_learner_cols/1` gives); the others are strings. A field that is empty in Athena's result CSV is `null`, so an empty string and a missing value read the same, as they do in a `student-actions` CSV. Rows are ordered by `timestamp`, then `id`.
- **R6. The window, and what a caller may ask for within it.** The window (R8) is the route's whole reach: it reads nothing earlier than `window_start`, and a caller can narrow it but not widen it. Rows have `since <= timestamp < until`. A caller sets the bounds one of three ways:
  - **Nothing:** `since` is `window_start` and there is no `until`, so the newest rows are always included.
  - **`start` and `end`:** optional query parameters in epoch milliseconds, either or both. `since` is `start` (default `window_start`) and `until` is `end` (default none). `start` earlier than `window_start`, `end` earlier than `window_start`, `end` not after `start`, or a value that is not a non-negative integer of at most 13 digits is 400 `BAD_REQUEST`, with a message naming `window_start` and saying that earlier days come from a Student Actions run over the nightly copy.
  - **`cursor`:** R9. A cursor with `start` or `end` is 400.
- **R7. The query follows REPORT-107's conventions.** It reads `logs_by_hour` in the configured log database, bounds `dt` below at the hour of `since` minus one hour and, when there is an `until`, above at the hour of `until` plus one hour (conventions 1 and 3), filters on `timestamp`, never `time` (convention 2), and scopes by row to the learners' `run_remote_endpoint` (convention 6). It has no `application` filter.

### The window, the cursor and the seam with the nightly copy

- **R8. The window start, and the nightly seam.** The window starts at 00:00 UTC of the day before the query's UTC date (`window_start`), so it spans 24 to 48 hours. The day before it (`window_start - 1 day`) is the last day the route treats as held by the nightly copy, and the response says so (R11). A caller that wants a class's whole history takes a `student-actions` run ending on that day and the route's rows from `window_start`; with REPORT-182, the two meet at `timestamp = window_start` with no gap. The route returns every application's rows, so a caller whose run named applications filters the route's rows to the same ones by `application`, the raw client value (`Activity Player`, not `Activity_Player`; REPORT-107 convention 7). (The nightly copy of that day was written by the partitioner's 02:00 UTC run on `window_start`'s date, at least 22 hours before any query that uses this rule.)
- **R9. The cursor.** Every response to a request with no `end` carries `next_cursor` (a bounded read is not incremental, so it carries none), an opaque string whose version-1 content is the class id and `since = query_started_at - 10 minutes`, where `query_started_at` is report-server's clock when it submits the Athena query. It is never derived from the rows returned. A request with a cursor reads from the cursor's `since`, with no `until`. Responses overlap by design, and the caller deduplicates on `id`. A cursor for another class, an unknown version, or one that does not decode is 400 `BAD_REQUEST`. A cursor whose `since` is earlier than the current `window_start` is 410 `EXPIRED_CURSOR`, which tells the caller to start again without a cursor (and to read the days before from a nightly run).
- **R10. (Withdrawn 2026-10-21.)** No count-only form: its one consumer, RD-12's live log count, was dropped (Doug).

### The response

- **R11. Shape.** 200 with JSON `{class_id, window_start, nightly_through, since, until, query_started_at, latest_timestamp, count, rows, next_cursor}`. `window_start`, `since`, `until`, `query_started_at` and `latest_timestamp` are epoch milliseconds, and `until` is `null` when the read has no upper bound; `nightly_through` is the ISO date of the last day R8 assigns to the nightly copy; `latest_timestamp` is the largest `timestamp` among the rows counted, or `null` when there are none; `count` is the number of rows. `rows` is an array of objects keyed by R5's column names. Since the rows stream (R12), `count`, `latest_timestamp` and `next_cursor` come after `rows` in the body.
- **R12. Large answers stream.** The rows are streamed to the client from the Athena result as they are read, so a response's size does not bound report-server's memory. Streaming starts only after the query has succeeded and the audit row is written; a failure reading the result after the first byte ends the response early, so the body is not valid JSON and the caller retries.
- **R13. Errors use the API's error shape** (`ErrorHelpers.render_error/4`). An Athena failure, or a query not finished within 60 seconds, is 503 `SERVICE_UNAVAILABLE`. report-server stops waiting but does not stop the query: that needs `athena:StopQueryExecution`, which neither report-server policy allows, and a query over at most two days of `logs_by_hour` finishes on its own. A class whose learners make the query longer than Athena's 262,144-byte limit (about 2,100 learners, counting each student once per assignment) is 422 `UNPROCESSABLE`, with a message saying the class is too large for the route.
- **R14. Bounded concurrency.** At most a configured number of requests wait on or stream these queries at once per server (default 4); a request beyond that is 503 `SERVICE_UNAVAILABLE` at once rather than queued. A query left running after R13's timeout no longer holds a slot.

### Reading Athena

- **R15. As the caller, with the server's AWS identity.** The query runs in the caller's own Athena workgroup, the one report runs use, with report-server's AWS credentials. The result is read from the query's output location in S3 with those credentials; `athena:GetQueryResults` is not used, since neither environment's report-server policy allows it (REPORT-107, Technical Notes). No IAM change.
- **R16. The access-token caller has a report-server user.** A caller with only an access token is resolved to its report-server user row by portal and portal user id, created from the portal's user row on first use and refreshed from it on every later use, so that the workgroup and the audit row (R17) are the same ones that user's report runs and API reads use. The refresh also rewrites the row's stored role flags, names and email, which that user's API tokens are checked against, as minting a dashboard VM token already does.

### Audit

- **R17. Every answer with rows is audited, fail closed.** Before the first row is sent, report-server writes a `data_access_log` row: event `recent_logs_read`, source `api`, data type `recent_logs`, the caller's user, the class id, `since`, and the learners' remote endpoints. If the write fails, the response is 500 and carries no rows. The audit log's report-run requirement is relaxed for this event only, which needs a migration (`data_access_log.report_run_id` is `NOT NULL` today) applied before the release's image serves traffic. The class id goes in the row's `report_filter`, `since` in its `cursor` and the endpoints in its `endpoint_set`, so the audit page's remote-endpoint filter finds these reads. The audit page shows such a row with its class in place of a run link.

### Cross-origin

- **R18. CORS for the dashboard.** The route answers browser requests from the origins in `PACKAGES_CORS_ORIGINS`, the allowlist the catalog uses, through the same plug (`CatalogCors`), with an `OPTIONS` preflight route. It has no anonymous form, so a request from another origin is refused as the catalog refuses it.

### Documentation and checks

- **R19. README.** `server/README.md` documents the route: the credentials, the window and the nightly seam (including that it assumes the partitioner's run for `nightly_through` succeeded, and that a failed run is fixed by rerunning it for that day), `start` and `end` and their limit to the window, the cursor and its overlap, the rule that a caller resuming a pull sets `start` (or keeps the cursor) from its last `query_started_at` minus ten minutes and never from the largest `timestamp` it holds (a row with an earlier `timestamp` can land later), the error codes, and the audit event. The catalog paragraph's "These three reads are the only routes with CORS" is corrected.
- **R20. Tests.** The generated SQL is pinned as a string (the `dt` bound padded an hour, the `timestamp` bound, the learner join, no `time` or `application` predicate, the 13 columns), including the window start on either side of midnight UTC, a cursor's `since`, and `start` with `end` (the `dt` upper bound padded an hour and the `timestamp < until` bound). The cursor round-trips, and each refusal in R6 and R9 is tested. Each credential's refusals in R2 and R3 are tested, including an access token for another class and a class outside the grants. The 503s in R13 and R14, the 422 in R13, and the audit row and its fail-closed path in R17 are tested against stubbed Athena and S3.
- **R21. Staging check (on Doug's go).** On deployed staging, for a class with learners active that day: the route answers rows whose `timestamp` is at or after `since`, a new student action appears within two minutes plus the query time, a second call with `next_cursor` returns the overlap and the new rows, a call with `start` and `end` an hour apart returns only rows inside them, a `start` before `window_start` is 400, the rows with `timestamp` before today's 00:00 UTC match by `id` a `student-actions` run for yesterday alone taken after yesterday's nightly copy exists (after 02:00 UTC plus the partitioner's run time), a class outside the caller's grants is 403, and the dashboard's access token for the class works from the dashboard's origin.

## Technical Notes

- **Code it builds on.** `ReportQuery.get_log_cols/1` (the 12 log columns, `remove_username: true`) and `get_minimal_learner_cols/1`; `ReportQuery.get_athena_query/3` builds `student-actions` over `logs_by_app_and_secure_key` with the uploaded `"report-service"."learners"` table joined on `query_id` and `run_remote_endpoint`; `LearnerData.fetch_and_upload/2` writes that table's JSONL; `LearnerBaseQuery.build/4` scopes learners to allowed projects; `DimensionScope` decides which classes a caller may name (a class whose teacher is in an allowed project's cohort); `HideNames` does not affect the 13 columns, since `username` is removed and the learner columns are ids.
- **Athena execution.** `AthenaDB.query/3` checks the 262,144-byte limit, ensures the per-user workgroup (named from portal server, portal user id and email), and starts the query with server credentials; `AthenaQueryPoller` polls every 5 s with no timeout, which is too coarse and unbounded for a request; `Aws.get_file_stream/1` streams an output CSV, as the CLUE answers path does (`clue.ex`). Nothing uses `GetQueryResults`.
- **Credentials today.** `AuthPlug` gives `:current_user` from an API token; `PortalTokenPlug` gives `:portal_claims` from an access token with a named capability and is used only by the catalog (`packages:read`); no route reads a token's `context`. `Packages.reader/1` builds a `%User{}` from claims with fresh role flags. A dashboard VM's token is an ordinary API token minted by `DashboardTokenController`, nine hours, no class binding.
- **Audit today.** `DataAccessLogEntry` requires `report_run_id` and `user_id` and restricts `event`, `source` and `data_type` to fixed lists; every write is fail closed.
- **Limits today.** `PortalDownloadLimiter` is the existing counting semaphore (503 when full). There is no request rate limiting and no cache.
- **Permissions.** Both report-server IAM users can start and read Athena queries, read the log buckets and read and write their report bucket's `workgroup-output/`, which is where a per-user workgroup's results go (REPORT-107 R14).
- **Cost.** A full row reads every column for the hours in range across every application, since the class filter is a row predicate: about 170 MB per production day (REPORT-107's measurement of a day's data), so a first call reads up to two days and a cursor call about two hours (the padded `dt` range).
- **REPORT-182** is merged into this branch's base (`master` `162c0d4`). R8's seam relies on its `timestamp` bounds for the nightly run, so the seam is exact on any server whose release carries REPORT-182; before that release, a `student-actions` run filters on `time` and the seam is approximate. The route uses none of REPORT-182's code: its helpers (`ReportUtils.apply_log_start_date/3` and `apply_log_end_date/3`, `ReportQuery.partition_date/2`) turn ISO dates into bounds, while the route works in epoch milliseconds and reads no `year`/`month` partitions.
- **Checked in throwaway tests while speccing.** `LearnerBaseQuery.build/4` with a filter naming only a class builds `rl.class_id IN (<id>)` over `report_learners` with `DISTINCT rl.learner_id`, so the `LEFT JOIN portal_runs` does not repeat a learner and the Athena join does not repeat a row. A `%User{}` built from token claims, as `Packages.reader/1` builds it, has no `portal_email`, and `AthenaDB`'s workgroup name for it is `learn-concord-org-7-` rather than the name with the email that user's report runs use, which is why R16 resolves the user row. `ReportFilter.get_filter_values/2` with `%ReportFilter{class: [id]}` answers `{:error, :out_of_scope, _}` for a class the caller's projects do not reach; R3 maps that to 403 rather than the 400 `POST /reports` gives.
- **Checked in stage 4.** The access-token verifier returns the raw claims (`PortalToken.verify_access_token/3`), so the route can read `context`; the dashboard's staging token carries `context` class 590 (RIGSE-374's staging check, stream channel #735). `CatalogCors` reads nothing route-specific, so a second scope can use it. Window arithmetic run in Elixir for 00:00:30 and 23:59:59 on 2026-10-21, 00:05 on 2026-11-01 and 00:00 on 2026-01-01: `window_start` is the previous day's 00:00 UTC, `nightly_through` the day before that, the `dt` lower bound the hour before `window_start` (`2025/12/30/23` across the year end), and a cursor taken at any of those times is still inside the next request's window.
- **Not checked live while speccing.** No Athena or AWS call was made (Athena queries wait on Doug's go). The costs above are REPORT-107's measurements.

## Out of Scope

- The cc-data command, its `id`-keyed store and its persisted cursor (REPORT-152).
- Deduplicating log rows across overlapping log runs and recent-log pulls: REPORT-192, a separate cc-data-cli story (Doug, 2026-10-21), so no package has to work out which rows are the same event.
- A completion marker for the nightly copy, or any change to the partitioner, Firehose or the log tables.
- Deduplicating rows in the route: a row repeated under the same `id` is left to the caller, and one repeated under a new `id` is undetectable (REPORT-107).
- Reading days before `window_start`: those come from a Student Actions run over the nightly copy.
- Caching answers between requests.
- Moving `teacher-actions` or the Student Actions reports onto `logs_by_hour`.
- Scopes other than a class (a cohort; final design 15.1).

## Open Questions

### RESOLVED: Recent window only, or everything?
**Context**: Doug left this for stage 8. The question behind it (Doug, 2026-10-21): once cc-data uses the route in a package re-run, no logs may be missed.
**Options considered**:
- A) The fixed recent window only.
- B) An optional `start` reaching further back (7 days was proposed) from `logs_by_hour`, which could also patch a stale log run or a day missing from the nightly copy.
- C) A whole-history count for `count_only` only.

**Decision** (Doug, 2026-10-21): A, with optional `start` and `end` that must fall inside the window (R6), so a package that knows what it already holds asks only for what follows. Days before `window_start` come from a regular Student Actions run over the nightly copy. `wildfire-simulation-use` already takes a whole-history log run fetched after the 03:00 UTC cutoff (`run.py`), which always reaches at least to `window_start`, so the two meet with no gap, and the overlap is removed by REPORT-192, the separate cc-data-cli dedup story. Not covered by the route, by choice: a day the partitioner failed to copy (REPORT-184; REPORT-114's alerting and gap check are the remedy), and a row Firehose delivers after its day was copied and after the window has moved past it (a pipeline gap every log report already shares).

### RESOLVED: Judgment call: one route for both credentials, with the class in the path
**Options considered**: one route accepting either credential, the class in the path and an access token's `context` required to match; two routes, one per credential, the access-token one taking its class from the token alone (the final design's "no scope in the routes" for rigse's endpoints).
**Decision**: one route. cc-data's API token names no class, so its route needs one in the request, and a second route for the same rows would be a second contract for REPORT-152 and RD-12 to keep in step. The match check is one comparison.

### RESOLVED: Judgment call: a count-only form
**Options considered**: rows only, the page counting them by `id` across cursor calls; a `count_only` flag.
**Decision**: `count_only` (R10), chosen for RD-12's polling page so it would not download full rows to show one number. Withdrawn on 2026-10-21 when RD-12 stopped using the route (Doug); the route answers rows only.

### RESOLVED: Judgment call: audit the route
**Options considered**: no audit row (the route is a read like `GET /reports/:id`); an audit row per answer with rows, relaxing the report-run requirement for the new event.
**Decision**: audit. The route returns student rows outside any report run, and every other path that hands out student data (CSV URLs, bulk reads, attachments) is audited fail closed; a new export path without it would be the gap a review flags.

### RESOLVED: Low confidence: R8's nightly rule assumes the partitioner run succeeded
**Context**: The partitioner's Batch job has no retry and writes no marker (REPORT-107 convention 5). If its run for `nightly_through` failed, a caller combining a nightly run with the route misses that day without knowing.
**Options considered**:
- A) Keep R8 and document that a failed partitioner run is an operations failure to be rerun.
- B) Start the window two days back (48 to 72 hours, about 50% more bytes per first call).
- C) Check the nightly copy for `nightly_through` before answering (an extra Athena or S3 listing per request), and move the window back a day when it is missing.

**Decision**: A. A failed partitioner run already leaves that day missing from every log report, so it is an existing operations failure with an existing remedy (rerun the partitioner for the day), not one this route can usefully paper over: B only moves the edge a day and C doubles the work on every request for a rare event. R19's README text states the assumption and the remedy.

### RESOLVED: Low confidence: report-server-staging's Glue and Athena reach for `logs_by_hour`
**Context**: REPORT-107's checks ran on staging with an operator's credentials, not report-server's. Its notes say staging's policy allows `glue:GetTable` and the two Athena actions, but not on which resources. If `glue:GetTable` is resource-scoped to the older tables, the route fails on staging until the policy names `logs_by_hour`.
**Options considered**:
- A) Read the staging and production policy documents (`aws iam get-policy-version`) before implementation, on Doug's go, and add an IAM step if needed.
- B) Find out at R21's staging check.

**Decision**: A, run on Doug's go on 2026-10-21: both policies grant `glue:GetTable` on `*` and the Athena and S3 actions the route uses, so no IAM change is needed (implementation.md, Pre-flight).

### RESOLVED: A 422 for a class too large for the inline learner list
**Context**: Found at stage 8: the plan puts the learners inline in the SQL (no S3 write per poll), which reaches Athena's 262,144-byte query limit at about 2,100 learners (123 bytes each with UUID secure keys), and no requirement said what the route answers then.
**Options considered**: add the 422 to R13; use the uploaded `learners` table, as `student-actions` does, which has no such limit but writes a file to S3 on every request.
**Decision**: add the 422 (stage 8, no decision needed from Doug). A class of 35 students with 14 assignments is 490 learners, a quarter of the limit, and the S3 write would land on every poll of every open page.

### RESOLVED: The access-token caller's user row is refreshed on every call
**Context**: Found at stage 8: R16 said the row is created on first use, but the plan's `Accounts.find_or_create_user/1` also updates an existing row, including the role flags API tokens are checked against.
**Decision**: state it in R16 (stage 8, no decision needed from Doug). The refreshed values are the portal's current ones, which is fresher than what the row held, and minting a dashboard VM token already rewrites the same row the same way.

## Self-Review

Roles: Security Engineer, Senior Engineer (Elixir and report-server), API consumer (REPORT-152's cc-data command), Dashboard consumer (RD-12), Education Researcher, DevOps Engineer, QA Engineer. Each finding below was checked against the code before it was written; each had one defensible correction and is fixed in place.

### DevOps Engineer

#### RESOLVED: The audit row needs a migration and an audit page change
`data_access_log.report_run_id` is `NOT NULL` with a foreign key (`priv/repo/migrations/20260713080100_create_data_access_log.exs`), and the audit page links every row to `/reports/runs/<report_run_id>` (`audit_log_live/index.html.heex`). R17 now names the migration, its deploy order (README "Deploying" step 3), where the class, `since` and endpoints go in the existing columns, and the page's run-less row.

### API consumer (REPORT-152)

#### RESOLVED: Streamed rows and the envelope's computed fields
`count` and `latest_timestamp` are known only after every row is read, and the status is sent before the first row. R11 puts them after `rows`, and R12 says streaming starts only after the query and the audit write succeed, and what a mid-stream failure looks like.

#### RESOLVED: Null and empty values
Athena's result is a CSV, and the existing CSV readers (`NimbleCSV`, cc-data) do not tell an empty string from a null. R5 now types the four numeric columns and makes an empty field `null`.

#### RESOLVED: A nightly run that named applications does not meet the route's rows
`student-actions` with an `app` filter adds `log.app IN (...)` (`report_query.ex`, `apply_app/2`), and `logs_by_hour` has no `app` partition (convention 7). R8 now tells a combining caller to filter the route's rows by the raw `application` value.

### Dashboard consumer (RD-12)

#### RESOLVED: A recent-only count drops at midnight UTC
Under R8, `window_start` moves forward a day at each 00:00 UTC, so a count of the window falls. Added to the open window question's context, since it decides how the page labels the number.

### QA Engineer

#### RESOLVED: R13 asked Athena to stop a query report-server cannot stop
Neither report-server policy allows `athena:StopQueryExecution` (REPORT-107's Technical Notes list the Athena actions each allows), so R13's stop would fail and R15's "no IAM change" would be false. R13 now stops waiting only, and says why that is bounded. (Found in stage 4.)

#### RESOLVED: R21's reconciliation day had no nightly copy yet
The window's first full day is yesterday, whose nightly copy exists only after today's 02:00 UTC partitioner run. R21 now reconciles against a `student-actions` run for yesterday taken after that copy exists.

### Round 3 (2026-10-21)

Roles as in implementation.md's Round 3. Each finding was checked against the code or by throwaway tests (deleted).

#### RESOLVED: Security Engineer: R6 let an absurd bound through to a 500
A 20-digit `end`, or a `start` past year 9999, passed "a non-negative integer" and made the `dt` bound raise (throwaway test). R6 now caps a value at 13 digits (year 2286), which the plan checks.

#### RESOLVED: Operator: R14 promised a cap on running queries that a timeout breaks
The slot is the request's, released when it ends (`PortalDownloadLimiter` monitors the caller), and R13 leaves a timed-out query running in Athena, so more than the cap can run for a while. R14 now caps requests, per server, and says so.

