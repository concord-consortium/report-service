# cc-data CLI server support: logout revoke, token introspection + export coverage metadata

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-77

**Related specs**: [REPORT-74 (STORY 1 — auth + JSON API foundation, Closed)](REPORT-74-cc-data-authenticated-json-api-auth-foundation.md), [REPORT-76 (STORY 3 — bulk read answers/history, Closed)](REPORT-76-cc-data-bulk-read-answers-history.md); client spec: `cc-data-cli` repo, `specs/REPORT-77-cc-data-cli/`

**Status**: **Closed**

## Overview

Three small server-side pieces owed by the cc-data CLI story (REPORT-77): an authenticated endpoint that revokes the calling API token (backing `cc-data logout`), a token-introspection endpoint plus an optional label on the CLI token exchange (backing `cc-data auth status --check` and distinguishable token labels), and a `total_endpoints` field on the answers/history export envelope so the CLI can record honest coverage counts.

The CLI degrades gracefully when any piece is missing (logout falls back to local delete with a warning; `--check` falls back to `GET /reports?limit=1` and marks token metadata unknown; coverage records `with_data` only), so shipping order between the repos does not matter.

## Requirements

### Logout: revoke the calling token

- `ReportServerWeb.Api.AuthPlug` additionally assigns the resolved token struct (`assign(conn, :api_token, api_token)`); existing behavior (verify, `can_access_reports?`, `touch_api_token`, `:current_user`) is unchanged on existing routes.
- A new authenticated endpoint, `DELETE /api/v1/tokens/current`, revokes the bearer token making the call via `Accounts.revoke_api_token(api_token, user.id)` (self-revocation: `revoked_by` is the token's own user).
- The revoke endpoint authenticates by **token validity alone**: it verifies the bearer but skips the `can_access_reports?` role gate, so a de-provisioned user can still revoke their own credential. Mechanically: a `token_only: true` option on `AuthPlug` in a dedicated router pipeline; every existing `/api/v1` route keeps the full role-gated pipeline. Invalid and already-revoked tokens still receive the standard 401.
- Success returns 200 with `{"revoked": true}` (no success anywhere in the API returns 204). A lost race (`{:error, :already_revoked}`) is the same success; a genuinely revoked token cannot reach the endpoint (401 at token verification), so this only covers concurrent self-revocations.
- Consumer contract: a 401 from this endpoint means the bearer is already invalid, which a logout client may safely treat as nothing-to-revoke success (the matching client-side exemption from the generic 401 rule is specced in cc-data-cli).

### Token introspection: `GET /api/v1/tokens/current` + exchange label

- `GET /api/v1/tokens/current` returns the calling bearer token's own metadata: 200 + `{"label": ..., "created_at": ..., "last_used_at": ..., "report_access": true|false}` (`created_at` from `inserted_at`, ISO 8601 UTC; `last_used_at` and `label` nullable). Backs `cc-data auth status --check`.
- Same authentication posture as the revoke route (token-only pipeline, one small token-self-management scope). `report_access` carries the role-gate result as data so the CLI can render "token valid, but the account lacks report access" instead of a bare 401; the flag reflects the locally-stored `portal_is_*` role flags with the same staleness the role gate itself has.
- The introspection call must not bump `last_used_at`: the token-only pipeline skips `touch_api_token`, so `--check` does not overwrite the signal it reports.
- No `data_access_log` write on either token route: credential-management events, not data exports.
- Optional additive `label` on the token exchange: `POST /auth/cli/token` accepts an optional `label` string; when present it becomes the minted token's label instead of the constant "CLI login". Sanitized rather than rejected (trim; truncate to 100 chars; empty/non-string falls back to the default) because the exchange burns the one-time code. Older CLIs that send no label keep today's behavior.

### Export coverage: `total_endpoints` on the envelope

- `GET /api/v1/reports/:id/answers` and `.../history` envelopes gain `total_endpoints`: the size of the export's derived endpoint set (`length(scratch.endpoint_set)` in `serve_page`; `0` on the empty-export first page).
- The value is constant across all pages of one export (the endpoint set is snapshotted at export start; mid-export cutoffs fail the whole request with 401 via `AuthPlug` and never shrink a page, per the REPORT-76 snapshot-at-start semantics).
- Additive and backward compatible; `GET /api/v1/reports` keeps its two-key envelope.

## Technical Notes

- Files: `lib/report_server_web/api/auth_plug.ex` (assign `:api_token`; token-only mode), `lib/report_server_web/router.ex` (token-only pipeline + scope, defined **above** the `/api/v1` fallback scope whose `match :*` catch-all would otherwise shadow the routes with an unauthenticated 404; the pipeline includes `force_json`), `lib/report_server_web/api/v1/token_controller.ex` (new), `lib/report_server_web/controllers/auth_cli_controller.ex` + `lib/report_server/accounts.ex` (optional exchange `label` threaded into `create_api_token/2`), `lib/report_server_web/api/v1/bulk_export_controller.ex` (both envelope emission points), plus tests alongside the existing controller tests.
- `Accounts.revoke_api_token/2` performs an atomic conditional `UPDATE ... WHERE revoked_at IS NULL`; no changes were needed there.
- Audit: token revocation is a credential-management event; the credential audit trail is the `api_tokens` row itself, which durably records `revoked_at` and `revoked_by_user_id` (first-writer-wins actor attribution). The token UIs list active tokens only, so a revoked token drops out of them.
- `Exports.merge_touched_endpoints` rewrites `scratch.endpoint_set` between pages (tuple-cache writes) but is an `Enum.map` over existing entries — membership and cardinality never change, so the `total_endpoints` denominator is invariant across pages.
- Accepted trade-off: introspection permits zero-trace validity checking of a held token (no `last_used_at` bump, no audit row). The alternative (touching on `--check`) would destroy the very signal the endpoint reports, and it is visible only to someone already holding the raw token.

## Out of Scope

- Generation-readiness items (a `NOT_APPLICABLE` error code, widening the Athena-slug gate, any create-run endpoint): follow-on work, not this story. *(`report_type` in run metadata was originally deferred here too; that deferral was reversed post-closure — see Amendments.)*
- Any CLI-side behavior (owned by the client spec in cc-data-cli).
- Token-management UI changes (STORY 2 shipped them; revoked tokens drop out of the token UIs automatically — they list active tokens only).

## Decisions

### Where does the revoke endpoint live?
**Context**: The ticket left the route open ("e.g. POST /auth/cli/logout or DELETE /api/v1/tokens/current"). The `/auth` scope uses the unauthenticated `:api` pipeline, while `/api/v1` already runs bearer auth.
**Options considered**:
- A) `DELETE /api/v1/tokens/current`: RESTful shape, leaves room for future token-management routes under `/tokens`.
- B) `POST /auth/cli/logout`: name mirrors the login flow, but needs the bearer pipeline bolted onto a scope that otherwise has none.

