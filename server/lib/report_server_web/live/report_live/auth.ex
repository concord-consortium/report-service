defmodule ReportServerWeb.ReportLive.Auth do
  import Phoenix.LiveView
  import Phoenix.Component

  alias ReportServerWeb.Auth

  def on_mount(:default, _params, session, socket) do
    if Auth.logged_in?(session) do
      if Auth.can_access_reports?(session) do
        socket = socket
          |> assign(:user, session["user"])
          |> assign(Auth.public_session_vars(session))
        {:cont, socket}
      else
        socket = socket
          |> put_flash(:error, "Sorry, you are not a portal admin, project admin, or project researcher so you can't access reports.")
          |> redirect(to: "/")
        {:halt, socket}
      end
    else
      # since the current url isn't available at on_mount time, attach a hook to handle_params where it is available
      socket =
        attach_hook(socket, :redirect_and_halt, :handle_params, fn _, url, socket ->
          return_to = URI.parse(url) |> Map.get(:path)
          socket = redirect(socket, to: "/auth/login?return_to=#{return_to}")
          {:halt, socket}
        end)

      {:cont, socket}
    end
  end
end
