# cc-data: Bulk-Read Function for Answers + Interactive History (Paged, Resumable)

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-76
**Repo**: https://github.com/concord-consortium/report-service
**Design doc**: REPORT-71 gist — https://gist.github.com/dougmartin/034b3004e9cd42f6e9960a478358d622
**Related specs**: [REPORT-74 (STORY 1 — auth + JSON API foundation, Closed)](../REPORT-74-cc-data-authenticated-json-api-auth-foundation.md), [REPORT-75 (STORY 2 — token-management UI, Closed)](../REPORT-75-cc-data-token-management-ui.md)
**Implementation Spec**: [implementation.md](implementation.md)
**Status**: **In Development**

## Overview

STORY 3 of the cc-data researcher toolchain adds authenticated endpoints that let a researcher
download, for a report run they own, every student's raw saved answers, the full history of how each
answer changed as the student worked, and the binary attachments those answers reference (open-response
audio recordings and offloaded CODAP/SageModeler documents) — the per-answer detail, moment-by-moment
trajectory, and rich media that the existing denormalized CSV report can't express. Because a single
report can hold tens of thousands of history snapshots, the answers/history download is delivered in
bounded, resumable pages that survive function timeouts and network interruptions; attachments are handed
out as short-lived presigned URLs from a batch endpoint. Every access is authorization-gated and
audit-logged.

## Project Owner Overview

The cc-data toolchain (REPORT-70/71) lets education researchers pull their own report data down to a
laptop and analyze it with DuckDB or an AI assistant. STORY 1 shipped the authenticated API and the CSV
report download; STORY 2 shipped the token-management UI. This story delivers the half of the data the
CSV can't express: each student's raw per-answer state and the full interactive-state **trajectory** —
every saved snapshot of an answer as the student worked, not just the final value — which researchers
need to study how learning unfolds over time, not merely where it ended. It is the read-from-Firestore
sibling of the existing report generation, consumed by the STORY-4 command-line tool (REPORT-77).

A single report can carry tens of thousands of history snapshots, so the download is delivered in
bounded, resumable pages: a researcher can pull a large class across many pages and, if the connection
drops or the tool is interrupted, resume where they left off rather than restarting. Access stays
tightly governed. The set of students a researcher may export is derived once, at the start of each
export, from the same report filters and project permissions the reports themselves apply — and every
page is re-checked against the researcher's live access token, so revoking a researcher's token cuts the
export off. Every export is recorded in the STORY-1 audit log — both the students it was *scoped to* and
the students whose data *actually left the server*, correlated by a stable export id — and the admin
audit page gains the ability to search that history by export or by individual student, so "who exported
which student's data, and when" stays answerable for IRB and breach review.

## Background

STORY 1 (REPORT-74, merged) built the authenticated JSON API foundation on the Elixir server:
- The `:api_authenticated` pipeline (`plug :force_json` + `ReportServerWeb.Api.AuthPlug`), which
  verifies a per-user bearer token, enforces `can_access_reports?`, and assigns
  `conn.assigns.current_user` (`server/lib/report_server_web/router.ex:24`,
  `server/lib/report_server_web/api/auth_plug.ex`).
- `ReportServerWeb.Api.V1.ReportController` with `index`/`show`/`download`, the ownership-gated
  `Reports.get_api_report_run/2`, keyset pagination (`Api.V1.Params`), the `{items, next_page_token}`
  envelope (`Api.V1.ReportJSON`), and the shared API error shape (`ErrorHelpers`).
- The `data_access_log` table — which **already reserves `cursor` and `endpoint_set` columns for this
  story** (`server/priv/repo/migrations/20260713080100_create_data_access_log.exs`), plus
  `AuditLog.issue_download_url/6` with fail-closed ordering.
- The Elixir→Firebase HTTP client `ReportServer.ReportService` (uses `Req`, `auth: {:bearer, token}`,
  base URL + static `REPORT_SERVICE_TOKEN` from config; `server/lib/report_server/report_service.ex`).

This story adds, on the **Elixir** side, two new `/api/v1/reports/:id/{answers,history}` endpoints that
authorize via the reports' own `LearnerData.fetch/2` learner query (deriving the allowed
`run_remote_endpoint` set live from the run's filters + the caller's `allowed_project_ids`), then proxy
to a **new Node/Firebase read** that admin-SDK-reads Firestore for exactly those endpoints and returns
paged JSON envelopes back through Elixir to the CLI. On the **Node/Firebase** side it adds a bulk read
over the `answers`, `interactive_state_histories`, and `interactive_state_history_states` collections —
the last two being surface **nothing currently exposes** (existing `get-answer` reads only single
answers).

Source derivation was validated against prod during REPORT-71 (Spike B1): the hostname portion `source =
hostname(runnable_url)` + the `activity-player-offline.concord.org → activity-player.concord.org` remap
already applied in `shared_queries.ex`; 30/30 endpoints / 2,895 docs matched, zero mismatches (the sampled
runs had no `answersSourceKey` override, so the spike validated only the hostname branch). STORY 3 uses the
report's **full** derivation `COALESCE(url_extract_parameter(runnable_url, 'answersSourceKey'),
hostname(runnable_url))` + the offline remap (`shared_queries.ex:431-436`) so override runs are not silently
missed — see the Live-endpoint-derivation requirement. Elixir
already has `runnable_url` per learner from `LearnerData.fetch` (it groups results by `runnable_url`),
so it derives the source and passes it to the Node read per endpoint.

### How the data is written (activity-player, verified)

- `createOrUpdateAnswer` (activity-player `src/firebase-db.ts:476`) writes in one atomic batch under
  `sources/{sourceKey}/`:
  - `answers/{answer_id}` — current answer state (one doc per `remote_endpoint`+`question_id`).
  - `interactive_state_histories/{historyId}` — lightweight metadata (`id`, `answer_id`,
    `question_id`, `state_type:"full"`, `created_at` server timestamp, identity fields); written only
    on **create** of a new history id.
  - `interactive_state_history_states/{historyId}` — the real snapshot: a **full copy of the answer
    doc** at that instant (so authenticated runs carry `remote_endpoint`).
- History is enabled only when the activity/sequence's `save_interactive_state_history` flag is on.
  The history id is a `nanoid` **rotated to a fresh id after every save**
  (`managed-interactive.tsx:186`), which turns single saves into a *series* of snapshots.
- **State is double-JSON-encoded**: `report_state` is a JSON string → parse → `.interactiveState` is
  itself a JSON string → parse again. Confirmed via activity-player `answer-utils.ts` /
  `embeddable-utils.ts`.
- Identity fields are **pseudonymous** (`platform_user_id`, `remote_endpoint`, `context_id`,
  `run_key`); **no name/email fields** are written to answer or history docs (verified in
  `createAnswerDoc`).

## Requirements

### Elixir bulk endpoints

- Add `GET /api/v1/reports/:id/answers` and `GET /api/v1/reports/:id/history` under the existing
  `:api_authenticated` scope (in `ReportServerWeb.Api.V1.ReportController` or a sibling controller —
  an implementation detail, not a scope decision).
- **Authz reuses STORY 1's ownership gate**: both require `report_runs.user_id == caller`
  (`Reports.get_api_report_run/2`); non-existent / not-owned / non-Athena / malformed `:id` all return
  the same indistinguishable **404 `NOT_FOUND`** (no existence leaks), consistent with STORY 1. **Note the
  malformed-`:id` 404 comes from `Params.parse_id/1`, not `get_api_report_run/2`** (which has a `when
  is_integer(id)` guard and would *raise* on a non-integer) — STORY 3's controller MUST keep STORY 1's
  `parse_id` → `get_api_report_run` order so a malformed id 404s rather than 500s.
- **Live endpoint derivation (once per export)**: on the **first** page of an export (null
  `page_token`), **after the ownership gate passes** (`parse_id` → `get_api_report_run`, so a not-owned run 404s
  *before* any expensive work — no owned-vs-not-owned timing distinguisher), Elixir runs the reports' own
  `LearnerData.fetch(report_run.report_filter, caller, allow_empty: true)` to derive the authorized learner set live. **`report_filter` MUST be normalized `nil → %ReportFilter{}`
  first (required — nil is a live state that would otherwise 500):** `report_runs.report_filter` is a nullable
  column and nil is a supported value (STORY 1 serializes it as the empty filter, `report_json.ex`
  `report_filter_json(nil)`, with a dedicated test), but `LearnerData.fetch`'s first clause pattern-matches
  `%ReportFilter{...}` (`learner_data.ex:24`), so `fetch(nil, …)` raises `FunctionClauseError` → 500. The bulk
  controller normalizes `report_run.report_filter || %ReportFilter{}` (mirroring `report_filter_json/1`) before
  deriving — a nil-filter Athena run then exports its (filter-unconstrained, permission-bounded) learners rather
  than crashing. Covered by a nil-filter acceptance scenario. From the normalized filter it then applies
  `apply_allowed_project_ids_filter` +
  `get_allowed_project_ids` exactly as the reports do. **An empty (`[]`) permission set MUST short-circuit
  to `{:ok, []}` BEFORE any SQL is built (required — otherwise it 500s, not the promised empty-200):**
  `apply_allowed_project_ids_filter` emits `project_id IN #{list_to_in(allowed)}` for every non-`:all`
  value (`report_utils.ex:106-123`), and `list_to_in([]) → "()"` → invalid MySQL `IN ()` (query error →
  500). A role-flagged researcher with **zero project rows** legitimately gets `[]`
  (`get_allowed_project_ids` → `get_project_ids` → `[]`, `portal_dbs.ex:150`) — this is the **real,
  reachable** empty-permission case. So the bulk path checks `get_allowed_project_ids(caller)` up front and,
  when it is `[]`, returns `{:ok, []}` → a **200 empty page** without calling `LearnerData.fetch` at all.
  **`:none` is NOT a reachable controller state** — `get_allowed_project_ids` returns `:none` only when all
  `portal_is_*` flags are false, which is exactly when `can_access_reports?` is false → **AuthPlug 401s
  before the controller runs** (so `:none` cannot produce a 200; treating it as an empty-200 would
  contradict the 401 path). Map `:none` to `{:ok, []}` **defensively** (belt-and-suspenders, since
  `list_to_in(:none)` would otherwise raise on `Enum.map` of an atom), but it is unreachable and is **not**
  a claimed acceptance behavior — the empty-permission 200 is asserted only for `[]`. (This is distinct from
  `allow_empty`, which handles a *non-empty* permission set that simply matches *no learners*; the
  short-circuit handles the *empty permission set* itself, which fails earlier at SQL construction.)
  **`allow_empty: true` is required**
  for the matches-no-learners case: the default `fetch`
  path calls `ensure_not_empty` and returns `{:error, "No learners…"}` on an empty set (correct for report
  generation, wrong here) — STORY 3 needs an empty set to become `{:ok, []}` → a **200 empty page**, not an
  error (see the Round-4 empty-export item; the option defaults to `false` so the existing report callers are
  unaffected) — and builds, per learner, `{remote_endpoint,
  source}` where **`source` matches the report's own derivation `COALESCE(url_extract_parameter(runnable_url,
  'answersSourceKey'), hostname(runnable_url))` + the offline remap** (`shared_queries.ex:431-436`): the
  `answersSourceKey` query param on `runnable_url` takes precedence over the host, then the
  `activity-player-offline → activity-player` remap applies. **Not hostname-only** — a run whose answers were
  written under an `answersSourceKey` override would otherwise be queried at the wrong `source` and silently
  miss all data (see Out of Scope for the accurately-scoped residual). This set is **snapshotted into
  scratch and is the authorization of record for the whole export**; every later page serves from it
  without re-deriving. The client never supplies endpoints; a persisted run never stores them. **No
  `project_id` is annotated** and none is needed — `LearnerData.fetch`'s learner map does not emit one,
  authorization is a *compound* JOIN predicate (`ac_teacher_a.project_id IN allowed AND
  (ac_assignment_a.project_id IN allowed OR apm_a.project_id IN allowed)` — `report_utils.ex:106-128`)
  not reducible to a single id, and because we do not re-authorize per page there is nothing to annotate
  against.
- **Snapshot-at-start authorization; what is (and isn't) enforced live per page**: the authorized set
  (roster + filter + project permissions) is frozen at export start; a **fine-grained** project-scoped
  change mid-export (researcher removed from one project, or a teacher/assignment pulled from a project's
  cohort/materials) is **not** reflected until a fresh export — an accepted, documented tolerance, since
  exports run long after activities and a project-level revocation racing an in-flight pull is
  vanishingly rare, and the caller owned + was authorized for the run at start. What **remains dynamic
  per page**: the `:api_authenticated` pipeline re-runs `AuthPlug` on **every** request (`auth_plug.ex`),
  which enforces exactly two things live — (a) **API-token revocation** (`verify_api_token`'s
  `where: is_nil(t.revoked_at)` fails → 401) and (b) the caller's **locally-stored** `portal_is_*` role
  flags going false (`can_access_reports?` reads the preloaded local `users` row, `auth.ex:63-65`). **A
  pure Portal-side role change is NOT live**: those flags are refreshed only at Portal-login upsert
  (`accounts.ex:47-49,69-71`), not on API-token use, so a Portal-side de-authorization carries the **same
  staleness as the derived snapshot** until the local row refreshes (re-login) or an `EXPIRED_CURSOR`
  restart re-derives. So: a **revoked token halts the export on the next page**; a **Portal role removal
  does not, until re-login** — an accepted tolerance, not an immediate cut-off. An `EXPIRED_CURSOR` restart
  (after the idle TTL) re-derives from scratch, picking up any permission change at that point.
  (Rationale + the rejected per-page /
  time-throttled / project-id-gated re-check alternatives: see the "project-annotated endpoint set"
  self-review item.)
- **Elixir proxies, Node reads**: Elixir loads the snapshot, slices the ordered endpoint list from the
  cursor's endpoint index onward, and passes that slice + source per endpoint + the inner cursor to the
  new Node read (holding the static Firebase bearer server-side — `ReportService`), receives the page,
  and returns it to the CLI. The static bearer never reaches the CLI.
- **Any Athena-type owned run id is valid** (the same 5-report set STORY 1 exposes via
  `athena_report_slugs()`). The learner set comes from the run's **filters** via `LearnerData.fetch`,
  which is report-type-agnostic (keys only off generic `%ReportFilter{}` learner fields), so the
  endpoints do **not** require the run to be an "answers report." A `teacher-actions` run — the one
  Athena report that doesn't itself use `LearnerData.fetch` — also works: its teacher/assignment/cohort/
  school filters transitively select learners, returning those students' answers/history (a documented,
  intended outcome, still bounded by the caller's `allowed_project_ids`). Consequence: because the
  learner set is purely filter-derived, these endpoints inherit whatever breadth the run's filters have
  (an under-constrained run yields a broad set — same as running the answers report itself, and
  permission-bounded).
- **`Cache-Control: no-store` on both bulk responses (required — new to STORY 3):** unlike STORY 1's
  `/download` (which returns a short-lived presigned URL in a tiny body, not the data), `/answers` and
  `/history` return raw per-answer state + full history **directly in the response body**, embedding
  pseudonymous identity fields and `remote_endpoint`s (which embed credential-grade `secure_key`s). The
  server sets no cache headers today (verified: no `cache-control`/`no-store` anywhere in `server/lib/`),
  so a researcher CLI pulling through an intermediary proxy/cache could see this body cached. Set
  `Cache-Control: no-store` (and `Pragma: no-cache`) on the two bulk responses — a small plug on the bulk
  routes or a `put_resp_header` in the controller. STORY 1 set no precedent; the data-in-body exposure is
  new, so this is stated as a requirement.

### Pagination + resumability (contract)

- **Unified envelope** (same as STORY 1): `{ "items": [...], "next_page_token": "<opaque>" | null }`;
  `limit` query param in; `page_token` echoed back as the request param (AIP-158, as STORY 1).
  `next_page_token` is null on the last page; the CLI loops until null.
- **`limit` bounds are STORY-3-specific, NOT STORY 1's clamp (required — reusing STORY 1's is a
  self-contradiction):** STORY 1's `Params.parse_limit` clamps to `@default_limit 50` / `@max_limit 200`
  (`params.ex:2-4,13`, verified by execution: `limit=500 → 200`, omitted → 50). STORY 3's page cap is
  **~500 returned items/page** (see Server-side scratch), so reusing STORY 1's parser would make the
  default 50 (invalidating every cost figure below, which assume ~500) and make `limit` unable to ever
  reach 500. STORY 3 therefore uses its **own** limit parser with `@default_limit ~500` and
  `@max_limit ≥ 500` (do **not** widen STORY 1's shared `@max_limit`, which would perturb `/reports` page
  size + its test at `report_controller_test.exs:115`). **`limit` only *lowers* the ~500 cap** (a caller
  may request a smaller page; it may not raise the cap above the server max) — the CLI (STORY 4) sizes its
  request loop against this. This supersedes the earlier "clamped like STORY 1" wording anywhere below.
- **Termination is signalled *solely* by `next_page_token == null` — `items: []` is NOT end-of-stream.** A page
  MAY legitimately return `items: []` with a **non-null** `next_page_token` (e.g. a page that filled its endpoint
  budget on learners who have answers but no history → empty history page mid-export, see "History mechanic —
  minor cases"). The CLI **MUST** keep requesting until `next_page_token` is null and **MUST NOT** treat an empty
  `items` array as completion — doing so would silently truncate the export (a silent research-data-loss trap).
  (Covered by the "Empty mid-export page" acceptance scenario.)
- **Stable iteration order + monotonic progress (consumer-facing guarantee)**: the endpoint iteration order is
  fixed by the export snapshot (frozen in scratch) and is **stable across all pages** of an export; progress is
  monotonic modulo the tolerated at-least-once re-delivery. The CLI may rely on this.
- **No total-count / progress signal in v1** (intentional): the envelope is strictly loop-until-null; there is no
  page-count or "N of M" (a total would require an extra full traversal). Deferred as an additive field if a
  future CLI needs it.
- **Bounded work per call**: each page reads a bounded chunk sized to stay well within the Cloud Function
  timeout **and** under the HTTP response-size cap (see Technical Notes) — never a single long stream.
  Bounded by **three** independent caps — a returned-item cap (`limit`, ~500), an endpoints-walked cap
  (`endpoint_limit`), and a pre-filter raw-doc-read cap (`read_limit`) — a page returns when **any** is hit.
  `endpoint_limit` catches the answers-but-no-history-learners case (0 items, whole slice scanned);
  `read_limit` catches the one-learner-with-a-huge-filtered-history case (0 items, thousands of docs read
  then dropped by the `remote_endpoint` filter). See the internal wire contract's page-bounds bullet.
- **Paginate by learner**: outer position = which endpoint (learner) we're on; inner paging = that
  learner's Firestore cursor. **No `offset()`** (Firestore bills skipped docs). Per learner we query a
  single endpoint at a time (not `remote_endpoint in […]`, which caps at 30 and has no single native
  cursor), so:
  - **answers**: `answers where remote_endpoint == x` ordered by `__name__` (doc id) — a total order, no
    timestamp needed.
  - **history**: `interactive_state_histories where {LTI tuple}` ordered by `created_at` **plus
    `__name__`** as the total-order tiebreaker (see Firestore read surface). Note this makes the
    per-learner inner cursor a `{created_at value, docId}` pair for history and a `{docId}` for answers.
  - **History cursor precision + type (required — a lossy `created_at` skips snapshots)**: `created_at`
    is a Firestore `Timestamp` (a `serverTimestamp`, **microsecond** precision — Firestore truncates the
    nanosecond field below 1µs, verified on the emulator; activity-player `firebase-db.ts:604`). The inner cursor
    MUST carry it as the Timestamp's full `{seconds, nanoseconds}` **integers only** (µs-granular), and Node
    MUST reconstruct a `Firestore.Timestamp` for `startAfter(createdAt, docId)` — **never** a JS millis
    number and **never a "raw ISO" cursor** (verified: `Timestamp.fromDate(new Date(iso))` truncates to
    milliseconds — `.123456Z → nanoseconds:123000000` — silently re-losing the µs the cursor must preserve,
    reintroducing the skip below; and a bare number mis-compares against a Timestamp field). ISO stays fine
    for the *wire* `created_at`, **never** for the cursor. The
    `__name__` tiebreaker only disambiguates rows at an **exactly-equal** `created_at`; a cursor value
    that rounds **up** silently skips every snapshot in that sub-ms window (**data loss**), while
    rounding **down** merely re-reads (a duplicate, tolerated by dedup-at-read). If any lossy encoding is
    unavoidable it MUST floor, never round up. (portal-report's slider query orders by `created_at`
    without an explicit `__name__` and takes no cursor, so it is **not** a precedent for this round-trip.)
    **Node MUST guard the reconstruction (required — `new admin.firestore.Timestamp(s, n)` is strict and
    *throws* on string args or `nanoseconds ∉ [0, 999999999]`, verified):** validate the cursor's
    `seconds`/`nanoseconds` are integers in range and reject as **`BAD_REQUEST`** otherwise (or have Elixir
    decode-and-validate the inner cursor's numeric fields before forwarding). Without this, a base64/JSON-
    valid cursor carrying `nanoseconds:1000000000` or stringified numbers passes a shallow Elixir
    "decodable?" check yet throws at Node's `new Timestamp()` → an uncaught **500**, not the Round-4
    `BAD_REQUEST` guarantee (`get-answer.ts:37-40` surfaces throws as a generic error). See the matching
    acceptance scenario.
- **Opaque composite cursor**: `next_page_token` references (a) the server-side scratch id (the
  snapshotted endpoint set), (b) the endpoint index, and (c) the inner Firestore cursor
  (base64'd — a `DocumentSnapshot` can't be serialized: `{docId}` for answers, `{created_at, docId}` for
  history). The client round-trips it opaquely; the server unpacks all three.
- **Cursor integrity is enforced by capability + re-check, not by signing** (see Round-4 security items).
  The token is base64 plaintext (as STORY 1) and is **not** HMAC-signed, so it must not be *trusted*: (i) the
  `scratch_id` is an **unguessable capability** — `Base.url_encode64(:crypto.strong_rand_bytes(32), padding:
  false)`, minted per export, **not** the table PK (reuses the `auth_grants` mint idiom); (ii) **every page load
  re-verifies scratch ownership** by an **identity** match `WHERE scratch_id == ? AND user_id == ^caller.id
  AND report_run_id == ^id AND data_type == ^route` (**no** expiry predicate — expiry is the separate
  serve-vs-410 branch, see the two-step Read-time-expiry lookup), returning the indistinguishable
  **404** on no match, so a token naming another export's scratch (or the sibling route's scratch) resolves to
  nothing; a matched-but-expired row yields **410**, not 404; (iii) the `endpoint_index` is validated `∈ [0, len)` and a
  malformed inner cursor is rejected `BAD_REQUEST` after the (ownership-checked) scratch loads — and because
  Node's Firestore `where` clause is set **server-side** from the scratch slice, an injected inner cursor can only
  re-position `startAfter` **within** the already-authorized endpoint, never widen the query. The inline
  `EXPIRED_CURSOR` delete carries the same ownership predicate.
- **Scratch is route-bound by a `data_type` column in the ownership guard (required — shape rejection alone
  is insufficient):** each scratch row carries its route `data_type` (`answers_bulk` / `history_bulk`) and
  the ownership guard includes `AND data_type == ^route`, so a `/history` token replayed against
  `/reports/:id/answers` (same user, same run) fails the guard → the indistinguishable **404**. This is
  **mandatory, not the optional stricter alternative** it was first framed as, because inner-cursor **shape
  rejection cannot cover a `null` inner cursor**: at an endpoint boundary the next token legitimately has
  `inner_cursor: null` (a fresh endpoint start), which has no answers-vs-history shape to reject, so a
  null-cursor `/history` token would otherwise replay cleanly on `/answers`. Same user/run means no
  confidentiality leak, but it would feed answers items into the CLI's history export (or vice-versa) —
  data-integrity corruption for STORY 4. Shape validation is **still** kept as defense-in-depth (a
  non-null wrong-shape cursor → `BAD_REQUEST`), but the `data_type` guard is the primary, complete defense.
  Covered by the cross-route-replay acceptance scenario (including the `null`-inner-cursor case).
- **Cursor ownership (tier split) — Elixir owns all cursor/scratch state; Node stays stateless.** Per
  page: (1) **Elixir** parses the incoming `page_token` → `{scratch id, endpoint index, inner cursor}`,
  loads the scratch snapshot **under the two-step ownership/expiry lookup** (identity `WHERE scratch_id == ?
  AND user_id == ^caller.id AND report_run_id == ^id AND data_type == ^route` → 404 on no match; matched-but-
  expired → 410 `EXPIRED_CURSOR`; active → serve + bump; see the Read-time-expiry lookup + the cross-route
  `data_type` requirement), validates `endpoint_index ∈ [0, len)` (else `BAD_REQUEST`), and hands **Node** an *ordered
  endpoint slice* (from the current index onward, each with its `source`) + the starting inner cursor.
  (No per-page re-derivation — authorization was snapshotted at export start; the pipeline still enforces
  total access loss per request.)
  (2) **Node** walks the slice in order, reading until any of the three caps (`limit`/`endpoint_limit`/
  `read_limit`) is hit, and returns `items` + the **slice-relative `stop_endpoint_offset`** of the endpoint
  it stopped **on** + that endpoint's inner Firestore cursor + the *`endpoint_exhausted`*
  flag + any freshly-derived LTI tuples (`touched_endpoints`) — it never sees the scratch id or the token
  format (see the internal wire contract). (3) **Elixir** persists the returned tuples into scratch, then
  reassembles the next `page_token` (same scratch id + new absolute index **per the `endpoint_exhausted`
  rule** — exhausted → `current_index + stop_endpoint_offset + 1` with a **null** inner cursor;
  not-exhausted → `current_index + stop_endpoint_offset` with the returned inner cursor; see the wire
  contract's `stop_endpoint_offset` bullet), or emits `next_page_token: null` when the **last** endpoint of
  the scratch set is exhausted. Node is a pure Firestore reader; every stateful decision lives in the tier
  that holds the scratch and the auth context.
- **Idempotent retry**: requesting the **same cursor twice must be safe** (no double-advance). The page
  is identical (authorization is snapshotted at export start, so it does not shift between two retries of
  the same token); a caller whose **API token is revoked** (or local role flags cleared) between the two is
  rejected with **401** at the pipeline, not served a partial page. **This holds for the terminal page too**: the
  scratch row is retained after the final page (not inline-deleted), so replaying the terminal
  `page_token` re-serves the identical final page rather than returning `EXPIRED_CURSOR` — cleanup of
  completed exports is left to the TTL sweep (see Server-side scratch → Cleanup).
- **At-least-once + dedup-at-read**: a crash between "append page" and "persist cursor" can re-deliver a
  page on resume, so duplicate items are possible on the wire and on disk. This is tolerated; the CLI
  (STORY 4) dedups by stable id (`answer_id` / `history_id`, keep latest `created_at`). The **server
  does not** guarantee exactly-once delivery.
- **`EXPIRED_CURSOR`**: because the CLI persists `last_cursor` locally but the server scratch has a
  short TTL, a resume after the TTL lapsed returns **`EXPIRED_CURSOR`**; the CLI discards its partial
  file and restarts the export from a null cursor (re-derives the endpoint set). Restart-on-expiry is
  the required floor.
- **Node read failure mid-page**: a failed Node/Firestore read (unavailable, network error, partial
  read) → Elixir returns **`SERVER_ERROR`**, writes **no** audit row, and does **not** advance the
  cursor; the CLI retries the same `page_token` idempotently (safe — nothing advanced). Mirrors STORY
  1's "presign fails → normal error path, no audit row."

### Firestore read surface (Node)

- Per endpoint, under the single computed `source` (`sources/{source}/...`):
  - **answers**: `answers where remote_endpoint == x`, cursor-paginated ordered by `__name__` (doc id) —
    served by Firestore's **automatic single-field index** (no composite needed). One doc per
    `remote_endpoint`+`question_id`.
  - **interactive history — keyed by the LTI identity tuple, NOT `remote_endpoint`** (corrects the
    design doc): the metadata collection `interactive_state_histories` carries the authoritative
    sortable `created_at` (Firestore `Timestamp`) but **has no `remote_endpoint`**; the state
    collection `interactive_state_history_states` has `remote_endpoint` but its only timestamp is the
    non-lexicographically-sortable `created` string (`new Date().toUTCString()`). So per learner:
    1. `answers where remote_endpoint == x limit 1` → read `{platform_id, resource_link_id,
       platform_user_id}` (the exact strings Firestore stored; the metadata doc is built from the same
       answer doc, so they match).
    2. `interactive_state_histories where platform_id == … where resource_link_id == … where
       platform_user_id == …` `orderBy(created_at, __name__)`, `startAfter(cursor).limit(M)` — a clean
       cursor-paginated per-learner query returning all the learner's snapshots across all questions in
       chronological order. This mirrors portal-report's proven slider query
       (`portal-report/js/actions/index.ts:174`).
    3. Batch-get the matching `interactive_state_history_states/{historyId}` docs for the payloads.
    4. **Filter the fetched state docs to the exact authorized `remote_endpoint`** for this endpoint
       index. **Required, not optional**: the LTI tuple `(platform_id, platform_user_id,
       resource_link_id)` = `(portal, student.user.id, offering.id)` is **1:many** to `remote_endpoint`
       — `portal_learners` has **no unique constraint on `(student_id, offering_id)`** and
       `find_or_create_learner` is non-atomic (verified in rigse: `portal/learner.rb`,
       `portal/offering.rb:33`, `schema.rb:626`), so one (student, offering) can have multiple
       `secure_key`s → multiple `remote_endpoint`s. The tuple query returns snapshots for **all** of
       that student+offering's `secure_key`s; the state docs carry `remote_endpoint`, so filtering to
       the authorized one keeps history **provably scoped to the exact audited endpoint set**. Not a
       security leak either way (duplicate rows share offering→project→permission), but without the
       filter the logged `endpoint_set` wouldn't name the sibling endpoint whose snapshots leaked in —
       an audit-fidelity gap. In the common 1:1 case the filter is a no-op; in the rare duplicate case
       each endpoint index keeps its own `remote_endpoint` (union = all **authorized** siblings, no double-count).
       **Caveat:** a sibling `secure_key` that the run's date/permission filters exclude has no endpoint index, so
       the shared-tuple history query pulls its snapshots in and every authorized index drops them — that
       sibling's history is intentionally omitted (correct scoping: it is genuinely unauthorized for this run).
       History is thus bounded by the same per-learner filter as `/answers` (which never queries the excluded
       endpoint) — the two stay symmetric; "union = all" means all *authorized* siblings, not all of a student's
       raw `secure_key`s.
  - Both history collections are **new read surface** for `functions/` (nothing there exposes them
    today).
- **Trust boundary — the Node function is authorization-blind by design.** Like `get-answer`, it does
  **no** project/ownership authz: it trusts Elixir to have authorized and to pass only permitted
  endpoints, and is protected solely by the static `AUTH_BEARER_TOKEN` (server-to-server). The blast
  radius is far larger than the single-record endpoints (one call returns all of many learners'
  answers + full history), so the boundary must be stated **accurately** — the routes live on the
  **public** gen1 `api` `https.onRequest` function, so they *are* internet-reachable; "isolation" is not
  a network fact but the sum of these controls:
  - (a) **Static-bearer-gated, and Elixir is the sole *intended* caller** — the function cannot tell an
    authorized caller from anyone else holding the token, so the real perimeter is **secret hygiene**,
    not unreachability. (The earlier "must never be reachable by any client that could supply arbitrary
    endpoints" was aspirational and is corrected here: it is reachable; it is gated.)
  - (b) **Elixir is the sole authz chokepoint** — all project/ownership decisions happen in Elixir
    before the Node call; Node only reads the endpoints it is handed.
  - (c) **The static bearer stays server-side only** (Elixir↔functions), never shipped to the CLI/client
    — same trust model as `get-answer`, just larger blast radius.
  - (d) **Header-only bearer on the bulk routes** (cheap hardening, no second secret): the shared
    `bearer-token-auth` also accepts the token as a `?bearer=` **query param** (and body —
    `bearer-token-auth.ts:23-34`), which can leak into access/proxy logs — an outsized risk for this
    route's blast radius. An org-wide search (2026-07-14) confirms **every** real caller (LARA
    `report_service.rb:118`, rigse `students_controller.rb:248`, query-creator `firebase.js`, the Elixir
    server) already uses the `Authorization: Bearer` **header** and **no caller uses the query-param/body
    form**, so the bulk routes require the header and reject the query-param/body bearer — closing the
    URL-logging vector without a second secret and without breaking any caller. **This is not a free
    property of the existing middleware and must be implemented as such**: the shared `bearer-token-auth`
    runs for every route, *accepts* all three token sources, and records nothing about which one
    authenticated, so a `?bearer=` request is already past it before any handler runs. Enforce header-only
    with a **small per-bulk-route guard** that runs after the shared middleware and returns **401** if
    `req.query.bearer` or `req.body.bearer` is present (the bulk routes thus require the header form
    specifically). **The guard MUST be a key-existence check, NOT `typeof === "string"` (required):** the
    shared middleware guards with `typeof req.query.bearer === "string"` (`bearer-token-auth.ts:23`), but
    `?bearer=a&bearer=b` and `?bearer[0]=<TOKEN>` parse to an **array** and `?bearer[x]=<TOKEN>` to an
    **object** (verified via qs/Express) — a `typeof === "string"` guard copied from the middleware would
    let a `?bearer[0]=<TOKEN>` that *also* carried a valid header slip past and land the token in the URL/
    access log, defeating the guard's purpose. Use `"bearer" in req.query || "bearer" in req.body` (or a
    truthiness check) so **any** query/body form the guard sees — scalar, array, or object — is rejected
    (**401**). **Layer note (not a gap):** an array/object query form presented *alone* (no valid header)
    never reaches the guard — the shared middleware doesn't extract it (`typeof !== "string"`) and returns
    **400 "No bearer found"** first; that is still a rejection (the token is not honored), just at the shared
    layer. So the guard catches scalar-query/body forms and array/object-*with*-header (401); the shared
    middleware catches array/object-*alone* (400); either way a bulk route never honors a non-header bearer
    (see the "Header-only bearer" acceptance scenario). This deliberately **leaves the
    shared middleware unchanged**, so `get-answer` and every
    other co-located route keep accepting all three forms and no existing caller breaks; only the two new
    bulk routes are tightened. **A separate secret was considered and declined**: all report-service tokens
    live in the same server config, so a second secret adds rotation burden without materially shrinking the
    config-compromise surface; the query-param log-exposure it would have addressed is instead removed
    directly by (d).
- **History volume**: **`/history` always returns the full series** (its whole purpose is the
  trajectory). There is **no `history_mode` param in v1** — "latest state per answer" is served by
  `/answers` (the answer doc equals the latest `interactive_state_history_states` snapshot for `report_state`
  and scalar fields; activity-player `firebase-db.ts:531`). **Not** byte-identical, though: the answer doc is
  written with Firestore `merge:true` (deep-merges nested maps) while the history-state doc is a JS shallow
  spread (wholesale-replaces nested maps), so a nested `answer` map that drops a sub-key on a later save can
  differ between the two (verified by simulation, Round-4 data item) — `/history` remains the authority for a
  snapshot's exact nested state. Server-side `latest-N` slimming is **deferred** as a
  purely additive, backward-compatible param if a future CLI need arises.
- **Raw state passthrough**: the Node read returns the docs **as stored** (state left
  double-JSON-encoded); decoding is the CLI's job. The server does not decode
  `report_state.interactiveState`.
- **Authenticated learners only**: the answers read keys on `remote_endpoint` and the history read on
  the LTI tuple derived from it — both exist only for authenticated (portal/LTI) runs. Anonymous/offline
  `run_key` runs are out of scope (and by construction aren't part of a portal report). Documented
  boundary, no code.
- **Composite index — exists in prod, MISSING in dev (verified via `firebase firestore:indexes`)**:
  the required `interactive_state_histories` index `(platform_id, platform_user_id, resource_link_id,
  created_at, __name__)` is present in **`report-service-pro`** (console-created for portal-report's
  own-work slider) but **absent from `report-service-dev`** — dev only has the two `context_id`-led
  variants (teacher/shared-work views), which cannot serve a query that doesn't filter on `context_id`
  (equality fields must be an index prefix). The `answers` query needs no composite (auto single-field
  index). **Required prerequisite task**: **create the `interactive_state_histories (platform_id,
  platform_user_id, resource_link_id, created_at)` composite index in `report-service-dev`** before the
  history query is tested there. This project manages Firestore indexes **manually** (its
  `firestore.indexes.json` is intentionally empty; many indexes are console-created) — create it via the
  console (or the click-to-create link the first failing query emits), or optionally capture it in
  `firestore.indexes.json`; either is acceptable per project practice.

### Item shapes (wire)

- **Raw doc passthrough** (matches the existing `get-answer`, which returns `snapshot.docs[0].data()`):
  items are the raw Firestore docs, with the doc id folded in. Safe to pass through raw — identity
  fields are pseudonymous (no name/email), and the only URL-ish field, `attachments[*]`, holds storage
  **path references** (`publicPath`/`folder`/`contentType`), not signed URLs/credentials, and is
  already returned raw by `get-answer`. Collaboration runs additionally carry `collaborators_data_url` +
  `collaboration_owner_id` (`firebase-db.ts:565-571`); these also pass through raw — the URL is a plain
  peer-bearer-Pundit-gated REST endpoint with **no token embedded** (rigse `create_collaboration.rb:59`,
  `collaboration_policy.rb`), i.e. **not** credential-grade (unlike `remote_endpoint`, which embeds
  `secure_key`). No name/email/token fields are in the returned docs.
- Each **`/answers`** item = the raw answer doc (which already carries its own `id` = `answer_id`,
  plus `source_key`, `remote_endpoint`, `question_id`, `report_state`, `created`, `platform_user_id`,
  `platform_id`, `resource_link_id`, `context_id`).
- Each **`/history`** item = the raw `interactive_state_history_states` doc (a full answer-doc copy)
  **plus** `history_id` (the doc id) and the authoritative **`created_at`** (ISO 8601) and
  `answer_id`/`question_id` from the metadata doc. **Node MUST explicitly convert the metadata `created_at`
  Firestore `Timestamp` to an ISO string** (`.toDate().toISOString()`) before folding it into the item — a raw
  `Timestamp` left on the item serializes through `res.json`/`JSON.stringify` as `{_seconds,_nanoseconds}`,
  **not** ISO, silently breaking this contract (verified, Round-4 Node item). The
  CLI's "keep latest `created_at`" dedup relies on this metadata `created_at`, **not** the state doc's
  unsortable `created` string; **because the wire ISO string is millisecond-precision** (`toISOString` truncates
  the µs the cursor preserves), the CLI **MUST break `created_at` ties by `history_id`** so two sub-ms-apart
  snapshots aren't conflated.
- **State stays double-JSON-encoded** on the wire (`report_state` → `.interactiveState`); the CLI
  double-decodes (portal-report confirms the same double-parse, `report-reducer.ts:315`). **The inner
  `interactiveState` parse can legitimately yield a `string | object | null | array`** (a raw-string
  interactiveState round-trips to a string — activity-player `embeddable-utils.ts:72-77`), so the CLI must
  double-decode in a try/catch and not assume the inner value is always an object (both existing readers do —
  `answer-utils.ts:31-32`, `report-reducer.ts:315-327`).
- **Raw passthrough couples the v1 wire shape to Firestore's stored doc shape** (accepted): a breaking
  activity-player doc-shape change would require a v2 (or an explicit projection layer). Accepted for v1 to match
  `get-answer` and stay future-field-tolerant.
- Envelope items include enough provenance for the CLI's `run_id`-scoped dedup — but `run_id` itself is
  synthetic (the CLI attaches it from its manifest), so items need not carry it.

### Attachment download (batch presigned URLs)

**Why.** `report_state` (and history `interactive_state`) can reference **S3 attachments** rather than inline
the payload — `__attachment__` (whole interactive state offloaded ≥400 KiB; CODAP/SageModeler via
`cloud-file-manager`) and `audioFile` (open-response audio). The bulk-read walker returns these references
**verbatim** and never resolves them (resolving inline would re-inflate multi-MB payloads into the page — a real
CODAP `file.json` measured **2.9 MB** — defeating the response-byte budget). The attachment bytes live in a
**private** S3 bucket (verified: `token-service-files-private` staging / `cc-student-work` production, public
access blocked, 403 unauthenticated), so a client cannot fetch them directly. This endpoint hands the client
**short-lived presigned GET URLs** for the attachments it needs.

**Endpoint.** `POST /api/v1/reports/:id/attachments` — a third sibling to `/reports/:id/answers` and
`/reports/:id/history`, with the run id in the **path** (`:id`, the durable auth handle — see below), same
per-user bearer + run-ownership check. **POST** (not GET like its siblings) because it carries a batch body.
Batch by design — a client rendering a page of answers commonly needs many attachment URLs at once.

```
POST /api/v1/reports/:id/attachments               // :id = report_run_id (durable auth handle)
body: { "disposition": "attachment"|"inline",       // OPTIONAL, default "attachment"
        "attachments": [ { "collection": "answers"|"history", "source": <s>, "doc_id": <answer_id|history_id>,
                           "name": <attachment name, e.g. "file.json" | "audio1762….mp3"> }, … ] }   // ≤ 500
