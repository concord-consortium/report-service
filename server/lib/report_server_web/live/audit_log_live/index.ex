defmodule ReportServerWeb.AuditLogLive.Index do
  use ReportServerWeb, :live_view

  alias ReportServer.{AuditLog, Pagination}

  @impl true
  def mount(_params, _session, %{assigns: %{user: user}} = socket) do
    if user.portal_is_admin do
      {:ok, assign(socket, :page_title, "Data Access Log")}
    else
      {:ok, socket |> put_flash(:error, "Sorry, you don't have access to that page.") |> redirect(to: "/reports")}
    end
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> put_flash(:error, "Sorry, you don't have access to that page.") |> redirect(to: "/reports")}
  end

  @impl true
  def handle_params(params, _url, %{assigns: %{user: %{portal_is_admin: true}}} = socket) do
    result = AuditLog.list_entries_paginated(Pagination.normalize_page(params["page"]))

    socket = socket
      |> assign(:entries, result.items)
      |> assign(:page, result.page)
      |> assign(:total_pages, result.total_pages)

    {:noreply, socket}
  end

  @impl true
  def handle_params(_params, _url, socket), do: {:noreply, socket}

  defp audit_log_path(1), do: ~p"/reports/audit-log"
  defp audit_log_path(page), do: ~p"/reports/audit-log?page=#{page}"
end
