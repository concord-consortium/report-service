defmodule ReportServer.Reports.TBDReport do
  use ReportServer.Reports.Report, tbd: true

  def get_query(_report_filter = %ReportFilter{}) do
    %ReportQuery{}
  end
end
