defmodule ReportServerWeb.Api.V1.ReportControllerTest do
  use ReportServerWeb.ConnCase

  import ReportServer.AccountsFixtures

  alias ReportServer.AuditLog.DataAccessLogEntry
  alias ReportServer.Repo
  alias ReportServer.Reports
  alias ReportServer.Reports.{Report, ReportFilter, ReportQuery, Tree}
  alias ReportServer.Reports.Portal.Csv

  @filter_keys ~w(filters state start_date end_date hide_names exclude_internal cohort school
                  teacher assignment class student permission_form country subject_area)

  defmodule TreeStub do
    def find_report(_slug), do: Application.get_env(:report_server, :test_tree_report)
  end

  setup :clean_env

  defp clean_env(_context) do
    on_exit(fn ->
      Application.delete_env(:report_server, :athena_db)
      Application.delete_env(:report_server, :report_tree)
      Application.delete_env(:report_server, :test_tree_report)
      Application.delete_env(:report_server, :portal_db)
    end)

    :ok
  end

  defp start_athena_stub(responses) do
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

  defp entry_count(), do: Repo.aggregate(DataAccessLogEntry, :count)

  # a super-admin owner (get_allowed_project_ids -> :all, no portal-DB call) with a non-empty
  # learner-narrowing filter and exclude_internal false, so teacher-status get_query builds real
  # SQL with zero PortalDbs calls and only the stubbed stream_query runs.
  defp portal_admin_run(filter \\ %ReportFilter{filters: [:cohort], cohort: [1], exclude_internal: false}) do
    user = user_fixture(%{portal_is_admin: true})
    {raw_token, _} = api_token_fixture(user)
    run = run_fixture(user, %{report_slug: "teacher-status", report_filter: filter})
    {raw_token, run}
  end

  defp start_portal_stub(stream_query_fun) do
    Application.put_env(:report_server, :portal_db, ReportServer.PortalDbsStub)
    {:ok, pid} = ReportServer.PortalDbsStub.start(%{stream_query: stream_query_fun})
    on_exit(fn -> if Process.alive?(pid), do: Agent.stop(pid) end)
    pid
  end

  defp myxql_result(cols, rows), do: %MyXQL.Result{columns: cols, rows: rows, num_rows: length(rows)}

  # drive the caller's reducer over the given envelopes and thread the acc back out as {:ok, acc}
  defp drive(envelopes) do
    fn _server, _sql, _params, opts ->
      {:ok, Enum.reduce(envelopes, opts[:acc], opts[:reducer])}
    end
  end

  defp spawn_limiter_holder() do
    test = self()

    pid =
      spawn(fn ->
        :ok = ReportServer.PortalDownloadLimiter.try_acquire()
        send(test, :acquired)
        receive do: (:stop -> :ok)
      end)

    receive do: (:acquired -> :ok)
    pid
  end

  describe "GET /api/v1/reports (index)" do
    setup :register_and_put_bearer_token

    test "returns the caller's Athena and Portal runs newest-id-first", %{raw_token: raw_token, user: user} do
      other = user_fixture()
      portal = run_fixture(user, %{report_slug: "teacher-status"})
      run1 = run_fixture(user, %{report_slug: "student-answers"})
      run2 = run_fixture(user, %{report_slug: "teacher-actions", athena_query_state: "queued"})
      _other_run = run_fixture(other, %{report_slug: "student-answers"})

      conn = get(authed_conn(raw_token), ~p"/api/v1/reports")
      body = json_response(conn, 200)

      assert Enum.map(body["items"], & &1["id"]) == [run2.id, run1.id, portal.id]
      assert Enum.map(body["items"], & &1["report_type"]) == ["log", "answers", nil]
      assert Enum.map(body["items"], & &1["execution"]) == ["async", "async", "sync"]
      assert body["next_page_token"] == nil
    end

    test "makes no Athena stub calls (stored state served as-is)", %{raw_token: raw_token, user: user} do
      run_fixture(user, %{athena_query_state: "running", athena_query_id: "qid"})
      Application.put_env(:report_server, :athena_db, ReportServer.AthenaDBStub)
      start_athena_stub(%{
        query: fn _, _, _ -> raise "should not be called" end,
        get_query_info: fn _ -> raise "should not be called" end
      })

      conn = get(authed_conn(raw_token), ~p"/api/v1/reports")
      assert %{"items" => [item]} = json_response(conn, 200)
      assert item["athena_query_state"] == "running"
    end
  end

  describe "report_type" do
    setup :register_and_put_bearer_token

    @report_types %{
      "student-answers" => "answers",
      "student-assignment-usage" => "usage",
      "student-actions" => "log",
      "student-actions-with-metadata" => "log",
      "teacher-actions" => "log"
    }

    test "every Athena report slug carries its exact report_type in show and index payloads",
         %{raw_token: raw_token, user: user} do
      # a new Athena report shipping without a vocabulary value fails here
      slugs = Tree.athena_report_slugs()
      assert Enum.sort(slugs) == Enum.sort(Map.keys(@report_types))

      runs =
        Map.new(slugs, fn slug ->
          run = run_fixture(user, %{report_slug: slug, athena_query_id: "qid", athena_query_state: "succeeded"})
          {run.id, Map.fetch!(@report_types, slug)}
        end)

      for {id, expected} <- runs do
        assert json_response(get(authed_conn(raw_token), ~p"/api/v1/reports/#{id}"), 200)["report_type"] == expected
      end

      items = json_response(get(authed_conn(raw_token), ~p"/api/v1/reports"), 200)["items"]
      assert length(items) == map_size(runs)

      for item <- items do
        assert item["report_type"] == Map.fetch!(runs, item["id"])
      end
    end
  end

  describe "GET /api/v1/reports pagination" do
    setup :register_and_put_bearer_token

    test "paginates with limit and page_token", %{raw_token: raw_token, user: user} do
      r1 = run_fixture(user)
      r2 = run_fixture(user)
      r3 = run_fixture(user)

      conn1 = get(authed_conn(raw_token), ~p"/api/v1/reports?limit=2")
      body1 = json_response(conn1, 200)
      assert Enum.map(body1["items"], & &1["id"]) == [r3.id, r2.id]
      token = body1["next_page_token"]
      assert is_binary(token)

      conn2 = get(authed_conn(raw_token), ~p"/api/v1/reports?limit=2&page_token=#{token}")
      body2 = json_response(conn2, 200)
      assert Enum.map(body2["items"], & &1["id"]) == [r1.id]
      assert body2["next_page_token"] == nil
    end

    test "rejects a non-integer or fractional limit", %{raw_token: raw_token} do
      for bad <- ["abc", "1.5"] do
        conn = get(authed_conn(raw_token), ~p"/api/v1/reports?limit=#{bad}")
        assert json_response(conn, 400)["error"] == "BAD_REQUEST"
      end
    end

    test "clamps a below-one limit up to one", %{raw_token: raw_token, user: user} do
      run_fixture(user)
      run_fixture(user)

      conn = get(authed_conn(raw_token), ~p"/api/v1/reports?limit=0")
      assert length(json_response(conn, 200)["items"]) == 1
    end

    test "clamps a huge limit and still returns 200", %{raw_token: raw_token} do
      conn = get(authed_conn(raw_token), ~p"/api/v1/reports?limit=9999")
      assert json_response(conn, 200)["items"] == []
    end

    test "rejects malformed, out-of-range and non-positive page tokens", %{raw_token: raw_token} do
      malformed = "@@@"
      out_of_range = Base.url_encode64("18446744073709551616", padding: false)
      zero = Base.url_encode64("0", padding: false)
      negative = Base.url_encode64("-1", padding: false)

      for token <- [malformed, out_of_range, zero, negative] do
        conn = get(authed_conn(raw_token), "/api/v1/reports?page_token=#{token}")
        assert json_response(conn, 400)["error"] == "BAD_REQUEST"
      end
    end
  end

  describe "GET /api/v1/reports/:id (show)" do
    setup :register_and_put_bearer_token

    test "returns the full contract shape and never the result url", %{raw_token: raw_token, user: user} do
      run =
        run_fixture(user, %{
          report_slug: "student-answers",
          report_filter: %ReportFilter{
            filters: [:cohort, :school],
            cohort: [1, 2],
            school: [3],
            start_date: "",
            end_date: "2024-01-01",
            hide_names: true
          },
          report_filter_values: %{"cohort" => %{"1" => "Cohort One"}},
          athena_query_id: "qid",
          athena_query_state: "succeeded",
          athena_result_url: "s3://secret/result.csv"
        })

      conn = get(authed_conn(raw_token), ~p"/api/v1/reports/#{run.id}")
      body = json_response(conn, 200)

      assert body["id"] == run.id
      assert body["report_slug"] == "student-answers"
      assert body["report_type"] == "answers"
      assert body["athena_query_state"] == "succeeded"
      assert body["report_filter_values"] == %{"cohort" => %{"1" => "Cohort One"}}
      refute Map.has_key?(body, "athena_result_url")

      filter = body["report_filter"]
      assert Enum.sort(Map.keys(filter)) == Enum.sort(@filter_keys)
      assert filter["filters"] == ["cohort", "school"]
      assert filter["cohort"] == [1, 2]
      assert filter["school"] == [3]
      assert filter["start_date"] == nil
      assert filter["end_date"] == "2024-01-01"
      assert filter["hide_names"] == true
      assert filter["exclude_internal"] == false
    end

    test "serializes a nil report_filter as the empty-filter object", %{raw_token: raw_token, user: user} do
      run =
        run_fixture(user, %{
          report_filter: nil,
          athena_query_id: "qid",
          athena_query_state: "succeeded",
          athena_result_url: "s3://x"
        })

      conn = get(authed_conn(raw_token), ~p"/api/v1/reports/#{run.id}")
      filter = json_response(conn, 200)["report_filter"]

      refute is_nil(filter)
      assert Enum.sort(Map.keys(filter)) == Enum.sort(@filter_keys)
      assert filter["filters"] == []
      assert filter["cohort"] == nil
      assert filter["state"] == nil
      assert filter["hide_names"] == false
      assert filter["exclude_internal"] == false
    end

    test "buckets every non-resolving id into an identical 404", %{raw_token: raw_token} do
      other = user_fixture()
      others_run = run_fixture(other, %{report_slug: "student-answers"})
      not_found = %{"error" => "NOT_FOUND", "message" => "Not found."}

      ids = [
        "999999999",
        to_string(others_run.id),
        "abc",
        "123abc",
        "-1",
        "99999999999999999999"
      ]

      for id <- ids do
        conn = get(authed_conn(raw_token), "/api/v1/reports/#{id}")
        assert json_response(conn, 404) == not_found
      end
    end
  end

  describe "GET /api/v1/reports/:id (show freshness and self-start)" do
    setup :register_and_put_bearer_token

    test "refreshes a running run to succeeded and persists both fields", %{raw_token: raw_token, user: user} do
      run = run_fixture(user, %{athena_query_id: "qid-run", athena_query_state: "running"})
      Application.put_env(:report_server, :athena_db, ReportServer.AthenaDBStub)
      start_athena_stub(%{get_query_info: fn "qid-run" -> {:ok, "succeeded", "s3://out.csv"} end})

      conn = get(authed_conn(raw_token), ~p"/api/v1/reports/#{run.id}")
      assert json_response(conn, 200)["athena_query_state"] == "succeeded"

      reloaded = Reports.get_report_run!(run.id)
      assert reloaded.athena_query_state == "succeeded"
      assert reloaded.athena_result_url == "s3://out.csv"
    end

    test "serves the stored state when the refresh fails", %{raw_token: raw_token, user: user} do
      run = run_fixture(user, %{athena_query_id: "qid-run", athena_query_state: "running"})
      Application.put_env(:report_server, :athena_db, ReportServer.AthenaDBStub)
      start_athena_stub(%{get_query_info: fn _ -> {:error, "boom"} end})

      conn = get(authed_conn(raw_token), ~p"/api/v1/reports/#{run.id}")
      assert json_response(conn, 200)["athena_query_state"] == "running"
    end

    test "does not call Athena for a terminal run", %{raw_token: raw_token, user: user} do
      run = run_fixture(user, %{athena_query_id: "qid-run", athena_query_state: "succeeded", athena_result_url: "s3://x"})
      Application.put_env(:report_server, :athena_db, ReportServer.AthenaDBStub)
      start_athena_stub(%{get_query_info: fn _ -> raise "should not be called" end})

      conn = get(authed_conn(raw_token), ~p"/api/v1/reports/#{run.id}")
      assert json_response(conn, 200)["athena_query_state"] == "succeeded"
    end

    test "self-starts a never-started run through the HTTP path", %{raw_token: raw_token, user: user} do
      run = run_fixture(user, %{report_slug: "student-answers"})
      Application.put_env(:report_server, :athena_db, ReportServer.AthenaDBStub)
      Application.put_env(:report_server, :report_tree, TreeStub)

      Application.put_env(
        :report_server,
        :test_tree_report,
        %Report{
          type: :athena,
          slug: "student-answers",
          get_query: fn _filter, _user -> {:ok, %ReportQuery{raw_sql: "SELECT 1"}} end
        }
      )

      start_athena_stub(%{query: fn _sql, _id, _user -> {:ok, "new-qid", "queued"} end})

      conn = get(authed_conn(raw_token), ~p"/api/v1/reports/#{run.id}")
      assert json_response(conn, 200)["athena_query_state"] == "queued"

      reloaded = Reports.get_report_run!(run.id)
      assert reloaded.athena_query_id == "new-qid"
    end
  end

  describe "GET /api/v1/reports/:id/download" do
    setup :register_and_put_bearer_token

    test "mints a fresh presigned url and writes exactly one audit row", %{raw_token: raw_token, user: user} do
      run =
        run_fixture(user, %{
          report_slug: "student-answers",
          report_filter: %ReportFilter{filters: [:cohort], cohort: [1]},
          athena_query_id: "qid",
          athena_query_state: "succeeded",
          athena_result_url: "s3://bucket/result.csv"
        })

      Application.put_env(:report_server, :athena_db, ReportServer.AthenaDBStub)
      start_athena_stub(%{get_download_url: fn _url, _filename -> {:ok, "https://presigned"} end})

      conn = get(authed_conn(raw_token), ~p"/api/v1/reports/#{run.id}/download")
      body = json_response(conn, 200)

      assert body == %{
               "download_url" => "https://presigned",
               "filename" => "student-answers-run-#{run.id}.csv",
               "expires_in_seconds" => 600
             }

      assert entry_count() == 1
      entry = Repo.one!(DataAccessLogEntry)
      assert entry.source == "api"
      assert entry.data_type == "run_csv"
      assert entry.job_id == nil
      assert entry.user_id == user.id
      assert entry.report_run_id == run.id
      assert entry.report_filter["cohort"] == [1]
    end

    test "returns 409 with the state for every non-succeeded state and writes no audit row",
         %{raw_token: raw_token, user: user} do
      echo = %{
        "qid-queued" => {:ok, "queued", nil},
        "qid-running" => {:ok, "running", nil},
        "qid-null" => {:ok, nil, nil}
      }

      Application.put_env(:report_server, :athena_db, ReportServer.AthenaDBStub)
      start_athena_stub(%{get_query_info: fn qid -> Map.fetch!(echo, qid) end})

      cases = [
        {%{athena_query_id: "qid-queued", athena_query_state: "queued"}, "queued"},
        {%{athena_query_id: "qid-running", athena_query_state: "running"}, "running"},
        {%{athena_query_id: "qid-null", athena_query_state: nil}, nil},
        {%{athena_query_id: "qid-failed", athena_query_state: "failed"}, "failed"},
        {%{athena_query_id: "qid-cancelled", athena_query_state: "cancelled"}, "cancelled"}
      ]

      for {attrs, expected_state} <- cases do
        run = run_fixture(user, attrs)
        conn = get(authed_conn(raw_token), ~p"/api/v1/reports/#{run.id}/download")
        body = json_response(conn, 409)
        assert body["error"] == "NOT_READY"
        assert body["athena_query_state"] == expected_state
      end

      assert entry_count() == 0
    end

    test "refreshes a running run to succeeded during download", %{raw_token: raw_token, user: user} do
      run = run_fixture(user, %{athena_query_id: "qid-run", athena_query_state: "running"})

      Application.put_env(:report_server, :athena_db, ReportServer.AthenaDBStub)
      start_athena_stub(%{
        get_query_info: fn "qid-run" -> {:ok, "succeeded", "s3://out.csv"} end,
        get_download_url: fn _url, _filename -> {:ok, "https://presigned"} end
      })

      conn = get(authed_conn(raw_token), ~p"/api/v1/reports/#{run.id}/download")
      assert json_response(conn, 200)["download_url"] == "https://presigned"
      assert entry_count() == 1
    end

    test "self-starts a never-started run and returns 409 with the new state", %{raw_token: raw_token, user: user} do
      run = run_fixture(user, %{report_slug: "student-answers"})

      Application.put_env(:report_server, :athena_db, ReportServer.AthenaDBStub)
      Application.put_env(:report_server, :report_tree, TreeStub)

      Application.put_env(
        :report_server,
        :test_tree_report,
        %Report{
          type: :athena,
          slug: "student-answers",
          get_query: fn _filter, _user -> {:ok, %ReportQuery{raw_sql: "SELECT 1"}} end
        }
      )

      start_athena_stub(%{query: fn _sql, _id, _user -> {:ok, "new-qid", "queued"} end})

      conn = get(authed_conn(raw_token), ~p"/api/v1/reports/#{run.id}/download")
      body = json_response(conn, 409)
      assert body["athena_query_state"] == "queued"

      reloaded = Reports.get_report_run!(run.id)
      assert reloaded.athena_query_id == "new-qid"
      assert entry_count() == 0
    end

    test "releases the claim and returns 409 with a null state when self-start fails", %{raw_token: raw_token, user: user} do
      run = run_fixture(user, %{report_slug: "student-answers"})

      Application.put_env(:report_server, :athena_db, ReportServer.AthenaDBStub)
      Application.put_env(:report_server, :report_tree, TreeStub)

      Application.put_env(
        :report_server,
        :test_tree_report,
        %Report{
          type: :athena,
          slug: "student-answers",
          get_query: fn _filter, _user -> {:ok, %ReportQuery{raw_sql: "SELECT 1"}} end
        }
      )

      start_athena_stub(%{query: fn _sql, _id, _user -> {:error, "boom"} end})

      conn = get(authed_conn(raw_token), ~p"/api/v1/reports/#{run.id}/download")
      assert json_response(conn, 409)["athena_query_state"] == nil

      reloaded = Reports.get_report_run!(run.id)
      assert reloaded.athena_query_state == nil
      assert entry_count() == 0
    end

    test "returns 500 with no audit row when a succeeded run has no result url", %{raw_token: raw_token, user: user} do
      run = run_fixture(user, %{athena_query_id: "qid", athena_query_state: "succeeded", athena_result_url: nil})

      conn = get(authed_conn(raw_token), ~p"/api/v1/reports/#{run.id}/download")
      assert json_response(conn, 500)["error"] == "SERVER_ERROR"
      assert entry_count() == 0
    end

    test "returns 500 with no audit row when the presign fails", %{raw_token: raw_token, user: user} do
      run = run_fixture(user, %{athena_query_id: "qid", athena_query_state: "succeeded", athena_result_url: "s3://x"})

      Application.put_env(:report_server, :athena_db, ReportServer.AthenaDBStub)
      start_athena_stub(%{get_download_url: fn _url, _filename -> {:error, "presign boom"} end})

      conn = get(authed_conn(raw_token), ~p"/api/v1/reports/#{run.id}/download")
      assert json_response(conn, 500)["error"] == "SERVER_ERROR"
      assert entry_count() == 0
    end

    test "buckets every non-resolving id into an identical 404", %{raw_token: raw_token} do
      other = user_fixture()
      others_run = run_fixture(other, %{report_slug: "student-answers"})
      not_found = %{"error" => "NOT_FOUND", "message" => "Not found."}

      ids = [
        "999999999",
        to_string(others_run.id),
        "abc",
        "123abc",
        "-1",
        "99999999999999999999"
      ]

      for id <- ids do
        conn = get(authed_conn(raw_token), "/api/v1/reports/#{id}/download")
        assert json_response(conn, 404) == not_found
      end
    end
  end

  describe "GET /api/v1/reports/:id/download (Portal)" do
    test "streams a text/csv body byte-compatible with the shared encoder", %{} do
      {token, run} = portal_admin_run()
      cols = ["a", "b"]
      rows1 = [["1", "x"], ["2", "y,z"]]
      rows2 = [["3", "line\nbreak"]]

      start_portal_stub(
        drive([myxql_result(cols, []), myxql_result(cols, rows1), myxql_result(cols, rows2)])
      )

      conn = get(authed_conn(token), ~p"/api/v1/reports/#{run.id}/download")

      expected = Csv.header_row(cols) <> Csv.encode_batch(rows1) <> Csv.encode_batch(rows2)
      assert response(conn, 200) == expected
      assert hd(get_resp_header(conn, "content-type")) =~ "text/csv"

      assert get_resp_header(conn, "content-disposition") ==
               [~s(attachment; filename="teacher-status-run-#{run.id}.csv")]

      assert entry_count() == 1
      entry = Repo.one!(DataAccessLogEntry)
      assert entry.event == "run_csv_streamed"
      assert entry.source == "api"
      assert entry.data_type == "run_csv"
      assert entry.report_run_id == run.id
    end

    test "an empty result streams a header-only 200 body", %{} do
      {token, run} = portal_admin_run()
      cols = ["a", "b"]

      start_portal_stub(drive([myxql_result(cols, []), myxql_result(cols, [])]))

      conn = get(authed_conn(token), ~p"/api/v1/reports/#{run.id}/download")

      assert response(conn, 200) == Csv.header_row(cols)
      assert hd(get_resp_header(conn, "content-type")) =~ "text/csv"
      assert entry_count() == 1
    end

    test "a pre-first-byte execution error returns a generic 500 with the initiated audit row", %{} do
      {token, run} = portal_admin_run()

      start_portal_stub(fn _server, _sql, _params, _opts ->
        raise %MyXQL.Error{message: "table secret_schema.x does not exist"}
      end)

      conn = get(authed_conn(token), ~p"/api/v1/reports/#{run.id}/download")

      body = json_response(conn, 500)
      assert body["error"] == "SERVER_ERROR"
      refute body["message"] =~ "secret_schema"
      # the fail-closed row is written before the stream is attempted
      assert entry_count() == 1
      assert Repo.one!(DataAccessLogEntry).event == "run_csv_streamed"
    end

    test "a seam error returned without raising is classified pre-first-byte as a generic 500", %{} do
      {token, run} = portal_admin_run()

      start_portal_stub(fn _server, _sql, _params, _opts -> {:error, "portal pool failed to start"} end)

      conn = get(authed_conn(token), ~p"/api/v1/reports/#{run.id}/download")
      assert json_response(conn, 500)["error"] == "SERVER_ERROR"
    end

    test "a construction error (super-admin blank filter) returns a clean 422, not a raised 500", %{} do
      {token, run} = portal_admin_run(%ReportFilter{})

      conn = get(authed_conn(token), ~p"/api/v1/reports/#{run.id}/download")

      assert json_response(conn, 422)["error"] == "UNPROCESSABLE"
      # nothing streamed, so no audit row was written
      assert entry_count() == 0
    end

    test "a mid-stream failure raises after send_chunked", %{} do
      {token, run} = portal_admin_run()
      cols = ["a", "b"]

      start_portal_stub(fn _server, _sql, _params, opts ->
        acc = opts[:reducer].(myxql_result(cols, []), opts[:acc])
        _acc = opts[:reducer].(myxql_result(cols, [["1", "x"]]), acc)
        raise "mid-stream boom"
      end)

      assert_raise RuntimeError, "mid-stream boom", fn ->
        get(authed_conn(token), ~p"/api/v1/reports/#{run.id}/download")
      end
    end

    test "a deadline in the past yields a clean pre-first-byte JSON error", %{} do
      original = Application.get_env(:report_server, :portal_download)
      on_exit(fn -> Application.put_env(:report_server, :portal_download, original) end)
      Application.put_env(:report_server, :portal_download, Keyword.put(original, :timeout_ms, -1000))

      {token, run} = portal_admin_run()
      cols = ["a", "b"]
      start_portal_stub(drive([myxql_result(cols, [])]))

      conn = get(authed_conn(token), ~p"/api/v1/reports/#{run.id}/download")
      assert json_response(conn, 500)["error"] == "SERVER_ERROR"
    end

    test "returns 503 once the concurrency cap is reached", %{} do
      {token, run} = portal_admin_run()
      cap = Application.get_env(:report_server, :portal_download) |> Keyword.fetch!(:max_concurrent)
      holders = for _ <- 1..cap, do: spawn_limiter_holder()
      on_exit(fn -> Enum.each(holders, &send(&1, :stop)) end)

      conn = get(authed_conn(token), ~p"/api/v1/reports/#{run.id}/download")
      assert json_response(conn, 503)["error"] == "SERVICE_UNAVAILABLE"
      assert entry_count() == 0
    end
  end
end
