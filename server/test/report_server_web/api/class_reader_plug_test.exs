defmodule ReportServerWeb.Api.ClassReaderPlugTest do
  use ReportServerWeb.ConnCase, async: false

  import ReportServer.AccountsFixtures
  import ReportServerWeb.PortalTokenFixture

  alias ReportServer.Accounts
  alias ReportServerWeb.Api.{ClassReaderPlug, PortalToken}

  setup do
    install!()
    :ok
  end

  defp call(conn, bearer) do
    conn
    |> then(&if(bearer, do: put_req_header(&1, "authorization", "Bearer #{bearer}"), else: &1))
    |> ClassReaderPlug.call([])
  end

  defp access_token(scope, opts \\ []) do
    claims = access_claims(:staging, [iss(:staging), PortalToken.access_token_audience()], scope)
    sign_access(:staging, claims, opts)
  end

  test "an API token reaches the next plug as the current user", %{conn: conn} do
    user = user_fixture()
    {raw_token, _} = api_token_fixture(user)

    conn = call(conn, raw_token)

    refute conn.halted
    assert conn.assigns.current_user.id == user.id
  end

  test "an API token for a user without report access is refused", %{conn: conn} do
    user = user_fixture(%{portal_is_admin: false, portal_is_project_admin: false, portal_is_project_researcher: false})
    {raw_token, _} = api_token_fixture(user)

    conn = call(conn, raw_token)

    assert conn.halted
    assert conn.status == 401
  end

  test "a revoked API token is refused", %{conn: conn} do
    user = user_fixture()
    {raw_token, api_token} = api_token_fixture(user)
    {:ok, _} = Accounts.revoke_api_token(api_token, user.id)

    conn = call(conn, raw_token)

    assert conn.halted
    assert conn.status == 401
  end

  test "an access token carrying class:researcher-read is taken, claims and all", %{conn: conn} do
    conn = call(conn, access_token("class:researcher-read packages:read"))

    refute conn.halted
    assert conn.assigns.portal_claims["iss"] == iss(:staging)
  end

  test "an access token without class:researcher-read is refused", %{conn: conn} do
    conn = call(conn, access_token("packages:read"))

    assert conn.halted
    assert conn.status == 401
  end

  test "an HS256 token signed with the public key and an assertion are refused", %{conn: conn} do
    claims = access_claims(:staging, [iss(:staging), PortalToken.access_token_audience()], "class:researcher-read")
    hs256 = sign_hs256_with_public_pem(:staging, claims)
    assertion = sign(:staging, claims(:staging, PortalToken.access_token_audience(), %{"scope" => "class:researcher-read"}))

    for bearer <- [hs256, assertion] do
      conn = call(conn, bearer)
      assert conn.halted
      assert conn.status == 401
    end
  end

  test "a request with no bearer is refused", %{conn: conn} do
    conn = call(conn, nil)

    assert conn.halted
    assert conn.status == 401
  end
end
