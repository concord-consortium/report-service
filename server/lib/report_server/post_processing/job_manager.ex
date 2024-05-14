defmodule ReportServer.PostProcessing.JobManager do
  alias ReportServer.PostProcessing.JobServer

  def maybe_start_server(query_id, mode) do
    case JobServer.start_link(query_id, mode) do
      {:ok, pid} ->
        {:ok, pid}
      {:error, {:already_started, pid}} ->
        {:ok, pid}
      {:error, error} -> {:error, error}
    end
  end
end
