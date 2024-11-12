defmodule ReportServerWeb.PageControllerTest do
  use ReportServerWeb.ConnCase

  test "GET /config", %{conn: conn} do
    conn = get(conn, ~p"/config")
    assert html_response(conn, 200) =~ "Config Info"
  end
end
