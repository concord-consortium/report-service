# Portal download: separate the transaction budget from the per-batch cap

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-128

**Repo**: https://github.com/concord-consortium/report-service

**Implementation Spec**: [implementation.md](implementation.md)

**Status**: **In Development**

## Overview

`GET /api/v1/reports/:id/download` passes one number, 15,000 ms, as both the per-batch fetch timeout and the enclosing `MyXQL.transaction/3` timeout. The transaction timeout is a DBConnection checkout deadline that bounds the entire download, so no Portal report whose query takes longer than 15 seconds can be downloaded through the API, and the configured 120-second `portal_download_timeout_ms` is unreachable.

## Project Owner Overview

Two Portal reports, Detailed Metrics by School and Summary Metrics by Subject Area, aggregate across the whole portal and take about 30 seconds to compute. They download fine from the web report page. Through the API they always fail with a 500, which means cc-data cannot fetch them at all. Because both reports set `derives_learner_data: false`, downloading is the only thing a researcher can do with a run of either, so the failure removes them from the API surface entirely rather than degrading them.

The cause is one line: a single timeout value is doing two different jobs, and the shorter of the two jobs wins. The fix gives the download the budget it was already configured to have.

## Background

REPORT-88 built the streaming download and set an API-specific wall-clock budget, `PORTAL_DOWNLOAD_TIMEOUT_MS`, default 120,000 ms, deliberately shorter than the portal DB's 5-minute `@query_timeout`. During its PR review a per-batch cap was added on top, `min(portal_download_timeout_ms(), 15_000)`, so that "a stuck fetch overshoots the overall wall-clock deadline by at most one batch rather than the full budget" (`9883860`).

That change rested on a belief about MyXQL that is not true: that `MyXQL.stream/4`'s `:timeout` bounds each batch fetch, and that `MyXQL.transaction/3`'s `:timeout` bounds only the checkout plus `BEGIN`/`COMMIT`. Both halves are backwards. The value has no effect on a fetch at all, and it caps the entire transaction. The net result is that the cap did not add the guard it was written for, and did silently reduce the download budget from 120 seconds to 15.

REPORT-94 taught cc-data to download Portal reports, which put a terminal on this endpoint for the first time and exposed the failure against production data.

## Requirements

- `PortalDbs.stream_query/4`'s budget option is named for the thing it actually controls, the transaction's checkout deadline, and the inert `timeout:` handed to `MyXQL.stream/4` is deleted rather than kept alongside it. Leaving an option in place that the driver discards is what produced the belief this story exists to correct. The option keeps a default, so the two existing test callers, which pass no budget, are untouched.
- The transaction budget for an API download is the full configured `portal_download_timeout_ms` (120,000 ms by default), so a Portal query slower than 15 seconds completes.
- `GET /api/v1/reports/:id/download` returns a 200 `text/csv` body for a `school-metrics` run and for a `summary-metrics-by-subject-area` run, and that body is byte-identical to what the web run page produces for the same run. This is satisfied by both paths sharing `Csv.header_row/1` and `Csv.encode_batch/1`, which is a property of the code rather than something a test can assert without being true by construction. Do not write a test that encodes the same rows twice and compares them.
- The download still ends at the `portal_download_timeout_ms` wall clock. A run that exceeds the budget fails, pre-first-byte as a clean JSON 500 and mid-stream as an aborted chunked response, exactly as today.
- Two tests, splitting the regression between the two modules that have to agree.
  - A `:portal_db` test proves `PortalDbs.stream_query/4` honors the transaction budget it is handed: `SELECT SLEEP(2)` returns under a 6,000 ms budget and raises `DBConnection.ConnectionError` under a 1,000 ms one. `SELECT SLEEP(n)` is the only reliable way to be slow on demand, since no report query is dependably slow against a fixture, and the pair costs 3.0 seconds, measured. Deleting either half of the split in `stream_query/4` fails one of the two assertions.
  - A controller test proves `stream_portal_csv/5` hands down the full budget, asserting on the `opts` the `portal_db` stub already receives. This is the half that catches a reintroduced `min(budget, 15_000)`; the DB test cannot see it, because it calls `stream_query/4` directly. Nothing pins this wiring today.