→ 200 { "expires_in_seconds": 600,
        "results": [ { "doc_id":…, "name":…, "url": <presigned GET> }
                   | { "doc_id":…, "name":…, "error": "not_found"|"not_authorized" }, … ] }
```

- **`disposition` (per-request, default `attachment`).** `attachment` → the presigned URL forces a download
  (`response-content-disposition: attachment; filename=<name>`), matching STORY-1 CSV downloads; safe default
  (a browser never *renders* the content). `inline` → `response-content-disposition: inline` +
  `response-content-type: <the attachment's contentType>`, so audio plays / JSON renders when the URL is opened
  in a browser — the opt-in path for a client that hands out clickable links. Applies to every item in the
  batch; a client that wants both flavors makes two calls. Invalid values → 400.

- **Cap 500** (reuse the page `limit` ceiling); validated `1..500` at the boundary. **Partial success**: a bad/
  unauthorized/missing item yields a per-item `error`, never fails the whole batch.
- **TTL 600 s** (reuse STORY 1's presign TTL), surfaced as `expires_in_seconds`.

**Authorization — durable, NOT the export scratch.** The scratch/`page_token` has a 1-hour TTL; a user may pull
attachments **days or weeks later**, so this endpoint re-derives authorization from the **durable**
`:id` (the `report_run_id` in the path), exactly like bulk-read **page 1** (minus caching):
`Reports.get_api_report_run(user, id)` (ownership) → derive the authorized `endpoint_set` fresh (`LearnerData.fetch` +
`allowed_project_ids`) → require each attachment's owner `∈ endpoint_set`. Re-deriving reflects **current**
permissions (if the user has since lost class access, signing is correctly denied) and costs one derivation per
call regardless of batch size (a short per-`(user,report_run)` cache is a possible later optimization).

**IDOR guard (critical).** report-service's server creds hold `s3:GetObject` on the **entire**
`<private-bucket>/interactive-attachments/*` prefix (every learner's attachments — verified in both accounts),
and a presigned URL authorizes **as the signer**. So the server must **never** sign a client-supplied path: for
each item it **re-reads the doc itself** (`sources/{source}/answers/{doc_id}` or `…/interactive_state_history_states/{doc_id}`)
for the **authoritative** `attachments[name].publicPath`, authorizes the **doc's `remote_endpoint`** (the
learner whose answer it is) `∈ endpoint_set`, then presigns the authoritative key. The client's `publicPath`
(which it does receive in the bulk-read item) is never trusted. **Authorize on the doc's `remote_endpoint`, not
`folder.ownerId`**: `folder.ownerId` (a LARA field = the creating learner's endpoint) usually equals
`remote_endpoint`, but LARA's "run with others" case legitimately makes them differ (an answer can carry an
attachment owned by the original creator) — gating on `folder.ownerId` would wrongly deny a file that is
genuinely part of the authorized learner's answer. A doc with **no `remote_endpoint`** (anonymous/`run_key`, out
of scope) resolves to `not_authorized`. (See implementation self-review #4 for the data + LARA-source rationale.)

**Consent scope for run-with-others (IRB).** When `folder.ownerId` is a *different* learner B than the doc's
`remote_endpoint` A (A's answer references an artifact B created in a collaborative run), a researcher authorized
for A receives B's file. This is **acceptable and intended**: run-with-others collaboration happens **within a
shared class/activity context**, so B is a co-participant in the same offering A's report covers, and B's
participation permission is **implicit in the collaboration** — the same consent regime under which the answer was
authored and is being reported. The endpoint therefore does **not** separately re-check B's permission form; it
authorizes on the answer the researcher is entitled to see. (Re-adding an `ownerId` gate to "protect B" would
break legitimate collaborative artifacts and is explicitly not done.)

**Presign — report-service's own SERVER creds, no token-service brokering.** report-service runs in the **same
AWS account as the private bucket per environment** and already holds the scoped `GetObject` grant (added for the
existing `transcribe_audio.ex` step), selected by the single existing env var `TOKEN_SERVICE_PRIVATE_BUCKET` →
`TokenService.get_private_bucket/0`. So a resolve is a thin presign with **server creds** (`:aws_credentials`) —
build `s3://#{get_private_bucket()}/#{publicPath}` (exactly as `transcribe_audio.ex` does) and sign it, with
**no** `getCredentials`/`readWriteToken` dance. This uses a new `Aws.presign_server_get/2` (server creds +
`disposition`/`content-type` options) — **not** the existing `Aws.get_presigned_url/3`, which signs with
**workgroup** (per-user Athena) creds that are the wrong trust boundary and can't read the attachments bucket.
(Firestore lives in Node, so the doc re-read is a small Node metadata helper; Elixir does the authz + presign.)

**Audit — one row per call.** Reuse `data_access_log` at bulk-read's per-page granularity: one row per sign
request (event `attachment_urls_issued`, `data_type: "attachment"`), recording the **distinct
`remote_endpoints`** actually signed (in `endpoint_set`), `export_id`-nullable (the durable
`report_run_id` correlates it). Answers "which learners' attachments did user U access, and when" without a
per-file row explosion (a 500-batch re-signed every 10 min while scrolling would otherwise flood the table).

**Validated end-to-end on real staging data (2026-07-15)** with only client-visible coordinates: server re-read
→ authoritative `publicPath` → owner-∈-endpoint check → presign (broad staging creds) → **HTTP 200, 2.9 MB CODAP
document** fetched via the URL with no client creds. History attachments (`file-{ts}.json` on a state doc) are
structurally identical (`collection:"history"`, `doc_id:history_id`).

### Audit logging (reuse STORY 1's table)

- **Two row kinds, correlated by a stable export id.** Every `data_access_log` row this story writes
  carries the **export id = the scratch id**, so all rows of one export (the intent row + every page's
  access row) are queryable together — this answers "which students were in export E?" cleanly.
  **Schema addition**: STORY 1's `data_access_log` has no free column for this (`cursor` holds page
  progress and is null on the intent row), so add a **nullable `export_id :string` column** (small
  migration, this story owns migrations already) with an index for the correlation query. Null on
  STORY 1's CSV/job rows. **The `DataAccessLogEntry` changeset must be extended (required, else every bulk
  request fails fail-closed):** add `field :export_id, :string` to the schema, add `:export_id` to the changeset
  `cast` list, and widen the two `validate_inclusion` allow-lists — `event` to
  `["download_url_issued", "export_scoped", "bulk_read"]` and `data_type` to
  `["run_csv", "job_result", "answers_bulk", "history_bulk", "export_scoped"]`. STORY 3 writes via
  `AuditLog.create_entry` (or a new fail-closed bulk helper), **not** `issue_download_url` (which hardcodes
  `event: "download_url_issued"`). See the Round-4 audit-changeset item.
  - **Intent row — once, at export start** (`event: "export_scoped"`, `data_type: "export_scoped"`):
    `endpoint_set` = the **full derived endpoint set** for the run (the same set cached into scratch on
    page 1). This is the snapshot-accurate "who this export was **scoped to**" record. It is **not**
    losslessly re-derivable later (re-running `LearnerData.fetch` reflects *current* roster/permissions,
    which drift), and there is no follow-on **server-side** story (REPORT-77/STORY 4 is the Go CLI, which won't
    build Elixir audit surfaces) — so it is captured now. Nearly free: the set is
    already materialized for scratch on page 1.
  - **Access rows — per page** (dedicated `event: "bulk_read"` — **not** the reused `download_url_issued`, since
    a bulk Firestore read issues no download URL; distinct `data_type` `answers_bulk` / `history_bulk`):
    `endpoint_set` = the endpoints **actually served on that page**. This is the
    truthful "what data **left the server**" primitive — the one IRB/breach review needs, and the one
    that can't be backfilled.
  - Keeping intent and access as **distinct labeled rows** prevents conflating "scoped to" with
    "actually exported" (the intent set would otherwise over-report exposure).
- All rows also carry: `source: "api"`, requesting `user_id`, `report_run_id`, `report_slug`,
  `report_filter` snapshot, and the page **`cursor`** (progress; null on the intent row). Per-page
  events fill the `cursor`/`endpoint_set` columns STORY 1 reserved.
- **`EXPIRED_CURSOR` restart mints a new scratch → new export id** (accepted): one logical pull that was
  restarted shows two export ids in the log, each a real, distinct authorized derivation.
- **`/answers` and `/history` are independent exports with distinct `export_id`s** (their inner-cursor shapes
  differ — `{docId}` vs `{created_at, docId}` — so they cannot share one scratch). A researcher's logical "pull
  run 42" is therefore **two** exports / two `export_id`s; correlating a researcher's full pull requires filtering
  the audit log by `report_run_id` + `user_id`, **not** a single `export_id`. The admin `export_id` filter is
  understood as *per-endpoint-export*, and the `remote_endpoint` search (which matches across all of a run's
  export rows) is the cross-endpoint "which exports touched student X" primitive.
- **Retry distinguishability**: a retried page is distinguishable from new access via `(user,
  report_run, data_type, export id, cursor)`; the log is append-only (never suppress an audit write to
  dedup).
- **Fail-closed ordering**, mirroring STORY 1: derive/read the page, then write the audit row; only
  after the audit write succeeds is the page returned. An audit-write failure fails the request closed
  (`SERVER_ERROR`), returning no data. The intent row is written (fail-closed) before the first page is
  returned.
- **Page-1 atomicity (scratch row + intent row)**: `AuditLog.create_entry` is a bare `Repo.insert`
  (`audit_log.ex:45-48`), and page 1 both creates the scratch row and writes the intent row. Wrap these in
  an **`Ecto.Multi`/`Repo.transaction`** so the scratch row and its intent row commit **both-or-neither** —
  otherwise a scratch inserted before a failing intent-audit write persists (page-1 retry re-derives and
  mints a fresh `export_id`, churning ids + leaving a swept orphan), or an intent row is written for a
  page-1 whose data never left the server (muddying the "scoped-to vs actually-exported" distinction).
  Neither is corruption or a leak (orphans are swept; intent-only over-reports, the safe direction), but
  the atomic page-1 write removes both. The per-page access row is written after (fail-closed) as above.
- The `endpoint_set` columns make the audit log itself a record of which students were accessed — it is
  sensitive and inherits the admin-only read surface + indefinite retention from STORY 1.
- **`endpoint_set` stores full `remote_endpoint`s (which embed the learner `secure_key`) — accepted, not
  masked.** This story is the **first** to actually populate `endpoint_set` (STORY 1 reserved the column
  but only ever wrote `nil`), and a `remote_endpoint` is
  `"{site_url}/dataservice/external_activity_data/{secure_key}"` (rigse `portal/learner.rb`), i.e. it
  embeds the credential-grade `secure_key`. Storing and rendering it **raw** (no masking) is accepted
  because the same `remote_endpoint` **already travels to the researcher in every `/answers` and
  `/history` export** (the answer/history docs carry it and are returned raw), so the audit copy is **not**
  a new exposure of the key — it is the same value, under the audit log's admin-only surface and STORY-1
  retention posture. No masking in the admin UI. (A non-secret search key — a hash of `remote_endpoint`,
  or `platform_user_id`+`offering_id` — remains a possible later hardening if the at-rest copy itself ever
  becomes a concern, but is out of scope here.)

### Admin audit-log page — filter by export id + student (`remote_endpoint`) search

