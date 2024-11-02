defmodule ReportServerWeb.NewReportLive.Form do
  @doc """
  Render the form for a new report.
  May eventually get a different @live_action to show the result of the report.
  """

  use ReportServerWeb, :live_view

  @known_reports ["one", "two"]

  @impl true
  def mount(_params, _session, socket) do
    socket = socket
      |> assign(:page_title, "Report Form")

    {:ok, socket}
  end

  @impl true
  def handle_params(unsigned_params, _uri, socket) do
    report = Map.get(unsigned_params, "report")

    socket = socket
      |> assign(:report, report)
      |> assign(:known_report, report in @known_reports)

    {:noreply, socket}
  end

end
