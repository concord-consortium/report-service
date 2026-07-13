# cc-data: Authenticated JSON API + Auth Foundation

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-74
**Repo**: https://github.com/concord-consortium/report-service
**Design doc**: `/home/doug/tmp/cc-data-app.md` (published as [gist](https://gist.github.com/dougmartin/034b3004e9cd42f6e9960a478358d622), linked from REPORT-71)
**Implementation Spec**: [implementation.md](implementation.md)
**Status**: **In Development**

## Overview

Add a per-user bearer-token auth system and an authenticated JSON API (`/api/v1/reports...`) to the
Elixir report server, so the future `cc-data` researcher CLI can list report runs and download their
CSVs without going through the LiveView UI. Includes audit logging of data access from day one.

## Project Owner Overview

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

## Background

The report server (`server/`, Phoenix 1.7 + LiveView) currently has **no JSON API at all** — the
router declares a bare `:api` pipeline (`plug :accepts, ["json"]` — `router.ex:24-27`) but nothing
routes through it. All access is via LiveView behind a session cookie populated by the portal OAuth
implicit flow (`AuthController` + `AuthLive.Callback` + `/auth/save_token`).

The machinery the API needs already exists internally:

- **Users** are real local rows (`ReportServer.Accounts.User`, identity = `portal_server` +
  `portal_user_id`); `report_runs.user_id` references `users.id`.
- **Run listing scoped to a user** exists as `Reports.list_user_report_runs/2` (backs the
  `/reports/runs` `:my_runs` LiveView).
- **Presigned CSV URLs** are already minted by `AthenaDB.get_download_url/2` (10-minute expiry,
  `attachment` content-disposition) from the run's `athena_result_url`.

This story exposes that machinery through an authenticated JSON API:

1. **Per-user token model** — non-expiring, revocable bearer tokens issued by the report server
   (the portal OAuth flow stays server-side; the server is the auth broker). Tokens are per-user,
   and since users are keyed by portal, "one token per portal" falls out naturally on the CLI side.
2. **Login handoff** — two paths that mint the *same* token:
   - **Loopback flow**: an `/auth/cli` controller flow using a one-time code + PKCE +
     `state` nonce; the final hop is a **plain controller redirect** to the CLI's
     `127.0.0.1:<port>/callback` listener (not LiveView). The CLI listener half is built in
     STORY 4; this story builds the server side.
   - **Manual fallback**: a LiveView route (e.g. `/reports/cli-token`) that shows the token once
     for `cc-data login --token <paste>`.
3. **API v1** — `:api_authenticated` pipeline + five endpoints (run list / show / download, plus
   post-processing job list / job download) with strict per-endpoint ownership authz.
4. **Audit logging** — a `data_access_log` table written on every download-URL issuance, with a
   schema that must also accommodate STORY 3's per-page answers/history access events.

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
  tokens **and one-time
  codes** are generated with a cryptographically secure RNG with sufficient entropy (with rate
  limiting out of scope for v1, code entropy is the only brute-force defense during the 5-minute
  code window); tokens and one-time codes must never appear in server logs or error messages.

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
  origin** (`https://host[:port]` — no userinfo, path, query, or fragment; External Review
  Round 4: the server mapping keys on the parsed host alone, and the value is reused as the
  OAuth site, so non-origin inputs like `https://learn.concord.org/evil` would pass a
  host-only check and then produce broken or unsafe external login redirects), and it must
  resolve via the existing portal→server mapping (`PortalDbs.get_server_for_portal_url/1`) to
  a portal with a configured portal-DB connection — an invalid `portal` is an entry-validation
  failure (error at `/auth/cli`, no redirect, no code; see the failure clause below). When
  valid, the **normalized origin** (not the raw input) is what is preserved
  across the login round trip with the rest of the request state and is the portal the login and
  token are scoped to, **overriding any session portal** — if an existing session user's
  `portal_server` does not match the requested portal, `/auth/cli` runs the portal login against
  the requested portal rather than reusing the session. **Fallback when omitted**: existing
  browser behavior — the session's portal if set, else the configured default portal.
- **Request-state preservation and `state` echo**: `/auth/cli` validates `redirect_uri`, `state`,
  `code_challenge`, and (when present) `portal` **on entry**, and when a portal login round trip
  is needed, the validated request state must survive it — stored server-side before redirecting
  to login, or carried as an encoded full `/auth/cli` request URI in `return_to` (mechanism is an
  implementation.md decision); after login the flow resumes with the original validated values. The final redirect
  to the loopback carries **both** the one-time `code` and the original `state` echoed verbatim —
  the CLI correlates the callback to its login attempt via `state` (the listener half is STORY 4,
  but the echo is this story's server-contract obligation). A **failed entry validation**
  (non-loopback `redirect_uri`, missing `state` or `code_challenge`, non-S256 PKCE method, or an
  invalid `portal` per the Portal selection bullet)
  renders an error response at `/auth/cli` itself — never a redirect to the supplied
  `redirect_uri`, and no one-time code is minted (per RFC 6749 §3.1.2.4: never redirect to an
  unvalidated redirect URI).
- **Code-exchange endpoint contract**: **`POST /auth/cli/token`** with JSON body
  `{ "code": "<one-time code>", "code_verifier": "<PKCE verifier>" }`. It is a direct CLI→server
  call — no session or cookies (routed through the `:api` pipeline, not `:browser`, so no CSRF
  involvement). Success: `200` with `{ "token": "<bearer token>" }` (additional fields may be
  added later within v1, additive-only); the exchange is the **mint point** — the token is
  created here, not at `/auth/cli` (see the Loopback flow bullet). Failure: the standard API error shape; an unknown,
  expired, or already-used code and a PKCE verifier mismatch all return a single
  indistinguishable **400 `BAD_REQUEST`** — no distinct responses that would let a caller probe
  whether a guessed code exists or only its verifier failed. Single-use enforcement is
  **atomic**: exactly one exchange of a given code can ever succeed — concurrent duplicate
  exchanges must not both mint a token; the loser gets the same indistinguishable 400. The code/verifier travel in the POST
  body (never the query string) so they stay out of URL logs; both param names fall under the
  `filter_parameters` log-hygiene obligation (see Technical Notes).
- The `/auth/cli` flow refuses to mint for users who fail `can_access_reports?` — it fails at
  login with a clear message (e.g. "you don't have report access") rather than handing out a
  token the API's role gate would reject on every request. (The manual page is already covered:
  it lives in the `:reports` live_session, which enforces the same gate at mount.)
- One-time codes **expire 5 minutes after issuance** and are single-use (invalid after the first
  successful exchange); an expired or already-used code fails the exchange with the same
  indistinguishable **400 `BAD_REQUEST`** as an unknown code (see the exchange-endpoint contract).
  The real token never appears in browser history.
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
  || project researcher) on the token's resolved user — matching the gate every web report surface
  applies at mount. A valid token whose user fails the check gets **401 `NOT_AUTHENTICATED`**,
  indistinguishable from a bad token (no distinct code, so role state isn't leaked).
- `GET /api/v1/reports` — list the caller's report runs (`report_runs.user_id == caller`),
  **keyset-paginated** (`WHERE id < ? ORDER BY id DESC LIMIT n`; last id encoded into
  `next_page_token`). List scope = runs you authored.
- **Athena-backed runs only**: non-Athena (portal/MySQL usage-report) runs are excluded from the
  API entirely — not listed, and `/:id` / `/:id/download` treat them as not-found. Portal reports
  are about portal usage, not student data.
- **Classification is by report type, not artifact presence**: a run is API-visible iff its
  `report_slug` resolves to an Athena-type report definition, regardless of query state. A
  queued/running Athena run appears in list/show with its current `athena_query_state` — the CLI
  polls exactly this. State only gates `/download`.
- `GET /api/v1/reports/:id` — one run's metadata + `athena_query_state`.
- **State freshness**: the stored `athena_query_state` only advances while the run's LiveView
  Show page is open in a browser (its poll loop is the sole writer today), so the API must not
  serve it blindly. On `GET /:id` and `/:id/download`, when the run has an `athena_query_id` and
  a non-terminal stored state (null/queued/running), the server refreshes from Athena
  (`AthenaDB.get_query_info/1`) and persists **both** fields the call returns —
  `athena_query_state` AND `athena_result_url` — before responding (mirroring the LiveView poll,
  `show.ex:233`), so a run refreshed to `succeeded` is immediately downloadable. List responses
  serve stored state as-is (no per-run Athena calls; the CLI polls show, not list). If the Athena
  refresh fails (e.g. transient AWS error/throttling), the endpoint serves the **stored** state
  and logs the failure server-side — the CLI polling loop survives transient errors rather than
  seeing 500s.
- **Not-yet-started runs self-start**: an Athena-type run can exist with
  `athena_query_id == nil` — the web form only creates the `report_runs` row; the Athena query is
  started later by the run's Show LiveView on mount (`form.ex:226`, `show.ex:168`) — so an
  interrupted redirect leaves a run that would otherwise never progress. On `GET /:id` and
  `/:id/download`, when an Athena-type run has `athena_query_id == nil`, the server **starts the
  Athena query** via the same path the Show LiveView uses (build the query from the stored
  `report_filter` → `AthenaDB.query` → persist `athena_query_id` + `athena_query_state`) before
  responding. If the start fails, the endpoint serves the stored state (`null`) and logs the
  failure server-side — the next poll retries, mirroring the refresh-failure clause. List never
  starts queries. **Duplicate API requests are single-flight** (tightened in implementation
  Self-Review Round 3): the query build is a minutes-long portal query + S3 upload and the CLI
  polls ~1s, so the API claims a run atomically before starting — concurrent API polls serve
  the stored state instead of stacking starts. The Show-mount-vs-API concurrent start remains a
  known, **accepted** race — same as today's two-browser-tab behavior; worst case is one wasted
  duplicate query of the same SQL, with the last-persisted id winning. Self-start must be covered
  by a test that starts from a **persisted** filtered run (a `report_filter` round-tripped
  through the DB, not an in-memory struct) — the loaded filter differs from the freshly built one
  (see the `EctoReportFilter.load/1` caveat in Technical Notes), and the test locks in that the
  self-start path works on the loaded form.
- `GET /api/v1/reports/:id/download` — mint a **fresh** presigned CSV URL (reusing
  `AthenaDB.get_download_url/2`); **409 `NOT_READY`** for every non-succeeded state
  (queued/running/failed/cancelled/nil), with the current `athena_query_state` in the error
  context — the CLI branches on the state (poll vs give up), not on distinct codes. A
  `succeeded` run with a null `athena_result_url` is a server invariant violation: 500-class
  error, logged server-side.
- `GET /api/v1/reports/:id/jobs` — list the run's **post-processing jobs** from the persisted
  jobs file (`s3://<output-bucket>/jobs/<athena_query_id>_jobs.json`). Each item is exactly
  `{ "id": <int>, "steps": [{ "id": "...", "label": "..." }], "status": "<status>",
  "has_result": <bool> }` — the persisted `result` S3 URL is mapped to the `has_result`
  boolean and is never serialized (see the no-raw-artifact-URLs Contract bullet). Runs with
  no jobs file (or no `athena_query_id`) return an empty list. Statuses are served **as persisted** — there is no
  job-liveness refresh (the web UI has the same property); no pagination (job counts per run are
  small): same envelope with `next_page_token` always null. Only a **missing** jobs file yields
  the empty list; any other S3 read failure is a 500-class error, logged server-side — a
  transient S3 error must never masquerade as "no jobs".
- `GET /api/v1/reports/:id/jobs/:job_id/download` — mint a **fresh** presigned URL for the job's
  result CSV (job results are S3 URLs presignable by the same `AthenaDB.get_download_url/2`);
  **409 `NOT_READY`** with the job `status` in the error context for any non-completed job
  (started/failed); **404 `NOT_FOUND`** for unknown or malformed `:job_id`, indistinguishable
  from a non-existent run. A `completed` job with a null `result` is a server invariant
  violation: 500-class error, logged server-side (mirroring the run-download clause). Issuance
  is audit-logged like every other download surface.
- **Job creation stays web-UI-only** — the API downloads post-processed outputs but cannot
  create jobs (consistent with the author-in-web / download-in-CLI scope boundary).
- **Per-endpoint authz**: every `/:id/*` endpoint requires `report_runs.user_id == caller` — a run
  id is guessable/shareable, so authz cannot be implicit. The download case is the sharp one: the
  CSV is a pre-generated Athena artifact built under the owner's permissions, so it is
  ownership-gated. **Strict ownership applies to admins too** (no `portal_is_admin` bypass, unlike
  the LiveView) — admins use the web UI for other users' runs.
- **No existence leaks**: non-existent, not-owned, and non-Athena run ids all return **404
  `NOT_FOUND`**, indistinguishable from each other. Syntactically invalid or out-of-bigint-range
  `:id` path params fall in the same 404 bucket (the default data layer raises
  `Ecto.Query.CastError` on them — the API must not surface that as a 500).
- Run metadata in list/show responses includes at minimum: id, `report_slug`, `report_filter`
  (raw ids), `report_filter_values` (resolved human labels, as stored on the run),
  `athena_query_state`, and timestamps — the CLI captures filter provenance from these responses.
  Run responses **never include `athena_result_url`** or any other raw storage URL (see the
  no-raw-artifact-URLs Contract bullet).

### Contract

- Unified paged envelope: `{ "items": [...], "next_page_token": "<opaque>" | null }`; `limit`
  query param in (default 50; numeric values clamped into `[1, 200]`; non-integer `limit` or
  otherwise malformed query params → **400 `BAD_REQUEST`**); the token is opaque — clients never
  interpret it.
- **Page-token request parameter is `page_token`**:
  `GET /api/v1/reports?limit=50&page_token=<opaque>` — clients echo the previous response's
  `next_page_token` value back as `page_token` (request `page_token` / response
  `next_page_token`, per the common AIP-158 convention). A malformed/undecodable `page_token`
  returns **400 `BAD_REQUEST`** in the standard error shape. There is no expired/unknown-token
  state by design: with keyset pagination any decodable token is a valid `WHERE id < ?` bound
  even if the referenced run was since deleted — the query simply returns the correct next page.
- **Download success shape** (both `/download` endpoints, same shape): **200**
  `{ "download_url": "<presigned https URL>", "filename": "...", "expires_in_seconds": 600 }` —
  a bare object, not the paged envelope. `filename` is the server's suggested name, following
  the existing web conventions (run: `<report_slug>-run-<id>.csv`; job:
  `<report_slug>-run-<run_id>-job-<job_id>.csv` — see Technical Notes). `expires_in_seconds`
  reports the presign expiry (currently 600, from `AthenaDB.get_download_url/2`) so the CLI
  never hardcodes the window. Evolution within v1 is additive-only, like the code-exchange
  response.
- **No raw artifact URLs outside `/download`**: list, show, and jobs responses never contain
  raw storage URLs (`athena_result_url`, job `result`, or any other `s3://` location).
  Presigned URLs are issued **only** by the two `/download` endpoints — that is what makes
  every URL issuance audit-logged.
- Timestamps serialize as **ISO 8601 UTC strings**.
- **`report_filter` serialization**: a JSON object with **all fields always present** (stable
  shape — no absent-vs-null ambiguity):
  - `"filters"`: array of filter-type strings, in stored order (stored order is right-to-left
    processing order — served as stored, not reversed);
  - `"cohort"`, `"school"`, `"teacher"`, `"assignment"`, `"class"`, `"student"`,
    `"permission_form"`, `"country"`, `"subject_area"`: arrays of integer ids, or `null` when
    unset;
  - `"state"`: array of strings (e.g. `"CA"`), or `null` when unset;
  - `"start_date"`, `"end_date"`: strings as stored, with empty string normalized to `null`;
  - `"hide_names"`, `"exclude_internal"`: booleans.
  A run stored with **no** `report_filter` (nil is schema-legal — the changeset requires only
  `user_id`/`report_slug`) serializes as the **empty filter** in this same all-fields-present
  shape (`filters: []`, dimensions/`state`/dates `null`, booleans `false`) — `report_filter` is
  never JSON `null` (External Review of the implementation spec, Round 1).
- **`report_filter_values` serialization**: served as stored — an object keyed by filter type
  whose id keys become **JSON strings** (JSON has no integer keys), e.g.
  `{"class": {"254": "Ms. Smith (period3)"}}`; clients must expect string keys.
- `athena_query_state` in responses is one of: `null`, `"queued"`, `"running"`, `"succeeded"`,
  `"failed"`, `"cancelled"` (Athena's states, lowercased) — the CLI branches on these values.
- Post-processing job `status` in responses is one of: `"started"`, `"completed"`, `"failed"`
  (the values persisted in the jobs file) — only `"completed"` jobs are downloadable.
- `Authorization: Bearer <token>` on every request; unauthenticated requests get **401** with a
  single-line JSON error body `{ "error": "NOT_AUTHENTICATED", ... }`.
- One error shape everywhere: `{ "error": "<CODE>", "message": "...", ...context }` with v1 codes
  `NOT_AUTHENTICATED` (401), `NOT_FOUND` (404), `NOT_READY` (409), `BAD_REQUEST` (400),
  `SERVER_ERROR` (500). (No `FORBIDDEN` in v1 — ownership failures are 404 by design; STORY 3 may
  reintroduce it.)
- **All 500-class API failures use the single code `SERVER_ERROR`** — invariant violations
  (succeeded run / completed job with a null artifact URL), non-missing S3 read failures,
  audit-write failures, and any other internal error render
  `{ "error": "SERVER_ERROR", "message": "..." }`. One code by design: the CLI can't act
  differently on internal failure modes, and distinct codes would leak them. The distinction lives
  in server-side logs. The message/context carries **safe content only** — no exception details,
  stack traces, S3 URLs, or secrets.
- **The API ignores `Accept` and always speaks JSON**: the `/api/v1` pipelines force the json
  format unconditionally rather than negotiating it (External Review of the implementation
  spec, Round 2: `plug :accepts, ["json"]` raises `Phoenix.NotAcceptableError` on an explicit
  non-JSON `Accept` header before any controller or catch-all runs, and with `render_errors`
  listing html before json, an API request with `Accept: text/html` would have gotten an HTML
  406 instead of the contract shape). Routed API requests and unknown `/api/v1` paths
  therefore return the contract shape **regardless of the `Accept` header** — present, absent,
  or non-JSON. The one exception is request-body failures that occur before routing (a
  malformed JSON body raising in the **endpoint's** parser), which Phoenix's error renderer
  negotiates from the `Accept` header (falling back to **HTML** when it is absent) — so
  sending `Accept: application/json` on every request remains a STORY 4 CLI obligation,
  extending the contract-shape guarantee to malformed-body errors too.
- Path-versioned (`/api/v1/...`); the server stays backward-compatible within v1.

### Audit logging (from day one)

- Create the `data_access_log` table/migration AND log the CSV **URL-issuance** event on
  `/download` (mint ≠ download — log that access was granted).
- **Web-UI downloads are logged too**: the existing LiveView Athena download
  (`download_athena_report`) writes a `data_access_log` row on every successful URL-issuance,
  with an event/source value distinguishing web-UI issuance from API issuance. The row records
  the **requesting** user — who may be an admin downloading another user's run, the case the API
  refuses and therefore the one only the web path can produce. Portal (MySQL) report downloads
  stay unlogged (portal-usage data, not student data — consistent with the API-scope decision).
- **Post-processing result URL-issuance is logged too**: the run page's post-processing
  component mints presigned URLs for derived student-data CSVs (audio transcriptions, glossary
  data, merged answers — `post_processing.ex:176`) via both its "Download Result" and "Copy
  Result URL" buttons; every such issuance writes a `data_access_log` row through the same audit
  call, with a distinct data-type/event value identifying it as a post-processing artifact and
  recording the job id. API job-result downloads (`/:id/jobs/:job_id/download`) log the same
  post-processing event with the API source value.
- **Legacy `/old-reports` export path is disabled**: the `/old-reports` router scope
  (`router.ex:48-52`) is removed in this story rather than brought into the audit net, and
  replaced with a **redirect to `/reports`** using the existing backwards-compat pattern (the
  `/new-reports/*` scope already does exactly this via `RedirectToReports`, `router.ex:54-59`) —
  old bookmarks land on the current reports UI instead of a 404. That legacy LiveView mints
  presigned URLs for student-data CSVs — both original query results and post-processing job
  results (`old_report_live/query.ex:209-237`) — through a separate presign helper
  (`ReportServerWeb.Aws.get_presigned_url/3`), gated only by `Auth.logged_in?` (it sits outside
  the `:reports` live_session, so no `can_access_reports?` check) and with no `report_runs` row
  an audit record could reference. Its removal was long overdue; disabling the route closes the
  last unaudited student-data export surface. The `OldReportLive` modules may remain in the tree
  as unreachable code — deleting them is optional cleanup, not a requirement.
- **Audit writes are fail-closed, in a pinned order**: on every logged surface (API `/download`,
  web raw-CSV download, post-processing buttons), the sequence is: (1) **generate** the presigned
  URL first but do not return it — if presigning fails, take the surface's normal error path
  (API: 500-class `SERVER_ERROR`; LiveView: existing error handling) and write **no audit row**;
  (2) **write** the audit row — if the write fails, discard the generated URL and fail closed
  with a server error (API: 500-class; LiveView: error flash), no URL returned; (3) only after
  the audit write succeeds is the URL **returned/pushed**. Two invariants hold: every returned
  URL has an audit row, and every audit row corresponds to a URL that was actually generated.
- Each record: timestamp, requesting `user_id`, the `report_run` / filters, data type,
  page/cursor progress (null for CSV issuance), and a **nullable artifact-context field**
  carrying at minimum the post-processing job id for job-result issuance rows (null for plain
  CSV issuance; available to STORY 3 event types). Append-only; a retried page must be
  distinguishable from new access.
- The schema includes a **nullable resolved-endpoint-set field** (JSON column) for student-level
  auditability — null for CSV URL-issuance rows; STORY 3's per-page events fill it.
- **Documented limitation**: CSV audit rows are run+filter granularity. Student-level questions
  about a CSV export are answered via the **persisted S3 artifact** the run points to
  (`athena_result_url`) — the audit row supplies who/when/which run; the artifact is the literal
  exported content. Optional follow-up (with STORY 3): derive and log the endpoint set at CSV
  download time.
- The schema MUST accommodate STORY 3's per-page answers/history events, which reuse this table.
- This story also **decides**: log content resolution (resolved endpoint set vs hash), event
  types, retention, and who can read the log (the log is itself sensitive). See Open Questions.
- **Admin-only audit-log page**: an admin-only (`portal_is_admin`) LiveView page lists
  `data_access_log` events, **paginated**, newest first — columns: timestamp, requesting user,
  run id + report slug, data type/event. No filters in v1 (filters/student search come with
  STORY 3). Retention is indefinite (no cleanup job).

### Pagination (LiveView pages)

- Implement a **generic, reusable pagination method** for LiveView list pages:
  page-number/offset style with a classic pager UI (prev/next + page numbers).
- Use it for the new audit-log page AND **retrofit the existing run list pages** —
  `/reports/runs` (`:my_runs`) and `/reports/all-runs` (`:all_runs`) — which currently load all
  rows unpaginated.
- **Pager contract** (shared by all three pages):
  - **Page size**: fixed at **25** rows per page, not user-configurable in v1.
  - **URL semantics**: the current page lives in the URL query string as `?page=N`
    (`push_patch` navigation), so pages are bookmarkable/shareable and back/forward work;
    page 1 is the canonical no-param URL.
  - **Invalid input**: a non-integer or `< 1` `page` param is treated as page 1; a `page`
    beyond the last page **clamps to the last page**. No error state either way — the pager
    always renders the page actually shown.
  - **Empty list**: renders page 1 with the table's empty state; the pager is hidden whenever
    there is only one page (including zero rows).
  - Finer-grained details (page-number windowing/truncation for long pagers, component API)
    are implementation.md concerns.
- The JSON API keeps its separate keyset contract (different consumers, different mechanics).

### Accessibility (new UI surfaces)

- The pager is keyboard-operable, wrapped in a `<nav aria-label="pagination">` landmark, with
  `aria-current="page"` on the active page link.
- Data tables (audit log, run lists) use proper `<th>` header markup.
- The `/reports/cli-token` page renders the token as selectable text with an accessible
  copy-to-clipboard control, and announces "copied" via an ARIA live region.
- New UI follows the app's existing Tailwind styles and maintains WCAG AA color contrast. (No
  Zeplin designs exist for these internal pages; existing app styling is the intended path.)

## Technical Notes

- **Router / pipelines**: `server/lib/report_server_web/router.ex` — `:browser` pipeline uses
  `ReportServerWeb.Auth.Plug` (session-based, non-enforcing; enforcement is the
  `ReportServerWeb.ReportLive.Auth` `on_mount` in the `:reports` live_session). The `:api`
  pipeline (lines 24-27) is bare. No `/api` routes exist today.
- **Session auth**: `ReportServerWeb.Auth` — session holds portal `access_token`, `expires`, and
  the serialized `%Accounts.User{}`. `logged_in?/1` requires `expires > now + 3600`. The portal
  OAuth is the **implicit flow** (`PortalStrategy`, `response_type=token`): the token arrives in
  the URL fragment, read client-side by the `AuthLive.Callback` LiveView, then persisted into the
  session by the `/auth/save_token` **controller**. So `/auth/save_token` is the session-save hop
  of the browser flow — a useful controller-vs-LiveView precedent for `/auth/cli`, but not
  directly a token-minting flow.
- **Portal-selection machinery**: `Auth.Plug` calls `Auth.save_portal_url/1` on every `:browser`
  request (`auth/plug.ex:12`), stashing `conn.params["portal"]` into the session
  (`auth.ex:32-35`); `AuthController.login/2` reads it back via `Auth.get_portal_url/1` with the
  configured default portal as fallback (`auth_controller.ex:13`,
  `PortalStrategy.get_portal_url/0`). There is **no explicit portal allowlist** anywhere —
  validity is enforced only implicitly, because `save_token` must query the portal's DB, whose
  credentials come from a per-server env var (`<SERVER>_DB`, e.g. `LEARN_CONCORD_ORG_DB` —
  `portal_dbs.ex:185-192`). `/auth/cli`'s `portal` validation grounds on the same condition:
  mapped server (`get_server_for_portal_url/1`) has a configured DB connection.
- **`return_to` machinery stores a path-only string**: the LiveView auth hook builds `return_to`
  from `URI.parse(url) |> Map.get(:path)` (`report_live/auth.ex:23-25`), dropping the query
  string, and `AuthController.login`/`save_token` just round-trip whatever string is in the
  session (`auth_controller.ex:16`, `auth_controller.ex:32-39`) — nothing carries extra request
  params across the portal hop. `/auth/cli` must not inherit that pattern blindly; it must
  explicitly preserve its query params across the login round trip (see the Login handoff
  preservation requirement).
- **Users**: `ReportServer.Accounts.User` — `users` table, unique on
  `(portal_server, portal_user_id)`; role flags `portal_is_admin`, `portal_is_project_admin`,
  `portal_is_project_researcher` snapshotted from the portal at login
  (`Accounts.find_or_create_user/1` from `PortalDbs.get_user_info/2`).
- **Report runs**: `ReportServer.Reports.ReportRun` — `report_slug`, `report_filter` (custom Ecto
  type), `report_filter_values` (map), `athena_query_id`, `athena_query_state` (nil → "queued" /
  "running" → "succeeded" / "failed" / "cancelled"), `athena_result_url` (s3:// URL),
  `belongs_to :user`. `Reports.list_user_report_runs/2` is the existing my-runs query to reuse.
- **Download today**: `ReportRunLive.Show.download_athena_report/1` →
  `AthenaDB.get_download_url(athena_result_url, filename)` (ExAws presign, 10-min expiry,
  server credentials) → browser fetches S3 directly. Filename convention:
  `"#{report_slug}-run-#{id}.#{filetype}"`. **Note**: portal (MySQL) report runs have no
  `athena_result_url` — their download runs the query live in the LiveView
  (`download_portal_report/2`). **Resolved**: non-Athena runs are excluded from the API
  entirely — list, show, and download treat them as not-found (see resolved question).
- **LiveView show authz precedent**: `report_run.user_id == user.id || user.portal_is_admin`
  (`show.ex` `handle_params`). **Resolved**: the API is strict owner-only with no admin bypass,
  unlike the LiveView (see resolved question).
- **DB/migrations**: single Ecto repo `ReportServer.Repo` (MySQL/MyXQL); migrations in
  `server/priv/repo/migrations/` (`timestamps(type: :utc_datetime)`, bigint ids, FK
  `references(:users, ...)` + index pattern per `create_report_runs.exs`). New tables:
  API tokens table + `data_access_log`.
- **Token implementation material**: no `Phoenix.Token` usage today; `secret_key_base` is
  available; `elixir_uuid` dep exists. Token format/storage (opaque random + hash-at-rest vs
  signed) is an implementation.md decision.
- **JSON conventions**: `formats: [:html, :json]` configured; `ReportServerWeb.ErrorJSON` renders
  `%{errors: %{detail: ...}}` — the cc-data contract (`{"error": CODE, ...}`) intentionally
  differs; the API pipeline needs its own error rendering so 401/404/409 bodies match the
  contract.
- **Filter labels**: `report_filter_values` is populated at run creation
  (`ReportLive.Form` → `ReportFilter.get_filter_values/2`) with resolved display names from the
  portal DB (e.g. `%{class: %{254 => "Ms. Smith (period3)"}}`); student names respect
  `hide_names`. Raw ids are in `report_filter`. Both are safe *content* to return as stored, but
  **`%ReportFilter{}` has no `Jason.Encoder`** (`Jason.encode/1` raises
  `Protocol.UndefinedError`) — the implementation must add an explicit serializer (view-layer map
  or derived encoder) matching the Contract section's `report_filter` shape; returning the struct
  raw is a 500.
- **Loaded-filter atom/string asymmetry**: `EctoReportFilter.load/1` atomizes only **top-level
  keys** (`ecto_report_filter.ex:12-18`), so a DB-loaded `report_filter` has *string* entries in
  `filters` (e.g. `["cohort"]`) while `ReportFilter.from_form/2` stores *atoms*. The Athena
  `get_query` path never reads the `filters` list (each report destructures the dimension fields
  directly — verified across all five `reports/athena/*_report.ex`), and today's only query-start
  path already runs on DB-loaded filters (Show mount, `show.ex:169`), so **API self-start is safe
  iff it reuses `report.get_query` exactly as the requirement says**. But
  `ReportFilterQuery.get_filter_query/5` pattern-matches **atom** filter names only — it is the
  filter-form autocomplete path (`get_options`/`get_option_count`, called only from
  `ReportLive.Form` with in-memory atom filters) and raises `FunctionClauseError` if handed a
  loaded filter. The API implementation must not reach for `ReportFilterQuery` (or anything
  dispatching on `filters` entries) with a persisted filter. Normalizing `load/1` to re-atomize
  `filters` entries would remove the trap but touches every existing load site — possible
  hardening, not required by this story.
- **Post-processing jobs**: per-`athena_query_id` GenServer (`PostProcessing.JobServer`) whose
  job list is **persisted to S3** at `s3://<output-bucket>/jobs/<query_id>_jobs.json`
  (`Output.get_jobs_url/1`, `read_jobs_file`/`save_jobs_file` — `job_server.ex:158-176`) and
  reloaded on server start — so the API can read the jobs file directly without the GenServer
  running. Serialized job fields are exactly `id` (1-based int, unique per query), `steps`
  (with labels), `status`, `result` (S3 URL or null) — `@derive Jason.Encoder` at `job.ex:11`.
  **Caveat**: that derived encoder includes `:result` (a raw S3 URL), so the API jobs list must
  not render jobs via the derived encoding — it needs an explicit sanitized serializer mapping
  `result` → `has_result` per the Contract (same situation as the missing `%ReportFilter{}`
  encoder). `Step` derives exactly `[:id, :label]` (`step.ex:2`), matching the Contract's
  steps shape.
  Web download filename convention: `"#{report_slug}-run-#{run_id}-job-#{job_id}.csv"`
  (`post_processing.ex:174`). **Caveat**: `Aws.get_file_contents/1` cannot distinguish a missing
  file from other S3 failures — `get_file_stream/1` rescues everything into one error tuple, and
  the lazy ExAws stream is actually fetched outside that rescue (`aws.ex:41-63`) — so the API
  jobs-list needs a read path that separates S3 not-found (→ empty list) from other failures
  (→ 500-class).
- **Log hygiene**: Phoenix logs controller params, redacting only the keys in
  `config :phoenix, :filter_parameters` — default `["password"]` — and this app sets **no**
  `filter_parameters` config at all (today's `save_token` already receives the portal
  `access_token` as an unfiltered param). The implementation must add the one-time-code and any
  token/code param names to `:phoenix, :filter_parameters` for the "never in server logs"
  requirement to hold.
- **Testing**: `ConnCase` exists but has no auth helper and no JSON/controller-auth test
  precedent — this story establishes the bearer-auth test pattern.
- **No rate limiting / telemetry export / audit logging** exists anywhere today.
- **Future consideration (not this story)**: if run creation ever moves into the API, query
  start/polling should move out of the Show LiveView into a server-side process (e.g. a per-run
  GenServer) that owns `athena_query_id`/`athena_query_state`/`athena_result_url` — eliminating
  both the LiveView-dependent polling and the duplicate-start race by giving those fields a
  single writer.

## Out of Scope

- **Token-management UI** (list tokens, `last_used_at` display, self-serve revoke) — STORY 2.
  Required before researcher rollout, but not part of this story; revocation here is manual
  (DB/console).
- **Answers/history bulk endpoints** (`/api/v1/reports/:id/answers|history`, Node bulk-read
  function, cursor scratch, `EXPIRED_CURSOR`) — STORY 3. This story only ensures the audit-log
  schema accommodates them.
- **The Go CLI itself**, including the loopback listener half of the login flow — STORY 4. The
  manual paste token is enough to exercise the API here.
- **Creating report runs via the API** — download-only, per the design doc's decided scope
  boundary (author in the web UI; download/query in the CLI).
- **Creating post-processing jobs via the API** — same boundary: job-result *download* is in
  scope (see API requirements), but jobs are created only from the web run page.
- **Non-Athena (portal/MySQL) report runs** — excluded from the API surface entirely (see
  resolved question); they concern portal usage, not student data.
- **Rate limiting / abuse protection** — noted as a future concern in the design doc, not v1.
- **Encryption at rest / TTL for local CLI data** — CLI-side concern (STORY 4), decided no for v1.

## Open Questions

<!-- Requirements-focused questions only (scope, acceptance criteria, business rules).
     Implementation questions go in implementation.md. -->

### RESOLVED: How should the API handle non-Athena (portal/MySQL) report runs?
**Context**: `report_runs` includes runs of portal-DB reports that have no Athena artifact — no
`athena_query_id`/`athena_result_url`. Today their LiveView download runs the SQL live and pushes
the data to the browser. The ticket/design doc only specify the Athena CSV path
(`athena_query_state`, presigned URL). The API needs defined behavior for these runs in both the
list and the download endpoints.
**Options considered**:
- A) Include them in `GET /api/v1/reports`, but `/download` returns a distinct error code.
- B) Exclude non-Athena runs from the API entirely (list filters to Athena-backed runs).
- C) Implement live-query download for portal reports in the API too.

**Decision**: **B — exclude non-Athena runs from the API entirely.** Portal reports are about
portal usage, not student data; cc-data is a student-data tool, so the API surface matches what
the CLI can consume. List, show, and download all treat non-Athena runs as outside the API
(a non-Athena run id on `/:id`/`/download` behaves as not-found).

### RESOLVED: Can a user hold multiple active tokens at once?
**Context**: The ticket says "one token per portal," which describes how the *CLI* keys its stored
credentials. Server-side, STORY 2's token-management UI is described as listing "*all* of a user's
active tokens, each with `last_used_at` ... and an optional label (e.g. 'Doug's MacBook')" — which
implies multiple concurrent tokens per user (e.g. two machines). This affects the token table
shape and what re-login does.
**Options considered**:
- A) Multiple active tokens per user; each `login`/generate mints a new one (optional label,
  defaulted server-side); old ones live until revoked. Matches the STORY 2 UI description.
- B) Single active token per user; minting a new one revokes the previous.

