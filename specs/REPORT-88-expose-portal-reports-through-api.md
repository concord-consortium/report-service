# Expose Portal reports through the report-service API

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-88

**Status**: **Closed**

## Overview

Make the Portal report family reachable through the `/api/v1` surface the same way Athena reports already are, so API clients (cc-data and others) can list Portal runs and download their results programmatically instead of only viewing them in the report-server web UI. Today the v1 API only knows about Athena-backed report runs; Portal reports (which run live SQL against the portal database and build a CSV in-process) are invisible to every downstream tool. This story is the server-side enabler for the rest of the Portal-report work (the new learners report, the cc-data CLI integration, and the skill/guidance updates). After it, a client can list Portal runs alongside Athena runs, download a Portal run's CSV, and pass a Portal run to the bulk answers/history/attachments endpoints.

Both API read paths funnel through two functions in `reports.ex`: `list_api_report_runs` (index) and `get_api_report_run` (show, download, answers, history, attachments, and the two Athena post-processing job endpoints). Both gated on `r.report_slug in ^Tree.athena_report_slugs()`, the single choke point that hid Portal runs. An Athena run carries `athena_query_id`/`athena_query_state`/`athena_result_url` (download returns a presigned-URL envelope); a Portal run has no stored result artifact at all: it is a `ReportQuery` (SQL) built by the report module's `get_query/2`, run live against the portal DB, with the CSV built in-process. The LiveView offloads that to an async task pushing over a websocket, which an HTTP API controller cannot reuse, so the download strategy had to be decided rather than inherited.

## Requirements

### Listing
- `GET /api/v1/reports` (index) returns Portal runs alongside Athena runs, covering all non-`tbd` `type: :portal` reports; `tbd: true` placeholders are excluded.
- `GET /api/v1/reports/:id` (show) returns a single Portal run the caller owns.
- Each run's JSON gains an `execution` field: `"async"` for Athena, `"sync"` for Portal, sourced from the report module `type`; clients branch on it to choose their download path.
- `report_type` (= `api_report_type`) is unchanged and documented nullable: Portal runs carry `report_type: null` (a valid, expected value).
- A Portal run's Athena-specific JSON fields reflect their real empty/`null` values and must not trigger any Athena computation on show.

### Job endpoints (Athena post-processing)
- The two job endpoints route through the same widened gate, so Portal runs are admitted. The deliberate Portal contract: `GET /reports/:id/jobs` returns `200` with `items: []`, and `GET /reports/:id/jobs/:job_id/download` returns `404`. No Portal-specific code is needed (`JobsFile.list_jobs(nil) -> {:ok, []}` and `find_job(nil, _) -> {:error, :not_found}` already yield it); regression tests lock it.

