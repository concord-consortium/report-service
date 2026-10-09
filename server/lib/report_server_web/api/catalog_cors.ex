defmodule ReportServerWeb.Api.CatalogCors do
  @moduledoc """
  CORS for the catalog's read routes, and only those. The anonymous answer lists official
  packages and may go to any origin. An answer that depends on a bearer lists a researcher's
  private packages, so it goes only to an origin in `:packages, :cors_origins`, or any page
  could read that list with the researcher's token. A request with no `Origin` is not from a
  browser and passes untouched.
  """
  import Plug.Conn

  alias ReportServerWeb.Api.ErrorHelpers

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_req_header(conn, "origin") do
      [] ->
        conn

      [origin | _] ->
        cond do
          conn.method != "OPTIONS" and get_req_header(conn, "authorization") == [] ->
            put_resp_header(conn, "access-control-allow-origin", "*")

          # the anonymous list's JSON POST is preflighted, and its preflight names no authorization
          conn.method == "OPTIONS" and not requests_authorization?(conn) ->
            conn
            |> put_resp_header("access-control-allow-origin", "*")
            |> put_resp_header("access-control-allow-headers", "content-type")
            |> put_resp_header("access-control-allow-methods", "GET, POST")

          origin in allowed_origins() ->
            conn
            |> put_resp_header("access-control-allow-origin", origin)
            |> put_resp_header("vary", "Origin")
            |> put_resp_header("access-control-allow-headers", "authorization, content-type")
            |> put_resp_header("access-control-allow-methods", "GET, POST")

          true ->
            ErrorHelpers.render_error(conn, "FORBIDDEN", "This origin may not read the catalog with a bearer.")
        end
    end
  end

  defp requests_authorization?(conn) do
    conn
    |> get_req_header("access-control-request-headers")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.any?(&(&1 |> String.trim() |> String.downcase() == "authorization"))
  end

  defp allowed_origins, do: Keyword.get(Application.get_env(:report_server, :packages, []), :cors_origins, [])
end
