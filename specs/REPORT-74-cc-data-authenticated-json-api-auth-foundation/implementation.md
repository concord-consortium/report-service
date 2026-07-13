# Implementation Plan: cc-data Authenticated JSON API + Auth Foundation

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-74
**Requirements Spec**: [requirements.md](requirements.md)
**Status**: **In Development**

All paths below are relative to `server/` unless they start with `specs/`.

**Cross-cutting decisions embodied in this plan** (each is an Open Question at the end of this
file; the code below follows the recommended option):

- **Token format**: opaque random (`ccd_` + 256-bit base64url) with SHA-256 hash at rest (OQ-1).
- **AWS test seams**: config-swappable stub modules, no new deps (OQ-2).
- **State refresh/self-start**: extracted into a shared `Reports.AthenaRunOps` module that the
  Show LiveView is retrofitted to call (OQ-3).
- **Login round-trip preservation**: server-side session storage of the validated request (OQ-4).

## Implementation Plan

### Release migrator + deployment ordering note

**Summary**: The repo has no production migration mechanism — the release start script only
starts the app (`rel/overlays/bin/server`), the runner image has no `mix` (`Dockerfile:104`),
and the README's deploy steps (build → push → CloudFormation ImageUrl update) never mention
migrations. That gap becomes acute in this story: the web-audit step routes the **existing**
web CSV/post-processing downloads through the fail-closed `AuditLog.issue_download_url/6`, so
deploying the new image before the `data_access_log` migration breaks the primary existing
export path, not just the new API. This step adds the standard phx.gen.release migrator module
so the deployed container can run its own migrations, plus the deploy-ordering documentation.

**Files affected**:
- `lib/report_server/release.ex` — new (standard phx.gen.release migrator)
- `README.md` — deploy section gains the migration step

**Estimated diff size**: ~40 lines

```elixir
defmodule ReportServer.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed: bin/report_server eval "ReportServer.Release.migrate"
  """
  @app :report_server

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
```

README deploy-section addition (between the push and the CloudFormation update):

> Before updating the stack to the new image, apply any new migrations by running
> `bin/report_server eval "ReportServer.Release.migrate"` in a one-off task/container built
> from the new image (or, from a workstation with DB access, `MIX_ENV=prod mix ecto.migrate`
> with the RDS connection configured). **For this release specifically**: the
> `data_access_log` migration must be applied before the new image serves traffic — the web
> download paths fail closed against that table.

(The three migrations in this plan are additive `create table`s, so old-app + new-schema is
safe and rollback needs no schema change.)

---

### API token model: migration, schema, mint/verify/revoke

**Summary**: The per-user token foundation everything else builds on. Creates the `api_tokens`
table and the `Accounts` functions to mint (returning the raw token exactly once), verify
(resolving to the same `%Accounts.User{}` the LiveViews use), revoke, and touch `last_used_at`.
No routes yet — pure data layer, independently testable.

**Files affected**:
- `priv/repo/migrations/<ts>_create_api_tokens.exs` — new
- `lib/report_server/accounts/api_token.ex` — new
- `lib/report_server/accounts.ex` — add token functions
- `test/report_server/accounts_test.exs` — new (or extend if created earlier)
- `test/support/fixtures/accounts_fixtures.ex` — new (`user_fixture/1`, `api_token_fixture/1`)

**Estimated diff size**: ~320 lines

Migration (follows the `create_report_runs.exs` pattern — bigint ids, `references(:users)`,
`timestamps(type: :utc_datetime)`):

```elixir
defmodule ReportServer.Repo.Migrations.CreateApiTokens do
  use Ecto.Migration

  def change do
    create table(:api_tokens) do
      add :token_hash, :string, null: false
      add :label, :string
      add :last_used_at, :utc_datetime
      add :revoked_at, :utc_datetime
      add :user_id, references(:users, on_delete: :nothing), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:api_tokens, [:token_hash])
    create index(:api_tokens, [:user_id])
  end
end
```

Schema:

```elixir
defmodule ReportServer.Accounts.ApiToken do
  use Ecto.Schema

  import Ecto.Changeset

  alias ReportServer.Accounts.User

  schema "api_tokens" do
    field :token_hash, :string
    field :label, :string
    field :last_used_at, :utc_datetime
    field :revoked_at, :utc_datetime

    belongs_to :user, User, foreign_key: :user_id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(api_token, attrs) do
    api_token
    |> cast(attrs, [:user_id, :token_hash, :label, :last_used_at, :revoked_at])
    |> validate_required([:user_id, :token_hash])
    |> unique_constraint(:token_hash)
  end
end
```

Context functions added to `ReportServer.Accounts`. The raw token exists only in the return
value of `create_api_token/2` — the DB stores the SHA-256 hex digest. The `ccd_` prefix makes
tokens grep-able in secret scanners and visually identifiable in the CLI.

```elixir
alias ReportServer.Accounts.ApiToken

@api_token_prefix "ccd_"
@api_token_bytes 32

def create_api_token(user = %User{}, label \\ nil) do
  raw_token = @api_token_prefix <> Base.url_encode64(:crypto.strong_rand_bytes(@api_token_bytes), padding: false)

  result =
    %ApiToken{}
    |> ApiToken.changeset(%{user_id: user.id, token_hash: hash_api_token(raw_token), label: label})
    |> Repo.insert()

  case result do
    {:ok, api_token} -> {:ok, raw_token, api_token}
    {:error, changeset} -> {:error, changeset}
  end
end

def verify_api_token(raw_token) when is_binary(raw_token) do
  query = from t in ApiToken,
    where: t.token_hash == ^hash_api_token(raw_token),
    where: is_nil(t.revoked_at),
    preload: [:user]

  case Repo.one(query) do
    nil -> :error
    api_token -> {:ok, api_token.user, api_token}
  end
end
def verify_api_token(_), do: :error

def revoke_api_token(api_token = %ApiToken{}) do
  api_token
  |> ApiToken.changeset(%{revoked_at: DateTime.utc_now(:second)})
  |> Repo.update()
end

@touch_threshold_seconds 60

def touch_api_token(api_token = %ApiToken{}) do
  # fire-and-forget freshness marker for the STORY 2 UI; failures must not fail the request.
  # Thresholded: a CLI polling loop hits the API every second, and per-second UPDATEs are
  # pure binlog churn for a value STORY 2 reads at "used recently" granularity.
  now = DateTime.utc_now(:second)

  if api_token.last_used_at == nil ||
       DateTime.diff(now, api_token.last_used_at) >= @touch_threshold_seconds do
    api_token
    |> ApiToken.changeset(%{last_used_at: now})
    |> Repo.update()
  else
    {:ok, api_token}
  end
end

defp hash_api_token(raw_token) do
  :crypto.hash(:sha256, raw_token) |> Base.encode16(case: :lower)
end
```

`test/support/fixtures/accounts_fixtures.ex` (new — no user fixture exists today; needed by
nearly every later test):

```elixir
defmodule ReportServer.AccountsFixtures do
  alias ReportServer.Repo
  alias ReportServer.Accounts
  alias ReportServer.Accounts.User

  def user_fixture(attrs \\ %{}) do
    defaults = %{
      portal_server: "learn.concord.org",
      portal_user_id: System.unique_integer([:positive]),
      portal_login: "user#{System.unique_integer([:positive])}",
      portal_first_name: "Test",
      portal_last_name: "User",
      portal_email: "test#{System.unique_integer([:positive])}@example.com",
      portal_is_admin: false,
      portal_is_project_admin: false,
      portal_is_project_researcher: true
    }

    struct(User, Map.merge(defaults, Map.new(attrs))) |> Repo.insert!()
  end

  def api_token_fixture(user, label \\ nil) do
    {:ok, raw_token, api_token} = Accounts.create_api_token(user, label)
    {raw_token, api_token}
  end
end
```

Tests (`accounts_test.exs`), summarized:
- mint returns a `ccd_`-prefixed raw token; the DB row stores only the 64-char hex hash, never the raw value
- two mints for one user coexist (multiple active tokens) with distinct hashes
- verify: valid raw token → `{:ok, user, token}` with the user preloaded; unknown/garbage/`nil` → `:error`
- revoke: verify returns `:error` immediately after `revoke_api_token/1`
- `touch_api_token/1` sets `last_used_at` when nil; a second touch within the 60s threshold is a
  no-op (`last_used_at` unchanged); a token with `last_used_at` older than the threshold is
  re-touched
- optional label is persisted

---

### API pipeline: bearer plug, contract error rendering, `/api/v1` scope

**Summary**: The `:api_authenticated` pipeline from the requirements — a bearer-verifying plug
(analogous to `Auth.Plug`) that also enforces the `can_access_reports?` role gate, plus the
API's own error rendering (the cc-data `{"error": CODE, ...}` contract, which intentionally
differs from `ReportServerWeb.ErrorJSON`). Establishes the bearer-auth `ConnCase` test pattern.
Ships with a trivial `GET /api/v1/ping` so the pipeline is testable before the real endpoints
land in the next steps (the ping route is removed by the runs-endpoint commit).

**Files affected**:
- `lib/report_server_web/api/auth_plug.ex` — new
- `lib/report_server_web/api/error_helpers.ex` — new
- `lib/report_server_web/api/v1/ping_controller.ex` — new (temporary)
- `lib/report_server_web/api/v1/fallback_controller.ex` — new (catch-all contract 404 for unknown `/api/v1` paths)
- `lib/report_server_web/router.ex` — add `:api_authenticated` pipeline + `/api/v1` scope + catch-all scope
- `lib/report_server_web/controllers/error_json.ex` — API-path clause for raised exceptions
- `test/support/conn_case.ex` — add bearer helpers + SQL sandbox setup
- `test/report_server_web/api/auth_plug_test.exs` — new

**Estimated diff size**: ~330 lines

