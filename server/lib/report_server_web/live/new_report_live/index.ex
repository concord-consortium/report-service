defmodule ReportServerWeb.NewReportLive.Index do
  use ReportServerWeb, :live_view

  alias ReportServer.Reports
  alias ReportServer.Reports.ReportGroup

  @impl true
  def mount(%{"path" => path}, _session, socket) do
    report_group = get_report_group(path)

    socket = socket
      |> assign(:root_path, Reports.get_root_path())
      |> assign(:report_group, report_group)
      |> assign(:page_title, get_page_title(report_group))

    {:ok, socket}
  end

  defp get_report_group([]), do: Reports.tree()
  defp get_report_group(path) do
    slug = List.last(path)
    case Reports.find(slug) do
      report_group = %ReportGroup{} -> report_group
      _ -> nil
    end
  end

  defp get_page_title(nil), do: "Reports"
  defp get_page_title(%ReportGroup{title: title, parents: []}), do: title
  defp get_page_title(%ReportGroup{title: title, parents: parents}) do
    prefix = parents
      |> Enum.map(fn {slug, title, path} -> title end)
      |> Enum.join(": ")

    "#{prefix}: #{title}"
  end

end
