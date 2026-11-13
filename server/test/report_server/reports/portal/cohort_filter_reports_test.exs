defmodule ReportServer.Reports.Portal.CohortFilterReportsTest do
  use ExUnit.Case, async: true

  alias ReportServer.Accounts.User
  alias ReportServer.Reports.{CohortFilter, ReportFilter, ReportQuery}
  alias ReportServer.Reports.Portal.{ResourceMetricsDetailsReport, ResourceMetricsSummaryReport, TeacherStatusReport}

  # These reports select columns the portal fixture does not carry, so they are checked by their SQL;
  # the rule itself runs against the fixture in CohortFilterDbTest. A site admin needs no portal read.
  @site_admin %User{portal_server: "portal.example.com", portal_is_admin: true}

  for report <- [TeacherStatusReport, ResourceMetricsSummaryReport, ResourceMetricsDetailsReport] do
    test "#{inspect(report)} admits a cohort's activities through the shared rule" do
      filter = %ReportFilter{filters: [:cohort], cohort: [6], exclude_internal: false}
      {:ok, query} = unquote(report).get_query(filter, @site_admin)
      {:ok, sql} = ReportQuery.get_sql(query)

      assert sql =~ CohortFilter.activity_in_cohorts("ea.id", [6])
      refute sql =~ "aci_assignment"
    end
  end
end
