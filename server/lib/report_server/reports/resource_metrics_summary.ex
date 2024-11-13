defmodule ReportServer.Reports.ResourceMetricsSummary do
  alias ReportServer.PortalDbs
  alias ReportServer.Reports.Report
  alias ReportServer.Reports.ReportFilter

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
    dev_query_portal = "learn.concord.org" # FIXME
    where_clauses = ReportFilter.get_where_clauses(filters)
    dev_query = """
    select
      trim(external_activities.name) as activity_name,
      count(distinct report_learners.teachers_id) as number_of_teachers,
      count(distinct report_learners.school_id) as number_of_schools,
      count(distinct report_learners.class_id) as number_of_classes,
      count(distinct report_learners.id) as number_of_students
    from
      external_activities
      left join report_learners on (report_learners.runnable_id = external_activities.id and report_learners.last_run is not null)
    where
      #{where_clauses}
    group by
      external_activities.id
    order by
      external_activities.name
    """
    PortalDbs.query(dev_query_portal, dev_query)
  end

end
