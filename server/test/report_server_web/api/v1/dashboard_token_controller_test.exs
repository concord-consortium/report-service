defmodule ReportServerWeb.Api.V1.DashboardTokenControllerTest do
  use ReportServerWeb.ConnCase, async: false

  import ReportServerWeb.PortalTokenFixture

  alias ReportServer.Accounts
  alias ReportServer.Accounts.{ApiToken, UsedPortalAssertion, User}
  alias ReportServer.Repo

  @staging_db_env "LEARN_PORTAL_STAGING_CONCORD_ORG_DB"
  @staging_server "learn.portal.staging.concord.org"

  setup do
    previous = System.get_env(@staging_db_env)
    System.put_env(@staging_db_env, "mysql://user:pass@localhost:3306")

    on_exit(fn ->
      if previous, do: System.put_env(@staging_db_env, previous), else: System.delete_env(@staging_db_env)
    end)
  end

  defp assertion_claims(overrides \\ %{}) do
    claims(
      :staging,
      "report-server",
      Map.merge(
        %{
          "uid" => 1001,
          "jti" => Ecto.UUID.generate(),
          "user_type" => "researcher",
          "scope_kind" => "class",
          "scope_id" => 7,
          "portal_user_id" => 1001,
          "portal_server" => @staging_server,
          "login" => "rresearcher",
          "first_name" => "Rae",
          "last_name" => "Searcher",
          "email" => "rae@example.com",
          "is_admin" => false,
          "is_project_admin" => false,
          "is_project_researcher" => true
        },
        overrides
      )
    )
  end

  defp mint(conn, token, body \\ %{}) do
    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> post(~p"/api/v1/dashboard-tokens", body)
  end

  defp dashboard_user do
    Repo.get_by!(User, portal_server: @staging_server, portal_user_id: 1001)
  end

  test "mints a token that verifies, expires in nine hours and names the assertion's user", %{conn: conn} do
    body = conn |> mint(sign(:staging, assertion_claims())) |> json_response(201)

    assert {:ok, user, api_token} = Accounts.verify_api_token(body["token"])
    assert user.portal_user_id == 1001
    assert user.portal_server == @staging_server
    assert body["user_id"] == user.id
    assert api_token.label == Accounts.dashboard_token_label()
    assert_in_delta DateTime.diff(api_token.expires_at, DateTime.utc_now()), 9 * 60 * 60, 5
  end

  test "a second mint revokes the first", %{conn: conn} do
    first = conn |> mint(sign(:staging, assertion_claims())) |> json_response(201)
    second = build_conn() |> mint(sign(:staging, assertion_claims())) |> json_response(201)

    assert :error == Accounts.verify_api_token(first["token"])
    assert {:ok, _user, _token} = Accounts.verify_api_token(second["token"])
  end

  test "leaves the user's other tokens alone", %{conn: conn} do
    conn |> mint(sign(:staging, assertion_claims())) |> json_response(201)
    {:ok, cli_raw, _cli} = Accounts.create_api_token(dashboard_user(), "CLI login")

    build_conn() |> mint(sign(:staging, assertion_claims())) |> json_response(201)

    assert {:ok, _user, _token} = Accounts.verify_api_token(cli_raw)
  end

  test "refuses a replayed assertion and mints nothing", %{conn: conn} do
    token = sign(:staging, assertion_claims())
    conn |> mint(token) |> json_response(201)

    assert build_conn() |> mint(token) |> json_response(401)
    assert Repo.aggregate(ApiToken, :count) == 1
  end

  test "refuses an assertion without a jti", %{conn: conn} do
    assert conn |> mint(sign(:staging, assertion_claims(), without: ["jti"])) |> json_response(401)
    assert Repo.aggregate(ApiToken, :count) == 0
  end

  test "refuses an assertion whose portal_user_id is not its uid, and mints nothing", %{conn: conn} do
    body = conn |> mint(sign(:staging, assertion_claims(%{"uid" => 2002}))) |> json_response(400)

    assert body["message"] =~ "portal_user_id"
    assert Repo.aggregate(ApiToken, :count) == 0
  end

  test "refuses an assertion whose exp is beyond what can be recorded", %{conn: conn} do
    token = sign(:staging, assertion_claims(%{"exp" => 300_000_000_000}))

    assert conn |> mint(token) |> json_response(401)
    assert Repo.aggregate(ApiToken, :count) == 0
  end

  test "refuses a jti too long to record", %{conn: conn} do
    token = sign(:staging, assertion_claims(%{"jti" => String.duplicate("j", 256)}))

    assert conn |> mint(token) |> json_response(401)
    assert Repo.aggregate(ApiToken, :count) == 0
  end

  test "refuses a portal report-server has no database connection for", %{conn: conn} do
    System.delete_env(@staging_db_env)

    assert conn |> mint(sign(:staging, assertion_claims())) |> json_response(401)
    assert Repo.aggregate(ApiToken, :count) == 0
  end

  test "refuses a portal_server that disagrees with iss", %{conn: conn} do
    token = sign(:staging, assertion_claims(%{"portal_server" => "learn.concord.org"}))

    assert conn |> mint(token) |> json_response(401)
    assert Repo.aggregate(ApiToken, :count) == 0
  end

  test "refuses an assertion of another audience", %{conn: conn} do
    token = sign(:staging, assertion_claims(%{"aud" => "researcher-dashboard"}))

    assert conn |> mint(token) |> json_response(401)
  end

  test "refuses an API token as the bearer", %{conn: conn} do
    user = ReportServer.AccountsFixtures.user_fixture()
    {:ok, raw, _token} = Accounts.create_api_token(user)

    assert conn |> mint(raw) |> json_response(401)
  end

  test "ignores the body: a body naming another user or admin flags changes nothing", %{conn: conn} do
    body = %{"portal_user_id" => 1, "portal_server" => "learn.concord.org", "is_admin" => true}

    conn |> mint(sign(:staging, assertion_claims()), body) |> json_response(201)

    user = dashboard_user()
    refute user.portal_is_admin
    assert Repo.aggregate(User, :count) == 1
  end

  test "creates the user on the first mint and updates the flags on the next", %{conn: conn} do
    conn |> mint(sign(:staging, assertion_claims())) |> json_response(201)
    refute dashboard_user().portal_is_project_admin

    build_conn()
    |> mint(sign(:staging, assertion_claims(%{"is_project_admin" => true, "email" => "rae@new.example.com"})))
    |> json_response(201)

    user = dashboard_user()
    assert user.portal_is_project_admin
    assert user.portal_email == "rae@new.example.com"
  end

  test "stores a role flag as true only when its claim is literally true", %{conn: conn} do
    claims = assertion_claims(%{"is_admin" => "true", "is_project_admin" => 1})

    conn |> mint(sign(:staging, claims, without: ["is_project_researcher"])) |> json_response(201)

    user = dashboard_user()
    refute user.portal_is_admin
    refute user.portal_is_project_admin
    refute user.portal_is_project_researcher
  end

  test "refuses an assertion missing a required user claim, naming it", %{conn: conn} do
    body = conn |> mint(sign(:staging, assertion_claims(), without: ["email"])) |> json_response(400)

    assert body["message"] =~ "email"
    assert Repo.aggregate(ApiToken, :count) == 0
  end

  test "prunes used jtis whose assertions have expired", %{conn: conn} do
    stale_expiry = DateTime.utc_now(:second) |> DateTime.add(-60)
    Repo.insert!(%UsedPortalAssertion{jti: "stale", expires_at: stale_expiry})

    conn |> mint(sign(:staging, assertion_claims())) |> json_response(201)

    refute Repo.get_by(UsedPortalAssertion, jti: "stale")
    assert Repo.aggregate(UsedPortalAssertion, :count) == 1
  end
end
