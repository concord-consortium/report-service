defmodule ReportServer.Reports.AthenaRunOpsTest do
  use ReportServer.DataCase, async: false

  import ReportServer.AccountsFixtures

  alias ReportServer.Reports
  alias ReportServer.Reports.{AthenaRunOps, Report, ReportFilter, ReportQuery, ReportRun, Tree}

  defmodule TreeStub do
    def find_report(_slug), do: Application.get_env(:report_server, :test_tree_report)
  end

  setup do
    Application.put_env(:report_server, :athena_db, ReportServer.AthenaDBStub)
    Application.put_env(:report_server, :report_tree, TreeStub)

    on_exit(fn ->
      Application.delete_env(:report_server, :athena_db)
      Application.delete_env(:report_server, :report_tree)
      Application.delete_env(:report_server, :test_tree_report)
    end)

    :ok
  end

  defp start_athena_stub(responses) do
    {:ok, pid} = ReportServer.AthenaDBStub.start(responses)
    on_exit(fn -> if Process.alive?(pid), do: Agent.stop(pid) end)
    pid
  end

  defp put_tree_report(report), do: Application.put_env(:report_server, :test_tree_report, report)

  defp run_fixture(user, attrs) do
    {:ok, run} =
      Reports.create_report_run(
        Map.merge(%{user_id: user.id, report_slug: "student-answers"}, attrs)
      )

    run
  end

  describe "refresh_query_state/1" do
    test "persists both athena_query_state and athena_result_url for a non-terminal run" do
      user = user_fixture()
      run = run_fixture(user, %{athena_query_id: "qid-1", athena_query_state: "running"})
      start_athena_stub(%{get_query_info: fn "qid-1" -> {:ok, "succeeded", "s3://bucket/out.csv"} end})

      assert {:ok, refreshed} = AthenaRunOps.refresh_query_state(run)
      assert refreshed.athena_query_state == "succeeded"
      assert refreshed.athena_result_url == "s3://bucket/out.csv"

      reloaded = Reports.get_report_run!(run.id)
      assert reloaded.athena_query_state == "succeeded"
      assert reloaded.athena_result_url == "s3://bucket/out.csv"
    end

    test "is a no-op for a terminal run and does not call Athena" do
      user = user_fixture()
      run = run_fixture(user, %{athena_query_id: "qid-2", athena_query_state: "succeeded", athena_result_url: "s3://existing"})
      start_athena_stub(%{get_query_info: fn _ -> raise "should not be called" end})

      assert {:ok, unchanged} = AthenaRunOps.refresh_query_state(run)
      assert unchanged.athena_query_state == "succeeded"
      assert unchanged.athena_result_url == "s3://existing"
    end

    test "returns the error and leaves stored fields untouched when Athena fails" do
      user = user_fixture()
      run = run_fixture(user, %{athena_query_id: "qid-3", athena_query_state: "running"})
      start_athena_stub(%{get_query_info: fn _ -> {:error, "boom"} end})

      assert {:error, "boom"} = AthenaRunOps.refresh_query_state(run)

      reloaded = Reports.get_report_run!(run.id)
      assert reloaded.athena_query_state == "running"
      assert reloaded.athena_result_url == nil
    end
  end

  describe "ensure_current/1" do
    test "serves the stored run without raising when the refresh fails" do
      user = user_fixture()
      run = run_fixture(user, %{athena_query_id: "qid-4", athena_query_state: "running"})
      start_athena_stub(%{get_query_info: fn _ -> {:error, "boom"} end})

      result = AthenaRunOps.ensure_current(run)
      assert result.id == run.id
      assert result.athena_query_state == "running"
    end

    test "releases the claim and serves the stored run when self-start fails" do
      user = user_fixture()
      run = run_fixture(user, %{}) |> with_user(user)
      put_tree_report(athena_report(fn _filter, _user -> {:ok, %ReportQuery{raw_sql: "SELECT 1"}} end))
      start_athena_stub(%{query: fn _sql, _id, _user -> {:error, "boom"} end})

      result = AthenaRunOps.ensure_current(run)
      assert result.athena_query_id == nil

      reloaded = Reports.get_report_run!(run.id)
      assert reloaded.athena_query_id == nil
      assert reloaded.athena_query_state == nil
    end

    test "single-flight winning path claims the row and runs the start" do
      user = user_fixture()
      run = run_fixture(user, %{}) |> with_user(user)
      put_tree_report(athena_report(fn _filter, _user -> {:ok, %ReportQuery{raw_sql: "SELECT 1"}} end))
      start_athena_stub(%{query: fn _sql, _id, _user -> {:ok, "athena-qid", "queued"} end})

      result = AthenaRunOps.ensure_current(run)
      assert result.athena_query_id == "athena-qid"

      reloaded = Reports.get_report_run!(run.id)
      assert reloaded.athena_query_id == "athena-qid"
      assert reloaded.athena_query_state == "queued"
    end

    test "single-flight losing path serves the claimed row without touching the stubs" do
      user = user_fixture()
      run = run_fixture(user, %{athena_query_state: "queued"})
      put_tree_report(athena_report(fn _filter, _user -> raise "get_query should not be called" end))
      start_athena_stub(%{query: fn _sql, _id, _user -> raise "query should not be called" end})

      result = AthenaRunOps.ensure_current(run)
      assert result.athena_query_id == nil
      assert result.athena_query_state == "queued"
    end

    test "single-flight stale-struct loser reflects the claimed state, not the stale nil" do
      user = user_fixture()
      run = run_fixture(user, %{}) |> with_user(user)
      put_tree_report(athena_report(fn _filter, _user -> {:ok, %ReportQuery{raw_sql: "SELECT 1"}} end))
      start_athena_stub(%{query: fn _sql, _id, _user -> {:ok, "athena-qid", "queued"} end})

      _first = AthenaRunOps.ensure_current(run)
      second = AthenaRunOps.ensure_current(run)

      assert second.athena_query_id == nil
      assert second.athena_query_state == "queued"
    end
  end

  describe "start_query/1" do
    test "passes the loaded (round-tripped) filter form to the report's get_query and persists the result" do
      user = user_fixture()

      run =
        run_fixture(user, %{report_filter: %ReportFilter{filters: [:cohort], cohort: [1, 2]}})

      reloaded = Reports.get_report_run_with_user!(run.id)

      test_pid = self()

      put_tree_report(
        athena_report(fn filter, _user ->
          send(test_pid, {:got_filter, filter})
          {:ok, %ReportQuery{raw_sql: "SELECT 1"}}
        end)
      )

      start_athena_stub(%{query: fn _sql, _id, _user -> {:ok, "athena-qid", "queued"} end})

      assert {:ok, updated} = AthenaRunOps.start_query(reloaded)
      assert updated.athena_query_id == "athena-qid"
      assert updated.athena_query_state == "queued"

      assert_receive {:got_filter, filter}
      assert filter.filters == ["cohort"]
      assert filter.cohort == [1, 2]
    end

    test "returns a generic message (not the inspected detail) when a step returns an unexpected value" do
      user = user_fixture()
      run = run_fixture(user, %{}) |> with_user(user)
      put_tree_report(athena_report(fn _filter, _user -> :unexpected end))

      assert {:error, "An unexpected error occurred while running the report."} =
               AthenaRunOps.start_query(run)
    end
  end

  describe "Tree.athena_report_slugs/0" do
    test "returns exactly the five Athena slugs and no portal slugs" do
      assert Enum.sort(Tree.athena_report_slugs()) ==
               Enum.sort(~w(
                 student-actions
                 student-actions-with-metadata
                 student-answers
                 student-assignment-usage
                 teacher-actions
               ))
    end
  end

  defp athena_report(get_query) do
    %Report{type: :athena, slug: "student-answers", get_query: get_query}
  end

  defp with_user(run = %ReportRun{}, user), do: %{run | user: user}
end
