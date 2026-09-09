# Portal download: separate the transaction budget from the per-batch cap

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-128

**Status**: **Closed**

## Overview

`GET /api/v1/reports/:id/download` passed one number, 15,000 ms, as both the per-batch fetch timeout and the enclosing `MyXQL.transaction/3` timeout. The transaction timeout is a DBConnection checkout deadline that bounds the entire download, so no Portal report whose query took longer than 15 seconds could be downloaded through the API, and the configured 120-second `portal_download_timeout_ms` was unreachable. `school-metrics` and `summary-metrics-by-subject-area` set `derives_learner_data: false`, so downloading is the only thing a researcher can do with a run of either, and neither worked.

## Requirements

- `PortalDbs.stream_query/4`'s budget option is named for the thing it controls, the transaction's checkout deadline, and the inert `timeout:` handed to `MyXQL.stream/4` is deleted rather than kept alongside it. The option keeps a default, so the two existing test callers are untouched.
- The transaction budget for an API download is the full configured `portal_download_timeout_ms` (120,000 ms by default), so a Portal query slower than 15 seconds completes.
- `GET /api/v1/reports/:id/download` returns a 200 `text/csv` body for a `school-metrics` run and for a `summary-metrics-by-subject-area` run, byte-identical to what the web run page produces. *(No test covers this; it is satisfied by both paths sharing `Csv.header_row/1` and `Csv.encode_batch/1`, and was verified against production instead. See Not Yet Implemented.)*
- The download still ends at the `portal_download_timeout_ms` wall clock. A run that exceeds the budget fails pre-first-byte as a clean JSON 500 and mid-stream as an aborted chunked response, exactly as before.
- Two tests, splitting the regression between the two modules that have to agree. A `:portal_db` test proves `stream_query/4` honors the budget it is handed (`SELECT SLEEP(2)` returns under 6,000 ms and raises `DBConnection.ConnectionError` under 1,000 ms). A controller test proves `stream_portal_csv/5` hands down the full budget, which is the half that catches a reintroduced `min(budget, 15_000)`.
- The inverted comments at `report_controller.ex:8-9` and `:220-224`, and `stream_query/4`'s `@doc`, are corrected or deleted.
- `specs/REPORT-88-expose-portal-reports-through-api.md` is corrected where it records the same inverted model (the Timeout / pool bullet and decision Q2).
- A download that exceeds its budget says so in the log rather than surfacing as a bare `socket closed`. The client-visible response is unchanged.

## Technical Notes

**`MyXQL.stream/4`'s `:timeout` is inert.** In MyXQL 0.7.1 a cursor fetch ignores it: `MyXQL.Connection.fetch_first/5` binds its options as `_opts` (`deps/myxql/lib/myxql/connection.ex:214`), `fetch_next/5` reads only `:max_rows` (`:235`), and `Client.com_stmt_execute/5` (`client.ex:147`) and `com_stmt_fetch/4` (`:153`) call `recv_packets/5` with its default of `:infinity` (`client.ex:207`). DBConnection adds nothing: `Holder.handle/4` runs the fetch without touching the deadline, which is set once at checkout. **There is no per-batch bound in this system, only the checkout deadline.**

**`MyXQL.transaction/3`'s `:timeout` bounds the whole transaction**, including time spent in the caller's reducer. Measured against MySQL 8.0.39: a 1-second transaction budget killed a `SELECT SLEEP(3)` at 1,005 ms with the production error, "socket closed (the connection was closed by the pool...)", while a 1-second *fetch* cap let the same query through untouched. A 20-second budget cleared an 18-second query with the 15-second "batch cap" still in place.

**Two bounds now exist and neither covers the other's case.** The reducer's wall-clock `deadline` (`report_controller.ex:216`, raised at `:281`) bounds a slow consumer between batches with a named exception; the checkout deadline is the only thing that bounds a fetch that never returns, which the reducer cannot see because no batch arrives. The reducer's clock starts earlier, before `get_or_start_pool/1`, so no explicit margin is needed.

**The web UI was never affected.** `ReportRunLive.Show` reads through buffered `PortalDbs.query/4` (`show.ex:163`, `:204`) at the module default `@query_timeout` of 300,000 ms.

**Pool exposure.** The per-server pool is `pool_size: 5`, shared with auth, authz, the web run page and bulk reads; `PortalDownloadLimiter` admits `max_concurrent: 2`. A download can now hold a connection for two minutes rather than fifteen seconds. The buffered web path already holds one for up to five minutes. Starvation is legible: `query_with_reason/4` classifies `:queue_timeout` as `:busy` (`portal_dbs.ex:35-37`), distinct from timeout and outage.

