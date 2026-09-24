defmodule ReportServer.Accounts do
  import Ecto.Query, warn: false

  alias ReportServer.Repo
  alias ReportServer.Pagination
  alias ReportServer.Accounts.ApiToken
  alias ReportServer.Accounts.AuthGrant
  alias ReportServer.Accounts.UsedPortalAssertion
  alias ReportServer.Accounts.User
  alias ReportServer.PortalDbs.PortalUserInfo

  @api_token_prefix "ccd_"
  @api_token_bytes 32
  @touch_threshold_seconds 60
  @auth_grant_ttl_seconds 5 * 60
  @dashboard_token_label "researcher-dashboard"
  # Just past the eight-hour maximum life of the VM that holds it: nothing revokes the token
  # of a VM that dies without running its terminate hook.
  @dashboard_token_ttl_seconds 9 * 60 * 60

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
  SHA-256 hash is stored, so it cannot be recovered afterwards. `expires_in:` (seconds) sets
  an expiry; without it the token lives until revoked.
  """
  def create_api_token(user = %User{}, label \\ nil, opts \\ []) do
    raw_token = @api_token_prefix <> Base.url_encode64(:crypto.strong_rand_bytes(@api_token_bytes), padding: false)

    expires_at =
      case Keyword.get(opts, :expires_in) do
        nil -> nil
        seconds when is_integer(seconds) -> DateTime.utc_now(:second) |> DateTime.add(seconds)
      end

    result =
      %ApiToken{}
      |> ApiToken.changeset(%{user_id: user.id, token_hash: hash_secret(raw_token), label: label, expires_at: expires_at})
      |> Repo.insert()

    case result do
      {:ok, api_token} -> {:ok, raw_token, api_token}
      {:error, changeset} -> {:error, changeset}
    end
  end

  def dashboard_token_label, do: @dashboard_token_label

  @doc """
  Mints the API token a Researcher Dashboard VM pulls with, as the researcher themselves.
  Finds or creates the user from the portal's claims, revokes their live dashboard tokens so
  one is live at a time, and mints one expiring in nine hours. Returns
  `{:ok, {user, raw_token, api_token}}`.
  """
  def mint_dashboard_token(portal_user_info = %PortalUserInfo{}) do
    Repo.transaction(fn ->
      with {:ok, user} <- find_or_create_user(portal_user_info),
           {:ok, _count} <- revoke_dashboard_tokens(user),
           {:ok, raw_token, api_token} <-
             create_api_token(user, @dashboard_token_label, expires_in: @dashboard_token_ttl_seconds) do
        {user, raw_token, api_token}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Revokes every live dashboard token the user holds, attributed to the user themselves since
  no operator asked for it.
  """
  def revoke_dashboard_tokens(user = %User{}) do
    now = DateTime.utc_now(:second)

    query =
      from t in live_api_tokens(),
        where: t.user_id == ^user.id and t.label == ^@dashboard_token_label

    {count, _} = Repo.update_all(query, set: [revoked_at: now, revoked_by_user_id: user.id, updated_at: now])
    {:ok, count}
  end

  @doc """
  Records a portal assertion's jti, or refuses one already used. The unique index makes the
  insert the check, so it holds across restarts and more than one node. Expired rows are
  pruned first; they could never match a live assertion again.
  """
  def claim_assertion_jti(jti, exp) when is_binary(jti) and jti != "" and is_integer(exp) do
    now = DateTime.utc_now(:second)
    Repo.delete_all(from u in UsedPortalAssertion, where: u.expires_at < ^now)

    %UsedPortalAssertion{}
    |> UsedPortalAssertion.changeset(%{jti: jti, expires_at: DateTime.from_unix!(exp)})
    |> Repo.insert()
    |> case do
      {:ok, _} ->
        :ok

      {:error, changeset} ->
        case changeset.errors[:jti] do
          {_message, opts} -> if opts[:constraint] == :unique, do: {:error, :replayed}, else: {:error, :invalid_jti}
          nil -> {:error, :invalid_jti}
        end
    end
  end

  def claim_assertion_jti(_, _), do: {:error, :no_jti}

  def verify_api_token(raw_token) when is_binary(raw_token) do
    query = from t in live_api_tokens(),
      where: t.token_hash == ^hash_secret(raw_token),
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
      from t in live_api_tokens(),
        where: t.user_id == ^user_id,
        order_by: [desc: t.inserted_at, desc: t.id]
    )
  end

  def get_user_api_token(id, user_id) do
    Repo.one(
      from t in live_api_tokens(),
        where: t.id == ^id and t.user_id == ^user_id
    )
  end

  def get_active_api_token(id) do
    Repo.one(from t in live_api_tokens(), where: t.id == ^id)
  end

  def list_all_active_api_tokens(page) do
    from(t in live_api_tokens(),
      order_by: [desc: t.inserted_at, desc: t.id],
      preload: [:user]
    )
    |> Pagination.paginate(page)
  end

  defp live_api_tokens do
    now = DateTime.utc_now(:second)
    from t in ApiToken, where: is_nil(t.revoked_at) and (is_nil(t.expires_at) or t.expires_at > ^now)
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
  An optional `label` overrides the default `"CLI login"` token label.
  """
  def exchange_auth_grant(raw_code, code_verifier, label \\ nil)

  def exchange_auth_grant(raw_code, code_verifier, label) when is_binary(raw_code) and is_binary(code_verifier) do
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
          create_api_token(auth_grant.user, label || "CLI login")
        else
          :error
        end

      _ ->
        :error
    end
  end
  def exchange_auth_grant(_, _, _), do: :error

  defp pkce_verifier_matches?(code_challenge, code_verifier) do
    computed = :crypto.hash(:sha256, code_verifier) |> Base.url_encode64(padding: false)
    Plug.Crypto.secure_compare(computed, code_challenge)
  end

  defp hash_secret(raw_secret) do
    :crypto.hash(:sha256, raw_secret) |> Base.encode16(case: :lower)
  end
end
