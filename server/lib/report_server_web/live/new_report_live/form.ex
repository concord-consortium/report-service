defmodule ReportServerWeb.NewReportLive.Form do
  @doc """
  Render the form for a new report.
  May eventually get a different @live_action to show the result of the report.
  """

  use ReportServerWeb, :live_view

  alias ReportServer.Reports
  alias ReportServer.Reports.Report

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(unsigned_params, _uri, socket) do
    slug = unsigned_params |> Map.get("slug")
    report = slug |> Reports.find()
    title = if report, do: report.title, else: "Error: #{slug} is not a known report"

    socket = socket
    |> assign(:report, report)
    |> assign(:title, title)
    |> assign(:page_title, "Reports: #{title}")
    |> assign(:results, nil)

    {:noreply, socket}
  end

  @impl true
  def handle_event("submit-form", _unsigned_params, %{assigns: %{report: %Report{} = report}} = socket) do
    # when this is real the params would become the filters passed to the report run function
    _results = report.run.([])

    # fake the results for now
    results = "This is where the sortable table would display with the report results along with a download link..."

    socket = socket
      |> assign(:results, results)

    {:noreply, socket}
  end

end
