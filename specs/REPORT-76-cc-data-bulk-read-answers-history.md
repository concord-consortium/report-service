# cc-data: Bulk-Read Function for Answers + Interactive History (Paged, Resumable)

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-76

**Related specs**: [REPORT-74 (STORY 1 — auth + JSON API foundation, Closed)](REPORT-74-cc-data-authenticated-json-api-auth-foundation.md), [REPORT-75 (STORY 2 — token-management UI, Closed)](REPORT-75-cc-data-token-management-ui.md)

**Status**: **Closed**

## Overview

STORY 3 of the cc-data researcher toolchain adds authenticated endpoints that let a researcher download, for a report run they own, every student's raw saved answers, the full history of how each answer changed as the student worked, and the binary attachments those answers reference (open-response audio recordings and offloaded CODAP/SageModeler documents) — the per-answer detail, moment-by-moment trajectory, and rich media the existing denormalized CSV report can't express. Because a single report can hold tens of thousands of history snapshots, the answers/history download is delivered in bounded, resumable pages that survive function timeouts and network interruptions; attachments are handed out as short-lived presigned URLs from a batch endpoint. Every access is authorization-gated and audit-logged.

It is the read-from-Firestore sibling of the existing report generation, consumed by the STORY-4 command-line tool (REPORT-77). The set of students a researcher may export is derived once, at the start of each export, from the same report filters and project permissions the reports apply — and every page is re-checked against the researcher's live access token. Every export is recorded in the STORY-1 audit log (both the students it was *scoped to* and the students whose data *actually left the server*, correlated by a stable export id), and the admin audit page gains search by export or by individual student.

## Requirements

### Elixir bulk endpoints
- `GET /api/v1/reports/:id/answers` and `GET /api/v1/reports/:id/history` under the existing `:api_authenticated` scope.
- Authz reuses STORY 1's ownership gate (`report_runs.user_id == caller`); non-existent / not-owned / non-Athena / malformed `:id` all return indistinguishable **404 `NOT_FOUND`**. Malformed-`:id` 404 comes from `Params.parse_id/1` (kept before `get_api_report_run/2`, which would raise on a non-integer).
- **Live endpoint derivation (once per export)**: on the first page (null `page_token`), after the ownership gate, Elixir runs `LearnerData.fetch(report_run.report_filter, caller, allow_empty: true)` to derive the authorized learner set. `report_filter` is normalized `nil → %ReportFilter{}` first (nil would 500 `FunctionClauseError`). An empty (`[]`) permission set short-circuits to `{:ok, []}` **before any SQL** (else `IN ()` → 500). `:none` mapped defensively but unreachable (401s at AuthPlug). Per learner it builds `{remote_endpoint, source}` where `source` matches the report's own `COALESCE(url_extract_parameter(runnable_url, 'answersSourceKey'), hostname(runnable_url))` + offline→online remap (not hostname-only).
- Snapshot-at-start authorization: the authorized set is frozen at export start. Per page, `AuthPlug` enforces live only (a) API-token revocation and (b) locally-stored `portal_is_*` role flags. A pure Portal-side role change is not live until re-login.
- Elixir proxies, Node reads: Elixir loads the snapshot, slices the ordered endpoint list from the cursor's endpoint index onward, passes the slice + source-per-endpoint + inner cursor to a new Node read, holding the static Firebase bearer server-side.
- Any Athena-type owned run id is valid (all 5 `athena_report_slugs()`); the learner set is filter-derived and report-type-agnostic, so a `teacher-actions` run works too.
- `Cache-Control: no-store` (and `Pragma: no-cache`) on both bulk responses (raw per-answer state + `remote_endpoint`s ship directly in the body).

