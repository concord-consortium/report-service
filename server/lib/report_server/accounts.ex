defmodule ReportServer.Accounts do
  import Ecto.Query, warn: false

  alias ReportServer.Repo
  alias ReportServer.Accounts.User
  alias ReportServer.PortalDbs.PortalUserInfo

  def find_or_create_user(portal_user_info = %PortalUserInfo{}) do
    query = from u in User,
      where: u.portal_server == ^portal_user_info.server,
      where: u.portal_user_id == ^portal_user_info.id

    case Repo.one(query) do
      nil -> create_user(portal_user_info)
      user -> update_user(user, portal_user_info)
    end
  end

  defp create_user(portal_user_info = %PortalUserInfo{}) do
    %{
      id: id,
      login: login,
      first_name: first_name,
      last_name: last_name,
      email: email,
      is_admin: is_admin,
      server: server
    } = portal_user_info

    %User{
      portal_server: server,
      portal_user_id: id,
      portal_login: login,
      portal_first_name: first_name,
      portal_last_name: last_name,
      portal_email: email,
      portal_is_admin: !!is_admin
    } |> Repo.insert()
  end

  defp update_user(user = %User{}, portal_user_info = %PortalUserInfo{}) do
    %{
      login: login,
      first_name: first_name,
      last_name: last_name,
      email: email,
      is_admin: is_admin,
    } = portal_user_info

    user |> User.changeset(%{
      portal_login: login,
      portal_first_name: first_name,
      portal_last_name: last_name,
      portal_email: email,
      portal_is_admin: !!is_admin
    })
    |> Repo.update()
  end

end
