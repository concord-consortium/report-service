defmodule ReportServerWeb.Api.ClassReaderPlug do
  @moduledoc """
  Authenticates a class read by either credential that may make one: a report-server API token
  (cc-data, a dashboard VM), checked as `AuthPlug` checks it, or the portal's scoped access token
  carrying `class:researcher-read` (the dashboard page), checked as the catalog checks it. An API
  token is recognized by its prefix; anything else is tried as an access token.
  """
  alias ReportServer.Accounts
  alias ReportServerWeb.Api.{AuthPlug, PortalTokenPlug}

  @access_token PortalTokenPlug.init(capability: "class:researcher-read")
  @api_bearer "Bearer " <> Accounts.api_token_prefix()

  def init(opts), do: opts

  def call(conn, _opts) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      [@api_bearer <> _] -> AuthPlug.call(conn, [])
      _ -> PortalTokenPlug.call(conn, @access_token)
    end
  end
end
