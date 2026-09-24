defmodule ReportServerWeb.Api.PortalTokenPlug do
  @moduledoc """
  Authenticates a request by a rigse-signed token for one audience, given as
  `audience: "..."`, and assigns its verified claims as `:portal_claims`.
  """
  alias ReportServerWeb.Api.{ErrorHelpers, PortalToken}

  import Plug.Conn

  def init(opts), do: Keyword.fetch!(opts, :audience)

  def call(conn, audience) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, claims} <- PortalToken.verify(token, audience) do
      assign(conn, :portal_claims, claims)
    else
      _ -> ErrorHelpers.not_authenticated(conn)
    end
  end
end
