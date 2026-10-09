defmodule ReportServerWeb.Api.V1.PackageControllerAppliesTest do
  use ReportServerWeb.ConnCase, async: false

  alias ReportServer.{Accounts, ReportServiceStub}
  alias ReportServer.PortalDbs.PortalUserInfo

  @limits (Path.expand("../../../../../fixtures/package-contract.json", __DIR__) |> File.read!() |> Jason.decode!())["limits"]

  setup :register_and_put_bearer_token

  setup do
    on_exit(fn -> Application.delete_env(:report_server, :report_service_client) end)
  end

  defp stub_derive(fun) do
    if pid = Process.whereis(ReportServiceStub), do: Agent.stop(pid)
    {:ok, _} = ReportServiceStub.start(%{derive_urls: fun})
    Application.put_env(:report_server, :report_service_client, ReportServiceStub)
  end

  # a fresh conn with the same bearer, since a conn is spent once it has been sent
  defp again(conn), do: build_conn() |> put_req_header("authorization", hd(get_req_header(conn, "authorization")))

  defp applies(conn, body), do: post(conn, "/api/v1/packages/applies", body)

  test "matches scope URLs as given, with null groups empty, and derives nothing", %{conn: conn} do
    stub_derive(fn _ -> flunk("derived") end)
    body = %{"urls" => %{"all" => nil, "any" => ["*open-response*"], "none" => nil}, "scope_urls" => ["https://a/open-response/"]}

    assert json_response(applies(conn, body), 200) ==
             %{"applies" => true, "reason" => nil, "interactive_urls" => [], "unread" => [], "truncated" => false}
  end

  test "derives assignment URLs and matches them with their interactives", %{conn: conn} do
    stub_derive(fn ["https://ap/?activity=x"] ->
      {:ok, %{"interactive_urls" => ["https://qi/open-response/"], "unread" => [%{"url" => "u", "reason" => "HTTP 500"}], "truncated" => true}}
    end)

    assert %{
             "applies" => true,
             "interactive_urls" => ["https://qi/open-response/"],
             "unread" => [%{"url" => "u", "reason" => "HTTP 500"}],
             "truncated" => true
           } = json_response(applies(conn, %{"urls" => %{"all" => ["*open-response*"]}, "assignment_urls" => ["https://ap/?activity=x"]}), 200)

    assert %{"applies" => true} =
             json_response(applies(again(conn), %{"urls" => %{"all" => ["*ap/?activity=*"]}, "assignment_urls" => ["https://ap/?activity=x"]}), 200)

    assert %{"applies" => false, "reason" => "no URL in this class matches any of *drawing*"} =
             json_response(applies(again(conn), %{"urls" => %{"any" => ["*drawing*"]}, "assignment_urls" => ["https://ap/?activity=x"]}), 200)
  end

  test "matches scope URLs and derived interactive URLs together", %{conn: conn} do
    stub_derive(fn ["https://ap/?activity=x"] -> {:ok, %{"interactive_urls" => ["https://qi/drawing/"], "unread" => [], "truncated" => false}} end)

    body = %{
      "urls" => %{"all" => ["*drawing*", "*open-response*"]},
      "assignment_urls" => ["https://ap/?activity=x"],
      "scope_urls" => ["https://qi/open-response/"]
    }

    assert %{"applies" => true, "interactive_urls" => ["https://qi/drawing/"]} = json_response(applies(conn, body), 200)

    assert %{"applies" => false, "reason" => "no URL in this class matches the required pattern *open-response*"} =
             json_response(applies(again(conn), Map.delete(body, "scope_urls")), 200)
  end

  test "a deriver refusal is a 400 and any other failure a 503, never a 404", %{conn: conn} do
    body = %{"urls" => %{}, "assignment_urls" => ["x"]}

    stub_derive(fn _ -> {:error, {:bad_request, "assignment_urls must be an array of at most 500 strings"}} end)
    assert %{"error" => "BAD_REQUEST", "message" => "assignment_urls must be" <> _} = json_response(applies(conn, body), 400)

    stub_derive(fn _ -> {:error, :unavailable} end)
    assert %{"error" => "SERVICE_UNAVAILABLE"} = json_response(applies(again(conn), body), 503)
  end

  test "refuses a body it cannot read as patterns and a scope", %{conn: conn} do
    combining = "a" <> String.duplicate("́", 3_900)

    for body <- [
          %{"url" => %{"all" => ["*never*"]}, "scope_urls" => ["https://x/"]},
          %{"urls" => nil},
          %{"urls" => %{"anyy" => []}},
          %{"urls" => %{"any" => List.duplicate("*x*", 21)}},
          %{"urls" => %{}, "scope_urls" => List.duplicate("x", 1_001)},
          %{"urls" => %{}, "scope_urls" => [String.duplicate("x", 2_049)]},
          %{"urls" => %{}, "scope_urls" => [combining]},
          %{"urls" => %{}, "scope_urls" => "x"}
        ] do
      assert %{"error" => "BAD_REQUEST"} = json_response(applies(again(conn), body), 400), inspect(body, limit: 3)
    end

    text = again(conn) |> put_req_header("content-type", "text/plain") |> post("/api/v1/packages/applies", ~s({"urls":{"all":["*never*"]}}))
    assert %{"error" => "BAD_REQUEST"} = json_response(text, 400)

    query = again(conn) |> put_req_header("content-type", "text/plain") |> post("/api/v1/packages/applies?urls[any][]=*x*", "unread")
    assert %{"error" => "BAD_REQUEST"} = json_response(query, 400)
  end

  test "bounds a scope URL in code points, at the contract's limit", %{conn: conn} do
    max = @limits["max_url_length"]
    status = fn url -> applies(again(conn), %{"urls" => %{}, "scope_urls" => [url]}).status end

    assert status.(String.duplicate("a", max)) == 200
    assert status.(String.duplicate("a", max + 1)) == 400
    assert status.(String.duplicate("😀", max)) == 200
  end

  test "needs a token, and takes the runner's dashboard token" do
    assert %{"error" => "NOT_AUTHENTICATED"} = json_response(applies(build_conn(), %{"urls" => %{}}), 401)

    info = %PortalUserInfo{
      id: 777,
      server: "learn.concord.org",
      login: "r",
      first_name: "R",
      last_name: "S",
      email: "r@example.org",
      is_admin: false,
      is_project_admin: false,
      is_project_researcher: true
    }

    {:ok, {_user, raw, _}} = Accounts.mint_dashboard_token(info)
    conn = build_conn() |> put_req_header("authorization", "Bearer " <> raw)
    assert %{"applies" => true} = json_response(applies(conn, %{"urls" => %{}, "scope_urls" => []}), 200)
  end
end