- The comments at `server/lib/report_server_web/api/v1/report_controller.ex:8-9` and `:220-224`, and `stream_query/4`'s `@doc` at `server/lib/report_server/portal_dbs.ex:72-73`, are corrected or deleted. All three state the inverted model of what each timeout bounds.
- `specs/REPORT-88-expose-portal-reports-through-api.md` is corrected where it records the same inverted model (the Timeout / pool bullet and decision Q2), because it is the document a later reader would consult before touching this code.
- Whatever the answer to Q1 below, the spec states in one place what actually bounds a single stalled fetch, so the next reader does not have to rediscover it.
- A download that exceeds its budget says so. The checkout-deadline `DBConnection.ConnectionError` currently reaches the log as `socket closed`, which is what made this bug hard to read; the rescue in `stream_portal_csv/5` should name the budget it blew instead. The client-visible response is unchanged.

## Technical Notes

### Verified findings

Every claim below was checked against the code at `02095d3` or run against the local MySQL 8.0.39 on port 3406.

**The one number, and its two jobs.** `stream_portal_csv/5` computes `batch_timeout = min(portal_download_timeout_ms(), @portal_download_batch_timeout_ms)`, which is `min(120_000, 15_000)` (`report_controller.ex:225`, module attribute at `:10`). It passes that value as `timeout:` to `PortalDbs.stream_query/4`, which spends it twice: as `MyXQL.stream/4`'s `timeout:` and as `MyXQL.transaction/3`'s `timeout:` (`portal_dbs.ex:82-86`).

**`MyXQL.stream/4`'s `:timeout` is inert.** In MyXQL 0.7.1 a cursor fetch ignores it. `MyXQL.Connection.fetch_first/5` binds the options as `_opts` (`deps/myxql/lib/myxql/connection.ex:214`), `fetch_next/5` reads only `:max_rows` from them (`:235`), and both reach the socket through `Client.com_stmt_execute/5` (`client.ex:147`) and `Client.com_stmt_fetch/4` (`:153`), neither of which passes a timeout to `recv_packets/5`, whose default is `:infinity` (`client.ex:207`). `DBConnection` does not supply one either: `Holder.handle/4` runs the fetch without touching the deadline, which is set once at checkout (`deps/db_connection/lib/db_connection/holder.ex:122-131`, `:293`). So there is no per-batch bound in the system today, only the checkout deadline.

**`MyXQL.transaction/3`'s `:timeout` bounds the whole transaction.** It becomes the DBConnection checkout deadline, and DBConnection kills the connection when the caller has held it longer than that, wherever the caller happens to be, including inside the reducer.

**Probe results** (throwaway script against the local MySQL, deleted; `tx` is `MyXQL.transaction/3`'s `:timeout`, `fetch` is `MyXQL.stream/4`'s):

| Probe | tx | fetch | Work | Elapsed | Result |
|---|---|---|---|---|---|
| A | 30s | 1s | `SELECT SLEEP(3)` | 3,139 ms | `{:ok, 1}`, so the fetch cap never fired |
| B | 1s | 30s | `SELECT SLEEP(3)` | 1,005 ms | `DBConnection.ConnectionError`, "socket closed (the connection was closed by the pool, possibly due to a timeout or because the pool has been terminated)" |
| C | 2s | 30s | 5,000 rows, reducer sleeps 200 ms per batch | 2,013 ms | killed while blocked in the reducer, "client timed out because it queued and checked out the connection for longer than 2000ms" |
| C2 | 30s | 1s | the same 5,000 rows and reducer | 2,455 ms | `{:ok, 5000}`, ten fetches under a 1s cap that does not exist |
| F | 20s | 15s | `SELECT SLEEP(18)` | 18,043 ms | `{:ok, 1}`, so raising only the transaction budget is sufficient |

B reproduces the production symptom exactly: the ticket records run 206 failing at 15,004 ms with `socket closed`, and B is the same error at its own 1-second deadline. F is the fix in miniature: the query cleared an 18-second run with the 15-second "batch cap" still in place, because that cap does nothing.

**The reducer's wall-clock deadline is the design's real total bound, and it has never fired.** `stream_portal_csv/5` computes `deadline` from the full `portal_download_timeout_ms()` (`report_controller.ex:216`) and `stream_reducer/2` raises `PortalDownloadTimeout` when a batch arrives past it (`:281`). Because the checkout deadline is eight times tighter, DBConnection always wins first. Once the transaction gets the full budget, the two bounds become the same number and the reducer's check fires marginally earlier, since it runs before the batch is encoded.

