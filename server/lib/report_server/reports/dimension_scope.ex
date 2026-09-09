defmodule ReportServer.Reports.DimensionScope do
  @moduledoc """
  What a filter dimension is in the portal database: the expression that is its option id, the base
  table and joins that expression is valid in, and the joins and predicate that restrict it to the
  projects a caller may see.

  Option discovery (`ReportFilterQuery`) and label resolution (`ReportFilter.get_filter_values/2`)
  both read it, so an id resolves to a label exactly when `filter-options` would have offered it.

  Membership is against the unnarrowed option set. The cascade is not expressed here: a caller may
  name a cohort and a school that do not intersect, which is an empty report rather than a filter
  this module rejects.
  """

  import ReportServer.Reports.ReportUtils, only: [list_to_in: 1]

  alias ReportServer.Reports.AllowedProjectsLookupError

  @bases %{
    cohort: %{
      id: "admin_cohorts.id",
      type: :integer,
      from: "admin_cohorts",
      join: [],
      where: []
    },
    school: %{
      id: "portal_schools.id",
      type: :integer,
      from: "portal_schools",
      join: [],
      where: []
    },
    teacher: %{
      id: "portal_teachers.id",
      type: :integer,
      from: "portal_teachers",
      join: ["JOIN users u ON u.id = portal_teachers.user_id"],
      where: []
    },
    assignment: %{
      id: "external_activities.id",
      type: :integer,
      from: "external_activities",
      join: [],
      where: []
    },
    permission_form: %{
      id: "ppf.id",
      type: :integer,
      from: "portal_permission_forms ppf JOIN admin_projects ap ON ap.id = ppf.project_id",
      join: [],
      where: []
    },
    class: %{
      id: "pc.id",
      type: :integer,
      from: "portal_clazzes pc",
      join: [],
      where: []
    },
    student: %{
      id: "ps.id",
      type: :integer,
      from: "portal_students ps JOIN users u ON u.id = ps.user_id",
      join: [],
      where: []
    },
    country: %{
      id: "portal_countries.id",
      type: :integer,
      from: "portal_countries",
      join: [],
      where: []
    },
    state: %{
      id: "COALESCE(portal_schools.state, '(Unknown)')",
      type: :string,
      from: "portal_schools",
      join: [],
      where: []
    },
    subject_area: %{
      id: "admin_tags.id",
      type: :integer,
      from: "admin_tags",
      join: [],
      where: ["admin_tags.scope = 'subject_areas'"]
    }
  }

  # `country`, `state` and `subject_area` are global vocabularies carrying no per-person data, so
  # they are unscoped by decision rather than by an absent clause. An entity reaches a project
  # through a cohort, except an assignment, which reaches one through a cohort or through the
  # project's own materials, which is why its joins are LEFT and its predicate a disjunction.
  @scopes %{
    cohort: %{join: [], where: ["admin_cohorts.project_id IN"]},
    school: %{
      join: [
        "JOIN portal_school_memberships psm ON (psm.member_type = 'Portal::Teacher' AND psm.school_id = portal_schools.id)",
        "JOIN admin_cohort_items aci_cohort ON (aci_cohort.item_type = 'Portal::Teacher' AND aci_cohort.item_id = psm.member_id)",
        "JOIN admin_cohorts ac ON (ac.id = aci_cohort.admin_cohort_id)"
      ],
      where: ["ac.project_id IN"]
    },
    teacher: %{
      join: [
        "JOIN admin_cohort_items aci_cohort ON (aci_cohort.item_type = 'Portal::Teacher' AND aci_cohort.item_id = portal_teachers.id)",
        "JOIN admin_cohorts ac ON (ac.id = aci_cohort.admin_cohort_id)"
      ],
      where: ["ac.project_id IN"]
    },
    assignment: %{
      join: [
        "LEFT JOIN admin_cohort_items aci_cohort ON (aci_cohort.item_type = 'ExternalActivity' AND aci_cohort.item_id = external_activities.id)",
        "LEFT JOIN admin_cohorts ac ON (ac.id = aci_cohort.admin_cohort_id)",
        "LEFT JOIN admin_project_materials apm ON (apm.material_type = 'ExternalActivity' AND apm.material_id = external_activities.id)"
      ],
      where: ["ac.project_id IN", "apm.project_id IN"]
    },
    permission_form: %{
      join: [
        "JOIN portal_student_permission_forms pspf ON pspf.portal_permission_form_id = ppf.id",
        "JOIN portal_student_clazzes psc ON psc.student_id = pspf.portal_student_id",
        "JOIN portal_teacher_clazzes ptc ON (ptc.clazz_id = psc.clazz_id)",
        "JOIN admin_cohort_items aci ON (aci.item_type = 'Portal::Teacher' AND aci.item_id = ptc.teacher_id)",
        "JOIN admin_cohorts ac ON (ac.id = aci.admin_cohort_id)"
      ],
      where: ["ac.project_id IN"]
    },
    class: %{
      join: [
        "JOIN portal_teacher_clazzes ptc ON (ptc.clazz_id = pc.id)",
        "JOIN admin_cohort_items aci ON (aci.item_type = 'Portal::Teacher' AND aci.item_id = ptc.teacher_id)",
        "JOIN admin_cohorts ac ON (ac.id = aci.admin_cohort_id)"
      ],
      where: ["ac.project_id IN"]
    },
    student: %{
      join: [
        "JOIN portal_student_clazzes psc ON psc.student_id = ps.id",
        "JOIN portal_teacher_clazzes ptc ON (ptc.clazz_id = psc.clazz_id)",
        "JOIN admin_cohort_items aci ON (aci.item_type = 'Portal::Teacher' AND aci.item_id = ptc.teacher_id)",
        "JOIN admin_cohorts ac ON (ac.id = aci.admin_cohort_id)"
      ],
      where: ["ac.project_id IN"]
    },
    country: :none,
    state: :none,
    subject_area: :none
  }

  @doc "The portal expression that is `dimension`'s option id, without any alias."
  def id_expr(dimension), do: base(dimension).id

  @doc """
  Whether `dimension`'s ids are integers or strings.

  `state` is the one string dimension, because its id is the state code itself rather than a key.
  """
  def id_type(dimension), do: base(dimension).type

  @doc "The table `id_expr/1` is selected from."
  def from(dimension), do: base(dimension).from

  @doc "The joins the id and its label need, before any scoping."
  def join(dimension), do: base(dimension).join

  @doc "The predicates that define which rows of `from/1` are options at all."
  def where(dimension), do: base(dimension).where

  @doc """
  The joins and predicates that restrict `dimension` to what `allowed` covers, or `:none` when the
  dimension is a global vocabulary that is deliberately unscoped.

  `:all` (a portal super-admin) scopes nothing. An empty list or `:none` is a caller who can see no
  project-scoped data, which is not the same as "no restriction": it restricts to nothing.
  """
  def scope(dimension, allowed) do
    case Map.fetch!(@scopes, dimension) do
      :none -> :none
      config -> restrict(config, allowed)
    end
  end

  defp restrict(_config, :all), do: {[], []}

  # A failed permission lookup is not "no projects": swallowing it would answer with an
  # authoritative-looking empty scope for a transient database error.
  defp restrict(_config, {:error, reason}) do
    raise AllowedProjectsLookupError, message: "allowed-projects lookup failed: #{inspect(reason)}"
  end

  defp restrict(_config, allowed) when allowed in [[], :none], do: {[], ["1 = 0"]}

  defp restrict(config, allowed) when is_list(allowed) do
    {config.join, [project_predicate(config.where, allowed)]}
  end

  defp project_predicate([column], allowed), do: "#{column} #{list_to_in(allowed)}"

  defp project_predicate(columns, allowed) do
    columns |> Enum.map_join(" OR ", &"(#{&1} #{list_to_in(allowed)})")
  end

  defp base(dimension), do: Map.fetch!(@bases, dimension)
end
