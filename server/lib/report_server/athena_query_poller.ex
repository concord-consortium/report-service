defmodule ReportServer.AthenaQueryPoller do
  alias ReportServer.AthenaDB

  @poll_interval 5_000  # 5 seconds

  def wait_for(query_id) do
    task = Task.async(fn -> poll_query_status(query_id) end)
    Task.await(task, :infinity)
  end

  ## Routed through the same seam the rest of the app uses, so a stubbed
  ## AthenaDB is not bypassed here. Without this, swapping :athena_db in a test
  ## intercepts the query but not the poll loop, which then calls out to AWS.
  defp athena_db(), do: Application.get_env(:report_server, :athena_db, AthenaDB)

  defp poll_query_status(query_id) do
    case athena_db().get_query_info(query_id) do
      {:ok, "succeeded", output_location} ->
        {:ok, output_location}
      {:ok, "failed", _output_location} ->
        {:error, "Query failed"}
      {:ok, "cancelled", _output_location} ->
        {:error, "Query cancelled"}
      {:ok, _status, _output_location} ->
        ## Queued or Running
        :timer.sleep(@poll_interval)  # Wait before polling again
        poll_query_status(query_id)
      {:error, reason} ->
        IO.puts("Error fetching query status: #{inspect(reason)}")
        {:error, reason}
    end
  end

end
