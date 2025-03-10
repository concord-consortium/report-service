defmodule ReportServer.AthenaQueryPoller do
  alias ReportServer.AthenaDB

  @poll_interval 5_000  # 5 seconds

  def wait_for(query_id) do
    task = Task.async(fn -> poll_query_status(query_id) end)
    Task.await(task, :infinity)
  end

  defp poll_query_status(query_id) do
    case AthenaDB.get_query_info(query_id) do
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
