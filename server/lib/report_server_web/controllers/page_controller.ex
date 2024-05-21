defmodule ReportServerWeb.PageController do
  use ReportServerWeb, :controller

  alias ReportServerWeb.{Auth, TokenService}


  def home(conn, _params) do
    # The home page is often custom made,
    # so skip the default app layout.
    render(conn, :home, page_title: "Home")
  end

  def config(conn, _params) do
    session = get_session(conn)
    if Auth.logged_in?(session) do
      portal = Application.get_env(:report_server, :portal) |> Enum.into(%{})
      token_service = Application.get_env(:report_server, :token_service) |> Enum.into(%{})
      output = Application.get_env(:report_server, :output) |> Enum.into(%{})
      report_service_url = Application.get_env(:report_server, :report_service) |> Keyword.get(:url)

      portal_credentials = Auth.get_portal_credentials(session)
      {:ok, token_service_env} = TokenService.get_env("prod", portal_credentials)

      config = %{
        portal: portal,
        token_service: token_service,
        output: output,
        report_service_url: report_service_url,
        token_service_env: token_service_env,
        full_token_service_url: TokenService.get_token_service_url(token_service_env)
      }
      render(conn, :config, page_title: "Config", config: config, error: nil)
    else
      render(conn, :config, page_title: "Config", error: "To get the config you first need to login.")
    end
  end
end
