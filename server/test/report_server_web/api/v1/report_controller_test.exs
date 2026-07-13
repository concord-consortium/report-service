defmodule ReportServerWeb.Api.V1.ReportControllerTest do
  use ReportServerWeb.ConnCase

  import ReportServer.AccountsFixtures

  alias ReportServer.Reports
  alias ReportServer.Reports.{Report, ReportFilter, ReportQuery}

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

  describe "GET /api/v1/reports (index)" do
    setup :register_and_put_bearer_token

    test "returns only the caller's Athena-type runs newest-id-first", %{raw_token: raw_token, user: user} do
      other = user_fixture()
      _portal = run_fixture(user, %{report_slug: "teacher-status"})
      run1 = run_fixture(user, %{report_slug: "student-answers"})
      run2 = run_fixture(user, %{report_slug: "teacher-actions", athena_query_state: "queued"})
      _other_run = run_fixture(other, %{report_slug: "student-answers"})

      conn = get(authed_conn(raw_token), ~p"/api/v1/reports")
      body = json_response(conn, 200)

      assert Enum.map(body["items"], & &1["id"]) == [run2.id, run1.id]
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

    test "buckets every non-resolving id into an identical 404", %{raw_token: raw_token, user: user} do
      other = user_fixture()
      others_run = run_fixture(other, %{report_slug: "student-answers"})
      portal_run = run_fixture(user, %{report_slug: "teacher-status"})
      not_found = %{"error" => "NOT_FOUND", "message" => "Not found."}

      ids = [
        "999999999",
        to_string(others_run.id),
        to_string(portal_run.id),
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
end
