defmodule ReportServerWeb.NewReportLive.Auth do
  import Phoenix.LiveView
  import Phoenix.Component

  alias ReportServerWeb.Auth

  def on_mount(:default, _params, session, socket) do
    if Auth.logged_in?(session) do
      {:cont, assign(socket, Auth.public_session_vars(session))}
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
