defmodule ReportServer.Reports.ResourceMetricsSummary do
  use ReportServer.Reports.Report

  def run(_filters) do
    dev_query_portal = "learn.concord.org"
    dev_query = """
    select
      trim(ea.name) as activity_name,
      count(distinct rl.teachers_id) as number_of_teachers,
      count(distinct rl.school_id) as number_of_schools,
      count(distinct rl.class_id) as number_of_classes,
      count(distinct rl.id) as number_of_students
    from
      external_activities ea
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
