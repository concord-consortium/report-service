# cc-data: Token-Management UI

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-75

**Status**: **Closed**

## Overview

Give researchers a self-serve page that lists all of their active `cc-data` CLI access tokens — each
with its label, creation date, and last-used time — and lets them revoke any token, with a
confirmation that names the exact token so the wrong machine is never cut off. The existing
generate-a-token page (`/reports/cli-token`) is extended into this page, so a just-minted token
appears in the list immediately below its shown-once value. A parallel admin-only view lists every
user's active tokens and lets an admin revoke a departed researcher's token without database access.

This is the user-visible "see them and kill them" half of the non-expiring token model from
REPORT-74, and a prerequisite for handing the `cc-data` CLI to researchers outside the team.
REPORT-74 deliberately traded token expiry for control-via-revocation; that trade-off only holds if a
user can *see* the tokens they have minted and *kill* the ones they no longer recognize, and if the
team can cut off a departed researcher who can no longer self-revoke. This story delivers that,
plus per-revocation accountability (**who** revoked) and race-safe revocation.

## Requirements

### Token list (per-user)

- The token-management page lists **all of the signed-in user's active (non-revoked) tokens**,
  newest-first, showing at minimum the optional **label**, **created** date (`inserted_at`), and
  **last used** time (`last_used_at`).
- A never-used token renders a clear **"Never used"** state rather than a blank cell.
- The **raw token value is never shown** — it is unrecoverable (only the SHA-256 hash is stored);
  rows are identified by label + created + last-used.
