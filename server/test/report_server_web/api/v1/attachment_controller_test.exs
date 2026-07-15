defmodule ReportServerWeb.Api.V1.AttachmentControllerTest do
  use ReportServerWeb.ConnCase, async: false

  import ReportServer.AccountsFixtures

  alias ReportServer.AuditLog.DataAccessLogEntry
  alias ReportServer.{LearnerDataStub, ReportServiceStub, Repo}
  alias ReportServer.Reports

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

  defp learner_group(endpoint, url) do
    %{runnable_url: url, query_id: "q", learners: [%{run_remote_endpoint: endpoint, runnable_url: url}]}
  end

  defp meta(re, opts \\ []) do
    %{
      "publicPath" => Keyword.get(opts, :key, "interactive-attachments/f/u/file.json"),
      "contentType" => Keyword.get(opts, :ct, "application/json"),
      "remote_endpoint" => re
    }
  end

  defp result_row(doc_id, name, m), do: %{"doc_id" => doc_id, "name" => name, "meta" => m}

  defp item(overrides \\ %{}) do
    Map.merge(%{"collection" => "answers", "source" => "s", "doc_id" => "d1", "name" => "file.json"}, overrides)
  end

  defp default_meta(_req), do: {:ok, %{"results" => [result_row("d1", "file.json", meta("re-1"))]}}

  defp stub(opts) do
    allowed = Keyword.get(opts, :allowed, [1, 2])
    fetch = Keyword.get(opts, :fetch, fn _f, _u, _o -> {:ok, [learner_group("re-1", "https://example.com/a")]} end)
    meta_fun = Keyword.get(opts, :meta, &default_meta/1)

    {:ok, ld} = LearnerDataStub.start(%{get_allowed_project_ids: fn _ -> allowed end, fetch: fetch})
    {:ok, rs} = ReportServiceStub.start(%{fetch_attachment_meta: meta_fun})

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
    {:ok, run} = Reports.create_report_run(Map.merge(%{user_id: user.id, report_slug: "student-answers"}, attrs))
    run
  end

  defp post_attachments(conn, run_id, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/v1/reports/#{run_id}/attachments", Jason.encode!(body))
  end

  # ---- happy path + authorization ----

  test "signs a url for an authorized learner", %{conn: conn, user: user} do
    stub([])
    run = run_fixture(user)

    body = json_response(post_attachments(conn, run.id, %{attachments: [item()]}), 200)
    assert [%{"doc_id" => "d1", "name" => "file.json", "url" => url}] = body["results"]
    assert body["expires_in_seconds"] == 600
    assert String.contains?(url, "interactive-attachments/f/u/file.json")
  end

  test "not_authorized for a remote_endpoint outside the set and for a nil remote_endpoint", %{conn: conn, user: user} do
    stub(
      meta: fn _r ->
        {:ok, %{"results" => [result_row("d1", "file.json", meta("re-999")), result_row("d2", "a.mp3", meta(nil))]}}
      end
    )

    run = run_fixture(user)
    body = json_response(post_attachments(conn, run.id, %{attachments: [item(), item(%{"doc_id" => "d2", "name" => "a.mp3"})]}), 200)

    assert Enum.all?(body["results"], &(&1["error"] == "not_authorized"))
  end

  test "not_found for a null meta (missing doc or missing name)", %{conn: conn, user: user} do
    stub(meta: fn _r -> {:ok, %{"results" => [result_row("d1", "file.json", nil)]}} end)
    run = run_fixture(user)
    body = json_response(post_attachments(conn, run.id, %{attachments: [item()]}), 200)
    assert [%{"error" => "not_found"}] = body["results"]
  end

  test "partial success: one authorized + one not_found in the same batch", %{conn: conn, user: user} do
    stub(
      meta: fn _r ->
        {:ok, %{"results" => [result_row("d1", "file.json", meta("re-1")), result_row("d2", "x.json", nil)]}}
      end
    )

    run = run_fixture(user)
    body = json_response(post_attachments(conn, run.id, %{attachments: [item(), item(%{"doc_id" => "d2", "name" => "x.json"})]}), 200)

    assert [%{"url" => _}, %{"error" => "not_found"}] = body["results"]
  end

  test "a three-way mixed batch coexists and the audit records only the one authorized learner", %{conn: conn, user: user} do
    stub(
      meta: fn _r ->
        {:ok,
         %{
           "results" => [
             result_row("d1", "a", meta("re-1")),
             result_row("d2", "b", meta("re-999")),
             result_row("d3", "c", nil)
           ]
         }}
      end
    )

    run = run_fixture(user)

    body =
      json_response(
        post_attachments(conn, run.id, %{
          attachments: [item(%{"doc_id" => "d1", "name" => "a"}), item(%{"doc_id" => "d2", "name" => "b"}), item(%{"doc_id" => "d3", "name" => "c"})]
        }),
        200
      )

    assert [%{"url" => _}, %{"error" => "not_authorized"}, %{"error" => "not_found"}] = body["results"]
    assert Repo.one!(DataAccessLogEntry).endpoint_set == ["re-1"]
  end

  # ---- disposition ----

  test "the default disposition presigns a Content-Disposition attachment with a filename", %{conn: conn, user: user} do
    stub([])
    run = run_fixture(user)
    body = json_response(post_attachments(conn, run.id, %{attachments: [item()]}), 200)
    q = body["results"] |> hd() |> Map.fetch!("url") |> URI.parse() |> Map.get(:query) |> URI.decode_query()
    assert q["response-content-disposition"] =~ ~s(attachment; filename="file.json")
  end

  test "disposition inline presigns inline + response-content-type from the meta contentType", %{conn: conn, user: user} do
    stub(meta: fn _r -> {:ok, %{"results" => [result_row("d1", "audio.mp3", meta("re-1", ct: "audio/mpeg"))]}} end)
    run = run_fixture(user)

    body = json_response(post_attachments(conn, run.id, %{attachments: [item(%{"name" => "audio.mp3"})], disposition: "inline"}), 200)
    q = body["results"] |> hd() |> Map.fetch!("url") |> URI.parse() |> Map.get(:query) |> URI.decode_query()
    assert q["response-content-disposition"] == "inline"
    assert q["response-content-type"] == "audio/mpeg"
  end

  test "inline with a nil contentType falls back to application/octet-stream", %{conn: conn, user: user} do
    stub(meta: fn _r -> {:ok, %{"results" => [result_row("d1", "f", meta("re-1", ct: nil))]}} end)
    run = run_fixture(user)
    body = json_response(post_attachments(conn, run.id, %{attachments: [item(%{"name" => "f"})], disposition: "inline"}), 200)
    q = body["results"] |> hd() |> Map.fetch!("url") |> URI.parse() |> Map.get(:query) |> URI.decode_query()
    assert q["response-content-type"] == "application/octet-stream"
  end

  test "a name with a quote/CR-LF/control char is sanitized in the Content-Disposition", %{conn: conn, user: user} do
    stub(meta: fn _r -> {:ok, %{"results" => [result_row("d1", "a\"b\r\nc", meta("re-1"))]}} end)
    run = run_fixture(user)
    body = json_response(post_attachments(conn, run.id, %{attachments: [item(%{"name" => "a\"b\r\nc"})]}), 200)
    q = body["results"] |> hd() |> Map.fetch!("url") |> URI.parse() |> Map.get(:query) |> URI.decode_query()
    assert q["response-content-disposition"] == ~s(attachment; filename="abc")
  end

  # ---- server creds + no-store ----

  test "presigns with the server credentials (not workgroup) and sets no-store", %{conn: conn, user: user} do
    stub([])
    run = run_fixture(user)
    conn = post_attachments(conn, run.id, %{attachments: [item()]})
    body = json_response(conn, 200)

    server_key = Application.get_env(:report_server, :aws_credentials) |> Keyword.get(:access_key_id)
    url = body["results"] |> hd() |> Map.fetch!("url")
    assert String.contains?(url, server_key)
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  # ---- history path + wire capture ----

  test "the history collection is forwarded to Node and signs", %{conn: conn, user: user} do
    test_pid = self()

    stub(meta: fn req -> send(test_pid, {:meta_req, req}); {:ok, %{"results" => [result_row("d1", "file.json", meta("re-1"))]}} end)
    run = run_fixture(user)

    body = json_response(post_attachments(conn, run.id, %{attachments: [item(%{"collection" => "history"})]}), 200)
    assert [%{"url" => _}] = body["results"]
    assert_received {:meta_req, %{items: [%{"collection" => "history"}]}}
  end

  # ---- validation errors ----

  test "not-owned run -> 404", %{conn: conn} do
    stub([])
    other = user_fixture()
    run = run_fixture(other)
    assert json_response(post_attachments(conn, run.id, %{attachments: [item()]}), 404)
  end

  test "bad disposition -> 400", %{conn: conn, user: user} do
    stub([])
    run = run_fixture(user)
    assert json_response(post_attachments(conn, run.id, %{attachments: [item()], disposition: "nope"}), 400)
  end

  test "non-string disposition -> 400 (not 500)", %{conn: conn, user: user} do
    stub([])
    run = run_fixture(user)
    assert json_response(post_attachments(conn, run.id, %{attachments: [item()], disposition: 5}), 400)
    assert json_response(post_attachments(conn, run.id, %{attachments: [item()], disposition: ["inline"]}), 400)
  end

  test "attachments not an array / omitted / missing key / empty coordinate / slash -> 400", %{conn: conn, user: user} do
    stub([])
    run = run_fixture(user)

    assert json_response(post_attachments(conn, run.id, %{}), 400)
    assert json_response(post_attachments(conn, run.id, %{attachments: "x"}), 400)
    assert json_response(post_attachments(conn, run.id, %{attachments: []}), 400)
    assert json_response(post_attachments(conn, run.id, %{attachments: [Map.delete(item(), "name")]}), 400)
    assert json_response(post_attachments(conn, run.id, %{attachments: [item(%{"source" => ""})]}), 400)
    assert json_response(post_attachments(conn, run.id, %{attachments: [item(%{"source" => "a/b"})]}), 400)
    assert json_response(post_attachments(conn, run.id, %{attachments: [item(%{"doc_id" => "a/b"})]}), 400)
    assert json_response(post_attachments(conn, run.id, %{attachments: [item(%{"collection" => "nope"})]}), 400)
  end

  test "exactly 500 attachments -> 200 and 501 -> 400", %{conn: conn, user: user} do
    echo = fn %{items: items} ->
      {:ok, %{"results" => Enum.map(items, &result_row(&1["doc_id"], &1["name"], meta("re-none")))}}
    end

    stub(meta: echo)
    run = run_fixture(user)

    items_500 = for i <- 1..500, do: item(%{"doc_id" => "d#{i}"})
    assert json_response(post_attachments(conn, run.id, %{attachments: items_500}), 200)

    items_501 = for i <- 1..501, do: item(%{"doc_id" => "d#{i}"})
    assert json_response(post_attachments(conn, run.id, %{attachments: items_501}), 400)
  end

  test "a Node meta-count mismatch -> 500 (never a silently truncated results)", %{conn: conn, user: user} do
    stub(meta: fn _r -> {:ok, %{"results" => []}} end)
    run = run_fixture(user)
    assert json_response(post_attachments(conn, run.id, %{attachments: [item()]}), 500)
  end

  test "a Node/derivation error -> 500, not 400", %{conn: conn, user: user} do
    stub(meta: fn _r -> {:error, "node exploded"} end)
    run = run_fixture(user)
    assert json_response(post_attachments(conn, run.id, %{attachments: [item()]}), 500)
  end

  test "duplicate identical items both sign and the audit lists the learner once", %{conn: conn, user: user} do
    stub(
      meta: fn _r ->
        {:ok, %{"results" => [result_row("d1", "file.json", meta("re-1")), result_row("d1", "file.json", meta("re-1"))]}}
      end
    )

    run = run_fixture(user)
    body = json_response(post_attachments(conn, run.id, %{attachments: [item(), item()]}), 200)
    assert [%{"url" => _}, %{"url" => _}] = body["results"]
    assert Repo.one!(DataAccessLogEntry).endpoint_set == ["re-1"]
  end

  test "writes exactly one attachment_urls_issued audit row", %{conn: conn, user: user} do
    stub([])
    run = run_fixture(user)
    post_attachments(conn, run.id, %{attachments: [item()]})

    row = Repo.one!(DataAccessLogEntry)
    assert row.event == "attachment_urls_issued"
    assert row.data_type == "attachment"
    assert row.export_id == nil
  end
end