**Decision**: **A — multiple active tokens per user.** Each login/generate mints a new token;
tokens live until revoked. Consistent with STORY 2's token-list UI (per-token `last_used_at` +
label) and avoids a second machine silently invalidating the first.

### RESOLVED: Should admins be able to read/download other users' runs via the API?
**Context**: The LiveView run page allows `owner || portal_is_admin`. The design doc decided the
API is strictly ownership-gated ("the CLI downloads reports you authored") — but that discussion
was aimed at *non-admin colleagues*; it doesn't explicitly address portal admins, who can already
see all runs in `/reports/all-runs` and download any CSV via the web today.
**Options considered**:
- A) Strict ownership for everyone, including admins (narrowest; API ≠ web parity; an admin can
  still use the web UI for other users' runs).
- B) Owner OR `portal_is_admin`, mirroring the existing LiveView check.

**Decision**: **A — strict ownership for everyone, including admins.** A non-expiring admin token
that can pull any run in the system meaningfully worsens the leaked-token blast radius; the web UI
already covers the admin need, and STORY 3's endpoints stay consistent with the same rule.

### RESOLVED: data_access_log — who can read it, and what retention policy?
**Context**: The ticket assigns this story the decisions about the audit log: who can read it
(the log records which students'/runs' data was exported by whom, so it is itself sensitive) and
how long records are kept. "Append-only" and "must answer 'who exported student X's data'" are
already decided.
**Options considered**:
- A) v1: no in-app read surface at all (DB/console access only); retention: indefinite.
- B) v1: admin-only LiveView page listing recent access events; retention: indefinite.
- C) A or B but with a defined retention window enforced by a cleanup job.