STORY 1 shipped the admin-only audit-log LiveView (`ReportServerWeb.AuditLogLive.Index`,
`/reports/audit-log`, `portal_is_admin`, backed by `AuditLog.list_entries_paginated/1` with the generic
`Pagination`) with **no filters**, explicitly deferring student-level search "to STORY 3, when the
endpoint-set column has data to search." This story populates `endpoint_set`, so it lands here — the
data + the write-side + the way to actually query it ship together (no follow-on **server-side** story —
REPORT-77/STORY 4 is the Go CLI, which won't build Elixir audit UI).

- **Filter by `export_id`** (exact match): shows every row of one export — the intent row + all page
  access rows — together.
- **Search by `remote_endpoint`** within `endpoint_set`: "which exports touched student X." Matches both
  the intent row (full derived set) and the per-page access rows (actually served), so an admin sees
  both "scoped to" and "actually exported" for that student, correlatable via `export_id`.
- **Storage shape to enable search**: the audit `endpoint_set` is stored as a **JSON array of
  `remote_endpoint` strings** (the student-level question needs only the endpoints, not the
  `source` annotation the scratch carries), so MySQL `JSON_CONTAINS(endpoint_set, JSON_QUOTE(?))`
  (pathless — top-level array) serves the search. **Schema-field-type change (required, no migration)**:
  STORY 1 declares `data_access_log.endpoint_set` as Ecto **`:map`**, whose cast/dump/load guard on
  `is_map/1` and **reject a top-level list** (Ecto 3.12.4 `type.ex:569/667/930`). Change the *schema
  field* to a **custom `:map`-typed Ecto type** (`ReportServer.Types.EctoJsonArray`) that carries a
  top-level list — the MySQL column stays `json` (an Ecto `:map` migration compiles to `json`), so only the
  `field` declaration changes; STORY 1's own rows write `null` (valid). **NOT a bare `{:array, :string}`**:
  under `Ecto.Adapters.MyXQL` the adapter prepends `json_decode` only for `:map`/`{:map, _}` loaders
  (`ecto_sql .../myxql.ex:153-158`), so a bare `{:array, _}` field receives the raw JSON string from the
  `json` column on load and **fails to load** (writes work — MyXQL JSON-encodes a list — but reads crash).
  The custom type's `type/0 == :map` gets it the `json_decode` loader while keeping a top-level array on
  dump (pathless `JSON_CONTAINS` unchanged); it mirrors the repo's existing `EctoReportFilter`. See the
  implementation spec's "Why a custom Ecto type" note (F-ext3-1).
- **Query**: extend `AuditLog.list_entries_paginated/2` to accept optional filters (`export_id` →
  `where ==`; `remote_endpoint` → `where JSON_CONTAINS(...)`), keeping the existing order + `Pagination`.
  The `remote_endpoint` value MUST be a **bound parameter** — `fragment("JSON_CONTAINS(endpoint_set,
  JSON_QUOTE(?))", ^remote_endpoint)` — never string-interpolated (the codebase has no existing `fragment`
  precedent to copy, so this is stated explicitly to avoid an injection footgun).
- **UI**: add the two filter inputs to `AuditLogLive.Index`, driven by URL query params so they compose
  with `?page=N` (`push_patch`), reusing STORY 1's pager. Admin-only, unchanged.
- **Perf caveat (documented)**: the `remote_endpoint` JSON search is an **unindexed scan** of
  `data_access_log` (no JSON index) — acceptable for low-volume admin use at current data size; a
  generated-column index is a possible later optimization, out of scope here.
- **`JSON_CONTAINS` is intentionally case-sensitive (required property — do not "optimize" it away)**:
  verified on dev MySQL 8.0.39, `JSON_CONTAINS(endpoint_set, JSON_QUOTE(?))` matches with **binary/
  case-sensitive** semantics independent of the tables' `utf8mb4_0900_ai_ci` (case-*insensitive*)
  collation — which is exactly what `secure_key` matching needs (a `secure_key` is case-sensitive, so two
  learners' endpoints can differ only in case). Any future generated-column/`LIKE` index optimization MUST
  preserve case-sensitive (`utf8mb4_bin`/`_cs`) semantics or it will mis-match endpoints (a `=`/`LIKE`
  over the case-insensitive column collation would match the wrong learner).
- **Accessibility** (new UI surface, consistent with STORY 1; verified against the real
  `audit_log_live/index.html.heex` + shared components):
  - **`aria-live` result announcement (required)**: the table re-renders via `push_patch`/`handle_params`
    (`index.ex:21-30`) with **no live region** today, so a screen-reader user who submits the filter hears
    nothing. Wrap a result summary in `aria-live="polite"`/`role="status"` (e.g. "Showing N events…")
    updated on every `handle_params`, so both filter and pager patches are announced.
  - **Filter-aware empty state (required — the current message lies)**: `index.html.heex:37` renders one
    hardcoded branch for zero rows — "No data access events have been recorded yet." Once filters exist,
    that same branch fires when a filter merely matches nothing, telling the admin nothing was *ever*
    recorded. Branch the empty state on whether a filter is active and render a filter-specific "No events
    match export id X / student Y", inside the `aria-live` region so it is announced.
  - **Focus management**: after a filter submit, move focus to the results region/heading (a
    `tabindex="-1"` container via `push_focus`) so keyboard/SR users are taken to the updated content; the
    pager keeps focus on the activated control.
  - **Real labeled form (mechanism pinned)**: the two inputs (`export_id` exact, `remote_endpoint` search)
    MUST be built with `<.label for={id}>` + `id` (the app's `.input`/`.label` components,
    `core_components.ex:386-399`) — **placeholders are not labels** (WCAG 1.3.1/4.1.2); `type="text"`; a
    **visible `<button type="submit">`** (submit-on-enter alone leaves no focusable control for keyboard/SR
    users, WCAG 2.1.1/3.2.2); don't truncate the long `remote_endpoint`/`export_id` accessible names.
  - **Table name + headers**: add a `<caption class="sr-only">` naming the table (reflecting the active
    filter); add `scope="col"` to the `<th>` headers, which the STORY-1 headers at `index.html.heex:10-13`
    lack. (The pager's `aria-current`/`<nav aria-label>` are **already** provided by STORY-1's `.pager`,
    `custom_components.ex:364,373` — no new work there; two distinctly-labeled pagers at
    `index.html.heex:6,35`.)
  - Existing Tailwind + WCAG AA contrast (spot-checked: `text-zinc-600` on white passes AA; don't
    introduce grey placeholder-as-label text).

### Server-side scratch (paginated endpoint set)

- A short-TTL server-side store holds the **once-derived authorized endpoint snapshot**
  (`{remote_endpoint, source}` per learner) keyed by an **unguessable capability** `scratch_id` —
  `Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)`, minted per export, **not** the table's
  autoincrement PK (reuses the `auth_grants` mint idiom, `accounts.ex`) — so the expensive
  `LearnerData.fetch` join runs **once per export** (on page 1) instead of every page. **Every access to a
  scratch row is ownership-guarded** by the identity predicate
  `WHERE scratch_id == ? AND user_id == ^caller.id AND report_run_id == ^id AND data_type == ^route` (expiry
  handled as the separate serve/410 branch, see the two-step Read-time-expiry lookup), so a
  forged/guessed/cross-export/cross-route `scratch_id` in the client-held token resolves to the indistinguishable
  404 rather than another researcher's data (see Round-4 security items). It is the
  **authorization of record** for the export: (a) the frozen set each page serves from, (b) the anchor
  for the endpoint-index cursor, and (c) a per-learner LTI-tuple cache (below). Because authorization is
  snapshotted at start (not re-checked per page — see Snapshot-at-start authorization), the snapshot needs
  no `project_id` annotation and no per-page re-intersection.
- **Backing: a MySQL `export_scratch` table** (not ETS), matching STORY 1's `auth_grants` short-TTL
  precedent. The deployment is AWS Fargate behind an ALB with `maximumPercent: 200` — so a rolling
  deploy transiently runs **two tasks** behind the same target group (no session stickiness), and any
  in-memory scratch on one task is invisible to the other and destroyed on drain. A DB table is the
  only correct backing. Columns: opaque `scratch_id`, `endpoint_set` — the per-learner snapshot list;
  a JSON **array** (declare it with a **custom `:map`-typed Ecto type** — `ReportServer.Types.EctoJsonArray` —
  **not** `:map` (rejects a top-level list) and **not** a bare `{:array, :map}` (MyXQL won't `json_decode` it on
  load; see the Ecto `:map`/MyXQL self-review item) sized ~tens of KB typical, **~1.9 MB worst case
  for a 10k-learner cohort (measured — real secure-key-length endpoints push it above the earlier ~1.3 MB
  estimate)**, still ~34× under the 64 MiB `max_allowed_packet` — `report_run_id`, `user_id`,
  **`data_type` (`answers_bulk` / `history_bulk`, so the ownership guard binds the scratch to its route —
  see the cross-route rejection requirement)**, `expires_at :utc_datetime`, timestamps; **`unique_index` on
  `scratch_id`** (the lookup capability, per the `auth_grants`/`api_tokens` precedent — a single unique index
  resolves the ownership-guarded lookup to ≤1 row, no compound index needed) and a plain index on
  `expires_at` (for the sweep's range delete).
- **Read-time expiry is a TWO-STEP lookup (required — a single `expires_at > now` filter cannot produce
  410):** the page load must distinguish "scratch doesn't exist / isn't yours" (→ **404**) from "your
  scratch existed but lapsed" (→ **410 `EXPIRED_CURSOR`**), and a single guarded query that *includes*
  `expires_at > now` collapses an expired row into the same "miss" as a forged one → it would wrongly 404
  and break the CLI's restart contract. So:
  1. **Identity match** on `WHERE scratch_id == ? AND user_id == ^caller.id AND report_run_id == ^id AND
     data_type == ^route` (**no** expiry predicate). **No row → 404** (forged / cross-user / cross-route /
     swept — indistinguishable, no existence leak, since only the owner can name their own capability).
  2. Row found but **`expires_at <= now`** → **delete it** (same ownership+`data_type` predicate, pure
     reclaim) and return **410 `EXPIRED_CURSOR`**.
  3. Row found and **`expires_at > now`** → serve the page and **bump** `expires_at` (sliding TTL).
  This preserves 404-indistinguishability for anything not the caller's own, while giving the owner the 410
  they need. (The `auth_grants` "invisible when lapsed" idiom does not apply here because auth_grants never
  needs to signal *expired-vs-absent* differently — STORY 3 does.)
- **Sliding TTL of 1 hour of inactivity**: each page read bumps `expires_at = now + 1h`, so an
  actively-progressing export never expires; only an idle/abandoned one lapses. (The read-time *expiry filter*
  `WHERE expires_at > now` is the `auth_grants` idiom; the *bump* is **new** — `auth_grants` has no sliding TTL,
  it only consumes once. The bump MUST be an **absolute** `SET expires_at = ^(now + 1h)`, never `expires_at +
  delta`, so concurrent same-token retries converge monotonically and stay idempotent.)
- **Cleanup — no reliance on unbounded accumulation** (the DB is a 20 GB `db.t3.micro`, and scratch
  rows are far larger than tiny `auth_grants` rows):
  - **delete-on-`EXPIRED_CURSOR`** (inline, step 2 of the two-step read-time-expiry lookup above): a resume
    whose identity match finds the row but sees `expires_at <= now` deletes it as pure reclaim (then returns
    410) — safe because an expired row can't serve a valid retry anyway. The delete is
    **ownership+route-scoped** (`WHERE scratch_id == ? AND user_id == ^caller.id AND report_run_id == ^id AND
    data_type == ^route`), so a caller can only reclaim a row already bound to them.
    **The terminal page does NOT delete the scratch** — see below.
  - **Terminal page is retained, not deleted** (idempotency requirement): serving the final page (which
    returns `next_page_token: null`) leaves the completed scratch row in place until its normal TTL/sweep
    reclaims it, so replaying the terminal `page_token` re-serves the **identical** final page instead of
    returning `EXPIRED_CURSOR`. Inline delete-on-terminal would turn a lost final-page response into a
    `410` → **full re-export**, contradicting the idempotent-retry guarantee — so cleanup of completed
    exports is left to the TTL sweep (a completed row lingers ≤ ~1 h, negligible given the sweep + bounded
    row size).
  - **periodic GenServer sweep** (backstop for abandoned *and completed* exports): `DELETE FROM
    export_scratch WHERE expires_at < now()` on a **15-minute** interval (mirrors the `StatsServer`
    `Process.send_after` pattern), **plus a sweep on boot** (the table survives Fargate deploys, so a
    fresh task clears rows orphaned by the previous one). **The boot sweep MUST run *after* `init/1`
    returns — NOT inside `init` (required):** mirror `StatsServer`, which deliberately does no DB work in
    `init` and defers it to `handle_continue` (`stats_server.ex:31-51`, "return immediately and handle the
    rest of the (potentially long running) startup in the handle_continue handler"). A synchronous
    `DELETE` inside `init` runs on the supervisor's start path, so a momentarily-slow DB at boot
    (post-deploy / RDS failover) blocks the child's start and can restart-loop — for pure reclaim that
    "correctness never depends on." Run the boot sweep via `handle_continue` (or
    `Process.send_after(self(), :sweep, 0)`). Correctness never depends on the interval —
    stale rows are already invisible via the read-time clause — so 15 min is a storage-reclaim cadence,
    not a correctness one; worst-case a dead row occupies disk ~1h15m.
- **Max page size bounded by returned-item count, endpoints walked, AND raw docs read** (predictable
  Firestore read cost + JSON size, and termination even when a page returns no items):
  accumulate items across learners until a per-page cap (default **~500 returned items/page**), **or** the
  `endpoint_limit` learners-walked cap, **or** the `read_limit` pre-filter raw-doc-read cap — whichever comes
  first — then return the cursor. `endpoint_limit` lets a page that touches only answers-but-no-history
  learners terminate with `items: []` and a non-null token (the empty-mid-export case); `read_limit` bounds
  the one-learner-huge-filtered-history case (docs read then dropped by the `remote_endpoint` filter), and
  the inner cursor is returned mid-learner so it resumes. The item cap counts **returned snapshots/answers**,
  so in the common case actual Firestore reads per page
  are ≈ **2× cap** for history (metadata query + state batch-get) **+ one `limit(1)` tuple read per
  learner touched**, and ≈ **1× cap** for answers — this is the formula the validation-milestone cost
  sizing uses. `limit` (STORY-3's own parser, `@default_limit ~500`/`@max_limit ≥ 500` — **not** STORY 1's
  50/200 clamp; see the Pagination `limit`-bounds bullet) only **lowers** this cap, never raises it. Keeps
  JSON a few MB under the 10 MB gen1 response cap and each page's reads within seconds of the raised ~300 s
  timeout.
  (**This formula is the 1:1 case.** In the rare duplicate-learner case — sibling `remote_endpoint`s share
  one LTI tuple — each sibling endpoint index re-runs the identical tuple metadata query + state batch-get
  and then filters to its own `remote_endpoint`, discarding the siblings', so history reads are multiplied
  by the sibling count over that shared snapshot set. Bounded by how rare duplicates are and by the item
  cap; caching the tuple **query result** in the scratch so siblings reuse it is an optional future
  mitigation, not required here.)
- **Cache the derived LTI tuple in the scratch row** (`{remote_endpoint, source, lti_tuple?}`),
  populated on **first** touch of a learner, so the `limit(1)` tuple read happens **once per export**
  rather than once per page that touches that learner — removes the read amplification on resumes and
  multi-page learners.
- **Chunk the history state batch-get** (`getAll`) if a page's state-doc set is large, to respect
  Firestore batch-read practical limits.

### Error codes

- Reuse STORY 1's shape `{ "error": "<CODE>", "message": "...", ...context }` and its
  `ErrorHelpers`/`@statuses` map (`error_helpers.ex:5`). Codes: `NOT_AUTHENTICATED` (401), `NOT_FOUND`
  (404, ownership/existence), `BAD_REQUEST` (400, malformed `limit`/`page_token`/params),
  `SERVER_ERROR` (500), and the **one new** code `EXPIRED_CURSOR` → **410 Gone** (scratch TTL lapsed →
  CLI discards its partial file and restarts from a null cursor). 410 is chosen over reusing 409 so
  `code_for_status/1`'s reverse map has no status collision with `NOT_READY`.
- **No `FORBIDDEN`** (STORY 1 dropped it; STORY 3 does not reintroduce it): ownership failures stay
  **404** (no existence leak); bad-token/lost-report-access is **401** at the pipeline; a shrunk
  `allowed_project_ids` down to `[]` (via the empty-permission short-circuit — see Live endpoint
  derivation) yields an **empty 200 page**, not an error (the
  caller owns the run, so an empty page leaks nothing). `:none` never reaches here — it implies all role
  flags false → `can_access_reports?` false → 401 at the pipeline. Every access-control outcome is covered
  by 404 / 401 / empty-200.

### Validation (in-story milestone)

- Delivered as **one story** (matches REPORT-74/75; REPORT-76 has no subtasks), with the Phase 2
  implementation plan front-loading an **early end-to-end validation milestone** — a minimal vertical
  slice (one learner → one page → cursor → resume) that proves the mechanic and lets us **measure
  big-class full-history cost/latency and Cloud Function timeout headroom on real data before** building
  out audit/sweep/polish. No throwaway spike. Size Firestore read cost/quota for bulk history at that
  checkpoint. (Timeout risk is largely designed away by bounded ~500-doc pages + the raised ~300 s
  timeout; the residual unknown is read cost/latency, which the real implementation measures directly.)

## Technical Notes

### Cloud Functions timeouts & Firestore pagination (researched)

- **HTTP function max timeout**: gen1 = **540 s (9 min)**; gen2 (Cloud Run) = **3600 s (60 min)**.
  Default for both = 60 s.
- **The existing `api` function is gen1** (`functions.https.onRequest`, `firebase-functions ^4.0.0`,
  `firebase-admin ^10.0.0`, Node 22) with **no explicit `timeoutSeconds`** — so it currently runs at
  the **60 s gen1 default**. All existing endpoints (`get-answer`, etc.) are routes on one shared
  Express app (`functions/src/index.ts:32`), wrapped by one `functions.runWith({ secrets:[bearerToken]
  }).https.onRequest`. A long bulk route added to that same app inherits its (single) timeout — hence
  the where-it-lives + timeout Open Question.
- **Timeout syntax**: gen1 `functions.runWith({ timeoutSeconds: 540, memory: "1GB" })`; gen2
  `onRequest({ timeoutSeconds: 3600, memory: "1GiB" }, handler)` (note `GB` vs `GiB` unit casing).
- **Response-size cap**: gen1 = 10 MB; gen2 = 32 MB (10 MB if streaming) — a harder wall than timeout
  for large pages. Bound page size against this regardless of the timeout ceiling.
- **Firestore paging**: use `orderBy(...).startAfter(cursor).limit(n)`; **never `offset(n)`** — it
  bills a read per skipped doc (deep offset paging is O(n²) in reads). Cursors add no query surcharge;
  you're billed one read per returned doc.
- **Recommendation**: bound each page well under the timeout and paginate via cursor rather than lean
  on a long timeout — a single 60-min request is fragile (proxy/idle timeouts, cold starts, deploys,
  transient errors lose the whole run) and the response-size cap forces bounded pages anyway. This also
  keeps the design portable if the function stays gen1.

### Elixir integration points (STORY 1, verified)

- Router: add routes under the `:api_authenticated` scope (`router.ex:55`). Keep the
  `match :*, "/*path"` fallback below them.
- `LearnerData.fetch/2` (`server/lib/report_server/reports/athena/learner_data.ex:24`) takes
  `(%ReportFilter{}, %User{})`, runs the portal query with `apply_allowed_project_ids_filter(user, …,
  "po.runnable_id", "ptc.teacher_id")`, and returns a list grouped by `runnable_url`, each group's
  `learners` carrying `run_remote_endpoint`
  (`https://{portal_server}/dataservice/external_activity_data/{secure_key}` — the `secure_key` is
  embedded here, **not** a standalone field), `runnable_url`, `student_id`, `offering_id`, `user_id`,
  etc. (verified `learner_data.ex:166-183`; note there is **no `project_id`** field — see the per-page
  re-check).
- `get_allowed_project_ids/1` (`server/lib/report_server/portal_dbs.ex:140`): admin → `:all`; project
  admin/researcher → their `admin_project_users` projects; else `:none`.
- `report_run.report_filter` is already a `%ReportFilter{}` struct (custom Ecto type), directly usable
  as the `LearnerData.fetch` arg. **Loaded-filter atom/string asymmetry** applies (STORY 1 note):
  `EctoReportFilter.load/1` atomizes only top-level keys — reuse existing query paths, don't hand the
  loaded filter to atom-only matchers.
- `ReportService` (`server/lib/report_server/report_service.ex`): `Req`-based, `get_endpoint/1` builds
  `{url, token}` from config (`REPORT_SERVICE_URL`, `REPORT_SERVICE_TOKEN`,
  `REPORT_SERVICE_FIREBASE_APP`), calls with `auth: {:bearer, token}`. Add a bulk-read call here.
  **The bulk call MUST set an explicit `receive_timeout` above the Node ceiling (required — a hard
  blocker otherwise):** Req 0.4.14 defaults `receive_timeout` to **15 000 ms** (`deps/req/lib/req.ex:327`),
  and the existing calls (`report_service.ex:16-22,42-48`) set none. Since the design raises the Node/Cloud-
  Function timeout to ~300 s and sizes pages against it, a bulk `Req.get` left at the 15 s default would
  abort every page that legitimately runs longer than 15 s → `SERVER_ERROR` → CLI retries the same page →
  same 15 s failure (no progress on any slow page). Set `receive_timeout: ~310_000` (comfortably above the
  ~300 s Node ceiling) on the bulk call. (Deploy-review, out of Elixir scope: sanity-check the ALB / any
  proxy idle timeout in front of the Node function against ~300 s.)
- `data_access_log` schema (`server/lib/report_server/audit_log/data_access_log_entry.ex`) already has
  `cursor` (string) and `endpoint_set` (currently Ecto `:map`) fields; `AuditLog` module holds the
  fail-closed helper. **This story retypes the `endpoint_set` *field* to a custom `:map`-typed Ecto type
  (`ReportServer.Types.EctoJsonArray`), NOT a bare `{:array, :string}`** (MyXQL only `json_decode`s
  `:map`/`{:map, _}` loaders, so a bare `{:array, _}` field crashes on read — F-ext3-1), so it can
  hold the audit endpoint array and serve pathless `JSON_CONTAINS` — no migration needed (the MySQL
  column is already `json`); see the audit-search "Storage shape" requirement + the Ecto `:map`/MyXQL
  self-review item.
- No server-side scratch/TTL store exists today (only an ETS `:tree_cache` in
  `server/lib/report_server/reports/tree.ex`); the scratch mechanism is new. The closest precedent is
  STORY 1's `auth_grants` short-TTL DB record (`create_auth_grants.exs`; `Accounts.exchange_auth_grant`
  enforces expiry via `WHERE expires_at > ^now` + atomic `update_all`, no cleanup job). The
  `StatsServer` GenServer (`server/lib/report_server/dashboard/stats_server.ex`, 60 s
  `Process.send_after` loop) is the pattern to mirror for the scratch sweep.
- **Deployment topology (verified via AWS)**: single ECS **Fargate** service (`report-server` on
  `fargate-public-cluster`) behind an **ALB** (target group, no session stickiness); `desiredCount: 1`
  with `maximumPercent: 200` and `minimumHealthyPercent: 75`, so a rolling deploy transiently runs
  **two tasks** sharing the target group. This rules out any in-memory (ETS/GenServer-state) scratch —
  a resumed page can land on the other task. DB is `db.t3.micro`, **MySQL 8.4.7**, 20 GB allocated
  (small — reinforces bounded scratch cleanup). The report-server DB is separate from the remote portal
  DB that `LearnerData.fetch` queries.

### Firebase/Node integration points (verified)

- **Internal Elixir↔Node wire contract (pin it — the endpoint slice won't fit the existing GET-query
  idiom):** today `ReportService` calls functions as **GET with query params** and Node reads `req.query`
  (`report_service.ex:15-23`, `index.ts:56-57`), but the bulk request must carry an **ordered endpoint
  slice** up to the full learner set (scratch sized ~1.9 MB worst case for 10k learners), which cannot
  ride a GET query string. So the bulk Node route is a **`POST` with a JSON body** — the first read route
  needing a body — and the internal contract is pinned as:
  - **Request** (Elixir → Node, JSON body): `{ collection: "answers" | "history", source_endpoints:
    [{ remote_endpoint, source, lti_tuple? }] (ordered slice from the current endpoint index onward),
    inner_cursor, limit, endpoint_limit, read_limit }`.
  - **Three independent page bounds (all required — items alone don't bound the work):** a page returns when
    **any** of these is hit (or the slice ends):
    - **`limit`** — returned-item cap (~500), the client-facing page size.
    - **`endpoint_limit`** — max **endpoints/learners walked**. Required because a page landing on
      answers-but-no-history learners returns 0 items and would otherwise scan the whole remaining slice.
      The empty-mid-export page (`items: []` + non-null token) is exactly the `endpoint_limit`-reached-with-
      zero-items case.
    - **`read_limit`** — max **raw Firestore docs read (pre-filter)**: metadata + state docs read count
      toward this cap *before* the `remote_endpoint` post-filter. Required because the tuple→`remote_endpoint`
      1:many means one learner's shared-tuple history can fetch thousands of metadata+state docs that are
      then **all filtered out** — 0 returned items but unbounded reads, blowing the read-cost/timeout bound
      that `limit` (0 items) and `endpoint_limit` (still one endpoint) don't catch. When `read_limit` is hit
      mid-learner, Node returns with `endpoint_exhausted: false` **and MUST return the `inner_cursor` even
      when every fetched doc was filtered out**, so the next page resumes *within* that learner rather than
      re-reading. (Answers reads are 1:1 with returned items, so `read_limit` mainly bounds history.)
      **Forward-progress invariant (required — else a page can make no progress → infinite loop):**
      `read_limit ≥ 1`, and the per-learner `answers … limit 1` tuple-derivation read is an *answers* doc
      that does **NOT** count toward `read_limit` (only `interactive_state_histories` metadata + state docs
      do). This guarantees a `read_limit`-bounded page always reads at least one history metadata doc and so
      strictly advances the `{created_at, docId}` inner cursor (or exhausts the endpoint), never returning a
      token identical to the one requested.
  - **Response** (Node → Elixir, via `res.success`): `{ items, stop_endpoint_offset, inner_cursor,
    endpoint_exhausted, touched_endpoints, success: true }` — Elixir strips the `res.success`-injected
    `success` key (`response-methods.ts:14`) and reassembles the client-facing `{items, next_page_token}`
    envelope.
  - **`stop_endpoint_offset` is SLICE-RELATIVE, and `endpoint_exhausted` decides the ±1 (required — the
    advance formula is not just `+ offset`):** Node receives a slice starting at the current index, so it
    reports the slice offset of the endpoint it stopped **on** (`0..len(slice)`), plus whether that endpoint
    was fully read (`endpoint_exhausted`). **Elixir** advances:
    - **`endpoint_exhausted == true`** (the stopped-on endpoint finished) → `next_absolute_index =
      current_index + stop_endpoint_offset + 1`, and the **next inner_cursor is `null`** (a fresh start of
      the next endpoint).
    - **`endpoint_exhausted == false`** (page cap — item/endpoint/read — hit mid-endpoint) →
      `next_absolute_index = current_index + stop_endpoint_offset` (**no +1** — resume the *same* endpoint),
      and the next inner_cursor is the `inner_cursor` Node returned.
    Omitting the `endpoint_exhausted` term re-enters an already-exhausted learner → duplicate pages or a
    loop; conflating the two cases skips a learner. (The old name `stop_endpoint_index` invited a
    relative/absolute mismatch too — the field is explicitly a slice offset.) `next_page_token: null` only
    when the **last** endpoint of the whole scratch set is exhausted.
  - **`endpoint_exhausted` MUST be definitive, never a guess (required — Firestore `limit(M)` returning M
    docs does NOT prove exhaustion):** Node sets `endpoint_exhausted: true` **only on proof** — either a
    batch read returned **fewer docs than requested** (natural end), **or** a **one-doc lookahead**
    (`limit(1)` `startAfter` the last consumed doc) returned empty. When a page cap (`limit`/`endpoint_limit`/
    `read_limit`) stops Node mid-endpoint with the next-doc status *unknown* (the read returned exactly the
    requested count), Node performs the lookahead to set the flag exactly (the lookahead counts toward
    `read_limit` and may exceed it by 1) — it **MUST NOT** guess `true`, since a false `true` skips the rest
    of that endpoint's docs (**data loss**), whereas a false `false` is merely an extra resuming page (safe,
    dedup-at-read absorbs it). So the ±1 advance is always driven by a *proven* `endpoint_exhausted`.
    Covered by the "cap hit exactly after exhausting the current endpoint" acceptance scenario.
  - **`touched_endpoints: [{ remote_endpoint, lti_tuple }]` returns freshly-derived LTI tuples (required —
    the scratch tuple-cache has no other feed):** the design caches the per-learner LTI tuple in the
    scratch row on first touch (see Server-side scratch), but Node is what derives it (the `answers … limit
    1` read) — so Node MUST return each endpoint whose tuple it newly derived this page, and **Elixir
    persists those into scratch before minting the next cursor**. Endpoints already carrying a cached
    `lti_tuple` in the request need not reappear here. Without this channel the cache can never populate and
    every page re-runs the `limit(1)` tuple read.
  - Node stays the stateless reader (never sees the scratch id / token format); Elixir owns all cursor
    assembly. This lets the Elixir and Node sides be built independently without a shape mismatch.
- **New routes on the shared gen1 Express `api` app** (per OQ decision), following `get-answer.ts` —
  `getPath(source, "answers")` → `getCollection(path).where(...).get()`, `getPath`/`getCollection` in
  `functions/src/api/helpers/paths.ts`. History paths:
  `sources/{source}/interactive_state_history_states` and `/interactive_state_histories`. Raise the
  `wrappedApi` `runWith` `timeoutSeconds` (`index.ts:64`) from the 60 s default to ~300 s; leave memory
  at default. (Repo already mixes gen1/gen2 — `taskWorker` is gen2 — so this stays gen1 purely because
  bounded pages don't need gen2's ceilings.)
- Bearer middleware (`functions/src/middleware/bearer-token-auth.ts`) applies automatically to all
  non-root routes; `res.success` / `res.error` from `response-methods.ts` shape responses (existing
  shape is `{success, ...}` — the bulk envelope should return the `{items, next_page_token}` contract;
  confirm how it composes with `res.success`).
- `firestore.indexes.json` is empty (`{"indexes": [], "fieldOverrides": []}`) — this project manages
  indexes **manually** (console-created). The one history composite already exists in prod but is
  missing in dev (see Firestore read surface → Composite index); creating it in dev is the required
  index task, optionally captured here.
- Admin SDK auto-detects project (`report-service-dev` vs `-pro`) from the runtime; `.firebaserc` maps
  `default`/`production`.
- TypeScript, Jest (`ts-jest`), tests co-located as `*.test.ts`.
- **Test strategy — emulator-backed + unit split** (the bulk read *is* its Firestore query/cursor/order
  behavior, which unit mocks can't meaningfully exercise):
  - **Elixir-side mock seams are prerequisite deliverables (required — no seam exists today):** the
    thorough Node/emulator strategy below has **no Elixir counterpart**, and neither the Node bulk call nor
    the portal-DB learner derivation is testable as-is. STORY 1's `athena_db` stub works only because
    Athena is looked up via `Application.get_env(:report_server, :athena_db)`; there is **no Mox/Bypass** in
    the project. Two new seams must be built and are Phase-2 deliverables:
    - **`ReportService` bulk-call seam** — route the bulk Node call through
      `Application.get_env(:report_server, :report_service_client, ReportService)` + a
      `test/support/report_service_stub.ex` (mirroring `AthenaDBStub`). Without it, "Node read failure →
      SERVER_ERROR / no audit row / no advance", "idempotent page_token", "empty mid-export page", and the
      big-class scenarios can't be asserted at the controller.
    - **`LearnerData` derivation seam** — `LearnerData.fetch`/`get_allowed_project_ids` call
      `PortalDbs.query` against a **live remote portal MyXQL** keyed off a `"{server}_DB"` env var
      (`portal_dbs.ex:15,192-202`); the portal is **not** an Ecto repo, so `Ecto.Adapters.SQL.Sandbox`
      (started for the local Repo only, `data_case.ex:39`) can't sandbox it, and no test drives `fetch`
      through a DB (the one download-audit test explicitly stubs `get_query` to avoid a reachable portal).
      Add a config-lookup seam (or injectable module) + a `LearnerDataStub` so the empty-export / non-empty
      / ownership / 404-vs-derived scenarios run without a live staging portal DB (which is not in CI). The
      404/malformed-`:id`/not-owned scenarios short-circuit before `fetch`, so those alone are writable
      today by copying `report_controller_test.exs:430-449`.
  - **Node HTTP-layer tests need no `supertest` (pin the cheap path)**: `functions/` has no supertest/
    express-app harness. Unit-test the header-only guard by calling the guard middleware directly with mock
    `req` objects (`query.bearer` / `body.bearer` / `?bearer[0]=` array / header set); induce "Node read
    failure" in an emulator test via an injected/stubbed Firestore accessor or an unreachable emulator.
  - **Emulator-backed tests** (Firestore emulator on `firebase.json` port 9090):
    pagination, `orderBy(created_at, __name__)` ordering + ties, `startAfter` cursor round-trip/resume,
    page-cap-mid-learner boundaries, the duplicate-learner `remote_endpoint` filter, and coverage cases.
    **Caveat — emulator green does NOT prove index coverage** (verified by execution 2026-07-14): the
    Firestore emulator serves the three-equality + `orderBy(created_at, __name__)` history query with an
    **empty** `firestore.indexes.json` and **no** composite index, so the exact failure the composite-index
    prerequisite guards against (`FAILED_PRECONDITION` in real dev/prod) is **invisible** to these tests.
    The dev/prod index must therefore be verified out-of-band — see Deployment / operational notes.
  - **Seed data is required** — the emulator starts empty, so tests need faithful fixtures. Seed
    **programmatically per scenario** via a helper that writes `answers` +
    `interactive_state_histories` + `interactive_state_history_states` docs **mirroring
    activity-player's real write shapes**. **Copy the exact field set verbatim from activity-player
    `createAnswerDoc` (`firebase-db.ts:542-590`) and `createInteractiveStateHistoryEntry` (`:596+`) — do
    not hand-pick a subset:** the full LTI answer doc also carries `created`, `source_key`, `resource_url`,
    `tool_id`, `context_id`, `run_key`, `interactive_state_history_id`, and the base metadata spread
    (`id`/`question_id`/`type`/…), beyond the `platform_id`/`resource_link_id`/`platform_user_id`/
    `remote_endpoint` + double-encoded `report_state` minimum; the metadata doc carries a server `Timestamp`
    `created_at`; the state doc is the merged answer-doc copy. A fixture missing `source_key`/`context_id`
    passes a naive test but under-exercises tuple-derivation. Faithful shapes are what make the
    tests actually exercise tuple-derivation, the filter, ordering, and double-decode. The existing
    `emulator-data` import (`package.json` `emulator` script) can hold a shared baseline, but
    per-scenario programmatic seeding is primary (it can target the tricky fixtures a snapshot can't).
  - **Ordering / tie / sub-ms-precision fixtures use controlled explicit `Timestamp` values, not
    `serverTimestamp` (required — verified on the emulator).** `activity-player` writes `created_at` as a
    server-assigned `serverTimestamp()`, which a test **cannot** pin to force an *exactly-equal* tie or a
    chosen *sub-millisecond* gap — so the shape-fidelity fixtures use `serverTimestamp`, but the
    ordering/tie/precision fixtures write explicit `admin.firestore.Timestamp(seconds, nanoseconds)` with
    chosen nanoseconds (exact ties and sub-ms gaps). A probe (2026-07-14) confirmed the emulator accepts
    these, that a full-precision `{seconds, nanoseconds}` `startAfter` cursor resumes across a tie with **no
    skipped snapshot**, and that a **millis-rounded-up** cursor **skips** a snapshot — the exact data loss
    the History-cursor precision contract forbids (so the "ties at identical `created_at`" acceptance test
    is constructible and must assert the full-precision cursor drops nothing while a rounded-up one fails).
  - **Pure unit tests**: double-decode passthrough (must be untouched), the `remote_endpoint` filter,
    cursor (de)serialization, and envelope shaping.
  - **No automated emulator test harness exists today — standing one up is an early Phase-2 step**
    (verified 2026-07-14): the emulator *binary* is configured (`firebase.json` port 9090, manual
    `npm run emulator --import=./emulator-data`), but the *test* side is not — `functions/package.json`'s
    `test` script is plain `jest`; `firebase-functions-test ^0.3.3` is an SDK stub (not an emulator
    harness); there is **no** `@firebase/rules-unit-testing`, **no** jest `globalSetup`/`globalTeardown`,
    and no test references `FIRESTORE_EMULATOR_HOST` (only the runtime `firebase-client.ts:54` does); jest
    is `^24`. All existing `functions/` tests are pure in-memory unit tests. The **verified-working minimal
    harness** is a new `test:emulator` script that wraps jest in `firebase emulators:exec --only firestore
    'jest'` — the admin SDK then auto-detects the emulator (a probe test round-tripped and passed this way).
  - **Safety guard — emulator tests must fail closed when `FIRESTORE_EMULATOR_HOST` is unset (required).**
    Verified by execution: running an admin-SDK jest test **without** the emulator wrapper does **not** error
    out locally — it connects to the **real `report-service-dev` project** (via ambient gcloud credentials)
    and ran the query against live Firestore (returning the real project's `FAILED_PRECONDITION`). A seeding
    test run that way would **read/write live dev Firestore**. The harness must therefore assert
    `FIRESTORE_EMULATOR_HOST` is set (or force it) in test setup and abort otherwise, so emulator-backed
    tests can never touch a real project.

### Portal data model (verified in rigse — authoritative)

- LTI identity (`app/services/api/v1/show_collaborators_data.rb:32-34`): `platform_id = site_url`,
  `platform_user_id = student.user.id.to_s`, `resource_link_id = offering.id`, `context_id =
  clazz.class_hash`. So the tuple identifies a **(student, offering)** pair.
- `portal_learners` (`schema.rb:626`): belongs_to student + offering; **`secure_key` unique**, but **no
  unique index on `(student_id, offering_id)`**; `Portal::Offering#find_or_create_learner` is
  non-atomic (`portal/offering.rb:33`). ⇒ tuple → `remote_endpoint` is **1:many** (drives the required
  history `remote_endpoint` post-filter).
- `remote_endpoint = "#{site_url}/dataservice/external_activity_data/#{secure_key}"`
  (`portal/learner.rb:104-118`), matching `LearnerData`'s derivation.

### Deployment / operational notes

- **Raising the shared `api` function timeout affects co-located routes**: bumping `wrappedApi`'s
  `runWith` `timeoutSeconds` (60 → ~300 s) raises the **max** duration for **every** route on the shared
  Express app (`import_run`, `move_student_work`, `get-answer`, …). It's a ceiling, not a cost floor
  (short calls still bill short), and existing endpoints tolerate a higher ceiling — but call it out in
  deploy review.
- **Supervision wiring**: the scratch-sweep GenServer is added to the supervision tree in
  `application.ex` (alongside the existing `StatsServer`/`PostProcessingRegistry` children); its
  15-minute `Process.send_after` loop plus a **boot sweep run from `handle_continue` (not `init`)**
  reclaims rows orphaned across Fargate deploys — the DB `DELETE` must never block the supervisor's start
  path (see Server-side scratch → Cleanup; mirrors `StatsServer`'s deferred-startup pattern). Ships with
  the `export_scratch` migration and the `data_access_log` `export_id` migration.
- **Dev Firestore index prerequisite**: the `interactive_state_histories (platform_id,
  platform_user_id, resource_link_id, created_at)` index must exist in `report-service-dev` before the
  history query is exercised there (present in prod, missing in dev — see Firestore read surface). Not
  captured in `firestore.indexes.json` (project convention is manual index management); create it via
  the console / the click-to-create link the first failing query emits.
- **Non-emulator index guard (required — the emulator can't catch this)**: because the Firestore emulator
  serves the composite-requiring history query with no index declared (verified by execution — see Test
  strategy), passing emulator tests do **not** prove the index exists in a real project. Add a
  deploy-checklist assertion that the `interactive_state_histories (platform_id, platform_user_id,
  resource_link_id, created_at)` index is present in the target project before the history route is
  exercised there — checkable via `firebase firestore:indexes --project <target>` (or the Firestore admin
  API). This is the guard the emulator suite cannot provide; it must run against the live project, not the
  emulator.

### History mechanic — minor cases (folded in)

- A learner with **answers but no history** (interactive didn't set `save_interactive_state_history`) →
  the tuple query returns empty (coverage "none" — expected, distinct from "not fetched").
- A learner with **no answers at all** → the `limit(1)` tuple-fetch returns nothing → skip for history
  (they have no history either).
- History uses the **same per-learner `source`** as answers (`COALESCE(answersSourceKey param,
  hostname(runnable_url))` + offline remap).
- The derived LTI tuple is cached in the scratch row on first touch (see Server-side scratch), so the
  `limit(1)` tuple read is once per export per learner, not once per page.

## Acceptance Criteria / Test Scenarios

Each maps to decisions made above; these are the sign-off scenarios.

- **Empty export** — a run whose live learner set is empty → **200** with `items: []` and
  `next_page_token: null` (not an error). Two distinct paths, both asserted: (a) a **non-empty** permission
  set that matches **no learners** (handled by `allow_empty: true`), and (b) an **empty permission set** —
  caller's `get_allowed_project_ids` is `[]` (role-flagged researcher with zero project rows) — which
  **short-circuits to `{:ok, []}` before any SQL is built** (must NOT reach `LearnerData.fetch`, which would
  emit `IN ()` → 500). (`:none` is **not** an empty-200 case — it 401s at AuthPlug before the controller; not
  asserted here.)
- **Nil-`report_filter` run** — an owned Athena run with `report_filter == nil` (a supported state)
  normalizes to `%ReportFilter{}` and derives its (filter-unconstrained, permission-bounded) learners →
  a normal export, **not** a 500 (`FunctionClauseError`) from `LearnerData.fetch(nil, …)`.
- **`answersSourceKey`-override run** — a run whose `runnable_url` carries an `answersSourceKey` query
  param exports from that override `source` (not the hostname), matching the report's own derivation; no
  silent miss.
- **Learner with answers but no history** (interactive didn't set `save_interactive_state_history`) →
  `/history` returns nothing for them; coverage reads "none" (distinct from "not fetched").
- **Empty mid-export page (non-terminal empty items)** — a `/history` page that walks its full
  `endpoint_limit` on learners with answers-but-no-history returns `items: []` with a **non-null**
  `next_page_token` (the page terminates on the endpoint cap, not the item cap); the next request continues
  the export. Asserts the terminal signal is `next_page_token == null` only, that empty `items` mid-export
  is **not** end-of-stream, and that `endpoint_limit` bounds the page so it does not scan the whole slice.
- **Learner with no answers at all** → `limit(1)` tuple-fetch empty → skipped for `/history`.
- **Duplicate learner (`remote_endpoint` 1:many)** → the tuple query's snapshots are filtered to the
  authorized endpoint's `remote_endpoint`; each endpoint index keeps only its own (union = all **authorized**
  siblings, no double-count). A sibling excluded by the run's date/permission filters is intentionally dropped
  (no endpoint index for it), keeping `/history` symmetric with `/answers`.
- **`EXPIRED_CURSOR`** — resume after the scratch TTL lapsed → **410 `EXPIRED_CURSOR`**; CLI restarts
  from a null cursor.
- **Mid-export permission change** → a **fine-grained** project-scoped change (researcher removed from
  one project, or a teacher/assignment pulled from a cohort/materials) is **not** reflected mid-export —
  subsequent pages continue serving the start-of-export snapshot (documented accepted tolerance).
  **API-token revocation** (or the local `portal_is_*` flags cleared) → **401** at the pipeline on the next
  page, export halts. A **pure Portal-side role removal is NOT reflected** until the local `users` row
  refreshes (re-login) — asserts the live check is token-revocation + local-flag, not a Portal round-trip.
  `EXPIRED_CURSOR` restart re-derives fresh.
- **Idempotent `page_token`** — replaying the same token (authz unchanged) yields the same page and no
  double-advance. **Including the terminal token**: replaying the final `page_token` after the export
  completed re-serves the identical last page (`next_page_token: null`), **not** `EXPIRED_CURSOR` (the
  completed scratch row is retained until TTL sweep, not inline-deleted).
- **Page-cap boundary mid-learner** — a page that fills the ~500-doc cap partway through a learner
  returns a cursor that resumes that learner correctly (no skip/dup beyond the tolerated at-least-once).
- **Cap hit exactly after exhausting the current endpoint** — a page whose cap lands exactly on an
  endpoint's last doc: Node's one-doc lookahead past the last consumed doc returns empty → it sets
  `endpoint_exhausted: true` **definitively** (not a guess); the next page advances to `current_index +
  offset + 1` with a `null` inner cursor (does **not** re-enter the exhausted endpoint) — asserts both the
  `endpoint_exhausted` ±1 term **and** the lookahead-proof rule (a page that returned exactly M docs must
  not blind-guess exhausted). The mirror case (cap hit mid-endpoint, lookahead finds more →
  `endpoint_exhausted: false`) resumes the **same** endpoint (`+ offset`, no +1) via the returned inner
  cursor. A test that forces an endpoint boundary at the cap must confirm no docs are skipped.
- **Huge filtered history bounded by `read_limit`** — one learner with a large shared-tuple history whose
  fetched metadata/state docs are (mostly) filtered out by the `remote_endpoint` post-filter → the page
  terminates on `read_limit` (pre-filter doc count), returns few/zero items with a **non-null** token and a
  **valid mid-learner inner cursor**, and the next page resumes within that learner (no re-read, no
  unbounded scan). Asserts reads are bounded even when returned items are ~0.
- **History ties at identical `created_at` across a page boundary** — multiple `interactive_state_histories`
  snapshots sharing the same `created_at` value, split by the page cap, resume via the `{created_at,
  docId}` cursor with **no skipped snapshot** (the `__name__` tiebreaker + full-precision Timestamp
  round-trip); a lossy/rounded-up cursor would drop rows and must fail this test.
- **Malformed inner cursor → `BAD_REQUEST` (not 500)** — a base64/JSON-valid `page_token` whose inner
  cursor carries an out-of-range `nanoseconds` (e.g. `1000000000`) or stringified Timestamp fields returns
  **`BAD_REQUEST`**, not an uncaught 500 from `new admin.firestore.Timestamp()` (Node/Elixir guards the
  reconstruction).
- **Cross-route replay rejection** — replaying a `/history` `page_token` against `/reports/:id/answers`
  (and vice-versa), same user/run, is rejected by the scratch `data_type` guard as **404** — including the
  **`null` inner cursor** case at an endpoint boundary (which has no shape to reject, so the `data_type`
  guard is what catches it). A non-null wrong-shape cursor is *also* rejected `BAD_REQUEST` by the strict
  decoder (defense-in-depth). Same user/run → no confidentiality impact; this asserts the export can't be
  cross-fed into the wrong CLI file.
- **Ownership/existence** — non-owned, non-Athena, non-existent, or malformed `:id` → **404
  `NOT_FOUND`** (indistinguishable).
- **Header-only bearer on the bulk routes** — the bulk routes never *honor* a non-header bearer; the
  rejection code depends on which layer catches it (both are asserted):
  - **Scalar `?bearer=<TOKEN>` query, or a `bearer` in the request body**, no header → the shared middleware
    *authenticates* it (it's a string / truthy body value) and passes it through, then the **per-bulk-route
    guard rejects it → 401** (key-existence check, `"bearer" in req.query || "bearer" in req.body`).
  - **Array/object query form alone** (`?bearer[0]=<TOKEN>` / `?bearer[x]=<TOKEN>`), no header → the shared
    middleware never extracts it (`typeof !== "string"`, `bearer-token-auth.ts:23`) and, finding no bearer
    anywhere, returns **400 "No bearer found"** *before* the route guard runs. (Still a rejection — the
    token is not honored — just at the shared-middleware layer, not the guard.)
  - **Array/object query form *with* a valid `Authorization: Bearer` header** → shared middleware
    authenticates via the header, then the guard's key-existence check sees `bearer` in `req.query` → **401**.
  - **`Authorization: Bearer` header only** → allowed.
  The security property "a bulk route never honors a non-header bearer" holds in every case (401 or 400).
  (Co-located routes like `get-answer` are unaffected — the shared middleware still accepts all three forms
  for them; only the bulk routes add the guard.)
- **Big-class full-history (manual/measured milestone — NOT an automated test)** — a large class × several
  history-enabled interactives completes across many pages. What is **automatable** on seeded data:
  page-count > 1, cursor round-trip across pages, per-page item count ≤ cap, response bytes < 10 MB. What
  is **measured on real data at the validation milestone** (no unit/emulator assertion): wall-clock latency,
  Cloud-Function timeout headroom, and Firestore read cost. Treated like "Self-start N/A" — a called-out
  non-automated scenario.
- **Node read failure** → **`SERVER_ERROR`**, no audit row, no cursor advance; same-token retry succeeds
  once Firestore recovers.
- **Self-start N/A** — unlike STORY 1's `/download`, these endpoints read Firestore live and do not
  depend on `athena_query_state`, so no query-readiness/self-start scenarios apply.

## Out of Scope

- **The Go CLI** consuming these endpoints (dedup-at-read, NDJSON storage, `.tmp`→rename, resume,
  DuckDB views) — STORY 4.
- **CSV / report download** and the `/reports`, `/:id`, `/:id/download`, `/jobs` endpoints — STORY 1
  (done).
- **Token issuance / management UI** — STORY 1 / STORY 2 (done); this story consumes the existing token
  + audit infrastructure.
- **Anonymous/offline (`run_key`) runs** — no `remote_endpoint`, not part of portal reports.
- **`answersSourceKey`-override launches are now HANDLED, not an accepted miss** (corrects the earlier
  "not persisted anywhere" claim): the override **is** persisted — it rides `runnable_url` as the
  `answersSourceKey` query param, and the report's own SQL reads it via `url_extract_parameter`
  (`shared_queries.ex:431-436`). STORY 3 matches that derivation (see Live-endpoint-derivation), so those
  runs are queried at the correct `source`. The **only** residual out-of-scope edge: an answer written under
  a stored `source_key` (the answer doc's own `source_key[question_id]`) that differs from what
  `runnable_url` yields — the report recovers this solely because it has the materialized answers table,
  which a live Firestore read (needing the `source` *before* it can find the answer) cannot; this is a
  narrow, accurately-stated boundary, not the whole `answersSourceKey` feature.
- **Server-side decoding of interactive state** — raw double-encoded passthrough; the CLI decodes.
- **Any mid-export roster / filter / project-permission change** — the authorized endpoint set is
  derived once and snapshotted at export start (and the run's `report_filter` is fixed), so roster
  additions/removals and fine-grained project-scoped permission changes are **not** reflected until a
  fresh export (or an `EXPIRED_CURSOR` restart, which re-derives). What is still enforced live per page is
  the pipeline's per-request `AuthPlug` check — but only **API-token revocation** and **locally-stored
  role-flag** changes cut the export off (on the next page); a **pure Portal-side role change is itself
  subject to the same staleness** (the local `users` row's `portal_is_*` flags refresh at re-login, not on
  API use), so "total access loss" here means token revocation / local-flag clearance, not an instant
  Portal round-trip. (Rationale: exports run long after activities; a permission change racing an in-flight
  pull is vanishingly rare — see the "project-annotated endpoint set" self-review item.)
- **Per-user / per-token rate limiting or read quotas** — deferred (as in STORY 1, REPORT-74, which noted
  it "a future concern, not v1"), but **carried forward with new context**: STORY 3 is the first endpoint
  that lets an authenticated caller drive **unbounded looped live Firestore reads** (STORY 1 only issued
  presigned URLs over already-generated artifacts). Accepted for v1 because callers are authenticated,
  report-access-gated researchers (not the public) and the per-page ~500-item cap bounds a single call —
  though **not** a loop of calls. Firestore read-cost exposure to a looping caller is an accepted v1 risk,
  to be revisited if abuse appears.
- **The `cc-data logout` server endpoint and the `AuthPlug` `api_token` assign it needs** — STORY 4
  (REPORT-77). `AuthPlug` today assigns only `:current_user`; STORY 3 does **not** add the `api_token`
  assign, but an implementer touching `AuthPlug` for the new routes should know STORY 4 will extend its
  assigns (a coordination note, not a STORY-3 deliverable).
- **Finer-grained resume-after-`EXPIRED_CURSOR`** — accepted UX tolerance: an export idle beyond the 1 h
  sliding TTL forces the CLI to re-download from scratch (partial NDJSON discarded); actively-progressing
  exports never expire (the sliding bump). Partial-scratch-resume-after-TTL is deliberately out of scope
  (it would reintroduce the staleness the derive-once model avoids).

## Open Questions

### RESOLVED: Where does the bulk read live, and at what Cloud Function generation/timeout?
**Context**: The design says "a new Node function," but every existing Firestore read is a route on one
shared gen1 Express `api` function (`functions/src/index.ts:64`) that currently has **no explicit
`timeoutSeconds` (60 s gen1 default)** and one 10 MB response cap. Because pages are bounded, none of
the gen2 ceilings (3600 s / 32 MB) are needed, so the real choice is where the routes live, not gen1
vs gen2. (Verified: the repo **already** ships a gen2 function — `taskWorker` via
`firebase-functions/v2/tasks`, `src/tasks/task-worker.ts:70` — so gen2 is not a new-precedent risk;
and long async work is offloaded to Cloud Tasks + that worker, a pattern that does **not** apply here
because the bulk read is synchronous request→page→response.)
**Options considered**:
- A) Add `get answers` / `get history` as **new routes on the existing gen1 `api` app**, and raise that
  function's `timeoutSeconds` via `runWith` (leave memory default). Reuses bearer middleware,
  response-methods, cors, `getPath`/`getCollection`, and the URL-normalization wrapper for free; raises
  the *max* duration (a ceiling, not a fixed cost) for co-located endpoints.
- B) A **separate gen1 function** with its own `runWith` timeout, leaving the shared `api` profile
  untouched; costs its own bearer/middleware wiring + a second function to monitor.
- C) A **separate gen2 function** (`onRequest`) — unnecessary headroom for bounded pages; gen2 per-
  instance concurrency also changes the Firestore-load profile.

**Decision**: **A — new routes on the existing gen1 `api` Express app, raising just that function's
`timeoutSeconds` for headroom against a slow Firestore page (e.g. 60 → ~300 s), memory left at
default.** Bounded pages make the extra headroom ample, and the routes inherit all existing
middleware/helpers with the least new surface. The per-page bound (Open Question on scratch/page size)
is what actually keeps each call short; the raised timeout is only slack.

---

### RESOLVED: What backs the server-side scratch, and what TTL / max page size?
**Context**: The **once-derived authorized endpoint snapshot** (`{remote_endpoint, source}` per learner)
must be cached across pages so the expensive `LearnerData.fetch` join runs once per export, not every
page — it is the export's authorization of record + endpoint-index anchor + LTI-tuple cache, keyed by an
opaque scratch id with a short TTL. (Note: authorization is snapshotted at export start, not re-checked
per page — see the "project-annotated endpoint set" self-review item, resolved to **derive-once**; total
access loss is still enforced per request by the `AuthPlug` pipeline.) No such store existed (only an ETS
tree cache).
**Deployment verified (AWS)**: ECS **Fargate** service `report-server` on `fargate-public-cluster`,
behind an ALB (target group, no session stickiness), `desiredCount: 1` but `maximumPercent: 200` →
**two tasks run transiently during every rolling deploy**. DB is `db.t3.micro` **MySQL 8.4.7**, 20 GB.
**Options considered**:
- A) **MySQL table** — durable across restarts/deploys, correct under the transient 2-task deploy
  window, `:map`/JSON fits the set; needs a cleanup story.
- B) **ETS / in-memory** — fast, zero migration, but **wrong under the 2-task deploy window** (a
  resumed page can hit the other task, whose ETS lacks the scratch) and wiped on every deploy.
- C) Encode the whole set into the cursor — rejected by the design (can't be safely re-intersected;
  token bloat).

**Decision**: **A — a MySQL `export_scratch` table**, `auth_grants`-style short-TTL *storage* — but **NOT**
`auth_grants`' single-query invisible-when-expired lookup (`WHERE expires_at > now`), which would collapse an
expired row into "not found" → 404 and break the 410 restart contract. Instead the scratch uses the
**two-step lookup**: identity match (no expiry) → 404 on miss; matched-but-expired → delete + **410
`EXPIRED_CURSOR`**; active → serve + bump (see the Read-time-expiry requirement). **Sliding 1 h-of-inactivity
TTL** (each page bumps `expires_at` absolutely), max page
size **bounded by a ~500-doc cap** (`limit` — STORY-3's own parser, default/max ≥ 500 — only lowers it,
not STORY 1's 50/200 clamp). ETS is ruled out by the
Fargate `maximumPercent: 200` deploy overlap + ALB-without-stickiness, not merely by future multi-node.
**Cleanup: delete inline only on `EXPIRED_CURSOR`; the terminal page is retained (not deleted) so its
`page_token` stays idempotently re-servable; a periodic GenServer sweep every 15 min + a boot sweep**
(`DELETE WHERE expires_at < now()`), with an `expires_at` index, reclaims both completed and abandoned
rows. The 15-min cadence is storage-reclaim only (stale rows are already invisible via the read-time
clause); chosen over the tiny-row "let them accumulate" `auth_grants` approach because scratch rows are
larger and the DB is a 20 GB t3.micro. (Inline delete-on-terminal was rejected: it would turn a lost
final-page response into a `410` → full re-export — see the delete-on-terminal self-review item.)

---

### RESOLVED: Does the v1 endpoint accept a `history_mode` (full / latest-only / latest-N), or always full?
**Context**: The design decides **full series by default**, with optional `--latest-only` /
`--latest-N` framed as CLI flags. Verified: no `history_mode`/`latest-only` reference exists anywhere
in the repo, and the answer doc is equivalent to the latest history snapshot (activity-player
`firebase-db.ts:531` writes the history-state doc as the merged answer-doc data), so "latest state" is
already what `/answers` returns.
**Options considered**:
- A) Always full; CLI slims (but `--latest-only` still reads + transfers the full series).
- B) `/history` accepts `history_mode` (full/latest-only/latest-N), slims server-side (fewer reads, but
  `latest-N` needs per-answer ordered queries + an index, and `latest-only` just re-serves the answer
  doc).
- C) `/history` always full; "latest state" is `/answers`; no `history_mode`; `latest-N` deferred as an
  additive param.

**Decision**: **C.** Simplest correct server; avoids a `latest-only` mode that would duplicate the
`/answers` doc; matches the design's framing (answers = reliable per-answer raw state, history = the
trajectory layer where it exists). Server-side `latest-N` is deferred as a backward-compatible additive
param if STORY 4 ever needs it.

---

### RESOLVED: Do the endpoints work for any Athena-type run, or only answer-report runs?
**Context**: Verified 5 Athena reports; `LearnerData.fetch` is report-type-agnostic (keys off generic
`%ReportFilter{}` learner fields). 4 reports (`student-actions`, `student-actions-with-metadata`,
`student-answers`, `student-assignment-usage`) call it directly; `teacher-actions` doesn't, but its
filters still transitively select learners. STORY 1 exposes all 5 uniformly.
**Options considered**:
- A) **Any Athena-type owned run** — filter-derived learner set; report type irrelevant; symmetric with
  STORY 1; no allowlist.
- B) Restrict to learner-based reports — tighter mental model but adds a maintained allowlist, makes
  `/answers` a subset of `/download` visibility, and needs an excluded-run error decision, for marginal
  benefit (permission gate already bounds sharing).

**Decision**: **A.** `teacher-actions` runs work too (documented, permission-bounded). Endpoints
inherit the run's filter breadth by design.

---

### RESOLVED: Exact wire item shapes for `/answers` and `/history` (projected fields).
**Context**: Raw-vs-projected. Verified: `get-answer` already returns the raw doc
(`snapshot.docs[0].data()`); identity fields are pseudonymous (no name/email); the only URL-ish field
`attachments[*]` holds storage path refs (`publicPath`/`folder`/`contentType`), not credentials.
**This verification also uncovered a design-doc error** and its fix (see below), which portal-report's
production slider confirms.
**Options considered**:
- A) **Raw doc passthrough** + folded doc id — simplest, future-proof, matches `get-answer`.
- B) Projected field allow-list — smaller pages but must track CLI needs.

