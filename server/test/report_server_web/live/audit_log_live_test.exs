defmodule ReportServerWeb.AuditLogLiveTest do
  use ReportServerWeb.ConnCase

  import Ecto.Query
  import Phoenix.LiveViewTest
  import ReportServer.AccountsFixtures

  alias ReportServer.AuditLog
  alias ReportServer.AuditLog.DataAccessLogEntry
  alias ReportServer.Repo
  alias ReportServer.Reports

  defp setup_run(user) do
    {:ok, run} = Reports.create_report_run(%{user_id: user.id, report_slug: "student-answers"})
    run
  end

  defp create_entry(user, run, attrs \\ %{}) do
    base = %{
      event: "download_url_issued",
      source: "api",
      data_type: "run_csv",
      user_id: user.id,
      report_run_id: run.id,
      report_slug: run.report_slug
    }

    {:ok, entry} = AuditLog.create_entry(Map.merge(base, attrs))
    entry
  end

  defp set_inserted_at(entry, dt) do
    Repo.update_all(from(e in DataAccessLogEntry, where: e.id == ^entry.id), set: [inserted_at: dt])
  end

  test "redirects a non-admin", %{conn: conn} do
    user = user_fixture(%{portal_is_admin: false})
    assert {:error, {:redirect, %{to: "/reports"}}} = live(log_in_conn(conn, user), ~p"/reports/audit-log")
  end

  test "an admin sees entries newest-first in a table with the four columns", %{conn: conn} do
    admin = user_fixture(%{portal_is_admin: true})
    run = setup_run(admin)
    older = create_entry(admin, run)
    newer = create_entry(admin, run, %{data_type: "job_result", job_id: 9})
    set_inserted_at(older, ~U[2020-01-01 00:00:00Z])
    set_inserted_at(newer, ~U[2021-06-15 12:30:00Z])

    {:ok, _view, html} = live(log_in_conn(conn, admin), ~p"/reports/audit-log")

    assert html =~ "Data Access Log"
    assert html =~ "<th"
    assert html =~ ~s(<time datetime="2021-06-15T12:30:00Z")
    assert html =~ admin.portal_email
    assert html =~ "job_result"
    assert html =~ "job 9"

    newer_pos = :binary.match(html, "2021-06-15") |> elem(0)
    older_pos = :binary.match(html, "2020-01-01") |> elem(0)
    assert newer_pos < older_pos
  end

  test "paginates 26 entries with a pager above and below the table", %{conn: conn} do
    admin = user_fixture(%{portal_is_admin: true})
    run = setup_run(admin)
    for _ <- 1..26, do: create_entry(admin, run)

    {:ok, view, html} = live(log_in_conn(conn, admin), ~p"/reports/audit-log")
    assert html =~ ~s(aria-label="pagination top")
    assert html =~ ~s(aria-label="pagination bottom")

    html2 = render_patch(view, "/reports/audit-log?page=2")
    assert html2 =~ ~s(aria-current="page")
  end

  test "shows an empty state when nothing has been recorded", %{conn: conn} do
    admin = user_fixture(%{portal_is_admin: true})
    {:ok, _view, html} = live(log_in_conn(conn, admin), ~p"/reports/audit-log")

    assert html =~ "No data access events have been recorded yet."
    refute html =~ ~s(aria-label="pagination)
  end
end
