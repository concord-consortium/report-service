defmodule ReportServer.Reports.AthenaRunOps do
  import Ecto.Query, warn: false

  require Logger

  alias ReportServer.Repo
  alias ReportServer.Reports
  alias ReportServer.Reports.{Report, ReportQuery, ReportRun, Tree}

  defp athena_db(), do: Application.get_env(:report_server, :athena_db, ReportServer.AthenaDB)
  defp tree(), do: Application.get_env(:report_server, :report_tree, Tree)

  def non_terminal?(%ReportRun{athena_query_state: state}) when state in [nil, "queued", "running"], do: true
  def non_terminal?(_), do: false

  def start_query(report_run = %ReportRun{athena_query_id: nil}) do
    with report = %Report{} <- tree().find_report(report_run.report_slug),
         {:ok, query} <- report.get_query.(report_run.report_filter, report_run.user),
         {:ok, sql} <- ReportQuery.get_sql(query),
         {:ok, athena_query_id, athena_query_state} <- athena_db().query(sql, report_run.id, report_run.user),
         {:ok, report_run} <- Reports.update_report_run(report_run, %{athena_query_id: athena_query_id, athena_query_state: athena_query_state}) do
      {:ok, report_run}
    else
      nil ->
        {:error, "Unable to find report: #{report_run.report_slug}"}

      {:error, error} ->
        {:error, error}

      error ->
        # generic user-facing message; the inspected detail is logged, not surfaced to the UI
        Logger.error("Unknown error running Athena report #{report_run.id}: #{inspect(error)}")
        {:error, "An unexpected error occurred while running the report."}
    end
  end

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
        %{report_run | athena_query_state: "queued"}
    end
  end
  def ensure_current(report_run = %ReportRun{athena_query_id: nil}) do
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
