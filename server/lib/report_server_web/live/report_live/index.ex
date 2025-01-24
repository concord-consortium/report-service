defmodule ReportServerWeb.ReportLive.Index do
  use ReportServerWeb, :live_view

  alias ReportServer.Reports
  alias ReportServer.Reports.Tree
  alias ReportServer.Reports.Tree.ReportGroup

  @impl true
  def mount(%{"path" => path}, _session, socket) do
    report_group = Tree.find_report_group(path)

    socket = socket
      |> assign(:root_path, Reports.get_root_path())
      |> assign(:report_group, report_group)
      |> assign(:page_title, get_page_title(report_group))
      |> assign(:is_root, length(path) == 0)

    {:ok, socket}
  end

  defp get_page_title(nil), do: "Reports"
  defp get_page_title(%ReportGroup{title: title, parents: []}), do: title
  defp get_page_title(%ReportGroup{title: title, parents: parents}) do
    prefix = parents
      |> Enum.map(fn {_slug, title, _path} -> title end)
      |> Enum.join(": ")

    "#{prefix}: #{title}"
  end

end
