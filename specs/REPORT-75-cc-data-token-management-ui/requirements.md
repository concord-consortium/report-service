# cc-data: Token-Management UI

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-75
**Repo**: https://github.com/concord-consortium/report-service
**Implementation Spec**: [implementation.md](implementation.md)
**Status**: **Ready for Implementation**

## Overview

Give researchers a self-serve page that lists all of their active `cc-data` CLI access tokens — each
with its label, creation date, and last-used time — and lets them revoke any token, with a
confirmation that names the exact token so the wrong machine is never cut off. The existing
generate-a-token page is extended into this page, so a just-minted token appears in the list
immediately below its shown-once value. A parallel admin-only view lists every user's active tokens
and lets an admin revoke a departed researcher's token without database access. This is the
user-visible "see them and kill them" half of the non-expiring token model from REPORT-74, and a
prerequisite for handing the `cc-data` CLI to researchers outside the team.

## Project Owner Overview

REPORT-74 established a per-user, **non-expiring** bearer-token model for the `cc-data` researcher CLI,
deliberately trading token expiry for control-via-revocation. That trade-off only holds if a user can
actually *see* the tokens they have minted and *kill* the ones they no longer recognize — the classic
"old laptop I logged in from once and forgot" case — and if the team can cut off a **departed**
researcher who can no longer self-revoke. Today revocation is manual (DB/console only), which is fine
for internal spikes but unacceptable before the tool reaches researchers outside the team.

This story delivers the self-serve token-management page (merged into the existing generate page so
mint-then-see-it-listed is one flow) plus an admin audit-and-revoke view of every user's tokens. Every
revocation is recorded with **who performed it** — a small accountability addition that closes the "who
killed this token" gap the new admin-revoke power introduces — and revocation is race-safe so
concurrent or two-tab revokes can't misattribute or double-count. Together these close the loop so the
non-expiring model is defensible and the CLI can be rolled out. Out of scope: minting changes, label
editing, and the CLI's own `cc-data logout` command (deferred to STORY 4 / REPORT-77).

## Background

The `cc-data` CLI (epic REPORT-70, design doc REPORT-71) lets researchers pull report data locally
and query it (including via an AI assistant) instead of hand-downloading CSVs from the web UI.
REPORT-74 ("STORY 1") built the server foundation: a per-user API-token model, the `/auth/cli`
loopback login + code-exchange flow, the authenticated `/api/v1/...` JSON API, and a
`data_access_log` audit table.

The token model (`ReportServer.Accounts.ApiToken`, table `api_tokens`) already supports everything
this UI needs to *read and act on*:

- `create_api_token/2`, `verify_api_token/1`, `revoke_api_token/1` (sets `revoked_at`), and
  `touch_api_token/1` (updates `last_used_at`, thresholded to ~60s) all exist and are tested.
- Each row carries `label` (optional, user-supplied at mint time), `last_used_at`, `revoked_at`,
  `inserted_at`/`updated_at`, and `token_hash` (SHA-256; the raw `ccd_...` token is shown once at
  mint time and is **not recoverable**).
- A user may hold **multiple concurrent active tokens** (one per machine/login).

What does **not** exist yet, and is the substance of this story:

- No way to **list** a user's tokens (there is no `list_*_api_tokens` function).
- No **self-serve UI** to view or revoke tokens — revocation is manual DB/console only.
- No **admin** view of tokens.
- The existing token-related page, `/reports/cli-token` (`ReportLive.CliToken`), only **mints** a
  token and shows it once; it does not list existing tokens.

This story adds a LiveView page (and the supporting context functions) that lists a user's active
tokens and revokes them, plus an admin view of the same information, following the patterns
REPORT-74 established for the audit-log page.

## Requirements

<!-- Verified assumptions are marked ✓ (proven against the real schema/DB with a throwaway ExUnit
     probe during spec authoring — see Technical Notes → "Assumptions verified"). -->

### Token list (per-user)

- A token-management page lists **all of the signed-in user's active (non-revoked) tokens**. ✓
- Each row shows, at minimum: the optional **label**, **created** date (`inserted_at`), and
  **last used** time (`last_used_at`). ✓
- A token that has **never been used** renders a clear "never used" state rather than a blank
  cell (`last_used_at` is nil until the first API request touches it). ✓
- Tokens are listed **newest-first**. ✓
- The **raw token value is never shown** in the list — it is unrecoverable (only the hash is
  stored); rows are identified by label + created + last-used. ✓
- **Empty state**: a user with no active tokens sees a clear "no active tokens" message, not an
  empty table. On the **merged** self-serve page the create path is the generate form already
  present above the list, so the empty-state copy is simply "You have no active tokens yet." (it does
  **not** repeat a "create one" call-to-action). The **admin** page's empty state is self-contained
  ("No active tokens.") since it has no generate form. ✓ (merged page always renders the generate
  form — `cli_token.html.heex`)
- **Live refresh after mint** (merged page): a token minted via the generate form **appears in the
  active-token list in the same LiveView render**, immediately below the shown-once value — this is
  Q1's headline benefit. Because `mount/3` runs once, the `generate` event handler must **re-load the
  active-token list assign** after `create_api_token/2` succeeds (assigning the list only at mount
  would leave a just-minted token invisible until reload). This is a **net-new** behavior on the
  existing generate handler (which today assigns only `:raw_token`) and must be tested. ✓ (verified:
  `cli_token.ex` `generate` handler assigns only `:raw_token`; nothing refreshes a list today)
  Conversely, the new **`revoke` handler must preserve `@raw_token`** when revoking a *different* row:
  while the shown-once value is displayed, the just-minted token also appears in the list, so a user can
  click Revoke on another (old) row without leaving the page; the revoke handler reassigns only the list
  + flash and must **not** blank the shown-once value the user may still be copying.
  **Exception — revoking the just-minted row clears the shown-once panel**: because the just-minted
  token is itself a revocable row, a user can revoke the very token being displayed. A revoked token
  must **not** remain on screen under "Your new token" as if usable, so when the revoked id **is** the
  shown-once token's id, the handler clears `@raw_token` (and its tracked id). To distinguish the two
  cases the `generate` handler records the minted token's id (e.g. `@raw_token_id`) and the `revoke`
  handler clears the panel only on an id match. Both behaviors must be tested (revoke-another-row
  preserves the value; revoke-the-minted-row clears it).
- **Columns**: Label, Created, Last used, (Revoke). Timestamps render **absolute UTC** via
  `<time datetime="…">YYYY-MM-DD HH:MM UTC</time>`, matching the audit-log page; `last_used_at ==
  nil` renders "Never used". No token-id column. The admin view prepends a **User** column rendering
  **name + email** (`First Last (email)`), matching the audit-log page — not the run list's name-only
  `include_user` — so an admin can reliably identify a departed researcher's tokens. ✓
- **Pagination**: the self-serve per-user list shows **all** of the caller's active tokens
  **unpaginated** (a user's active tokens are naturally bounded — roughly one per machine — so
  paginating your own handful is worse UX). Only the admin global list is paginated (25/page). ✓

### Revoke

- The user can **revoke any token** in their list. ✓
- Revocation is **immediate**: a revoked token stops authenticating on the very next API request
  (the underlying revoke stamps `revoked_at`, which `verify_api_token/1` already filters on; the UI
  calls the actor-stamping `revoke_api_token/2`, now an atomic conditional write — see Revocation
  accountability). ✓
- Revocation **only affects the targeted token**; the user's other tokens keep working. ✓
- Revocation is scoped to ownership: a user can only revoke **their own** tokens; the revoke action
  must be authorization-checked server-side, not just hidden in the UI. ✓ (ownership-scoped fetch
  verified to block another user's token id)
- Revoke is guarded by a confirmation naming the specific token (`data-confirm`); on confirm the
  token **disappears from the active list** and a flash (`role="alert"`) announces "Token revoked".
  ✓ (`<.flash_group>` renders on this page via `app.html.heex`)
- **Server-side authorization of the revoke event (primary control)**: the self-serve `revoke`
  event handler fetches the token **ownership-scoped and active-only**
  (`WHERE id = ? AND user_id = <caller> AND revoked_at IS NULL`); a forged/other-user or
  already-revoked id fetches as **nil and is a benign no-op**, never a cross-user revoke or a crash.
  This is the load-bearing IDOR guard (the page is mounted for all report users) and must be tested.
  ✓ (fetch semantics verified against the DB: owner→row, other-user→nil, already-revoked→nil)
- The admin `revoke` handler uses an active-only cross-user fetch and **re-asserts `portal_is_admin`
  in the handler** as defense-in-depth (the mount gate already blocks non-admins; the re-check is
  cheap insurance, not the primary control).
- **Already-revoked / stale-render no-op**: a `revoke` whose target fetches as nil (already revoked
  in another tab or by an admin, or absent) is a **benign no-op** — the handler re-renders the
  refreshed list and shows an **`:info` flash worded for the benign end-state**
  ("That token was already inactive"). The app's `flash_group` supports only two kinds — `:info`
  ("Success!", green) and `:error` ("Error!", red) — with no neutral kind, so the no-op uses `:info`
  and is **worded to read correctly under the "Success!" frame** (the user's goal, an inactive token,
  is already met); it is deliberately **not** an `:error`, which would wrongly signal the user erred
  on a benign race. Applies to both the self-serve and admin handlers. ✓ (nil-fetch verified;
  `flash_group` two-kind constraint verified by rendering the component)

### Admin audit view

- A `portal_is_admin`-gated admin page lists **all users' active tokens** — a global list with a
  **user** column plus label, created, and last-used — paginated 25/page, newest-first, mirroring
  `/reports/all-runs` and the audit-log page. ✓ (cross-user "all active tokens, user preloaded"
  query verified; paginates via `Pagination.paginate`)
- **Stable pagination order**: because the admin list is **paginated** (independent `LIMIT/OFFSET`
  queries per page), its `order_by` must be a **total order**, not just `[desc: inserted_at]` —
  `inserted_at` is a second-granularity `:utc_datetime` and multiple tokens can share one value, so a
  tie straddling a page boundary could be duplicated onto or skipped from both pages. The admin query
  orders by **`[desc: inserted_at, desc: id]`** (the primary key breaks ties into a genuine total
  order). ✓ (probe: 30 rapidly-minted tokens collapsed to **one** distinct `inserted_at`; the `id`
  tiebreaker restored a no-dup/no-skip order across pages). The per-user self-serve list is
  unpaginated, so its `[desc: inserted_at]` ordering needs no tiebreaker (a tie there is only a
  cosmetic within-page ordering, never a skipped row). *(Index note: no index currently backs
  `WHERE revoked_at IS NULL ORDER BY inserted_at, id` — negligible at this story's token volumes;
  revisit with a composite index only if the table grows.)*
- Admins can **revoke any user's token** from this view (offboarding a departed researcher without
  DB access), calling the actor-stamping `revoke_api_token/2` with the admin's id. ✓
