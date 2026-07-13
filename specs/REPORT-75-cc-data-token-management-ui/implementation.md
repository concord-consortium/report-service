# Implementation Plan: cc-data Token-Management UI

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-75
**Requirements Spec**: [requirements.md](requirements.md)
**Status**: **Ready for Implementation**

## Implementation Plan

The plan is six commits. The order is bottom-up so nothing has a forward dependency: the
schema/column lands first, then the context functions that use it, then the two LiveView pages that
call the context, then navigation. Tests are co-located with the code they exercise (context tests
in the context commit, self-serve LiveView tests in the self-serve commit, admin LiveView tests in
the admin commit) so every commit is independently shippable and green.

A shared `token_table` function component (and its confirm-text helper) is introduced in the
self-serve commit and reused by the admin commit — it is the single place the accessible table
markup, the "Never used" rendering, and the id-disambiguated revoke confirmation live, so the two
pages cannot drift.

---

### Add the `revoked_by_user_id` accountability column

**Summary**: Adds the one schema change this story needs — a nullable `revoked_by_user_id` FK on
`api_tokens` for revocation accountability (Requirements → Revocation accountability, RESOLVED Q6).
No supporting index is added: at this story's volume (~10 researchers, ~one token per machine) the
table tops out at a few dozen rows, so `WHERE revoked_at IS NULL ORDER BY inserted_at, id` is a
trivial scan; the "revisit with a composite index if the table grows" note in the requirements
stands. This commit is schema-only; the two-arg `revoke_api_token/2` that stamps the column lands in
the next commit alongside its callers so this commit stays green on its own.

**Files affected**:
- `server/priv/repo/migrations/20260713090000_add_revoked_by_to_api_tokens.exs` — new migration
- `server/lib/report_server/accounts/api_token.ex` — `belongs_to :revoked_by` + cast the FK

**Estimated diff size**: ~20 lines

New migration (`on_delete: :nothing` matches the existing `user_id` FK on this table, verified in
`20260713080000_create_api_tokens.exs`; nullable is correct for historical rows and manual
DB/console revokes):

```elixir
defmodule ReportServer.Repo.Migrations.AddRevokedByToApiTokens do
  use Ecto.Migration

  def change do
    alter table(:api_tokens) do
      add :revoked_by_user_id, references(:users, on_delete: :nothing)
    end
  end
end
```

`api_token.ex` — add the association and include the column in the changeset (cast, not required —
the DB column is nullable):

```elixir
    field :last_used_at, :utc_datetime
    field :revoked_at, :utc_datetime

    belongs_to :user, User, foreign_key: :user_id
    belongs_to :revoked_by, User, foreign_key: :revoked_by_user_id   # NEW

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(api_token, attrs) do
    api_token
    |> cast(attrs, [:user_id, :token_hash, :label, :last_used_at, :revoked_at, :revoked_by_user_id])  # + :revoked_by_user_id
    |> validate_required([:user_id, :token_hash])
    |> unique_constraint(:token_hash)
  end
```

---

### Context functions: list / ownership-scoped fetch / two-arg revoke

**Summary**: Adds the four `Accounts` functions the UI drives, and makes the accountability-stamping
signature change. This is the load-bearing security surface, so it ships with its own context tests.
The `revoke_api_token/1` → `revoke_api_token/2` change is breaking; the only two callers exist
(both tests, verified by grep) and are updated in this same commit so nothing else breaks.

**Files affected**:
- `server/lib/report_server/accounts.ex` — add `list_active_api_tokens/1`, `get_user_api_token/2`,
  `get_active_api_token/1`, `list_all_active_api_tokens/1`; change `revoke_api_token/1` →
  `revoke_api_token/2`
- `server/test/report_server/accounts_test.exs` — update the revoke caller + add tests
- `server/test/report_server_web/api/auth_plug_test.exs` — update the revoke caller

**Estimated diff size**: ~130 lines (incl. tests — the atomic conditional revoke + the first-writer-wins race test)

In `accounts.ex`, change `revoke_api_token/1` to the **required** two-arg form (no default — so no
code path can silently produce an unattributed revoke). The write is an **atomic conditional UPDATE**
(`where is_nil(revoked_at)`, checking the affected-row count) rather than an unconditional
`Repo.update()`, mirroring the established exactly-once idiom in this same module
(`exchange_auth_grant/2` at `accounts.ex:154-182`, whose docstring spells out "exactly one exchange …
can get `{1, _}` back — so concurrent duplicates cannot both mint"; `athena_run_ops.ex:57` uses the
same claim pattern). This makes revocation **first-writer-wins**: in a concurrent self/admin or two-tab
race, two handlers can both fetch the token active, but only the first UPDATE matches `is_nil(revoked_at)`
and stamps `revoked_by_user_id`; the loser matches **0 rows** and overwrites nothing, so accountability
("who killed this token") is deterministic and the already-revoked path stays a benign no-op even under
true concurrency. MySQL/MyXQL has no `RETURNING`, so the success branch re-fetches the row (exactly as
`exchange_auth_grant` re-fetches with `Repo.one!`):

```elixir
  # BEFORE
  def revoke_api_token(api_token = %ApiToken{}) do
    api_token
    |> ApiToken.changeset(%{revoked_at: DateTime.utc_now(:second)})
    |> Repo.update()
  end

  # AFTER — atomic conditional write; {:error, :already_revoked} on a lost race / stale struct
  def revoke_api_token(api_token = %ApiToken{}, revoked_by_user_id) do
    now = DateTime.utc_now(:second)

    revoke_query =
      from t in ApiToken, where: t.id == ^api_token.id and is_nil(t.revoked_at)

    case Repo.update_all(revoke_query,
           set: [revoked_at: now, revoked_by_user_id: revoked_by_user_id, updated_at: now]) do
      {1, _} -> {:ok, Repo.get!(ApiToken, api_token.id)}
      {0, _} -> {:error, :already_revoked}
    end
  end
```

Return contract: `{:ok, %ApiToken{}}` on a successful revoke (the reloaded, now-revoked row) and
`{:error, :already_revoked}` when the token was already revoked between the handler's fetch and this
write. Both revoke handlers treat `{:error, :already_revoked}` as the same benign no-op as a nil fetch
(see the handler snippets below). `updated_at` is set explicitly because `update_all` bypasses the
changeset's autogenerated timestamps.

Add the four query functions (grouped with the other token functions). Note `get_user_api_token/2`
is a real `is_nil(revoked_at)` query, **not** `Repo.get_by/2` — `get_by` is not `revoked_at`-filtered
(it returns an already-revoked row, verified during spec authoring), which would defeat the
stale/already-revoked no-op contract:

