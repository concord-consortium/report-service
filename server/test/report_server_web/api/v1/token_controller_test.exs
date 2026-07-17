defmodule ReportServerWeb.Api.V1.TokenControllerTest do
  use ReportServerWeb.ConnCase

  import ReportServer.AccountsFixtures

  alias ReportServer.Accounts
  alias ReportServer.Accounts.ApiToken
  alias ReportServer.Repo
  alias ReportServerWeb.Api.V1.TokenController

  @not_authenticated %{
    "error" => "NOT_AUTHENTICATED",
    "message" => "You must supply a valid API token."
  }

  defp deroled_user do
    user_fixture(%{
      portal_is_admin: false,
      portal_is_project_admin: false,
      portal_is_project_researcher: false
    })
  end

  defp put_bearer(conn, raw_token), do: put_req_header(conn, "authorization", "Bearer #{raw_token}")

  describe "DELETE /api/v1/tokens/current" do
    test "revokes the calling token; any reuse gets the standard 401", %{conn: conn} do
      user = user_fixture()
      {raw_token, api_token} = api_token_fixture(user)
      conn = put_bearer(conn, raw_token)

      assert json_response(delete(conn, ~p"/api/v1/tokens/current"), 200) == %{"revoked" => true}

      revoked = Repo.get!(ApiToken, api_token.id)
      assert revoked.revoked_at != nil
      assert revoked.revoked_by_user_id == user.id

      # the token is dead everywhere: data routes and a second revoke both 401
      assert json_response(get(conn, ~p"/api/v1/reports"), 401) == @not_authenticated
      assert json_response(delete(conn, ~p"/api/v1/tokens/current"), 401) == @not_authenticated
    end

    test "requires authentication", %{conn: conn} do
      assert json_response(delete(conn, ~p"/api/v1/tokens/current"), 401) == @not_authenticated
    end

    test "a valid token whose user has no report-access roles can still revoke itself", %{conn: conn} do
      {raw_token, _api_token} = api_token_fixture(deroled_user())
      conn = put_bearer(conn, raw_token)

      # the role-gated routes still reject this user...
      assert json_response(get(conn, ~p"/api/v1/reports"), 401) == @not_authenticated
      # ...but self-revocation succeeds
      assert json_response(delete(conn, ~p"/api/v1/tokens/current"), 200) == %{"revoked" => true}
    end

    test "a lost race ({:error, :already_revoked}) still returns revoked: true" do
      # unreachable over HTTP (a revoked token 401s at AuthPlug before the controller),
      # so invoke the action directly with a stale pre-revocation struct in assigns
      user = user_fixture()
      {_raw_token, api_token} = api_token_fixture(user)
      {:ok, _revoked} = Accounts.revoke_api_token(api_token, user.id)

      conn =
        build_conn(:delete, "/api/v1/tokens/current")
        |> assign(:current_user, user)
        |> assign(:api_token, api_token)
        |> TokenController.delete_current(%{})

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body) == %{"revoked" => true}
    end
  end

  describe "GET /api/v1/tokens/current" do
    test "returns the calling token's own metadata, not another of the user's tokens", %{conn: conn} do
      user = user_fixture()
      {raw_token, api_token} = api_token_fixture(user, "My label")
      {_other_raw, _other_token} = api_token_fixture(user, "Other label")
      conn = put_bearer(conn, raw_token)

      assert json_response(get(conn, ~p"/api/v1/tokens/current"), 200) == %{
               "label" => "My label",
               "created_at" => DateTime.to_iso8601(api_token.inserted_at),
               "last_used_at" => nil,
               "report_access" => true
             }
    end

    test "a token with no label returns label: null", %{conn: conn} do
      {raw_token, _api_token} = api_token_fixture(user_fixture())
      conn = put_bearer(conn, raw_token)

      assert json_response(get(conn, ~p"/api/v1/tokens/current"), 200)["label"] == nil
    end

    test "a de-roled user's valid token gets 200 with report_access: false", %{conn: conn} do
      {raw_token, _api_token} = api_token_fixture(deroled_user())
      conn = put_bearer(conn, raw_token)

      body = json_response(get(conn, ~p"/api/v1/tokens/current"), 200)
      assert body["report_access"] == false
    end

    test "does not change last_used_at", %{conn: conn} do
      user = user_fixture()
      {raw_token, api_token} = api_token_fixture(user)
      assert Repo.get!(ApiToken, api_token.id).last_used_at == nil

      conn = put_bearer(conn, raw_token)
      assert json_response(get(conn, ~p"/api/v1/tokens/current"), 200)

      assert Repo.get!(ApiToken, api_token.id).last_used_at == nil
    end

    test "renders a non-nil last_used_at in ISO 8601 and leaves it unchanged", %{conn: conn} do
      user = user_fixture()
      {raw_token, api_token} = api_token_fixture(user)
      {:ok, touched} = Accounts.touch_api_token(api_token)

      conn = put_bearer(conn, raw_token)
      body = json_response(get(conn, ~p"/api/v1/tokens/current"), 200)

      assert body["last_used_at"] == DateTime.to_iso8601(touched.last_used_at)
      assert Repo.get!(ApiToken, api_token.id).last_used_at == touched.last_used_at
    end

    test "requires authentication; a revoked token gets the standard 401", %{conn: conn} do
      assert json_response(get(conn, ~p"/api/v1/tokens/current"), 401) == @not_authenticated

      user = user_fixture()
      {raw_token, api_token} = api_token_fixture(user)
      {:ok, _revoked} = Accounts.revoke_api_token(api_token, user.id)

      conn = put_bearer(conn, raw_token)
      assert json_response(get(conn, ~p"/api/v1/tokens/current"), 401) == @not_authenticated
    end
  end
end
