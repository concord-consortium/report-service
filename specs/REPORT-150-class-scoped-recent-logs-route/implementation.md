# Implementation Plan: The class-scoped recent-logs route

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-150
**Requirements Spec**: [requirements.md](requirements.md)
**Status**: **In Development**

Paths are under `server/` unless they start with `specs/`. Each step compiles with `mix compile --warnings-as-errors` and passes `mix test` on its own. Run the suite as `server/README.md` "Testing" says (placeholder secrets, `docker compose up`, never `source .env`); the controller and caller tests are `:portal_db` tests against the portal fixture.

**Pre-flight: done 2026-10-21 on Doug's go.** Both checks passed, and the plan needs no IAM step and no SQL change.
- **IAM.** Staging's `report-server` (user `report-server-staging`, v7) and production's `report-server-prod` (v7) each allow `glue:GetTable` on `*`, `athena:StartQueryExecution`, `GetQueryExecution`, `GetWorkGroup` and `CreateWorkGroup` on `*`, read on all of the environment's log bucket, and read and write on all of its report bucket, which holds `workgroup-output/`. Neither allows `athena:GetQueryResults` or `StopQueryExecution`, as the plan assumes. The README's two policy blocks omit these "PortedQueryCreator" statements, which is the drift REPORT-107 noted and this story leaves alone.
- **Athena syntax.** An `EXPLAIN` of the `:count` SQL on staging (`log_ingester_qa`, workgroup `primary`, engine 3, one made-up learner) succeeded with 0 bytes scanned. The plan reads only `run_remote_endpoint` and `timestamp`, folds the one-row `VALUES` join into a filter, and projects `dt` from `2026/10/19/23` to the current hour. The output prefix was deleted afterward.

## Implementation Plan

### A bounded wait for an Athena query

**Summary**: The route waits for its query inside a request (R13), so `AthenaQueryPoller.wait_for/1`'s five-second poll with no timeout is wrong for it. Add options; the existing caller keeps its behavior.

**Files affected**:
- `lib/report_server/athena_query_poller.ex`: `wait_for/2` with `:timeout_ms` (default `:infinity`) and `:interval_ms` (default 5,000).
- `test/report_server/athena_query_poller_test.exs`: two tests.

**Estimated diff size**: ~60 lines

```elixir
@poll_interval 5_000

def wait_for(query_id, opts \\ []) do
  interval = Keyword.get(opts, :interval_ms, @poll_interval)
  deadline =
    case Keyword.get(opts, :timeout_ms, :infinity) do
      :infinity -> :infinity
      ms -> System.monotonic_time(:millisecond) + ms
    end

  task = Task.async(fn -> poll_query_status(query_id, interval, deadline) end)
  Task.await(task, :infinity)
end

# in the queued/running clause:
{:ok, _status, _output_location, _reason} ->
  if deadline != :infinity and System.monotonic_time(:millisecond) + interval > deadline do
    {:error, :timeout}
  else
    :timer.sleep(interval)
    poll_query_status(query_id, interval, deadline)
  end
```

