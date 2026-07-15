defmodule ReportServer.Exports.SweepServer do
  @moduledoc """
  Periodic (+ boot) storage-reclaim sweep for export_scratch. Correctness never depends on the interval —
  expired rows are already invisible via the two-step read-time lookup — so this is a reclaim cadence only.
  Mirrors StatsServer: no DB work in init/1 (the boot sweep runs from handle_continue), and a disabled?/0 gate
  keeps it inert under the :test SQL sandbox (it hits the LOCAL Repo, so it must be gated in tests).
  """
  use GenServer

  require Logger
  alias ReportServer.Exports

  @sweep_interval 15 * 60 * 1000

  # `:name` is injectable so an isolated test can start a SECOND instance under a different name — the
  # supervised singleton owns __MODULE__.
  def start_link(opts), do: GenServer.start_link(__MODULE__, %{}, name: Keyword.get(opts, :name, __MODULE__))

  def disabled?, do: Keyword.get(Application.get_env(:report_server, :exports_sweep, []), :disable, false)

  @impl true
  def init(state) do
    if disabled?() do
      {:ok, state}
    else
      {:ok, state, {:continue, :boot_sweep}}
    end
  end

  @impl true
  def handle_continue(:boot_sweep, state) do
    {:noreply, sweep_and_schedule(state)}
  end

  @impl true
  def handle_info(:sweep, state) do
    {:noreply, sweep_and_schedule(state)}
  end

  defp sweep_and_schedule(state) do
    count = Exports.sweep_expired()
    if count > 0, do: Logger.info("Exports.SweepServer reclaimed #{count} expired scratch row(s)")
    Process.send_after(self(), :sweep, @sweep_interval)
    state
  end
end
