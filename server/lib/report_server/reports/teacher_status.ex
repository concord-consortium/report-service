defmodule ReportServer.Reports.TeacherStatus do
  alias ReportServer.PortalDbs
  alias ReportServer.Reports.Report

  def new(report = %Report{}), do: %{report | run: &run/1}

  # real query - rename when Boris can connect to db
  def run(_filters) do
    dev_query_portal = "learn.concord.org"
    dev_query = """
    select
      concat(u.first_name, ' ', u.last_name) as teacher_name,
      u.email as teacher_email,
      trim(ea.name) as activity_name,
      pc.name as class_name,
        date(po.created_at) as date_assigned,
        (select count(*) from portal_student_clazzes psc where psc.clazz_id = pc.id) as num_students_in_class,
        count(rl.id) as num_students_started,
        min(rl.last_run) as date_of_first_use,
        max(rl.last_run) as date_of_last_use
    from
      users u
    left join portal_teachers pt on (pt.user_id = u.id)
    left join portal_teacher_clazzes ptc on (ptc.teacher_id = pt.id)
    left join portal_clazzes pc on (pc.id = ptc.clazz_id)
    left join portal_offerings po on (po.clazz_id = pc.id)
    left join external_activities ea on (po.runnable_id = ea.id)
    left join report_learners rl on (rl.class_id = pc.id and rl.runnable_id = ea.id and rl.last_run is not null)
    where
      email = 'dmartin@concord.org'
    group by
      u.id, ea.id, pc.id, po.id, ea.id
    order by
      u.first_name, trim(ea.name)
    """

    PortalDbs.query(dev_query_portal, dev_query)
  end
end
