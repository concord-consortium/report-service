defmodule ReportServer.Reports.ReportFilter do
  require Logger

  alias ReportServer.Accounts.User
  alias ReportServer.PortalDbs
  alias ReportServer.Reports.ReportFilter

  defstruct filters: [], cohort: nil, school: nil, teacher: nil, assignment: nil, class: nil, student: nil,
    permission_form: nil, country: nil, state: nil, subject_area: nil, start_date: nil, end_date: nil,
    hide_names: false, exclude_internal: false

  @valid_filter_types ~w"cohort school teacher assignment class student permission_form country state subject_area"
  @filter_type_atoms Enum.map(@valid_filter_types, &String.to_atom/1)

  def from_form(form, filter_index) do
    if (filter_index < 1) do
      %ReportFilter{}
    else
      Enum.reduce(1..filter_index, %ReportFilter{}, fn i, acc ->
        filter_type = get_filter_type!(form, i)
        filter_value = get_filter_value(form, i)
        if filter_type do
          acc
          |> Map.put(filter_type, filter_value)
          |> Map.put(:filters, [filter_type | acc.filters])
        else
          acc
        end
      end)
      # NOTE: we do not reverse the filters as they need to be processed from right to left
    end
    |> Map.put(:start_date, form.params["start_date"])
    |> Map.put(:end_date, form.params["end_date"])
    |> Map.put(:hide_names, form.params["hide_names"] == "true")
    |> Map.put(:exclude_internal, form.params["exclude_internal"] == "true")
  end

  def get_filter_values(report_filter = %ReportFilter{}, user = %User{}) do
    sql = Enum.reduce(@filter_type_atoms, [], fn filter_type, acc ->
      ids = Map.get(report_filter, filter_type) || []
      if length(ids) > 0 do
        in_ids = Enum.join(ids, ",")
        case filter_type do
          :cohort ->
            ["SELECT 'cohort' AS table_name, id, TRIM(name) as name FROM admin_cohorts WHERE id IN (#{in_ids})" | acc]
          :school ->
            ["SELECT 'school' AS table_name, id, TRIM(name) as name FROM portal_schools WHERE id IN (#{in_ids})" | acc]
          :teacher ->
            ["SELECT 'teacher' AS table_name, pt.id, CONCAT(TRIM(u.first_name), ' ', TRIM(u.last_name), ' <', TRIM(u.email), '>') AS name FROM portal_teachers pt join users u on (u.id = pt.user_id) WHERE pt.id IN (#{in_ids})" | acc]
          :assignment ->
            ["SELECT 'assignment' AS table_name, id, TRIM(name) as name FROM external_activities WHERE id IN (#{in_ids})" | acc]
          :permission_form ->
            ["SELECT 'permission_form' AS table_name, ppf.id, CONCAT(TRIM(ap.name), ': ', TRIM(ppf.name)) as name FROM portal_permission_forms ppf JOIN admin_projects ap ON ap.id = ppf.project_id WHERE ppf.id IN (#{in_ids})" | acc]
          :class ->
            ["SELECT 'class' AS table_name, pc.id, CONCAT(TRIM(pc.name), ' (', TRIM(pc.class_word), ')') as name FROM portal_clazzes pc WHERE pc.id IN (#{in_ids})" | acc]
          :student ->
            if report_filter.hide_names do
              ["SELECT 'student' AS table_name, ps.id, CAST(u.id AS CHAR) AS name FROM portal_students ps join users u on (u.id = ps.user_id) WHERE ps.id IN (#{in_ids})" | acc]
            else
              ["SELECT 'student' AS table_name, ps.id, CONCAT(TRIM(u.first_name), ' ', TRIM(u.last_name), ' <', TRIM(u.id), '>') AS name FROM portal_students ps join users u on (u.id = ps.user_id) WHERE ps.id IN (#{in_ids})" | acc]
            end
          :country ->
            ["SELECT 'country' AS table_name, id, TRIM(name) as name FROM portal_countries WHERE id IN (#{in_ids})" | acc]
          :state ->
            ["SELECT 'state' AS table_name, TRIM(state) as id, TRIM(state) as name FROM portal_schools WHERE state IN (#{Enum.map(ids, fn id -> "'#{id}'" end) |> Enum.join(",")}) GROUP BY state" | acc]
          :subject_area ->
            ["SELECT 'subject_area' AS table_name, id, TRIM(tag) as name FROM admin_tags WHERE scope = 'subject_areas' AND id IN (#{in_ids})" | acc]
        end
      else
        acc
      end
    end)
    |> Enum.join("\nUNION ALL\n")

    case PortalDbs.query(user.portal_server, sql) do
      {:ok, results} ->
        results.rows
        |> Enum.group_by(fn [table_name, _id, _name] -> table_name end)
        |> Enum.into(%{}, fn {table_name, entries} ->
          {
            String.to_atom(table_name),
            Enum.into(entries, %{}, fn [_table_name, id, name] -> {id, name} end)
          }
        end)

      {:error, error} ->
        Logger.error(error)
        %{}
    end
  end

  defp get_filter_type!(form, i) do
    filter_type = form.params["filter#{i}_type"]
    cond do
      filter_type == "" -> nil
      Enum.member?(@valid_filter_types, filter_type) ->
        String.to_atom(filter_type)
      true -> raise "Invalid filter type: #{filter_type}"
    end
  end

  defp get_filter_value(form, i) do
    filter_type = get_filter_type!(form, i)
    values = form.params["filter#{i}"] || []

    # State filter uses string values (e.g., "CA", "NY"), all others use integer IDs
    case filter_type do
      :state -> values
      _ -> Enum.map(values, &String.to_integer/1)
    end
  end
end
