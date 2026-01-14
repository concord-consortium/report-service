defmodule ReportServer.Reports.ReportFilterQuery do
  require Logger

  import ReportServer.Reports.ReportUtils

  alias ReportServer.Accounts.User
  alias ReportServer.PortalDbs
  alias ReportServer.Reports.{ReportFilter, ReportFilterQuery}

  defstruct id: nil, value: nil, from: nil, join: [], where: [], order_by: nil, num_params: 1

  # Registry of reusable JOIN patterns
  # Each pattern is a list of JOIN clauses that can be composed together
  @join_patterns %{
    # Core connectivity patterns
    cohort_items_teacher: "JOIN admin_cohort_items aci ON (aci.item_type = 'Portal::Teacher' and aci.admin_cohort_id = admin_cohorts.id)",
    cohort_items_teacher_via_id: "JOIN admin_cohort_items aci ON (aci.item_type = 'Portal::Teacher' AND aci.item_id = ptc.teacher_id)",
    cohort_items_teacher_ref: "JOIN admin_cohort_items aci_cohort ON (aci_cohort.item_type = 'Portal::Teacher' AND aci_cohort.item_id = portal_teachers.id)",
    cohort_items_teacher_via_member: "JOIN admin_cohort_items aci_cohort ON (aci_cohort.item_type = 'Portal::Teacher' AND aci_cohort.item_id = psm.member_id)",
    cohort_items_assignment: "JOIN admin_cohort_items aci_assignment ON (aci_assignment.item_type = 'ExternalActivity' and aci_assignment.admin_cohort_id = admin_cohorts.id)",
    cohort_items_assignment_ref: "JOIN admin_cohort_items aci_cohort ON (aci_cohort.item_type = 'ExternalActivity' AND aci_cohort.item_id = external_activities.id)",
    cohort_via_items: "JOIN admin_cohorts ac ON (ac.id = aci.admin_cohort_id)",
    cohort_via_items_ref: "JOIN admin_cohorts ac ON (ac.id = aci_cohort.admin_cohort_id)",

    # Teacher-class relationships
    teacher_class_via_id: "JOIN portal_teacher_clazzes ptc ON (ptc.teacher_id = portal_teachers.id)",
    teacher_class_via_member: "JOIN portal_teacher_clazzes ptc ON (ptc.teacher_id = psm.member_id)",
    teacher_class_via_cohort: "JOIN portal_teacher_clazzes ptc ON (ptc.teacher_id = aci.item_id)",
    teacher_class_via_class: "JOIN portal_teacher_clazzes ptc ON (ptc.clazz_id = psc.clazz_id)",
    teacher_class_from_class: "JOIN portal_teacher_clazzes ptc ON (ptc.clazz_id = pc.id)",
    teacher_class_via_offering: "JOIN portal_teacher_clazzes ptc ON (ptc.clazz_id = po.clazz_id)",
    teacher_class_assignment: "JOIN portal_teacher_clazzes ptc_assignment ON (ptc_assignment.clazz_id = po_assignment.clazz_id)",
    teacher_class_school: "JOIN portal_teacher_clazzes ptc_school ON (ptc_school.clazz_id = po.clazz_id)",
    teacher_class_class_filter: "JOIN portal_teacher_clazzes ptc_class ON (ptc_class.clazz_id = po.clazz_id)",
    teacher_class_teacher_filter: "JOIN portal_teacher_clazzes ptc_teacher ON (ptc_teacher.clazz_id = po_teacher.clazz_id)",

    # Student-class relationships
    student_class_via_student: "JOIN portal_student_clazzes psc ON psc.student_id = ps.id",
    student_class_via_teacher: "JOIN portal_student_clazzes psc ON (psc.clazz_id = ptc.clazz_id)",
    student_class_via_permission: "JOIN portal_student_clazzes psc ON psc.student_id = pspf.portal_student_id",
    student_class_from_class: "JOIN portal_student_clazzes psc ON (psc.clazz_id = pc.id)",
    student_class_via_offering: "JOIN portal_student_clazzes psc ON (psc.clazz_id = po.clazz_id)",
    student_class_reverse: "JOIN portal_student_clazzes psc ON (ptc.clazz_id = psc.clazz_id)",

    # School membership relationships
    school_member_teacher_via_id: "JOIN portal_school_memberships psm_school ON (psm_school.member_type = 'Portal::Teacher' AND psm_school.member_id = portal_teachers.id)",
    school_member_via_teacher: "JOIN portal_school_memberships psm ON (psm.member_id = ptc.teacher_id AND psm.member_type = 'Portal::Teacher')",
    school_member_via_cohort: "JOIN portal_school_memberships psm_school ON (psm_school.member_type = 'Portal::Teacher' AND psm_school.member_id = aci.item_id)",
    school_member_from_school: "JOIN portal_school_memberships psm ON (psm.member_type = 'Portal::Teacher' AND psm.school_id = portal_schools.id)",
    school_member_assignment: "JOIN portal_school_memberships psm_assignment ON (psm_assignment.member_type = 'Portal::Teacher' AND psm_assignment.member_id = ptc_assignment.teacher_id AND psm_assignment.school_id = portal_schools.id)",
    school_member_school_filter: "JOIN portal_school_memberships psm_school ON (psm_school.member_type = 'Portal::Teacher' AND psm_school.member_id = ptc_school.teacher_id)",
    school_join: "JOIN portal_schools ps ON (ps.id = psm.school_id)",

    # Class relationships
    class_via_teacher: "JOIN portal_clazzes pc ON (pc.id = ptc.clazz_id)",

    # Permission form relationships
    permission_form_via_student: "JOIN portal_student_permission_forms pspf ON pspf.portal_student_id = psc.student_id",
    permission_form_from_form: "JOIN portal_student_permission_forms pspf ON pspf.portal_permission_form_id = ppf.id",
    permission_form_via_student_id: "JOIN portal_student_permission_forms pspf ON pspf.portal_student_id = ps.id",

    # Offering/Assignment relationships
    offering_from_assignment: "JOIN portal_offerings po ON (po.runnable_type = 'ExternalActivity' AND po.runnable_id = external_activities.id)",
    offering_via_class: "JOIN portal_offerings po ON (po.clazz_id = psc.clazz_id AND po.runnable_type = 'ExternalActivity')",
    offering_from_class: "JOIN portal_offerings po ON (po.clazz_id = pc.id AND po.runnable_type = 'ExternalActivity')",
    offering_from_teacher_class: "JOIN portal_offerings po ON (po.clazz_id = ptc.clazz_id AND po.runnable_type = 'ExternalActivity')",
    offering_assignment_only: "JOIN portal_offerings po_assignment ON (po_assignment.runnable_type = 'ExternalActivity')",
    offering_assignment_via_teacher: "JOIN portal_offerings po_assignment ON (po_assignment.clazz_id = ptc.clazz_id AND po_assignment.runnable_type = 'ExternalActivity')",
    offering_teacher_filter: "JOIN portal_offerings po_teacher ON (po_teacher.runnable_type = 'ExternalActivity' AND po_teacher.runnable_id = external_activities.id)",

    # User relationships
    user_via_teacher: "JOIN users u ON u.id = portal_teachers.user_id",

    # Special allowed_project_ids patterns
    allowed_projects_cohort: "JOIN admin_cohorts ac ON (ac.id = aci_cohort.admin_cohort_id)",
    allowed_projects_school: [
      "JOIN portal_school_memberships psm ON (psm.member_type = 'Portal::Teacher' AND psm.school_id = portal_schools.id)",
      "JOIN admin_cohort_items aci_cohort ON (aci_cohort.item_type = 'Portal::Teacher' AND aci_cohort.item_id = psm.member_id)",
      "JOIN admin_cohorts ac ON (ac.id = aci_cohort.admin_cohort_id)"
    ],
    allowed_projects_teacher: [
      "JOIN admin_cohort_items aci_cohort ON (aci_cohort.item_type = 'Portal::Teacher' AND aci_cohort.item_id = portal_teachers.id)",
      "JOIN admin_cohorts ac ON (ac.id = aci_cohort.admin_cohort_id)"
    ],
    allowed_projects_assignment: [
      "LEFT JOIN admin_cohort_items aci_cohort ON (aci_cohort.item_type = 'ExternalActivity' AND aci_cohort.item_id = external_activities.id)",
      "LEFT JOIN admin_cohorts ac ON (ac.id = aci_cohort.admin_cohort_id)",
      "LEFT JOIN admin_project_materials apm ON (apm.material_type = 'ExternalActivity' AND apm.material_id = external_activities.id)"
    ],
    allowed_projects_permission_form: [
      "JOIN portal_student_permission_forms pspf ON pspf.portal_permission_form_id = ppf.id",
      "JOIN portal_student_clazzes psc ON psc.student_id = pspf.portal_student_id",
      "JOIN portal_teacher_clazzes ptc ON (ptc.clazz_id = psc.clazz_id)",
      "JOIN admin_cohort_items aci ON (aci.item_type = 'Portal::Teacher' AND aci.item_id = ptc.teacher_id)",
      "JOIN admin_cohorts ac ON (ac.id = aci.admin_cohort_id)"
    ],
    allowed_projects_class: [
      "JOIN portal_teacher_clazzes ptc ON (ptc.clazz_id = pc.id)",
      "JOIN admin_cohort_items aci ON (aci.item_type = 'Portal::Teacher' AND aci.item_id = ptc.teacher_id)",
      "JOIN admin_cohorts ac ON (ac.id = aci.admin_cohort_id)"
    ],
    allowed_projects_student: [
      "JOIN portal_student_clazzes psc ON psc.student_id = ps.id",
      "JOIN portal_teacher_clazzes ptc ON (ptc.clazz_id = psc.clazz_id)",
      "JOIN admin_cohort_items aci ON (aci.item_type = 'Portal::Teacher' AND aci.item_id = ptc.teacher_id)",
      "JOIN admin_cohorts ac ON (ac.id = aci.admin_cohort_id)"
    ],

    # Country patterns
    country_via_school: "JOIN portal_schools ps_country ON (ps_country.country_id = portal_countries.id)",
    school_via_country: "JOIN portal_schools ps_country ON (ps_country.country_id = portal_countries.id)",
    country_from_school: "JOIN portal_countries pc_country ON (pc_country.id = portal_schools.id)",

    # State patterns
    state_via_school: "JOIN portal_schools ps_state ON (ps_state.state = portal_schools.state)",
    school_via_state: "JOIN portal_schools ps_state",

    # Subject Area patterns (ExternalActivity taggings only)
    subject_area_base: "JOIN taggings t ON (t.tag_id = admin_tags.id AND t.context = 'subject_areas' AND t.taggable_type = 'ExternalActivity')",
    external_activity_via_subject: "JOIN external_activities ea ON (ea.id = t.taggable_id)",
    external_activity_via_offering: "JOIN external_activities ea ON (ea.id = po.runnable_id)",
    subject_via_external_activity: "JOIN taggings t ON (t.taggable_type = 'ExternalActivity' AND t.taggable_id = ea.id AND t.context = 'subject_areas')",
    offering_via_external_activity: "JOIN portal_offerings po ON (po.runnable_id = ea.id AND po.runnable_type = 'ExternalActivity')",
    subject_via_offering: [
      "JOIN portal_offerings po ON (po.runnable_type = 'ExternalActivity')",
      "JOIN external_activities ea ON (ea.id = po.runnable_id)",
      "JOIN taggings t ON (t.taggable_type = 'ExternalActivity' AND t.taggable_id = ea.id AND t.context = 'subject_areas')"
    ],
    school_via_subject: [
      "JOIN portal_offerings po ON (po.runnable_type = 'ExternalActivity' AND po.runnable_id = ea.id)",
      "JOIN portal_teacher_clazzes ptc ON (ptc.clazz_id = po.clazz_id)",
      "JOIN portal_school_memberships psm ON (psm.member_type = 'Portal::Teacher' AND psm.member_id = ptc.teacher_id)"
    ],
    teacher_via_subject: [
      "JOIN portal_offerings po ON (po.runnable_type = 'ExternalActivity' AND po.runnable_id = ea.id)",
      "JOIN portal_teacher_clazzes ptc ON (ptc.clazz_id = po.clazz_id)"
    ]
  }

  # Configuration map defining join and where clauses for each (primary_filter, secondary_filter) combination
  # Join patterns are now referenced by name from @join_patterns and resolved at runtime
  @secondary_filter_config %{
    cohort: %{
      school: %{
        join: [
          :cohort_items_teacher,
          :school_member_via_cohort
        ],
        where: "psm_school.school_id IN"
      },
      teacher: %{
        join: :cohort_items_teacher,
        where: "aci.item_id IN"
      },
      assignment: %{
        join: :cohort_items_assignment,
        where: "aci_assignment.item_id IN"
      },
      permission_form: %{
        join: [
          :cohort_items_teacher,
          :teacher_class_via_cohort,
          :student_class_via_teacher,
          :permission_form_via_student
        ],
        where: "pspf.portal_permission_form_id IN"
      },
      class: %{
        join: [
          :cohort_items_teacher,
          :teacher_class_via_cohort,
          :class_via_teacher
        ],
        where: "pc.id IN"
      },
      student: %{
        join: [
          :cohort_items_teacher,
          :teacher_class_via_cohort,
          :student_class_via_teacher
        ],
        where: "psc.student_id IN"
      }
    },
    school: %{
      cohort: %{
        join: [
          :school_member_from_school,
          :cohort_items_teacher_via_member
        ],
        where: "aci_cohort.admin_cohort_id IN"
      },
      teacher: %{
        join: :school_member_from_school,
        where: "psm.member_id IN"
      },
      assignment: %{
        join: [
          :offering_assignment_only,
          :teacher_class_assignment,
          :school_member_assignment
        ],
        where: "po_assignment.runnable_id IN"
      },
      permission_form: %{
        join: [
          :school_member_from_school,
          :teacher_class_via_member,
          :student_class_reverse,
          :permission_form_via_student
        ],
        where: "pspf.portal_permission_form_id IN"
      },
      class: %{
        join: [
          :school_member_from_school,
          :teacher_class_via_member,
          :class_via_teacher
        ],
        where: "pc.id IN"
      },
      student: %{
        join: [
          :school_member_from_school,
          :teacher_class_via_member,
          :student_class_via_teacher
        ],
        where: "psc.student_id IN"
      }
    },
    teacher: %{
      cohort: %{
        join: :cohort_items_teacher_ref,
        where: "aci_cohort.admin_cohort_id IN"
      },
      school: %{
        join: :school_member_teacher_via_id,
        where: "psm_school.school_id IN"
      },
      assignment: %{
        join: [
          :teacher_class_via_id,
          :offering_assignment_via_teacher
        ],
        where: "po_assignment.runnable_id IN"
      },
      permission_form: %{
        join: [
          :teacher_class_via_id,
          :student_class_via_teacher,
          :permission_form_via_student
        ],
        where: "pspf.portal_permission_form_id IN"
      },
      class: %{
        join: [
          :teacher_class_via_id,
          :class_via_teacher
        ],
        where: "pc.id IN"
      },
      student: %{
        join: [
          :teacher_class_via_id,
          :student_class_via_teacher
        ],
        where: "psc.student_id IN"
      }
    },
    assignment: %{
      cohort: %{
        join: :cohort_items_assignment_ref,
        where: "aci_cohort.admin_cohort_id IN"
      },
      school: %{
        join: [
          :offering_from_assignment,
          :teacher_class_school,
          :school_member_school_filter
        ],
        where: "psm_school.school_id IN"
      },
      teacher: %{
        join: [
          :offering_teacher_filter,
          :teacher_class_teacher_filter
        ],
        where: "ptc_teacher.teacher_id IN"
      },
      permission_form: %{
        join: [
          :offering_from_assignment,
          :student_class_via_offering,
          :permission_form_via_student
        ],
        where: "pspf.portal_permission_form_id IN"
      },
      class: %{
        join: [
          :offering_from_assignment,
          :teacher_class_class_filter
        ],
        where: "ptc_class.clazz_id IN"
      },
      student: %{
        join: [
          :offering_from_assignment,
          :student_class_via_offering
        ],
        where: "psc.student_id IN"
      }
    },
    permission_form: %{
      cohort: %{
        join: [
          :permission_form_from_form,
          :student_class_via_permission,
          :teacher_class_via_class,
          :cohort_items_teacher_via_id
        ],
        where: "aci.admin_cohort_id IN"
      },
      school: %{
        join: [
          :permission_form_from_form,
          :student_class_via_permission,
          :teacher_class_via_class,
          :school_member_via_teacher
        ],
        where: "psm.school_id IN"
      },
      teacher: %{
        join: [
          :permission_form_from_form,
          :student_class_via_permission,
          :teacher_class_via_class
        ],
        where: "ptc.teacher_id IN"
      },
      assignment: %{
        join: [
          :permission_form_from_form,
          :student_class_via_permission,
          :offering_via_class
        ],
        where: "po.runnable_id IN"
      },
      class: %{
        join: [
          :permission_form_from_form,
          :student_class_via_permission
        ],
        where: "psc.clazz_id IN"
      },
      student: %{
        join: :permission_form_from_form,
        where: "pspf.portal_student_id IN"
      }
    },
    class: %{
      cohort: %{
        join: [
          :teacher_class_from_class,
          :cohort_items_teacher_via_id
        ],
        where: "aci.admin_cohort_id IN"
      },
      school: %{
        join: [
          :teacher_class_from_class,
          :school_member_via_teacher,
          :school_join
        ],
        where: "ps.id IN"
      },
      teacher: %{
        join: :teacher_class_from_class,
        where: "ptc.teacher_id IN"
      },
      assignment: %{
        join: [
          :teacher_class_from_class,
          :offering_from_class
        ],
        where: "po.runnable_id IN"
      },
      permission_form: %{
        join: [
          :student_class_from_class,
          :permission_form_via_student
        ],
        where: "pspf.portal_permission_form_id IN"
      },
      student: %{
        join: :student_class_from_class,
        where: "psc.student_id IN"
      }
    },
    student: %{
      cohort: %{
        join: [
          :student_class_via_student,
          :teacher_class_via_class,
          :cohort_items_teacher_via_id
        ],
        where: "aci.admin_cohort_id IN"
      },
      school: %{
        join: [
          :student_class_via_student,
          :teacher_class_via_class,
          :school_member_via_teacher
        ],
        where: "psm.school_id IN"
      },
      teacher: %{
        join: [
          :student_class_via_student,
          :teacher_class_via_class
        ],
        where: "ptc.teacher_id IN"
      },
      assignment: %{
        join: [
          :student_class_via_student,
          :offering_via_class
        ],
        where: "po.runnable_id IN"
      },
      permission_form: %{
        join: :permission_form_via_student_id,
        where: "pspf.portal_permission_form_id IN"
      },
      class: %{
        join: :student_class_via_student,
        where: "psc.clazz_id IN"
      }
    },
    country: %{
      state: %{
        join: :school_via_country,
        where: "ps_country.state IN"
      },
      school: %{
        join: :school_via_country,
        where: "ps_country.id IN"
      },
      teacher: %{
        join: [
          :school_via_country,
          :school_member_from_school
        ],
        where: "psm.member_id IN"
      },
      subject_area: %{
        join: [
          :school_via_country,
          :school_member_from_school,
          :teacher_class_via_member,
          :offering_from_class,
          :subject_via_external_activity
        ],
        where: "t.tag_id IN"
      }
    },
    state: %{
      country: %{
        join: [],
        where: "portal_schools.country_id IN"
      },
      school: %{
        join: [],
        where: "portal_schools.id IN"
      },
      teacher: %{
        join: :school_member_from_school,
        where: "psm.member_id IN"
      },
      subject_area: %{
        join: [
          :school_member_from_school,
          :teacher_class_via_member,
          :offering_from_teacher_class,
          :external_activity_via_offering,
          :subject_via_external_activity
        ],
        where: "t.tag_id IN"
      }
    },
    subject_area: %{
      country: %{
        join: [
          :subject_area_base,
          :external_activity_via_subject,
          :offering_via_external_activity,
          :teacher_class_via_offering,
          :school_member_via_teacher,
          :school_join
        ],
        where: "ps.country_id IN"
      },
      state: %{
        join: [
          :subject_area_base,
          :external_activity_via_subject,
          :offering_via_external_activity,
          :teacher_class_via_offering,
          :school_member_via_teacher,
          :school_join
        ],
        where: "ps.state IN"
      },
      school: %{
        join: [
          :subject_area_base,
          :external_activity_via_subject,
          :school_via_subject
        ],
        where: "psm.school_id IN"
      },
      teacher: %{
        join: [
          :subject_area_base,
          :external_activity_via_subject,
          :teacher_via_subject
        ],
        where: "ptc.teacher_id IN"
      }
    }
  }

  def get_options(report_filter = %ReportFilter{}, %User{portal_server: portal_server}, allowed_project_ids, like_text \\ "") do
    {query, params} = get_query_and_params(report_filter, allowed_project_ids, like_text, portal_server)
    if query == nil do
      {:ok, [], "", params}
    else
      sql = get_options_sql(query)

      case PortalDbs.query(portal_server, sql, params) do
        {:ok, result} ->
          {:ok, Enum.map(result.rows, fn [id, value] -> {value, to_string(id)} end), sql, params}
        {:error, error} ->
          Logger.error(error)
          {:error, error, sql, params}
      end
    end
  end

  def get_option_count(report_filter = %ReportFilter{}, %User{portal_server: portal_server}, allowed_project_ids, like_text \\ "") do
    {query, params} = get_query_and_params(report_filter, allowed_project_ids, like_text, portal_server)
    if query == nil do
      {:ok, 0}
    else
      sql = get_counts_sql(query)

      case PortalDbs.query(portal_server, sql, params) do
        {:ok, result} ->
          # COUNT query should return a single row with a single column.
          count = result.rows |> List.first |> List.first
          {:ok, count}
        {:error, error} ->
          Logger.error(error)
          {:error, error, sql, params}
      end
    end
  end

  # this handles the case where the user has not selected any filters but checked the "exclude CC users" checkbox
  def get_query_and_params(_report_filter = %ReportFilter{filters: []}, _allowed_project_ids, _like_text, _portal_server) do
    {nil, []}
  end

  def get_query_and_params(report_filter = %ReportFilter{filters: [primary_filter | _secondary_filters]}, allowed_project_ids, like_text, portal_server) do
    if allowed_project_ids == :none do
      {nil, []}
    else
      query = get_filter_query(primary_filter, report_filter, allowed_project_ids, like_text, portal_server)
      params = like_params(like_text, query)
      {query, params}
    end
  end

  # Helper function to build a base query structure
  defp build_base_query(config) do
    %ReportFilterQuery{
      id: config.id,
      value: config.value,
      from: config.from,
      where: Map.get(config, :where, []),
      order_by: config.order_by,
      num_params: Map.get(config, :num_params, 1),
      join: Map.get(config, :join, [])
    }
  end

  # Helper function to check if any dependent filters are empty lists
  defp has_empty_dependent_filters?(report_filter, primary_filter) do
    dependent_filters = get_dependent_filters(primary_filter)
    Enum.any?(dependent_filters, fn filter_key ->
      Map.get(report_filter, filter_key) == []
    end)
  end

  # Returns the list of filter keys that a primary filter depends on
  defp get_dependent_filters(:cohort), do: [:school, :teacher, :assignment, :permission_form, :class, :student]
  defp get_dependent_filters(:school), do: [:cohort, :teacher, :assignment, :permission_form, :class, :student]
  defp get_dependent_filters(:teacher), do: [:cohort, :school, :assignment, :permission_form, :class, :student]
  defp get_dependent_filters(:assignment), do: [:cohort, :school, :teacher, :permission_form, :class, :student]
  defp get_dependent_filters(:permission_form), do: [:cohort, :school, :teacher, :assignment, :class, :student]
  defp get_dependent_filters(:class), do: [:cohort, :school, :teacher, :assignment, :permission_form, :student]
  defp get_dependent_filters(:student), do: [:cohort, :school, :teacher, :assignment, :permission_form, :class]
  defp get_dependent_filters(:country), do: [:state, :school, :teacher, :subject_area]
  defp get_dependent_filters(:state), do: [:country, :school, :teacher, :subject_area]
  defp get_dependent_filters(:subject_area), do: [:country, :state, :school, :teacher]

  # Resolves JOIN pattern names to actual SQL JOIN strings
  # Accepts either a single pattern name (atom) or a list of pattern names
  # Returns a list of SQL JOIN strings
  defp resolve_join_patterns(pattern) when is_atom(pattern) do
    case Map.get(@join_patterns, pattern) do
      nil -> []
      sql_string -> [sql_string]
    end
  end
  defp resolve_join_patterns(patterns) when is_list(patterns) do
    Enum.flat_map(patterns, &resolve_join_patterns/1)
  end
  defp resolve_join_patterns(sql_string) when is_binary(sql_string) do
    # Already a SQL string, return as-is (for backward compatibility during migration)
    [sql_string]
  end

  # Apply all secondary filters to a query based on the configuration map
  defp apply_secondary_filters(query, _primary_filter, _report_filter, []), do: query
  defp apply_secondary_filters(query, primary_filter, report_filter, [filter_name | rest]) do
    filter_value = Map.get(report_filter, filter_name)

    query = if filter_value == nil do
      query
    else
      config = get_in(@secondary_filter_config, [primary_filter, filter_name])
      if config do
        join = resolve_join_patterns(config.join)
        # State filters use string values, others use integer IDs
        in_clause = if filter_name == :state do
          string_list_to_single_quoted_in(filter_value)
        else
          list_to_in(filter_value)
        end
        where = "#{config.where} #{in_clause}"
        secondary_filter_query(query, join, where)
      else
        query
      end
    end

    apply_secondary_filters(query, primary_filter, report_filter, rest)
  end

  defp get_filter_query(:cohort, report_filter = %ReportFilter{}, allowed_project_ids, like_text, _portal_server) do
    ## If there are any empty-set filters, do not bother querying and just return nil.
    if has_empty_dependent_filters?(report_filter, :cohort) do
      nil
    else
      query = build_base_query(%{
        id: "admin_cohorts.id",
        value: "admin_cohorts.name",
        from: "admin_cohorts",
        where: maybe_add_like(like_text, ["admin_cohorts.name LIKE ?"]),
        order_by: "admin_cohorts.name"
      })

      query = if allowed_project_ids == :all do
        query
      else
        where = "admin_cohorts.project_id IN #{list_to_in(allowed_project_ids)}"
        %{query | where: [ where | query.where ]}
      end

      apply_secondary_filters(query, :cohort, report_filter, [:school, :teacher, :assignment, :permission_form, :class, :student])
    end
  end

  defp get_filter_query(:school, report_filter = %ReportFilter{}, allowed_project_ids, like_text, _portal_server) do
    ## If there are any empty-set filters, do not bother querying and just return nil.
    if has_empty_dependent_filters?(report_filter, :school) do
      nil
    else
      query = build_base_query(%{
        id: "portal_schools.id",
        value: "portal_schools.name",
        from: "portal_schools",
        where: maybe_add_like(like_text, ["portal_schools.name LIKE ?"]),
        order_by: "portal_schools.name"
      })

      query = if allowed_project_ids == :all do
        query
      else
        join = resolve_join_patterns(:allowed_projects_school)
        where = "ac.project_id IN #{list_to_in(allowed_project_ids)}"
        secondary_filter_query(query, join, where)
      end

      apply_secondary_filters(query, :school, report_filter, [:cohort, :teacher, :assignment, :permission_form, :class, :student])
    end
  end

  defp get_filter_query(:teacher, report_filter = %ReportFilter{exclude_internal: exclude_internal}, allowed_project_ids, like_text, portal_server) do
    ## If there are any empty-set filters, do not bother querying and just return nil.
    if has_empty_dependent_filters?(report_filter, :teacher) do
      nil
    else
      query = build_base_query(%{
        id: "portal_teachers.id",
        value: "CONCAT(u.first_name, ' ', u.last_name, ' <', u.email, '>') AS fullname",
        from: "portal_teachers",
        join: resolve_join_patterns(:user_via_teacher),
        where: maybe_add_like(like_text, ["CONCAT(u.first_name, ' ', u.last_name, ' <', u.email, '>') LIKE ?"]),
        order_by: "fullname",
        num_params: 1
      })

      query = %{query | where: exclude_internal_accounts(exclude_internal, query.where, portal_server, "portal_teachers")}

      query = if allowed_project_ids == :all do
        query
      else
        join = resolve_join_patterns(:allowed_projects_teacher)
        where = "ac.project_id IN #{list_to_in(allowed_project_ids)}"
        secondary_filter_query(query, join, where)
      end

      apply_secondary_filters(query, :teacher, report_filter, [:cohort, :school, :assignment, :permission_form, :class, :student])
    end
  end

  defp get_filter_query(:assignment, report_filter = %ReportFilter{}, allowed_project_ids, like_text, _portal_server) do
    ## If there are any empty-set filters, do not bother querying and just return nil.
    if has_empty_dependent_filters?(report_filter, :assignment) do
      nil
    else
      query = build_base_query(%{
        id: "external_activities.id",
        value: "external_activities.name",
        from: "external_activities",
        where: maybe_add_like(like_text, ["external_activities.name LIKE ?"]),
        order_by: "external_activities.name"
      })

      query = if allowed_project_ids == :all do
        query
      else
        join = resolve_join_patterns(:allowed_projects_assignment)
        where = "(ac.project_id IN #{list_to_in(allowed_project_ids)}) OR (apm.project_id IN #{list_to_in(allowed_project_ids)})"
        secondary_filter_query(query, join, where)
      end

      apply_secondary_filters(query, :assignment, report_filter, [:cohort, :school, :teacher, :permission_form, :class, :student])
    end
  end

  defp get_filter_query(:permission_form, report_filter = %ReportFilter{}, allowed_project_ids, like_text, _portal_server) do
    ## If there are any empty-set filters, do not bother querying and just return nil.
    if has_empty_dependent_filters?(report_filter, :permission_form) do
      nil
    else
      query = build_base_query(%{
        id: "ppf.id",
        value: "CONCAT(ap.name, ': ', ppf.name)",
        from: "portal_permission_forms ppf JOIN admin_projects ap ON ap.id = ppf.project_id",
        where: maybe_add_like(like_text, ["ppf.name LIKE ? or ap.name LIKE ?"]),
        order_by: "ppf.name",
        num_params: 2
      })

      ## Several of the "where" clauses before are identical since we need to connect through teachers or classes
      ## That's ok since the later processing will remove duplicates.
      ## Just make sure that they are truly identical if they use the same table alias.

      query = if allowed_project_ids == :all do
        query
      else
        join = resolve_join_patterns(:allowed_projects_permission_form)
        where = "ac.project_id IN #{list_to_in(allowed_project_ids)}"
        secondary_filter_query(query, join, where)
      end

      apply_secondary_filters(query, :permission_form, report_filter, [:cohort, :school, :teacher, :assignment, :class, :student])
    end
  end

  defp get_filter_query(:class, report_filter = %ReportFilter{}, allowed_project_ids, like_text, _portal_server) do
    ## If there are any empty-set filters, do not bother querying and just return nil.
    if has_empty_dependent_filters?(report_filter, :class) do
      nil
    else
      query = build_base_query(%{
        id: "pc.id",
        value: "CONCAT(pc.name, ' (', pc.class_word, ')') AS fullname",
        from: "portal_clazzes pc",
        where: maybe_add_like(like_text, ["pc.name LIKE ? OR pc.class_word LIKE ?"]),
        order_by: "fullname",
        num_params: 2
      })

      query = if allowed_project_ids == :all do
        query
      else
        join = resolve_join_patterns(:allowed_projects_class)
        where = "ac.project_id IN #{list_to_in(allowed_project_ids)}"
        secondary_filter_query(query, join, where)
      end

      apply_secondary_filters(query, :class, report_filter, [:cohort, :school, :teacher, :assignment, :permission_form, :student])
    end
  end

  defp get_filter_query(:student, report_filter = %ReportFilter{hide_names: hide_names}, allowed_project_ids, like_text, _portal_server) do
          ## If there are any empty-set filters, do not bother querying and just return nil.
    if has_empty_dependent_filters?(report_filter, :student) do
      nil
    else
      value = if hide_names do
        "CAST(u.id AS CHAR) AS fullname"
      else
        "CONCAT(u.first_name, ' ', u.last_name, ' <', u.id, '>') AS fullname"
      end
      where = if hide_names do
        maybe_add_like(like_text, ["CAST(u.id AS CHAR) LIKE ?"])
      else
        maybe_add_like(like_text, ["CONCAT(u.first_name, ' ', u.last_name, ' <', u.id, '>') LIKE ?"])
      end

      query = build_base_query(%{
        id: "ps.id",
        value: value,
        from: "portal_students ps JOIN users u ON u.id = ps.user_id",
        where: where,
        order_by: "fullname",
        num_params: 1
      })

      query = if allowed_project_ids == :all do
        query
      else
        join = resolve_join_patterns(:allowed_projects_student)
        where = "ac.project_id IN #{list_to_in(allowed_project_ids)}"
        secondary_filter_query(query, join, where)
      end

      apply_secondary_filters(query, :student, report_filter, [:cohort, :school, :teacher, :assignment, :permission_form, :class])
    end
  end

  defp get_filter_query(:country, report_filter = %ReportFilter{}, _allowed_project_ids, like_text, _portal_server) do
    ## If there are any empty-set filters, do not bother querying and just return nil.
    if has_empty_dependent_filters?(report_filter, :country) do
      nil
    else
      query = build_base_query(%{
        id: "portal_countries.id",
        value: "COALESCE(portal_countries.name, '(Unknown)') AS country_name",
        from: "portal_countries",
        where: maybe_add_like(like_text, ["portal_countries.name LIKE ?"]),
        order_by: "country_name"
      })

      apply_secondary_filters(query, :country, report_filter, [:state, :school, :teacher, :subject_area])
    end
  end

  defp get_filter_query(:state, report_filter = %ReportFilter{}, _allowed_project_ids, like_text, _portal_server) do
    ## If there are any empty-set filters, do not bother querying and just return nil.
    if has_empty_dependent_filters?(report_filter, :state) do
      nil
    else
      query = build_base_query(%{
        id: "COALESCE(portal_schools.state, '(Unknown)') AS state_code",
        value: "COALESCE(portal_schools.state, '(Unknown)') AS state_name",
        from: "portal_schools",
        where: maybe_add_like(like_text, ["portal_schools.state LIKE ?"]),
        order_by: "state_name"
      })

      apply_secondary_filters(query, :state, report_filter, [:country, :school, :teacher, :subject_area])
    end
  end

  defp get_filter_query(:subject_area, report_filter = %ReportFilter{}, _allowed_project_ids, like_text, _portal_server) do
    ## If there are any empty-set filters, do not bother querying and just return nil.
    if has_empty_dependent_filters?(report_filter, :subject_area) do
      nil
    else
      # Always include scope filter, optionally add LIKE filter
      base_where = ["admin_tags.scope = 'subject_areas'"]
      where_clauses = if like_text != "" do
        ["admin_tags.tag LIKE ?" | base_where]
      else
        base_where
      end

      query = build_base_query(%{
        id: "admin_tags.id",
        value: "admin_tags.tag",
        from: "admin_tags",
        where: where_clauses,
        order_by: "admin_tags.tag",
        num_params: if(like_text != "", do: 1, else: 0)
      })

      apply_secondary_filters(query, :subject_area, report_filter, [:country, :state, :school, :teacher])
    end
  end

  defp secondary_filter_query(query, join, where) do
    %{query | join: [ join | query.join ], where: [ where | query.where ]}
  end

  def get_options_sql(%{id: id, value: value, from: from, join: join, where: where, order_by: order_by} = %ReportFilterQuery{}) do
    {join_sql, where_sql} = get_join_where_sql(join, where)
    "SELECT DISTINCT #{id}, #{value} FROM #{from} #{join_sql} #{where_sql} ORDER BY #{order_by}"
  end

  defp get_counts_sql(%{id: id, from: from, join: join, where: where} = %ReportFilterQuery{}) do
    {join_sql, where_sql} = get_join_where_sql(join, where)
    # Strip any alias from the id expression for use in COUNT
    count_id = strip_alias(id)
    "SELECT COUNT(DISTINCT #{count_id}) AS the_count FROM #{from} #{join_sql} #{where_sql}"
  end

  defp strip_alias(expression) do
    # Remove " AS alias" from the expression (case insensitive)
    expression
    |> String.replace(~r/\s+AS\s+\w+$/i, "")
  end

  defp get_join_where_sql(join, where) do
    # NOTE: the reverse is before flatten to keep any sublists in order
    join_sql = join |> Enum.reverse() |> List.flatten() |> Enum.uniq() |> Enum.join(" ")
    where_sql = where |> Enum.reverse() |> List.flatten() |> Enum.map(&("(#{&1})")) |> Enum.join(" AND ")
    where_sql = if String.length(where_sql) > 0, do: "WHERE #{where_sql}", else: ""
    {join_sql, where_sql}
  end

  defp maybe_add_like("", _where), do: []
  defp maybe_add_like(_like_text, where), do: where

  defp like_params("", %ReportFilterQuery{}), do: []
  defp like_params(_like_text, nil), do: []
  defp like_params(like_text, %ReportFilterQuery{num_params: num_params}), do: List.duplicate("%#{like_text}%", num_params)

end
