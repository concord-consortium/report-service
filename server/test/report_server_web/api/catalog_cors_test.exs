defmodule ReportServerWeb.Api.CatalogCorsTest do
  use ReportServerWeb.ConnCase, async: false

  import ReportServerWeb.PortalTokenFixture

  alias ReportServer.PackagesPortalStub

  @allowed "https://researcher-dashboard.concord.org"
  @db_env "LEARN_PORTAL_STAGING_CONCORD_ORG_DB"

  setup do
    previous_db = System.get_env(@db_env)
    System.put_env(@db_env, "mysql://user:pass@localhost:3306")
    install!()
    PackagesPortalStub.set(%{})
    packages_config = Application.get_env(:report_server, :packages)
    Application.put_env(:report_server, :packages, Keyword.put(packages_config, :cors_origins, [@allowed]))

    on_exit(fn ->
      if previous_db, do: System.put_env(@db_env, previous_db), else: System.delete_env(@db_env)
      Application.put_env(:report_server, :packages, packages_config)
      PackagesPortalStub.reset()
    end)
  end

  defp launch_token, do: sign(:staging, claims(:staging, "researcher-dashboard"))
  defp from(conn, origin), do: put_req_header(conn, "origin", origin)
  defp bearer(conn), do: put_req_header(conn, "authorization", "Bearer #{launch_token()}")
  defp header(conn, name), do: get_resp_header(conn, name)

  test "an anonymous read from any origin is answered to every origin", %{conn: conn} do
    conn = conn |> from("https://anywhere.example") |> get("/api/v1/packages?portal=learn.concord.org")
    assert json_response(conn, 200)
    assert header(conn, "access-control-allow-origin") == ["*"]
    assert header(conn, "cache-control") != ["no-store"]
  end

  test "a bearer read from an allowlisted origin echoes it, varies on it, and is not cached", %{conn: conn} do
    conn = conn |> from(@allowed) |> bearer() |> get("/api/v1/packages")
    assert json_response(conn, 200)
    assert header(conn, "access-control-allow-origin") == [@allowed]
    assert header(conn, "vary") == ["Origin"]
    assert header(conn, "cache-control") == ["no-store"]
  end

  test "a bearer read from another origin is refused before any lookup", %{conn: conn} do
    PackagesPortalStub.set(%{user_roles: fn _, _ -> raise "looked up" end})
    conn = conn |> from("https://evil.example") |> bearer() |> get("/api/v1/packages")
    assert %{"error" => "FORBIDDEN"} = json_response(conn, 403)
    assert header(conn, "access-control-allow-origin") == []
  end

  test "a request with no Origin is not origin-checked", %{conn: conn} do
    conn = conn |> bearer() |> get("/api/v1/packages")
    assert json_response(conn, 200)
    assert header(conn, "access-control-allow-origin") == []
  end

  test "a preflight is answered for an allowlisted origin only", %{conn: conn} do
    for path <- ["/api/v1/packages", "/api/v1/packages/resolve"] do
      conn =
        build_conn()
        |> from(@allowed)
        |> put_req_header("access-control-request-method", "GET")
        |> put_req_header("access-control-request-headers", "authorization")
        |> options(path)

      assert conn.status == 204
      assert header(conn, "access-control-allow-origin") == [@allowed]
      assert header(conn, "access-control-allow-headers") == ["authorization"]
      assert header(conn, "access-control-allow-methods") == ["GET"]
    end

    assert %{"error" => "FORBIDDEN"} = json_response(conn |> from("https://evil.example") |> options("/api/v1/packages"), 403)
  end

  test "no other API route gains CORS", %{conn: conn} do
    conn = conn |> from(@allowed) |> get("/api/v1/reports")
    assert header(conn, "access-control-allow-origin") == []
    assert build_conn() |> from(@allowed) |> options("/api/v1/reports") |> Map.fetch!(:status) == 404
  end
end
