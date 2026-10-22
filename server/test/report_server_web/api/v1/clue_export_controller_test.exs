defmodule ReportServerWeb.Api.V1.ClueExportControllerTest do
  use ReportServerWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog
  import ReportServer.AccountsFixtures

  alias ReportServer.AuditLog.DataAccessLogEntry
  alias ReportServer.Exports.ExportScratch
  alias ReportServer.{ClueClassHashesStub, ClueExportStub, LearnerDataStub, Repo}
  alias ReportServer.Reports
  alias ReportServerWeb.Api.V1.BulkParams

  setup :register_and_put_bearer_token

  @hash String.duplicate("a", 48)
  @hash_b String.duplicate("b", 48)
  @clue_url "https://collaborative-learning.concord.org/?unit=x"
  @student %{"class_hash" => @hash, "uid" => "101", "kind" => "student", "portal_class_id" => 601, "offerings" => [701]}
  @class %{"class_hash" => @hash, "uid" => "class_" <> @hash, "kind" => "class", "portal_class_id" => 601, "offerings" => [701]}

  setup do
    on_exit(fn ->
      Application.delete_env(:report_server, :learner_data)
      Application.delete_env(:report_server, :allowed_project_ids_source)
      Application.delete_env(:report_server, :clue_export_client)
      Application.delete_env(:report_server, :clue_class_hashes)
    end)

    :ok
  end

  # ---- helpers ----

  defp learner(user_id, class_id, offering_id, url \\ @clue_url),
    do: %{user_id: user_id, class_id: class_id, offering_id: offering_id, runnable_url: url,
          run_remote_endpoint: "re-#{user_id}-#{offering_id}"}

  defp groups_of(learners), do: [%{runnable_url: @clue_url, query_id: "q", learners: learners}]

  defp page(items, off, cursor, exhausted, served),
    do: %{"items" => items, "stop_owner_offset" => off, "inner_cursor" => cursor,
          "owner_exhausted" => exhausted, "served_owner_offsets" => served}

  defp terminal(req), do: {:ok, page([%{"doc_id" => "d1"}], length(req.owners) - 1, nil, true, [0])}

  defp stub(opts \\ []) do
    test_pid = self()
    allowed = Keyword.get(opts, :allowed, [1, 2])
    learners = Keyword.get(opts, :learners, [learner(101, 601, 701)])
    fetch = Keyword.get(opts, :fetch, fn _f, _u, _o -> {:ok, groups_of(learners)} end)
    hashes = Keyword.get(opts, :hashes, fn _portal, ids -> {:ok, Map.new(ids, &{&1, hash_for(&1)})} end)
    owners = Keyword.get(opts, :owners, fn _req -> {:ok, %{"groups" => []}} end)
    call = Keyword.get(opts, :call, &terminal/1)
    url = Keyword.get(opts, :url, "https://clueexport.example.org")

    {:ok, ld} = LearnerDataStub.start(%{get_allowed_project_ids: fn _ -> allowed end, fetch: fetch})
    {:ok, ch} = ClueClassHashesStub.start(hashes)

    {:ok, ce} =
      ClueExportStub.start(%{
        url_for: fn _portal -> url end,
        call: fn _portal, req ->
          send(test_pid, {:call, req})
          if req.operation == "owners", do: owners.(req), else: call.(req)
        end
      })

    Application.put_env(:report_server, :learner_data, LearnerDataStub)
    Application.put_env(:report_server, :allowed_project_ids_source, LearnerDataStub)
    Application.put_env(:report_server, :clue_export_client, ClueExportStub)
    Application.put_env(:report_server, :clue_class_hashes, ClueClassHashesStub)

    on_exit(fn -> for pid <- [ld, ch, ce], Process.alive?(pid), do: Agent.stop(pid) end)
    :ok
  end

  defp hash_for(601), do: @hash
  defp hash_for(602), do: @hash_b
  defp hash_for(id), do: id |> Integer.to_string() |> String.pad_leading(48, "0")

  defp refuse_calls do
    Agent.update(ClueExportStub, &Map.put(&1, :call, fn _portal, _req -> raise "the function should not be called" end))
  end

  defp run_fixture(user, attrs \\ %{}) do
    {:ok, run} = Reports.create_report_run(Map.merge(%{user_id: user.id, report_slug: "student-answers"}, attrs))
    run
  end

  defp clue_path(run, route, token \\ nil) do
    base = "/api/v1/reports/#{run.id}/clue/#{route}"
    if token, do: base <> "?page_token=" <> URI.encode_www_form(token), else: base
  end

  defp walk_requests do
    Stream.repeatedly(fn ->
      receive do
        {:call, %{operation: op} = req} when op != "owners" -> req
      after
        0 -> nil
      end
    end)
    |> Enum.take_while(& &1)
  end

  defp owners_requests do
    Stream.repeatedly(fn ->
      receive do
        {:call, %{operation: "owners"} = req} -> req
      after
        0 -> nil
      end
    end)
    |> Enum.take_while(& &1)
  end

  defp scratch_count, do: Repo.aggregate(ExportScratch, :count)
  defp entry_count, do: Repo.aggregate(DataAccessLogEntry, :count)
  defp entries(event), do: Repo.all(from e in DataAccessLogEntry, where: e.event == ^event, order_by: e.id)

  # ---- per route ----

  for {route, data_type, cursor} <- [
        {"documents", "clue_documents_bulk", %{"docId" => "d1"}},
        {"history", "clue_history_bulk", %{"docId" => "d1", "index" => 2, "entryId" => "e2"}},
        {"content", "clue_content_bulk", %{"docId" => "d1"}}
      ] do
    describe "/clue/#{route}" do
      test "a first page serves the function's items and records the intent and the page", %{conn: conn, user: user} do
        stub(call: fn _req -> {:ok, page([%{"doc_id" => "d1"}, %{"doc_id" => "d2"}], 0, unquote(Macro.escape(cursor)), false, [0])} end)
        run = run_fixture(user)

        body = json_response(get(conn, clue_path(run, unquote(route))), 200)
        assert body["items"] == [%{"doc_id" => "d1"}, %{"doc_id" => "d2"}]
        assert body["total_endpoints"] == 2
        assert is_binary(body["next_page_token"])

        assert [%{operation: unquote(route), owners: [@student, @class], inner_cursor: nil, limit: 500,
                  owner_limit: 250, read_limit: 5000}] = walk_requests()

        assert [intent] = entries("export_scoped")
        assert %{data_type: unquote(data_type), item_count: nil} = intent
        assert intent.endpoint_set == ["clue:#{@hash}:101", "clue:#{@hash}:class_#{@hash}"]

        assert [access] = entries("bulk_read")
        assert %{data_type: unquote(data_type), item_count: 2, export_id: export_id} = access
        assert export_id == intent.export_id
        assert access.endpoint_set == ["clue:#{@hash}:101"]
      end

      test "resuming sends the stored slice and cursor, and the terminal token re-serves the final page",
           %{conn: conn, user: user} do
        stub(call: fn
          %{inner_cursor: nil} -> {:ok, page([%{"doc_id" => "d1"}], 0, unquote(Macro.escape(cursor)), false, [0])}
          _resumed -> {:ok, page([%{"doc_id" => "d2"}], 1, nil, true, [0, 1])}
        end)

        run = run_fixture(user)

        token = json_response(get(conn, clue_path(run, unquote(route))), 200)["next_page_token"]
        walk_requests()

        final = json_response(get(conn, clue_path(run, unquote(route), token)), 200)
        assert final == %{"items" => [%{"doc_id" => "d2"}], "next_page_token" => nil, "total_endpoints" => 2}
        assert [%{owners: [@student, @class], inner_cursor: unquote(Macro.escape(cursor))}] = walk_requests()

        assert [_first_page, %{cursor: ^token}] = entries("bulk_read")

        assert json_response(get(conn, clue_path(run, unquote(route), token)), 200) == final
      end

      test "a token idle past an hour is 410", %{conn: conn, user: user} do
        stub(call: fn _req -> {:ok, page([], 0, unquote(Macro.escape(cursor)), false, [])} end)
        run = run_fixture(user)

        token = json_response(get(conn, clue_path(run, unquote(route))), 200)["next_page_token"]
        Repo.update_all(ExportScratch, set: [expires_at: DateTime.utc_now(:second) |> DateTime.add(-60)])

        assert json_response(get(conn, clue_path(run, unquote(route), token)), 410)["error"] == "EXPIRED_CURSOR"
      end

      test "a portal unconfigured after the first page is 503 on the next", %{conn: conn, user: user} do
        stub(call: fn _req -> {:ok, page([], 0, unquote(Macro.escape(cursor)), false, [])} end)
        run = run_fixture(user)

        token = json_response(get(conn, clue_path(run, unquote(route))), 200)["next_page_token"]
        Agent.update(ClueExportStub, &Map.put(&1, :url_for, fn _portal -> nil end))

        assert json_response(get(conn, clue_path(run, unquote(route), token)), 503)["error"] == "SERVICE_UNAVAILABLE"
        assert length(entries("bulk_read")) == 1
      end

      test "an unconfigured portal is 503 before any scratch or audit row", %{conn: conn, user: user} do
        stub(url: nil)
        run = run_fixture(user)

        assert json_response(get(conn, clue_path(run, unquote(route))), 503)["error"] == "SERVICE_UNAVAILABLE"
        assert scratch_count() == 0
        assert entry_count() == 0
      end
    end
  end

  test "a limit lowers the page cap the function is sent, and a malformed one is 400", %{conn: conn, user: user} do
    stub()
    run = run_fixture(user)

    assert json_response(get(conn, clue_path(run, "history") <> "?limit=7"), 200)
    assert [%{limit: 7}] = walk_requests()

    assert json_response(get(conn, clue_path(run, "history") <> "?limit=abc"), 400)["error"] == "BAD_REQUEST"
  end

  test "a /clue/history token is 404 on /clue/documents", %{conn: conn, user: user} do
    stub(call: fn _req -> {:ok, page([], 0, %{"docId" => "d1", "index" => 0, "entryId" => "e0"}, false, [])} end)
    run = run_fixture(user)

    token = json_response(get(conn, clue_path(run, "history")), 200)["next_page_token"]
    assert json_response(get(conn, clue_path(run, "documents", token)), 404)["error"] == "NOT_FOUND"
  end

  # ---- run kinds and authorization ----

  describe "run kinds" do
    for slug <- ["student-id-mapping", "student-answers"] do
      test "a #{slug} run serves a first page", %{conn: conn, user: user} do
        stub()
        run = run_fixture(user, %{report_slug: unquote(slug)})
        assert json_response(get(conn, clue_path(run, "documents")), 200)["items"] == [%{"doc_id" => "d1"}]
      end
    end

    test "a report without per-learner data is 422", %{conn: conn, user: user} do
      stub()
      run = run_fixture(user, %{report_slug: "school-metrics"})
      assert json_response(get(conn, clue_path(run, "documents")), 422)["error"] == "UNPROCESSABLE"
    end
  end

  describe "authorization" do
    test "a run the caller does not own is 404", %{conn: conn} do
      stub()
      run = run_fixture(user_fixture())
      assert json_response(get(conn, clue_path(run, "documents")), 404)["error"] == "NOT_FOUND"
    end

    test "a token whose user has no report role is 401", %{conn: conn} do
      stub()
      user = user_fixture(%{portal_is_admin: false, portal_is_project_admin: false, portal_is_project_researcher: false})
      {raw_token, _api_token} = api_token_fixture(user)
      run = run_fixture(user)

      conn = conn |> put_req_header("authorization", "Bearer #{raw_token}") |> get(clue_path(run, "documents"))
      assert json_response(conn, 401)["error"] == "NOT_AUTHENTICATED"
    end

    test "grants that exclude every learner give an empty terminal page and an intent row", %{conn: conn, user: user} do
      stub(allowed: [], fetch: fn _f, _u, _o -> raise "should not be called" end)
      refuse_calls()
      run = run_fixture(user)

      assert json_response(get(conn, clue_path(run, "documents")), 200) == %{"items" => [], "next_page_token" => nil, "total_endpoints" => 0}
      assert scratch_count() == 0
      assert [%{endpoint_set: [], data_type: "clue_documents_bulk"}] = entries("export_scoped")
    end
  end

  # ---- scope ----

  describe "empty scope" do
    test "learners whose classes have no hash", %{conn: conn, user: user} do
      stub(hashes: fn _portal, _ids -> {:ok, %{}} end)
      refuse_calls()
      run = run_fixture(user)

      assert json_response(get(conn, clue_path(run, "history")), 200) == %{"items" => [], "next_page_token" => nil, "total_endpoints" => 0}
      assert scratch_count() == 0
      assert length(entries("export_scoped")) == 1
    end

    test "learners on no CLUE-writing host", %{conn: conn, user: user} do
      stub(learners: [learner(101, 601, 701, "https://activity.concord.org/?x=collaborative-learning.concord.org")])
      refuse_calls()
      run = run_fixture(user)

      assert json_response(get(conn, clue_path(run, "history")), 200) == %{"items" => [], "next_page_token" => nil, "total_endpoints" => 0}
      assert scratch_count() == 0
      assert length(entries("export_scoped")) == 1
    end
  end

  describe "scope owners" do
    test "251 classes make owners calls of 250 and 1, and a group from the second is frozen", %{conn: conn, user: user} do
      learners = for class_id <- 1..251, do: learner(class_id, class_id, 1000 + class_id)
      last_hash = hash_for(251)

      stub(
        learners: learners,
        owners: fn req ->
          groups =
            if Enum.any?(req.classes, &(&1["class_hash"] == last_hash)),
              do: [%{"class_hash" => last_hash, "uid" => "group_1251_1", "offering" => 1251}],
              else: []

          {:ok, %{"groups" => groups}}
        end
      )

      run = run_fixture(user)
      assert is_binary(json_response(get(conn, clue_path(run, "documents")), 200)["next_page_token"])

      assert [walk] = walk_requests()
      assert length(walk.owners) == 250

      assert [first, second] = owners_requests()
      assert length(first.classes) == 250
      assert second.classes == [%{"class_hash" => last_hash, "offerings" => [1251]}]

      [scratch] = Repo.all(ExportScratch)
      assert length(scratch.endpoint_set) == 251 * 2 + 1

      assert %{"kind" => "group", "portal_class_id" => 251, "offerings" => [1251]} =
               Enum.find(scratch.endpoint_set, &(&1["uid"] == "group_1251_1"))
    end

    test "only learners on CLUE-writing hosts with a class hash become owners", %{conn: conn, user: user} do
      test_pid = self()

      stub(
        learners: [
          learner(101, 601, 701, "https://collaborative-learning.concord.org/branch/master/?unit=x"),
          learner(102, 601, 702, "https://dataflow-app.concord.org/"),
          learner(103, 602, 801, "https://activity.concord.org/a"),
          learner(104, 603, 901)
        ],
        hashes: fn _portal, ids ->
          send(test_pid, {:hash_ids, ids})
          {:ok, ids |> Enum.reject(&(&1 == 603)) |> Map.new(&{&1, hash_for(&1)})}
        end
      )

      run = run_fixture(user)
      assert json_response(get(conn, clue_path(run, "documents")), 200)["total_endpoints"] == 3
      assert_received {:hash_ids, ids}
      assert Enum.sort(ids) == [601, 603]

      [scratch] = Repo.all(ExportScratch)
      assert Enum.map(scratch.endpoint_set, & &1["uid"]) == ["101", "102", "class_" <> @hash]
      assert [%{classes: [%{"class_hash" => @hash, "offerings" => [701, 702]}]}] = owners_requests()
    end

    test "group rows become owners narrowed to their own offering", %{conn: conn, user: user} do
      stub(
        learners: [learner(101, 601, 701), learner(101, 601, 703)],
        owners: fn _req -> {:ok, %{"groups" => [%{"class_hash" => @hash, "uid" => "group_703_2", "offering" => 703}]}} end
      )

      run = run_fixture(user)
      assert json_response(get(conn, clue_path(run, "documents")), 200)

      [scratch] = Repo.all(ExportScratch)

      assert scratch.endpoint_set == [
               %{@student | "offerings" => [701, 703]},
               %{@class | "offerings" => [701, 703]},
               %{"class_hash" => @hash, "uid" => "group_703_2", "kind" => "group", "portal_class_id" => 601, "offerings" => [703]}
             ]
    end

    for {label, group} <- [
          {"an unrequested class", %{"class_hash" => String.duplicate("c", 48), "uid" => "group_701_1", "offering" => 701}},
          {"an unrequested offering", %{"class_hash" => String.duplicate("a", 48), "uid" => "group_999_1", "offering" => 999}},
          {"another offering's group id", %{"class_hash" => String.duplicate("a", 48), "uid" => "group_7011_1", "offering" => 701}}
        ] do
      test "a group row naming #{label} is 500 and writes no row", %{conn: conn, user: user} do
        stub(owners: fn _req -> {:ok, %{"groups" => [unquote(Macro.escape(group))]}} end)
        run = run_fixture(user)

        assert json_response(get(conn, clue_path(run, "documents")), 500)
        assert scratch_count() == 0
        assert entry_count() == 0
      end
    end

    for {label, answer} <- [
          {"no groups list", %{}},
          {"a group row with no offering", %{"groups" => [%{"class_hash" => String.duplicate("a", 48), "uid" => "group_701_1"}]}}
        ] do
      test "an owners answer with #{label} is 500 and writes no row", %{conn: conn, user: user} do
        stub(owners: fn _req -> {:ok, unquote(Macro.escape(answer))} end)
        run = run_fixture(user)

        assert json_response(get(conn, clue_path(run, "documents")), 500)
        assert scratch_count() == 0
        assert entry_count() == 0
      end
    end

    test "a failed class-hash lookup is 500 and writes no row", %{conn: conn, user: user} do
      stub(hashes: fn _portal, _ids -> {:error, "portal down"} end)
      refuse_calls()
      run = run_fixture(user)

      assert json_response(get(conn, clue_path(run, "documents")), 500)
      assert scratch_count() == 0
      assert entry_count() == 0
    end

    test "a failed owners call is 500 and writes no row", %{conn: conn, user: user} do
      stub(owners: fn _req -> {:error, "read failed"} end)
      run = run_fixture(user)

      assert json_response(get(conn, clue_path(run, "documents")), 500)
      assert scratch_count() == 0
      assert entry_count() == 0
    end

    test "the owners are frozen on the first page", %{conn: conn, user: user} do
      stub(call: fn
        %{inner_cursor: nil} -> {:ok, page([], 0, %{"docId" => "d1"}, false, [])}
        _resumed -> {:ok, page([], 1, nil, true, [])}
      end)

      run = run_fixture(user)
      token = json_response(get(conn, clue_path(run, "documents")), 200)["next_page_token"]
      walk_requests()

      Agent.update(LearnerDataStub, &Map.put(&1, :fetch, fn _f, _u, _o -> {:ok, groups_of([learner(999, 602, 801)])} end))

      assert json_response(get(conn, clue_path(run, "documents", token)), 200)
      assert [%{owners: [@student, @class]}] = walk_requests()
    end
  end

  # ---- paging ----

  describe "paging" do
    test "a history export resumes inside a document and ends with every entry once, in order",
         %{conn: conn, user: user} do
      student_entries = for i <- 0..6, do: %{"doc_id" => "d1", "entry_id" => "e#{i}", "idx" => i}
      class_entries = [%{"doc_id" => "c1", "entry_id" => "x0", "idx" => 0}]

      stub(call: fn
        %{inner_cursor: nil, owners: [@student | _]} ->
          {:ok, page(Enum.slice(student_entries, 0, 3), 0, %{"docId" => "d1", "index" => 2, "entryId" => "e2"}, false, [0])}

        %{inner_cursor: %{"entryId" => "e2"}} ->
          {:ok, page(Enum.slice(student_entries, 3, 3), 0, %{"docId" => "d1", "index" => 5, "entryId" => "e5"}, false, [0])}

        %{inner_cursor: %{"entryId" => "e5"}} ->
          {:ok, page(Enum.slice(student_entries, 6, 1), 0, nil, true, [0])}

        %{inner_cursor: nil, owners: [@class]} ->
          {:ok, page(class_entries, 0, nil, true, [0])}
      end)

      run = run_fixture(user)

      items =
        Stream.unfold(nil, fn
          :done -> nil
          token ->
            body = json_response(get(conn, clue_path(run, "history", token)), 200)
            {body["items"], body["next_page_token"] || :done}
        end)
        |> Enum.concat()

      assert items == student_entries ++ class_entries

      assert Enum.map(entries("bulk_read"), & &1.endpoint_set) ==
               List.duplicate(["clue:#{@hash}:101"], 3) ++ [["clue:#{@hash}:class_#{@hash}"]]
    end

    test "an empty mid-export page with a token continues", %{conn: conn, user: user} do
      stub(call: fn
        %{inner_cursor: nil} -> {:ok, page([], 0, %{"docId" => "d1"}, false, [])}
        _resumed -> {:ok, page([%{"doc_id" => "d2"}], 1, nil, true, [0])}
      end)

      run = run_fixture(user)
      body = json_response(get(conn, clue_path(run, "documents")), 200)
      assert body["items"] == []
      assert is_binary(body["next_page_token"])

      assert json_response(get(conn, clue_path(run, "documents", body["next_page_token"])), 200)["items"] == [%{"doc_id" => "d2"}]
    end
  end

  # ---- cursors ----

  describe "cursors" do
    for {route, cursor} <- [
          {"history", %{"docId" => "d1", "index" => 0}},
          {"history", %{"docId" => "d1", "index" => -1, "entryId" => "e0"}},
          {"history", %{"docId" => "a/b", "index" => 0, "entryId" => "e0"}},
          {"history", %{"docId" => "d1", "index" => 0, "entryId" => "e.0"}},
          {"history", %{"docId" => "d1", "index" => 0, "entryId" => "e]0"}},
          {"documents", %{"docId" => "a#b"}},
          {"documents", %{"docId" => "a$b"}},
          {"documents", %{"docId" => "a[b"}},
          {"documents", %{"docId" => ""}},
          {"documents", %{"docId" => 1}},
          {"content", %{"docId" => "a]b"}}
        ] do
      test "a #{route} cursor #{inspect(cursor)} is 400 before the function is called", %{conn: conn, user: user} do
        good = if unquote(route) == "history", do: %{"docId" => "d1", "index" => 0, "entryId" => "e0"}, else: %{"docId" => "d1"}
        stub(call: fn _req -> {:ok, page([], 0, good, false, [])} end)
        run = run_fixture(user)

        token = json_response(get(conn, clue_path(run, unquote(route))), 200)["next_page_token"]
        {:ok, %{scratch_id: sid}} = BulkParams.parse_page_token(%{"page_token" => token})
        refuse_calls()

        bad = BulkParams.encode_page_token(sid, 0, unquote(Macro.escape(cursor)))
        assert json_response(get(conn, clue_path(run, unquote(route), bad)), 400)["error"] == "BAD_REQUEST"
      end
    end
  end

  test "a token whose owner index is past the frozen owners is 400", %{conn: conn, user: user} do
    stub(call: fn _req -> {:ok, page([], 0, %{"docId" => "d1"}, false, [])} end)
    run = run_fixture(user)

    token = json_response(get(conn, clue_path(run, "documents")), 200)["next_page_token"]
    {:ok, %{scratch_id: sid}} = BulkParams.parse_page_token(%{"page_token" => token})
    refuse_calls()

    bad = BulkParams.encode_page_token(sid, 2, nil)
    assert json_response(get(conn, clue_path(run, "documents", bad)), 400)["error"] == "BAD_REQUEST"
  end

  # ---- the function's answers ----

  test "a resumed page that does not advance is 500 with no page row", %{conn: conn, user: user} do
    cursor = %{"docId" => "d1"}

    stub(call: fn
      %{inner_cursor: nil} -> {:ok, page([], 0, cursor, false, [])}
      _resumed -> {:ok, page([], 0, cursor, false, [])}
    end)

    run = run_fixture(user)
    token = json_response(get(conn, clue_path(run, "documents")), 200)["next_page_token"]

    assert json_response(get(conn, clue_path(run, "documents", token)), 500)
    assert length(entries("bulk_read")) == 1
  end

  describe "audit and the function's answers" do
    test "a page row names only the owners that served items, and counts them", %{conn: conn, user: user} do
      stub(
        learners: [learner(101, 601, 701), learner(102, 601, 701)],
        call: fn _req -> {:ok, page([%{"doc_id" => "a"}, %{"doc_id" => "b"}, %{"doc_id" => "c"}], 2, nil, true, [1, 1])} end
      )

      run = run_fixture(user)
      assert json_response(get(conn, clue_path(run, "documents")), 200)

      assert [access] = entries("bulk_read")
      assert access.endpoint_set == ["clue:#{@hash}:102"]
      assert access.item_count == 3
    end

    for {label, answer} <- [
          {"a served offset beyond the stop", %{"items" => [], "stop_owner_offset" => 0, "inner_cursor" => nil,
                                                "owner_exhausted" => true, "served_owner_offsets" => [1]}},
          {"a stop offset outside the slice", %{"items" => [], "stop_owner_offset" => 2, "inner_cursor" => nil,
                                                "owner_exhausted" => true, "served_owner_offsets" => []}},
          {"an exhausted owner with a cursor", %{"items" => [], "stop_owner_offset" => 0, "inner_cursor" => %{"docId" => "d1"},
                                                 "owner_exhausted" => true, "served_owner_offsets" => []}},
          {"an unexhausted owner with no cursor", %{"items" => [], "stop_owner_offset" => 0, "inner_cursor" => nil,
                                                    "owner_exhausted" => false, "served_owner_offsets" => []}},
          {"a cursor that would not resume", %{"items" => [], "stop_owner_offset" => 0, "inner_cursor" => %{"docId" => "a/b"},
                                               "owner_exhausted" => false, "served_owner_offsets" => []}},
          {"items with no served owner", %{"items" => [%{"doc_id" => "d1"}], "stop_owner_offset" => 0, "inner_cursor" => nil,
                                           "owner_exhausted" => true, "served_owner_offsets" => []}},
          {"a missing field", %{"items" => []}}
        ] do
      test "#{label} is 500 with no page row", %{conn: conn, user: user} do
        stub(call: fn _req -> {:ok, unquote(Macro.escape(answer))} end)
        run = run_fixture(user)

        assert json_response(get(conn, clue_path(run, "documents")), 500)
        assert entries("bulk_read") == []
      end
    end

    test "an unexpected page is logged by its shape, never its items", %{conn: conn, user: user} do
      stub(call: fn _req -> {:ok, %{"items" => [%{"doc_id" => "student-work-d9"}], "stop_owner_offset" => 7}} end)
      run = run_fixture(user)

      log = capture_log(fn -> assert json_response(get(conn, clue_path(run, "documents")), 500) end)
      assert log =~ "unexpected page"
      assert log =~ "stop_owner_offset 7"
      refute log =~ "student-work-d9"
    end

    test "a failed read is 500 with no page row", %{conn: conn, user: user} do
      stub(call: fn _req -> {:error, "read failed"} end)
      run = run_fixture(user)

      assert json_response(get(conn, clue_path(run, "content")), 500)
      assert entries("bulk_read") == []
    end

    test "a served page is never cached", %{conn: conn, user: user} do
      stub()
      run = run_fixture(user)

      conn = get(conn, clue_path(run, "content"))
      assert json_response(conn, 200)
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert get_resp_header(conn, "pragma") == ["no-cache"]
    end
  end
end