**Decision**: A. B's only advantage was naming symmetry. Amended during self-review: the endpoint skips the role gate, so it got a token-only pipeline rather than reusing `:api_authenticated` as-is.

---

### Can a de-provisioned user revoke their own token?
**Context**: `AuthPlug` requires `can_access_reports?`, so behind the standard pipeline exactly the user most in need of cleanup (deprovisioned researcher, the REPORT-74 deprovisioning flow) could not self-revoke — the token hash would stay live and silently resurrect if roles were ever restored.
**Options considered**:
- A) Keep the role gate; admins revoke via the token UI; document the limitation.
- B) Authenticate the revoke endpoint by token validity alone — self-revocation of a valid credential is always fail-safe.

**Decision**: B. Marginal trade-off accepted: on this one endpoint a valid-but-de-roled token is distinguishable from an invalid one (success vs 401), visible only to someone already holding the token.

---

### Success response shape for the revoke endpoint
**Context**: The CLI codes against a versioned contract; "match the codebase's API conventions" would defer a decision the spec exists to make.
**Decision**: 200 with `{"revoked": true}`. Verified convention: no success response anywhere in the API returns 204 — every success is 200 + JSON.

---

### A 401 from logout means "already dead", not "log in again"
**Context**: The client spec's blanket rule (non-login commands emit "run cc-data login" on 401) would have told a user whose token an admin already revoked to log back in during logout, possibly leaving the local credential stored.
**Decision**: Contract sentence added: a 401 from this endpoint means the bearer is already invalid, which a logout client safely treats as nothing-to-revoke success. The matching exemption (warn, delete local credential, exit 0) was specced in cc-data-cli. This also makes logout retry compose safely: a network-failed DELETE that succeeded server-side gets 401 on retry, which is the same success.

---

### The race-branch test is unreachable over HTTP
**Context**: After a first revoke, any second HTTP request 401s at `AuthPlug`, so the `{:error, :already_revoked}` → success branch only executes when revocation lands between `AuthPlug` and the controller action. A two-request HTTP test would exercise the wrong branch.
**Decision**: The test invokes the controller action directly with a pre-revoked `%ApiToken{}` in assigns. The construction (`Phoenix.Controller.json/2` on a bare `build_conn()` with assigns) was proven with a throwaway ExUnit test before the spec was written.

---

### Does the revoke route also skip `touch_api_token`, or only introspection?
**Context**: Introspection must skip the touch (`--check` must not overwrite the signal it reports); revoke could have gone either way.
**Decision**: Token-only mode skips the touch for both routes. Bumping `last_used_at` on a token in the act of being revoked is a wasted write with no observable value — the revocation is durably recorded in `revoked_at`. One mode, one behavior, simpler plug.

---

### AuthPlug option vs. sibling plug for the token-only mode
**Context**: The requirements allowed either an `AuthPlug` option or a small sibling plug.
**Decision**: An `AuthPlug` option (`token_only: true`). The two modes share every line of the verify-and-assign path; a sibling plug would duplicate it or extract a shared helper for two call sites.

