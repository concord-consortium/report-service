defmodule ReportServerWeb.CliTokenLiveTest do
  use ReportServerWeb.ConnCase

  import Phoenix.LiveViewTest
  import ReportServer.AccountsFixtures

  alias ReportServer.Accounts.ApiToken
  alias ReportServer.Repo

  defp token_count(), do: Repo.aggregate(ApiToken, :count)

  test "mounting the page mints no tokens", %{conn: conn} do
    user = user_fixture()
    {:ok, _view, html} = live(log_in_conn(conn, user), ~p"/reports/cli-token")

    assert html =~ "CLI Access Token"
    assert token_count() == 0
  end

  test "generating mints exactly one token and shows the raw value with a copy button", %{conn: conn} do
    user = user_fixture()
    {:ok, view, _html} = live(log_in_conn(conn, user), ~p"/reports/cli-token")

    html = view |> form("form", %{"label" => "My Laptop"}) |> render_submit()

    assert token_count() == 1
    token = Repo.one!(ApiToken)
    assert token.label == "My Laptop"

    [raw] = Regex.run(~r/ccd_[A-Za-z0-9_-]+/, html)
    assert token.token_hash == (:crypto.hash(:sha256, raw) |> Base.encode16(case: :lower))
    assert html =~ "Copy to clipboard"
  end

  test "a blank label persists as nil", %{conn: conn} do
    user = user_fixture()
    {:ok, view, _html} = live(log_in_conn(conn, user), ~p"/reports/cli-token")

    view |> form("form", %{"label" => "   "}) |> render_submit()

    assert Repo.one!(ApiToken).label == nil
  end

  test "remounting after generating shows no token and does not re-mint", %{conn: conn} do
    user = user_fixture()
    {:ok, view, _html} = live(log_in_conn(conn, user), ~p"/reports/cli-token")
    view |> form("form", %{"label" => ""}) |> render_submit()
    assert token_count() == 1

    {:ok, _view2, html2} = live(log_in_conn(conn, user), ~p"/reports/cli-token")
    refute html2 =~ "ccd_"
    assert token_count() == 1
  end

  test "a user without report access is redirected by the live_session gate", %{conn: conn} do
    user =
      user_fixture(%{
        portal_is_admin: false,
        portal_is_project_admin: false,
        portal_is_project_researcher: false
      })

    assert {:error, {:redirect, %{to: "/"}}} = live(log_in_conn(conn, user), ~p"/reports/cli-token")
  end

  test "a minted token appears in the active list in the same render", %{conn: conn} do
    user = user_fixture()
    {:ok, view, _html} = live(log_in_conn(conn, user), ~p"/reports/cli-token")

    html = view |> form("form", %{"label" => "My Laptop"}) |> render_submit()

    assert html =~ "ccd_"
    assert html =~ "My Laptop"
    assert html =~ "Your active tokens"
  end

  test "revoking an older row does not blank the shown-once value", %{conn: conn} do
    user = user_fixture()
    {_raw, old} = api_token_fixture(user, "Old Machine")
    {:ok, view, _html} = live(log_in_conn(conn, user), ~p"/reports/cli-token")

    render_submit(form(view, "form", %{"label" => "New Machine"}))
    html = render_click(view, "revoke", %{"id" => to_string(old.id)})

    assert html =~ "ccd_"
    assert html =~ "Token revoked"
    refute html =~ "Old Machine"
    assert html =~ "New Machine"
  end

  test "revoking the just-minted row clears the shown-once panel (no dead token left visible)", %{conn: conn} do
    user = user_fixture()
    {:ok, view, _html} = live(log_in_conn(conn, user), ~p"/reports/cli-token")

    html = render_submit(form(view, "form", %{"label" => "Fresh"}))
    assert html =~ "ccd_"
    minted = ReportServer.Accounts.list_active_api_tokens(user.id) |> List.first()

    html = render_click(view, "revoke", %{"id" => to_string(minted.id)})

    assert html =~ "Token revoked"
    refute html =~ "ccd_"
    refute html =~ "Fresh"
    assert html =~ "You have no active tokens yet."
  end

  test "self-revoke removes the row; the token stops authenticating", %{conn: conn} do
    user = user_fixture()
    {raw, token} = api_token_fixture(user, "Doomed")
    {:ok, view, html} = live(log_in_conn(conn, user), ~p"/reports/cli-token")
    assert html =~ "Doomed"

    html = render_click(view, "revoke", %{"id" => to_string(token.id)})
    assert html =~ "Token revoked"
    refute html =~ "Doomed"
    assert :error == ReportServer.Accounts.verify_api_token(raw)
  end

  test "a forged id for another user's token is a benign no-op (IDOR)", %{conn: conn} do
    user = user_fixture()
    other = user_fixture()
    {other_raw, other_token} = api_token_fixture(other, "Not Yours")
    {:ok, view, _html} = live(log_in_conn(conn, user), ~p"/reports/cli-token")

    html = render_click(view, "revoke", %{"id" => to_string(other_token.id)})

    assert html =~ "That token was already inactive"
    assert {:ok, _u, _t} = ReportServer.Accounts.verify_api_token(other_raw)
  end

  test "the self-serve list renders only the caller's tokens", %{conn: conn} do
    user = user_fixture()
    other = user_fixture()
    api_token_fixture(user, "Mine")
    api_token_fixture(other, "Theirs")

    {:ok, _view, html} = live(log_in_conn(conn, user), ~p"/reports/cli-token")

    assert html =~ "Mine"
    refute html =~ "Theirs"
  end

  test "revoking an already-revoked token is a benign no-op", %{conn: conn} do
    user = user_fixture()
    {_raw, token} = api_token_fixture(user, "Gone")
    {:ok, revoked} = ReportServer.Accounts.revoke_api_token(token, user.id)
    {:ok, view, _html} = live(log_in_conn(conn, user), ~p"/reports/cli-token")

    html = render_click(view, "revoke", %{"id" => to_string(token.id)})

    assert html =~ "That token was already inactive"
    reloaded = ReportServer.Repo.get(ReportServer.Accounts.ApiToken, token.id)
    assert reloaded.revoked_by_user_id == revoked.revoked_by_user_id
  end

  test "empty state shows the 'none yet' copy", %{conn: conn} do
    user = user_fixture()
    {:ok, _view, html} = live(log_in_conn(conn, user), ~p"/reports/cli-token")
    assert html =~ "You have no active tokens yet."
  end

  test "an unauthenticated visit redirects instead of crashing", %{conn: conn} do
    assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/reports/cli-token")
    assert to in ["/reports", "/auth/login?return_to=/reports/cli-token"]
  end
end
