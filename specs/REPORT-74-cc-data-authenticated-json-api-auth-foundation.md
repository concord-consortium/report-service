# cc-data: Authenticated JSON API + Auth Foundation

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-74

**Status**: **Closed**

## Overview

Add a per-user bearer-token auth system and an authenticated JSON API (`/api/v1/reports...`) to the
Elixir report server, so the future `cc-data` researcher CLI can list report runs and download their
CSVs without going through the LiveView UI. Includes audit logging of data access from day one.

Researchers currently download report data by logging into the report server web UI, running a
report, and downloading a CSV by hand. The cc-data project (REPORT-70/71) replaces that workflow
with a desktop CLI that can pull data down locally and let researchers (or an AI assistant on their
behalf) query it directly. This story delivers the server-side foundation that CLI will talk to:
a way for a researcher to get a long-lived, revocable personal access token, and an authenticated
JSON API that lists the report runs they authored and mints fresh download links for completed
reports.

This story is independently shippable and proves the API path end-to-end — the manual "paste a
token" flow is enough to exercise the whole API before the CLI itself (STORY 4 / REPORT-77-era
work) exists. It also establishes the `data_access_log` audit table so that "who exported which
student data, and when?" is answerable from the very first export — access logs cannot be
backfilled later.

Related stories: STORY 2 (token-management UI — required before researcher rollout), STORY 3
(answers/history bulk endpoints — reuses the auth pipeline and audit table), STORY 4 (the Go CLI).

## Requirements

### Per-user token model

- The server can **issue, verify, and revoke** per-user API tokens.
- Tokens are **non-expiring and revocable** (no expiry, no refresh rotation) — control is via
  visibility + revocation (STORY 2 UI) + the audit log, per the design doc's decided trade-off.
- Tokens are tied to a local `users` row (and therefore to one portal).
- A user may hold **multiple active tokens** concurrently (e.g. two machines); each
  login/generate mints a new token with an optional label. Tokens live until revoked.
- Token verification resolves to the same `%Accounts.User{}` struct the LiveViews use, so existing
  scoping/authz code ports over.
- Each token records `last_used_at`, updated on API requests (STORY 2's UI depends on this).
- Revocation in this story can be **manual (DB/console)** — the self-serve UI is STORY 2. A revoked
  token must immediately stop authenticating.
- **Documented limitation**: the role flags consulted by the API's role gate are snapshots
  refreshed only at web login (`Accounts.find_or_create_user/1`), so portal deprovisioning does
  **not** automatically cut off API access — timely cutoff requires token revocation (manual in
  this story; the STORY 2 self-serve UI is a rollout prerequisite for this reason too).
- **Secret handling**: the raw token is shown/delivered **once** at mint time and is not
  recoverable afterwards (the server stores it only in irreversible form); one-time codes are
  likewise stored server-side **only in irreversible form** (the exchange compares against the
  stored form — a leaked grants table must not yield usable codes during their 5-minute window);
  tokens **and one-time codes** are generated with a cryptographically secure RNG with sufficient
  entropy (with rate limiting out of scope for v1, code entropy is the only brute-force defense
  during the 5-minute code window); tokens and one-time codes must never appear in server logs or
  error messages.

### Login handoff

- **Loopback flow** (server side only in this story): `/auth/cli` controller flow accepting
  `redirect_uri` (loopback `127.0.0.1:<port>/callback` only), `state` nonce, and a PKCE
  `code_challenge`; runs the existing portal login if there is no session. On success it does
  **not** mint the token — it creates a **pending authorization grant** (the one-time code bound
  to the authenticated user and the `code_challenge`, with the 5-minute expiry) and redirects to
  the loopback with the **one-time code** via a **plain controller redirect** (not LiveView).
  The API token is **minted atomically during a successful `POST /auth/cli/token`** exchange
  (code valid + PKCE verifier matches): mint, store only the irreversible form, return the raw
  token once in that response — no raw token exists server-side before the exchange, and none is
  recoverable after it.
- **Portal selection**: `/auth/cli` accepts an optional **`portal`** parameter (a portal URL,
  same meaning as the existing browser `?portal=` param). Tokens are portal-scoped (users are
  keyed by `portal_server` + `portal_user_id`), so the CLI must be able to control which portal
  it gets a token for. When present, `portal` is validated **on entry**: it must be an **https
  origin** (`https://host[:port]` — no userinfo, path, query, or fragment) and must resolve via the
  existing portal→server mapping (`PortalDbs.get_server_for_portal_url/1`) to a portal with a
  configured portal-DB connection — an invalid `portal` is an entry-validation failure (error at
  `/auth/cli`, no redirect, no code). When valid, the **normalized origin** (not the raw input)
  is what is preserved across the login round trip with the rest of the request state and is the
  portal the login and token are scoped to, **overriding any session portal** — if an existing
  session user's `portal_server` does not match the requested portal, `/auth/cli` runs the portal
  login against the requested portal rather than reusing the session. **Fallback when omitted**:
  existing browser behavior — the session's portal if set, else the configured default portal.
- **Request-state preservation and `state` echo**: `/auth/cli` validates `redirect_uri`, `state`,
  `code_challenge`, and (when present) `portal` **on entry**, and when a portal login round trip
  is needed, the validated request state must survive it. After login the flow resumes with the
  original validated values. The final redirect to the loopback carries **both** the one-time
  `code` and the original `state` echoed verbatim — the CLI correlates the callback to its login
  attempt via `state`. A **failed entry validation** (non-loopback `redirect_uri`, missing `state`
  or `code_challenge`, non-S256 PKCE method, or an invalid `portal`) renders an error response at
  `/auth/cli` itself — never a redirect to the supplied `redirect_uri`, and no one-time code is
  minted (per RFC 6749 3.1.2.4).
- **Code-exchange endpoint contract**: **`POST /auth/cli/token`** with JSON body
  `{ "code": "<one-time code>", "code_verifier": "<PKCE verifier>" }`. It is a direct CLI->server
  call — no session or cookies (routed through the `:api` pipeline, not `:browser`, so no CSRF
  involvement). Success: `200` with `{ "token": "<bearer token>" }` (additional fields may be
  added later within v1, additive-only); the exchange is the **mint point**. Failure: the standard
  API error shape; an unknown, expired, or already-used code and a PKCE verifier mismatch all
  return a single indistinguishable **400 `BAD_REQUEST`**. Single-use enforcement is **atomic**:
  exactly one exchange of a given code can ever succeed — concurrent duplicate exchanges must not
  both mint a token; the loser gets the same indistinguishable 400. The code/verifier travel in
  the POST body (never the query string) so they stay out of URL logs; both param names fall under
  the `filter_parameters` log-hygiene obligation.
- The `/auth/cli` flow refuses to mint for users who fail `can_access_reports?` — it fails at
  login with a clear message rather than handing out a token the API's role gate would reject.
- One-time codes **expire 5 minutes after issuance** and are single-use (invalid after the first
  successful exchange); an expired or already-used code fails the exchange with the same
  indistinguishable **400 `BAD_REQUEST`** as an unknown code.
- PKCE method is **S256 only** — `plain` is rejected.
- **Manual fallback**: an authenticated LiveView route (e.g. `/reports/cli-token`) that generates
  and **shows the token once** for manual paste. Minting happens only on an explicit user action
  (e.g. a "Generate token" button, alongside the optional label input) — page load/refresh never
  mints, and a refresh after minting does not re-mint or re-display the token.
- Both paths mint the **same kind** of token (one token model behind both).

### API (canonical paths `/api/v1/...`)

- New `:api_authenticated` Phoenix pipeline = `:api` + a bearer-verifying plug (analogous to
  `Auth.Plug`).
- **Role gate**: the pipeline also enforces `can_access_reports?` (portal admin || project admin
  || project researcher) on the token's resolved user. A valid token whose user fails the check
  gets **401 `NOT_AUTHENTICATED`**, indistinguishable from a bad token.
- `GET /api/v1/reports` — list the caller's report runs (`report_runs.user_id == caller`),
  **keyset-paginated** (`WHERE id < ? ORDER BY id DESC LIMIT n`; last id encoded into
  `next_page_token`). List scope = runs you authored.
- **Athena-backed runs only**: non-Athena (portal/MySQL usage-report) runs are excluded from the
  API entirely — not listed, and `/:id` / `/:id/download` treat them as not-found.
- **Classification is by report type, not artifact presence**: a run is API-visible iff its
  `report_slug` resolves to an Athena-type report definition, regardless of query state. A
  queued/running Athena run appears in list/show with its current `athena_query_state`. State only
  gates `/download`.
- `GET /api/v1/reports/:id` — one run's metadata + `athena_query_state`.
- **State freshness**: the stored `athena_query_state` only advances while the run's LiveView
  Show page is open in a browser, so the API must not serve it blindly. On `GET /:id` and
  `/:id/download`, when the run has an `athena_query_id` and a non-terminal stored state
  (null/queued/running), the server refreshes from Athena (`AthenaDB.get_query_info/1`) and
  persists **both** fields the call returns — `athena_query_state` AND `athena_result_url` —
  before responding, so a run refreshed to `succeeded` is immediately downloadable. List responses
  serve stored state as-is (no per-run Athena calls). If the Athena refresh fails (e.g. transient
  AWS error/throttling), the endpoint serves the **stored** state and logs the failure server-side.
- **Not-yet-started runs self-start**: an Athena-type run can exist with `athena_query_id == nil`.
  On `GET /:id` and `/:id/download`, when an Athena-type run has `athena_query_id == nil`, the
  server **starts the Athena query** via the same path the Show LiveView uses (build the query from
  the stored `report_filter` -> `AthenaDB.query` -> persist `athena_query_id` + `athena_query_state`)
  before responding. If the start fails, the endpoint serves the stored state (`null`) and logs the
  failure server-side. List never starts queries. **Duplicate API requests are single-flight**: the
  API claims a run atomically before starting — concurrent API polls serve the stored state instead
  of stacking starts. The Show-mount-vs-API concurrent start remains a known, **accepted** race
  (same as today's two-browser-tab behavior; worst case is one wasted duplicate query, last-persisted
  id wins). Self-start must be covered by a test that starts from a **persisted** filtered run (a
  `report_filter` round-tripped through the DB, not an in-memory struct).
- `GET /api/v1/reports/:id/download` — mint a **fresh** presigned CSV URL (reusing
  `AthenaDB.get_download_url/2`); **409 `NOT_READY`** for every non-succeeded state
  (queued/running/failed/cancelled/nil), with the current `athena_query_state` in the error
  context. A `succeeded` run with a null `athena_result_url` is a server invariant violation:
  500-class error, logged server-side.
- `GET /api/v1/reports/:id/jobs` — list the run's **post-processing jobs** from the persisted
  jobs file (`s3://<output-bucket>/jobs/<athena_query_id>_jobs.json`). Each item is exactly
  `{ "id": <int>, "steps": [{ "id": "...", "label": "..." }], "status": "<status>",
  "has_result": <bool> }` — the persisted `result` S3 URL is mapped to the `has_result` boolean
  and is never serialized. Runs with no jobs file (or no `athena_query_id`) return an empty list.
  Statuses are served **as persisted** (no job-liveness refresh); no pagination (same envelope with
  `next_page_token` always null). Only a **missing** jobs file yields the empty list; any other S3
  read failure is a 500-class error, logged server-side.
- `GET /api/v1/reports/:id/jobs/:job_id/download` — mint a **fresh** presigned URL for the job's
  result CSV; **409 `NOT_READY`** with the job `status` in the error context for any non-completed
  job (started/failed); **404 `NOT_FOUND`** for unknown or malformed `:job_id`, indistinguishable
  from a non-existent run. A `completed` job with a null `result` is a server invariant violation:
  500-class error, logged server-side. Issuance is audit-logged like every other download surface.
- **Job creation stays web-UI-only** — the API downloads post-processed outputs but cannot create
  jobs.
- **Per-endpoint authz**: every `/:id/*` endpoint requires `report_runs.user_id == caller`.
  **Strict ownership applies to admins too** (no `portal_is_admin` bypass, unlike the LiveView) —
  admins use the web UI for other users' runs.
- **No existence leaks**: non-existent, not-owned, and non-Athena run ids all return **404
  `NOT_FOUND`**, indistinguishable from each other. Syntactically invalid or out-of-bigint-range
  `:id` path params fall in the same 404 bucket (the default data layer raises
  `Ecto.Query.CastError` on them — the API must not surface that as a 500).
- Run metadata in list/show responses includes at minimum: id, `report_slug`, `report_filter`
  (raw ids), `report_filter_values` (resolved human labels, as stored on the run),
  `athena_query_state`, and timestamps. Run responses **never include `athena_result_url`** or any
  other raw storage URL.

### Contract

- Unified paged envelope: `{ "items": [...], "next_page_token": "<opaque>" | null }`; `limit`
  query param in (default 50; numeric values clamped into `[1, 200]`; non-integer `limit` or
  otherwise malformed query params -> **400 `BAD_REQUEST`**); the token is opaque.
- **Page-token request parameter is `page_token`**: clients echo the previous response's
  `next_page_token` value back as `page_token` (per the AIP-158 convention). A malformed/undecodable
  `page_token` returns **400 `BAD_REQUEST`**. There is no expired/unknown-token state by design:
  with keyset pagination any decodable token is a valid `WHERE id < ?` bound even if the referenced
  run was since deleted.
- **Download success shape** (both `/download` endpoints, same shape): **200**
  `{ "download_url": "<presigned https URL>", "filename": "...", "expires_in_seconds": 600 }` —
  a bare object, not the paged envelope. `filename` is the server's suggested name (run:
  `<report_slug>-run-<id>.csv`; job: `<report_slug>-run-<run_id>-job-<job_id>.csv`).
  `expires_in_seconds` reports the presign expiry (currently 600) so the CLI never hardcodes the
  window. Evolution within v1 is additive-only.
