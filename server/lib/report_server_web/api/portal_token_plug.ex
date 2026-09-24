defmodule ReportServerWeb.Api.PortalTokenPlug do
  @moduledoc """
  Authenticates a request by a rigse-signed token for one audience, given as
  `audience: "..."`, and assigns its verified claims as `:portal_claims`. With `optional: true`
  a request without an `Authorization` header passes unauthenticated, but one with an invalid
  bearer is still refused rather than treated as anonymous.
  """
  alias ReportServerWeb.Api.{ErrorHelpers, PortalToken}

  import Plug.Conn

  def init(opts), do: {Keyword.fetch!(opts, :audience), Keyword.get(opts, :optional, false)}

  def call(conn, {audience, optional}) do
    case get_req_header(conn, "authorization") do
      [] when optional -> conn
      _ -> verify(conn, audience)
    end
  end

  defp verify(conn, audience) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, claims} <- PortalToken.verify(token, audience) do
      assign(conn, :portal_claims, claims)
    else
      _ -> ErrorHelpers.not_authenticated(conn)
    end
  end
end
