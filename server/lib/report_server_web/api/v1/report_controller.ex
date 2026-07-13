defmodule ReportServerWeb.Api.V1.ReportController do
  use ReportServerWeb, :controller

  require Logger

  alias ReportServer.AuditLog
  alias ReportServer.Reports
  alias ReportServer.Reports.{AthenaRunOps, ReportRun}
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

  defp athena_db(), do: Application.get_env(:report_server, :athena_db, ReportServer.AthenaDB)
end