**Decision**: **B, with pagination — and a scope addition.** An admin-only LiveView page lists
access-log events, paginated. Retention: indefinite. Since no run-list page currently paginates,
this story implements a **generic (reusable) pagination method** and applies it to the new audit
page **and retrofits the existing run list pages** (`/reports/runs` `:my_runs` and
`/reports/all-runs` `:all_runs`).

### RESOLVED: data_access_log content — resolved endpoint set vs hash (schema decision owed to STORY 3)
**Context**: For this story's CSV URL-issuance events, the log row is run-level (user, run,
filters, timestamp) — no endpoint set is involved. But the schema must accommodate STORY 3's
per-page answers/history events, and the design doc leans strongly toward logging the **resolved
`remote_endpoint` set** (a count+hash cannot answer "was student X in this export?", and
student-level auditability is the likely requirement). Deciding it now fixes the schema.
**Options considered**:
- A) Schema includes a nullable field for the resolved endpoint set (e.g. JSON column); CSV
  rows leave it null; STORY 3 fills it per page.
- B) Schema stores only a count + hash of the endpoint set.
- C) Defer the field to STORY 3.

**Decision**: **A — nullable resolved-endpoint-set field (JSON column).** Student-level
auditability is the point of the log; count+hash can't answer "was student X in this export?".
CSV URL-issuance rows leave it null; STORY 3's per-page events fill it. The resulting sensitivity
is handled by the admin-only read surface (previous decision).

