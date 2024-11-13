defmodule ReportServer.Reports do
  alias ReportServer.Reports.{
    TeacherStatus,
    ResourceMetricsSummary,
    ResourceMetricsDetails
  }

  @root_slug "new-reports"

  defmodule Report do
    defstruct slug: nil, title: nil, subtitle: nil, run: nil, parents: [], path: nil
  end

  defmodule ReportGroup do
    defstruct slug: nil, title: nil, subtitle: nil, children: [], parents: [], path: nil
  end

  def tree() do
    %ReportGroup{slug: @root_slug, title: "Reports", subtitle: "Top Level Reports", children: [
      %ReportGroup{slug: "portal-reports", title: "Portal Reports", subtitle: "Teacher and resource reports", children: [
        TeacherStatus.new(),
        ResourceMetricsSummary.new(),
        ResourceMetricsDetails.new()
      ]},
    ]}
    |> decorate_tree()
  end

  def find(slug) do
    find(slug, tree().children)
  end
  def find(slug, parent) do
    Enum.reduce_while(parent, nil, fn node, _acc ->
      case find_in_node(node, slug) do
        nil -> {:cont, nil}
        found -> {:halt, found}
      end
    end)
  end

  def get_root_path(), do: "/#{@root_slug}"

  def get_parent_path([]), do: ""
  def get_parent_path(parents) do
    slugs = parents
      |> Enum.map(fn {slug, _title, _path} -> slug end)
      |> Enum.join("/")
    "/#{slugs}"
  end

  defp find_in_node(%Report{slug: node_slug} = node, slug) when node_slug == slug, do: node
  defp find_in_node(%ReportGroup{slug: node_slug} = node, slug) when node_slug == slug, do: node
  defp find_in_node(%ReportGroup{children: children}, slug), do: find(slug, children)
  defp find_in_node(_node, _slug), do: nil

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
end
