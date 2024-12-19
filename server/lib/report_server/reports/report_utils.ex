defmodule ReportServer.Reports.ReportUtils do
  def list_to_in(nil), do: "()"
  def list_to_in(list) do
    "(#{list |> Enum.map(&Integer.to_string/1) |> Enum.join(",")})"
  end

  def numeric_string_list_to_in(nil), do: "()"
  def numeric_string_list_to_in(list) do
    "(#{list |> Enum.join(",")})"
  end

  def string_list_to_single_quoted_in(nil), do: "()"
  def string_list_to_single_quoted_in(list) do
    "(#{list |> Enum.map(&("'#{escape_single_quote(&1)}'")) |> Enum.join(",")})"
  end

  def have_filter?(nil), do: false
  def have_filter?(filter_list), do: !Enum.empty?(filter_list)

  def exclude_internal_accounts(where, false), do: where
  def exclude_internal_accounts(where, true) do
    [ "u.email NOT LIKE '%@concord.org'" | where ]
  end

  def apply_start_date(where, start_date, table_name \\ "run") do
    if String.length(start_date || "") > 0 do
      ["#{table_name}.start_time >= '#{start_date}'" | where]
    else
      where
    end
  end

  def apply_end_date(where, end_date, table_name \\ "run") do
    if String.length(end_date || "") > 0 do
      ["#{table_name}.start_time <= '#{end_date}'" | where]
    else
      where
    end
  end

  def apply_where_filter(where, filter, additional_where) do
    if have_filter?(filter) do
      [additional_where | where]
    else
      where
    end
  end

  def apply_log_start_date(where, start_date, table_name \\ "log") do
    apply_log_date(where, start_date, ">=", table_name)
  end

  def apply_log_end_date(where, end_date, table_name \\ "log") do
    apply_log_date(where, end_date, "<=", table_name)
  end

  def apply_log_date(where, log_date, cmp, table_name \\ "log")
  def apply_log_date(where, nil, _cmp, _table_name), do: where
  def apply_log_date(where, "", _cmp, _table_name), do: where

  def apply_log_date(where, log_date, cmp, table_name) do
    [year, month, day] = String.split(log_date, "-")
    iso_date = "#{year}-#{month}-#{day}T00:00:00Z"

    case DateTime.from_iso8601(iso_date) do
      {:ok, datetime, _} ->
        time = DateTime.to_unix(datetime)
        ["#{table_name}.time #{cmp} #{time}" | where]

      {:error, _} ->
        where
    end
  end

  def escape_single_quote(str) do
    String.replace(str, "'", "''")
  end
end
