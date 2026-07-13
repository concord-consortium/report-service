defmodule ReportServerWeb.AllTokensLiveTest do
  use ReportServerWeb.ConnCase

  import Phoenix.LiveViewTest
  import ReportServer.AccountsFixtures

  test "redirects a non-admin", %{conn: conn} do
    user = user_fixture(%{portal_is_admin: false})
    assert {:error, {:redirect, %{to: "/reports"}}} = live(log_in_conn(conn, user), ~p"/reports/all-tokens")
  end

  test "an admin sees all users' active tokens with a name+email User column", %{conn: conn} do
    admin = user_fixture(%{portal_is_admin: true})
    owner = user_fixture(%{portal_first_name: "Dana", portal_last_name: "Researcher"})
    api_token_fixture(owner, "Dana Laptop")

    {:ok, _view, html} = live(log_in_conn(conn, admin), ~p"/reports/all-tokens")

    assert html =~ "All CLI Tokens"
    assert html =~ "Dana Laptop"
    assert html =~ owner.portal_email
  end

  test "an admin revokes another user's token (attributed to the admin)", %{conn: conn} do
    admin = user_fixture(%{portal_is_admin: true})
    owner = user_fixture()
    {raw, token} = api_token_fixture(owner, "Departing")
    {:ok, view, _html} = live(log_in_conn(conn, admin), ~p"/reports/all-tokens")

    html = render_click(view, "revoke", %{"id" => to_string(token.id)})

    assert html =~ "Token revoked"
    refute html =~ "Departing"
    assert :error == ReportServer.Accounts.verify_api_token(raw)
    assert ReportServer.Repo.get(ReportServer.Accounts.ApiToken, token.id).revoked_by_user_id == admin.id
  end

  test "revoking the only token on the last page lands on a valid page", %{conn: conn} do
    admin = user_fixture(%{portal_is_admin: true})
    owner = user_fixture()
    tokens = for _ <- 1..26, do: (api_token_fixture(owner) |> elem(1))
    last = Enum.min_by(tokens, & &1.id)

    {:ok, view, _html} = live(log_in_conn(conn, admin), ~p"/reports/all-tokens?page=2")
    html = render_click(view, "revoke", %{"id" => to_string(last.id)})

    assert html =~ "Token revoked"
    refute html =~ "aria-label=\"pagination"
  end

  test "a non-admin revoke event is rejected by the handler and revokes nothing" do
    non_admin = user_fixture(%{portal_is_admin: false})
    owner = user_fixture()
    {raw, _token} = api_token_fixture(owner, "Untouched")

    socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, user: non_admin}}
    assert {:noreply, ^socket} =
             ReportServerWeb.AllTokensLive.Index.handle_event("revoke", %{"id" => "1"}, socket)

    assert {:ok, _u, _t} = ReportServer.Accounts.verify_api_token(raw)
  end

  test "the pager appears only past 25 tokens", %{conn: conn} do
    admin = user_fixture(%{portal_is_admin: true})
    owner = user_fixture()
    for _ <- 1..26, do: api_token_fixture(owner)

    {:ok, _view, html} = live(log_in_conn(conn, admin), ~p"/reports/all-tokens")
    assert html =~ ~s(aria-label="pagination top")
  end

  test "shows an empty state and hides the pager when there are no active tokens", %{conn: conn} do
    admin = user_fixture(%{portal_is_admin: true})
    {:ok, _view, html} = live(log_in_conn(conn, admin), ~p"/reports/all-tokens")
    assert html =~ "No active tokens."
    refute html =~ ~s(aria-label="pagination)
  end
end
