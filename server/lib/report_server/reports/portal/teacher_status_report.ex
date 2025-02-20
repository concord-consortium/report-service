defmodule ReportServer.Reports.Portal.TeacherStatusReport do
  use ReportServer.Reports.Report, type: :portal

  def get_query(report_filter = %ReportFilter{}, user = %User{}) do
    %ReportQuery{
      cols: [
        {"concat(u.last_name, ', ', u.first_name)", "teacher_name"},
        {"u.email", "teacher_email"},
        {"trim(ea.name)", "activity_name"},
        {"pc.name", "class_name"},
        {"date(po.created_at)", "date_assigned"},
        {"(select count(*) from portal_student_clazzes psc where psc.clazz_id = pc.id)", "num_students_in_class"},
        {"count(distinct pl.student_id)", "num_students_started"},
        {"count(distinct run.id)", "number_of_runs"},
        {"date(min(run.start_time))", "first_run"},
        {"date(max(run.start_time))", "last_run"}
      ],
      from: "portal_teachers pt",
      join: [[
        "join users u on (u.id = pt.user_id)",
        "join portal_teacher_clazzes ptc on (ptc.teacher_id = pt.id)",
        "join portal_clazzes pc on (pc.id = ptc.clazz_id)",
        "join portal_offerings po on (po.clazz_id = pc.id)",
        "join external_activities ea on (po.runnable_id = ea.id)",
        "left join portal_student_clazzes psc on (psc.clazz_id = pc.id)",
        # The "exists" clause is so that portal_learners without runs don't count towards "# students started"
        "left join portal_learners pl on (pl.offering_id = po.id and pl.student_id = psc.student_id
          and exists (select 1 from portal_runs r2 where r2.learner_id = pl.id))",
        "left join portal_runs run on (run.learner_id = pl.id)",
      ]],
      group_by: "u.id, ea.id, pc.id, po.id, ea.id",
      order_by: [{"teacher_name", :asc}, {"activity_name", :asc}]
    }
    |> apply_filters(report_filter, user)
  end

  defp apply_filters(report_query = %ReportQuery{},
      %ReportFilter{cohort: cohort, school: school, teacher: teacher, assignment: assignment,
        exclude_internal: exclude_internal, start_date: start_date, end_date: end_date}, user = %User{}) do
    join = []
    where = []

    where = exclude_internal_accounts(where, exclude_internal)

    {join, where} = apply_allowed_project_ids_filter(user, join, where, "ea.id", "pt.id")

    # check cohorts
    {join, where} = if have_filter?(cohort) do
      {
        [
          "join admin_cohort_items aci_teacher on (aci_teacher.item_type = 'Portal::Teacher' and aci_teacher.item_id = pt.id)",
          "join admin_cohort_items aci_assignment on (aci_assignment.item_type = 'ExternalActivity' and aci_assignment.item_id = ea.id)"
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
        ["join portal_school_memberships psm on (psm.member_type = 'Portal::Teacher' and psm.member_id = pt.id)" | join],
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

    where = where
    |> apply_start_date(start_date)
    |> apply_end_date(end_date)

    ReportQuery.update_query(report_query, join: join, where: where)
  end

end
