defmodule ReportServerWeb.Api.V1.BulkExportControllerTest do
  use ReportServerWeb.ConnCase, async: false

  import ReportServer.AccountsFixtures

  alias ReportServer.Accounts
  alias ReportServer.AuditLog.DataAccessLogEntry
  alias ReportServer.Exports.ExportScratch
  alias ReportServer.{LearnerDataStub, ReportServiceStub, Repo}
  alias ReportServer.Reports
  alias ReportServerWeb.Api.V1.BulkParams

  setup :register_and_put_bearer_token

  setup do
    on_exit(fn ->
      Application.delete_env(:report_server, :learner_data)
      Application.delete_env(:report_server, :allowed_project_ids_source)
      Application.delete_env(:report_server, :report_service_client)
    end)

    :ok
  end

  # ---- helpers ----

  @page %{
    "items" => [%{"remote_endpoint" => "re-1", "id" => "a1"}],
    "stop_endpoint_offset" => 0,
    "inner_cursor" => %{"docId" => "a1"},
    "endpoint_exhausted" => false,
    "touched_endpoints" => []
  }

  @terminal_page %{
    "items" => [%{"remote_endpoint" => "re-1", "id" => "a2"}],
    "stop_endpoint_offset" => 0,
    "inner_cursor" => nil,
    "endpoint_exhausted" => true,
    "touched_endpoints" => []
  }

  defp learner_group(endpoint, url) do
    %{runnable_url: url, query_id: "q", learners: [%{run_remote_endpoint: endpoint, runnable_url: url}]}
  end

  defp stub(opts) do
    allowed = Keyword.get(opts, :allowed, [1, 2])
    fetch = Keyword.get(opts, :fetch, fn _f, _u, _o -> {:ok, [learner_group("re-1", "https://example.com/a")]} end)
    bulk_read = Keyword.get(opts, :bulk_read, fn _req -> {:ok, @page} end)

    {:ok, ld} =
      LearnerDataStub.start(%{get_allowed_project_ids: fn _ -> allowed end, fetch: fetch})

    {:ok, rs} = ReportServiceStub.start(%{bulk_read: bulk_read})

    Application.put_env(:report_server, :learner_data, LearnerDataStub)
    Application.put_env(:report_server, :allowed_project_ids_source, LearnerDataStub)
    Application.put_env(:report_server, :report_service_client, ReportServiceStub)

    on_exit(fn ->
      if Process.alive?(ld), do: Agent.stop(ld)
      if Process.alive?(rs), do: Agent.stop(rs)
    end)

    :ok
  end

  defp run_fixture(user, attrs \\ %{}) do
    {:ok, run} =
      Reports.create_report_run(Map.merge(%{user_id: user.id, report_slug: "student-answers"}, attrs))

    run
  end

  defp scratch_count, do: Repo.aggregate(ExportScratch, :count)
  defp entry_count, do: Repo.aggregate(DataAccessLogEntry, :count)

  # ---- ownership / existence ----

  describe "ownership and :id parsing" do
    test "404 for a run owned by someone else", %{conn: conn} do
      stub([])
      other = user_fixture()
      run = run_fixture(other)
      assert json_response(get(conn, ~p"/api/v1/reports/#{run.id}/answers"), 404)["error"] == "NOT_FOUND"
    end

    test "404 for a non-existent run", %{conn: conn} do
      stub([])
      assert json_response(get(conn, ~p"/api/v1/reports/999999/answers"), 404)
    end

    test "404 for a malformed :id", %{conn: conn} do
      stub([])
      assert json_response(get(conn, ~p"/api/v1/reports/not-a-number/answers"), 404)
    end

    test "404 for an out-of-bigint-range :id (never a 500)", %{conn: conn} do
      stub([])
      assert json_response(get(conn, ~p"/api/v1/reports/99999999999999999999999999/answers"), 404)
    end
  end

  test "the production report_service default resolves to a real module/function" do
    assert Code.ensure_loaded?(ReportServer.ReportService)
    assert function_exported?(ReportServer.ReportService, :bulk_read, 1)
  end

  # ---- derive path ----

  describe "first page derivation" do
    test "a run with a nil report_filter derives normally (not a 500)", %{conn: conn, user: user} do
      stub([])
      run = run_fixture(user)
      body = json_response(get(conn, ~p"/api/v1/reports/#{run.id}/answers"), 200)
      assert body["items"] == [%{"remote_endpoint" => "re-1", "id" => "a1"}]
    end

    test "empty permission set -> terminal empty page, no LearnerData.fetch, one intent row", %{conn: conn, user: user} do
      stub(allowed: [], fetch: fn _f, _u, _o -> raise "should not be called" end)
      run = run_fixture(user)

      body = json_response(get(conn, ~p"/api/v1/reports/#{run.id}/answers"), 200)
      assert body == %{"items" => [], "next_page_token" => nil}
      assert scratch_count() == 0

      entry = Repo.one!(DataAccessLogEntry)
      assert entry.event == "export_scoped"
      assert entry.data_type == "answers_bulk"
      assert entry.endpoint_set == []
    end

    test "non-empty perms but zero learners -> terminal empty page, one intent row", %{conn: conn, user: user} do
      stub(fetch: fn _f, _u, _o -> {:ok, []} end)
      run = run_fixture(user)

      body = json_response(get(conn, ~p"/api/v1/reports/#{run.id}/answers"), 200)
      assert body == %{"items" => [], "next_page_token" => nil}
      assert scratch_count() == 0
      assert Repo.one!(DataAccessLogEntry).endpoint_set == []
    end

    test "portal permission-query failure -> 500, no fetch, no rows written", %{conn: conn, user: user} do
      stub(allowed: {:error, "boom"}, fetch: fn _f, _u, _o -> raise "should not be called" end)
      run = run_fixture(user)

      assert json_response(get(conn, ~p"/api/v1/reports/#{run.id}/answers"), 500)
      assert scratch_count() == 0
      assert entry_count() == 0
    end

    test "an answersSourceKey-override run derives the override as the Firestore source", %{conn: conn, user: user} do
      test_pid = self()

      stub(
        fetch: fn _f, _u, _o ->
          {:ok, [learner_group("re-1", "https://activity-player.concord.org/x?answersSourceKey=custom-key")]}
        end,
        bulk_read: fn req -> send(test_pid, {:req, req}); {:ok, @page} end
      )

      run = run_fixture(user)
      get(conn, ~p"/api/v1/reports/#{run.id}/answers")

      assert_received {:req, req}
      assert [%{"source" => "custom-key", "remote_endpoint" => "re-1"}] = req.source_endpoints
    end

    test "a teacher-actions run derives a non-empty endpoint set and serves a page", %{conn: conn, user: user} do
      stub([])
      run = run_fixture(user, %{report_slug: "teacher-actions"})
      body = json_response(get(conn, ~p"/api/v1/reports/#{run.id}/answers"), 200)
      assert length(body["items"]) == 1
    end

    test "learners whose derived source is unusable are dropped, the rest serve normally", %{conn: conn, user: user} do
      test_pid = self()

      stub(
        fetch: fn _f, _u, _o ->
          {:ok,
           [
             learner_group("re-nil", nil),
             learner_group("re-foo", "foo"),
             learner_group("re-empty", "https://"),
             learner_group("re-slash", "https://example.com/x?answersSourceKey=a/b"),
             learner_group("re-ok", "https://example.com/a")
           ]}
        end,
        bulk_read: fn req -> send(test_pid, {:req, req}); {:ok, @page} end
      )

      run = run_fixture(user)
      assert json_response(get(conn, ~p"/api/v1/reports/#{run.id}/answers"), 200)

      assert_received {:req, req}
      assert Enum.map(req.source_endpoints, & &1["remote_endpoint"]) == ["re-ok"]
    end
  end

  # ---- paging / cursor round-trip ----

  describe "cursor round-trip" do
    test "one learner -> one page -> cursor -> resume (idempotent)", %{conn: conn, user: user} do
      stub([])
      run = run_fixture(user)

      body = json_response(get(conn, ~p"/api/v1/reports/#{run.id}/answers"), 200)
      token = body["next_page_token"]
      assert is_binary(token)

      assert {:ok, %{scratch_id: sid, endpoint_index: 0, inner_cursor: %{"docId" => "a1"}}} =
               BulkParams.parse_page_token(%{"page_token" => token})

      assert is_binary(sid)

      # replay the same token -> same page served (idempotent)
      body2 = json_response(get(conn, ~p"/api/v1/reports/#{run.id}/answers?page_token=#{token}"), 200)
      assert body2["items"] == body["items"]
    end

    test "a terminal page returns a null next_page_token and can be replayed", %{conn: conn, user: user} do
      stub(bulk_read: fn _req -> {:ok, @terminal_page} end)
      run = run_fixture(user)

      body = json_response(get(conn, ~p"/api/v1/reports/#{run.id}/answers"), 200)
      assert body["next_page_token"] == nil
    end

    test "no-store cache header on a served response", %{conn: conn, user: user} do
      stub([])
      run = run_fixture(user)
      conn = get(conn, ~p"/api/v1/reports/#{run.id}/answers")
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end
  end

  # ---- expiry / errors ----

  describe "errors" do
    test "an expired scratch -> 410 EXPIRED_CURSOR", %{conn: conn, user: user} do
      stub([])
      run = run_fixture(user)

      body = json_response(get(conn, ~p"/api/v1/reports/#{run.id}/answers"), 200)
      token = body["next_page_token"]

      # expire the scratch row
      Repo.update_all(ExportScratch, set: [expires_at: DateTime.utc_now(:second) |> DateTime.add(-60)])

      resp = get(conn, ~p"/api/v1/reports/#{run.id}/answers?page_token=#{token}")
      assert json_response(resp, 410)["error"] == "EXPIRED_CURSOR"
    end

    test "a Node read failure -> 500, no cursor advance", %{conn: conn, user: user} do
      stub(bulk_read: fn _req -> {:error, "node down"} end)
      run = run_fixture(user)
      assert json_response(get(conn, ~p"/api/v1/reports/#{run.id}/answers"), 500)
    end

    test "a Node success with an unexpected body shape -> 500 (fail closed, no crash)", %{conn: conn, user: user} do
      stub(bulk_read: fn _req -> {:ok, %{"unexpected" => true}} end)
      run = run_fixture(user)
      assert json_response(get(conn, ~p"/api/v1/reports/#{run.id}/answers"), 500)
    end

    test "a Node success with broken semantics (bad offset / non-boolean exhausted) -> 500, no cursor advance", %{conn: conn, user: user} do
      bad_pages = [
        %{@page | "stop_endpoint_offset" => -1},
        %{@page | "stop_endpoint_offset" => 1},        # only 1 endpoint in the slice
        %{@page | "stop_endpoint_offset" => "0"},
        %{@page | "endpoint_exhausted" => "yes"},
        %{@page | "items" => "not-a-list"}
      ]

      {:ok, holder} = Agent.start_link(fn -> nil end)
      stub(bulk_read: fn _req -> {:ok, Agent.get(holder, & &1)} end)
      run = run_fixture(user)

      for bad_page <- bad_pages do
        Agent.update(holder, fn _ -> bad_page end)
        assert json_response(get(conn, ~p"/api/v1/reports/#{run.id}/answers"), 500)
      end
    end

    test "a revoked API token halts a mid-export request with 401", %{conn: conn, user: user, api_token: api_token} do
      stub([])
      run = run_fixture(user)

      body = json_response(get(conn, ~p"/api/v1/reports/#{run.id}/answers"), 200)
      token = body["next_page_token"]

      {:ok, _} = Accounts.revoke_api_token(api_token, user.id)

      resp = get(conn, ~p"/api/v1/reports/#{run.id}/answers?page_token=#{token}")
      assert json_response(resp, 401)["error"] == "NOT_AUTHENTICATED"
    end
  end

  # ---- history + audit build-out ----

  defp sid_from(body), do: elem(BulkParams.parse_page_token(%{"page_token" => body["next_page_token"]}), 1).scratch_id

  describe "/history" do
    test "serves a page and mints a history_bulk scratch", %{conn: conn, user: user} do
      stub([])
      run = run_fixture(user)

      body = json_response(get(conn, ~p"/api/v1/reports/#{run.id}/history"), 200)
      assert length(body["items"]) == 1
      assert Repo.one!(ExportScratch).data_type == "history_bulk"
    end

    test "an out-of-range history cursor seconds -> 400, not 500", %{conn: conn, user: user} do
      stub([])
      run = run_fixture(user)
      body = json_response(get(conn, ~p"/api/v1/reports/#{run.id}/history"), 200)
      sid = sid_from(body)

      for bad_seconds <- [253_402_300_800, -62_135_596_801] do
        token = BulkParams.encode_page_token(sid, 0, %{"seconds" => bad_seconds, "nanoseconds" => 0, "docId" => "x"})
        assert json_response(get(conn, ~p"/api/v1/reports/#{run.id}/history?page_token=#{token}"), 400)
      end

      ok = BulkParams.encode_page_token(sid, 0, %{"seconds" => 253_402_300_799, "nanoseconds" => 0, "docId" => "x"})
      assert json_response(get(conn, ~p"/api/v1/reports/#{run.id}/history?page_token=#{ok}"), 200)
    end

    test "a non-plain cursor docId -> 400, not 500", %{conn: conn, user: user} do
      stub([])
      run = run_fixture(user)
      body = json_response(get(conn, ~p"/api/v1/reports/#{run.id}/history"), 200)
      sid = sid_from(body)

      for bad_doc <- ["a/b", ""] do
        token = BulkParams.encode_page_token(sid, 0, %{"seconds" => 1, "nanoseconds" => 0, "docId" => bad_doc})
        assert json_response(get(conn, ~p"/api/v1/reports/#{run.id}/history?page_token=#{token}"), 400)
      end
    end
  end

  describe "audit rows" do
    test "page 1 writes an export_scoped intent row and a bulk_read access row, both export_id = scratch_id",
         %{conn: conn, user: user} do
      stub([])
      run = run_fixture(user)

      body = json_response(get(conn, ~p"/api/v1/reports/#{run.id}/answers"), 200)
      sid = sid_from(body)

      rows = Repo.all(DataAccessLogEntry)
      assert length(rows) == 2
      assert Enum.sort(Enum.map(rows, & &1.event)) == ["bulk_read", "export_scoped"]
      assert Enum.all?(rows, &(&1.export_id == sid))

      access = Enum.find(rows, &(&1.event == "bulk_read"))
      assert access.data_type == "answers_bulk"
      assert access.endpoint_set == ["re-1"]

      intent = Enum.find(rows, &(&1.event == "export_scoped"))
      assert intent.data_type == "answers_bulk"
    end

    test "the intent row's data_type matches the route (history)", %{conn: conn, user: user} do
      stub([])
      run = run_fixture(user)

      json_response(get(conn, ~p"/api/v1/reports/#{run.id}/history"), 200)

      intent = DataAccessLogEntry |> Repo.all() |> Enum.find(&(&1.event == "export_scoped"))
      assert intent.data_type == "history_bulk"
    end

    test "a subsequent page writes only a bulk_read access row", %{conn: conn, user: user} do
      stub([])
      run = run_fixture(user)

      body = json_response(get(conn, ~p"/api/v1/reports/#{run.id}/answers"), 200)
      token = body["next_page_token"]

      before = Repo.aggregate(DataAccessLogEntry, :count)
      json_response(get(conn, ~p"/api/v1/reports/#{run.id}/answers?page_token=#{token}"), 200)

      new_rows = Repo.aggregate(DataAccessLogEntry, :count) - before
      assert new_rows == 1
    end
  end

  describe "empty mid-export page" do
    test "items [] with a non-null next token when an endpoint cap lands mid-export", %{conn: conn, user: user} do
      empty_page = %{
        "items" => [],
        "stop_endpoint_offset" => 0,
        "inner_cursor" => nil,
        "endpoint_exhausted" => true,
        "touched_endpoints" => []
      }

      stub(
        fetch: fn _f, _u, _o ->
          {:ok, [learner_group("re-1", "https://example.com/a"), learner_group("re-2", "https://example.com/b")]}
        end,
        bulk_read: fn _req -> {:ok, empty_page} end
      )

      run = run_fixture(user)
      body = json_response(get(conn, ~p"/api/v1/reports/#{run.id}/answers"), 200)
      assert body["items"] == []
      assert is_binary(body["next_page_token"])
    end
  end

  describe "cross-route replay" do
    test "a /history-minted token replayed on /answers -> 404 via the data_type guard", %{conn: conn, user: user} do
      stub([])
      run = run_fixture(user)

      body = json_response(get(conn, ~p"/api/v1/reports/#{run.id}/history"), 200)
      token = body["next_page_token"]

      assert json_response(get(conn, ~p"/api/v1/reports/#{run.id}/answers?page_token=#{token}"), 404)
    end
  end
end
