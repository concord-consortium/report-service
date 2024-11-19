defmodule ReportServer.Reports.ReportQuery do
  alias ReportServer.Reports.ReportQuery

  defstruct select: "", from: "", join: [], where: [], group_by: "", order_by: ""

  def get_sql(%ReportQuery{select: select, from: from, join: join, where: where, group_by: group_by, order_by: order_by}) do
    # NOTE: the reverse is before flatten to keep any sublists in order
    join_sql = join |> Enum.reverse() |> List.flatten() |> Enum.join(" ")
    where_sql = where |> Enum.reverse() |> List.flatten() |> Enum.map(&("(#{&1})")) |> Enum.join(" AND ")
    group_by_sql = if String.length(group_by) == 0, do: "", else: "GROUP BY #{group_by}"
    order_by_sql = if String.length(order_by) == 0, do: "", else: "ORDER BY #{order_by}"

    "SELECT #{select} FROM #{from} #{join_sql} WHERE #{where_sql} #{group_by_sql} #{order_by_sql}"
  end

  def update_query(report_query = %ReportQuery{}, opts) do
    join = Keyword.get(opts, :join, [])
    where = Keyword.get(opts, :where, [])

    if Enum.empty?(join) && Enum.empty?(where) do
      # TODO: this should return an error tuple instead
      raise "No way to figure out teacher filter!"
    end

    %{report_query | join: [ join | report_query.join ], where: [ where | report_query.where ]}
  end
end
