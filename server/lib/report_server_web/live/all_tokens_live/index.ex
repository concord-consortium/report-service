defmodule ReportServerWeb.AllTokensLive.Index do
  use ReportServerWeb, :live_view

  alias ReportServer.Accounts
  alias ReportServer.Accounts.ApiToken
  alias ReportServer.Pagination

  @impl true
  def mount(_params, _session, %{assigns: %{user: %{portal_is_admin: true}}} = socket) do
    {:ok, assign(socket, :page_title, "All CLI Tokens")}
  end

  # Logged in but not an admin: this is a genuine authorization failure, so reject it.
  @impl true
  def mount(_params, _session, %{assigns: %{user: _user}} = socket) do
    {:ok, socket |> put_flash(:error, "Sorry, you don't have access to that page.") |> redirect(to: "/reports")}
  end

  # Not logged in (no :user assign): return without redirecting so ReportLive.Auth's handle_params
  # hook redirects to /auth/login?return_to=<path> and preserves the deep link, rather than
  # bouncing an anonymous visitor to /reports with a misleading authorization error (see CliToken).
  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, %{assigns: %{user: %{portal_is_admin: true}}} = socket) do
    {:noreply, assign_page(socket, Pagination.normalize_page(params["page"]))}
  end

  @impl true
  def handle_params(_params, _url, socket), do: {:noreply, socket}

  @impl true
  def handle_event("revoke", %{"id" => id}, %{assigns: %{user: %{portal_is_admin: true} = user}} = socket) when is_binary(id) do
    token = with {token_id, ""} <- Integer.parse(id), do: Accounts.get_active_api_token(token_id)

    socket =
      case token do
        %ApiToken{} = token ->
          case Accounts.revoke_api_token(token, user.id) do
            {:ok, _} -> put_flash(socket, :info, "Token revoked")
            {:error, :already_revoked} -> put_flash(socket, :info, "That token was already inactive")
          end

        _ ->
          put_flash(socket, :info, "That token was already inactive")
      end

    {:noreply, assign_page(socket, socket.assigns.page)}
  end

  @impl true
  def handle_event("revoke", _params, socket) do
    {:noreply, socket}
  end

  defp assign_page(socket, page) do
    result = Accounts.list_all_active_api_tokens(page)

    socket
    |> assign(:tokens, result.items)
    |> assign(:page, result.page)
    |> assign(:total_pages, result.total_pages)
  end

  defp all_tokens_path(1), do: ~p"/reports/all-tokens"
  defp all_tokens_path(page), do: ~p"/reports/all-tokens?page=#{page}"
end
