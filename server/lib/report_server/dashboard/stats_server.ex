defmodule ReportServer.Dashboard.StatsServer do
  use GenServer

  alias ReportServer.PortalDbs

  @query_interval 60 * 1000 # 1 minute

  # Define a struct to represent the server stats
  defmodule DashboardStats do
    defstruct num_students: 0, num_teachers: 0, num_classes: 0, num_activities: 0, num_offerings: 0
  end

  # public api

  def start_link(servers) when is_list(servers) do
    GenServer.start_link(__MODULE__, {servers}, name: __MODULE__)
  end

  def get_dashboard_stats do
    GenServer.call(__MODULE__, :get_dashboard_stats)
  end

  # genserver callbacks

  @impl true
  def init({servers}) do
    # Initialize state with empty data for each server
    initial_state = Enum.into(servers, %{}, fn server -> {server, %DashboardStats{}} end)

    # return immediately and handle the rest of the (potentially long running) startup
    # in the handle_continue handler
    {:ok, initial_state, {:continue, :query_and_schedule_next}}
  end

  # called via {:continue, :query_and_schedule_next} in init/1
  @impl true
  def handle_continue(:query_and_schedule_next, state) do
    new_state = query_and_schedule_next(state)
    {:noreply, new_state}
  end

  # called via Process.send_after/3 in query_and_schedule_next/1
  @impl true
  def handle_info(:query_and_schedule_next, state) do
    new_state = query_and_schedule_next(state)
    {:noreply, new_state}
  end

  # called via get_dashboard_stats/1
  @impl true
  def handle_call(:get_dashboard_stats, _from, state) do
    {:reply, state, state}
  end

  # private helper functions

  defp query_and_schedule_next(state) do
    # do the queries
    new_state = perform_queries(state)

    # inform any connected live views that there is new data
    Phoenix.PubSub.broadcast(ReportServer.PubSub, "stats_server", :dashboard_stats_updated)

    # Schedule the next run
    Process.send_after(self(), :query_and_schedule_next, @query_interval)

    new_state
  end

  # performs the same query over each server
  defp perform_queries(state) do
    Enum.reduce(Map.keys(state), state, fn server, acc ->
      result = perform_query(server)
      Map.put(acc, server, result)
    end)
  end

  # Placeholder for querying a remote database for a specific server
  defp perform_query(server) do
    query = """
    SELECT
      (SELECT COUNT(DISTINCT user_id) FROM portal_students) AS num_students,
      (SELECT COUNT(DISTINCT user_id) FROM portal_teachers) AS num_teachers,
      (SELECT COUNT(*) FROM portal_clazzes) AS num_classes,
      (SELECT COUNT(*) FROM external_activities) AS num_activities,
      (SELECT COUNT(*) FROM portal_offerings) AS num_offerings
    """

    case PortalDbs.query(server, query) do
      {:ok, rows} ->
        struct(DashboardStats, hd(rows))

      {:error, _} ->
        %DashboardStats{}
    end
  end
end