**Decision**: **A.** `/answers` item = raw answer doc (carries its own `id`). `/history` item = raw
`interactive_state_history_states` doc + `history_id` + authoritative `created_at` (ISO 8601 from the
metadata `Timestamp`) + `answer_id`/`question_id`. State stays double-encoded (CLI decodes).

**History query mechanic — corrects the design doc (verified against portal-report + live indexes):**
The design doc's plan to query the history collections by `remote_endpoint` + `orderBy(created_at)` is
**not implementable**: `interactive_state_histories` (authoritative sortable `created_at`) has **no
`remote_endpoint`**, and `interactive_state_history_states` (has `remote_endpoint`) has only the
non-sortable `created` string (`toUTCString()`). The working mechanic (portal-report
`js/actions/index.ts:174`) keys history off the **LTI tuple**: per learner,
`answers where remote_endpoint == x limit 1` → `{platform_id, resource_link_id, platform_user_id}`, then
`interactive_state_histories where those 3 == orderBy(created_at, __name__)` cursor-paginated, then
batch-get `interactive_state_history_states/{id}`. **Index verified present in `report-service-pro` but
MISSING in `report-service-dev`** (dev only has `context_id`-led variants) → **prerequisite task: create
`interactive_state_histories (platform_id, platform_user_id, resource_link_id, created_at)` in dev**.
Answers query uses the auto single-field index.

---

### RESOLVED: Spike-then-implement split, or one story?
**Context**: The design allowed splitting into Spike B2 + impl. Verified: REPORT-76 is a Story with no
subtasks; siblings REPORT-74/75 each ran as one story. Risk is now low — the history mechanic is proven
(portal-report + verified prod index) and the timeout is designed away by bounded pages.
**Options considered**:
- A) **One story**, with an early end-to-end validation milestone in the Phase 2 plan (no throwaway).
- B) Formal spike + impl subtasks — against project convention, buys less now that the mechanic is
  proven.

**Decision**: **A.** One story with a front-loaded "validate on a big class" implementation step.

---

### RESOLVED: Does STORY 3 reintroduce a `FORBIDDEN` error code?
**Context**: STORY 1 dropped `FORBIDDEN` (ownership → 404). Verified `ErrorHelpers` set
(`error_helpers.ex:5`): BAD_REQUEST/NOT_AUTHENTICATED/NOT_FOUND/NOT_READY/SERVER_ERROR, no FORBIDDEN.
Every access path here is covered without a 403.
**Options considered**:
- A) **No `FORBIDDEN`** — ownership → 404; bad-token/lost-access → 401; permission shrink → empty-200;
  only new code is `EXPIRED_CURSOR` (410).
- B) Add `FORBIDDEN` for some case — but a fully-emptied permission set is a legitimate empty-200 (caller
  owns the run), and a 403 would leak nothing 404 doesn't already handle.

**Decision**: **A — no `FORBIDDEN`.** Only new code is `EXPIRED_CURSOR` → 410 Gone.

---

### RESOLVED: Admin audit-log page student search (surfaced during self-review re-run)
**Context**: STORY 1 deferred audit-page filters/student search "to STORY 3, when the endpoint-set
column has data to search." This story populates that column; with no follow-on **server-side** story
(REPORT-77 is the Go CLI), the search would
otherwise never be built (logging student-level access nobody can query is half a feature).
**Decision**: **In scope.** Add to STORY 1's `AuditLogLive.Index`: **filter by `export_id`** + **search
`remote_endpoint`** within `endpoint_set` (stored as a JSON array of endpoint strings; MySQL
`JSON_CONTAINS`). Reuses STORY 1's pager; admin-only; documented unindexed-scan perf caveat. See
"Admin audit-log page" requirement.

---