### Download
- `GET /api/v1/reports/:id/download` for a non-`tbd` Portal run runs the report's query against the portal DB on request and streams the resulting CSV directly to the client as a chunked response (compute-on-request), memory bounded by streaming `MyXQL.stream` batches through the CSV encoder rather than materializing the whole result.
- The Athena download path (presigned envelope) is unchanged; the endpoint branches on report `type`.
- Filename follows `#{report_slug}-run-#{id}.csv`; Portal response sets `Content-Type: text/csv` and `Content-Disposition: attachment; filename="…"`.
- The streamed CSV is byte-compatible with the web CSV under the report's default row order (headers, column ordering, delimiter, quoting), for any result including the empty (zero-row) case, because this story also corrects the web encoder's zero-row output to a header-only line so the two surfaces agree. The one excluded case is rows re-ordered by an interactive web column sort (session-only, never persisted on the run, so outside the API contract).
- Zero rows returns a header-only CSV with `200` (not an error, not a zero-byte body).
- A failure before any bytes are sent returns a clean JSON error, covering both a query-*building* failure (`get_query`/`update_query` returning `{:error, _}`, e.g. the `"Cannot run query with no filters"` short-circuit) and a query-*executing* failure (a DB error on the first fetch); neither may fall through as an unhandled `WithClauseError`. A failure mid-stream aborts the chunked response without clean termination so the client detects truncation. Errors are generic; the raw portal-DB error message is never in the response body.
- Bounded by an API-specific, configurable wall-clock timeout (`PORTAL_DOWNLOAD_TIMEOUT_MS`, default 120000) rather than the portal DB's 5-minute `@query_timeout`.
- Concurrent Portal downloads are capped per node (`PORTAL_DOWNLOAD_MAX_CONCURRENT`, default 2, below the pool's 5) so streaming downloads cannot starve authentication/authorization on the shared portal pool; over the cap returns a retryable `503 SERVICE_UNAVAILABLE` before checking out a connection.
- Audit parity with the Athena path: the download is recorded in `data_access_log` before any bytes are sent, fail-closed, with `source: "api"`, `data_type: "run_csv"`, and a new `event: "run_csv_streamed"`.

### Bulk endpoints
- `/answers`, `/history`, and `POST /attachments` accept a Portal run and return that run's learners' data, derived from the run's `report_filter`.
- A report declares whether its runs can produce a per-learner set via a new `derives_learner_data` flag on the `Report` struct (default `true`). Aggregate-only reports (`school-metrics`, `summary-metrics-by-subject-area`, whose `include_filters` never narrow to learners) are marked `false`.
- The three bulk endpoints return `422 UNPROCESSABLE` for a `derives_learner_data: false` run, replacing today's over-broad project-wide pull (researcher) or `500` (super-admin). This is a per-report capability check keyed on the report module, not a per-run filter-shape check and not a slug allowlist.
- The flag narrows only the three bulk learner endpoints; it has no effect on the gate, listing, show, or `/download` (an aggregate report stays fully listable, fetchable, and downloadable).

### Regression
- Existing Athena-specific API behavior is unchanged and regression-tested: `report_type` values, the presigned-envelope download contract, the 409 not-ready/state responses, and index pagination/ordering.
- The two job endpoints change observably for Portal runs (`/jobs` flips `404` -> `200 {items: []}`; job download stays `404`); Athena runs are entirely unchanged. Three existing tests that encoded the old Athena-only exclusion of Portal runs were updated to the new inclusion/resolution behavior.
- For bulk, the behavior change is confined to the aggregate reports (newly `422`); every learner-derivable run (Athena or Portal) still derives exactly as today.

## Technical Notes

- **Gate widening.** New `Tree.api_report_slugs()` collects non-`tbd` reports of `type in [:athena, :portal]`, honoring `tbd` across the full parent chain (leaf `Report.tbd` and group `ReportGroup.tbd`), because `collect_reports/1` recurses into groups unconditionally and group-level `tbd` is only a decorative web-UI badge. The two `reports.ex` gate clauses and their stale "Athena-type" docstrings flip together in the final activation commit.
- **`execution` source / `ensure_current` guard.** Resolve the module via `Tree.find_report(report_slug)`; map `:athena -> "async"`, `:portal -> "sync"`. Guard `AthenaRunOps.ensure_current` in `show` by branching on the resolved `type` (a `%ReportRun{}` has no `type` field, so a struct-level guard clause is impossible); `download`'s guard is subsumed by its Athena/Portal branch.
- **Portal download execution.** Build the query from the run's stored `report_filter` (never API params) via the identical `get_query` path the web UI uses. Stream via `MyXQL.stream` inside a transaction (`MyXQL.transaction`), emitting the header exactly once from the first result's `columns`, skipping zero-row envelope results, and encoding each non-empty batch's raw row lists as list-of-lists with `delimiter: "\n"` (byte-identical to `format_results/2`; the naive per-batch `CSV.encode(headers: …)` repeats the header mid-file and is wrong). The streaming entry point is swappable via `Application.get_env` for testing without a live portal DB.
- **Timeout / pool.** An overall wall-clock deadline is tracked in the chunk loop (since `MyXQL.stream`'s `:timeout` only bounds each per-batch fetch), plus a per-batch fetch timeout. The per-server pool (`pool_size: 5`) is shared with auth/authz/bulk/web; the concurrency cap keeps downloads below it. The held read view (inherent to `MyXQL.stream`, which must run in a transaction) is an accepted risk bounded by the timeout.
- **Audit.** A new fail-closed `AuditLog.log_run_csv_streamed/2` (modeled on `log_attachment_urls/3`) writes one pre-stream row; the controller gates the stream on `{:ok, _}`. The new `event` value is added to the `validate_inclusion` list (no migration).
- **Bulk.** Add `UNPROCESSABLE`/422 and `SERVICE_UNAVAILABLE`/503 to `ErrorHelpers`; add `derives_learner_data` to the `Report` defstruct; add a per-report capability check inside `EndpointSet.derive_endpoint_set` (the single shared path for all three endpoints) that short-circuits before `LearnerData.fetch`, its `{:error, :not_learner_derivable}` sentinel matched before the generic `{:error, _} -> server_error` in both controllers. A tree-consistency test ties the hand-set flag to its determinant (no learner-narrowing `include_filters` => flag must be `false`).
- **Security.** `/download` takes only the run `id`; SQL is rebuilt from the server-stored filter, adding no new injection surface. Learner-scoped reports re-apply owner project scoping (`apply_allowed_project_ids_filter`) and may return teacher identity (name/email); the two aggregate reports apply no scoping and carry no per-learner PII (`school-metrics` emits per-school institutional identity only). Guardrail: any future `type: :portal` report exposing per-learner/PII data must apply owner project scoping in its `get_query`.
- **Empty allowed-projects scoping (shared fix).** A project-admin/researcher with zero allowed projects made `apply_allowed_project_ids_filter` render `project_id IN ()` (a MySQL syntax error), pre-existing and identical in the web LiveView download. Refactored into `scope_by_allowed_projects/5`: `:all` -> no scoping, non-empty list -> scope as before, empty list / `:none` / lookup error -> constrain to zero rows (`1 = 0`). A no-projects owner now gets a clean header-only `200`, mirroring the bulk empty-permission short-circuit; also corrects the web UI.
- **Tests.** Stub the swappable streaming seam so no live portal DB is needed. `ConnTest`/`Plug.Test` can assert the streamed body and the pre-stream error/timeout paths but cannot observe wire-level chunked truncation (clean-EOF vs aborted framing); that property is verified at integration level or at the cc-data client.

## Out of Scope

- The cc-data CLI changes that consume the new Portal download stream and `execution` field (separate story). Cross-story dependency: because the download is a chunked stream, the client must stage the body to a temp file and promote it only on clean stream completion; a truncated/aborted stream must be discarded. This completeness check lives in the client and is what makes the "no partial file" behavior end-to-end.
- The new Student ID Mapping / Student Metadata Portal reports themselves (separate story); this story only guarantees they are covered automatically by the type-based mechanism once they land.
- Any change to Athena report behavior or the presigned-envelope download contract.
- `tbd: true` placeholder reports.
- JSON download of Portal reports (the API download contract is CSV only, matching the Athena path).

## Not Yet Implemented

- **Distinct timeout error code.** A pre-first-byte timeout is indistinguishable from a generic DB error to the client (both map to `SERVER_ERROR`/500). The Download requirement only mandates "a clean JSON error," so this is acceptable and left as-is; a distinct message/code for the `PortalDownloadTimeout` pre-stream case is noted as an optional future nicety (P3-5).
- **Wire-level chunked-truncation detection** (clean-EOF vs aborted framing on the client) is not observable via `Plug.Test`; it was verified with a throwaway live-Bandit + `curl` probe (curl exit 18 on truncation) and is formally exercised end-to-end at the cc-data client (separate story). At the unit level the mid-stream and timeout-abort tests assert only that the reducer raised after `send_chunked`.

## Decisions

### Q1 — What is the download streaming/timeout strategy, and what does a client see on a slow/failed query?
**Context**: The ticket explicitly said to decide this rather than assume the LiveView's async handling is reusable; the choice affects the observable error contract.
**Options considered**:
- A) Materialize the full CSV in memory, then send. Simplest, but peak memory = full CSV on a small task and does not bound a future large report.
- B) Stream chunked CSV directly to the client (`MyXQL.stream` -> `CSV.encode` -> `Plug.Conn.chunk`).
- C) Async task + poll, mirroring Athena. Contradicts the ticket's compute-on-request decision and reintroduces Portal-side run state.
- D) Stage to a server-side temp file, then serve. Rejected: unnecessary double I/O and cleanup.

