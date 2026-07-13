defmodule ReportServerWeb.ReportLive.CliToken do
  use ReportServerWeb, :live_view

  alias ReportServer.Accounts

  @impl true
  def mount(_params, _session, socket) do
    socket = socket
      |> assign(:page_title, "CLI Access Token")
      |> assign(:raw_token, nil)
      |> assign(:form, to_form(%{"label" => ""}))

    {:ok, socket}
  end

  @impl true
  def handle_event("generate", %{"label" => label}, %{assigns: %{user: user}} = socket) do
    label = case String.trim(label) do
      "" -> nil
      trimmed -> trimmed
    end

    case Accounts.create_api_token(user, label) do
      {:ok, raw_token, _api_token} ->
        {:noreply, assign(socket, :raw_token, raw_token)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Unable to generate a token. Please try again.")}
    end
  end
end
