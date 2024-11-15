defmodule ReportServer.Reports.ResourceMetricsDetails do
  use ReportServer.Reports.Report

  # TODO Grade level -- does not return any results

  def run(_filters) do
    dev_query_portal = "learn.concord.org"
    dev_query = """
    select
      trim(ea.name) as activity_name,
      concat(u.last_name, ', ', u.first_name) as teacher_name,
      u.email as teacher_email,
      ps.name as school_name,
      pd.name as school_district,
      ps.state as school_state,
      pco.two_letter as school_country,
      count(distinct pc.id) as number_of_classes,
      pgl.name as grade_levels,
      count(distinct rl.student_id) as number_of_students,
      date(po.created_at) as first_assigned,
      date(min(rl.last_run)) as first_student_use,
      date(max(rl.last_run)) as most_recent_student_use
    from
      external_activities ea
      join portal_offerings po on (po.runnable_id = ea.id)
      join portal_clazzes pc on (pc.id = po.clazz_id)
      join portal_teacher_clazzes ptc on (ptc.clazz_id = pc.id)
      join portal_teachers pt on (pt.id = ptc.teacher_id)
      join users u on (u.id=pt.user_id)
      left join portal_grade_levels_teachers pglt on (pglt.teacher_id = pt.id)
      left join portal_grade_levels pgl on (pgl.id = pglt.grade_level_id)
      left join portal_school_memberships psm on (psm.member_id = pt.id and psm.member_type = 'Portal::Teacher')
      left join portal_schools ps on (ps.id = psm.school_id)
      left join portal_districts pd on (pd.id = ps.district_id)
      left join portal_countries pco on (pco.id = ps.country_id)
      left join report_learners rl on (rl.runnable_id = ea.id and rl.class_id = pc.id and rl.last_run is not null)
    where
      ea.id in (2304, 3091)
    group by
      ea.id, pt.id, u.id
    order by
      ea.name, u.last_name, u.first_name
    """
    PortalDbs.query(dev_query_portal, dev_query)
  end

end