### Pagination + resumability (contract)
- Unified envelope `{ "items": [...], "next_page_token": "<opaque>" | null }`; `limit` query param in; `page_token` echoed as the request param.
- STORY-3-specific `limit`: default/max **500** (not STORY 1's 50/200); `limit` only **lowers** the cap.
- Termination is signalled **solely** by `next_page_token == null`; `items: []` with a non-null token is a legitimate mid-export page and must NOT be treated as end-of-stream.
- Stable iteration order frozen in scratch; monotonic progress modulo tolerated at-least-once re-delivery. No total-count/progress signal in v1.
- **Bounded work per call** by three caps — returned-item cap (`limit` ~500), endpoints-walked cap (`endpoint_limit` 250), pre-filter raw-doc-read cap (`read_limit` 5000) — a page returns when any is hit. (A fourth Node-side `RESPONSE_BYTE_BUDGET` ~8 MB cap was added during implementation; see Decisions.)
- Paginate by learner (outer = endpoint index, inner = per-learner Firestore cursor). No `offset()`. answers ordered by `__name__`; history ordered by `(created_at, __name__)`.
- History cursor carries the full Timestamp `{seconds, nanoseconds}` integers (µs-granular); Node reconstructs a `Firestore.Timestamp` for `startAfter`. Never a millis number, never a raw-ISO cursor (both re-lose µs → skipped snapshots). Node/Elixir guard the reconstruction and return `BAD_REQUEST` on out-of-range/stringified fields (never an uncaught 500).
- Opaque composite cursor references (a) the server-side scratch id, (b) the endpoint index, (c) the inner Firestore cursor. Integrity is enforced by capability + per-page ownership/`data_type` re-check + `endpoint_index ∈ [0, len)` + inner-cursor validation — **not** by signing.
- Scratch is route-bound by a `data_type` column in the ownership guard (a `/history` token replayed on `/answers` → 404, including the `null`-inner-cursor case). Shape validation kept as defense-in-depth.
- Idempotent retry (no double-advance); the terminal page's scratch row is retained so replaying the terminal token re-serves the identical final page (not `EXPIRED_CURSOR`).
- At-least-once + dedup-at-read (the CLI dedups by stable id); `EXPIRED_CURSOR` on resume after TTL lapse (CLI restarts from null cursor); a Node read failure → `SERVER_ERROR`, no audit row, no cursor advance.

### Firestore read surface (Node)
- Per endpoint under the computed `source`: answers `where remote_endpoint == x` ordered by `__name__` (auto single-field index); history keyed by the **LTI identity tuple** `(platform_id, platform_user_id, resource_link_id)` — derive via `answers … limit 1`, query `interactive_state_histories` `orderBy(created_at, __name__)`, batch-get `interactive_state_history_states/{historyId}`, then **filter state docs to the authorized `remote_endpoint`** (the tuple is 1:many to `remote_endpoint`, so filtering keeps history provably scoped + audit-accurate).
- The Node function is authorization-blind by design (trusts Elixir; gated by the static `AUTH_BEARER_TOKEN`). **Header-only bearer** enforced on the bulk routes via a small per-route key-existence guard (rejects scalar/array/object query or body bearer) — the shared middleware stays unchanged for co-located routes.
- Raw state passthrough (double-JSON-encoded); the CLI decodes.
- Prerequisite composite index `interactive_state_histories (platform_id, platform_user_id, resource_link_id, created_at)` in the target project (dev/pro carry only `context_id`-led variants that cannot serve this query).

### Item shapes (wire)
- Raw doc passthrough (matches `get-answer`), doc id folded in. `/answers` item = raw answer doc; `/history` item = raw state doc + `history_id` + ISO `created_at` (Node converts the metadata `Timestamp` via `.toDate().toISOString()`) + `answer_id`/`question_id`. State stays double-encoded.

### Attachment download (batch presigned URLs)
- `POST /api/v1/reports/:id/attachments` (run id in path = durable auth handle). Body: optional `disposition` (`attachment` default / `inline`), `attachments: [{collection, source, doc_id, name}, …]` ≤ 500. Returns per-item `{url}` or `{error: not_found|not_authorized}` + `expires_in_seconds: 600`. Partial success.
- Authorization is **durable** (re-derives `endpoint_set` from `:id`, survives the scratch TTL, reflects current permissions), NOT the export scratch.
- **IDOR guard**: the server re-reads each doc via a Node metadata helper for the authoritative `publicPath`, authorizes on the doc's `remote_endpoint ∈ endpoint_set` (never a client-supplied path; not `folder.ownerId` — run-with-others legitimately differs).
- Presign with report-service's own **server creds** (`Aws.presign_server_get/2`), not workgroup creds; no token-service brokering. One fail-closed audit row per call (`attachment_urls_issued` / `attachment`, distinct signed `remote_endpoints`).

### Audit logging (reuse STORY 1's `data_access_log`)
- Two row kinds correlated by export id = scratch id: an **intent** row once at export start (`export_scoped`, full derived set) and per-page **access** rows (`bulk_read`, endpoints actually served). Distinct labeled rows prevent conflating "scoped-to" with "actually exported".
- Add a nullable `export_id` column + index; extend the `DataAccessLogEntry` changeset (`event`/`data_type` allow-lists) and retype `endpoint_set` to a custom `:map`-typed Ecto type carrying a top-level JSON array.
- Fail-closed ordering; page-1 scratch + intent rows written atomically (`Ecto.Multi`).

### Admin audit-log page — filter by export id + student search
- Filter by `export_id` (exact) and search `remote_endpoint` within `endpoint_set` via pathless, bound-parameter `JSON_CONTAINS(endpoint_set, JSON_QUOTE(?))` (intentionally case-sensitive for `secure_key` matching). URL-param-driven, reuses STORY 1's pager, admin-only.
- Accessibility: `aria-live` result summary, filter-aware empty state, focus move to results on filter (not paging), real labeled form (one associated label per control, visible submit button), `<caption>` + `scope="col"`.

### Server-side scratch (paginated endpoint set)
- A MySQL `export_scratch` table (not ETS — Fargate `maximumPercent: 200` + ALB-without-stickiness makes in-memory wrong) holds the once-derived snapshot keyed by an unguessable `scratch_id` capability (`strong_rand_bytes(32)`, not the PK). Columns include `endpoint_set` (EctoJsonArray), `report_run_id`, `user_id`, `data_type`, `expires_at`; unique index on `scratch_id`, plain index on `expires_at`.
- **Two-step read-time lookup**: identity match (no expiry) → 404 on miss; matched-but-expired → delete (scoped) + **410 `EXPIRED_CURSOR`**; active → serve + **absolute** sliding-TTL bump (1 h inactivity).
- Cleanup: inline delete only on `EXPIRED_CURSOR`; terminal page retained; a periodic + boot GenServer sweep (`DELETE WHERE expires_at < now()`, 15 min) reclaims both. The boot sweep runs from `handle_continue`, never `init/1`.
- Per-learner LTI-tuple cache in the scratch (`answers … limit 1` runs once per export); chunk the history state batch-get.

### Error codes
- Reuse STORY 1's shape and `@statuses`; codes `NOT_AUTHENTICATED` (401), `NOT_FOUND` (404), `BAD_REQUEST` (400), `SERVER_ERROR` (500), and the one new `EXPIRED_CURSOR` → **410 Gone** (chosen over 409 to avoid a `code_for_status/1` reverse-map collision with `NOT_READY`). No `FORBIDDEN`.

### Validation (in-story milestone)
- Delivered as one story with a front-loaded end-to-end vertical slice (one learner → one page → cursor → resume) to measure big-class cost/latency/timeout headroom on real data before build-out.

## Technical Notes
- Cloud Functions: bounded pages keep each call well under the response cap and the raised ~300 s timeout; no gen2 needed.
- Elixir integration reuses STORY 1's `:api_authenticated` pipeline, `Reports.get_api_report_run/2`, `ErrorHelpers`, `AuditLog`, and `ReportService` (`Req`, static bearer).
- Firestore data model (verified): answers/history written atomically under `sources/{sourceKey}/`; `report_state` is double-JSON-encoded; identity fields are pseudonymous (no name/email); history metadata carries the authoritative sortable `created_at` while the state doc carries `remote_endpoint`.
- Deployment prerequisites (must run against the live target project, not the emulator): create the `interactive_state_histories (platform_id, platform_user_id, resource_link_id, created_at)` composite index (dev/pro carry only `context_id`-led variants that cannot serve this query — a missing index surfaces as `FAILED_PRECONDITION`); the shared `api` `timeoutSeconds` bump (60 → 300) lifts the ceiling for every co-located route, so call it out in deploy review and sanity-check the ALB/proxy idle timeout against ~300 s; the two new migrations (`export_scratch`, `data_access_log.export_id`) run on deploy; the attachment endpoint needs no new infra (the `report-server-*` IAM already grants `s3:GetObject` on `<private-bucket>/interactive-attachments/*` and `TOKEN_SERVICE_PRIVATE_BUCKET` selects the per-env bucket); and run the env-gated real-data source-fidelity check once before exercising `/answers` + `/history` for real.

## Out of Scope
- The Go CLI consuming these endpoints (dedup-at-read, NDJSON storage, resume, DuckDB views) — STORY 4.
- CSV / report download and the `/reports`, `/:id`, `/:id/download`, `/jobs` endpoints — STORY 1.
- Token issuance / management UI — STORY 1 / STORY 2.
- Anonymous/offline (`run_key`) runs (no `remote_endpoint`).
- The narrow residual `answersSourceKey` edge: an answer written under a stored `source_key[question_id]` that differs from the `runnable_url` derivation (a live Firestore read needs the `source` before it can find the answer; only the materialized report recovers this). The general `answersSourceKey`-override case IS handled.
- Server-side decoding of interactive state (raw passthrough; the CLI decodes).
- Any mid-export roster / filter / project-permission change (snapshotted at export start; only token revocation / local-flag clearance cut it off live).
- Per-user / per-token rate limiting or read quotas (deferred; accepted v1 risk for authenticated researchers).
- The `cc-data logout` server endpoint and the `AuthPlug` `api_token` assign — STORY 4.
- Finer-grained resume-after-`EXPIRED_CURSOR` (partial-scratch resume after TTL).

## Not Yet Implemented

These were deliberately deferred as backward-compatible/additive future work (no contract or cursor change needed to add later):

- **Server-side `latest-N` history slimming** — deferred as an additive `/history` param if STORY 4 needs it; "latest state" is already served by `/answers`.
- **Server-side `question_id` filter for history (and answers)** — deferred (client-side filtering suffices; the client already receives `question_id` on every item). The only efficient server-side option is index-based (`.where("question_id","==",…)` + a new composite index in dev and pro); revisit if a concrete consumer repeatedly wants a single question's history in isolation.
- **Total-count / progress signal** in the envelope — deferred as an additive field (a total would require an extra full traversal).
- **A dedicated attachment-*content*-resolve endpoint** (byte proxy / redirect) — the walker stays reference-only and the batch presign endpoint covers URL issuance; a content-resolve endpoint is a possible later story.
- **Short per-`(user, report_run)` attachment-derivation cache** and **tuple query-result caching for duplicate-learner siblings** — possible later optimizations, not required.
- **`firestore.indexes.json` capture** — left empty per the repo's manual/console index convention; the history composite index is created out-of-band (see `deploy-checklist.md`).
- **A masked/non-secret search key for `endpoint_set`** and a **generated-column JSON index** for the `remote_endpoint` search — later hardening/perf, out of scope (the search is an accepted unindexed scan at current admin volume).

## Decisions

### Where does the bulk read live, and at what Cloud Function generation/timeout?
**Context**: Every existing Firestore read is a route on one shared gen1 Express `api` function with no explicit timeout (60 s default). Bounded pages mean no gen2 ceiling is needed.
**Options considered**:
- A) New routes on the existing gen1 `api` app, raising just that function's `timeoutSeconds`.
- B) A separate gen1 function with its own timeout.
- C) A separate gen2 function.

