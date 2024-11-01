defmodule ReportServerWeb.NewReportsLive.Index do
  use ReportServerWeb, :live_view
  alias ReportServerWeb.Auth

  @impl true
  def mount(_params, session, socket) do
    socket = socket
      |> assign(:page_title, "New Reports")
      |> assign(Auth.public_session_vars(session))

    {:ok, socket}
  end

end