**The web UI is unaffected**, which is why this went unseen. `ReportRunLive.Show` reads through the buffered `PortalDbs.query/4` (`show.ex:163` for the count, `:204` for the rows), which takes the module default `@query_timeout` of 300,000 ms (`portal_dbs.ex:9`).

**The two affected reports.** `school-metrics` and `summary-metrics-by-subject-area` are the only reports with `derives_learner_data: false` (`tree.ex:227`, `:236`). `EndpointSet.ensure_bulk_derivable/1` refuses them for bulk answer, history and attachment reads (`endpoint_set.ex:41`), so downloading is the whole of their API surface. Both are pure aggregates: MySQL materializes a `GROUP BY` before returning the first row, so their first fetch legitimately needs the entire query time and streaming buys them nothing.

**Blast radius.** `stream_query/4` has exactly one production caller, `stream_portal_csv/5`. Its other callers are two `:portal_db`-tagged DB tests (`student_id_mapping_report_db_test.exs:125`, `student_metadata_report_db_test.exs:187`), both of which pass no `:timeout` and so take the `@query_timeout` default.

**Pool exposure.** The per-server pool is `pool_size: 5` (`portal_dbs.ex:99`) and is shared with auth, authz, the web run page and bulk reads. `PortalDownloadLimiter` admits `max_concurrent: 2` downloads (`config.exs:55-57`). Raising the transaction budget to 120 seconds means a download can hold one of those five connections for two minutes instead of fifteen seconds. The buffered web path already holds one for up to five minutes, so this is not a new class of exposure, but it is a real increase for the streaming path. If it ever does starve the pool the symptom is legible rather than mysterious: `query_with_reason/4` matches `%DBConnection.ConnectionError{reason: :queue_timeout}` separately and classifies it as `:busy` (`portal_dbs.ex:35-37`), which is distinct from the timeout and outage kinds.

**The download's first-byte idle period equals the query time.** The header is not chunked until the first batch arrives (`report_controller.ex:295`), and an aggregate's first fetch runs the whole query, so a `school-metrics` download sends nothing for about thirty seconds and then everything. Anything between the client and the server that bounds idle time on a response therefore sees the full query duration as silence. Nothing in this repository configures that layer; the server's stacks are `report-service-qa` and `report-service-prod` in CloudFormation, so what the edge allows is a deploy-time fact rather than a repository one. Run 206 at 32,466 ms fits inside a 60-second default comfortably, and the 120-second ceiling is only genuinely reachable if the edge allows it. Worth confirming against the deployed stack before treating 120 seconds as the operative budget in production.

**Retry amplification.** cc-data retries a 5xx on an idempotent GET inside its backoff budget, so one user command becomes about six server attempts, each recomputing a roughly 30-second query against a limiter admitting two concurrent downloads. Fixing the timeout removes the retries by removing the failure; it is noted here because it bears on Q1's cost side, not because anything in cc-data needs to change.

### The test seam

`report_controller_test.exs` stubs the `portal_db` seam (`PortalDbsStub`, `test/support/portal_dbs_stub.ex`), which drives the reducer with canned `%MyXQL.Result{}` envelopes and never reaches MySQL. That seam can assert which timeouts the controller passes down, but it cannot show that the transaction survives a slow query, because there is no transaction. A test that actually catches the regression has to go through `PortalDbs.stream_query/4` against the fixture database, alongside the existing `:portal_db`-tagged tests, which are excluded when the fixture is unreachable and raise in CI.

## Out of Scope

- Pool sizing, `queue_target` and `queue_interval` for the portal pools.
- The concurrency cap and its 503 behavior.
- Any change to cc-data's retry policy; it is behaving correctly.
- A distinct error code or message for a download that exceeds its budget. REPORT-88 considered this and left it as a future nicety; nothing here changes that.
- Making the aggregate reports faster.
- The web run page's buffered path and its 300,000 ms default.


## Open Questions

### RESOLVED: How should "a stalled batch is still bounded" be satisfied, given that MyXQL discards the per-fetch timeout?

**Context**: The ticket's second acceptance criterion is that one stuck fetch cannot consume the whole 120-second budget. Nothing bounds a single fetch today except the checkout deadline, and the fix raises that deadline to 120 seconds, so splitting the number in two does not by itself satisfy the criterion.