- **Revoke-and-repaginate** (admin page): revoking is a `phx-click` **event**, but the list is
  paginated via `handle_params` — so the revoke handler must **re-run the paginated query and
  reassign `@page`/`@total_pages`/items from the `Pagination.paginate` result** (not keep the stale
  socket `@page`). Revoking the **last row on the last page** shrinks `total_pages`; the handler must
  land the admin on a valid page (re-paginating with the clamped `result.page`), never on an empty
  page N. `Pagination.paginate` already clamps `page = min(page, total_pages)` so this cannot crash,
  but the post-revoke page the admin sees must be defined and tested. (Equivalent implementation:
  `push_patch` to the current page so `handle_params` re-paginates through the same clamp.) ✓
  (`Pagination.paginate` clamp verified in `pagination.ex`; audit-log page reassigns page from the
  paginate result via `handle_params`, but revoke is a separate event path with no such reassignment
  today)
- Admin-initiated revokes are **attributed** — see the accountability requirement below. The admin
  revoke action is authorization-checked server-side (`portal_is_admin`), not merely UI-hidden.

### Revocation accountability

- Every revocation records **who performed it**: a nullable `revoked_by_user_id` FK column on
  `api_tokens`, stamped at revoke time (self-revoke → owner's id; admin-revoke → the admin's id).
  This closes the "who killed this token" gap that admin-revoke introduces (the row already records
  `revoked_at`, the *when*). No lifecycle **create** events are logged, and `data_access_log` is
  **not** reused (it is data-access-only and structurally rejects a run-less event).
- **Accountability is race-safe (first-writer-wins)**: revocation is an **atomic conditional write**
  (`UPDATE … WHERE id = ? AND revoked_at IS NULL`, checking the affected-row count), not a
  fetch-then-unconditional-update. In a concurrent self/admin or two-tab race, two handlers can both
  fetch the token active, but only the **first** write matches `revoked_at IS NULL` and stamps
  `revoked_by_user_id`; the loser matches **0 rows** and overwrites nothing — so the recorded actor is
  deterministic (the first revoker), never clobbered by a later racing revoke. This mirrors the
  existing exactly-once idiom in `Accounts.exchange_auth_grant/2` (and `athena_run_ops`). The loser's
  handler treats the `{:error, :already_revoked}` result as the same benign no-op as an already-revoked
  fetch ("That token was already inactive"), so the no-op contract holds even under true concurrency,
  not just under sequential tab ordering.

### Access control / navigation

- The page(s) live under the existing `:reports` `live_session` and are gated by
  `can_access_reports?` (portal admin || project admin || project researcher), matching every other
  reports page. The admin audit view additionally requires `portal_is_admin`, matching the
  audit-log page.
- The reports home (`index.html.heex` root) gains `described_link`s: **"CLI Access Tokens"** (all
  report users → merged token page), **"All CLI Tokens"** (admins → admin audit view), and
  **"Data Access Log"** (admins → the previously-orphaned `/reports/audit-log`). This makes the
  token page discoverable so the "find your forgotten token" purpose is actually reachable.

### Accessibility (mandatory — UI feature)

- The token table uses proper `<th>` header markup **and an accessible name** via `<caption>` (may
  be `sr-only`) or `aria-label`. This is **net-new** — the sibling audit-log/run tables have no
  caption or `aria-label`, so it must be added here, not inherited from that pattern.