**Decision**: **B** — compute-on-request, chunked CSV streamed directly, no S3 object or presigned envelope. Server memory is bounded to one batch. Completeness is conveyed by chunked transfer-encoding: a clean chunked-EOF is a complete file; an aborted stream is a truncation the client (cc-data) discards after staging to a temp file. A pre-stream error returns clean JSON; a mid-stream failure aborts without clean termination.

### Q2 — Should the API use a shorter download timeout than the portal DB's 5-minute `@query_timeout`?
**Context**: Streaming holds a portal-DB connection and an open read view for the whole download, exposure the web UI does not have (it materializes before pushing bytes). `MyXQL.stream`'s `:timeout` bounds only each per-batch fetch, not total wall-clock.
**Options considered**: keep the 5-minute query timeout; enforce an API-specific configurable timeout.
**Decision**: Enforce an API-specific configurable download timeout: an overall wall-clock deadline checked in the chunk loop plus a per-batch fetch timeout, via `PORTAL_DOWNLOAD_TIMEOUT_MS` (default 120000). Pre-deadline with no bytes sent -> clean JSON error; mid-stream -> aborted stream. Independent of pool sizing (out of scope).

### Q3 — How is a Portal download recorded in the audit log, and is the write fail-closed before streaming?
**Context**: The Athena path records every download via `issue_download_url` (presign-shaped); a Portal download issues no URL. `data_type: "run_csv"` and `source: "api"` fit, but no existing `event` matches, and `event` is a plain string column gated only by `validate_inclusion`.
**Decision**: Audit before streaming, fail-closed, single row, with a new distinct `event: "run_csv_streamed"` (added to `validate_inclusion`, no migration). The controller writes it before `send_chunked`; on write failure it returns `SERVER_ERROR` and does not stream. The row records that a download was authorized and initiated, not that bytes were delivered.

