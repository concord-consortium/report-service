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

  @doc "Whether the caller holds a researcher project, which narrows what consent-bound outputs show."
  def researcher?(%__MODULE__{researcher: [_ | _]}), do: true
  def researcher?(_allowed), do: false

  @admin_cohort_joins "JOIN admin_cohort_items aci_n ON (aci_n.item_type = 'Portal::Teacher' AND aci_n.item_id = ptc_n.teacher_id) " <>
                        "JOIN admin_cohorts ac_n ON (ac_n.id = aci_n.admin_cohort_id)"

  @doc """
  The condition that a row's class is reached through one of the caller's admin projects, the
  portal's `User#is_project_admin_for_clazz?`: the class (`:class`, over `rl.class_id`) has a teacher
  in a cohort of an admin project. `nil` for a caller with no researcher project, whose every row is
  treated alike.
  """
  def admin_class_sql(allowed, by) do
    if researcher?(allowed), do: admin_class_exists(allowed.admin, by), else: nil
  end

  defp admin_class_exists([], _by), do: "FALSE"

  defp admin_class_exists(admin_ids, :class),
    do:
      "EXISTS (SELECT 1 FROM portal_teacher_clazzes ptc_n #{@admin_cohort_joins} " <>
        "WHERE ptc_n.clazz_id = rl.class_id AND #{in_clause("ac_n.project_id", admin_ids)})"

  @doc "The projects whose forms a narrowed row may name: `:all` for a caller with no researcher project."
  def form_project_ids(allowed), do: if(researcher?(allowed), do: ids(allowed), else: :all)

  @doc """
  The `permission_forms` column for this caller. Unnarrowed rows read `rl.permission_forms`; a
  narrowed row (not in an admin-project class) keeps only the forms of `form_project_ids/1`, in the
  portal's stored text and order. The portal writes `permission_forms` and `permission_forms_id` as
  parallel comma lists with commas inside names replaced, so a position in one is the same form in
  the other; lists of different lengths give NULL rather than a misaligned name.
  """
  def form_names_sql(allowed) do
    case {form_project_ids(allowed), admin_class_sql(allowed, :class)} do
      {:all, _} -> "rl.permission_forms"
      {ids, "FALSE"} -> narrowed_form_names(ids)
      {ids, admin_class} -> "CASE WHEN #{admin_class} THEN rl.permission_forms ELSE #{narrowed_form_names(ids)} END"
    end
  end

  defp narrowed_form_names(project_ids) do
    """
    (SELECT GROUP_CONCAT(SUBSTRING_INDEX(SUBSTRING_INDEX(rl.permission_forms, ',', jt.pos), ',', -1)
                         ORDER BY jt.pos SEPARATOR ',')
       FROM JSON_TABLE(CONCAT('[', COALESCE(rl.permission_forms_id, ''), ']'),
                       '$[*]' COLUMNS (pos FOR ORDINALITY, fid INT PATH '$')) jt
       JOIN portal_permission_forms ppf_v ON (ppf_v.id = jt.fid)
      WHERE #{in_clause("ppf_v.project_id", project_ids)}
        AND #{comma_count("rl.permission_forms")} = #{comma_count("rl.permission_forms_id")})
    """
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp comma_count(col), do: "CHAR_LENGTH(#{col}) - CHAR_LENGTH(REPLACE(#{col}, ',', ''))"

  # every caller passes a non-empty list, so no `IN ()` is rendered
  defp in_clause(column, ids), do: "#{column} IN (#{Enum.map_join(ids, ",", &Integer.to_string/1)})"
end