- **Empty state**: a user with no active tokens sees "You have no active tokens yet." (no "create
  one" CTA — the generate form is already above the list). The admin page's empty state is the
  self-contained "No active tokens."
- **Live refresh after mint**: a token minted via the generate form appears in the active-token list
  in the **same LiveView render**, immediately below the shown-once value (the `generate` handler
  re-loads the list assign after a successful mint). The `revoke` handler **preserves `@raw_token`**
  when revoking a *different* row, but **clears the shown-once panel** when the revoked id **is** the
  just-minted token (a revoked token must not remain on screen as if usable).
- **Columns**: Label, Created, Last used, (Revoke). Timestamps render **absolute UTC** via
  `<time datetime="…">YYYY-MM-DD HH:MM UTC</time>`, matching the audit-log page. No token-id column.
- **Pagination**: the per-user self-serve list is **unpaginated** (a user's active tokens are
  naturally bounded, ~one per machine). Only the admin global list is paginated (25/page).

### Revoke

- The user can revoke any token in their list. Revocation is **immediate** (stamps `revoked_at`,
  which `verify_api_token/1` already filters on) and affects **only the targeted token**.
- **Server-side authorization is the primary control**: the self-serve `revoke` handler fetches the
  token **ownership-scoped and active-only** (`WHERE id = ? AND user_id = <caller> AND revoked_at IS
  NULL`); a forged/other-user or already-revoked id fetches as **nil** and is a benign no-op — never
  a cross-user revoke or a crash. This is the load-bearing IDOR guard (the page is mounted for all
  report users). Uses a real query (`get_user_api_token/2`), **not** `Repo.get_by/2` (which is not
  `revoked_at`-filtered).
- Revoke is guarded by a `data-confirm` confirmation naming the specific token; on confirm the token
  **disappears from the active list** and an `:info` flash (`role="alert"`) announces "Token revoked".
- **Already-revoked / stale-render no-op**: a `revoke` whose target fetches as nil (revoked in
  another tab/by an admin, or absent) is a benign no-op — the handler re-renders the refreshed list
  and shows an `:info` flash worded for the benign end-state ("That token was already inactive"),
  deliberately **not** an `:error`. (The app's `flash_group` supports only `:info`/`:error`; the
  no-op is worded to read correctly under the green "Success!" frame.)

### Admin audit view

- A `portal_is_admin`-gated page (`/reports/all-tokens`, mirroring `/reports/all-runs`) lists **all
  users' active tokens** — a global list with a **User** column (name + email, `First Last (email)`)
  plus label, created, last-used — paginated 25/page, newest-first. The admin `revoke` handler
  re-asserts `portal_is_admin` as defense-in-depth.
- **Stable pagination order**: the admin query orders by **`[desc: inserted_at, desc: id]`** — a
  total order, since `inserted_at` is second-granularity and multiple tokens can share one value, so
  a bare `[desc: inserted_at]` could duplicate or skip a tie across a page boundary.
- Admins can **revoke any user's token** (offboarding a departed researcher without DB access).
- **Revoke-and-repaginate**: the revoke handler re-runs the paginated query and reassigns
  `@page`/`@total_pages`/items from the `Pagination.paginate` result (which clamps
  `page = min(page, total_pages)`), so revoking the last row on the last page lands the admin on a
  valid page, never an empty page N.

### Revocation accountability

- Every revocation records **who performed it** via a nullable `revoked_by_user_id` FK column on
  `api_tokens` (self-revoke → owner's id; admin-revoke → admin's id). No lifecycle *create* events
  are logged, and `data_access_log` is **not** reused (it is data-access-only and structurally
  rejects a run-less event).
- **Race-safe (first-writer-wins)**: revocation is an **atomic conditional write**
  (`UPDATE … WHERE id = ? AND revoked_at IS NULL`, checking the affected-row count), not a
  fetch-then-unconditional-update. In a concurrent self/admin or two-tab race, only the first write
  matches and stamps `revoked_by_user_id`; the loser matches 0 rows, overwrites nothing, and its
  handler treats `{:error, :already_revoked}` as the same benign no-op. Mirrors the exactly-once idiom
  in `Accounts.exchange_auth_grant/2`.

### Access control / navigation

- Pages live under the existing `:reports` `live_session`, gated by `can_access_reports?` (portal
  admin || project admin || project researcher). The admin view additionally requires
  `portal_is_admin`.
- The reports home gains three `described_link`s: **"CLI Access Tokens"** (all report users → merged
  token page), **"All CLI Tokens"** (admins → admin audit view), and **"Data Access Log"** (admins →
  the previously-orphaned `/reports/audit-log`).

### Accessibility

- The token table uses proper `<th>` headers **and** an accessible name via `<caption>` (may be
  `sr-only`) or `aria-label` — net-new here (the sibling audit-log/run tables have neither).
- The revoke control is a real `<button>` with an accessible name identifying **which** token it
  revokes, confirming destructive intent via `data-confirm`. The confirmation / accessible name
  identifies the token **unambiguously even when unlabeled or sharing a label** by including the
  label (else "unlabeled"), the created and last-used timestamps, **and the token's non-secret DB
  id** as a guaranteed-unique discriminator — since label + created + last-used are not a unique key
  (second-granularity `inserted_at`; never-used rows all share `last_used_at == nil`). The id appears
  only in the confirm string / accessible name, **not** as a visible column.
- Both the success and already-inactive outcomes surface through the existing `flash_group`
  (`role="alert"`), so both are announced to AT with no custom live region. New UI follows the app's
  Tailwind styles and maintains WCAG AA contrast.

## Technical Notes

- **Context** (`ReportServer.Accounts`): added `list_active_api_tokens/1`, an ownership-scoped
  active-only `get_user_api_token/2` for revoke-by-id, and a cross-user paginated
  `list_all_active_api_tokens/1` for the admin view.
- **`revoke_api_token` signature change**: the pre-story `revoke_api_token/1` becomes
  `revoke_api_token(api_token, revoked_by_user_id)` with the actor **required** (no default), so no
  path can produce a silently-unattributed revoke. Its body changed from fetch-then-`Repo.update()`
  to an atomic conditional `Repo.update_all` (`WHERE … revoked_at IS NULL`), returning
  `{:ok, reloaded}` on `{1,_}` and `{:error, :already_revoked}` on `{0,_}`. The two existing callers
  (both tests) were updated to the 2-arg form in the same change.
- **Schema/migration**: one migration adds the nullable `revoked_by_user_id` FK
  (`references(:users, on_delete: :nothing)`), plus a schema `belongs_to` and changeset inclusion.
  No other schema change was needed (all display columns already existed).
- **LiveView / routes**: the per-user list+revoke is **merged into** `ReportLive.CliToken` at
  `/reports/cli-token` (heading "CLI Access Tokens"), preserving its shown-once contract; the admin
  view is a new `portal_is_admin`-gated route modeled on `AuditLogLive.Index`. This is the app's
  first **destructive, in-place** LiveView action, so its authz-scoped fetch and re-render path carry
  focused tests.
- **Pagination**: the admin list reuses `ReportServer.Pagination` (offset, 25/page) and the
  `<.pager>` component; the self-serve list uses neither.

*Index note*: no index currently backs `WHERE revoked_at IS NULL ORDER BY inserted_at, id` —
negligible at this story's token volumes; revisit with a composite index only if the table grows.

## Out of Scope

- **Changing how tokens are minted** — the existing generate form + shown-once behavior is reused
  as-is; the `/auth/cli` loopback mint flow is untouched.
- **Editing an existing token's label** — labels stay mint-time only (RESOLVED Q7).
- **The Go CLI and its `cc-data logout` command** — STORY 4 / REPORT-77; the server-side endpoint a
  CLI logout would call is deferred there (RESOLVED Q3).
- **Answers/history bulk endpoints** — STORY 3.
- **Rate limiting / abuse protection** — future, per REPORT-74.
- **Changing the token model** (expiry, refresh, scopes) — stays non-expiring + revocable per the
  design doc.

## Not Yet Implemented

These were consciously accepted as v1 trade-offs during implementation self-review, not oversights:

- **Keyboard focus after a revoked row disappears** — the focused revoke `<button>` is inside the
  removed row, so focus falls back to `<body>`. The `role="alert"` flash is the load-bearing
  feedback and the list is short (~one row per machine). Revisit with focus-return to the table
  caption/heading if the list grows or feedback surfaces it.
- **Unlabeled-token cell renders a bare "—"** — cosmetic; the load-bearing identification is the
  revoke button's accessible name ("the unlabeled token … #id"). Not worth a special-case render for
  v1.
- **Stale URL query string after an admin revoke clamps the page** — when revoking the last row on
  the last page clamps `@page` 2→1, the rendered page and pager are correct but the address bar still
  reads `?page=2` until the next pager click or reload. The `push_patch` variant would also sync the
  URL and remains an equivalent option if URL fidelity is ever wanted.
- **Server-side `cc-data logout` endpoint** — deferred to STORY 4 / REPORT-77 (no consumer until the
  CLI exists). Recorded prerequisite: `Api.AuthPlug` currently assigns only `:current_user`, not the
  `api_token`, so the logout endpoint will need the plug to also expose the current token; it will
  then self-revoke via the two-arg `revoke_api_token/2` introduced by this story.

## Decisions

### Separate token-management page, or merge list/revoke into the existing `/reports/cli-token` page?
**Context**: REPORT-74 shipped `/reports/cli-token`, which mints a token and shows it once. This
story adds list + revoke. Merging gives a single page where a user generates a token, sees it once,
then sees it appear in the list below.
**Options considered**:
- A) **Merge** into one page: generate form + shown-once value + list-with-revoke together.
- B) **Separate** new page for list+revoke; leave `/reports/cli-token` as the generate page.