### RESOLVED: LTI-tuple↔`remote_endpoint` cardinality — does tuple-keyed history stay scoped? (surfaced during re-check)
**Context**: The corrected history mechanic fetches by the LTI tuple `(platform_id, platform_user_id,
resource_link_id)`, but authz/audit is by `remote_endpoint`. If the tuple isn't 1:1 to
`remote_endpoint`, tuple-keyed history could include snapshots outside the audited endpoint set.
**Verified in rigse (portal source, authoritative)**: `resource_link_id = offering.id`,
`platform_user_id = student.user.id`, `platform_id = site_url`
(`app/services/api/v1/show_collaborators_data.rb:32-34`); `portal_learners` has **no unique constraint
on `(student_id, offering_id)`** (only `secure_key` is unique — `schema.rb:626`) and
`find_or_create_learner` is non-atomic (`portal/offering.rb:33`). So the tuple → `remote_endpoint` is
**1:many** (1:1 in the common case; duplicates arise from races / delete-recreate).
**Options considered**:
- A) Assume 1:1; verify on real data at the validation milestone. Risk: audit-fidelity gap (logged
  `endpoint_set` wouldn't name a sibling `secure_key` whose snapshots leak into a tuple query).
- B) **Post-filter fetched `interactive_state_history_states` docs to the authorized `remote_endpoint`**
  (the state docs carry it) — provably scoped + audit-accurate regardless of cardinality; cheap
  in-memory filter, no-op in the 1:1 case.

**Decision**: **B.** Filtering is required, not belt-and-suspenders — it makes history provably scoped
to the exact audited endpoint set given the confirmed 1:many. (No over-share risk either way — duplicate
learner rows share offering→project→permission — but B closes the audit-accuracy gap.)

## Self-Review

### Senior Engineer

#### RESOLVED: Cursor ownership/assembly across the Elixir↔Node tier split is underspecified
**Resolution**: Added a "Cursor ownership (tier split)" bullet to Pagination — Elixir owns all
cursor/scratch state and endpoint-index advancement; Node is a stateless Firestore reader returning
items + stop index + inner cursor + exhausted flag.
The opaque `next_page_token` is a composite of (scratch id, endpoint index, inner Firestore cursor), but
scratch lives in Elixir and the inner Firestore cursor is produced by Node — so the token is assembled
across two tiers, and a page can span multiple learners (accumulate to the ~500-doc cap), meaning
*something* must advance the endpoint index when a learner is exhausted mid-page. The spec doesn't pin
who parses/assembles the composite token or who advances the endpoint index. Suggested resolution:
Elixir owns the composite token (parse on the way in, assemble on the way out); per page it loads
scratch and hands Node an ordered endpoint slice + starting endpoint
index + inner cursor; Node walks endpoints until the doc cap, returning `items` + the last endpoint
index reached + that endpoint's inner cursor (+ an "endpoint exhausted" flag); Elixir reassembles the
next token. Node stays stateless; Elixir owns all cursor/scratch state.

---

#### RESOLVED: Node/Firestore read-failure behavior mid-page is undefined
**Resolution**: Added a Pagination bullet — Node read failure → `SERVER_ERROR`, no audit row, no cursor
advance; CLI retries the same `page_token` idempotently.
The spec pins idempotent retry and fail-closed audit, but not what happens when the Node call itself
fails (Firestore unavailable, network error, partial read) mid-page. Suggested resolution: a failed
Node read → Elixir returns **`SERVER_ERROR`**, writes **no** audit row, and does **not** advance the
cursor (the CLI retries the same `page_token`, idempotently). Mirrors STORY 1's "presign fails → normal
error path, no audit row."

---

### Security Engineer

#### RESOLVED: The Node bulk function performs no authorization — make the trust boundary explicit
**⚠️ SUPERSEDED (see the later Round-2 item "Never reachable … is not achievable as written" + the accurate
body at the Firestore-read-surface Trust-boundary bullet):** the "never client-reachable" / "must never be
reachable by the CLI or any client" language in this early resolution is **stale and inaccurate** — the Node
routes live on a **public** gen1 `https.onRequest` function and *are* internet-reachable; the real perimeter
is the static bearer (secret hygiene) + Elixir as the sole intended caller and authz chokepoint, not
unreachability. Read the corrected body, not the struck-through claim below.
**Resolution**: Added a "Trust boundary" bullet to Firestore read surface — Node is authorization-blind,
Elixir is the sole authz chokepoint, static bearer stays server-side, ~~function never client-reachable~~.
Like `get-answer`, the new Node read does **no** project/ownership authz — it trusts Elixir to have
authorized and to pass only permitted endpoints, and is protected solely by the static
`AUTH_BEARER_TOKEN` (server-to-server). The stakes are higher here (bulk, all of a learner's
answers+history). The spec should state explicitly: (a) the Node function must **never** be reachable by
the CLI or any client that could supply arbitrary endpoints; (b) it is authorization-blind by design
and the static bearer must remain server-side only (Elixir↔functions); (c) it is the same trust model
as the existing single-record endpoints, just larger blast radius.

---

### QA Engineer

#### RESOLVED: No explicit test-scenario / acceptance-criteria list
**Resolution**: Added an "Acceptance Criteria / Test Scenarios" section covering empty export,
no-history/no-answers learners, duplicate-learner filter, `EXPIRED_CURSOR`, mid-export revocation,
idempotent token, page-cap mid-learner, 404 cases, big-class full-history, and Node read failure.
The requirements are prose; a concrete scenario list makes the story testable and pins the edges we
designed for. Suggested resolution: add an Acceptance Criteria / Test Scenarios subsection covering at
least: empty export (no learners / `:none` perms → 200 empty, cursor null); learner with answers but no
history (coverage "none"); learner with no answers (skipped for history); **duplicate-learner**
`remote_endpoint` filter keeps only the authorized endpoint's snapshots; `EXPIRED_CURSOR` on a
past-TTL resume; mid-export permission revocation shrinks/empties subsequent pages; **idempotent** repeat
of the same `page_token` (no double-advance); page-cap boundary landing **mid-learner** (cursor
round-trips correctly); non-owned/non-Athena/malformed `:id` → 404; big-class full-history completes
across many pages within the function timeout.

---

#### RESOLVED: Node Firestore test strategy unspecified
**Resolution**: Added a "Test strategy" bullet — emulator-backed tests for query/cursor/order behavior +
pure unit tests for decode/filter/serialization, with **programmatic per-scenario seed data mirroring
activity-player's real write shapes** (the emulator starts empty, so faithful fixtures are required).
Existing `functions/` tests are pure unit tests (jest, in-memory). The bulk read is defined by its
Firestore query/cursor/order behavior, which unit mocks can't meaningfully exercise. Suggested
resolution: test the query/pagination/order/dedup against the **Firestore emulator** (already
configured, `firebase.json` port 9090) with seeded answers + history docs; keep pure-unit tests for the
double-decode passthrough, the `remote_endpoint` filter, and cursor (de)serialization. Note this as the
test approach so it isn't discovered late.

---

### Performance Engineer

#### RESOLVED: History read amplification and what the page cap counts
**Resolution**: Page cap now counts **returned items**, with a stated read-cost formula (~2× cap + one
tuple read/learner for history); tuple-caching-in-scratch promoted from optional to the design; added a
batch-get chunking note.
Per learner, `/history` issues: one `answers … limit 1` (tuple derivation) + the metadata query + a
batch-get of state docs (≈2 reads per returned snapshot). For learners with tiny histories the `limit
1` overhead is proportionally large, and it recurs on every resume of that learner unless the tuple is
cached. Suggested resolution: (a) clarify the ~500 cap counts **returned snapshots** (so cost ≈ 2× cap
+ one tuple read per learner touched), feeding the validation-milestone cost sizing; (b) cache the
derived LTI tuple in the scratch row **from the first pass**, not only on resume, so each learner's
tuple read happens once per export; (c) note `getAll`/batch-get should be chunked if a page's state-doc
fetch is large.

---

### Education Researcher (IRB / audit)

