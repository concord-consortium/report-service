defmodule ReportServerWeb.ReportLive.Index do
  use ReportServerWeb, :live_view

  alias ReportServerWeb.Auth
  alias ReportServerWeb.TokenService

  @impl true
  def mount(_params, session, socket) do
    if Auth.logged_in?(session) do
      portal_credentials = Auth.get_portal_credentials(session)

      {:ok,
      socket
        # assign the session vars for the login/logout links
        |> assign(Auth.public_session_vars(session))
        # get the aws data from the token service via async (the fn is wrapped in a task)
        |> assign_async(:aws_data, fn -> TokenService.get_aws_data(portal_credentials) end)
      }
    else
      {:ok, redirect(socket, to: ~p"/auth/login?return_to=/reports")}
    end
  end

  @impl true
  def handle_params(_params, _url, socket) do
    socket =
      socket
      |> assign(:page_title, "Your Reports")

    {:noreply, socket}
  end
end
