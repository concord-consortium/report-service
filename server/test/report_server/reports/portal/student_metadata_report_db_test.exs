defmodule ReportServer.Reports.Portal.StudentMetadataReportDbTest do
  use ExUnit.Case, async: false

  @moduletag :portal_db

  alias ReportServer.{PortalDbs, PortalFixture}
  alias ReportServer.Accounts.User
  alias ReportServer.Reports.{ReportFilter, ReportQuery}
  alias ReportServer.Reports.Portal.{StudentIdMappingReport, StudentMetadataReport}

  @server PortalFixture.server()
  @salt "pinned.salt"
  @teacher_columns [:teacher_user_ids, :teacher_names, :teacher_emails, :teacher_districts, :teacher_states]

  setup do
    athena = Application.get_env(:report_server, :athena, [])
    Application.put_env(:report_server, :athena, Keyword.put(athena, :hide_username_hash_salt, @salt))
    on_exit(fn -> Application.put_env(:report_server, :athena, athena) end)
  end

  defp filter(class \\ [601, 602]), do: %ReportFilter{filters: [:class], class: class}
  defp admin, do: %User{portal_server: @server, portal_is_admin: true}

  defp run(filter \\ filter(), user \\ admin()) do
    {:ok, query} = StudentMetadataReport.get_query(filter, user)
    {:ok, sql} = ReportQuery.get_sql(query)
    {:ok, result} = PortalDbs.query(@server, sql)
    {result, PortalDbs.map_columns_on_rows(result)}
  end

  defp by_learner(rows), do: Map.new(rows, &{&1.learner_id, &1})
  defp split(nil), do: []
  defp split(value), do: String.split(value, ",")

  test "the five teacher columns carry one entry per teacher, aligned by index" do
    {_result, rows} = run()
    row = by_learner(rows)[901]

    assert Enum.map(@teacher_columns, &split(row[&1])) == [
             ["31", "32"],
             ["Ann Teach", "Bob Teach"],
             ["ann@e.org", "bob@e.org"],
             ["Dist W", "Dist Y"],
             ["NH", "MA"]
           ]
  end

  test "the district and the state at each index come from the same school" do
    {_result, rows} = run()
    row = by_learner(rows)[901]

    pairs = Enum.zip(split(row.teacher_districts), split(row.teacher_states))

    assert pairs == [{"Dist W", "NH"}, {"Dist Y", "MA"}],
           "Dist W is in NH and Dist Y in MA; a crossed pair means the two columns chose different schools"
  end

  test "a teacher with no school and an id with no teacher row keep their positions" do
    {_result, rows} = run()
    row = by_learner(rows)[903]

    assert split(row.teacher_names) == ["Ann Teach", "Cid Teach", "Gone Teach"]
    assert split(row.teacher_districts) == ["Dist W", "", ""]
    assert split(row.teacher_states) == ["NH", "", ""]

    for column <- @teacher_columns do
      assert length(split(row[column])) == 3, "#{column} lost a position"
    end
  end

  test "a learner with no teachers at all yields empty cells rather than failing the statement" do
    {_result, rows} = run()
    row = by_learner(rows)[904]

    for column <- @teacher_columns do
      assert row[column] in [nil, ""]
    end
  end

  test "the raised GROUP_CONCAT ceiling is what keeps the teacher lists whole" do
    {:ok, query} = StudentMetadataReport.get_query(filter(), admin())
    {:ok, sql} = ReportQuery.get_sql(query)
    {:ok, generous} = PortalDbs.query(@server, sql)

    tiny = String.replace(sql, "group_concat_max_len=1048576", "group_concat_max_len=8")
    {:ok, cut} = PortalDbs.query(@server, tiny)

    assert generous.num_warnings == 0
    assert cut.num_warnings > 0, "a tiny ceiling must truncate, or this guard proves nothing"

    assert by_learner(PortalDbs.map_columns_on_rows(generous))[901].teacher_districts ==
             "Dist W,Dist Y"

    assert by_learner(PortalDbs.map_columns_on_rows(cut))[901].teacher_districts == "Dist W,D"
  end

  test "the hidden username equals the digest the Athena expression produces" do
    {_result, rows} = run(%{filter() | hide_names: true})
    row = by_learner(rows)[901]

    assert row.username == Base.encode16(:crypto.hash(:sha, @salt <> "stu.one"))
    assert row.student_name == row.student_id
  end

  test "names are present when hide_names is off" do
    {_result, rows} = run(%{filter() | hide_names: false})
    row = by_learner(rows)[901]

    assert row.student_name == "Stu One"
    assert row.username == "stu.one"
  end

  test "every list column separates on a bare comma" do
    {_result, rows} = run()
    row = by_learner(rows)[901]

    for column <- @teacher_columns ++ [:permission_forms] do
      refute row[column] =~ ", ", "#{column} still carries the portal's ', ' separator"
    end

    assert row.permission_forms == "Proj A: Form 1,Proj B: Form 2"
  end

  test "last_run renders as an ISO-8601 string, and an absent one as an empty cell" do
    {_result, rows} = run()
    by = by_learner(rows)

    assert by[901].last_run == "2026-05-01T10:00:00"
    assert by[902].last_run == nil
    assert by[902].teacher_names == "Ann Teach,Bob Teach"
  end

  test "the two reports emit the same learners and join 1:1 on learner_id" do
    {_result, metadata_rows} = run()

    {:ok, mapping_query} = StudentIdMappingReport.get_query(filter(), admin())
    {:ok, mapping_sql} = ReportQuery.get_sql(mapping_query)
    {:ok, mapping_result} = PortalDbs.query(@server, mapping_sql)
    mapping_rows = PortalDbs.map_columns_on_rows(mapping_result)

    assert Enum.map(metadata_rows, & &1.learner_id) == Enum.map(mapping_rows, & &1.learner_id)
    assert length(metadata_rows) == 4

    for {metadata, mapping} <- Enum.zip(metadata_rows, mapping_rows) do
      assert metadata.run_remote_endpoint == mapping.run_remote_endpoint
    end
  end

  test "the row count the web UI computes matches the rows the report emits" do
    {:ok, query} = StudentMetadataReport.get_query(filter(), admin())
    {:ok, count_sql} = ReportQuery.get_count_sql(query)
    {:ok, count_result} = PortalDbs.query(@server, count_sql)
    {_result, rows} = run()

    assert [[4]] = count_result.rows
    assert length(rows) == 4
    refute count_sql =~ "GROUP_CONCAT", "the count discards the select list, hint and all"
  end

  test "one row per learner for a single-learner filter" do
    {_result, rows} = run(%ReportFilter{filters: [:student], student: [71]})

    assert Enum.map(rows, & &1.learner_id) == [901]
  end

  test "a caller with no allowed projects gets zero rows rather than an error" do
    {:ok, query} = StudentMetadataReport.get_query(filter(), %User{portal_server: @server})
    {:ok, sql} = ReportQuery.get_sql(query)

    assert {:ok, %{rows: []}} = PortalDbs.query(@server, sql)

    assert {:ok, 0} =
             PortalDbs.stream_query(@server, sql, [],
               acc: 0,
               max_rows: 500,
               reducer: fn result, acc -> acc + length(result.rows) end
             )
  end
end