### Q4 — Should bulk answers/history/attachments accept every non-tbd Portal run, or only the Student ID Mapping report?
**Context**: Loosening the shared gate admits all non-`tbd` Portal runs to the bulk endpoints. Aggregate reports filter by geography, which `LearnerData.fetch` ignores, producing an over-broad researcher pull or a super-admin `500`.
**Options considered**: a uniform gate with no extra check; a per-run filter-shape 422; a per-report capability flag; a hardcoded slug allowlist.
**Decision**: Uniform gate **plus a per-report `derives_learner_data` capability check** (default `true`; `false` on the two aggregate reports). Chosen over a per-run filter-shape check because it is semantically honest ("this report has no bulk learner endpoints"), eliminates the `nil`-vs-`[]` blank ambiguity, and collapses the regression/test cost (existing learner-derivable fixtures stay green). A tree-consistency test guards against a future aggregate report missing the flag.

### PERF2 — Streaming downloads compete with auth/authz for the shared 5-connection portal pool
**Context**: A streaming download holds one of the 5 shared connections for the whole transfer, so a handful of concurrent downloads could stall logins and authorization on that portal server.
**Decision**: Add a configurable per-node concurrency cap (default 2, below `pool_size: 5`); over the cap returns a clean retryable `503` before checking out a connection. Distinct from (and not dependent on) resizing the pool. The cap is per node, so aggregate concurrency across the deployment is `cap × task_count`.

