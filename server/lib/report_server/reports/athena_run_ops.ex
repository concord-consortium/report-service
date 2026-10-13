defmodule ReportServer.Reports.AthenaRunOps do
  import Ecto.Query, warn: false

  require Logger

  alias ReportServer.{AthenaDB, Repo}
  alias ReportServer.Reports
  alias ReportServer.Reports.{AthenaFailure, Report, ReportQuery, ReportRun, Tree}
  alias ReportServer.Reports.Athena.{LearnerData, TeacherActionsReport}

  # The retry window bounds how long a run keeps retrying, not when it answers: a start already
  # underway runs to completion, so clients still need their own timeout. A start can run several
  # portal queries, each allowed 5 minutes (PortalDbs @query_timeout), so a claim older than the
  # abandoned bound belongs to a process that died.
  @retry_window_seconds 10 * 60
  @abandoned_claim_seconds 30 * 60

  @retrying "The report could not be started because of a temporary error; it will be retried."
  @gave_up "The report could not be started because of a temporary error. Duplicate the run to try again."
  @abandoned "The report could not be started; the attempt to start it did not finish."
  @unexpected "An unexpected error occurred while running the report."

  defp athena_db(), do: Application.get_env(:report_server, :athena_db, ReportServer.AthenaDB)
  defp tree(), do: Application.get_env(:report_server, :report_tree, Tree)

  def non_terminal?(%ReportRun{athena_query_state: state}) when state in [nil, "queued", "running"], do: true
  def non_terminal?(_), do: false

  def refresh_query_state(report_run = %ReportRun{athena_query_id: athena_query_id}) when is_binary(athena_query_id) do
    if non_terminal?(report_run) do
      with {:ok, athena_query_state, athena_result_url, athena_query_error} <- athena_db().get_query_info(athena_query_id),
           {:ok, report_run} <- Reports.update_report_run(report_run, %{athena_query_state: athena_query_state, athena_result_url: athena_result_url, athena_query_error: athena_query_error}) do
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
  Brings a run up to date, starting its Athena query when nothing has yet.

  A run is started by claiming it: an atomic write moves it from a null state to `queued` and
  stamps `updated_at`, so only one caller starts it, and that caller's outcome is written only
  while the row still holds that claim.
  """
  def ensure_current(report_run = %ReportRun{id: id, athena_query_id: nil, athena_query_state: nil}) do
    claimed_at = DateTime.utc_now(:second)

    claim = from r in ReportRun,
      where: r.id == ^id,
      where: is_nil(r.athena_query_id) and is_nil(r.athena_query_state)

    case Repo.update_all(claim, set: [athena_query_state: "queued", updated_at: claimed_at]) do
      {1, _} ->
        self_start(%{report_run | athena_query_state: "queued", updated_at: claimed_at})

      _ ->
        %{report_run | athena_query_state: "queued"}
    end
  end
  def ensure_current(report_run = %ReportRun{athena_query_id: nil, athena_query_state: "queued"}) do
    if older_than?(report_run.updated_at, @abandoned_claim_seconds) do
      Logger.error("Report run #{report_run.id} was claimed at #{report_run.updated_at} and never started; failing it")
      record_outcome(report_run, athena_query_state: "failed", athena_query_error: @abandoned)
    else
      report_run
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
        Logger.error("State refresh failed for report run #{report_run.id}: #{inspect(error)}")
        report_run
    end
  end

  defp self_start(report_run) do
    case try_start_query(report_run) do
      {:ok, athena_query_id, athena_query_state} ->
        record_started(report_run, athena_query_id, athena_query_state)

      {:error, :permanent, message} ->
        Logger.error("Starting report run #{report_run.id} failed permanently: #{message}")
        record_outcome(report_run, athena_query_state: "failed", athena_query_error: message)

      {:error, :transient, detail} ->
        record_transient(report_run, detail)
    end
  end

  defp record_started(report_run, athena_query_id, athena_query_state) do
    record_outcome(report_run, athena_query_id: athena_query_id, athena_query_state: athena_query_state, athena_query_error: nil)
  catch
    kind, reason ->
      record_transient(report_run, "storing Athena query #{athena_query_id} failed: " <> Exception.format(kind, reason, __STACKTRACE__))
  end

  defp record_transient(report_run, detail) do
    Logger.error("Starting report run #{report_run.id} failed: #{detail}")

    if older_than?(report_run.inserted_at, @retry_window_seconds) do
      record_outcome(report_run, athena_query_state: "failed", athena_query_error: @gave_up)
    else
      record_outcome(report_run, athena_query_state: nil, athena_query_error: @retrying)
    end
  end

  defp try_start_query(report_run) do
    start_query(report_run)
  catch
    kind, reason ->
      {:error, :transient, Exception.format(kind, reason, __STACKTRACE__)}
  end

  defp start_query(report_run = %ReportRun{}) do
    with {:report, report = %Report{}} <- {:report, tree().find_report(report_run.report_slug)},
         {:query, {:ok, query}} <- {:query, report.get_query.(report_run.report_filter, report_run.user)},
         {:ok, sql} <- ReportQuery.get_sql(query),
         {:athena, {:ok, athena_query_id, athena_query_state}} <- {:athena, athena_db().query(sql, report_run.id, report_run.user)} do
      {:ok, athena_query_id, athena_query_state}
    else
      {:report, nil} ->
        {:error, :permanent, "Unable to find report: #{report_run.report_slug}"}

      {step, {:error, message}} when is_binary(message) ->
        if permanent?(step, message) do
          {:error, :permanent, message}
        else
          {:error, :transient, message}
        end

      {_step, {:error, reason}} ->
        {:error, :transient, inspect(reason)}

      unexpected ->
        Logger.error("Unknown error running Athena report #{report_run.id}: #{inspect(unexpected)}")
        {:error, :permanent, @unexpected}
    end
  end

  defp permanent?(:query, message) do
    message in [
      LearnerData.no_learners_error(),
      ReportQuery.no_filters_error(),
      ReportQuery.no_learners_error(),
      TeacherActionsReport.no_match_error()
    ] or ReportQuery.unknown_app_error?(message)
  end
  defp permanent?(:athena, message), do: message == AthenaDB.query_too_large_error()

  # Written only while the row still holds the claim this outcome belongs to, so a late start can't
  # overwrite a run that has since failed, started or been claimed again.
  defp record_outcome(report_run = %ReportRun{id: id, updated_at: claimed_at}, changes) do
    changes = Keyword.update(changes, :athena_query_error, nil, &AthenaFailure.truncate/1)
    now = DateTime.utc_now(:second)

    still_claimed = from r in ReportRun,
      where: r.id == ^id and is_nil(r.athena_query_id),
      where: r.athena_query_state == "queued" and r.updated_at == ^claimed_at

    case Repo.update_all(still_claimed, set: [{:updated_at, now} | changes]) do
      {1, _} ->
        struct(report_run, [{:updated_at, now} | changes])

      _ ->
        Logger.warning("Report run #{id} changed while it was being started; the start's outcome was not recorded: #{inspect(changes)}")
        current = Repo.get!(ReportRun, id)
        struct(report_run, Map.take(current, [:athena_query_id, :athena_query_state, :athena_query_error, :athena_result_url, :updated_at]))
    end
  end

  defp older_than?(at, seconds), do: DateTime.diff(DateTime.utc_now(), at) > seconds
end
