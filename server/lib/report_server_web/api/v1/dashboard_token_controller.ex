defmodule ReportServerWeb.Api.V1.DashboardTokenController do
  @moduledoc """
  Mints and revokes the API token a Researcher Dashboard MicroVM pulls with.

  The portal signs the researcher's own user info into a short-lived assertion, which it
  is authoritative about, so no portal-database lookup happens on this path and the role
  flags are as fresh as the portal's rather than as fresh as this user's last sign-in
  here. Reading them from verified claims rather than from the request body is what lets
  the assertion be relayed by the launch function without that function being able to
  choose the user or the flags.
  """
  use ReportServerWeb, :controller

  alias ReportServer.Accounts
  alias ReportServer.PortalDbs.PortalUserInfo

  # Minting revokes the researcher's previous dashboard token, so one is live at a time
  # and a copy that leaked from an earlier VM stops working at the next launch.
  def create(conn, _params) do
    with {:ok, info} <- portal_user_info(conn),
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
  def delete(conn, _params) do
    with {:ok, info} <- portal_user_info(conn),
         {:ok, user} <- Accounts.find_or_create_user(info),
         {:ok, revoked} <- Accounts.revoke_dashboard_tokens(user) do
      json(conn, %{revoked: revoked})
    else
      {:error, :invalid_params, message} -> bad_request(conn, message)
      _ -> bad_request(conn, "could not revoke dashboard tokens")
    end
  end

  # From the assertion's verified claims, never from the request body. These are what
  # get_allowed_project_ids branches on, so a caller that could set them could mint a
  # token scoped to every project at Concord for any user it named.
  defp portal_user_info(%{assigns: %{portal_claims: claims}}) do
    with {:ok, id} <- required_integer(claims, "portal_user_id"),
         {:ok, server} <- required_string(claims, "portal_server") do
      {:ok,
       %PortalUserInfo{
         id: id,
         server: server,
         login: claims["login"],
         first_name: claims["first_name"],
         last_name: claims["last_name"],
         email: claims["email"],
         is_admin: !!claims["is_admin"],
         is_project_admin: !!claims["is_project_admin"],
         is_project_researcher: !!claims["is_project_researcher"]
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