The deadline check comes before the sleep, so a 60-second budget never sleeps past it. The `IO.puts` in the `{:error, reason}` clause becomes `Logger.error`, in the function this step rewrites anyway, so a status-check failure on the request path reaches the log with its level (kept at stage 8 as part of the step's own change, not a separate requirement).

Tests (with `AthenaDBStub`, as the existing poller test does): a query that stays `"running"` with `timeout_ms: 50, interval_ms: 10` returns `{:error, :timeout}` within 200 ms; one that succeeds on the third poll with `interval_ms: 1` returns `{:ok, location}` (the existing default-path test stays as it is).

---

### A second concurrency limiter

**Summary**: R14 needs a server-wide cap separate from the Portal download cap. `PortalDownloadLimiter` is already a generic counting semaphore; give it a `:name` option and start a second instance.

**Files affected**:
- `lib/report_server/portal_download_limiter.ex`: `start_link/1` takes `:name` (default `__MODULE__`), and a `child_spec/1` whose `id` is the name.
- `lib/report_server/application.ex`: a child `{ReportServer.PortalDownloadLimiter, name: ReportServer.RecentLogsLimiter, cap: recent_logs_config(:max_concurrent)}`.
- `config/config.exs`: `config :report_server, :recent_logs, max_concurrent: 4, timeout_ms: 60_000, poll_interval_ms: 500, settle_ms: 600_000`.
- `config/runtime.exs`: `RECENT_LOGS_MAX_CONCURRENT` overrides `max_concurrent`, beside `PORTAL_DOWNLOAD_MAX_CONCURRENT`.
- `test/report_server/portal_download_limiter_test.exs` (new, or the existing limiter test if one exists): two named instances do not share slots.

**Estimated diff size**: ~50 lines

```elixir
def child_spec(opts) do
  name = Keyword.get(opts, :name, __MODULE__)
  %{id: name, start: {__MODULE__, :start_link, [opts]}}
end

def start_link(opts) do
  {name, opts} = Keyword.pop(opts, :name, __MODULE__)
  GenServer.start_link(__MODULE__, opts, name: name)
end
```

The module keeps its name: its moduledoc changes to say it is a counting semaphore started once per capped path (Portal downloads, recent logs). Renaming it would touch every Portal download caller for no behavior change.

---

### The audit event for a recent-logs read

**Summary**: R17. A run-less audit row: a migration, the changeset, the writer, and the audit page.

**Files affected**:
- `priv/repo/migrations/<timestamp>_allow_runless_data_access_log.exs` (new): the column-only change below. The foreign key stays as it is.
- `lib/report_server/audit_log/data_access_log_entry.ex`: `"recent_logs_read"` in the events, `"recent_logs"` in the data types; `report_run_id` required unless the event is `recent_logs_read`.
- `lib/report_server/audit_log.ex`: `log_recent_logs_read/4`.
- `test/support/audit_log_failing_stub.ex` (new): a module whose `log_recent_logs_read/4` answers `{:error, :stubbed}`, for the controller's fail-closed test.
- `lib/report_server_web/live/audit_log_live/index.html.heex`: a row without a run shows `class <id>` from `report_filter`.
- `test/report_server/audit_log_test.exs` and the audit page's LiveView test: new cases.

**Estimated diff size**: ~120 lines

```elixir
defmodule ReportServer.Repo.Migrations.AllowRunlessDataAccessLog do
  use Ecto.Migration

  def change do
    alter table(:data_access_log) do
      modify :report_run_id, :"bigint unsigned", null: true, from: {:"bigint unsigned", null: false}
    end
  end
end
```

Not `modify :report_run_id, references(...)`: on MySQL that emits `DROP FOREIGN KEY` and `ADD CONSTRAINT` under the same name in one `ALTER`, which fails with "Duplicate foreign key constraint name" (run in a throwaway test database in stage 7). The column-only form migrated, left `data_access_log_report_run_id_fkey` in place with the column `DEFAULT NULL`, and rolled back.

```elixir
# data_access_log_entry.ex
|> validate_required([:event, :source, :data_type, :user_id])
|> validate_run_unless_runless_event()

@runless_events ["recent_logs_read"]

defp validate_run_unless_runless_event(changeset) do
  if get_field(changeset, :event) in @runless_events,
    do: changeset,
    else: validate_required(changeset, [:report_run_id])
end
```

```elixir
# audit_log.ex
@doc """
One fail-closed row per recent-logs answer that carries rows, written before the first row is
sent. The class goes in `report_filter`, the read's lower bound in `cursor`, and the learners'
endpoints in `endpoint_set`, so the remote-endpoint filter finds the read.
"""
def log_recent_logs_read(_user = %{id: user_id}, class_id, since_ms, endpoints) do
  create_entry(%{
    event: "recent_logs_read",
    source: "api",
    data_type: "recent_logs",
    user_id: user_id,
    report_filter: %{"class" => [class_id]},
    cursor: Integer.to_string(since_ms),
    endpoint_set: endpoints
  })
end
```

```heex
<td class="p-2 font-normal border-b align-top">
  <%= if entry.report_run_id do %>
    <.link class="underline" href={"/reports/runs/#{entry.report_run_id}"}><%= entry.report_run_id %></.link>
    <span class="text-zinc-600"><%= entry.report_slug %></span>
  <% else %>
    <span class="text-zinc-600">class <%= Enum.join(entry.report_filter["class"] || [], ", ") %></span>
  <% end %>
</td>
```

Tests: the changeset accepts `recent_logs_read` without a run and still refuses `bulk_read` without one; `log_recent_logs_read/4` writes the four fields; `list_entries_paginated(1, %{remote_endpoint: ep})` finds the row; the audit page renders a run-less row with `class 601` and no link. The migration runs in the test database through the existing `mix test` alias.

---

### Window, cursor, SQL and rows

**Summary**: The pure core of R5 to R11: everything that can be pinned without a portal, Athena or a connection. One module and its tests.

**Files affected**:
- `lib/report_server/recent_logs.ex` (new).
- `test/report_server/recent_logs_test.exs` (new).

**Estimated diff size**: ~330 lines

```elixir
defmodule ReportServer.RecentLogs do
  @moduledoc """
  The class-scoped recent-logs read over `logs_by_hour` (server README, "Querying recent logs"):
  its window, its cursor, its SQL and the rows it answers. The window starts at 00:00 UTC of the
  day before the query's date; the day before that is the last one left to the nightly copy, so
  a `student-actions` run ending on it and these rows meet at `window_start`.
  """

  alias ReportServer.Reports.ReportQuery

  @columns ~w(id session application activity event event_value time parameters extras run_remote_endpoint timestamp user_id primary_user_id)
  @integer_columns ~w(time timestamp user_id primary_user_id)
  @cursor_version "v1"
  # 13 digits (year 2286): DateTime can still render the padded `dt` hour, and Athena's bigint holds it
  @max_ms 9_999_999_999_999

  def columns, do: @columns

  @doc "`window_start` in epoch ms and `nightly_through` as a Date, for a query made at `now_ms`."
  def window(now_ms) do
    today = now_ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_date()
    start = DateTime.new!(Date.add(today, -1), ~T[00:00:00], "Etc/UTC")
    %{window_start: DateTime.to_unix(start, :millisecond), nightly_through: Date.add(today, -2)}
  end

  @doc "The opaque cursor for a read submitted at `query_started_at` (ms): its `since` is that minus the settle margin."
  def next_cursor(class_id, query_started_at, settle_ms) do
    payload = Jason.encode!(%{"c" => class_id, "s" => query_started_at - settle_ms})
    @cursor_version <> "." <> Base.url_encode64(payload, padding: false)
  end

  @doc """
  The bounds a request reads, `{:ok, %{since: ms, until: ms | nil}}`, from its `cursor`, `start`
  and `end` parameters (R6, R9). Nothing reads before `window_start`.
  """
  def bounds(params, class_id, %{window_start: window_start}) do
    case {params["cursor"], params["start"], params["end"]} do
      {nil, start, finish} -> explicit_bounds(start, finish, window_start)
      {cursor, nil, nil} -> cursor_bounds(cursor, class_id, window_start)
      _ -> {:error, :cursor_with_bounds}
    end
  end

  defp explicit_bounds(start, finish, window_start) do
    with {:ok, since} <- bound(start, window_start),
         {:ok, until} <- bound(finish, nil),
         :ok <- inside_window(since, until, window_start) do
      {:ok, %{since: since, until: until}}
    end
  end

  defp bound(nil, default), do: {:ok, default}

  defp bound(value, _default) when is_binary(value) do
    case Integer.parse(value) do
      {ms, ""} when ms >= 0 and ms <= @max_ms -> {:ok, ms}
      _ -> {:error, :bad_bound}
    end
  end

  defp bound(_, _), do: {:error, :bad_bound}

  defp inside_window(since, until, window_start) do
    cond do
      since < window_start -> {:error, :out_of_window}
      until != nil and until < window_start -> {:error, :out_of_window}
      until != nil and until <= since -> {:error, :bad_bound}
      true -> :ok
    end
  end

  defp cursor_bounds(cursor, class_id, window_start) when is_binary(cursor) do
    with [@cursor_version, encoded] <- String.split(cursor, ".", parts: 2),
         {:ok, json} <- Base.url_decode64(encoded, padding: false),
         {:ok, %{"c" => ^class_id, "s" => since}} when is_integer(since) and since <= @max_ms <- Jason.decode(json) do
      if since < window_start, do: {:error, :expired_cursor}, else: {:ok, %{since: since, until: nil}}
    else
      _ -> {:error, :bad_cursor}
    end
  end

  defp cursor_bounds(_, _, _), do: {:error, :bad_cursor}

  @doc "The `dt` range for `since`..`until`: an hour of padding on each side (conventions 1 and 3)."
  def dt_predicate(%{since: since, until: until}) do
    lower = "log.dt >= '#{dt_hour(since, -3600)}'"
    if until, do: "#{lower} AND log.dt <= '#{dt_hour(until, 3600)}'", else: lower
  end

  defp dt_hour(ms, shift) do
    ms |> DateTime.from_unix!(:millisecond) |> DateTime.add(shift) |> Calendar.strftime("%Y/%m/%d/%H")
  end

  @doc """
  The Athena SQL for `learners` (maps with `run_remote_endpoint`, `user_id`, `primary_user_id`)
  within `bounds`. `:rows` selects the 13 columns ordered by `timestamp` then `id`; `:count`
  selects only `count` and `latest_timestamp`. The learners are an inline `VALUES` table rather
  than the uploaded `learners` table, so a read writes nothing to S3.
  """
  def sql(learners, bounds = %{since: since, until: until}, mode) when mode in [:rows, :count] and learners != [] do
    log_db = ReportQuery.get_log_db_name()
    until_predicate = if until, do: "\n  AND log.timestamp < #{until}", else: ""

    from = """
    FROM "#{log_db}"."logs_by_hour" log
    JOIN (VALUES #{Enum.map_join(learners, ", ", &learner_value/1)})
      AS learner (run_remote_endpoint, user_id, primary_user_id)
      ON learner.run_remote_endpoint = log.run_remote_endpoint
    WHERE #{dt_predicate(bounds)}
      AND log.timestamp >= #{since}#{until_predicate}
    """

    case mode do
      :rows ->
        cols = ReportQuery.get_log_cols(remove_username: true) ++ ReportQuery.get_minimal_learner_cols()
        "SELECT #{Enum.map_join(cols, ", ", fn {col, name} -> "#{col} AS #{name}" end)}\n#{from}ORDER BY log.timestamp, log.id"

      :count ->
        "SELECT count(*) AS count, max(log.timestamp) AS latest_timestamp\n#{from}"
    end
  end

  defp learner_value(%{run_remote_endpoint: ep, user_id: user_id, primary_user_id: primary}) do
    "('#{String.replace(ep, "'", "''")}', #{integer!(user_id)}, #{integer!(primary)})"
  end

  defp integer!(value) when is_integer(value), do: value

  @doc """
  One CSV row (a header-keyed map, as `CSV.decode(headers: true)` gives it) as the route answers
  it: an ordered object, so it encodes in the `student-actions` column order. A plain map of 13
  keys encodes in key order.
  """
  def row(csv_row) do
    Jason.OrderedObject.new(Enum.map(@columns, fn col -> {col, typed(col, Map.fetch!(csv_row, col))} end))
  end

  defp typed(_col, ""), do: nil
  defp typed(col, value) when col in @integer_columns, do: String.to_integer(value)
  defp typed(_col, value), do: value
end
```

Checked again at stage 8 after `start`/`end` were added (throwaway module, deleted): `bounds/3` gave every result its tests list, `dt_predicate/1` padded both ends, and the bounded `:rows` SQL in DuckDB kept a row one millisecond before `end` and dropped one at `end`. First checked by building this module as throwaway code (stage 5): `ReportQuery.get_log_cols/1` and `get_minimal_learner_cols/0` return `{expression, alias}` tuples (the first draft joined them as strings and raised), so the select renders `"log"."id" AS id` and so on, as `ReportQuery.get_sql/2` does, and Athena's CSV header is the bare alias. The generated `:rows` and `:count` SQL, with the database name unquoted, ran in DuckDB over a synthetic `logs_by_hour`: a row filed in the folder before its hour was kept, rows before `since` and rows of another learner were dropped, an endpoint holding `'` matched, and the count was 2 with the right `latest_timestamp`. Also checked: and the `csv` library decodes the S3 stream's arbitrary byte chunks, including a quoted field holding a newline, with an unquoted empty field and `""` both decoding to `""`.

Tests (`ReportServer.RecentLogsTest`, `async: false` because setup replaces the global `:athena` env, as `report_query_test.exs` says of its own; `Application.put_env(:report_server, :athena, log_db_name: "log_ingester_qa")` in setup and restored on exit):
- `window/1` for `2026-10-21T00:00:30Z`, `2026-10-21T23:59:59Z`, `2026-11-01T00:05:00Z` and `2026-01-01T00:00:00Z`: `window_start` is `1792454400000` for both October 21 times, `nightly_through` is `2026-10-19`, `2026-10-30` and `2025-12-30` respectively.
- `dt_predicate/1` for `since` = `window_start` on 2026-01-01 and no `until` is `log.dt >= '2025/12/30/23'`; with an `until` of 2026-01-01T05:30Z it adds `log.dt <= '2026/01/01/06'`.
- `bounds/3`: no parameters give `window_start` and no `until`; `start` and `end` inside the window are taken as given; `start` one millisecond before `window_start`, and `end` one millisecond before it with no `start`, are `:out_of_window`; `end` equal to `start`, `start=abc`, `start=-1` and `end=10000000000000` are `:bad_bound`; a cursor with `start` or `end` is `:cursor_with_bounds`; `next_cursor` round-trips for its class with no `until`; another class, a `v2.` prefix, bad base64, a non-integer `s` and an `s` of `10000000000000` are each `:bad_cursor`; a cursor one millisecond before `window_start` is `:expired_cursor`.
- `sql/3` `:rows` pinned with `normalized_sql/1` (copied from `report_query_test.exs`): the 13 columns in order, `"log_ingester_qa"."logs_by_hour"`, the `VALUES` join with two learners, `log.dt >= '2026/10/19/23'`, `log.timestamp >= 1792454400000`, no `log.timestamp <` and no `log.dt <=`, the `ORDER BY`; and the same with an `until`, adding both upper bounds; refute `"log"."time" >=`, `log.app`, `application` in the `WHERE`, and `"log"."username"`.
- `sql/3` `:count` pinned the same way; a learner endpoint holding `'` is doubled.
- `row/1`: integers parsed, `""` is `nil`, a `parameters` value with a newline survives, `Jason.encode!/1` of the row gives its keys in `columns/0` order, and a CSV with a missing column raises (`Map.fetch!`).

---

### Who is asking, and may they read this class

**Summary**: R2, R3, R4 and R16 as one module plus a plug, testable against the portal fixture without Athena.

**Files affected**:
- `lib/report_server/portal_dbs.ex`: `get_user_info_by_id/3`, the `get_user_info/2` query keyed by `users.id` (fresh role flags, login, names, email).
- `lib/report_server_web/api/class_reader_plug.ex` (new): accepts an API token or a `class:researcher-read` access token.
- `lib/report_server/recent_logs/access.ex` (new): `caller/2` and `learners/2`.
- `lib/report_server/accounts.ex`: `api_token_prefix/0`, returning `@api_token_prefix`.
- `test/support/portal_token_fixture.ex`: a third key, `:portal_fixture`, whose issuer is `https://portal-test.example.com/`, so an access token can name the fixture portal.
- `test/report_server_web/api/class_reader_plug_test.exs`, `test/report_server/recent_logs/access_test.exs` (new, `:portal_db`).

**Estimated diff size**: ~320 lines

```elixir
defmodule ReportServerWeb.Api.ClassReaderPlug do
  @moduledoc """
  Authenticates a class read by either credential that may make one: a report-server API token
  (cc-data, a dashboard VM), checked as `AuthPlug` checks it, or the portal's scoped access token
  carrying `class:researcher-read` (the dashboard page), checked as the catalog checks it. An API
  token is recognized by its prefix; anything else is tried as an access token.
  """
  alias ReportServer.Accounts
  alias ReportServerWeb.Api.{AuthPlug, PortalTokenPlug}

  @access_token PortalTokenPlug.init(capability: "class:researcher-read")
  @api_bearer "Bearer " <> Accounts.api_token_prefix()

  def init(opts), do: opts

  def call(conn, _opts) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      [@api_bearer <> _] -> AuthPlug.call(conn, [])
      _ -> PortalTokenPlug.call(conn, @access_token)
    end
  end
end
```

`Accounts` already owns the `ccd_` prefix (`@api_token_prefix`); the plug reads it through a new `Accounts.api_token_prefix/0` rather than repeating the literal.

```elixir
defmodule ReportServer.RecentLogs.Access do
  @moduledoc """
  The caller of a class read and the class's learners as that caller. An access-token caller is
  resolved to its report-server user row, created or refreshed from the portal's user row, so its
  Athena workgroup and audit rows are the ones its report runs use; its role flags are therefore
  read from the portal on every request.
  """
  alias ReportServer.{Accounts, PortalDbs}
  alias ReportServer.Reports.ReportFilter

  @portal_timeout_ms 5_000

  @doc "The `%User{}` asking, or `{:error, :forbidden | :not_authenticated | :portal_unavailable}`."
  def caller(%{assigns: %{current_user: user}}, _class_id), do: {:ok, user}

  def caller(%{assigns: %{portal_claims: claims}}, class_id) do
    with :ok <- context_names(claims["context"], class_id),
         server = PortalDbs.get_server_for_portal_url(claims["iss"]),
         true <- (is_binary(server) and PortalDbs.has_db_connection?(server)) || {:error, :not_authenticated},
         {:ok, info} <- user_info(server, claims["uid"]),
         {:ok, user} <- Accounts.find_or_create_user(info) do
      {:ok, user}
    end
  end

  defp context_names(%{"type" => "class", "id" => id}, id), do: :ok
  defp context_names(_, _), do: {:error, :forbidden}

  defp user_info(server, uid) when is_integer(uid) do
    case PortalDbs.get_user_info_by_id(server, uid, timeout: @portal_timeout_ms) do
      {:ok, info} -> {:ok, info}
      {:error, :not_found} -> {:error, :not_authenticated}
      _ -> {:error, :portal_unavailable}
    end
  end

  defp user_info(_, _), do: {:error, :not_authenticated}

  @doc """
  The class's learners as `user` sees them, or `{:error, :forbidden}` when the class is outside
  the caller's grants (whether or not it exists), `{:error, :portal_unavailable}` when the portal
  cannot be asked.
  """
  def learners(user, class_id) do
    filter = %ReportFilter{class: [class_id]}

    with {:ok, _values} <- ReportFilter.get_filter_values(filter, user),
         {:ok, groups} <- learner_data().fetch(filter, user, allow_empty: true) do
      {:ok, Enum.flat_map(groups, & &1.learners)}
    else
      {:error, :out_of_scope, _missing} -> {:error, :forbidden}
      {:error, _reason} -> {:error, :portal_unavailable}
    end
  end

  defp learner_data, do: Application.get_env(:report_server, :learner_data, ReportServer.Reports.Athena.LearnerData)
end
```

`LearnerData.fetch/3` with `allow_empty: true` answers `{:ok, []}` for a class with no learners (R4). The `:learner_data` seam is the one `EndpointSet` already reads, so `LearnerDataStub` works for the controller's error-path tests.

Plug tests (`async: false`, `install!/0`): an API token reaches the next plug with `:current_user`; a revoked one is 401; an access token with `class:researcher-read` and the catalog audience assigns `:portal_claims`; one with only `packages:read` is 401; an HS256 token and an assertion (`aud` a string) are 401; no header is 401.

Access tests (`:portal_db`, `PortalFixture.setup!/0`, fixture classes 2, 601, 603 and users 557 and 560; each expectation below was run against the fixture in stage 7): researcher 557 by API token reads one learner in class 601, `SECUREKEY123` with `user_id` 101 (the other learner's activity 802 is outside project 900), none in class 2 (in scope, no learners), and is `:forbidden` for 603 (no teacher, so no project) and for class 999999, with the same atom; site admin 560 reads two learners in 601 (the second with no secure key, whose endpoint ends in `/`, exactly as `student-actions` maps it) and none in 603; an access-token caller for 557 with `context` class 601 resolves to a user row with `portal_email` `rae@e.org` and `portal_is_project_researcher` true, a second call reuses the row, and a context naming 602 is `:forbidden` before any portal query; a `uid` the portal lacks is `:not_authenticated`.

---

### The route

**Summary**: R1, R6 to R15 and R17 to R18: the controller, the router scope, CORS, and the streamed answer.

**Files affected**:
- `lib/report_server_web/router.ex`: a pipeline and scope above the catch-all, and the catalog scope's comment ("and the only routes with CORS") no longer claims the catalog is alone.
- `lib/report_server_web/api/v1/recent_logs_controller.ex` (new).
- `lib/report_server_web/api/catalog_cors.ex`: the moduledoc and the refusal message stop saying "catalog" only.
- `test/report_server_web/api/v1/recent_logs_controller_test.exs` (new, `:portal_db`, `async: false`).

**Estimated diff size**: ~450 lines (about 200 of them tests)

```elixir
# router.ex
pipeline :api_class_read do
  plug :force_json
  plug ReportServerWeb.Api.CatalogCors
end

scope "/api/v1", ReportServerWeb.Api.V1 do
  pipe_through :api_class_read

  options "/classes/:class_id/recent-logs", RecentLogsController, :preflight
end

scope "/api/v1", ReportServerWeb.Api.V1 do
  pipe_through [:api_class_read, :api_class_reader]

  get "/classes/:class_id/recent-logs", RecentLogsController, :show
end
```

with `pipeline :api_class_reader do plug ReportServerWeb.Api.ClassReaderPlug end`. CORS runs before authentication, so a refused origin never reaches a token check, as on the catalog.

```elixir
defmodule ReportServerWeb.Api.V1.RecentLogsController do
  use ReportServerWeb, :controller

  require Logger

  alias ReportServer.{AuditLog, AthenaQueryPoller, PortalDownloadLimiter, RecentLogs}
  alias ReportServer.RecentLogs.Access
  alias ReportServerWeb.Api.ErrorHelpers

  def preflight(conn, _params), do: send_resp(conn, 204, "")

  def show(conn, params) do
    now = System.system_time(:millisecond)
    window = RecentLogs.window(now)
    count_only = params["count_only"] == "true"

    with {:ok, class_id} <- class_id(params["class_id"]),
         :ok <- no_cursor_with_count(count_only, params["cursor"]),
         {:ok, bounds} <- RecentLogs.bounds(params, class_id, window),
         {:ok, user} <- Access.caller(conn, class_id),
         {:ok, learners} <- Access.learners(user, class_id) do
      envelope = %{class_id: class_id, window_start: window.window_start,
                   nightly_through: Date.to_iso8601(window.nightly_through),
                   since: bounds.since, until: bounds.until}
      answer(conn, user, learners, bounds, envelope, count_only)
    else
      {:error, :bad_class} -> ErrorHelpers.bad_request(conn, "class_id must be a positive integer.")
      {:error, :cursor_with_count} -> ErrorHelpers.bad_request(conn, "count_only takes no cursor.")
      {:error, :cursor_with_bounds} -> ErrorHelpers.bad_request(conn, "A cursor cannot be combined with start or end.")
      {:error, :bad_bound} -> ErrorHelpers.bad_request(conn, "start and end must be epoch milliseconds, with end after start.")
      {:error, :out_of_window} -> ErrorHelpers.bad_request(conn, "start and end must be at or after #{window.window_start} (00:00 UTC yesterday); read earlier days with a Student Actions run.")
      {:error, :bad_cursor} -> ErrorHelpers.bad_request(conn, "The cursor is not valid for this class.")
      {:error, :expired_cursor} -> ErrorHelpers.render_error(conn, "EXPIRED_CURSOR", "The cursor is older than the recent window; start again without one.")
      {:error, :forbidden} -> ErrorHelpers.render_error(conn, "FORBIDDEN", "You may not read this class's logs.")
      {:error, :not_authenticated} -> ErrorHelpers.not_authenticated(conn)
      {:error, :portal_unavailable} -> ErrorHelpers.service_unavailable(conn, "The portal could not be asked; retry shortly.")
    end
  end
end
```

`answer/6`:
1. No learners: 200 with `count` 0, `latest_timestamp` `null`, `rows` `[]`, `query_started_at` `now` and (rows mode, no `until`) `next_cursor` from `now`. No Athena query and no audit row.
2. `PortalDownloadLimiter.try_acquire(ReportServer.RecentLogsLimiter)`; `:full` is 503 "Too many recent-log reads; retry shortly." Released in an `after`, as `portal_download/4` does.
3. `query_started_at = System.system_time(:millisecond)`, then `athena_db().query(RecentLogs.sql(learners, bounds, mode), UUID.uuid4(), user)`; a `query_too_large_error()` is 422 `UNPROCESSABLE` (R13, a class over roughly 2,100 learners), any other error 503.
4. `AthenaQueryPoller.wait_for(id, timeout_ms: cfg(:timeout_ms), interval_ms: cfg(:poll_interval_ms))`; `{:error, :timeout}` and failures are 503 with the query id logged.
5. `aws_file_store().get_file_stream(location)` (the `:aws_file_store` seam, defaulting to `ReportServerWeb.Aws`); an error is 503.
6. Count mode: decode the one row, answer `count`, `latest_timestamp` (`null` when `count` is 0), `query_started_at` and the envelope, with no `rows` and no `next_cursor`.
7. Rows mode: `audit_log().log_recent_logs_read(user, class_id, bounds.since, Enum.map(learners, & &1.run_remote_endpoint))`; `{:error, _}` is 500 with no rows. Then `send_chunked(conn, 200)` with `content-type: application/json`, one chunk with the envelope's opening (`{"class_id":…,"window_start":…,"nightly_through":…,"since":…,"until":…,"query_started_at":…,"rows":[`), the decoded rows in chunks of 500 (`Jason.encode!/1` each, comma-joined), tracking the count and the largest `timestamp`, and a closing chunk `],"count":N,"latest_timestamp":T,"next_cursor":"…"}` (`next_cursor` `null` when the request had an `end`). A decode raise after the first chunk is logged and re-raised; an S3 read failure arrives instead as an exit from ExAws's linked `Task.async_stream` task, which kills the request process past any `rescue` or `after` (the task's crash report is the log line, and the limiter's monitor frees the slot). Either way Bandit closes the connection without the terminating chunk and the JSON is incomplete (R12).

`class_id/1` accepts only `~r/^[1-9][0-9]{0,17}$/`, the catalog's id grammar.

Controller tests (`:portal_db`; `AthenaDBStub` and `AwsFileStoreStub` installed through `:athena_db` and `:aws_file_store`; `:recent_logs` set to the configured list with `timeout_ms: 100, poll_interval_ms: 5` merged in (`Keyword.merge/2`, since `put_env` replaces the whole list and `settle_ms` would go) and restored on exit; `:athena` set to `log_db_name: "log_ingester_qa"` and restored on exit, since the test env has no `:athena` and `ReportQuery.get_log_db_name/0` raises without it):
- Researcher 557's API token for class 601: 200; `rows` decoded from a stubbed three-row CSV (one with a newline in `parameters`, one with an empty `extras`) with integer `time`/`timestamp`/`user_id`; `count` 3; `latest_timestamp` the largest; `next_cursor` decodes to `query_started_at - 600000`; the SQL the stub received names `logs_by_hour` and the one endpoint the fixture gives 557 (`SECUREKEY123`); one `recent_logs_read` audit row with class 601 and that endpoint. Site admin 560's token for 601: the SQL and the audit row name both endpoints.
- The same with `count_only=true`: a `:count` SQL, `count` and `latest_timestamp` from the stubbed one-row CSV, no `rows`, no `next_cursor`, no audit row.
- A cursor from the first answer: the stub receives `log.timestamp >= <since>` and no upper bound.
- `start` and `end` an hour apart inside the window: the stub receives both `timestamp` bounds and both `dt` bounds, and the answer has `until` set and `next_cursor` `null`; `start` before `window_start` is 400 naming it; a cursor with `start` is 400; `count_only` with `start` and `end` passes both to the `:count` SQL.
- 400 for `class_id=0`, `abc` and a cursor with `count_only`; 400 for a cursor for class 602; 410 for an expired cursor (built with `next_cursor/3` from a time two days back).
- 403 for class 603 and for a nonexistent class, with the same body; 403 for an access token whose context is class 602 asking for 601; 401 with no token.
- An access token for 557 (the `:portal_fixture` key, `class:researcher-read`, context 601) from the allowlisted origin: 200 with `access-control-allow-origin` echoed; the same from another origin: 403 before any lookup; the preflight from the allowlisted origin: 204 with `authorization` allowed.
- Class with no learners (a fixture class with a teacher in project 900 and no learners: class 2): 200, `count` 0, and the Athena stub's `query` raises if called.
- 503 when the stub's `get_query_info` stays `"running"` past the timeout, when it answers `"failed"`, and when the limiter is full: the test starts as many processes as the configured cap, each taking a slot with `PortalDownloadLimiter.try_acquire(ReportServer.RecentLogsLimiter)` and blocking on a message, makes the request, then releases them; a slot freed by a dead holder is the limiter's own monitor test, already covered.
- 500 and no rows when the audit write fails: the controller reads its audit module through `Application.get_env(:report_server, :audit_log, ReportServer.AuditLog)`, and the test sets `ReportServer.AuditLogFailingStub`. (No existing controller test forces an insert failure; `audit_log_test.exs` does it with an invalid changeset, and DDL inside the sandbox would commit implicitly on MySQL.)
- 422 when the stub's `query` answers `query_too_large_error()`.
- 503 when the portal cannot be asked (R3): `:learner_data` set to `LearnerDataStub` with `fetch` answering `{:error, "connection refused"}`, for researcher 557 and class 601.

---

### Documentation

**Summary**: R19, and the prose the route makes untrue.

**Files affected**:
- `server/README.md`: a "Recent logs for a class" subsection after "The package catalog", and the catalog paragraph's "These three reads are the only routes with CORS" made true again ("These three reads and the recent-logs route are the only routes with CORS"); "Querying recent logs" gains one sentence pointing at the route as the code that follows its conventions. The environment block's `PACKAGES_CORS_ORIGINS` comment ("origins that may read the catalog with an access token") and the `PORTAL_PUBLIC_KEYS` paragraph (access tokens "on the package catalog's reads") also name the route.
- `lib/report_server_web/api/catalog_cors.ex`: moduledoc (done in the previous step; listed here so the grep below finds nothing stale).

**Estimated diff size**: ~70 lines

The subsection covers: the URL and both credentials (with the `class:researcher-read` capability and the `context` match); the 403 that does not reveal existence; the window (`window_start`, `nightly_through`, 24 to 48 hours), the seam with a `student-actions` run ending on `nightly_through` and the application filter a combining caller applies; its assumption that the partitioner's run for that day succeeded, and rerunning it if not; `start` and `end` and their limit to the window; the cursor (opaque, ten-minute overlap, dedup by `id`, 400 and 410); the resume rule (a caller sets `start` from its last `query_started_at` minus ten minutes, or keeps the cursor, never the largest `timestamp` it holds); `count_only`; the 13 columns and their types, `null` for an empty value; streaming and an incomplete body on a mid-stream failure; 400, 401, 403, 410, 422, 500 (audit write failed) and 503; `RECENT_LOGS_MAX_CONCURRENT`; and the `recent_logs_read` audit event.

Before committing: `grep -rn "only routes with CORS\|catalog's read routes, and only those\|read the catalog with an access token\|on the package catalog's reads" server/` returns only the corrected lines.

## Release notes for the implementer

- The migration in the audit step must run before the image serves traffic (README "Deploying", step 3); the release that carries this has one.
- Rolling back the image needs no migration rollback: the previous image writes the nullable column as before, and its audit page shows a run-less row with an empty run link. Do not roll the migration back once a `recent_logs_read` row exists: restoring `NOT NULL` fails with MySQL 1138 ("Invalid use of NULL value").
- No IAM change is expected (requirements R15), subject to the pre-flight above.
- `PACKAGES_CORS_ORIGINS` must include the dashboard's origin on each stack, as it already must for the catalog.
- R21's staging check runs on Doug's go after the staging release, with the dashboard's access token for a class with that day's activity.

## Open Questions

### RESOLVED: Judgment call: inline learners instead of the uploaded `learners` table
**Options considered**: `LearnerData.fetch_and_upload/2` and the `"report-service"."learners"` join `student-actions` uses; an inline `VALUES` table in the SQL.
**Decision**: inline. A polling page would otherwise write a learners file to S3 on every request, and the query would depend on the Glue `learners` table as well as `logs_by_hour`. The cost is the 262,144-byte query limit: about 123 bytes per learner (a production endpoint with a UUID secure key, measured in stage 8), so roughly 2,100 learners (students times assignments) per class, against tens to a few hundred in real classes; above it the route answers 422 (R13).

### RESOLVED: Judgment call: reuse `PortalDownloadLimiter` with a name rather than a new module
**Options considered**: a new `RecentLogsLimiter` module duplicating the semaphore; renaming the module to a generic name; a `:name` option on the existing one.
**Decision**: the `:name` option. One semaphore implementation (one source of truth), no rename churn in the Portal download path, and the moduledoc says what each instance caps.

### RESOLVED: Judgment call: decide the credential by the `ccd_` prefix
**Options considered**: try the API token, then the access token, for every bearer; branch on the prefix.
**Decision**: the prefix. Every report-server API token starts with it (`Accounts`, `@api_token_prefix`) and no JWT can (a JWT starts with its base64url header, `eyJ`), so the branch is exact and a bad token is checked once.

### RESOLVED: Low confidence: Trino's `VALUES` alias syntax on Athena (checked: accepted)
**Context**: `JOIN (VALUES (...), ...) AS learner (run_remote_endpoint, user_id, primary_user_id) ON ...` is standard Trino and ran in DuckDB (stage 5), but no Athena query has been run with it while speccing (Athena queries wait on Doug's go). If Athena rejects the alias form, the fallback is a `WITH learner (run_remote_endpoint, user_id, primary_user_id) AS (VALUES ...)` clause, which REPORT-107's note says Athena does not materialize but which is referenced once here.
**Options considered**:
- A) Run one `EXPLAIN` of the `:count` SQL for a staging class on Doug's go before the controller step.
- B) Find out at R21's staging check.

**Decision**: A, folded into the pre-flight at the top of this plan: one `EXPLAIN` of the `:count` SQL for a staging class (no bytes scanned), on Doug's go like every Athena call from this work. A rejection switches `sql/3` to the `WITH` form before the controller step, rather than at the staging release.

## Self-Review

Roles: commit reviewer (does each step compile and pass alone), test writer (can each named test be written against the harness the plan provides), operator (deploy and rollback), Security Engineer, Senior Engineer (Elixir, Ecto on MySQL). Each finding was checked by running code in stage 7 before it was written; each had one defensible correction and is fixed in place.

### Operator

#### RESOLVED: The audit migration failed on MySQL
`modify ... references(...), from: references(...)` generated `DROP FOREIGN KEY` plus `ADD CONSTRAINT` with the same name in one `ALTER`, and MySQL refused it ("Duplicate foreign key constraint name"). Run with `MIX_TEST_PARTITION=r150probe` so the shared test database was not touched. The step now uses a column-only `modify`, which migrated, kept the foreign key, and rolled back; the probe database was dropped afterward.

### Test writer

#### RESOLVED: The fixture gives researcher 557 one learner in class 601, not two
Run against the portal fixture: `LearnerData.fetch/3` for 557 and class 601 returns only `SECUREKEY123`, because the learner query also requires the assignment to be in an allowed cohort or project materials (`report_utils.ex`, `scope_by_allowed_projects/5`) and activity 802 is in neither. The site admin gets both. Class 2 is in scope with no learners, and 603 and 999999 are both out of scope for the researcher (999999 also for the admin). The access tests now state what the fixture returns.

#### RESOLVED: The audit-failure test could not be written as planned
Renaming the table inside the SQL sandbox is DDL, which MySQL commits implicitly, and no controller test forces an audit insert failure. The controller now reads its audit module through a config seam, as it reads `:athena_db` and `:aws_file_store`, and the test sets a failing stub.

#### RESOLVED: The full-limiter test restarted a supervised named process
Restarting `ReportServer.RecentLogsLimiter` with cap 0 inside a test fights the application supervisor. The test now fills the configured cap from helper processes, which needs no restart.

### Commit reviewer

#### RESOLVED: `Accounts.api_token_prefix/0` had no step
The plug calls it, but no step's file list added it. It is now in the step that adds the plug, so that step compiles alone.

### Round 3 (2026-10-21)

Roles: Security Engineer, Senior Engineer (Elixir, Phoenix, Ecto on MySQL), QA and test writer, commit reviewer, operator, API consumer (REPORT-152, RD-12). Each finding was checked against the code or by throwaway tests (deleted, with the `r150review` test database dropped).

#### RESOLVED: Security Engineer: an oversized `start`, `end` or cursor `s` crashed the route
`bound/2` and the cursor accepted any non-negative integer, and `dt_hour/2` raised `ArgumentError` ("invalid Unix time") for `end=99999999999999999999`, `start=300000000000000` and a forged cursor with that `s` (run in a throwaway test): a 500, not R6's 400. `bound/2` and the cursor now refuse values above 13 digits (`@max_ms`), with tests.

#### RESOLVED: Senior Engineer: `end` before `window_start` answered the wrong 400
With no `start`, `since` is `window_start`, so such an `end` fell to `until <= since` and answered `:bad_bound` (run in a throwaway test), whose message does not name `window_start` as R6 requires. `inside_window/3` now answers `:out_of_window` for it first, the message names both bounds, and there is a test.

#### RESOLVED: Senior Engineer: the plug repeated the `ccd_` literal its prose said it read from `Accounts`
The snippet matched `"Bearer ccd_" <> _`. It now builds `@api_bearer` from `Accounts.api_token_prefix/0` and matches `@api_bearer <> _` (a module attribute in a binary pattern compiled and matched in a throwaway test).

#### RESOLVED: API consumer: the streamed envelope dropped `until`, and count mode dropped `query_started_at`
R11 lists both, and the start/end controller test reads `until`, but `answer/6` step 7's opening chunk omitted `until` and step 6 never added `query_started_at` to the envelope built in `show/2`. Both steps now name them.

#### RESOLVED: Test writer: the controller test expected two endpoints for researcher 557
Rerun against the fixture: `LearnerData.fetch/3` gives 557 one learner in class 601 (`SECUREKEY123`) and site admin 560 two, as the access tests already say. The controller test now expects one endpoint for 557 and adds 560 for both.

#### RESOLVED: Test writer: `RecentLogsTest` was async while replacing the global `:athena` env
`report_query_test.exs` is `async: false` for exactly this reason, and `learner_hide_names_test.exs` and others read `:athena` concurrently. The test is now `async: false`.

#### RESOLVED: Test writer: the controller tests had no `:athena` env
The test env configures no `:athena` (`config/runtime.exs` sets it under `:prod` only), and `ReportQuery.get_log_db_name/0` raised `FunctionClauseError` without it (run under `MIX_ENV=test`), so every rows test would be a 500. The setup now sets it.

#### RESOLVED: Commit reviewer: three lines of prose the route invalidates were not in any step
`router.ex`'s catalog comment ("the only routes with CORS"), the README's `PACKAGES_CORS_ORIGINS` comment and its `PORTAL_PUBLIC_KEYS` paragraph each describe the catalog as the only user. The route and documentation steps now update them, and the grep covers the last two.

#### RESOLVED: Operator: step 7 named Cowboy
The server runs Bandit (`Bandit.PhoenixAdapter`). A throwaway Bandit plug that raised after its first chunk sent the headers and that chunk, then closed with no terminating chunk, so R12's truncated body holds; the text now names Bandit.


### Round 4 (2026-10-21)

Roles: Senior Engineer (Elixir, Phoenix, Ecto on MySQL), QA and test writer, commit reviewer, operator, API consumer (REPORT-152, RD-12), Security Engineer. Each finding was checked against the code or by throwaway tests (deleted, with the `r150review4` test database dropped).

#### RESOLVED: API consumer: rows encoded in alphabetical key order, not R5's column order
`row/1` built a plain map, and `Jason.encode!/1` of a 13-key map emits `activity, application, event, ...` (throwaway test), against R5's `student-actions` order. `row/1` now returns a `Jason.OrderedObject` (Jason 1.4.1; it implements `Access`, so the other `row/1` tests read it as before), with a test on the encoded key order.

#### RESOLVED: Senior Engineer: step 7 said an S3 failure mid-stream is rescued and re-raised
`Aws.get_file_stream/1` is `ExAws.stream!` over `Task.async_stream` (`ex_aws_s3` `download.ex`), and a raise in a chunk task killed the consuming process with neither its `rescue` nor its `after` running (throwaway test). Step 7 now says so: the task's crash report is the log line and the limiter's monitor frees the slot; R12's truncated body is unchanged.

#### RESOLVED: Test writer: R3's 503 had no test
R20 asks for each R3 refusal, and the plan said `LearnerDataStub` serves the controller's error-path tests, but no listed test used it. A controller test now stubs `fetch` with a portal error and expects 503.

#### RESOLVED: Test writer: the controller setup dropped `settle_ms`
`Application.put_env/3` replaces the whole `:recent_logs` list, so a setup naming only `timeout_ms` and `poll_interval_ms` leaves `next_cursor` without `settle_ms` and every rows test fails. The setup now merges into the configured list.

#### RESOLVED: Commit reviewer: the README coverage list lagged R19
R19 asks for `start` and `end` and their window limit, and the resume rule (last `query_started_at` minus ten minutes, never the largest `timestamp`); the documentation step's list had neither, and its error codes omitted 400 and 500. All are now in the list.

#### RESOLVED: Operator: the migration cannot be rolled back once used
Run in a throwaway database: after one run-less `data_access_log` row, `mix ecto.rollback` of the column-only migration failed with MySQL 1138 ("Invalid use of NULL value"). The previous image's audit template renders a `nil` run as an empty link, so an image rollback needs no migration rollback; the release notes now say both.
