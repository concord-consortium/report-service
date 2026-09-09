defmodule ReportServerWeb.ReportRunLive.Duplicate do
  @moduledoc """
  The runs UI's duplicate action, shared by the runs tables and the run page.

  The run id arrives from the DOM rather than from the page's own params, so the action resolves it
  through the own-or-admin read instead of trusting the page it was rendered on. The duplicate
  belongs to the clicking user and its filter goes through `HideNames.enforce/2` like every other
  path, so it can never widen what its creator may see.
  """

  import Phoenix.LiveView, only: [put_flash: 3, redirect: 2]

  require Logger

  alias ReportServer.Reports
  alias ReportServer.Reports.{FilterValidation, Report, Tree}
  alias ReportServerWeb.Api.V1.Params

  def duplicate(socket, user, id) do
    with {:ok, id} <- Params.parse_id(id),
         {:ok, source} <- Reports.get_report_run_for_user(user, id),
         %Report{} = report <- Tree.find_report(source.report_slug),
         {:ok, report_run} <- Reports.duplicate_api_report_run(user, report, source) do
      redirect(socket, to: "/reports/runs/#{report_run.id}")
    else
      {:error, :invalid, message} ->
        put_flash(socket, :error, "Unable to duplicate this report run: #{message}")

      {:error, :out_of_scope, dimensions} ->
        put_flash(socket, :error, "Unable to duplicate this report run: #{FilterValidation.out_of_scope_message(dimensions)}")

      {:error, :not_found} ->
        put_flash(socket, :error, "Sorry, you don't have access to that report run.")

      failure ->
        Logger.error("Unable to duplicate report run #{inspect(id)}: #{inspect(failure)}")
        put_flash(socket, :error, "Unable to duplicate this report run.")
    end
  end
end
