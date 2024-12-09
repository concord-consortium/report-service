defmodule ReportServer.Reports.ReportQuery do
  alias ReportServer.Reports.ReportQuery

  defstruct cols: [], from: "", join: [], where: [], group_by: "", order_by: []

  def get_sql(%ReportQuery{cols: cols, from: from, join: join, where: where, group_by: group_by, order_by: order_by}, limit \\ nil) do
    select_sql = cols |> Enum.map(fn {col, alias} -> "#{col} AS #{alias}" end) |> Enum.join(", ")
    # NOTE: the reverse is before flatten to keep any sublists in order
    join_sql = join |> Enum.reverse() |> List.flatten() |> Enum.join(" ")
    where_sql = where |> Enum.reverse() |> List.flatten() |> Enum.map(&("(#{&1})")) |> Enum.join(" AND ")
    group_by_sql = if String.length(group_by) != 0, do: "GROUP BY #{group_by}", else: ""
    order_by_sql = if !Enum.empty?(order_by) do
       "ORDER BY " <> (order_by |> Enum.map(fn {col, dir} -> "#{col} #{Atom.to_string(dir)}" end) |> Enum.join(", "))
    else
      ""
    end
    limit_sql = if limit != nil, do: "LIMIT #{limit}", else: ""

    {:ok, "SELECT #{select_sql} FROM #{from} #{join_sql} WHERE #{where_sql} #{group_by_sql} #{order_by_sql} #{limit_sql}"}
  end

  def get_count_sql(%ReportQuery{from: from, join: join, where: where, group_by: group_by}) do
    query_without_cols_or_order = %ReportQuery{cols: [{"1", "row"}], from: from, join: join, where: where, group_by: group_by}
    {:ok, subquery} = get_sql(query_without_cols_or_order)

    {:ok, "SELECT COUNT(*) AS count FROM (#{subquery}) AS subquery"}
  end

  def update_query(report_query = %ReportQuery{}, opts) do
    join = Keyword.get(opts, :join, [])
    where = Keyword.get(opts, :where, [])

    # Must have some filters in order to be valid
    if Enum.empty?(join) && Enum.empty?(where) do
      {:error, "Cannot run query with no filters"}
    else
      {:ok, %{report_query | join: [ join | report_query.join ], where: [ where | report_query.where ]}}
    end
  end

  # Order_by is a list of tuples, where the first element is the column name and the second is the direction.
  # This removes any duplicate columns from the list, maintaining the order of the first occurrence.
  def uniq_order_by(order_by) do
    order_by |> Enum.uniq_by(fn {col, _dir} -> col end)
  end

  # Prepend the given column indexes to the list of order_by columns.
  # Previous sorts are maintained in order, but duplicates are removed.
  def add_sort_columns(report_query = %ReportQuery{order_by: order_by}, cols) do
    new_order_by = cols ++ order_by |> uniq_order_by()
    %{report_query | order_by: new_order_by}
  end

  def get_log_cols(opts \\ []) do
    hide_names = Keyword.get(opts, :hide_names, false)
    remove_username = Keyword.get(opts, :remove_username, false)

    ["id", "session", "username", "application", "activity", "event", "event_value", "time", "parameters", "extras", "run_remote_endpoint", "timestamp"]
      |> Enum.filter(&(!(&1 == "username" && remove_username)))
      |> Enum.map(&(maybe_hash_username(&1 == "username" && hide_names, &1)))
  end

  def get_log_db_name() do
    Application.get_env(:report_server, :athena) |> Keyword.get(:log_db_name, "log_ingester_production")
  end

  defp maybe_hash_username(hash, col) do
    if hash do
      hide_username_hash_salt = Application.get_env(:report_server, :athena) |> Keyword.get(:hide_username_hash_salt, "no-hide-username-salt-provided!!!");
      {"TO_HEX(SHA1(CAST(('#{hide_username_hash_salt}' || \"log\".#{col}) AS VARBINARY)))", col}
    else
      {"\"log\".\"#{col}\"", col}
    end
  end
end