Error helpers — one module renders every contract error shape so all controllers/plugs share it
(single-line JSON bodies; the `context` map is merged in for e.g. `NOT_READY`'s state):

```elixir
defmodule ReportServerWeb.Api.ErrorHelpers do
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  @statuses %{
    "BAD_REQUEST" => 400,
    "NOT_AUTHENTICATED" => 401,
    "NOT_FOUND" => 404,
    "NOT_READY" => 409,
    "SERVER_ERROR" => 500
  }

  def render_error(conn, code, message, context \\ %{}) do
    conn
    |> put_status(Map.fetch!(@statuses, code))
    |> json(Map.merge(context, %{error: code, message: message}))
    |> halt()
  end

  def not_authenticated(conn), do: render_error(conn, "NOT_AUTHENTICATED", "You must supply a valid API token.")
  def not_found(conn), do: render_error(conn, "NOT_FOUND", "Not found.")
  def bad_request(conn, message), do: render_error(conn, "BAD_REQUEST", message)
  def server_error(conn), do: render_error(conn, "SERVER_ERROR", "An internal error occurred.")
end
```

Contract shape for **raised** exceptions (Self-Review Round 3): explicit renders go through
`ErrorHelpers`, but anything that raises inside `/api/v1` (a bug, DB outage) is rendered by the
endpoint's `render_errors` fallback — `ReportServerWeb.ErrorJSON`, whose
`{"errors": {"detail": ...}}` shape the contract intentionally differs from. Phoenix passes the
`conn` to the error view's assigns, so one path-keyed clause keeps the contract's "one error
shape everywhere" guarantee without touching non-API error rendering. The same clause covers
`POST /auth/cli/token` (also a contract surface — e.g. a malformed JSON body raises
`Plug.Parsers.ParseError` → 400):

```elixir
# error_json.ex — added ABOVE the existing catch-all render/2
@api_statuses %{
  400 => "BAD_REQUEST",
  401 => "NOT_AUTHENTICATED",
  404 => "NOT_FOUND",
  409 => "NOT_READY"
}

def render(template, %{conn: %Plug.Conn{request_path: path}})
    when binary_part(path, 0, 5) == "/api/" or path == "/auth/cli/token" do
  status = template |> String.split(".") |> hd() |> String.to_integer()
  code = Map.get(@api_statuses, status, "SERVER_ERROR")
  %{error: code, message: Phoenix.Controller.status_message_from_template(template)}
end
```

(The message is the generic status phrase — never exception details, satisfying the
safe-content requirement. `binary_part/3` guards against paths shorter than 5 bytes via the
`when` fallthrough: a non-matching or too-short path falls to the existing catch-all clause.)

**Scope caveat (Self-Review Round 4, tightened in External Review Round 2)**: this clause fires
only when the **json format is set on the conn**. Routed API requests always have it — the
pipelines' `plug :force_json` stores the json format unconditionally (Round 2 replaced
`plug :accepts, ["json"]`, which raised `Phoenix.NotAcceptableError` on an explicit non-JSON
`Accept` header **before** the auth plug or catch-all ran; with `render_errors` listing html
before json, `Accept: text/html` produced an HTML 406 instead of the contract shape) — and
unknown `/api/v1` paths never reach `ErrorJSON` at all (the router catch-all above renders the
contract 404 directly). The one remaining pre-negotiation failure is
`Plug.Parsers.ParseError`: a malformed JSON body raises in the **endpoint's** parser, before
routing, where Phoenix falls back to the `Accept` header and renders **HTML** for clients that
send none (verified dynamically — Go's `net/http` sends no `Accept` header by default). The
contract shape for malformed-body failures therefore requires `Accept: application/json` — a
STORY 4 CLI obligation recorded in the requirements Contract section; the exception-fallback
tests set the header explicitly.

Auth plug — a failed role check renders the same `NOT_AUTHENTICATED` as a bad token (no role
leak, per the requirements). `can_access_reports?/1` takes a session-shaped map today (verified
in the pre-spec throwaway tests), so the plug wraps the resolved user in `%{"user" => user}`
rather than changing the existing function:

```elixir
defmodule ReportServerWeb.Api.AuthPlug do
  import Plug.Conn

  alias ReportServer.Accounts
  alias ReportServerWeb.Auth
  alias ReportServerWeb.Api.ErrorHelpers

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> raw_token] <- get_req_header(conn, "authorization"),
         {:ok, user, api_token} <- Accounts.verify_api_token(raw_token),
         true <- Auth.can_access_reports?(%{"user" => user}) do
      Accounts.touch_api_token(api_token)
      assign(conn, :current_user, user)
    else
      _ -> ErrorHelpers.not_authenticated(conn)
    end
  end
end
```

Router changes:

```elixir
# force_json replaces `plug :accepts, ["json"]` in BOTH API pipelines (External Review
# Round 2): :accepts raises Phoenix.NotAcceptableError on an explicit non-JSON Accept header
# before any controller or catch-all runs, and with render_errors listing html before json
# that renders an HTML 406 — the API ignores Accept entirely, so the contract shape holds
# regardless of the header. Storing the format also makes Phoenix's error renderer pick
# ErrorJSON for every raise after the pipeline. Defined alongside allow_iframe/2 at the
# bottom of the router (put_format is already imported via `use ReportServerWeb, :router`).
defp force_json(conn, _opts), do: put_format(conn, "json")

# the existing :api pipeline (currently unused by any route) changes the same way:
pipeline :api do
  plug :force_json
end

pipeline :api_authenticated do
  plug :force_json
  plug ReportServerWeb.Api.AuthPlug
end

scope "/api/v1", ReportServerWeb.Api.V1 do
  pipe_through :api_authenticated

  get "/ping", PingController, :ping  # temporary; replaced by report routes
end

# catch-all AFTER every real /api/v1 route (Self-Review Round 4): unknown API paths render
# the contract 404 through the :api pipeline — whose `plug :force_json` stores the json
# format regardless of the Accept header (Round 2) — instead of raising NoRouteError, which
# Phoenix's error renderer turns into an HTML page for header-less clients. Unknown paths
# deliberately 404 without requiring auth (standard; leaks nothing).
scope "/api/v1", ReportServerWeb.Api.V1 do
  pipe_through :api

  match :*, "/*path", FallbackController, :not_found
end
```

```elixir
defmodule ReportServerWeb.Api.V1.FallbackController do
  use ReportServerWeb, :controller

  alias ReportServerWeb.Api.ErrorHelpers

  def not_found(conn, _params), do: ErrorHelpers.not_found(conn)
end
```

`ConnCase` additions (the bearer-auth test pattern this story establishes — requirements
Technical Notes call out that none exists today):

```elixir
def register_and_put_bearer_token(%{conn: conn}) do
  user = ReportServer.AccountsFixtures.user_fixture()
  {raw_token, api_token} = ReportServer.AccountsFixtures.api_token_fixture(user)
  conn = Plug.Conn.put_req_header(conn, "authorization", "Bearer #{raw_token}")
  %{conn: conn, user: user, raw_token: raw_token, api_token: api_token}
end
```

(Registered as a `setup` helper; tests opt in with `setup :register_and_put_bearer_token`.)
`ConnCase` also gains the standard `Ecto.Adapters.SQL.Sandbox` checkout in `setup` (it has none
today because no existing conn test touches the DB — copy the `DataCase.setup_sandbox/1` lines).

Tests, summarized:
- no `Authorization` header → 401, body is exactly `{"error": "NOT_AUTHENTICATED", "message": ...}`
- garbage token / revoked token → same 401 body
- valid token for a user with all role flags false → same 401 body (indistinguishable role gate)
- valid token (researcher flag) → 200, `conn.assigns.current_user` is the owning user, and the token row's `last_used_at` is set
- wrong scheme (`Basic xyz`) → 401
- exception fallback: an unknown path under `/api/v1` hits the catch-all → 404 with the
  **contract** shape `{"error": "NOT_FOUND", ...}`, asserted **without** an `Accept` header,
  **with** `Accept: application/json`, and **with `Accept: text/html`** (the `NoRouteError`
  path it replaces renders HTML for header-less clients — Round 4; the explicit-html case is
  External Review Round 2 — the old `:accepts` plug raised `NotAcceptableError` and rendered
  an HTML 406 before the catch-all ran); a routed API request with `Accept: text/html` and no
  bearer token → **401 in the contract shape** (the same Round 2 guarantee on a routed path);
  a raised exception inside a routed API request (assert via `assert_error_sent` or a
  temporary raising ping clause) → 500 with `{"error": "SERVER_ERROR", ...}` and no exception
  detail in the body (no `Accept` header needed — the pipeline's `force_json` already stored
  the format); a malformed JSON body POSTed to `/auth/cli/token` **with**
  `Accept: application/json` → 400 in the contract shape (the pre-router `ParseError` case;
  without the header Phoenix renders HTML — the documented CLI obligation); a non-API path's
  error rendering is unchanged (existing `ErrorJSON` shape)

---

### `data_access_log`: migration, context, fail-closed issuance helper

**Summary**: The audit table and the single audit-write path every logged surface (API
downloads, web downloads, post-processing buttons) calls. Encodes the requirements' pinned
fail-closed order — presign first (no row on presign failure), audit write second (discard URL
on write failure), return URL only after the row commits — as one helper so no call site can
get the order wrong. Schema carries the STORY 3 accommodations (nullable cursor, endpoint-set
JSON, artifact-context/job id).

**Files affected**:
- `priv/repo/migrations/<ts>_create_data_access_log.exs` — new
- `lib/report_server/audit_log/data_access_log_entry.ex` — new
- `lib/report_server/audit_log.ex` — new context
- `test/report_server/audit_log_test.exs` — new

**Estimated diff size**: ~330 lines

Migration:

```elixir
defmodule ReportServer.Repo.Migrations.CreateDataAccessLog do
  use Ecto.Migration

  def change do
    create table(:data_access_log) do
      # what happened: e.g. "download_url_issued"; STORY 3 adds e.g. "answers_page_read"
      add :event, :string, null: false
      # which surface: "web" | "api"
      add :source, :string, null: false
      # what data: "run_csv" | "job_result"; STORY 3 adds "answers" | "history"
      add :data_type, :string, null: false
      # requesting user (may be an admin downloading another user's run via the web)
      add :user_id, references(:users, on_delete: :nothing), null: false
      add :report_run_id, references(:report_runs, on_delete: :nothing), null: false
      # denormalized filter snapshot so the log row is self-contained even if the run changes
      add :report_filter, :map
      add :report_slug, :string
      # artifact context: post-processing job id for job_result rows; null for plain CSV rows
      add :job_id, :integer
      # STORY 3 per-page events: page/cursor progress; null for URL-issuance rows
      add :cursor, :string
      # STORY 3 per-page events: resolved remote_endpoint set; null for URL-issuance rows
      add :endpoint_set, :map

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:data_access_log, [:user_id])
    create index(:data_access_log, [:report_run_id])
    create index(:data_access_log, [:inserted_at])
  end
end
```

(Append-only: no `updated_at`, and the context exposes no update/delete functions.)

**Deliberate one-way door** (Self-Review Round 3): the `on_delete: :nothing` FKs are RESTRICT
on MySQL — once a run is audited, its `report_runs` and `users` rows can never be deleted
without first handling the audit rows. That is the intended integrity posture (the row also
denormalizes `report_slug`/`report_filter` so it stays meaningful), but any future
run-deletion tooling (`Reports.delete_report_run/1` exists, currently uncalled) must account
for it.

Schema (`DataAccessLogEntry`) — pinned in full (External Review Round 2: the admin audit page
runs `preload: [:user]` and its template dereferences `entry.user.*`, and Ecto does **not**
infer associations from the migration FK — a fields-only "mirror" schema would let the
audit-write path work while the audit page crashes on `%Ecto.Association.NotLoaded{}`;
`belongs_to :report_run` is declared for FK symmetry). Two pinned lines are load-bearing:
`timestamps(type: :utc_datetime, updated_at: false)` (Self-Review Round 4 — Ecto **schema**
timestamps default to `:naive_datetime` regardless of the migration's column type; the app's
`generators: [timestamp_type: :utc_datetime]` affects generators only, and the audit-page
template calls `DateTime.to_iso8601(entry.inserted_at)`, which **raises** on a
`NaiveDateTime`), and the changeset's FK constraints — without them, a violation makes
`Repo.insert` **raise** `Ecto.ConstraintError` instead of returning `{:error, changeset}`,
bypassing the designed `{:error, :audit, _}` branch (a raise still fails closed via the
API-path `ErrorJSON` fallback, but the designed path is the changeset error):

```elixir
defmodule ReportServer.AuditLog.DataAccessLogEntry do
  use Ecto.Schema

  import Ecto.Changeset

  alias ReportServer.Accounts.User
  alias ReportServer.Reports.ReportRun

  schema "data_access_log" do
    field :event, :string
    field :source, :string
    field :data_type, :string
    field :report_filter, :map
    field :report_slug, :string
    field :job_id, :integer
    field :cursor, :string
    field :endpoint_set, :map

    belongs_to :user, User, foreign_key: :user_id
    belongs_to :report_run, ReportRun, foreign_key: :report_run_id

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc false
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:event, :source, :data_type, :user_id, :report_run_id, :report_filter,
                    :report_slug, :job_id, :cursor, :endpoint_set])
    |> validate_required([:event, :source, :data_type, :user_id, :report_run_id])
    |> validate_inclusion(:event, ["download_url_issued"])
    |> validate_inclusion(:source, ["web", "api"])
    |> validate_inclusion(:data_type, ["run_csv", "job_result"])
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:report_run_id)
  end
end
```

(STORY 3 extends the inclusion lists when it adds its event/data types.)

Context:

```elixir
defmodule ReportServer.AuditLog do
  import Ecto.Query, warn: false

  require Logger

  alias ReportServer.Repo
  alias ReportServer.AuditLog.DataAccessLogEntry
  alias ReportServer.Reports.ReportRun

  @doc """
  Fail-closed download-URL issuance, in the order pinned by the requirements:
  1. presign (via `presign_fun`) — on failure return {:error, :presign, reason}, write no row
  2. write the audit row — on failure discard the URL and return {:error, :audit, reason}
  3. only then return {:ok, url}
  """
  def issue_download_url(source, data_type, report_run = %ReportRun{}, user_id, presign_fun, opts \\ []) do
    case presign_fun.() do
      {:ok, url} ->
        attrs = %{
          event: "download_url_issued",
          source: source,
          data_type: data_type,
          user_id: user_id,
          report_run_id: report_run.id,
          report_slug: report_run.report_slug,
          report_filter: dump_filter(report_run.report_filter),
          job_id: Keyword.get(opts, :job_id)
        }

        case create_entry(attrs) do
          {:ok, _entry} ->
            {:ok, url}
          {:error, reason} ->
            Logger.error("Audit write failed for report run #{report_run.id}: #{inspect(reason)}")
            {:error, :audit, reason}
        end

      {:error, reason} ->
        {:error, :presign, reason}
    end
  end

  def create_entry(attrs) do
    %DataAccessLogEntry{}
    |> DataAccessLogEntry.changeset(attrs)
    |> Repo.insert()
  end

  defp dump_filter(nil), do: nil
  defp dump_filter(report_filter), do: Map.from_struct(report_filter)
end
```

(This commit exposes only `create_entry/1` and `issue_download_url/6` — everything the API and
web surfaces need to write. The read side, `list_entries_paginated/1`, ships with the
admin-page step where its only caller and its `ReportServer.Pagination` dependency live —
resolved in OQ-6.)

Tests, summarized:
- happy path: presign_fun returns `{:ok, url}` → row written with the exact attrs (source/data_type/job_id/filter snapshot), `{:ok, url}` returned
- presign failure: presign_fun returns `{:error, reason}` → **no row written**, `{:error, :presign, reason}` returned
- audit failure: force a changeset error via an invalid `source` (inclusion validation) passed
  to `issue_download_url/6` directly → URL discarded, `{:error, :audit, _}` returned, no row.
  (Note: a "deleted user row" cannot force this — the FKs on `api_tokens`/`report_runs` RESTRICT
  the user delete itself; the inclusion-validation route is the reliable unit-level forcing
  mechanism. The fail-closed **negative** path is covered here at the unit level by design;
  controller/LiveView tests cover the presign-failure half, which is stub-forceable — see the
  download-step and web-audit-step test lists.)
- both fail-closed invariants asserted: every `{:ok, url}` has exactly one row; a failure path leaves zero rows
- entries are append-only: the context module exposes no update/delete

---

### Shared Athena run ops: state refresh + self-start, extracted from the Show LiveView

**Summary**: The state-freshness and self-start requirements say the API must use "the same path
the Show LiveView uses". This step extracts that path into `ReportServer.Reports.AthenaRunOps`
(query start from a stored filter; non-terminal state refresh persisting **both**
`athena_query_state` and `athena_result_url`) and retrofits `Show` to call it, so the logic has
one home and the API inherits LiveView-proven behavior (OQ-3). Also introduces the
config-swappable `AthenaDB` seam the API tests need (OQ-2).

**Files affected**:
- `lib/report_server/reports/athena_run_ops.ex` — new
- `lib/report_server_web/live/report_run_live/show.ex` — retrofit `run_report/5` (nil-query-id clause) and `check_query_state/2` to delegate
- `lib/report_server/reports/tree.ex` — add `athena_report_slugs/0`
- `config/test.exs` — add the `:report_server, :output` config (moved here from the jobs step:
  the Show smoke test renders run pages whose `PostProcessingComponent` boots a `JobServer`,
  and `Output.config/0` raises on the missing config — see the test notes below)
- `test/report_server/reports/athena_run_ops_test.exs` — new
- `test/report_server_web/live/report_run_show_live_test.exs` — new (retrofit smoke test)
- `test/support/athena_db_stub.ex` — new

**Estimated diff size**: ~400 lines

```elixir
defmodule ReportServer.Reports.AthenaRunOps do
  import Ecto.Query, warn: false

  require Logger

  alias ReportServer.Repo
  alias ReportServer.Reports
  alias ReportServer.Reports.{Report, ReportQuery, ReportRun, Tree}

  # config seams so tests can stub Athena/S3 and the report tree without AWS credentials,
  # a live portal DB, or network (OQ-2; the real get_query implementations call
  # LearnerData.fetch_and_upload, which needs both)
  defp athena_db(), do: Application.get_env(:report_server, :athena_db, ReportServer.AthenaDB)
  defp tree(), do: Application.get_env(:report_server, :report_tree, Tree)

  def non_terminal?(%ReportRun{athena_query_state: state}) when state in [nil, "queued", "running"], do: true
  def non_terminal?(_), do: false

  @doc """
  Start the Athena query for a run that has none yet — the exact sequence the Show LiveView
  runs on mount (show.ex:168-172): report.get_query on the STORED filter -> get_sql ->
  AthenaDB.query -> persist athena_query_id + athena_query_state.
  """
  def start_query(report_run = %ReportRun{athena_query_id: nil}) do
    with report = %Report{} <- tree().find_report(report_run.report_slug),
         {:ok, query} <- report.get_query.(report_run.report_filter, report_run.user),
         {:ok, sql} <- ReportQuery.get_sql(query),
         {:ok, athena_query_id, athena_query_state} <- athena_db().query(sql, report_run.id, report_run.user),
         {:ok, report_run} <- Reports.update_report_run(report_run, %{athena_query_id: athena_query_id, athena_query_state: athena_query_state}) do
      {:ok, report_run}
    else
      nil -> {:error, "Unable to find report: #{report_run.report_slug}"}
      {:error, error} -> {:error, error}
      error -> {:error, "Unknown error: failed to run Athena report: #{inspect(error)}"}
    end
  end

  @doc """
  Refresh a non-terminal stored state from Athena, persisting BOTH fields returned by
  get_query_info/1 (mirrors the LiveView poll at show.ex:232-233). Terminal states are a no-op.
  """
  def refresh_query_state(report_run = %ReportRun{athena_query_id: athena_query_id}) when is_binary(athena_query_id) do
    if non_terminal?(report_run) do
      with {:ok, athena_query_state, athena_result_url} <- athena_db().get_query_info(athena_query_id),
           {:ok, report_run} <- Reports.update_report_run(report_run, %{athena_query_state: athena_query_state, athena_result_url: athena_result_url}) do
        {:ok, report_run}
      else
        {:error, error} -> {:error, error}
        error -> {:error, error}
      end
    else
      {:ok, report_run}
    end
  end
  def refresh_query_state(report_run = %ReportRun{}), do: {:ok, report_run}

  @doc """
  API entry point for GET /:id and /:id/download: self-start a never-started run, otherwise
  refresh non-terminal state. Failures serve the STORED run and log server-side, per the
  requirements' refresh-failure and start-failure clauses — the CLI polling loop must survive
  transient AWS errors.

  Self-start is SINGLE-FLIGHT (Self-Review Round 3): the query build is a portal-DB query plus
  an S3 upload that can take minutes, and the CLI polls ~1s — without a claim, every poll
  during the first start would stack another one. The claim is an atomic conditional UPDATE
  flipping athena_query_state nil -> "queued" (a contract-legal value, so concurrent polls
  reading the claimed row serve a truthful state); exactly one request wins and runs the
  start; losers serve the claimed "queued" state (External Review Round 1: a {0, _} means the
  row was no longer nil/nil at claim time, so the loser's stale pre-claim struct would
  mis-report null — "queued" is a truthful lower bound, self-correcting on the next ~1s poll).
  On start failure the claim is released (state back to nil) so the next poll retries. The
  Show-LiveView-vs-API concurrent start remains the requirements' accepted race (Show's mount
  start is unclaimed, same as today); a crash between claim and release leaves a
  "queued"/nil-id run that the API won't restart, but a Show-page visit still will (its start
  keys on athena_query_id alone) — mirroring today's recovery path.
  """
  def ensure_current(report_run = %ReportRun{id: id, athena_query_id: nil, athena_query_state: nil}) do
    claim = from r in ReportRun,
      where: r.id == ^id,
      where: is_nil(r.athena_query_id) and is_nil(r.athena_query_state)

    case Repo.update_all(claim, set: [athena_query_state: "queued", updated_at: DateTime.utc_now(:second)]) do
      {1, _} ->
        case start_query(report_run) do
          {:ok, report_run} ->
            report_run
          {:error, error} ->
            Logger.error("API self-start failed for report run #{id}: #{inspect(error)}")
            release = from r in ReportRun, where: r.id == ^id and is_nil(r.athena_query_id)
            Repo.update_all(release, set: [athena_query_state: nil])
            report_run
        end

      _ ->
        # another request holds the claim (or just won it): the row is no longer nil/nil,
        # so the stale pre-claim struct would mis-report null — serve the claimed state
        %{report_run | athena_query_state: "queued"}
    end
  end
  def ensure_current(report_run = %ReportRun{athena_query_id: nil}) do
    # claimed by an in-flight self-start elsewhere; serve the stored run
    report_run
  end
  def ensure_current(report_run = %ReportRun{}) do
    case refresh_query_state(report_run) do
      {:ok, report_run} ->
        report_run
      {:error, error} ->
        Logger.error("API state refresh failed for report run #{report_run.id}: #{inspect(error)}")
        report_run
    end
  end
end
```

`Tree.athena_report_slugs/0` — the "Athena-type by `report_slug`" classification the API list
query filters on (walks the same tree `find_report/1` searches, so the two can never disagree):

```elixir
def athena_report_slugs() do
  # root() serves the ETS-cached decorated tree (falls back to a fresh build in dev, where
  # the cache is disabled) — no per-request tree reconstruction
  root()
  |> collect_reports()
  |> Enum.filter(&(&1.type == :athena))
  |> Enum.map(&(&1.slug))
end

defp collect_reports(report = %Report{}), do: [report]
defp collect_reports(%ReportGroup{children: children}), do: Enum.flat_map(children, &collect_reports/1)
```

`Show` retrofit (before/after; behavior-preserving):

```elixir
# BEFORE (show.ex:168-189, the athena_query_id: nil clause of run_report/5)
defp run_report(report = %Report{type: :athena}, report_run = %ReportRun{id: report_run_id, athena_query_id: nil}, _sort_columns, _row_limit, live_view_pid) do
  with {:ok, query} <- report.get_query.(report_run.report_filter, report_run.user),
       {:ok, sql} <- ReportQuery.get_sql(query),
       {:ok, athena_query_id, athena_query_state} <- AthenaDB.query(sql, report_run_id, report_run.user),
       {:ok, _report_run} <- Reports.update_report_run(report_run, %{athena_query_id: athena_query_id, athena_query_state: athena_query_state}) do
    send(live_view_pid, :poll_query_state)
    {:ok, %{report_results: nil}}
  else
    ...
  end
end

# AFTER
defp run_report(%Report{type: :athena}, report_run = %ReportRun{athena_query_id: nil}, _sort_columns, _row_limit, live_view_pid) do
  case AthenaRunOps.start_query(report_run) do
    {:ok, _report_run} ->
      send(live_view_pid, :poll_query_state)
      {:ok, %{report_results: nil}}
    {:error, error} ->
      Logger.error(error)
      {:error, error}
  end
end
```

```elixir
# BEFORE (show.ex:230-243, check_query_state/2 inner with-block)
with {:ok, athena_query_state, athena_result_url} <- AthenaDB.get_query_info(athena_query_id),
     {:ok, report_run} <- Reports.update_report_run(report_run, %{athena_query_state: ..., athena_result_url: ...}) do

# AFTER — delegate; poll_query_state?/1 stays in the LiveView (its schedule concern), but the
# state test moves behind AthenaRunOps.non_terminal?/1 so there is one definition
case AthenaRunOps.refresh_query_state(report_run) do
  {:ok, report_run} ->
    maybe_poll_query_state(report_run, live_view_pid)
    report_run
  {:error, _} ->
    report_run
end
```

`test/support/athena_db_stub.ex` — an Agent holding canned responses per test (tests using it
run `async: false` and set `Application.put_env(:report_server, :athena_db, ReportServer.AthenaDBStub)`
in setup with an `on_exit` reset):

```elixir
defmodule ReportServer.AthenaDBStub do
  def start(responses), do: Agent.start_link(fn -> responses end, name: __MODULE__)

  def query(sql, report_run_id, user), do: apply_stub(:query, [sql, report_run_id, user])
  def get_query_info(query_id), do: apply_stub(:get_query_info, [query_id])
  def get_download_url(s3_url, filename), do: apply_stub(:get_download_url, [s3_url, filename])

  defp apply_stub(name, args) do
    Agent.get(__MODULE__, &Map.fetch!(&1, name)) |> apply(args)
  end
end
```

Tests, summarized:
- `refresh_query_state/1`: non-terminal stored state + stub returning `{:ok, "succeeded", "s3://..."}` → **both** fields persisted (the round-4 requirement); terminal stored state → no stub call, run unchanged; stub error → `{:error, _}` and stored fields untouched
- `ensure_current/1`: refresh failure returns the stored run (no raise); self-start failure returns the stored run with `athena_query_id` still nil **and releases the claim** (row state back to nil)
- `ensure_current/1` single-flight: (a) winning path — nil/nil run → claim flips the row to `"queued"`, `start_query` runs, row ends with the stub's query id/state; (b) losing path — a run whose ROW is already claimed (`athena_query_state: "queued"`, `athena_query_id: nil`) → **no** tree/athena stub calls, stored run served; (c) stale-struct path — call `ensure_current` twice with the same loaded nil/nil struct; the second call loses the `update_all` claim (0 rows), makes no stub calls, and **returns a struct with `athena_query_state: "queued"`**, not the stale pre-claim `nil` (External Review Round 1: the loser must reflect the claimed stored state, per the requirements' concurrent-polls-serve-stored-state clause)
- `start_query/1` — **the requirements-mandated persisted-filter test**: insert a run whose `%ReportFilter{}` (atom `filters`, populated dimensions) is round-tripped through MySQL, reload it, and run `start_query/1` with a stubbed tree report whose `get_query` asserts it received the **loaded** form (string `filters` entries, intact dimension arrays) and returns a real `%ReportQuery{}`; assert `athena_query_id`/`athena_query_state` persisted. The `tree()` seam in the code block (`Application.get_env(:report_server, :report_tree, Tree)`) is what makes this test writable — the real five `get_query` implementations need a live portal DB + S3 (`LearnerData.fetch_and_upload`), so the loaded-form contract is locked in at the `AthenaRunOps -> report.get_query` boundary; the real implementations' tolerance of loaded filters was verified statically and dynamically during requirements review (see requirements External Review Round 6). **Note**: seam-stubbed runs must still carry a real Athena `report_slug` — the API context queries filter by the real `Tree.athena_report_slugs()`, which is not seam-covered
- `Tree.athena_report_slugs/0` returns exactly the five Athena slugs (`student-answers`, `student-actions`, `student-actions-with-metadata`, `student-assignment-usage`, `teacher-actions`) and none of the portal slugs
- Show LiveView retrofit smoke test (`report_run_show_live_test.exs`, per self-review): log in as the run's owner via `log_in_conn`, open `/reports/runs/:id` for a persisted Athena run with `athena_query_id: nil` and stubbed `:athena_db` (returning `{:ok, "qid", "queued"}`) **and `:report_tree`** (canned report whose `get_query` returns a real `%ReportQuery{}` — Round 4: mount-start goes through `AthenaRunOps.start_query`, and the **real** `get_query` implementations query the portal DB, e.g. `teacher_actions_report.ex:8-9` `get_usernames`/`get_activities`, which the test env doesn't have — without the tree stub `get_query` errors and no `athena_query_id` is ever persisted) → page renders and the run row gains `athena_query_id` (mount-start through the retrofit); the run still carries a **real** Athena `report_slug` so Show's own un-seamed `Tree.find_report/1` in `handle_params` resolves the page's report struct. Second case with a stored `"running"` run needs only the `:athena_db` stub (no `get_query` involved) → the poll refresh persists the stub's `succeeded` state + result URL. **Both cases use a steps-less Athena slug** (`teacher-actions` or `student-assignment-usage`) so the succeeded-state render never boots the PostProcessing `JobServer` (whose S3 read is not seam-covered — `job_server.ex:159` calls `Aws.get_file_contents` directly); the `:output` test config added in this step is defense-in-depth for any other test that renders a succeeded run. Assertions target DB effects and basic rendering, not the `assign_async` results panel, to stay robust. Note: this pulls the `log_in_conn` ConnCase helper into this step (it was introduced later in the plan; it moves here)

---

### API v1: run list and show endpoints (keyset pagination, contract serialization)

**Summary**: `GET /api/v1/reports` and `GET /api/v1/reports/:id` — the first real endpoints.
Adds the Athena-only owner-scoped queries to the `Reports` context, the query-param/path-param
validation the contract pins (limit clamping, opaque `page_token`, 404 bucket for malformed
ids), and the response serializers implementing the `report_filter` /
`report_filter_values` contract shapes. Show runs `AthenaRunOps.ensure_current/1`; list serves
stored state. Removes the temporary ping route.

**Files affected**:
- `lib/report_server/reports.ex` — add `list_api_report_runs/3`, `get_api_report_run/2`
- `lib/report_server_web/api/v1/params.ex` — new
- `lib/report_server_web/api/v1/report_json.ex` — new
- `lib/report_server_web/api/v1/report_controller.ex` — new (`index`, `show`)
- `lib/report_server_web/router.ex` — replace ping with report routes
- `lib/report_server_web/api/v1/ping_controller.ex` — deleted
- `test/report_server_web/api/auth_plug_test.exs` — retarget from `GET /api/v1/ping` to
  `GET /api/v1/reports` (assertions port unchanged; without this the suite is red at this
  commit)
- `test/report_server_web/api/v1/report_controller_test.exs` — new

**Estimated diff size**: ~480 lines

Context queries (keyset `WHERE id < ? ORDER BY id DESC LIMIT n` per the contract; ownership and
Athena-classification are query conditions, so not-owned and non-Athena ids are
indistinguishable from non-existent — the 404 bucket falls out of `Repo.one/1` returning nil):

```elixir
# reports.ex also gains: alias ReportServer.Reports.Tree
# (the module aliases only Repo/User/ReportRun today — a bare Tree call would resolve to a
# non-existent top-level module and fail at runtime)

def list_api_report_runs(user = %User{}, limit, before_id \\ nil) do
  # no :user preload: the serializer reads no user fields and every listed run belongs to
  # the already-loaded caller (get_api_report_run/2 DOES preload — start_query needs run.user)
  query = from r in ReportRun,
    where: r.user_id == ^user.id,
    where: r.report_slug in ^Tree.athena_report_slugs(),
    order_by: [desc: r.id],
    limit: ^limit

  query = if before_id do
    from r in query, where: r.id < ^before_id
  else
    query
  end

  Repo.all(query)
end

def get_api_report_run(user = %User{}, id) when is_integer(id) do
  query = from r in ReportRun,
    where: r.id == ^id,
    where: r.user_id == ^user.id,
    where: r.report_slug in ^Tree.athena_report_slugs(),
    preload: [:user]

  case Repo.one(query) do
    nil -> {:error, :not_found}
    report_run -> {:ok, report_run}
  end
end
```

Param validation (the contract's edge cases live here so controllers stay thin; malformed ids
return `{:error, :not_found}` — same bucket as missing, per the no-existence-leaks requirement,
and `parse_id` bounds-checks so `Ecto.Query.CastError` can never surface as a 500):

```elixir
defmodule ReportServerWeb.Api.V1.Params do
  @default_limit 50
  @max_limit 200
  @max_bigint 9_223_372_036_854_775_807

  def parse_limit(params) do
    case Map.fetch(params, "limit") do
      :error ->
        {:ok, @default_limit}
      {:ok, value} when is_binary(value) ->
        case Integer.parse(value) do
          {n, ""} -> {:ok, n |> max(1) |> min(@max_limit)}
          _ -> {:error, "limit must be an integer"}
        end
      {:ok, _} ->
        {:error, "limit must be an integer"}
    end
  end

  def parse_page_token(params) do
    case Map.fetch(params, "page_token") do
      :error ->
        {:ok, nil}
      {:ok, token} when is_binary(token) ->
        # same bounds check as parse_id: Elixir integers are arbitrary-precision, and an
        # out-of-int64 value raises inside the MyXQL parameter encoder (no fallback clause) —
        # a decodable-but-unbounded token must be a contract 400, not a 500
        with {:ok, decoded} <- Base.url_decode64(token, padding: false),
             {id, ""} when id > 0 and id <= @max_bigint <- Integer.parse(decoded) do
          {:ok, id}
        else
          _ -> {:error, "page_token is not valid"}
        end
      {:ok, _} ->
        {:error, "page_token is not valid"}
    end
  end

  def encode_page_token(id), do: Base.url_encode64(Integer.to_string(id), padding: false)

  def parse_id(id_param) when is_binary(id_param) do
    with {id, ""} <- Integer.parse(id_param),
         true <- id > 0 and id <= @max_bigint do
      {:ok, id}
    else
      _ -> {:error, :not_found}
    end
  end
end
```

