defmodule ReportServerWeb.Api.AuthPlug do
  import Plug.Conn

  alias ReportServer.Accounts
  alias ReportServerWeb.Auth
  alias ReportServerWeb.Api.ErrorHelpers

  def init(opts), do: opts

  # token_only: true authenticates by token validity alone — no role gate, so a
  # de-provisioned user can still manage their own credential, and no last_used_at touch,
  # so a status check never overwrites the signal it reports.
  def call(conn, opts) do
    token_only = Keyword.get(opts, :token_only, false)

    with ["Bearer " <> raw_token] <- get_req_header(conn, "authorization"),
         {:ok, user, api_token} <- Accounts.verify_api_token(raw_token),
         true <- token_only || Auth.can_access_reports?(%{"user" => user}) do
      if !token_only do
        Accounts.touch_api_token(api_token)
      end

      conn
      |> assign(:current_user, user)
      |> assign(:api_token, api_token)
    else
      _ -> ErrorHelpers.not_authenticated(conn)
    end
  end
end
