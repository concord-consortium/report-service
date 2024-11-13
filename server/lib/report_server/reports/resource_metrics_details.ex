defmodule ReportServer.Reports.ResourceMetricsDetails do

  alias ReportServer.Reports.Report

  def new(report = %Report{}), do: %{report | run: &ReportServer.Reports.TeacherStatus.run/1 } # &run/1

  # add this back when not delegating to the teacher status report for initial development
  # def run(filters) do
  #   IO.inspect(filters, label: "Running #{__MODULE__}")
  # end

end
