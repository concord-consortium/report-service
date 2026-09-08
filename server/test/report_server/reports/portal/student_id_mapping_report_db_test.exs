defmodule ReportServer.Reports.Portal.StudentIdMappingReportDbTest do
  use ExUnit.Case, async: false

  @moduletag :portal_db

  alias ReportServer.{PortalDbs, PortalFixture}
  alias ReportServer.Accounts.User
  alias ReportServer.Reports.{ReportFilter, ReportQuery}
  alias ReportServer.Reports.Portal.StudentIdMappingReport

  @server PortalFixture.server()

  defp filter(class \\ [601, 602]), do: %ReportFilter{filters: [:class], class: class}
  defp admin, do: %User{portal_server: @server, portal_is_admin: true}

  defp query_for(user, filter \\ filter()) do
    {:ok, query} = StudentIdMappingReport.get_query(filter, user)
    query
  end

  defp learner_ids(user), do: user |> run() |> Enum.map(& &1.learner_id)

  defp run(user, filter \\ filter()) do
    query = query_for(user, filter)
    {:ok, sql} = ReportQuery.get_sql(query)
    {:ok, result} = PortalDbs.query(@server, sql)
    PortalDbs.map_columns_on_rows(result)
  end

  test "a learner whose joins fan out is emitted once" do
    rows = run(admin(), filter([601]))

    assert Enum.map(rows, & &1.learner_id) == [901, 902]
  end

  test "a filter selecting one learner emits exactly one row" do
    assert run(admin(), %ReportFilter{filters: [:student], student: [71]}) |> Enum.map(& &1.learner_id) ==
             [901]
  end

  test "the row count the web UI computes matches the rows the report emits" do
    query = query_for(admin(), filter([601]))
    {:ok, count_sql} = ReportQuery.get_count_sql(query)
    {:ok, result} = PortalDbs.query(@server, count_sql)

    assert [[2]] = result.rows
    assert length(run(admin(), filter([601]))) == 2
  end

  test "run_remote_endpoint is byte-identical to the string LearnerData builds in Elixir" do
    rows = run(admin())
    by_learner = Map.new(rows, &{&1.learner_id, &1})

    assert by_learner[901].run_remote_endpoint ==
             "https://#{@server}/dataservice/external_activity_data/SECUREKEY123"

    assert by_learner[902].run_remote_endpoint ==
             "https://#{@server}/dataservice/external_activity_data/"
  end

  test "a learner with no runnable_url is emitted rather than dropped" do
    rows = run(admin())
    by_learner = Map.new(rows, &{&1.learner_id, &1})

    assert by_learner[902].runnable_url == nil
    assert by_learner[901].runnable_url =~ "activity.example.org"
  end

  test "a filter matching no learners is a zero-row success, not an error" do
    assert run(admin(), filter([9999])) == []
  end

  test "hide_names changes neither the SQL nor the rows" do
    hidden = run(admin(), %{filter() | hide_names: true})
    shown = run(admin(), %{filter() | hide_names: false})

    assert hidden == shown
  end

  describe "project scoping" do
    test "a project admin sees a strict subset of what a super-admin sees" do
      scoped = learner_ids(%User{portal_server: @server, portal_is_project_admin: true, portal_user_id: 555})
      unscoped = learner_ids(admin())

      assert scoped != []
      assert unscoped != []
      assert scoped -- unscoped == []
      assert length(scoped) < length(unscoped)
    end

    test "a project researcher is scoped by their project, like a project admin" do
      researcher =
        learner_ids(%User{portal_server: @server, portal_is_project_researcher: true, portal_user_id: 557})

      project_admin =
        learner_ids(%User{portal_server: @server, portal_is_project_admin: true, portal_user_id: 555})

      assert researcher != []
      assert researcher == project_admin
      assert length(researcher) < length(learner_ids(admin()))
    end

    test "a role-less caller gets zero rows rather than an error, on both surfaces" do
      assert_zero_rows(%User{portal_server: @server})
    end

    test "a project admin with no projects gets zero rows rather than an error, on both surfaces" do
      assert_zero_rows(%User{portal_server: @server, portal_is_project_admin: true, portal_user_id: 556})
    end
  end

  # the web run page reads through query/4 and counts through get_count_sql/1, and the API download
  # reads through stream_query/4; the grouping that satisfies ONLY_FULL_GROUP_BY has to hold for all
  # three, and scoping a caller with no projects must render a false predicate rather than an empty
  # `IN ()`, which is a MySQL syntax error
  defp assert_zero_rows(user) do
    query = query_for(user)
    {:ok, sql} = ReportQuery.get_sql(query)
    {:ok, count_sql} = ReportQuery.get_count_sql(query)

    assert {:ok, %{rows: []}} = PortalDbs.query(@server, sql)
    assert {:ok, %{rows: [[0]]}} = PortalDbs.query(@server, count_sql)

    assert {:ok, 0} =
             PortalDbs.stream_query(@server, sql, [],
               acc: 0,
               max_rows: 500,
               reducer: fn result, acc -> acc + length(result.rows) end
             )
  end
end