- The revoke control is a real `<button>` (keyboard-operable, correct AT role) with an accessible
  name identifying **which** token it revokes, and confirms destructive intent via `data-confirm`
  (RESOLVED Q4). The confirmation (and the button's accessible name) must identify the token
  **unambiguously even when it is unlabeled or shares a label** — include the label when present
  (else "unlabeled"), the **created timestamp** (and last-used), **and the token's non-secret DB id
  as a guaranteed-unique discriminator**, all drawn from the same row, e.g.
  _"Revoke the token labeled 'Doug's MacBook' (created 2026-07-01 14:22 UTC, last used 2026-07-10
  09:03 UTC, #42)? The machine using it will need a new token."_ or _"Revoke the unlabeled token
  created 2026-07-01 14:22 UTC (never used, #57)? …"_.
  **The id is required, not decorative**: label + created + last-used are **not** a unique key —
  `inserted_at` is second-granularity (verified: rapidly-minted tokens collapse to one value) and
  never-used rows all share `last_used_at == nil`, so two unlabeled tokens minted in the same second
  are otherwise **identical** in the confirm text; the `id` is what actually prevents revoking the
  wrong machine's token. This does **not** reintroduce a visible token-id **column** (Q7 rejected
  that as techy) — the id appears only in the confirm string / accessible name, where correctness of a
  destructive action outweighs the tidiness of the visible table. The admin confirmation carries the
  same id discriminator (a single user's two same-second unlabeled tokens collide there too, despite
  the User column).
- Both the success ("Token revoked") and the already-inactive no-op ("That token was already
  inactive") outcomes are `:info` flashes that surface through the app's existing `flash_group`,
  which renders `role="alert"` for the `:info` kind — so both are announced to assistive tech with
  **no** custom live region needed. (Note: this covers *announcement* only; the two outcomes are not
  visually distinguished as success-vs-neutral because `flash_group` has no neutral kind — both show
  the green "Success!" frame, which is acceptable since both represent a satisfied end-state.)
  (The cli-token page's existing `aria-live="polite"` region stays for the copy-to-clipboard action.)
- New UI follows the app's existing Tailwind styles and maintains WCAG AA contrast (same bar
  REPORT-74 set for the audit-log and cli-token pages).

## Technical Notes

### Where this fits

- **Context**: `ReportServer.Accounts` (`server/lib/report_server/accounts.ex`) — add a list query
  (e.g. `list_active_api_tokens/1`), an ownership-scoped **active-only** fetch for revoke-by-id
  (e.g. `get_user_api_token/2`), and, for the admin view, a cross-user list (e.g.
  `list_all_active_api_tokens/1`, paginated). `get_user_api_token/2` must be a real query
  (`from t in ApiToken, where: t.id == ^id and t.user_id == ^user_id and is_nil(t.revoked_at)`),
  **not** `Repo.get_by/2` — `get_by` is not `revoked_at`-filtered (verified: it returns an
  already-revoked row), so it would defeat the stale/already-revoked no-op contract. The pre-story
  `revoke_api_token/1` is **not** reused as-is — it gains a required actor argument (see the
  "`revoke_api_token` signature change" note below); both handlers call the two-arg form.
- **Schema/migration**: `ReportServer.Accounts.ApiToken` — the list/revoke core needs no schema
  change (all display columns already exist). Per RESOLVED Q6, this story adds **one** migration:
  a nullable `revoked_by_user_id` FK column (`references(:users, on_delete: :nothing)`) for
  revocation accountability, plus a schema `belongs_to` and inclusion in the changeset.
- **`revoke_api_token` signature change**: becomes `revoke_api_token(api_token, revoked_by_user_id)`
  with the actor **required** (no default) so no code path can produce a silently-unattributed
  revoke — self-revoke passes the owner's id, admin-revoke passes the admin's id. The DB column
  stays **nullable** (legitimate for historical rows and manual DB/console revokes). The body also
  changes from a fetch-then-`Repo.update()` to an **atomic conditional `Repo.update_all` write**
  (`WHERE id = ? AND revoked_at IS NULL`, returning `{:ok, reloaded}` on `{1,_}` and
  `{:error, :already_revoked}` on `{0,_}`) so concurrent revokes are first-writer-wins and cannot
  clobber `revoked_by_user_id` — see Requirements → Revocation accountability, and the precedent in
  `Accounts.exchange_auth_grant/2`. Only two callers exist today, both tests
  (`test/report_server_web/api/auth_plug_test.exs`, `test/report_server/accounts_test.exs`); each does
  a single revoke of a fresh token (`{:ok, _} = …`) so both still match under the new return contract,
  and both are updated to the 2-arg form in the same commit.
- **LiveView / routes**: model the page(s) on `ReportServerWeb.AuditLogLive.Index`
  (`server/lib/report_server_web/live/audit_log_live/`) — mount gate, `handle_params`,
  table + `<.pager>`, empty state. The **per-user** list+revoke is merged into the existing
  `ReportLive.CliToken` page at `/reports/cli-token` (RESOLVED Q1); the **admin** view adds a new
  `portal_is_admin`-gated route mirroring `/reports/all-runs` (e.g. `live "/all-tokens", ...`,
  RESOLVED Q2), inside the `:reports` `live_session` in
  `server/lib/report_server_web/router.ex`.
- **Revoke interaction**: a `phx-click` event carrying the token id; the handler re-fetches the
  token **ownership-scoped** (never trusts the id alone), revokes, and re-renders the list.
  Mutating LiveView events already exist (`ReportLive.CliToken` `generate` mints a token;
  `ReportLive.Form` `submit_form` creates a report run — both create-then-assign/redirect), but this
  is the first **destructive, in-place** reports action (revoke → row disappears, same render), so
  its authz-scoped fetch and re-render path are worth a focused test. Reuse the existing
  mutating-event test patterns (`cli_token_live_test.exs`, `report_live_test.exs`) as precedent.
- **Pagination**: the **admin** global list reuses `ReportServer.Pagination` (offset, 25/page) and
  the `<.pager>` component (`custom_components.ex`; renders nothing for a single page,
  `<nav aria-label=...>`, `aria-current="page"`). Because offset pagination issues an independent
  query per page, the admin query orders by **`[desc: inserted_at, desc: id]`** — a unique tiebreaker
  making the order total, so no tied row is duplicated or skipped at a page boundary (unlike a bare
  `[desc: inserted_at]`, which is non-unique at second granularity). The **self-serve** per-user list
  is unpaginated (shows all active tokens) — no `Pagination`/`<.pager>`, and `[desc: inserted_at]`
  suffices there.
- **Auth helpers**: `ReportServerWeb.Auth.can_access_reports?/1` and the `portal_is_admin` flag on
  the session `user`; `ReportServerWeb.ReportLive.Auth` on_mount already assigns `@user`.
- **Existing mint page**: `ReportServerWeb.ReportLive.CliToken` at `/reports/cli-token` mints +
  shows-once; per RESOLVED Q1 the per-user list + revoke are merged into this same page (heading
  becomes "CLI Access Tokens"), preserving its shown-once contract.
- **Copy hook / one-time display** (only relevant if list+generate are merged): the `CopyToClipboard`
  JS hook and the shown-once token pattern already exist in `cli_token.html.heex`.

### Assumptions verified (throwaway ExUnit probe, run green, then deleted)

During spec authoring I ran a disposable probe test against the real MySQL test DB (CI env vars from
`.github/workflows/report-server.yml`) to de-risk the requirements. All passed:

1. `WHERE user_id = ? AND revoked_at IS NULL ORDER BY inserted_at DESC` returns only the user's
   active tokens and never leaks another user's rows.
2. Listed rows carry `label`, `inserted_at`, and `last_used_at` (nil before first `touch`,
   populated after); `token_hash` is present but is not the raw `ccd_...` token (confirming the
   value is unshowable).
3. A cross-user "all active tokens" query with `preload: [:user]` yields each token's owning user —
   feasible basis for the admin audit view.
4. `Repo.get_by(ApiToken, id: id, user_id: user.id)` returns the row for the owner and **nil** for
   a non-owner — this proves the **ownership** scope only. It is **not** `revoked_at`-filtered (it
   returns an already-revoked row), so the actual handler fetch (`get_user_api_token/2`) adds
   `is_nil(t.revoked_at)`; that active-only exclusion is standard SQL and its "revoked → out of the
   active set" behavior is separately exercised by #5 below.
5. `revoke_api_token/1` removes the token from the active list and is idempotent-safe (re-revoking
   an already-revoked token does not error).

### Testing

- `ConnCase.log_in_conn/2` (`test/support/conn_case.ex`) puts a logged-in portal session on the
  conn for LiveView tests; `AccountsFixtures.user_fixture/1` and `api_token_fixture/2` create users
  and tokens. `AuditLogLiveTest` is the closest precedent for list/pagination/empty-state/
  authz-redirect assertions; `CliTokenLiveTest` covers the merged page's existing shown-once
  behavior (must keep passing).
- This story adds the app's first **destructive** LiveView action tests (mutating LiveView events
  already exist — mint on this same page, report-run creation in `ReportLive.Form` — but none that
  delete/revoke in place). Acceptance criteria to cover
  explicitly:
  - **Self-revoke happy path**: owner revokes their token → row disappears, "Token revoked" flash.
  - **IDOR no-op**: a forged `revoke` event with another user's token id does **not** revoke it
    (the target stays active); no crash. (Context-level fetch semantics already verified by probe.)
  - **List isolation (view layer)**: with two users each holding active tokens, the self-serve list
    renders **only the signed-in user's** tokens — a second user's active token is **absent** from
    the render. Pins tenant isolation at the LiveView boundary (not just the context query), so a
    regression to an unscoped list function is caught.
  - **Admin revoke happy path**: an admin revokes another user's token from `/reports/all-tokens`.
  - **Admin authz**: a non-admin is redirected at mount **and** an admin `revoke` event pushed by a
    non-admin is rejected by the handler (defense-in-depth).
  - **Attribution**: `revoked_by_user_id` == owner id on self-revoke, == admin id on admin-revoke.
  - **Atomic first-writer-wins (accountability race)**: a context-level test proving a second revoke of
    an already-revoked token (passing a stale still-active struct, as a lost-race handler would hold)
    returns `{:error, :already_revoked}` and **does not overwrite** the original `revoked_by_user_id`.
    Pins the atomic conditional write so concurrent self/admin revokes cannot clobber "who killed it".
  - **Stale/already-revoked**: revoking a token already revoked elsewhere is a benign no-op — the
    row is absent from the re-rendered list and an `:info` flash ("That token was already inactive")
    is shown (not an `:error`); the token is **not** re-revoked and `revoked_by_user_id` is unchanged.
  - **Rendering**: `last_used_at == nil` renders "Never used"; empty state renders its message and
    hides the pager; the admin pager appears only past 25 rows.
  - **Mint refreshes the list** (merged page): submitting the generate form makes the just-minted
    token appear in the active-token list in the same render (not only after reload) — the new test
    guarding Q1's headline behavior, alongside the existing shown-once assertions. Also assert that a
    subsequent `revoke` (of a different, older token) **does not blank `@raw_token`** — the shown-once
    value stays on screen through the revoke.
  - **Revoking the just-minted row clears the shown-once panel**: after minting (shown-once value on
    screen and the token also listed), revoking **that same** row removes it from the list **and**
    clears the shown-once value (`refute html =~ "ccd_"`), so a now-revoked token is not left displayed
    as usable — the counterpart to the preserve-on-other-row assertion above.
  - **Admin revoke-and-repaginate**: revoking the **only** token on the last admin page re-renders
    on a valid (non-empty) page with `@page`/`@total_pages` updated from the paginate result; no
    crash, no empty page N.
  - **Stable admin pagination order**: with more than 25 tokens **sharing one `inserted_at`**, every
    token appears **exactly once** across all pages (no duplicate, no skip) — pinning the
    `[desc: inserted_at, desc: id]` total-order tiebreaker.
  - **Accessibility**: the token table exposes an accessible name; the revoke control is a
    `<button>` with a token-specific accessible name; success **and** failure are announced.
  - **Confirmation disambiguation**: for two **unlabeled** tokens minted in the same second (both
    never-used — so label, created, and last-used all coincide), each revoke control's confirmation /
    accessible name still differs by the token's **DB id**, so they are distinguishable.

## Out of Scope

- **Changing how tokens are minted** — the existing generate form + shown-once behavior on
  `/reports/cli-token` is reused as-is (this story adds the list + revoke to that same page per
  RESOLVED Q1); the `/auth/cli` loopback mint flow is untouched.
- **Editing an existing token's label** — out (label is set at mint time; RESOLVED Q7). It does not
  serve the forgotten-token goal and would add the app's first inline-edit surface.
- **The Go CLI itself and its `cc-data logout` command** — STORY 4 (REPORT-77). The *server-side*
  endpoint a CLI logout would call is deferred to REPORT-77 (RESOLVED Q3) and noted on that ticket.
- **Answers/history bulk endpoints** — STORY 3.
- **Rate limiting / abuse protection** — future, per REPORT-74.
- **Changing the token model** (expiry, refresh, scopes) — the model stays non-expiring +
  revocable per the design doc.

## Open Questions

### RESOLVED: Separate token-management page, or merge list/revoke into the existing `/reports/cli-token` page?
**Context**: REPORT-74 shipped `/reports/cli-token` (`ReportLive.CliToken`), which mints a token and
shows it once. This story adds list + revoke. Merging gives a single "Access Tokens" page where a
user generates a token, sees it once, then sees it appear in the list below — arguably the best UX
and one fewer nav entry. Keeping them separate keeps each page simple and matches the current
route layout.
**Options considered**:
- A) **Merge** into one page (rename to e.g. "Access Tokens"): generate form + shown-once value +
  list-with-revoke on the same page. Redirect/keep `/reports/cli-token`.
