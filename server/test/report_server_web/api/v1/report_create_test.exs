defmodule ReportServerWeb.Api.V1.ReportCreateTest do
  use ReportServerWeb.ConnCase

  @moduletag :portal_db

  import ReportServer.AccountsFixtures

  alias ReportServer.{PortalFixture, Repo}
  alias ReportServer.Reports.ReportRun

  @server PortalFixture.server()

  setup do
    test = self()
    Application.put_env(:report_server, :athena_run_starter, fn run -> send(test, {:started, run.id}) end)
    on_exit(fn -> Application.delete_env(:report_server, :athena_run_starter) end)
    :ok
  end

  defp admin_token do
    user = user_fixture(%{portal_server: @server, portal_is_admin: true})
    {raw_token, _} = api_token_fixture(user)
    {user, raw_token}
  end

  defp researcher_token do
    user =
      user_fixture(%{portal_server: @server, portal_user_id: 557, portal_is_project_researcher: true})

    {raw_token, _} = api_token_fixture(user)
    {user, raw_token}
  end

  defp authed_conn(conn, raw_token), do: put_req_header(conn, "authorization", "Bearer #{raw_token}")

  defp post_create(conn, raw_token, body) do
    conn |> authed_conn(raw_token) |> post(~p"/api/v1/reports", body)
  end

  defp run_count, do: Repo.aggregate(ReportRun, :count)

  test "an Athena create answers 201 with the run JSON and no query state yet", %{conn: conn} do
    {user, token} = admin_token()

    body =
      post_create(conn, token, %{
        "report_slug" => "student-answers",
        "report_filter" => %{"cohort" => [1]}
      })
      |> json_response(201)

    assert body["report_slug"] == "student-answers"
    assert body["report_type"] == "answers"
    assert body["execution"] == "async"
    assert body["athena_query_state"] == nil
    assert body["report_filter"]["cohort"] == [1]
    assert body["report_filter"]["filters"] == ["cohort"]
    assert body["report_filter_values"] == %{"cohort" => %{"1" => "Cohort One"}}

    run_id = body["id"]
    assert_receive {:started, ^run_id}
    assert Repo.get!(ReportRun, run_id).user_id == user.id
  end

  test "a Portal create answers 201", %{conn: conn} do
    {_user, token} = admin_token()

    body =
      post_create(conn, token, %{
        "report_slug" => "school-metrics",
        "report_filter" => %{"country" => [1]}
      })
      |> json_response(201)

    assert body["execution"] == "sync"
    assert body["report_filter_values"] == %{"country" => %{"1" => "United States"}}
  end

  test "the created run is listed for its owner and not for anyone else", %{conn: conn} do
    {_user, token} = admin_token()
    {_other, other_token} = admin_token()

    id =
      post_create(conn, token, %{"report_slug" => "student-answers", "report_filter" => %{"cohort" => [1]}})
      |> json_response(201)
      |> Map.fetch!("id")

    mine = build_conn() |> authed_conn(token) |> get(~p"/api/v1/reports") |> json_response(200)
    assert Enum.map(mine["items"], & &1["id"]) == [id]

    theirs = build_conn() |> authed_conn(other_token) |> get(~p"/api/v1/reports") |> json_response(200)
    assert theirs["items"] == []
  end

  test "an id outside the caller's projects is a bad request naming the dimension and the id", %{conn: conn} do
    {_user, token} = researcher_token()
    before = run_count()

    body =
      post_create(conn, token, %{"report_slug" => "student-answers", "report_filter" => %{"cohort" => [2]}})
      |> json_response(400)

    assert body["error"] == "BAD_REQUEST"
    assert body["message"] =~ "cohort: 2"
    assert run_count() == before
  end

  test "hide_names comes back on for a caller who may not see names", %{conn: conn} do
    {_user, token} = researcher_token()

    body =
      post_create(conn, token, %{
        "report_slug" => "student-answers",
        "report_filter" => %{"cohort" => [1], "hide_names" => false}
      })
      |> json_response(201)

    assert body["report_filter"]["hide_names"] == true
  end

  test "an unknown slug and a report group slug are both not found", %{conn: conn} do
    {_user, token} = admin_token()

    unknown = post_create(conn, token, %{"report_slug" => "no-such"}) |> json_response(404)
    group = build_conn() |> post_create(token, %{"report_slug" => "student-reports"}) |> json_response(404)

    assert unknown == group
    assert unknown["error"] == "NOT_FOUND"
  end

  test "a missing report_slug is a bad request", %{conn: conn} do
    {_user, token} = admin_token()

    body = post_create(conn, token, %{"report_filter" => %{"cohort" => [1]}}) |> json_response(400)

    assert body["message"] =~ "report_slug is required"
  end

  test "a malformed report_filter is a bad request carrying the parser's message", %{conn: conn} do
    {_user, token} = admin_token()

    body =
      post_create(conn, token, %{"report_slug" => "student-answers", "report_filter" => %{"cohort" => ["abc"]}})
      |> json_response(400)

    assert body["message"] =~ "cohort values must be integer ids"
  end

  test "an unauthenticated create is refused", %{conn: conn} do
    body = post(conn, ~p"/api/v1/reports", %{"report_slug" => "student-answers"}) |> json_response(401)

    assert body["error"] == "NOT_AUTHENTICATED"
    assert run_count() == 0
  end
end
