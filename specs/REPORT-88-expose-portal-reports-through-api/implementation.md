# Implementation Plan: Expose Portal reports through the report-service API

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-88
**Requirements Spec**: [requirements.md](requirements.md)
**Status**: **In Development**

## Orientation

All paths are relative to `server/`. The work has two independent halves that share only the widened gate:

1. **Read-surface widening** (small, low-risk): gate helper, listing/show, `execution` field, `ensure_current` guard, the `derives_learner_data` bulk capability check, and the job-endpoint regression lock. These are ordinary Ecto/JSON/controller edits.
2. **Portal `/download` streaming** (net-new): a swappable streaming seam on `PortalDbs`, a shared CSV encoder, a per-node concurrency cap, a fail-closed audit row, and the polymorphic download branch that ties them together with a wall-clock deadline and pre-first-byte/mid-stream error classification.

The streaming mechanics below are pinned by throwaway probes run against a live MySQL 8.0 (the dev DB on port 3406) and a live Bandit endpoint, including a full end-to-end harness that stood up the encoder, streaming seam, limiter, and reducer/classification as real modules and drove every download scenario with curl (see Self-Review "Load-bearing verification"). Their outcomes are recorded in requirements Self-Review Round 6 and are cited inline where they justify a design choice. The probes live in the session scratch dir, not the repo.

Steps are ordered so no step depends on a later one, and so that **the gate is widened last** (the "Open the API gate to Portal runs" step): all Portal-handling paths land first, then a single small commit flips the two gate `where` clauses to expose them, so no intermediate commit ever serves a half-handled Portal run. Each step is an independently reviewable commit.

---

## Add 422 and 503 to ErrorHelpers

**Summary**: Introduce the two new status codes the rest of the work needs, `422 UNPROCESSABLE` for the bulk capability check and `503 SERVICE_UNAVAILABLE` for the download concurrency cap, plus their convenience helpers. Isolated and dependency-free, so it lands first.

**Files affected**:
- `lib/report_server_web/api/error_helpers.ex` — two `@statuses` rows, two helper functions.

**Estimated diff size**: ~8 lines.

Before (`error_helpers.ex:5-12`):
```elixir
  @statuses %{
    "BAD_REQUEST" => 400,
    "NOT_AUTHENTICATED" => 401,
    "NOT_FOUND" => 404,
    "NOT_READY" => 409,
    "EXPIRED_CURSOR" => 410,
    "SERVER_ERROR" => 500
  }
```

After:
```elixir
  @statuses %{
    "BAD_REQUEST" => 400,
    "NOT_AUTHENTICATED" => 401,
    "NOT_FOUND" => 404,
    "NOT_READY" => 409,
    "EXPIRED_CURSOR" => 410,
    "UNPROCESSABLE" => 422,
    "SERVER_ERROR" => 500,
    "SERVICE_UNAVAILABLE" => 503
  }
```

Add helpers alongside the existing ones (`error_helpers.ex:29-32`):
```elixir
  def unprocessable(conn, message), do: render_error(conn, "UNPROCESSABLE", message)
  def service_unavailable(conn, message), do: render_error(conn, "SERVICE_UNAVAILABLE", message)
```

`@codes_by_status` and `code_for_status/1` derive from `@statuses` automatically, so `ErrorJSON` renders a raised 422/503 in the same envelope shape with no further change.

---

## Gate helper: `Tree.api_report_slugs/0` (tbd-aware across the parent chain)