- **No raw artifact URLs outside `/download`**: list, show, and jobs responses never contain raw
  storage URLs (`athena_result_url`, job `result`, or any other `s3://` location). Presigned URLs
  are issued **only** by the two `/download` endpoints — that is what makes every URL issuance
  audit-logged.
- Timestamps serialize as **ISO 8601 UTC strings**.
- **`report_filter` serialization**: a JSON object with **all fields always present** (stable
  shape — no absent-vs-null ambiguity):
  - `"filters"`: array of filter-type strings, in stored order (served as stored, not reversed);
  - `"cohort"`, `"school"`, `"teacher"`, `"assignment"`, `"class"`, `"student"`,
    `"permission_form"`, `"country"`, `"subject_area"`: arrays of integer ids, or `null` when unset;
  - `"state"`: array of strings, or `null` when unset;
  - `"start_date"`, `"end_date"`: strings as stored, with empty string normalized to `null`;
  - `"hide_names"`, `"exclude_internal"`: booleans.

  A run stored with **no** `report_filter` (nil is schema-legal) serializes as the **empty filter**
  in this same all-fields-present shape (`filters: []`, dimensions/`state`/dates `null`, booleans
  `false`) — `report_filter` is never JSON `null`.
- **`report_filter_values` serialization**: served as stored — an object keyed by filter type
  whose id keys become **JSON strings**, e.g. `{"class": {"254": "Ms. Smith (period3)"}}`.
