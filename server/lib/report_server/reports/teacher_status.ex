defmodule ReportServer.Reports.TeacherStatus do
  alias ReportServer.PortalDbs
  alias ReportServer.Reports.Report
  alias ReportServer.Reports.ReportFilter

  def new() do
    %Report{
      slug: "teacher-status",
      title: "Teacher Status",
      subtitle: "Teacher status report",
      filters: [ "cohort", "school", "teacher" ],
      run: &run/1
    }
  end

  # real query - rename when Boris can connect to db
  def run(filters) do
    dev_query_portal = "learn.concord.org" # FIXME
    where_clauses = ReportFilter.get_where_clauses(filters)
    dev_query = """
    select
      concat(users.first_name, ' ', users.last_name) as teacher_name,
      users.email as teacher_email,
      trim(external_activities.name) as activity_name,
      portal_clazzes.name as class_name,
        date(portal_offerings.created_at) as date_assigned,
        (select count(*) from portal_student_clazzes psc where psc.clazz_id = portal_clazzes.id) as num_students_in_class,
        count(report_learners.id) as num_students_started,
        min(report_learners.last_run) as date_of_first_use,
        max(report_learners.last_run) as date_of_last_use
    from
      users
      left join portal_teachers on (portal_teachers.user_id = users.id)
      left join portal_teacher_clazzes on (portal_teacher_clazzes.teacher_id = portal_teachers.id)
      left join portal_clazzes on (portal_clazzes.id = portal_teacher_clazzes.clazz_id)
      left join portal_offerings on (portal_offerings.clazz_id = portal_clazzes.id)
      left join external_activities on (portal_offerings.runnable_id = external_activities.id)
      left join report_learners on (report_learners.class_id=portal_clazzes.id and report_learners.runnable_id=external_activities.id and report_learners.last_run is not null)
    where
      #{where_clauses}
    group by
      users.id, external_activities.id, portal_clazzes.id, portal_offerings.id, external_activities.id
    order by
      users.first_name, trim(external_activities.name)
    """

    PortalDbs.query(dev_query_portal, dev_query)
  end
end