- B) **Separate** new page (e.g. `/reports/tokens`) for list+revoke; leave `/reports/cli-token` as
  the generate page; cross-link the two.

**Decision**: **A — merge** the list + revoke into the existing `ReportLive.CliToken` page (heading
becomes "CLI Access Tokens"): the generate form + shown-once value stay, and the active-token list
with per-row revoke renders below. The `/reports/cli-token` route is kept (a just-minted token
appears in the list immediately below the shown-once value). Verified low-risk: the `/reports/cli-token`
URL has no external/CLI/doc dependencies (only the router, its template, and its own test reference
it; the CLI is STORY 4 and does not exist yet), and the existing shown-once contract
(`cli_token_live_test.exs`: mount mints nothing, refresh does not re-mint/re-show, blank label →
nil) is preserved unchanged — the merge only adds a list section.

### RESOLVED: What is the admin "audit the same view" — a single global list, per-user drill-down, and can admins revoke?
**Context**: The ticket says "Admins can audit the same view." That can mean (a) one admin-only page
listing **all** users' active tokens with a user column (paginated, like the audit-log page), or
(b) an admin can look up a **specific user** and see that user's tokens. It also doesn't say whether
admins can **revoke** other users' tokens or only view them. (For data downloads, REPORT-74
deliberately made the API strict-ownership and pointed admins at the web UI; there is no analogous
precedent for token revocation.)
**Options considered**:
- A) Global admin list of all active tokens (user, label, created, last-used), **view-only**,
  paginated 25/page, newest-first — mirrors the audit-log page. Revocation stays self-serve only.
- B) Global admin list as in A, **plus admins can revoke** any user's token (e.g. offboarding a
  departed researcher without DB access).
- C) Per-user drill-down (admin picks a user, sees their tokens), view-only or with revoke.

**Decision**: **B — global admin list + admin revoke.** A `portal_is_admin`-gated admin page (route
mirroring `/reports/all-runs`, e.g. `/reports/all-tokens`) lists **every** user's active tokens with
a user column (user, label, created, last-used), paginated 25/page, newest-first, and lets an admin
**revoke** any user's token. This closes the offboarding gap REPORT-74 documented — portal
deprovisioning does not auto-cut API access, and a *departed* researcher cannot self-revoke, so
without admin revoke the only cutoff path is still manual DB/console (the very thing this story
exists to eliminate). Admin revoke calls the actor-stamping `revoke_api_token/2`; because it acts on another user's
resource, it is paired with token-lifecycle audit logging (see Q6) so admin-initiated revokes are
recorded (actor + affected token + timestamp). Chosen over view-only (A) because timely
admin-driven cutoff of a departed researcher's non-expiring token is a real rollout requirement;
over per-user drill-down (C) because the global-list pattern already exists (`/reports/all-runs`,
audit-log) and needs no new navigation model. Verified feasible during authoring: the cross-user
"all active tokens, `preload: [:user]`" query works and paginates (`Pagination.paginate` strips
`:preload`/`:order_by` for its count), and the admin-revoke fetch is a cross-user **active-only**
query (`from t in ApiToken, where: t.id == ^id and is_nil(t.revoked_at)`) so an already-revoked id
fetches as **nil** and drops into the same benign no-op path as the self-serve handler (never a
`Repo.get`, which returns revoked rows — verified against the DB).

### RESOLVED: Is a server-side "revoke the calling token" endpoint (for `cc-data logout`) in scope here?
**Context**: The design intent says the UI "pairs with `cc-data logout` (revokes the current
token)." The CLI (STORY 4 = REPORT-77) needs a server endpoint to revoke the token it is currently
holding — revocation is inherently server-side (the CLI holds only the raw token; the server stores
its hash and flips `revoked_at`). REPORT-74 did not add one, and it firmly bucketed all CLI-facing
work (including the loopback listener) into STORY 4. This is arguably token-management server surface
that fits this story, or it can wait for STORY 4.
**Options considered**:
- A) **Out of scope** — STORY 4 adds whatever endpoint the CLI needs; this story is UI + context
  functions only.
- B) **In scope** — add a small authenticated endpoint (e.g. `POST /auth/cli/logout` or
  `DELETE /api/v1/tokens/current`) that revokes the bearer token making the call, so the
  server-side revocation surface is complete and testable now.

**Decision**: **A — out of scope; defer to STORY 4 (REPORT-77).** The logout endpoint has **no
consumer until the CLI exists**, and REPORT-74 deliberately placed every CLI-facing piece in STORY 4;
`cc-data logout` is a CLI subcommand. Unlike Q2's admin-revoke (which has a web-UI consumer in this
story and closes a documented security gap), shipping a consumer-less endpoint now is speculative —
STORY 4 will build it with its real request/response shape and client-driven tests. **Known
prerequisite recorded for STORY 4**: `Api.AuthPlug` currently assigns only `:current_user` (not the
`api_token`) at `auth_plug.ex:15`, though it already has the token struct in scope from
`verify_api_token/1` (`auth_plug.ex:12`) — so the logout endpoint will need the plug to also expose the
current token. The endpoint then revokes via the **actor-stamping two-arg**
`revoke_api_token(api_token, revoked_by_user_id)` that **this** story introduces (the pre-story one-arg
`revoke_api_token/1` is removed here — see Technical Notes → "`revoke_api_token` signature change"),
passing the authenticated `current_user.id` as `revoked_by_user_id`. A `cc-data logout` is a
**self-revoke**, so this attributes the revocation to the token's owner and keeps the endpoint on the
same accountability path as the UI (no unattributed revokes). This deferral + prerequisite is being
noted on REPORT-77 so it is not lost.

### RESOLVED: Revoke confirmation UX, and do revoked tokens vanish immediately or linger briefly?
**Context**: Revocation is destructive (the only recovery is minting a new token and re-logging-in
the affected machine). We should guard against accidental clicks. Separately, the list is defined as
"active tokens," so a revoked token would simply disappear — but a moment of "Revoked ✓" feedback
can reduce confusion.
**Options considered**:
- A) Confirmation before revoke (e.g. `data-confirm` browser prompt or a LiveView confirm), token
  **removed from the list** on success with a flash/live-region "Token revoked" message. Simplest.
- B) Confirmation, then the row stays visibly marked "Revoked" (greyed, action disabled) for the
  rest of the session/page render, giving stronger feedback; a refresh drops it.
- C) No confirmation (a revoke is recoverable by re-minting) — rely on the flash message only.

**Decision**: **A — `data-confirm` + vanish + flash.** The Revoke control uses LiveView
`data-confirm` (native `window.confirm`, fully keyboard/screen-reader accessible, no extra
component) with text naming the specific token (e.g. "Revoke the token labeled 'Doug's MacBook'? The
machine using it will need a new token."). On confirm the token is revoked, **removed from the
active list**, and a flash (`put_flash(:info, "Token revoked")`, rendered by the existing
`<.flash_group>` in `app.html.heex`, `role="alert"`) announces success. Same behavior in the admin
view. Chosen over the styled `<.modal>` + lingering "Revoked" row (B) because lingering adds per-row
session state that contradicts the "active tokens" list definition for marginal benefit; over
no-confirmation (C) because a native confirm is a cheap, accessible guard on a destructive action.

### RESOLVED: Should this story add reports-home navigation to the token page (and, for admins, the audit-log page)?
**Context**: The `/reports/cli-token` and `/reports/audit-log` pages exist but have **no** links on
the reports home (`ReportLive.Index` / `index.html.heex`) — they are reachable only by direct URL.
A token-management page that researchers can't find doesn't serve its "discover the forgotten token"
purpose. This story is a natural place to add discoverability.
**Options considered**:
- A) Add a home-page link to the token page for all report users, and (for admins) a link to the
  admin audit view — and, while here, also surface the existing audit-log/cli-token links.
- B) Add only the token-page link(s) this story introduces; leave the other pages' discoverability
  alone.
- C) No navigation changes — access by direct URL / from the CLI docs only (not recommended).

**Decision**: **A — add all three links** on the reports home root (`index.html.heex`, using the
existing `described_link` component; `@user` is available there via the `ReportLive.Auth` on_mount):
a **"CLI Access Tokens"** link for all report users (→ the merged token page at `/reports/cli-token`),
an **"All CLI Tokens"** link for admins (→ the new admin audit view), and — opportunistically — the
previously-orphaned **"Data Access Log"** link for admins (→ `/reports/audit-log`), since this story
is already assembling the admin-tools cluster. The audit-log link is a trivial fix for a REPORT-74
orphan; including it keeps the admin tools discoverable together.