- `athena_query_state` in responses is one of: `null`, `"queued"`, `"running"`, `"succeeded"`,
  `"failed"`, `"cancelled"` (Athena's states, lowercased).
- Post-processing job `status` in responses is one of: `"started"`, `"completed"`, `"failed"` —
  only `"completed"` jobs are downloadable.
- `Authorization: Bearer <token>` on every request; unauthenticated requests get **401** with a
  single-line JSON error body `{ "error": "NOT_AUTHENTICATED", ... }`.
- One error shape everywhere: `{ "error": "<CODE>", "message": "...", ...context }` with v1 codes
  `NOT_AUTHENTICATED` (401), `NOT_FOUND` (404), `NOT_READY` (409), `BAD_REQUEST` (400),
  `SERVER_ERROR` (500). (No `FORBIDDEN` in v1 — ownership failures are 404 by design; STORY 3 may
  reintroduce it.)
- **All 500-class API failures use the single code `SERVER_ERROR`** — invariant violations,
  non-missing S3 read failures, audit-write failures, and any other internal error render
  `{ "error": "SERVER_ERROR", "message": "..." }`. The message/context carries **safe content
  only** — no exception details, stack traces, S3 URLs, or secrets.
- **The API ignores `Accept` and always speaks JSON**: the `/api/v1` pipelines force the json
  format unconditionally rather than negotiating it. Routed API requests and unknown `/api/v1`
  paths therefore return the contract shape **regardless of the `Accept` header**. The one
  exception is request-body failures that occur before routing (a malformed JSON body raising in
  the endpoint's parser), which Phoenix's error renderer negotiates from the `Accept` header
  (falling back to HTML when it is absent) — so sending `Accept: application/json` on every request
  remains a STORY 4 CLI obligation.
- Path-versioned (`/api/v1/...`); the server stays backward-compatible within v1.

### Audit logging (from day one)

- Create the `data_access_log` table/migration AND log the CSV **URL-issuance** event on
  `/download` (mint != download — log that access was granted).
- **Web-UI downloads are logged too**: the existing LiveView Athena download
  (`download_athena_report`) writes a `data_access_log` row on every successful URL-issuance, with
  an event/source value distinguishing web-UI issuance from API issuance. The row records the
  **requesting** user (who may be an admin downloading another user's run — the case the API
  refuses). Portal (MySQL) report downloads stay unlogged.
- **Post-processing result URL-issuance is logged too**: the run page's post-processing component
  mints presigned URLs for derived student-data CSVs via both its "Download Result" and "Copy
  Result URL" buttons; every such issuance writes a `data_access_log` row through the same audit
  call, with a distinct data-type/event value identifying it as a post-processing artifact and
  recording the job id. API job-result downloads log the same post-processing event with the API
  source value.
- **Legacy `/old-reports` export path is disabled**: the `/old-reports` router scope is removed in
  this story rather than brought into the audit net, and replaced with a **redirect to `/reports`**
  using the existing backwards-compat pattern (`RedirectToReports`). That legacy LiveView minted
  presigned URLs for student-data CSVs gated only by `Auth.logged_in?` with no `report_runs` row an
  audit record could reference. The `OldReportLive` modules may remain in the tree as unreachable
  code — deleting them is optional cleanup, not a requirement.
- **Audit writes are fail-closed, in a pinned order**: on every logged surface (API `/download`,
  web raw-CSV download, post-processing buttons), the sequence is: (1) **generate** the presigned
  URL first but do not return it — if presigning fails, take the surface's normal error path (API:
  500-class `SERVER_ERROR`; LiveView: existing error handling) and write **no audit row**;
  (2) **write** the audit row — if the write fails, discard the generated URL and fail closed with
  a server error (API: 500-class; LiveView: error flash), no URL returned; (3) only after the audit
  write succeeds is the URL **returned/pushed**. Two invariants hold: every returned URL has an
  audit row, and every audit row corresponds to a URL that was actually generated.
- Each record: timestamp, requesting `user_id`, the `report_run` / filters, data type, page/cursor
  progress (null for CSV issuance), and a **nullable artifact-context field** carrying at minimum
  the post-processing job id for job-result issuance rows (null for plain CSV issuance; available
  to STORY 3 event types). Append-only; a retried page must be distinguishable from new access.
- The schema includes a **nullable resolved-endpoint-set field** (JSON column) for student-level
  auditability — null for CSV URL-issuance rows; STORY 3's per-page events fill it.
- **Documented limitation**: CSV audit rows are run+filter granularity. Student-level questions
  about a CSV export are answered via the **persisted S3 artifact** the run points to
  (`athena_result_url`) — the audit row supplies who/when/which run; the artifact is the literal
  exported content. Optional follow-up (with STORY 3): derive and log the endpoint set at CSV
  download time.
- The schema MUST accommodate STORY 3's per-page answers/history events, which reuse this table.
- **Admin-only audit-log page**: an admin-only (`portal_is_admin`) LiveView page lists
  `data_access_log` events, **paginated**, newest first — columns: timestamp, requesting user, run
  id + report slug, data type/event. No filters in v1 (filters/student search come with STORY 3).
  Retention is indefinite (no cleanup job).

### Pagination (LiveView pages)

- Implement a **generic, reusable pagination method** for LiveView list pages: page-number/offset
  style with a classic pager UI (prev/next + page numbers).
- Use it for the new audit-log page AND **retrofit the existing run list pages** —
  `/reports/runs` (`:my_runs`) and `/reports/all-runs` (`:all_runs`) — which currently load all
  rows unpaginated.
- **Pager contract** (shared by all three pages):
  - **Page size**: fixed at **25** rows per page, not user-configurable in v1.
  - **URL semantics**: the current page lives in the URL query string as `?page=N`
    (`push_patch` navigation); page 1 is the canonical no-param URL.
  - **Invalid input**: a non-integer or `< 1` `page` param is treated as page 1; a `page` beyond
    the last page **clamps to the last page**. No error state either way.
  - **Empty list**: renders page 1 with the table's empty state; the pager is hidden whenever there
    is only one page (including zero rows).
  - Windowing/truncation and component API are implementation concerns (resolved as
    `1 ... p-1 p p+1 ... N`, max 7 items — see Decisions).
- The JSON API keeps its separate keyset contract (different consumers, different mechanics).

### Accessibility (new UI surfaces)

- The pager is keyboard-operable, wrapped in a `<nav aria-label="pagination">` landmark, with
  `aria-current="page"` on the active page link.
- Data tables (audit log, run lists) use proper `<th>` header markup.
- The `/reports/cli-token` page renders the token as selectable text with an accessible
  copy-to-clipboard control, and announces "copied" via an ARIA live region.
- New UI follows the app's existing Tailwind styles and maintains WCAG AA color contrast.

## Technical Notes

- **Router / pipelines**: `:browser` uses `ReportServerWeb.Auth.Plug` (session-based,
  non-enforcing; enforcement is the `ReportLive.Auth` `on_mount` in the `:reports` live_session).
  The `:api` pipeline is bare; no `/api` routes exist today.
- **Session auth**: the portal OAuth is the **implicit flow** (`response_type=token`): the token
  arrives in the URL fragment, read client-side by `AuthLive.Callback`, then persisted into the
  session by the `/auth/save_token` **controller** — a useful controller-vs-LiveView precedent for
  `/auth/cli`, but not directly a token-minting flow.
- **Portal-selection machinery**: `Auth.Plug` stashes `conn.params["portal"]` into the session on
  every `:browser` request; `AuthController.login/2` reads it back with the configured default
  portal as fallback. There is **no explicit portal allowlist** anywhere — validity is enforced
  only implicitly, because `save_token` must query the portal's DB, whose credentials come from a
  per-server env var (`<SERVER>_DB`). `/auth/cli`'s `portal` validation grounds on the same
  condition: mapped server has a configured DB connection.
- **`return_to` machinery stores a path-only string**: the LiveView auth hook builds `return_to`
  from `URI.parse(url) |> Map.get(:path)`, dropping the query string. `/auth/cli` must not inherit
  that pattern blindly; it must explicitly preserve its request state across the login round trip.
- **Users**: `ReportServer.Accounts.User` — unique on `(portal_server, portal_user_id)`; role
  flags `portal_is_admin`, `portal_is_project_admin`, `portal_is_project_researcher` snapshotted
  from the portal at login.
- **Report runs**: `ReportServer.Reports.ReportRun` — `report_slug`, `report_filter` (custom Ecto
  type), `report_filter_values` (map), `athena_query_id`, `athena_query_state`, `athena_result_url`
  (s3:// URL), `belongs_to :user`. `Reports.list_user_report_runs/2` is the existing my-runs query.
- **Download today**: `ReportRunLive.Show.download_athena_report/1` ->
  `AthenaDB.get_download_url(athena_result_url, filename)` (ExAws presign, 10-min expiry). Portal
  (MySQL) report runs have no `athena_result_url`.
- **DB/migrations**: single Ecto repo `ReportServer.Repo` (MySQL/MyXQL); `timestamps(type:
  :utc_datetime)`, bigint ids, FK + index pattern per `create_report_runs.exs`. New tables: API
  tokens table + `data_access_log` (+ auth grants table).
- **Token implementation material**: no `Phoenix.Token` usage today; `secret_key_base` and
  `elixir_uuid` are available.
- **JSON conventions**: `ReportServerWeb.ErrorJSON` renders `%{errors: %{detail: ...}}` — the
  cc-data contract (`{"error": CODE, ...}`) intentionally differs; the API pipeline needs its own
  error rendering.
- **Filter labels**: `report_filter_values` is populated at run creation with resolved display
  names from the portal DB; student names respect `hide_names`. Raw ids are in `report_filter`.
  But **`%ReportFilter{}` has no `Jason.Encoder`** — the implementation must add an explicit
  serializer matching the Contract's `report_filter` shape; returning the struct raw is a 500.
- **Loaded-filter atom/string asymmetry**: `EctoReportFilter.load/1` atomizes only top-level keys,
  so a DB-loaded `report_filter` has *string* entries in `filters` while `ReportFilter.from_form/2`
  stores atoms. The Athena `get_query` path never reads the `filters` list, and today's only
  query-start path already runs on DB-loaded filters, so **API self-start is safe iff it reuses
  `report.get_query` exactly**. The API must not reach for `ReportFilterQuery` (which pattern-matches
  atom filter names only and raises on a loaded filter) with a persisted filter.
- **Post-processing jobs**: per-`athena_query_id` GenServer whose job list is **persisted to S3**
  at `s3://<output-bucket>/jobs/<query_id>_jobs.json` and reloaded on server start — so the API can
  read the jobs file directly without the GenServer running. The derived `Job` encoder includes
  `:result` (a raw S3 URL), so the API jobs list must use an explicit sanitized serializer mapping
  `result` -> `has_result`. `Aws.get_file_contents/1` cannot distinguish a missing file from other
  S3 failures — the API jobs-list needs a read path that separates S3 not-found (-> empty list) from
  other failures (-> 500-class).
- **Log hygiene**: Phoenix logs controller params, redacting only keys in
  `config :phoenix, :filter_parameters` — default `["password"]` — and this app sets **no**
  `filter_parameters` config at all. The implementation must add the one-time-code and any
  token/code param names to `:phoenix, :filter_parameters`.
- **Testing**: `ConnCase` exists but has no auth helper and no JSON/controller-auth test precedent —
  this story establishes the bearer-auth test pattern.
- **No rate limiting / telemetry export / audit logging** exists anywhere today.
- **Future consideration (not this story)**: if run creation ever moves into the API, query
  start/polling should move out of the Show LiveView into a server-side process (e.g. a per-run
  GenServer) that owns `athena_query_id`/`athena_query_state`/`athena_result_url`.

## Out of Scope

- **Token-management UI** (list tokens, `last_used_at` display, self-serve revoke) — STORY 2.
  Required before researcher rollout; revocation here is manual (DB/console).
- **Answers/history bulk endpoints** (`/api/v1/reports/:id/answers|history`, Node bulk-read
  function, cursor scratch, `EXPIRED_CURSOR`) — STORY 3. This story only ensures the audit-log
  schema accommodates them.
- **The Go CLI itself**, including the loopback listener half of the login flow — STORY 4.
- **Creating report runs via the API** — download-only, per the design doc's decided scope boundary.
- **Creating post-processing jobs via the API** — same boundary: job-result *download* is in scope,
  but jobs are created only from the web run page.
- **Non-Athena (portal/MySQL) report runs** — excluded from the API surface entirely; they concern
  portal usage, not student data.
- **Rate limiting / abuse protection** — noted as a future concern, not v1.
- **Encryption at rest / TTL for local CLI data** — CLI-side concern (STORY 4), decided no for v1.

## Not Yet Implemented

- **Job-result endpoint set derivation / logging for CSV downloads** — CSV audit rows stay
  run+filter granularity in v1; deriving and logging the resolved endpoint set at CSV download time
  is an optional follow-up once STORY 3's derivation call exists.
- **Retention/cleanup job for `data_access_log`** — deliberately excluded; retention is indefinite
  in v1 (no cleanup job).
- **Audit-log page filters / student-level search** — deferred to STORY 3, when the endpoint-set
  column has data to search.
- **`/auth/cli` optional `label` param** — the CLI login flow hardcodes label `"CLI login"`; a
  validated `label` param on `/auth/cli` stays available as a purely additive follow-up whenever
  STORY 4 wants it.
- **Deletion of the unreachable `OldReportLive` modules** — optional cleanup, not a requirement;
  the modules may remain in the tree as dead code after the `/old-reports` route is disabled.
- **Normalizing `EctoReportFilter.load/1` to re-atomize `filters` entries** — noted as optional
  hardening (touches every existing load site), not required by this story.

## Decisions

### How should the API handle non-Athena (portal/MySQL) report runs?
**Context**: `report_runs` includes runs of portal-DB reports that have no Athena artifact. Today
their LiveView download runs the SQL live. The API needs defined behavior in both list and download.
**Options considered**:
- A) Include them in `GET /api/v1/reports`, but `/download` returns a distinct error code.
- B) Exclude non-Athena runs from the API entirely (list filters to Athena-backed runs).
- C) Implement live-query download for portal reports in the API too.

**Decision**: **B — exclude non-Athena runs from the API entirely.** Portal reports are about portal
usage, not student data; cc-data is a student-data tool. List, show, and download all treat
non-Athena runs as outside the API (behaving as not-found).

---

### Can a user hold multiple active tokens at once?
**Context**: The ticket says "one token per portal" (how the CLI keys its stored credentials), but
STORY 2's token UI lists "all of a user's active tokens" with per-token `last_used_at` and label —
implying multiple concurrent tokens.
**Options considered**:
- A) Multiple active tokens per user; each login/generate mints a new one; old ones live until revoked.
- B) Single active token per user; minting a new one revokes the previous.

