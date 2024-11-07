defmodule ReportServerWeb.AuthController do
  use ReportServerWeb, :controller

  require Logger

  alias ReportServer.PortalDbs.PortalUserInfo
  alias ReportServer.Accounts
  alias ReportServer.PortalDbs
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

    portal_url = Auth.get_portal_url(conn)
    portal_server = URI.parse(portal_url).host
    return_to = get_session(conn, :return_to, "/")

    with {:ok, portal_user_info = %PortalUserInfo{}} <- PortalDbs.get_user_info(portal_server, access_token),
         {:ok, user = %Accounts.User{}} = Accounts.find_or_create_user(portal_user_info) do
        conn
          |> Auth.login(portal_url, access_token, expires, user)
          |> delete_session(:return_to)
          |> redirect(to: return_to)

    else
    {:error, error} ->
      Logger.error(error)

      conn
      |> put_flash(:error, "Unable to get your portal user info")
      |> halt()
    end

  end

end
