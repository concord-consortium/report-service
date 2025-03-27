defmodule ReportServer.Reports.ReportFilterQuery do
  require Logger

  import ReportServer.Reports.ReportUtils

  alias ReportServer.Accounts.User
  alias ReportServer.PortalDbs
  alias ReportServer.Reports.{ReportFilter, ReportFilterQuery}

  defstruct id: nil, value: nil, from: nil, join: [], where: [], order_by: nil, num_params: 1

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

  defp get_filter_query(:cohort, %ReportFilter{school: school, teacher: teacher, assignment: assignment, permission_form: permission_form}, allowed_project_ids, like_text, _portal_server) do
    ## If there are any empty-set filters, do not bother querying and just return nil.
    if (school == [] || teacher == [] || assignment == [] || permission_form == []) do
      nil
    else
      query = %ReportFilterQuery{
        id: "admin_cohorts.id",
        value: "admin_cohorts.name",
        from: "admin_cohorts",
        where: maybe_add_like(like_text, ["admin_cohorts.name LIKE ?"]),
        order_by: "admin_cohorts.name"
      }

      query = if allowed_project_ids == :all do
        query
      else
        where = "admin_cohorts.project_id IN #{list_to_in(allowed_project_ids)}"
        %{query | where: [ where | query.where ]}
      end

      query = if school == nil do
        query
      else
        join = [
        "JOIN admin_cohort_items aci ON (aci.item_type = 'Portal::Teacher' and aci.admin_cohort_id = admin_cohorts.id)",
        "JOIN portal_school_memberships psm_school ON (psm_school.member_type = 'Portal::Teacher' AND psm_school.member_id = aci.item_id)"
        ]
        where = "psm_school.school_id IN #{list_to_in(school)}"
        secondary_filter_query(query, join, where)
      end

      query = if teacher == nil do
        query
      else
        join = "JOIN admin_cohort_items aci ON (aci.item_type = 'Portal::Teacher' and aci.admin_cohort_id = admin_cohorts.id)"
        where = "aci.item_id IN #{list_to_in(teacher)}"
        secondary_filter_query(query, join, where)
      end

      query = if assignment == nil do
        query
      else
        join = "JOIN admin_cohort_items aci_assignment ON (aci_assignment.item_type = 'ExternalActivity' and aci_assignment.admin_cohort_id = admin_cohorts.id)"
        where = "aci_assignment.item_id IN #{list_to_in(assignment)}"
        secondary_filter_query(query, join, where)
      end

      query = if permission_form == nil do
        query
      else
        join = [
          "JOIN admin_cohort_items aci ON (aci.item_type = 'Portal::Teacher' and aci.admin_cohort_id = admin_cohorts.id)",
          "JOIN portal_teacher_clazzes ptc ON (ptc.teacher_id = aci.item_id)",
          "JOIN portal_student_clazzes psc ON (psc.clazz_id = ptc.clazz_id)",
          "JOIN portal_student_permission_forms pspf ON (pspf.portal_student_id = psc.student_id)"
        ]
        where = "pspf.portal_permission_form_id IN #{list_to_in(permission_form)}"
        secondary_filter_query(query, join, where)
      end

      query
    end
  end

  defp get_filter_query(:school, %ReportFilter{cohort: cohort, teacher: teacher, assignment: assignment, permission_form: permission_form}, allowed_project_ids, like_text, _portal_server) do
    ## If there are any empty-set filters, do not bother querying and just return nil.
    if (cohort == [] || teacher == [] || assignment == [] || permission_form == []) do
      nil
    else
      query = %ReportFilterQuery{
        id: "portal_schools.id",
        value: "portal_schools.name",
        from: "portal_schools",
        where: maybe_add_like(like_text, ["portal_schools.name LIKE ?"]),
        order_by: "portal_schools.name"
      }

      query = if allowed_project_ids == :all do
        query
      else
        join = [
          "JOIN portal_school_memberships psm ON (psm.member_type = 'Portal::Teacher' AND psm.school_id = portal_schools.id)",
          "JOIN admin_cohort_items aci_cohort ON (aci_cohort.item_type = 'Portal::Teacher' AND aci_cohort.item_id = psm.member_id)",
          "JOIN admin_cohorts ac ON (ac.id = aci_cohort.admin_cohort_id)"
        ]
        where = "ac.project_id IN #{list_to_in(allowed_project_ids)}"
        secondary_filter_query(query, join, where)
      end

      query = if cohort == nil do
        query
      else
        join = [
          "JOIN portal_school_memberships psm ON (psm.member_type = 'Portal::Teacher' AND psm.school_id = portal_schools.id)",
          "JOIN admin_cohort_items aci_cohort ON (aci_cohort.item_type = 'Portal::Teacher' AND aci_cohort.item_id = psm.member_id)"
        ]
        where = "aci_cohort.admin_cohort_id IN #{list_to_in(cohort)}"
        secondary_filter_query(query, join, where)
      end

      query = if teacher == nil do
        query
      else
        join = "JOIN portal_school_memberships psm ON (psm.member_type = 'Portal::Teacher' AND psm.school_id = portal_schools.id)"
        where = "psm.member_id IN #{list_to_in(teacher)}"
        secondary_filter_query(query, join, where)
      end

      query = if assignment == nil do
        query
      else
        join = [
          "JOIN portal_offerings po_assignment ON (po_assignment.runnable_type = 'ExternalActivity')",
          "JOIN portal_teacher_clazzes ptc_assignment ON (ptc_assignment.clazz_id = po_assignment.clazz_id)",
          "JOIN portal_school_memberships psm_assignment ON (psm_assignment.member_type = 'Portal::Teacher' AND psm_assignment.member_id = ptc_assignment.teacher_id AND psm_assignment.school_id = portal_schools.id)"
        ]
        where = "po_assignment.runnable_id IN #{list_to_in(assignment)}"
        secondary_filter_query(query, join, where)
      end

      query = if permission_form == nil do
        query
      else
        join = [
          "JOIN portal_school_memberships psm ON (psm.member_type = 'Portal::Teacher' AND psm.school_id = portal_schools.id)",
          "JOIN portal_teacher_clazzes ptc ON (ptc.teacher_id = psm.member_id)",
          "JOIN portal_student_clazzes psc ON (ptc.clazz_id = psc.clazz_id)",
          "JOIN portal_student_permission_forms pspf ON (pspf.portal_student_id = psc.student_id)"
        ]
        where = "pspf.portal_permission_form_id IN #{list_to_in(permission_form)}"
        secondary_filter_query(query, join, where)
      end

      query
    end
  end

  defp get_filter_query(:teacher, %ReportFilter{cohort: cohort, school: school, assignment: assignment, permission_form: permission_form, exclude_internal: exclude_internal}, allowed_project_ids, like_text, portal_server) do
    ## If there are any empty-set filters, do not bother querying and just return nil.
    if (cohort == [] || school == [] || assignment == [] || permission_form == []) do
      nil
    else
      query = %ReportFilterQuery{
        id: "portal_teachers.id",
        value: "CONCAT(u.first_name, ' ', u.last_name, ' <', u.email, '>') AS fullname",
        from: "portal_teachers",
        join: ["JOIN users u ON u.id = portal_teachers.user_id"],
        where: maybe_add_like(like_text, ["CONCAT(u.first_name, ' ', u.last_name, ' <', u.email, '>') LIKE ?"]),
        order_by: "fullname",
        num_params: 1
      }

      query = %{query | where: exclude_internal_accounts(query.where, exclude_internal, portal_server, "portal_teachers")}

      query = if allowed_project_ids == :all do
        query
      else
        join = [
          "JOIN admin_cohort_items aci_cohort ON (aci_cohort.item_type = 'Portal::Teacher' AND aci_cohort.item_id = portal_teachers.id)",
          "JOIN admin_cohorts ac ON (ac.id = aci_cohort.admin_cohort_id)"
        ]
        where = "ac.project_id IN #{list_to_in(allowed_project_ids)}"
        secondary_filter_query(query, join, where)
      end

      query = if cohort == nil do
        query
      else
        join = "JOIN admin_cohort_items aci_cohort ON (aci_cohort.item_type = 'Portal::Teacher' AND aci_cohort.item_id = portal_teachers.id)"
        where = "aci_cohort.admin_cohort_id IN #{list_to_in(cohort)}"
        secondary_filter_query(query, join, where)
      end

      query = if school == nil do
        query
      else
        join = "JOIN portal_school_memberships psm_school ON (psm_school.member_type = 'Portal::Teacher' AND psm_school.member_id = portal_teachers.id)"
        where = "psm_school.school_id IN #{list_to_in(school)}"
        secondary_filter_query(query, join, where)
      end

      query = if assignment == nil do
        query
      else
        join = [
          "JOIN portal_teacher_clazzes ptc ON (ptc.teacher_id = portal_teachers.id)",
          "JOIN portal_offerings po_assignment ON (po_assignment.clazz_id = ptc.clazz_id AND po_assignment.runnable_type = 'ExternalActivity')"
        ]
        where = "po_assignment.runnable_id IN #{list_to_in(assignment)}"
        secondary_filter_query(query, join, where)
      end

      query = if permission_form == nil do
        query
      else
        join = [
          "JOIN portal_teacher_clazzes ptc ON (ptc.teacher_id = portal_teachers.id)",
          "JOIN portal_student_clazzes psc ON (psc.clazz_id = ptc.clazz_id)",
          "JOIN portal_student_permission_forms pspf ON pspf.portal_student_id = psc.student_id",
        ]
        where = "pspf.portal_permission_form_id IN #{list_to_in(permission_form)}"
        secondary_filter_query(query, join, where)
      end

      query
    end
  end

  defp get_filter_query(:assignment, %ReportFilter{cohort: cohort, school: school, teacher: teacher, permission_form: permission_form}, allowed_project_ids, like_text, _portal_server) do
    ## If there are any empty-set filters, do not bother querying and just return nil.
    if (cohort == [] || school == [] || teacher == [] || permission_form == []) do
      nil
    else
      query = %ReportFilterQuery{
        id: "external_activities.id",
        value: "external_activities.name",
        from: "external_activities",
        where: maybe_add_like(like_text, ["external_activities.name LIKE ?"]),
        order_by: "external_activities.name",
      }

      query = if allowed_project_ids == :all do
        query
      else
        join = [
          "LEFT JOIN admin_cohort_items aci_cohort ON (aci_cohort.item_type = 'ExternalActivity' AND aci_cohort.item_id = external_activities.id)",
          "LEFT JOIN admin_cohorts ac ON (ac.id = aci_cohort.admin_cohort_id)",
          "LEFT JOIN admin_project_materials apm ON (apm.material_type = 'ExternalActivity' AND apm.material_id = external_activities.id)",
        ]
        where = "(ac.project_id IN #{list_to_in(allowed_project_ids)}) OR (apm.project_id IN #{list_to_in(allowed_project_ids)})"
        secondary_filter_query(query, join, where)
      end

      query = if cohort == nil do
        query
      else
        join = "JOIN admin_cohort_items aci_cohort ON (aci_cohort.item_type = 'ExternalActivity' AND aci_cohort.item_id = external_activities.id)"
        where = "aci_cohort.admin_cohort_id IN #{list_to_in(cohort)}"
        secondary_filter_query(query, join, where)
      end

      query = if school == nil do
        query
      else
        join = [
          "JOIN portal_offerings po ON (po.runnable_type = 'ExternalActivity' AND po.runnable_id = external_activities.id)",
          "JOIN portal_teacher_clazzes ptc_school ON (ptc_school.clazz_id = po.clazz_id)",
          "JOIN portal_school_memberships psm_school ON (psm_school.member_type = 'Portal::Teacher' AND psm_school.member_id = ptc_school.teacher_id)"
        ]
        where = "psm_school.school_id IN #{list_to_in(school)}"
        secondary_filter_query(query, join, where)
      end

      query = if teacher == nil do
        query
      else
        join = [
          "JOIN portal_offerings po_teacher ON (po_teacher.runnable_type = 'ExternalActivity' AND po_teacher.runnable_id = external_activities.id)",
          "JOIN portal_teacher_clazzes ptc_teacher ON (ptc_teacher.clazz_id = po_teacher.clazz_id)",
        ]
        where = "ptc_teacher.teacher_id IN #{list_to_in(teacher)}"
        secondary_filter_query(query, join, where)
      end

      query = if permission_form == nil do
        query
      else
        join = [
          "JOIN portal_offerings po ON (po.runnable_type = 'ExternalActivity' AND po.runnable_id = external_activities.id)",
          "JOIN portal_student_clazzes psc ON (psc.clazz_id = po.clazz_id)",
          "JOIN portal_student_permission_forms pspf ON pspf.portal_student_id = psc.student_id"
        ]
        where = "pspf.portal_permission_form_id IN #{list_to_in(permission_form)}"
        secondary_filter_query(query, join, where)
      end

      query
    end
  end

  defp get_filter_query(:permission_form, %ReportFilter{cohort: cohort, school: school, teacher: teacher, assignment: assignment}, allowed_project_ids, like_text, _portal_server) do
    ## If there are any empty-set filters, do not bother querying and just return nil.
    if (cohort == [] || school == [] || teacher == [] || assignment == []) do
      nil
    else
      query = %ReportFilterQuery{
        id: "ppf.id",
        value: "CONCAT(ap.name, ': ', ppf.name)",
        from: "portal_permission_forms ppf JOIN admin_projects ap ON ap.id = ppf.project_id",
        where: maybe_add_like(like_text, ["ppf.name LIKE ? or ap.name LIKE ?"]),
        order_by: "ppf.name",
        num_params: 2,
      }

      ## Several of the "where" clauses before are identical since we need to connect through teachers or classes
      ## That's ok since the later processing will remove duplicates.
      ## Just make sure that they are truly identical if they use the same table alias.

      query = if allowed_project_ids == :all do
        query
      else
        join = [
          "JOIN portal_student_permission_forms pspf ON pspf.portal_permission_form_id = ppf.id",
          "JOIN portal_student_clazzes psc ON psc.student_id = pspf.portal_student_id",
          "JOIN portal_teacher_clazzes ptc ON (ptc.clazz_id = psc.clazz_id)",
          "JOIN admin_cohort_items aci ON (aci.item_type = 'Portal::Teacher' AND aci.item_id = ptc.teacher_id)",
          "JOIN admin_cohorts ac ON (ac.id = aci.admin_cohort_id)"
        ]
        where = "ac.project_id IN #{list_to_in(allowed_project_ids)}"
        secondary_filter_query(query, join, where)
      end

      query = if cohort == nil do
        query
      else
        join = [
          "JOIN portal_student_permission_forms pspf ON pspf.portal_permission_form_id = ppf.id",
          "JOIN portal_student_clazzes psc ON psc.student_id = pspf.portal_student_id",
          "JOIN portal_teacher_clazzes ptc ON (ptc.clazz_id = psc.clazz_id)",
          "JOIN admin_cohort_items aci ON (aci.item_type = 'Portal::Teacher' AND aci.item_id = ptc.teacher_id)",
        ]
        where = "aci.admin_cohort_id IN #{list_to_in(cohort)}"
        secondary_filter_query(query, join, where)
      end

      query = if school == nil do
        query
      else
        join = [
          "JOIN portal_student_permission_forms pspf ON pspf.portal_permission_form_id = ppf.id",
          "JOIN portal_student_clazzes psc ON psc.student_id = pspf.portal_student_id",
          "JOIN portal_teacher_clazzes ptc ON (ptc.clazz_id = psc.clazz_id)",
          "JOIN portal_school_memberships psm ON (psm.member_id = ptc.teacher_id AND psm.member_type = 'Portal::Teacher')",
        ]
        where = "psm.school_id IN #{list_to_in(school)}"
        secondary_filter_query(query, join, where)
      end

      query = if teacher == nil do
        query
      else
        join = [
          "JOIN portal_student_permission_forms pspf ON pspf.portal_permission_form_id = ppf.id",
          "JOIN portal_student_clazzes psc ON psc.student_id = pspf.portal_student_id",
          "JOIN portal_teacher_clazzes ptc ON (ptc.clazz_id = psc.clazz_id)",
        ]
        where = "ptc.teacher_id IN #{list_to_in(teacher)}"
        secondary_filter_query(query, join, where)
      end

      query = if assignment == nil do
        query
      else
        join = [
          "JOIN portal_student_permission_forms pspf ON pspf.portal_permission_form_id = ppf.id",
          "JOIN portal_student_clazzes psc ON psc.student_id = pspf.portal_student_id",
          "JOIN portal_offerings po ON (po.clazz_id = psc.clazz_id AND po.runnable_type = 'ExternalActivity')"
        ]
        where = "po.runnable_id IN #{list_to_in(assignment)}"
        secondary_filter_query(query, join, where)
      end

      query
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
    "SELECT COUNT(DISTINCT #{id}) AS the_count FROM #{from} #{join_sql} #{where_sql}"
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
