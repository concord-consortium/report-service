defmodule ReportServerWeb.Api.V1.ReportDuplicateTest do
  use ReportServerWeb.ConnCase

  @moduletag :portal_db

  import ReportServer.AccountsFixtures

  alias ReportServer.{PortalFixture, Reports}
  alias ReportServer.Reports.ReportFilter

  @server PortalFixture.server()

  setup do
    test = self()
    Application.put_env(:report_server, :athena_run_starter, fn run -> send(test, {:started, run.id}) end)
    on_exit(fn -> Application.delete_env(:report_server, :athena_run_starter) end)
    :ok
  end

  defp admin do
    user = user_fixture(%{portal_server: @server, portal_is_admin: true})
    {raw_token, _} = api_token_fixture(user)
    {user, raw_token}
  end

  defp authed_conn(conn, raw_token), do: put_req_header(conn, "authorization", "Bearer #{raw_token}")

  defp run_fixture(user, slug, filter \\ %ReportFilter{cohort: [1]}, attrs \\ %{}) do
    {:ok, run} =
      Reports.create_report_run(
        Map.merge(
          %{user_id: user.id, report_slug: slug, report_filter: filter, report_filter_values: %{}},
          attrs
        )
      )

    run
  end

  defp duplicate(conn, token, id, body \\ %{}) do
    conn |> authed_conn(token) |> post(~p"/api/v1/reports/#{id}/duplicate", body)
  end

  describe "an Athena run" do
    test "duplicates freely, into a new run with no query of its own yet", %{conn: conn} do
      {user, token} = admin()

      source =
        run_fixture(user, "student-answers", %ReportFilter{cohort: [1]}, %{
          athena_query_id: "query-abc",
          athena_query_state: "succeeded",
          athena_result_url: "s3://bucket/result.csv"
        })

      body = duplicate(conn, token, source.id) |> json_response(201)

      assert body["id"] != source.id
      assert body["report_slug"] == "student-answers"
      assert body["report_filter"]["cohort"] == [1]
      assert body["athena_query_id"] == nil
      assert body["athena_query_state"] == nil

      run_id = body["id"]
      assert_receive {:started, ^run_id}
    end

    test "re-derives the labels the source never carried", %{conn: conn} do
      {user, token} = admin()
      source = run_fixture(user, "student-answers")

      body = duplicate(conn, token, source.id) |> json_response(201)

      assert body["report_filter_values"] == %{"cohort" => %{"1" => "Cohort One"}}
    end
  end

  describe "the Portal guard" do
    test "refuses without force, naming the run to re-read", %{conn: conn} do
      {user, token} = admin()
      source = run_fixture(user, "school-metrics", %ReportFilter{country: [1]})

      body = duplicate(conn, token, source.id) |> json_response(409)

      assert body["error"] == "PORTAL_DUPLICATE_UNNECESSARY"
      assert body["message"] =~ "Run #{source.id} is a Portal report"
      assert body["message"] =~ "Re-read run #{source.id}"
      assert body["run_id"] == source.id
    end

    test "the refusal body carries exactly error, message and run_id", %{conn: conn} do
      {user, token} = admin()
      source = run_fixture(user, "school-metrics", %ReportFilter{country: [1]})

      body = duplicate(conn, token, source.id) |> json_response(409)

      assert Enum.sort(Map.keys(body)) == ["error", "message", "run_id"]
    end

    test "force: true duplicates", %{conn: conn} do
      {user, token} = admin()
      source = run_fixture(user, "school-metrics", %ReportFilter{country: [1]})

      body = duplicate(conn, token, source.id, %{"force" => true}) |> json_response(201)

      assert body["id"] != source.id
      assert body["report_filter"]["country"] == [1]
    end

    test "force as a string is not force", %{conn: conn} do
      {user, token} = admin()
      source = run_fixture(user, "school-metrics", %ReportFilter{country: [1]})

      body = duplicate(conn, token, source.id, %{"force" => "true"}) |> json_response(409)

      assert body["error"] == "PORTAL_DUPLICATE_UNNECESSARY"
    end
  end

  describe "runs the caller cannot duplicate" do
    test "another user's run is not found", %{conn: conn} do
      {_user, token} = admin()
      {other, _other_token} = admin()
      source = run_fixture(other, "student-answers")

      assert duplicate(conn, token, source.id) |> json_response(404)
    end

    test "a non-integer id is not found", %{conn: conn} do
      {_user, token} = admin()

      assert duplicate(conn, token, "abc") |> json_response(404)
    end

    test "an unauthenticated duplicate is refused", %{conn: conn} do
      {user, _token} = admin()
      source = run_fixture(user, "student-answers")

      assert post(conn, ~p"/api/v1/reports/#{source.id}/duplicate", %{}) |> json_response(401)
    end
  end

  test "a stored filter the report no longer accepts is a bad request", %{conn: conn} do
    {user, token} = admin()
    source = run_fixture(user, "student-answers", %ReportFilter{cohort: [1], start_date: "nope"})

    body = duplicate(conn, token, source.id) |> json_response(400)

    assert body["message"] =~ "ISO 8601"
  end
end
