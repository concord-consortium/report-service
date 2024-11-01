defmodule ReportServerWeb.PageLive.Home do
  use ReportServerWeb, :live_view

  alias ReportServer.Dashboard.StatsServer
  alias ReportServerWeb.Auth

  @impl true
  def mount(_params, session, socket) do
    socket = socket
      |> assign(:page_title, "Home")
      |> assign(Auth.public_session_vars(session))
      |> assign(:stats, StatsServer.get_dashboard_stats())
      |> assign(:stats_disabled, StatsServer.disabled?())

    # listen for the stats server message that the dashboard stats updated
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ReportServer.PubSub, "stats_server")
    end

    {:ok, socket}
  end

  # Handles pubsub messages sent from the stats server
  @impl true
  def handle_info(:dashboard_stats_updated, socket) do
    # Update the LiveView assigns with the new dashboard data
    {:noreply, assign(socket, :stats, StatsServer.get_dashboard_stats())}
  end
end
