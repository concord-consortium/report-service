defmodule ReportServerWeb.AuthCliControllerTest do
  use ReportServerWeb.ConnCase

  import ReportServer.AccountsFixtures

  alias ReportServer.Accounts
  alias ReportServer.Accounts.AuthGrant
  alias ReportServer.Repo

  @bad_request %{"error" => "BAD_REQUEST", "message" => "Invalid code or verifier."}

  defp pkce_pair() do
    verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
    {verifier, challenge}
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
  end

  describe "log hygiene" do
    test "filter_parameters redacts the auth secret param names" do
      params = Application.get_env(:phoenix, :filter_parameters)

      for name <- ["password", "token", "access_token", "code", "code_verifier"] do
        assert name in params
      end
    end
  end
end
