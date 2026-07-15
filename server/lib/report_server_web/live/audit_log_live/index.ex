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
    filters = %{
      export_id: params["export_id"] || "",
      remote_endpoint: params["remote_endpoint"] || ""
    }

    result = AuditLog.list_entries_paginated(Pagination.normalize_page(params["page"]), filters)
    filtered? = filters.export_id != "" or filters.remote_endpoint != ""

    socket =
      socket
      |> assign(:entries, result.items)
      |> assign(:page, result.page)
      |> assign(:total_pages, result.total_pages)
      |> assign(:total_count, result.total_count)
      |> assign(:filters, filters)
      |> assign(:filtered?, filtered?)

    # No unconditional focus push here: handle_params fires on both filter submit AND paging. Focus is driven
    # by the template's data-refocus token (filter-derived), so it moves on a filter change but NOT on paging.
    {:noreply, socket}
  end

  @impl true
  def handle_params(_params, _url, socket), do: {:noreply, socket}

  @impl true
  def handle_event("filter", %{"export_id" => export_id, "remote_endpoint" => remote_endpoint}, socket) do
    {:noreply, push_patch(socket, to: filter_path(export_id, remote_endpoint))}
  end

  # results-container refocus token: changes iff the FILTER values change (paging preserves them)
  defp refocus_token(%{export_id: e, remote_endpoint: r}), do: "#{e}|#{r}"

  # human-readable active-filter suffix for the aria-live summary and the table caption
  defp filter_suffix(%{export_id: e, remote_endpoint: r}) do
    parts =
      [{"export id", e}, {"student", r}]
      |> Enum.filter(fn {_label, v} -> v not in [nil, ""] end)
      |> Enum.map(fn {label, v} -> "#{label} \"#{v}\"" end)

    if parts == [], do: "", else: " (filtered by " <> Enum.join(parts, " and ") <> ")"
  end

  defp filter_path(export_id, remote_endpoint) do
    query =
      %{"export_id" => export_id, "remote_endpoint" => remote_endpoint}
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)

    if query == [], do: ~p"/reports/audit-log", else: ~p"/reports/audit-log?#{query}"
  end

  defp audit_log_path(page, filters) do
    query =
      %{"export_id" => filters.export_id, "remote_endpoint" => filters.remote_endpoint}
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
      |> then(fn q -> if page > 1, do: [{"page", page} | q], else: q end)

    if query == [], do: ~p"/reports/audit-log", else: ~p"/reports/audit-log?#{query}"
  end
end