```elixir
  # All of a user's active (non-revoked) tokens, newest-first. Unpaginated: a user's active
  # tokens are naturally bounded (~one per machine). No id tiebreaker needed — unpaginated, so a
  # tie is only a cosmetic within-page ordering, never a skipped row.
  def list_active_api_tokens(user_id) do
    Repo.all(
      from t in ApiToken,
        where: t.user_id == ^user_id and is_nil(t.revoked_at),
        order_by: [desc: t.inserted_at]
    )
  end

  # Ownership-scoped, active-only fetch for the self-serve revoke handler (the load-bearing IDOR
  # guard). A forged/other-user or already-revoked id fetches as nil → benign no-op.
  def get_user_api_token(id, user_id) do
    Repo.one(
      from t in ApiToken,
        where: t.id == ^id and t.user_id == ^user_id and is_nil(t.revoked_at)
    )
  end

  # Active-only cross-user fetch for the admin revoke handler. Not Repo.get (which returns
  # already-revoked rows) so an already-revoked id fetches as nil → same benign no-op path.
  def get_active_api_token(id) do
    Repo.one(from t in ApiToken, where: t.id == ^id and is_nil(t.revoked_at))
  end

  # Every user's active tokens, paginated 25/page, newest-first, owner preloaded. The order_by is a
  # TOTAL order — [desc: inserted_at, desc: id] — because the list is paginated (independent
  # LIMIT/OFFSET per page) and inserted_at is second-granularity (rapidly-minted tokens collapse to
  # one value), so a bare [desc: inserted_at] could duplicate/skip a tied row at a page boundary.
  def list_all_active_api_tokens(page) do
    from(t in ApiToken,
      where: is_nil(t.revoked_at),
      order_by: [desc: t.inserted_at, desc: t.id],
      preload: [:user]
    )
    |> Pagination.paginate(page)
  end
```

Add the `Pagination` alias at the top of `accounts.ex`:

```elixir
  alias ReportServer.Pagination
```

Update the two existing callers to the two-arg form:

- `accounts_test.exs:86` — `Accounts.revoke_api_token(api_token)` →
  `Accounts.revoke_api_token(api_token, user.id)` (rename the `describe "revoke_api_token/1"` block
  to `/2`).
- `auth_plug_test.exs:34` — `Accounts.revoke_api_token(api_token)` →
  `Accounts.revoke_api_token(api_token, user.id)`.

Add context tests to `accounts_test.exs` covering the new functions and attribution:

```elixir
  describe "list_active_api_tokens/1" do
    test "returns only the user's active tokens, newest-first, excluding revoked and other users'" do
      user = user_fixture()
      other = user_fixture()
      {_r1, older} = api_token_fixture(user, "old")
      {_r2, newer} = api_token_fixture(user, "new")
      {_r3, revoked} = api_token_fixture(user, "revoked")
      {_r4, _foreign} = api_token_fixture(other, "theirs")
      {:ok, _} = Accounts.revoke_api_token(revoked, user.id)
      # force a deterministic newest-first order (inserted_at is second-granularity)
      Repo.update_all(from(t in ApiToken, where: t.id == ^older.id), set: [inserted_at: ~U[2020-01-01 00:00:00Z]])
      Repo.update_all(from(t in ApiToken, where: t.id == ^newer.id), set: [inserted_at: ~U[2021-01-01 00:00:00Z]])

      ids = Accounts.list_active_api_tokens(user.id) |> Enum.map(& &1.id)
      assert ids == [newer.id, older.id]
    end
  end

  describe "get_user_api_token/2" do
    test "returns the owner's active token, nil for another user, nil once revoked" do
      user = user_fixture()
      other = user_fixture()
      {_raw, token} = api_token_fixture(user)

      assert %ApiToken{} = Accounts.get_user_api_token(token.id, user.id)
      assert nil == Accounts.get_user_api_token(token.id, other.id)

      {:ok, _} = Accounts.revoke_api_token(token, user.id)
      assert nil == Accounts.get_user_api_token(token.id, user.id)
    end
  end

  describe "revoke_api_token/2 attribution" do
    test "stamps revoked_by_user_id with the actor's id" do
      owner = user_fixture()
      admin = user_fixture(%{portal_is_admin: true})
      {_r1, self_tok} = api_token_fixture(owner)
      {_r2, admin_tok} = api_token_fixture(owner)

      {:ok, self_revoked} = Accounts.revoke_api_token(self_tok, owner.id)
      {:ok, admin_revoked} = Accounts.revoke_api_token(admin_tok, admin.id)

      assert self_revoked.revoked_by_user_id == owner.id
      assert admin_revoked.revoked_by_user_id == admin.id
    end

    test "is an atomic first-writer-wins write — a second (lost-race) revoke cannot overwrite the actor" do
      owner = user_fixture()
      admin = user_fixture(%{portal_is_admin: true})
      {_raw, token} = api_token_fixture(owner)

      # first revoke wins and stamps the owner
      {:ok, first} = Accounts.revoke_api_token(token, owner.id)
      assert first.revoked_by_user_id == owner.id

      # `token` is the pre-revoke struct (revoked_at still nil in memory) — exactly what a handler that
      # fetched active then lost the race holds. The conditional `is_nil(revoked_at)` matches 0 rows.
      assert {:error, :already_revoked} = Accounts.revoke_api_token(token, admin.id)
      assert Repo.get!(ApiToken, token.id).revoked_by_user_id == owner.id   # unchanged, not overwritten
    end
  end

  describe "list_all_active_api_tokens/1 stable order" do
    test "every token appears exactly once across pages when many share one inserted_at" do
      user = user_fixture()
      tokens = for _ <- 1..30, do: (api_token_fixture(user) |> elem(1))
      ids = Enum.map(tokens, & &1.id)
      Repo.update_all(from(t in ApiToken, where: t.id in ^ids), set: [inserted_at: ~U[2020-01-01 00:00:00Z]])

      p1 = Accounts.list_all_active_api_tokens(1)
      p2 = Accounts.list_all_active_api_tokens(2)
      seen = Enum.map(p1.items ++ p2.items, & &1.id)

      assert p1.total_count == 30
      assert length(seen) == 30
      assert Enum.sort(seen) == Enum.sort(ids)   # no dup, no skip
    end
  end
```

