defmodule ReportServerWeb.NewReportLive.Form do
  @doc """
  Render the form for a new report.
  May eventually get a different @live_action to show the result of the report.
  """

  use ReportServerWeb, :live_view

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

  def handle_event("download_csv", _unsigned_params, %{assigns: %{results: results}} = socket) do
    # convert results into a stream
    csv = Stream.map(results.rows, &(&1)) |> CSV.encode() |> Enum.to_list()
    Logger.debug("CSV: #{csv}")

    # TODO: not working
    Process.send_after(self(), :clear_flash, 2000)

    # Ask browser to download the file
    # See https://elixirforum.com/t/download-or-export-file-from-phoenix-1-7-liveview/58484/10
    {:noreply,
     socket
     |> put_flash(:info, "Downloading CSV")
     |> push_event("download_csv", %{csv: csv, filename: "report.csv"})
    }
  end

  defp get_report_info(slug, nil) do
    %{title: "Error: #{slug} is not a known report", subtitle: nil}
  end
  defp get_report_info(_slug, report = %Report{}) do
    %{title: report.title, subtitle: report.subtitle}
  end

end
