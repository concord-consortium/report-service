defmodule ReportServer.Reports.ResourceMetricsDetails do
  use ReportServer.Reports.Report

  def get_query(report_filter = %ReportFilter{}) do
    %ReportQuery{
      select: """
        trim(ea.name) as activity_name,
        concat(u.last_name, ', ', u.first_name) as teacher_name,
        u.email as teacher_email,
        ps.name as school_name,
        pd.name as school_district,
        ps.state as school_state,
        pco.two_letter as school_country,
        count(distinct pc.id) as number_of_classes,
        (select group_concat(tags.name order by cast(tags.name as unsigned))
          from taggings
          join tags on (taggings.tag_id = tags.id)
          where
            taggings.taggable_type = 'ExternalActivity'
            and taggings.taggable_id = ea.id
            and taggings.context = 'grade_levels'
          group by taggings.taggable_id
          ) as grade_levels,
        count(distinct rl.student_id) as number_of_students,
        date(po.created_at) as first_assigned,
        date(min(rl.last_run)) as first_student_use,
        date(max(rl.last_run)) as most_recent_student_use
      """,
      from: "external_activities ea",
      join: [[
        "join portal_offerings po on (po.runnable_id = ea.id)",
        "join portal_clazzes pc on (pc.id = po.clazz_id)",
        "join portal_teacher_clazzes ptc on (ptc.clazz_id = pc.id)",
        "join portal_teachers pt on (pt.id = ptc.teacher_id)",
        "join users u on (u.id=pt.user_id)",
        "left join portal_school_memberships psm on (psm.member_id = pt.id and psm.member_type = 'Portal::Teacher')",
        "left join portal_schools ps on (ps.id = psm.school_id)",
        "left join portal_districts pd on (pd.id = ps.district_id)",
        "left join portal_countries pco on (pco.id = ps.country_id)",
        "left join report_learners rl on (rl.class_id = pc.id and rl.runnable_id = ea.id and rl.last_run is not null)"
      ]],
      group_by: "ea.id, pt.id, u.id",
      order_by: "ea.name, u.last_name, u.first_name"
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

    ReportQuery.update_query(report_query, join: join, where: where,
      startDate: startDate, endDate: endDate)
  end

end
