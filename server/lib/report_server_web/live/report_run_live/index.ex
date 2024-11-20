defmodule ReportServerWeb.ReportRunLive.Index do
  use ReportServerWeb, :live_view

  require Logger

  alias ReportServer.Reports

  @impl true
  def mount(_params, _session, %{assigns: %{user: user}} = socket) do
    {report_runs, page_title} = if user.portal_is_admin do
      {Reports.list_all_report_runs(), "All Runs"}
    else
      {Reports.list_user_report_runs(user), "Your Runs"}
    end

    socket = socket
      |> assign(:report_runs, report_runs)
      |> assign(:page_title, page_title)

    {:ok, socket}
  end

end
