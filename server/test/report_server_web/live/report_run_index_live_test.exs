defmodule ReportServerWeb.ReportRunIndexLiveTest do
  use ReportServerWeb.ConnCase

  import Phoenix.LiveViewTest
  import ReportServer.AccountsFixtures

  alias ReportServer.Reports
  alias ReportServer.Reports.ReportFilter

  defp make_runs(user, n) do
    for _ <- 1..n do
      {:ok, run} =
        Reports.create_report_run(%{
          user_id: user.id,
          report_slug: "student-answers",
          report_filter: %ReportFilter{filters: [:cohort], cohort: [1]},
          report_filter_values: %{"cohort" => %{"1" => "Cohort One"}}
        })

      run
    end
  end

  describe "my runs" do
    test "shows the empty state and no pager when there are no runs", %{conn: conn} do
      user = user_fixture()
      {:ok, _view, html} = live(log_in_conn(conn, user), ~p"/reports/runs")

      assert html =~ "No report runs found."
      refute html =~ ~s(aria-label="pagination)
    end

    test "renders a pager above and below the table and navigates to page 2 via patch", %{conn: conn} do
      user = user_fixture()
      make_runs(user, 26)

      {:ok, view, html} = live(log_in_conn(conn, user), ~p"/reports/runs")
      assert html =~ ~s(aria-label="pagination top")
      assert html =~ ~s(aria-label="pagination bottom")

      html2 = render_patch(view, "/reports/runs?page=2")
      assert html2 =~ ~s(aria-current="page")
    end

    test "an overflow page clamps to the last page without crashing", %{conn: conn} do
      user = user_fixture()
      make_runs(user, 26)

      {:ok, _view, html} = live(log_in_conn(conn, user), ~p"/reports/runs?page=99")
      assert html =~ ~s(aria-label="pagination top")
      assert html =~ ~s(aria-current="page")
    end

    test "an invalid page param renders page 1", %{conn: conn} do
      user = user_fixture()
      make_runs(user, 3)

      {:ok, _view, html} = live(log_in_conn(conn, user), ~p"/reports/runs?page=abc")
      refute html =~ ~s(aria-label="pagination)
      refute html =~ "No report runs found."
    end
  end

  describe "all runs" do
    test "redirects a non-admin", %{conn: conn} do
      user = user_fixture(%{portal_is_admin: false})
      assert {:error, {:redirect, %{to: "/reports"}}} = live(log_in_conn(conn, user), ~p"/reports/all-runs")
    end

    test "an admin sees the all-runs page", %{conn: conn} do
      admin = user_fixture(%{portal_is_admin: true})
      other = user_fixture()
      make_runs(other, 1)

      {:ok, _view, html} = live(log_in_conn(conn, admin), ~p"/reports/all-runs")
      assert html =~ "All Runs"
    end
  end
end
