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
    %{title: title, subtitle: subtitle} = get_report_info(slug, report)

    socket = socket
    |> assign(:report, report)
    |> assign(:title, title)
    |> assign(:subtitle, subtitle)
    |> assign(:page_title, "Reports: #{title}")
    |> assign(:results, nil)
    |> assign(:error, nil)

    {:noreply, socket}
  end

  @impl true
  def handle_event("submit-form", _unsigned_params, %{assigns: %{report: %Report{} = report}} = socket) do
    # when this is real the params would become the filters passed to the report run function
    socket = case report.run.([]) do
      {:ok, results} ->
        socket
        |> assign(:results, results)
        |> assign(:error, nil)

      {:error, error} ->
        socket
        |> assign(:results, nil)
        |> assign(:error, error)
    end

    {:noreply, socket}
  end

  defp get_report_info(slug, nil) do
    %{title: "Error: #{slug} is not a known report", subtitle: nil}
  end
  defp get_report_info(_slug, report = %Report{}) do
    %{title: report.title, subtitle: report.subtitle}
  end

end