Serializer — implements the Contract section's `report_filter` shape (all fields always
present; `filters` as strings in stored order; `""` dates normalized to `null`) and serves
`report_filter_values` as stored (id keys become JSON strings automatically — verified in the
pre-spec throwaway tests). No `athena_result_url` or any raw storage URL anywhere:

```elixir
defmodule ReportServerWeb.Api.V1.ReportJSON do
  alias ReportServer.Reports.{ReportFilter, ReportRun}
  alias ReportServerWeb.Api.V1.Params

  @id_dimensions [:cohort, :school, :teacher, :assignment, :class, :student, :permission_form, :country, :subject_area]

  def index(report_runs, limit) do
    %{
      items: Enum.map(report_runs, &run_json/1),
      next_page_token: next_page_token(report_runs, limit)
    }
  end

  def show(report_run), do: run_json(report_run)

  def download(download_url, filename) do
    # expires_in_seconds mirrors the presign expiry hardcoded in AthenaDB.get_download_url/2
    %{download_url: download_url, filename: filename, expires_in_seconds: 600}
  end

  defp next_page_token(report_runs, limit) when length(report_runs) < limit, do: nil
  defp next_page_token(report_runs, _limit), do: Params.encode_page_token(List.last(report_runs).id)

  defp run_json(report_run = %ReportRun{}) do
    %{
      id: report_run.id,
      report_slug: report_run.report_slug,
      report_filter: report_filter_json(report_run.report_filter),
      report_filter_values: report_run.report_filter_values || %{},
      athena_query_state: report_run.athena_query_state,
      inserted_at: DateTime.to_iso8601(report_run.inserted_at),
      updated_at: DateTime.to_iso8601(report_run.updated_at)
    }
  end

  # nil stored filters are schema-legal (the changeset requires only user_id/report_slug) and
  # must still honor the all-fields-present contract shape — %ReportFilter{} defaults
  # (filters: [], dimensions/dates nil, booleans false) produce exactly that shape, so a
  # missing filter serializes as the empty filter, never as null (External Review Round 1)
  def report_filter_json(nil), do: report_filter_json(%ReportFilter{})
  def report_filter_json(report_filter = %ReportFilter{}) do
    base = %{
      filters: Enum.map(report_filter.filters, &to_string/1),
      state: report_filter.state,
      start_date: presence(report_filter.start_date),
      end_date: presence(report_filter.end_date),
      hide_names: !!report_filter.hide_names,
      exclude_internal: !!report_filter.exclude_internal
    }

    Enum.reduce(@id_dimensions, base, fn dimension, acc ->
      Map.put(acc, dimension, Map.get(report_filter, dimension))
    end)
  end

  defp presence(""), do: nil
  defp presence(value), do: value
end
```

(A full-page final page yields a `next_page_token` whose next request returns an empty page
with a null token — standard keyset behavior, one extra request in the worst case, no
correctness impact. The `filters` list is served in **stored** order per the requirements —
loaded values are already strings, `to_string/1` is a no-op there and covers freshly-built
atom filters uniformly.)

Controller:

```elixir
defmodule ReportServerWeb.Api.V1.ReportController do
  use ReportServerWeb, :controller

  alias ReportServer.Reports
  alias ReportServer.Reports.AthenaRunOps
  alias ReportServerWeb.Api.ErrorHelpers
  alias ReportServerWeb.Api.V1.{Params, ReportJSON}

  def index(conn, params) do
    with {:ok, limit} <- Params.parse_limit(params),
         {:ok, before_id} <- Params.parse_page_token(params) do
      report_runs = Reports.list_api_report_runs(conn.assigns.current_user, limit, before_id)
      json(conn, ReportJSON.index(report_runs, limit))
    else
      {:error, message} -> ErrorHelpers.bad_request(conn, message)
    end
  end

  def show(conn, %{"id" => id_param}) do
    with {:ok, id} <- Params.parse_id(id_param),
         {:ok, report_run} <- Reports.get_api_report_run(conn.assigns.current_user, id) do
      report_run = AthenaRunOps.ensure_current(report_run)
      json(conn, ReportJSON.show(report_run))
    else
      {:error, :not_found} -> ErrorHelpers.not_found(conn)
    end
  end
end
```

Router (replacing the ping route; the `:api`-piped catch-all scope from the pipeline step
stays **below** this scope — every later route addition must also land above it):

```elixir
scope "/api/v1", ReportServerWeb.Api.V1 do
  pipe_through :api_authenticated

  get "/reports", ReportController, :index
  get "/reports/:id", ReportController, :show
end
```

Tests (bearer setup from the pipeline step; stub `athena_db` where show triggers
refresh/self-start), summarized:
- **list**: returns only the caller's Athena-type runs newest-id-first; another user's runs and a portal-report run (`report_slug: "teacher-status"`-style) are absent; a queued Athena run with no `athena_query_id` IS listed (classification by type, not artifact); envelope is `{"items": [...], "next_page_token": ...}`
- **list pagination**: 3 runs with `limit=2` → 2 items + token; echoing the token as `page_token` returns the third; `limit=abc`/`limit=1.5` → 400 `BAD_REQUEST`; `limit=0` and `limit=9999` clamp to 1/200; malformed `page_token` → 400; a **decodable but out-of-int64** `page_token` (base64url of `"18446744073709551616"`) and a non-positive one (base64url of `"0"`/`"-1"`) → the same 400, not a 500; list makes **no** stub calls (stored state served as-is)
- **show**: owned Athena run → contract shape verified key-by-key, including the full `report_filter` object (all 15 fields present, `""` date → null, stored-order string `filters`) and string-keyed `report_filter_values`; response contains no `athena_result_url` key anywhere
- **show nil `report_filter`**: owned Athena run inserted with `report_filter: nil` (schema-legal — the changeset requires only `user_id`/`report_slug`) → `report_filter` in the response is the **empty-filter object** with all 15 fields present (`filters: []`, dimensions/`state`/dates `null`, booleans `false`), never JSON `null` (External Review Round 1)
- **show 404 bucket**: non-existent id, other user's run, portal-type run, `abc`, `123abc`, `-1`, and `99999999999999999999` all → identical 404 `NOT_FOUND` body
- **show freshness**: run stored `"running"` + stub `get_query_info` returning `{:ok, "succeeded", "s3://..."}` → response says `succeeded` AND the DB row now has both fields; stub returning `{:error, _}` → response serves stored `"running"` (no 500); terminal stored state → stub not called
- **show self-start**: persisted run with `athena_query_id: nil` + stubbed tree/athena → response shows the new state and the run gained an `athena_query_id` (complements the AthenaRunOps unit test through the full HTTP path)

---

### API v1: run download endpoint (fresh presign + audit, 409/500 semantics)

**Summary**: `GET /api/v1/reports/:id/download` — mints a fresh presigned URL through the
fail-closed `AuditLog.issue_download_url/6` helper, returning the contract's download shape.
Every non-succeeded state (including after the ensure-current refresh) is `409 NOT_READY` with
the state in context; succeeded-with-null-URL is the 500-class invariant violation.

**Files affected**:
- `lib/report_server_web/api/v1/report_controller.ex` — add `download/2`
- `lib/report_server_web/router.ex` — add the route
- `test/report_server_web/api/v1/report_controller_test.exs` — extend

**Estimated diff size**: ~200 lines

```elixir
# ReportController additionally gains (the step-5 module has none of these):
#   require Logger
#   alias ReportServer.AuditLog
#   alias ReportServer.Reports.ReportRun

def download(conn, %{"id" => id_param}) do
  user = conn.assigns.current_user

  with {:ok, id} <- Params.parse_id(id_param),
       {:ok, report_run} <- Reports.get_api_report_run(user, id) do
    report_run = AthenaRunOps.ensure_current(report_run)

    case report_run do
      %ReportRun{athena_query_state: "succeeded", athena_result_url: nil} ->
        Logger.error("Report run #{report_run.id} is succeeded but has no athena_result_url")
        ErrorHelpers.server_error(conn)

      %ReportRun{athena_query_state: "succeeded", athena_result_url: athena_result_url} ->
        filename = "#{report_run.report_slug}-run-#{report_run.id}.csv"

        case AuditLog.issue_download_url("api", "run_csv", report_run, user.id, fn ->
               athena_db().get_download_url(athena_result_url, filename)
             end) do
          {:ok, download_url} ->
            json(conn, ReportJSON.download(download_url, filename))
          {:error, :presign, error} ->
            Logger.error("Presign failed for report run #{report_run.id}: #{inspect(error)}")
            ErrorHelpers.server_error(conn)
          {:error, :audit, _reason} ->
            ErrorHelpers.server_error(conn)
        end

      %ReportRun{athena_query_state: athena_query_state} ->
        ErrorHelpers.render_error(conn, "NOT_READY", "The report is not ready to download.", %{athena_query_state: athena_query_state})
    end
  else
    {:error, :not_found} -> ErrorHelpers.not_found(conn)
  end
end

# same config seam as AthenaRunOps
defp athena_db(), do: Application.get_env(:report_server, :athena_db, ReportServer.AthenaDB)
```

Route: `get "/reports/:id/download", ReportController, :download`.

Tests, summarized:
- succeeded run → 200 `{"download_url": ..., "filename": "<slug>-run-<id>.csv", "expires_in_seconds": 600}` AND exactly one `data_access_log` row (`source: "api"`, `data_type: "run_csv"`, `job_id: nil`, requesting user, filter snapshot)
- every non-succeeded state (nil / queued / running / failed / cancelled, stub pinned so refresh keeps the state) → 409 with `athena_query_state` in the body; **no** audit row
- refresh-to-succeeded during download: stored `"running"`, stub refreshes to `succeeded` + result URL → 200 (the tab-closed-run scenario end-to-end)
- **download self-start** (the requirement covers `/download` too, not just show): persisted run
  with `athena_query_id: nil` + stubbed tree/athena → 409 with the **new** state
  (`"queued"`) in the body AND the run row gained an `athena_query_id`; start-failure twin
  (tree/athena stub errors) → 409 with `athena_query_state: null` and the claim released