**Decision**: **A — multiple active tokens per user.** Consistent with STORY 2's token-list UI and
avoids a second machine silently invalidating the first.

---

### Should admins be able to read/download other users' runs via the API?
**Context**: The LiveView run page allows `owner || portal_is_admin`. The design doc decided the API
is strictly ownership-gated, but that discussion was aimed at non-admin colleagues.
**Options considered**:
- A) Strict ownership for everyone, including admins (an admin can still use the web UI).
- B) Owner OR `portal_is_admin`, mirroring the existing LiveView check.

**Decision**: **A — strict ownership for everyone, including admins.** A non-expiring admin token
that can pull any run meaningfully worsens the leaked-token blast radius; the web UI already covers
the admin need, and STORY 3 stays consistent.

---

### data_access_log — who can read it, and what retention policy?
**Context**: The story owns the decisions about who can read the sensitive audit log and how long
records are kept.
**Options considered**:
- A) No in-app read surface (DB/console only); retention indefinite.
- B) Admin-only LiveView page listing recent access events; retention indefinite.
- C) A or B but with a defined retention window enforced by a cleanup job.

**Decision**: **B, with pagination — and a scope addition.** An admin-only LiveView page lists
access-log events, paginated. Retention indefinite. Since no run-list page currently paginates, this
story implements a **generic (reusable) pagination method** and applies it to the new audit page and
retrofits the existing run list pages.

---

### data_access_log content — resolved endpoint set vs hash (schema decision owed to STORY 3)
**Context**: CSV events are run-level, but the schema must accommodate STORY 3's per-page
answers/history events, which lean toward logging the resolved `remote_endpoint` set.
**Options considered**:
- A) Schema includes a nullable field for the resolved endpoint set (JSON column); CSV rows leave
  it null; STORY 3 fills it per page.
- B) Schema stores only a count + hash of the endpoint set.
- C) Defer the field to STORY 3.

**Decision**: **A — nullable resolved-endpoint-set field (JSON column).** Count+hash can't answer
"was student X in this export?"; the sensitivity is handled by the admin-only read surface.

---

### Should list/show responses resolve human-readable filter labels?
**Context**: The design doc wants the CLI to capture both raw filter values and resolved human
labels from list/show responses.
**Decision**: Return `report_filter_values` exactly as stored — verified in code that it already
contains resolved human labels (populated at run-creation time from the portal DB). Raw ids live in
`report_filter`. Returning both fields as stored satisfies the design doc with no extra resolution.

---

### Pagination limits — default and max page size for `GET /api/v1/reports`?
**Context**: The contract takes a `limit` param, but the default and cap were unspecified.
**Options considered**:
- A) Default 50, max 200.
- B) Default 100, max 500.

**Decision**: **A — default 50, max 200.** Values above the max are clamped to 200.

---

### Admin audit-log page — what does it show and filter by (v1)?
**Context**: The admin page needs a defined v1 surface. Until STORY 3 lands, every row is a CSV
URL-issuance event with a null endpoint-set column, so student-level search has nothing to search.
**Options considered**:
- A) Simple paginated table, newest first: timestamp, requesting user, run id + report slug, data
  type/event. No filters in v1.
- B) A plus basic filters (by user, by run id).
- C) B plus student-level search over the endpoint-set column.

**Decision**: **A — simple paginated table, newest first, no filters in v1.** Filters and
student-level search come with STORY 3.

---

### LiveView pagination style — page numbers or "load more"?
**Context**: The generic pagination method backs three LiveView pages. The API uses keyset; the
LiveView pages can use either style.
**Options considered**:
- A) Page-number/offset pagination (classic pager UI: prev/next + page numbers).
- B) Keyset-based "Load more" / infinite scroll.

**Decision**: **A — page-number/offset pagination with a classic pager.** Familiar and jumpable for
admin tables; offset cost negligible at these table sizes. The API keeps its separate keyset contract.

---

### Not-owned run responses can leak run existence (403 vs 404)
**Context**: Run ids are sequential and guessable; a 403 confirms "this run exists" to any token
holder, enabling enumeration.
**Decision**: Non-existent, not-owned, and non-Athena run ids all return **404 `NOT_FOUND`**,
indistinguishable from each other. `FORBIDDEN` is dropped from the v1 error-code list (STORY 3 can
reintroduce it if needed).

---

### Token/secret handling requirements are missing
**Context**: The spec deferred token format to implementation, but several properties are
requirements, not implementation choices.
**Decision**: Added as requirements: (a) the raw token is shown/delivered once and stored only in
irreversible form; (b) tokens and one-time codes never appear in server logs or error messages;
(c) tokens are generated with a CSPRNG and sufficient entropy; (d) PKCE method is S256 only.
Mechanism (opaque vs signed, hash algorithm, prefix) remains an implementation decision.

---

### "Athena-backed run" exclusion criterion — classification by report type
**Context**: If the filter were "has `athena_query_id`/`athena_result_url`", a just-created queued
Athena run would vanish from the API — but the CLI polls the API while the query runs.
**Decision**: Classification is by **report type** (the run's `report_slug` resolves to an
Athena-type report definition), independent of query state; state only gates `/download`.

---

### Download endpoint behavior for failed/cancelled/nil states and the missing-URL edge
**Context**: "409 unless succeeded" left ambiguity about failed runs and the succeeded-with-null-URL
edge.
**Decision**: `/download` returns **409 `NOT_READY`** with the current `athena_query_state` in the
error context for every non-succeeded state (the CLI decides poll vs give up);
succeeded-with-missing-URL is a server invariant violation -> 500-class error, logged.

---

### Contract details untestable as written: timestamp format and invalid `limit` values
**Context**: The envelope and error shape were specified, but not timestamp serialization nor what
`limit=0`/`limit=-5`/`limit=abc` do.
**Decision**: Timestamps are ISO 8601 UTC strings; `limit` is clamped into `[1, 200]` when numeric,
and a non-integer `limit` (or other malformed query param) returns **400 `BAD_REQUEST`**.
`BAD_REQUEST` added to the v1 code list.

---

### CSV issuance rows can't answer student-level audit questions — even after STORY 3
**Context**: The endpoint-set column is null for CSV rows by design; STORY 3 only fills it for
answers/history pages. 4 of the 5 API-visible Athena reports carry student-level identifiers.
**Decision**: **Accept and document.** Mitigating fact: the CSV artifact itself persists in S3, so
student-level questions are answerable by reading the artifact the audit row points to (who/when/which
run from the log; contents from the persisted artifact). "Derive and log the endpoint set for CSV
downloads" noted as an optional follow-up.

---

### No accessibility requirements for the new UI surfaces
**Context**: The story adds three UI surfaces with no accessibility requirements.
**Decision**: Added an "Accessibility (new UI surfaces)" subsection: keyboard-operable pager in a
`<nav aria-label="pagination">` landmark with `aria-current="page"`; proper `<th>` table headers;
selectable token text with an accessible copy control + ARIA live region; existing Tailwind styles +
WCAG AA contrast.

---

### API polling contract — `athena_query_state` freezes when the browser tab closes
**Context**: The stored state only advances while the run's Show LiveView is open in a browser (the
poll loop is the sole writer). If the researcher closes the tab mid-query, the API would report
"running" forever and `/download` 409 forever.
**Decision**: Added a **State freshness** requirement: on show and download, when a run has an
`athena_query_id` and a non-terminal stored state, the server refreshes via
`AthenaDB.get_query_info/1` and persists the result before responding; list serves stored state
as-is. Enumerated the `athena_query_state` value vocabulary in the Contract.

---

### Bearer auth has no role gate — API access survives portal deprovisioning
**Context**: Web report surfaces enforce `can_access_reports?` at mount and re-snapshot roles on
each login; the API specified only ownership authz and tokens are non-expiring.
**Decision**: (a) The `:api_authenticated` pipeline also enforces `can_access_reports?` against the
token's resolved user (role failure -> 401 `NOT_AUTHENTICATED`, indistinguishable from a bad token);
(b) added a documented limitation: role snapshots refresh only at web login, so timely
deprovisioning requires token revocation — reinforcing STORY 2 as a rollout prerequisite.

---

