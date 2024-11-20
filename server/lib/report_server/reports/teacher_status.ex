defmodule ReportServer.Reports.TeacherStatus do
  use ReportServer.Reports.Report

  def get_query(report_filter = %ReportFilter{}) do
    %ReportQuery{
      select: """
        concat(u.last_name, ', ', u.first_name) as teacher_name,
        u.email as teacher_email,
        trim(ea.name) as activity_name,
        pc.name as class_name,
        date(po.created_at) as date_assigned,
        (select count(*) from portal_student_clazzes psc where psc.clazz_id = pc.id) as num_students_in_class,
        count(distinct rl.student_id) as num_students_started,
        date(min(rl.last_run)) as date_of_first_use,
        date(max(rl.last_run)) as date_of_last_use
      """,
      from: "portal_teachers pt",
      join: [[
        "join users u on (u.id = pt.user_id)",
        "left join portal_teacher_clazzes ptc on (ptc.teacher_id = pt.id)",
        "left join portal_clazzes pc on (pc.id = ptc.clazz_id)",
        "left join portal_offerings po on (po.clazz_id = pc.id)",
        "left join external_activities ea on (po.runnable_id = ea.id)",
        "left join report_learners rl on (rl.class_id = pc.id and rl.runnable_id = ea.id and rl.last_run is not null)",
      ]],
      group_by: "u.id, ea.id, pc.id, po.id, ea.id",
      order_by: "u.last_name, u.first_name, trim(ea.name)"
    }
    |> apply_filters(report_filter)
  end

  defp apply_filters(report_query = %ReportQuery{},
      %ReportFilter{cohort: cohort, school: school, teacher: teacher, assignment: assignment, startDate: startDate, endDate: endDate}) do
    join = []
    where = []

    # check cohorts
    {join, where} = if have_filter?(cohort) do
      {
        [
          "left join admin_cohort_items aci_teacher on (aci_teacher.item_type = 'Portal::Teacher' and aci_teacher.item_id = pt.id)",
          "left join admin_cohort_items aci_assignment on (aci_assignment.item_type = 'ExternalActivity')"
          | join
        ],
        [
          "aci_teacher.admin_cohort_id in #{list_to_in(cohort)}",
          "aci_assignment.admin_cohort_id in #{list_to_in(cohort)} and aci_assignment.item_id = ea.id"
          | where
        ]
      }
    else
      {join, where}
    end

    {join, where} = if have_filter?(school) do
      # use all the teachers in the school(s)
      {
        ["left join portal_school_memberships psm on (psm.member_type = 'Portal::Teacher' and psm.member_id = pt.id)" | join],
        ["psm.school_id in #{list_to_in(school)} " | where]
      }
    else
      {join, where}
    end

    {join, where} = if have_filter?(teacher) do
      {join, ["pt.id in #{list_to_in(teacher)}" | where]}
    else
      {join, where}
    end

    {join, where} = if have_filter?(assignment) do
      {join, ["ea.id in #{list_to_in(assignment)}" | where]}
    else
      # use all assignments for the filtered teachers
      {join, where}
    end

    ReportQuery.update_query(report_query, join: join, where: where,
      startDate: startDate, endDate: endDate)
  end

end