**Decision**: **A — merge** into the existing `ReportLive.CliToken` page (heading "CLI Access
Tokens"). A just-minted token appears in the list immediately below the shown-once value. Verified
low-risk: the URL has no external/CLI/doc dependencies (the CLI is STORY 4 and does not exist yet),
and the existing shown-once contract is preserved unchanged — the merge only adds a list section.

### What is the admin "audit the same view" — global list, per-user drill-down, and can admins revoke?
**Context**: The ticket says "Admins can audit the same view," without specifying a global list vs a
per-user drill-down, or whether admins can revoke.
**Options considered**:
- A) Global admin list of all active tokens, **view-only**, paginated — mirrors the audit-log page.
- B) Global admin list **plus admin revoke** of any user's token.
- C) Per-user drill-down (admin picks a user).

**Decision**: **B — global admin list + admin revoke** (`/reports/all-tokens`). This closes the
offboarding gap REPORT-74 documented: portal deprovisioning does not auto-cut API access and a
departed researcher cannot self-revoke, so without admin revoke the only cutoff path is still manual
DB/console — the very thing this story exists to eliminate. Chosen over view-only (A) because timely
cutoff of a departed researcher's non-expiring token is a real rollout requirement; over per-user
drill-down (C) because the global-list pattern already exists and needs no new navigation model.

### Is a server-side "revoke the calling token" endpoint (for `cc-data logout`) in scope here?
**Context**: The CLI (STORY 4 = REPORT-77) needs a server endpoint to revoke the token it holds.
REPORT-74 bucketed all CLI-facing work into STORY 4.
**Options considered**:
- A) **Out of scope** — STORY 4 adds whatever endpoint the CLI needs.
- B) **In scope** — add an authenticated endpoint that revokes the calling bearer token now.

**Decision**: **A — defer to STORY 4 (REPORT-77).** The endpoint has no consumer until the CLI
exists; shipping a consumer-less endpoint now is speculative. Recorded prerequisite for STORY 4:
`Api.AuthPlug` assigns only `:current_user` (not the `api_token`), so logout will need the plug to
expose the current token, then self-revoke via this story's two-arg `revoke_api_token/2` passing the
owner's id.

### Revoke confirmation UX, and do revoked tokens vanish immediately or linger?
**Context**: Revocation is destructive (recovery = re-mint + re-login the affected machine); guard
against accidental clicks. A revoked token would simply drop off the "active tokens" list.
**Options considered**:
- A) `data-confirm` + token removed from list on success + flash "Token revoked".
- B) Confirmation, then the row lingers visibly marked "Revoked" for the render.
- C) No confirmation — rely on the flash only.

