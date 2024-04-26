defmodule ReportServerWeb.Auth.PortalStrategy do
  use OAuth2.Strategy

  # Public API

  def client(portal_url \\ nil) do
    portal = Application.get_env(:report_server, :portal)

    OAuth2.Client.new([
      strategy: __MODULE__,
      client_id: Keyword.get(portal, :client_id, "research-report-server"),
      site: portal_url || Keyword.get(portal, :url, "https://learn.portal.staging.concord.org"),
      authorize_url: "/auth/oauth_authorize",
      redirect_uri: "#{ReportServerWeb.Endpoint.url}/auth/callback"
    ])
  end

  # normally the oauth strategy pattern is to use authorize_url!/0 for the custom callback but we need to pass the portal url
  # so we need to rename this function so that it does not conflict with authorize_url!/1 imported from OAuth2.Strategy
  def get_authorize_url(portal_url \\ nil) do
    authorize_url!(client(portal_url))
  end

  # Strategy Callbacks

  def authorize_url(client, params) do
    client
    |> put_param(:response_type, "token")
    |> put_param(:client_id, client.client_id)
    |> put_param(:redirect_uri, client.redirect_uri)
    |> merge_params(params)
  end

  # this isn't used by the portal but the OAuth2.Strategy behavior requires it to be defined
  def get_token(client, params, headers) do
    client
    |> put_header("accept", "application/json")
    |> OAuth2.Strategy.AuthCode.get_token(params, headers)
  end
end