### RESOLVED: Are token-lifecycle events (revoke, and/or create) audited anywhere?
**Context**: `data_access_log` records **data access** (CSV/URL issuance), not token lifecycle. There
is currently no record of who revoked or created which token. For an offboarding/security story,
"who killed this token and when" may matter — but it may also be unnecessary for v1.
**Options considered**:
- A) **No lifecycle logging** in v1 — out of scope; revocation just flips `revoked_at`.
- B) Log **revocations** (and maybe creations) to a lightweight audit trail (a new table or a
  reuse of the audit log with a distinct event type), capturing actor, token id, and timestamp —
  especially relevant if admins can revoke others' tokens (see the admin-view question).

**Decision**: **B, minimal form — add a nullable `revoked_by_user_id` FK column to `api_tokens`**
(stamped at revoke time: self-revoke → owner's id, admin-revoke → admin's id). The pre-story
`revoke_api_token/1` becomes the required two-arg `revoke_api_token(api_token, revoked_by_user_id)`.
This closes exactly the accountability gap that admin-revoke (Q2)
introduces — the token already records `revoked_at` (the *when*) but not the *who* — with a trivial
migration, **no new table**, and no new UI. Rejected reusing `data_access_log` (it is purpose-built
for data access: `report_run_id` is NOT-NULL and `event`/`source`/`data_type` are hard-locked
allowlists; a revoke has no report run, so it does not fit without invasively loosening a REPORT-74
table and muddying its meaning). Rejected a dedicated `token_events` table (C) as over-built: a
token has exactly one terminal revocation, nothing in this story displays a lifecycle feed, and
create-event logging would add write points to REPORT-74's two mint paths for no in-scope benefit.
Creation events are **not** logged; a future "revocation history" admin page can build on
`revoked_by_user_id` if ever needed.

### RESOLVED: Can a user add/edit a label on an existing token?
**Context**: Labels are currently set only at mint time (and are optional). A user staring at an
unlabeled token they can't identify might want to *rename* it rather than revoke-and-remint. But
allowing edits adds a form/mutation surface and validation.
**Options considered**:
- A) **No** — labels are mint-time only (out of scope); unidentifiable tokens are handled by
  revoking them (the safe default the story is built around).
- B) **Yes** — allow inline label edit on the list (a small mutation + test).

**Decision**: **A — no; labels stay mint-time only (out of scope).** Label editing does not serve
the story's forgotten-token goal: if you have forgotten what a token is, renaming it cannot recover
that knowledge — you can only meaningfully label a token you already recognize, so editing is a
minor convenience for the "forgot to type a label at mint" case, and the intended remedy for an
unrecognized token is revoke-and-remint. It would also introduce the app's first inline-edit
pattern (new UI + mutation + test) for that marginal benefit. Cheap to add later
(`ApiToken.changeset/2` already casts `:label`) if unlabeled-token annoyance shows up in practice.

### RESOLVED: Beyond label/created/last-used, what columns/formatting does a row need?
**Context**: The raw token is unshowable, so users identify tokens by label + timestamps. Questions:
should we show a non-secret **token id** (the DB id) as a stable handle (e.g. to correlate with an
admin's view or a support request)? Should timestamps be **absolute UTC** (like the audit-log page's
`YYYY-MM-DD HH:MM UTC`) or **relative** ("3 days ago") — or both (relative with an absolute
`title`/`<time datetime>`)? Should the current session's own token be flagged (N/A — the web session
is cookie-based, not token-based, so there is no "this token is me" on the web).
**Options considered**:
- A) Columns: Label, Created, Last used, (Revoke). Absolute UTC timestamps matching the audit-log
  page. No id column.
- B) As A, plus a token **id** column for cross-referencing.
- C) As A/B but timestamps rendered **relative** with an absolute `<time datetime>`/title tooltip.

**Decision**: **A — Label, Created, Last used, (Revoke); absolute UTC; no id column.** The admin
view adds a leading **User** column rendering **name + email** (`First Last (email)`) like the
audit-log page — deliberately *not* the run list's name-only `include_user`, since this view exists
to offboard a departed researcher and two researchers can share a name, so email is the reliable
identifier. Timestamps render
absolute UTC via `<time datetime="…">YYYY-MM-DD HH:MM UTC</time>` exactly like the audit-log page
(accessible, precise, consistent with the sibling audit surface, no component changes);
`last_used_at == nil` renders **"Never used"**. No id **column** — researchers identify by label +
last-used, a bare DB id is techy, and there is no token detail page to link to. (The DB id **does**
appear in the revoke confirmation string / button accessible name as a guaranteed-unique
disambiguator — see Requirements → Accessibility — since label + created + last-used are not a unique
key; that is a hidden-in-the-confirm use, not a visible column, so it does not conflict with this
decision.) Relative time (C)
was rejected only because the existing `relative_time` component caps at days and lacks a
`<time datetime>` wrapper, so it is not accessible/precise enough for a security surface as-is
(revisit if that component is enhanced). No "this token is me" flag — the web session is
cookie-based, not token-based.

## Self-Review

### Senior Engineer

#### RESOLVED: Stale "Open Question" references and a route-name inconsistency left by the decisions
_Fixed: the a11y bullet, the "Existing mint page" note, the route note (per-user →
`/reports/cli-token`, admin → `/reports/all-tokens`), and the Out-of-Scope logout line now read in
their resolved state._
Several spots still say "is an Open Question" now that all eight are resolved, and one route note
contradicts the merge decision:
- Accessibility bullet: "confirms destructive intent (mechanism is an Open Question)" — resolved
  (`data-confirm`, Q4).
- Technical Notes → "Existing mint page": "Whether this story merges … is an Open Question" —
  resolved (merge, Q1).
- Technical Notes → LiveView: `live "/tokens", ...` — but Q1 keeps the per-user page at
  `/reports/cli-token` (merged) and Q2 puts the admin page at `/reports/all-tokens`; there is no
  `/reports/tokens` route. Misleading.
- Out of Scope → CLI logout: "Whether the server-side endpoint … belongs here is an Open Question" —
  resolved (defer to REPORT-77, Q3).
Why it matters: internal contradictions make the spec untrustworthy to an implementer. Fix by
updating these to the resolved state.

#### RESOLVED: `revoke_api_token/1` signature change is a breaking change to a REPORT-74 function
Q6 adds an actor argument so revocation can stamp `revoked_by_user_id`. `revoke_api_token/1` already
exists and has callers/tests from REPORT-74. The spec should state the change is
backward-compatible (e.g. `revoke_api_token(token, revoked_by_user_id \\ nil)` or update all call
sites in the same commit) so existing behavior/tests don't silently break.
_Resolved: use the **required** 2-arg form `revoke_api_token(api_token, revoked_by_user_id)` (no
default, so no unattributed revokes); DB column nullable; the only two callers (both tests) are
updated in the same commit. Captured in Technical Notes → "`revoke_api_token` signature change"._

### Security Engineer

#### RESOLVED: The revoke **event handlers** must re-check authorization server-side, not just the mount gate
_Resolved (with a throwaway DB probe): the load-bearing control is the self-serve handler's
**ownership-scoped, active-only** fetch (verified: owner→row, other-user→nil, already-revoked→nil);
the admin handler re-asserts `portal_is_admin` as defense-in-depth. Captured under Requirements →
Revoke. My original finding overstated the admin re-check as required; corrected to defense-in-depth._

A mounted LiveView will process any event a client pushes, regardless of what the rendered UI
offers. Two concrete risks: (1) on the **self-serve** page, a `revoke` event must fetch the token
**ownership-scoped** (`get_user_api_token/2`) so a forged `phx-value` id for another user's token
is a no-op — never an unscoped `Repo.get`; (2) on the **admin** page, the `revoke` event handler
must re-assert `portal_is_admin` itself (a non-admin who reaches a mounted admin LiveView, or forges
the event, must be rejected in the handler), because the admin path intentionally uses the unscoped
`Repo.get(ApiToken, id)`. The spec states ownership-scoping for the self path but should make the
admin-path re-check explicit.

#### RESOLVED: Define the behavior when the targeted token is already revoked / gone (stale render)
_Resolved: benign no-op — re-render the refreshed list + an `:info` flash for both handlers.
Mechanism (nil fetch) verified by the same throwaway probe. **Superseded by the second-pass finding
below**: the flash cannot be truly "neutral" (`flash_group` has only `:info`/`:error`), so the final
wording is an `:info` flash "That token was already inactive". Captured under Requirements → Revoke._

Between render and click, the token may already be revoked (another browser tab, or an admin). The
handler should treat "not found / already revoked" as a benign no-op with a neutral message (e.g.
"That token is no longer active"), not a crash or a misleading success. The ownership/admin fetch
should therefore also account for a row that is already `revoked_at`-stamped. (The probe confirmed
`revoke_api_token/1` is idempotent-safe, but the UI contract should be stated.)

### QA Engineer

#### RESOLVED: Acceptance criteria omit the admin-revoke and attribution test cases
_Resolved: the Testing section now enumerates explicit acceptance criteria — self-revoke + IDOR
no-op, admin revoke + non-admin rejection, attribution stamping, stale no-op, "Never used"/empty/
pager rendering, and the a11y assertions._