(`accounts_test.exs` will need `import Ecto.Query` and the `ApiToken`/`Repo` aliases if not already
present — mirror `audit_log_live_test.exs`'s imports.)

---

### Shared token table component + confirm-text helper

**Summary**: Adds the one reusable piece both pages render: an accessible token table with a
per-row revoke button. Centralizing it here means the net-new table accessible name
(`<caption class="sr-only">`), the `scope="col"` column headers, the "Never used" rendering, and the
**id-disambiguated** revoke confirmation (Requirements → Accessibility) are defined once and shared by
the self-serve and admin pages. This commit adds the component and its unit-level render assertions
(including that a label with special characters is HTML-escaped in the confirm/accessible name); the
pages wire it up in the next two commits.

**Files affected**:
- `server/lib/report_server_web/components/custom_components.ex` — add `token_table/1` +
  `token_descriptor/1`
- `server/test/report_server_web/components/custom_components_test.exs` — component render tests
  (new file if absent)

**Estimated diff size**: ~105 lines

Add to `custom_components.ex`. The descriptor is shared verbatim by the `data-confirm` text and the
button's `aria-label`, so the visible confirm and the AT name never diverge. The id is required, not
decorative: label + created + last-used are not a unique key (same-second unlabeled never-used
tokens are otherwise identical), so `#id` is what actually prevents revoking the wrong machine's
token:

```elixir
  attr :tokens, :list, required: true
  attr :caption, :string, required: true, doc: "accessible table name (rendered sr-only)"
  attr :include_user, :boolean, default: false, doc: "admin view prepends a User column"
  attr :revoke_event, :string, default: "revoke"

  def token_table(assigns) do
    ~H"""
    <table class="w-full border-collapse bg-white text-sm">
      <caption class="sr-only"><%= @caption %></caption>
      <thead class="bg-gray-100 text-left leading-6 text-zinc-600">
        <tr>
          <th :if={@include_user} scope="col" class="p-2 font-normal border-b">User</th>
          <th scope="col" class="p-2 font-normal border-b">Label</th>
          <th scope="col" class="p-2 font-normal border-b">Created</th>
          <th scope="col" class="p-2 font-normal border-b">Last used</th>
          <th scope="col" class="p-2 font-normal border-b"><span class="sr-only">Revoke</span></th>
        </tr>
      </thead>
      <tbody>
        <tr :for={token <- @tokens} class="group hover:bg-zinc-200 even:bg-gray-50">
          <td :if={@include_user} class="p-2 font-normal border-b align-top">
            <%= token.user.portal_first_name %> <%= token.user.portal_last_name %> (<%= token.user.portal_email %>)
          </td>
          <td class="p-2 font-normal border-b align-top"><%= token.label || "—" %></td>
          <td class="p-2 font-normal border-b align-top">
            <time datetime={DateTime.to_iso8601(token.inserted_at)}>
              <%= Calendar.strftime(token.inserted_at, "%Y-%m-%d %H:%M UTC") %>
            </time>
          </td>
          <td class="p-2 font-normal border-b align-top">
            <%= if token.last_used_at do %>
              <time datetime={DateTime.to_iso8601(token.last_used_at)}>
                <%= Calendar.strftime(token.last_used_at, "%Y-%m-%d %H:%M UTC") %>
              </time>
            <% else %>
              Never used
            <% end %>
          </td>
          <td class="p-2 font-normal border-b align-top">
            <button
              type="button"
              phx-click={@revoke_event}
              phx-value-id={token.id}
              data-confirm={"Revoke #{token_descriptor(token)}? The machine using it will need a new token."}
              aria-label={"Revoke #{token_descriptor(token)}"}
              class="rounded px-2 py-1 border border-rose-600 text-rose-700 text-sm hover:bg-rose-600 hover:text-white"
            >
              Revoke
            </button>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  # Unique, human-readable identifier for a token used in the revoke confirmation and the button's
  # accessible name. The #id is the guaranteed-unique discriminator: label + created + last-used are
  # NOT a unique key (inserted_at is second-granularity; never-used rows share last_used_at == nil),
  # so two same-second unlabeled tokens are otherwise identical here.
  defp token_descriptor(token) do
    label_part = if token.label, do: "the token labeled '#{token.label}'", else: "the unlabeled token"
    created = Calendar.strftime(token.inserted_at, "%Y-%m-%d %H:%M UTC")

    used =
      if token.last_used_at do
        "last used " <> Calendar.strftime(token.last_used_at, "%Y-%m-%d %H:%M UTC")
      else
        "never used"
      end

    "#{label_part} (created #{created}, #{used}, ##{token.id})"
  end
```

Component tests (`render_component/2`) assert the a11y-critical rendering and the disambiguation:

```elixir
  test "renders never-used, an accessible caption, scoped headers, and an id-disambiguated revoke name" do
    t1 = %ApiToken{id: 41, label: nil, inserted_at: ~U[2026-07-01 14:22:00Z], last_used_at: nil}
    t2 = %ApiToken{id: 57, label: nil, inserted_at: ~U[2026-07-01 14:22:00Z], last_used_at: nil}

    html = render_component(&CustomComponents.token_table/1, tokens: [t1, t2], caption: "Your active CLI tokens")

    assert html =~ ~s(<caption class="sr-only">Your active CLI tokens</caption>)
    assert html =~ ~s(<th scope="col")           # column headers are scoped for AT
    assert html =~ "Never used"
    # two same-second unlabeled never-used tokens differ only by #id
    assert html =~ "aria-label=\"Revoke the unlabeled token (created 2026-07-01 14:22 UTC, never used, #41)\""
    assert html =~ "#57"
    assert html =~ ~s(data-confirm=)
  end

  test "a label with special characters is HTML-escaped in the confirm/accessible name" do
    # HEEx escapes attribute values, so a label with an apostrophe renders as &#39; — the descriptor
    # (shared by data-confirm and aria-label) must still name the token without breaking the markup.
    t = %ApiToken{id: 42, label: "Doug's MacBook", inserted_at: ~U[2026-07-01 14:22:00Z], last_used_at: nil}

    html = render_component(&CustomComponents.token_table/1, tokens: [t], caption: "Your active CLI tokens")

    assert html =~ "the token labeled &#39;Doug&#39;s MacBook&#39;"
    assert html =~ "#42"
  end
```

---

### Merge list + revoke into the self-serve CLI-token page

**Summary**: Turns `ReportLive.CliToken` from mint-only into the merged self-serve page
(RESOLVED Q1): it now loads the caller's active tokens at mount, renders them with `token_table`
below the shown-once value, and revokes ownership-scoped in place. Two net-new behaviors this commit
must get right and test: the `generate` handler **re-loads** the token list (so a just-minted token
appears in the same render — Q1's headline benefit), and the `revoke` handler **preserves
`@raw_token`** (so revoking an *old* row does not blank a shown-once value the user is still copying) —
**except** when the row being revoked *is* the just-minted token itself, in which case the shown-once
panel must be cleared (a revoked token must not remain displayed as a usable "Your new token"). To tell
those apart, `generate` records the minted token's id in `@raw_token_id`, and `revoke` clears the
shown-once value only when it revokes that id.

**Files affected**:
- `server/lib/report_server_web/live/report_live/cli_token.ex` — mount assign, generate refresh,
  revoke handler
- `server/lib/report_server_web/live/report_live/cli_token.html.heex` — heading + list section
- `server/test/report_server_web/live/cli_token_live_test.exs` — new behavior tests

**Estimated diff size**: ~155 lines (incl. the shown-once-id tracking + the revoke-the-minted-row test)

`cli_token.ex` — assign the list at mount, refresh it on generate, and add the revoke handler.
`@user` is available via the `ReportLive.Auth` on_mount:

```elixir
  @impl true
  def mount(_params, _session, %{assigns: %{user: user}} = socket) do
    socket = socket
      |> assign(:page_title, "CLI Access Tokens")
      |> assign(:raw_token, nil)
      |> assign(:raw_token_id, nil)
      |> assign(:form, to_form(%{"label" => ""}))
      |> assign(:tokens, Accounts.list_active_api_tokens(user.id))

    {:ok, socket}
  end

  # Fallback for the not-logged-in first-load: on_mount (ReportLive.Auth) does NOT assign @user on the
  # unauthenticated branch (it defers to a handle_params login-redirect that fires AFTER mount), so a
  # user-less socket reaches mount. Without this clause the @user-requiring clause above raises
  # FunctionClauseError (500) before the redirect hook runs. Mirrors AuditLogLive.Index's fallback
  # mount clause; the redirect here plus the on_mount hook complete the send-to-login flow.
  @impl true
  def mount(_params, _session, socket) do
    {:ok, redirect(socket, to: "/reports")}
  end

  @impl true
  def handle_event("generate", %{"label" => label}, %{assigns: %{user: user}} = socket) do
    label = case String.trim(label) do
      "" -> nil
      trimmed -> trimmed
    end

    case Accounts.create_api_token(user, label) do
      {:ok, raw_token, api_token} ->
        # re-load the list so the just-minted token appears in THIS render (mount runs once); record
        # the minted id so a later revoke of THIS token can clear the shown-once panel (see revoke).
        socket = socket
          |> assign(:raw_token, raw_token)
          |> assign(:raw_token_id, api_token.id)
          |> assign(:tokens, Accounts.list_active_api_tokens(user.id))
        {:noreply, socket}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Unable to generate a token. Please try again.")}
    end
  end

  @impl true
  def handle_event("revoke", %{"id" => id}, %{assigns: %{user: user}} = socket) do
    token = with {token_id, ""} <- Integer.parse(id), do: Accounts.get_user_api_token(token_id, user.id)

    socket =
      case token do
        %ApiToken{} = token ->
          case Accounts.revoke_api_token(token, user.id) do
            {:ok, _} ->
              socket |> clear_shown_once_if(token.id) |> put_flash(:info, "Token revoked")

            {:error, :already_revoked} ->
              # lost a fetch→write race (revoked in another tab / by an admin) → benign no-op
              socket |> put_flash(:info, "That token was already inactive")
          end

        _ ->
          # forged/other-user/already-revoked id → benign no-op (worded for the satisfied end-state)
          socket |> put_flash(:info, "That token was already inactive")
      end

    {:noreply, assign(socket, :tokens, Accounts.list_active_api_tokens(user.id))}
  end

  # Preserve @raw_token across a revoke of some OTHER (older) row — a shown-once value the user may
  # still be copying must survive. But if the row being revoked IS the just-minted token, its shown-once
  # value is now dead, so clear the panel rather than leave an invalid token displayed as usable.
  defp clear_shown_once_if(socket, revoked_id) do
    if socket.assigns[:raw_token_id] == revoked_id do
      socket |> assign(:raw_token, nil) |> assign(:raw_token_id, nil)
    else
      socket
    end
  end
```

Add the alias for the struct match at the top of `cli_token.ex`:

```elixir
  alias ReportServer.Accounts
  alias ReportServer.Accounts.ApiToken   # NEW (for the %ApiToken{} guard)
```

`cli_token.html.heex` — update the heading (breadcrumb) and append the list section after the
existing `<div :if={@raw_token != nil}>` block, still inside `.../max-w-xl`? No — the table wants
full width, so close the narrow wrapper and add the list below it. Change the breadcrumb `current`
to the plural heading:

```heex
  <.breadcrumbs previous={[{"Reports", ~p"/reports"}]} current="CLI Access Tokens" />
```

Append below the existing `max-w-xl` block (the generate form is always on the page, so the empty
state is just "none yet" — no redundant "create one" CTA):

```heex
<div class="mt-8">
  <h2 class="font-bold text-sm mb-2">Your active tokens</h2>
  <.token_table
    :if={length(@tokens) > 0}
    tokens={@tokens}
    caption="Your active CLI access tokens"
  />
  <p :if={length(@tokens) == 0} class="text-sm text-slate-600">You have no active tokens yet.</p>
</div>
```

Tests to add to `cli_token_live_test.exs` (the existing shown-once tests keep passing — note
`"CLI Access Tokens"` still contains the substring `"CLI Access Token"` the mount test asserts):

```elixir
  test "a minted token appears in the active list in the same render", %{conn: conn} do
    user = user_fixture()
    {:ok, view, _html} = live(log_in_conn(conn, user), ~p"/reports/cli-token")

    html = view |> form("form", %{"label" => "My Laptop"}) |> render_submit()

    assert html =~ "ccd_"                         # shown-once value still on screen
    assert html =~ "My Laptop"                    # ...and now also listed below
    assert html =~ "Your active tokens"
  end

  test "revoking an older row does not blank the shown-once value", %{conn: conn} do
    user = user_fixture()
    {_raw, old} = api_token_fixture(user, "Old Machine")
    {:ok, view, _html} = live(log_in_conn(conn, user), ~p"/reports/cli-token")

    render_submit(form(view, "form", %{"label" => "New Machine"}))     # shows @raw_token
    html = render_click(view, "revoke", %{"id" => to_string(old.id)})

    assert html =~ "ccd_"                         # @raw_token preserved through the revoke
    assert html =~ "Token revoked"
    refute html =~ "Old Machine"                  # revoked row gone
    assert html =~ "New Machine"
  end

  test "revoking the just-minted row clears the shown-once panel (no dead token left visible)", %{conn: conn} do
    user = user_fixture()
    {:ok, view, _html} = live(log_in_conn(conn, user), ~p"/reports/cli-token")

    html = render_submit(form(view, "form", %{"label" => "Fresh"}))
    assert html =~ "ccd_"                         # shown-once value on screen
    minted = ReportServer.Accounts.list_active_api_tokens(user.id) |> List.first()

    html = render_click(view, "revoke", %{"id" => to_string(minted.id)})

    assert html =~ "Token revoked"
    refute html =~ "ccd_"                         # the now-dead shown-once value is cleared, not left copyable
    refute html =~ "Fresh"                        # revoked row gone from the list
    assert html =~ "You have no active tokens yet."
  end

  test "self-revoke removes the row; the token stops authenticating", %{conn: conn} do
    user = user_fixture()
    {raw, token} = api_token_fixture(user, "Doomed")
    {:ok, view, html} = live(log_in_conn(conn, user), ~p"/reports/cli-token")
    assert html =~ "Doomed"

    html = render_click(view, "revoke", %{"id" => to_string(token.id)})
    assert html =~ "Token revoked"
    refute html =~ "Doomed"
    assert :error == ReportServer.Accounts.verify_api_token(raw)
  end

  test "a forged id for another user's token is a benign no-op (IDOR)", %{conn: conn} do
    user = user_fixture()
    other = user_fixture()
    {other_raw, other_token} = api_token_fixture(other, "Not Yours")
    {:ok, view, _html} = live(log_in_conn(conn, user), ~p"/reports/cli-token")

    html = render_click(view, "revoke", %{"id" => to_string(other_token.id)})

    assert html =~ "That token was already inactive"           # benign no-op, no crash
    assert {:ok, _u, _t} = ReportServer.Accounts.verify_api_token(other_raw)  # still active
  end

  test "the self-serve list renders only the caller's tokens", %{conn: conn} do
    user = user_fixture()
    other = user_fixture()
    api_token_fixture(user, "Mine")
    api_token_fixture(other, "Theirs")

    {:ok, _view, html} = live(log_in_conn(conn, user), ~p"/reports/cli-token")

    assert html =~ "Mine"
    refute html =~ "Theirs"
  end

  test "revoking an already-revoked token is a benign no-op", %{conn: conn} do
    user = user_fixture()
    {_raw, token} = api_token_fixture(user, "Gone")
    {:ok, revoked} = ReportServer.Accounts.revoke_api_token(token, user.id)
    {:ok, view, _html} = live(log_in_conn(conn, user), ~p"/reports/cli-token")

    html = render_click(view, "revoke", %{"id" => to_string(token.id)})

    assert html =~ "That token was already inactive"
    # attribution unchanged (not re-revoked)
    reloaded = ReportServer.Repo.get(ReportServer.Accounts.ApiToken, token.id)
    assert reloaded.revoked_by_user_id == revoked.revoked_by_user_id
  end

  test "empty state shows the 'none yet' copy", %{conn: conn} do
    user = user_fixture()
    {:ok, _view, html} = live(log_in_conn(conn, user), ~p"/reports/cli-token")
    assert html =~ "You have no active tokens yet."
  end

  test "an unauthenticated visit redirects instead of crashing", %{conn: conn} do
    # not logged in: on_mount leaves @user unassigned, so mount must fall through to the redirect
    # clause rather than raising FunctionClauseError on the @user-requiring clause.
    assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/reports/cli-token")
    assert to in ["/reports", "/auth/login?return_to=/reports/cli-token"]
  end
```

---

### Admin all-tokens audit + revoke page

**Summary**: Adds the `portal_is_admin`-gated global list at `/reports/all-tokens` (RESOLVED Q2),
mirroring `AuditLogLive.Index`: paginated 25/page via `handle_params`, a **User** column
(name + email), newest-first with the id tiebreaker, and admin revoke of any user's token. Two
behaviors specific to this page: the mount gate is backed by a **handler-level `portal_is_admin`
re-check** (defense-in-depth against a forged event), and revoke **re-paginates** so revoking the
last row on the last page lands on a valid page.

**Files affected**:
- `server/lib/report_server_web/live/all_tokens_live/index.ex` — new LiveView
- `server/lib/report_server_web/live/all_tokens_live/index.html.heex` — new template
- `server/lib/report_server_web/router.ex` — add the route
- `server/test/report_server_web/live/all_tokens_live_test.exs` — new tests

**Estimated diff size**: ~165 lines

`router.ex` — add inside the `:reports` `live_session`, next to the other admin list `/all-runs`:

```elixir
      live "/all-runs", ReportRunLive.Index, :all_runs
      live "/all-tokens", AllTokensLive.Index, :index        # NEW
```

`all_tokens_live/index.ex` — mount gate + paginated `handle_params` copied from `AuditLogLive.Index`,
plus the revoke `handle_event` with a defense-in-depth admin re-check and a re-paginate:

```elixir
defmodule ReportServerWeb.AllTokensLive.Index do
  use ReportServerWeb, :live_view

  alias ReportServer.Accounts
  alias ReportServer.Accounts.ApiToken
  alias ReportServer.Pagination

  @impl true
  def mount(_params, _session, %{assigns: %{user: %{portal_is_admin: true}}} = socket) do
    {:ok, assign(socket, :page_title, "All CLI Tokens")}
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> put_flash(:error, "Sorry, you don't have access to that page.") |> redirect(to: "/reports")}
  end

  @impl true
  def handle_params(params, _url, %{assigns: %{user: %{portal_is_admin: true}}} = socket) do
    {:noreply, assign_page(socket, Pagination.normalize_page(params["page"]))}
  end

  @impl true
  def handle_params(_params, _url, socket), do: {:noreply, socket}

  @impl true
  def handle_event("revoke", %{"id" => id}, %{assigns: %{user: %{portal_is_admin: true} = user}} = socket) do
    token = with {token_id, ""} <- Integer.parse(id), do: Accounts.get_active_api_token(token_id)

    socket =
      case token do
        %ApiToken{} = token ->
          case Accounts.revoke_api_token(token, user.id) do
            {:ok, _} -> put_flash(socket, :info, "Token revoked")
            {:error, :already_revoked} -> put_flash(socket, :info, "That token was already inactive")
          end

        _ ->
          put_flash(socket, :info, "That token was already inactive")
      end

    # re-run the paginated query; paginate clamps page = min(page, total_pages), so revoking the last
    # row on the last page lands on a valid (non-empty) page rather than an empty page N.
    {:noreply, assign_page(socket, socket.assigns.page)}
  end

  @impl true
  def handle_event("revoke", _params, socket) do
    # a non-admin who forged the event (mount already gates the page) — reject, no-op
    {:noreply, socket}
  end

  defp assign_page(socket, page) do
    result = Accounts.list_all_active_api_tokens(page)

    socket
    |> assign(:tokens, result.items)
    |> assign(:page, result.page)
    |> assign(:total_pages, result.total_pages)
  end

  defp all_tokens_path(1), do: ~p"/reports/all-tokens"
  defp all_tokens_path(page), do: ~p"/reports/all-tokens?page=#{page}"
end
```

`all_tokens_live/index.html.heex` — reuse `token_table` (with `include_user`) and the `pager`,
mirroring the audit-log template's empty state and dual pagers:

```heex
<div class="font-bold my-2">
  <.breadcrumbs previous={[{"Reports", ~p"/reports"}]} current="All CLI Tokens" />
</div>

<div :if={length(@tokens) > 0}>
  <.pager page={@page} total_pages={@total_pages} path_fun={&all_tokens_path/1} label="pagination top" />
  <.token_table tokens={@tokens} caption="All active CLI access tokens" include_user={true} />
  <.pager page={@page} total_pages={@total_pages} path_fun={&all_tokens_path/1} label="pagination bottom" />
</div>
<div :if={length(@tokens) == 0} class="my-4 text-sm">No active tokens.</div>
```

Tests (`all_tokens_live_test.exs`) — model on `audit_log_live_test.exs`:

```elixir
  test "redirects a non-admin", %{conn: conn} do
    user = user_fixture(%{portal_is_admin: false})
    assert {:error, {:redirect, %{to: "/reports"}}} = live(log_in_conn(conn, user), ~p"/reports/all-tokens")
  end

  test "an admin sees all users' active tokens with a name+email User column", %{conn: conn} do
    admin = user_fixture(%{portal_is_admin: true})
    owner = user_fixture(%{portal_first_name: "Dana", portal_last_name: "Researcher"})
    # apostrophe-free label: HEEx escapes `<%= token.label %>`, so a label like "Dana's Laptop" renders
    # as "Dana&#39;s Laptop" and a raw `html =~ "Dana's Laptop"` assertion would never match.
    api_token_fixture(owner, "Dana Laptop")

    {:ok, _view, html} = live(log_in_conn(conn, admin), ~p"/reports/all-tokens")

    assert html =~ "All CLI Tokens"
    assert html =~ "Dana Laptop"
    assert html =~ owner.portal_email        # email, not name-only
  end

  test "an admin revokes another user's token (attributed to the admin)", %{conn: conn} do
    admin = user_fixture(%{portal_is_admin: true})
    owner = user_fixture()
    {raw, token} = api_token_fixture(owner, "Departing")
    {:ok, view, _html} = live(log_in_conn(conn, admin), ~p"/reports/all-tokens")

    html = render_click(view, "revoke", %{"id" => to_string(token.id)})

    assert html =~ "Token revoked"
    refute html =~ "Departing"
    assert :error == ReportServer.Accounts.verify_api_token(raw)
    assert ReportServer.Repo.get(ReportServer.Accounts.ApiToken, token.id).revoked_by_user_id == admin.id
  end

  test "revoking the only token on the last page lands on a valid page", %{conn: conn} do
    admin = user_fixture(%{portal_is_admin: true})
    owner = user_fixture()
    tokens = for _ <- 1..26, do: (api_token_fixture(owner) |> elem(1))
    # order_by [desc: inserted_at, desc: id] with 26 near-simultaneous rows ⇒ effectively desc id, so
    # page 1 holds the 25 highest ids and page 2 holds the single LOWEST id. Revoke that page-2 row
    # (min id) — the row actually displayed on the last page — not List.last (which is the max id on p1).
    last = Enum.min_by(tokens, & &1.id)

    {:ok, view, _html} = live(log_in_conn(conn, admin), ~p"/reports/all-tokens?page=2")
    html = render_click(view, "revoke", %{"id" => to_string(last.id)})

    assert html =~ "Token revoked"
    refute html =~ "aria-label=\"pagination"   # 25 rows left → single page, pager hidden
  end

  # Defense-in-depth: mount already redirects non-admins, so the forged revoke event can't be driven
  # through LiveViewTest — call the handler clause directly with a non-admin socket and assert it
  # no-ops and revokes nothing. Guards against a refactor that drops the fallback clause.
  test "a non-admin revoke event is rejected by the handler and revokes nothing" do
    non_admin = user_fixture(%{portal_is_admin: false})
    owner = user_fixture()
    {raw, _token} = api_token_fixture(owner, "Untouched")

    socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, user: non_admin}}
    assert {:noreply, ^socket} =
             ReportServerWeb.AllTokensLive.Index.handle_event("revoke", %{"id" => "1"}, socket)

    assert {:ok, _u, _t} = ReportServer.Accounts.verify_api_token(raw)   # still active
  end

  test "the pager appears only past 25 tokens", %{conn: conn} do
    admin = user_fixture(%{portal_is_admin: true})
    owner = user_fixture()
    for _ <- 1..26, do: api_token_fixture(owner)

    {:ok, _view, html} = live(log_in_conn(conn, admin), ~p"/reports/all-tokens")
    assert html =~ ~s(aria-label="pagination top")
  end

  test "shows an empty state and hides the pager when there are no active tokens", %{conn: conn} do
    admin = user_fixture(%{portal_is_admin: true})
    {:ok, _view, html} = live(log_in_conn(conn, admin), ~p"/reports/all-tokens")
    assert html =~ "No active tokens."
    refute html =~ ~s(aria-label="pagination)
  end
```

---

### Reports-home navigation links

**Summary**: Adds the three `described_link`s that make these pages discoverable (RESOLVED Q5):
**CLI Access Tokens** for all report users, and — for admins — **All CLI Tokens** and the
previously-orphaned **Data Access Log**. Without this the token page a researcher needs to "find
their forgotten token" is reachable only by direct URL.

**Files affected**:
- `server/lib/report_server_web/live/report_live/index.html.heex` — three links (root only)

**Estimated diff size**: ~15 lines

Add inside the existing `@is_root` region. The CLI-token link is for all report users; the admin two
go inside the existing `@user.portal_is_admin` block:

```heex
  <.described_link navigate={~p"/reports/cli-token"} description={"Create and manage your cc-data CLI access tokens"} :if={@is_root}>
    CLI Access Tokens
  </.described_link>

  <%= if @user.portal_is_admin do %>
    <.described_link navigate={~p"/reports/all-runs"} description={"Lists all the report runs (because you are an admin)"} :if={@is_root}>
      All Runs
    </.described_link>
    <.described_link navigate={~p"/reports/all-tokens"} description={"View and revoke any user's CLI access tokens (admin)"} :if={@is_root}>
      All CLI Tokens
    </.described_link>
    <.described_link navigate={~p"/reports/audit-log"} description={"Data access audit log (admin)"} :if={@is_root}>
      Data Access Log
    </.described_link>
  <% end %>
```

---

## Open Questions

<!-- None. All requirements-level decisions are RESOLVED in requirements.md; the implementation
     follows established patterns (AuditLogLive.Index, report_runs/1, pager, described_link) with no
     new architectural choices. -->

## Self-Review

### QA Engineer

#### RESOLVED: The required handler-level non-admin revoke rejection is now tested
`requirements.md` → Testing lists, as an explicit acceptance criterion: *"a non-admin is redirected
at mount **and** an admin `revoke` event pushed by a non-admin is rejected by the handler
(defense-in-depth)."* The plan has the fallback `handle_event("revoke", _params, socket)` clause, but
the admin-page test suite originally covered only the **mount** redirect. It also can't be driven the
usual way: `mount/3` redirects a non-admin, so `LiveViewTest.live/2` never yields a live process to
push the forged event from.
_Resolved: added the direct-call unit test **"a non-admin revoke event is rejected by the handler and
revokes nothing"** to `all_tokens_live_test.exs` — it builds a `%Phoenix.LiveView.Socket{}` with a
non-admin `@user`, asserts `AllTokensLive.Index.handle_event("revoke", %{"id" => "1"}, socket)`
returns `{:noreply, socket}`, and asserts the victim token still authenticates. This pins the
defense-in-depth clause against a refactor that drops it, without needing an integration path the
mount gate forbids._

---

### WCAG Accessibility Expert

#### RESOLVED (accepted trade-off): Keyboard focus is lost when a revoked row disappears
Revoke is a destructive, in-place action: the focused `<button>` is inside the row that the
re-render removes, so after a successful revoke keyboard/AT focus falls back to `<body>`. The
`role="alert"` flash *announces* the outcome (so the user is told it worked), but focus placement is
undefined. This is a known LiveView pattern (focus must be actively managed, e.g. `phx-mounted`/
`JS.focus`).
_Resolved: **accepted as a known v1 gap.** The `role="alert"` flash is the load-bearing feedback and
the token list is short (~one row per machine), so the lost-place cost is low. Left unimplemented
deliberately; revisit with focus-return to the table caption/heading if the list grows or user
feedback surfaces it._

#### RESOLVED (accepted trade-off): The unlabeled-token cell renders a bare "—"
`token.label || "—"` shows an em-dash for unlabeled tokens. The row is still fully identifiable via
the revoke button's accessible name (which says "the unlabeled token … #id"), so this is cosmetic,
but a screen reader may read "—" as "em dash" or skip it.
_Resolved: **accepted as-is.** The load-bearing identification is the button's accessible name, which
already spells out "the unlabeled token"; the visible cell is cosmetic. Not worth a special-case
render for v1._

---

### Senior Elixir Engineer

#### RESOLVED (accepted trade-off): After an admin revoke clamps the page, the URL query string is left stale
The admin `revoke` handler re-paginates inline via `assign_page(socket, socket.assigns.page)` and
reassigns `@page` from the clamped `Pagination.paginate` result (spec-sanctioned). But when revoking
the last row on the last page clamps `@page` from 2→1, the address bar still reads `?page=2`. Behavior
is correct (the rendered page and pager are page 1); only the URL is cosmetically stale until the next
pager click or reload (a reload re-requests page 2, which re-clamps harmlessly).
_Resolved: **accepted as-is.** The requirements explicitly sanction the inline-reassign approach, and
the reassigned-from-`result.page` state is correct and tested. The `push_patch` variant (which would
also sync the URL) remains an equivalent option if URL fidelity is ever wanted._

#### Assessed — no change: `with {n, ""} <- Integer.parse(id), do: …` returns a non-nil sentinel on a bad id
On an unparseable/garbage `phx-value-id`, the `with` (no `else`) returns `:error` or `{n, "rest"}`
rather than nil — but the following `case token do %ApiToken{} -> …; _ -> benign end` catches those in
the `_` clause, so the outcome is the intended benign no-op with no crash. Correct as written;
recorded here only because the sentinel value is implicit. No change proposed.

---

### Security Engineer

#### Assessed — no change (positive finding): the no-op flash is not an enumeration oracle
On the self-serve page a forged **other-user** id, an **already-revoked own** id, and a
**nonexistent** id all fetch as nil and yield the identical `"That token was already inactive"`
flash — so the response does not reveal whether a given id exists or belongs to someone else. Combined
with the ownership-scoped, active-only `get_user_api_token/2` (the load-bearing IDOR guard) and the
admin handler's `portal_is_admin` re-check + active-only `get_active_api_token/1`, the authorization
surface is sound. No change.

<!-- Phase 3 self-review complete. Finding #1 (QA) applied; #2–#5 resolved as accepted trade-offs /
     positive findings. Re-review after applying #1 surfaced no new issues (the change was a single
     additive unit test). -->

---

## Self-Review (second pass — code-verified against the real source)

<!-- A fresh multi-role pass focused on the *code and test code* in this implementation plan (the
     earlier passes lived mostly in requirements.md). Every candidate below was chased into the actual
     source before being written; the two empirical ones were proven by running real code (noted
     inline). Candidates that did not survive verification are listed under DISMISSED. -->

### Senior Engineer / Security Engineer

#### RESOLVED: The merged `cli_token` mount has a single `@user`-requiring clause — an unauthenticated first-load crashes instead of redirecting to login
_Resolved: added a fallback `def mount(_params, _session, socket), do: {:ok, redirect(socket, to:
"/reports")}` clause after the `@user` clause (mirroring `AuditLogLive.Index`), plus a test —
"an unauthenticated visit redirects instead of crashing" — asserting `live(conn, ~p"/reports/cli-token")`
redirects rather than raising._

The plan replaces the current permissive mount
(`def mount(_params, _session, socket)`, one clause, never touches `@user`) with a **single** clause
that pattern-matches `%{assigns: %{user: user}}` and calls `list_active_api_tokens(user.id)` — with
**no fallback clause**. That assumes `@user` is always assigned by mount time. It is not, for the
**not-logged-in** path.

**Verified against the real source:**
- `ReportServerWeb.Auth.Plug.call/2` (`auth/plug.ex:10-17`) does **not** halt an unauthenticated
  request — it only saves the portal URL and merges public session vars.
- `ReportServerWeb.ReportLive.Auth.on_mount/4` (`report_live/auth.ex`) assigns `:user` **only** on the
  logged-in-and-authorized branch. The logged-in-but-unauthorized branch `{:halt}`s (redirect to `/`,
  so mount never runs). The **not-logged-in** branch attaches a `:handle_params` redirect hook and
  returns **`{:cont, socket}` without assigning `:user`**.
- LiveView lifecycle runs `mount/3` **before** `handle_params/3`, so the login-redirect hook fires
  *after* mount. A user-less socket therefore reaches mount first.
- The current `ReportLive.CliToken` mount matches any socket, so today an unauthenticated hit to
  `/reports/cli-token` redirects cleanly to login. `report_live_test.exs:7-12` proves this path is
  real: `live(conn, ~p"/reports")` (no login) redirects to `/auth/login?return_to=/reports`.
- The established pattern for these gated pages is a **fallback mount clause**: `AuditLogLive.Index`
  has two `def mount` clauses (`audit_log_live/index.ex:7-18`), `ReportRunLive.Index` has three, and
  `ReportLive.Index` matches on **params** (`%{"path" => path}`) rather than on `@user` — none of them
  crash on a user-less socket. The plan's `all_tokens_live` page correctly carries the fallback clause;
  only the **merged `cli_token`** mount omits it.

Consequence: with the plan as written, a not-logged-in visitor to `/reports/cli-token` raises
`FunctionClauseError` at mount (a 500), a **regression** from the current clean login redirect. The
existing `cli_token_live_test.exs:55` "without report access" test does **not** catch this — it
exercises the logged-in-but-unauthorized `{:halt}` path (redirect to `/`), not the not-logged-in path.

**Suggested resolution**: keep a fallback mount clause on the merged page, mirroring
`AuditLogLive.Index` — e.g. add `def mount(_params, _session, socket), do: {:ok, redirect(socket, to:
"/reports")}` after the `@user` clause (the on_mount hook then completes the login redirect), or match
the first clause loosely and read `@user` defensively. Add a test asserting an unauthenticated
`live(conn, ~p"/reports/cli-token")` redirects rather than crashes.

### QA Engineer

#### RESOLVED: The admin "sees all users' active tokens" test asserts a raw apostrophe that HEEx escapes → the test fails as written
_Resolved: changed the seeded label to the apostrophe-free "Dana Laptop" (matching the self-serve
tests' convention) and updated the assertion accordingly; the `owner.portal_email` assertion still
proves the name+email User column. A comment records why an apostrophe label would break a raw
`html =~` assertion._

The admin-page test seeds `api_token_fixture(owner, "Dana's Laptop")` and asserts
`assert html =~ "Dana's Laptop"`. The label renders through `<%= token.label %>` in the `token_table`
component, and HEEx HTML-escapes attribute/text output, so the rendered markup contains
`Dana&#39;s Laptop`, **not** `Dana's Laptop` — the assertion never matches.

**Verified empirically** (throwaway, run against this app's deps, then discarded):
`Phoenix.HTML.html_escape("Dana's Laptop") |> Phoenix.HTML.safe_to_string()` →
`Dana&#39;s Laptop`. `<%= %>` in HEEx delegates to exactly this escaping. This is the *same* mechanism
the component test elsewhere in this plan correctly accounts for
(`assert html =~ "the token labeled &#39;Doug&#39;s MacBook&#39;"`) — so the two tests are internally
inconsistent.

**Suggested resolution**: assert on an apostrophe-free label (as every self-serve test already does —
"My Laptop", "Old Machine", …), or assert the escaped form `"Dana&#39;s Laptop"`, or drop the label
assertion and lean on the already-present `assert html =~ owner.portal_email` (which needs no
apostrophe). Same care applies to any future label-with-punctuation assertion.

#### RESOLVED: The admin "revoke the only token on the last page" test targets a page-1 row, not the last-page row (passes, but not for the stated reason)
_Resolved: changed the revoked row to `Enum.min_by(tokens, & &1.id)` — the actual page-2 row under
`[desc: inserted_at, desc: id]` ordering — with a comment explaining the id ordering, so the test now
exercises the stated "revoke the row on the last page" path (the assertions are unchanged and still
pass)._

The test seeds 26 tokens, navigates to `?page=2`, and revokes
`last = List.last(Enum.sort_by(tokens, & &1.id))`. But the admin query orders
`[desc: inserted_at, desc: id]`, and with all 26 rows sharing (near-)identical `inserted_at`, the
order is effectively **desc id** — so page 1 holds the 25 **highest** ids and page 2 holds the single
**lowest** id. `List.last(sort_by(… & &1.id))` is the **highest** id — i.e. the **first row of page
1**, not the row displayed on page 2.

**Verified against the real source**: `Pagination.paginate/3` (`pagination.ex:20-24`) applies
`limit 25 |> offset (page-1)*25`; with the plan's `order_by [desc: inserted_at, desc: id]` the page-2
row is the minimum id. The test still **passes** (revoking any one of the 26 collapses the list to 25
rows → `total_pages` 2→1 → the `min(page, total_pages)` clamp lands page 1 → pager hidden), so it does
exercise the clamp — but it does not exercise "revoke the row you are looking at on the last page,"
and the inline comment ("page 2 holds one row … `last`") is misleading to an implementer.

**Suggested resolution**: revoke the actual last-page row —
`last = Enum.min_by(tokens, & &1.id)` (or `List.first(Enum.sort_by(tokens, & &1.id))`) — and keep the
existing assertions; the test then matches its stated intent.

### Candidates investigated and DISMISSED (verification evidence)

- **`create_api_token/2` return shape** — the plan's `{:ok, raw_token, _api_token}` matches
  `accounts.ex:79-91`. `verify_api_token/1` returns `{:ok, user, token}` / `:error`
  (`accounts.ex:93-104`), matching the tests' `{:ok, _u, _t}` / `:error`. `api_token_fixture/2` returns
  `{raw, token}` (`accounts_fixtures.ex:27-30`), matching every `{raw, token}` / `|> elem(1)` use. No
  issue.
- **`Pagination.paginate` result shape** — returns `%{items:, page:, per_page:, total_pages:,
  total_count:}` (`pagination.ex:26`); the admin `assign_page` and the stable-order context test use
  only present keys. `normalize_page/1` accepts int/binary/nil (`pagination.ex:29-36`), so both the
  `handle_params` (string) and revoke-handler (integer `@page`) call sites are safe. No issue.
- **`@user` present at mount for the admin page** — unlike the merged page, `all_tokens_live` mount
  *does* carry a fallback clause, and its admin clause only runs when on_mount assigned an admin user;
  the redirect-a-non-admin test uses the default researcher fixture (`can_access_reports?` true →
  reaches mount → second clause → redirect `/reports`), which the assertion matches. No issue.
- **Component/API signatures** — `<.pager>` attrs `page/total_pages/path_fun/label`
  (`custom_components.ex:355-358`), `<.described_link>` (`navigate/description` + default inner slot,
  `:57-88`), `<.breadcrumbs>` (`previous/current`, `:222-224`), and `report_runs`' name-only
  `include_user` (`:328`) all match the plan's usage; User carries `portal_email`
  (`user.ex:16`). `@is_root` + the `@user.portal_is_admin` block already exist in
  `report_live/index.html.heex`. Token prefix is `"ccd_"` (`accounts.ex:10`), so the `html =~ "ccd_"`
  assertions hold. No issue.