- succeeded + null `athena_result_url` (terminal state so refresh won't overwrite) → 500 `SERVER_ERROR`, no audit row
- presign stub failure → 500, **no audit row** (the HTTP-level fail-closed case; the
  audit-write-failure half is covered at the unit level in the `data_access_log` step — see the
  forcing-mechanism note there)
- 404 bucket: same six malformed/foreign id cases as show

---

### API v1: post-processing jobs list + job download

**Summary**: `GET /api/v1/reports/:id/jobs` and `GET /api/v1/reports/:id/jobs/:job_id/download`.
Adds the S3 read path that distinguishes not-found (→ empty list) from other failures (→ 500) —
the existing `Aws.get_file_contents/1` collapses both (requirements Technical Notes caveat) —
and a `JobsFile` module that reads the persisted jobs file without the `JobServer` GenServer.
Serialization maps `result` → `has_result` (never the raw S3 URL) with steps as `{id, label}`.

**Files affected**:
- `lib/report_server_web/aws.ex` — add `fetch_file_contents/1`
- `lib/report_server/post_processing/jobs_file.ex` — new
- `lib/report_server_web/api/v1/report_job_controller.ex` — new
- `lib/report_server_web/api/v1/report_job_json.ex` — new
- `lib/report_server_web/router.ex` — add the two routes
- `test/support/aws_file_store_stub.ex` — new (same Agent pattern as `AthenaDBStub`)
- `test/report_server_web/api/v1/report_job_controller_test.exs` — new

**Estimated diff size**: ~420 lines

New non-streaming S3 read in `ReportServerWeb.Aws` (jobs files are tiny; `get_object` returns
the status code the streaming path loses):

```elixir
@doc """
Like get_file_contents/1 but distinguishes a missing object from other failures.
Returns {:ok, contents} | {:error, :not_found} | {:error, {:s3_error, reason}}.
"""
def fetch_file_contents(s3_url) do
  client = get_exaws_client(get_server_credentials())
  {bucket, path} = get_bucket_and_path(s3_url)

  case ExAws.S3.get_object(bucket, path) |> ExAws.request(client) do
    {:ok, %{body: body}} -> {:ok, body}
    {:error, {:http_error, 404, _}} -> {:error, :not_found}
    {:error, reason} -> {:error, {:s3_error, reason}}
  end
end
```

`JobsFile` — reads the same file `JobServer.read_jobs_file/1` reads
(`s3://<output-bucket>/jobs/<query_id>_jobs.json`), but API-safe: missing file is an empty
list, any other failure propagates as an error (never a misleading empty 200). Decoded jobs
stay string-keyed maps — the persisted shape (`id`/`steps`/`status`/`result`, string statuses)
was pinned by the pre-spec throwaway tests:

```elixir
defmodule ReportServer.PostProcessing.JobsFile do
  alias ReportServer.PostProcessing.Output

  # config seam so tests can stub S3 (same pattern as :athena_db)
  defp aws(), do: Application.get_env(:report_server, :aws_file_store, ReportServerWeb.Aws)

  def list_jobs(nil), do: {:ok, []}
  def list_jobs(athena_query_id) do
    jobs_url = Output.get_jobs_url("#{athena_query_id}_jobs.json")

    case aws().fetch_file_contents(jobs_url) do
      {:ok, contents} -> parse_jobs(contents)
      {:error, :not_found} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  def find_job(athena_query_id, job_id) when is_integer(job_id) do
    with {:ok, jobs} <- list_jobs(athena_query_id) do
      case Enum.find(jobs, fn job -> job["id"] == job_id end) do
        nil -> {:error, :not_found}
        job -> {:ok, job}
      end
    end
  end

  defp parse_jobs(contents) do
    case Jason.decode(contents) do
      {:ok, %{"jobs" => jobs}} when is_list(jobs) -> {:ok, jobs}
      {:ok, _} -> {:error, :malformed_jobs_file}
      {:error, reason} -> {:error, reason}
    end
  end
end
```

Serializer (closed item shape from the Contract; the paged envelope with an always-null token):

```elixir
defmodule ReportServerWeb.Api.V1.ReportJobJSON do
  def index(jobs) do
    %{
      items: Enum.map(jobs, &job_json/1),
      next_page_token: nil
    }
  end

  defp job_json(job) do
    %{
      id: job["id"],
      steps: Enum.map(job["steps"] || [], fn step -> %{id: step["id"], label: step["label"]} end),
      status: job["status"],
      has_result: job["result"] != nil
    }
  end
end
```

Controller:

```elixir
defmodule ReportServerWeb.Api.V1.ReportJobController do
  use ReportServerWeb, :controller

  require Logger

  alias ReportServer.{AuditLog, Reports}
  alias ReportServer.PostProcessing.JobsFile
  alias ReportServerWeb.Api.ErrorHelpers
  alias ReportServerWeb.Api.V1.{Params, ReportJobJSON, ReportJSON}

  def index(conn, %{"id" => id_param}) do
    with {:ok, id} <- Params.parse_id(id_param),
         {:ok, report_run} <- Reports.get_api_report_run(conn.assigns.current_user, id) do
      case JobsFile.list_jobs(report_run.athena_query_id) do
        {:ok, jobs} ->
          json(conn, ReportJobJSON.index(jobs))
        {:error, reason} ->
          Logger.error("Unable to read jobs file for report run #{report_run.id}: #{inspect(reason)}")
          ErrorHelpers.server_error(conn)
      end
    else
      {:error, :not_found} -> ErrorHelpers.not_found(conn)
    end
  end

  def download(conn, %{"id" => id_param, "job_id" => job_id_param}) do
    user = conn.assigns.current_user

    with {:ok, id} <- Params.parse_id(id_param),
         {:ok, report_run} <- Reports.get_api_report_run(user, id),
         {:ok, job_id} <- Params.parse_id(job_id_param),
         {:ok, job} <- JobsFile.find_job(report_run.athena_query_id, job_id) do
      case job do
        %{"status" => "completed", "result" => nil} ->
          Logger.error("Job #{job_id} of report run #{report_run.id} is completed but has no result")
          ErrorHelpers.server_error(conn)

        %{"status" => "completed", "result" => result} ->
          filename = "#{report_run.report_slug}-run-#{report_run.id}-job-#{job_id}.csv"

          case AuditLog.issue_download_url("api", "job_result", report_run, user.id, fn ->
                 athena_db().get_download_url(result, filename)
               end, job_id: job_id) do
            {:ok, download_url} ->
              json(conn, ReportJSON.download(download_url, filename))
            {:error, :presign, error} ->
              Logger.error("Presign failed for job #{job_id} of report run #{report_run.id}: #{inspect(error)}")
              ErrorHelpers.server_error(conn)
            {:error, :audit, _reason} ->
              ErrorHelpers.server_error(conn)
          end

        %{"status" => status} ->
          ErrorHelpers.render_error(conn, "NOT_READY", "The job result is not ready to download.", %{status: status})
      end
    else
      {:error, :not_found} -> ErrorHelpers.not_found(conn)
      {:error, reason} ->
        Logger.error("Unable to read jobs file: #{inspect(reason)}")
        ErrorHelpers.server_error(conn)
    end
  end

  defp athena_db(), do: Application.get_env(:report_server, :athena_db, ReportServer.AthenaDB)
end
```

(Note the `else` ordering: `find_job/2` returns `{:error, :not_found}` for an unknown job —
same 404 bucket as an unknown run, per the requirements — while an S3/decode failure reason
falls through to 500. No state refresh on jobs endpoints: statuses are served **as persisted**.)

Routes:

```elixir
get "/reports/:id/jobs", ReportJobController, :index
get "/reports/:id/jobs/:job_id/download", ReportJobController, :download
```

Test-env config: `JobsFile.list_jobs/1` builds the jobs URL via `Output.get_jobs_url/1`
**before** reaching the stubbed `aws()` seam, and `Output.config/0` does
`Keyword.get(Application.get_env(:report_server, :output), ...)` — but only `dev.exs` and
`runtime.exs` define `:report_server, :output`, so without config the test env raises
`FunctionClauseError` (verified). The `config/test.exs` addition now lands in the earlier
**AthenaRunOps step** (its Show smoke test needed it first — Self-Review Round 3):

```elixir
config :report_server, :output,
  bucket: "report-server-output-test",
  jobs_folder: "jobs",
  transcripts_folder: "transcripts"
```

Tests (stubbing `:aws_file_store` with canned jobs-file JSON), summarized:
- jobs list: run with a jobs file → items in the exact closed shape (`id`/`steps(id,label)`/`status`/`has_result`), **no `result` key**; `has_result` true/false per null-ness; envelope has `next_page_token: null`
- jobs list: run with `athena_query_id: nil` → `{"items": [], "next_page_token": null}`; stub `{:error, :not_found}` → same empty 200; stub `{:error, {:s3_error, ...}}` → 500 `SERVER_ERROR` (transient S3 error never masquerades as no-jobs)
- job download: completed job → 200 download shape with `<slug>-run-<id>-job-<job_id>.csv` + one audit row with `data_type: "job_result"` and the `job_id`
- job download: `started`/`failed` job → 409 with `status` in body, no audit row; unknown `job_id`, `job_id=abc` → 404 identical to unknown-run 404; completed + null result → 500
- ownership: another user's run id → 404 on both endpoints (the run gate runs before any S3 read)

---

### Auth grants + code exchange endpoint (`POST /auth/cli/token`) + log hygiene

**Summary**: The pending-authorization-grant model and the mint-point exchange. A grant stores
only the SHA-256 of the one-time code (a leaked grants table yields nothing usable), bound to
the user and PKCE challenge with a 5-minute expiry. Single-use is enforced atomically with a
conditional `UPDATE` — exactly one exchange can ever consume a code, even under concurrent
duplicates. The exchange endpoint returns every failure as the same indistinguishable 400.
Also adds the `filter_parameters` config the log-hygiene requirement depends on.

**Files affected**:
- `priv/repo/migrations/<ts>_create_auth_grants.exs` — new
- `lib/report_server/accounts/auth_grant.ex` — new
- `lib/report_server/accounts.ex` — add grant functions
- `lib/report_server_web/controllers/auth_cli_controller.ex` — new (`token/2` action only; the browser actions land in the next step)
- `lib/report_server_web/router.ex` — add the `:api`-piped exchange route
- `config/config.exs` — add `filter_parameters`
- `test/report_server/accounts_test.exs`, `test/report_server_web/controllers/auth_cli_controller_test.exs` — extend/new

**Estimated diff size**: ~380 lines

Migration:

```elixir
defmodule ReportServer.Repo.Migrations.CreateAuthGrants do
  use Ecto.Migration

  def change do
    create table(:auth_grants) do
      add :code_hash, :string, null: false
      add :code_challenge, :string, null: false
      add :portal_url, :string, null: false
      add :expires_at, :utc_datetime, null: false
      add :used_at, :utc_datetime
      add :user_id, references(:users, on_delete: :nothing), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:auth_grants, [:code_hash])
    create index(:auth_grants, [:user_id])
  end
end
```

Schema module — pinned in full (External Review Round 2: `exchange_auth_grant/2` below runs
`preload: [:user]` and reads `auth_grant.user`, and Ecto does **not** infer associations from
the migration FK — a fields-only "mirror" schema would crash the exchange's success path).
Declares `:utc_datetime` timestamps and datetime fields (the same naive-default trap pinned
for `DataAccessLogEntry` in Round 4). Expired/used rows are left in place — they are inert and
tiny; a cleanup job is deliberately not part of v1:

```elixir
defmodule ReportServer.Accounts.AuthGrant do
  use Ecto.Schema

  import Ecto.Changeset

  alias ReportServer.Accounts.User

  schema "auth_grants" do
    field :code_hash, :string
    field :code_challenge, :string
    field :portal_url, :string
    field :expires_at, :utc_datetime
    field :used_at, :utc_datetime

    belongs_to :user, User, foreign_key: :user_id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(auth_grant, attrs) do
    auth_grant
    |> cast(attrs, [:user_id, :code_hash, :code_challenge, :portal_url, :expires_at, :used_at])
    |> validate_required([:user_id, :code_hash, :code_challenge, :portal_url, :expires_at])
    |> unique_constraint(:code_hash)
  end
end
```

Context functions in `Accounts` (reusing `hash_api_token/1`, renamed to a shared private
`hash_secret/1` used by both tokens and codes):

```elixir
@auth_grant_ttl_seconds 5 * 60

def create_auth_grant(user = %User{}, code_challenge, portal_url) do
  raw_code = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  expires_at = DateTime.utc_now(:second) |> DateTime.add(@auth_grant_ttl_seconds)

  result =
    %AuthGrant{}
    |> AuthGrant.changeset(%{
      user_id: user.id,
      code_hash: hash_secret(raw_code),
      code_challenge: code_challenge,
      portal_url: portal_url,
      expires_at: expires_at
    })
    |> Repo.insert()

  case result do
    {:ok, auth_grant} -> {:ok, raw_code, auth_grant}
    {:error, changeset} -> {:error, changeset}
  end
end

@doc """
The mint point (requirements: Code-exchange endpoint contract). Consuming the code is an
atomic conditional UPDATE — exactly one exchange of a given code can ever get {1, _} back,
so concurrent duplicates cannot both mint. Unknown, expired, used, and verifier-mismatch all
return :error (the controller renders one indistinguishable 400). A verifier mismatch
deliberately still consumes the code (the code was exposed to a party without the verifier;
burning it matches OAuth 2.0 Security BCP guidance — see OQ-8).
"""
def exchange_auth_grant(raw_code, code_verifier) when is_binary(raw_code) and is_binary(code_verifier) do
  now = DateTime.utc_now(:second)
  code_hash = hash_secret(raw_code)

  consume_query = from g in AuthGrant,
    where: g.code_hash == ^code_hash,
    where: is_nil(g.used_at),
    where: g.expires_at > ^now

  case Repo.update_all(consume_query, set: [used_at: now]) do
    {1, _} ->
      auth_grant = Repo.one!(from g in AuthGrant, where: g.code_hash == ^code_hash, preload: [:user])

      if pkce_verifier_matches?(auth_grant.code_challenge, code_verifier) do
        create_api_token(auth_grant.user, "CLI login")
      else
        :error
      end

    _ ->
      :error
  end
end
def exchange_auth_grant(_, _), do: :error

defp pkce_verifier_matches?(code_challenge, code_verifier) do
  computed = :crypto.hash(:sha256, code_verifier) |> Base.url_encode64(padding: false)
  Plug.Crypto.secure_compare(computed, code_challenge)
end
```

Exchange action (`AuthCliController.token/2`) — routed through `:api` (no session/CSRF). The
secrets must travel in the POST body **only**, and that has to be enforced, not assumed
(External Review Round 3): a controller action's params argument is Phoenix's **merged**
`conn.params`, so a naive pattern match would accept
`POST /auth/cli/token?code=...&code_verifier=...` — putting the one-time code and verifier in
access/proxy log URL lines, which `filter_parameters` (Phoenix params logging) cannot redact.
The action therefore reads `conn.body_params` and rejects any request carrying either name in
the query string, **before** the exchange runs (so a query-string attempt does not consume the
grant). Same indistinguishable 400 as every other failure. (`conn.query_params` is already
fetched here — the endpoint's `Plug.Parsers` fetches query params before merging.)

```elixir
def token(conn, _params) do
  query_secrets? =
    Map.has_key?(conn.query_params, "code") or Map.has_key?(conn.query_params, "code_verifier")

  case {query_secrets?, conn.body_params} do
    {false, %{"code" => code, "code_verifier" => code_verifier}}
    when is_binary(code) and is_binary(code_verifier) ->
      case Accounts.exchange_auth_grant(code, code_verifier) do
        {:ok, raw_token, _api_token} ->
          json(conn, %{token: raw_token})
        _ ->
          ErrorHelpers.bad_request(conn, "Invalid code or verifier.")
      end

    _ ->
      ErrorHelpers.bad_request(conn, "Invalid code or verifier.")
  end
end
```

Router:

```elixir
scope "/auth", ReportServerWeb do
  pipe_through :api

  post "/cli/token", AuthCliController, :token
end
```

Log hygiene (`config/config.exs` — the config is **read at request time** by
`Phoenix.Logger.filter_values/2`; `config.exs` placement works because releases bake app env
into `sys.config`, not because anything is compiled against it. Technical Notes documents that
the app currently filters nothing, and today's `save_token` already receives the portal
`access_token` unfiltered, so this also closes a pre-existing gap):

```elixir
config :phoenix, :filter_parameters, ["password", "token", "access_token", "code", "code_verifier"]
```

(Matching is substring-based — `String.contains?(key, params)` — so `"token"` also redacts the
harmless `page_token` query param in request logs. Accepted side effect; worth knowing when
grepping logs to debug CLI pagination.)

Tests, summarized:
- grant creation stores only the hash (row's `code_hash` ≠ raw code, 64 hex chars), bound challenge/portal/user, `expires_at` ≈ now+300s
- exchange happy path: real PKCE pair (`verifier` random, `challenge = B64URL(SHA256(verifier))`) → `{:ok, "ccd_..." , token}`; the grant is marked used; the minted token verifies via `verify_api_token/1`
- one indistinguishable 400 for each of: unknown code, expired grant (insert with past `expires_at`), already-used grant, wrong verifier — controller bodies byte-identical
- single-use lock-in: two **sequential** exchanges of the same code → first `{:ok, ...}`, second `:error`. (Race-safety itself is guaranteed by construction — the conditional `UPDATE` returning `{1, _}` is the atomic compare-and-swap; a concurrent-`Task` test under the shared SQL sandbox funnels through one connection and cannot produce real DB interleaving, so it is deliberately not claimed as a race test)
- verifier mismatch consumes the code: a subsequent correct-verifier exchange also gets 400
- **query-string exchange rejected** (External Review Round 3): a **valid** code/verifier pair
  sent as `?code=...&code_verifier=...` with an empty body → 400, and the grant is **not**
  consumed (a subsequent body-only exchange of the same code succeeds); either secret in the
  query string alongside a valid body → the same 400
- exchange endpoint requires no session/CSRF token (plain `post` in ConnCase passes)
- log hygiene: `Phoenix.Logger` filtering is config-level; assert `Application.get_env(:phoenix, :filter_parameters)` contains the four names (a smoke check that the config landed)

---

### `/auth/cli` loopback flow: entry validation, portal selection, login round trip

**Summary**: The browser half of the loopback flow. `GET /auth/cli` validates
`redirect_uri`/`state`/`code_challenge`(+method)/`portal` **on entry** (failure renders at
`/auth/cli`, never a redirect, per RFC 6749 §3.1.2.4), enforces `can_access_reports?` before
issuing anything, and either issues the one-time code immediately (session user on the right
portal) or stores the validated request in the session, runs the existing portal login with
`return_to = /auth/cli/resume`, and finishes there. The final hop is a plain controller
redirect to the loopback with `code` + verbatim `state` (OQ-4: session storage for the round
trip).

**Files affected**:
- `lib/report_server_web/controllers/auth_cli_controller.ex` — add `cli/2`, `resume/2`
- `lib/report_server_web/controllers/auth_cli_html.ex` + `auth_cli_html/error.html.heex` — new (minimal error page)
- `lib/report_server/portal_dbs.ex` — add `has_db_connection?/1`
- `lib/report_server_web/router.ex` — add the two `:browser` routes
- `test/report_server_web/controllers/auth_cli_controller_test.exs` — extend

**Estimated diff size**: ~420 lines

`PortalDbs.has_db_connection?/1` (public wrapper over the existing private
`get_connection_string/1`, grounding portal validation in the same condition login needs):

```elixir
def has_db_connection?(server) do
  case get_connection_string(server) do
    {:ok, _connection_string} -> true
    _ -> false
  end
end
```

Controller actions:

```elixir
def cli(conn, params) do
  case validate_cli_request(conn, params) do
    {:ok, request} ->
      session = get_session(conn)
      user = session["user"]

      if Auth.logged_in?(session) && user && portal_matches?(user, request.portal_url) do
        authorize_or_reject(conn, user, request)
      else
        # store the validated request server-side and run the existing portal login;
        # portal_url is set explicitly so the login targets the REQUESTED portal even when a
        # session for a different portal exists (requirements: portal override)
        conn
        |> put_session(:cli_auth_request, request)
        |> put_session(:portal_url, request.portal_url)
        |> put_session(:return_to, ~p"/auth/cli/resume")
        |> redirect(external: PortalStrategy.get_authorize_url(request.portal_url))
      end

    {:error, message} ->
      render_cli_error(conn, message)
  end
end

def resume(conn, _params) do
  request = get_session(conn, :cli_auth_request)
  session = get_session(conn)
  user = session["user"]

  cond do
    request == nil ->
      render_cli_error(conn, "No CLI login is in progress. Start again from your terminal.")
    !(Auth.logged_in?(session) && user && portal_matches?(user, request.portal_url)) ->
      render_cli_error(conn, "Portal login did not complete. Start again from your terminal.")
    true ->
      conn
      |> delete_session(:cli_auth_request)
      |> authorize_or_reject(user, request)
  end
end

# role gate BEFORE any code is issued (requirements: /auth/cli refuses to mint for users
# failing can_access_reports?)
defp authorize_or_reject(conn, user, request) do
  if Auth.can_access_reports?(%{"user" => user}) do
    case Accounts.create_auth_grant(user, request.code_challenge, request.portal_url) do
      {:ok, raw_code, _auth_grant} ->
        query = URI.encode_query(%{"code" => raw_code, "state" => request.state})
        conn
        |> delete_session(:cli_auth_request)
        |> redirect(external: "#{request.redirect_uri}?#{query}")
      {:error, _changeset} ->
        render_cli_error(conn, "Something went wrong starting the CLI login. Please try again.")
    end
  else
    render_cli_error(conn, "Sorry, you are not a portal admin, project admin, or project researcher so you don't have report access.")
  end
end

defp portal_matches?(user, portal_url) do
  user.portal_server == PortalDbs.get_server_for_portal_url(portal_url)
end

defp render_cli_error(conn, message) do
  conn
  |> put_status(:bad_request)
  |> render(:error, message: message, page_title: "CLI Login Error")
end
```

Entry validation — every rule from the requirements' failure clause, checked before anything
else touches the request:

```elixir
defp validate_cli_request(conn, params) do
  with {:ok, redirect_uri} <- validate_redirect_uri(params["redirect_uri"]),
       {:ok, state} <- require_param(params, "state"),
       {:ok, code_challenge} <- validate_code_challenge(params["code_challenge"]),
       :ok <- validate_challenge_method(params["code_challenge_method"]),
       {:ok, portal_url} <- validate_portal(conn, params["portal"]) do
    {:ok, %{redirect_uri: redirect_uri, state: state, code_challenge: code_challenge, portal_url: portal_url}}
  end
end

defp validate_redirect_uri(redirect_uri) when is_binary(redirect_uri) do
  uri = URI.parse(redirect_uri)

  # exact-form loopback only (External Review Round 3, verified against URI.parse):
  # - userinfo must be absent (http://evil@127.0.0.1:123/callback parses with host 127.0.0.1)
  # - the authority must be the literal "host:port" — this also kills malformed ports, which
  #   URI.parse accepts silently ("127.0.0.1:-1" parses with port DEFAULTING to 80; ":0" and
  #   ":99999" parse as integer ports) — and rejects a portless URI (the CLI always binds an
  #   explicit ephemeral port)
  # - the port must be a real TCP port
  if uri.scheme == "http" && uri.host == "127.0.0.1" && uri.userinfo == nil &&
       is_integer(uri.port) && uri.port in 1..65535 &&
       uri.authority == "127.0.0.1:#{uri.port}" &&
       uri.path == "/callback" && uri.query == nil && uri.fragment == nil do
    {:ok, redirect_uri}
  else
    {:error, "redirect_uri must be http://127.0.0.1:<port>/callback"}
  end
end
defp validate_redirect_uri(_), do: {:error, "redirect_uri must be http://127.0.0.1:<port>/callback"}

defp require_param(params, name) do
  case params[name] do
    value when is_binary(value) and value != "" -> {:ok, value}
    _ -> {:error, "#{name} is required"}
  end
end

# an S256 challenge is by definition exactly 43 base64url characters (RFC 7636 §4.2); anything
# else can never be exchanged, so fail fast at entry instead of a confusing exchange-time 400
defp validate_code_challenge(code_challenge) when is_binary(code_challenge) do
  if Regex.match?(~r/^[A-Za-z0-9_-]{43}$/, code_challenge) do
    {:ok, code_challenge}
  else
    {:error, "code_challenge must be a base64url-encoded SHA-256 digest"}
  end
end
defp validate_code_challenge(_), do: {:error, "code_challenge must be a base64url-encoded SHA-256 digest"}

# S256 only, and it must be explicit — OAuth's default method is "plain", which we reject
defp validate_challenge_method("S256"), do: :ok
defp validate_challenge_method(_), do: {:error, "code_challenge_method must be S256"}

# when omitted: existing browser behavior (session portal, else configured default —
# server-configured values, not attacker-supplied, so no shape check needed)
defp validate_portal(conn, nil), do: {:ok, Auth.get_portal_url(conn)}
defp validate_portal(_conn, portal_url) do
  # normalize to an exact https origin BEFORE the DB check (External Review Round 4): the
  # server mapping keys on URI.parse(...).host alone (portal_dbs.ex:83-89), so inputs like
  # ftp://learn.concord.org, https://learn.concord.org/evil, and
  # https://evil@learn.concord.org all derive a valid server — and PortalStrategy.client/1
  # uses the value verbatim as the OAuth site (portal_strategy.ex:10), turning them into
  # broken or phishing-shaped external login redirects. https-only is safe: every configured
  # portal URL is https in every environment. The same literal-authority check as
  # validate_redirect_uri catches URI.parse's silent port defaulting ("host:-1" parses with
  # port 443 for https). The NORMALIZED origin — never the raw input — is what flows into the
  # DB check, the stored auth request / grant row, and get_authorize_url/1.
  uri = URI.parse(portal_url)

  valid_origin? =
    uri.scheme == "https" && uri.userinfo == nil && is_binary(uri.host) && uri.host != "" &&
      uri.path in [nil, "/"] && uri.query == nil && uri.fragment == nil &&
      is_integer(uri.port) && uri.port in 1..65535 &&
      uri.authority in [uri.host, "#{uri.host}:#{uri.port}"]

  if valid_origin? do
    # explicit ":443" and a trailing "/" collapse to the canonical bare-origin form
    normalized =
      if uri.port == 443, do: "https://#{uri.host}", else: "https://#{uri.host}:#{uri.port}"

    server = PortalDbs.get_server_for_portal_url(normalized)

    if PortalDbs.has_db_connection?(server) do
      {:ok, normalized}
    else
      {:error, "unknown portal"}
    end
  else
    {:error, "portal must be an https origin (https://host[:port])"}
  end
end
```

Routes (in the existing `:browser`-piped auth scope):

```elixir
get "/auth/cli", AuthCliController, :cli
get "/auth/cli/resume", AuthCliController, :resume
```

`error.html.heex` is a minimal page (heading + message) using the root layout.

Flow notes, pinned here because they depend on existing machinery:
- The `:browser` pipeline's `Auth.Plug` already stashes `conn.params["portal"]` into the
  session on every request (`auth.ex:32-35`) — so by the time `cli/2` runs, a supplied
  `?portal=` is the session portal, in its **raw** form. That is the same side effect as a
  manual `?portal=` login today (accepted in requirements External Review Round 6); on an
  *invalid* portal the stashed value is also what today's behavior would produce, and the
  error page stops the flow. Round 4 note: for a *valid-but-non-canonical* input (trailing
  `/`, explicit `:443`), the login round trip's session portal is still the raw form — same
  as today's manual `?portal=` login, out of scope here — while the CLI flow's own stored
  auth request and grant row carry the **normalized** origin from `validate_portal/2`.
- `save_token` deletes `:return_to` and calls `configure_session(renew: true)`, which keeps
  session data (new session id only) — `:cli_auth_request` survives the login round trip.
  `resume/2` re-checks login, portal match, and the role gate rather than trusting the stored
  request.
- The one-time code travels only in the loopback redirect query string (that URL is the CLI's
  own localhost listener; the code is in `filter_parameters` so the server's own param logging
  redacts it on the exchange POST).

Tests, summarized (no live portal needed — "logged in" is faked by seeding the session the way
`Auth.login/5` builds it, via `Plug.Test.init_test_session/2`). Two setup obligations for any
test that supplies a **valid** `?portal=` (Self-Review Round 3): (a)
`PortalDbs.has_db_connection?/1` reads `System.get_env("<SERVER>_DB")` at call time, so setup
must `System.put_env` a fake connection string for the test portal's derived key (with an
`on_exit` cleanup); (b) the session user's `portal_server` must equal
`PortalDbs.get_server_for_portal_url(portal)` for `portal_matches?/2` to hold — the fixture
default `"learn.concord.org"` does **not** match the test-config default portal
(`learn.portal.staging.concord.org`), so build the user's `portal_server` from
`get_server_for_portal_url/1` rather than relying on fixture defaults:
- entry validation failures render 400 **at `/auth/cli`** (response has no `location` header) and mint no grant, for each of: missing/non-loopback/`https`/wrong-path/query-carrying `redirect_uri`, `localhost` host (must be literal `127.0.0.1`), userinfo-carrying `redirect_uri` (`http://evil@127.0.0.1:123/callback`), malformed/invalid ports (`:0`, `:-1` — which `URI.parse` silently defaults to port 80 — `:99999`, and portless `http://127.0.0.1/callback`) (Round 3), missing `state`, missing `code_challenge`, malformed `code_challenge` (wrong length / non-base64url chars), method `plain`, method omitted, invalid `portal`, and non-origin `portal` values (Round 4): `ftp://` and `http://` schemes, userinfo (`https://evil@learn.concord.org`), path (`https://learn.concord.org/evil`), query, fragment, and malformed port (`https://learn.concord.org:-1` — `URI.parse` silently defaults it to 443, caught by the literal-authority check)
- portal normalization (Round 4): `?portal=` with a trailing slash or explicit `:443` on a DB-configured portal → flow proceeds, and the stored auth request / grant row carry the **canonical** origin (`https://<host>`), not the raw input (uses the valid-portal env setup obligations above)
- logged-in researcher on the matching portal → 302 to exactly `redirect_uri?code=...&state=<verbatim>`; a grant row exists bound to that user/challenge; the code in the URL hashes to the row's `code_hash`
- logged-in user failing the role gate → error page, **no grant row**
- not logged in → 302 to the portal authorize URL; session holds `:cli_auth_request`, `:portal_url` (the requested portal), and `:return_to == "/auth/cli/resume"`
- session user on a different portal than `?portal=` → treated as not-logged-in (fresh login against the requested portal), per the portal-override requirement
- `resume` with a seeded session (request + logged-in user) → loopback redirect with code + verbatim state, `:cli_auth_request` cleared; `resume` with no pending request → error page
- full state echo: a `state` containing URL-meta characters (`a b&c=d`) round-trips verbatim (percent-encoding aside — assert on the decoded query)

---

### Manual fallback: `/reports/cli-token` LiveView (mint on explicit action, show once)

**Summary**: The paste-a-token path that makes the API exercisable before the CLI exists.
Lives in the `:reports` live_session so the existing `can_access_reports?` mount gate covers
it. Minting happens only on the Generate button (with optional label); the raw token is held
in socket assigns only — a refresh remounts with no token, satisfying show-once. Includes the
accessible copy-to-clipboard control with an ARIA live region.

**Files affected**:
- `lib/report_server_web/live/report_live/cli_token.ex` — new
- `lib/report_server_web/live/report_live/cli_token.html.heex` — new
- `lib/report_server_web/router.ex` — add the route to the `:reports` live_session
- `assets/tailwind.config.js` — add `"dark-orange": "#c14d10"` (white-on-orange `#ea6d2f` is
  3.12:1, failing the requirements' WCAG AA promise; white on `#c14d10` is 4.84:1 — used by
  this page's buttons and the pager's active page)
- `assets/js/app.ts` — add a `CopyToClipboard` entry inside the existing `const Hooks = {...}` literal (`app.ts:32`)
- `test/report_server_web/live/cli_token_live_test.exs` — new

**Estimated diff size**: ~270 lines

```elixir
defmodule ReportServerWeb.ReportLive.CliToken do
  use ReportServerWeb, :live_view

  alias ReportServer.Accounts

  @impl true
  def mount(_params, _session, socket) do
    socket = socket
      |> assign(:page_title, "CLI Access Token")
      |> assign(:raw_token, nil)
      |> assign(:form, to_form(%{"label" => ""}))

    {:ok, socket}
  end

  @impl true
  def handle_event("generate", %{"label" => label}, %{assigns: %{user: user}} = socket) do
    label = case String.trim(label) do
      "" -> nil
      trimmed -> trimmed
    end

    case Accounts.create_api_token(user, label) do
      {:ok, raw_token, _api_token} ->
        {:noreply, assign(socket, :raw_token, raw_token)}
      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Unable to generate a token. Please try again.")}
    end
  end
end
```

Template (existing Tailwind styling conventions; the token is selectable text in a `<code>`
element; the live region announces the copy):

```heex
<div class="font-bold my-2">
  <.breadcrumbs previous={[{"Reports", ~p"/reports"}]} current="CLI Access Token" />
</div>

<div class="max-w-xl">
  <p class="my-2 text-sm">
    Generate a personal access token for the <code>cc-data</code> CLI. The token is shown
    <b>once</b> — copy it now; you will not be able to see it again. Use it with
    <code>cc-data login --token &lt;paste&gt;</code>.
  </p>

  <.form :if={@raw_token == nil} for={@form} phx-submit="generate" class="my-4">
    <%!-- plain labeled input rather than <.input>: the core component's default clause applies
         focus:ring-0, leaving a 1.73:1 border-shade shift as the only focus indicator; the
         teal ring below is 3.66:1 against white (>= 3:1 for non-text indicators) --%>
    <label for="token-label" class="block text-sm font-semibold">
      Label (optional, e.g. “Doug’s MacBook”)
    </label>
    <input
      type="text"
      name="label"
      id="token-label"
      value={@form[:label].value}
      class="mt-1 block w-full rounded-md border border-zinc-300 sm:text-sm focus:border-teal focus:ring-2 focus:ring-teal"
    />
    <%!-- dark-orange, not orange: white-on-orange is 3.12:1 (fails AA); white-on-dark-orange
         is 4.84:1, and the inverted hover (dark-orange on white) is the same 4.84:1 --%>
    <button class="mt-3 rounded px-2 py-1 bg-dark-orange border border-dark-orange text-white text-sm hover:bg-white hover:text-dark-orange">
      Generate token
    </button>
  </.form>

  <div :if={@raw_token != nil} class="my-4">
    <div class="font-bold text-sm mb-1">Your new token:</div>
    <code id="cli-token-value" class="block select-all break-all p-2 bg-slate-100 border border-slate-300 text-sm"><%= @raw_token %></code>
    <button
      id="copy-cli-token"
      type="button"
      phx-hook="CopyToClipboard"
      data-target="cli-token-value"
      data-announce="cli-token-announce"
      class="mt-2 rounded px-2 py-1 bg-dark-orange border border-dark-orange text-white text-sm hover:bg-white hover:text-dark-orange"
    >
      Copy to clipboard
    </button>
    <div id="cli-token-announce" aria-live="polite" class="sr-only"></div>
    <p class="mt-2 text-sm text-slate-600">
      This token will not be shown again. If you lose it, generate a new one.
    </p>
  </div>
</div>
```

JS hook — added as a new entry **inside** the existing `const Hooks = {...}` literal in
`app.ts` (the file is TypeScript; a post-hoc `Hooks.CopyToClipboard = ...` assignment on the
const literal is a TS type error — esbuild would still transpile it, but it breaks any
editor/CI typecheck — Round 4):

```javascript
CopyToClipboard: {
  mounted() {
    this.el.addEventListener("click", () => {
      const target = document.getElementById(this.el.dataset.target)
      navigator.clipboard.writeText(target.textContent).then(() => {
        const announce = document.getElementById(this.el.dataset.announce)
        if (announce) {
          // clear-then-set: several screen reader/browser pairs deduplicate identical
          // live-region content, so a repeat click would otherwise announce nothing
          announce.textContent = ""
          setTimeout(() => { announce.textContent = "Copied to clipboard" }, 50)
        }
      })
    })
  }
}
```

Route (inside the existing `:reports` live_session, so the `ReportLive.Auth` on_mount gate
applies unchanged). **Placement matters**: it must go **above** the `live "/*path"` catch-all
that ends the live_session (`router.ex:69`) — Phoenix matches routes in order, so a route added
after the wildcard never matches:

```elixir
live "/cli-token", ReportLive.CliToken, :cli_token
```

Tests (LiveViewTest, using the `log_in_conn(conn, user)` ConnCase helper introduced with the
AthenaRunOps step's Show smoke test — it seeds the session the way `Auth.login/5` does and is
reused here and by the pagination and audit-page steps), summarized:
- mounting the page mints nothing (no `api_tokens` rows)
- Generate → exactly one token row; the rendered page contains the raw `ccd_` token and the copy button; the row's hash matches the displayed token
- re-mount (simulated refresh) after generating → no token shown, still exactly one row (no re-mint, no re-display)
- label input round-trips to the row; blank label → nil
- a user failing `can_access_reports?` is redirected by the existing live_session gate (mount-level flash + redirect, same as other report pages)

---

### Web-UI audit logging: run-page CSV download + post-processing result buttons

**Summary**: Brings the two existing web export surfaces into the audit net through the same
fail-closed helper the API uses. The run page's Athena CSV download logs `source: "web"`,
`data_type: "run_csv"`; the post-processing component's Download Result / Copy Result URL
buttons (one shared server event) log `data_type: "job_result"` with the job id. Also fixes a
latent crash in the current download code (`{:ok, download_url} =` match instead of `<-`).

**Files affected**:
- `lib/report_server_web/live/report_run_live/show.ex` — rewrite `download_athena_report/1`; add the `{:put_flash, kind, msg}` `handle_info` clause (Round 3)
- `lib/report_server_web/live/report_run_live/show.html.heex` — pass `user={@user}` to the post-processing component
- `lib/report_server_web/live/report_live/post_processing.ex` — audit in the `"download"` event, flash-via-parent on audit failure
- `test/report_server_web/live/` — new LiveView tests for both paths

**Estimated diff size**: ~220 lines

`download_athena_report/1` after (before: `show.ex:278-290`; note the requesting user comes
from the socket — for an admin downloading another user's run this records the **admin**, the
case only the web path can produce):

```elixir
# show.ex gains the same config seam as the API controllers, so the LiveView tests can stub
# the presign and force its failure path (the direct AthenaDB call would silently succeed in
# tests — the presign is offline signing, no network):
#   defp athena_db(), do: Application.get_env(:report_server, :athena_db, ReportServer.AthenaDB)

defp download_athena_report(%{assigns: %{report_run: report_run, user: user}} = socket) do
  filename = get_download_filename("csv", report_run)

  with {:ok, athena_result_url} <- get_athena_result_url(report_run),
       {:ok, download_url} <- AuditLog.issue_download_url("web", "run_csv", report_run, user.id, fn ->
         athena_db().get_download_url(athena_result_url, filename)
       end) do
    socket = socket |> push_event("download_report", %{download_url: download_url, filename: filename})
    {:noreply, socket}
  else
    {:error, :presign, error} ->
      {:noreply, put_flash(socket, :error, error)}
    {:error, :audit, _reason} ->
      {:noreply, put_flash(socket, :error, "Unable to record this download in the access log, so the download was not started. Please try again.")}
    {:error, error} ->
      {:noreply, put_flash(socket, :error, error)}
  end
end
```

Post-processing component `"download"` handler after (before: `post_processing.ex:170-185`;
both buttons emit this same event, so one audit point covers Download Result and Copy Result
URL; `user` is a new required assign passed from `show.html.heex`):

```elixir
def handle_event("download", params = %{"type" => type}, socket = %{assigns: %{report_run: report_run, jobs: jobs, user: user}}) do
  presigned_url = case type do
    "job" ->
      job = Enum.find(jobs, fn %{id: id} -> "#{id}" == params["jobId"] end)

      if job && job.result do
        filename = "#{report_run.report_slug}-run-#{report_run.id}-job-#{job.id}.csv"

        # post_processing.ex gains the same athena_db() seam as show.ex (see above)
        case AuditLog.issue_download_url("web", "job_result", report_run, user.id, fn ->
               athena_db().get_download_url(job.result, filename)
             end, job_id: job.id) do
          {:ok, download_url} ->
            download_url

          {:error, :audit, _reason} ->
            # requirements clause (2): audit-write failure on a LiveView surface fails
            # closed WITH an error flash. put_flash on a LiveComponent socket never renders
            # in the parent layout, so message the parent Show LiveView (Round 3)
            send(self(), {:put_flash, :error, "Unable to record this download in the access log, so the download was not started. Please try again."})
            nil

          _ ->
            nil
        end
      else
        nil
      end

    _ -> nil
  end

  {:reply, %{url: presigned_url}, socket}
end
```

(The client hook already treats a nil url as a failed download, so no URL is ever delivered on
any failure. Presign failure keeps the surface's **existing** error path — the nil reply — per
the requirements' fail-closed clause (1) ("the surface's normal error path"). Audit-write
failure additionally requires a LiveView **error flash** per clause (2) (External Review
Round 3 — the earlier draft collapsed it to the bare nil reply): the component sends
`{:put_flash, kind, msg}` to the parent, and `Show` gains the matching clause alongside its
existing `handle_info`s —
`def handle_info({:put_flash, kind, msg}, socket), do: {:noreply, put_flash(socket, kind, msg)}`
— because a LiveComponent's own flash never renders in the parent layout. Same flash copy as
the raw-CSV audit-failure branch above.)

Tests, summarized (LiveView tests with the `log_in_conn` helper and stubbed `:athena_db` —
which the seam retrofit above is what makes possible; run pages use steps-less Athena slugs
except where jobs are explicitly seeded):
- run-page download → exactly one audit row (`source: "web"`, `data_type: "run_csv"`, requesting user, run + filter snapshot); the pushed event carries the stubbed URL
- admin downloading another user's run → row records the **admin's** user id
- presign stub failure → flash error, no `download_report` event pushed, no row (the
  fail-closed half that is stub-forceable; the audit-write-failure half is unit-covered in the
  `data_access_log` step — see the forcing-mechanism note there)
- post-processing download event → row with `data_type: "job_result"` and `job_id`; reply
  carries the stubbed URL; presign stub failure → `%{url: nil}` reply, no row, **no flash**
  (clause (1): the surface's normal error path). Audit-failure flash (Round 3): the
  `{:error, :audit, _}` **branch** is unit-covered in the `data_access_log` step (audit-write
  failure is not stub-forceable through the LiveView — see the forcing-mechanism note there);
  the new flash **plumbing** is covered directly — send the Show LiveView
  `{:put_flash, :error, msg}` and assert the flash renders (the same `handle_info` clause the
  component's audit branch targets). **Jobs seeding**:
  the component's own jobs load is not seam-covered (`JobServer.read_jobs_file` calls
  `Aws.get_file_contents` directly), so the test seeds jobs by sending the Show LiveView the
  `{:jobs, query_id, jobs}` message it already forwards to the component (`show.ex:95-99`) with
  a `%Job{}` list containing a completed job with a `result` URL — no S3 involved
- portal (MySQL) report download writes **no** audit row (unchanged path)

---

### Remove the legacy `/old-reports` export surface

**Summary**: Replaces the `/old-reports` router scope — the last unaudited student-data export
path, gated only by `logged_in?` — with the existing `RedirectToReports` backwards-compat
pattern, so old bookmarks land on `/reports`. The unreachable `OldReportLive` modules stay in
the tree (deleting them is optional cleanup per the requirements; keeping the diff minimal
here). Nothing else links to `/old-reports` (verified by grep — the router scope is the only
non-`old_report_live` reference).

**Files affected**:
- `lib/report_server_web/router.ex` — replace the scope
- `test/report_server_web/` — small router test

**Estimated diff size**: ~30 lines

```elixir
# BEFORE (router.ex:48-52)
scope "/old-reports", ReportServerWeb do
  pipe_through :browser

  live "/", OldReportLive.Index, :index
end

# AFTER — same pattern as the /new-reports scope below it
scope "/old-reports", ReportServerWeb do
  pipe_through :browser

  get "/*path", RedirectToReports, []
end
```

Tests: `GET /old-reports` → 302 to `/reports`; `GET /old-reports/anything` → 302 to
`/reports/anything` (matching the `/new-reports` behavior).

---

### Generic LiveView pagination + retrofit of the run list pages

**Summary**: The reusable offset pagination from the requirements' pager contract: a
`ReportServer.Pagination` query helper (fixed 25/page, clamp-to-last-page, page 1 canonical)
and a `pager` function component (keyboard-operable links in a
`<nav aria-label="pagination">` with `aria-current="page"`), then retrofits `/reports/runs`
and `/reports/all-runs`, which currently load all rows. Data loading moves from `mount` to
`handle_params` so `?page=N` navigation works via `push_patch`.

**Files affected**:
- `lib/report_server/pagination.ex` — new
- `lib/report_server_web/components/custom_components.ex` — add `pager/1` (+ its page-windowing helper)
- `lib/report_server/reports.ex` — add `list_user_report_runs_paginated/2`, `list_all_report_runs_paginated/1`
- `lib/report_server_web/live/report_run_live/index.ex` — move loads to `handle_params`, page assigns
- `lib/report_server_web/live/report_run_live/index.html.heex` — pager + empty state
- `test/report_server/pagination_test.exs`, `test/report_server_web/live/report_run_index_live_test.exs` — new

**Estimated diff size**: ~430 lines

Query helper (invalid input handling per the pager contract — non-integer/`< 1` → page 1,
beyond-last clamps; the returned `page` is always the page actually shown):

```elixir
defmodule ReportServer.Pagination do
  import Ecto.Query, warn: false

  alias ReportServer.Repo

  @per_page 25

  def per_page(), do: @per_page

  def paginate(query, page, per_page \\ @per_page) do
    total_count =
      query
      |> exclude(:order_by)
      |> exclude(:preload)
      |> Repo.aggregate(:count)

    total_pages = max(Float.ceil(total_count / per_page) |> trunc(), 1)
    page = page |> normalize_page() |> min(total_pages)

    items =
      query
      |> limit(^per_page)
      |> offset(^((page - 1) * per_page))
      |> Repo.all()

    %{items: items, page: page, per_page: per_page, total_pages: total_pages, total_count: total_count}
  end

  def normalize_page(page) when is_integer(page) and page >= 1, do: page
  def normalize_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {n, ""} when n >= 1 -> n
      _ -> 1
    end
  end
  def normalize_page(_), do: 1
end
```

Pager component (in `custom_components.ex`; hidden whenever there is one page; `path_fun`
builds hrefs so each page keeps its own URL scheme, with page 1 the canonical no-param URL;
windowing per OQ-5: `1 … p-1 p p+1 … N`):

```elixir
attr :page, :integer, required: true
attr :total_pages, :integer, required: true
attr :path_fun, :any, required: true, doc: "fn page -> patch path; must return the no-param path for page 1"

def pager(assigns) do
  assigns = assign(assigns, :items, pager_items(assigns.page, assigns.total_pages))

  ~H"""
  <%!-- disabled endpoints are plain spans WITHOUT aria-disabled (not a global ARIA state; a
       generic-role span doesn't permit it and screen readers ignore it there — the inactive
       text-zinc-500 styling is exempt from contrast as an inactive component). Unselected
       buttons are white with a border-zinc-500 boundary (>= 3:1 vs white per WCAG 1.4.11) and
       text-zinc-800; the disabled endpoints use a lighter border-zinc-300. Active page uses
       dark-orange: white on orange #ea6d2f is 3.12:1 (fails AA); on #c14d10 it is 4.84:1.
       aria-labels give SR users page semantics beyond bare numbers. --%>
  <nav :if={@total_pages > 1} aria-label="pagination" class="flex items-center gap-1 my-4 text-sm">
    <.link :if={@page > 1} patch={@path_fun.(@page - 1)} aria-label="Previous page" class="px-2 py-1 border border-zinc-500 rounded bg-white text-zinc-800 hover:bg-zinc-200">Previous</.link>
    <span :if={@page == 1} class="px-2 py-1 border border-zinc-300 rounded bg-white text-zinc-500">Previous</span>
    <%= for item <- @items do %>
      <span :if={item == :ellipsis} aria-hidden="true" class="px-1">&#8230;</span>
      <.link
        :if={is_integer(item)}
        patch={@path_fun.(item)}
        aria-label={"Page #{item}"}
        aria-current={if item == @page, do: "page"}
        class={["px-2 py-1 border rounded", item == @page && "bg-dark-orange text-white border-dark-orange", item != @page && "border-zinc-500 bg-white text-zinc-800 hover:bg-zinc-200"]}
      >
        <%= item %>
      </.link>
    <% end %>
    <.link :if={@page < @total_pages} patch={@path_fun.(@page + 1)} aria-label="Next page" class="px-2 py-1 border border-zinc-500 rounded bg-white text-zinc-800 hover:bg-zinc-200">Next</.link>
    <span :if={@page == @total_pages} class="px-2 py-1 border border-zinc-300 rounded bg-white text-zinc-500">Next</span>
  </nav>
  """
end

defp pager_items(page, total_pages) do
  [1, page - 1, page, page + 1, total_pages]
  |> Enum.filter(&(&1 >= 1 and &1 <= total_pages))
  |> Enum.uniq()
  |> Enum.sort()
  |> Enum.chunk_every(2, 1, :discard)
  |> Enum.reduce([1], fn [a, b], acc ->
    acc ++ if b - a > 1, do: [:ellipsis, b], else: [b]
  end)
end
```

Context queries reuse the existing query shapes:

```elixir
# reports.ex also gains: alias ReportServer.Pagination (External Review Round 3 — the same
# bare-alias trap as Tree in the API-endpoints step: the module aliases only
# Repo/User/ReportRun/Tree, so an unaliased Pagination call resolves to a non-existent
# top-level module and fails at runtime)

def list_user_report_runs_paginated(user = %User{}, page) do
  from(r in ReportRun, where: r.user_id == ^user.id, order_by: [desc: r.inserted_at], preload: [:user])
  |> Pagination.paginate(page)
end

def list_all_report_runs_paginated(page) do
  from(r in ReportRun, order_by: [desc: r.inserted_at], preload: [:user])
  |> Pagination.paginate(page)
end
```

`Index` LiveView after — mounts keep the access checks and static assigns; `handle_params`
loads the page (`push_patch` re-enters it):

```elixir
# index.ex also gains: alias ReportServer.Pagination (Round 3 — it aliases only
# ReportServer.Reports today)

@impl true
def mount(_params, _session, %{assigns: %{user: _user, live_action: :my_runs}} = socket) do
  {:ok, assign(socket, :page_title, "Your Runs")}
end

@impl true
def mount(_params, _session, %{assigns: %{user: user, live_action: :all_runs}} = socket) do
  if user.portal_is_admin do
    {:ok, assign(socket, :page_title, "All Runs")}
  else
    {:ok, socket |> put_flash(:error, "Sorry, you don't have access to that page.") |> redirect(to: "/reports")}
  end
end

@impl true
def mount(_params, _session, socket) do
  {:ok, socket |> put_flash(:error, "Sorry, you don't have access to that page.") |> redirect(to: "/reports")}
end

@impl true
def handle_params(params, _url, %{assigns: %{user: user, live_action: live_action}} = socket) do
  page = Pagination.normalize_page(params["page"])

  result = case live_action do
    :my_runs -> Reports.list_user_report_runs_paginated(user, page)
    :all_runs -> Reports.list_all_report_runs_paginated(page)
  end

  socket = socket
    |> assign(:report_runs, result.items)
    |> assign(:page, result.page)
    |> assign(:total_pages, result.total_pages)

  {:noreply, socket}
end

# defensive no-op for redirected mounts (LiveView does not invoke handle_params after a
# redirect in mount, but the clause keeps the module total)
@impl true
def handle_params(_params, _url, socket), do: {:noreply, socket}
```

Template after — pager below the table, plus the empty state the pager contract requires
(today an empty list renders a blank page):

```heex
<div class="font-bold my-2">
  <.breadcrumbs previous={[{"Reports", ~p"/reports"}]} current={@page_title} />
</div>

<div :if={length(@report_runs) > 0}>
  <.report_runs report_runs={@report_runs} include_report_titles={true} include_user={@user.portal_is_admin} />
  <.pager page={@page} total_pages={@total_pages} path_fun={run_list_path(@live_action)} />
</div>
<div :if={length(@report_runs) == 0} class="my-4 text-sm">No report runs found.</div>
```

with a small helper in the LiveView building canonical URLs:

```elixir
defp run_list_path(:my_runs), do: fn
  1 -> ~p"/reports/runs"
  page -> ~p"/reports/runs?page=#{page}"
end
defp run_list_path(:all_runs), do: fn
  1 -> ~p"/reports/all-runs"
  page -> ~p"/reports/all-runs?page=#{page}"
end
```

Tests, summarized:
- `Pagination.paginate/3`: 0 rows → page 1, total_pages 1, empty items; 26 rows → pages 1-2 with 25/1 items; `page=2` of 26 returns the overflow row; `page="abc"`/`page="0"`/nil → page 1; `page=99` clamps to last
- pager component (render-component tests): hidden at 1 page; `aria-current="page"` on the active link; `aria-label="Page N"` on number links and `"Previous page"`/`"Next page"` on the endpoints; no `aria-disabled` anywhere; window `1 … 4 5 6 … 20` for page 5 of 20; no ellipsis for 3 pages
- LiveView: page 2 via `?page=N` patch shows rows 26+; invalid/overflow pages render page 1/last with no crash; `:all_runs` still admin-gated; empty list shows the empty state and no pager

---

### Admin-only audit-log page

**Summary**: The read surface for `data_access_log` decided in the requirements: an admin-only
(`portal_is_admin`) LiveView at `/reports/audit-log`, paginated newest-first with the shared
pager, columns exactly per the requirements (timestamp, requesting user, run id + report slug,
data type/event). No filters in v1.

**Files affected**:
- `lib/report_server/audit_log.ex` — `list_entries_paginated/1` goes live against `Pagination`
- `lib/report_server_web/live/audit_log_live/index.ex` + `index.html.heex` — new
- `lib/report_server_web/router.ex` — route in the `:reports` live_session
- `test/report_server_web/live/audit_log_live_test.exs` — new

**Estimated diff size**: ~240 lines

`AuditLog.list_entries_paginated/1` (the template dereferences `entry.user.*`, so the `:user`
preload is load-bearing — Ecto doesn't lazy-load; without it the page crashes on
`%Ecto.Association.NotLoaded{}`):

```elixir
# audit_log.ex also gains: alias ReportServer.Pagination (Round 3 — its alias block declares
# only Repo/DataAccessLogEntry/ReportRun)

def list_entries_paginated(page) do
  from(e in DataAccessLogEntry, order_by: [desc: e.inserted_at], preload: [:user])
  |> Pagination.paginate(page)
end
```

LiveView (mirrors the `:all_runs` admin gate; data loads in `handle_params` like the
retrofitted run lists):

```elixir
defmodule ReportServerWeb.AuditLogLive.Index do
  use ReportServerWeb, :live_view

  alias ReportServer.{AuditLog, Pagination}

  @impl true
  def mount(_params, _session, %{assigns: %{user: user}} = socket) do
    if user.portal_is_admin do
      {:ok, assign(socket, :page_title, "Data Access Log")}
    else
      {:ok, socket |> put_flash(:error, "Sorry, you don't have access to that page.") |> redirect(to: "/reports")}
    end
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> put_flash(:error, "Sorry, you don't have access to that page.") |> redirect(to: "/reports")}
  end

  @impl true
  def handle_params(params, _url, %{assigns: %{user: %{portal_is_admin: true}}} = socket) do
    result = AuditLog.list_entries_paginated(Pagination.normalize_page(params["page"]))

    socket = socket
      |> assign(:entries, result.items)
      |> assign(:page, result.page)
      |> assign(:total_pages, result.total_pages)

    {:noreply, socket}
  end
  def handle_params(_params, _url, socket), do: {:noreply, socket}
end
```

Template — proper `<th>` markup (same table classes as `report_runs/1` in
`custom_components.ex`), run id linking to the run page, and the shared pager:

```heex
<div class="font-bold my-2">
  <.breadcrumbs previous={[{"Reports", ~p"/reports"}]} current="Data Access Log" />
</div>

<div :if={length(@entries) > 0}>
  <%!-- text-zinc-600, not the run lists' zinc-500: zinc-500 on the gray-100 header is 4.39:1
       and on hovered zinc-200 rows 3.81:1 (both fail AA); zinc-600 is >= 6:1 on both.
       Optionally retrofit report_runs/1 in custom_components.ex to match. --%>
  <table class="w-full border-collapse bg-white text-sm">
    <thead class="bg-gray-100 text-left leading-6 text-zinc-600">
      <tr>
        <th class="p-2 font-normal border-b">When</th>
        <th class="p-2 font-normal border-b">User</th>
        <th class="p-2 font-normal border-b">Run</th>
        <th class="p-2 font-normal border-b">Access</th>
      </tr>
    </thead>
    <tbody>
      <tr :for={entry <- @entries} class="group hover:bg-zinc-200 even:bg-gray-50">
        <td class="p-2 font-normal border-b align-top">
          <time datetime={DateTime.to_iso8601(entry.inserted_at)}>
            <%= Calendar.strftime(entry.inserted_at, "%Y-%m-%d %H:%M UTC") %>
          </time>
        </td>
        <td class="p-2 font-normal border-b align-top"><%= entry.user.portal_first_name %> <%= entry.user.portal_last_name %> (<%= entry.user.portal_email %>)</td>
        <td class="p-2 font-normal border-b align-top">
          <.link class="underline" href={"/reports/runs/#{entry.report_run_id}"}><%= entry.report_run_id %></.link>
          <span class="text-zinc-600"><%= entry.report_slug %></span>
        </td>
        <td class="p-2 font-normal border-b align-top">
          <%= entry.data_type %> / <%= entry.event %> (<%= entry.source %>)
          <span :if={entry.job_id}>— job <%= entry.job_id %></span>
        </td>
      </tr>
    </tbody>
  </table>
  <.pager page={@page} total_pages={@total_pages} path_fun={&audit_log_path/1} />
</div>
<div :if={length(@entries) == 0} class="my-4 text-sm">No data access events have been recorded yet.</div>
```

Route (inside the `:reports` live_session — the researcher gate applies, then the mount narrows
to admins). Same placement rule as `/cli-token`: it must go **above** the `live "/*path"`
catch-all (`router.ex:69`) or it never matches:

```elixir
live "/audit-log", AuditLogLive.Index, :index
```

with the canonical-URL helper the template's `path_fun={&audit_log_path/1}` capture refers to
(page 1 is the no-param URL, mirroring `run_list_path/1` in the pagination step):

```elixir
defp audit_log_path(1), do: ~p"/reports/audit-log"
defp audit_log_path(page), do: ~p"/reports/audit-log?page=#{page}"
```

Tests, summarized:
- non-admin researcher → redirect + flash (and non-report users are stopped by the live_session gate)
- admin sees rows newest-first with the four columns populated; job rows show the job id
- pagination: 26 entries → pager present, page 2 shows the oldest
- table headers are `<th>` elements; pager `nav` has `aria-label="pagination"`; the timestamp cell renders a `<time>` element with an ISO 8601 `datetime` attribute (all asserted via rendered HTML)

## Open Questions

<!-- Implementation-focused questions only. Requirements questions go in requirements.md. -->

### OQ-1 RESOLVED: Token format — opaque random + hash-at-rest, or signed (Phoenix.Token)?
**Context**: The requirements pin the properties (shown once, irreversible at rest, CSPRNG,
revocable, non-expiring) but defer the mechanism. The plan's code uses **opaque random**:
`ccd_` + base64url of 32 random bytes, SHA-256 hex at rest, verified by hash lookup.
**Options considered**:
- A) Opaque random + SHA-256 at rest (as written). One indexed lookup to verify; nothing
  recoverable from a leaked DB; no crypto-versioning concerns; the `ccd_` prefix supports
  secret scanning. (Recommended)
- B) `Phoenix.Token` signed tokens. Verification without a DB hit — but revocation and
  `last_used_at` require the DB row anyway, so the benefit evaporates; and `secret_key_base`
  rotation would invalidate every CLI token.

**Decision**: **A — opaque random + SHA-256 at rest.** B's stateless-verification advantage
does not apply (revocation and `last_used_at` need the row on every request anyway), and A
avoids coupling token validity to `secret_key_base` rotation. The plan's code stands as
written.

### OQ-2 RESOLVED: Test seams for AWS/portal calls — config-swappable stubs or Mox?
**Context**: API tests must control Athena/S3 responses (no credentials or network in CI). The
plan uses `Application.get_env(:report_server, :athena_db | :aws_file_store | :report_tree,
RealModule)` seams with Agent-backed stubs in `test/support` (tests `async: false`).
**Options considered**:
- A) Config-swappable modules (as written). No new dependency; matches the app's plain style;
  the seams are three one-line private functions. Costs: affected tests are `async: false`,
  and there is no automatic call-verification. (Recommended)
- B) Add `mox` and define behaviours for the three seams. Standard, async-safe,
  expectation-verified — at the cost of a new dep plus behaviour modules for code that has
  exactly one production implementation.