### "Audit from day one" doesn't cover the existing web-UI export path
**Context**: The LiveView download mints the same presigned URL for the same student-data artifacts
(including admins downloading others' runs, which the API refuses) and wrote nothing.
**Decision**: Added a **Web-UI downloads are logged too** requirement: the LiveView Athena download
logs URL-issuance with a web-vs-API event/source value, recording the requesting user; portal (MySQL)
report downloads stay unlogged.

---

### `/reports/cli-token` mint trigger unspecified — mint-on-page-load would create orphan immortal tokens
**Context**: With multiple active tokens and no token-management UI until STORY 2, minting on page
load would silently create untrackable non-expiring tokens.
**Decision**: The Manual fallback requirement now specifies mint-on-explicit-action only: page
load/refresh never mints, and a refresh after minting does not re-mint or re-display the token.

---

### State-freshness requirement left refresh-failure behavior undefined
**Context**: The State freshness change made show/download refresh "before responding" but didn't
define behavior when `AthenaDB.get_query_info/1` fails (transient AWS error/throttling).
**Decision**: On refresh failure the endpoint serves the stored state and logs the failure
server-side, so the CLI polling loop survives transient AWS errors instead of seeing 500s.

---

### `/auth/cli` could mint tokens for users the API role gate will always reject
**Context**: The role gate means a token for a user failing `can_access_reports?` 401s on every
request — but `/auth/cli` sits outside the `:reports` live_session gate, so it would happily mint
such a token.
**Decision**: `/auth/cli` refuses to mint for users failing `can_access_reports?`, failing at login
with a clear message instead.

---

### State refresh must persist `athena_result_url` too, or the tab-closed run 500s on download forever
**Context**: `get_query_info/1` returns both the state and the S3 output location, and the LiveView
poll persists both. Persisting only the state would leave a `succeeded` run with a null
`athena_result_url`, which the invariant clause then classifies as a server error.
**Decision**: The State-freshness bullet requires persisting both `athena_query_state` and
`athena_result_url` from the same `get_query_info/1` call, so a run refreshed to `succeeded` is
immediately downloadable.

---

### "Never in server logs" will be violated by default — no `filter_parameters` config exists
**Context**: Phoenix logs every request's params, filtering only `password` by default, and the app
sets no `filter_parameters` — so the one-time code would be logged on every exchange request.
**Decision**: Added a **Log hygiene** Technical Notes bullet documenting the missing config and the
implementation obligation to filter one-time-code/token param names.

---

### Malformed or out-of-range `:id` path params are undefined — the naive implementation 500s
**Context**: The data layer raises `Ecto.Query.CastError` on `/api/v1/reports/abc` or an
out-of-bigint-range id, each surfacing as a 500 with no defined expectation.
**Decision**: A syntactically invalid or out-of-range `:id` behaves as **404 `NOT_FOUND`** — same
bucket as non-existent, keeping the "one indistinguishable 404" property.

---

### Post-processing result downloads are unlogged student-data exports
**Context**: The run Show page's post-processing component has "Download Result" and "Copy Result
URL" buttons that both mint presigned URLs for derived student-data CSVs, unlogged.
**Decision**: Added a **Post-processing result URL-issuance is logged too** requirement (both
buttons, same audit call, distinct data-type/event value, job id recorded).

---

### Audit-write failure semantics — can a download proceed if its audit row can't be written?
**Context**: An undefined choice that silently sets policy: fail-open (export proceeds unrecorded)
vs fail-closed (no export while the log table has trouble).
**Decision**: **Fail-closed.** The URL is minted only after the audit row commits; a failed write ->
500 and no URL. The audit table lives in the same MySQL instance as everything else, so an
unavailable log table means the app is degraded anyway.

---

### Post-processed results are absent from the spec — silently out of scope for the CLI
**Context**: The API's list/show/download covered only the raw Athena artifact, so a CLI researcher
would lose access to post-processed outputs (audio transcription, glossary data, merged answers) —
a workflow gap nobody decided on the record.
**Options considered**:
- A) Add an Out of Scope bullet keeping post-processing web-UI-only.
- B) Extend the API to expose post-processed job results.

**Decision**: Suggested out-of-scope resolution **rejected**; scope extended instead. Added
`GET /api/v1/reports/:id/jobs` and `GET /api/v1/reports/:id/jobs/:job_id/download` (fresh presigned
URL, 409 `NOT_READY` for non-completed, 404 for unknown/malformed job ids, audit-logged). Job
**creation** stays web-UI-only. Feasibility verified: jobs persist to S3 and are readable without
the job GenServer; results are S3 URLs presignable by `AthenaDB.get_download_url/2`.

---

### Jobs-list behavior on S3 read failure is undefined
**Context**: The new `/jobs` requirement said runs with no jobs file return an empty list but didn't
say what a failed S3 read returns; serving an empty list on a transient error tells the CLI "your
jobs are gone." The current helper can't distinguish "no jobs file" from "S3 error".
**Decision**: Missing jobs file -> empty list (200); any other S3 read failure -> 500-class error,
logged. Technical Notes gained the `Aws.get_file_contents/1` caveat.

---

### A `completed` job with a null `result` is unspecified on `/jobs/:job_id/download`
**Context**: Round-4 defined 409 for non-completed and 404 for unknown ids but not the
invariant-violation case (status `"completed"` with a null `result` URL).
**Decision**: Mirror the run-download clause: `completed` job with null `result` is a server
invariant violation -> 500-class error, logged server-side.

---

### The audit-record field list has no home for the job id
**Context**: Round 4 required post-processing events to record the job id, but the "Each record"
schema bullet enumerated no field to store it.
**Decision**: The "Each record" bullet now includes a nullable artifact-context field carrying the
post-processing job id (null for plain CSV issuance rows).

---

### API-visible Athena runs can get stuck before a query is ever started
**Context**: The web form creates the `report_runs` row before any Athena query exists; the query is
started only on Show mount. An interrupted redirect leaves an Athena-type run with
`athena_query_id: null` that can never progress.
**Decision**: Added a **Not-yet-started runs self-start** requirement: on `GET /:id` and
`/:id/download`, an Athena-type run with `athena_query_id == nil` has its query started server-side
via the same path the Show LiveView uses; start failure serves stored state and logs; list never
starts queries. The duplicate-start race was discussed and **accepted** (matches today's
two-browser-tab behavior). Future-consideration Technical Note: move query start/polling to a
server-side single-writer process if run creation moves into the API.

---

### 500-class API errors had no contract code
**Context**: Multiple requirements mandate 500-class responses and "one error shape everywhere", but
the v1 code list had no code a 500 body could carry — Phoenix's default `ErrorJSON` would leak
through.
**Decision**: Added `SERVER_ERROR` (500) to the v1 code list plus a Contract bullet: all 500-class
failures render `{ "error": "SERVER_ERROR", "message": "..." }` with safe context only. One code by
design; the distinction lives in server-side logs.

---

### Pagination response token had no request parameter name
**Context**: The contract defined `next_page_token` in responses but never named the request
parameter, and invalid-token behavior was undefined.
**Decision**: The request parameter is `page_token` (per the AIP-158 convention);
malformed/undecodable `page_token` -> **400 `BAD_REQUEST`**. Deliberately did not spec
expired/unknown-token behavior: with keyset-over-ids any decodable token is a valid `WHERE id < ?`
bound; only undecodable input can fail.

---

### Loopback code-exchange endpoint was underspecified
**Context**: The loopback flow required "a code-exchange endpoint" but defined no path, method,
fields, or success shape.
**Decision**: `POST /auth/cli/token` with JSON body `{ "code", "code_verifier" }`; direct CLI->server
call through the `:api` pipeline; success `200 { "token" }`; unknown/expired/used code and PKCE
mismatch all return one indistinguishable **400 `BAD_REQUEST`**; code/verifier travel in the body
and fall under the `filter_parameters` obligation.

---

### "Short-lived" one-time code lifetime was not testable
**Context**: "Short-lived and single-use" pinned single-use but not the lifetime.
**Decision**: One-time codes expire **5 minutes** after issuance (generous for slow logins, within
OAuth 2.0's <=10-minute guidance) and are invalid after the first successful exchange.

---

### CSPRNG/entropy requirement covered tokens but not one-time codes
**Context**: The secret-handling bullet required CSPRNG generation for tokens only; the round-2
changes made codes a concrete attack surface (5-minute lifetime, unauthenticated exchange endpoint,
no rate limiting) where code entropy is the only brute-force defense.
**Decision**: The CSPRNG/entropy requirement now applies to one-time codes as well. A `page_token`
sent to the unpaginated `/jobs` endpoints was deliberately left unspecified (standard
ignore-unused-params plus the existing malformed-query-param 400 rule cover it).

---

### Audit scope missed the legacy `/old-reports` export path
**Context**: The `/old-reports` LiveView minted presigned URLs for student-data CSVs via a different
presign helper (missed by the `AthenaDB.get_download_url/2` sweep), routed through `:browser` only
(no `can_access_reports?` gate), with no `report_runs` row an audit record could reference.
**Options considered**:
- Include it in the audit net (extending the schema for run-less events).
- Explicitly declare it out of scope.
- Disable the route.

**Decision**: **Disable the route.** The `/old-reports` scope is removed and replaced with a
**redirect to `/reports`** via the existing `RedirectToReports` pattern, closing the last unaudited
student-data export surface. Deleting the unreachable `OldReportLive` modules is optional cleanup.

---

### `report_filter` response shape was not a concrete JSON contract
**Context**: The stored value is a `%ReportFilter{}` struct with no `Jason.Encoder`, so a naive
controller 500s and careful implementations could each invent a different shape.
**Decision**: Added a **`report_filter` serialization** contract bullet (all fields always present)
and a **`report_filter_values` serialization** bullet (as stored, id keys become JSON strings).
Technical Notes flags the missing encoder and the need for an explicit serializer.

---

### LiveView pagination lacked page-size and URL semantics
**Context**: The Pagination section pinned only the style — no page size, query parameter name, or
invalid/out-of-range/empty-page behavior.
**Decision**: Added a **Pager contract**: fixed page size **25** (adjusted from the proposed 50),
`?page=N` via `push_patch` (page 1 = canonical no-param URL), non-integer/`< 1` treated as page 1,
beyond-last-page clamps to the last page, empty list renders page 1's empty state with the pager
hidden whenever there is only one page.

---

### Loopback login handoff did not preserve or return CLI state
**Context**: The existing machinery carries only a path-only `return_to` string across the login hop,
dropping the query string; without a `state` echo the STORY 4 listener cannot correlate the callback.
**Decision**: Added a **Request-state preservation and `state` echo** bullet: `/auth/cli` validates
the triple on entry and preserves it across the login hop (mechanism an implementation decision), and
the final loopback redirect carries both the one-time `code` and the original `state` echoed
verbatim.

---

### Audit fail-closed ordering could log URL issuance that never happened
**Context**: "Issued" was ambiguous between generated and returned, so an audit-then-presign
implementation would write audit rows for URLs never produced.
**Decision**: The fail-closed bullet now pins the order on every logged surface: generate the URL
first without returning it (presign failure -> normal error path, no audit row); write the audit row
(write failure -> discard the URL, fail closed); return/push the URL only after the audit write
succeeds. Both integrity invariants are explicit.

---

### `/auth/cli` entry-validation failure behavior was undefined
**Context**: The OAuth rule (RFC 6749 3.1.2.4) is that the server must never redirect to an
unvalidated redirect URI.
**Decision**: A failed entry validation (non-loopback `redirect_uri`, missing `state` or
`code_challenge`, non-S256 PKCE method) renders an error response at `/auth/cli` itself — never a
redirect to the supplied `redirect_uri`, and no one-time code is minted.

---

### Download endpoints did not define their success JSON shape
**Context**: The two existing web paths disagree on field names (`%{download_url, filename}` vs
`%{url}`), so STORY 4's CLI could implement a different name than the server.
**Decision**: Added a **Download success shape** bullet shared by both endpoints:
`200 { "download_url", "filename", "expires_in_seconds": 600 }`, a bare object; `filename` follows
existing web conventions; `expires_in_seconds` reports the presign expiry so the CLI never hardcodes
the window. `download_url` + `filename` chosen as the richer of the two existing shapes.

---

### Non-download responses did not prohibit raw artifact URLs
**Context**: The naive implementation leaks storage paths (`athena_result_url` is `s3://`; `Job`
derives `Jason.Encoder` with `:result`), blurring the audit boundary.
**Decision**: (1) a **No raw artifact URLs outside `/download`** bullet; (2) the jobs-list closed
item shape `{ id, steps, status, has_result }` with `result` mapped to `has_result`; (3) run
metadata explicitly excludes `athena_result_url`, and the jobs Technical Note gained the
derived-encoder caveat.

---

### Stored filters can break API self-start (failure scenario refuted; latent trap documented)
**Context**: The reviewer claimed self-start is unimplementable because `EctoReportFilter.load/1`
leaves `filters` values as strings while `ReportFilterQuery.get_filter_query/5` matches atoms only.
**Decision**: **Partial-agree** — no requirements change to the self-start path (it already pins the
correct `report.get_query` path, and today's only query-start path already runs on DB-loaded
filters). But the atom/string asymmetry is a real trap: added a **Loaded-filter atom/string
asymmetry** Technical Note (the API must reuse `report.get_query`, never `ReportFilterQuery`, with a
persisted filter) and extended the self-start requirement to demand a test from a persisted filtered
run.

---

### Loopback token mint timing conflicted with hash-only token storage
**Context**: Minting the token at `/auth/cli` (before the exchange) requires holding it recoverably
for up to the 5-minute window, contradicting the store-only-in-irreversible-form requirement.
**Decision**: Standard authorization-code design adopted: `/auth/cli` creates only a **pending
authorization grant** (one-time code bound to the user and `code_challenge`, 5-minute expiry); the
token is **minted atomically during `POST /auth/cli/token`**. One-time codes are also stored only in
irreversible form. The CLI-observable contract is unchanged.

---

### Loopback flow did not specify portal selection/preservation
**Context**: Tokens are portal-scoped and the browser flow picks its portal from a session-stashed
`?portal=` param, so `cc-data login` could mint a token for the default or a stale session portal.
There is no portal allowlist today.
**Decision**: Added a **Portal selection** bullet: `/auth/cli` accepts an optional `portal`
parameter, validated on entry (mapped server must have a configured portal-DB connection), preserved
across the login round trip, and scoping the login/token — overriding any session portal, including
forcing a fresh portal login on mismatch. Fallback when omitted: session portal, else configured
default.

---

### Concurrent duplicate code exchanges could both mint
**Context**: Moving the mint point to the exchange sharpened a loose edge — two racing
`POST /auth/cli/token` requests both validating before either marks the code used.
**Decision**: Single-use enforcement is pinned as **atomic**: exactly one exchange can ever succeed;
the loser gets the same indistinguishable 400. Deliberately left as-is: (a) no `redirect_uri`
re-presentation at the token endpoint (PKCE already binds the exchange); (b) the portal-override
login overwriting the session portal (same side effect as a manual `?portal=` login today).

---

### OQ-1: Token format — opaque random + hash-at-rest, or signed (Phoenix.Token)?
**Context**: The requirements pin the properties but defer the mechanism.
**Options considered**:
- A) Opaque random + SHA-256 at rest (`ccd_` + base64url of 32 random bytes; hash lookup to verify;
  `ccd_` prefix supports secret scanning).
