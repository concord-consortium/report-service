defmodule ReportServer.Accounts do
  import Ecto.Query, warn: false

  alias ReportServer.Repo
  alias ReportServer.Accounts.ApiToken
  alias ReportServer.Accounts.User
  alias ReportServer.PortalDbs.PortalUserInfo

  @api_token_prefix "ccd_"
  @api_token_bytes 32
  @touch_threshold_seconds 60

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
      is_project_admin: is_project_admin,
      is_project_researcher: is_project_researcher,
      server: server
    } = portal_user_info

    %User{
      portal_server: server,
      portal_user_id: id,
      portal_login: login,
      portal_first_name: first_name,
      portal_last_name: last_name,
      portal_email: email,
      portal_is_admin: is_admin,
      portal_is_project_admin: is_project_admin,
      portal_is_project_researcher: is_project_researcher,
    } |> Repo.insert()
  end

  defp update_user(user = %User{}, portal_user_info = %PortalUserInfo{}) do
    %{
      login: login,
      first_name: first_name,
      last_name: last_name,
      email: email,
      is_admin: is_admin,
      is_project_admin: is_project_admin,
      is_project_researcher: is_project_researcher,
    } = portal_user_info

    user |> User.changeset(%{
      portal_login: login,
      portal_first_name: first_name,
      portal_last_name: last_name,
      portal_email: email,
      portal_is_admin: is_admin,
      portal_is_project_admin: is_project_admin,
      portal_is_project_researcher: is_project_researcher,
    })
    |> Repo.update()
  end

  @doc """
  Mints an API token for a user. The raw token is returned exactly once — only its
  SHA-256 hash is stored, so it cannot be recovered afterwards.
  """
  def create_api_token(user = %User{}, label \\ nil) do
    raw_token = @api_token_prefix <> Base.url_encode64(:crypto.strong_rand_bytes(@api_token_bytes), padding: false)

    result =
      %ApiToken{}
      |> ApiToken.changeset(%{user_id: user.id, token_hash: hash_api_token(raw_token), label: label})
      |> Repo.insert()

    case result do
      {:ok, api_token} -> {:ok, raw_token, api_token}
      {:error, changeset} -> {:error, changeset}
    end
  end

  def verify_api_token(raw_token) when is_binary(raw_token) do
    query = from t in ApiToken,
      where: t.token_hash == ^hash_api_token(raw_token),
      where: is_nil(t.revoked_at),
      preload: [:user]

    case Repo.one(query) do
      nil -> :error
      api_token -> {:ok, api_token.user, api_token}
    end
  end
  def verify_api_token(_), do: :error

  def revoke_api_token(api_token = %ApiToken{}) do
    api_token
    |> ApiToken.changeset(%{revoked_at: DateTime.utc_now(:second)})
    |> Repo.update()
  end

  @doc """
  Marks a token as recently used. Thresholded to avoid a row UPDATE per request from a
  polling CLI — the freshness marker is only read at "used recently" granularity.
  """
  def touch_api_token(api_token = %ApiToken{}) do
    now = DateTime.utc_now(:second)

    if api_token.last_used_at == nil ||
         DateTime.diff(now, api_token.last_used_at) >= @touch_threshold_seconds do
      api_token
      |> ApiToken.changeset(%{last_used_at: now})
      |> Repo.update()
    else
      {:ok, api_token}
    end
  end

  defp hash_api_token(raw_token) do
    :crypto.hash(:sha256, raw_token) |> Base.encode16(case: :lower)
  end
end