**Decision**: **A — config-swappable modules, no new dependency.** The suite is small and the
tests assert on observed effects (DB rows, response bodies) rather than call counts, so Mox's
advantages don't pay for the boilerplate here. Revisit if the seams multiply.

### OQ-3 RESOLVED: Extract state-refresh/self-start into `AthenaRunOps` and retrofit the Show LiveView?
**Context**: The requirements demand the API use "the same path the Show LiveView uses". The
plan extracts that path into `Reports.AthenaRunOps` and rewrites two Show internals to
delegate, so there is one implementation. The alternative keeps Show untouched and duplicates
the with-chains in API-only code.
**Options considered**:
- A) Extract + retrofit (as written). Single writer of the start/refresh logic; the API
  provably shares the LiveView's path; small behavior-preserving edit to `Show` (its only risk,
  and it is covered by the AthenaRunOps unit tests). (Recommended)
- B) API-side duplication, Show untouched. Zero regression risk to the web page now, but two
  copies of subtle logic ("persist both fields") that can drift — the exact drift class the
  round-4 requirements finding was about.

**Decision**: **A — extract into `AthenaRunOps` and retrofit Show to delegate.** The
single-writer property protects the persist-both-fields behavior the requirements exist to
guarantee, the Show edit is mechanical, and this matches the requirements' future-consideration
direction (one owner of query start/poll logic).

