defmodule ReportServerWeb.NewReportLive.Form do
  @doc """
  Render the form for a new report.
  May eventually get a different @live_action to show the result of the report.
  """

  use ReportServerWeb, :live_view
  alias Jason
  alias ReportServer.PortalDbs
  alias ReportServer.Reports
  alias ReportServer.Reports.Report
  require Logger

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

  def handle_event("sort_column", %{"column" => column}, %{assigns: %{results: results}} = socket) do
    results = PortalDbs.sort_results(results, column)
    {:noreply, assign(socket, :results, results)}
  end

  def handle_event("download_report", %{"filetype" => filetype}, %{assigns: %{results: results}} = socket) do
    case format_results(results, String.to_atom(filetype)) do
      {:ok, data} ->
      file_extension = String.downcase(filetype)
      # Ask browser to download the file
      # See https://elixirforum.com/t/download-or-export-file-from-phoenix-1-7-liveview/58484/10
      {:noreply, request_download(socket, data, "report.#{file_extension}")}

      {:error, error} ->
      socket = put_flash(socket, :error, "Failed to format results: #{error}")
      {:noreply, socket}
    end
  end

  def request_download(socket, data, filename) do
    socket
    |> push_event("download_report", %{data: data, filename: filename}) # TODO: more informative filename
  end

  def format_results(results, :CSV) do
    csv = results
      |> PortalDbs.map_columns_on_rows()
      |> tap(&IO.inspect(&1))
      |> Stream.map(&(&1))
      |> CSV.encode(headers: results.columns |> Enum.map(&String.to_atom/1), delimiter: "\n")
      |> Enum.to_list()
      |> Enum.join("")
    {:ok, csv}
  end

  def format_results(results, :JSON) do
    results
      |> PortalDbs.map_columns_on_rows()
      |> Jason.encode()
  end

  defp get_report_info(slug, nil) do
    %{title: "Error: #{slug} is not a known report", subtitle: nil}
  end
  defp get_report_info(_slug, report = %Report{}) do
    %{title: report.title, subtitle: report.subtitle}
  end

end
