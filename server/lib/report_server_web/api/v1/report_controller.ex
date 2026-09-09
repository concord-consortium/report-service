defmodule ReportServerWeb.Api.V1.ReportController do
  use ReportServerWeb, :controller

  require Logger

  alias ReportServer.{AuditLog, ClientClosedError, PortalDownloadLimiter, PortalDownloadTimeout}

  # Caps a single batch fetch (and the transaction's checkout/BEGIN/COMMIT), so a stuck fetch can
  # overshoot the overall wall-clock deadline by at most one batch rather than the full budget.
  @portal_download_batch_timeout_ms 15_000
  alias ReportServer.Reports
  alias ReportServer.Reports.{AthenaRunOps, FilterValidation, Report, ReportFilter, ReportQuery, ReportRun, Tree}
  alias ReportServer.Reports.Portal.Csv
  alias ReportServerWeb.Api.ErrorHelpers
  alias ReportServerWeb.Api.V1.{FilterParams, Params, ReportJSON}

  def index(conn, params) do
    with {:ok, limit} <- Params.parse_limit(params),
         {:ok, before_id} <- Params.parse_page_token(params) do
      report_runs = Reports.list_api_report_runs(conn.assigns.current_user, limit, before_id)
      json(conn, ReportJSON.index(report_runs, limit))
    else
      {:error, message} -> ErrorHelpers.bad_request(conn, message)
    end
  end

  def create(conn, params) do
    user = conn.assigns.current_user

    with {:ok, report} <- find_api_report(params["report_slug"]),
         {:ok, report_filter} <- FilterParams.parse(params["report_filter"]),
         {:ok, report_run} <- Reports.create_api_report_run(user, report, report_filter) do
      conn |> put_status(:created) |> json(ReportJSON.show(report_run))
    else
      error -> render_create_error(conn, error)
    end
  end

  def duplicate(conn, %{"id" => id_param} = params) do
    user = conn.assigns.current_user

    with {:ok, id} <- Params.parse_id(id_param),
         {:ok, source} <- Reports.get_api_report_run(user, id),
         {:ok, report} <- find_api_report(source.report_slug),
         :ok <- check_duplicate_allowed(report, source, params),
         {:ok, report_run} <- Reports.duplicate_api_report_run(user, report, source) do
      conn |> put_status(:created) |> json(ReportJSON.show(report_run))
    else
      {:portal_duplicate, run_id} -> render_portal_duplicate(conn, run_id)
      error -> render_create_error(conn, error)
    end
  end

  # A Portal run is computed on request, so a duplicate of one is a new id over identical live
  # data. The habit comes from Athena, where duplicating is the only way to take a fresh snapshot.
  defp check_duplicate_allowed(%Report{type: :portal}, source, params) do
    if params["force"] == true, do: :ok, else: {:portal_duplicate, source.id}
  end

  defp check_duplicate_allowed(_report, _source, _params), do: :ok

  # The keys of this body are a pinned contract: cc-data copies a coded error's context into the
  # envelope its CLI prints and into the MCP result, so a field added here is disclosed the day it
  # ships. The advice names re-reading the run rather than any client's flag.
  defp render_portal_duplicate(conn, run_id) do
    ErrorHelpers.render_error(
      conn,
      "PORTAL_DUPLICATE_UNNECESSARY",
      "Run #{run_id} is a Portal report, computed live on every request, so a duplicate returns " <>
        "the same data under a new id. Re-read run #{run_id} for current data, or pass " <>
        "force: true to duplicate anyway.",
      %{run_id: run_id}
    )
  end

  defp render_create_error(conn, {:error, :not_found}), do: ErrorHelpers.not_found(conn)
  defp render_create_error(conn, {:error, :invalid, message}), do: ErrorHelpers.bad_request(conn, message)

  defp render_create_error(conn, {:error, :out_of_scope, dimensions}),
    do: ErrorHelpers.bad_request(conn, FilterValidation.out_of_scope_message(dimensions))

  defp render_create_error(conn, {:error, :derivation_failed, reason}) do
    Logger.error("Unable to derive filter values: #{inspect(reason)}")
    ErrorHelpers.server_error(conn)
  end

  defp render_create_error(conn, {:error, message}) when is_binary(message),
    do: ErrorHelpers.bad_request(conn, message)

  defp render_create_error(conn, {:error, reason}) do
    Logger.error("Unable to create report run: #{inspect(reason)}")
    ErrorHelpers.server_error(conn)
  end

  # A slug that exists but is not API-exposed is not found, rather than a report the API does not
  # otherwise serve.
  defp find_api_report(nil), do: {:error, :invalid, "report_slug is required"}

  defp find_api_report(slug) when is_binary(slug) do
    case Tree.find_report(slug) do
      %Report{slug: ^slug} = report ->
        if slug in Tree.api_report_slugs(), do: {:ok, report}, else: {:error, :not_found}

      _ ->
        {:error, :not_found}
    end
  end

  defp find_api_report(_slug), do: {:error, :invalid, "report_slug must be a string"}

  def show(conn, %{"id" => id_param}) do
    with {:ok, id} <- Params.parse_id(id_param),
         {:ok, report_run} <- Reports.get_api_report_run(conn.assigns.current_user, id) do
      report_run = ensure_current_if_athena(report_run)
      json(conn, ReportJSON.show(report_run))
    else
      {:error, :not_found} -> ErrorHelpers.not_found(conn)
    end
  end

  defp ensure_current_if_athena(report_run) do
    case Tree.find_report(report_run.report_slug) do
      %Report{type: :portal} -> report_run
      _ -> AthenaRunOps.ensure_current(report_run)
    end
  end

  def download(conn, %{"id" => id_param}) do
    user = conn.assigns.current_user

    with {:ok, id} <- Params.parse_id(id_param),
         {:ok, report_run} <- Reports.get_api_report_run(user, id) do
      case Tree.find_report(report_run.report_slug) do
        %Report{type: :portal} = report -> portal_download(conn, user, report, report_run)
        _ -> athena_download(conn, user, report_run)
      end
    else
      {:error, :not_found} -> ErrorHelpers.not_found(conn)
    end
  end

  defp athena_download(conn, user, report_run) do
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
        ErrorHelpers.render_error(conn, "NOT_READY", "The report is not ready to download.", %{
          athena_query_state: athena_query_state,
          athena_query_id: report_run.athena_query_id,
          athena_query_error: report_run.athena_query_error
        })
    end
  end

  defp portal_download(conn, user, report, report_run) do
    filename = "#{report_run.report_slug}-run-#{report_run.id}.csv"

    with {:ok, query} <- build_query(report, report_run),
         {:ok, sql} <- ReportQuery.get_sql(query) do
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
      {:error, "Cannot run query with no filters"} ->
        ErrorHelpers.unprocessable(conn, "This report run has no filters and cannot be downloaded.")

      {:error, reason} ->
        Logger.error("Portal query build failed for run #{report_run.id}: #{inspect(reason)}")
        ErrorHelpers.server_error(conn)
    end
  end

  defp build_query(%Report{get_query: get_query}, report_run) do
    get_query.(report_run.report_filter || %ReportFilter{}, report_run.user)
  rescue
    e ->
      Logger.error("Portal query build raised for run #{report_run.id}: #{Exception.message(e)}")
      {:error, :build_raised}
  end

  defp stream_portal_csv(conn, user, report_run, sql, filename) do
    case AuditLog.log_run_csv_streamed(user, report_run) do
      {:error, _} ->
        ErrorHelpers.server_error(conn)

      {:ok, _} ->
        deadline = System.monotonic_time(:millisecond) + portal_download_timeout_ms()
        server = report_run.user.portal_server
        sent = :atomics.new(1, signed: false)
        acc0 = %{conn: conn, state: :header_pending, deadline: deadline, filename: filename, sent: sent}

        # The overall wall-clock bound is `deadline`, checked between batches in the reducer. The
        # per-batch fetch timeout is capped separately so a single stuck fetch cannot overshoot the
        # deadline by the full budget (it is also stream_query's transaction/checkout timeout, which
        # bounds BEGIN/COMMIT, not the transaction lifetime).
        batch_timeout = min(portal_download_timeout_ms(), @portal_download_batch_timeout_ms)

        result =
          try do
            case portal_db().stream_query(server, sql, [],
                   acc: acc0, max_rows: 500, timeout: batch_timeout, reducer: &stream_reducer/2) do
              {:ok, %{conn: streamed}} ->
                {:ok, streamed}

              # A seam error with no bytes sent (e.g. a pool-start failure) is pre-first-byte and gets
              # a clean JSON error. If bytes were already sent, raise so the rescue below aborts the
              # chunked framing rather than rendering JSON on an already-committed response.
              {:error, reason} ->
                if :atomics.get(sent, 1) == 1 do
                  raise "Portal download seam failed after streaming started for run #{report_run.id}: #{inspect(reason)}"
                else
                  {:pre_stream, reason}
                end
            end
          rescue
            # A normal client disconnect mid-stream: return the already-chunked conn quietly rather
            # than re-raising a crash. The socket is gone, so the response framing no longer matters.
            e in ClientClosedError ->
              {:client_closed, e.conn}

            e ->
              if :atomics.get(sent, 1) == 1 do
                reraise(e, __STACKTRACE__)
              else
                {:pre_stream, e}
              end
          end

        case result do
          {:ok, streamed} ->
            streamed

          {:client_closed, streamed} ->
            Logger.info("Portal download for run #{report_run.id}: client closed the connection mid-stream")
            streamed

          {:pre_stream, reason} ->
            Logger.error("Portal download failed before first byte for run #{report_run.id}: #{inspect(reason)}")
            ErrorHelpers.server_error(conn)
        end
    end
  end

  defp chunk_or_raise_closed(conn, data) do
    case chunk(conn, data) do
      {:ok, conn} -> conn
      {:error, :closed} -> raise ClientClosedError, conn: conn
    end
  end

  defp stream_reducer(%MyXQL.Result{columns: cols, rows: rows}, acc) do
    if System.monotonic_time(:millisecond) > acc.deadline, do: raise(PortalDownloadTimeout)

    acc =
      case acc.state do
        :header_pending ->
          conn =
            acc.conn
            |> put_resp_content_type("text/csv")
            |> put_resp_header("content-disposition", ~s(attachment; filename="#{acc.filename}"))
            |> send_chunked(200)

          # send_chunked has committed the 200 and headers, so from here any failure (including a
          # failed header chunk) is mid-stream and must abort the chunked framing, not render JSON.
          :atomics.put(acc.sent, 1, 1)
          conn = chunk_or_raise_closed(conn, Csv.header_row(cols))
          %{acc | conn: conn, state: :streaming}

        :streaming ->
          acc
      end

    case rows do
      r when r in [nil, []] ->
        acc

      _ ->
        conn = chunk_or_raise_closed(acc.conn, Csv.encode_batch(rows))
        %{acc | conn: conn}
    end
  end

  defp athena_db(), do: Application.get_env(:report_server, :athena_db, ReportServer.AthenaDB)

  defp portal_db(), do: Application.get_env(:report_server, :portal_db, ReportServer.PortalDbs)

  defp portal_download_timeout_ms(),
    do: Application.get_env(:report_server, :portal_download) |> Keyword.fetch!(:timeout_ms)
end
