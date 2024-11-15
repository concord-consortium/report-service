defmodule ReportServer.Reports.ResourceMetricsSummary do
  use ReportServer.Reports.Report

  def run(_filters) do
    dev_query_portal = "learn.concord.org"
    dev_query = """
    select
      trim(ea.name) as activity_name,
      count(distinct pt.id) as number_of_teachers,
      count(distinct ps.id) as number_of_schools,
      count(distinct pc.id) as number_of_classes,
      count(distinct rl.id) as number_of_students
    from
      external_activities ea
      join portal_offerings po on (po.runnable_id = ea.id)
      join portal_clazzes pc on (pc.id = po.clazz_id)
      join portal_teacher_clazzes ptc on (ptc.clazz_id = pc.id)
      join portal_teachers pt on (pt.id = ptc.teacher_id)
      left join portal_school_memberships psm on (psm.member_id = pt.id and psm.member_type = 'Portal::Teacher')
      left join portal_schools ps on (ps.id = psm.school_id)
      left join report_learners rl on (rl.runnable_id = ea.id and rl.last_run is not null)
    where
      ea.id in (2304, 3091)
    group by
      ea.id
    order by
      ea.name
    """
    PortalDbs.query(dev_query_portal, dev_query)
  end

end