The Testing section names the self-revoke authz test but not: (a) an admin **can** revoke another
user's token via the admin path; (b) a non-admin cannot (event-handler authz); (c) `revoked_by_user_id`
is stamped with the **owner's** id on self-revoke and the **admin's** id on admin-revoke; (d) the
"Never used" state and empty-state render; (e) the pager appears only past 25 rows in the admin
view. These are the story's highest-risk behaviors and should be explicit acceptance criteria.

### WCAG Accessibility Expert

#### RESOLVED: Table needs an accessible name, and the revoke control must be a real `<button>` with announced failure
_Resolved (markup verified): table accessible name via `<caption>`/`aria-label` is net-new (sibling
tables lack it); revoke is a `<button>` with a token-specific name; success and no-op both announce
through the existing `role="alert"` flash (both `:info` and `:error` kinds carry it). Captured under
Requirements → Accessibility._

The sibling audit-log table has `<th>`s but **no caption/`aria-label`**, so "follow the audit-log
pattern" would inherit that gap — this story explicitly requires a caption/label, so it must be
*added*, not copied. Also: the revoke control must be a `<button>` (keyboard-operable, correct AT
role), and **failure** of a revoke (the "already gone" path above) must be announced too, not just
success — the spec currently only commits to announcing success.

### Product Manager

#### RESOLVED: Admin **revoke** exceeds the ticket's "audit the same view" wording — reflect the expanded scope in the Jira story?
_Resolved: appended a Requirements bullet to REPORT-75's Jira description noting admin-revoke +
`revoked_by_user_id` attribution are in scope, and the `cc-data logout` endpoint is deferred to
REPORT-77 (ADF preserved, verified)._

The ticket lists "Admins can audit the same view" (visibility); Q2 deliberately added admin
**revoke** + accountability (`revoked_by_user_id`) as a rollout-safety measure. That is a defensible
expansion, but the REPORT-75 description does not mention it. We updated REPORT-77 for the deferred
logout endpoint; consider likewise noting on REPORT-75 that admin-revoke + revocation attribution
are now in scope, so the ticket matches the build.

### Researcher (end-user usability)

#### RESOLVED: Two unlabeled (or same-labeled) tokens are hard to tell apart at revoke time
_Resolved: the revoke confirmation + button accessible name must disambiguate even unlabeled/
same-labeled tokens by including label-or-"unlabeled" plus the created (and last-used) timestamps.
Captured under Requirements → Accessibility._

With no id column and identification by label + timestamps, a researcher with two blank-label tokens
used around the same time can't confidently pick the right one to revoke — and revoking the wrong
one silently breaks a machine still in use. Mitigations to consider: make the `data-confirm` text
include the **created** time (and label if present) so the confirmation disambiguates; and/or nudge
toward labeling at mint. Worth a requirement so the confirm text is unambiguous even for unlabeled
tokens.

---

## Self-Review (second pass — code-verified)

<!-- A second review pass in which each candidate issue was verified against the actual source
     (and, where empirical, a throwaway ExUnit probe run against the test DB, then deleted) before
     being written here. These surface contradictions between requirements and decisions added at
     different points of the first pass. -->

### Senior Engineer / Security Engineer

#### RESOLVED: Admin revoke fetch contradicts itself — "active-only" (Requirements) vs unscoped `Repo.get` (Q2)
_Resolved: the Q2 decision text now prescribes a cross-user **active-only** query
(`from t in ApiToken, where: t.id == ^id and is_nil(t.revoked_at)`) instead of `Repo.get`, so an
already-revoked id fetches as nil and hits the same benign no-op path as the self-serve handler —
consistent with the Requirements → Revoke admin bullet._

The Requirements section says the admin `revoke` handler "uses an **active-only** cross-user fetch"
(Requirements → Revoke, the admin bullet), but the Q2 decision rationale says "an **unscoped
`Repo.get(ApiToken, id)`** is the natural admin-revoke fetch." These are mutually exclusive.
**Verified** with a throwaway ExUnit probe against the test DB: `Repo.get(ApiToken, id)` returns a
token whose `revoked_at` is already stamped (the row is still returned, not nil). Consequence: if the
admin handler uses `Repo.get`, the "already-revoked → fetches as nil → benign no-op" contract
(Requirements → Revoke, explicitly *"Applies to both the self-serve and admin handlers"*) **cannot
hold on the admin path** — an already-revoked token comes back as a live row, so the handler would
re-revoke it and flash success instead of the benign no-op. Resolution: the admin fetch must be an
explicit active-only query (`WHERE id = ? AND revoked_at IS NULL`), mirroring the self-serve fetch;
correct the stale Q2 rationale to match.

### Security Engineer

#### RESOLVED: Self-serve "active-only" fetch is marked ✓ but the probe never exercised the `revoked_at` clause
_Resolved: kept the ✓ (ownership scoping was genuinely proven) but tightened what it certifies —
probe note #4 now states it proved ownership only, the handler fetch `get_user_api_token/2` is pinned
to a real `is_nil(revoked_at)` query (not `Repo.get_by/2`), and the active-set exclusion is noted as
covered by probe #5._

Requirements → Revoke marks ✓ the ownership-scoped **and active-only** fetch
(`WHERE id = ? AND user_id = <caller> AND revoked_at IS NULL`), but the probe that earned the ✓
(Technical Notes → "Assumptions verified" #4) was `Repo.get_by(ApiToken, id: id, user_id: user.id)`
— which has **no `revoked_at` filter**. **Verified**: that `get_by` returns an already-revoked row.
So the *ownership* dimension was proven but the *active-only* dimension — the part the stale/no-op
contract depends on — was **not**, despite the ✓. Resolution: specify the self-serve fetch as a real
query with `is_nil(revoked_at)` (not `Repo.get_by/2`), and either re-scope or footnote the ✓ so it
does not overclaim what the probe covered.

### WCAG Accessibility Expert / Product

#### RESOLVED: The required "neutral" flash is not achievable with the existing flash component
_Resolved (option A — reword to an `:info` flash): the no-op is now specified as an `:info` flash
worded for the satisfied end-state, "That token was already inactive," and the spec no longer claims
a "neutral" flash anywhere. Requirements → Revoke, Requirements → Accessibility, and the Testing
bullet were updated; the first-pass Security "stale render" resolution was annotated as superseded.
The `flash_group` two-kind constraint is called out so no implementer expects a neutral kind._

Requirements → Revoke and Requirements → Accessibility require the already-revoked no-op to surface a
**neutral** flash — *"neither a 'Token revoked' success nor an error."* **Verified** by rendering
`flash_group/1`: the component hardcodes exactly two kinds — `:info` (title **"Success!"**, green) and
`:error` (title **"Error!"**, red). `put_flash(:info, "That token is no longer active")` therefore
renders under a green **"Success!"** banner (contradicts "not a success") and `:error` renders under a
red **"Error!"** banner (contradicts "not an error"). The Accessibility bullet conflates *announcement*
(true — `role="alert"` fires for both kinds) with *neutral semantics* (impossible without a new kind).
Resolution (product decision needed): (a) accept the no-op as an `:info` flash and reword to fit
("Success!"-framed, e.g. "That token was already inactive"); (b) accept it as `:error`; or (c) add a
neutral flash kind to `flash_group` (a larger change the spec currently says is *not* needed). Update
the requirement to name the chosen mechanism instead of asserting an unachievable "neutral" flash.

### Product Manager / Researcher (end-user usability)

#### RESOLVED: Admin "User" column (name-only) is too weak for the offboarding use case it exists for
_Resolved: the admin User column now renders **name + email** (`First Last (email)`), matching the
audit-log page it is modeled on rather than the run list's name-only `include_user`. Updated in the
Columns bullet and the Q7 decision._

The admin view's User column is specced to mirror the run list's `include_user`, which renders **name
only** (`custom_components.ex` `report_runs/1`: `portal_first_name` + `portal_last_name`). But the
admin view's justification (Q2) is *offboarding a departed researcher*, and it claims to mirror the
**audit-log page** (Requirements → Admin audit view), which renders name **+ email**
(`audit_log_live/index.html.heex`). **Verified** by reading both templates. Two researchers with the
same name make the admin unable to tell whose token to revoke — the same disambiguation principle the
first pass applied to the per-user revoke confirm (Researcher review above) but did not apply to the
admin list's *user* identification. Resolution: the admin User column should include the email (like
the audit-log sibling it claims to mirror), not just the name.

---

## Self-Review (third pass — code-verified, merged-page mutating behavior)

<!-- Each candidate below was chased into the actual source (and existing tests) before being
     written here; several other candidates were investigated and DISMISSED with evidence (listed at
     the end) rather than recorded as issues. This pass focused on the *mutating* behavior of the
     merged self-serve page and the admin page, which the first two (largely read-only-focused)
     passes did not exercise. Playwright was not used: findings #1–#2 concern behavior of a page that
     does not exist yet, so there is nothing running to drive. -->

### QA Engineer / Senior Engineer

