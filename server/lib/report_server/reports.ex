defmodule ReportServer.Reports do
  alias ReportServer.Reports.{
    TeacherStatus,
    ResourceMetricsSummary,
    ResourceMetricsDetails
  }

  @tree_cache :tree_cache
  @root_slug "new-reports"

  defmodule Report do
    defstruct slug: nil, title: nil, subtitle: nil, run: nil, parents: [], path: nil
  end

  defmodule ReportGroup do
    defstruct slug: nil, title: nil, subtitle: nil, children: [], parents: [], path: nil
  end

  # Initialize the ETS table with the report tree, called at application start
  def init do
    :ets.new(@tree_cache, [:named_table, :set, :public, read_concurrency: true])

    %ReportGroup{slug: @root_slug, title: "Reports", subtitle: "Top Level Reports", children: [
      %ReportGroup{slug: "portal-reports", title: "Portal Reports", subtitle: "Teacher and resource reports", children: [
        TeacherStatus.new(%Report{
          slug: "teacher-status",
          title: "Teacher Status",
          subtitle: "Teacher status report"
        }),
        ResourceMetricsSummary.new(%Report{
          slug: "resource-metrics-summary",
          title: "Resource Metrics Summary",
          subtitle: "Summary report on resource metrics"
        }),
        ResourceMetricsDetails.new(%Report{
          slug: "resource-metrics-details",
          title: "Resource Metrics Details",
          subtitle: "Detail report on resource metrics"}
        )
      ]},
    ]}
    |> decorate_tree()
    |> add_to_cache()
  end

  def tree(), do: find(@root_slug)

  def find(slug) do
    case :ets.lookup(@tree_cache, slug) do
      [{^slug, value}] -> value
      [] -> :nil
    end
  end

  def get_root_path(), do: "/#{@root_slug}"

  defp decorate_tree(root) do
    decorate_tree(root, [])
  end
  defp decorate_tree(node = %ReportGroup{}, parents) do
    children = parents ++ [{node.slug, node.title, get_parent_path(parents ++ [{node.slug, node.title, ""}])}]
    %{node | parents: parents, path: "#{get_parent_path(parents)}/#{node.slug}", children: Enum.map(node.children, &(decorate_tree(&1, children)))}
  end
  defp decorate_tree(node = %Report{}, parents) do
    %{node | parents: parents, path: "#{get_root_path()}/new/#{node.slug}"}
  end

  defp get_parent_path([]), do: ""
  defp get_parent_path(parents) do
    slugs = parents
      |> Enum.map(fn {slug, _title, _path} -> slug end)
      |> Enum.join("/")
    "/#{slugs}"
  end

  defp add_to_cache(%Report{} = node), do: :ets.insert(@tree_cache, {node.slug, node})
  defp add_to_cache(%ReportGroup{} = node) do
    :ets.insert(@tree_cache, {node.slug, node})
    Enum.each(node.children, &add_to_cache/1)
  end
end
