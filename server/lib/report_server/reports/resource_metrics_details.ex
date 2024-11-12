defmodule ReportServer.Reports.ResourceMetricsDetails do
  alias ReportServer.PortalDbs
  alias ReportServer.Reports.Report

  def new() do
    %Report{
      slug: "resource-metrics-details",
      title: "Resource Metrics Details",
      subtitle: "Detail report on resource metrics",
      filters: [ "resource" ],
      run: &run/1 # &run/1
    }
  end

  def run(filters) do
    IO.inspect(filters, label: "Running #{__MODULE__}")
    dev_query_portal = "learn.concord.org" # FIXME
    dev_query = """
    select
      trim(ea.name) as activity_name,
      rl.teachers_name as teacher_name,
      rl.teachers_email as teacher_email,
      rl.school_id as school_id,
      rl.school_name as school_name,
      rl.teachers_district as school_district,
      rl.teachers_state as school_state,
      count(distinct rl.class_id) as number_of_classes,
      count(distinct rl.student_id) as number_of_students
    from
      external_activities ea
      left join report_learners rl on (rl.runnable_id = ea.id and rl.last_run is not null)
    where
      ea.id between 1 and 20
    group by
      ea.id, rl.teachers_name, rl.teachers_email, rl.school_id
    order by
      ea.name, rl.teachers_name
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
