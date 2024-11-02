defmodule ReportServerWeb.NewReportLive.Index do
  use ReportServerWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    socket = socket
      |> assign(:page_title, "New Reports")

    {:ok, socket}
  end

end
