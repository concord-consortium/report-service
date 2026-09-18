defmodule ReportServerWeb.Api.V1.DashboardTokenController do
  @moduledoc """
  Mints and revokes the API token a Researcher Dashboard MicroVM pulls with.

  The portal sends the researcher's own user info, which it is authoritative about, so
  no portal-database lookup happens on this path and the role flags are as fresh as the
  portal's rather than as fresh as this user's last sign-in here.
  """
  use ReportServerWeb, :controller

  alias ReportServer.Accounts
  alias ReportServer.PortalDbs.PortalUserInfo

  # Minting revokes the researcher's previous dashboard token, so one is live at a time
  # and a copy that leaked from an earlier VM stops working at the next launch.
  def create(conn, params) do
    with {:ok, info} <- portal_user_info(params),
         {:ok, user, raw_token, api_token} <- Accounts.mint_dashboard_token(info) do
      conn
      |> put_status(:created)
      |> json(%{
        token: raw_token,
        label: api_token.label,
        user_id: user.id,
        portal_user_id: user.portal_user_id
      })
    else
      {:error, :invalid_params, message} -> bad_request(conn, message)
      _ -> bad_request(conn, "could not mint a dashboard token")
    end
  end

  # Called when a VM terminates, so the credential dies with the VM rather than living
  # until the researcher's next launch.
  def delete(conn, params) do
    with {:ok, info} <- portal_user_info(params),
         {:ok, user} <- Accounts.find_or_create_user(info),
         {:ok, revoked} <- Accounts.revoke_dashboard_tokens(user) do
      json(conn, %{revoked: revoked})
    else
      {:error, :invalid_params, message} -> bad_request(conn, message)
      _ -> bad_request(conn, "could not revoke dashboard tokens")
    end
  end

  defp portal_user_info(params) do
    with {:ok, id} <- required_integer(params, "portal_user_id"),
         {:ok, server} <- required_string(params, "portal_server") do
      {:ok,
       %PortalUserInfo{
         id: id,
         server: server,
         login: params["login"],
         first_name: params["first_name"],
         last_name: params["last_name"],
         email: params["email"],
         # The portal is authoritative about its own users, and these are what
         # get_allowed_project_ids branches on. Taking them from the caller keeps them
         # current, where this server's own copy is only as fresh as the user's last
         # sign-in here.
         is_admin: !!params["is_admin"],
         is_project_admin: !!params["is_project_admin"],
         is_project_researcher: !!params["is_project_researcher"]
       }}
    end
  end

  defp required_integer(params, key) do
    case params[key] do
      value when is_integer(value) -> {:ok, value}
      value when is_binary(value) ->
        case Integer.parse(value) do
          {int, ""} -> {:ok, int}
          _ -> {:error, :invalid_params, "#{key} must be an integer"}
        end
      _ -> {:error, :invalid_params, "#{key} is required"}
    end
  end

  defp required_string(params, key) do
    case params[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :invalid_params, "#{key} is required"}
    end
  end

  defp bad_request(conn, message) do
    conn |> put_status(:bad_request) |> json(%{error: message})
  end
end
