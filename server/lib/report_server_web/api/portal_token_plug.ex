defmodule ReportServerWeb.Api.PortalTokenPlug do
  @moduledoc """
  Authenticates a request by a rigse-signed token and assigns its verified claims as
  `:portal_claims`. `audience: "..."` takes an assertion addressed to that one audience;
  `capability: "..."` takes a scoped access token that names this deployment and carries that
  capability. With `optional: true` a request without an `Authorization` header passes
  unauthenticated, but one with an invalid bearer is still refused rather than treated as
  anonymous.
  """
  alias ReportServerWeb.Api.{ErrorHelpers, PortalToken}

  import Plug.Conn

  def init(opts) do
    optional = Keyword.get(opts, :optional, false)

    case {Keyword.get(opts, :audience), Keyword.get(opts, :capability)} do
      {audience, nil} when is_binary(audience) -> {{:assertion, audience}, optional}
      {nil, capability} when is_binary(capability) -> {{:access_token, capability}, optional}
    end
  end

  def call(conn, {credential, optional}) do
    case get_req_header(conn, "authorization") do
      [] when optional -> conn
      _ -> verify(conn, credential)
    end
  end

  defp verify(conn, credential) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, claims} <- check(credential, token) do
      assign(conn, :portal_claims, claims)
    else
      _ -> ErrorHelpers.not_authenticated(conn)
    end
  end

  defp check({:assertion, audience}, token), do: PortalToken.verify(token, audience)

  defp check({:access_token, capability}, token),
    do: PortalToken.verify_access_token(token, PortalToken.access_token_audience(), capability)
end
