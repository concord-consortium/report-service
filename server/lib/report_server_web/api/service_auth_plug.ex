defmodule ReportServerWeb.Api.ServiceAuthPlug do
  @moduledoc """
  Authenticates the portal, not a user, and carries the user the portal is acting for.

  The one caller is rigse, asking for a credential on a researcher's behalf after it has
  applied its own class check. That check is the only gate on which classes a researcher
  may analyze, so it stays in the portal and this endpoint does not re-derive it.

  The credential is a short-lived assertion the portal signs, and the user information is
  read from its verified claims rather than from the request body. That is what makes the
  endpoint safe to reach through a relay: this endpoint's role flags decide what the
  minted token can read, since `get_allowed_project_ids` returns every project for a site
  admin, so a caller able to set them could mint a token for any user at any scope. Signed
  claims can be carried but not edited or re-aimed. It also keeps the shared secret a
  verification key that never travels on a request.
  """
  import Plug.Conn

  alias ReportServerWeb.Api.ErrorHelpers
  alias ReportServerWeb.Api.PortalAssertion

  def init(opts), do: opts

  def call(conn, _opts) do
    with secret when is_binary(secret) and secret != "" <- configured_secret(),
         ["Bearer " <> assertion] <- get_req_header(conn, "authorization"),
         {:ok, claims} <- PortalAssertion.verify(assertion, secret) do
      assign(conn, :portal_claims, claims)
    else
      _ -> ErrorHelpers.not_authenticated(conn)
    end
  end

  defp configured_secret do
    Application.get_env(:report_server, :portal_service_secret)
  end
end
