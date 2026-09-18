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

  defp researcher_claims(overrides \\ %{}) do
    Map.merge(
      %{
        "aud" => "report-server",
        "exp" => System.system_time(:second) + 120,
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

  defp sign(claims, secret \\ @secret) do
    {:ok, token} = Joken.Signer.sign(claims, Joken.Signer.create("HS256", secret))
    token
  end

  defp as_portal(conn, overrides \\ %{}) do
    put_req_header(conn, "authorization", "Bearer #{sign(researcher_claims(overrides))}")
  end

  describe "authentication" do
    test "refuses a request with no credential", %{conn: conn} do
      assert json_response(post(conn, ~p"/api/v1/dashboard-tokens", %{}), 401)
    end

    # The secret verifies assertions rather than being one, so presenting it proves
    # nothing. That is what lets a relay carry an assertion without being able to mint
    # one; a holder of the secret itself can still sign whatever it likes.
    test "refuses the bare shared secret", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{@secret}")
        |> post(~p"/api/v1/dashboard-tokens", researcher_claims())

      assert json_response(conn, 401)
    end

    test "refuses an assertion signed with another key", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{sign(researcher_claims(), "not-the-secret")}")
        |> post(~p"/api/v1/dashboard-tokens", %{})

      assert json_response(conn, 401)
    end

    # Without this an assertion minted for some other service sharing this secret would be
    # spendable here.
    test "refuses an assertion addressed elsewhere", %{conn: conn} do
      conn = conn |> as_portal(%{"aud" => "somewhere-else"}) |> post(~p"/api/v1/dashboard-tokens", %{})
      assert json_response(conn, 401)
    end

    test "refuses an expired assertion", %{conn: conn} do
      conn =
        conn
        |> as_portal(%{"exp" => System.system_time(:second) - 1})
        |> post(~p"/api/v1/dashboard-tokens", %{})

      assert json_response(conn, 401)
    end

    # Refused rather than treated as unlimited, so a claim that never dies cannot be
    # accepted by omission.
    test "refuses an assertion with no expiry", %{conn: conn} do
      claims = researcher_claims() |> Map.delete("exp")

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{sign(claims)}")
        |> post(~p"/api/v1/dashboard-tokens", %{})

      assert json_response(conn, 401)
    end

    # Without this the endpoint would be open in any environment that forgot to set it.
    test "refuses everything when no secret is configured", %{conn: conn} do
      Application.put_env(:report_server, :portal_service_secret, nil)

      conn = conn |> as_portal() |> post(~p"/api/v1/dashboard-tokens", %{})
      assert json_response(conn, 401)
    end
  end

  describe "minting" do
    test "creates the user it has never seen and returns a usable token", %{conn: conn} do
      conn = conn |> as_portal() |> post(~p"/api/v1/dashboard-tokens", %{})
      body = json_response(conn, 201)

      assert body["label"] == Accounts.dashboard_token_label()
      assert body["portal_user_id"] == 200
      # The point of the credential: it authenticates as that researcher.
      assert {:ok, user, _api_token} = Accounts.verify_api_token(body["token"])
      assert user.portal_user_id == 200
      assert user.portal_login == "dougresearcher"
    end

    # The whole reason the user information is signed. get_allowed_project_ids returns
    # every project for a site admin, so a relay able to raise these flags in the body
    # could mint a token reaching every class at Concord.
    test "takes the role flags from the assertion and ignores the request body", %{conn: conn} do
      conn =
        conn
        |> as_portal(%{"is_admin" => false})
        |> post(~p"/api/v1/dashboard-tokens", %{"is_admin" => true, "portal_user_id" => 999})

      body = json_response(conn, 201)
      assert body["portal_user_id"] == 200
      assert {:ok, user, _token} = Accounts.verify_api_token(body["token"])
      refute user.portal_is_admin
      assert user.portal_user_id == 200
    end

    test "revokes the researcher's previous dashboard token", %{conn: conn} do
      first = conn |> as_portal() |> post(~p"/api/v1/dashboard-tokens", %{})
      first_token = json_response(first, 201)["token"]

      second = build_conn() |> as_portal() |> post(~p"/api/v1/dashboard-tokens", %{})
      second_token = json_response(second, 201)["token"]

      refute first_token == second_token
      # A copy that leaked from an earlier VM stops working at the next launch.
      assert :error = Accounts.verify_api_token(first_token)
      assert {:ok, _user, _token} = Accounts.verify_api_token(second_token)
    end

    test "leaves another researcher's token alone", %{conn: conn} do
      mine = conn |> as_portal() |> post(~p"/api/v1/dashboard-tokens", %{})
      my_token = json_response(mine, 201)["token"]

      build_conn()
      |> as_portal(%{"portal_user_id" => 136})
      |> post(~p"/api/v1/dashboard-tokens", %{})

      assert {:ok, _user, _token} = Accounts.verify_api_token(my_token)
    end

    test "requires a portal user in the assertion", %{conn: conn} do
      claims = researcher_claims() |> Map.delete("portal_user_id")

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{sign(claims)}")
        |> post(~p"/api/v1/dashboard-tokens", %{})

      assert json_response(conn, 400)["error"] =~ "portal_user_id"
    end
  end

  describe "revoking" do
    test "revokes every live dashboard token for the researcher", %{conn: conn} do
      minted = conn |> as_portal() |> post(~p"/api/v1/dashboard-tokens", %{})
      token = json_response(minted, 201)["token"]

      revoked = build_conn() |> as_portal() |> delete(~p"/api/v1/dashboard-tokens", %{})
      assert json_response(revoked, 200)["revoked"] == 1

      # This is what makes the credential die with the VM rather than at the next launch.
      assert :error = Accounts.verify_api_token(token)
    end

    test "is harmless when there is nothing to revoke", %{conn: conn} do
      conn = conn |> as_portal() |> delete(~p"/api/v1/dashboard-tokens", %{})
      assert json_response(conn, 200)["revoked"] == 0
    end
  end
end
