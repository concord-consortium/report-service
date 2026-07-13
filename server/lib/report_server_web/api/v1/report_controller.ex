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