What the guard is worth is the crux. The failure it protects against is a portal DB that accepts a fetch and goes silent. The download itself is bounded at `portal_download_timeout_ms` either way, so the entire benefit is recovering one of five pooled connections sooner in that case, with at most two downloads in flight.

**Options considered**:

- A) **Accept the wall-clock budget as the only bound, and amend the criterion.** Delete `@portal_download_batch_timeout_ms`, pass the full budget as the transaction timeout, and restate the criterion as "the download is bounded at `portal_download_timeout_ms` whatever the DB does". Roughly a five-line change, and it makes the code honest about what is actually enforced. It leaves the endpoint with no bound tighter than the budget.
- B) **Reimpose a real per-batch bound with a producer task.** Verified feasible, and cheaper than it first looks: the DB stream runs in a `Task` that holds the checkout for the full budget and sends each batch to the controller process, acknowledging one batch at a time; the controller bounds each batch with a `receive/after` and keeps chunking on the process that owns the socket, so REPORT-88's `send_chunked` framing, the `sent` atomic and `ClientClosedError` are untouched. A throwaway probe ran all three cases against the local MySQL: 5,000 rows over ten batches completed in 46 ms, a `SELECT SLEEP(5)` first fetch aborted at 1,001 ms against a 1-second batch bound with the transaction budget at 30 seconds, and a `SELECT SLEEP(3)` under a 5-second bound completed normally at 3,045 ms. Aborting kills the task, which correctly makes DBConnection discard the connection rather than return a still-busy one to the pool. Cost: a process, an ack round trip per batch, and new failure interactions on the one path in this codebase that is delicate about response framing.
- C) **Bound the fetch at the socket.** Ruled out. `Client.com_stmt_execute/5` and `com_stmt_fetch/4` call `recv_packets/5` without a timeout and there is no configuration path to one, so this needs a patched MyXQL.
- D) **Let MySQL bound the statement, and keep A's transaction fix underneath it.** `SELECT /*+ MAX_EXECUTION_TIME(n) */ ...` on the download's SQL, with the checkout deadline still holding the full budget as the outer wall clock. Verified against the local MySQL: the hint interrupted a genuinely slow aggregate (a 2,000 by 2,000 join with a per-row `MD5`) at 1,044 ms against a 4,458 ms unbounded control, and interrupted `SELECT SLEEP(3)` at 1,041 ms. It surfaces as `MyXQL.Error` 3024, "Query execution was interrupted, maximum statement execution time exceeded", rather than `socket closed`, and the connection survives: the pool answered `SELECT 1` immediately afterwards. The hint form leaves no residue, which the `SET SESSION max_execution_time` form would on a pooled connection: after the hinted statement ran, the same connection completed the identical unhinted statement in 5,112 ms and `@@SESSION.max_execution_time` was still 0.

**Decision**: A, plus the error-legibility change below (chosen 2026-09-09). D was recommended first and then rejected on closer examination; the reasons are recorded here so it is not re-derived.

**What this commits to.** The endpoint has one bound, `portal_download_timeout_ms`, and nothing tighter. The guard AC2 asks for has never existed: the ticket was written believing the per-batch cap was real and merely needed separating from the transaction budget, and it was not real. So AC2 is amended to "the download is bounded at `portal_download_timeout_ms` whatever the DB does" rather than implemented. B stays available if that trade is ever revisited, and its probe results above are what a future reader needs to cost it.

**Why D was rejected.** Its case was decoupling the stall bound from the budget, and that case mostly collapses. The inner bound has to exceed the slowest legitimate report, so setting it low recreates this bug behind a second knob, and setting it to the budget makes it the same number as the checkout deadline and decouples nothing. A meaningfully smaller inner bound is only principled when query time and total time differ, and for two pure aggregates whose entire cost is the query, they do not.

It also has nowhere clean to live. `ReportQuery.get_sql/2` has eleven callers and four of them build Athena SQL (`learner_data.ex:26`, `:75`, `:208`, `:240`, `teacher_actions_report.ex:77`, `athena_run_ops.ex:19`), where a MySQL optimizer hint is wrong, so the hint cannot go in the builder and has to be spliced onto the finished statement. That splice is brittle in two verified ways: `get_sql/1`'s `raw_sql` clause (`report_query.ex:10-12`) returns a statement the builder never shaped, and the hint is silently dropped when the statement is wrapped, as `get_count_sql/1` wraps it. Measured: the same hinted query interrupted at 1,051 ms at top level and ran to completion in 4,766 ms inside `SELECT COUNT(*) FROM (...) AS subquery`. A guard whose failure mode is silent absence is worse than no guard, and no test would catch it.

