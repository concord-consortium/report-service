defmodule ReportServerWeb.ReportLive.Index do
  use ReportServerWeb, :live_view

  alias ReportServerWeb.Auth

  @impl true
  def mount(_params, session, socket) do
    if Auth.logged_in?(session) do
      # assign the session vars for the login/logout links
      {:ok, assign(socket, Auth.public_session_vars(session))}
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
