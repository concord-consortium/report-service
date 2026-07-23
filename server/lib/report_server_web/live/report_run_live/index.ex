defmodule ReportServerWeb.ReportRunLive.Index do
  use ReportServerWeb, :live_view

  require Logger

  alias ReportServer.Pagination
  alias ReportServer.Reports

  @impl true
  def mount(_params, _session, %{assigns: %{user: _user, live_action: :my_runs}} = socket) do
    {:ok, assign(socket, :page_title, "Your Runs")}
  end

  @impl true
  def mount(_params, _session, %{assigns: %{user: user, live_action: :all_runs}} = socket) do
    if user.portal_is_admin do
      {:ok, assign(socket, :page_title, "All Runs")}
    else
      {:ok, socket |> put_flash(:error, "Sorry, you don't have access to that page.") |> redirect(to: "/reports")}
    end
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> put_flash(:error, "Sorry, you don't have access to that page.") |> redirect(to: "/reports")}
  end

  @impl true
  def handle_params(params, _url, %{assigns: %{user: user, live_action: live_action}} = socket) do
    page = Pagination.normalize_page(params["page"])

    result = case live_action do
      :my_runs -> Reports.list_user_report_runs_paginated(user, page)
      :all_runs -> Reports.list_all_report_runs_paginated(page)
    end

    socket = socket
      |> assign(:report_runs, result.items)
      |> assign(:page, result.page)
      |> assign(:total_pages, result.total_pages)

    {:noreply, socket}
  end

  @impl true
  def handle_params(_params, _url, socket), do: {:noreply, socket}

  defp run_list_path(:my_runs), do: fn
    1 -> ~p"/reports/runs"
    page -> ~p"/reports/runs?page=#{page}"
  end
  defp run_list_path(:all_runs), do: fn
    1 -> ~p"/reports/all-runs"
    page -> ~p"/reports/all-runs?page=#{page}"
  end
end