- B) `Phoenix.Token` signed tokens (stateless verification, but revocation/`last_used_at` need the
  DB row anyway, and `secret_key_base` rotation would invalidate every CLI token).

**Decision**: **A — opaque random + SHA-256 at rest.** B's stateless-verification advantage doesn't
apply (the row is needed on every request), and A avoids coupling token validity to `secret_key_base`
rotation.

---

### OQ-2: Test seams for AWS/portal calls — config-swappable stubs or Mox?
**Context**: API tests must control Athena/S3 responses with no credentials or network in CI.
**Options considered**:
- A) Config-swappable modules (`Application.get_env` seams with Agent-backed stubs; tests
  `async: false`, no automatic call-verification).
- B) Add `mox` with behaviours (async-safe, expectation-verified, at the cost of a new dep +
  behaviour modules for single-implementation code).

**Decision**: **A — config-swappable modules, no new dependency.** The suite is small and asserts on
observed effects, not call counts. Revisit if the seams multiply.

---

### OQ-3: Extract state-refresh/self-start into `AthenaRunOps` and retrofit the Show LiveView?
**Context**: The requirements demand the API use "the same path the Show LiveView uses".
**Options considered**:
- A) Extract into `Reports.AthenaRunOps` + retrofit Show to delegate (single writer; the API
  provably shares the LiveView's path).
- B) API-side duplication, Show untouched (zero regression risk now, but two copies of subtle
  "persist both fields" logic that can drift).

**Decision**: **A — extract into `AthenaRunOps` and retrofit Show to delegate.** The single-writer
property protects the persist-both-fields behavior; the Show edit is mechanical and matches the
future-consideration direction.

---

### OQ-4: Login round-trip preservation — session storage or encoded `return_to` URI?
**Context**: The requirements allow either mechanism.
**Options considered**:
- A) Store the validated request map in the session (`:cli_auth_request`) + `return_to =
  /auth/cli/resume` (only validated data crosses the hop; resume handler re-checks
  login/portal/role).
- B) Encode the full `/auth/cli` request URI into `return_to` (survives session loss, but params
  re-validate and `return_to` was never designed for nested URIs).

**Decision**: **A — session storage + `/auth/cli/resume`.** Uses the existing `return_to` machinery
as designed; only validated data crosses the hop; the dedicated resume action with explicit
re-checks is easier to reason about and test.

---

### OQ-5: Pager windowing — `1 ... p-1 p p+1 ... N`?
**Context**: The requirements leave windowing/truncation to implementation.
**Options considered**:
- A) `1 ... p-1 p p+1 ... N` (max 7 items, stable width).
- B) A wider neighborhood (+/-2) — more jump targets, longer pager.
- C) Prev/Next only, no numbers (points away from the "classic pager" language).

**Decision**: **A — `1 ... p-1 p p+1 ... N`.** Bounded width at any table size (matters for the
unbounded audit log); conventional for admin tables.

---

### OQ-6: Where does `AuditLog.list_entries_paginated/1` land?
**Context**: The audit-table step is several commits before the pagination step that provides
`ReportServer.Pagination`.
**Options considered**:
- A) Ship the read function with the admin-page step (audit-table commit exposes only `create_entry`
  + `issue_download_url`; no forward references).
- B) Ship a non-paginated `list_entries/0` early and swap it later (throwaway code).

**Decision**: **A — the read function ships with the admin-page step**, arriving with its only caller
and its `Pagination` dependency. No forward references, no throwaway code.

---

### OQ-7: Default label for tokens minted via the CLI login flow?
**Context**: The manual page has a label input; the loopback flow has nowhere to collect one.
**Options considered**:
- A) Fixed label `"CLI login"` (STORY 2 still distinguishes tokens by timestamps).
- B) No label (nil) — indistinguishable rows in the STORY 2 list.
- C) Accept an optional validated `label` param on `/auth/cli` now.

**Decision**: **A — fixed label `"CLI login"`.** No contract surface added; STORY 2's list
distinguishes by timestamps. A `label` param on `/auth/cli` stays available as a purely additive
follow-up.

---

### OQ-8: Verifier mismatch burns the one-time code — confirm?
**Context**: The exchange consumes the code atomically before checking the PKCE verifier, so a
mismatched verifier leaves the code unusable.
**Options considered**:
- A) Consume-first — code burned on any exchange attempt.
- B) Transactional verify-then-consume — code survives verifier mismatches (kinder to buggy clients,
  but gives a code thief unlimited verifier guesses within the 5-minute window).

**Decision**: **A — consume-first; any exchange attempt burns the code.** Matches OAuth 2.0 Security
BCP (a failed attempt means the code may be in an attacker's hands) and the "code entropy + single-use
are the only brute-force defenses" posture. A wrong-verifier CLI bug failing loudly is desired.

---

### `code_challenge` format is not validated at entry
**Context**: Entry validation only required a non-empty string; an S256 challenge is by definition
exactly 43 base64url characters. Accepting arbitrary strings means junk grants and a confusing
exchange-time 400 instead of a clear entry-time error.
**Decision**: Added `validate_code_challenge/1` (`~r/^[A-Za-z0-9_-]{43}$/`) to the entry-validation
chain, with a malformed-challenge entry-validation test.

---

### `authorize_or_reject` crashes on an unexpected grant-insert failure
**Context**: A hard `{:ok, ...} =` match on `create_auth_grant` turns a changeset error (e.g. under a
DB outage) into a `MatchError` and a raw 500 mid-login.
**Decision**: `authorize_or_reject` now cases on the insert result and renders the existing CLI error
page on `{:error, _changeset}`.

---

### Pagination retrofit — the promised `handle_params` fallback clause is missing from the code block
**Context**: The step's prose referenced a catch-all `handle_params` clause the code block didn't
define.
**Decision**: The defensive fallback clause is now in the code block (with a clarifying comment) and
the stale prose note was removed.

---

### Unhandled API exceptions render Phoenix's `ErrorJSON` shape, not the contract's `SERVER_ERROR` shape
**Context**: Any raise inside `/api/v1` is rendered by the endpoint's `render_errors` fallback
(`ReportServerWeb.ErrorJSON`, `{"errors": {"detail": ...}}`), the exact shape the contract differs
from — but the requirements pin "**All** 500-class API failures use `SERVER_ERROR`".
**Options considered**:
- Exception rendering via a path-keyed `ErrorJSON` clause.
- `Plug.ErrorHandler` in the pipeline.

**Decision**: Exception rendering via a path-keyed `ErrorJSON` clause emitting
`{"error": "SERVER_ERROR", "message": "An internal error occurred."}`.

---

### The exception-rendering fix only works when the client sends `Accept: application/json` — Go's default client doesn't
**Context**: The path-keyed `ErrorJSON` clause fires only if json was negotiated. For failures before
a route's `:accepts` plug (`Phoenix.Router.NoRouteError` on an unknown `/api/v1` path;
`Plug.Parsers.ParseError` on a malformed JSON body), Phoenix negotiates from the `Accept` header
(html-first, and no header falls back to HTML). Go's `net/http` sends no `Accept` header by default.
**Decision**: (a) Added a `FallbackController` + an `:api`-piped catch-all `/api/v1` scope (kept
below every real route) so header-less clients get the contract 404 and `NoRouteError` never fires;
(b) the pre-router `ParseError` cannot be fixed by routing — documented that the contract shape for
malformed-body failures requires `Accept: application/json`, made a STORY 4 CLI obligation.

