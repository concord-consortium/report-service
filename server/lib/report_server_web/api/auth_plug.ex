defmodule ReportServerWeb.Api.AuthPlug do
  import Plug.Conn

  alias ReportServer.Accounts
  alias ReportServerWeb.Auth
  alias ReportServerWeb.Api.ErrorHelpers

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> raw_token] <- get_req_header(conn, "authorization"),
         {:ok, user, api_token} <- Accounts.verify_api_token(raw_token),
         true <- Auth.can_access_reports?(%{"user" => user}) do
      Accounts.touch_api_token(api_token)
      assign(conn, :current_user, user)
    else
      _ -> ErrorHelpers.not_authenticated(conn)
    end
  end
end
