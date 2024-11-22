defmodule ReportServer.Reports.TBDReport do
  use ReportServer.Reports.Report, type: :portal, tbd: true

  def get_query(_report_filter = %ReportFilter{}, _user = %User{}) do
    %ReportQuery{}
  end
end
