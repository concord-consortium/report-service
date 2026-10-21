defmodule ReportServerWeb.Api.V1.RecentLogsControllerTest do
  use ReportServerWeb.ConnCase, async: false

  @moduletag :portal_db

  import Ecto.Query
  import ReportServer.AccountsFixtures
  import ReportServerWeb.PortalTokenFixture

  alias ReportServer.{AthenaDB, AthenaDBStub, AwsFileStoreStub, LearnerDataStub, PortalDownloadLimiter, PortalFixture, RecentLogs, Repo}
  alias ReportServer.AuditLog.DataAccessLogEntry
  alias ReportServerWeb.Api.PortalToken

  @server PortalFixture.server()
  @endpoint_557 "https://#{@server}/dataservice/external_activity_data/SECUREKEY123"
  @endpoint_blank "https://#{@server}/dataservice/external_activity_data/"
  @allowed "https://researcher-dashboard.concord.org"
  @columns RecentLogs.columns()

  setup do
    restore =
      for key <- [:athena_db, :aws_file_store, :recent_logs, :athena, :packages, :audit_log, :learner_data],
          into: %{},
          do: {key, Application.get_env(:report_server, key)}

    on_exit(fn ->
      for {key, value} <- restore do
        if value == nil,
          do: Application.delete_env(:report_server, key),
          else: Application.put_env(:report_server, key, value)
      end
    end)

    Application.put_env(:report_server, :athena_db, AthenaDBStub)
    Application.put_env(:report_server, :aws_file_store, AwsFileStoreStub)
    Application.put_env(:report_server, :athena, log_db_name: "log_ingester_qa")

    Application.put_env(
      :report_server,
      :recent_logs,
      Keyword.merge(restore.recent_logs, timeout_ms: 100, poll_interval_ms: 5)
    )

    Application.put_env(:report_server, :packages, Keyword.put(restore.packages || [], :cors_origins, [@allowed]))
    install!()
    :ok
  end

  defp quoted(values), do: Enum.map_join(values, ",", &~s("#{&1}"))

  defp rows_csv(rows) do
    header = quoted(@columns)
    body = Enum.map(rows, fn row -> Enum.map_join(@columns, ",", &csv_field(Map.get(row, &1))) end)
    Enum.join([header | body], "\n") <> "\n"
  end

  defp csv_field(nil), do: ""
  defp csv_field(value), do: ~s("#{String.replace(to_string(value), "\"", "\"\"")}")

  defp row(id, timestamp, overrides \\ %{}) do
    Map.merge(
      %{
        "id" => id, "session" => "s", "application" => "Activity Player", "activity" => "a",
        "event" => "e", "event_value" => "v", "time" => div(timestamp, 1000), "parameters" => "{}",
        "extras" => "{}", "run_remote_endpoint" => @endpoint_557, "timestamp" => timestamp,
        "user_id" => 101, "primary_user_id" => 101
      },
      overrides
    )
  end

  defp stub_athena(opts) do
    test_pid = self()
    csv = Keyword.fetch!(opts, :csv)
    state = Keyword.get(opts, :state, "succeeded")

    {:ok, athena} =
      AthenaDBStub.start(%{
        query: Keyword.get(opts, :query, fn sql, _id, _user -> send(test_pid, {:sql, sql}); {:ok, "qid", "queued"} end),
        get_query_info: fn _id -> {:ok, state, "s3://bucket/out.csv", nil} end
      })

    {:ok, files} =
      AwsFileStoreStub.start(%{
        get_file_stream: Keyword.get(opts, :get_file_stream, fn _location -> {:ok, [csv]} end)
      })

    on_exit(fn ->
      for pid <- [athena, files], Process.alive?(pid), do: Agent.stop(pid)
    end)
  end

  defp api_conn(conn, attrs) do
    user = user_fixture(Map.merge(%{portal_server: @server}, attrs))
    {raw_token, _} = api_token_fixture(user)
    put_req_header(conn, "authorization", "Bearer #{raw_token}")
  end

  defp researcher_conn(conn), do: api_conn(conn, %{portal_user_id: 557, portal_is_project_researcher: true})

  defp admin_conn(conn) do
    api_conn(conn, %{portal_user_id: 560, portal_is_admin: true, portal_is_project_researcher: false})
  end

  defp access_token(class_id) do
    claims =
      access_claims(:portal_fixture, [iss(:portal_fixture), PortalToken.access_token_audience()], "class:researcher-read", %{
        "uid" => 557,
        "context" => %{"type" => "class", "id" => class_id}
      })

    sign_access(:portal_fixture, claims)
  end

  defp read(conn, class_id, params \\ %{}), do: get(conn, "/api/v1/classes/#{class_id}/recent-logs", params)

  defp audit_rows do
    Repo.all(from e in DataAccessLogEntry, where: e.event == "recent_logs_read")
  end

  defp window_start, do: RecentLogs.window(System.system_time(:millisecond)).window_start

  describe "rows" do
    test "a researcher reads the class's rows, typed, with the freshness and a cursor", %{conn: conn} do
      ws = window_start()

      stub_athena(
        csv:
          rows_csv([
            row("a", ws + 1_000, %{"parameters" => "{\"note\":\"line1\nline2\"}"}),
            row("b", ws + 3_000, %{"extras" => nil}),
            row("c", ws + 2_000)
          ])
      )

      before = System.system_time(:millisecond)
      body = conn |> researcher_conn() |> read(601) |> json_response(200)

      assert body["class_id"] == 601
      assert body["window_start"] == ws
      assert body["since"] == ws
      assert body["until"] == nil
      assert body["nightly_through"] == Date.to_iso8601(RecentLogs.window(body["query_started_at"]).nightly_through)
      assert Enum.map(body["rows"], & &1["id"]) == ["a", "b", "c"]
      assert hd(body["rows"])["parameters"] == "{\"note\":\"line1\nline2\"}"
      assert Enum.at(body["rows"], 1)["extras"] == nil
      assert hd(body["rows"])["time"] == div(ws + 1_000, 1000)
      assert hd(body["rows"])["user_id"] == 101
      assert body["count"] == 3
      assert body["latest_timestamp"] == ws + 3_000
      assert body["query_started_at"] >= before

      assert {:ok, %{since: since}} =
               RecentLogs.bounds(%{"cursor" => body["next_cursor"]}, 601, RecentLogs.window(body["query_started_at"]))

      assert since == body["query_started_at"] - 600_000

      assert_received {:sql, sql}
      assert sql =~ ~s("log_ingester_qa"."logs_by_hour")
      assert sql =~ "'#{@endpoint_557}'"
      refute sql =~ "'#{@endpoint_blank}'"

      assert [entry] = audit_rows()
      assert entry.report_filter == %{"class" => [601]}
      assert entry.endpoint_set == [@endpoint_557]
      assert entry.cursor == Integer.to_string(ws)
    end

    test "more rows than one chunk stream as one valid answer, with the latest from any chunk", %{conn: conn} do
      ws = window_start()
      rows = [row("first", ws + 999_999) | for(n <- 1..600, do: row("r#{n}", ws + n))]
      stub_athena(csv: rows_csv(rows))

      body = conn |> researcher_conn() |> read(601) |> json_response(200)

      assert length(body["rows"]) == 601
      assert body["count"] == 601
      assert body["latest_timestamp"] == ws + 999_999
    end

    test "a site admin reads every learner of the class", %{conn: conn} do
      stub_athena(csv: rows_csv([]))

      body = conn |> admin_conn() |> read(601) |> json_response(200)

      assert body["rows"] == []
      assert body["count"] == 0
      assert_received {:sql, sql}
      assert sql =~ "'#{@endpoint_557}'"
      assert sql =~ "'#{@endpoint_blank}'"
      assert [entry] = audit_rows()
      assert Enum.sort(entry.endpoint_set) == [@endpoint_blank, @endpoint_557]
    end

    test "a cursor reads from its since, with no upper bound", %{conn: conn} do
      stub_athena(csv: rows_csv([]))
      cursor = RecentLogs.next_cursor(601, System.system_time(:millisecond), 600_000)
      {:ok, %{since: since}} = RecentLogs.bounds(%{"cursor" => cursor}, 601, RecentLogs.window(System.system_time(:millisecond)))

      body = conn |> researcher_conn() |> read(601, %{cursor: cursor}) |> json_response(200)

      assert body["since"] == since
      assert_received {:sql, sql}
      assert sql =~ "log.timestamp >= #{since}"
      refute sql =~ "log.timestamp <"
      refute sql =~ "log.dt <="
    end

    test "start and end read a bounded span, which takes no cursor", %{conn: conn} do
      stub_athena(csv: rows_csv([]))
      ws = window_start()
      params = %{start: ws + 60_000, end: ws + 3_660_000}

      body = conn |> researcher_conn() |> read(601, params) |> json_response(200)

      assert body["since"] == ws + 60_000
      assert body["until"] == ws + 3_660_000
      assert body["next_cursor"] == nil
      assert_received {:sql, sql}
      assert sql =~ "log.timestamp >= #{ws + 60_000}"
      assert sql =~ "log.timestamp < #{ws + 3_660_000}"
      assert sql =~ "log.dt <="
    end

    test "a start with no end still gets a cursor", %{conn: conn} do
      stub_athena(csv: rows_csv([]))
      ws = window_start()

      body = conn |> researcher_conn() |> read(601, %{start: ws + 60_000}) |> json_response(200)

      assert body["since"] == ws + 60_000
      assert body["until"] == nil
      assert {:ok, %{until: nil}} = RecentLogs.bounds(%{"cursor" => body["next_cursor"]}, 601, RecentLogs.window(body["query_started_at"]))
      assert_received {:sql, sql}
      refute sql =~ "log.timestamp <"
    end

    test "a class in the grants with no learners answers empty without querying Athena", %{conn: conn} do
      stub_athena(csv: "", query: fn _sql, _id, _user -> raise "queried Athena" end)

      body = conn |> researcher_conn() |> read(2) |> json_response(200)

      assert body["count"] == 0
      assert body["rows"] == []
      assert body["latest_timestamp"] == nil
      assert is_binary(body["next_cursor"])
      assert audit_rows() == []
    end
  end

  describe "refusals" do
    test "a malformed class id, or a cursor with start, is 400", %{conn: conn} do
      cursor = RecentLogs.next_cursor(601, System.system_time(:millisecond), 600_000)
      authed = researcher_conn(conn)

      for {class_id, params} <- [{"0", %{}}, {"abc", %{}}, {"601%0A", %{}}, {601, %{cursor: cursor, start: window_start()}}] do
        assert %{"error" => "BAD_REQUEST"} = authed |> read(class_id, params) |> json_response(400)
      end
    end

    test "a start before the window, a malformed bound, or an end not after start is 400 and names the window start", %{conn: conn} do
      ws = window_start()
      authed = researcher_conn(conn)

      for params <- [%{start: ws - 1}, %{start: "abc"}, %{start: ws + 10, end: ws + 10}] do
        body = authed |> read(601, params) |> json_response(400)

        assert body["error"] == "BAD_REQUEST"
        assert body["message"] =~ Integer.to_string(ws)
        assert body["message"] =~ "Student Actions"
      end
    end

    test "a cursor for another class is 400, and one older than the window is 410", %{conn: conn} do
      other = RecentLogs.next_cursor(602, System.system_time(:millisecond), 600_000)
      expired = RecentLogs.next_cursor(601, System.system_time(:millisecond) - 2 * 86_400_000, 0)

      authed = researcher_conn(conn)

      assert %{"error" => "BAD_REQUEST"} = authed |> read(601, %{cursor: other}) |> json_response(400)
      expired_body = authed |> read(601, %{cursor: expired}) |> json_response(410)
      assert expired_body["error"] == "EXPIRED_CURSOR"
      assert expired_body["message"] =~ "Student Actions"
    end

    test "a class outside the grants and a class that does not exist are refused alike", %{conn: conn} do
      authed = researcher_conn(conn)
      outside = authed |> read(603) |> json_response(403)
      missing = authed |> read(999_999) |> json_response(403)

      assert outside == missing
      assert outside["error"] == "FORBIDDEN"
    end

    test "an access token for a class outside the grants is 403", %{conn: conn} do
      assert %{"error" => "FORBIDDEN"} =
               conn |> put_req_header("authorization", "Bearer #{access_token(603)}") |> read(603) |> json_response(403)
    end

    test "an access token for another class is 403, and no token is 401", %{conn: conn} do
      assert %{"error" => "FORBIDDEN"} =
               conn |> put_req_header("authorization", "Bearer #{access_token(602)}") |> read(601) |> json_response(403)

      assert %{"error" => "NOT_AUTHENTICATED"} = conn |> read(601) |> json_response(401)
    end

    test "the portal unreachable while reading learners is 503, whether the read errs or raises", %{conn: conn} do
      Application.put_env(:report_server, :learner_data, LearnerDataStub)
      authed = researcher_conn(conn)

      for fetch <- [
            fn _filter, _user, _opts -> {:error, "connection refused"} end,
            fn _filter, _user, _opts -> raise ReportServer.Reports.AllowedProjectsLookupError, message: "lookup failed" end
          ] do
        {:ok, pid} = LearnerDataStub.start(%{fetch: fetch})
        assert %{"error" => "SERVICE_UNAVAILABLE"} = authed |> read(601) |> json_response(503)
        Agent.stop(pid)
      end
    end
  end

  describe "the dashboard's access token" do
    test "reads from the allowlisted origin, which the answer echoes", %{conn: conn} do
      stub_athena(csv: rows_csv([]))

      conn =
        conn
        |> put_req_header("origin", @allowed)
        |> put_req_header("authorization", "Bearer #{access_token(601)}")
        |> read(601)

      assert json_response(conn, 200)["class_id"] == 601
      assert get_resp_header(conn, "access-control-allow-origin") == [@allowed]
    end

    test "is refused from another origin, with no allow-origin header", %{conn: conn} do
      conn =
        conn
        |> put_req_header("origin", "https://evil.example")
        |> put_req_header("authorization", "Bearer #{access_token(601)}")
        |> read(601)

      assert %{"error" => "FORBIDDEN"} = json_response(conn, 403)
      assert get_resp_header(conn, "access-control-allow-origin") == []
    end

    test "a bad bearer from another origin is refused by CORS before any token check", %{conn: conn} do
      conn =
        conn
        |> put_req_header("origin", "https://evil.example")
        |> put_req_header("authorization", "Bearer not-a-token")
        |> read(601)

      assert %{"error" => "FORBIDDEN"} = json_response(conn, 403)
    end

    test "the preflight from the allowlisted origin allows the authorization header", %{conn: conn} do
      conn =
        conn
        |> put_req_header("origin", @allowed)
        |> put_req_header("access-control-request-headers", "authorization")
        |> options("/api/v1/classes/601/recent-logs")

      assert conn.status == 204
      assert get_resp_header(conn, "access-control-allow-origin") == [@allowed]
      assert hd(get_resp_header(conn, "access-control-allow-headers")) =~ "authorization"
    end
  end

  describe "failures" do
    test "a query still running past the timeout is 503, and its limiter slot is given back", %{conn: conn} do
      stub_athena(csv: "", state: "running")

      assert %{"error" => "SERVICE_UNAVAILABLE"} = conn |> researcher_conn() |> read(601) |> json_response(503)

      assert :sys.get_state(ReportServer.RecentLogsLimiter).holders == %{}
    end

    test "a failed query is 503", %{conn: conn} do
      stub_athena(csv: "", state: "failed")

      assert %{"error" => "SERVICE_UNAVAILABLE"} = conn |> researcher_conn() |> read(601) |> json_response(503)
    end

    test "an S3 failure reading the result is 503", %{conn: conn} do
      stub_athena(csv: "", get_file_stream: fn _location -> {:error, "Unable to get stream"} end)

      assert %{"error" => "SERVICE_UNAVAILABLE"} = conn |> researcher_conn() |> read(601) |> json_response(503)
      assert audit_rows() == []
    end

    test "a query too large for Athena is 422", %{conn: conn} do
      stub_athena(csv: "", query: fn _sql, _id, _user -> {:error, AthenaDB.query_too_large_error()} end)

      assert %{"error" => "UNPROCESSABLE"} = conn |> researcher_conn() |> read(601) |> json_response(422)
    end

    test "a full limiter is 503 at once", %{conn: conn} do
      stub_athena(csv: rows_csv([]))
      cap = Application.get_env(:report_server, :recent_logs) |> Keyword.fetch!(:max_concurrent)
      parent = self()

      holders =
        for _ <- 1..cap do
          spawn(fn ->
            send(parent, {self(), PortalDownloadLimiter.try_acquire(ReportServer.RecentLogsLimiter)})
            receive do: (:stop -> :ok)
          end)
        end

      on_exit(fn -> for holder <- holders, do: send(holder, :stop) end)
      for holder <- holders, do: assert_receive({^holder, :ok})

      assert %{"error" => "SERVICE_UNAVAILABLE"} = conn |> researcher_conn() |> read(601) |> json_response(503)
      refute_received {:sql, _}
    end

    test "an audit write that fails is 500 with no rows", %{conn: conn} do
      stub_athena(csv: rows_csv([row("a", window_start() + 1_000)]))
      Application.put_env(:report_server, :audit_log, ReportServer.AuditLogFailingStub)

      body = conn |> researcher_conn() |> read(601) |> json_response(500)

      assert body["error"] == "SERVER_ERROR"
      refute Map.has_key?(body, "rows")
    end
  end
end