#### RESOLVED: Q1's "just-minted token appears in the list" is unstated as a requirement, untested, and does not happen for free
_Resolved: added Requirements → Token list "**Live refresh after mint**" bullet (the `generate`
handler must re-load the list assign after `create_api_token/2`) and a Testing acceptance criterion
"**Mint refreshes the list**"._

Q1's decision rationale sells the merge with *"a just-minted token appears in the list immediately
below the shown-once value."* **Verified** against `cli_token.ex:17-30`: the `generate` handler
assigns **only** `:raw_token` and touches no list assign. Because `mount/3` runs once, a list
assigned only at mount is stale after the `generate` event — so a naive implementation shows the new
token **only after navigate/reload**, silently violating Q1's headline benefit. The behavior was
neither stated as a Requirement nor covered by the Testing section (which only required the *existing*
`cli_token_live_test.exs` shown-once tests to keep passing). Resolution: make the post-mint list
refresh an explicit requirement and add a test.

### QA Engineer

#### RESOLVED: Admin revoke of the last token on the last page — page-clamp/re-render behavior was undefined and untested
_Resolved: added Requirements → Admin audit view "**Revoke-and-repaginate**" bullet and a Testing
acceptance criterion "**Admin revoke-and-repaginate**"._

**Verified** against `pagination.ex:10-27`, `audit_log_live/index.ex`, and the spec's `phx-click`
revoke model: the admin list pages via `handle_params`→`Pagination.paginate`, but revoke is a
`handle_event`. Revoking the only row on the last page shrinks `total_pages`; unless the revoke
handler re-paginates and reassigns `@page` from `result.page` (the way `handle_params` does), the
pager can render an empty page N. `Pagination.paginate` clamps `page = min(page, total_pages)` so
there is no crash, but this is the app's first *mutating paginated* view and the post-revoke page was
left undefined. Resolution: specify that the revoke handler re-paginates and reassigns page state
(or `push_patch`es through the same clamp), and test the last-row-on-last-page case.

### Product Manager / Researcher (end-user usability)

#### RESOLVED: Merged-page empty-state copy told the user to "create one" when the create form is already on the page
_Resolved: reworded the Empty state bullet — the merged page shows "You have no active tokens yet."
(the generate form above **is** the create path), while the admin page keeps a self-contained "No
active tokens." message._

**Verified** against `cli_token.html.heex`: the generate form always renders on the merged page. The
original empty-state requirement — *"a clear 'no active tokens' message (with a path to create one)"*
— was written for a standalone list page; on the merged page the "path to create one" is redundant
with the form directly above. Minor wording fix; the admin page (no form) keeps its standalone empty
state.

### Candidates investigated and DISMISSED (verification evidence)

These were reviewed and traced into the source but are **not** issues — recorded so the diligence is
auditable:

- **`revoked_by_user_id` FK actor validity** — concern: the stamped actor might be a portal id, not a
  `users.id`. Dismissed: `auth_controller.ex:35-37` shows `session["user"]` is the local
  `%Accounts.User{}` returned by `find_or_create_user`, so `@user.id` is a valid `users.id` FK target.
- **"Only two callers of `revoke_api_token`, both tests"** — verified accurate: `grep` finds exactly
  `test/report_server_web/api/auth_plug_test.exs:34` and `test/report_server/accounts_test.exs:86`
  plus the definition. The required 2-arg signature change is safe.
- **`data-confirm` wiring** — verified: `assets/js/app.ts` imports `phoenix_html` and builds a
  `LiveSocket`, so native `data-confirm` fires; the accessible-confirm plan (Q4) holds.
- **`flash_group` two-kind constraint** — verified: `core_components.ex:147-151` hardcodes
  `:info`→"Success!" and `:error`→"Error!", both `role="alert"`; the `:info`-worded no-op decision is
  correct.
- **Admin paginated preload query** — verified: `Pagination.paginate` strips `:preload`/`:order_by`
  for the count, so an `is_nil(revoked_at)` + `order_by desc` + `preload: [:user]` admin query
  behaves exactly like `AuditLog.list_entries_paginated`. Feasible as specced.

---

## Self-Review (fourth pass — DBA/DevOps lens + fresh Sec/QA/a11y, code+probe verified)

<!-- This pass applies a DevOps/DBA perspective the first three passes never used, plus a fresh
     Senior/Security/QA/WCAG re-read against the real source. Every candidate below was chased into
     the actual code before being written; the pagination finding was additionally exercised with a
     throwaway ExUnit probe against the MySQL test DB (then deleted). Candidates that survived
     verification are recorded as OPEN; candidates that were investigated and did NOT hold are listed
     under "DISMISSED" with evidence, so the diligence is auditable. -->

### DBA / DevOps  ·  Senior Engineer

#### RESOLVED: The admin paginated list has no stable total order — `ORDER BY inserted_at` alone is not unique
_Resolved (recommendation applied): the admin query now orders by `[desc: inserted_at, desc: id]` — a
unique total-order tiebreaker — captured in Requirements → Admin audit view ("Stable pagination
order" bullet) and Technical Notes → Pagination, with a Testing acceptance criterion ("Stable admin
pagination order"). The missing supporting index is recorded as a negligible-at-this-volume note, not
a change. The per-user list stays `[desc: inserted_at]` (unpaginated → a tie is cosmetic, never a
skip)._
The admin list is specced to page via `Pagination.paginate` over
`from t in ApiToken, where: is_nil(t.revoked_at), order_by: [desc: t.inserted_at], preload: [:user]`
— the third pass verified this is *feasible* (count strips `:order_by`/`:preload`) but not that the
order is *stable*. **Verified with a throwaway ExUnit probe against the MySQL test DB**: `inserted_at`
is a second-granularity `:utc_datetime`, and 30 tokens minted rapidly collapsed to **one distinct
`inserted_at` value** — so the sort key is genuinely non-unique. `Pagination.paginate` issues page 1
and page 2 as two **independent** `LIMIT/OFFSET` queries that share no tiebreaker, so MySQL is free to
order the tied rows differently between them; a tie that straddles the 25/26 boundary can then be
**duplicated onto both pages or skipped from both**. (Honesty note: on the probe run MySQL 8 happened
to return the ties in a consistent order — I could **not** force an actual dup/skip this run — so the
defect is *latent/implementation-defined*, not reliably reproducible; the guarantee is simply absent.)
The same probe proved that adding the primary key as a tiebreaker —
`order_by: [desc: t.inserted_at, desc: t.id]` — restores a genuine total order (no dup, no skip across
pages). The admin view is the one place this matters (it is the only *paginated* token list, and it
exists to reliably enumerate a departed researcher's tokens for revocation, where a silently-skipped
row = a token that never gets killed). The pattern is inherited from the audit-log page, which shares
the latent issue but is lower-stakes (append-only, and no security action hangs on completeness).
**Suggested resolution**: specify the admin list's `order_by` as `[desc: inserted_at, desc: id]` (a
unique tiebreaker), and add a test asserting all rows appear exactly once across pages when many
tokens share an `inserted_at`. *(Sub-point, DBA:* the supporting index is also absent — the
`api_tokens` migration indexes only `token_hash` (unique) and `user_id`, so
`WHERE revoked_at IS NULL ORDER BY inserted_at, id` is a scan + filesort. **Negligible** at this
story's token volumes (≈one per researcher-machine) and explicitly not a blocker; worth at most a
one-line "revisit with a composite index if the table grows" note, or folding a
`(revoked_at, inserted_at, id)` index into the same migration since one is already being added for
`revoked_by_user_id`.)*

### QA Engineer

