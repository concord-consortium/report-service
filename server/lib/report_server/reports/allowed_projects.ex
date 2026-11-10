defmodule ReportServer.Reports.AllowedProjects do
  @moduledoc """
  The projects a portal user holds a live project role on: `admin`, the projects they administer,
  and `researcher`, the ones they research and do not also administer. At least one list is
  non-empty; `PortalDbs.get_allowed_project_ids/2` answers `:none` for a user with neither.

  A project admin sees a project's students through its cohort classes; a project researcher sees
  only those of them holding one of that project's permission forms, as rigse's
  `Report::LearnerPolicy` does. Scopes that reach no students use `ids/1`.
  """
  @enforce_keys [:admin, :researcher]
  defstruct [:admin, :researcher]

  def ids(%__MODULE__{admin: admin, researcher: researcher}), do: admin ++ researcher

  @doc """
  The predicate restricting `project_col` to these projects. `consent` is a condition that holds
  when a student the row reaches has a permission form of `project_col`'s project; it applies to
  the researcher projects only. Without it both lists take the admin rule.
  """
  def predicate(allowed, project_col, consent \\ nil)

  def predicate(allowed = %__MODULE__{}, project_col, nil), do: in_clause(project_col, ids(allowed))
  def predicate(allowed = %__MODULE__{researcher: []}, project_col, _consent), do: in_clause(project_col, ids(allowed))

  def predicate(%__MODULE__{admin: admin, researcher: researcher}, project_col, consent) do
    [{admin, nil}, {researcher, consent}]
    |> Enum.reject(fn {ids, _} -> ids == [] end)
    |> Enum.map_join(" OR ", fn
      {ids, nil} -> "(#{in_clause(project_col, ids)})"
      {ids, condition} -> "(#{in_clause(project_col, ids)} AND #{condition})"
    end)
  end

  @doc "Whether the student `student_ref` holds a permission form of the project `project_col`."
  def consent_exists(student_ref, project_col) do
    "EXISTS (SELECT 1 FROM portal_student_permission_forms pspf_r " <>
      "JOIN portal_permission_forms ppf_r ON (ppf_r.id = pspf_r.portal_permission_form_id) " <>
      "WHERE pspf_r.portal_student_id = #{student_ref} AND ppf_r.project_id = #{project_col})"
  end

  # an empty list never reaches here: predicate/3 drops it, and the struct always has one non-empty list
  defp in_clause(column, ids), do: "#{column} IN (#{Enum.map_join(ids, ",", &Integer.to_string/1)})"
end
