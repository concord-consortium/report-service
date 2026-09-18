defmodule ReportServerWeb.Api.ServiceAuthPlug do
  @moduledoc """
  Authenticates the portal, not a user.

  The one caller is rigse, asking for a credential on a researcher's behalf after it has
  applied its own class check. That check is the only gate on which classes a researcher
  may analyze, so it stays in the portal and this endpoint does not re-derive it.

  A shared secret rather than a signed token, deliberately: report-server has no JWT
  library, and the alternatives all wanted one plus a change to cc-data, which already
  speaks this API's tokens. The secret authenticates a service and mints nothing by
  itself, so it cannot be used to forge an identity the way a shared signing key could.
  """
  import Plug.Conn

  alias ReportServerWeb.Api.ErrorHelpers

  def init(opts), do: opts

  def call(conn, _opts) do
    with secret when is_binary(secret) and secret != "" <- configured_secret(),
         ["Bearer " <> presented] <- get_req_header(conn, "authorization"),
         true <- Plug.Crypto.secure_compare(presented, secret) do
      conn
    else
      _ -> ErrorHelpers.not_authenticated(conn)
    end
  end

  defp configured_secret do
    Application.get_env(:report_server, :portal_service_secret)
  end
end