**Decision**: **A — `data-confirm` + vanish + flash.** Native `window.confirm` is fully
keyboard/screen-reader accessible with no extra component, and its text names the specific token.
Chosen over the lingering "Revoked" row (B), which adds per-row session state contradicting the
"active tokens" list definition, and over no-confirmation (C) since a native confirm is a cheap,
accessible guard on a destructive action.

### Should this story add reports-home navigation to the token page (and the audit-log page)?
**Context**: `/reports/cli-token` and `/reports/audit-log` existed but had **no** links on the
reports home — reachable only by direct URL. A token page researchers can't find doesn't serve its
purpose.
**Options considered**:
- A) Add the token-page link(s) **and** opportunistically surface the orphaned audit-log link.
- B) Add only the token-page link(s) this story introduces.
- C) No navigation changes.

**Decision**: **A — add all three links** on the reports home via the existing `described_link`
component: "CLI Access Tokens" (all report users), "All CLI Tokens" (admins), and the
previously-orphaned "Data Access Log" (admins). The audit-log link is a trivial fix for a REPORT-74
orphan, and this story is already assembling the admin-tools cluster.

### Are token-lifecycle events (revoke, and/or create) audited anywhere?
**Context**: `data_access_log` records data access, not token lifecycle. There was no record of who
revoked or created which token — relevant once admins can revoke others' tokens.
**Options considered**:
- A) **No lifecycle logging** in v1.
- B) Log revocations (and maybe creations) with actor, token id, timestamp — new table or reuse of
  the audit log.

**Decision**: **B, minimal form — add a nullable `revoked_by_user_id` FK column to `api_tokens`**
(self-revoke → owner's id, admin-revoke → admin's id), and make `revoke_api_token/2` require the
actor. This closes exactly the accountability gap admin-revoke introduces (the row already records
`revoked_at`, the *when*) with a trivial migration, **no new table**, no new UI. Rejected reusing
`data_access_log` (its `report_run_id` is NOT-NULL and `event`/`source`/`data_type` are hard-locked
allowlists — a revoke has no run) and a dedicated `token_events` table (over-built: a token has one
terminal revocation and nothing displays a lifecycle feed). Creation events are not logged; a future
"revocation history" page can build on `revoked_by_user_id` if ever needed.

### Can a user add/edit a label on an existing token?
**Context**: Labels are set only at mint time. A user staring at an unlabeled token might want to
rename rather than revoke-and-remint, but edits add a form/mutation surface.
**Options considered**:
- A) **No** — labels are mint-time only; unidentifiable tokens are handled by revoking them.
- B) **Yes** — inline label edit on the list.

**Decision**: **A — no; labels stay mint-time only.** Renaming does not serve the forgotten-token
goal: if you have forgotten what a token is, renaming cannot recover that knowledge — you can only
meaningfully label a token you already recognize. It would also introduce the app's first inline-edit
pattern for marginal benefit. Cheap to add later (`ApiToken.changeset/2` already casts `:label`).

### Beyond label/created/last-used, what columns/formatting does a row need?
**Context**: Users identify tokens by label + timestamps. Should we show a non-secret DB **id**?
Absolute vs relative timestamps? Flag the current session's token?
**Options considered**:
- A) Columns Label, Created, Last used, (Revoke); absolute UTC; no id column.
- B) As A, plus a token **id** column.
- C) As A/B but relative timestamps ("3 days ago") with an absolute `<time datetime>` tooltip.

**Decision**: **A — Label, Created, Last used, (Revoke); absolute UTC; no id column.** The admin view
prepends a **User** column (name + email — deliberately not the run list's name-only, since two
researchers can share a name and this view exists to offboard a departed one). Timestamps render
absolute UTC via `<time datetime>` like the audit-log page; `last_used_at == nil` renders "Never
used". No id **column** (a bare DB id is techy and there is no token detail page) — the id appears
only in the revoke confirmation string / button accessible name as a guaranteed-unique disambiguator.
Relative time (C) was rejected only because the existing `relative_time` component caps at days and
lacks a `<time datetime>` wrapper. No "this token is me" flag — the web session is cookie-based, not
token-based.

### Testing the non-admin admin-revoke rejection (implementation)
**Context**: The acceptance criteria require that an admin `revoke` event pushed by a non-admin is
rejected by the handler (defense-in-depth), but `mount/3` redirects a non-admin, so
`LiveViewTest.live/2` never yields a live process to push the forged event from.
**Decision**: Added a direct-call unit test that builds a `%Phoenix.LiveView.Socket{}` with a
non-admin `@user`, asserts `AllTokensLive.Index.handle_event("revoke", %{"id" => "1"}, socket)`
returns `{:noreply, socket}`, and asserts the victim token still authenticates — pinning the
defense-in-depth clause against a refactor that drops it, without needing an integration path the
mount gate forbids.