### OQ-4 RESOLVED: Login round-trip preservation — session storage or encoded `return_to` URI?
**Context**: The requirements allow either "stored server-side before redirecting to login, or
carried as an encoded full `/auth/cli` request URI in `return_to`". The plan stores the
validated request map in the session (`:cli_auth_request`) and sets
`return_to = /auth/cli/resume`.
**Options considered**:
- A) Session storage + `/auth/cli/resume` (as written). Only validated data crosses the hop;
  the resume handler re-checks login/portal/role; no query-string length or re-validation
  concerns; uses `save_token`'s existing `return_to` mechanics unchanged. (Recommended)
- B) Encode the full `/auth/cli` request URI into `return_to`. No new session key and the
  request survives a session loss — but the params make a second pass through validation, the
  URI needs encoding discipline, and `return_to` handling today is a plain string round-trip
  never designed for nested URIs.

**Decision**: **A — session storage + `/auth/cli/resume`.** Uses the existing `return_to`
machinery exactly as designed (a plain path), only validated data crosses the hop, and the
dedicated resume action with explicit re-checks (login, portal match, role gate) is easier to
reason about and test than URI-encoding discipline.

### OQ-5 RESOLVED: Pager windowing — `1 … p-1 p p+1 … N`?
**Context**: The requirements leave windowing/truncation to implementation. The plan renders
first page, a one-page neighborhood of the current page, and the last page, with ellipses —
7 items maximum, stable width.
**Options considered**:
- A) `1 … p-1 p p+1 … N` (as written). Compact and conventional for admin tables. (Recommended)
- B) A wider neighborhood (±2) — more jump targets, longer pager.
- C) Prev/Next only, no numbers — simplest, but the requirements' "classic pager UI
  (prev/next + page numbers)" language points away from this.

**Decision**: **A — `1 … p-1 p p+1 … N`.** Bounded width (max 7 items plus Previous/Next) at
any table size, which matters for the unbounded audit log; conventional for admin tables.

### OQ-6 RESOLVED: Where does `AuditLog.list_entries_paginated/1` land?
**Context**: The audit-table step (early, so the API downloads can log) is several commits
before the pagination step that provides `ReportServer.Pagination`.
**Options considered**:
- A) The function ships with the admin-page step (last), keeping the audit-table commit free of
  forward references. The audit context's early commit exposes only `create_entry` +
  `issue_download_url`. (Recommended — and what the step list above actually implies)
- B) Ship a non-paginated `list_entries/0` early and swap it later (throwaway code).

**Decision**: **A — the read function ships with the admin-page step.** The early audit commit
exposes only `create_entry/1` + `issue_download_url/6`; `list_entries_paginated/1` arrives with
its only caller and its dependency. No forward references, no throwaway code.

### OQ-7 RESOLVED: Default label for tokens minted via the CLI login flow?
**Context**: The manual page has a label input; the loopback flow has nowhere to collect one
(the CLI could pass a `label` param through `/auth/cli`, but that is a contract addition STORY 4
would have to honor). The plan hardcodes `"CLI login"`.
**Options considered**:
- A) Fixed label `"CLI login"` (as written); STORY 2's UI still distinguishes tokens by
  `last_used_at`/created time. (Recommended for this story; a `label` param can be added to
  `/auth/cli` later, additively)
- B) No label (nil) — indistinguishable rows in the STORY 2 list.
- C) Accept an optional validated `label` param on `/auth/cli` now and echo it into the mint —
  nicer labels, small scope addition to the server contract STORY 4 can adopt.

**Decision**: **A — fixed label `"CLI login"`.** No contract surface added; STORY 2's list
distinguishes tokens by timestamps regardless. A `label` param on `/auth/cli` stays available
as a purely additive follow-up whenever STORY 4 wants it.

### OQ-8 RESOLVED: Verifier mismatch burns the one-time code — confirm?
**Context**: The exchange consumes the code atomically **before** checking the PKCE verifier,
so a mismatched verifier leaves the code unusable (a retry with the right verifier gets the
same 400). This is deliberate: consume-first is what makes single-use atomic, and OAuth 2.0
Security BCP advises invalidating a code after a failed exchange attempt (it may be in an
attacker's hands). The cost: a CLI bug that sends a wrong verifier forces a fresh browser
login. The alternative (verify-then-consume in a transaction, leaving the code intact on
mismatch) is kinder to buggy clients but gives a code thief unlimited verifier guesses within
the 5-minute window.
**Options considered**:
- A) Consume-first (as written) — code burned on any exchange attempt. (Recommended)
- B) Transactional verify-then-consume — code survives verifier mismatches; single-use still
  atomic via `SELECT ... FOR UPDATE`.

**Decision**: **A — consume-first; any exchange attempt burns the code.** Matches OAuth 2.0
Security BCP (a failed attempt means the code may be in an attacker's hands) and the
requirements' posture that code entropy + single-use are the only brute-force defenses with
rate limiting out of scope. A wrong-verifier CLI bug failing loudly is the desired behavior.

## Self-Review

Roles run with no findings: **DevOps Engineer** (all three migrations are additive with the
repo's existing FK conventions; `filter_parameters` is read at request time so `config.exs`
placement works; no deploy-ordering hazards — migrations precede app start as usual).
Verified during review: dimension ids in `report_filter` are stored as **integers**
(`ReportFilter.get_filter_value/2` maps `String.to_integer/1`; `:state` stays strings), so the
serializer's serve-as-stored is contract-compliant.

### Senior Engineer

#### RESOLVED: Pagination retrofit — the promised `handle_params` fallback clause is missing from the code block
The step's prose says "the catch-all `handle_params` clause for that case simply returns
`{:noreply, socket}`", but the code block defines only the
`%{assigns: %{user: _, live_action: _}}` clause. LiveView does not invoke `handle_params`
after a `redirect/2` in mount, so in practice the clause never fires — but the prose and code
disagree, and an implementer copying the block gets a module whose comment references a clause
that isn't there. Add the fallback clause to the code block (or drop the prose sentence).
**Resolution**: Approved — the fallback clause is now in the code block (with a comment noting
it is defensive) and the stale prose note was removed.

---

#### RESOLVED: `authorize_or_reject` crashes on an unexpected grant-insert failure
`{:ok, raw_code, _auth_grant} = Accounts.create_auth_grant(...)` is a hard match; a changeset
error (practically unreachable — all inputs are server-generated — but possible under e.g. a
DB outage) becomes a `MatchError` and a raw 500 page mid-login. A `case` with the error branch
rendering the existing CLI error page ("Something went wrong, please try again") is a
three-line change that keeps the flow's failure mode consistent.
**Resolution**: Approved — `authorize_or_reject` now cases on the insert result and renders
the CLI error page on `{:error, _changeset}`.

---

### Security Engineer

#### RESOLVED: `code_challenge` format is not validated at entry
Entry validation only requires `code_challenge` to be a non-empty string. An S256 challenge is
by definition exactly 43 base64url characters (RFC 7636 §4.2). Accepting arbitrary strings
means junk grants (unexchangeable, since no verifier can hash to a non-base64url value) and a
confusing exchange-time 400 instead of a clear entry-time error. One regex at entry —
`~r/^[A-Za-z0-9_-]{43}$/` — fails fast with "code_challenge must be a base64url-encoded SHA-256
digest" and keeps garbage out of the grants table.
**Resolution**: Approved — `validate_code_challenge/1` added to the entry validation chain,
with a malformed-challenge case added to the entry-validation test list.

---

### QA Engineer

#### RESOLVED: The `AthenaRunOps` step edits the Show LiveView with no LiveView-level regression test
Step 4 rewrites two internals of `show.ex` (query start on mount, poll-driven refresh) and
covers the extracted logic with `AthenaRunOps` unit tests, explicitly deferring Show coverage.
That leaves the delegation edit itself — the one behavior-risk in the step — untested at the
LiveView layer. A single smoke test (log in via `log_in_conn`, open an Athena run with a
stubbed `:athena_db`, assert the run gains an `athena_query_id` and the page renders the
running state) would catch a botched retrofit for ~40 lines of test.
**Resolution**: Approved — a Show smoke test (mount-start case + poll-refresh case) was added
to the AthenaRunOps step, which now also introduces the `log_in_conn` ConnCase helper the later
LiveView tests reuse. Assertions target DB effects and basic rendering, not the `assign_async`
results panel.

---

### Performance Engineer

#### RESOLVED: `Tree.athena_report_slugs/0` rebuilds the whole report tree on every call
As written it calls the private `get_tree()`, which constructs every group/report struct and
closure — and it runs on every API list/show/download/jobs request (inside the query
builders). The tree is static and already cached in ETS at startup. Walking `root()` (the
cached, decorated tree) instead is the same one-line body with no per-request reconstruction;
in dev (cache disabled) `root()` falls back to `search_in_tree` and behavior is identical.
Negligible at current traffic either way — this is hygiene, not a hotspot.
**Resolution**: Approved — `athena_report_slugs/0` now walks `root()` (the cached tree) with a
comment explaining the choice.

---

### WCAG Accessibility Expert

#### RESOLVED: Audit-log timestamp cell renders a raw `DateTime`
`<%= entry.inserted_at %>` renders Elixir's default `DateTime` string. The run lists render
timestamps via the existing `.relative_time` component; an audit log needs *absolute* times,
but should still use a semantic `<time datetime={DateTime.to_iso8601(entry.inserted_at)}>`
element with a human-formatted UTC display (e.g. `2026-07-10 15:03 UTC`) so assistive tech and
machine readers get the precise instant.
**Resolution**: Approved — the template now renders
`<time datetime={ISO 8601}>%Y-%m-%d %H:%M UTC</time>`, with a rendered-HTML assertion added to
the audit-page tests.

---

## Self-Review — Round 2 (cross-reference vs requirements + code-verified assumptions)

A full cross-reference of this plan against requirements.md found **no coverage gaps** — every
requirement traces to a step. The plan's assumptions about existing code were then verified
against the codebase (file:line checks for every load-bearing claim: jobs-file JSON shape and
filename, `Job`/`Step` encoder fields, `AthenaDB` signatures/returns, `Auth` session functions
and the cookie-store `renew: true` data-survival claim, the Show LiveView before-blocks
including the latent `{:ok, download_url} =` crash, `ReportFilter`'s 15 fields, `Tree.init` at
app start and the five `:athena` slugs, User/ReportRun schemas, bare `ConnCase`, missing
`filter_parameters`, Elixir 1.16.2 for `DateTime.utc_now(:second)`) — all confirmed. Pure-logic
assumptions (pager windowing across 7 cases, page-token round trip, total-pages math, S256
challenge = 43 base64url chars) were verified dynamically with a throwaway script (all passed,
then deleted). Playwright checks were again not applicable (no local server; flows need portal
OAuth + AWS credentials). Three plan defects were found and fixed:

### Senior Engineer

#### RESOLVED: `/cli-token` and `/audit-log` routes would be shadowed by the `live "/*path"` catch-all
The `:reports` live_session ends with `live "/*path", ReportLive.Index, :index`
(`router.ex:69`). Phoenix matches routes in order, and neither router snippet said where to
insert the new routes — appended after the wildcard (the natural "add at the end" move), the
two new pages would never mount.
**Resolution**: Fixed — both route snippets now state the route must be added **above** the
`/*path` catch-all, with the rationale.

---

### QA Engineer

#### RESOLVED: Jobs-endpoint tests crash — no `:report_server, :output` config exists in the test env
`JobsFile.list_jobs/1` calls `Output.get_jobs_url/1` before reaching the stubbed `aws()` seam,
and `Output.config/0` does `Keyword.get(Application.get_env(:report_server, :output), ...)`.
Only `dev.exs`/`runtime.exs` define `:output`; `config/test.exs` does not, so `get_env`
returns `nil` and `Keyword.get(nil, ...)` raises `FunctionClauseError` (verified dynamically).
**Resolution**: Fixed — the jobs step's files-affected list and body now include adding the
`:output` config to `config/test.exs`.

---

#### RESOLVED: `audit_log_path/1` referenced in the audit-log template but never defined
The template passes `path_fun={&audit_log_path/1}` to the pager, but unlike the pagination
step (which defines `run_list_path/1`), the helper appeared nowhere — an implementer copying
the step gets a compile error.
**Resolution**: Fixed — the admin-page step now defines `audit_log_path/1` (page 1 = canonical
no-param URL, mirroring `run_list_path/1`).

---

## Self-Review — Round 3 (multi-role, code-verified)

Six roles (Senior Engineer, Security Engineer, QA Engineer, Performance Engineer, DevOps
Engineer, WCAG Accessibility Expert) reviewed the plan independently; every candidate issue was
then **re-verified in the main review session** against the current codebase (file:line evidence
below) before being written up — unconfirmed candidates were discarded. Dynamic verification
where applicable: the `page_token` overflow was reproduced with a throwaway script against the
MyXQL encoder guard; all WCAG contrast ratios were recomputed independently from the actual
Tailwind palette; the Ecto/Phoenix dep sources were read for every framework-behavior claim
(`Phoenix.Logger.filter_values` runtime read, `Repo.update` empty-changeset no-op,
`Ecto.Adapters.SQL.Sandbox` shared-mode serialization, MyXQL int64 encode guard). Three
findings were discovered independently by two roles each (noted inline). Security additionally
verified and cleared: PKCE `secure_compare` length behavior, `update_all` compare-and-swap
atomicity, `redirect_uri` bypass candidates (`127.0.0.1.evil.com`, `localhost`, userinfo
tricks), `state` echo injection, code/token log exposure (response `Location` headers are not
logged), session fixation across `renew: true`, and audit-bypass paths — all clean.

**All findings below are RESOLVED — every suggested resolution was approved and applied to the
plan (2026-07-10).** Each entry's "Suggested resolution" is what was implemented; where an
entry offered options, the chosen one was: exception rendering via a path-keyed
`ErrorJSON` clause (not `Plug.ErrorHandler`); self-start made single-flight via an atomic
nil→`"queued"` claim in `ensure_current/1`; a new first step adds the phx.gen.release
`ReportServer.Release` migrator + README deploy note; audit-write-failure testing uses FK
constraints in the changeset plus unit-level forcing via inclusion validation, with the
HTTP-level negative path explicitly scoped to the presign half (documented in the
`data_access_log` and download/web-audit steps); the `data_access_log` FKs are **kept** and
documented as a deliberate one-way door; the cli-token label input is a plain labeled
`<input>` with a `focus:ring-2 focus:ring-teal` indicator (3.66:1); `bg-orange` text surfaces
use a new `dark-orange` `#c14d10` token (4.84:1, verified); the `touch_api_token` freshness
threshold (60s) was adopted. New replacement colors were contrast-verified before being
written in.

### Senior Engineer

#### RESOLVED: Unhandled API exceptions render Phoenix's `ErrorJSON` shape, not the contract's `SERVER_ERROR` shape
The plan's `ErrorHelpers` covers only *explicitly rendered* errors. Any raise inside `/api/v1`
(DB outage, a bug, the `page_token` overflow below) is rendered by the endpoint's configured
`render_errors` fallback — `ReportServerWeb.ErrorJSON` (`config/config.exs:17-20`), whose shape
is `{"errors": {"detail": ...}}` (`error_json.ex:18-20`) — the exact shape the requirements say
the contract "intentionally differs" from. The requirements Contract section pins "**All**
500-class API failures use the single code `SERVER_ERROR`", and nothing in the plan (no
`Plug.ErrorHandler`, no API-scoped exception rendering) delivers that for raises.
**Why it matters**: the CLI is promised one error shape everywhere; the most common real-world
500s (unexpected exceptions) would return a different one.
**Suggested resolution**: add API-scoped exception rendering (e.g. `Plug.ErrorHandler` in the
pipeline or a custom `ErrorJSON` clause keyed on the request path) emitting
`{"error": "SERVER_ERROR", "message": "An internal error occurred."}` — or explicitly scope the
requirement to handled failures and document the fallback shape.

