defmodule ReportServer.Reports.Portal.ResourceMetricsSummaryReport do
  use ReportServer.Reports.Report, type: :portal

  def get_query(report_filter = %ReportFilter{}, _user = %User{}) do
    %ReportQuery{
      cols: [
        {"trim(ea.name)", "activity_name"},
        {"count(distinct pt.id)", "number_of_teachers"},
        {"count(distinct ps.id)", "number_of_schools"},
        {"count(distinct pc.id)", "number_of_classes"},
        {"count(distinct pl.student_id)", "number_of_students"}
      ],
      from: "external_activities ea",
      join: [[
        "join portal_offerings po on (po.runnable_id = ea.id)",
        "join portal_clazzes pc on (pc.id = po.clazz_id)",
        "join portal_teacher_clazzes ptc on (ptc.clazz_id = pc.id)",
        "join portal_teachers pt on (pt.id = ptc.teacher_id)",
        "left join portal_school_memberships psm on (psm.member_id = pt.id and psm.member_type = 'Portal::Teacher')",
        "left join portal_schools ps on (ps.id = psm.school_id)",
        "left join portal_student_clazzes psc on (psc.clazz_id = pc.id)",
        # The "exists" clause is so that portal_learners without runs don't count towards "# students started"
        "left join portal_learners pl on (pl.offering_id = po.id and pl.student_id = psc.student_id
          and exists (select 1 from portal_runs r2 where r2.learner_id = pl.id))",
        "left join portal_runs run on (run.learner_id = pl.id)",
      ]],
      group_by: "ea.id",
      order_by: [{"activity_name", :asc}]
    }
    |> apply_filters(report_filter)
  end

  defp apply_filters(report_query = %ReportQuery{},
      %ReportFilter{cohort: cohort, school: school, teacher: teacher, assignment: assignment, start_date: start_date, end_date: end_date}) do
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
        join, # use existing portal_schools (ps) join
        ["ps.id in #{list_to_in(school)} " | where]
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

    where = where
    |> apply_start_date(start_date)
    |> apply_end_date(end_date)

    ReportQuery.update_query(report_query, join: join, where: where)
  end
end