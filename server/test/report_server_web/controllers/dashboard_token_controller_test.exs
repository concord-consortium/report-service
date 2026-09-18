defmodule ReportServerWeb.Api.V1.DashboardTokenControllerTest do
  use ReportServerWeb.ConnCase, async: true

  alias ReportServer.Accounts

  @secret "test-portal-service-secret"
  @portal_server "learn.portal.staging.concord.org"

  setup do
    previous = Application.get_env(:report_server, :portal_service_secret)
    Application.put_env(:report_server, :portal_service_secret, @secret)
    on_exit(fn -> Application.put_env(:report_server, :portal_service_secret, previous) end)
    :ok
  end

  defp as_portal(conn), do: put_req_header(conn, "authorization", "Bearer #{@secret}")

  defp researcher_params(overrides \\ %{}) do
    Map.merge(
      %{
        "portal_user_id" => 200,
        "portal_server" => @portal_server,
        "login" => "dougresearcher",
        "first_name" => "Doug",
        "last_name" => "Researcher",
        "email" => "dougresearcher@example.com",
        "is_project_researcher" => true
      },
      overrides
    )
  end

  describe "authentication" do
    test "refuses a request with no credential", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/dashboard-tokens", researcher_params())
      assert json_response(conn, 401)
    end

    test "refuses a wrong secret", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer not-the-secret")
        |> post(~p"/api/v1/dashboard-tokens", researcher_params())

      assert json_response(conn, 401)
    end

    # Without this the endpoint would be open in any environment that forgot to set it,
    # which is the one failure mode a shared secret has.
    test "refuses everything when no secret is configured", %{conn: conn} do
      Application.put_env(:report_server, :portal_service_secret, nil)

      conn = conn |> as_portal() |> post(~p"/api/v1/dashboard-tokens", researcher_params())
      assert json_response(conn, 401)
    end
  end

  describe "minting" do
    test "creates the user it has never seen and returns a usable token", %{conn: conn} do
      conn = conn |> as_portal() |> post(~p"/api/v1/dashboard-tokens", researcher_params())
      body = json_response(conn, 201)

      assert body["label"] == Accounts.dashboard_token_label()
      assert body["portal_user_id"] == 200
      # The point of the credential: it authenticates as that researcher.
      assert {:ok, user, _api_token} = Accounts.verify_api_token(body["token"])
      assert user.portal_user_id == 200
      assert user.portal_login == "dougresearcher"
    end

    test "revokes the researcher's previous dashboard token", %{conn: conn} do
      first = conn |> as_portal() |> post(~p"/api/v1/dashboard-tokens", researcher_params())
      first_token = json_response(first, 201)["token"]

      second = build_conn() |> as_portal() |> post(~p"/api/v1/dashboard-tokens", researcher_params())
      second_token = json_response(second, 201)["token"]

      refute first_token == second_token
      # A copy that leaked from an earlier VM stops working at the next launch.
      assert :error = Accounts.verify_api_token(first_token)
      assert {:ok, _user, _token} = Accounts.verify_api_token(second_token)
    end

    test "leaves another researcher's token alone", %{conn: conn} do
      mine = conn |> as_portal() |> post(~p"/api/v1/dashboard-tokens", researcher_params())
      my_token = json_response(mine, 201)["token"]

      build_conn()
      |> as_portal()
      |> post(~p"/api/v1/dashboard-tokens", researcher_params(%{"portal_user_id" => 136}))

      assert {:ok, _user, _token} = Accounts.verify_api_token(my_token)
    end

    test "requires a portal user and server", %{conn: conn} do
      conn = conn |> as_portal() |> post(~p"/api/v1/dashboard-tokens", %{"portal_server" => @portal_server})
      assert json_response(conn, 400)["error"] =~ "portal_user_id"
    end
  end

  describe "revoking" do
    test "revokes every live dashboard token for the researcher", %{conn: conn} do
      minted = conn |> as_portal() |> post(~p"/api/v1/dashboard-tokens", researcher_params())
      token = json_response(minted, 201)["token"]

      revoked = build_conn() |> as_portal() |> delete(~p"/api/v1/dashboard-tokens", researcher_params())
      assert json_response(revoked, 200)["revoked"] == 1

      # This is what makes the credential die with the VM rather than at the next launch.
      assert :error = Accounts.verify_api_token(token)
    end

    test "is harmless when there is nothing to revoke", %{conn: conn} do
      conn = conn |> as_portal() |> delete(~p"/api/v1/dashboard-tokens", researcher_params())
      assert json_response(conn, 200)["revoked"] == 0
    end
  end
end