#### RESOLVED: `start_query/1` hardcodes `Tree.find_report/1`, but the step's mandated tests require the `:report_tree` seam the code never defines
*(found independently by Senior Engineer and QA Engineer)*
The `AthenaRunOps.start_query/1` code block calls `Tree.find_report(report_run.report_slug)`
directly, while the step's persisted-filter test bullet says "The report seam is
`Application.get_env(:report_server, :report_tree, Tree)`" and OQ-2 lists `:report_tree` as one
of the three seams. Without the seam, the requirements-mandated persisted-filter self-start test
and the API "show self-start" test are unwritable: the five real `get_query` implementations
call `LearnerData.fetch_and_upload` (`reports/athena/student_answers_report.ex:6-8`), which
needs a live portal DB (env-var connection strings, `portal_dbs.ex:185-196`) and S3. Note also
that the API context queries filter by the **real** `Tree.athena_report_slugs()` (not
seam-covered), so seam-stubbed test runs must still use a real Athena slug — worth stating.
**Suggested resolution**: add
`defp tree(), do: Application.get_env(:report_server, :report_tree, Tree)` to the
`AthenaRunOps` block and call `tree().find_report(...)`; note the real-slug constraint in the
test bullets.

#### RESOLVED: Missing aliases / `require Logger` in two code blocks
(a) The `Reports` context additions call `Tree.athena_report_slugs()`, but `reports.ex:1-7`
aliases only `Repo`, `User`, `ReportRun` — bare `Tree` resolves to a non-existent top-level
module: compiles with a warning, `UndefinedFunctionError` on first request. (b) The download
step's `download/2` uses `Logger.error` (a macro needing `require Logger`),
`AuditLog.issue_download_url`, and `%ReportRun{}` matches, but the `ReportController` defined in
the previous step has none of those requires/aliases and `use ReportServerWeb, :controller`
does not provide `Logger` (`report_server_web.ex` controller macro verified) — compile error.
**Suggested resolution**: add `alias ReportServer.Reports.Tree` to the reports.ex diff;
add `require Logger` + `alias ReportServer.AuditLog` + `alias ReportServer.Reports.ReportRun`
to the download-step controller diff.

---

### Security Engineer

#### RESOLVED: A decodable `page_token` carrying an out-of-int64 integer crashes the list query — 500 in the wrong error shape where the contract mandates 400
*(found independently by Security Engineer and Senior Engineer)*
`parse_page_token` only does `Base.url_decode64` + `Integer.parse` — unlike `parse_id`, which
deliberately bounds-checks against `@max_bigint`. Elixir integers are arbitrary-precision and
Ecto's `:id` type doesn't range-check, but MyXQL's binary encoder accepts only
`value >= -1 <<< 63 and value < 1 <<< 64` with **no fallback clause**
(`deps/myxql/lib/myxql/protocol/values.ex:191-193`) — anything larger raises
`FunctionClauseError` inside `Repo.all`. Verified dynamically: `page_token =`
base64url(`"18446744073709551616"`) decodes cleanly, passes `Integer.parse`, and fails the
MyXQL guard. The controller's `else` only handles `{:error, message}`, so the raise propagates
to the default `ErrorJSON` — a 500 in the non-contract shape, where the contract mandates
**400 `BAD_REQUEST`** for a malformed `page_token`. Remotely triggerable by any token holder.
**Suggested resolution**: give `parse_page_token` the same bounds check as `parse_id` (share
`@max_bigint`; reject non-positive too), returning `{:error, "page_token is not valid"}`. Add
the oversized-token case to the list-pagination tests.

---

### QA Engineer

#### RESOLVED: Web-audit tests say "stubbed `:athena_db`", but the retrofitted LiveView code calls `AthenaDB.get_download_url/2` directly — the stub is inert
*(found independently by QA Engineer and Senior Engineer)*
Both web retrofits hardcode `AthenaDB.get_download_url(...)` inside the presign fun (run page
and post-processing handler), with no `athena_db()` seam — unlike the API download step. The
test bullets claim "stubbed `:athena_db`" and assert "the pushed event carries the stubbed
URL". The real call doesn't even fail loudly: `get_download_url` is an **offline** ExAws presign
(`athena_db.ex:28-34`, no network) and `:aws_credentials` is configured unconditionally in
`runtime.exs`, so tests get a real locally-signed URL that never equals the stub's canned value
— and the web presign-failure fail-closed branch (a pinned requirement) is untestable.
**Suggested resolution**: route both web presign calls through the same
`athena_db()` config seam used everywhere else (one line each).

#### RESOLVED: Show-page tests with succeeded runs collide with the un-stubbed PostProcessing `JobServer` — crash at the AthenaRunOps step, unseedable jobs at the web-audit step
`show.html.heex:24-30` renders `PostProcessingComponent` unconditionally; its `update` gates on
`show_component?` (`post_processing.ex:14-26,191-199`) — true for a succeeded `:athena` run
whose report type has steps (`student-answers`, `student-actions`,
`student-actions-with-metadata` — `job_server.ex:157-172`) — and then `init` runs
`JobSupervisor.maybe_start_server` + `JobServer.register_client`. `JobServer.init` →
`read_jobs_file` → `Output.get_jobs_url` → `Output.config` does
`Keyword.get(Application.get_env(:report_server, :output), ...)` (`output.ex:2-8`), and
`:output` is only added to `config/test.exs` in the **later jobs step** — so at the
AthenaRunOps step the smoke test's poll-refresh-to-`succeeded` case crashes the temporary
JobServer, and `get_server_pid`'s `[{pid, _}] = Registry.lookup(...)` (`job_server.ex:178-181`)
can `MatchError` **in the LiveView process**. At the web-audit step (config present),
`JobServer.read_jobs_file` calls `Aws.get_file_contents` directly (`job_server.ex:159`) — not
the `:aws_file_store` seam — so it makes a real S3 attempt per test and jobs stay `[]`; the
post-processing audit test needs a rendered job with a `result` to click, and the plan gives no
seeding mechanism.
**Suggested resolution**: (a) move the `:output` test config into the AthenaRunOps step, and/or
pin the smoke test's succeeded-state case to a steps-less slug (`teacher-actions` /
`student-assignment-usage`); (b) for the post-processing audit test, seed jobs via the
`{:jobs, query_id, jobs}` message the Show LiveView already forwards (`show.ex:95-99`), or
route `JobServer.read_jobs_file` through the `:aws_file_store` seam.

#### RESOLVED: The "force an audit-write failure" tests have no workable forcing mechanism — and the imagined one raises instead of returning `{:error, :audit, _}`
*(found independently by QA Engineer and Senior Engineer)*
The API download test bullet forces audit failure via a "deleted user row edge", which is
doubly unreachable: (1) the authenticated user always holds `api_tokens` and `report_runs` rows
whose FKs are `on_delete: :nothing` (MySQL RESTRICT) — the `DELETE FROM users` itself fails;
(2) even with an engineered FK violation, `Repo.insert` **raises** `Ecto.ConstraintError`
unless the changeset declares `foreign_key_constraint(...)` — and the `DataAccessLogEntry`
changeset is described as validating only event/source/data_type inclusion. So
`issue_download_url`'s `{:error, :audit, _}` branch never fires for that cause; the raise
bypasses `ErrorHelpers.server_error/1` and lands in the wrong-shape 500 (see the Senior
Engineer exception-rendering finding).
**Suggested resolution**: declare `foreign_key_constraint(:user_id)` /
`foreign_key_constraint(:report_run_id)` in the changeset; force unit-level failure via an
invalid `source`/`data_type` (inclusion validation); for controller/LiveView level either add a
small injectable audit seam or scope the fail-closed negative coverage to the unit test and say
so.

#### RESOLVED: Removing `/api/v1/ping` breaks `auth_plug_test.exs`, which the runs step doesn't touch
The pipeline step's auth tests all exercise `GET /api/v1/ping`; the runs step deletes the route
and controller but its files-affected list omits `test/report_server_web/api/auth_plug_test.exs`
— every auth-plug test raises `Phoenix.Router.NoRouteError` at that commit (broken intermediate
commit; hurts bisectability).
**Suggested resolution**: add "retarget `auth_plug_test.exs` to `GET /api/v1/reports`" to the
runs step's files-affected list (assertions port unchanged).

#### RESOLVED: Coverage gap — `/download` self-start (nil `athena_query_id`) is never exercised
The requirements pin self-start on **both** `GET /:id` and `/:id/download`, but the union of
all test lists covers it only on show. The download tests' nil case reads as a nil-*state* run
under a pinned refresh — a controller that called `ensure_current` only in `show` would pass
every listed test while violating the requirement, on the endpoint the CLI actually blocks on.
**Suggested resolution**: add one download test: persisted run with `athena_query_id: nil` +
stubbed tree/athena → 409 with the **new** state and the run row gained an `athena_query_id`;
optionally the start-failure twin (stub error → 409 with `athena_query_state: null`).

#### RESOLVED: Valid-`portal` tests depend on `<SERVER>_DB` env vars and fixture `portal_server` alignment the plan never states
`validate_portal` → `PortalDbs.has_db_connection?/1` → `get_connection_string/1` reads
`System.get_env("<SERVER>_DB")` at call time (`portal_dbs.ex:185-196`); the test env sets no
such var, so every supplied `?portal=` fails entry validation unless setup does
`System.put_env` (with `on_exit` cleanup). Separately, the happy-path "logged-in researcher on
the matching portal" test must build the session user with
`portal_server == PortalDbs.get_server_for_portal_url(portal)` — the fixture default
`"learn.concord.org"` does not match the test-config default portal
`learn.portal.staging.concord.org` (`config/test.exs:34-36`), so `portal_matches?` would route
to a fresh portal login where the test expects the loopback redirect.
**Suggested resolution**: add a test-notes line to the step: set a fake `<SERVER>_DB` env var in
setup for valid-portal cases, and derive the session user's `portal_server` via
`get_server_for_portal_url/1`.

#### RESOLVED: The "two concurrent Tasks" atomic-exchange test cannot produce real DB concurrency under the shared sandbox
`test_helper.exs` sets `:manual` mode; the planned ConnCase setup copies
`DataCase.setup_sandbox/1`, whose shared mode funnels every process through the owner's
**single** connection (`deps/ecto_sql/.../sandbox.ex` — only PostgreSQL supports truly
concurrent sandbox tests). The two Tasks' `update_all` calls are serialized by DBConnection, so
the test passes against the planned implementation but would catch a regression to a racy
SELECT-then-UPDATE implementation only flakily, if ever — it re-proves single-use, not
race-safety.
**Suggested resolution**: keep the test but note in the plan that atomicity is guaranteed by
construction (conditional `UPDATE` returning `{1, _}`), which the sequential
second-exchange-fails test already locks in — don't present the Task test as race-proof.

---

### Performance Engineer

#### RESOLVED: API self-start stampede — a 1s-polling CLI can stack concurrent 5-minute portal queries
Self-start runs `report.get_query` inline in the request; for all five Athena reports that is
`LearnerData.fetch_and_upload` — a portal MySQL query (timeout **300_000 ms**,
`portal_dbs.ex:9`; per-portal pool of **5** connections, `portal_dbs.ex:31`) plus an S3 upload.
The Show LiveView does this inside `assign_async` (`show.ex:46-47`) — off the request path; the
API does it inline. While the first self-start is in flight, `athena_query_id` is still nil, so
**every poll starts another one** — the requirements' accepted race ("one wasted duplicate
query", calibrated to two browser tabs) becomes a pool-saturating stampede under the CLI's ~1s
poll loop. (The Athena `StartQueryExecution` itself is idempotent via the deterministic
`ClientRequestToken`, `athena_db.ex:102-105` — the real waste is the repeated portal query + S3
upload, plus requests hanging for minutes.)
**Suggested resolution**: make API self-start single-flight — claim the run first with an
atomic conditional write (`update_all` on `id == ^id and is_nil(athena_query_id) and
is_nil(athena_query_state)`, e.g. `set: [athena_query_state: "starting"]`; losers serve stored
state — exactly the existing start-failure behavior; reset on failure so the next poll
retries). A few lines in `ensure_current/1`.

#### RESOLVED: `touch_api_token` per-request UPDATE — adopt a freshness threshold or record acceptance
`DateTime.utc_now(:second)` dedupes writes within the same second (verified: `Repo.update` with
an empty changeset issues no SQL), but a 1s poll loop lands in a new second each time — steady
state is one MySQL row UPDATE per poll per active CLI, pure binlog churn for a value STORY 2
reads at "used recently" granularity. The verify query itself is fine (unique `token_hash`
point lookup).
**Suggested resolution**: one guard clause — skip the touch when `last_used_at` is within 60s
of now — or a sentence recording that per-second writes are accepted.

#### RESOLVED: `list_entries_paginated/1` has no code block, and the audit template dereferences `entry.user.*`
The admin-page step says the function "goes live against `Pagination`" but never shows it; the
template renders `entry.user.portal_first_name` etc. Ecto doesn't lazy-load — without
`preload: [:user]` the page crashes on `%Ecto.Association.NotLoaded{}`, and the naive per-row
fix is an N+1. The cheapest implementer guess compiles and crashes at runtime.
**Suggested resolution**: pin the one-liner in the step:
`from(e in DataAccessLogEntry, order_by: [desc: e.inserted_at], preload: [:user]) |> Pagination.paginate(page)`.

#### RESOLVED: `list_api_report_runs/3` preloads `:user` for no consumer
The list endpoint serves stored state only and `run_json/1` reads no user fields — every listed
run belongs to `current_user`, already loaded by `verify_api_token`'s preload. One wasted
SELECT per list request. (`get_api_report_run/2`'s preload IS load-bearing — `start_query`
passes `report_run.user` to `report.get_query` — keep that one.)
**Suggested resolution**: drop `preload: [:user]` from the list query only.

---

### DevOps Engineer

#### RESOLVED: No production migration mechanism exists — and this release makes *existing* web downloads hard-depend on a new table
The release start script only starts the app (`rel/overlays/bin/server`); there is no
`ReportServer.Release` migrator module, no `Ecto.Migrator` reference anywhere in `lib/`/`rel/`,
and the runner image has no `mix` (`Dockerfile:104`, `CMD ["/app/bin/server"]`). Deployment is
a manual CloudFormation ImageUrl update (`README.md:107-113`) with no migration step
documented. Round 1's "no deploy-ordering hazards — migrations precede app start as usual" is
ungrounded. The stakes are new: every existing web CSV/post-processing download now routes
through fail-closed `AuditLog.issue_download_url`, so deploying the image before the
`data_access_log` migration breaks the **primary existing export path**, not just the new API.
**Suggested resolution**: add a deployment note to the spec (apply the three migrations before
updating the stack image, and how) — or better, include the standard phx.gen.release
`ReportServer.Release.migrate/0` module in this story so the container can run
`bin/report_server eval "ReportServer.Release.migrate"`; ~20 lines, and it de-risks STORY 2/3
too.

#### RESOLVED: `data_access_log` FKs make audited runs and users permanently undeletable — an undocumented one-way door
`on_delete: :nothing` is RESTRICT on MySQL; with indefinite retention, any audited run pins its
`report_runs` and `users` rows forever. `Reports.delete_report_run/1` exists
(`reports.ex:137-139`, currently uncalled), and manual DB cleanup is plausible ops work that
will fail with FK errors. Arguably *desired* for audit integrity — but nobody decided it on the
record, and the row already denormalizes `report_slug`/`report_filter` precisely to be
self-contained.
**Suggested resolution**: one sentence making the choice explicit (audited rows pin their
run/user rows; deletion tooling must handle the audit table first) — or drop the FKs in favor
of plain ids given the denormalized snapshot.

#### RESOLVED: `filter_parameters` is mislabeled "compile-time", and substring matching will redact `page_token` in request logs
`Phoenix.Logger.filter_values/2` reads the config at call time via a default argument
(`deps/phoenix/lib/phoenix/logger.ex:158`) — the Round 1 "read at request time" claim is right,
but the auth-grants step's "compile-time Phoenix config" label invites wrong inferences
(`config.exs` placement works because releases bake it into `sys.config`, not because anything
is compiled). Separately, discard-mode matching is `String.contains?(k, params)`
(`logger.ex:167-172`), so `"token"` also redacts the harmless `page_token` query param —
worth knowing when grepping request logs to debug CLI pagination.
**Suggested resolution**: reword to "runtime-read config (baked into the release's
`sys.config`)" and add a one-line note about the `page_token` redaction side effect
(acceptable as-is).

---

### WCAG Accessibility Expert

#### RESOLVED: `bg-orange text-white` fails AA contrast (3.12:1) on all three new surfaces — breaching the spec's own AA requirement
`orange` is `#ea6d2f` (`tailwind.config.js:19`). Computed (and independently recomputed):
**white on #ea6d2f = 3.12:1** vs the 4.5:1 threshold for the 14px `text-sm` text used
everywhere here; the hover state (`#ea6d2f` on `light-orange #ffe6d0`) is **2.60:1**. Affected:
the pager's active page number, and the cli-token page's Generate and Copy buttons. The pattern
is copied from existing app styling, but the requirements explicitly promise WCAG AA contrast
for the *new* UI.
**Suggested resolution**: use a darker orange for text-on-orange in the new surfaces (e.g.
`#c14d10` ≈ 4.5:1 vs white) or invert the active-page style (orange border + dark text on
white); fix the hover pair the same way.

#### RESOLVED: Audit-table `text-zinc-500` dips below AA on the `bg-gray-100` header and hovered rows
Computed: zinc-500 `#71717a` on gray-100 `#f3f4f6` = **4.39:1** (header row, every page load);
on zinc-200 `#e4e4e7` (hovered row, slug span) = **3.81:1**; on white/gray-50 it passes.
Styles are copied from `report_runs/1` (`custom_components.ex`), so the run lists share the
defect, but this template is where the spec asserts AA.
**Suggested resolution**: `text-zinc-600` (`#52525b`: ≥7:1 on gray-100, ≥5:1 on zinc-200) for
the thead and slug span; optionally retrofit `report_runs/1` to match.

#### RESOLVED: `aria-disabled="true"` on a plain `<span>` is invalid ARIA
`aria-disabled` is not a global state — it isn't permitted on the `generic` role a bare span
has; validators flag it and screen readers ignore it, so the disabled semantics never reach AT
users anyway. (The zinc-400 contrast on these spans is exempt as an inactive component — not a
finding.)
**Suggested resolution**: drop the attribute (a non-focusable span reading "Previous" as plain
text is fine), or omit the boundary items entirely.

#### RESOLVED: Bare page-number link text and unlabeled Previous/Next give weak screen-reader context
A SR links list reads "1, 3, 4, 5, 20" with no page semantics; "Previous"/"Next" don't say
previous *what* outside the landmark. `aria-current="page"` helps only for the current page.
**Suggested resolution**: `aria-label={"Page #{item}"}` on number links and
`aria-label="Previous page"` / `"Next page"` on the endpoints (or `sr-only` suffixes — the
utility is already in the bundle).

#### RESOLVED: The copy-confirmation live region won't re-announce on repeat clicks
The hook sets the same `textContent` every click; several SR/browser pairs (VoiceOver/Safari
notably) deduplicate identical live-region content, so a second click — the "did it actually
copy?" click — produces silence, which reads as failure.
**Suggested resolution**: clear the region then set the message (e.g. `textContent = ""` then
set inside a short `setTimeout`) — one extra line in the hook.

#### RESOLVED: The label input's focus indicator is a 1.73:1 border-shade shift
The default `.input` clause applies `focus:ring-0` + `focus:border-zinc-400` over resting
`border-zinc-300` (`core_components.ex:338,358-360`) — the forms-plugin ring is explicitly
removed, leaving a zinc-300→zinc-400 border change whose computed contrast is **1.73:1**
(SC 2.4.7: near-invisible). Pre-existing generator styling, but this spec adds the first
user-facing text input on these new surfaces.
**Suggested resolution**: keep a visible ring on this input (drop `focus:ring-0` via a passed
class or add `focus:ring-2` with an accessible ring color).

---

## Self-Review — Round 4 (multi-role, code-verified)

Six roles (Senior Engineer, Security Engineer, QA Engineer, Performance Engineer, DevOps
Engineer, WCAG Accessibility Expert) re-reviewed the plan after the Round 3 changes. Every
candidate issue was deep-dived against the current codebase before being written up;
unconfirmed candidates were discarded. Dynamic verification ran as throwaway ExUnit tests
against the test env (app boots; the tests below did not need the DB), then deleted:
error-format negotiation for unrouted `/api` paths and malformed JSON bodies (with and without
an `Accept` header), `DateTime.to_iso8601/1` on a `NaiveDateTime`, and the failure mode of
`Aws.get_file_contents/1` on an unfetchable S3 URL.

