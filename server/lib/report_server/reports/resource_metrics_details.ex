defmodule ReportServer.Reports.ResourceMetricsDetails do
  use ReportServer.Reports.Report

  def run(_filters) do
    dev_query_portal = "learn.concord.org"
    dev_query = """
    select
      trim(ea.name) as activity_name,
      rl.teachers_name as teacher_name,
      rl.teachers_email as teacher_email,
      rl.school_name as school_name,
      'TBD' as school_country,
      rl.teachers_state as school_state,
      rl.teachers_district as school_district,
      count(distinct rl.class_id) as number_of_classes,
      'TBD' as grade_levels,
      count(distinct rl.student_id) as number_of_students,
      'TBD' as assigned,
      'TBD' as first_student_use,
      'TBD' as most_recent_student_use
    from
      external_activities ea
      join report_learners rl on (rl.runnable_id = ea.id and rl.last_run is not null)
      join portal_schools ps on (ps.id = rl.school_id)
      join portal_teachers pt on (pt.id = rl.teachers_id)
    where
      ea.id in (2304, 3091)
    group by
      ea.id, rl.teachers_name, rl.teachers_email, rl.school_id
    order by
      ea.name, rl.teachers_name
    """
    PortalDbs.query(dev_query_portal, dev_query)
  end

end
