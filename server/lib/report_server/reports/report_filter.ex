defmodule ReportServer.Reports.ReportFilter do
  defstruct filters: [], cohort: [], school: [], teacher: [], permission_form: [], resource: []

  def from_form(form, num_filters) do
    if (num_filters < 1) do
      %ReportServer.Reports.ReportFilter{}
    else
      Enum.reduce(1..num_filters, %ReportServer.Reports.ReportFilter{}, fn i, acc ->
        filter_type = String.to_atom(form.params["filter#{i}_type"])
        filter_value = form.params["filter#{i}"]
        acc
        |> Map.put(filter_type, filter_value)
        |> Map.put(:filters, [filter_type | acc.filters])
      end)
      |> Map.update!(:filters, &Enum.reverse(&1))
    end
  end

  ### get_where_clause -- return the "where" for a single field filter

  defp get_where_clause(_type, []), do: ""

  defp get_where_clause(:cohort, cohorts) do
    "admin_cohort_items.admin_cohort_id in (#{Enum.join(cohorts, ",")})"
  end

  defp get_where_clause(:school, schools) do
    "portal_schools.id in (#{Enum.join(schools, ",")})"
  end

  defp get_where_clause(:teacher, teachers) do
    "portal_teachers.id in (#{Enum.join(teachers, ",")})"
  end

  defp get_where_clause(:permission_form, permission_forms) do
    "portal_permission_forms.id in (#{Enum.join(permission_forms, ",")})"
  end

  defp get_where_clause(:resource, resources) do
    "external_activities.id in (#{Enum.join(resources, ",")})"
  end

  ### get_where_clauses -- return all the "wheres" for all the filters

  # If there are no filters, "where" clause should always be true.
  def get_where_clauses(%{ filters: [] }), do: "true"

  def get_where_clauses(%{ filters: filters } = report_filter) do
    filters
    |> Enum.map(&get_where_clause(&1, Map.get(report_filter, &1)))
    |> Enum.join(" and ")
  end

end
