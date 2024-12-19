defmodule ReportServer.Reports.ReportQuery do
  alias ReportServer.Reports.ReportQuery

  defstruct cols: [], from: "", join: [], where: [], group_by: "", order_by: []

  def get_sql(%ReportQuery{cols: cols, from: from, join: join, where: where, group_by: group_by, order_by: order_by}, limit \\ nil) do
    select_sql = cols |> Enum.map(fn {col, alias} -> "#{col} AS #{alias}" end) |> Enum.join(", ")
    # NOTE: the reverse is before flatten to keep any sublists in order
    join_sql = join |> Enum.reverse() |> List.flatten() |> Enum.join(" ")
    where_sql = where |> Enum.reverse() |> List.flatten() |> Enum.map(&("(#{&1})")) |> Enum.join(" AND ")
    where_sql = if String.length(where_sql) != 0, do: "WHERE #{where_sql}", else: ""
    group_by_sql = if String.length(group_by) != 0, do: "GROUP BY #{group_by}", else: ""
    order_by_sql = if !Enum.empty?(order_by) do
       "ORDER BY " <> (order_by |> Enum.map(fn {col, dir} -> "#{col} #{Atom.to_string(dir)}" end) |> Enum.join(", "))
    else
      ""
    end
    limit_sql = if limit != nil, do: "LIMIT #{limit}", else: ""

    {:ok, "SELECT #{select_sql} FROM #{from} #{join_sql} #{where_sql} #{group_by_sql} #{order_by_sql} #{limit_sql}"}
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
      |> Enum.map(&(to_tuple("log", &1)))
      |> Enum.filter(&(!(is_username?(&1) && remove_username)))
      |> Enum.map(&(hash_username(&1, hide_names)))
  end

  def get_learner_cols(opts \\ []) do
    hide_names = Keyword.get(opts, :hide_names, false)

    ["learner_id", "run_remote_endpoint", "class_id", "runnable_url", "student_id", "class", "school", "user_id", "offering_id", "permission_forms", "username", "student_name", "teachers", "last_run", "query_id"]
      |> Enum.map(&(to_tuple("learner", &1)))
      |> Enum.map(&(hash_username(&1, hide_names)))
      |> Enum.map(&(hide_learner_student_name(&1, hide_names)))
  end

  def get_log_db_name() do
    Application.get_env(:report_server, :athena) |> Keyword.get(:log_db_name, "log_ingester_production")
  end

  def to_tuple(table, col), do: {"\"#{table}\".\"#{col}\"", col}

  defp is_username?({_, "username"}), do: true
  defp is_username?({_, _}), do: false

  # When the second parameter is true this hides the username to prevent PII from being exposed by hashing it concated with a secret salt.
  # (note: the || operator is used to concat strings by Athena)
  defp hash_username({table_and_col, col = "username"}, true) do
    hide_username_hash_salt = Application.get_env(:report_server, :athena) |> Keyword.get(:hide_username_hash_salt, "no-hide-username-salt-provided!!!");
    {"TO_HEX(SHA1(CAST(('#{hide_username_hash_salt}' || #{table_and_col}) AS VARBINARY)))", col}
  end
  defp hash_username(tuple, _), do: tuple

  # when the second parameter is true this hides the student name to prevent PII from being exposed by replacing it with the student_id when keeping the column name as student_name.
  defp hide_learner_student_name({_, "student_name"}, true) do
    {"\"learner\".\"student_id\"", "student_name"}
  end
  defp hide_learner_student_name(tuple, _), do: tuple
end