Finally it does not satisfy the criterion it was reached for. `MAX_EXECUTION_TIME` bounds server-side execution, so a stalled fetch, where the server has finished and the bytes stop arriving, is untouched. B remains the only complete answer to AC2 and is still not worth a process on the chunked path. Against all of that, D would touch SQL generation shared with the web page, count queries, bulk export and Athena, to fix one `min()` in one function.

**What D was right about, kept cheaply.** Under A a blown budget reaches the log as `socket closed`, which is exactly what made this bug hard to read. The controller's existing rescue should recognize the checkout-deadline `DBConnection.ConnectionError` and log that the download exceeded its budget, naming the number. That is a few lines in `stream_portal_csv/5`, adds no knob and touches no SQL, and it is the part of D that carried real value.


### RESOLVED: Should a report with `derives_learner_data: false` take the buffered path instead of streaming?

**Context**: The ticket's second scope bullet asks this directly. An aggregate gets nothing from streaming: MySQL materializes the `GROUP BY` before the first row, so the cursor's first fetch does all the work.

**Decision**: Keep one streaming path for every Portal report and fix only the timeouts.

Buffering would be a change for the worse in every dimension that was checked. Both paths already encode through the same functions, `Csv.header_row/1` and `Csv.encode_batch/1` (`show.ex:215`, `report_controller.ex:295` and `:307`), so buffering buys nothing in output fidelity; the requirement that the CSV match the web page is satisfied by the shared encoder, not by sharing a path. Buffering holds the whole result in memory, which is worse precisely where these reports are riskiest, an unfiltered `school-metrics` run rather than run 206's 643 rows. Neither path sends a byte before the aggregate finishes, so the client-visible idle period is identical, and buffering then adds encode time on top of it. Against all of that, a branch on `derives_learner_data` would add a second download path to the endpoint and a per-report behavior that has to be kept in step with `tree.ex`.

### RESOLVED: Once the transaction gets the full budget, should the reducer's wall-clock deadline check stay?

**Context**: `deadline` in `stream_portal_csv/5` (`report_controller.ex:216`) and the `PortalDownloadTimeout` raise in `stream_reducer/2` (`:281`) were written as the overall bound, with the checkout deadline believed to be unrelated. After the fix both are `portal_download_timeout_ms`.

**Decision**: Keep both, at the same value, with no margin added between them.

They are not two expressions of one guard. The reducer's check bounds a slow consumer between batches and raises a named exception that says what happened; the checkout deadline is the only thing that bounds a fetch that never returns, which is the case the reducer cannot see because no batch arrives. Neither covers the other's case.

The same number is not the same instant, and the difference runs the right way. `deadline` is computed at `report_controller.ex:216`, before `stream_query/4` is called and therefore before `get_or_start_pool/1` has fetched or started the pool, which can itself spend up to `@connect_timeout`, 15,000 ms (`portal_dbs.ex:6`). The checkout deadline does not start until `MyXQL.transaction/3` is entered. So the reducer's clock is always the earlier of the two by however long acquiring a connection took, and an explicit margin would only be adding to a gap that already exists.

An explicit margin was considered anyway and rejected: it cannot buy determinism. The reducer only tests the clock when a batch arrives, so a batch that passes the check at 119.9 seconds is still followed by chunking and another fetch that the pool can kill, whatever the margin. It also cannot buy a client-visible difference, because the controller classifies by whether bytes have been sent rather than by exception type (`report_controller.ex:244-256`): `PortalDownloadTimeout` and `DBConnection.ConnectionError` both yield a clean JSON 500 pre-first-byte and both abort the framing mid-stream. The only thing that varies is which exception the log names, which is not worth holding a connection past the budget for.

### RESOLVED: Is 120 seconds still the right default budget?

**Context**: 120,000 ms was chosen in REPORT-88 as a bound deliberately below the portal DB's 300,000 ms `@query_timeout`, and it has never been in force, because the 15-second cap has masked it since the endpoint shipped. Turning it on is a real change in exposure: a download can hold one of five pooled connections for two minutes.

**Decision**: Keep 120,000 ms.

