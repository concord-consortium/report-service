defmodule ReportServerWeb.AuthCliControllerTest do
  use ReportServerWeb.ConnCase

  import ReportServer.AccountsFixtures

  alias ReportServer.Accounts
  alias ReportServer.Accounts.AuthGrant
  alias ReportServer.PortalDbs
  alias ReportServer.Repo

  @bad_request %{"error" => "BAD_REQUEST", "message" => "Invalid code or verifier."}
  @default_portal "https://learn.portal.staging.concord.org"

  defp pkce_pair() do
    verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
    {verifier, challenge}
  end

  defp valid_challenge() do
    {_verifier, challenge} = pkce_pair()
    challenge
  end

  defp grant_count(), do: Repo.aggregate(AuthGrant, :count)

  defp cli_query(overrides \\ %{}) do
    %{
      "redirect_uri" => "http://127.0.0.1:12345/callback",
      "state" => "abc123",
      "code_challenge" => valid_challenge(),
      "code_challenge_method" => "S256"
    }
    |> Map.merge(overrides)
    |> Enum.reject(fn {_k, v} -> v == :omit end)
    |> URI.encode_query()
  end

  defp matching_user(attrs \\ %{}) do
    server = PortalDbs.get_server_for_portal_url(@default_portal)
    user_fixture(Map.merge(%{portal_server: server}, attrs))
  end

  defp put_portal_db(server) do
    key = "#{server}_DB" |> String.replace(".", "_") |> String.replace("-", "_") |> String.upcase()
    System.put_env(key, "fake-connection-string")
    on_exit(fn -> System.delete_env(key) end)
  end

  defp grant_fixture() do
    user = user_fixture()
    {verifier, challenge} = pkce_pair()
    {:ok, raw_code, _grant} = Accounts.create_auth_grant(user, challenge, "https://learn.concord.org")
    {raw_code, verifier}
  end

  defp post_json(conn, path, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(path, body)
  end

  describe "POST /auth/cli/token" do
    test "exchanges a body-only code/verifier pair for an API token", %{conn: conn} do
      {code, verifier} = grant_fixture()

      conn = post_json(conn, "/auth/cli/token", Jason.encode!(%{"code" => code, "code_verifier" => verifier}))
      body = json_response(conn, 200)

      assert String.starts_with?(body["token"], "ccd_")
      assert {:ok, _user, _token} = Accounts.verify_api_token(body["token"])
    end

    test "returns an identical 400 for unknown, used and wrong-verifier codes", %{conn: conn} do
      {code, verifier} = grant_fixture()

      unknown =
        post_json(conn, "/auth/cli/token", Jason.encode!(%{"code" => "nope", "code_verifier" => verifier}))
      assert json_response(unknown, 400) == @bad_request

      wrong =
        post_json(conn, "/auth/cli/token", Jason.encode!(%{"code" => code, "code_verifier" => "wrong"}))
      assert json_response(wrong, 400) == @bad_request

      # the wrong-verifier attempt above consumed the code, so a correct retry also fails
      retry =
        post_json(conn, "/auth/cli/token", Jason.encode!(%{"code" => code, "code_verifier" => verifier}))
      assert json_response(retry, 400) == @bad_request
    end

    test "rejects a query-string code/verifier without consuming the grant", %{conn: conn} do
      {code, verifier} = grant_fixture()

      rejected = post_json(conn, "/auth/cli/token?code=#{code}&code_verifier=#{verifier}", "{}")
      assert json_response(rejected, 400) == @bad_request

      # the grant was not consumed: a body-only exchange still succeeds
      accepted = post_json(build_conn(), "/auth/cli/token", Jason.encode!(%{"code" => code, "code_verifier" => verifier}))
      assert String.starts_with?(json_response(accepted, 200)["token"], "ccd_")
    end

    test "rejects a secret in the query string even alongside a valid body", %{conn: conn} do
      {code, verifier} = grant_fixture()

      conn =
        post_json(conn, "/auth/cli/token?code=#{code}", Jason.encode!(%{"code" => code, "code_verifier" => verifier}))

      assert json_response(conn, 400) == @bad_request
      assert Repo.one!(AuthGrant).used_at == nil
    end

    test "requires no session or CSRF token", %{conn: conn} do
      {code, verifier} = grant_fixture()

      conn = post_json(conn, "/auth/cli/token", Jason.encode!(%{"code" => code, "code_verifier" => verifier}))
      assert json_response(conn, 200)["token"]
    end

    test "returns 400 for a body missing the code or code_verifier", %{conn: _conn} do
      for body <- [%{}, %{"code" => "x"}, %{"code_verifier" => "y"}] do
        conn = post_json(build_conn(), "/auth/cli/token", Jason.encode!(body))
        assert json_response(conn, 400) == @bad_request
      end
    end

    test "an optional label becomes the minted token's label", %{conn: conn} do
      {code, verifier} = grant_fixture()

      conn =
        post_json(conn, "/auth/cli/token",
          Jason.encode!(%{"code" => code, "code_verifier" => verifier, "label" => "CLI login (myhost)"}))

      {:ok, _user, api_token} = Accounts.verify_api_token(json_response(conn, 200)["token"])
      assert api_token.label == "CLI login (myhost)"
    end

    test "no label keeps the default", %{conn: conn} do
      {code, verifier} = grant_fixture()

      conn = post_json(conn, "/auth/cli/token", Jason.encode!(%{"code" => code, "code_verifier" => verifier}))

      {:ok, _user, api_token} = Accounts.verify_api_token(json_response(conn, 200)["token"])
      assert api_token.label == "CLI login"
    end

    test "an over-long label is truncated to 100 chars, never a 400", %{conn: conn} do
      {code, verifier} = grant_fixture()
      long_label = String.duplicate("x", 150)

      conn =
        post_json(conn, "/auth/cli/token",
          Jason.encode!(%{"code" => code, "code_verifier" => verifier, "label" => long_label}))

      {:ok, _user, api_token} = Accounts.verify_api_token(json_response(conn, 200)["token"])
      assert api_token.label == String.duplicate("x", 100)
    end

    test "truncation that cuts at a space leaves no trailing whitespace", %{conn: conn} do
      {code, verifier} = grant_fixture()
      label = String.duplicate("x", 99) <> " " <> String.duplicate("y", 50)

      conn =
        post_json(conn, "/auth/cli/token",
          Jason.encode!(%{"code" => code, "code_verifier" => verifier, "label" => label}))

      {:ok, _user, api_token} = Accounts.verify_api_token(json_response(conn, 200)["token"])
      assert api_token.label == String.duplicate("x", 99)
    end

    test "whitespace-only and non-string labels fall back to the default" do
      for label <- ["   ", 123, %{"nested" => true}] do
        {code, verifier} = grant_fixture()

        conn =
          post_json(build_conn(), "/auth/cli/token",
            Jason.encode!(%{"code" => code, "code_verifier" => verifier, "label" => label}))

        {:ok, _user, api_token} = Accounts.verify_api_token(json_response(conn, 200)["token"])
        assert api_token.label == "CLI login"
      end
    end
  end

  describe "log hygiene" do
    test "filter_parameters redacts the auth secret param names" do
      params = Application.get_env(:phoenix, :filter_parameters)

      for name <- ["password", "token", "access_token", "code", "code_verifier"] do
        assert name in params
      end
    end
  end

  @invalid_requests [
    %{"redirect_uri" => :omit},
    %{"redirect_uri" => "http://example.com:12345/callback"},
    %{"redirect_uri" => "https://127.0.0.1:12345/callback"},
    %{"redirect_uri" => "http://127.0.0.1:12345/other"},
    %{"redirect_uri" => "http://127.0.0.1:12345/callback?x=1"},
    %{"redirect_uri" => "http://localhost:12345/callback"},
    %{"redirect_uri" => "http://evil@127.0.0.1:12345/callback"},
    %{"redirect_uri" => "http://127.0.0.1:0/callback"},
    %{"redirect_uri" => "http://127.0.0.1:-1/callback"},
    %{"redirect_uri" => "http://127.0.0.1:99999/callback"},
    %{"redirect_uri" => "http://127.0.0.1/callback"},
    %{"state" => :omit},
    %{"code_challenge" => :omit},
    %{"code_challenge" => "short"},
    %{"code_challenge" => String.duplicate("a", 42) <> "!"},
    %{"code_challenge_method" => "plain"},
    %{"code_challenge_method" => :omit},
    %{"portal" => "ftp://learn.concord.org"},
    %{"portal" => "http://learn.concord.org"},
    %{"portal" => "https://evil@learn.concord.org"},
    %{"portal" => "https://learn.concord.org/evil"},
    %{"portal" => "https://learn.concord.org?x=1"},
    %{"portal" => "https://learn.concord.org#frag"},
    %{"portal" => "https://learn.concord.org:-1"},
    %{"portal" => "https://unknown.example.com"}
  ]

  describe "GET /auth/cli" do
    test "renders a 400 at /auth/cli and mints no grant for invalid entry requests", %{conn: conn} do
      for overrides <- @invalid_requests do
        result = get(conn, "/auth/cli?" <> cli_query(overrides))
        assert response(result, 400)
        assert get_resp_header(result, "location") == []
      end

      assert grant_count() == 0
    end

    test "a logged-in researcher on the matching portal gets a loopback redirect with code and state", %{conn: conn} do
      user = matching_user()
      challenge = valid_challenge()

      conn =
        conn
        |> log_in_conn(user)
        |> get("/auth/cli?" <> cli_query(%{"code_challenge" => challenge, "state" => "abc123"}))

      location = redirected_to(conn, 302)
      assert String.starts_with?(location, "http://127.0.0.1:12345/callback?")

      params = URI.parse(location).query |> URI.decode_query()
      assert params["state"] == "abc123"

      grant = Repo.one!(AuthGrant)
      assert grant.user_id == user.id
      assert grant.code_challenge == challenge
      assert grant.portal_url == @default_portal
      assert grant.code_hash == (:crypto.hash(:sha256, params["code"]) |> Base.encode16(case: :lower))
    end

    test "a logged-in user failing the role gate sees an error and no grant is minted", %{conn: conn} do
      user = matching_user(%{portal_is_admin: false, portal_is_project_admin: false, portal_is_project_researcher: false})

      conn =
        conn
        |> log_in_conn(user)
        |> get("/auth/cli?" <> cli_query())

      assert response(conn, 400)
      assert get_resp_header(conn, "location") == []
      assert grant_count() == 0
    end

    test "an unauthenticated request redirects to the portal login and stores the pending request", %{conn: conn} do
      conn = get(conn, "/auth/cli?" <> cli_query())

      assert redirected_to(conn, 302) =~ "/auth/oauth_authorize"
      assert get_session(conn, :cli_auth_request)
      assert get_session(conn, :return_to) == "/auth/cli/resume"
      assert get_session(conn, :portal_url) == @default_portal
      assert grant_count() == 0
    end

    test "a session user on a different portal is treated as unauthenticated for the requested portal", %{conn: conn} do
      put_portal_db("learn.portal.staging.concord.org")
      user = user_fixture(%{portal_server: "learn.concord.org"})

      conn =
        conn
        |> log_in_conn(user)
        |> get("/auth/cli?" <> cli_query(%{"portal" => @default_portal}))

      assert redirected_to(conn, 302) =~ "/auth/oauth_authorize"
      assert get_session(conn, :cli_auth_request).portal_url == @default_portal
      assert grant_count() == 0
    end

    test "normalizes a trailing-slash or :443 portal to the canonical origin in the grant", %{conn: _conn} do
      put_portal_db("learn.portal.staging.concord.org")
      user = matching_user()

      for portal <- ["#{@default_portal}/", "#{@default_portal}:443"] do
        result =
          build_conn()
          |> log_in_conn(user)
          |> get("/auth/cli?" <> cli_query(%{"portal" => portal}))

        assert redirected_to(result, 302)
      end

      assert grant_count() == 2
      assert Enum.all?(Repo.all(AuthGrant), &(&1.portal_url == @default_portal))
    end

    test "echoes a state containing URL-meta characters verbatim", %{conn: conn} do
      user = matching_user()

      conn =
        conn
        |> log_in_conn(user)
        |> get("/auth/cli?" <> cli_query(%{"state" => "a b&c=d"}))

      location = redirected_to(conn, 302)
      params = URI.parse(location).query |> URI.decode_query()
      assert params["state"] == "a b&c=d"
    end
  end

  describe "GET /auth/cli/resume" do
    test "issues the code and clears the pending request", %{conn: conn} do
      user = matching_user()

      request = %{
        redirect_uri: "http://127.0.0.1:12345/callback",
        state: "xyz",
        code_challenge: valid_challenge(),
        portal_url: @default_portal
      }

      conn =
        conn
        |> log_in_conn(user)
        |> Plug.Conn.put_session(:cli_auth_request, request)
        |> get(~p"/auth/cli/resume")

      location = redirected_to(conn, 302)
      assert String.starts_with?(location, "http://127.0.0.1:12345/callback?")

      params = URI.parse(location).query |> URI.decode_query()
      assert params["state"] == "xyz"
      assert get_session(conn, :cli_auth_request) == nil
      assert Repo.one!(AuthGrant).user_id == user.id
    end

    test "shows an error when no CLI login is in progress", %{conn: conn} do
      user = matching_user()

      conn =
        conn
        |> log_in_conn(user)
        |> get(~p"/auth/cli/resume")

      assert response(conn, 400)
      assert get_resp_header(conn, "location") == []
    end
  end
end