#### RESOLVED: Per-export correlation and served-vs-authorized logging semantics
**Resolution**: (a) Every audit row carries a stable **export id** (scratch id) via a new nullable
`export_id` column for per-export correlation. (b) With no follow-on **server-side** story possible
(REPORT-77 is the Go CLI), **both** records
land now as distinct labeled rows: a once-per-export **intent** row (`export_scoped`, full derived
endpoint set — snapshot-accurate and not losslessly re-derivable) + per-page **access** rows
(actually-served endpoints). `EXPIRED_CURSOR` restart → new export id (accepted).
Audit rows are per page, and one export spans many pages (and a learner can span pages), so answering
"which students were in export E" requires correlating an export's pages — but no stable per-export id
is logged. Also, logging only the **per-page served** endpoint set means an export abandoned on page 1
records only page-1 students, not the full authorized set. Suggested resolution: (a) log a **stable
export id** (the scratch id) on every page's `data_access_log` row so all pages of one export are
queryable together; (b) keep per-page `endpoint_set` = **actually served** endpoints (truthful "what
left the server"), and optionally also log the **full derived endpoint set once at export start**
(intent/authorization record) so a partially-run export still shows who it *would* have covered. Decide
whether the intent-record is in scope for v1 or deferred.

---

### DevOps Engineer

#### RESOLVED: Dev index reproducibility + shared-function timeout + supervision wiring
**Resolution**: Added a "Deployment / operational notes" subsection covering (b) the shared-`api`
timeout bump affecting co-located routes and (c) supervision-tree wiring for the sweep GenServer + boot
sweep + the two migrations. (a) Index capture in `firestore.indexes.json` **declined** — project keeps
manual index management; dev index stays a documented manual prerequisite.
Three deployment concerns: (a) the required `interactive_state_histories` dev index is currently a
manual-console task — capturing it in `firestore.indexes.json` (despite the project's manual
convention) makes it reproducible for fresh envs and avoids repeating the prod drift; at minimum it
belongs on a deploy checklist. (b) Raising the shared `api` function's `timeoutSeconds` to ~300 s
changes the max duration for **all** co-located routes (`import_run`, `move_student_work`, …) — a
ceiling, not a cost floor, but call it out as a deploy-review note. (c) The scratch-sweep GenServer must
be added to the supervision tree (`application.ex`) alongside the `export_scratch` migration; the boot
sweep runs on `init`.

---

## Self-Review — Round 2 (code-verified, 2026-07-14)

A second multi-role pass in which **each issue below was verified against the actual source** (report-service
Elixir + `functions/`, plus activity-player / portal-report / rigse) before being written, per the review
mandate. Findings that turned out to be non-issues on inspection were dropped (the `EXPIRED_CURSOR`→410
reverse-map reasoning is sound — `NOT_READY` is genuinely 409 at `error_helpers.ex:5`; `res.success`
cleanly carries `{items, next_page_token}`; the `/answers` raw-doc `id`/`question_id`/`report_state`
claim is correct — `types.ts:276` `IExportableAnswerMetadataBase`).

### Senior Engineer / Security Engineer

#### RESOLVED: The "project-annotated endpoint set" has no data source, and one `project_id` can't represent the authorization
**Resolution (derive-once at export start; no per-page re-check):** Dropped the `project_id` annotation
entirely, and — after weighing alternatives — dropped per-page re-derivation too. The scratch holds the
authorized `{remote_endpoint, source}` snapshot (+ LTI-tuple cache) derived once on page 1;
authorization (roster + filter + project permissions) is **frozen for the export**. Fine-grained
project-scoped changes are not reflected mid-export (accepted: exports run long after activities, so a
revocation racing an in-flight pull is vanishingly rare), while the `:api_authenticated` pipeline still
re-checks the bearer + `can_access_reports?` **per request**, so total access loss halts the export at
the next page (401); `EXPIRED_CURSOR` restart re-derives fresh. Updated: Live-endpoint-derivation /
snapshot-authorization / Elixir-proxies bullets, the cursor tier-split, idempotent-retry, the
Server-side-scratch section + OQ, Overview/Out-of-Scope, and the mid-export-revocation acceptance
scenario.
**Alternatives considered and rejected during this thread:** (1) *per-endpoint `project_id` annotation* —
impossible, endpoints carry no project id and authorization is a compound cohort/materials join; (2)
*re-run `LearnerData.fetch` every page* — provably correct but fires the heavy roster join hundreds/
thousands of times per export against the shared production portal DB (the cost the scratch exists to
avoid — raised as re-scan Issue #6); (3) *gate the re-fetch on a cheap `get_allowed_project_ids` equality
check* — `get_allowed_project_ids` is cheap (verified: single-table `admin_project_users` query,
`portal_dbs.ex:150`), but an unchanged `allowed_project_ids` does **not** prove the endpoint set is still
authorized (a teacher/assignment pulled from a project's cohort de-authorizes transitively without
changing the caller's project list), so the gate would miss real revocations; (4) *time-throttled
re-fetch (≤ T s)* — complete + cost-bounded, but derive-once is simpler and the domain (exports long
post-activity) makes even T-second freshness unnecessary. Derive-once chosen.
**Verified:** `LearnerData.fetch`'s learner map (`server/lib/report_server/reports/athena/learner_data.ex:166-183`)
carries `run_remote_endpoint, runnable_url, offering_id, student_id, user_id, …` but **no `project_id`**.
Authorization is applied by `apply_allowed_project_ids_filter` (`server/lib/report_server/reports/report_utils.ex:106-128`)
purely as query-time JOINs — nothing selects a project id into the result. The predicate is **compound**:
`ac_teacher_a.project_id IN allowed AND (ac_assignment_a.project_id IN allowed OR apm_a.project_id IN allowed)`,
so a learner endpoint can be authorized via teacher-cohort and/or assignment-cohort and/or project-material
projects — a **set**, not a single id.
**Why it mattered (original finding):** As originally written, the per-page re-check (cache
`{remote_endpoint, source, project_id}` and re-intersect against `allowed_project_ids` each page) rested on
an annotation the current query does not produce; reducing it to one `project_id` would make revocation
checks wrong. The Resolution above supersedes this by removing per-page re-checking altogether (derive-once).

---

#### RESOLVED: `delete-on-terminal` breaks idempotent retry of the final page → forces a full re-export
**Resolution:** Dropped inline delete-on-terminal. The completed scratch row is retained until the normal
TTL/sweep reclaims it, so replaying the terminal `page_token` re-serves the identical final page instead
of `410`. Inline delete now happens only on the `EXPIRED_CURSOR` path (already-invisible row → pure
reclaim). Updated the scratch Cleanup bullets + OQ decision, the idempotent-retry requirement, and the
idempotent-`page_token` acceptance scenario.
**Verified (logic against spec text):** "delete-on-terminal (inline): the request deletes the scratch row
when an export finishes (final page, cursor null)" (L337-338) contradicts "requesting the same cursor twice
must be safe" (L150) and "EXPIRED_CURSOR → CLI discards its partial file and restarts from a null cursor"
(L157-160). The final page is requested with token `T_last`; serving it deletes the scratch. If that page's
HTTP response is lost and the CLI retries `T_last`, the scratch is gone → **410 EXPIRED_CURSOR** → the CLI
discards the entire partial file and re-pulls the whole export — the worst moment to lose resumability.
**Suggested resolution:** Do not inline-delete on the terminal page. Keep the completed scratch row until its
normal TTL/sweep (so `T_last` stays idempotently re-servable), or mark it `completed` and re-serve the
identical terminal page on retry. Reserve inline delete for a distinct client-ack signal, or rely on the
sweep alone.

---

### Data / Persistence Engineer

#### RESOLVED: `endpoint_set` as Ecto `:map` cannot hold a JSON array — conflicts with the audit-search shape and the scratch shape
**⚠ SUPERSEDED by External Review Round 3 (F-ext3-1):** the original resolution below picked a **bare**
`{:array, :string}` / `{:array, :map}` field. That does NOT round-trip under `Ecto.Adapters.MyXQL` — the
adapter prepends `json_decode` only for `:map`/`{:map, _}` loaders (`ecto_sql .../myxql.ex:153-158`), so a
bare `{:array, _}` field reads the raw JSON string back and crashes on load (writes succeed; reads fail).
The "Verified at Ecto source" note below tested `Ecto.Type` in ISOLATION (which passes on an
already-a-list value) and did not exercise the adapter loader chain. **Corrected resolution:** use a custom
`:map`-typed Ecto type (`ReportServer.Types.EctoJsonArray`, `type/0 == :map`, list-shaped cast/load/dump,
mirroring `EctoReportFilter`) for BOTH fields — it gets the `:map` `json_decode` loader while keeping a
top-level array on dump (pathless `JSON_CONTAINS` unchanged). Original resolution retained below for the record.

**Resolution (typed array fields, no migration):** `data_access_log.endpoint_set` schema *field* retyped
`:map` → `{:array, :string}` (MySQL column already `json`; STORY-1 rows write null) — keeps the pathless
`JSON_CONTAINS(endpoint_set, JSON_QUOTE(?))` search. New `export_scratch.endpoint_set` declared
`{:array, :map}` (array of per-learner objects). Updated the audit "Storage shape" requirement, the
Technical-Notes schema bullet, and the Server-side-scratch column list. Wrap-in-`%{endpoints:[…]}` +
path-`JSON_CONTAINS` was rejected as less self-describing.
**Verified at Ecto source (3.12.4):** `deps/ecto/lib/ecto/type.ex:569` `dump(:map, v)`→`same_map`, `:667`
`load(:map, v)`→`same_map`, `:930` `cast_map` — all guard on `is_map(term)`; a **list fails on cast, dump,
and load** (`:984` `same_map(term) when is_map(term)`). The existing `data_access_log.endpoint_set` is `:map`
(`server/lib/report_server/audit_log/data_access_log_entry.ex`) and is currently written with no non-nil value
(only a `== nil` test), so the array path is unexercised. The spec wants a **top-level JSON array of
`remote_endpoint` strings** searched by pathless `JSON_CONTAINS(endpoint_set, JSON_QUOTE(?))` (L303-306), and
the new `export_scratch.endpoint_set :map` to hold a **list of `{remote_endpoint, source, project_id}`**
(L327-330) — both are arrays.
**Suggested resolution:** For both columns declare `{:array, :map}` / `{:array, :string}` (Ecto supports these,
`type.ex:562`) or a custom type; **or** commit to a wrapped-object shape (`%{endpoints: [...]}`) and change the
audit search to the path form `JSON_CONTAINS(endpoint_set, JSON_QUOTE(?), '$.endpoints')`. Pin one, since the
search SQL depends on it.

---

#### RESOLVED: History inner cursor `{created_at, docId}` needs a precision/type contract or it can skip snapshots (data loss)
**Resolution:** Pinned the cursor contract — carry `created_at` as the Firestore `Timestamp`'s full
`{seconds, nanoseconds}`, reconstruct a `Firestore.Timestamp` for `startAfter` (never a millis
number/ISO), floor-never-round-up if any lossy encoding is used. Added the contract to the Pagination
"Paginate by learner" bullet and a new "History ties at identical `created_at` across a page boundary"
acceptance test.
**Verified:** `interactive_state_histories.created_at` is a Firestore **serverTimestamp** (activity-player
`src/firebase-db.ts:604`) with sub-millisecond precision. portal-report's cited "proven" query
(`js/actions/index.ts:174`) uses only `orderBy("created_at","asc")` with **no explicit `__name__`** and no
cursor, so it is not a precedent for cursor round-tripping. If Node serializes `created_at` to millis/ISO and
reconstructs it for `startAfter`, rounding **up** skips every snapshot in that sub-ms window (the `__name__`
tiebreaker only helps at an exactly-equal value), and a plain number mis-compares against a Timestamp field.
The design tolerates duplicates (dedup-at-read) but **not** skips — a skip is silent research-data loss.
**Suggested resolution:** Specify the cursor carries the Timestamp's full `{seconds, nanoseconds}`, reconstructed
as a `Firestore.Timestamp` for `startAfter` (never a millis number / ISO string); if any lossy encoding is
used it must floor, never round up. Add a "ties at identical `created_at` across a page boundary" acceptance test.

---

### Security Engineer

#### RESOLVED: "Never reachable by any client that could supply arbitrary endpoints" is not achievable as written
**Resolution (A truthful rewording + D header-only hardening; no second secret):** Rewrote the
trust-boundary bullet (a)-(c) to state the accurate perimeter — public but static-bearer-gated, Elixir the
sole intended caller + sole authz chokepoint, bearer server-side only — and dropped the false
"unreachable" claim. Added (d): the bulk routes require the `Authorization: Bearer` **header** and reject
the `?bearer=`/body form. **An org-wide GitHub search (2026-07-14) confirmed every real caller already
uses the header and none uses the query-param/body form** (LARA `report_service.rb:118`, rigse
`students_controller.rb:248`, query-creator `firebase.js`, Elixir `report_service.ex`; org-wide
`?bearer=` sweep found only shell config scripts). A **separate secret was declined** (user decision) —
all tokens share the same server config, so it adds rotation burden without shrinking the real
compromise surface; (d) removes the query-param log-exposure it would have targeted.
**Verified:** The OQ resolved to co-locate the bulk routes on the **shared public gen1 `api` Express app**
(`functions/src/index.ts:64`, a public `functions.https.onRequest`). It is guarded only by `bearer-token-auth`
(`functions/src/middleware/bearer-token-auth.ts`), which compares against the **one shared `AUTH_BEARER_TOKEN`**
used by every route including `get-answer`, and even accepts the bearer as a **URL query param** (`?bearer=`).
So the bulk read is internet-reachable; anyone holding that shared secret can pass arbitrary `source` +
`remote_endpoint` and exfiltrate any learner's answers **and full history** across all sources — a categorically
larger blast radius than single-doc `get-answer`, behind the same secret. The trust-boundary requirement
(L201-208) claim (a) overstates the isolation.
**Suggested resolution:** Reword (a) to the truthful control (public but static-bearer-gated; Elixir is the sole
intended caller and sole authz chokepoint; secret hygiene is the boundary), **and** weigh giving the bulk route
a **separate secret** from the widely-used `get-answer` bearer so a leak of the common token does not
automatically grant bulk exfiltration. The OQ currently trades this away implicitly for co-location convenience.

---

### Minor / closes

- **Node envelope (closes the spec's own open verification, L453-454):** `res.success({items, next_page_token})`
  returns `{items, next_page_token, success: true}` — it mutates the object in place
  (`functions/src/middleware/response-methods.ts`). The Elixir↔Node internal payload thus carries an extra
  `success` key that Elixir must strip when reshaping for the CLI. Not a defect; pin it.
- **Wire imprecision:** Technical Notes L416 lists `secure_key` as a learner field — it is not standalone, only
  embedded in `run_remote_endpoint` (`learner_data.ex:162,179`). Cosmetic.
- **WCAG:** The a11y bullet is accurate (existing table has `<th>` + two distinctly-labeled pagers,
  `index.html.heex:6,35`), but existing `<th>` lack `scope="col"`, and the new filter should be a real labeled
  `<form>` (submit-on-enter), not just live-change. Small adds.

---

## Self-Review — Round 3 (code- and execution-verified, 2026-07-14)

A third multi-role pass in which **every** load-bearing factual claim in the spec was re-checked against the
actual source (report-service Elixir + `functions/`, activity-player, portal-report, rigse), and the two
highest-risk resolutions plus one test-strategy assumption were **executed** rather than reasoned about. The
verification confirmed the prior rounds were accurate; the findings below are **new gaps** those rounds did not
surface, not corrections.

**Execution results (prior resolutions hold under test):**
- **Ecto type resolution — ⚠ FALSE POSITIVE, corrected by External Review Round 3 (F-ext3-1).** This ran
  `Ecto.Type.cast/dump/load` **in isolation**, where `{:array,:string}`/`{:array,:map}` do round-trip a list
  (`{:ok, [...]}`) — but that test fed an already-decoded LIST and therefore never exercised the
  `Ecto.Adapters.MyXQL` **loader chain**, which is where the real bug lives: MyXQL prepends `json_decode`
  only for `:map`/`{:map,_}` loaders, so a bare `{:array,_}` field over a `json` column receives the raw
  JSON **string** on load and crashes. The correct resolution is a custom `:map`-typed Ecto type
  (`EctoJsonArray`) — see the SUPERSEDED note on the Round-2 Data/Persistence item and the implementation
  spec's "Why a custom Ecto type" section. (`:map` correctly returns `:error` on a list and accepts `nil` —
  that half of the observation stands.) **Lesson: an in-isolation `Ecto.Type` test does NOT prove adapter
  round-trip; verify against the driver's loaders/dumpers (or a real DB insert→select).**
- **Audit-search SQL — PASSES.** Ran against MySQL 8: pathless `JSON_CONTAINS(<json array>, JSON_QUOTE(?))`
  returns `1`/`0` correctly, matches on a JSON-**text** array (the top-level-array shape both a bare
  `{:array,:string}` **and** the corrected `EctoJsonArray` custom type dump — so this result is unaffected by
  F-ext3-1) and on a
  real slashed endpoint string embedding a `secure_key`; a `NULL` column yields `NULL` (unmatched, no error, so
  STORY-1 rows are safely skipped). (Dev DB is MySQL 8.0.39; prod is 8.4.7 — both support this.)
- **Emulator index enforcement — the finding below is proven, not asserted** (see #2).

### Security Engineer / Senior Engineer

#### RESOLVED: Requirement (d) "header-only bearer on the bulk routes" cannot be enforced by the shared middleware, is unscoped, and has no acceptance test
**Resolution:** Reworded trust-boundary bullet (d) to state header-only is **not** a free property of the
shared middleware (which accepts query/body/header and records no source) and must be implemented as a **small
per-bulk-route guard** that 401s when `req.query.bearer`/`req.body.bearer` is present, deliberately leaving the
shared middleware unchanged so co-located routes and all existing callers are unaffected. Added an acceptance
scenario ("Header-only bearer on the bulk routes": `?bearer=`/body → 401, header → allowed).
**Verified:** `functions/src/index.ts` mounts every route on one Express app with `api.use(bearerTokenAuth)`,
and `functions/src/middleware/bearer-token-auth.ts:23-34` extracts the token from `?bearer=` query param **or**
`req.body.bearer` **or** the `Authorization: Bearer` header, then compares against the one shared token —
**recording nothing about which source authenticated**. So a request that authenticated via `?bearer=` is
already past the middleware before any route handler runs. Requirement (d) (spec L246-255) states the bulk routes
"reject the query-param/body bearer and require the header … without a second secret and without breaking any
caller," and the Round-2 security item repeats it as settled — but the shared middleware makes header-only
enforcement **impossible for one route without extra code**: either (a) a per-bulk-route guard that re-inspects
`req.query.bearer`/`req.body.bearer` and 401s if present, or (b) a change to the shared middleware (which the
same OQ deliberately avoids so as not to alter `get-answer` et al.). Neither the mechanism nor a test scenario is
specified. **Suggested resolution:** pin the mechanism (recommend a small per-bulk-route check, since it keeps
the shared middleware and all existing callers untouched), and add an acceptance scenario: a bulk request
carrying the token only as `?bearer=`/body → **401**, header form → allowed. Reword (d) to note it is a
per-route add, not a free property of the existing middleware.

### QA Engineer / DevOps Engineer

#### RESOLVED: The emulator-backed test strategy cannot catch the missing dev composite index the spec flags as a prerequisite (false-green)
**Resolution:** Added a caveat to the Test-strategy bullet (emulator green does not prove index coverage) and a
required **Non-emulator index guard** to Deployment / operational notes — a deploy-checklist assertion that the
`interactive_state_histories` composite index exists in the target project (via `firebase firestore:indexes` /
the Firestore admin API), run against the live project before the history route is exercised there.
**Verified by execution (both directions):** with `firestore.indexes.json` empty, the Firestore emulator
served the exact history query (three equality filters on `platform_id`/`platform_user_id`/`resource_link_id` +
`orderBy(created_at, __name__)`) returning docs with **no composite index declared**; the *same* query run
against the **real `report-service-dev` project** threw `FAILED_PRECONDITION: The query requires an index`
(with a click-to-create link) — proving both the false-green and that the dev composite index is genuinely
missing. The spec both (i) makes
emulator tests the primary strategy because "the bulk read *is* its Firestore query/cursor/order behavior"
(L536, Technical Notes) and (ii) flags the missing `report-service-dev` composite index as a required
prerequisite (L268-279). Because the emulator does **not** enforce composite indexes, the test suite stays
green while a real dev/prod query throws `FAILED_PRECONDITION`. **Suggested resolution:** add an explicit
non-emulator guard for the index prerequisite — a deploy-checklist assertion and/or a test that verifies the
index exists via the Firestore admin/REST API against the real project — and note in the test-strategy bullet
that emulator green does not prove index coverage.

#### RESOLVED: "Firestore emulator, already configured" overstates the harness — there is no automated emulator test infrastructure today
**Resolution:** Corrected the Test-strategy wording (emulator binary configured vs no automated test harness),
added an early Phase-2 step to stand up the harness with the **verified-working** minimal approach (a
`test:emulator` script wrapping jest in `firebase emulators:exec`; a probe test passed this way), and — from a
hazard the probe exposed — added a **required safety guard**: emulator tests must fail closed when
`FIRESTORE_EMULATOR_HOST` is unset, because an admin-SDK jest test run without the wrapper connects to the
**real `report-service-dev` project** (verified: it ran against live Firestore and returned the real project's
`FAILED_PRECONDITION`), so an unguarded seeding test would read/write live dev data.
**Verified:** `functions/package.json` has `firebase-functions-test ^0.3.3` (an SDK stub, not an emulator
harness), `jest ^24` (old), **no** `@firebase/rules-unit-testing`, **no** jest `globalSetup`/`globalTeardown`,
the `test` script is plain `jest`, and no existing test references `FIRESTORE_EMULATOR_HOST` (only the runtime
`firebase-client.ts:54` does). The `emulator` npm script (`firebase emulators:start --import=./emulator-data`)
is a **manual** data-run tool, not wired into `npm test`; all existing `functions/` tests are pure in-memory
unit tests. So the spec's "emulator … already configured" (Technical Notes L536-537) is true of the emulator
binary but **not** of any test harness. Standing up the first emulator-backed jest test is net-new
infrastructure (emulator lifecycle around jest — e.g. `emulators:exec 'jest'` or a `globalSetup` — admin SDK
pointed at `FIRESTORE_EMULATOR_HOST`, likely a jest/ts-jest bump, and CI wiring). **Suggested resolution:**
scope this harness as an explicit early implementation step in Phase 2 (it gates every emulator test the
strategy depends on), and correct the Technical-Notes wording to distinguish "emulator configured" from
"emulator test harness exists."

### Security Engineer / Education Researcher (IRB)

#### RESOLVED (accepted, not masked): This story is the first to persist `remote_endpoint`s in the audit log, and each embeds a learner `secure_key` (a live access credential) — now stored indefinitely and made admin-searchable/displayable
**Resolution (user decision — accept, no masking):** Storing the full `remote_endpoint` raw is accepted
because the identical value **already travels to the researcher in every `/answers` and `/history` export**,
so the audit copy is not a new exposure of the `secure_key` — same value, under the existing admin-only +
indefinite-retention posture. No UI masking. Added an audit-logging bullet recording this rationale and noting
a non-secret search key as a possible later hardening (out of scope). The one genuinely-new fact (this is the
first story to populate `endpoint_set`, which STORY 1 only ever wrote as `nil`) is captured there.
**Verified:** `data_access_log.endpoint_set` has only ever been written `nil` (STORY 1 reserved the column but
never populated it — confirmed at `data_access_log_entry.ex` + a grep for writers), so STORY 3 is the **first**
code to store real endpoints there. `remote_endpoint = "#{site_url}/dataservice/external_activity_data/#{secure_key}"`
(rigse `portal/learner.rb:112-117`), and `secure_key` is the bearer-style token activity-player uses to
read/write that run's data (rigse `ExternalActivityData` path) — i.e. **credential-grade**, not a mere
identifier. The audit requirements (L303-306, L337-370) treat `endpoint_set` sensitivity as "which students
were accessed" and inherit STORY 1's admin-only + **indefinite retention**, and this story additionally renders
and free-text-searches it in the admin LiveView. Net effect: per-learner access credentials stored at rest
forever in a searchable, rendered admin table — a surface neither STORY 1 (column always null) nor the prior
rounds weighed. **No new exfil path to the researcher** (the answer/history docs already carry `remote_endpoint`,
returned raw by `/answers`), but the **retention + admin-render + search** surface is new. **Suggested
resolution:** decide among (a) index/store a non-secret student key for search (e.g. hash of `remote_endpoint`,
or `platform_user_id`+`offering_id`) instead of the raw endpoint; (b) mask the `secure_key` when rendering
`endpoint_set` in the admin UI; or (c) explicitly accept storing the raw endpoint with a written rationale and a
retention note. Pin one.

### QA Engineer

#### RESOLVED: The two most important history correctness tests (ties + sub-ms precision) can't be built from the prescribed seed shape
**Resolution:** Amended the Test-strategy seeding to carve out the ordering/tie/precision fixtures to use
controlled explicit `admin.firestore.Timestamp(seconds, nanoseconds)` values (chosen ties + sub-ms gaps) while
shape-fidelity fixtures keep `serverTimestamp`. **Verified on the emulator (2026-07-14):** explicit Timestamps
are accepted, a full-precision `{seconds,nanoseconds}` `startAfter` cursor resumes across a tie with no skipped
snapshot, and a millis-rounded-up cursor **skips** a snapshot — an executable demonstration of the data loss the
precision contract forbids, confirming the acceptance test is both constructible and meaningful.
**Verified:** `interactive_state_histories.created_at` is written as `FieldValue.serverTimestamp()`
(activity-player `firebase-db.ts:604`), which is **server-assigned** — a test cannot force two docs to share an
*exactly-equal* `created_at` (the tie case) or sit a chosen *sub-millisecond* apart (the precision case) using
that shape. But the test strategy (L544-548) says to seed "mirroring activity-player's real write shapes …
metadata doc with a server `Timestamp` `created_at`," and the acceptance list requires exactly those two tests
(L618-621). Taken literally the seed rule blocks the fixtures the tests need. The tie/precision fixtures must
instead write explicit `admin.firestore.Timestamp(seconds, nanoseconds)` values — a deliberate, documented
deviation from the serverTimestamp production shape. **Suggested resolution:** amend the test-strategy bullet to
state that the ordering/tie/precision fixtures use **controlled explicit `Timestamp` values** (chosen
`{seconds, nanoseconds}`), while the shape-fidelity fixtures use `serverTimestamp` — so both the "faithful
shape" tests and the "cursor precision" tests are constructible.

### Performance Engineer / Senior Engineer

#### RESOLVED (minor): The duplicate-learner (1:many) case amplifies history reads beyond the stated cost formula
**Resolution:** Added a parenthetical to the page-cap/read-cost bullet noting the formula is the 1:1 figure and
that the rare duplicate-learner case multiplies history reads by the sibling count over the shared snapshot set,
with optional tuple-query-result caching in scratch as a future mitigation (not required here).
**Verified (logic against the confirmed 1:many cardinality):** sibling `remote_endpoint`s for one
(student, offering) share a single LTI tuple (rigse: no unique `(student_id, offering_id)`, non-atomic
`find_or_create_learner`), so each sibling **endpoint index** independently re-runs the identical
`interactive_state_histories where {tuple}` query + state batch-get and then filters to its own
`remote_endpoint`, discarding the siblings' snapshots — N siblings → **N× reads** over the same snapshot set.
Correctness is unaffected (the spec's required post-filter handles it), but the read-cost formula
"~2× cap + one `limit(1)` tuple read per learner" (L412-418) silently assumes 1:1 and under-counts the
duplicate case. Bounded by the rarity of duplicates and the per-page item cap. **Suggested resolution:** either
cache the tuple **query result** (not just the tuple) in the scratch so sibling endpoints reuse it, or add a
one-line note that the cost formula is the 1:1 figure and the rare duplicate case multiplies history reads by
the sibling count.

---

## Self-Review — Round 4 (code- and execution-verified, 2026-07-14)

A fourth multi-role pass. Roles: Elixir/OTP Engineer, Firestore/Node Engineer, adversarial Security Engineer,
API-Contract/Integration Engineer, Data-Integrity/Research-Validity Engineer, Product/Scope (STORY-4 handoff).
**Every finding below was verified against the actual source before being written** (report-service Elixir +
`functions/`, plus activity-player / portal-report / rigse), per the review mandate; the two highest-risk items
(the composite-cursor forgery and the timestamp serialization/precision cluster) were **executed** — a forged
STORY-1 token and Firestore-emulator cursor/precision probes — not merely reasoned. These are **new gaps** the
first three rounds did not surface. Several are implementation-blocking (they would make a straight-ahead build
fail or silently lose data), which is why they matter despite the spec's maturity.

### Security Engineer / Senior Engineer

#### RESOLVED: Composite cursor is unsigned forgeable plaintext AND the spec never re-verifies the loaded scratch's ownership → cross-researcher IDOR
**Verified (executed):** STORY 1's page token is plaintext base64 with **no MAC** — `encode_page_token(id) =
Base.url_encode64(Integer.to_string(id))` (`params.ex:40`); parse just base64-decodes + `Integer.parse`s
(`params.ex:28-29`). No `:crypto`, `Plug.Crypto.sign`, or `secure_compare` anywhere in the token path. I forged
a valid token for an arbitrary id with zero secret knowledge (`enc(999999) = "OTk5OTk5"` → decodes to `999999`).
STORY 3 reuses this format for a **composite** `{scratch_id, endpoint_index, inner_cursor}` (L159-166) and
"loads the scratch snapshot" from the token's `scratch_id` (L164-166) — but **no requirement re-checks
`scratch.user_id == caller` and `scratch.report_run_id == :id` on load.** The `:id` ownership gate (L89) guards
only the **path param**, not the scratch the token points to. In STORY 1 an unsigned token is harmless because
the id is consumed inside a **user-scoped** query (`list_api_report_runs`, `reports.ex:71-84`) that bounds it to
the caller's own rows; STORY 3 breaks that safety because the scratch row **is the authorization of record**
(L393-399). **Attack:** researcher A presents a `page_token` carrying researcher B's `scratch_id` → resumes B's
export and exfiltrates B's authorized learners' answers + full history.
**Severity: CRITICAL.**
**Suggested resolution:** On every page load, require the scratch to satisfy a single guarded `WHERE scratch_id
== ? AND user_id == ^caller.id AND report_run_id == ^id AND expires_at > ^now`, returning **404** on miss
(indistinguishable, per this story's own 404 posture) — mirroring `exchange_auth_grant`'s guarded lookup
(`accounts.ex:200-203`).

**Decision:** **A (capability + ownership re-check) — adopted.** Every page load re-verifies the scratch with a
single guarded query `WHERE scratch_id == ? AND user_id == ^caller.id AND report_run_id == ^id AND expires_at >
^now`, returning **404** on miss (indistinguishable). Paired with a random `strong_rand_bytes` `scratch_id` (see
next item), so the binding holds even against a guessed/leaked id. See the updated "Server-side scratch" and
Pagination "Cursor ownership (tier split)" requirement bullets.

---

#### RESOLVED: `scratch_id` minting is unspecified — a table-autoincrement PK would be guessable, compounding the IDOR above
**Verified:** the scratch id is described only as "opaque `scratch_id`" (L404, L159, L394) with **no minting
method**, and the MySQL-table backing + "matches STORY 1's `auth_grants` precedent" framing invites a default
bigint autoincrement PK (sequential, enumerable). The codebase already has the correct unguessable-capability
idiom the spec fails to cite: `auth_grants` mints `Base.url_encode64(:crypto.strong_rand_bytes(32))` and stores
only its SHA-256 (`accounts.ex:170,177,226-227`); the API-token path uses the same `strong_rand_bytes` pattern
(`accounts.ex:81`). The spec cites `auth_grants` for **TTL/expiry** (L401, L529-531) but **not** for id
generation.
**Severity: CRITICAL in combination with the item above** (guessable id + no ownership re-check = trivial
enumerable IDOR); High even alone (an "opaque" capability that is actually enumerable is not opaque).
**Suggested resolution:** specify `scratch_id = Base.url_encode64(:crypto.strong_rand_bytes(32), padding:
false)` (a random capability token, **not** the table PK), reusing the `auth_grants` mint. With the ownership
re-check this is defense-in-depth; without it, unguessability is the only barrier between researchers.

**Decision:** **A (capability + ownership re-check).** Mint `scratch_id = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)`
(a random capability token, not the table PK), reusing the `auth_grants` mint. This resolves both this item and
the ownership item above. HMAC-signing the whole cursor (option B) was considered and **not** adopted: A already
fails closed on the ownership predicate regardless of how a `scratch_id` is obtained, and the endpoint-index /
inner-cursor bounds validation (see the `endpoint_index` item) neutralizes the tamper-correctness risk B would
target — so B's signing layer (a new pattern STORY 1 doesn't have) buys no additional confidentiality on top of A.

---

#### RESOLVED: `endpoint_index` and the inner Firestore cursor are attacker-controlled token fields with no bounds/validation
**Verified:** Elixir "parses the incoming `page_token` → `{scratch id, endpoint index, inner cursor}`" and
"slices the ordered endpoint list from the cursor's endpoint index onward" (L116-117, L164-166), then hands Node
the slice + inner cursor. No requirement validates `0 <= endpoint_index < length(endpoint_set)` or constrains
the inner cursor (STORY 1's parser only validates the id is `1..max_bigint`, `params.ex:29,43-44` — no analog for
the composite fields). **Confidentiality is not the risk once ownership is fixed** — Node's `where` clause is
server-set from the (ownership-checked) scratch slice, so an injected inner cursor only re-positions `startAfter`
**within** the authorized endpoint and cannot widen the query; an out-of-range `endpoint_index` reaches nothing
beyond the authorized set. The real risk is **unhandled** input → a slice past the list end or a garbage cursor
crashing the request (500 / undefined behavior).
**Severity: HIGH** (robustness; confidentiality angle collapses into the ownership fix).
**Suggested resolution:** after loading the ownership-checked scratch, validate `endpoint_index ∈ [0, len)` →
`BAD_REQUEST` otherwise; treat a malformed inner cursor as `BAD_REQUEST`; and state explicitly that the inner
cursor never influences the Firestore `where` clause (server-set from scratch), making injection provably
non-widening.

**Decision:** **Adopted** (with option A). Elixir validates `endpoint_index ∈ [0, len)` (`BAD_REQUEST` otherwise)
and rejects a malformed inner cursor as `BAD_REQUEST`, both **after** the ownership-checked scratch load; the spec
now states the inner cursor never influences the server-set `where` clause. Threaded into the Pagination
"Opaque composite cursor" integrity bullet and the "Cursor ownership (tier split)" step (1).

---

#### RESOLVED (low, falls out of the ownership fix): delete-on-`EXPIRED_CURSOR` is not ownership-scoped
**Verified:** "a resume that finds the scratch already lapsed **deletes the (invisible) row**" (L415-416) keys the
delete off the token's `scratch_id` with no `user_id`/`report_run_id` predicate. With a guessable id (above) a
caller could trigger deletion of another user's lapsed scratch — a griefing/reclaim-timing nuisance (the row is
already TTL-invisible and swept anyway), not data loss.
**Severity: Low** (Medium only if the two items above stay open).
**Suggested resolution:** scope the inline delete with the same `WHERE scratch_id == ? AND user_id == ? AND
report_run_id == ?` — free once the ownership predicate is required.

**Decision:** **Adopted (free rider on option A).** The inline `EXPIRED_CURSOR` delete carries the same
`WHERE scratch_id == ? AND user_id == ^caller.id AND report_run_id == ^id` predicate as the page-load lookup, so
a caller can only ever delete a scratch that is already bound to them.

---

### Elixir/OTP Engineer

#### RESOLVED: "Empty export → 200 `items: []`" is contradicted by `LearnerData.fetch`, which returns `{:error, …}` on an empty learner set
**Verified:** the core acceptance criterion (L660-662) and the "empty-200 leaks nothing" reasoning (L462-463,
L873) promise a **200 with `items: []`** when the live learner set is empty (empty roster, or a researcher scoped
to nothing → `[]`). But `LearnerData.fetch` → `map_learner_data` calls `ensure_not_empty(rows, "No learners were
found matching the filters you selected.")` (`learner_data.ex:154`), and `ensure_not_empty` returns
`{:error, message}` on an empty list (`report_utils.ex:90-96`) — **an error tuple, never `{:ok, []}`**. STORY 1's
report generation *wants* this (a no-learner report is a user error); STORY 3 wants the opposite. The spec never
mentions `ensure_not_empty`. (Note: `allowed_project_ids == :none` is unreachable via this API — `can_access_reports?`
requires admin/project-admin/researcher, so a caller is always `:all` or a possibly-empty list, never `:none`;
a zero-project researcher gets `[]` → zero rows → this same empty path, not a raise.)
**Severity: BLOCKING** — an empty/narrowly-scoped export errors instead of returning the promised empty-200, and
the page-1 intent-audit-row flow has no set to snapshot.
**Suggested resolution:** STORY 3 must not reuse the empty-is-error path — call a `LearnerData` variant (or a thin
wrapper) that maps `{:error, "No learners…"}`/empty rows to `{:ok, []}`, and pin this in the spec.

**Decision:** **A (option-gated `LearnerData` variant) — adopted, verified non-breaking.** Add `opts \\ []` to
`fetch` threaded into `map_learner_data`, and when `allow_empty: true` skip `ensure_not_empty` (empty rows →
`{:ok, []}`); STORY 3 calls `fetch(report_filter, caller, allow_empty: true)`. **Not** the error-string-match
option (B), which would couple a correctness path to a human-readable message. **Blast-radius check (verified):**
`fetch/2` has exactly 4 callers, all via `fetch_and_upload/2` (`student_actions`,
`student_actions_with_metadata`, `student_answers`, `student_assignment_usage`), none pass opts;
`map_learner_data` is private; `ensure_not_empty` has this single usage; no test references `LearnerData.fetch`.
With `allow_empty` defaulting to `false` the existing `with` chain is byte-identical, so all four reports keep
"no learners → `{:error, …}`". The empty path is clean — `get_teacher_map([], …)`/`get_permission_form_map([],
…)` already have `{:ok, %{}}` clauses (`learner_data.ex:223,260`), so empty rows fold to `{:ok, []}` with no new
throw. Threaded into the "Live endpoint derivation" requirement bullet.

---

#### RESOLVED: The audit changeset's `validate_inclusion` allow-lists reject every STORY-3 row → fail-closed ordering 500s every bulk request
**Verified:** `DataAccessLogEntry.changeset` hard-validates `validate_inclusion(:event, ["download_url_issued"])`
and `validate_inclusion(:data_type, ["run_csv", "job_result"])` (`data_access_log_entry.ex:31-33`). STORY 3 needs
`event: "export_scoped"` + a per-page event (L318) and `data_type` values `answers_bulk`/`history_bulk`/
`export_scoped` (L318,L324). All STORY-3 audit writes go through `AuditLog.create_entry` → `changeset` →
`Repo.insert` (`audit_log.ex:45-48`), so these inclusions reject STORY-3's values; combined with the story's own
**fail-closed ordering** (L338-341: audit-write failure ⇒ `SERVER_ERROR`, no data), **every** `/answers` and
`/history` page would 500. Also: the new nullable `export_id` column must be added to the changeset `cast` list
(`:28-29`) or it is silently dropped; and `issue_download_url` hardcodes `event: "download_url_issued"`
(`audit_log.ex:21`), so STORY 3 cannot reuse it and must extend the validated `create_entry` path.
**Severity: BLOCKING** — unmentioned required code change; retyping `endpoint_set` alone is insufficient.
**Suggested resolution:** the spec must call out extending `validate_inclusion(:event, …)` and `(:data_type, …)`
for the new labels and adding `export_id` to `cast`.

**Decision:** **A (extend allow-lists + dedicated `bulk_read` event) — adopted, verified non-breaking.** The
changeset changes:
- `validate_inclusion(:event, ["download_url_issued", "export_scoped", "bulk_read"])`
- `validate_inclusion(:data_type, ["run_csv", "job_result", "answers_bulk", "history_bulk", "export_scoped"])`
- add `field :export_id, :string` to the schema and `:export_id` to the `cast` list.
- **Access rows use a dedicated `event: "bulk_read"`, NOT the reused `download_url_issued`** (the spec's L324
  "existing event" is corrected — a bulk Firestore read issues no download URL, and conflating it with CSV-presign
  events pollutes the audit log). Intent row: `event: "export_scoped"`, `data_type: "export_scoped"`. Access rows:
  `event: "bulk_read"`, `data_type: "answers_bulk"` / `"history_bulk"`.
- STORY 3 does **not** reuse `issue_download_url` (which hardcodes `event: "download_url_issued"`,
  `audit_log.ex:21`); it writes via `create_entry` (or a new fail-closed helper) with the new labels.

**Blast-radius check (verified):** the negative tests at `audit_log_test.exs:136-142` assert `"nope"` is rejected
for event/source/data_type — still true under the extended lists; existing writers keep valid values; `cast`
ignores callers that omit `export_id`; existing rows get `NULL` for the new column. Threaded into the "Audit
logging" requirement bullets.

---

#### RESOLVED (accuracy): sliding-TTL bump is misattributed to the "`auth_grants` idiom" — auth_grants never bumps `expires_at`
**Verified:** the spec says the sliding TTL "bump `expires_at = now + 1h` on every page read" follows "the
`auth_grants` idiom" (L409-412, L768). auth_grants does exactly one state transition — a conditional consume
`WHERE code_hash=? AND is_nil(used_at) AND expires_at > now` `set used_at: now`, asserting `{1,_}`
(`accounts.ex:200-206`) — and **never** updates `expires_at`. The read-time *expiry filter* (`WHERE expires_at >
now`) is genuinely the auth_grants idiom; the *bump* is new. The bump is not harmfully racy (an absolute `SET
expires_at = now+1h` converges monotonically under concurrent retries) — this is a precedent-accuracy issue.
**Severity: minor.** **Suggested resolution:** reword to state the bump is new (auth_grants has no sliding TTL)
and must be an absolute `SET` (not `expires_at + delta`) so concurrent same-token retries stay idempotent.

**Decision:** **Adopted.** Reworded the Server-side-scratch "Sliding TTL" bullet: the read-time expiry filter is
the `auth_grants` idiom but the bump is new (auth_grants has no sliding TTL), and it must be an absolute
`SET expires_at = ^(now + 1h)`.

---

#### RESOLVED (accuracy): malformed-`:id` → 404 comes from `Params.parse_id`, not `get_api_report_run/2` (which would raise)
**Verified:** the spec attributes indistinguishable-404-for-malformed-`:id` to `Reports.get_api_report_run/2`
(L89-91, L686-687), but that function has a `when is_integer(id)` guard (`reports.ex:91`) — a non-integer id
would raise `FunctionClauseError` (500), not 404. The malformed-id 404 actually comes from `Params.parse_id/1`
(`params.ex:42-49`), which STORY 1's controller calls **first** (`report_controller.ex:23-24,35-36`). If STORY 3's
new controller omits `parse_id`, malformed ids raise instead of 404-ing.
**Severity: minor.** **Suggested resolution:** state the malformed-id 404 comes from `parse_id`, and that STORY 3
must keep the `parse_id` → `get_api_report_run` order.

**Decision:** **Adopted.** Noted in the "Authz reuses STORY 1's ownership gate" requirement bullet that the
malformed-`:id` 404 comes from `Params.parse_id/1` and STORY 3 must keep the `parse_id` → `get_api_report_run`
order.

---

### Firestore/Node Engineer

#### RESOLVED: A raw Firestore `Timestamp` serializes to `{_seconds,_nanoseconds}` via `res.json`, **not** the ISO 8601 the wire contract requires
**Verified (executed):** `JSON.stringify(new Timestamp(...))` → `{"_seconds":…,"_nanoseconds":…}`; `res.success`/
`res.json` use `JSON.stringify`. The wire contract makes the history item's authoritative `created_at` "ISO 8601,
serialized from the metadata doc's Firestore `Timestamp`" (L301-303), but the spec never says Node must call
`.toDate().toISOString()` — and a naive "fold `created_at` in and return raw" implementation (the pattern the
raw-passthrough design otherwise encourages, L291-303) would emit `{_seconds,_nanoseconds}` and silently violate
the ISO contract. This is precisely the hazard the raw-passthrough ethos invites.
**Severity: Medium** (contract violation waiting to happen; not caught by any stated test).
**Suggested resolution:** add an explicit requirement + acceptance test: Node converts the metadata `created_at`
Timestamp to an ISO string before adding it to the history item; a raw `Timestamp` must never reach `res.json`.

**Decision:** **Adopted.** The `/history` item-shape requirement now mandates Node convert the metadata
`created_at` `Timestamp` via `.toDate().toISOString()` before folding it in (a raw `Timestamp` serializes as
`{_seconds,_nanoseconds}`, not ISO).

---

#### RESOLVED (accuracy + wire dedup): Firestore stores **microsecond**, not "nanosecond/sub-millisecond," precision, and the wire ISO-8601 `created_at` (ms) collapses distinct µs snapshots
**Verified (executed on emulator):** Firestore truncates the nanosecond field to **microsecond** granularity on
write (`nanos=123456789 → 123456000`; `nanos=500001 → 500000`). The spec repeatedly says "sub-millisecond
precision" / "full `{seconds, nanoseconds}`" / "sub-ms window" (L150-158, L584-588, L1138-1147, L1306-1316) —
the stored resolution is microseconds, so "nanoseconds"/"sub-ms" overstate it and a fixture attempting a sub-µs
gap collapses to a tie (a false, invisible ordering fixture). Separately: `new Timestamp(1000,500000)` and
`new Timestamp(1000,501000)` (1µs apart, distinct, correctly cursor-ordered) **both** `.toISOString()` to
`…:40.001Z` — so the wire `created_at` (ISO ms, L301-303) is the field the CLI dedups on ("keep latest
`created_at`") yet cannot distinguish two sub-ms-apart snapshots. The cursor stays µs-safe; only the wire dedup
tiebreak is lossy. (The precision *conclusion* — never JS-millis, floor-never-round-up — still holds; µs is also
lost by ms encodings.)
**Severity: Low-Medium** (factual accuracy in a load-bearing contract + an under-specified CLI dedup tiebreak).
**Suggested resolution:** reword the precision contract to "microsecond precision (Firestore truncates below
1µs)"; ordering/tie fixtures use ≥1µs gaps; and state the CLI must break `created_at` ties by `history_id` (the
ISO-ms wire value alone can't), or emit sub-ms `created_at` on the wire.

**Decision:** **Adopted (reword + tiebreak).** The History-cursor precision bullet now says **microsecond** (not
sub-ms/nanosecond), and the `/history` item-shape requirement states the CLI must break `created_at` ties by
`history_id` since the wire ISO string is ms-precision. Cursor stays full `{seconds, nanoseconds}` (µs-safe).

---

#### CLOSED (verification note, no change needed): `req.body.bearer` **can** be set on these GET routes — the header-only guard's body branch is load-bearing, not dead code
**Verified:** `index.ts` mounts no `express.json()`/body-parser, yet existing POST handlers read `req.body`
because the gen1 Cloud Functions runtime pre-parses the body by content-type before Express runs — and that
parse is **method-agnostic**, so a GET carrying a JSON/form body + matching `Content-Type` populates
`req.body.bearer`, which `bearer-token-auth.ts:26-28` accepts. This **confirms** the spec's prescribed guard must
check **both** `req.query.bearer` **and** `req.body.bearer` (a query-only guard would miss a real vector). No spec
change needed beyond ensuring the "Header-only bearer" acceptance test (L688-691) actually exercises a
**GET-with-body**, not only `?bearer=`.
**Round-5 update:** the internal bulk hop is now pinned as **POST with a JSON body** (Round-5 finding #6, the
Elixir↔Node wire contract), so the body branch is directly load-bearing for the bulk routes regardless of the
gen1 pre-parse subtlety; the acceptance test covers both the POST body form and (for co-located GET routes)
the GET-with-body form.

**Decision:** <!-- confirmatory; body-bearer guard covered by the Round-5 header-only resolution + acceptance test -->

---

### Data-Integrity / Research-Validity Engineer

#### RESOLVED: "Answer doc **verified equivalent** to the latest history snapshot" overstates it — nested `answer` maps use deep-merge vs shallow-spread and can diverge
**Verified (executed simulation):** the answer doc is written `batch.set(answerRef, answerDocData, {merge: true})`
— Firestore `merge:true` **deep-merges** nested map fields (`firebase-db.ts:518`); the history-state doc is
`const historyState = {...existingAnswerData, ...answerDocData, …}` — a JS **shallow spread** that wholesale-
replaces nested maps (`firebase-db.ts:531`). Simulating a later save that drops a sub-key of the nested `answer`
object (e.g. `image_question_answer = {text, image_url}`, `types.ts:302-308`): Firestore-merge preserved the
stale `image_url` in the **answer** doc while the spread dropped it from the **history** doc → the two `answer`
objects were **not** byte-equal. (`report_state` is a flat string, always fully replaced — no divergence there;
`attachments` never diverge.) So the L266-268/L531/L787 justification ("no `history_mode`; latest = `/answers`")
is field-level / `report_state`-byte equivalent, **not** byte-identical for nested maps.
**Severity: Moderate** (narrow: needs a partial nested-`answer` update). **Suggested resolution:** downgrade
"verified equivalent" to "equal for `report_state` and scalar fields; nested `answer` maps can differ (deep-merge
vs shallow-spread) on a dropped sub-key," and keep `/history` (not `/answers`) as the authority for a snapshot's
exact nested state.

**Decision:** **Adopted.** The `history_mode` OQ / requirement bullet now says the answer doc equals the latest
snapshot for `report_state` + scalar fields but is **not** byte-identical for nested `answer` maps (deep-merge vs
shallow-spread); `/history` is the authority for exact nested state.

---

#### RESOLVED: "union = all, no double-count" fails when the run's filters exclude one sibling `secure_key` → that endpoint's history is silently dropped (`/answers` vs `/history` asymmetry)
**Verified (static trace):** the duplicate-learner claim (L227, L666-668, L1324-1338) says every sibling
`remote_endpoint` is iterated so the post-filter reassembles the complete set. But `LearnerData.fetch` applies
the run's **per-learner filters/permissions** — the date-range filter targets `run.start_time` via a per-learner
`LEFT JOIN portal_runs` (`report_utils.ex:32-46`, `learner_data.ex:53`). A sibling `secure_key` whose runs fall
outside the window (or that fails any per-learner filter) is **excluded from the authorized set**, so no endpoint
index exists for it — yet the shared-tuple history query still returns its snapshots, which the required
post-filter drops at every *authorized* index → **that sibling's history is silently omitted**. This is arguably
*correct scoping* (the sibling is genuinely unauthorized), but it contradicts the absolute "union = all" and
creates an asymmetry: `/answers` never touches the excluded endpoint (clean omission) while `/history` pulls its
snapshots in and discards them, with no signal.
**Severity: Moderate** (research-completeness clarity). **Suggested resolution:** reword to "union = all
*authorized* siblings; a sibling excluded by the run's date/permission filters is intentionally dropped (correct
scoping), so history is bounded by the same per-learner filter as answers" and state the answers/history symmetry.

**Decision:** **Adopted.** Reworded "union = all" → "union = all **authorized** siblings" in both the Firestore
read-surface filter requirement and the duplicate-learner acceptance scenario, with the filter-excluded-sibling
caveat and the `/answers`↔`/history` symmetry noted.

---

#### CLOSED (verification note): the double-decode inner value may be a **string**, not an object — pin a try/catch expectation for the CLI
**Verified:** double-encoding is unconditional (`embeddable-utils.ts:77,85,123`), but the inner
`interactiveState` parse can legitimately yield `string | object | null | array` (a raw-string interactiveState
round-trips to a string — explicit comment `embeddable-utils.ts:72-77`); both existing readers double-parse in
try/catch (`answer-utils.ts:31-32`, `report-reducer.ts:315-327`). No answer leaves `interactiveState` a bare
object. **Server change: none** (raw passthrough is correct). Worth one wire-contract sentence so STORY 4 doesn't
assume the inner value is always an object.

**Decision:** <!-- confirmatory; one-line note in Item shapes -->

---

### Product / Scope (STORY-4 handoff) + API Contract

#### RESOLVED: The envelope contract does not pin that `items: []` with a **non-null** `next_page_token` is a valid mid-export page — a silent-data-loss trap for the CLI
**Verified:** the contract says only "`next_page_token` is null on the last page; the CLI loops until null"
(L133-135). But the mechanic guarantees mid-export empty pages: a learner with answers but no history → tuple
query empty (L648, L663-664), and a page accumulates across endpoints to the ~500 cap (L431-437), so a page can
touch only no-history learners → `items: []` while more endpoints remain (non-null token). The spec never states
that `items: []` + non-null token is legal and must **not** be treated as end-of-stream. A CLI written to the
common "stop when items is empty" idiom would truncate the export and silently drop every learner after the first
empty page — indistinguishable from success.
**Severity: HIGH** (silent research-data-loss contract trap). **Suggested resolution:** add to the envelope
contract: "A page MAY return `items: []` with a **non-null** `next_page_token`; termination is signalled
**solely** by `next_page_token == null`; the CLI MUST NOT treat empty `items` as end-of-stream," plus an
acceptance scenario.

**Decision:** **Adopted (no alternative).** Pinned the terminal-signal contract in the Pagination "Unified
envelope" bullet and added the "Empty mid-export page (non-terminal empty items)" acceptance scenario.

---

#### RESOLVED: `/answers` and `/history` mint **two** export ids for one logical researcher pull — fractures the "which students were in export E?" audit story
**Verified:** `export_id = scratch id` (L311-313), scratch is minted per-export keyed to an endpoint's iteration
state, and the two routes have **incompatible inner-cursor shapes** (answers `{docId}` vs history
`{created_at,docId}`, L146-147) so they **cannot** share one scratch → each mints its own `export_id`. The spec
never says this. The headline audit value is "which students were in export E?" (L313), but a researcher's real
action ("pull run 42") is **two exports / two export_ids**; an admin filtering by one `export_id` sees half the
pull. The `EXPIRED_CURSOR`-restart-mints-new-id case is documented (L333); this far more common case is not.
**Severity: Medium.** **Suggested resolution:** add: "`/answers` and `/history` are independent exports with
distinct `export_id`s; correlating a researcher's full pull of a run requires filtering by `report_run_id` +
`user_id`, not a single `export_id`" (and reflect this in the admin UI's `export_id` filter semantics).

**Decision:** **Adopted.** Added an Audit-logging bullet: `/answers` and `/history` are independent exports with
distinct `export_id`s (incompatible inner-cursor shapes), so a full pull correlates by `report_run_id` + `user_id`
(or the `remote_endpoint` search), not a single `export_id`.

---

#### RESOLVED: The "no follow-on story" justification is false — REPORT-77 (STORY 4, the Go CLI) exists; the reasoning rests on a wrong premise
**Verified:** REPORT-76 asserts "no follow-on story" in four places (L322, L362, L878, L1007) as the load-bearing
reason to pull the intent audit row + the admin filter UI into this story now. But STORY 1 and STORY 2 both name
**STORY 4 = REPORT-77 = the Go CLI** as a real upcoming story (`REPORT-74-…md:22,27-28`; `REPORT-75-…md:146,168,
204,210`). The correct premise is "no follow-on **server-side** story" (REPORT-77 is a Go CLI and won't build
Elixir audit UI) — the conclusion may still hold, but the stated premise is false.
**Severity: Medium** (scope-justification integrity). **Suggested resolution:** reword all four to "no follow-on
**server-side** story (REPORT-77 is the Go CLI, which won't build Elixir audit UI)."

**Decision:** **Adopted.** Reworded all four "no follow-on story" occurrences to "no follow-on **server-side**
story (REPORT-77 is the Go CLI)."

---

#### RESOLVED (low): three thin contract omissions worth one line each (cross-page ordering stability; no progress/total signal; v1↔Firestore shape coupling); plus one scope-boundary note (audit-log filter UI in a data-plane story)
**Verified:** (a) the endpoint iteration order **is** stable (frozen in the scratch, L116,L166) but is never
surfaced as a **consumer-facing** guarantee — a CLI author has no documented monotonic-progress contract to lean
on. (b) The only progress signal is loop-until-null; no total/page count exists (STORY-1 envelope is
`{items,next_page_token}` only, `report_json.ex:8-13`) — a legitimate choice, but state it as intentional so
STORY 4 doesn't file it as a gap. (c) Raw passthrough on a `/api/v1/` path couples the wire shape to Firestore's
internal doc shape (a future activity-player doc change silently changes v1) — accepted, but acknowledge the
coupling. (d) Scope note: the admin audit-log **filter UI** (LiveView + `list_entries_paginated/2` + `JSON_CONTAINS`
+ a11y, L356-389) is a read-side UI feature bundled into a bulk-read data-plane story; it **was** pre-deferred
here by STORY 1 (`REPORT-74-…md:284`), so it's planned, but a reviewer should confirm the team wants a UI feature
in this story vs a thin REPORT-76b.
**Severity: Low** (documentation/scope clarity). **Suggested resolution:** add the three one-line contract
statements to the envelope/Item-shapes sections and one explicit line accepting (or splitting off) the audit-UI
scope.

**Decision:** **Adopted (contract lines added); audit-UI scope accepted here.** Added: "stable iteration order +
monotonic progress" and "no total-count/progress signal in v1" to the Pagination envelope; "raw passthrough
couples v1 wire to Firestore doc shape (accepted)" to Item shapes. The audit-log filter UI **stays in this story**
(it was pre-deferred here by STORY 1 and there is no follow-on server-side story) rather than splitting a
REPORT-76b — accepted as an explicit scope decision.

---

#### CLOSED (verification notes, no change needed):
- **EXPIRED_CURSOR 410 body + CLI distinguishability:** sound — `render_error` merges `%{error: code, message}`
  so the 410 body carries `error: "EXPIRED_CURSOR"` (`error_helpers.ex:21-26`); the reverse `@codes_by_status`
  map has no 410 today (409=NOT_READY) so adding it is clean; `plug :force_json` is unconditional on
  `:api_authenticated` so errors stay JSON. (Low caveat: `code_for_status(410)` would mis-map a *raised* 410 to
  `SERVER_ERROR`, but EXPIRED_CURSOR is always explicitly rendered, never raised — no bite.)
- **Param/envelope consistency with STORY 1:** identical (`limit` in, `page_token` echoed, `{items,
  next_page_token}`, null-on-last) — `params.ex:6,22`, `report_json.ex:8-22`. No CLI-breaking mismatch.
- **Route shadowing:** clean — `/reports/:id` (2 segments) cannot shadow `/reports/:id/answers` (3), and the
  `match :*, "/*path"` fallback is in a separate scope below all real routes (`router.ex:55-71`).
- **Audit search SQL-injection:** the mandated `JSON_CONTAINS(endpoint_set, JSON_QUOTE(?))` is a bound-parameter
  Ecto `fragment`, not interpolation; current LiveView reads only `params["page"]`. **One-line spec add worth it:**
  state the value is bound via `fragment("… JSON_QUOTE(?)", ^remote_endpoint)`, never string-built (the codebase
  has no existing `fragment` precedent to copy, so an implementer could reach for interpolation).
- **Ownership gate precedes `LearnerData.fetch`:** the STORY-1 `with`-chain runs `get_api_report_run` first
  (`report_controller.ex:23-24`), so an owned-but-empty run and a not-owned run differ by **response body**, not
  just timing — no real distinguisher. Worth a half-sentence pinning "ownership gate precedes the fetch," not a
  finding.
- **getAll batch-get has no hard doc cap for this use:** `@google-cloud/firestore@4.15.1` `Firestore.getAll`
  enforces only a MIN-args check (no max); the 500-doc cap is a **transaction** limit and this read is
  non-transactional (emulator ran `getAll(750 refs)` → 750, 0 errors). "Chunk if large" with no number is
  acceptable; the real bound is the 10 MB response wall.

**Decision:** <!-- confirmatory; adopt the bound-parameter and ownership-ordering one-liners -->

---

## Self-Review — Round 5 (code- and execution-verified, 2026-07-14)

A fifth multi-role pass (Elixir/OTP, Firestore/Node, adversarial Security, API-Contract/Integration,
Database/Migration, QA/Test, WCAG Accessibility, Product/Scope). **Every finding below was verified against
the actual source before being written** (report-service Elixir + `functions/`, plus activity-player /
portal-report / rigse); the highest-risk items were **executed** — Req's vendored dep source, `parse_limit`
run in Elixir, the Firestore emulator (cursor/Timestamp probes), the dev MySQL (`JSON_CONTAINS`
case-sensitivity), qs/Express query-coercion, and the live audit-log `.heex` — not merely reasoned. The
first four rounds' resolutions were re-attacked and **hold**; these are **new gaps** those rounds did not
surface. Several are implementation-blocking (a straight-ahead build would hang, 500, or leave acceptance
tests unwritable), which is why they matter despite the spec's maturity.

### Elixir/OTP Engineer

#### RESOLVED: BLOCKING — the `Req` client's 15 s default `receive_timeout` silently defeats the ~300 s Node timeout the whole design rests on
**Verified:** `ReportService`'s existing calls — `Req.get(...)` at `report_service.ex:16-22` and `:42-48` —
set **no** `receive_timeout`, and Req 0.4.14 (`mix.lock`) documents a **15 000 ms** default
(`deps/req/lib/req.ex:327`). The spec raises the *Node/Cloud-Function* ceiling 60 → ~300 s in many places
(L522, L564-573, L627-633, L707-711) and sizes pages "within seconds of the raised ~300 s timeout," but says
only "Add a bulk-read call here" (L602-604) with no Elixir-side timeout override. A page the design *expects*
to take up to ~300 s Node-side trips a Req `:timeout` at 15 s → Elixir `SERVER_ERROR` → (per this story's own
rule) no audit row, no cursor advance → CLI retries the identical page → same 15 s failure. **No page that
legitimately exceeds 15 s can ever make progress** — the exact slow-page the 300 s headroom exists for.
**Severity: BLOCKING.**
**Suggested resolution:** the new bulk `Req.get` MUST set `receive_timeout:` above the Node ceiling (e.g.
`~310_000`); pin it in the "Reuse of `ReportService`" bullet (L602-604). Also sanity-check the ALB/any proxy
idle timeout in front of the Node function against ~300 s (out of Elixir scope, deploy-review note).

**Decision:** **Adopted** — the "Suggested resolution" above was folded verbatim into the requirements body (see the matching section).

---

#### RESOLVED: MEDIUM — "sweep on `init`" contradicts the `StatsServer` pattern it cites and blocks supervision-tree boot on a slow DB
**Verified:** the spec says the sweep GenServer does a "sweep on `init` (boot)" (L510-512, L714, L863) and
cites `StatsServer` as the pattern to mirror (L616, L510) — but `StatsServer.init/1` **deliberately does no
DB work**, returning `{:ok, state, {:continue, :query_and_schedule_next}}` with the comment "return
immediately and handle the rest of the (potentially long running) startup in the handle_continue handler"
(`stats_server.ex:31-51`); the DB query runs in `handle_continue/2`. Children start `:one_for_one`
(`application.ex:14-25`). A synchronous `DELETE FROM export_scratch …` inside `init/1` runs on the
supervisor's start path; if the DB is momentarily slow at boot (post-deploy / RDS failover) the child's start
blocks and can restart-loop — for pure storage reclaim that "correctness never depends on" (L513-515).
**Severity: MEDIUM.**
**Suggested resolution:** reword L510-512/L714 to run the boot sweep via `handle_continue` (or
`Process.send_after(self(), :sweep, 0)`) **after** `init` returns, mirroring `StatsServer`'s deferral.

**Decision:** **Adopted** — the "Suggested resolution" above was folded verbatim into the requirements body (see the matching section).

---

#### RESOLVED: LOW/MEDIUM — page-1 has no defined atomicity between "create scratch row" and "write the intent audit row"
**Verified:** the page-1 flow (derive → cache scratch → Node read → intent row → access row) pins *fail-closed
audit ordering* (L408-411) but never pins the scratch-create step relative to the audit writes, and uses no
`Ecto.Multi`/`Repo.transaction` (`AuditLog.create_entry` is a bare `Repo.insert`, `audit_log.ex:45-48`). If
the scratch is inserted before a failing intent-audit write, the request 500s (correct) but the scratch
persists → a page-1 retry (null token) re-derives and mints a **new** `export_id` (export-id churn +
TTL-swept orphan). If the intent row is written but the access row / Node read then fails, an intent row
exists for an export whose page-1 data never left the server — muddying the "scoped-to vs actually-exported"
distinction the two-row design (L392-393) exists to keep clean. Neither is corruption or a leak (orphans are
swept; intent-only over-reports, the safe direction).
**Severity: LOW/MEDIUM.**
**Suggested resolution:** pin the page-1 ordering; simplest correct is an `Ecto.Multi` inserting scratch +
intent row atomically (both or neither), then the access row, then return. If a transaction is judged
unnecessary, document that a page-1 partial failure may leave a swept orphan scratch and churn `export_id`.

**Decision:** **Adopted** — the "Suggested resolution" above was folded verbatim into the requirements body (see the matching section).

---

### API-Contract / Integration Engineer

#### RESOLVED: HIGH — `limit` clamp collision: STORY 1's `@max_limit 200` / `@default_limit 50` makes "~500 cap, tunable via `limit`, clamped like STORY 1" unreachable and self-contradictory
**Verified (executed):** STORY 1's clamp is the single source `params.ex:2-4,13` — `@default_limit 50`,
`@max_limit 200`, `min(n, @max_limit)`; reproducing `parse_limit`, `limit=500 → 200`, `limit=1000 → 200`,
omitted → 50. But the spec pins the page cap at "~500 returned items/page" (L517) and "tunable via `limit`,
clamped like STORY 1" (L521, L860). So if STORY 3 reuses `parse_limit`: (i) default page size is **50**, not
~500 — every cost-sizing figure (the "~2× cap" formula, the "few MB under 10 MB" sizing, L516-522) is
computed against a 500 the code never produces by default; (ii) `limit` can only *lower* below 200 and can
**never reach 500**, so "~500 cap tunable via `limit`" is unreachable. Round 4's CLOSED note (L1820-1821)
checked param *plumbing* parity but never the *clamp values* against the ~500 cap. (Product/Scope
independently flagged that the clamp ceiling is never pinned to a number — "clamped like STORY 1" is a
dangling reference the CLI author and test-writer both need resolved.)
**Severity: HIGH** (implementation-blocking contradiction + STORY-4 CLI handoff).
**Suggested resolution:** pin one — (a) STORY 3 adds its **own** limit parser (`@default_limit ~500`,
`@max_limit ≥ 500`) and the spec drops "clamped like STORY 1" for explicit STORY-3 bounds; or (b) raise
`@max_limit`/`@default_limit` in shared `params.ex` (must confirm no perturbation to STORY 1's `/reports`
page size + its test at `report_controller_test.exs:115`). Either way state the clamp max as a **number** and
whether `limit` **raises or only lowers** the ~500 cap (STORY 4 sizes its request loop against this).

**Decision:** **Adopted** — the "Suggested resolution" above was folded verbatim into the requirements body (see the matching section).

---

#### RESOLVED: MEDIUM — the internal Elixir→Node bulk payload has no concrete wire contract (method + shape), and the endpoint slice won't fit the existing GET-query idiom
**Verified:** today `ReportService` calls functions as **GET with query params** (`report_service.ex:15-23`,
Node reads `req.query`, routes are `api.get(...)` `index.ts:56-57`); only writes are POST. STORY 3's internal
contract is prose only — Elixir "passes that slice + source per endpoint + the inner cursor" (L124-125), Node
"returns `items` + the endpoint index it stopped at + inner cursor + exhausted flag" (L203-205) — with no
request/response schema and no HTTP method. The bulk request must carry an **ordered endpoint slice** up to
the full learner set (scratch sized "~1.3 MB worst case for 10k learners," L486), which cannot ride a GET
query string, so the bulk call almost certainly must become a **POST with a JSON body** — a departure from
every existing `ReportService` call and Node read route the spec never states. Round 1's tier-split pinned
*which tier owns what state*, not the *bytes between them*; two engineers building Elixir and Node
independently can diverge on method, key names, and the `success:true` key `res.success` mutates in
(`response-methods.ts:14`).
**Severity: MEDIUM** (integration-mismatch; blocks parallel Elixir/Node build).
**Suggested resolution:** add a short concrete internal-contract block — HTTP method (recommend **POST** with
a JSON body; note it's the first read route needing a body), request keys (e.g. `{source_endpoints:
[{remote_endpoint, source, lti_tuple?}], inner_cursor, limit, collection}`), response keys (e.g. `{items,
stop_endpoint_index, inner_cursor, endpoint_exhausted, success}`), so the tiers build independently.

**Decision:** **Adopted** — the "Suggested resolution" above was folded verbatim into the requirements body (see the matching section).

---

#### RESOLVED: LOW-MEDIUM — no `Cache-Control: no-store` on the bulk endpoints, which now return sensitive student data directly in the response body
**Verified:** the server sets no cache headers on any API response (grep for `cache-control`/`no-store`
across `server/lib/` is empty; the only `put_resp_header` is an unrelated codap-iframe CSP, `router.ex:134`).
Harmless in STORY 1 — `/download` returns a short-lived presigned URL in a tiny body, not the data
(`report_controller.ex:53-58`). STORY 3 returns raw per-answer state + full history **directly in the body**
(L333-352), embedding pseudonymous identity fields and `remote_endpoint`s (which embed credential-grade
`secure_key`s). A researcher CLI pulling through any intermediary proxy/cache could see this body cached.
**Severity: LOW-MEDIUM** (defense-in-depth; new to STORY 3).
**Suggested resolution:** add `Cache-Control: no-store` (consider `Pragma: no-cache`) to the two bulk
responses (a small plug on the bulk routes, or a `put_resp_header` in the controller) and state it as a
requirement, since STORY 1 set no precedent and the data-in-body exposure is new.

**Decision:** **Adopted** — the "Suggested resolution" above was folded verbatim into the requirements body (see the matching section).

---

### Firestore/Node Engineer

#### RESOLVED: MEDIUM — Timestamp cursor reconstruction has two unhandled hazards: the sanctioned "raw ISO" cursor form re-loses µs, and the strict constructor throws a 500 (not `BAD_REQUEST`) on a malformed inner cursor
**Verified (executed, `firebase-admin@10.0.0`):** (a) L171 still sanctions the cursor carrying `created_at`
as "`{seconds, nanoseconds}` … **or the raw ISO-with-sub-ms**," but reconstructing from ISO via
`Timestamp.fromDate(new Date(iso))` truncates to **milliseconds** (`.123456Z` → `nanoseconds:123000000`),
reintroducing the sub-ms skip the cursor contract forbids — only the `{seconds, nanoseconds}` form is safe.
(b) `new admin.firestore.Timestamp(s, n)` is strict — it **throws** on string args and on `nanoseconds ∉ [0,
999999999]`. Round 4 placed inner-cursor validation in **Elixir** (`BAD_REQUEST`, L1513-1516) but the
Timestamp reconstruction happens in **Node** (L171), and the tier split treats the inner cursor as opaque
bytes Elixir forwards — a base64/JSON-valid cursor with `nanoseconds:1000000000` or stringified numbers
passes a shallow Elixir "decodable?" check yet throws at Node's `new Timestamp()` → an uncaught **500**, not
the promised `BAD_REQUEST` (`get-answer.ts:37-40` surfaces throws as a generic error).
**Severity: MEDIUM.**
**Suggested resolution:** (a) drop "or the raw ISO-with-sub-ms" from L171 — pin the cursor to full `{seconds,
nanoseconds}` **integers** only (ISO stays fine for the *wire* `created_at`, never the cursor); (b) require
Node to reconstruct with integer args and **guard** it (validate `seconds`/`nanoseconds` are integers,
`nanoseconds ∈ [0, 999999999]`), or have Elixir decode-and-validate the inner cursor's numeric fields before
forwarding; add an acceptance case: out-of-range/stringified Timestamp fields → `BAD_REQUEST`, not 500.

**Decision:** **Adopted** — the "Suggested resolution" above was folded verbatim into the requirements body (see the matching section).

---

### Security Engineer (adversarial)

#### RESOLVED: MEDIUM — the header-only bearer guard's presence check is under-specified and will likely be coerced past by `?bearer[0]=<TOKEN>`, landing the token in access logs
**Verified (executed qs/Express probe):** the shared middleware guards with `typeof req.query.bearer ===
"string"` (`bearer-token-auth.ts:23`); `?bearer=a&bearer=b` and `?bearer[0]=a` parse to an **array**,
`?bearer[x]=a` to an **object** (`typeof "object"`). The spec's guard (L297, L1305-1324) says reject "if
`req.query.bearer` … is present" but never pins that this must be a **key-existence** check covering
array/object forms. An implementer copying the adjacent `typeof === "string"` idiom would let
`?bearer[0]=<TOKEN>` slip past the guard. Not an auth *bypass* (the array form doesn't authenticate through
the shared middleware either → falls to header), but the token still lands in the URL/access log — defeating
the guard's *only* purpose (log-hygiene, L296). Round 4's L1671 confirmed the *body* branch matters but not
this query type-coercion evasion.
**Severity: MEDIUM.**
**Suggested resolution:** pin that the guard rejects when the `bearer` key exists in `req.query`/`req.body`
**in any form** (`"bearer" in req.query || "bearer" in req.body`, or a truthiness check — NOT `typeof ===
"string"`), and extend the "Header-only bearer" acceptance scenario to include `?bearer[0]=` (array) and
`?bearer[x]=` (object) forms, not just scalar `?bearer=`.

**Decision:** **Adopted** — the "Suggested resolution" above was folded verbatim into the requirements body (see the matching section).

---

#### RESOLVED: LOW — scratch rows aren't bound to their route, so a `/history` token loads on `/answers` (and vice-versa); safe only if the wrong-shape inner cursor is strictly rejected (not confidentiality)
**Verified:** the ownership guard is `WHERE scratch_id AND user_id AND report_run_id AND expires_at` (L188,
L198) — **no route/`data_type` predicate**. The spec asserts `/answers` and `/history` "cannot share one
scratch" **solely** because their inner-cursor shapes differ (`{docId}` vs `{created_at, docId}`, L399-400),
relying on shape rejection — but a `{created_at, docId}` map fed to the answers path is valid JSON with an
extra key, not obviously "malformed," so whether it's rejected as `BAD_REQUEST` (L191) depends on the answers
decoder being **strict** about unexpected keys. **Not a leak** (the scratch `endpoint_set` is identical
regardless of which route derived it, same user/run → same authorized endpoints); purely "clean 400 vs
500/mis-serve."
**Severity: LOW.**
**Suggested resolution:** either add a `data_type`/route column to the scratch row and the ownership guard
(cleanest — cross-route replay → 404), or explicitly require the answers/history inner-cursor decoders to
reject a well-formed-but-wrong-shape cursor as `BAD_REQUEST`; add a cross-route-replay acceptance scenario.

**Decision:** **Adopted** — the "Suggested resolution" above was folded verbatim into the requirements body (see the matching section).

---

#### CLOSED (verification note): the raw doc passthrough also carries `collaborators_data_url` + `collaboration_owner_id` — non-credential, but the Item-shapes enumeration only names `remote_endpoint`/`attachments`
**Verified:** authenticated answer docs can carry `collaborators_data_url` + `collaboration_owner_id`
(`firebase-db.ts:565-571`); in rigse the URL is a plain REST endpoint `…/collaborations/{id}/collaborators_data`
gated by a peer-bearer Pundit policy with **no token in the URL** (`create_collaboration.rb:59`,
`collaboration_policy.rb`) — **not** credential-grade (unlike `remote_endpoint`). No name/email/token in the
returned docs (matches the pseudonymity claim). Worth one optional line in Item-shapes acknowledging these
also pass through raw (non-credential).
**Decision:** <!-- confirmatory; optional one-line note in Item shapes -->

---

### QA / Test Engineer

#### RESOLVED: BLOCKING (testability) — no mock seam exists for the Node bulk read; STORY 1's `athena_db` stub pattern does not extend to it
**Verified:** `ReportService` builds its client inline (`Req.new()` + config at call time) — **no injected
client, behaviour, or module attribute** to swap. The project has **no Mox and no Bypass** (`mix.exs` deps;
grep of `lib/`+`test/` empty). STORY 1's controller test stubs the *Athena* dep only because it's looked up
via `Application.get_env(:report_server, :athena_db)` (`report_controller_test.exs:70`,
`test/support/athena_db_stub.ex`); `ReportService` has **no** equivalent config indirection, so the STORY-1
idiom can't be reused as-is. Consequence: "Node read failure → SERVER_ERROR", "idempotent page_token",
"empty mid-export page", "big-class full-history" can't be asserted at the controller without new plumbing.
**Severity: BLOCKING (testability).**
**Suggested resolution:** add an implementation task — route the bulk Node call through a swappable seam
mirroring `athena_db` (e.g. `Application.get_env(:report_server, :report_service_client, ReportService)` +
`test/support/report_service_stub.ex`), and list the stub as a test-strategy deliverable.

**Decision:** **Adopted** — the "Suggested resolution" above was folded verbatim into the requirements body (see the matching section).

---

#### RESOLVED: BLOCKING (testability) — `LearnerData.fetch` hits a real remote portal MySQL with no sandbox or stub seam, so live-derivation/empty-export/ownership scenarios can't run in CI
**Verified:** `LearnerData.fetch` and `get_allowed_project_ids` call `PortalDbs.query(user.portal_server,
sql)` (`learner_data.ex:126`, `portal_dbs.ex:150`), which opens a **live MyXQL pool** to a remote server
keyed off a `"#{server}_DB"` env var set only in real deploys (`portal_dbs.ex:15,192-202`). The portal is
**not** an Ecto repo, so `Ecto.Adapters.SQL.Sandbox` (which `data_case.ex:39` starts for the *local* Repo
only) can't sandbox it. No test drives `fetch` through a DB — portal report tests are pure SQL-string
builders, and the one download-audit test explicitly bypasses the portal DB with a stubbed `get_query`
(`report_run_download_audit_test.exs:93-113`, comment "so the test does not depend on a reachable portal
DB"). The headline mechanic — derive the learner set live via `fetch(..., allow_empty: true)` — is exactly
the path with no seam; the **empty-export** scenario depends on `fetch` returning a controlled `{:ok, []}`.
The test-strategy section is thorough on the Node/emulator side and silent on the Elixir side.
**Severity: BLOCKING (testability).**
**Suggested resolution:** add a swappable seam for the learner-derivation call (config-lookup like
`athena_db`, or an injectable module) + a `LearnerDataStub`; note the portal DB is un-sandboxable and this is
the only seam option, else the Elixir acceptance suite needs a live staging portal DB not wired into CI.

**Decision:** **Adopted** — the "Suggested resolution" above was folded verbatim into the requirements body (see the matching section).

---

#### RESOLVED: MEDIUM — no Node HTTP-route test harness exists (no `supertest`), so the "Header-only bearer" and "Node read failure" scenarios have no assertion path
**Verified:** `functions/` has **no `supertest`** and no express-app test harness (`package.json` devDeps:
`jest ^24`, `ts-jest ^24`, `firebase-functions-test ^0.3.3`; no test imports the app or mocks
firebase-admin). There is no existing test for `bearer-token-auth.ts` or `get-answer.ts` to copy. The
header-only guard is a Node HTTP-layer behavior the emulator query tests can't exercise.
**Severity: MEDIUM.**
**Suggested resolution:** state the mechanism — the header-only guard is unit-tested by calling the guard
middleware with mock `req` objects (`query.bearer`/`body.bearer`/header set), needing no supertest (cheapest
path); "Node read failure" is induced in an emulator test via an injected/stubbed Firestore accessor or an
unreachable emulator. Pin each so they aren't found un-testable during implementation.

**Decision:** **Adopted** — the "Suggested resolution" above was folded verbatim into the requirements body (see the matching section).

---

#### RESOLVED: LOW-MEDIUM — "Big-class full-history" sits in the acceptance list as if automatable, but it is a manual/measured milestone
**Verified:** the acceptance list includes "Big-class full-history … each within the raised function timeout
and under the 10 MB response cap (the validation-milestone target)" (L783) alongside genuinely
unit/emulator-testable scenarios, but the Validation section (L552) describes it as measured **on real
data**; "completes within the function timeout" has no assertion an emulator/unit test can meaningfully make
(no billing, cold starts, or prod latency).
**Severity: LOW-MEDIUM.**
**Suggested resolution:** annotate this item as a **manual/measured milestone** (like "Self-start N/A"),
splitting what *is* automatable (page-count > 1, cursor round-trip, per-page item count ≤ cap, response bytes
< 10 MB on seeded data) from what's measured on real data (latency, timeout headroom, Firestore read cost).

**Decision:** **Adopted** — the "Suggested resolution" above was folded verbatim into the requirements body (see the matching section).

---

#### RESOLVED: LOW — the seed-fidelity write shape is copyable but the spec under-enumerates the full LTI answer-doc field set
**Verified:** activity-player is local and the spec's line refs are accurate (`createOrUpdateAnswer`
`firebase-db.ts:476`, shallow-spread `:531`, `serverTimestamp` `:604`), but the seed instruction (L658) lists
only a subset (`platform_id`/`resource_link_id`/`platform_user_id`/`remote_endpoint` + double-encoded
`report_state`), while the real `createAnswerDoc` (`firebase-db.ts:542-590`) also writes `created`,
`source_key`, `resource_url`, `tool_id`, `context_id`, `run_key`, `interactive_state_history_id`, and the
base metadata spread. A fixture missing `source_key`/`context_id` passes a naive test but exercises less.
**Severity: LOW** (clarity).
**Suggested resolution:** instruct authors to copy the exact field set from `createAnswerDoc`
(`firebase-db.ts:542`) and `createInteractiveStateHistoryEntry` (`:596`) verbatim rather than hand-pick.

**Decision:** **Adopted** — the "Suggested resolution" above was folded verbatim into the requirements body (see the matching section).

---

### WCAG Accessibility Expert

#### RESOLVED: HIGH (a11y) — the filtered/paged table re-renders via `push_patch` with no `aria-live` region, so screen-reader users get no announcement of the result
**Verified:** `AuditLogLive.Index` handles filter/page via `handle_params` and re-assigns `@entries`
(`index.ex:21-30`); the template swaps `<tbody>` with **no live region** (`index.html.heex:5-36`; the only
`role="alert"` is the flash, `core_components.ex:116`). A researcher submitting the export_id/remote_endpoint
filter gets no announcement that results changed or how many matched. The current Accessibility bullet
(labeled form + submit-on-enter) doesn't cover the async-result announcement.
**Severity: HIGH (a11y).**
**Suggested resolution:** wrap a result summary in `aria-live="polite"`/`role="status"` (e.g. "Showing N
events…") updated on every `handle_params`, so filter and pager patches are both announced.

**Decision:** **Adopted** — the "Suggested resolution" above was folded verbatim into the requirements body (see the matching section).

---

#### RESOLVED: HIGH (a11y) — the empty-state message will lie to admins when a filter matches nothing
**Verified:** `index.html.heex:37` renders one hardcoded branch for `length(@entries) == 0`: "No data access
events have been recorded yet." Once filters exist, the same branch fires when a filter matches nothing —
telling an admin nothing was *ever* recorded (factually wrong), with no distinct accessible "no results for
this filter" message. Spec is silent.
**Severity: HIGH (a11y + correctness of the message).**
**Suggested resolution:** branch the empty state on whether filters are active and render a filter-specific
"No events match export id X / student Y", inside the `aria-live` region above so it is announced.

**Decision:** **Adopted** — the "Suggested resolution" above was folded verbatim into the requirements body (see the matching section).

---

#### RESOLVED: MEDIUM — the "labeled form" requirement is under-specified: focus management, a visible submit control, the label mechanism, input typing, and a table name are all unpinned
**Verified against the real template + components:** (1) filter submit + pager use `push_patch`
(`index.ex:21-30`, `.pager` `patch=` links `custom_components.ex:365-379`) with no `JS.focus`/`push_focus` —
focus can land on a stale control or `<body>` after a patch. (2) "submit-on-enter" alone leaves no visible,
focusable submit control (WCAG 3.2.2/2.1.1); nothing mandates a rendered `<button type="submit">`. (3) The
app's `.input` (`core_components.ex:386-399`) *does* wire `<.label for>`+`id`, so a compliant form is
achievable **only if** the implementer routes through it — a hand-rolled `<input placeholder=…>` would pass
the spec's literal "labeled form" wording while failing 1.3.1/4.1.2. (4) inputs need a pinned `type="text"`
and a note that `remote_endpoint`/`export_id` are long opaque values (don't truncate the accessible name).
(5) the `<table>` (`index.html.heex:7`) has no `<caption>`/`aria-label`; with filters its meaning becomes
"filtered results" with no programmatic name. (Note: the bullet's `aria-current`/`nav aria-label` are already
provided by STORY-1's `.pager` at `custom_components.ex:364,373` — the bullet slightly over-claims them as
new work; `scope="col"` genuinely is missing at `index.html.heex:10-13` and stays needed.)
**Severity: MEDIUM (a11y).**
**Suggested resolution:** tighten the Accessibility bullet to require: focus moved to the results
region/heading (a `tabindex="-1"` container via `push_focus`) after submit; a visible labeled `<button
type="submit">`; inputs built with `<.label for>`+`id` (placeholders are not labels); `type="text"`; and a
`<caption class="sr-only">` naming the table. Correct the redundant `aria-current`/`nav`-already-present note.

**Decision:** **Adopted** — the "Suggested resolution" above was folded verbatim into the requirements body (see the matching section).

---

### Product / Scope Engineer

#### RESOLVED: MEDIUM — rate limiting / read quota is never stated out-of-scope, though this is the first endpoint that lets an authorized caller drive unbounded live Firestore reads
**Verified:** REPORT-74 explicitly deferred rate limiting ("noted as a future concern, not v1"; "no rate
limiting exists anywhere today"), but REPORT-76 has **zero** rate-limit/quota/abuse mentions in Requirements,
Out-of-Scope, or Technical Notes. STORY 1 issued presigned URLs (cost bounded by existing artifacts); STORY 3
is the first surface where an authorized researcher loops `/history` across many runs, billing real Firestore
reads (~2× cap/page) against prod with no per-user/per-token ceiling — the spec itself notes the "all of many
learners' answers + full history" blast radius (L272-273) and the `teacher-actions`/under-constrained-run
breadth (L134-137). Silently inheriting STORY 1's deferral leaves a reviewer unable to sign off on "is
unbounded researcher-driven read cost acceptable for v1?"
**Severity: MEDIUM** (scope-completeness / operational).
**Suggested resolution:** add one Out-of-Scope line carrying the deferral forward *with the new context* —
per-user/per-token rate limiting/quotas deferred (as in STORY 1), accepted for v1 because callers are
authenticated report-access-gated researchers and the per-page ~500 cap bounds a single call (not a loop);
Firestore read-cost exposure to a looping caller is an accepted v1 risk, revisited if abuse appears.

**Decision:** **Adopted** — the "Suggested resolution" above was folded verbatim into the requirements body (see the matching section).

---

#### RESOLVED: LOW — two consecutive stories both plan to modify `Api.AuthPlug`'s assigns and neither coordinates the touch
**Verified:** REPORT-75 (146-147, 168-170) and REPORT-77's ticket both record that the STORY-4 `cc-data
logout` endpoint needs `AuthPlug` to also assign the resolved `api_token` (it assigns only `:current_user`
today). REPORT-76 is the story between them that adds two routes under `:api_authenticated` and reuses
`AuthPlug` (L36-37, L118) — a natural place to at least note the pending assign change so a STORY-3
implementer editing `AuthPlug` is aware. Not a defect (logout is correctly STORY 4); a coordination gap.
**Severity: LOW.**
**Suggested resolution:** one line in Out-of-Scope or Elixir integration points — the `AuthPlug` `api_token`
assign is STORY 4 (REPORT-77); STORY 3 doesn't add it, but an implementer touching `AuthPlug` for the new
routes should know STORY 4 will extend its assigns.

**Decision:** **Adopted** — the "Suggested resolution" above was folded verbatim into the requirements body (see the matching section).

---

#### RESOLVED: LOW — the EXPIRED_CURSOR "re-download from scratch" cost is complete on the wire but never stated as an accepted researcher-facing UX tolerance
**Verified:** the server contract is thorough (410 → CLI discards partial, re-derives from null — L220-223,
L759-760), and the sliding TTL ensures an *actively-progressing* export never expires (L493-495) — so the
cliff only hits idle/abandoned resumes. But the *product* consequence — a researcher idle >1 h must
re-download the entire export — is stated only as CLI mechanics, never framed as an accepted UX tolerance
with the 1-hour number surfaced. Server-side this is the right call (partial-resume-after-TTL would
reintroduce the staleness derive-once avoids).
**Severity: LOW.**
**Suggested resolution:** one line on the EXPIRED_CURSOR requirement / Out-of-Scope — an export idle beyond
the 1 h sliding TTL forces a full re-download (partial discarded); actively-progressing exports never expire;
finer-grained resume-after-expiry is out of scope for v1.

**Decision:** **Adopted** — the "Suggested resolution" above was folded verbatim into the requirements body (see the matching section).

---

### Database / Migration Engineer

#### RESOLVED: LOW — the `JSON_CONTAINS` endpoint search is case-sensitive (correct, and required for `secure_key` matching) but the spec never states it, leaving it vulnerable to a collation-blind "optimization"
**Verified (executed on dev MySQL 8.0.39):** Ecto tables are `utf8mb4_0900_ai_ci` (case-insensitive), but
`JSON_CONTAINS(JSON_ARRAY('…/AbCdEf'), JSON_QUOTE('…/abcdef'))` → `0` while the exact-case match → `1` (JSON
string comparison is binary, independent of column collation). Since `secure_key` is case-sensitive, the
mandated `JSON_CONTAINS(endpoint_set, JSON_QUOTE(?))` is correct — but the spec's own "possible later
generated-column/`LIKE` index" optimization (L456-458) would collate case-*insensitively* and could match the
wrong learner. Round 3 verified `JSON_CONTAINS` returns 1/0/NULL but not the case dimension. (Also: the
measured worst-case scratch row is ~1.9 MB for 10k endpoints, not the spec's ~1.3 MB — still ~34× under the
64 MiB `max_allowed_packet`, changes no decision.)
**Severity: LOW** (doc/robustness).
**Suggested resolution:** add a sentence to the "Storage shape"/perf-caveat bullet — the `JSON_CONTAINS`
match is intentionally case-sensitive (JSON binary comparison, independent of the utf8mb4_0900_ai_ci column
collation), required for exact `secure_key` matching; any future generated-column/`LIKE` index must preserve
case-sensitive (`utf8mb4_bin`/`_cs`) semantics. Optionally correct the worst-case row size to ~1.9 MB.

**Decision:** **Adopted** — the "Suggested resolution" above was folded verbatim into the requirements body (see the matching section).

---

### Re-attacked and confirmed SOUND (no change)

Prior-round resolutions re-verified this round and found to hold: the Round-4 IDOR/cursor-forgery fix
(guard ties `report_run_id` to the **path** id and `user_id` to `conn.assigns.current_user.id`; a forged
token 404s); the timing/oracle ordering (`parse_id` → `get_api_report_run` first; owned-empty vs not-owned
differ by body, not timing); the audit `endpoint_set` heex render (auto-escaped, no `raw/1`); the
`JSON_CONTAINS` bound-param injection safety (`") OR 1=1 --` matches nothing); admin authz on mount +
handle_params; the `LearnerData.fetch allow_empty` blast radius (4 callers, all unaffected); the
`DataAccessLogEntry` changeset `validate_required` set (intent row's null cursor/report_slug pass); the
`export_scratch` `:utc_datetime` / unique-index-on-scratch_id design (**but the `{:array,:map}` field type was
later corrected to the `EctoJsonArray` custom type — F-ext3-1: a bare `{:array,_}` does not load under MyXQL**);
the 410 plumbing
(single auto-derived reverse map); STORY-1 route/`force_json`/fallback registration; and the STORY-4
(REPORT-77) handoff completeness (envelope, cursor opacity, dedup keys + `history_id` tiebreak,
EXPIRED_CURSOR restart, empty-mid-export rule, double-decode `string|object|null` caveat). The emulator
harness (`firebase emulators:exec --only firestore 'jest'`) still runs clean.

---

## External Review (Round 1) — 2026-07-14

An external multi-role review (Senior Engineer, QA, API-Contract, Product/Scope) surfaced four findings.
**Each was re-verified against the actual source before adoption** (per the standing review mandate); all
four were confirmed true — two of them (#3, #4) caught genuine under-specification in the Round-5 POST
internal-contract. All four are adopted and folded into the requirements body.

#### RESOLVED: HIGH — nil `report_filter` is a live state that would crash the derivation path
**Verified:** `report_runs.report_filter` is a nullable `:map`
(`priv/repo/migrations/20241120113001_create_report_runs.exs:7`, no `null: false`); nil is supported and
serialized as the empty filter (`report_json.ex` `report_filter_json(nil)`, with the test "serializes a nil
report_filter as the empty-filter object", `report_controller_test.exs:174`); and `LearnerData.fetch`'s
first clause pattern-matches `%ReportFilter{...}` (`learner_data.ex:24`), so `fetch(nil, …)` raises
`FunctionClauseError` → 500. **Decision:** normalize `report_run.report_filter || %ReportFilter{}` in the
bulk controller before derivation (mirroring `report_filter_json/1`); added the "Nil-`report_filter` run"
acceptance scenario. Folded into the Live-endpoint-derivation bullet.

#### RESOLVED: HIGH — source derivation dropped persisted `answersSourceKey` overrides; the spec's "not persisted anywhere" was false
**Verified:** the report's own SQL derives the source key as
`COALESCE(url_extract_parameter(runnable_url, 'answersSourceKey'), url_extract_host(runnable_url))` then the
offline remap (`shared_queries.ex:431-436`) — so `answersSourceKey` **is** persisted (in `runnable_url`) and
the report reads it; hostname-only derivation would query the wrong `source` and silently miss those runs.
**Decision:** STORY 3 matches the report's full derivation (`answersSourceKey` param → hostname → offline
remap); corrected the Background Spike-B1 note (the spike sampled only hostname-branch runs), the
History-mechanic source note, and rewrote the Out-of-Scope bullet — the override is now handled, and the
accurately-scoped residual is only an answer written under a stored `source_key` differing from
`runnable_url` (recoverable solely via the materialized answers table, not a live read). Added the
"`answersSourceKey`-override run" acceptance scenario.

#### RESOLVED: MEDIUM — the Node response contract had no channel to feed the required LTI-tuple scratch cache
**Verified:** the design caches `{remote_endpoint, source, lti_tuple?}` in scratch on first touch (Round-1
Performance resolution), and Node derives the tuple (the `answers … limit 1` read), but the Round-5 pinned
response `{items, stop_endpoint_index, inner_cursor, endpoint_exhausted}` returned no tuples — so Elixir had
nothing to persist and the cache could never populate. **Decision:** added `touched_endpoints:
[{remote_endpoint, lti_tuple}]` to the Node response (freshly-derived tuples only); Elixir persists them
into scratch before minting the next cursor. Folded into the internal wire contract + the tier-split bullet.

#### RESOLVED: MEDIUM — `stop_endpoint_index` was ambiguous (relative to the slice vs. absolute in the scratch set)
**Verified:** the request sends Node an endpoint slice "from the current index onward" with no absolute base,
so Node can only report a slice-relative position; the field name implied absolute, and a mismatch would
rewind/skip the cursor (duplicate pages, skipped learners, or a loop). **Decision:** renamed the response
field to **`stop_endpoint_offset`** (explicitly slice-relative) and pinned that Elixir computes
`next_absolute_index = current_index + offset`; Node stays slice-local, Elixir owns the absolute index
(consistent with the tier split). Folded into the internal wire contract + the tier-split bullet.

---

## External Review (Round 2) — 2026-07-14

A second external multi-role review (Senior, QA, API-Contract, Product/Scope) surfaced four more findings.
**Each was re-verified against the actual source before adoption**; all four confirmed true. Findings 1 and
3 again tightened the internal contract / scratch model; Finding 2 is the most consequential (a 500 where
the spec guaranteed an empty-200). All four adopted and folded into the body.

#### RESOLVED: MEDIUM — no endpoint/learner cap; the empty-mid-export page was unimplementable
**Verified:** the only pinned cap was "~500 **returned items**/page" (Max-page-size bullet); "N learners"
was mentioned (Bounded-work bullet) but never a real cap, and the empty-mid-export acceptance case relied on
an undefined "endpoint budget." A page landing on answers-but-no-history learners returns 0 items, never
trips the item cap, so Node would scan the whole remaining slice. **Decision:** added `endpoint_limit`
(learners-walked cap) to the Node request; a page returns on **either** the item `limit` **or**
`endpoint_limit`; the empty-mid-export page is the endpoint-cap-with-zero-items case. Folded into the
internal contract, the bounded-work + page-cap bullets, and the empty-mid-export acceptance scenario.

#### RESOLVED: HIGH — `:none`/`[]` permission set produced invalid `IN ()` SQL, not the promised empty-200
**Verified:** `apply_allowed_project_ids_filter` builds `project_id IN #{list_to_in(allowed)}` for every
non-`:all` value (`report_utils.ex:106-123`); `list_to_in([]) → "()"` → invalid MySQL `IN ()` (→ 500) and
`list_to_in(:none)` raises on `Enum.map` of an atom. A role-flagged researcher with zero project rows
legitimately gets `[]` (`portal_dbs.ex:150`), so the spec's empty-200 promise (No-FORBIDDEN bullet + Empty-
export scenario) would actually 500. The Round-4 `allow_empty` fix is for empty *rows*, not the empty
*permission set* (which fails earlier at SQL build). **Decision:** the bulk path checks
`get_allowed_project_ids(caller)` up front and short-circuits `:none`/`[]` → `{:ok, []}` (200 empty) before
`LearnerData.fetch`. Folded into the Live-derivation bullet, the No-FORBIDDEN bullet, and the Empty-export
scenario (two distinct paths now asserted).

#### RESOLVED: MEDIUM — cross-route replay: inner-cursor shape rejection is insufficient for a `null` cursor
**Verified:** the Round-5/External-1 fix relied on inner-cursor *shape* rejection (offering `data_type`
binding as optional), but at an endpoint boundary the next token legitimately has `inner_cursor: null` — no
answers-vs-history shape to reject — so a null-cursor `/history` token replays cleanly on `/answers`. Same
user/run → no confidentiality leak, but it feeds answers items into the CLI's history export (data-integrity
corruption for STORY 4). **Decision:** made the scratch `data_type` column + guard predicate (`AND data_type
== ^route`) **mandatory** (cross-route replay → 404, including the null-cursor case); shape validation kept
as defense-in-depth. Folded into the cross-route bullet, the scratch columns, the guard predicates, and the
cross-route acceptance scenario.

#### RESOLVED: LOW — stale self-review text contradicted the corrected public trust boundary
**Verified:** the early Round-2 Security item still said "function never client-reachable" / "must never be
reachable by the CLI or any client," contradicting the accurate body (public gen1 `https.onRequest`, static-
bearer-gated) and the later Round-2 correction. **Decision:** annotated the early item with a
⚠️ SUPERSEDED pointer to the correction + accurate body and struck the inaccurate phrase (history preserved,
not rewritten).

---

## External Review (Round 3) — 2026-07-14

A third external review. **Each finding re-verified against source before adoption**; all four confirmed —
Findings 1, 3, 4 again in the cursor/scratch/tier-split state machine (the incrementally-patched subsystem),
Finding 2 a code-accuracy overstatement. All adopted and folded into the body.

#### RESOLVED: HIGH — `endpoint_exhausted` ignored in the next-index computation (off-by-one → dup/loop)
**Verified:** the advance rule was pinned as `next = current_index + stop_endpoint_offset` with no
`endpoint_exhausted` term — so a page that stopped right after exhausting its endpoint re-enters that
learner (duplicate/loop), while a mid-endpoint stop must resume it. **Decision:** pinned the full rule —
exhausted → `+ offset + 1` with `inner_cursor: null`; not-exhausted → `+ offset` with the returned inner
cursor. Added the "cap hit exactly after exhausting the current endpoint" acceptance scenario. Folded into
the internal wire contract's `stop_endpoint_offset` bullet and the tier-split.

#### RESOLVED: HIGH — "loses report access entirely → 401 next page" overstated the live check
**Verified:** `AuthPlug` → `verify_api_token` preloads the **local** `users` row and `can_access_reports?`
reads its cached `portal_is_*` flags (`auth.ex:63-65`), set only at Portal-login upsert
(`accounts.ex:47-49,69-71`) — no live Portal re-fetch. So **API-token revocation** (`is_nil(revoked_at)`)
and **local role-flag** changes are enforced per request, but a **pure Portal-side role change is not** until
the local row refreshes (re-login). **Decision:** narrowed the wording in the Project-Owner Overview,
Snapshot-at-start authorization, idempotent-retry, Out-of-Scope, and the mid-export-revocation acceptance
scenario — token revocation halts the export; a Portal role removal carries the same staleness as the
derived snapshot, not an instant cut-off.

#### RESOLVED: HIGH — returned-item cap doesn't bound history reads after the `remote_endpoint` filter
**Verified:** `endpoint_limit` (Round-2) bounds *learners walked*, not reads *within* one learner; a single
learner with a large shared-tuple history full of excluded/duplicate siblings can read thousands of
metadata+state docs that are all post-filtered out → `items: []` while blowing the read/timeout bound.
**Decision:** added a third page bound — `read_limit`, a **pre-filter raw-doc-read cap** (metadata + state
docs counted before the `remote_endpoint` filter); a page returns on any of `limit`/`endpoint_limit`/
`read_limit`, and **MUST return the inner cursor even when every fetched doc was filtered out** so it resumes
mid-learner. Folded into the internal contract, the bounded-work + max-page-size bullets, and a new
"Huge filtered history bounded by `read_limit`" acceptance scenario.

#### RESOLVED: MEDIUM — EXPIRED_CURSOR lookup/delete predicates were contradictory (would 404 an expired row, not 410)
**Verified:** the guard predicates bundled `expires_at > now` and returned 404 on miss, but the read-time-
expiry/delete text needed an expired row to yield **410 `EXPIRED_CURSOR`** — an expired row is a "miss" under
`expires_at > now` → would 404, breaking the CLI's restart contract. **Decision:** specified the **two-step**
lookup — identity match (`scratch_id/user_id/report_run_id/data_type`, no expiry) → 404 on no match;
matched-but-expired → delete + 410; active → serve + bump. Preserves 404-indistinguishability for
forged/cross-user/cross-route ids while giving the owner the required 410. Reconciled all guard-predicate
quotes (cursor-integrity (ii), tier-split step 1, "Every access", delete-on-EXPIRED_CURSOR) to the identity/
expiry split.

---

## Internal Consistency Pass — cursor/scratch/tier-split state machine (2026-07-14)

After three external rounds patched the pagination state machine incrementally, a dedicated adversarial
end-to-end trace of the whole subsystem (first-page → mid-pages → crash-resume → retry → terminal →
replay-terminal → expired-resume → cross-route; all three caps; TTL-bump vs idempotency; touched_endpoints
crash-timing; audit/export_id-on-expiry) was run to catch exactly the "one of two co-located copies left
stale" hazard incremental patching creates.

#### RESOLVED: HIGH — the tier-split bullet retained the pre-Round-3 buggy advance formula (`current_index + offset`, no `endpoint_exhausted` term)
**Verified (traced):** Round-3 fixed the advance rule in the wire-contract bullet but **missed the
co-located copy in the "Cursor ownership (tier split)" bullet** (the section literally titled who advances
the endpoint index), which still read `new absolute index = current_index + offset`. Traced: an endpoint
exhausted exactly at the item cap returns `endpoint_exhausted: true, offset: k`; the stale formula advances
to `k` (not `k+1`), so the next page re-enters the just-exhausted endpoint, reads 0 items, exhausts again,
advances to `k` again → **infinite loop** — the exact HIGH dup/loop Round-3 fixed elsewhere. **Decision:**
rewrote the tier-split bullet to carry the full two-branch `endpoint_exhausted` rule (exhausted → `+offset+1`,
null inner cursor; not-exhausted → `+offset`, returned inner cursor), matching the wire contract. Verified no
other live-body copy of the bare formula remains (only historical decision-log records).

#### RESOLVED (hardening): pinned the `read_limit` forward-progress invariant
**Verified (traced):** the state machine's liveness quietly depended on `read_limit ≥ 1` and on the
per-learner `answers … limit 1` tuple read (an *answers* doc) **not** counting toward `read_limit` — else a
history page could trip `read_limit` before reading any `interactive_state_histories` doc, advancing neither
the endpoint index nor the inner cursor → a token identical to the one requested (no forward progress).
**Decision:** stated the invariant explicitly on the `read_limit` bullet.

**Certified sound (traced, no change needed):** first-page derivation + empty-permission short-circuit;
the empty-mid-export (`endpoint_limit`) and huge-filtered-history (`read_limit`) zero-item pages both yield
resumable non-null tokens; `stop_endpoint_offset` = "endpoint stopped **on**" is used consistently (the ±1
lives in `endpoint_exhausted`, not the offset); terminal-page retention → idempotent replay (not 410);
**absolute** TTL-bump keeps idempotent retry safe (bump touches only `expires_at`, never the cursor); the
two-step expired lookup distinguishes 404 from 410; `data_type` guard catches the null-inner-cursor
cross-route case; a `touched_endpoints`-then-cursor crash only costs a tuple re-read (dedup-at-read absorbs
it); deleting an expired scratch orphans no audit rows (append-only, independent `export_id`).

---

## External Review (Round 4) — 2026-07-14

A fourth external review. **Each finding re-verified against source before adoption**; all four confirmed.
As anticipated at convergence, every finding is in the cursor/scratch state machine or reconciles text an
earlier round edited — the review is polishing one subsystem, not finding spread-out defects.

#### RESOLVED: HIGH — `:none` in the empty-200 path contradicted the 401 path
**Verified:** `get_allowed_project_ids` returns `:none` only when all `portal_is_*` flags are false, which is
exactly when `can_access_reports?` is false → **AuthPlug 401 before the controller**. So `:none` is
unreachable past the pipeline, and my R2/R3 short-circuit lumping it with `[]` as an empty-200 case
contradicted "role flags cleared → 401." **Decision:** `[]` (role-flagged researcher, zero project rows) is
the real, reachable empty-200 case; `:none` is mapped to `{:ok, []}` **defensively** but marked unreachable
and **not** a claimed acceptance behavior. Reconciled the short-circuit, No-FORBIDDEN bullet, and
Empty-export scenario. (Round-4 self-review had already noted `:none` unreachable; this re-aligns the later
edits to it.)

#### RESOLVED: MEDIUM — array/object query bearer is rejected by shared mw (400), not the guard (401)
**Verified:** `bearer-token-auth.ts:23` only extracts a query bearer when `typeof === "string"`; an
array/object `?bearer[0]=` alone (no header) is never extracted → `res.error(400, "No bearer found")` before
the bulk guard. So the acceptance claim "`?bearer[0]=` → 401 from the guard" was inaccurate — the security
property (never *honor* a non-header bearer) holds, but the layer/code differ. **Decision:** corrected the
acceptance scenario + trust-boundary (d) to the accurate layering — scalar-query/body or array/object-*with*-
header → 401 (guard); array/object-*alone* → 400 (shared mw); header-only → allowed. (Took the accurate-
criteria option, not an invasive middleware reorder — both reject.)

#### RESOLVED: MEDIUM — stale OQ decision text still prescribed single-query expiry
**Verified:** the RESOLVED scratch OQ decision still read "`auth_grants`-style read-time expiry (`WHERE
expires_at > now`)," which an implementer could follow and collapse expired→404, breaking the 410 restart
contract the R3-F4 two-step lookup fixed in the body. **Decision:** updated the OQ decision — auth_grants-
style TTL *storage*, but **not** its single-query invisible-when-expired lookup; the scratch uses the
two-step identity/expiry split (404 vs 410).

#### RESOLVED: HIGH — `endpoint_exhausted` at an exact cap boundary was underspecified (Firestore has-more)
**Verified:** `limit(M)` returning M docs doesn't prove exhaustion; the spec never said how Node *knows*, so
a guessed `true` would skip data and a conservative `false` would fail the acceptance scenario. **Decision:**
pinned determinism — `endpoint_exhausted: true` **only on proof** (a short batch read, or a `limit(1)`
lookahead past the last consumed doc returning empty, counted against `read_limit`); when a cap stops Node
mid-endpoint with next-doc unknown it performs the lookahead — **never guesses true** (false-true = data
loss; false-false = a safe extra page). Folded into the internal contract and the "cap hit exactly after
exhausting" acceptance scenario.

---