**Candidates verified and cleared** (no finding): (a) the web-audit post-processing test's
JobServer boot does **not** crash on the un-stubbed S3 read — `ex_aws_s3`'s download stream
fetches the file size via an **eager** `head_object` + `request!` at stream construction
(`deps/ex_aws_s3/lib/ex_aws/s3/download.ex:26-57`), which is *inside* `get_file_stream`'s
rescue, so a missing/unreachable jobs file returns `{:error, "Unable to get stream"}` (verified
dynamically) and the JobServer just serves no jobs — the Round 3 message-seeding approach
stands. (This also refines the requirements' `Aws.get_file_contents/1` caveat: the *missing-file*
failure is caught by the rescue after all — only mid-stream chunk failures escape — but the
caveat's conclusion is unchanged: every failure collapses into one error tuple, so the API still
needs the new `fetch_file_contents/1`.) (b) `Plug.Test.init_test_session/2` reduces through
`put_session/3`, which stringifies keys (`deps/plug/lib/plug/test.ex:264-277`) — the planned
session-seeding test helpers work as written. (c) Re-verified as matching the plan:
`can_access_reports?/1`'s session-map shape, `Auth.get_portal_url/1` (takes a conn),
`PortalStrategy.get_authorize_url/1`, `PortalDbs.get_server_for_portal_url/1` (returns a host
string), `Output.get_jobs_url/1` (takes the `"<query_id>_jobs.json"` filename), the jobs-file
envelope (`{"version": 1, "jobs": [...]}` — `job_server.ex:170-173` — matches `parse_jobs`),
`Job`'s derived encoder fields and atom statuses (serialize to `"started"`/`"completed"`/
`"failed"`), the `DownloadButton` hook's nil-url failure alert and `data-job-id` → `jobId`
dataset plumbing, `ReportRun`/`User` schema `timestamps(type: :utc_datetime)`, the
`report_runs/1` `<th>` markup, and the run-list template's existing
`include_user={@user.portal_is_admin}` (the retrofit preserves it verbatim).

### Senior Engineer

#### RESOLVED: The exception-rendering fix only works when the client sends `Accept: application/json` — Go's default client doesn't
The Round 3 path-keyed `ErrorJSON` clause fires only if the **json format was negotiated** for
the request. For any failure that happens **before a route's `:accepts` plug runs**, Phoenix's
`RenderErrors` negotiates the format from the `Accept` header against
`render_errors[formats: [html: ..., json: ...]]` (html first — `config.exs:18-20`), and with no
`Accept` header it falls back to the **first** format
(`deps/phoenix/lib/phoenix/endpoint/render_errors.ex` `put_formats/2`). Two contract surfaces
hit this: (1) `Phoenix.Router.NoRouteError` — an unknown path under `/api/v1` never enters the
pipeline; (2) `Plug.Parsers.ParseError` — a malformed JSON body on `POST /auth/cli/token` is
raised at the endpoint, before routing. Go's `net/http` sends **no `Accept` header by
default**, so the STORY 4 CLI is exactly the affected client.
**Verified dynamically** (throwaway ExUnit, then deleted): `GET /api/v1/nonexistent` with no
`Accept` header → `404`, `content-type: text/html`, body `"Not Found"`; the same request with
`Accept: application/json` → `ErrorJSON` (which the plan's clause would rewrite into the
contract shape); malformed JSON `POST /auth/cli/token` with `content-type: application/json`
but no `Accept` → `400`, `content-type: text/html`, body `"Bad Request"`. Consequently the
pipeline step's own exception-fallback test bullets ("unknown path under `/api/v1` → contract
shape"; the auth-grants step's ParseError claim) **fail as written** unless the test conn sets
the `Accept` header.
**Suggested resolution**: (a) end the `/api/v1` scope with a catch-all route through a
json-only pipeline (`match :*, "/*path", <controller>, :not_found` piped through `:api` —
`plug :accepts, ["json"]` with no `Accept` header negotiates json, so the contract 404 renders
for header-less clients and `NoRouteError` never fires for `/api/v1/*`); (b) the pre-router
`ParseError` cannot be fixed by routing — document that the contract error shape for
malformed-body failures requires `Accept: application/json`, make sending that header a STORY 4
CLI obligation (one line in its contract notes), and set the header explicitly in the
exception-fallback tests.

**Resolution**: Approved — the pipeline step gained a `FallbackController` + an `:api`-piped
catch-all `/api/v1` scope (kept below every real route; the runs step's router snippet notes
the ordering obligation), the `ErrorJSON` section gained the scope caveat, the
exception-fallback test list now asserts the catch-all 404 with and without the `Accept`
header and the ParseError case with it, and the requirements Contract section gained a
**Clients must send `Accept: application/json`** bullet recording the STORY 4 obligation.

---

#### RESOLVED: `DataAccessLogEntry` schema timestamps type is not pinned — the audit page 500s if the schema omits `type: :utc_datetime`
The `data_access_log` step shows the migration (`timestamps(type: :utc_datetime,
updated_at: false)`) and the changeset, but describes the schema module only as "a
straightforward mirror of the table". Ecto **schema** `timestamps()` default to
`:naive_datetime` regardless of the migration's column type, and the app's
`generators: [timestamp_type: :utc_datetime]` (`config.exs:12`) affects only generators —
nothing generates this schema. An implementer writing `timestamps(updated_at: false)` in the
schema gets `NaiveDateTime` structs back, and the audit-page template calls
`DateTime.to_iso8601(entry.inserted_at)` — which **raises** on a `NaiveDateTime` (verified
dynamically: `MatchError`) — so the admin page crashes on first render with data. The plan's
`ApiToken` schema block already pins its type inline (and its `DateTime.diff` in
`touch_api_token/1` needs it for the same reason); `AuthGrant`'s "mirrors the table" has the
same gap but tolerates it (its datetimes only hit query params and casts).
**Suggested resolution**: pin the schema line in the `data_access_log` step —
`timestamps(type: :utc_datetime, updated_at: false)` — and add `type: :utc_datetime` to the
`AuthGrant` schema description for consistency.

**Resolution**: Approved — the `data_access_log` step's schema paragraph now pins
`timestamps(type: :utc_datetime, updated_at: false)` with the naive-default rationale, and the
auth-grants step's `AuthGrant` schema note now declares `:utc_datetime` for its timestamps and
datetime fields.

---

#### RESOLVED: The hooks file is `assets/js/app.ts` (TypeScript), not `app.js` — and the hook must be added inside the `Hooks` literal
The cli-token step's files-affected list says `assets/js/app.js` "(or the hooks module it
imports)", and the snippet uses post-hoc assignment (`Hooks.CopyToClipboard = {...}`). The
actual bundle entry is **`assets/js/app.ts`** (esbuild args, `config.exs:30`), where `Hooks` is
a `const` object literal (`app.ts:32`) containing the existing hooks. Post-hoc property
assignment on that literal is a TypeScript type error (esbuild transpiles without
type-checking, so it would still build — but it breaks any editor/CI typecheck); the idiomatic
edit is adding a `CopyToClipboard` key inside the literal.
**Suggested resolution**: correct the files-affected entry to `assets/js/app.ts` and reword the
snippet's framing to "add this entry inside the existing `const Hooks = {...}` literal" (hook
body unchanged).

**Resolution**: Approved — the cli-token step's files-affected entry now names
`assets/js/app.ts`, and the hook snippet is framed (and written) as a `CopyToClipboard:` entry
inside the existing `Hooks` literal.

---

### QA Engineer

#### RESOLVED: The Show smoke test's mount-start case stubs `:athena_db` but not `:report_tree` — the real `get_query` needs a portal DB, so the assertion fails
The AthenaRunOps step's Show smoke test reads: "a persisted Athena run with
`athena_query_id: nil` and a stubbed `:athena_db` returning `{:ok, "qid", "queued"}` → page
renders and the run row gains an `athena_query_id`". But mount-start runs
`AthenaRunOps.start_query/1` → `tree().find_report(...).get_query.(filter, user)`, and with no
`:report_tree` stub that is the **real** report implementation — verified for the suggested
steps-less slugs: `TeacherActionsReport.get_query/2` calls `get_usernames`/`get_activities`,
which query the **portal DB** (`teacher_actions_report.ex:8-9` → `PortalDbs.query`), and the
test env has no `<SERVER>_DB` var for the fixture's portal server — so `get_query` returns
`{:error, "Unknown server ..."}`, no query is started, no `athena_query_id` is persisted, and
the test's core assertion fails. (The poll-refresh case is unaffected — it only touches the
stubbed `get_query_info`. The API self-start test bullets already say "stubbed tree/athena"
correctly; only this smoke-test bullet is incomplete.)
**Suggested resolution**: add the `:report_tree` stub to the mount-start case (canned report
whose `get_query` returns a real `%ReportQuery{}`), keeping the run's real Athena
`report_slug` so Show's own (un-seamed) `Tree.find_report/1` in `handle_params` still resolves
the page's report struct.

**Resolution**: Approved — the smoke-test bullet now stubs both `:athena_db` and
`:report_tree` for the mount-start case (with the real-slug constraint stated), and notes that
the poll-refresh case needs only the `:athena_db` stub.

---

Roles run with no new findings this round: **Security Engineer** (independently re-verified the
Round 3 clearances: the conditional-`UPDATE` consume is a true compare-and-swap; `redirect_uri`
validation holds for userinfo tricks, default-port URIs, and query/fragment smuggling —
`URI.parse` yields host `"127.0.0.1"` and the redirect target stays loopback; `state` is
neutralized by `URI.encode_query`; `filter_parameters` substring matching covers
`code`/`code_challenge`/`code_verifier`/`token`/`access_token`), **Performance Engineer**
(`Tree.athena_report_slugs/0` walks the ETS-cached tree; the double call per show/download
request is trivial; `Pagination.paginate/3`'s COUNT-plus-page pair is fine at these sizes),
**DevOps Engineer** (the release-migrator step matches phx.gen.release; all three migrations
remain additive; `config.exs` placement of `filter_parameters` re-verified as runtime-read),
**WCAG Accessibility Expert** (the Round 3 markup resolutions are internally consistent —
pager labels/current-page semantics, `<time>` element, live-region clear-then-set, dark-orange
token — no regressions introduced by the Round 3 edits), and **Education Researcher** (all
three export surfaces route through `AuditLog.issue_download_url/6`; portal-report downloads
remain unlogged per the requirements' scope decision).


## External Review — Round 1

Findings from an external development review of `implementation.md` + `requirements.md`,
processed one at a time and re-verified against the code before processing.

#### RESOLVED: [MEDIUM] Concurrent self-start losers returned stale state
If two API requests loaded the same nil/nil run before the atomic claim, the loser got
`{0, _}` from `Repo.update_all` and returned its stale pre-claim struct, so show/download could
respond `athena_query_state: null` while the stored row was already `"queued"` — contradicting
the requirements' concurrent-polls-serve-stored-state clause, and contradicting the
`ensure_current/1` docstring itself, which justified `"queued"` as the claim value precisely so
"concurrent polls reading the claimed row serve a truthful state" (the losing branch never read
the claimed row).
**Resolution**: Approved — the `{0, _}` losing branch now returns
`%{report_run | athena_query_state: "queued"}`: a `{0, _}` means the row was no longer nil/nil
at claim time, so `"queued"` is a truthful lower bound, self-correcting on the next ~1s poll
(worst case: the winner already failed-and-released, and the loser reports `"queued"` for one
poll cycle before the next poll sees `null` and retries). Chosen over the reviewer's primary
suggestion (DB reload) as it costs no extra query and no preload bookkeeping while meeting the
same contract. The stale-struct unit test now asserts the loser's returned struct reflects
`"queued"`, not the pre-claim `nil`.

---

#### RESOLVED: [MEDIUM] Nil `report_filter` violated the stable API response contract
The serializer's `report_filter_json(nil), do: nil` emitted `report_filter: null`, but the
requirements contract pins `report_filter` as a JSON object with all fields always present
(no null-vs-object ambiguity). Verified real: the `ReportRun` changeset requires only
`user_id`/`report_slug` (`report_run.ex:26`), so nil-filter rows are schema-legal, and the API
list/show queries filter only by owner + Athena slug — such rows would be API-visible.
**Resolution**: Approved — nil filters now serialize as the empty filter
(`report_filter_json(nil)` delegates to `report_filter_json(%ReportFilter{})`); verified that
`%ReportFilter{}` defaults (`report_filter.ex:8-10`: `filters: []`, dimensions/dates nil,
booleans false) produce exactly the contract's all-fields-present shape, and "no stored filter"
is semantically the empty filter (no constraints). Chosen over migration/backfill/validation:
no data-migration risk, no change to the web form's create path, and it covers future
manually-inserted rows rather than only backfilling today's. Added a controller test (nil-filter
run → empty-filter object, never `null`) and a clarifying line to the requirements contract
bullet.

---

## External Review — Round 2

Findings from a second external development review of `implementation.md` + `requirements.md`,
processed one at a time and re-verified against the code before processing.

#### RESOLVED: [HIGH] `AuthGrant` schema did not pin the `:user` association
The auth-grants step described the schema only as "mirrors the table" (pinning timestamp
types), while `exchange_auth_grant/2` runs `preload: [:user]` and reads `auth_grant.user`.
Ecto does not infer associations from the migration FK, so a literal fields-only implementation
would crash the code exchange's **success** path.
**Resolution**: Approved — the `Accounts.AuthGrant` schema module is now pinned in full
(`belongs_to :user, User, foreign_key: :user_id`, `:utc_datetime` timestamps and datetime
fields, changeset with `unique_constraint(:code_hash)`), matching the explicit `ApiToken`
schema pattern.

---

#### RESOLVED: [HIGH] `DataAccessLogEntry` schema did not pin the load-bearing `:user` association
Same defect: the audit step described the schema as "a straightforward mirror of the table"
(pinning only `timestamps(type: :utc_datetime, updated_at: false)`), while the admin audit page
runs `preload: [:user]` and its template dereferences `entry.user.*` — the spec even calls that
preload "load-bearing" without declaring the association it needs. The audit-**write** path
would work while the audit page crashed.
**Resolution**: Approved — the `AuditLog.DataAccessLogEntry` schema module is now pinned in
full: all fields, `belongs_to :user`, `belongs_to :report_run` (the reviewer's optional
FK-symmetry suggestion, adopted so a future run preload can't repeat this finding), the
Round-4 timestamps pin, and the existing changeset folded into the module block.

---

#### RESOLVED: [MEDIUM] JSON error contract was overstated for explicit non-JSON `Accept` headers
The spec claimed routed API requests and unknown `/api/v1` paths return the contract shape
"regardless", but `plug :accepts, ["json"]` raises `Phoenix.NotAcceptableError` on an explicit
non-JSON `Accept` header **before** the auth plug or catch-all runs, and with the app's
`render_errors` listing html before json (`config.exs:18-21`), `Accept: text/html` produced an
HTML 406 instead of `{ "error": ... }`. Verified: the claim held for **missing** `Accept`
headers only.
**Resolution**: Approved — took the reviewer's force-JSON option over contract-narrowing: both
API pipelines replace `plug :accepts, ["json"]` with `plug :force_json`
(`put_format(conn, "json")` unconditionally), making `NotAcceptableError` impossible on
`/api/v1` and giving every post-pipeline raise the stored json format. Safe because the
existing `:api` pipeline is unused by any route today (verified in `router.ex`), and ignoring
`Accept` is standard for JSON-only APIs — the ad-hoc curl/browser user is exactly who the
one-error-shape guarantee serves. The requirements Contract bullet was rewritten ("the API
ignores `Accept` and always speaks JSON"), with the pre-router malformed-body `ParseError`
remaining the sole documented exception (the STORY 4 `Accept: application/json` CLI
obligation, now narrowed to that case). Tests added: `Accept: text/html` on the catch-all →
contract 404, and on a routed API path without a bearer token → contract 401.

---

## External Review — Round 3

Findings from a third external development review (Security Engineer, Senior Engineer, QA
Engineer roles; reviewed both spec files against the current server code), processed one at a
time and re-verified against the code — including dynamic verification of the `URI.parse`
claims — before processing.

#### RESOLVED: [HIGH] `/auth/cli/token` accepted query-string secrets despite the body-only contract
The token action pattern-matched its params argument, which is Phoenix's **merged**
`conn.params` (query params included), so `POST /auth/cli/token?code=...&code_verifier=...`
satisfied the exchange — putting the one-time code and verifier in access/proxy log URL lines,
which `filter_parameters` (Phoenix params logging only) cannot redact. The prose said "body
params only" but the code didn't enforce it.
**Resolution**: Approved — the action now reads `conn.body_params` exclusively and rejects any
request carrying `code` or `code_verifier` in `conn.query_params` **before** the exchange runs
(a query-string attempt does not consume the grant), rendering the endpoint's standard
indistinguishable 400. Tests added: valid pair via query-only → 400 with grant unconsumed
(subsequent body exchange succeeds); either secret in the query alongside a valid body → 400.

---

#### RESOLVED: [HIGH] Pagination snippets called `Pagination` without aliasing `ReportServer.Pagination`
Three snippets (`Reports` context, `ReportRunLive.Index`, `AuditLog` context) called
`Pagination.paginate/2` / `Pagination.normalize_page/1` bare, but none of those modules alias
`ReportServer.Pagination` (verified: `reports.ex` aliases only `Repo`/`User`/`ReportRun` plus
the spec-added `Tree`; `index.ex` only `Reports`; the spec's `AuditLog` block only
`Repo`/`DataAccessLogEntry`/`ReportRun`) — the calls would resolve to a non-existent top-level
`Pagination` module at runtime. The spec had already caught this exact trap once (the `Tree`
alias note); `AuditLogLive.Index` was unaffected (it aliases both).
**Resolution**: Approved — explicit `alias ReportServer.Pagination` gain-notes added at all
three snippets.

---

#### RESOLVED: [MEDIUM] Post-processing audit-write failure lacked the required LiveView error flash
The requirements' fail-closed bullet distinguishes presign failure ("the surface's normal
error path" — the preserved `%{url: nil}` reply is compliant) from audit-write failure
("server error (API: 500-class; LiveView: **error flash**), no URL returned"). The
post-processing handler collapsed both to `nil`, and its note wrongly claimed compliance.
**Resolution**: Approved — the handler's `{:error, :audit, _}` branch now sends
`{:put_flash, :error, msg}` to the parent (a LiveComponent's own `put_flash` never renders in
the parent layout — the mechanics the review's fix sketch glossed over) and `Show` gains the
matching `handle_info` clause; the flash copy matches the raw-CSV audit-failure branch, and
presign failure keeps the existing nil-reply path. Test coverage follows the established
convention: the audit branch is unit-covered in the `data_access_log` step (not
stub-forceable through the LiveView — see the forcing-mechanism note), and the flash plumbing
is covered by sending `Show` the message directly and asserting the flash renders.

---

#### RESOLVED: [MEDIUM] `redirect_uri` validation accepted non-literal or invalid loopback URIs
Dynamically verified against `URI.parse/1` with the spec's exact checks:
`http://evil@127.0.0.1:123/callback` passed (userinfo ignored), `:0` and `:99999` passed
(integer ports, invalid range), and `:-1` passed with the port **silently defaulting to 80**
while the raw `-1` string would have been stored and redirected to. This supersedes the
Self-Review Round 4 "userinfo tricks cleared" note — that round judged the redirect target
still-loopback (true), but the requirements pin the exact form `http://127.0.0.1:<port>/callback`.
**Resolution**: Approved — the validator now additionally requires `uri.userinfo == nil`,
`uri.port in 1..65535`, and `uri.authority == "127.0.0.1:#{uri.port}"` (one check that kills
both the userinfo and malformed-authority/port cases, and rejects portless URIs — the CLI
always binds an explicit ephemeral port). Entry-validation tests added for userinfo, `:0`,
`:-1`, `:99999`, and portless variants.

---

## External Review — Round 4

Finding from a fourth external development review (Security Engineer, Senior Engineer roles),
re-verified against the code before processing.

#### RESOLVED: [HIGH] `portal` validation accepted non-origin URLs and reused them raw as the OAuth site
`validate_portal/2` checked only the host-derived DB mapping and returned the **raw**
`portal_url`. Verified end to end in the live code: `PortalDbs.get_server_for_portal_url/1`
keys on `URI.parse(portal_url).host` alone (`portal_dbs.ex:83-89`), so
`ftp://learn.concord.org`, `https://learn.concord.org/evil`, and
`https://evil@learn.concord.org` all derive a valid server and pass the DB check — and
`PortalStrategy.client/1` uses the value verbatim as the OAuth `site`
(`portal_strategy.ex:10`), turning those inputs into broken or phishing-shaped external login
redirects after "passing" the entry validation whose purpose is to fail fast. Same bug class
as the Round 3 `redirect_uri` finding, on the other URL parameter of the same endpoint.
**Resolution**: Approved — `validate_portal/2` now normalizes before the DB check: `https`
only (verified safe — every configured portal URL in dev/staging/prod is https), no
userinfo/query/fragment, path `nil` or `/`, port in `1..65535` with the same
literal-authority check as `validate_redirect_uri` (catching `URI.parse`'s silent
port-defaulting on inputs like `:-1`), and the **rebuilt canonical origin**
(`https://host[:port]`, explicit `:443` and trailing `/` collapsed) — never the raw input —
is what flows into the DB check, the stored auth request / grant row, and
`get_authorize_url/1`. The requirements' Portal-selection bullet now pins the https-origin
shape and normalization. Scope note recorded in the flow notes: `Auth.Plug`'s raw `?portal=`
session stash (today's existing behavior for manual browser logins) is unchanged and out of
scope — entry validation 400s malformed values on the same request, and for
valid-but-non-canonical inputs the CLI flow's own stored state uses the normalized origin.
Tests added: entry-validation rejections for `ftp://`/`http://` schemes, userinfo, path,
query, fragment, and malformed port; plus a normalization positive test asserting the stored
request and grant carry the canonical origin.
