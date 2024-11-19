defmodule ReportServer.Reports.ReportFilterQuery do
  require Logger
  alias ReportServer.PortalDbs
  alias ReportServer.Reports.{ReportFilter, ReportFilterQuery}

  defstruct id: nil, value: nil, from: nil, join: [], where: [], order_by: nil, num_params: 1

  def get_options(report_filter = %ReportFilter{}, like_text \\ "") do
    {query, params} = get_query_and_params(report_filter, like_text)
    sql = get_options_sql(query)

    dev_query_portal = "learn.concord.org" # FIXME
    case PortalDbs.query(dev_query_portal, sql, params) do
      {:ok, result} ->
        {:ok, Enum.map(result.rows, fn [id, value] -> {value, to_string(id)} end), sql, params}
      {:error, error} ->
        Logger.error(error)
        {:error, error, sql, params}
    end
  end

  def get_counts(report_filter = %ReportFilter{}, like_text \\ "") do
    {query, params} = get_query_and_params(report_filter, like_text)
    sql = get_counts_sql(query)

    dev_query_portal = "learn.concord.org" # FIXME
    case PortalDbs.query(dev_query_portal, sql, params) do
      {:ok, result} ->
        # TODO: fix
        {:ok, Enum.map(result.rows, fn [id, value] -> {value, to_string(id)} end), sql, params}
      {:error, error} ->
        Logger.error(error)
        {:error, error, sql, params}
    end
  end

  defp get_query_and_params(report_filter = %ReportFilter{filters: [primary_filter | _secondary_filters]}, like_text) do
    query = get_filter_query(primary_filter, report_filter, like_text)
    params = like_params(like_text, query)
    {query, params}
  end

  defp get_filter_query(:cohort, %ReportFilter{school: school, teacher: teacher, assignment: assignment}, like_text) do
    query = %ReportFilterQuery{
      id: "admin_cohorts.id",
      value: "admin_cohorts.name",
      from: "admin_cohorts",
      where: maybe_add_like(like_text, ["admin_cohorts.name LIKE ?"]),
      order_by: "admin_cohorts.name"
    }

    query = if Enum.empty?(school) do
      query
    else
      join = [
       "JOIN admin_cohort_items aci_school ON (aci_school.item_type = 'Portal::Teacher')",
       "JOIN portal_school_memberships psm_school ON (psm_school.member_type = 'Portal::Teacher' AND psm_school.member_id = aci_school.item_id)"
      ]
      where = "psm_school.school_id IN #{list_to_in(school)}"
      secondary_filter_query(query, join, where)
    end

    query = if Enum.empty?(teacher) do
      query
    else
      join = "JOIN admin_cohort_items aci_teacher ON (aci_teacher.item_type = 'Portal::Teacher')"
      where = "aci_teacher.item_id IN #{list_to_in(teacher)}"
      secondary_filter_query(query, join, where)
    end

    query = if Enum.empty?(assignment) do
      query
    else
      join = "JOIN admin_cohort_items aci_assignment ON (aci_assignment.item_type = 'ExternalActivity')"
      where = "aci_assignment.item_id IN #{list_to_in(assignment)}"
      secondary_filter_query(query, join, where)
    end

    query
  end

  defp get_filter_query(:school, %ReportFilter{cohort: cohort, teacher: teacher, assignment: assignment}, like_text) do
    query = %ReportFilterQuery{
      id: "portal_schools.id",
      value: "portal_schools.name",
      from: "portal_schools",
      where: maybe_add_like(like_text, ["portal_schools.name LIKE ?"]),
      order_by: "portal_schools.name"
    }

    query = if Enum.empty?(cohort) do
      query
    else
      join = [
        "JOIN portal_school_memberships psm_cohort ON (psm_cohort.member_type = 'Portal::Teacher' AND psm_cohort.school_id = portal_schools.id)",
        "JOIN admin_cohort_items aci_cohort ON (aci_cohort.item_type = 'Portal::Teacher' AND aci_cohort.item_id = psm_cohort.member_id)"
      ]
      where = "aci_cohort.admin_cohort_id IN #{list_to_in(cohort)}"
      secondary_filter_query(query, join, where)
    end

    query = if Enum.empty?(teacher) do
      query
    else
      join = "JOIN portal_school_memberships psm_teacher ON (psm_teacher.member_type = 'Portal::Teacher' AND psm_teacher.school_id = portal_schools.id)"
      where = "psm_teacher.member_id IN #{list_to_in(teacher)}"
      secondary_filter_query(query, join, where)
    end

    query = if Enum.empty?(assignment) do
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

    query
  end

  defp get_filter_query(:teacher, %ReportFilter{cohort: cohort, school: school, assignment: assignment}, like_text) do
    query = %ReportFilterQuery{
      id: "portal_teachers.id",
      value: "CONCAT(users.first_name, ' ', users.last_name, ' <', users.email, '>') AS fullname",
      from: "portal_teachers",
      join: ["JOIN users ON users.id = portal_teachers.user_id"],
      where: maybe_add_like(like_text, ["users.first_name LIKE ? OR users.last_name LIKE ? OR users.email LIKE ?"]),
      order_by: "fullname",
      num_params: 3
    }

    query = if Enum.empty?(cohort) do
      query
    else
      join = "JOIN admin_cohort_items aci_cohort ON (aci_cohort.item_type = 'Portal::Teacher' AND aci_cohort.item_id = portal_teachers.id)"
      where = "aci_cohort.admin_cohort_id IN #{list_to_in(cohort)}"
      secondary_filter_query(query, join, where)
    end

    query = if Enum.empty?(school) do
      query
    else
      join = "JOIN portal_school_memberships psm_school ON (psm_school.member_type = 'Portal::Teacher' AND psm_school.member_id = portal_teachers.id)"
      where = "psm_school.school_id IN #{list_to_in(school)}"
      secondary_filter_query(query, join, where)
    end

    query = if Enum.empty?(assignment) do
      query
    else
      join = [
        "JOIN portal_teacher_clazzes ptc_assignment ON (ptc_assignment.teacher_id = portal_teachers.id)",
        "JOIN portal_offerings po_assignment ON (po_assignment.clazz_id = ptc_assignment.clazz_id AND po_assignment.runnable_type = 'ExternalActivity')"
      ]
      where = "po_assignment.runnable_id IN #{list_to_in(assignment)}"
      secondary_filter_query(query, join, where)
    end

    query
  end

  defp get_filter_query(:assignment, %ReportFilter{cohort: cohort, school: school, teacher: teacher}, like_text) do
    query = %ReportFilterQuery{
      id: "external_activities.id",
      value: "external_activities.name",
      from: "external_activities",
      where: maybe_add_like(like_text, ["external_activities.name LIKE ?"]),
      order_by: "external_activities.name",
    }

    query = if Enum.empty?(cohort) do
      query
    else
      join = "JOIN admin_cohort_items aci_cohort ON (aci_cohort.item_type = 'ExternalActivity' AND aci_cohort.item_id = external_activities.id)"
      where = "aci_cohort.admin_cohort_id IN #{list_to_in(cohort)}"
      secondary_filter_query(query, join, where)
    end

    query = if Enum.empty?(school) do
      query
    else
      join = [
        "JOIN portal_offerings po_school ON (po_school.runnable_type = 'ExternalActivity' AND po_school.runnable_id = external_activities.id)",
        "JOIN portal_teacher_clazzes ptc_school ON (ptc_school.clazz_id = po_school.clazz_id)",
        "JOIN portal_school_memberships psm_school ON (psm_school.member_type = 'Portal::Teacher' AND psm_school.member_id = ptc_school.teacher_id)"
      ]
      where = "psm_school.school_id IN #{list_to_in(school)}"
      secondary_filter_query(query, join, where)
    end

    query = if Enum.empty?(teacher) do
      query
    else
      join = [
        "JOIN portal_offerings po_teacher ON (po_teacher.runnable_type = 'ExternalActivity' AND po_teacher.runnable_id = external_activities.id)",
        "JOIN portal_teacher_clazzes ptc_teacher ON (ptc_teacher.clazz_id = po_teacher.clazz_id)",
      ]
      where = "ptc_teacher.teacher_id IN #{list_to_in(teacher)}"
      secondary_filter_query(query, join, where)
    end

    query
  end

  defp list_to_in(list) do
    "(#{list |> Enum.map(&Integer.to_string/1) |> Enum.join(",")})"
  end

  defp secondary_filter_query(query, join, where) do
    %{query | join: [ join | query.join ], where: [ where | query.where ]}
  end

  defp get_options_sql(%{id: id, value: value, from: from, join: join, where: where, order_by: order_by} = %ReportFilterQuery{}) do
    {join_sql, where_sql} = get_join_where_sql(join, where)
    "SELECT DISTINCT #{id}, #{value} FROM #{from} #{join_sql} #{where_sql} ORDER BY #{order_by}"
  end

  defp get_counts_sql(%{id: id, from: from, join: join, where: where} = %ReportFilterQuery{}) do
    {join_sql, where_sql} = get_join_where_sql(join, where)
    "SELECT COUNT(DISTINCT #{id}) AS the_count FROM #{from} #{join_sql} #{where_sql}"
  end

  defp get_join_where_sql(join, where) do
    # NOTE: the reverse is before flatten to keep any sublists in order
    join_sql = join |> Enum.reverse() |> List.flatten() |> Enum.join(" ")
    where_sql = where |> Enum.reverse() |> List.flatten() |> Enum.map(&("(#{&1})")) |> Enum.join(" AND ")
    where_sql = if String.length(where_sql) > 0, do: "WHERE #{where_sql}", else: ""
    {join_sql, where_sql}
  end

  defp maybe_add_like("", _where), do: []
  defp maybe_add_like(_like_text, where), do: where

  defp like_params("", %ReportFilterQuery{}), do: []
  defp like_params(like_text, %ReportFilterQuery{num_params: num_params}), do: List.duplicate("%#{like_text}%", num_params)
end
