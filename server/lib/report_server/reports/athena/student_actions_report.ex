defmodule ReportServer.Reports.Athena.StudentActionsReport do
  use ReportServer.Reports.Report, type: :athena

  alias ReportServer.PortalDbs

  def get_query(report_filter = %ReportFilter{}, user = %User{}) do
    case get_run_remote_endpoints(report_filter, user) do
      {:ok, run_remote_endpoints} ->
        hide_names = report_filter.hide_names
        remove_username = false

        if !Enum.empty?(run_remote_endpoints) do
          {:ok, %ReportQuery{
            cols: ReportQuery.get_log_cols(hide_names: hide_names, remove_username: remove_username),
            from: "\"#{ReportQuery.get_log_db_name()}\".\"logs_by_time\" log",
            where: [["\"log\".\"run_remote_endpoint\" IN #{string_list_to_single_quoted_in(run_remote_endpoints)}"]]
          }}
        else
          {:error, "No learners found to match the requested filter(s)."}
        end

      error -> error
    end
  end

  defp get_run_remote_endpoints(%ReportFilter{cohort: cohort, school: school, teacher: teacher, assignment: assignment, permission_form: permission_form, start_date: start_date, end_date: end_date}, user = %User{}) do
    portal_query = %ReportQuery{
      cols: [{"DISTINCT pl.secure_key", "secure_key"}],
      from: "portal_learners pl",
      join: [[
        "JOIN report_learners rl ON (rl.learner_id = pl.id)",
        "JOIN portal_offerings po ON (po.id = rl.offering_id)",
        "JOIN portal_student_clazzes psc ON (psc.student_id = rl.student_id)",
        "JOIN portal_teacher_clazzes ptc ON (ptc.clazz_id = psc.clazz_id)",
        "LEFT JOIN portal_runs run on (run.learner_id = pl.id)",
      ]]
    }

    join = []
    where = []

    allowed_project_ids = PortalDbs.get_allowed_project_ids(user)
    {join, where} = if allowed_project_ids == :all do
      {join, where}
    else
      {
        [
          "join admin_cohort_items aci_teacher on (aci_teacher.item_type = 'Portal::Teacher' AND aci_teacher.item_id = ptc.teacher_id)",
          "join admin_cohort_items aci_assignment on (aci_assignment.item_type = 'ExternalActivity' AND aci_assignment.item_id = po.runnable_id)",
          "join admin_cohorts ac_teacher ON (ac_teacher.id = aci_teacher.admin_cohort_id)",
          "join admin_cohorts ac_assignment ON (ac_assignment.id = aci_assignment.admin_cohort_id)"
          | join
        ],
        [
          "ac_teacher.project_id IN #{list_to_in(allowed_project_ids)}",
          "ac_assignment.project_id IN #{list_to_in(allowed_project_ids)}"
          | where
        ]
      }
    end

    {join, where} = if have_filter?(cohort) do
      {
        [
          "join admin_cohort_items aci_teacher on (aci_teacher.item_type = 'Portal::Teacher' AND aci_teacher.item_id = ptc.teacher_id)",
          "join admin_cohort_items aci_assignment on (aci_assignment.item_type = 'ExternalActivity' AND aci_assignment.item_id = po.runnable_id)"
          | join
        ],
        [
          "aci_teacher.admin_cohort_id in #{list_to_in(cohort)}",
          "aci_assignment.admin_cohort_id in #{list_to_in(cohort)}"
          | where
        ]
      }
    else
      {join, where}
    end

    {join, where} = if have_filter?(permission_form) do
      {
        [
          "JOIN portal_student_permission_forms pspf ON (pspf.portal_student_id = psc.student_id)"
          | join
        ],
        [
          "pspf.portal_permission_form_id IN #{list_to_in(permission_form)}"
          | where
        ]
      }
    else
      {join, where}
    end

    where = where
      |> apply_where_filter(school, "rl.school_id IN #{list_to_in(school)}")
      |> apply_where_filter(teacher, "ptc.teacher_id IN #{list_to_in(teacher)}")
      |> apply_where_filter(assignment, "po.runnable_id IN #{list_to_in(assignment)}")
      |> apply_start_date(start_date)
      |> apply_end_date(end_date)

    with {:ok, portal_query} <- ReportQuery.update_query(portal_query, join: join, where: where),
         {:ok, sql} <- ReportQuery.get_sql(portal_query),
         {:ok, result} <- PortalDbs.query(user.portal_server, sql) do
      {:ok, Enum.map(result.rows, fn [secure_key] -> "https://#{user.portal_server}/dataservice/external_activity_data/#{secure_key}" end)}
    else
      error -> error
    end
  end
end
