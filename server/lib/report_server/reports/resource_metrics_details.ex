defmodule ReportServer.Reports.ResourceMetricsDetails do

  alias ReportServer.Reports.Report

  def new() do
    %Report{slug: "resource-metrics-details", title: "Resource Metrics Details", run: &__MODULE__.run/1}
  end

  def run(filters) do
    IO.inspect(filters, label: "Running #{__MODULE__}")
  end

end