**Decision**: **A** — new routes on the existing gen1 `api` Express app, raising `timeoutSeconds` (60 → 300) for slack. Bounded pages keep each call short; the routes inherit all existing middleware/helpers with the least new surface.

---

### What backs the server-side scratch, and what TTL / max page size?
**Context**: The once-derived authorized endpoint snapshot must be cached across pages. Deployment is Fargate with `maximumPercent: 200` (two tasks transiently) behind an ALB without stickiness.
**Options considered**:
- A) MySQL `export_scratch` table — durable, correct under the 2-task deploy window.
- B) ETS / in-memory — wrong under the 2-task window (a resumed page can hit the other task) and wiped on deploy.
- C) Encode the whole set into the cursor — token bloat, can't be safely re-intersected.

**Decision**: **A** — a MySQL table with the **two-step** lookup (not `auth_grants`' single-query invisible-when-expired, which would collapse expired → 404 and break the 410 restart contract). Sliding 1 h TTL (absolute bump); ~500-doc page cap. Cleanup: inline delete only on `EXPIRED_CURSOR`, terminal page retained, periodic + boot sweep.

---

### Does the v1 endpoint accept a `history_mode` (full / latest-only / latest-N), or always full?
**Options considered**:
- A) Always full; CLI slims.
- B) `/history` accepts `history_mode` and slims server-side.
- C) `/history` always full; "latest state" is `/answers`; `latest-N` deferred.

