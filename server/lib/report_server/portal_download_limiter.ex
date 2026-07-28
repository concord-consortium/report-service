defmodule ReportServer.PortalDownloadLimiter do
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Returns :ok if a slot was acquired (auto-released when the caller dies), or :full."
  def try_acquire(server \\ __MODULE__), do: GenServer.call(server, :try_acquire)

  def release(server \\ __MODULE__), do: GenServer.cast(server, {:release, self()})

  @impl true
  def init(opts) do
    {:ok, %{cap: Keyword.fetch!(opts, :cap), holders: %{}}}
  end

  @impl true
  def handle_call(:try_acquire, {from_pid, _}, %{cap: cap, holders: holders} = state) do
    if map_size(holders) >= cap do
      {:reply, :full, state}
    else
      ref = Process.monitor(from_pid)
      {:reply, :ok, %{state | holders: Map.put(holders, from_pid, ref)}}
    end
  end

  @impl true
  def handle_cast({:release, pid}, state), do: {:noreply, drop(state, pid)}

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state), do: {:noreply, drop(state, pid)}

  defp drop(%{holders: holders} = state, pid) do
    case Map.pop(holders, pid) do
      {nil, _} -> state
      {ref, rest} -> Process.demonitor(ref, [:flush]); %{state | holders: rest}
    end
  end
end
