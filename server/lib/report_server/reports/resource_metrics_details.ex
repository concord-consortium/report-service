defmodule ReportServer.Reports.ResourceMetricsDetails do

  alias ReportServer.Reports.Report

  def new() do
    %Report{
      slug: "resource-metrics-details",
      title: "Resource Metrics Details",
      subtitle: "Detail report on resource metrics",
      filters: [ "resource" ],
      run: &ReportServer.Reports.TeacherStatus.run/1 # &run/1
    }
  end

  # add this back when not delegating to the teacher status report for initial development
  # def run(filters) do
  #   IO.inspect(filters, label: "Running #{__MODULE__}")
  # end

end