**Decision**: **C** — simplest correct server; avoids a `latest-only` mode that duplicates the `/answers` doc. Server-side `latest-N` deferred as a backward-compatible additive param.

---

### Do the endpoints work for any Athena-type run, or only answer-report runs?
**Options considered**:
- A) Any Athena-type owned run (filter-derived learner set, report type irrelevant, no allowlist).
- B) Restrict to learner-based reports (adds a maintained allowlist + an excluded-run error decision).

**Decision**: **A** — `teacher-actions` runs work too (permission-bounded); endpoints inherit the run's filter breadth by design.

---

### Exact wire item shapes for `/answers` and `/history`.
**Options considered**:
- A) Raw doc passthrough + folded doc id (matches `get-answer`).
- B) Projected field allow-list.

**Decision**: **A**. `/answers` = raw answer doc; `/history` = raw state doc + `history_id` + ISO `created_at` + `answer_id`/`question_id`. This verification also corrected the design doc: history is keyed by the **LTI tuple** (not `remote_endpoint` + `orderBy(created_at)`, which is not implementable because the sortable-timestamp collection has no `remote_endpoint`), matching portal-report's proven slider query, and requires the composite index prerequisite.

---

### Spike-then-implement split, or one story?
**Options considered**:
- A) One story with an early end-to-end validation milestone.
- B) Formal spike + impl subtasks.

