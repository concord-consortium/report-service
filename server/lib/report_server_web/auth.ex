defmodule ReportServerWeb.Auth do
  import Plug.Conn

  alias ReportServerWeb.Auth.PortalStrategy

  def logged_in?(_session = %{"access_token" => _access_token, "expires" => expires}) do
    now = System.os_time(:second)
    # give ourselves 1 hour padding
    expires > now + 60*60
  end
  def logged_in?(_session), do: false

  def login(conn, portal_url, access_token, expires) do
    conn
    |> put_session(:portal_url, portal_url)
    |> put_session(:access_token, access_token)
    |> put_session(:expires, expires)
    |> configure_session(renew: true)
  end

  def logout(conn) do
    conn
    |> clear_session()
    |> configure_session(renew: true)
  end

  def public_session_vars(session) do
    [logged_in: logged_in?(session), portal_domain: portal_domain(session)]
  end

  def save_portal_url(conn) do
    portal = conn.params["portal"]
    if portal do
      conn |> put_session(:portal_url, portal)
    else
      conn
    end
  end

  def get_portal_url(conn) do
    conn |> get_session(:portal_url, PortalStrategy.get_portal_url())
  end

  def get_portal_credentials(%{"access_token" => access_token, "portal_url" => portal_url}) do
    %{access_token:  access_token, portal_url: portal_url}
  end
  def get_portal_credentials(_), do: nil

  def portal_domain(%{"portal_url" => portal_url}) do
    portal_url
    |> URI.parse()
    |> Map.get(:host)
  end
  def portal_domain(_), do: nil

end