**An aggregate download is silent for its whole duration.** The header is not chunked until the first batch arrives (`report_controller.ex:295`) and the first cursor fetch runs the entire `GROUP BY`. Measured against production, first byte against total: run 206 at 29.96 s of 30.17 s, run 201 (unfiltered) at 70.71 s of 71.55 s.

**The edge is not a constraint.** Both `report-service-prod` (612297603577) and `report-service-qa` (816253370536) sit behind a shared `fargate-public-cluster` ALB with `idle_timeout.timeout_seconds` of 600, declared in the sibling `cloud-formation` repo at `fargate/public-network-stack.yml:163-169`, with `fargate/report-server.yml:8` naming the network stack this service imports from. That is five times the download budget, so `portal_download_timeout_ms` always cuts first. The ALB is shared with the rest of the cluster, so the invariant worth keeping is 600 staying above the download budget.

## Out of Scope

- Pool sizing, `queue_target` and `queue_interval` for the portal pools.
- The concurrency cap and its 503 behavior.
- cc-data's retry policy; it behaves correctly.
- A distinct error code or message to the client for a download that exceeds its budget. REPORT-88 left this as a future nicety and nothing here changes that.
- Making the aggregate reports faster.
- The web run page's buffered path and its 300,000 ms default.

## Not Yet Implemented

- **The ticket's second acceptance criterion, that a stalled batch stays bounded, was amended rather than implemented.** The guard it asks for never existed: the ticket was written believing the per-batch cap was real and merely needed separating from the transaction budget, and MyXQL discards it. AC2 was amended in Jira on 2026-09-09 to "the download is bounded at `portal_download_timeout_ms` whatever the DB does". A real per-batch bound remains buildable; see the Q1 decision for the verified design and its cost.
- **No test covers the two named aggregate reports.** A stub-driven test would assert that a report which already downloads still downloads, over a seam where the timeout under test is a value the stub ignores, so it could not fail for the reason this story cares about. The property that matters, that both finish inside the budget, is only observable against production, where it was verified: run 206 at 30.2 s (643 rows), run 200 at 7.6 s, run 201 at 71.5 s (4,051 rows), all 200s, with run 206's CSV byte-identical (same length, same SHA-256) to the buffered path the web page uses.

## Decisions

### How should "a stalled batch is still bounded" be satisfied, given that MyXQL discards the per-fetch timeout?
**Context**: The ticket's AC2 asks that one stuck fetch cannot consume the whole 120-second budget, but nothing bounds a single fetch except the checkout deadline, which the fix raises to 120 seconds. The failure it guards against is a portal DB that accepts a fetch and goes silent; the download is bounded either way, so the entire benefit is recovering one of five pooled connections sooner.

**Options considered**:
- A) Accept the wall-clock budget as the only bound and amend the criterion.
- B) Reimpose a real per-batch bound with a producer task: the DB stream runs in a `Task` holding the checkout for the full budget, sending each batch to the controller and acking one at a time, so chunking stays on the socket-owning process and REPORT-88's framing, `sent` atomic and `ClientClosedError` are untouched. Verified working: 5,000 rows over ten batches in 46 ms, a `SELECT SLEEP(5)` first fetch aborted at 1,001 ms against a 1-second bound, a `SELECT SLEEP(3)` completing normally under a 5-second bound.
- C) Bound the fetch at the socket. Ruled out: `com_stmt_execute`/`com_stmt_fetch` call `recv_packets/5` without a timeout and there is no configuration path to one, so it needs a patched MyXQL.
- D) Let MySQL bound the statement with a `MAX_EXECUTION_TIME(n)` hint, keeping A's transaction fix underneath.

**Decision**: **A**, plus the error-legibility change. The endpoint has one bound, `portal_download_timeout_ms`, and nothing tighter. B stays available if the trade is revisited; its probe numbers above are what a future reader needs to cost it, and it is the only complete answer to AC2 as originally worded, but it spends a process and an ack protocol on the one path in this codebase that is delicate about response framing, to shorten a held connection in a failure nobody has observed.

