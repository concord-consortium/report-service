defmodule ReportServerWeb.AuthController do
  use ReportServerWeb, :controller

  alias ReportServerWeb.Auth
  alias ReportServerWeb.Auth.PortalStrategy

  def login(conn, params) do
    portal_url = Auth.get_portal_url(conn)

    conn
    |> put_session(:return_to, Map.get(params, "return_to", "/"))
    |> redirect(external: PortalStrategy.get_authorize_url(portal_url))
  end

  def logout(conn, _params) do
    conn
    |> Auth.logout()
    |> redirect(to: ~p"/")
  end

  def save_token(conn, %{"access_token" => access_token, "expires_in" => expires_in}) do
    {expires_in, ""} = Integer.parse(expires_in)
    expires = System.os_time(:second) + expires_in

    return_to = get_session(conn, :return_to, "/")

    conn
    |> Auth.login(access_token, expires)
    |> delete_session(:return_to)
    |> redirect(to: return_to)
  end

end