### RESOLVED: Should list/show responses resolve human-readable filter labels?
**Context**: The design doc's dataset-manifest section wants the CLI to capture "both the raw
filter values and the resolved human labels where the server has them (e.g. `Class: "Ms. Smith —
Period 3"`, not just `class_id: 254`)" from the same list/show responses.
**Decision**: Return `report_filter_values` exactly as stored — **verified in code** that it
already contains resolved human labels: `ReportLive.Form` calls
`ReportFilter.get_filter_values/2` at run-creation time, which looks up display names in the
portal DB (class/teacher/assignment/school names; student names respect `hide_names`) and stores
the id→name map on the run. Raw ids live in `report_filter`. Returning both fields as stored
satisfies the design doc with no extra resolution work.

### RESOLVED: Pagination limits — default and max page size for `GET /api/v1/reports`?
**Context**: The contract takes a `limit` query param, but the default and cap are unspecified.
Report-run lists are small (this is runs-you-authored, not student data), so this is low-stakes —
just needs a decision for the contract.
**Options considered**:
- A) Default 50, max 200.
- B) Default 100, max 500.

**Decision**: **A — default 50, max 200.** Values above the max are clamped to 200.

### RESOLVED: Admin audit-log page — what does it show and filter by (v1)?
**Context**: The new admin-only LiveView page (previous decision) needs a defined v1 surface.
Note that until STORY 3 lands, every row is a CSV URL-issuance event and the endpoint-set column
is always null — so student-level search ("show me exports containing student X") has nothing to
search yet and naturally belongs with STORY 3.
**Options considered**:
- A) Simple paginated table, newest first: timestamp, requesting user, run id + report slug, data
  type/event. No filters in v1; filtering/search comes later (e.g. with STORY 3).
- B) A plus basic filters (by user, by run id).
- C) B plus student-level search over the endpoint-set column (premature until STORY 3 fills it).

**Decision**: **A — simple paginated table, newest first, no filters in v1.** Columns: timestamp,
requesting user, run id + report slug, data type/event. Filters and student-level search come
later (with STORY 3, when the endpoint-set column has data).

### RESOLVED: LiveView pagination style — page numbers or "load more"?
**Context**: The generic pagination method (previous decision) will back three LiveView pages:
the audit log (append-only, will grow unbounded) and the two run lists (currently modest row
counts). The API uses keyset pagination; the LiveView pages can use either style.
**Options considered**:
- A) Page-number/offset pagination (classic pager UI: prev/next + page numbers). Familiar,
  jumpable; offset cost is negligible at these table sizes for the foreseeable future.
- B) Keyset-based "Load more" (or infinite scroll) — consistent with the API's keyset approach
  and stays fast on an unbounded audit table, but no jumping to a page and less conventional for
  admin tables.

**Decision**: **A — page-number/offset pagination with a classic pager (prev/next + page
numbers).** Familiar and jumpable for admin tables; offset cost is negligible at these table
sizes. The API keeps its separate keyset contract — the two pagination styles serve different
consumers.

## Self-Review

### Security Engineer

#### RESOLVED: Not-owned run responses can leak run existence (403 vs 404)
The spec requires ownership on every `/:id/*` endpoint and lists a `FORBIDDEN` error code, but
doesn't say which status a non-owner gets. Run ids are sequential and guessable; a 403 confirms
"this run exists" to any token holder, enabling enumeration of how many runs exist and which ids
are live.
**Resolution**: Approved — non-existent, not-owned, and non-Athena run ids all return **404
`NOT_FOUND`**, indistinguishable from each other. `FORBIDDEN` is dropped from the v1 error-code
list (nothing returns it; STORY 3 can reintroduce it if needed).

#### RESOLVED: Token/secret handling requirements are missing
The spec defers token format to implementation.md, but several properties are requirements, not
implementation choices: (a) the raw token is shown/delivered **once** and must not be recoverable
afterwards (i.e. stored only in irreversible form server-side); (b) tokens and one-time codes must
never appear in server logs or error messages; (c) tokens must be generated with a CSPRNG and
sufficient entropy; (d) PKCE method is **S256 only** (reject `plain`).
**Resolution**: Approved — added as requirements bullets under "Per-user token model" (secret
handling) and "Login handoff" (PKCE S256 only). Mechanism (opaque vs signed, hash algorithm,
prefix format) remains an implementation.md decision.

