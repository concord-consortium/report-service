defmodule ReportServer.Reports.ResourceMetricsSummary do

  alias ReportServer.Reports.Report

  def new() do
    %Report{slug: "resource-metrics-summary", title: "Resource Metrics Summary", run: &__MODULE__.run/1}
  end

  def run(filters) do
    IO.inspect(filters, label: "Running #{__MODULE__}")
  end

end
