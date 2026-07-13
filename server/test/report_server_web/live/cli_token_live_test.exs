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
end
