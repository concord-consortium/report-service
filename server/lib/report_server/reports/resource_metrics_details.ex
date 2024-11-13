defmodule ReportServer.Reports.ResourceMetricsDetails do
  alias ReportServer.PortalDbs
  alias ReportServer.Reports.Report
  alias ReportServer.Reports.ReportFilter

  def new() do
    %Report{
      slug: "resource-metrics-details",
      title: "Resource Metrics Details",
      subtitle: "Detail report on resource metrics",
      filters: [ "cohort", "school", "teacher", "resource" ],
      run: &run/1 # &run/1
    }
  end

  def run(filters) do
    dev_query_portal = "learn.concord.org" # FIXME
    where_clauses = ReportFilter.get_where_clauses(filters)
    dev_query = """
    select
      trim(external_activities.name) as activity_name,
      report_learners.teachers_name as teacher_name,
      report_learners.teachers_email as teacher_email,
      report_learners.school_id as school_id,
      report_learners.school_name as school_name,
      report_learners.teachers_district as school_district,
      report_learners.teachers_state as school_state,
      count(distinct report_learners.class_id) as number_of_classes,
      count(distinct report_learners.student_id) as number_of_students
    from
      external_activities
      join report_learners on (report_learners.runnable_id = external_activities.id and report_learners.last_run is not null)
      join portal_schools on (portal_schools.id = report_learners.school_id)
      join portal_teachers on (portal_teachers.id = report_learners.teachers_id)
    where
      #{where_clauses}
    group by
      external_activities.id, report_learners.teachers_name, report_learners.teachers_email, report_learners.school_id
    order by
      external_activities.name, report_learners.teachers_name
    """
    PortalDbs.query(dev_query_portal, dev_query)
  end

  # Activity
  # Teacher Name
  # Teacher Email
  # School name
  # School country -- ?
  # School state
  # Grade level -- ?
  # Number of classes
  # Number of students
  # Date first assigned - TODO
  # Date first student use - TODO
  # Date last assigned - TODO
  # Date last student use - TODO

end
