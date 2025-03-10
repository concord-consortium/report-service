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

  def escape_url_for_filename(url) do
    String.replace(url, ~r/[^a-z0-9]/, "-")
  end

  def ensure_not_empty(list, error_message) when is_list(list) do
    if Enum.empty?(list) do
      {:error, error_message}
    else
      {:ok, list}
    end
  end

  def ensure_not_empty(map, error_message) when is_map(map) do
    if map_size(map) == 0 do
      {:error, error_message}
    else
      {:ok, map}
    end
  end

  def apply_allowed_project_ids_filter(user, join, where, assignment_id_ref, teacher_id_ref) do
    allowed_project_ids = ReportServer.PortalDbs.get_allowed_project_ids(user)
    if allowed_project_ids == :all do
      {join, where}
    else
      {
        [
          "join admin_cohort_items aci_teacher on (aci_teacher.item_type = 'Portal::Teacher' and aci_teacher.item_id = #{teacher_id_ref})",
          "join admin_cohorts ac_teacher ON (ac_teacher.id = aci_teacher.admin_cohort_id)",
          "left join admin_cohort_items aci_assignment on (aci_assignment.item_type = 'ExternalActivity' and aci_assignment.item_id = #{assignment_id_ref})",
          "left join admin_cohorts ac_assignment ON (ac_assignment.id = aci_assignment.admin_cohort_id)",
          "left join admin_project_materials apm ON (apm.material_type = 'ExternalActivity' AND apm.material_id = #{assignment_id_ref})"
          | join
        ],
        [
          "ac_teacher.project_id IN #{list_to_in(allowed_project_ids)}",
          "(ac_assignment.project_id IN #{list_to_in(allowed_project_ids)}) or (apm.project_id IN #{list_to_in(allowed_project_ids)})"
          | where
        ]
      }
    end

  end

end
