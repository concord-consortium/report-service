defmodule ReportServer.Reports do
  alias ReportServer.Reports.{
    TeacherStatus,
    ResourceMetricsSummary,
    ResourceMetricsDetails
  }

  def list() do
    [
      TeacherStatus.new(),
      ResourceMetricsSummary.new(),
      ResourceMetricsDetails.new()
    ]
  end

  def find(slug) do
    Enum.find(list(), &(&1.slug == slug))
  end
end
