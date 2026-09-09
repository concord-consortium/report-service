defmodule ReportServer.Reports.ReportFilter do
  import ReportServer.Reports.ReportUtils, only: [list_to_in: 1, mysql_string_list_to_in: 1]

  alias ReportServer.Accounts.User
  alias ReportServer.PortalDbs
  alias ReportServer.Reports.{DimensionScope, FilterOptions, ReportFilter}

  defstruct filters: [], cohort: nil, school: nil, teacher: nil, assignment: nil, class: nil, student: nil,
    permission_form: nil, country: nil, state: nil, subject_area: nil, start_date: nil, end_date: nil,
    hide_names: false, exclude_internal: false, app: nil

  @valid_filter_types ~w"cohort school teacher assignment class student permission_form country state subject_area"
  @filter_type_atoms Enum.map(@valid_filter_types, &String.to_atom/1)

  @doc "The portal-backed filter dimensions, in declaration order."
  def dimensions, do: @filter_type_atoms

  @doc """
  Resolves a caller-supplied dimension name against the allowlist.

  The allowlist is what makes the `String.to_atom/1` safe: atoms are never garbage collected, so
  converting caller-supplied strings without one is an exhaustion vector.
  """
  def dimension_from_string(raw) when is_binary(raw) do
    if raw in @valid_filter_types, do: {:ok, String.to_atom(raw)}, else: :error
  end

  def dimension_from_string(_raw), do: :error

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
    |> Map.put(:app, form.params["app"])
  end

  @doc """
  The selected applications as a list, empty when the filter is unset.

  The application control submits a list, no key at all when nothing is chosen, and a bare string
  only for a run stored before the filter accepted more than one.
  """
  def app_list(nil), do: []
  def app_list(""), do: []
  def app_list(app) when is_binary(app), do: [app]
  def app_list(apps) when is_list(apps), do: Enum.reject(apps, &(&1 == ""))

  @doc """
  The display labels for the ids a filter names, keyed by dimension.

  `{:ok, %{}}` is a filter with no ids to resolve, which is a legitimate run: a log report can be
  filtered by application and a date range alone. `{:error, :out_of_scope, missing}` names the
  dimensions and ids that did not resolve, which for the seven scoped dimensions means the caller
  cannot see them.
  """
  def get_filter_values(report_filter = %ReportFilter{}, user = %User{}) do
    case selected_dimensions(report_filter) do
      [] -> {:ok, %{}}
      dimensions -> resolve_values(dimensions, report_filter, user)
    end
  end

  defp selected_dimensions(report_filter) do
    Enum.filter(@filter_type_atoms, fn dimension ->
      case Map.get(report_filter, dimension) do
        ids when is_list(ids) -> ids != []
        _ -> false
      end
    end)
  end

  defp resolve_values(dimensions, report_filter, user) do
    allowed = FilterOptions.allowed_projects(user)

    sql =
      dimensions
      |> Enum.map(&value_select(&1, report_filter, allowed))
      |> Enum.join("\nUNION ALL\n")

    with {:ok, results} <- PortalDbs.query(user.portal_server, sql),
         values = group_values(results),
         [] <- unresolved(dimensions, report_filter, values) do
      {:ok, values}
    else
      {:error, error} -> {:error, error}
      missing when is_list(missing) -> {:error, :out_of_scope, missing}
    end
  end

  # DISTINCT because the scope joins fan an entity out by every teacher and cohort that reaches it.
  defp value_select(dimension, report_filter, allowed) do
    id_expr = DimensionScope.id_expr(dimension)
    {scope_join, scope_where} = scope_parts(dimension, allowed)
    join = Enum.join(DimensionScope.join(dimension) ++ scope_join, " ")
    ids = Map.get(report_filter, dimension)

    where =
      [["#{id_expr} IN #{id_list(dimension, ids)}"], DimensionScope.where(dimension), scope_where]
      |> List.flatten()
      |> Enum.map_join(" AND ", &"(#{&1})")

    "SELECT DISTINCT '#{dimension}' AS table_name, #{id_expr} AS id, " <>
      "#{label_expr(dimension, report_filter)} AS name " <>
      "FROM #{DimensionScope.from(dimension)} #{join} WHERE #{where}"
  end

  defp scope_parts(dimension, allowed) do
    case DimensionScope.scope(dimension, allowed) do
      :none -> {[], []}
      restriction -> restriction
    end
  end

  defp id_list(dimension, ids) do
    case DimensionScope.id_type(dimension) do
      :string -> mysql_string_list_to_in(ids)
      :integer -> list_to_in(ids)
    end
  end

  defp label_expr(:cohort, _report_filter), do: "TRIM(admin_cohorts.name)"
  defp label_expr(:school, _report_filter), do: "TRIM(portal_schools.name)"
  defp label_expr(:assignment, _report_filter), do: "TRIM(external_activities.name)"
  defp label_expr(:country, _report_filter), do: "TRIM(portal_countries.name)"
  defp label_expr(:subject_area, _report_filter), do: "TRIM(admin_tags.tag)"
  defp label_expr(:class, _report_filter), do: "CONCAT(TRIM(pc.name), ' (', TRIM(pc.class_word), ')')"
  defp label_expr(:permission_form, _report_filter), do: "CONCAT(TRIM(ap.name), ': ', TRIM(ppf.name))"
  defp label_expr(:state, _report_filter), do: DimensionScope.id_expr(:state)

  defp label_expr(:teacher, _report_filter),
    do: "CONCAT(TRIM(u.first_name), ' ', TRIM(u.last_name), ' <', TRIM(u.email), '>')"

  defp label_expr(:student, %ReportFilter{hide_names: true}), do: "CAST(u.id AS CHAR)"

  defp label_expr(:student, _report_filter),
    do: "CONCAT(TRIM(u.first_name), ' ', TRIM(u.last_name), ' <', TRIM(u.id), '>')"

  # MySQL widens the union's id column to a string as soon as one branch selects one, so the key
  # type is fixed here rather than left to which dimensions the filter happens to name.
  defp group_values(results) do
    results.rows
    |> Enum.group_by(fn [table_name, _id, _name] -> table_name end)
    |> Enum.into(%{}, fn {table_name, entries} ->
      dimension = String.to_existing_atom(table_name)

      {dimension, Enum.into(entries, %{}, fn [_table_name, id, name] -> {cast_id(dimension, id), name} end)}
    end)
  end

  defp cast_id(dimension, id), do: cast_typed_id(DimensionScope.id_type(dimension), id)
  defp cast_typed_id(:string, id), do: to_string(id)
  defp cast_typed_id(:integer, id) when is_integer(id), do: id
  defp cast_typed_id(:integer, id), do: id |> to_string() |> String.to_integer()

  defp unresolved(dimensions, report_filter, values) do
    Enum.flat_map(dimensions, fn dimension ->
      resolved =
        values |> Map.get(dimension, %{}) |> Map.keys() |> MapSet.new(&comparable_id/1)

      case Enum.reject(Map.get(report_filter, dimension), &MapSet.member?(resolved, comparable_id(&1))) do
        [] -> []
        missing -> [{dimension, missing}]
      end
    end)
  end

  # MySQL's collation is case insensitive, so a state resolves under the spelling the portal holds
  # rather than the one the caller asked for.
  defp comparable_id(id), do: id |> to_string() |> String.downcase()


  defp get_filter_type!(form, i) do
    filter_type = form.params["filter#{i}_type"]
    if filter_type == "" do
      nil
    else
      case dimension_from_string(filter_type) do
        {:ok, dimension} -> dimension
        :error -> raise "Invalid filter type: #{filter_type}"
      end
    end
  end

  defp get_filter_value(form, i) do
    case get_filter_type!(form, i) do
      nil -> []
      filter_type -> parse_filter_values(form.params["filter#{i}"] || [], filter_type)
    end
  end

  defp parse_filter_values(values, filter_type) do
    case DimensionScope.id_type(filter_type) do
      :string -> values
      :integer -> Enum.map(values, &String.to_integer/1)
    end
  end
end
