defmodule ReportServerWeb.ReportLive.CliToken do
  use ReportServerWeb, :live_view

  alias ReportServer.Accounts
  alias ReportServer.Accounts.ApiToken

  @impl true
  def mount(_params, _session, %{assigns: %{user: user}} = socket) do
    socket = socket
      |> assign(:page_title, "CLI Access Tokens")
      |> assign(:raw_token, nil)
      |> assign(:raw_token_id, nil)
      |> assign(:form, to_form(%{"label" => ""}))
      |> assign(:tokens, Accounts.list_active_api_tokens(user.id))

    {:ok, socket}
  end

  # Only reached when not logged in (this page is open to all report users, so there is no
  # logged-in-but-unauthorized case to reject here). ReportLive.Auth has already attached a
  # handle_params hook that redirects to /auth/login?return_to=<path>; return without
  # redirecting so that hook runs and the original deep link is preserved as return_to.
  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_event("generate", %{"label" => label}, %{assigns: %{user: user}} = socket) do
    label = case String.trim(label) do
      "" -> nil
      trimmed -> trimmed
    end

    case Accounts.create_api_token(user, label) do
      {:ok, raw_token, api_token} ->
        socket = socket
          |> assign(:raw_token, raw_token)
          |> assign(:raw_token_id, api_token.id)
          |> assign(:tokens, Accounts.list_active_api_tokens(user.id))
        {:noreply, socket}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Unable to generate a token. Please try again.")}
    end
  end

  @impl true
  def handle_event("revoke", %{"id" => id}, %{assigns: %{user: user}} = socket) do
    token = with {token_id, ""} <- Integer.parse(id), do: Accounts.get_user_api_token(token_id, user.id)

    socket =
      case token do
        %ApiToken{} = token ->
          case Accounts.revoke_api_token(token, user.id) do
            {:ok, _} ->
              socket |> clear_shown_once_if(token.id) |> put_flash(:info, "Token revoked")

            {:error, :already_revoked} ->
              socket |> put_flash(:info, "That token was already inactive")
          end

        _ ->
          socket |> put_flash(:info, "That token was already inactive")
      end

    {:noreply, assign(socket, :tokens, Accounts.list_active_api_tokens(user.id))}
  end

  defp clear_shown_once_if(socket, revoked_id) do
    if socket.assigns[:raw_token_id] == revoked_id do
      socket |> assign(:raw_token, nil) |> assign(:raw_token_id, nil)
    else
      socket
    end
  end
end
