defmodule ReportServer.AthenaQueryPoller do
  require Logger

  alias ReportServer.AthenaDB
  alias ReportServer.Reports.AthenaFailure

  @poll_interval 5_000  # 5 seconds

  @doc """
  Polls until the query finishes. `:timeout_ms` bounds the wait, answering `{:error, :timeout}`
  instead of sleeping past it; `:interval_ms` sets the polling interval.
  """
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

  ## Routed through the same seam the rest of the app uses, so a stubbed
  ## AthenaDB is not bypassed here. Without this, swapping :athena_db in a test
  ## intercepts the query but not the poll loop, which then calls out to AWS.
  defp athena_db(), do: Application.get_env(:report_server, :athena_db, AthenaDB)

  defp poll_query_status(query_id, interval, deadline) do
    case athena_db().get_query_info(query_id) do
      {:ok, "succeeded", output_location, _reason} ->
        {:ok, output_location}
      {:ok, "failed", _output_location, reason} ->
        Logger.error("Athena query #{query_id} failed: #{inspect(AthenaFailure.error_code(reason))}")
        {:error, "Query failed"}
      {:ok, "cancelled", _output_location, reason} ->
        Logger.error("Athena query #{query_id} cancelled: #{inspect(AthenaFailure.error_code(reason))}")
        {:error, "Query cancelled"}
      {:ok, _status, _output_location, _reason} ->
        ## Queued or Running
        if deadline != :infinity and System.monotonic_time(:millisecond) + interval > deadline do
          {:error, :timeout}
        else
          :timer.sleep(interval)
          poll_query_status(query_id, interval, deadline)
        end
      {:error, reason} ->
        Logger.error("Error fetching query status: #{inspect(reason)}")
        {:error, reason}
    end
  end

end
