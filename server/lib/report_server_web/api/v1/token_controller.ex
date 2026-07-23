defmodule ReportServerWeb.Api.V1.TokenController do
  use ReportServerWeb, :controller

  alias ReportServer.Accounts
  alias ReportServerWeb.Auth

  # Both actions run in the token-only pipeline: AuthPlug has verified the bearer but
  # skipped the role gate and the last_used_at touch. report_access carries the role-gate
  # result as data so the CLI can distinguish "valid token, no report access" from 401.
  def show_current(conn, _params) do
    api_token = conn.assigns.api_token
    user = conn.assigns.current_user

    json(conn, %{
      label: api_token.label,
      created_at: DateTime.to_iso8601(api_token.inserted_at),
      last_used_at: api_token.last_used_at && DateTime.to_iso8601(api_token.last_used_at),
      report_access: Auth.can_access_reports?(%{"user" => user})
    })
  end

  # A lost race ({:error, :already_revoked}) is the same success: the token is revoked
  # either way, and a genuinely revoked token cannot reach this action (401 at AuthPlug).
  def delete_current(conn, _params) do
    api_token = conn.assigns.api_token
    user = conn.assigns.current_user

    case Accounts.revoke_api_token(api_token, user.id) do
      {:ok, _revoked} -> json(conn, %{revoked: true})
      {:error, :already_revoked} -> json(conn, %{revoked: true})
    end
  end
end
