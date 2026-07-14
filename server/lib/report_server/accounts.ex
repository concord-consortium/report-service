defmodule ReportServer.Accounts do
  import Ecto.Query, warn: false

  alias ReportServer.Repo
  alias ReportServer.Pagination
  alias ReportServer.Accounts.ApiToken
  alias ReportServer.Accounts.AuthGrant
  alias ReportServer.Accounts.User
  alias ReportServer.PortalDbs.PortalUserInfo

  @api_token_prefix "ccd_"
  @api_token_bytes 32
  @touch_threshold_seconds 60
  @auth_grant_ttl_seconds 5 * 60

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
      |> ApiToken.changeset(%{user_id: user.id, token_hash: hash_secret(raw_token), label: label})
      |> Repo.insert()

    case result do
      {:ok, api_token} -> {:ok, raw_token, api_token}
      {:error, changeset} -> {:error, changeset}
    end
  end

  def verify_api_token(raw_token) when is_binary(raw_token) do
    query = from t in ApiToken,
      where: t.token_hash == ^hash_secret(raw_token),
      where: is_nil(t.revoked_at),
      preload: [:user]

    case Repo.one(query) do
      nil -> :error
      api_token -> {:ok, api_token.user, api_token}
    end
  end
  def verify_api_token(_), do: :error

  def revoke_api_token(api_token = %ApiToken{}, revoked_by_user_id) when is_integer(revoked_by_user_id) do
    now = DateTime.utc_now(:second)

    revoke_query =
      from t in ApiToken, where: t.id == ^api_token.id and is_nil(t.revoked_at)

    case Repo.update_all(revoke_query,
           set: [revoked_at: now, revoked_by_user_id: revoked_by_user_id, updated_at: now]) do
      {1, _} -> {:ok, Repo.get!(ApiToken, api_token.id)}
      {0, _} -> {:error, :already_revoked}
    end
  end

  def list_active_api_tokens(user_id) do
    Repo.all(
      from t in ApiToken,
        where: t.user_id == ^user_id and is_nil(t.revoked_at),
        order_by: [desc: t.inserted_at, desc: t.id]
    )
  end

  def get_user_api_token(id, user_id) do
    Repo.one(
      from t in ApiToken,
        where: t.id == ^id and t.user_id == ^user_id and is_nil(t.revoked_at)
    )
  end

  def get_active_api_token(id) do
    Repo.one(from t in ApiToken, where: t.id == ^id and is_nil(t.revoked_at))
  end

  def list_all_active_api_tokens(page) do
    from(t in ApiToken,
      where: is_nil(t.revoked_at),
      order_by: [desc: t.inserted_at, desc: t.id],
      preload: [:user]
    )
    |> Pagination.paginate(page)
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

  @doc """
  Creates a pending authorization grant for the CLI loopback flow. The raw code is returned
  exactly once — only its SHA-256 hash is stored — and expires in 5 minutes.
  """
  def create_auth_grant(user = %User{}, code_challenge, portal_url) do
    raw_code = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    expires_at = DateTime.utc_now(:second) |> DateTime.add(@auth_grant_ttl_seconds)

    result =
      %AuthGrant{}
      |> AuthGrant.changeset(%{
        user_id: user.id,
        code_hash: hash_secret(raw_code),
        code_challenge: code_challenge,
        portal_url: portal_url,
        expires_at: expires_at
      })
      |> Repo.insert()

    case result do
      {:ok, auth_grant} -> {:ok, raw_code, auth_grant}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Exchanges a one-time code for an API token. Consuming the code is an atomic conditional
  UPDATE — exactly one exchange of a given code can get `{1, _}` back — so concurrent
  duplicates cannot both mint. Unknown, expired, used, and verifier-mismatch all return
  `:error`. A verifier mismatch still consumes the code (burning an exposed code).
  """
  def exchange_auth_grant(raw_code, code_verifier) when is_binary(raw_code) and is_binary(code_verifier) do
    now = DateTime.utc_now(:second)
    code_hash = hash_secret(raw_code)

    consume_query = from g in AuthGrant,
      where: g.code_hash == ^code_hash,
      where: is_nil(g.used_at),
      where: g.expires_at > ^now

    case Repo.update_all(consume_query, set: [used_at: now]) do
      {1, _} ->
        auth_grant = Repo.one!(from g in AuthGrant, where: g.code_hash == ^code_hash, preload: [:user])

        if pkce_verifier_matches?(auth_grant.code_challenge, code_verifier) do
          create_api_token(auth_grant.user, "CLI login")
        else
          :error
        end

      _ ->
        :error
    end
  end
  def exchange_auth_grant(_, _), do: :error

  defp pkce_verifier_matches?(code_challenge, code_verifier) do
    computed = :crypto.hash(:sha256, code_verifier) |> Base.url_encode64(padding: false)
    Plug.Crypto.secure_compare(computed, code_challenge)
  end

  defp hash_secret(raw_secret) do
    :crypto.hash(:sha256, raw_secret) |> Base.encode16(case: :lower)
  end
end