It is `PORTAL_DOWNLOAD_TIMEOUT_MS` (`runtime.exs:61-63`), so an operator can move it without a deploy if a slow run turns up, and this story's job is to make the configured value reachable rather than to re-choose it. Run 206 measures 32,466 ms streamed, which leaves a wide margin; the unfiltered case is unmeasured, and measuring it needs the production tunnel, which is a poor reason to hold up a fix that is strictly better than the current 15 seconds at any setting. The exposure is bounded by `max_concurrent: 2` against `pool_size: 5`, and the buffered web path already holds a connection for up to five minutes.

## Self-Review

Roles: senior engineer, QA, performance and operations, product. Each finding below was checked against the code before it was written down; candidates that did not survive the check are not recorded. All of them had a single defensible correction, so all were applied to the spec above rather than left as questions.

### Senior Engineer

#### RESOLVED: the inverted model is also in `stream_query/4`'s own docstring
`portal_dbs.ex:72-73` documents `:timeout` as "(per-batch fetch timeout)", which is the belief this story disproves, and the prose-correction requirement named only the controller comments and REPORT-88's spec. Added to that requirement.

#### RESOLVED: the two deadlines do not start at the same instant
Q3 said the reducer's check and the checkout deadline become "the same value, no margin". True of the value, not of the clock: the reducer's deadline is set before the pool is acquired, so it always starts earlier, by up to `@connect_timeout`. Recorded in the Q3 resolution, which it strengthens rather than contradicts.

### QA Engineer

#### RESOLVED: the regression test was specified in terms that will not exist
It was written as "a portal query slower than the per-batch cap", which under Q1 option A has no referent, and no report query is dependably slow against a fixture. Restated as a `:portal_db` test driving `SELECT SLEEP(n)` through `stream_query/4`, with the mutation it catches named.

#### RESOLVED: nothing pins the controller's half of the wiring
No existing test asserts which timeouts `stream_portal_csv/5` passes to the seam, so a regression confined to the controller would leave the suite green even with the DB-level test in place. Added a stub-level requirement.

#### RESOLVED: the "byte-identical to the web page" requirement invites a test that cannot fail
Both paths call `Csv.header_row/1` and `Csv.encode_batch/1`, so a test comparing them would encode the same rows twice and assert they match. Said so in the requirement, and said not to write it.

### Performance and Operations

#### RESOLVED: pool starvation had no stated symptom
The exposure was described but not what an operator would see. Added that a queue timeout classifies as `:busy` through `query_with_reason/4`, distinct from the timeout and outage kinds.

#### RESOLVED: the budget is only reachable if the edge allows it
An aggregate download is silent for the whole query time, so a response idle timeout in front of the server bounds it independently of anything here. Nothing in this repository configures that layer. Recorded as a deploy-time check rather than a code change; run 206 fits inside a 60-second default, so it does not block the fix.

### Product

No findings. The four acceptance criteria and three scope bullets in the ticket each map to a requirement or to Q1, and the spec adds nothing the ticket did not ask for.

## Assumption verification

Run before writing the implementation spec, against the fixture database on `localhost:3406`. The code was deleted afterwards.

- **The proposed regression test is writable and does fail on the mutation.** Both assertions were built as a real `:portal_db`-tagged test against `PortalDbs.stream_query/4` and run: `SELECT SLEEP(2)` returned `{:ok, 1}` under a 6,000 ms budget and raised `DBConnection.ConnectionError` under a 1,000 ms one, in 3.0 seconds for the pair. The first shape tried used `SELECT SLEEP(5)` with 10,000 and 3,000 ms budgets and cost 8.0 seconds for no extra coverage, so the smaller numbers are the ones in the requirement.
- **The failing half logs a MyXQL disconnect** at `[error]` level, since aborting a checkout kills the connection. That is expected output rather than a failure, and other tests in this suite already produce it.
- **The controller-level assertion needs no new seam.** `PortalDbsStub.stream_query/4` passes `opts` straight through (`test/support/portal_dbs_stub.ex:11-12`) and the existing `drive/1` helper already binds it, so asserting on the budget is a change to an existing helper rather than new infrastructure.
- **Not verifiable here, and not re-verified**: that `school-metrics` and `summary-metrics-by-subject-area` complete once the budget is raised. That needs the production portal, and it is already measured in the ticket, where run 206 returned all 643 rows in 32,466 ms with only the timeout changed. The fixture database has no data that would exercise either report.
