defmodule ReportServerWeb.ReportRunDownloadAuditTest do
  use ReportServerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import ReportServer.AccountsFixtures

  alias ReportServer.AuditLog.DataAccessLogEntry
  alias ReportServer.PostProcessing.Job
  alias ReportServer.Repo
  alias ReportServer.Reports
  alias ReportServer.Reports.{Report, ReportFilter}
  alias ReportServerWeb.ReportLive.PostProcessingComponent
  alias ReportServerWeb.ReportRunLive.Show

  setup do
    on_exit(fn -> Application.delete_env(:report_server, :athena_db) end)
    :ok
  end

  defp start_athena_stub(responses) do
    Application.put_env(:report_server, :athena_db, ReportServer.AthenaDBStub)
    {:ok, pid} = ReportServer.AthenaDBStub.start(responses)
    on_exit(fn -> if Process.alive?(pid), do: Agent.stop(pid) end)
  end

  defp entry_count(), do: Repo.aggregate(DataAccessLogEntry, :count)

  defp succeeded_run(user, slug) do
    {:ok, run} =
      Reports.create_report_run(%{
        user_id: user.id,
        report_slug: slug,
        report_filter: %ReportFilter{filters: [:cohort], cohort: [1]},
        report_filter_values: %{"cohort" => %{"1" => "Cohort One"}},
        athena_query_id: "qid",
        athena_query_state: "succeeded",
        athena_result_url: "s3://bucket/result.csv"
      })

    run
  end

  describe "run-page CSV download" do
    test "writes a web/run_csv audit row and starts the download", %{conn: conn} do
      user = user_fixture()
      run = succeeded_run(user, "teacher-actions")
      start_athena_stub(%{get_download_url: fn _url, _filename -> {:ok, "https://presigned"} end})

      {:ok, view, _html} = live(log_in_conn(conn, user), ~p"/reports/runs/#{run.id}")
      render_async(view)

      render_hook(view, "download_report", %{})

      assert entry_count() == 1
      entry = Repo.one!(DataAccessLogEntry)
      assert entry.source == "web"
      assert entry.data_type == "run_csv"
      assert entry.job_id == nil
      assert entry.user_id == user.id
      assert entry.report_run_id == run.id
    end

    test "a presign failure flashes an error and writes no audit row", %{conn: conn} do
      user = user_fixture()
      run = succeeded_run(user, "teacher-actions")
      start_athena_stub(%{get_download_url: fn _url, _filename -> {:error, "presign failed"} end})

      {:ok, view, _html} = live(log_in_conn(conn, user), ~p"/reports/runs/#{run.id}")
      render_async(view)

      html = render_hook(view, "download_report", %{})

      assert html =~ "presign failed"
      assert entry_count() == 0
    end

    test "records the requesting admin when downloading another user's run", %{conn: conn} do
      owner = user_fixture()
      admin = user_fixture(%{portal_is_admin: true})
      run = succeeded_run(owner, "teacher-actions")
      start_athena_stub(%{get_download_url: fn _url, _filename -> {:ok, "https://presigned"} end})

      {:ok, view, _html} = live(log_in_conn(conn, admin), ~p"/reports/runs/#{run.id}")
      render_async(view)

      render_hook(view, "download_report", %{})

      entry = Repo.one!(DataAccessLogEntry)
      assert entry.user_id == admin.id
      assert entry.report_run_id == run.id
    end

    test "a portal (MySQL) report download does not touch the audit log", %{conn: _conn} do
      # the portal download path (download_report with a filetype) runs the report query and
      # streams the file itself — it never calls AuditLog. Drive the handler directly with a
      # stubbed portal report so the test does not depend on a reachable portal DB.
      user = user_fixture()
      {:ok, run} = Reports.create_report_run(%{user_id: user.id, report_slug: "teacher-status"})
      run = %{run | user: user}

      report = %Report{type: :portal, slug: "teacher-status", get_query: fn _filter, _user -> {:error, "stubbed"} end}

      socket = %Phoenix.LiveView.Socket{
        assigns: %{report: report, report_run: run, sort: [], downloading: nil, download_task_ref: nil, __changed__: %{}}
      }

      assert {:noreply, _socket} = Show.handle_event("download_report", %{"filetype" => "csv"}, socket)
      assert entry_count() == 0
    end
  end

  describe "flash plumbing" do
    test "the Show LiveView renders a flash message sent by the post-processing component", %{conn: conn} do
      user = user_fixture()
      run = succeeded_run(user, "teacher-actions")

      {:ok, view, _html} = live(log_in_conn(conn, user), ~p"/reports/runs/#{run.id}")
      render_async(view)

      send(view.pid, {:put_flash, :error, "Unable to record this download in the access log"})

      assert render(view) =~ "Unable to record this download in the access log"
    end
  end

  describe "post-processing job download" do
    test "writes a web/job_result audit row with the job id and replies with the url", %{conn: _conn} do
      user = user_fixture()
      run = succeeded_run(user, "student-answers")
      start_athena_stub(%{get_download_url: fn _url, _filename -> {:ok, "https://presigned"} end})

      job = %Job{id: 7, query_id: "qid", result: "s3://bucket/job.csv", status: :completed, steps: []}
      socket = %Phoenix.LiveView.Socket{assigns: %{report_run: run, jobs: [job], user: user, __changed__: %{}}}

      assert {:reply, %{url: "https://presigned"}, _socket} =
               PostProcessingComponent.handle_event("download", %{"type" => "job", "jobId" => "7"}, socket)

      assert entry_count() == 1
      entry = Repo.one!(DataAccessLogEntry)
      assert entry.source == "web"
      assert entry.data_type == "job_result"
      assert entry.job_id == 7
      assert entry.user_id == user.id
      assert entry.report_run_id == run.id
    end

    test "replies with a nil url and writes no audit row when the presign fails", %{conn: _conn} do
      user = user_fixture()
      run = succeeded_run(user, "student-answers")
      start_athena_stub(%{get_download_url: fn _url, _filename -> {:error, "presign failed"} end})

      job = %Job{id: 7, query_id: "qid", result: "s3://bucket/job.csv", status: :completed, steps: []}
      socket = %Phoenix.LiveView.Socket{assigns: %{report_run: run, jobs: [job], user: user, __changed__: %{}}}

      assert {:reply, %{url: nil}, _socket} =
               PostProcessingComponent.handle_event("download", %{"type" => "job", "jobId" => "7"}, socket)

      assert entry_count() == 0
    end
  end
end