### R5-1 — Portal runs are admitted to the two `/reports/:id/jobs` endpoints
**Context**: The job endpoints share the widened gate but are Athena post-processing endpoints keyed entirely on `athena_query_id`, which Portal runs lack.
**Options considered**: adopt the empty-jobs-list contract (no new code); reject Portal runs outright with a per-endpoint `type` guard.
**Decision**: Adopt the empty-jobs-list contract — `/jobs` -> `200 {items: []}`, job download -> `404` — which `JobsFile.list_jobs(nil)`/`find_job(nil, _)` already yield. Regression tests lock it so a future `JobsFile` change cannot silently turn the empty list into a `500`. The reject-outright alternative was declined as higher-cost with no user benefit.

### R5-2 — The pre-stream error path must also cover a query-construction failure
**Context**: Every Portal `get_query` ends in `ReportQuery.update_query`, which returns `{:error, "Cannot run query with no filters"}` for an all-empty join/where (reachable by a super-admin blank-filter run) before any SQL runs.
**Decision**: "Before any bytes are sent" covers both a query-building failure and a query-executing failure; both map to the same clean JSON error, neither may raise a `WithClauseError`/500. The `"Cannot run query with no filters"` string is an app-level constant (surfaced as a clean `422`), exempt from the raw-DB-message leak concern.

### R6-1 — Empty-result CSV: header-only vs byte-compatible with the web CSV
**Context**: An empirical probe showed the web `format_results/2` emits an empty (zero-byte) body for zero rows, which contradicts the desired header-only empty contract and the byte-compatibility contract.
**Options considered**: (a) match the web = empty body; (b) header-only, scoping byte-compat to non-empty; (Round 7) fix the web encoder so both agree.
**Decision** (project owner, Round 7): the web empty-body was a pre-existing bug; this story corrects the web encoder to emit the same header-only line as the API. Byte-compatibility then holds for the empty case too (both header-only). A header-only file is unambiguously a valid empty result, whereas a zero-byte body is indistinguishable from a truncated transfer. A LiveView (Csv-encoder) test locks the corrected empty behavior.

### R6-2 — The byte-compatible streaming-CSV recipe
**Context**: The recipe was doc-derived and needed empirical confirmation against a live MySQL 8.0.
**Decision**: Pin the exact recipe, confirmed byte-identical to `format_results/2`: emit the header once as a single CSV-encoded row of the column-name strings, then encode each non-empty batch's raw `MyXQL` row lists as list-of-lists (not remapped to maps) with `delimiter: "\n"`, skipping every zero-row envelope. The naive per-batch `CSV.encode(headers: …)` was rejected (repeats the header mid-file).

### P3-1 — Gate widening is the last non-test step
**Context**: Opening the gate before the Portal-handling machinery exists would produce broken intermediate commits (a Portal `show` would trip `ensure_current`'s Athena self-start; a Portal `download` would return a misleading `409`; Portal bulk would over-pull/500).
**Decision**: Split the gate work into an early "add the `api_report_slugs` helper" step (unused) and a final activation step that flips the two `where` clauses and docstrings, so the gate opens only after every Portal-handling path is in place. Job-regression and acceptance tests follow it.

### Zero-allowed-projects scoping fix (added during implementation)
**Context**: Live staging testing of the now-exposed `/download` surfaced that a project-admin/researcher with zero allowed projects makes `apply_allowed_project_ids_filter` render `project_id IN ()` (MySQL error 1064) -> `500`. Pre-existing and identical in the web LiveView download.
**Decision**: Fix it in this story (a bug the new API surface makes reachable, in shared code the download path exercises). Refactor into `scope_by_allowed_projects/5` so the no-projects case constrains to zero rows (`1 = 0`) with valid SQL, yielding a clean header-only `200`; `:all` and non-empty-list branches emit byte-identical SQL. Also corrects the web UI. Net-new API surface for the downstream stories (create/duplicate/filter-options/catalog) was deliberately left to their own PRs as purely additive work.
