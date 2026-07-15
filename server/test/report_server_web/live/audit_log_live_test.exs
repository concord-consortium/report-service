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

  defp count(haystack, needle), do: haystack |> String.split(needle) |> length() |> Kernel.-(1)

  defp refocus_value(html) do
    [_, value] = Regex.run(~r/id="audit-results"[^>]*data-refocus="([^"]*)"/, html)
    value
  end

  defp bulk_entry(user, run, attrs) do
    base = %{event: "bulk_read", source: "api", data_type: "answers_bulk", user_id: user.id, report_run_id: run.id}
    {:ok, entry} = AuditLog.create_entry(Map.merge(base, attrs))
    entry
  end

  test "renders exactly one associated label per filter control, a submit button, caption, scope and aria-live",
       %{conn: conn} do
    admin = user_fixture(%{portal_is_admin: true})
    run = setup_run(admin)
    create_entry(admin, run)

    {:ok, _view, html} = live(log_in_conn(conn, admin), ~p"/reports/audit-log")

    assert count(html, ~s(<label for="export_id")) == 1
    assert count(html, ~s(<label for="remote_endpoint")) == 1
    assert html =~ ~s(<button type="submit")
    assert html =~ ~s(<caption)
    assert html =~ ~s(scope="col")
    assert html =~ ~s(aria-live="polite")
    assert html =~ "Showing 1 event(s)"
  end

  test "the filtered empty-state message differs from the never-recorded one", %{conn: conn} do
    admin = user_fixture(%{portal_is_admin: true})
    {:ok, _view, html} = live(log_in_conn(conn, admin), ~p"/reports/audit-log?export_id=nomatch")

    assert html =~ "No events match the current filter."
    refute html =~ "No data access events have been recorded yet."
  end

  test "filters by export_id and by remote_endpoint through the URL", %{conn: conn} do
    admin = user_fixture(%{portal_is_admin: true})
    run = setup_run(admin)
    bulk_entry(admin, run, %{export_id: "exp-1", endpoint_set: ["re-keep"]})
    bulk_entry(admin, run, %{export_id: "exp-2", endpoint_set: ["re-other"]})

    {:ok, _view, html} = live(log_in_conn(conn, admin), ~p"/reports/audit-log?export_id=exp-1")
    assert html =~ "Showing 1 event(s)"
    assert html =~ "filtered by export id"

    {:ok, _view, html2} = live(log_in_conn(conn, admin), ~p"/reports/audit-log?remote_endpoint=re-keep")
    assert html2 =~ "Showing 1 event(s)"
  end

  test "the data-refocus token changes on a filter change but not on paging", %{conn: conn} do
    admin = user_fixture(%{portal_is_admin: true})
    run = setup_run(admin)
    for _ <- 1..26, do: bulk_entry(admin, run, %{export_id: "exp-1", endpoint_set: ["re-1"]})

    {:ok, _v, base} = live(log_in_conn(conn, admin), ~p"/reports/audit-log")
    {:ok, _v, filtered} = live(log_in_conn(conn, admin), ~p"/reports/audit-log?export_id=exp-1")
    {:ok, _v, paged} = live(log_in_conn(conn, admin), ~p"/reports/audit-log?export_id=exp-1&page=2")

    assert refocus_value(base) != refocus_value(filtered)
    assert refocus_value(filtered) == refocus_value(paged)
  end
end
