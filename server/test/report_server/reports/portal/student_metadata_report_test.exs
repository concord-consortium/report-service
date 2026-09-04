defmodule ReportServer.Reports.Portal.StudentMetadataReportTest do
  use ExUnit.Case, async: true

  alias ReportServer.Accounts.User
  alias ReportServer.Reports.{LearnerBaseQuery, ReportFilter, ReportQuery, ReportRun, Tree}
  alias ReportServer.Reports.Portal.StudentMetadataReport
  alias ReportServerWeb.Api.V1.ReportJSON

  @columns ~w(learner_id user_id primary_user_id student_id class_id school_id run_remote_endpoint
              student_name username class school teacher_user_ids teacher_names teacher_emails
              teacher_districts teacher_states permission_forms last_run)

  defp filter, do: %ReportFilter{filters: [:class], class: [601]}
  defp admin, do: %User{portal_server: "portal.example.com", portal_is_admin: true}

  defp sql_for(user, filter \\ filter()) do
    {:ok, query} = StudentMetadataReport.get_query(filter, user)
    {:ok, sql} = ReportQuery.get_sql(query)
    sql
  end

  defp select_list(sql), do: sql |> String.split(" FROM report_learners", parts: 2) |> List.first()

  test "emits the eighteen columns, in order" do
    emitted =
      ~r/ AS (\w+)/
      |> Regex.scan(select_list(sql_for(admin())))
      |> Enum.map(&List.last/1)

    assert emitted == @columns
    assert length(@columns) == 18
  end

  test "carries the join keys the mapping report emits, so it can stand alone" do
    sql = sql_for(admin())

    for col <- ~w(learner_id user_id primary_user_id student_id run_remote_endpoint) do
      assert sql =~ " AS #{col}"
    end
  end

  test "substitutes the student_id and a hash under hide_names" do
    sql = sql_for(admin(), %{filter() | hide_names: true})

    assert sql =~ "rl.student_id AS student_name"
    assert sql =~ "UPPER(SHA1(CONCAT("
    refute sql =~ "rl.student_name AS student_name"
    refute sql =~ "rl.username AS username"
  end

  test "selects the names themselves when hide_names is off" do
    sql = sql_for(admin(), %{filter() | hide_names: false})

    assert sql =~ "rl.student_name AS student_name"
    assert sql =~ "rl.username AS username"
    refute sql =~ "SHA1"
  end

  test "normalizes the portal's list separator so the file has one splitting rule" do
    sql = sql_for(admin())

    for col <- ~w(teachers_id teachers_name teachers_email) do
      assert sql =~ "REPLACE(rl.#{col}, ', ', ',')"
    end
  end

  test "derives the teacher districts and states from the teacher id list, not from the cache" do
    sql = sql_for(admin())

    assert sql =~ "JSON_TABLE(CONCAT('[', REPLACE(COALESCE(rl.teachers_id, ''), ' ', ''), ']')"
    refute sql =~ "rl.teachers_district"
    refute sql =~ "rl.teachers_state"
  end

  test "reads both district and state from one school, chosen by the lowest id" do
    sql = sql_for(admin())

    assert length(Regex.scan(~r/ORDER BY ps\.id LIMIT 1/, sql)) == 2
    refute sql =~ "MIN(pd."
  end

  test "keeps a position for a teacher with no district" do
    assert sql_for(admin()) =~ "GROUP_CONCAT(COALESCE("
  end

  test "raises the GROUP_CONCAT ceiling for its own statement only" do
    sql = sql_for(admin())

    assert String.starts_with?(sql, "SELECT /*+ SET_VAR(group_concat_max_len=1048576) */")
    refute sql =~ "SET SESSION"
  end

  test "renders last_run in the shape the Athena reports emit" do
    assert sql_for(admin()) =~ "DATE_FORMAT(rl.last_run, '%Y-%m-%dT%H:%i:%s')"
  end

  test "collapses with a grouping that survives the scoping clause, not with DISTINCT" do
    sql = sql_for(admin())

    assert sql =~ "GROUP BY #{LearnerBaseQuery.group_by()}"
    refute sql =~ "DISTINCT"
  end

  test "orders by learner_id so its rows line up with the mapping report's" do
    assert sql_for(admin()) =~ "ORDER BY learner_id asc"
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
             StudentMetadataReport.get_query(%ReportFilter{}, admin())
  end

  test "offers the hide-names option and nothing else" do
    assert Tree.find_report("student-metadata").form_options == [enable_hide_names: true]
  end

  test "both reports are exposed through the v1 API by the type-based mechanism" do
    for slug <- ["student-id-mapping", "student-metadata"] do
      report = Tree.find_report(slug)

      assert report.type == :portal
      assert report.api_report_type == nil
      assert report.derives_learner_data, "#{slug} must be accepted by the bulk endpoints"
      assert slug in Tree.api_report_slugs()
      refute slug in Tree.athena_report_slugs()
    end
  end

  test "a run of either report reports a sync execution and a null report_type" do
    now = DateTime.utc_now()

    for slug <- ["student-id-mapping", "student-metadata"] do
      json =
        ReportJSON.show(%ReportRun{
          id: 1,
          report_slug: slug,
          report_filter: filter(),
          inserted_at: now,
          updated_at: now
        })

      assert json.execution == "sync"
      assert json.report_type == nil
    end
  end
end
