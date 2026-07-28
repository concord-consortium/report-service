defmodule ReportServer.Reports.Portal.TeacherStatusReportTest do
  use ExUnit.Case, async: true

  alias ReportServer.Reports.{ReportFilter, ReportQuery}
  alias ReportServer.Reports.Portal.TeacherStatusReport
  alias ReportServer.Accounts.User

  defp sql_for(user) do
    filter = %ReportFilter{filters: [:teacher], teacher: [3], exclude_internal: false}
    {:ok, query} = TeacherStatusReport.get_query(filter, user)
    {:ok, sql} = ReportQuery.get_sql(query)
    sql
  end

  test "a super-admin applies no project scoping" do
    sql = sql_for(%User{portal_server: "portal.example.com", portal_is_admin: true})
    refute sql =~ "project_id IN"
    refute sql =~ "1 = 0"
  end

  test "a user with no allowed projects constrains to zero rows with valid SQL, not IN ()" do
    # all role flags false -> get_allowed_project_ids/1 returns :none with no portal-DB call
    sql = sql_for(%User{portal_server: "portal.example.com"})
    assert sql =~ "1 = 0"
    refute sql =~ "IN ()"
  end
end
