defmodule ReportServerWeb.ReportRunShowLiveTest do
  use ReportServerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import ReportServer.AccountsFixtures

  alias ReportServer.Reports
  alias ReportServer.Reports.{Report, ReportFilter, ReportQuery}
  alias ReportServer.Reports.Athena.LearnerData

  @retrying "The report could not be started because of a temporary error; it will be retried."

  defmodule TreeStub do
    def find_report(_slug), do: Application.get_env(:report_server, :test_tree_report)
  end

  setup do
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

  test "mounting a never-started Athena run starts the query", %{conn: conn} do
    user = user_fixture()

    {:ok, run} =
      Reports.create_report_run(%{
        user_id: user.id,
        report_slug: "teacher-actions",
        report_filter: %ReportFilter{filters: [:cohort], cohort: [1]},
        report_filter_values: %{"cohort" => %{"1" => "Cohort One"}}
      })

    Application.put_env(:report_server, :athena_db, ReportServer.AthenaDBStub)
    Application.put_env(:report_server, :report_tree, TreeStub)

    Application.put_env(
      :report_server,
      :test_tree_report,
      %Report{
        type: :athena,
        slug: "teacher-actions",
        get_query: fn _filter, _user -> {:ok, %ReportQuery{raw_sql: "SELECT 1"}} end
      }
    )

    test_pid = self()

    start_athena_stub(%{
      query: fn _sql, _id, _user ->
        send(test_pid, :query)
        {:ok, "qid-teacher", "queued"}
      end,
      get_query_info: fn _ -> {:ok, "succeeded", "s3://bucket/out.csv", nil} end
    })

    conn = log_in_conn(conn, user)
    {:ok, view, _html} = live(conn, ~p"/reports/runs/#{run.id}")
    render_async(view)

    assert_receive :query
    eventually(fn -> Reports.get_report_run!(run.id).athena_query_id == "qid-teacher" end)
  end

  test "a stored running run refreshes its state on poll", %{conn: conn} do
    user = user_fixture()

    {:ok, run} =
      Reports.create_report_run(%{
        user_id: user.id,
        report_slug: "teacher-actions",
        report_filter: %ReportFilter{filters: [:cohort], cohort: [1]},
        report_filter_values: %{"cohort" => %{"1" => "Cohort One"}},
        athena_query_id: "qid-existing",
        athena_query_state: "running"
      })

    Application.put_env(:report_server, :athena_db, ReportServer.AthenaDBStub)
    test_pid = self()

    start_athena_stub(%{
      get_query_info: fn "qid-existing" ->
        send(test_pid, :get_query_info)
        {:ok, "succeeded", "s3://bucket/done.csv", nil}
      end
    })

    conn = log_in_conn(conn, user)
    {:ok, view, _html} = live(conn, ~p"/reports/runs/#{run.id}")
    render_async(view)

    send(view.pid, :poll_query_state)

    assert_receive :get_query_info
    eventually(fn -> render(view) =~ "Only CSV download is available" end)

    reloaded = Reports.get_report_run!(run.id)
    assert reloaded.athena_query_state == "succeeded"
    assert reloaded.athena_result_url == "s3://bucket/done.csv"
  end

  describe "a run that has not started" do
    test "a run that failed to start is not restarted", %{conn: conn} do
      user = user_fixture()
      run = failed_run(user, %{athena_query_id: nil, athena_query_error: LearnerData.no_learners_error()})
      test_pid = self()
      put_athena_report(fn _filter, _user -> send(test_pid, :get_query) end)

      html = render_run(conn, user, run)

      assert html =~ "failed"
      assert html =~ "No student work matches these filters."
      assert html =~ LearnerData.no_learners_error()
      refute_receive :get_query, 200

      reloaded = Reports.get_report_run!(run.id)
      assert reloaded.athena_query_state == "failed"
      assert reloaded.athena_query_error == LearnerData.no_learners_error()
    end

    test "a permanent failure on mount is shown", %{conn: conn} do
      user = user_fixture()
      run = unstarted_run(user)

      test_pid = self()

      put_athena_report(fn _filter, _user ->
        send(test_pid, :get_query)
        {:error, LearnerData.no_learners_error()}
      end)

      view = mount_run(conn, user, run)

      assert_receive :get_query
      eventually(fn -> render(view) =~ "No student work matches these filters." end)
      assert render(view) =~ "failed"
      assert Reports.get_report_run!(run.id).athena_query_state == "failed"
    end

    test "a retrying run shows why and is not retried at once", %{conn: conn} do
      user = user_fixture()
      run = unstarted_run(user)

      test_pid = self()

      put_athena_report(fn _filter, _user ->
        send(test_pid, :get_query)
        {:error, "Unable to upload the learner data for the report."}
      end)

      view = mount_run(conn, user, run)

      assert_receive :get_query
      eventually(fn -> render(view) =~ @retrying end)
      refute_receive :get_query, 300
    end

    test "closing the page mid-start does not strand the claim", %{conn: conn} do
      user = user_fixture()
      run = unstarted_run(user)
      test_pid = self()

      put_athena_report(fn _filter, _user ->
        send(test_pid, {:get_query, self()})

        receive do
          :unblock -> {:error, "Unable to upload the learner data for the report."}
        end
      end)

      view = mount_run(conn, user, run)
      assert_receive {:get_query, starter}

      Process.flag(:trap_exit, true)
      GenServer.stop(view.pid, {:shutdown, :closed})
      assert Process.alive?(starter)

      send(starter, :unblock)

      eventually(fn ->
        reloaded = Reports.get_report_run!(run.id)
        reloaded.athena_query_state == nil and reloaded.athena_query_error == @retrying
      end)
    end
  end
  defp failed_run(user, attrs) do
    {:ok, run} =
      Reports.create_report_run(
        Map.merge(
          %{
            user_id: user.id,
            report_slug: "teacher-actions",
            report_filter: %ReportFilter{filters: [:cohort], cohort: [1]},
            report_filter_values: %{"cohort" => %{"1" => "Cohort One"}},
            athena_query_id: "qid-failed",
            athena_query_state: "failed"
          },
          attrs
        )
      )

    run
  end

  defp render_run(conn, user, run) do
    conn = log_in_conn(conn, user)
    {:ok, view, _html} = live(conn, ~p"/reports/runs/#{run.id}")
    render_async(view)
  end

  defp mount_run(conn, user, run) do
    conn = log_in_conn(conn, user)
    {:ok, view, _html} = live(conn, ~p"/reports/runs/#{run.id}")
    render_async(view)
    view
  end

  defp unstarted_run(user) do
    {:ok, run} =
      Reports.create_report_run(%{
        user_id: user.id,
        report_slug: "teacher-actions",
        report_filter: %ReportFilter{filters: [:cohort], cohort: [1]},
        report_filter_values: %{"cohort" => %{"1" => "Cohort One"}}
      })

    run
  end

  defp put_athena_report(get_query) do
    Application.put_env(:report_server, :report_tree, TreeStub)
    Application.put_env(:report_server, :test_tree_report, %Report{type: :athena, slug: "teacher-actions", get_query: get_query})
  end

  # The page starts and refreshes runs in tasks it does not await, so their effects land later.
  defp eventually(condition, attempts \\ 50) do
    cond do
      condition.() -> :ok
      attempts == 0 -> flunk("the condition never held")
      true ->
        Process.sleep(20)
        eventually(condition, attempts - 1)
    end
  end

  describe "a failed run" do
    test "renders the suggestion, the raw reason and the query id", %{conn: conn} do
      user = user_fixture()
      run = failed_run(user, %{athena_query_error: "HIVE_EXCEEDED_PARTITION_LIMIT: too many"})

      html = render_run(conn, user, run)

      assert html =~ "This query covers too many Athena partitions"
      assert html =~ "HIVE_EXCEEDED_PARTITION_LIMIT: too many"
      assert html =~ "Athena query id: qid-failed"
    end

    test "renders an unmapped reason with no suggestion", %{conn: conn} do
      user = user_fixture()
      run = failed_run(user, %{athena_query_error: "HIVE_MYSTERY: something else"})

      html = render_run(conn, user, run)

      assert html =~ "HIVE_MYSTERY: something else"
      refute html =~ "Narrow it with"
    end

    test "a non-owner who is not an admin is redirected away from it", %{conn: conn} do
      owner = user_fixture()
      run = failed_run(owner, %{athena_query_error: "HIVE_EXCEEDED_PARTITION_LIMIT: too many"})
      stranger = user_fixture()

      conn = log_in_conn(conn, stranger)

      assert {:error, {:redirect, %{to: "/reports"}}} = live(conn, ~p"/reports/runs/#{run.id}")
    end

    test "an admin who does not own the run still sees the reason", %{conn: conn} do
      owner = user_fixture()
      run = failed_run(owner, %{athena_query_error: "HIVE_EXCEEDED_PARTITION_LIMIT: too many"})
      admin = user_fixture(%{portal_is_admin: true})

      html = render_run(conn, admin, run)

      assert html =~ "HIVE_EXCEEDED_PARTITION_LIMIT: too many"
    end
  end

  describe "a run with no failure reason" do
    test "renders the live region but no suggestion, reason or query id", %{conn: conn} do
      user = user_fixture()
      run = failed_run(user, %{athena_query_error: nil})

      html = render_run(conn, user, run)

      assert html =~ ~s(role="status")
      refute html =~ "Athena query id"
      refute html =~ "Narrow it with"
    end
  end
end