**Summary**: Add the gate helper that admits every non-`tbd` Athena-or-Portal report, honoring `tbd` at both the leaf (`Report.tbd`) and group (`ReportGroup.tbd`) level (R4-5). This step only *adds* the helper; it is unused until the final activation step ("Open the API gate to Portal runs"). Deferring the actual gate flip to the end is deliberate (P3-1): widening the gate before the Portal-handling machinery exists would give broken intermediate commits (a Portal `show` would trip `ensure_current`'s Athena self-start; a Portal `download` would return a misleading `409 NOT_READY`; Portal bulk would do the over-broad pull/500).

**Files affected**:
- `lib/report_server/reports/tree.ex` — new `api_report_slugs/0`; new `collect_api_reports/1` that stops at a `tbd` group.

**Estimated diff size**: ~20 lines.

`collect_reports/1` (`tree.ex:75-76`) recurses into groups unconditionally and never consults `ReportGroup.tbd`, so a new helper must prune `tbd` groups itself (R4-5). Add to `tree.ex` next to `athena_report_slugs/0`:

```elixir
  @doc """
  Slugs of every report exposed through the v1 API: non-`tbd` reports whose module type is
  :athena or :portal. Honors `tbd` at both the leaf (`Report.tbd`) and the group
  (`ReportGroup.tbd`) level — a `tbd` group is pruned with all its descendants, because
  group-level `tbd` is only a decorative web-UI badge and does not otherwise gate exposure.
  """
  def api_report_slugs() do
    root()
    |> collect_api_reports()
    |> Enum.filter(&(&1.type in [:athena, :portal]))
    |> Enum.map(& &1.slug)
  end

  # like collect_reports/1 but prunes any tbd group (and its subtree) and any tbd report
  defp collect_api_reports(%Report{tbd: true}), do: []
  defp collect_api_reports(report = %Report{}), do: [report]
  defp collect_api_reports(%ReportGroup{tbd: true}), do: []
  defp collect_api_reports(%ReportGroup{children: children}), do: Enum.flat_map(children, &collect_api_reports/1)
```

`athena_report_slugs/0` is left in place (other callers may rely on it; the gate no longer uses it once flipped). The two `reports.ex` `where: r.report_slug in ^Tree.athena_report_slugs()` clauses (`reports.ex:74,95`) and their stale "Athena-type" docstrings are **not** touched here, they flip to `api_report_slugs()` in the final activation step ("Open the API gate to Portal runs"), so the gate opens only once all Portal handling is in place.

The `preload: [:user]` already present at `reports.ex:96` is what makes `report_run.user.portal_server` available to the Portal download path later, no change needed.

---

## Add the `execution` field to run JSON; document `report_type` nullable

**Summary**: Every run's JSON gains `execution: "async" | "sync"` sourced from the report module `type`, and the now-reachable `report_type: null` path for Portal runs is documented (the comment at `report_json.ex:56-57` currently claims it is unreachable). Clients branch on `execution` to pick their download path.

**Files affected**:
- `lib/report_server_web/api/v1/report_json.ex` — add `execution` to `run_json/1`; add an `execution/1` resolver; fix the stale comment.

**Estimated diff size**: ~15 lines.

`run_json/1` (`report_json.ex:24-35`) already carries `report_type: report_type(report_run.report_slug)`. Add one field and a resolver that reuses the same `Tree.find_report/1` lookup:

```elixir
  defp run_json(report_run = %ReportRun{}) do
    %{
      id: report_run.id,
      report_slug: report_run.report_slug,
      report_type: report_type(report_run.report_slug),
      execution: execution(report_run.report_slug),
      report_filter: report_filter_json(report_run.report_filter),
      ...
    }
  end

  # "async" for Athena runs (result fetched later via presigned URL), "sync" for Portal runs
  # (CSV computed and streamed on /download request). Sourced from the report module type.
  defp execution(report_slug) do
    case Tree.find_report(report_slug) do
      %Report{type: :portal} -> "sync"
      _ -> "async"
    end
  end
```

Update the `report_type/1` comment (`report_json.ex:56-57`) so the `nil` fallback reads as intended for Portal runs rather than "unreachable":
```elixir
  # answers | usage | log — declared on Athena report modules. Portal reports declare none, so
  # report_type is null for Portal runs (a documented, expected value, not an error).
```

Nothing else in the run JSON changes: a Portal run's `athena_query_state` etc. serialize as their real `nil`/empty values (the run is served as-is; no Athena computation, guaranteed by the next step).

---

## Guard `ensure_current` so Portal runs skip the Athena state machine

**Summary**: `report_controller.ex`'s `show` calls `AthenaRunOps.ensure_current/1`; its first clause matches a Portal-shaped run (`athena_query_id: nil, athena_query_state: nil`) and would claim it "queued" and self-start an Athena query (`athena_run_ops.ex:52`). Branch on the resolved report `type` so only Athena runs enter it. A guard clause on `ensure_current` itself is impossible: it receives a `%ReportRun{}`, which has no `type` field (R3-A2). This step guards **`show` only**; `download`'s `ensure_current` call is subsumed by its Athena/Portal split in the download step (P3-2), so guarding it here would just be churn.

**Files affected**:
- `lib/report_server_web/api/v1/report_controller.ex` — a private `ensure_current_if_athena/1` used in `show`.

**Estimated diff size**: ~10 lines.

Add a helper and call it in place of the `AthenaRunOps.ensure_current(report_run)` call in `show` (`report_controller.ex:25`):
```elixir
  # Portal runs have no Athena query to refresh/self-start; only Athena runs enter ensure_current
  # (whose nil/nil clause would otherwise claim a Portal run "queued" and start an Athena query).
  defp ensure_current_if_athena(report_run) do
    case Tree.find_report(report_run.report_slug) do
      %Report{type: :portal} -> report_run
      _ -> AthenaRunOps.ensure_current(report_run)
    end
  end
```

`show` (`report_controller.ex:25`) becomes `report_run = ensure_current_if_athena(report_run)`. Add `alias ReportServer.Reports.{... , Report, Tree}` to the controller's alias list. After this step (and once the gate is open), `GET /reports/:id` returns a Portal run's stored state verbatim.

---

## Bulk capability: `derives_learner_data` flag + 422 for aggregate reports

**Summary**: Add a per-report `derives_learner_data` flag (default `true`), set it `false` on the two aggregate reports, short-circuit `EndpointSet.derive_endpoint_set` to a `422` sentinel when it is false, map that sentinel ahead of the generic 500 in both bulk controllers, and add the tree-consistency test that ties the hand-set flag to its real determinant (Q4, R4-4, R3-A1). No allowlist, no per-run filter-shape check.

**Files affected**:
- `lib/report_server/reports/report.ex` — add `derives_learner_data: true` to the defstruct and thread it through `new/1`.
- `lib/report_server/reports/tree.ex` — set `derives_learner_data: false` on the two aggregate `%Report{}` literals.
- `lib/report_server_web/api/v1/endpoint_set.ex` — resolve the report and short-circuit to `{:error, :not_learner_derivable}` before `LearnerData.fetch`.
- `lib/report_server_web/api/v1/bulk_export_controller.ex` and `attachment_controller.ex` — map the sentinel to `ErrorHelpers.unprocessable/2` ahead of the generic `{:error, _} -> server_error`.
- `test/report_server/reports/tree_test.exs` — consistency test.

**Estimated diff size**: ~55 lines.

`report.ex:5` add the field, and `report.ex:18` thread the opt so a report module can override via `use ... , derives_learner_data: false` if ever wanted (default stays `true`):
```elixir
  defstruct type: nil, slug: nil, ..., api_report_type: nil, derives_learner_data: true

  # in new/1:
  def new(report = %Report{}) do
    %{report |
      get_query: &get_query/2,
      tbd: Keyword.get(@opts, :tbd, false),
      type: Keyword.get(@opts, :type, :portal),
      api_report_type: Keyword.get(@opts, :api_report_type),
      derives_learner_data: Keyword.get(@opts, :derives_learner_data, report.derives_learner_data)
    }
  end
```
Setting it on the `%Report{}` literal in `tree.ex` is the primary mechanism (matches how `include_filters` etc. are set per-report). `tree.ex` `school-metrics` (`:187-192`) and `summary-metrics-by-subject-area` (`:195-200`) gain `derives_learner_data: false` in the struct literal.

`endpoint_set.ex` — add the capability check as the first thing `derive_endpoint_set/2` does (before the `allowed_project_ids_source` call), as a small multi-headed function (R4-4 placement: this is the single shared path for `/answers`, `/history`, `/attachments`):
```elixir
  alias ReportServer.Reports.{Report, ReportFilter, SourceKey, Tree}

  def derive_endpoint_set(user, report_run) do
    with :ok <- ensure_bulk_derivable(Tree.find_report(report_run.report_slug)) do
      # ... existing body unchanged (allowed_project_ids_source().get_allowed_project_ids(user) case) ...
    end
  end

  # aggregate reports (grouped counts, geography filters) cannot answer a per-learner request
  defp ensure_bulk_derivable(%Report{derives_learner_data: false}), do: {:error, :not_learner_derivable}
  defp ensure_bulk_derivable(_report), do: :ok
```
Note `find_report/1` can return `nil` for an unknown slug, which the `_report` head treats as derivable, correct, since such a run cannot pass the gate to reach here anyway.

Both bulk controllers match sentinels top-to-bottom, so the new tuple must precede the catch-all `{:error, _}` (R4-4). In `bulk_export_controller.ex:77` (`first_page`'s `case`):
```elixir
      {:error, :not_learner_derivable} ->
        ErrorHelpers.unprocessable(conn, "This report does not support per-learner endpoints.")

      {:error, _reason} ->
        ErrorHelpers.server_error(conn)
```
In `attachment_controller.ex:36-42` (the `else` block), add ahead of the existing `{:error, _}` catch-all:
```elixir
      {:error, :not_learner_derivable} ->
        ErrorHelpers.unprocessable(conn, "This report does not support per-learner endpoints.")
```

Tree-consistency test (R4-4, the dangerous direction only, "no learner-narrowing `include_filters` => flag must be `false`"):
```elixir
  @learner_narrowing ~w(cohort school teacher assignment class student permission_form)a

  test "every report with no learner-narrowing include_filters is marked derives_learner_data: false" do
    Tree.root()
    |> all_reports()
    |> Enum.each(fn report ->
      if Enum.all?(@learner_narrowing, &(&1 not in report.include_filters)) do
        assert report.derives_learner_data == false,
               "#{report.slug} has no learner-narrowing filter but is not derives_learner_data: false"
      end
    end)
  end
```
(`all_reports/1` walks the tree; reuse `Tree`'s traversal or a local flatten in the test.)

---

## `PortalDbs` streaming seam + shared Portal CSV encoder

**Summary**: Add the swappable batch-streaming entry point `PortalDbs` exposes only `query/4` today (QA1), and a small encoder module that holds the CSV rules shared with the LiveView so the two surfaces cannot silently diverge (SE2). The encoder recipe and the stream envelope shape are the ones confirmed byte-identical to `format_results/2` in Round 6.

**Files affected**:
- `lib/report_server/portal_dbs.ex` — new `stream_query/4`.
- `lib/report_server/reports/portal/csv.ex` (new) — `header_row/1`, `encode_batch/1`.
- `lib/report_server_web/live/report_run_live/show.ex` — refactor `format_results/2` to call the shared encoder (byte-identical for non-empty; corrects the zero-row empty-body bug to header-only; keeps byte-compat honest).

**Estimated diff size**: ~70 lines.

The seam is a **reducer-shaped** function, not a lazy stream: `MyXQL.stream` must run inside a transaction and its connection is checked in when the transaction closes, so a lazy stream cannot escape. The controller passes a reducer that writes chunks; the seam runs it inside `MyXQL.transaction` + `Enum.reduce`. It does **not** rescue the reducer, exceptions propagate so the controller can classify pre-first-byte vs mid-stream (verified in Round 6 T3: a first-fetch DB error raises before the reducer runs; a mid-stream reducer raise propagates out).

```elixir
  # portal_dbs.ex
  @doc """
  Streams a SELECT to a caller-supplied reducer in max_rows batches, inside a transaction.
  reducer :: (%MyXQL.Result{}, acc -> acc). Returns {:ok, acc} | {:error, reason}.
  Exceptions from the *reducer* propagate (the caller classifies them); only setup/DB errors
  are converted to {:error, reason}. `opts`: :max_rows, :timeout (per-batch fetch timeout).
  """
  def stream_query(server, statement, params, opts) do
    max_rows = Keyword.get(opts, :max_rows, 500)
    timeout = Keyword.get(opts, :timeout, @query_timeout)
    acc = Keyword.fetch!(opts, :acc)
    reducer = Keyword.fetch!(opts, :reducer)

    with {:ok, pool_name} <- get_or_start_pool(server) do
      MyXQL.transaction(pool_name, fn conn ->
        MyXQL.stream(conn, statement, params, max_rows: max_rows, timeout: timeout)
        |> Enum.reduce(acc, reducer)
      end, timeout: timeout)
    end
  end
```
(`acc`/`reducer` ride in `opts` to keep a flat arity. `MyXQL.transaction` returns `{:ok, acc}` on success and surfaces DB errors either as `{:error, reason}` or a raised `MyXQL.Error`, both handled by the controller.)

Shared encoder, the exact Round 6 recipe (header once as a CSV row of the column-name strings; each non-empty batch encoded as list-of-lists; `delimiter: "\n"`; zero-row envelopes skipped):
```elixir
  defmodule ReportServer.Reports.Portal.Csv do
    @delimiter "\n"

    # one header line, byte-identical to CSV.encode(headers: atoms) over a non-empty enumerable
    def header_row(columns) do
      [columns] |> CSV.encode(delimiter: @delimiter) |> Enum.join("")
    end

    # a batch of raw MyXQL row lists -> encoded CSV rows (no header). [] for an empty batch.
    def encode_batch([]), do: ""
    def encode_batch(rows) do
      rows |> CSV.encode(delimiter: @delimiter) |> Enum.join("")
    end
  end
```

Refactor the LiveView `format_results/2` (`show.ex:208-216`) to build its CSV from `Csv.header_row/1 <> Csv.encode_batch(result.rows)`, so the web and API share the same encoding rules. For a **non-empty** result this is byte-for-byte identical to the current `format_results/2` output (confirmed against live MySQL in Round 6, and re-confirmed with a DB-free CSV probe in Round 7, which additionally verified that per-batch encoding is byte-identical to a single materialized encode). For an **empty** result it is a small, deliberate behavior change: the current `format_results/2` emits an empty (zero-byte) body for a zero-row download, which is a pre-existing bug; the refactor makes the web emit the same header-only line the API emits, so the two surfaces now agree in the empty case too (project-owner decision, Round 7 / R6-1). Because `format_results/2` is now a pure delegation to `Csv` and the web download path calls `PortalDbs.query` directly (no swappable seam, and tests never hold a live portal DB per R8-1), the empty-result header-only fix is locked by a `Csv` encoder test (`test/report_server/reports/portal/csv_test.exs`) that asserts byte-compatibility with the legacy `format_results/2` recipe for a non-empty result and header-only (not empty) output for a zero-row result, rather than a live-DB LiveView integration test.

---

## Per-node concurrent-download cap (semaphore)

**Summary**: A small supervised counter that admits at most `cap` concurrent Portal downloads per node and rejects the rest with a retryable `503` before any portal-DB connection is checked out (PERF2, R3-C1). Release is crash-safe: the semaphore monitors each holder and auto-releases on `:DOWN`, so a download process that dies mid-stream never leaks a slot.

**Files affected**:
- `lib/report_server/portal_download_limiter.ex` (new) — GenServer with `try_acquire/0` + monitor-based release.
- `lib/report_server/application.ex` — add to the supervision tree.
- `config/runtime.exs` + `config/config.exs` — `PORTAL_DOWNLOAD_MAX_CONCURRENT` (default 2).

**Estimated diff size**: ~60 lines.

```elixir
  defmodule ReportServer.PortalDownloadLimiter do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @doc "Returns :ok if a slot was acquired (auto-released when the caller dies), or :full."
    def try_acquire(server \\ __MODULE__), do: GenServer.call(server, :try_acquire)

    def release(server \\ __MODULE__), do: GenServer.cast(server, {:release, self()})

    @impl true
    def init(opts) do
      {:ok, %{cap: Keyword.fetch!(opts, :cap), holders: %{}}}
    end

    @impl true
    def handle_call(:try_acquire, {from_pid, _}, %{cap: cap, holders: holders} = state) do
      if map_size(holders) >= cap do
        {:reply, :full, state}
      else
        ref = Process.monitor(from_pid)
        {:reply, :ok, %{state | holders: Map.put(holders, from_pid, ref)}}
      end
    end

    @impl true
    def handle_cast({:release, pid}, state), do: {:noreply, drop(state, pid)}

    @impl true
    def handle_info({:DOWN, _ref, :process, pid, _reason}, state), do: {:noreply, drop(state, pid)}

    defp drop(%{holders: holders} = state, pid) do
      case Map.pop(holders, pid) do
        {nil, _} -> state
        {ref, rest} -> Process.demonitor(ref, [:flush]); %{state | holders: rest}
      end
    end
  end
```
Supervise it in `application.ex` with `{ReportServer.PortalDownloadLimiter, cap: portal_download_max_concurrent()}`, reading the cap from config (default 2, via the `portal_download_max_concurrent/0` helper defined in the download step). The `{Module, cap: N}` child spec is auto-generated by `use GenServer` and passes `[cap: N]` to `start_link/1` (verified). The controller pairs `try_acquire/0` with a `release/0` in an `after`/cleanup around the stream. Because the request process holds the slot and the monitor covers a crash, the only explicit release needed is the normal-completion one.

Latent-bug note (R8-3): `holders` is keyed by pid, so if a *single* process called `try_acquire` twice the second `Map.put` would overwrite the first entry (one slot consumed for two acquires, plus a transient extra monitor cleaned up on death — verified). The controller's one-acquire-per-request-process usage never does this, so it is safe as written; if any future caller might acquire twice from one process, guard with `Map.has_key?(holders, from_pid)` in `handle_call` (reject or return `:ok` idempotently) or key by a unique ref instead of pid.

---

## Fail-closed audit row for a streamed Portal download

**Summary**: Add the `run_csv_streamed` event to the audit vocabulary and a fail-closed `AuditLog` function modeled on `log_attachment_urls/3` that writes one pre-stream `data_access_log` row. The controller gates the stream on `{:ok, _}` (Q3, SEC3).

**Files affected**:
- `lib/report_server/audit_log/data_access_log_entry.ex` — add `"run_csv_streamed"` to the `event` `validate_inclusion` list (no migration; `event` is a plain string column).
- `lib/report_server/audit_log.ex` — new `log_run_csv_streamed/2`.

**Estimated diff size**: ~15 lines.

`data_access_log_entry.ex:45-50` — add the event value:
```elixir
    |> validate_inclusion(:event, [
      "download_url_issued",
      "export_scoped",
      "bulk_read",
      "attachment_urls_issued",
      "run_csv_streamed"
    ])
```
`data_type: "run_csv"` and `source: "api"` already validate. `audit_log.ex` — sibling of `log_attachment_urls/3`:
```elixir
  @doc """
  One fail-closed row recording that a streamed Portal CSV download was authorized and initiated
  (written before any bytes are sent, matching Athena's issue-time semantics). Returns
  create_entry/1's {:ok, _} | {:error, _} so the controller can gate the stream on it.
  """
  def log_run_csv_streamed(_user = %{id: user_id}, report_run = %ReportRun{}) do
    create_entry(%{
      event: "run_csv_streamed",
      source: "api",
      data_type: "run_csv",
      user_id: user_id,
      report_run_id: report_run.id,
      report_slug: report_run.report_slug,
      report_filter: dump_filter(report_run.report_filter)
    })
  end
```
The audit UI renders the event verbatim (`audit_log_live/index.html.heex:50`), so no UI change.

---

## Wire the polymorphic Portal `/download` branch

**Summary**: The integrating step. `download/2` branches on report `type`: Athena keeps the presigned-envelope path unchanged; Portal builds the query (mapping build errors to a clean pre-stream JSON error), acquires a cap slot (else `503`), writes the fail-closed audit row (else `500`), then streams the CSV with `Content-Type: text/csv` + `Content-Disposition`, bounded by a wall-clock deadline and a per-batch fetch timeout, classifying failures as pre-first-byte (clean JSON) vs mid-stream (abort framing). SQL is rebuilt only from the run's stored `report_filter` (SEC1); raw DB messages never reach the client (SEC2).

**Files affected**:
- `lib/report_server_web/api/v1/report_controller.ex` — Portal branch in `download/2` and its private helpers.
- `lib/report_server/portal_download_timeout.ex` (new) — a one-line `defexception` the reducer raises on the wall-clock deadline.
- `config/runtime.exs` + `config/config.exs` — `PORTAL_DOWNLOAD_TIMEOUT_MS` (default 120_000).

**Estimated diff size**: ~120 lines.

Branch at the top of `download/2` (after `get_api_report_run`, before `ensure_current_if_athena`):
```elixir
  def download(conn, %{"id" => id_param}) do
    user = conn.assigns.current_user

    with {:ok, id} <- Params.parse_id(id_param),
         {:ok, report_run} <- Reports.get_api_report_run(user, id) do
      case Tree.find_report(report_run.report_slug) do
        %Report{type: :portal} = report -> portal_download(conn, user, report, report_run)
        _ -> athena_download(conn, user, report_run)   # existing body, unchanged
      end
    else
      {:error, :not_found} -> ErrorHelpers.not_found(conn)
    end
  end
```
(`athena_download/3` is the current `download` body verbatim, including its `ensure_current` call, now `ensure_current_if_athena` is unnecessary there since the branch already proved it is Athena; keep the direct `AthenaRunOps.ensure_current` in the Athena branch.)

Portal branch, using the seam/encoder/cap/audit from the prior steps:
```elixir
  defp portal_download(conn, user, report, report_run) do
    filename = "#{report_run.report_slug}-run-#{report_run.id}.csv"

    # 1. Build the SQL from the run's STORED filter (never from request params). Both build steps
    #    can fail before any SQL runs -> clean pre-stream JSON error, no raise (R5-2, Round 6 T3).
    with {:ok, query} <- build_query(report, report_run),
         {:ok, sql} <- ReportQuery.get_sql(query) do
      # 2. Cap BEFORE checking out a portal-DB connection.
      case PortalDownloadLimiter.try_acquire() do
        :full ->
          ErrorHelpers.service_unavailable(conn, "Too many concurrent report downloads; retry shortly.")

        :ok ->
          try do
            stream_portal_csv(conn, user, report_run, sql, filename)
          after
            PortalDownloadLimiter.release()
          end
      end
    else
      # The only build error a well-formed run reaches is the app-level "no filters" short-circuit
      # (super-admin blank filter). It is an app constant, not a raw DB string, so it is safe to
      # surface as a 422 (P3-3). Any OTHER build failure is genericized to a 500 (SEC2).
      {:error, "Cannot run query with no filters"} ->
        ErrorHelpers.unprocessable(conn, "This report run has no filters and cannot be downloaded.")

      {:error, reason} ->
        Logger.error("Portal query build failed for run #{report_run.id}: #{inspect(reason)}")
        ErrorHelpers.server_error(conn)
    end
  end

  # get_query returns {:ok, %ReportQuery{}} | {:error, msg} (verified: TeacherStatusReport.get_query
  # tails into ReportQuery.update_query, Round 6). The rescue is belt-and-suspenders for an
  # unexpected raise, mapped to a non-leaky sentinel.
  defp build_query(%Report{get_query: get_query}, report_run) do
    get_query.(report_run.report_filter || %ReportFilter{}, report_run.user)
  rescue
    e -> Logger.error("Portal query build raised for run #{report_run.id}: #{Exception.message(e)}"); {:error, :build_raised}
  end

  defp stream_portal_csv(conn, user, report_run, sql, filename) do
    # 3. Audit BEFORE any byte (fail-closed).
    case AuditLog.log_run_csv_streamed(user, report_run) do
      {:error, _} -> ErrorHelpers.server_error(conn)
      {:ok, _} ->
        deadline = System.monotonic_time(:millisecond) + portal_download_timeout_ms()
        server = report_run.user.portal_server

        # 4. Stream. The reducer opens send_chunked on the first (columns) result, emits the header
        #    once, encodes non-empty batches, and enforces the wall-clock deadline. A first-fetch DB
        #    error raises before the reducer runs (Round 6 T3) -> classified pre-first-byte below.
        #
        # `sent` is a fresh one-slot atomics ref, NOT the process dictionary: it is created per
        # download, captured in the reducer closure, and read in the rescue. This deliberately avoids
        # two process-dict hazards verified in Round 6 T4: (a) Bandit reuses one process across
        # keep-alive requests (bandit http1/handler.ex `maybe_keepalive`), so a process-dict flag would
        # leak a stale "bytes sent" into the next request on the same connection and misclassify a
        # pre-first-byte error as mid-stream; and (b) an inline-only flag would break silently if the
        # stream were ever moved to a spawned process. The atomics ref is immune to both.
        sent = :atomics.new(1, signed: false)
        acc0 = %{conn: conn, state: :header_pending, deadline: deadline, filename: filename, sent: sent}

        result =
          try do
            case portal_db().stream_query(server, sql, [],
                   acc: acc0, max_rows: 500, timeout: portal_download_timeout_ms(), reducer: &stream_reducer/2) do
              # clean completion: acc threaded out with the fully-chunked conn
              {:ok, %{conn: streamed}} -> {:ok, streamed}
              # seam returned an error WITHOUT raising (e.g. pool-start failure): pre-first-byte,
              # nothing was sent (P3-4). Handle explicitly rather than via a MatchError.
              {:error, reason} -> {:pre_stream, reason}
            end
          rescue
            e ->
              # A DB/reducer exception. bytes already sent -> mid-stream: re-raise so Bandit aborts the
              # chunked framing WITHOUT a terminating 0-chunk (Round 6 T2) and the client detects
              # truncation. No bytes sent (first-fetch DB error, or deadline before the header) -> clean JSON.
              if :atomics.get(sent, 1) == 1 do
                reraise(e, __STACKTRACE__)
              else
                {:pre_stream, e}
              end
          end

        case result do
          {:ok, streamed} -> streamed             # clean EOF, conn already fully chunked
          {:pre_stream, reason} ->
            Logger.error("Portal download failed before first byte for run #{report_run.id}: #{inspect(reason)}")
            ErrorHelpers.server_error(conn)       # generic; SEC2: no raw DB msg in the body
        end
    end
  end
```

The reducer and error classification, the mechanic verified in Round 6 T3:
```elixir
  defp stream_reducer(%MyXQL.Result{columns: cols, rows: rows}, acc) do
    if System.monotonic_time(:millisecond) > acc.deadline, do: raise(PortalDownloadTimeout)

    acc =
      case acc.state do
        :header_pending ->
          conn = acc.conn
            |> put_resp_content_type("text/csv")
            |> put_resp_header("content-disposition", ~s(attachment; filename="#{acc.filename}"))
            |> send_chunked(200)
          {:ok, conn} = chunk(conn, Csv.header_row(cols))
          :atomics.put(acc.sent, 1, 1)   # from here, any raise is mid-stream (re-raise to abort)
          %{acc | conn: conn, state: :streaming}

        :streaming -> acc
      end

    case rows do
      r when r in [nil, []] -> acc                       # skip zero-row envelopes
      _ ->
        {:ok, conn} = chunk(acc.conn, Csv.encode_batch(rows))
        %{acc | conn: conn}
    end
  end
```
Notes carried from requirements:
- The `sent` atomics ref (set the instant `send_chunked` fires) is the classification flag, read in the rescue above. Round 6 T3 confirms the reducer never runs on a first-fetch DB error, so `sent` stays 0 and the error is cleanly classified as pre-first-byte; Round 6 T4 is why this is an atomics ref rather than the process dictionary.
- The empty-result case falls out for free: the leading zero-row envelope flips `:header_pending -> :streaming` and emits the header line; all envelopes are skipped; a clean EOF follows. Result: a header-only 200 (matching the now-corrected web encoder, both header-only; R6-1 / Round 7).
- `PortalDownloadTimeout` is a one-line custom exception (`lib/report_server/portal_download_timeout.ex`, new) so the deadline path is classifiable exactly like any other DB/reducer raise (pre-first-byte -> clean JSON; mid-stream -> abort): `defmodule ReportServer.PortalDownloadTimeout do defexception message: "portal download exceeded its time budget" end`.
- Two *kinds* of `Application.get_env` helper are needed, and they do not read the same way (R8-2). `portal_db/0` is a **flat** seam that genuinely mirrors `athena_db/0` (`report_controller.ex:69`) and carries a module default, so tests swap it for a stub with no live portal DB (QA1):
  ```elixir
  defp portal_db(), do: Application.get_env(:report_server, :portal_db, ReportServer.PortalDbs)
  ```
  `portal_download_timeout_ms/0` (controller) and `portal_download_max_concurrent/0` (`application.ex`) are **not** flat mirrors: the values live under the nested `:portal_download` keyword block, so they need a two-step read, not a flat `:portal_download_timeout_ms` key (which would return `nil`):
  ```elixir
  defp portal_download_timeout_ms(),
    do: Application.get_env(:report_server, :portal_download) |> Keyword.fetch!(:timeout_ms)
  # in application.ex:
  defp portal_download_max_concurrent(),
    do: Application.get_env(:report_server, :portal_download) |> Keyword.fetch!(:max_concurrent)
  ```
  The streamed query's per-batch fetch `:timeout` is set to the same overall `portal_download_timeout_ms()` value: a conservative ceiling on any single batch fetch, while the finer bound on total wall-clock is the deadline checked at the top of each reducer call (a separate per-batch knob was considered and dropped as unnecessary surface).

Config additions (`runtime.exs`, with a `config.exs`/`test.exs` default):
```elixir
  config :report_server, :portal_download,
    timeout_ms: String.to_integer(System.get_env("PORTAL_DOWNLOAD_TIMEOUT_MS") || "120000"),
    max_concurrent: String.to_integer(System.get_env("PORTAL_DOWNLOAD_MAX_CONCURRENT") || "2")
```

---

## Open the API gate to Portal runs (activation)

**Summary**: The activation switch. Flip the two `reports.ex` gate `where` clauses from `athena_report_slugs()` to `api_report_slugs()` and rewrite their stale "Athena-type" docstrings (R4-6). This is deliberately the **last non-test step** (P3-1): every Portal-handling path (execution field, `ensure_current` guard, `derives_learner_data` 422, and the polymorphic `/download` branch) is already in place, so no intermediate commit ever exposes a half-handled Portal run. The job-endpoint regression lock and the acceptance tests follow, exercising the now-open gate.

**Files affected**:
- `lib/report_server/reports.ex` — repoint both `where` clauses; rewrite two docstrings.

**Estimated diff size**: ~10 lines.

`list_api_report_runs` (`reports.ex:68-74`):
```elixir
  @doc """
  Lists the caller's API-exposed report runs (Athena and Portal), newest id first, keyset-paginated.
  """
  def list_api_report_runs(user = %User{}, limit, before_id \\ nil) do
    query = from r in ReportRun,
      where: r.user_id == ^user.id,
      where: r.report_slug in ^Tree.api_report_slugs(),   # was: Tree.athena_report_slugs()
      ...
```
`get_api_report_run` (`reports.ex:87-95`):
```elixir
  @doc """
  Gets one of the caller's API-exposed report runs (Athena or Portal) by id, with the user preloaded.
  Not-owned ids, and ids of runs whose slug is not API-exposed, are indistinguishable from
  non-existent (`{:error, :not_found}`).
  """
  def get_api_report_run(user = %User{}, id) when is_integer(id) do
    query = from r in ReportRun,
      where: r.id == ^id,
      where: r.user_id == ^user.id,
      where: r.report_slug in ^Tree.api_report_slugs(),   # was: Tree.athena_report_slugs()
      preload: [:user]
    ...
```
The moment this lands, Portal runs become listable, showable, downloadable, and (subject to `derives_learner_data`) bulk-derivable, and the two job endpoints begin returning the Portal empty-jobs contract locked by the next step.

---

## Job endpoints: no code change, regression lock

**Summary**: The widened gate admits Portal runs to `GET /reports/:id/jobs` and `/jobs/:job_id/download` (R5-1). `JobsFile.list_jobs(nil) -> {:ok, []}` and `find_job(nil, _) -> {:error, :not_found}` already produce the intended Portal contract (`200 {items: []}` and `404`). This step adds only the regression tests that lock it so a future `JobsFile` change cannot silently turn the empty list into a `500`.

**Files affected**:
- `test/report_server_web/api/v1/report_job_controller_test.exs` — two Portal cases.

**Estimated diff size**: ~30 lines (tests only).

```elixir
  test "a Portal run's /jobs returns 200 with an empty items list", %{raw_token: t, user: u} do
    run = run_fixture(u, %{report_slug: "teacher-status"})   # Portal, athena_query_id: nil
    conn = get(authed_conn(t), ~p"/api/v1/reports/#{run.id}/jobs")
    assert json_response(conn, 200) == %{"items" => []}
  end

  test "a Portal run's /jobs/:job_id/download returns 404", %{raw_token: t, user: u} do
    run = run_fixture(u, %{report_slug: "teacher-status"})
    conn = get(authed_conn(t), ~p"/api/v1/reports/#{run.id}/jobs/1/download")
    assert json_response(conn, 404)["error"] == "NOT_FOUND"
  end
```
Assert an Athena run's job-endpoint behavior is unchanged in the same file.

---

## Acceptance tests for the Portal read + download surface

**Summary**: The full acceptance set from the requirements Tests note, plus the three inverted regression assertions. `teacher-status` is the concrete Portal report exercised.

**Testability (no live portal DB, ever — R8-1).** Tests must reach zero `PortalDbs` calls. The `portal_db` seam stub only covers the *streaming* half; the query-*build* half of a learner-scoped report still calls `PortalDbs` directly and is **not** behind that seam:
- `apply_allowed_project_ids_filter` calls `ReportServer.PortalDbs.get_allowed_project_ids/1` directly (`report_utils.ex:107`); for a non-super-admin user with no test connection string this returns `{:error, "Unknown server ..."}` and the downstream `list_to_in/1` raises `Protocol.UndefinedError` (verified by probe), and for a real researcher it would need a live portal DB.
- `exclude_internal_accounts(true, ...)` calls `get_internal_teacher_ids/1 -> PortalDbs.query/2` (`report_utils.ex:23-24`).

So the streaming/build tests (**download success, empty, mid-stream, timeout**) seed the run's owner as a **super-admin** (`portal_is_admin: true`, so `get_allowed_project_ids -> :all` with no query) with **`exclude_internal: false`** and **at least one non-empty learner-narrowing filter** (so `update_query` does not short-circuit to "no filters"). Under those three conditions `get_query` builds real SQL with **no** `PortalDbs` call, and only the stubbed `stream_query` runs (the stub ignores the SQL and drives the reducer with canned envelopes). The **construction-error** test is the deliberate exception: super-admin + *blank* filter, which returns `{:error, "Cannot run query with no filters"}` before any DB access. Alternatively an aggregate report (`school-metrics`) can back a pure streaming success/empty assertion since its `get_query` never scopes (no `apply_allowed_project_ids_filter`), but `teacher-status` + super-admin is the primary fixture. This mirrors how the existing bulk/attachment suites already stub `learner_data`/`allowed_project_ids_source`; the download path's build-time `get_allowed_project_ids` is simply not one of those seams, so the super-admin `:all` short-circuit (not a stub) is what keeps it DB-free. Coverage note: because a non-admin download's project scoping is unreachable without a live portal DB, the API layer does not re-test learner-scoped scoping; that scoping lives in the shared `get_query`/report modules and is covered there.

**Files affected**:
- `test/report_server_web/api/v1/report_controller_test.exs` — listing, download success/empty/errors/timeout, and the three inverted assertions.
- `test/report_server_web/api/v1/bulk_export_controller_test.exs` + `attachment_controller_test.exs` — 422 for `school-metrics`; normal derivation for a learner-derivable Portal run.
- `test/support/` — a `PortalDbsStub` implementing only `stream_query/4` (the swapped `portal_db` seam), yielding canned `%MyXQL.Result{}` batches (leading columns envelope + row batches, or a raising variant). It does **not** stub `get_allowed_project_ids`/`query`, which is why the build-path DB access is avoided at the fixture level via the super-admin `:all` short-circuit (see Testability above), not by this stub.

**Estimated diff size**: ~200 lines (tests + stub).

Scenarios (each an assertion, mapped to requirements Tests bullets):
- **listing**: a `teacher-status` run appears with `execution: "sync"`, `report_type: null`; an Athena run shows `execution: "async"`. Update the existing `report_controller_test.exs:52-65` "returns only Athena-type runs" test to expect the Portal run present (it currently asserts absence).
- **show/download 404 buckets** (`:233-253`, `:466-486`): remove the Portal run id from the must-404 sets (it now resolves).
- **download success**: on a super-admin, non-empty-filter `teacher-status` run (see Testability), the stub yields columns + two batches; assert `content-type: text/csv`, `content-disposition`, and a body byte-equal to `Csv.header_row/1 <> encode_batch` over the same rows.
- **download empty**: stub yields only zero-row envelopes; assert a header-only 200 body (matching the now-corrected web encoder; see the shared-encoder step, whose `Csv` encoder test locks the header-only empty-result behavior the web and API now share).
- **download pre-first-byte, execution error**: stub raises a `MyXQL.Error` on first fetch (before the reducer); assert a clean `500` JSON, generic (no raw DB text), and exactly one `run_csv_streamed` audit row (the initiated row).
- **download pre-first-byte, construction error**: a super-admin blank-filter `teacher-status` run whose `get_query` returns `{:error, "Cannot run query with no filters"}`; assert a clean JSON error, not a raised 500 (uses the real `get_query`, no stub).
- **download mid-stream failure**: stub raises after the first batch; at `ConnTest` level assert the reducer raised after `send_chunked` (wire-level truncation is out of scope per R3-B2; the Round 6 T2 harness covers the live-Bandit property).
- **download timeout**: stub with a controllable clock / a deadline set in the past; assert the pre-first-byte case yields a clean JSON timeout error.
- **concurrency cap**: with `cap: 1` acquired, a second download returns `503`.
- **bulk 422**: `school-metrics` run on each of `/answers`, `/history`, `/attachments` returns `422 UNPROCESSABLE`; a learner-derivable Portal run derives normally.
- **Athena regression**: report_type, presigned envelope, 409 states, pagination unchanged (existing tests stay green).

---

## Open Questions

<!-- Implementation-focused questions only. Requirements questions go in requirements.md. -->

_None open. The three runtime assumptions that could have forced a redesign (stream envelope shape + byte-compat, live-Bandit truncation semantics, and pre-first-byte vs mid-stream error timing) were resolved empirically before this plan was written; see requirements Self-Review Round 6._

## Self-Review

### Load-bearing verification (Phase 3)

Before reviewing the plan for defects, the three genuinely net-new modules were stood up as real code and driven end-to-end against a live MySQL 8.0 (docker, port 3406) and a real Bandit endpoint (harness in the session scratch dir, not the repo). All passed:
- **`Portal.Csv` encoder** (step 6): the streamed `/download` body is **byte-identical** to the LiveView `format_results/2` reference for a non-empty result (commas, embedded quotes, embedded newlines), and header-only for an empty result.
- **`PortalDbs.stream_query` seam + reducer + `:atomics` classification** (steps 6/9): success streams `text/csv` with the `Content-Disposition` header; a first-fetch DB error returns a clean JSON `500`, **not chunked** and with no raw DB text; a mid-stream raise aborts the framing (curl exit 18, no terminating 0-chunk) while the status was already `200`; a fail-closed audit error returns `500` with no bytes.
- **`PortalDownloadLimiter` semaphore** (step 7): cap enforced (3rd concurrent acquire returns `:full`), explicit release and monitor-based `:DOWN` auto-release both return the count to 0.

### Cross-reference (Phase 3, Step 1)

Requirements coverage: every requirement (Listing, Job endpoints, Download, Bulk, Regression) maps to at least one step; no orphan steps; all steps ≤ ~200 lines. One ordering defect was found and fixed (P3-1). No OPEN items remain in either spec file.

### Senior Engineer / DevOps Engineer

#### RESOLVED: P3-1 - The gate widening was scheduled first, which regresses every intermediate commit
Opening the gate (repointing the two `reports.ex` `where` clauses) before the Portal-handling machinery exists means intermediate commits are broken: a Portal `show` would trip `ensure_current`'s Athena self-start (`athena_run_ops.ex:52`), a Portal `download` would fall to the `%ReportRun{athena_query_state: nil}` clause and return a misleading `409 NOT_READY`, and Portal bulk would do the over-broad pull/500. **Fix**: split the original step 2 into "add the `api_report_slugs` helper" (early, unused) and a new final non-test step "Open the API gate to Portal runs" that flips the two `where` clauses + docstrings. The gate now opens only after the execution field, `ensure_current` guard, `derives_learner_data` 422, and the `/download` branch are all in place; the job-regression and acceptance tests (which need the gate open) follow it.

#### RESOLVED: P3-2 - Step 4 guarded `download`'s `ensure_current`, which step 9 immediately undoes
The `ensure_current` guard step added `ensure_current_if_athena` to both `show` and `download`, but the download step restructures `download` into an Athena/Portal branch where the Athena branch calls `AthenaRunOps.ensure_current` directly. **Fix**: the guard step now touches `show` only; the download path's guard is subsumed by its type branch.

### Senior Engineer (error contract)

#### RESOLVED: P3-3 - The build-error `else` clause mapped *all* build failures to a 422 "no filters" message
`portal_download`'s `with/else` returned `unprocessable(conn, "...no filters...")` for every `{:error, _}` from `build_query`/`get_sql`, mislabeling any non-"no-filters" build failure and forcing a 422 for what may be a genuine server fault. **Fix**: match the app-level constant `{:error, "Cannot run query with no filters"}` -> `422` with that message (safe to surface, SEC2-exempt), and map any other `{:error, reason}` -> generic `server_error` (logged, no raw text in the body).

#### RESOLVED: P3-4 - The streaming seam's `{:error, reason}` return was handled only via a MatchError
`stream_portal_csv` bound `{:ok, %{conn: streamed}} = portal_db().stream_query(...)`, so a seam that *returns* `{:error, reason}` (e.g. a portal-pool start failure) would raise a MatchError caught by the rescue, correct outcome, wrong mechanism. **Fix**: `case` on the seam result explicitly, mapping `{:error, reason}` to the pre-first-byte clean-JSON path, and keep the rescue for genuine exceptions only.

### QA Engineer

#### RESOLVED: P3-5 - A pre-first-byte timeout is indistinguishable from a generic DB error to the client
All pre-first-byte failures map to a generic `SERVER_ERROR`, so a download that times out before the first byte returns the same `500` as a DB error. The Download requirement only mandates "a clean JSON error" (not a distinct timeout code), so this is acceptable and left as-is; noted here as an optional future nicety (a distinct message/code for the `PortalDownloadTimeout` pre-stream case) rather than a defect.

## Self-Review (Round 7: implementation-spec multi-role, every finding code-verified + probe-verified before being written)

Multi-role pass (Senior/OTP Engineer, Security, QA, Performance/Concurrency, DevOps) run against `implementation.md` specifically, with every candidate proved against the current working tree before being written, and the two load-bearing runtime assumptions re-checked with throwaway probes rather than trusted from Round 6 alone: a DB-free CSV probe comparing the LiveView `format_results/2` pipeline to the proposed `Portal.Csv` recipe, and a live-MySQL-8.0 (port 3406) probe of the `MyXQL.stream` envelope shape. Several strong-looking candidates were dropped after verification and are not listed: (a) `derives_learner_data` set on the `tree.ex` `%Report{}` literal survives `Report.new/1` unchanged, because `new/1` is a `%{report | ...}` struct-update that overwrites only `get_query/tbd/type/api_report_type` (`report.ex:17-19`); (b) wrapping the existing `EndpointSet.derive_endpoint_set/2` `case` in `with :ok <- ensure_bulk_derivable(...)` compiles and returns cleanly, and the alias add (`Report, Tree`) is required and correct; (c) `MyXQL.transaction/3` exists (`myxql.ex:674`), returns the fun result in `{:ok, _}`, requires `MyXQL.stream` to be wrapped in a transaction, and re-raises reducer exceptions (so the pre-first-byte/mid-stream classification holds); (d) the `PortalDownloadLimiter` is crash-safe with no double-release (`demonitor(ref, [:flush])` flushes a queued `:DOWN` after an explicit `release`, and the `map`-as-count makes `drop/1` idempotent); (e) `JobsFile.list_jobs(nil) -> {:ok, []}` / `find_job(nil, _) -> {:error, :not_found}`, the gate functions/docstrings, `ensure_current`'s first clause, and the audit vocabulary all match the spec's citations. The findings that survived are below.

### Senior Engineer / API Contract Reviewer

#### RESOLVED: R7-1 - The `format_results/2` refactor silently changed the web UI's empty-download behavior, contradicting the step's "pure refactor / LiveView output unchanged" claim
Verified with the Round 7 CSV probe: refactoring `format_results/2` to `Csv.header_row(cols) <> Csv.encode_batch(result.rows)` is byte-identical to the current output for a non-empty result (and per-batch encoding equals a single materialized encode), but for a **zero-row** result the current code emits an empty (zero-byte) body while the refactor emits a header-only line. So the step as written was a real, untested web-UI behavior change mislabeled "no behavior change," and it also falsified R6-1's premise ("the web encoder emits an empty body for zero rows") the moment the refactor landed. **Decision (project owner):** the web empty-body was a pre-existing bug; the web is corrected in this story to emit the same header-only line as the API. The shared-encoder step wording, its `show.ex` Files-affected note, the reducer/empty-case notes, the download-empty acceptance test, and R6-1 / the byte-compat scoping in `requirements.md` were all updated so the web and API agree in the empty case (byte-compat now holds for empty too), and a LiveView empty-download test was added to the plan.

### QA Engineer / DevOps Engineer

#### RESOLVED: R7-2 - The new streaming seam was named `stream_query/5` but is defined and called at arity 4
The Orientation/Files-affected called it `stream_query/5`, but the definition (`stream_query(server, statement, params, opts)`) and the sole call site (`portal_db().stream_query(server, sql, [], acc: ..., ...)`) are arity 4 (`acc`/`reducer` ride in `opts`). Corrected to `stream_query/4`.

#### RESOLVED: R7-3 - `per_batch_timeout/0` was used in the seam call but never defined and had no config key
The download code passed `timeout: per_batch_timeout()` to the seam, but the `:portal_download` config block defines only `timeout_ms` and `max_concurrent`, and no `per_batch_timeout/0` helper is specified anywhere. Rather than add a second timeout knob, the seam's per-batch fetch `:timeout` is now set to the overall `portal_download_timeout_ms()` (a conservative single-fetch ceiling; the finer total-wall-clock bound is the deadline checked between batches). The stray helper reference was removed.

#### RESOLVED: R7-4 - `PortalDownloadTimeout` was raised by the reducer but no step created it
The reducer does `raise(PortalDownloadTimeout)` and a note called it "a tiny custom exception," but no step's Files-affected or code block defined the `defexception`. Added `lib/report_server/portal_download_timeout.ex` (new) to the download step's Files-affected with the one-line `defexception` stub, so the plan is self-contained.

### Load-bearing verification (Round 7 probes)

- **CSV encoder (DB-free):** the LiveView `format_results/2` pipeline (`map_columns_on_rows` + `CSV.encode(headers: atoms, delimiter: "\n")`) and the proposed `Portal.Csv` recipe (`header_row(cols) <> encode_batch(rows)`) are byte-identical for a non-empty result with values containing commas, embedded double-quotes, and embedded newlines; multi-batch streamed output equals the single materialized encode; and for the empty case they differ (empty body vs header-only) — the evidence for R7-1.
- **`MyXQL.stream` envelope (live MySQL 8.0, port 3406):** confirmed the reducer's assumptions — a leading `num_rows: 0` result carrying `columns`; a trailing `num_rows: 0` result exactly when the row count is divisible by `max_rows`; and **two** zero-row envelopes (both carrying `columns`) for a zero-row query — so header-emit-once, zero-row-envelope-skip, and header-only-on-empty all hold. Probe scripts live in the session scratch dir, not the repo.

## Self-Review (Round 8: implementation-spec multi-role, every finding code-verified + probe-verified)

Eighth-pass review of `implementation.md`, focused on what the prior rounds' runtime probes had not exercised: the query-*build* half of the download path, the config-read plumbing, and the semaphore's edge behavior. Each candidate was proved against the current tree and, where a runtime behavior was in doubt, a throwaway probe (DB-free or against live MySQL 8.0 on port 3406) or a standalone GenServer harness. The core mechanics re-verified as sound and are **not** re-listed: the `Portal.Csv` recipe is byte-identical to `format_results/2` for non-empty (per-batch and single-materialized) and header-only-vs-empty for zero rows; `MyXQL.transaction/3` returns `{:ok, reduced_acc}` and *re-raises* both reducer exceptions and first-fetch DB errors (reducer runs 0 times on invalid SQL) while only a pool-start failure returns `{:error, reason}` — exactly the `case {:ok,_}/{:error,_}` + `rescue` split `stream_portal_csv` uses, so the pre-first-byte/mid-stream classification holds; and the `PortalDownloadLimiter` child-spec, `:DOWN` auto-release, double-release safety, and cap enforcement all pass under a real supervisor. The three findings that survived are below.

### QA Engineer / Senior Engineer

#### RESOLVED: R8-1 - The download acceptance tests could not run without a live portal DB (or would crash), because the `portal_db` stub covers only streaming, not the query-build's project-scoping DB call
The acceptance-tests step said the tests use `teacher-status` and "the `portal_db` stub seam so no live portal DB is needed." Verified this is false for a learner-scoped report: `teacher-status`'s `get_query` calls `apply_allowed_project_ids_filter`, which calls `ReportServer.PortalDbs.get_allowed_project_ids/1` **directly** (`report_utils.ex:107`), and `exclude_internal_accounts(true, ...)` calls `PortalDbs.query/2` (`report_utils.ex:23-24`) — neither is behind the swappable `portal_db` seam. Probe (super-admin vs researcher, no test connection string): a super-admin builds SQL with **zero** `PortalDbs` calls (`get_allowed_project_ids -> :all` short-circuit), while a researcher's `get_allowed_project_ids` returns `{:error, "Unknown server ..."}` and the downstream `list_to_in/1` raises `Protocol.UndefinedError` (Enumerable not implemented for a tuple). Since tests can never hold a real portal DB connection, the fixture must reach zero `PortalDbs` calls. **Resolution:** the streaming/build tests (download success, empty, mid-stream, timeout) seed the run's owner as a **super-admin** (`portal_is_admin: true`) with `exclude_internal: false` and ≥1 non-empty learner-narrowing filter, so `get_query` builds real SQL DB-free and only the stubbed `stream_query` runs; the construction-error test keeps super-admin + blank filter (already correct); and an aggregate report (`school-metrics`, never scopes) is documented as an alternative. The acceptance-tests step now carries an explicit "Testability (no live portal DB, ever)" note, the `test/support` `PortalDbsStub` bullet states the stub covers only streaming, and a coverage note records that non-admin learner-scoped scoping is exercised in the shared `get_query`, not re-tested at the API layer. Secondary accuracy point folded in: for learner-scoped reports the build-time `get_allowed_project_ids` call checks out a portal-DB connection *before* `try_acquire`, so the cap's "rejects before any portal-DB connection is checked out" framing is exact only for aggregate/super-admin builds.

### DevOps Engineer / Senior Engineer

#### RESOLVED: R8-2 - Three config-read helpers were referenced but never defined, and were mischaracterized as mirroring the flat `athena_db/0` read
`portal_db/0`, `portal_download_timeout_ms/0`, and `portal_download_max_concurrent/0` were cited as `Application.get_env` reads "mirroring `athena_db/0`," but only `portal_db/0` is a flat-key read like `athena_db/0`. The timeout and concurrency values live under the **nested** `config :report_server, :portal_download, timeout_ms:, max_concurrent:` block, so a flat `Application.get_env(:report_server, :portal_download_timeout_ms)` would return `nil`. Same self-containment class as Round 7's `PortalDownloadTimeout`/`per_batch_timeout` fixes. **Resolution:** the download step now defines all three helpers explicitly — `portal_db/0` as the flat seam with a module default, and the two config reads as `Application.get_env(:report_server, :portal_download) |> Keyword.fetch!(:timeout_ms | :max_concurrent)` — and the limiter step cross-references `portal_download_max_concurrent/0` and notes the auto-generated `{Module, cap: N}` child spec (verified).

### Senior Engineer / Concurrency Reviewer

#### RESOLVED: R8-3 - The `PortalDownloadLimiter` has a latent same-pid double-acquire slot-miscount (not reachable on the intended path)
Verified with a standalone harness: because `holders` is keyed by pid, a single process calling `try_acquire` twice overwrites its own entry via `Map.put`, consuming one slot for two acquires and holding a transient extra monitor (cleaned up when the process dies). The controller acquires exactly once per request process and releases via `self()`, so this never occurs on the real path. **Resolution:** left as-is (safe as written) with a one-line latent-bug note added to the limiter step recommending a `Map.has_key?(holders, from_pid)` guard or a ref-keyed map if any future caller might acquire twice from one process.
