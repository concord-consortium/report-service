defmodule ReportServerWeb.NewReportLive.Index do
  use ReportServerWeb, :live_view

  alias ReportServer.Reports

  @impl true
  def mount(_params, _session, socket) do
    socket = socket
      |> assign(:page_title, "New Reports")
      |> assign(:reports, Reports.list())

    {:ok, socket}
  end

end
