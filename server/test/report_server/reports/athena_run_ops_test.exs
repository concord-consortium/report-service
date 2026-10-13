defmodule ReportServer.Reports.AthenaRunOpsTest do
  use ReportServer.DataCase, async: false

  import ReportServer.AccountsFixtures

  alias ReportServer.AthenaDB
  alias ReportServer.Reports
  alias ReportServer.Reports.Athena.{LearnerData, TeacherActionsReport}

  alias ReportServer.Reports.{
    AllowedProjectsLookupError,
    AthenaFailure,
    AthenaRunOps,
    Report,
    ReportFilter,
    ReportQuery,
    ReportRun,
    Tree
  }

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

      start_athena_stub(%{
        get_query_info: fn "qid-1" -> {:ok, "succeeded", "s3://bucket/out.csv", nil} end
      })

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

    test "persists the reason for a failed run" do
      user = user_fixture()
      run = run_fixture(user, %{athena_query_id: "qid-failed", athena_query_state: "running"})

      start_athena_stub(%{
        get_query_info: fn "qid-failed" ->
          {:ok, "failed", nil, "HIVE_EXCEEDED_PARTITION_LIMIT: too many"}
        end
      })

      assert {:ok, refreshed} = AthenaRunOps.refresh_query_state(run)
      assert refreshed.athena_query_error == "HIVE_EXCEEDED_PARTITION_LIMIT: too many"

      assert Reports.get_report_run!(run.id).athena_query_error ==
               "HIVE_EXCEEDED_PARTITION_LIMIT: too many"
    end

    test "persists the reason for a cancelled run" do
      user = user_fixture()
      run = run_fixture(user, %{athena_query_id: "qid-cancelled", athena_query_state: "running"})

      start_athena_stub(%{
        get_query_info: fn "qid-cancelled" ->
          {:ok, "cancelled", nil, "Query cancelled by user"}
        end
      })

      assert {:ok, refreshed} = AthenaRunOps.refresh_query_state(run)
      assert refreshed.athena_query_error == "Query cancelled by user"
      assert Reports.get_report_run!(run.id).athena_query_error == "Query cancelled by user"
    end

    test "persists nil when Athena reports no reason" do
      user = user_fixture()
      run = run_fixture(user, %{athena_query_id: "qid-ok", athena_query_state: "running"})

      start_athena_stub(%{
        get_query_info: fn "qid-ok" -> {:ok, "succeeded", "s3://bucket/out.csv", nil} end
      })

      assert {:ok, refreshed} = AthenaRunOps.refresh_query_state(run)
      assert refreshed.athena_query_error == nil
      assert Reports.get_report_run!(run.id).athena_query_error == nil
    end

    test "a reason past the column ceiling still leaves the run terminal" do
      user = user_fixture()
      run = run_fixture(user, %{athena_query_id: "qid-big", athena_query_state: "running"})
      oversized = String.duplicate("x", 70_000)
      start_athena_stub(%{get_query_info: fn "qid-big" -> {:ok, "failed", nil, oversized} end})

      assert {:ok, _} = AthenaRunOps.refresh_query_state(run)

      reloaded = Reports.get_report_run!(run.id)
      assert reloaded.athena_query_state == "failed"
      refute AthenaRunOps.non_terminal?(reloaded)
      assert byte_size(reloaded.athena_query_error) <= AthenaFailure.max_reason_bytes()
    end

    test "does not overwrite a terminal run's stored reason on a later poll" do
      user = user_fixture()

      run =
        run_fixture(user, %{
          athena_query_id: "qid-terminal",
          athena_query_state: "failed",
          athena_query_error: "HIVE_S3_THROTTLING: original"
        })

      start_athena_stub(%{get_query_info: fn _ -> raise "should not be called" end})

      assert {:ok, unchanged} = AthenaRunOps.refresh_query_state(run)
      assert unchanged.athena_query_error == "HIVE_S3_THROTTLING: original"
      assert Reports.get_report_run!(run.id).athena_query_error == "HIVE_S3_THROTTLING: original"
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

  describe "ensure_current/1 starting a run" do
    @retrying "The report could not be started because of a temporary error; it will be retried."
    @gave_up "The report could not be started because of a temporary error. Duplicate the run to try again."
    @abandoned "The report could not be started; the attempt to start it did not finish."

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

      updated = AthenaRunOps.ensure_current(reloaded)
      assert updated.athena_query_id == "athena-qid"
      assert updated.athena_query_state == "queued"

      assert_receive {:got_filter, filter}
      assert filter.filters == ["cohort"]
      assert filter.cohort == [1, 2]
    end

    for {name, message} <- [
          {"no learners in the learner data", LearnerData.no_learners_error()},
          {"no filters", ReportQuery.no_filters_error()},
          {"no learners in the query", ReportQuery.no_learners_error()},
          {"an unknown application", ReportQuery.unknown_app_error(["x"])},
          {"no teachers or activities", TeacherActionsReport.no_match_error()}
        ] do
      @message message

      test "fails at once when get_query reports #{name}" do
        run = unstarted_run()
        put_tree_report(athena_report(fn _filter, _user -> {:error, @message} end))
        start_athena_stub(%{query: fn _sql, _id, _user -> raise "query should not be called" end})

        assert_failed(AthenaRunOps.ensure_current(run), @message)
      end
    end

    test "fails at once for an unknown report" do
      run = unstarted_run()
      put_tree_report(nil)

      assert_failed(AthenaRunOps.ensure_current(run), "Unable to find report: student-answers")
    end

    test "fails at once for a query too large for Athena" do
      run = unstarted_run()
      put_tree_report(athena_report(fn _filter, _user -> {:ok, %ReportQuery{raw_sql: "SELECT 1"}} end))
      start_athena_stub(%{query: fn _sql, _id, _user -> {:error, AthenaDB.query_too_large_error()} end})

      assert_failed(AthenaRunOps.ensure_current(run), AthenaDB.query_too_large_error())
    end

    test "fails with a generic message, not the inspected detail, when a step returns an unexpected value" do
      run = unstarted_run()
      put_tree_report(athena_report(fn _filter, _user -> :unexpected end))

      assert_failed(AthenaRunOps.ensure_current(run), "An unexpected error occurred while running the report.")
    end

    test "a transient failure releases the run to be retried, and a later success clears the error" do
      run = unstarted_run()
      put_tree_report(athena_report(fn _filter, _user -> {:error, "Unable to upload the learner data for the report."} end))
      start_athena_stub(%{query: fn _sql, _id, _user -> raise "query should not be called" end})

      assert_retrying(AthenaRunOps.ensure_current(run))

      put_tree_report(athena_report(fn _filter, _user -> {:ok, %ReportQuery{raw_sql: "SELECT 1"}} end))
      Agent.update(ReportServer.AthenaDBStub, &Map.put(&1, :query, fn _sql, _id, _user -> {:ok, "athena-qid", "queued"} end))

      result = AthenaRunOps.ensure_current(reload(run))
      assert result.athena_query_id == "athena-qid"
      assert result.athena_query_error == nil

      reloaded = Reports.get_report_run!(run.id)
      assert reloaded.athena_query_id == "athena-qid"
      assert reloaded.athena_query_state == "queued"
      assert reloaded.athena_query_error == nil
    end

    test "a transient failure stores the retrying message, not its detail" do
      run = unstarted_run()
      put_tree_report(athena_report(fn _filter, _user -> {:ok, %ReportQuery{raw_sql: "SELECT 1"}} end))

      start_athena_stub(%{
        query: fn _sql, _id, _user -> {:error, "User: arn:aws:iam::1:user/x is not authorized"} end
      })

      assert_retrying(AthenaRunOps.ensure_current(run))
    end

    test "a transient failure on a run older than the retry window fails it" do
      run = unstarted_run() |> age(:inserted_at, 11 * 60)
      put_tree_report(athena_report(fn _filter, _user -> {:error, "Unable to upload the learner data for the report."} end))

      assert_failed(AthenaRunOps.ensure_current(run), @gave_up)
    end

    test "a transient failure on a run inside the retry window is retried" do
      run = unstarted_run() |> age(:inserted_at, 9 * 60)
      put_tree_report(athena_report(fn _filter, _user -> {:error, "Unable to upload the learner data for the report."} end))

      assert_retrying(AthenaRunOps.ensure_current(run))
    end

    test "a raise during the start is retried, not raised" do
      run = unstarted_run()
      put_tree_report(athena_report(fn _filter, _user -> raise AllowedProjectsLookupError end))

      assert_retrying(AthenaRunOps.ensure_current(run))
    end

    test "a claim older than the abandoned-claim bound fails the run without starting it" do
      user = user_fixture()
      run = run_fixture(user, %{athena_query_state: "queued"}) |> age(:updated_at, 31 * 60)
      put_tree_report(athena_report(fn _filter, _user -> raise "get_query should not be called" end))
      start_athena_stub(%{query: fn _sql, _id, _user -> raise "query should not be called" end})

      assert_failed(AthenaRunOps.ensure_current(run), @abandoned)
    end

    test "a claim inside the abandoned-claim bound is served untouched" do
      user = user_fixture()
      run = run_fixture(user, %{athena_query_state: "queued"}) |> age(:updated_at, 29 * 60)
      put_tree_report(athena_report(fn _filter, _user -> raise "get_query should not be called" end))

      result = AthenaRunOps.ensure_current(run)
      assert result.athena_query_state == "queued"
      assert result.athena_query_error == nil
      assert Reports.get_report_run!(run.id).athena_query_state == "queued"
    end

    test "a start's outcome does not overwrite a run failed while it ran" do
      run = unstarted_run()

      put_tree_report(
        athena_report(fn _filter, _user ->
          set_row(run, athena_query_state: "failed", athena_query_error: @abandoned)
          {:ok, %ReportQuery{raw_sql: "SELECT 1"}}
        end)
      )

      start_athena_stub(%{query: fn _sql, _id, _user -> {:ok, "athena-qid", "queued"} end})

      assert_failed(AthenaRunOps.ensure_current(run), @abandoned)
    end

    test "a start's outcome does not overwrite a later claim of the same run" do
      run = unstarted_run()
      reclaimed_at = DateTime.add(DateTime.utc_now(:second), 60)

      put_tree_report(
        athena_report(fn _filter, _user ->
          set_row(run, updated_at: reclaimed_at)
          {:ok, %ReportQuery{raw_sql: "SELECT 1"}}
        end)
      )

      start_athena_stub(%{query: fn _sql, _id, _user -> {:ok, "athena-qid", "queued"} end})

      result = AthenaRunOps.ensure_current(run)
      assert result.athena_query_id == nil
      assert result.athena_query_state == "queued"

      reloaded = Reports.get_report_run!(run.id)
      assert reloaded.athena_query_id == nil
      assert reloaded.updated_at == reclaimed_at
    end

    test "a start's outcome does not overwrite a run started while it ran" do
      run = unstarted_run()

      put_tree_report(
        athena_report(fn _filter, _user ->
          set_row(run, athena_query_id: "other-qid", athena_query_state: "running")
          {:error, LearnerData.no_learners_error()}
        end)
      )

      result = AthenaRunOps.ensure_current(run)
      assert result.athena_query_id == "other-qid"
      assert result.athena_query_state == "running"

      reloaded = Reports.get_report_run!(run.id)
      assert reloaded.athena_query_id == "other-qid"
      assert reloaded.athena_query_state == "running"
      assert reloaded.athena_query_error == nil
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

  defp unstarted_run() do
    user = user_fixture()
    run_fixture(user, %{}) |> with_user(user)
  end

  defp reload(run = %ReportRun{}), do: Reports.get_report_run_with_user!(run.id)

  defp set_row(run = %ReportRun{id: id}, changes) do
    Repo.update_all(from(r in ReportRun, where: r.id == ^id), set: changes)
    run
  end

  defp age(run = %ReportRun{}, field, seconds) do
    run
    |> set_row([{field, DateTime.add(DateTime.utc_now(:second), -seconds)}])
    |> reload()
  end

  defp assert_failed(result = %ReportRun{}, message) do
    assert result.athena_query_state == "failed"
    assert result.athena_query_error == message
    assert result.athena_query_id == nil

    reloaded = Reports.get_report_run!(result.id)
    assert reloaded.athena_query_state == "failed"
    assert reloaded.athena_query_error == message
    assert reloaded.athena_query_id == nil
  end

  defp assert_retrying(result = %ReportRun{}) do
    assert result.athena_query_state == nil
    assert result.athena_query_error == @retrying
    assert result.athena_query_id == nil

    reloaded = Reports.get_report_run!(result.id)
    assert reloaded.athena_query_state == nil
    assert reloaded.athena_query_error == @retrying
    assert reloaded.athena_query_id == nil
  end
end
