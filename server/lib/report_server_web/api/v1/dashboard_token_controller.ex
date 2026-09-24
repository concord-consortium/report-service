defmodule ReportServerWeb.Api.V1.DashboardTokenController do
  @moduledoc """
  Exchanges rigse's `aud: report-server` assertion for the API token a Researcher Dashboard VM
  pulls with. Everything comes from the verified claims and nothing from the body: the role
  flags decide what `get_allowed_project_ids` returns, so a caller able to name the user or
  the flags could mint a token for any user with any scope.
  """
  use ReportServerWeb, :controller

  alias ReportServer.{Accounts, PortalDbs}
  alias ReportServer.PortalDbs.PortalUserInfo
  alias ReportServerWeb.Api.ErrorHelpers

  def create(conn, _params) do
    claims = conn.assigns.portal_claims
    server = PortalDbs.get_server_for_portal_url(claims["iss"])

    with :ok <- known_portal(server, claims["portal_server"]),
         :ok <- Accounts.claim_assertion_jti(claims["jti"], claims["exp"]),
         {:ok, info} <- portal_user_info(claims, server),
         {:ok, {user, raw_token, api_token}} <- Accounts.mint_dashboard_token(info) do
      conn
      |> put_status(:created)
      |> json(%{token: raw_token, expires_at: api_token.expires_at, user_id: user.id})
    else
      {:error, reason} when reason in [:unknown_portal, :no_jti, :invalid_jti, :invalid_expiry, :replayed] ->
        ErrorHelpers.not_authenticated(conn)

      {:error, message} when is_binary(message) ->
        ErrorHelpers.bad_request(conn, message)

      _ ->
        ErrorHelpers.server_error(conn)
    end
  end

  # The portal is the token's iss, which the signature binds; portal_server must agree, and
  # report-server must be connected to that portal.
  defp known_portal(server, claimed) when is_binary(server) do
    if claimed == server and PortalDbs.has_db_connection?(server), do: :ok, else: {:error, :unknown_portal}
  end

  defp known_portal(_, _), do: {:error, :unknown_portal}

  defp portal_user_info(claims, server) do
    # uid is who /run-package checked the assertion names, so the token must be minted for that user
    with {:ok, id} <- required(claims, "portal_user_id", &(is_integer(&1) and &1 > 0 and &1 == claims["uid"])),
         {:ok, login} <- required_string(claims, "login"),
         {:ok, first_name} <- required_string(claims, "first_name"),
         {:ok, last_name} <- required_string(claims, "last_name"),
         {:ok, email} <- required_string(claims, "email") do
      {:ok,
       %PortalUserInfo{
         id: id,
         server: server,
         login: login,
         first_name: first_name,
         last_name: last_name,
         email: email,
         is_admin: claims["is_admin"] == true,
         is_project_admin: claims["is_project_admin"] == true,
         is_project_researcher: claims["is_project_researcher"] == true
       }}
    end
  end

  # create_user would store a missing field as NULL and update_user's changeset would 500 on it
  defp required_string(claims, key), do: required(claims, key, &(is_binary(&1) and &1 != ""))

  defp required(claims, key, valid?) do
    value = claims[key]
    if valid?.(value), do: {:ok, value}, else: {:error, "the assertion's #{key} claim is missing or invalid"}
  end
end