#### RESOLVED: Acceptance criteria verify revoke-IDOR but never assert list-level isolation at the view layer
_Resolved: added a Testing acceptance criterion "List isolation (view layer)" — a two-user LiveView
assertion that the self-serve render contains only the caller's tokens — complementing the existing
revoke-IDOR test._
The Testing section covers the **IDOR no-op** on *revoke* (a forged id can't kill another user's
token) and the context-layer probe (#1) proved the *query* `WHERE user_id = ? AND revoked_at IS NULL`
doesn't leak. But there is **no acceptance criterion that the rendered self-serve list shows only the
caller's tokens** — i.e. that user A, mounting the merged page while user B also has active tokens,
sees A's rows and not B's. The list is the story's primary surface and its tenant-isolation is
currently only asserted one layer below the thing users actually see (the LiveView could, e.g., call
an unscoped list function and no test would catch it). **Suggested resolution**: add a Testing
acceptance criterion — "the self-serve list renders only the signed-in user's active tokens (a second
user's active token is absent from the render)" — a cheap two-user LiveView assertion that pins the
isolation at the view boundary, complementing the existing revoke-IDOR test.

### Senior Engineer  ·  QA (minor)

#### RESOLVED: Merged page — a revoke click must not clobber the shown-once `@raw_token` value mid-copy
_Resolved: the "Live refresh after mint" bullet now states the `revoke` handler must preserve
`@raw_token` (reassign only list + flash), and the mint-refresh Testing criterion gains an assertion
that a subsequent revoke does not blank the shown-once value._
On the merged page a just-minted token is displayed once via `@raw_token` (the generate form hides
while it shows — `:if={@raw_token == nil}` in `cli_token.html.heex`). The "Live refresh after mint"
requirement covers mint→list, but not the **inverse interaction**: while that shown-once value is on
screen, the freshly-minted token also appears in the list below, so the user can click **Revoke** on
some *other* (old) row without navigating away. The new `revoke` `handle_event` must reassign only the
list + flash and **leave `@raw_token` untouched**; a naive handler that rebuilds socket assigns could
drop the shown-once value the user is still copying. Low severity (narrow window, and the value is
regenerable), but it is an un-stated contract on the app's first **destructive** LiveView action on a
page that also holds unrecoverable one-time state. **Suggested resolution**: one sentence in the "Live
refresh after mint" bullet — "the `revoke` handler preserves `@raw_token`" — and an assertion in the
mint-refresh test that a subsequent revoke does not blank the displayed value.

### Candidates investigated and DISMISSED (verification evidence)

- **Security — self-serve vs admin handler cross-contamination** — concern: could a self-serve user
  reach the admin revoke path? Dismissed: the self-serve list+revoke lives on `ReportLive.CliToken`
  (no admin gate — correct, gated only by `can_access_reports?`) and the admin list+revoke is a
  **separate** `portal_is_admin`-gated LiveView; they are distinct modules with distinct
  `handle_event`s, so there is no shared handler to confuse. The ownership-scoped self fetch +
  admin-handler `portal_is_admin` re-check (already specced) is sound. No new issue.
- **WCAG — pager label collision / table naming on the admin page** — dismissed: the a11y section
  already requires a net-new table accessible name and a token-specific revoke-button name, and the
  admin page mirrors the audit-log pager which already uses unique `"pagination top"`/`"pagination
  bottom"` labels (`audit_log_live/index.html.heex`). Section holds; no new finding.
- **DBA — `revoked_by_user_id` FK `on_delete`** — dismissed: the spec's `references(:users,
  on_delete: :nothing)` matches the existing `user_id` FK on `api_tokens` (verified in
  `20260713080000_create_api_tokens.exs`), so the new column is consistent with the table's
  established delete semantics; nullable is correct for historical/manual revokes.

---

## External Review (round 1 — code-verified before applying)

<!-- Findings supplied by an external reviewer (fresh-context LLM read). Each was re-verified against
     the real source before applying — consistent with the discipline used in the self-review passes.
     All three held; all three applied. -->

### RESOLVED [MEDIUM]: Revoke API signature was contradictory (`/1` "reused as-is" vs the required 2-arg form)
_Verified: `accounts.ex:106-110` currently defines only `revoke_api_token/1`, and several normative
spots still said "reuse `revoke_api_token/1`" / "reused as-is," contradicting the RESOLVED decision to
move to the **required** two-arg `revoke_api_token(api_token, revoked_by_user_id)`. An implementer
following the `/1` refs could ship revocation without stamping `revoked_by_user_id`._
_Applied: corrected the normative references (Requirements → Revoke immediacy + admin bullet;
Technical Notes → Context; Q2 and Q6 decisions) to name the two-arg form. Left genuinely pre-story /
probe / self-review-history references to `/1` intact (they describe the function REPORT-74 shipped or
the probe that ran against it), and line 335's "reused as-is" (which refers to the `/reports/cli-token`
**page**, not the function)._

### RESOLVED [MEDIUM]: "Unambiguous" revoke confirmation was not actually guaranteed
_Verified (and independently proven by the pass-four probe): `inserted_at` is second-granularity and
rapidly-minted tokens collapse to one value; `create_api_token/2` permits repeated unlabeled/
same-label tokens; never-used rows share `last_used_at == nil`. So two unlabeled tokens minted in the
same second are **identical** under label + created + last-used — the confirm text could describe both
active rows, and a user could revoke the wrong machine's token despite the "unambiguous" requirement._
_Applied: the revoke confirmation / button accessible name now also includes the token's **non-secret
DB id** as a guaranteed-unique discriminator (Requirements → Accessibility), with a Testing
acceptance criterion ("Confirmation disambiguation"). Reconciled with Q7: the id appears only in the
confirm string / accessible name, **not** as a visible table column (Q7's actual objection), so no
conflict — correctness of a destructive action outweighs table tidiness. The admin confirmation
carries the same id (a single user's two same-second unlabeled tokens collide there too)._

### RESOLVED [LOW]: "First mutating reports LiveView action" was inaccurate
_Verified: `cli_token.ex:17` (`generate` mints a token) and `report_live/form.ex:214` (`submit_form`
creates a report run) are both already-mutating LiveView events, so "first mutating" is false._
_Applied: reworded to "first **destructive**, in-place LiveView action" (revoke → row disappears in
the same render) in Technical Notes → Revoke interaction, the Testing preamble, and the pass-four
self-review note; added pointers to the existing mutating-event test patterns
(`cli_token_live_test.exs`, `report_live_test.exs`) as precedent for implementers._

---

## External Review (round 2 — code-verified before applying)

<!-- A second external round (Senior/Security/QA). Both findings were chased into the real source
     before applying; the HIGH finding is corroborated by an in-module precedent. Both held; both
     applied. -->

### RESOLVED [HIGH]: Revocation was not atomic — concurrent revokes could overwrite accountability
_Verified: the proposed `revoke_api_token/2` did a fetch-then-unconditional-`Repo.update()`
(implementation.md), so two concurrent handlers (two tabs, or self+admin) could both fetch the token
active and the later write could overwrite `revoked_by_user_id`, making "who killed this token"
non-deterministic and letting a second racing revoke re-stamp an already-revoked row. Corroborated by
a direct precedent in the same module: `Accounts.exchange_auth_grant/2` (`accounts.ex:154-182`) already
uses an atomic conditional `Repo.update_all` and checks the `{1,_}` affected-count "so concurrent
duplicates cannot both mint" (its own docstring); `athena_run_ops.ex:57` uses the same claim pattern.
MySQL/MyXQL (confirmed adapter) has no `RETURNING`, matching how `exchange_auth_grant` re-fetches._
_Applied: `revoke_api_token/2` is now an atomic conditional write —
`Repo.update_all(where id == ^id and is_nil(revoked_at), set: [revoked_at, revoked_by_user_id,
updated_at])` returning `{:ok, reloaded}` on `{1,_}` and `{:error, :already_revoked}` on `{0,_}` —
making revocation **first-writer-wins**; the loser overwrites nothing and its handler folds
`{:error, :already_revoked}` into the existing benign "That token was already inactive" no-op (both
handlers updated). Added a context acceptance criterion + test proving a second (stale-struct) revoke
returns `{:error, :already_revoked}` and leaves the original `revoked_by_user_id` unchanged. Captured in
Requirements → Revocation accountability ("first-writer-wins" bullet), Revoke immediacy, Technical Notes
→ signature-change note, and the Testing section._

### RESOLVED [MEDIUM]: Revoking the just-minted row left its now-dead raw token visible
_Verified: the `generate` handler assigned only `:raw_token` and discarded the created `%ApiToken{}`
(implementation.md), while the just-minted token also renders as a list row **with a Revoke button**
(Q1's live-refresh) and the `revoke` handler preserved `@raw_token` **unconditionally** (the pass-four
"preserve the value mid-copy" rule). So revoking the just-minted row removed it from the list but left
`"Your new token: ccd_…"` shown and copyable — a revoked token presented as usable._
_Applied: `generate` now records the minted id in `@raw_token_id`; the `revoke` handler clears
`@raw_token`/`@raw_token_id` **only** when the revoked id matches the shown-once id (via a
`clear_shown_once_if/2` helper), and still preserves the value when revoking any other row. Added a
LiveView test asserting that revoking the just-minted row clears the shown-once panel
(`refute html =~ "ccd_"`). Captured in Requirements → Token list ("Live refresh after mint" exception)
and the Testing section, alongside the existing preserve-on-other-row assertion._

---

## External Review (round 3 — code-verified before applying)

<!-- A third external round (Senior/Security/QA) against requirements.md. The single finding held on
     verification and was applied. -->

### RESOLVED [MEDIUM]: The deferred REPORT-77 logout prerequisite still pointed at the removed, unattributed `revoke_api_token/1`
_Verified: the Q3 deferral's "Known prerequisite recorded for STORY 4" said the logout endpoint "then
revokes via `revoke_api_token/1`", but this story **removes** the one-arg form in favor of the required
two-arg `revoke_api_token(api_token, revoked_by_user_id)` (requirements.md → Technical Notes
signature-change note). Confirmed against the real source: `Api.AuthPlug` verifies and holds the
`api_token` (`auth_plug.ex:12`) but assigns only `:current_user` (`auth_plug.ex:15`), and
`revoke_api_token/1` still exists at `accounts.ex:106` **today** — but will not after this story. An
implementer following the note post-merge would call a removed function, or reintroduce an
unattributed revoke path, violating the accountability requirement._
_Applied: rewrote the prerequisite to name the two-arg `revoke_api_token(api_token,
revoked_by_user_id)`, passing the token struct the plug must expose plus the authenticated
`current_user.id` as the actor; noted that `cc-data logout` is a **self-revoke**, so this attributes to
the token owner and keeps the endpoint on the same accountability path as the UI. (Follow-up: the
REPORT-77 ticket note should be updated to match — see the summary; not auto-edited here.)_

---