---

### The token-only scope must sit above the `/api/v1` catch-all
**Context**: Verified with a throwaway ConnCase test: the fallback scope's `match :*` matches every verb, and Phoenix matches routes in definition order, so a scope added below it would be silently shadowed — every request would 404 before reaching the auth plug. This was the first new `/api/v1` scope added after the fallback landed.
**Decision**: The token-only scope is defined between the `:api_authenticated` scope and the fallback scope, with a router comment stating the constraint; its pipeline includes `force_json` like the others.

---

### Where does label sanitization live?
**Context**: Sanitizing untrusted HTTP input is a controller concern; `Accounts.create_api_token/2` has a store-what-you're-given contract the token UI already relies on.
**Decision**: In `AuthCliController` (`sanitize_label/1`), with the `"CLI login"` default applied at the `Accounts` call site via `label || "CLI login"`. Sanitize rather than reject (trim, truncate to 100 chars, empty/non-string → default): the exchange burns the one-time code, so a 400 over a cosmetic field would cost a whole login round-trip. Refined during implementation code review: trim again after truncation so a cut landing just past a space never stores trailing whitespace.

---

### View module or inline `json/2` for the token endpoints?
**Decision**: Inline `json/2`. `BulkExportController` already sets this precedent for minimal envelopes; both token bodies are four keys or fewer. A `TokenJSON` module would be indirection with a single caller each.

---

### The constant-denominator justification uses snapshot-at-start semantics
**Context**: An early draft justified `total_endpoints` constancy with "per-page permission re-checks shrink served items" — verified false. Per REPORT-76, the authorized set is frozen at export start; per-page live checks (token revocation, role-flag clearance) fail the whole request with 401, never shrink a page. The client spec's contrary contract note ("derived per page") was also fixed in cc-data-cli.
**Decision**: The requirement's conclusion (constant across pages) stands on the verified snapshot argument; both specs now state it consistently.

---

### No `data_access_log` write on token routes
**Context**: An earlier justification claimed the token UIs "display `revoked_at`" — verified false (they list active tokens only).
**Decision**: The no-audit decision stands on a true basis: reading or revoking one's own token is a credential-management event, and the `api_tokens` row durably records `revoked_at` + `revoked_by_user_id` with first-writer-wins actor attribution. Consistent with both existing revoke call sites (token UIs), which write no audit entry.

---

### Test-coverage decisions from implementation review
**Context**: Two QA findings during the implementation spec's self-review.
**Decision**: (1) The non-nil `last_used_at` rendering path (the introspection body's only conditional) gets a dedicated test that touches the token first, then asserts the ISO 8601 rendering and that introspection leaves the value unchanged. (2) The introspection metadata test mints a second, differently-labeled token for the same user so "returns the calling token's own row" is actually discriminated from "returns the user's most recent token".

## Amendments

### 2026-07-17: `report_type` on run metadata (added post-closure)

The cc-data-cli spec review added a fourth owed server dependency beyond the three deliverables above, reversing the Out of Scope deferral of `report_type` (the other generation-readiness items stay deferred).

**Requirement**: the v1 run JSON — both the `GET /api/v1/reports` list items and `GET /api/v1/reports/:id`, rendered in `report_json.ex` — gains an additive string field `report_type` with a server-owned vocabulary of `answers` | `usage` | `log`, derived from the run's report definition:

- `student-answers` → `answers`
- `student-assignment-usage` → `usage`
- `student-actions`, `student-actions-with-metadata`, `teacher-actions` → `log`

The distinguishing facts behind the vocabulary: only the shared_queries `:answers` SQL appends the two pseudo-header rows ("Prompt" and "Correct answer" in `student_id`) to its CSV; usage shares the learner-column shape without those rows; the three log-based reports carry log columns, and student-actions (minimal learner cols) and teacher-actions (log cols only) have no `student_id` column at all. Any future report type must ship with a value in this vocabulary or a new value; the vocabulary is part of the API contract and additions are contract changes.

**Why the CLI needs it**: cc-data keys its pseudo-header row filter and a report-shape allowlist on this field. It filters the two rows only for `report_type: answers` CSVs (an unconditional filter is a binder error on the log reports and a conversion error on usage), and it quarantines runs whose type it does not recognize (excluded from aggregate views with an upgrade warning, per-run views still available) instead of silently misinterpreting them. Against servers without the field the CLI derives the type from the known slugs, so the field is purely additive and backward-compatible.

**Implementation**: the value derives from the report definitions themselves — an `api_report_type` attribute on the Athena report modules (via `use ReportServer.Reports.Report` opts), read from the report tree by the JSON view — rather than a slug map inside the view. Every run the API lists (all Athena-slug runs) carries the field in both list and show payloads; tests assert presence and exact value per report slug, and fail if a future Athena report ships without a vocabulary value.
