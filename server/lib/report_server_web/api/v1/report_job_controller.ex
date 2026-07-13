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
      {:error, :not_found} ->
        ErrorHelpers.not_found(conn)

      {:error, reason} ->
        Logger.error("Unable to read jobs file: #{inspect(reason)}")
        ErrorHelpers.server_error(conn)
    end
  end

  defp athena_db(), do: Application.get_env(:report_server, :athena_db, ReportServer.AthenaDB)
end
