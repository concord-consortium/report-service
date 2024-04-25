defmodule ReportServerWeb.Auth.PortalStrategy do
  use OAuth2.Strategy

  # Public API

  def client(portal_url \\ nil) do
    OAuth2.Client.new([
      strategy: __MODULE__,
      client_id: get_client_id(),
      site: portal_url || get_portal_url(),
      authorize_url: "/auth/oauth_authorize",
      redirect_uri: "#{ReportServerWeb.Endpoint.url}/auth/callback"
    ])
  end

  def get_portal_config, do: Application.get_env(:report_server, :portal)

  def get_portal_url() do
    get_portal_config()
    |> Keyword.get(:url, "https://learn.portal.staging.concord.org")
  end

  def get_client_id() do
    get_portal_config()
    |> Keyword.get(:client_id, "research-report-server")
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