**Decision**: **A** — one story with a front-loaded "validate on a big class" step (the history mechanic is already proven and timeout is designed away by bounded pages).

---

### Does STORY 3 reintroduce a `FORBIDDEN` error code?
**Options considered**:
- A) No `FORBIDDEN` — ownership → 404, bad-token/lost-access → 401, permission shrink → empty-200; only new code is `EXPIRED_CURSOR` (410).
- B) Add `FORBIDDEN` for some case.

**Decision**: **A** — no `FORBIDDEN`. A fully-emptied permission set is a legitimate empty-200 (caller owns the run); a 403 would leak nothing 404 doesn't already handle.

---

### Admin audit-log page student search — in or out of scope?
**Context**: STORY 1 deferred audit-page filters "to STORY 3, when the endpoint-set column has data"; with no follow-on server-side story, the search would otherwise never be built.
**Decision**: **In scope** — filter by `export_id` + search `remote_endpoint` within `endpoint_set` (JSON array; `JSON_CONTAINS`), reusing STORY 1's pager, admin-only, with the a11y treatment.

---

### LTI-tuple ↔ `remote_endpoint` cardinality — does tuple-keyed history stay scoped?
**Context**: History fetches by the LTI tuple but authz/audit is by `remote_endpoint`. Verified in rigse: the tuple → `remote_endpoint` is **1:many** (`portal_learners` has no unique `(student_id, offering_id)` constraint; `find_or_create_learner` is non-atomic).
**Options considered**:
- A) Assume 1:1; verify at the validation milestone (audit-fidelity risk).
- B) Post-filter fetched state docs to the authorized `remote_endpoint`.

**Decision**: **B** — filtering is required (not belt-and-suspenders); it makes history provably scoped to the exact audited endpoint set regardless of cardinality (no-op in the common 1:1 case).

---

### Composite `page_token` wire format (implementation)
**Decision**: `base64url(JSON)` of `{"s": scratch_id, "i": endpoint_index, "c": inner_cursor}`, unsigned plaintext (as STORY 1). Integrity is capability (`strong_rand_bytes` scratch_id) + per-page ownership/`data_type` re-check + `endpoint_index ∈ [0, len)` + inner-cursor field validation — not signing.

---

### One Node route vs two (implementation)
**Decision**: One `POST /bulk_read` with `collection` in the body; the two Elixir routes both call it (avoids duplicating the walker). The Elixir `data_type` still binds each scratch to its route.

---