---

### Senior Engineer

#### RESOLVED: "Athena-backed run" exclusion criterion is undefined — and artifact-presence would break polling
Non-Athena runs are excluded, but the spec doesn't define how a run is classified. If the filter
were "has `athena_query_id`/`athena_result_url`", a just-created Athena run (queued, no artifact
yet) would vanish from the API — but the CLI's `get report` flow *polls the API while the query
runs*, so queued/running runs must be listed.
**Resolution**: Approved — classification is by **report type** (the run's `report_slug`
resolves to an Athena-type report definition), independent of query state; state only gates
`/download`. Added to the API requirements.

#### RESOLVED: Download endpoint behavior for failed/cancelled/nil states and the missing-URL edge
"409 unless succeeded" leaves ambiguity: is a `failed` run also `NOT_READY` (it will never be
ready)? And what if `athena_query_state == "succeeded"` but `athena_result_url` is unexpectedly
null?
**Resolution**: Approved — `/download` returns **409 `NOT_READY` with the current
`athena_query_state` in the error context** for every non-succeeded state (the CLI decides
whether to poll or give up based on the state); succeeded-with-missing-URL is a server-side
invariant violation → 500-class error, logged.

---

### QA Engineer

#### RESOLVED: Contract details untestable as written: timestamp format and invalid `limit` values
The envelope and error shape are specified, but not the JSON serialization of timestamps, nor
what `limit=0`, `limit=-5`, or `limit=abc` do — each is a test case with no defined expectation.
**Resolution**: Approved — timestamps are **ISO 8601 UTC strings**; `limit` is clamped into
`[1, 200]` when numeric, and a non-integer `limit` (or other malformed query param) returns
**400 `BAD_REQUEST`** in the standard error shape. `BAD_REQUEST` added to the v1 code list.

---

### Education Researcher

