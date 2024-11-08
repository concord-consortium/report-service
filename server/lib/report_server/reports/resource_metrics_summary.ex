defmodule ReportServer.Reports.ResourceMetricsSummary do
  alias ReportServer.PortalDbs
  alias ReportServer.Reports.Report

  def new() do
    %Report{
      slug: "resource-metrics-summary",
      title: "Resource Metrics Summary",
      subtitle: "Summary report on resource metrics",
      filters: [ "resource" ],
      run: &run/1
    }
  end

  def run(filters) do
    IO.inspect(filters, label: "Running #{__MODULE__}")
    dev_query_portal = "learn.concord.org" # FIXME
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
      ea.id between 1 and 20
    group by
      ea.id
    order by
      ea.name
    """
    PortalDbs.query(dev_query_portal, dev_query)
  end

end