---

### `page_token` carrying an out-of-int64 integer crashes the list query — 500 in the wrong shape
**Context**: `parse_page_token` did only `Base.url_decode64` + `Integer.parse` (no bounds check,
unlike `parse_id`); MyXQL's binary encoder has no fallback clause and raises `FunctionClauseError`
on a value >= 2^64, propagating to the default `ErrorJSON` — a 500 where the contract mandates 400.
Remotely triggerable by any token holder.
**Decision**: `parse_page_token` gained the same bounds check as `parse_id` (share `@max_bigint`,
reject non-positive), returning `{:error, "page_token is not valid"}` -> 400. Oversized-token test
added.

---

### Web-audit tests: "stubbed `:athena_db`" but the retrofitted LiveView calls `AthenaDB.get_download_url/2` directly
**Context**: Both web retrofits hardcoded `AthenaDB.get_download_url(...)` with no `athena_db()`
seam, so the stub was inert (the offline ExAws presign returns a real signed URL) and the web
presign-failure fail-closed branch was untestable.
**Decision**: Route both web presign calls through the same `athena_db()` config seam used everywhere
else (one line each).

---

### Show-page tests with succeeded runs collide with the un-stubbed PostProcessing `JobServer`
**Context**: A succeeded `:athena` run with a stepped report type boots the `JobServer`, which reads
the `:output` config (only added in a later step) and makes a real S3 attempt — crashing the
AthenaRunOps smoke test and leaving jobs unseedable at the web-audit step.
**Decision**: (a) Move the `:output` test config into the AthenaRunOps step and/or pin the
succeeded-state smoke case to a steps-less slug (`teacher-actions` / `student-assignment-usage`);
(b) for the post-processing audit test, seed jobs via the `{:jobs, query_id, jobs}` message the Show
LiveView already forwards, or route `read_jobs_file` through the `:aws_file_store` seam.

---

### The "force an audit-write failure" tests have no workable forcing mechanism
**Context**: The API download test forced audit failure via a "deleted user row" edge that is doubly
unreachable (FK RESTRICT blocks the DELETE; a raw `Repo.insert` raises `Ecto.ConstraintError` rather
than returning `{:error, :audit, _}` unless the changeset declares the constraint).
**Decision**: Declare `foreign_key_constraint(:user_id)` / `foreign_key_constraint(:report_run_id)`
in the changeset; force unit-level failure via an invalid `source`/`data_type` (inclusion
validation); scope the HTTP-level negative path to the presign half (documented in the relevant
steps).

---

### Removing `/api/v1/ping` breaks `auth_plug_test.exs`, which the runs step doesn't touch
**Context**: The pipeline step's auth tests exercise `GET /api/v1/ping`; the runs step deletes that
route but omits `auth_plug_test.exs` from its files-affected list — a broken intermediate commit.
**Decision**: Add "retarget `auth_plug_test.exs` to `GET /api/v1/reports`" to the runs step's
files-affected list (assertions port unchanged).

---

### Coverage gap — `/download` self-start (nil `athena_query_id`) is never exercised
**Context**: The requirements pin self-start on both `GET /:id` and `/:id/download`, but the test
lists covered it only on show — a controller calling `ensure_current` only in `show` would pass every
test while violating the requirement on the endpoint the CLI blocks on.
**Decision**: Add one download test: persisted run with `athena_query_id: nil` + stubbed tree/athena
-> 409 with the new state and the run row gained an `athena_query_id`; optionally the start-failure
twin.

---

### Valid-`portal` tests depend on `<SERVER>_DB` env vars and fixture `portal_server` alignment
**Context**: `validate_portal` reads `System.get_env("<SERVER>_DB")` at call time (unset in the test
env), and the happy-path test's session user must have `portal_server` matching the requested portal,
which the fixture default doesn't.
**Decision**: Add a test-notes line to the step: set a fake `<SERVER>_DB` env var in setup for
valid-portal cases (with `on_exit` cleanup), and derive the session user's `portal_server` via
`get_server_for_portal_url/1`.

---

### The "two concurrent Tasks" atomic-exchange test cannot produce real DB concurrency under the shared sandbox
**Context**: The shared Ecto sandbox funnels every process through the owner's single connection
(only PostgreSQL supports truly concurrent sandbox tests), so the two Tasks' `update_all` calls
serialize — the test re-proves single-use, not race-safety.
**Decision**: Keep the test but note in the plan that atomicity is guaranteed by construction
(conditional `UPDATE` returning `{1, _}`), which the sequential second-exchange-fails test already
locks in — don't present the Task test as race-proof.

---

### `Tree.athena_report_slugs/0` rebuilds the whole report tree on every call
**Context**: As written it called private `get_tree()`, reconstructing every group/report struct on
every API list/show/download/jobs request. The tree is static and already ETS-cached at startup.
**Decision**: `athena_report_slugs/0` now walks `root()` (the cached tree) — same one-line body with
no per-request reconstruction. (Hygiene, not a hotspot.)

---

### Audit-log timestamp cell renders a raw `DateTime`
**Context**: `<%= entry.inserted_at %>` renders Elixir's default `DateTime` string; the audit log
needs absolute, semantic times for assistive tech and machine readers.
**Decision**: The template renders `<time datetime={ISO 8601}>%Y-%m-%d %H:%M UTC</time>`, with a
rendered-HTML assertion added to the audit-page tests.

---

### `DataAccessLogEntry` schema timestamps type is not pinned — the audit page 500s if the schema omits `type: :utc_datetime`
**Context**: Ecto schema `timestamps()` default to `:naive_datetime` regardless of the migration
column type; the audit-page template calls `DateTime.to_iso8601(entry.inserted_at)`, which raises on
a `NaiveDateTime`.
**Decision**: Pin `timestamps(type: :utc_datetime, updated_at: false)` in the `data_access_log`
schema and add `type: :utc_datetime` to the `AuthGrant` schema for consistency.

---

### The hooks file is `assets/js/app.ts` (TypeScript), not `app.js` — and the hook must be added inside the `Hooks` literal
**Context**: The cli-token step named `app.js` and used post-hoc assignment; the actual bundle entry
is `app.ts` where `Hooks` is a `const` object literal, and post-hoc assignment is a TypeScript type
error.
**Decision**: Correct the files-affected entry to `assets/js/app.ts` and frame the `CopyToClipboard`
hook as an entry inside the existing `const Hooks = {...}` literal.

---

### The Show smoke test's mount-start case stubs `:athena_db` but not `:report_tree`
**Context**: Mount-start runs the real `get_query` (needs a portal DB with `<SERVER>_DB` set), so the
"run gains an `athena_query_id`" assertion fails without a `:report_tree` stub.
**Decision**: Add the `:report_tree` stub to the mount-start case (canned report whose `get_query`
returns a real `%ReportQuery{}`), keeping the run's real Athena `report_slug` so Show's own
un-seamed `Tree.find_report/1` still resolves. The poll-refresh case needs only the `:athena_db` stub.

---

### API self-start stampede — a 1s-polling CLI can stack concurrent 5-minute portal queries
**Context**: Self-start runs `report.get_query` (a 300s-timeout portal MySQL query + S3 upload)
inline in the request; while the first is in flight `athena_query_id` is still nil, so every ~1s poll
starts another — the accepted "one wasted duplicate query" race becomes a pool-saturating stampede.
**Decision**: Make API self-start single-flight — claim the run first with an atomic conditional
`update_all` (on `id == ^id and is_nil(athena_query_id) and is_nil(athena_query_state)`, set state
`"queued"`); losers serve stored state (existing start-failure behavior; reset on failure so the next
poll retries).

---

### `touch_api_token` per-request UPDATE — adopt a freshness threshold
**Context**: `DateTime.utc_now(:second)` dedupes within the same second, but a 1s poll loop lands in a
new second each time — one MySQL row UPDATE per poll per active CLI, binlog churn for a value STORY 2
reads at "used recently" granularity.
**Decision**: Adopt a 60s freshness threshold — skip the touch when `last_used_at` is within 60s of
now.

---

### `list_entries_paginated/1` has no code block, and the audit template dereferences `entry.user.*`
**Context**: Ecto doesn't lazy-load; without `preload: [:user]` the audit page crashes on
`%Ecto.Association.NotLoaded{}`, and the naive per-row fix is an N+1.
**Decision**: Pin the one-liner:
`from(e in DataAccessLogEntry, order_by: [desc: e.inserted_at], preload: [:user]) |> Pagination.paginate(page)`.

---

