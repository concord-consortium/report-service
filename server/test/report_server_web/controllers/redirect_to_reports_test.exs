defmodule ReportServerWeb.RedirectToReportsTest do
  use ReportServerWeb.ConnCase

  describe "GET /old-reports" do
    test "redirects the bare path to /reports", %{conn: conn} do
      conn = get(conn, "/old-reports")
      assert redirected_to(conn) == "/reports"
    end

    test "redirects a sub-path to the matching /reports path", %{conn: conn} do
      conn = get(conn, "/old-reports/foo/bar")
      assert redirected_to(conn) == "/reports/foo/bar"
    end
  end
end
