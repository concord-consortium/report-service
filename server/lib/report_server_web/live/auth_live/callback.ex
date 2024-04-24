defmodule ReportServerWeb.AuthLive.Callback do
  use ReportServerWeb, :live_view

  alias ReportServerWeb.Auth

  @impl true
  def mount(_params, session, socket) do
    # assign the session vars for the login/logout links
    {:ok, assign(socket, Auth.public_session_vars(session))}
  end

  @impl true
  def handle_params(params, _url, socket) do
    socket = socket
      |> assign(:page_title, "OAuth Callback")
      |> assign(:error, params["error"])

    {:noreply, socket}
  end

  @impl true
  def handle_event("save_token", %{"access_token" => access_token, "expires_in" => expires_in}, socket) do
    # need to redirect to a regular controller so the token can be saved in the session
    {:noreply, redirect(socket, to: ~p"/auth/save_token?access_token=#{access_token}&expires_in=#{expires_in}")}
  end
end