D was recommended first and then rejected on three grounds, recorded so it is not re-derived. Its case was decoupling the stall bound from the budget, and that collapses: the inner bound must exceed the slowest legitimate report, so setting it low recreates this bug behind a second knob and setting it to the budget decouples nothing. It has nowhere clean to live, because `ReportQuery.get_sql/2` has eleven callers and four build Athena SQL, so the hint cannot go in the builder and must be spliced onto the finished statement, where `get_sql/1`'s `raw_sql` clause and `get_count_sql/1`'s wrapping both break it. Measured: the same hinted query interrupted at 1,051 ms at top level but ran to completion in 4,766 ms inside `SELECT COUNT(*) FROM (...) AS subquery`, so its failure mode is silent absence. And it does not satisfy AC2 anyway, bounding only server-side execution and not a stalled fetch.

---

### Should a report with `derives_learner_data: false` take the buffered path instead of streaming?
**Context**: The ticket's second scope bullet asks this. An aggregate gets nothing from streaming, since MySQL materializes the `GROUP BY` before the first row.

**Options considered**:
- A) Keep one streaming path for every Portal report.
- B) Branch on `derives_learner_data: false` and buffer those through `PortalDbs.query/4`.

**Decision**: **A.** Buffering is worse in every dimension checked. Both paths already share the encoder, so it buys nothing in fidelity. It holds the whole result in memory, worst exactly where these reports are riskiest. Neither path sends a byte before the aggregate finishes, so the client-visible idle period is identical and buffering adds encode time on top. And a branch would add a second download path to keep in step with `tree.ex`.

---

### Once the transaction gets the full budget, should the reducer's wall-clock deadline check stay?
**Context**: Both are then `portal_download_timeout_ms`, so they look redundant.

**Decision**: **Keep both, same value, no margin added.** They cover different cases: the reducer bounds a slow consumer between batches with a named exception, the checkout deadline bounds a fetch that never returns. A margin cannot buy determinism, because the reducer only tests the clock when a batch arrives, and cannot buy a client-visible difference, because the controller classifies by whether bytes have been sent rather than by exception type (`report_controller.ex:244-256`).

---

### Is 120 seconds still the right default budget?
**Context**: 120,000 ms was chosen in REPORT-88 as a bound below the portal DB's 300,000 ms `@query_timeout`, and had never been in force because the 15-second cap masked it.

**Decision**: **Keep 120,000 ms.** Measured against production: run 206 at 30.2 s and an unfiltered `school-metrics` run at 71.5 s for 4,051 rows, so the headroom is about 1.7 times rather than the wide margin first assumed on run 206 alone. It covers the heaviest run anyone has produced, but a slower portal or larger corpus would reach it.

Raising it is a real change rather than a toggle. `PORTAL_DOWNLOAD_TIMEOUT_MS` is not in the task definition (`cloud-formation/fargate/report-server.yml`), nor is `PORTAL_DOWNLOAD_MAX_CONCURRENT`, so both environments run the `runtime.exs` defaults of 120,000 ms and 2. Changing either means a `cloud-formation` pull request adding the variable plus a stack update, which produces a new task definition and a rolling restart. No new image build, but not a console change either.

The ALB's 600-second idle timeout is not an argument for raising it. That was only ever a ceiling that might have cut downloads short, and it does not. The binding constraint is the portal pool: `pool_size: 5` shared with auth, authz, the web run page and bulk reads, against `max_concurrent: 2` downloads, so a longer budget is paid for by every other portal query on the box. If more headroom is ever wanted, the honest lever is pool sizing rather than the timeout, and that is out of scope here.

---

### Review findings that changed the spec
Each was verified against the code before being written down, and each had a single defensible correction:

- **The inverted model was also in `stream_query/4`'s own docstring**, not just the controller comments and REPORT-88's spec. Added to the prose-correction requirement.
- **The two deadlines do not start at the same instant.** The reducer's is set before the pool is acquired, so it always starts earlier, by up to `@connect_timeout`. This strengthens the Q3 decision rather than contradicting it.
- **The regression test was specified in terms that would not exist** ("slower than the per-batch cap"), and no report query is dependably slow against a fixture. Restated as `SELECT SLEEP(n)` through `stream_query/4`, with the mutation it catches named.
- **Nothing pinned the controller's half of the wiring**, so a regression confined to the controller would leave the suite green even with the DB-level test. Added the stub-level test.
- **The "byte-identical to the web page" requirement invited a test that cannot fail**, since both paths call the same encoder. The requirement now says so and says not to write it.
- **Pool starvation had no stated symptom.** Added that a queue timeout classifies as `:busy`.
- **The budget is only reachable if the edge allows it.** Raised as a deploy-time check, then settled by reading the CloudFormation templates: the ALB idle timeout is 600 seconds in both environments.
