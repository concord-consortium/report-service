defmodule ReportServerWeb.Api.V1.ReportJobControllerTest do
  use ReportServerWeb.ConnCase

  import ReportServer.AccountsFixtures

  alias ReportServer.AuditLog.DataAccessLogEntry
  alias ReportServer.Repo
  alias ReportServer.Reports

  setup :clean_env

  defp clean_env(_context) do
    on_exit(fn ->
      Application.delete_env(:report_server, :aws_file_store)
      Application.delete_env(:report_server, :athena_db)
    end)

    :ok
  end

  defp start_aws_stub(responses) do
    Application.put_env(:report_server, :aws_file_store, ReportServer.AwsFileStoreStub)

    case ReportServer.AwsFileStoreStub.start(responses) do
      {:ok, pid} ->
        on_exit(fn -> if Process.alive?(pid), do: Agent.stop(pid) end)

      {:error, {:already_started, pid}} ->
        Agent.update(pid, fn _ -> responses end)
    end
  end

  defp start_athena_stub(responses) do
    Application.put_env(:report_server, :athena_db, ReportServer.AthenaDBStub)
    {:ok, pid} = ReportServer.AthenaDBStub.start(responses)
    on_exit(fn -> if Process.alive?(pid), do: Agent.stop(pid) end)
    pid
  end

  defp authed_conn(raw_token) do
    build_conn() |> put_req_header("authorization", "Bearer #{raw_token}")
  end

  defp run_fixture(user, attrs \\ %{}) do
    {:ok, run} =
      Reports.create_report_run(Map.merge(%{user_id: user.id, report_slug: "student-answers"}, attrs))

    run
  end

  defp jobs_json(jobs), do: Jason.encode!(%{"jobs" => jobs})

  defp entry_count(), do: Repo.aggregate(DataAccessLogEntry, :count)

  describe "GET /api/v1/reports/:id/jobs" do
    setup :register_and_put_bearer_token

    test "returns the closed job shape with has_result and a null page token", %{raw_token: raw_token, user: user} do
      run = run_fixture(user, %{athena_query_id: "qid"})

      contents =
        jobs_json([
          %{"id" => 1, "steps" => [%{"id" => "s1", "label" => "Step 1"}], "status" => "completed", "result" => "s3://r1"},
          %{"id" => 2, "steps" => [], "status" => "started", "result" => nil}
        ])

      start_aws_stub(%{fetch_file_contents: fn _url -> {:ok, contents} end})

      conn = get(authed_conn(raw_token), ~p"/api/v1/reports/#{run.id}/jobs")
      body = json_response(conn, 200)

      assert body["next_page_token"] == nil
      [item1, item2] = body["items"]

      assert item1 == %{
               "id" => 1,
               "steps" => [%{"id" => "s1", "label" => "Step 1"}],
               "status" => "completed",
               "has_result" => true
             }

      refute Map.has_key?(item1, "result")

      assert item2["id"] == 2
      assert item2["steps"] == []
      assert item2["has_result"] == false
    end

    test "returns an empty list for a run with no athena_query_id", %{raw_token: raw_token, user: user} do
      run = run_fixture(user)

      conn = get(authed_conn(raw_token), ~p"/api/v1/reports/#{run.id}/jobs")
      assert json_response(conn, 200) == %{"items" => [], "next_page_token" => nil}
    end

    test "returns an empty list when the jobs file is missing", %{raw_token: raw_token, user: user} do
      run = run_fixture(user, %{athena_query_id: "qid"})
      start_aws_stub(%{fetch_file_contents: fn _url -> {:error, :not_found} end})

      conn = get(authed_conn(raw_token), ~p"/api/v1/reports/#{run.id}/jobs")
      assert json_response(conn, 200) == %{"items" => [], "next_page_token" => nil}
    end

    test "returns 500 on a transient S3 error", %{raw_token: raw_token, user: user} do
      run = run_fixture(user, %{athena_query_id: "qid"})
      start_aws_stub(%{fetch_file_contents: fn _url -> {:error, {:s3_error, "boom"}} end})

      conn = get(authed_conn(raw_token), ~p"/api/v1/reports/#{run.id}/jobs")
      assert json_response(conn, 500)["error"] == "SERVER_ERROR"
    end

    test "returns 404 for another user's run", %{raw_token: raw_token} do
      other = user_fixture()
      run = run_fixture(other, %{athena_query_id: "qid"})

      conn = get(authed_conn(raw_token), ~p"/api/v1/reports/#{run.id}/jobs")
      assert json_response(conn, 404) == %{"error" => "NOT_FOUND", "message" => "Not found."}
    end
  end

  describe "GET /api/v1/reports/:id/jobs/:job_id/download" do
    setup :register_and_put_bearer_token

    test "mints a fresh presigned url and writes one job_result audit row", %{raw_token: raw_token, user: user} do
      run = run_fixture(user, %{athena_query_id: "qid"})
      contents = jobs_json([%{"id" => 5, "steps" => [], "status" => "completed", "result" => "s3://res"}])
      start_aws_stub(%{fetch_file_contents: fn _url -> {:ok, contents} end})
      start_athena_stub(%{get_download_url: fn _url, _filename -> {:ok, "https://presigned"} end})

      conn = get(authed_conn(raw_token), ~p"/api/v1/reports/#{run.id}/jobs/5/download")
      body = json_response(conn, 200)

      assert body == %{
               "download_url" => "https://presigned",
               "filename" => "student-answers-run-#{run.id}-job-5.csv",
               "expires_in_seconds" => 600
             }

      assert entry_count() == 1
      entry = Repo.one!(DataAccessLogEntry)
      assert entry.data_type == "job_result"
      assert entry.job_id == 5
      assert entry.source == "api"
    end

    test "returns 409 with the status for a non-completed job and writes no audit row", %{raw_token: raw_token, user: user} do
      run = run_fixture(user, %{athena_query_id: "qid"})

      for status <- ["started", "failed"] do
        contents = jobs_json([%{"id" => 5, "steps" => [], "status" => status, "result" => nil}])
        start_aws_stub(%{fetch_file_contents: fn _url -> {:ok, contents} end})

        conn = get(authed_conn(raw_token), ~p"/api/v1/reports/#{run.id}/jobs/5/download")
        body = json_response(conn, 409)
        assert body["error"] == "NOT_READY"
        assert body["status"] == status
      end

      assert entry_count() == 0
    end

    test "returns 500 when a completed job has no result", %{raw_token: raw_token, user: user} do
      run = run_fixture(user, %{athena_query_id: "qid"})
      contents = jobs_json([%{"id" => 5, "steps" => [], "status" => "completed", "result" => nil}])
      start_aws_stub(%{fetch_file_contents: fn _url -> {:ok, contents} end})

      conn = get(authed_conn(raw_token), ~p"/api/v1/reports/#{run.id}/jobs/5/download")
      assert json_response(conn, 500)["error"] == "SERVER_ERROR"
      assert entry_count() == 0
    end

    test "returns 404 for an unknown or malformed job id", %{raw_token: raw_token, user: user} do
      run = run_fixture(user, %{athena_query_id: "qid"})
      contents = jobs_json([%{"id" => 5, "steps" => [], "status" => "completed", "result" => "s3://res"}])
      start_aws_stub(%{fetch_file_contents: fn _url -> {:ok, contents} end})
      not_found = %{"error" => "NOT_FOUND", "message" => "Not found."}

      for job_id <- ["999", "abc"] do
        conn = get(authed_conn(raw_token), "/api/v1/reports/#{run.id}/jobs/#{job_id}/download")
        assert json_response(conn, 404) == not_found
      end
    end

    test "returns 404 for another user's run before any S3 read", %{raw_token: raw_token} do
      other = user_fixture()
      run = run_fixture(other, %{athena_query_id: "qid"})

      conn = get(authed_conn(raw_token), ~p"/api/v1/reports/#{run.id}/jobs/5/download")
      assert json_response(conn, 404) == %{"error" => "NOT_FOUND", "message" => "Not found."}
    end
  end
end
