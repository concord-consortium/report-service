defmodule ReportServer.PostProcessing.JobSupervisor do
  use DynamicSupervisor
  alias ReportServer.PostProcessing.JobServer

  def start_link(_) do
    DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def maybe_start_server(query_id, mode) do
    child_spec = %{
      id: query_id,
      start: {JobServer, :start_link, [{query_id, mode}]},
      restart: :temporary,
      shutdown: 0,
      type: :worker,
      modules: [JobServer]
    }
    case DynamicSupervisor.start_child(__MODULE__, child_spec) do
      {:ok, pid} ->
        {:ok, pid}
      {:error, {:already_started, pid}} ->
        {:ok, pid}
      {:error, error} -> {:error, error}
    end
  end
end