### Default page caps and history batch sizes (implementation)
**Decision**: `endpoint_limit` 250, `read_limit` 5000, `HISTORY_BATCH` 300, `GETALL_CHUNK` 300; `limit` default/**max 500** (server cap == default, so `limit` only lowers). **Update discovered during implementation**: `limit=500` alone is not byte-safe (a live probe measured answers up to ~313 KB and history states p95 ~52 KB; large states cluster by activity), so a **fourth cap — an ~8 MB `RESPONSE_BYTE_BUDGET`** — was added to the Node walker. It bounds a page by accumulated serialized bytes, always admits ≥1 item (max item < 1 MiB ≪ 8 MB → forward progress guaranteed), and makes `limit` purely an item-count convenience.

---

### Test-seam mechanism for stubs (implementation)
**Decision**: Mirror the project's `AthenaDBStub` pattern — a named `Agent` selected via `Application.put_env` (`:report_service_client`, `:learner_data`, `:allowed_project_ids_source`), with `async: false` tests. Robust across processes; not the process dictionary.

---

### LiveView focus-move mechanism after filter submit (implementation)
**Decision**: A small `FocusResults` `phx-hook` on a `tabindex="-1"` results container whose `updated()` moves focus when a filter-derived `data-refocus` token changes — so focus moves on a filter change but NOT on paging (which would steal focus from the activated pager control). The `aria-live` region announces the result count independently.

---

### MyXQL does not round-trip a bare `{:array, _}` schema field over a `json` column (external review)
**Context**: The plan first declared `endpoint_set` as `{:array, :map}`/`{:array, :string}`, but `Ecto.Adapters.MyXQL` prepends `json_decode` only for `:map`/`{:map, _}` loaders — a bare `{:array, _}` field reads the raw JSON string back and fails to load (writes succeed).
**Decision**: Introduce a custom `ReportServer.Types.EctoJsonArray` (`type/0 == :map` so it gets the `json_decode` loader; list-shaped cast/load/dump), mirroring the repo's `EctoReportFilter`. Migration columns stay `:map`; the stored value remains a top-level JSON array so the pathless `JSON_CONTAINS` filter is unchanged. Added DB round-trip regression tests. (Lesson: verify adapter round-trip against the driver source, not by analogy.)

---

### Production default bulk client, `parse_id` max-bigint, error-code ordering (external review)
**Decision**: Fully-qualify the `report_service` accessor default to `ReportServer.ReportService` (an unqualified default resolves to a nonexistent module in production where the env is unset). Reuse STORY 1's `Params.parse_id/1` directly (restores the `@max_bigint` guard so an out-of-range `:id` 404s instead of blowing up the bigint column → 500). Move the `EXPIRED_CURSOR → 410` `@statuses` registration into the vertical-slice step so the slice's `:expired` path resolves 410 rather than raising a `KeyError` (no forward dependency).

---

### Portal permission-query failure handling (external review)
**Decision**: `derive_endpoint_set/2` adds an explicit `{:error, _reason}` branch (before the `_allowed` catch-all) so a portal permission-query failure maps to a controlled `SERVER_ERROR` (500), rather than being swallowed and later raising `Protocol.UndefinedError` deep in `list_to_in/1`.

---

### Source-derivation fidelity — URL-only by design (external review / IRB)
**Context**: The report's own SQL prefers the answer's recorded `source_key[question_id]` and uses the URL derivation only as a fallback; STORY 3's `SourceKey.from_runnable_url/1` implements only that URL-derived fallback (Elixir can't cheaply read the authoritative key at derive time).
**Decision**: Keep the URL-only derivation but make the trade-off explicit. Fidelity is checked in two parts: a hermetic stubbed controller test asserts the derived `source` reaches Node, and the real-data assertion (the URL-derived `source` matches where a known learner's answers live) is an env-gated live step in the deploy checklist. The uncovered divergence class (rehosted/migrated activity or per-question `source_key`) is documented and out of scope.

---

### Attachment endpoint — server-cred presign and authorization key (implementation / external review)
**Decision**: Presign with report-service's own **server creds** via a new `Aws.presign_server_get/2` (build `s3://<private_bucket>/<publicPath>` as `transcribe_audio.ex` does) — **not** the existing `Aws.get_presigned_url/3`, which uses per-user Athena workgroup creds (wrong trust boundary; can't read the attachments bucket). Authorize on the doc's **`remote_endpoint`** (`∈ endpoint_set`), never a client-supplied `publicPath` and never `folder.ownerId` (run-with-others legitimately makes `ownerId` differ; gating on it would wrongly deny a legitimate collaborative artifact). Extract the endpoint derivation into a shared public `EndpointSet` module so both controllers can call it. Add `validate_meta_count/2` so a Node result-count mismatch is a contract violation → 500, never a silently truncated result set. Response carries `cache-control: no-store`; the client filename flows through a `safe_filename/1` (strips CR/LF/quotes/control chars, RFC-6266-quoted).

---

### Emulator test harness — hermetic + serial (implementation)
**Context**: The repo had no automated emulator-backed test harness. A bare `firebase emulators:exec` relies on a global `firebase-tools`, and jest's default parallel workers race when two `*.emulator.test.ts` suites share one emulator (each clears `sources/*`).
**Decision**: Pin `firebase-tools` as a devDependency and invoke via `npx firebase emulators:exec`; add `\.emulator\.test\.` to `testPathIgnorePatterns` so plain `npm test` skips the emulator suites (their fail-closed `emulator-setup` import would otherwise redden a default run), re-including them via a CLI ignore override in `test:emulator`; and run the emulator suites with `--runInBand` so the shared-emulator `clearFirestore` races are avoided.