#### RESOLVED: CSV issuance rows can't answer student-level audit questions — even after STORY 3
The endpoint-set column is null for CSV URL-issuance rows *by design*, and STORY 3 only fills it
for answers/history pages. But 4 of the 5 API-visible Athena reports carry student-level
identifiers in the CSV (`student-answers`, `student-actions`, `student-actions-with-metadata`,
`student-assignment-usage`; only `teacher-actions` doesn't) — so "was student X's data exported?"
isn't directly answerable from a CSV audit row.
**Resolution**: Approved — **accept and document**. Mitigating fact found during review: the CSV
artifact itself persists in S3 (`athena_result_url`), so student-level questions about a CSV
export are answerable *exactly* by reading the artifact the audit row points to (who/when/which
run from the log; contents from the persisted artifact) — stronger than roster reconstruction,
as long as S3 objects are retained. "Derive and log the endpoint set for CSV downloads" noted as
an optional follow-up once STORY 3's derivation call exists.

---

### WCAG Accessibility Expert

#### RESOLVED: No accessibility requirements for the new UI surfaces
This story adds three UI surfaces (audit-log page, `/reports/cli-token` page, pager component on
three list pages) with no accessibility requirements.
**Resolution**: Approved — added an "Accessibility (new UI surfaces)" requirements subsection:
keyboard-operable pager in a `<nav aria-label="pagination">` landmark with `aria-current="page"`;
proper `<th>` table headers; selectable token text with an accessible copy control + ARIA live
region announcement; existing Tailwind styles + WCAG AA contrast. (No Zeplin designs exist for
these internal admin pages — following existing app styling is the intended path.)

---

## Self-Review — Round 2 (code-verified)

Every issue below was verified against the current code before being written up (file:line
references), and where possible confirmed dynamically with throwaway ExUnit tests run against the
dev MySQL container (all passed, then deleted). Playwright checks were not applicable: no local
server is running, and exercising these paths live requires portal OAuth + real AWS credentials;
the static call-graph evidence is conclusive for each finding.

### Senior Engineer

#### RESOLVED: API polling contract is unimplementable as written — `athena_query_state` freezes when the browser tab closes
The requirements say a queued/running run "appears in list/show with its current
`athena_query_state` — the CLI polls exactly this." But the stored state only advances while the
run's **Show LiveView is open in a browser**: the poll loop is
`Process.send_after(live_view_pid, :poll_query_state, 1000)` inside the LiveView process
(`show.ex:245-249`), and the only writers of `athena_query_state` in the entire codebase are
`show.ex:172` (query start) and `show.ex:233` (poll update). `AthenaQueryPoller` is used only by
Clue, synchronously, and never touches `report_runs`. The Athena query itself is also only
*started* on Show mount (`form.ex:229` redirects there after run creation).
**Verified**: call-graph grep over `lib/` (no other writers, no background poller) + throwaway
ExUnit tests — a run stored as `"running"` reads back `"running"` via the exact context functions
the API would use; a run created but never opened in Show has nil `athena_query_id` AND nil state.
**Why it matters**: the CLI's core `get report` flow polls the API while the query runs; Athena
queries can take minutes. If the researcher closes the tab mid-query, the API reports "running"
forever and `/download` returns 409 forever — even though Athena finished long ago.
**Suggested resolution**: add a requirement that the API returns *current* Athena state, not
last-LiveView-observed state — on `/:id` show (and optionally list), when a run has an
`athena_query_id` and a non-terminal stored state (nil/queued/running), the server refreshes via
`AthenaDB.get_query_info/1` and persists the result before responding. Also enumerate the state
vocabulary in the Contract section (null, "queued", "running", "succeeded", "failed",
"cancelled" — verified: `get_query_info` downcases Athena's states) since the CLI branches on it.
**Resolution**: Approved — added a **State freshness** requirement to the API section (show and
download refresh non-terminal state from Athena and persist before responding; list serves stored
state as-is) and enumerated the `athena_query_state` value vocabulary in the Contract section.

---

### Security Engineer

#### RESOLVED: Bearer auth has no role gate — API access survives portal deprovisioning (web access doesn't)
Every web report surface enforces `Auth.can_access_reports?` (portal admin || project admin ||
project researcher) at LiveView mount (`report_live/auth.ex:9` — its only call site), and the role
flags are re-snapshotted from the portal on every login (`accounts.ex:45-66`, called from
`AuthController.save_token`). Sessions effectively expire with the portal token (`auth.ex:6-10`),
so web access reflects current portal roles within one login cycle. The API requirements specify
**only ownership** authz — no role check anywhere — and tokens are non-expiring by design.
**Verified**: `can_access_reports?` has exactly one call site (the web on_mount); role flags are
written only by the login path.
**Why it matters**: a researcher deprovisioned on the portal (left the project, role revoked)
keeps pulling student-data CSVs via the API indefinitely — their snapshot flags freeze at their
last web login and the token never expires. Until STORY 2 ships, revocation is manual and nothing
prompts it.
**Suggested resolution**: (a) require the `:api_authenticated` pipeline to also enforce
`can_access_reports?` against the token's resolved user (local snapshot — no portal call, one
boolean check); (b) add an explicit documented limitation: role snapshots refresh only at web
login, so timely deprovisioning still requires token revocation — reinforces STORY 2 as a rollout
prerequisite.
**Resolution**: Approved — added a **Role gate** bullet to the API requirements (role failure →
401 `NOT_AUTHENTICATED`, indistinguishable from a bad token) and a **Documented limitation**
bullet under the token model (snapshot staleness; revocation is the timely cutoff).

---

### Education Researcher

#### RESOLVED: "Audit from day one" doesn't cover the existing export path — web-UI CSV downloads stay unlogged
The audit requirement logs URL-issuance on the API `/download` only. The LiveView download
(`download_athena_report`, `show.ex:278-290`) mints the *same* presigned URL for the *same*
student-data artifacts — including admins downloading other users' runs, which the API
deliberately refuses — and writes nothing.
**Verified**: no audit/logging code exists anywhere in the app today (grep for
audit/data_access/log-on-download), and the LiveView download path has no hook. After this story
ships, the web UI remains the primary export path (and for admins pulling others' runs, the only
one), so "who exported which student data?" stays unanswerable for most real exports.
**Why it matters**: the spec's own rationale is "access logs cannot be backfilled later." That
applies equally to the web exports happening today.
**Suggested resolution**: extend the audit requirement so the LiveView Athena download-URL
issuance also writes a `data_access_log` row (one call into the same context once it exists; the
data type/event field distinguishes web vs API issuance). Alternatively, explicitly document that
web exports are excluded from audit v1 — but the cost asymmetry strongly favors including them.
**Resolution**: Approved — added a **Web-UI downloads are logged too** bullet to the audit
requirements: the LiveView Athena download logs URL-issuance with a web-vs-API event/source
value, recording the requesting user (covers admin downloads of others' runs); portal (MySQL)
report downloads stay unlogged.

---

### Product Manager

#### RESOLVED: `/reports/cli-token` mint trigger is unspecified — mint-on-page-load would create orphan immortal tokens
With multiple active tokens per user (resolved decision) and no token-management UI until STORY 2,
the manual-fallback page's mint trigger matters: if the page mints on load, every visit/refresh
silently creates another non-expiring token the user can't see or revoke. The requirement
currently just says the page "generates and shows the token once."
**Verified**: requirements-level only — the page doesn't exist yet, so there is no code to check;
flagged because the multiple-tokens + no-UI combination is confirmed by the resolved questions.
**Suggested resolution**: require the token to be minted only on an explicit user action (e.g. a
"Generate token" button, with the optional label input), never on page load; a refresh after
minting must not mint again.
**Resolution**: Approved — the Manual fallback requirement now specifies mint-on-explicit-action
only: page load/refresh never mints, and a refresh after minting does not re-mint or re-display
the token.

---

## Self-Review — Round 3 (follow-on from round-2 changes)

### Senior Engineer

#### RESOLVED: State-freshness requirement left refresh-failure behavior undefined
The round-2 State freshness change made show/download refresh non-terminal state from Athena
"before responding," but didn't define behavior when `AthenaDB.get_query_info/1` fails
(transient AWS error/throttling) — contract-visible ambiguity introduced by the change itself.
**Resolution**: Approved — on refresh failure the endpoint serves the **stored** state and logs
the failure server-side, so the CLI polling loop survives transient AWS errors instead of
seeing 500s.

---

### Security Engineer

#### RESOLVED: `/auth/cli` could mint tokens for users the API role gate will always reject
The round-2 role gate means a token minted for a user failing `can_access_reports?` 401s on
every request — but the `/auth/cli` controller flow sits outside the `:reports` live_session
gate (verified: the gate is enforced only by the `ReportLive.Auth` on_mount), so it would
happily mint such a token, producing a confusing "login succeeded, everything 401s" CLI
experience. The manual page is already covered by the live_session gate.
**Resolution**: Approved — `/auth/cli` refuses to mint for users failing `can_access_reports?`,
failing at login with a clear message instead.

---

## Self-Review — Round 4 (code-verified)

Every issue below was verified against the current code before being written up (file:line
references). Where dynamic verification was possible it was done with throwaway ExUnit tests run
against the dev MySQL container (all passed, then deleted). Playwright checks were again not
applicable: no local server is running, and exercising these paths live requires portal OAuth +
real AWS credentials; static call-graph evidence is conclusive for each finding.

Roles run with no new findings: **Performance Engineer** (the per-poll Athena refresh has a 1s
LiveView-poll precedent — `show.ex:247`; table sizes make offset pagination and per-request
`last_used_at` writes negligible), **WCAG Accessibility Expert** (the existing run-list table
already uses proper `<th>` markup — `custom_components.ex:315-334` — so the retrofit requirement
is consistent with current code).

### Senior Engineer

#### RESOLVED: State refresh must persist `athena_result_url` too, or the tab-closed run 500s on download forever
The round-2 State-freshness requirement says the API "refreshes the **state** from Athena
(`AthenaDB.get_query_info/1`) and persists the update". But `get_query_info/1` returns **both**
the state and the S3 output location (`athena_db.ex:16-26`), and the LiveView poll persists both
(`show.ex:232-233` writes `athena_query_state` AND `athena_result_url`). `athena_result_url` has
no other writer. If an implementer reads the requirement literally and persists only the state,
the exact scenario the requirement was added to fix — researcher closes the tab, query finishes,
CLI polls the API — produces a run whose state refreshes to `succeeded` while `athena_result_url`
stays null, which the spec's own invariant clause then classifies as a server error: `/download`
500s forever on a perfectly good run.
**Verified**: `get_query_info/1` extracts `ResultConfiguration.OutputLocation`
(`athena_db.ex:21`); grep confirms `athena_result_url` is written only at `show.ex:233`.
**Suggested resolution**: amend the State-freshness bullet to say the refresh persists **both**
the state and the result URL returned by the same `get_query_info/1` call (mirroring the LiveView
poll at `show.ex:233`).

**Resolution**: Approved — the State-freshness bullet now requires persisting both
`athena_query_state` and `athena_result_url` from the same `get_query_info/1` call, so a run
refreshed to `succeeded` is immediately downloadable.

---

### Security Engineer

#### RESOLVED: "Never in server logs" will be violated by default — no `filter_parameters` config exists
The secret-handling requirement says tokens and one-time codes must never appear in server logs.
Phoenix logs every controller request's params, filtering only keys configured in
`config :phoenix, :filter_parameters` — whose default is `["password"]` — and **no
`filter_parameters` config exists anywhere in `server/config/`** (verified by grep). The
`/auth/cli` loopback flow delivers the one-time code as a query/form param (redirect + exchange
endpoint), and the exchange response carries the token — so with no config change, the code is
logged on every exchange request by default framework behavior.
**Verified**: `grep -rn filter_parameters server/config/` → no matches; the existing
`save_token` action (`auth_controller.ex:26`) already receives the portal `access_token` as a
param, unfiltered, so the default-logging behavior is live today.
**Suggested resolution**: add a Technical Notes bullet: Phoenix param logging filters only
`password` by default and the app sets no `filter_parameters`; the implementation must add the
one-time-code (and any token/code param names) to `:phoenix, :filter_parameters` for the
log-hygiene requirement to hold. (Requirement itself is already in place; this pins the known
gap so implementation.md addresses it.)

**Resolution**: Approved — added a **Log hygiene** Technical Notes bullet documenting the missing
`filter_parameters` config and the implementation obligation to filter one-time-code/token param
names.

---

### QA Engineer

#### RESOLVED: Malformed or out-of-range `:id` path params are undefined — the naive implementation 500s
The contract defines 404 for non-existent/not-owned/non-Athena ids and 400 for malformed **query**
params, but says nothing about the **path** param: `GET /api/v1/reports/abc`,
`/api/v1/reports/123abc`, or an id beyond bigint range. Phoenix delivers `:id` as a string, and
the data layer raises rather than returning nil.
**Verified dynamically** (throwaway ExUnit, dev MySQL container, then deleted):
`Repo.get(ReportRun, "abc")` and `Repo.get(ReportRun, "123abc")` raise `Ecto.Query.CastError`;
`Repo.get(ReportRun, 99_999_999_999_999_999_999)` also raises. Each would surface as a 500 from
a naive controller — three test cases with no defined expectation.
**Suggested resolution**: define that a syntactically invalid or out-of-range `:id` behaves as
**404 `NOT_FOUND`** — same bucket as non-existent, keeping the "one indistinguishable 404"
property (400 would create a distinguishable malformed-vs-missing signal for no benefit).

**Resolution**: Approved — the no-existence-leaks bullet now folds syntactically invalid and
out-of-range `:id` values into the same indistinguishable 404, with a note that the default data
layer raises `Ecto.Query.CastError` on them.

---

### Education Researcher

#### RESOLVED: Post-processing result downloads are unlogged student-data exports — the audit net has a second hole
The round-2 fix extended audit logging to the web UI's raw-CSV download, but the run Show page has
a **second** export surface: the post-processing component. For succeeded Athena runs it lists
completed jobs whose results are derived CSVs in S3 — derived from the same student data, and in
some cases *richer* (steps include "Add audio transcription column for open response answers",
"Add glossary definition and audio link columns", "Merge user answers", links to student work —
`post_processing/steps/*.ex`). Its "Download Result" **and** "Copy Result URL" buttons both mint
a presigned URL via the same `AthenaDB.get_download_url/2` (`post_processing.ex:170-185`) — and
the spec's audit bullet names only `download_athena_report`, so these issuances stay unlogged.
The Copy-URL button is the sharper case: it exists specifically to share the artifact URL.
**Verified**: `get_download_url/2` has exactly three call sites — `athena_db.ex:28` (def),
`show.ex:282` (covered by the spec), `post_processing.ex:176` (not covered).
**Suggested resolution**: extend the "Web-UI downloads are logged too" bullet to cover
post-processing job-result URL-issuance (both buttons — same event write, distinct data-type or
event value identifying it as a post-processing artifact, recording the job id).

**Resolution**: Approved — added a **Post-processing result URL-issuance is logged too** bullet
to the audit requirements (both buttons, same audit call, distinct data-type/event value, job id
recorded).

---

### DevOps Engineer

#### RESOLVED: Audit-write failure semantics are undefined — can a download proceed if its audit row can't be written?
"Log the URL-issuance event on every download" doesn't say what happens when the
`data_access_log` insert fails (DB hiccup, table lock). Fail-open means the export proceeds
unrecorded — an audit gap in the table whose whole rationale is "access logs cannot be
backfilled"; fail-closed means researchers can't export while the log table has trouble.
**Verified**: requirements-level only — no audit code exists yet to check (grep re-confirmed);
flagged because either behavior is a one-line implementation choice that silently sets policy.
**Suggested resolution**: decide explicitly. Recommended: **fail-closed** (the URL is minted only
after the audit row commits; a failed write → 500 and no URL). The audit table lives in the same
MySQL instance as everything else, so an unavailable log table means the app is degraded anyway —
the integrity guarantee costs little.

**Resolution**: Approved — fail-closed. Added an **Audit writes are fail-closed** bullet to the
audit requirements covering all three logged surfaces: URL issued only after the audit row
commits; a failed write aborts with a server error and no URL.

---

### Product Manager

#### RESOLVED: Post-processed results are absent from the spec — silently out of scope for the CLI
The spec never mentions post-processing at all, yet it is part of the researcher workflow this
project is replacing: researchers run post-processing jobs (audio transcription, glossary data,
merged answers) from the run page and download those derived CSVs (`post_processing.ex`). The
API's list/show/download surface covers only the raw Athena artifact, so a CLI researcher gets
raw CSVs but loses access to post-processed outputs — a workflow gap nobody decided on the
record.
**Verified**: no occurrence of "post-processing"/"job" anywhere in the spec; the feature is live
on the run Show page for succeeded Athena runs (`show_component?/2`, `post_processing.ex:191`).
**Suggested resolution**: add an explicit Out of Scope bullet: post-processing job creation and
job-result download stay web-UI-only in v1 (a researcher needing them uses the web page; a future
story could expose job results as additional downloadables on a run).

**Resolution**: Suggested resolution **rejected** — post-processed output must be downloadable
via the API. Scope extended instead: added `GET /api/v1/reports/:id/jobs` (list from the
persisted S3 jobs file) and `GET /api/v1/reports/:id/jobs/:job_id/download` (fresh presigned URL,
409 `NOT_READY` with job status for non-completed, 404 for unknown/malformed job ids,
audit-logged) to the API requirements; job **creation** stays web-UI-only (added to Out of
Scope); job `status` vocabulary added to the Contract; jobs-persistence details (S3 jobs file,
serialized fields, filename convention) added to Technical Notes. Feasibility verified: jobs are
persisted to `s3://<output-bucket>/jobs/<query_id>_jobs.json` and readable without the job
GenServer (`job_server.ex:158-176`); results are S3 URLs presignable by the existing
`AthenaDB.get_download_url/2`.

---

## Self-Review — Round 5 (follow-on from round-4 changes, code-verified)

Focused re-review of the round-4 changes, primarily the new post-processing job endpoints.

### Senior Engineer

#### RESOLVED: Jobs-list behavior on S3 read failure is undefined — and the current helper can't distinguish "no jobs file" from "S3 error"
The new `GET /:id/jobs` requirement says runs with no jobs file return an empty list, but doesn't
say what a *failed* S3 read returns. The distinction matters: serving an empty list on a
transient S3 error tells the CLI "your jobs are gone." And the current helper makes the
distinction impossible: `Aws.get_file_stream/1` rescues **every** failure into the same
`{:error, "Unable to get stream"}` (`aws.ex:41-53`), and because the ExAws stream is lazy, the
actual fetch happens at `Enum.join(stream)` in `get_file_contents/1` (`aws.ex:55-63`) — outside
the rescue. `JobServer.read_jobs_file/1` silently treats any error as "no jobs" (`job_server.ex:164-165`),
which is tolerable for the web UI but contract-visible for the API.
**Verified**: `aws.ex:41-63` (collapsed error tuple; lazy stream evaluated outside the rescue);
`job_server.ex:158-167` (any error → empty jobs).
**Suggested resolution**: require: missing jobs file → empty list (200); any other S3 read
failure → 500-class error, logged (never a misleading empty 200). Add a Technical Notes line
that `Aws.get_file_contents/1` as written can't make this distinction, so the implementation
needs a read path that separates S3 not-found from other failures.

**Resolution**: Approved — the jobs-list requirement now specifies missing-file → empty list,
any other S3 failure → 500-class logged error; Technical Notes gained the
`Aws.get_file_contents/1` caveat.

---

### QA Engineer

#### RESOLVED: A `completed` job with a null `result` is unspecified on `/jobs/:job_id/download`
The round-4 job-download requirement defines 409 for non-completed and 404 for unknown ids, but
not the invariant-violation case the run download already covers: status `"completed"` with a
null `result` URL (e.g. a jobs file written by a crashed update path). The run-download
requirement explicitly makes succeeded-with-null-URL a 500-class logged error; the job download
should mirror it — otherwise it's an untestable edge.
**Verified**: spec-internal (round-4 text vs the existing run-download invariant clause);
`update_job/4` does write `result: nil` on failure paths (`job_server.ex:192`), so
status/result mismatches are representable in the persisted file.
**Suggested resolution**: mirror the run-download clause: `completed` job with null `result` is a
server invariant violation → 500-class error, logged server-side.

**Resolution**: Approved — the job-download requirement now includes the invariant clause
(completed + null result → 500-class, logged), mirroring the run download.

---

### Education Researcher

#### RESOLVED: The audit-record field list has no home for the job id the round-4 bullets promise to record
Round 4 requires post-processing issuance events (web and API) to record the job id, but the
"Each record" schema bullet still enumerates only: timestamp, requesting user_id, report_run /
filters, data type, page/cursor progress, and the nullable endpoint-set column. A schema built
strictly from that list can't store the job id.
**Verified**: spec-internal cross-reference (audit schema bullet vs the round-4 post-processing
bullets).
**Suggested resolution**: extend the "Each record" bullet with a nullable artifact-context field
(at minimum the post-processing job id; null for plain CSV issuance rows), keeping the schema
accommodating for STORY 3 event types.

**Resolution**: Approved — the "Each record" bullet now includes a nullable artifact-context
field carrying the post-processing job id for job-result issuance rows.

---

## External Review — Round 1

Findings from an external development review (Senior Engineer, Product Manager roles), processed
one at a time with the project owner.

### Senior Engineer

#### RESOLVED: [HIGH] API-visible Athena runs can get stuck before a query is ever started
The spec defined state refresh only for runs that already have an `athena_query_id`, but the web
form creates the `report_runs` row **before** any Athena query exists (`form.ex:219-229`); the
query is started only when the Show LiveView mounts (`show.ex:168-172`). If the browser closes
during the redirect, the API lists an Athena-type run with `athena_query_id: null` that can never
progress — the CLI polls forever and `/download` 409s forever.
**Resolution**: Approved — added a **Not-yet-started runs self-start** bullet to the API
requirements: on `GET /:id` and `/:id/download`, an Athena-type run with `athena_query_id == nil`
has its query started server-side via the same path the Show LiveView uses, persisting
`athena_query_id` + `athena_query_state` before responding; start failure serves stored state and
logs (next poll retries); list never starts queries. The duplicate-start race (simultaneous Show
mount or concurrent API request) was discussed and **accepted** — the CLI cannot create runs in
this story, so the window is the sub-second gap between run creation and the Show redirect, and
the worst case (one wasted duplicate query, last-persisted id wins) matches today's tolerated
two-browser-tab behavior. A Technical Notes **Future consideration** bullet records the
longer-term direction: if run creation moves into the API, query start/polling moves to a
server-side single-writer process (e.g. per-run GenServer).

---

### Product Manager

#### RESOLVED: [LOW] Technical Notes still called resolved API decisions "Open Questions"
The "Download today" and "LiveView show authz precedent" Technical Notes bullets ended with
"is an Open Question" sentences predating the resolved questions — an implementer could treat
non-Athena API behavior and admin access as still undecided.
**Resolution**: Approved — both sentences replaced with **Resolved** references: non-Athena runs
are excluded from the API entirely (list/show/download treat them as not-found), and the API is
strict owner-only with no admin bypass, each pointing at its resolved question.

---

## External Review — Round 2

Findings from an external re-review of the requirements spec, processed one at a time with the
project owner.

#### RESOLVED: [HIGH] 500-class API errors have no contract code
Multiple requirements mandate 500-class responses (artifact-URL invariant violations, non-missing
S3 read failures, fail-closed audit-write failures) and "one error shape everywhere", but the v1
code list defined only 400/401/404/409 codes — no code a 500 body could legally carry, and
Phoenix's default `ErrorJSON` (`%{errors: %{detail: ...}}`) would leak through on exactly that
path.
**Resolution**: Approved — added `SERVER_ERROR` (500) to the v1 code list plus a Contract bullet:
all 500-class API failures render `{ "error": "SERVER_ERROR", "message": "..." }` with safe
context only (no exception details, stack traces, S3 URLs, or secrets). One code by design —
distinct internal-failure codes would leak failure modes the CLI can't act on anyway; the
distinction lives in server-side logs.

---

#### RESOLVED: [MEDIUM] Pagination response token had no request parameter name
The contract defined `next_page_token` in responses and the `limit` query param, but never named
the query parameter clients send the token back in — the CLI and server could implement different
names — and invalid-token behavior was undefined.
**Resolution**: Approved — added a Contract bullet: the request parameter is `page_token`
(`GET /api/v1/reports?limit=50&page_token=<opaque>`; request `page_token` / response
`next_page_token`, per the AIP-158 convention); malformed/undecodable `page_token` → **400
`BAD_REQUEST`**. Deliberately did **not** spec expired/unknown-token behavior: with
keyset-over-ids there is no such state — any decodable token is a valid `WHERE id < ?` bound even
if the referenced run was deleted; only undecodable input can fail.

---

#### RESOLVED: [MEDIUM] Loopback code-exchange endpoint was underspecified
The loopback flow required "a code-exchange endpoint" but defined no path, HTTP method, request
fields, or success shape — a CLI/server contract surface STORY 4 cannot reliably implement
against.
**Resolution**: Approved — added a **Code-exchange endpoint contract** bullet to Login handoff:
`POST /auth/cli/token` with JSON body `{ "code": ..., "code_verifier": ... }`; direct CLI→server
call through the `:api` pipeline (no session/CSRF); success `200 { "token": ... }`
(additive-only evolution within v1); unknown/expired/used code and PKCE verifier mismatch all
return one indistinguishable **400 `BAD_REQUEST`** (no code-probing oracle); code/verifier travel
in the POST body and fall under the `filter_parameters` log-hygiene obligation.

---

#### RESOLVED: [LOW] "Short-lived" one-time code lifetime was not testable
"Short-lived and single-use" pinned single-use but not the lifetime — implementations could pick
anywhere from seconds to hours and claim compliance.
**Resolution**: Approved — one-time codes expire **5 minutes** after issuance (generous for slow
logins, within OAuth 2.0's ≤10-minute authorization-code guidance) and are invalid after the
first successful exchange; expired/used codes fail with the same indistinguishable 400 as an
unknown code, consistent with the exchange-endpoint contract.

---

#### RESOLVED: [Follow-on] CSPRNG/entropy requirement covered tokens but not one-time codes
Found during the post-round re-review: the secret-handling bullet required CSPRNG generation with
sufficient entropy for tokens only; one-time codes appeared there only for log hygiene. The
round-2 changes made codes a concrete attack surface (defined 5-minute lifetime, defined
unauthenticated exchange endpoint, rate limiting out of scope) where code entropy is the only
brute-force defense.
**Resolution**: Approved — the secret-handling bullet now applies the CSPRNG/entropy requirement
to one-time codes as well, noting why (no rate limiting in v1). Also considered and deliberately
left unspecified: a `page_token` sent to the unpaginated `/jobs` endpoints — standard ignore-
unused-params behavior plus the existing malformed-query-param 400 rule cover it.

---

## External Review — Round 3

Findings from an external re-review of the requirements spec (Education Researcher / Security,
QA Engineer roles), processed one at a time with the project owner. Each finding was re-verified
against the code before processing.

#### RESOLVED: [HIGH] Audit scope missed the legacy `/old-reports` export path
The audit requirements enumerated the API `/download`, the run page raw-CSV download, and the
post-processing buttons — but the legacy `/old-reports` LiveView also mints presigned URLs for
student-data CSVs (original query results AND job results, `old_report_live/query.ex:209-237`)
via a *different* presign helper (`ReportServerWeb.Aws.get_presigned_url/3`, `aws.ex:32-38`) —
which is why the round-4 sweep over `AthenaDB.get_download_url/2` call sites missed it.
Re-verification found the gap slightly worse than reported: `/old-reports` routes through
`:browser` only (`router.ex:48-52`), outside the `:reports` live_session, so it lacks even the
`can_access_reports?` gate; and its queries live in the researcher's Athena workgroup with no
`report_runs` row, so the audit schema as written couldn't represent the event anyway.
**Resolution**: Reviewer offered audit-inclusion vs explicit out-of-scope; the project owner chose
a third option — **disable the route**: the `/old-reports` router scope is removed in this story
("should have been done long ago"), closing the last unaudited student-data export surface
instead of extending the audit schema to represent run-less legacy events. Post-round follow-on
(also approved): rather than leaving a bare 404, `/old-reports` **redirects to `/reports`** via
the existing `RedirectToReports` backwards-compat pattern (`router.ex:54-59`). Added a
**Legacy `/old-reports` export path is disabled** bullet to the audit requirements; deleting the
unreachable `OldReportLive` modules is optional cleanup, not a requirement.

---

#### RESOLVED: [MEDIUM] `report_filter` response shape was not a concrete JSON contract
The spec required list/show responses to include `report_filter` (raw ids) and called both filter
fields "safe to return as stored" — but the stored value is a `%ReportFilter{}` struct
(`report_run.ex:11` via `EctoReportFilter`, `ecto_report_filter.ex:12-18`) with **no
`Jason.Encoder`** (verified: derivations exist only on `PostProcessing.Step`/`Job`), so a naive
controller 500s and careful implementations could each invent a different shape.
**Resolution**: Approved — added a **`report_filter` serialization** contract bullet (all fields
always present: `filters` as filter-type strings in stored order; the nine id dimensions as
integer arrays or null; `state` as string array or null; dates as stored with `""` normalized to
`null`; the two booleans) and a **`report_filter_values` serialization** bullet (as stored, id
keys become JSON strings). Technical Notes now flags the missing encoder and the need for an
explicit serializer.

---

#### RESOLVED: [MEDIUM] LiveView pagination lacked page-size and URL semantics
The Pagination section pinned only the *style* (prev/next + page numbers) — no page size, no
query parameter name, no invalid/out-of-range/empty-page behavior. With the existing lists fully
unpaginated (`reports.ex:22-27`, `reports.ex:42-54`; full lists assigned in
`report_run_live/index.ex`), there is no convention to inherit, so tests and implementation
could diverge on basic pager behavior.
**Resolution**: Approved — added a **Pager contract** to the Pagination section: fixed page size
**25** (project owner adjusted from the proposed 50), `?page=N` via `push_patch` (bookmarkable,
page 1 = canonical no-param URL), non-integer/`< 1` treated as page 1, beyond-last-page clamps
to the last page (no error states), empty list renders page 1's empty state with the pager
hidden whenever there is only one page. Windowing/truncation and component API stay
implementation.md concerns.

---

## External Review — Round 4

Findings from an external re-review of the requirements spec (Security Engineer, QA Engineer,
DevOps Engineer roles), processed one at a time with the project owner. Each finding was
re-verified against the code before processing.

#### RESOLVED: [HIGH] Loopback login handoff did not preserve or return CLI state
The loopback flow accepted `redirect_uri`/`state`/`code_challenge` but never required preserving
them across the portal-login round trip, nor echoing `state` on the final loopback redirect.
Re-verified: the existing machinery carries only a `return_to` string across the hop
(`auth_controller.ex:16`, `auth_controller.ex:32-39`), and the LiveView auth-hook precedent
builds `return_to` as path-only, dropping the query string (`report_live/auth.ex:23-25`) — an
implementer following existing patterns would lose all three params exactly when the user wasn't
already logged in, and without a `state` echo the STORY 4 listener cannot correlate the callback
to its login attempt (RFC 6749 §4.1.2 / RFC 8252 loopback semantics).
**Resolution**: Approved — added a **Request-state preservation and `state` echo** bullet to
Login handoff: `/auth/cli` validates the triple on entry and preserves it across the login hop
(server-side storage or encoded-full-URI `return_to`; mechanism is an implementation.md
decision), and the final loopback redirect carries both the one-time `code` and the original
`state` echoed verbatim. Technical Notes gained a bullet documenting the path-only `return_to`
trap.

---

#### RESOLVED: [MEDIUM] Audit fail-closed ordering could log URL issuance that never happened
The audit requirements logged rows for **successful** URL issuance while the fail-closed bullet
said the URL is issued only **after** the audit row is written — "issued" was ambiguous between
generated and returned, so an audit-then-presign implementation would satisfy the text literally
while writing audit rows for URLs that were never produced. Re-verified: presigning can fail —
`AthenaDB.get_download_url/2` returns `{:ok, url}` or an error tuple (`athena_db.ex:28-34`), and
the post-processing download path already handles that error branch live
(`post_processing.ex:176-179`).
**Resolution**: Approved — the fail-closed bullet now pins the order on every logged surface:
generate the URL first without returning it (presign failure → normal error path, no audit row);
write the audit row (write failure → discard the URL, fail closed, no URL returned); return/push
the URL only after the audit write succeeds. Both integrity invariants are now explicit: every
returned URL has an audit row, and every audit row corresponds to a URL that was actually
generated.

---

#### RESOLVED: [Follow-on] `/auth/cli` entry-validation failure behavior was undefined
Found during the post-round re-review: the new preservation bullet requires validating
`redirect_uri`/`state`/`code_challenge` on entry, but nothing said what a failed validation looks
like — and the OAuth rule (RFC 6749 §3.1.2.4) is that the server must never redirect to an
unvalidated redirect URI.
**Resolution**: Approved — the preservation bullet now specifies: a failed entry validation
(non-loopback `redirect_uri`, missing `state` or `code_challenge`, non-S256 PKCE method) renders
an error response at `/auth/cli` itself — never a redirect to the supplied `redirect_uri`, and no
one-time code is minted.

---

## External Review — Round 5

Findings from an external re-review of the requirements spec (development review), processed one
at a time with the project owner. Each finding was re-verified against the code before processing.

#### RESOLVED: [HIGH] Download endpoints did not define their success JSON shape
The spec pinned error behavior (409/404/500-class) for both `/download` endpoints but never the
`200` body — and the two existing web paths disagree on field names: the raw-CSV download pushes
`%{download_url, filename}` (`show.ex:282`) while the job download replies `%{url}`
(`post_processing.ex:184`), so STORY 4's CLI could implement a different name than the server and
tests had no canonical success contract. `AthenaDB.get_download_url/2` hardcodes a 10-minute
expiry (`athena_db.ex:33`).
**Resolution**: Approved — added a **Download success shape** Contract bullet shared by both
endpoints: `200 { "download_url": ..., "filename": ..., "expires_in_seconds": 600 }`, a bare
object (not the paged envelope); `filename` follows the existing web conventions (already in
Technical Notes); `expires_in_seconds` reports the presign expiry so the CLI never hardcodes the
window; additive-only evolution within v1. `download_url` + `filename` chosen over the job path's
`url` as the richer of the two existing shapes.

---

#### RESOLVED: [MEDIUM] Non-download responses did not prohibit raw artifact URLs
The run-metadata contract was open-ended ("includes at minimum") and the jobs Technical Note
pointed implementers at persisted job fields including `result` — a raw S3 URL. Verified: the
naive implementation leaks storage paths in both surfaces (`ReportRun.athena_result_url` is an
`s3://` URL, `report_run.ex:15`; `Job` derives `Jason.Encoder` **with `:result`**, `job.ex:11`),
blurring the story's audit boundary (URLs must come only from the logged `/download` endpoints).
**Resolution**: Approved — three changes: (1) a **No raw artifact URLs outside `/download`**
Contract bullet (list/show/jobs responses never contain `athena_result_url`, job `result`, or any
other raw storage URL; presigned URLs are issued only by the two audit-logged `/download`
endpoints); (2) the jobs-list requirement now pins the closed item shape
`{ "id", "steps": [{ "id", "label" }], "status", "has_result" }` with `result` mapped to the
`has_result` boolean (verified `Step` derives exactly `[:id, :label]`, `step.ex:2`); (3) the run
metadata bullet explicitly excludes `athena_result_url`, and the jobs Technical Note gained the
derived-encoder caveat (the API must use an explicit sanitized serializer, like the
`%ReportFilter{}` case).

---

## External Review — Round 6

Findings from an external re-review of the requirements spec (Senior Engineer, Security Engineer,
Product Manager roles), processed one at a time with the project owner. Each finding was
re-verified against the code before processing.

#### RESOLVED: [HIGH] Stored filters can break API self-start (failure scenario refuted; latent trap documented)
The reviewer claimed the self-start requirement is unimplementable: `EctoReportFilter.load/1`
leaves `filters` values as strings while `ReportFilterQuery.get_filter_query/5` matches atoms
only, so building the Athena query from a stored `report_filter` would raise
`FunctionClauseError` and a stuck run could never recover.
**Re-verification refuted the failure scenario while confirming each code observation.**
`get_query_and_params/4` is called from exactly two places — `get_options/4` and
`get_option_count/4` (`report_filter_query.ex:533,550`), the filter-form autocomplete invoked
only from `ReportLive.Form` with in-memory atom filters — never with a DB-loaded filter. The
self-start requirement pins the query build to the Show LiveView path
(`report.get_query.(report_run.report_filter, user)`, `show.ex:169`), and all five Athena-type
reports' `get_query` implementations destructure the dimension fields and never read the
`filters` list. Decisively: today's **only** query-start path already runs on DB-loaded filters
(the form only creates the row; Show mounts, loads from the DB, and starts the query), so every
production Athena run has exercised exactly the path the API will reuse.
**Resolution**: Approved as partial-agree — no requirements change to the self-start path (it
already pins the correct one), but the underlying atom-at-creation/string-on-load asymmetry is a
real trap: added a **Loaded-filter atom/string asymmetry** Technical Notes bullet (the API must
reuse `report.get_query`, never `ReportFilterQuery`, with a persisted filter; normalizing
`load/1` noted as optional hardening) and extended the self-start requirement to demand a test
that starts from a **persisted** filtered run (DB round-trip, not an in-memory struct).

---

#### RESOLVED: [HIGH] Loopback token mint timing conflicted with hash-only token storage
The loopback bullet said `/auth/cli` "mints the per-user token" before redirecting with the
one-time code, while the secret-handling bullet requires the raw token to be delivered once and
stored only in irreversible form — mutually unsatisfiable: a token minted at redirect time must
be held recoverably (plaintext or reversibly encrypted) for up to the 5-minute code window so
`POST /auth/cli/token` can return it. Verified spec-internal; no existing code resolves it (only
session OAuth tokens exist — no API-token machinery or `Phoenix.Token` usage).
**Resolution**: Approved — standard authorization-code design adopted: `/auth/cli` now creates
only a **pending authorization grant** (one-time code bound to the authenticated user and the
`code_challenge`, 5-minute expiry); the token is **minted atomically during a successful
`POST /auth/cli/token`** (mint, store irreversible form, return raw token once) — no raw token
exists before the exchange and none is recoverable after. The secret-handling bullet now also
requires one-time codes to be stored only in irreversible form, and the code-exchange contract
bullet names the exchange as the mint point. The CLI-observable contract (redirect with
`code` + `state`; exchange returns `{ "token": ... }`) is unchanged for STORY 4.

---

#### RESOLVED: [HIGH] Loopback flow did not specify portal selection/preservation
The loopback request preserved only `redirect_uri`/`state`/`code_challenge`, but tokens are
portal-scoped (users keyed by `portal_server` + `portal_user_id`) and the browser flow picks its
portal from a `?portal=` param stashed in the session — so `cc-data login` could mint a token for
the default or a stale session portal with no way for the CLI to influence it.
**Re-verified**: `Auth.Plug` calls `save_portal_url/1` on every browser request (`auth/plug.ex:12`,
`auth.ex:32-35`); `AuthController.login/2` falls back session → configured default
(`auth_controller.ex:13`). Also found: there is **no portal allowlist** anywhere today — validity
is only implicit (login queries the portal DB, whose credentials come from a per-server
`<SERVER>_DB` env var, `portal_dbs.ex:185-192`).
**Resolution**: Approved — added a **Portal selection** bullet to Login handoff: `/auth/cli`
accepts an optional `portal` parameter, validated on entry (mapped server must have a configured
portal-DB connection — the same condition login needs anyway; invalid `portal` joins the
entry-validation failure list: error at `/auth/cli`, no redirect, no code), preserved across the
login round trip with the rest of the request state, and scoping the login/token — overriding any
session portal, including forcing a fresh portal login when an existing session user's
`portal_server` doesn't match the requested portal. Fallback when omitted: existing browser
behavior (session portal, else configured default). The preservation bullet now covers the
validated quadruple, and Technical Notes gained a **Portal-selection machinery** bullet
documenting the session plumbing and the no-allowlist reality grounding the validation.

---

#### RESOLVED: [Follow-on] Concurrent duplicate code exchanges could both mint
Found during the post-round re-review: moving the mint point to the exchange (the mint-timing
fix) sharpened a loose edge — "invalid after the first successful exchange" did not rule out two
racing `POST /auth/cli/token` requests both validating before either marks the code used, worst
case minting two tokens from one code.
**Resolution**: Approved — the code-exchange contract now pins single-use enforcement as
**atomic**: exactly one exchange of a given code can ever succeed; concurrent duplicates must not
both mint, and the loser gets the same indistinguishable 400. Also considered and deliberately
left as-is: (a) no `redirect_uri` re-presentation at the token endpoint — PKCE already binds the
exchange to the initiating client, matching OAuth 2.1's direction; (b) the portal-override login
overwriting the browser session's portal — the same side effect as a manual `?portal=` login
today.