### `list_api_report_runs/3` preloads `:user` for no consumer
**Context**: The list endpoint serves stored state only and `run_json/1` reads no user fields; every
listed run belongs to `current_user` (already loaded) — one wasted SELECT per list request.
(`get_api_report_run/2`'s preload IS load-bearing — `start_query` passes `report_run.user`.)
**Decision**: Drop `preload: [:user]` from the list query only.

---

### No production migration mechanism exists — and this release makes existing web downloads hard-depend on a new table
**Context**: There is no `ReportServer.Release` migrator, and the runner image has no `mix`;
deployment is a manual CloudFormation image update with no migration step. Every existing web download
now routes through fail-closed `AuditLog.issue_download_url`, so deploying the image before the
`data_access_log` migration breaks the primary existing export path.
**Decision**: Include the standard phx.gen.release `ReportServer.Release` migrator module in this
story (a new first step) so the container can run
`bin/report_server eval "ReportServer.Release.migrate"`, plus a README deploy note (apply the three
migrations before updating the stack image). De-risks STORY 2/3 too.

---

### `data_access_log` FKs make audited runs and users permanently undeletable — an undocumented one-way door
**Context**: `on_delete: :nothing` is RESTRICT on MySQL; with indefinite retention, any audited run
pins its `report_runs`/`users` rows forever, and manual DB cleanup will fail with FK errors.
**Decision**: **Keep the FKs** and document the choice as a deliberate one-way door (audited rows pin
their run/user rows; deletion tooling must handle the audit table first). Chosen over dropping the FKs
in favor of plain ids.

---

### `filter_parameters` is mislabeled "compile-time", and substring matching will redact `page_token`
**Context**: `Phoenix.Logger.filter_values/2` reads the config at call time; the "compile-time"
label invites wrong inferences. Discard-mode matching is `String.contains?`, so `"token"` also
redacts the harmless `page_token` query param.
**Decision**: Reword to "runtime-read config (baked into the release's `sys.config`)" and add a
one-line note about the `page_token` redaction side effect (acceptable as-is).

---

### `bg-orange text-white` fails AA contrast (3.12:1) on all three new surfaces
**Context**: `orange` is `#ea6d2f`; white on it is 3.12:1 vs the 4.5:1 threshold for the 14px text
used here, and the hover pair is 2.60:1. Affected: the pager's active page number and the cli-token
Generate/Copy buttons. The requirements promise WCAG AA for the new UI.
**Decision**: Use a darker orange for text-on-orange in the new surfaces — a new `dark-orange`
`#c14d10` token (4.84:1 vs white, verified); fix the hover pair the same way.

---

### Audit-table `text-zinc-500` dips below AA on the `bg-gray-100` header and hovered rows
**Context**: zinc-500 on gray-100 = 4.39:1 (header); on zinc-200 (hovered slug span) = 3.81:1.
**Decision**: Use `text-zinc-600` (>=7:1 on gray-100, >=5:1 on zinc-200) for the thead and slug span;
optionally retrofit `report_runs/1` to match.

---

### `aria-disabled="true"` on a plain `<span>` is invalid ARIA
**Context**: `aria-disabled` isn't permitted on the `generic` role a bare span has; validators flag it
and screen readers ignore it.
**Decision**: Drop the attribute (a non-focusable span reading "Previous" as plain text is fine), or
omit the boundary items entirely.

---

### Bare page-number link text and unlabeled Previous/Next give weak screen-reader context
**Context**: A SR links list reads "1, 3, 4, 5, 20" with no page semantics; "Previous"/"Next" don't
say previous what outside the landmark.
**Decision**: Add `aria-label={"Page #{item}"}` on number links and `aria-label="Previous page"` /
`"Next page"` on the endpoints (or `sr-only` suffixes).

---

### The copy-confirmation live region won't re-announce on repeat clicks
**Context**: The hook sets the same `textContent` every click; several SR/browser pairs deduplicate
identical live-region content, so the "did it actually copy?" second click produces silence.
**Decision**: Clear the region then set the message (`textContent = ""` then set inside a short
`setTimeout`) — one extra line in the hook.

---

### The label input's focus indicator is a 1.73:1 border-shade shift
**Context**: The default `.input` clause removes the ring and shifts border zinc-300->zinc-400 on
focus, a near-invisible 1.73:1 change (SC 2.4.7).
**Decision**: Keep a visible ring on this input — add `focus:ring-2` with an accessible ring color
(`focus:ring-teal`, 3.66:1).

---

### Concurrent self-start losers returned stale state
**Context**: If two API requests loaded the same nil/nil run before the atomic claim, the loser got
`{0, _}` from `Repo.update_all` and returned its stale pre-claim struct — so show/download could
respond `athena_query_state: null` while the stored row was already `"queued"`, contradicting the
concurrent-polls-serve-stored-state clause.
**Decision**: The `{0, _}` losing branch now returns `%{report_run | athena_query_state: "queued"}`
(a truthful lower bound, self-correcting on the next poll). Chosen over a DB reload (no extra query,
no preload bookkeeping).

---

### Nil `report_filter` violated the stable API response contract
**Context**: The serializer's `report_filter_json(nil)` emitted `report_filter: null`, but the
contract pins `report_filter` as an all-fields-present object. Nil-filter rows are schema-legal and
API-visible.
**Decision**: Nil filters serialize as the empty filter (`report_filter_json(nil)` delegates to
`report_filter_json(%ReportFilter{})`), whose defaults produce exactly the all-fields-present shape.
Chosen over migration/backfill/validation.

---

### `AuthGrant` schema did not pin the `:user` association
**Context**: The step described the schema as "mirrors the table", but `exchange_auth_grant/2` runs
`preload: [:user]` and reads `auth_grant.user`; Ecto doesn't infer associations from the migration FK,
so the exchange's success path would crash.
**Decision**: The `Accounts.AuthGrant` schema is now pinned in full (`belongs_to :user`,
`:utc_datetime` timestamps/datetime fields, changeset with `unique_constraint(:code_hash)`).

---

### `DataAccessLogEntry` schema did not pin the load-bearing `:user` association
**Context**: Same defect: the audit page runs `preload: [:user]` and dereferences `entry.user.*`, but
the schema was described only as "a straightforward mirror of the table".
**Decision**: The `AuditLog.DataAccessLogEntry` schema is pinned in full: all fields,
`belongs_to :user`, `belongs_to :report_run` (adopted for FK symmetry), the `:utc_datetime`
timestamps pin, and the existing changeset folded in.

---

### JSON error contract was overstated for explicit non-JSON `Accept` headers
**Context**: `plug :accepts, ["json"]` raises `Phoenix.NotAcceptableError` on an explicit non-JSON
`Accept` header before the auth plug or catch-all runs, and with `render_errors` listing html before
json, `Accept: text/html` produced an HTML 406 instead of the contract shape. The "regardless" claim
held for missing `Accept` headers only.
**Decision**: Force JSON — both API pipelines replace `plug :accepts, ["json"]` with `plug
:force_json` (`put_format(conn, "json")` unconditionally), making `NotAcceptableError` impossible on
`/api/v1`. Safe because the existing `:api` pipeline is unused today. The requirements Contract bullet
was rewritten ("the API ignores `Accept` and always speaks JSON"), with the pre-router malformed-body
`ParseError` the sole documented exception.

---

### `/auth/cli/token` accepted query-string secrets despite the body-only contract
**Context**: The token action pattern-matched Phoenix's merged `conn.params`, so
`POST /auth/cli/token?code=...&code_verifier=...` satisfied the exchange — putting the code/verifier
in access/proxy log URL lines, which `filter_parameters` cannot redact.
**Decision**: The action now reads `conn.body_params` exclusively and rejects any request carrying
`code` or `code_verifier` in `conn.query_params` before the exchange runs (a query-string attempt
does not consume the grant), rendering the standard indistinguishable 400.

---

### Pagination snippets called `Pagination` without aliasing `ReportServer.Pagination`
**Context**: Three snippets (`Reports` context, `ReportRunLive.Index`, `AuditLog` context) called
`Pagination.paginate/2` bare, resolving to a non-existent top-level module at runtime.
**Decision**: Explicit `alias ReportServer.Pagination` added at all three snippets.

---

### Post-processing audit-write failure lacked the required LiveView error flash
**Context**: The fail-closed bullet distinguishes presign failure (preserved nil-reply, compliant)
from audit-write failure (LiveView error flash), but the post-processing handler collapsed both to
`nil` and wrongly claimed compliance.
**Decision**: The handler's `{:error, :audit, _}` branch now sends `{:put_flash, :error, msg}` to the
parent (a LiveComponent's own `put_flash` never renders in the parent layout) and `Show` gains the
matching `handle_info` clause; presign failure keeps the existing nil-reply path.

---

### `redirect_uri` validation accepted non-literal or invalid loopback URIs
**Context**: Dynamic verification showed `http://evil@127.0.0.1:123/callback` passed (userinfo
ignored), `:0`/`:99999` passed (invalid ports), and `:-1` passed with the port silently defaulting to
80 — while the requirements pin the exact form `http://127.0.0.1:<port>/callback`.
**Decision**: The validator additionally requires `uri.userinfo == nil`, `uri.port in 1..65535`, and
`uri.authority == "127.0.0.1:#{uri.port}"` (one check killing userinfo, malformed-authority/port, and
portless cases). Entry-validation tests added for each variant.

---

### `portal` validation accepted non-origin URLs and reused them raw as the OAuth site
**Context**: `validate_portal/2` checked only the host-derived DB mapping and returned the raw
`portal_url`; `get_server_for_portal_url/1` keys on the host alone, so `ftp://...`,
`https://learn.concord.org/evil`, and `https://evil@learn.concord.org` all passed and then flowed
verbatim into the OAuth `site`, producing broken or phishing-shaped external redirects. Same bug class
as the `redirect_uri` finding, on the other URL parameter of the same endpoint.
**Decision**: `validate_portal/2` normalizes before the DB check: `https` only, no
userinfo/query/fragment, path `nil` or `/`, port in `1..65535` with the same literal-authority check,
and the **rebuilt canonical origin** (`https://host[:port]`, explicit `:443` and trailing `/`
collapsed) — never the raw input — flows into the DB check, the stored auth request/grant, and
`get_authorize_url/1`. The requirements Portal-selection bullet now pins the https-origin shape and
normalization. `Auth.Plug`'s raw `?portal=` session stash (manual browser logins) is unchanged and out
of scope.
