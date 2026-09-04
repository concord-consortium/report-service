defmodule ReportServer.Reports.Portal.StudentIdMappingReportTest do
  use ExUnit.Case, async: true

  alias ReportServer.Accounts.User
  alias ReportServer.Reports.{LearnerBaseQuery, ReportFilter, ReportQuery, Tree}
  alias ReportServer.Reports.Portal.StudentIdMappingReport
  alias ReportServer.Reports.ReportRun
  alias ReportServerWeb.Api.V1.ReportJSON

  @columns ~w(learner_id user_id primary_user_id student_id class_id offering_id runnable_url
              run_remote_endpoint)

  defp filter, do: %ReportFilter{filters: [:class], class: [601]}
  defp admin, do: %User{portal_server: "portal.example.com", portal_is_admin: true}

  defp sql_for(user, filter \\ filter()) do
    {:ok, query} = StudentIdMappingReport.get_query(filter, user)
    {:ok, sql} = ReportQuery.get_sql(query)
    sql
  end

  defp select_list(sql), do: sql |> String.split(" FROM ", parts: 2) |> List.first()

  test "emits the identifier columns, in order, and nothing else" do
    emitted =
      ~r/ AS (\w+)/
      |> Regex.scan(select_list(sql_for(admin())))
      |> Enum.map(&List.last/1)

    assert emitted == @columns
  end

  test "carries no name, username or secure_key column" do
    sql = sql_for(admin())

    refute sql =~ "student_name"
    refute sql =~ "username"
    refute sql =~ "class_name"
    refute sql =~ "school_name"
    refute sql =~ "teachers"
    refute sql =~ "AS secure_key"
  end

  test "collapses with a grouping that survives the scoping clause, not with DISTINCT" do
    sql = sql_for(admin())

    assert sql =~ "GROUP BY #{LearnerBaseQuery.group_by()}"
    refute sql =~ "DISTINCT"
  end

  test "orders by learner_id so repeated runs and the two reports agree row for row" do
    assert sql_for(admin()) =~ "ORDER BY learner_id asc"
  end

  test "hide_names changes nothing about the generated SQL" do
    hidden = sql_for(admin(), %{filter() | hide_names: true})
    shown = sql_for(admin(), %{filter() | hide_names: false})

    assert hidden == shown
  end

  test "a super-admin applies no project scoping" do
    sql = sql_for(admin())

    refute sql =~ "project_id IN"
    refute sql =~ "1 = 0"
  end

  test "a user with no allowed projects constrains to zero rows with valid SQL, not IN ()" do
    sql = sql_for(%User{portal_server: "portal.example.com"})

    assert sql =~ "1 = 0"
    refute sql =~ "IN ()"
  end

  test "a super-admin with no filters at all is rejected rather than run unscoped" do
    assert {:error, "Cannot run query with no filters"} =
             StudentIdMappingReport.get_query(%ReportFilter{}, admin())
  end

  test "the report is exposed through the v1 API by the type-based mechanism" do
    report = Tree.find_report("student-id-mapping")

    assert report.type == :portal
    assert report.api_report_type == nil
    assert report.derives_learner_data, "the bulk endpoints derive their learner set from this run"
    assert "student-id-mapping" in Tree.api_report_slugs()
    refute "student-id-mapping" in Tree.athena_report_slugs()
  end

  test "the report offers no form options" do
    assert Tree.find_report("student-id-mapping").form_options == []
  end

  test "a run of the report reports a sync execution and a null report_type" do
    now = DateTime.utc_now()

    json =
      ReportJSON.show(%ReportRun{
        id: 1,
        report_slug: "student-id-mapping",
        report_filter: filter(),
        inserted_at: now,
        updated_at: now
      })

    assert json.execution == "sync"
    assert json.report_type == nil
  end
end
