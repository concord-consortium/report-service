defmodule ReportServerWeb.AuthCliController do
  use ReportServerWeb, :controller

  alias ReportServer.Accounts
  alias ReportServerWeb.Api.ErrorHelpers

  def token(conn, _params) do
    query_secrets? =
      Map.has_key?(conn.query_params, "code") or Map.has_key?(conn.query_params, "code_verifier")

    case {query_secrets?, conn.body_params} do
      {false, %{"code" => code, "code_verifier" => code_verifier}}
      when is_binary(code) and is_binary(code_verifier) ->
        case Accounts.exchange_auth_grant(code, code_verifier) do
          {:ok, raw_token, _api_token} ->
            json(conn, %{token: raw_token})

          _ ->
            ErrorHelpers.bad_request(conn, "Invalid code or verifier.")
        end

      _ ->
        ErrorHelpers.bad_request(conn, "Invalid code or verifier.")
    end
  end
end
