defmodule ReportServerWeb.ReportRunLive.Index do
  use ReportServerWeb, :live_view

  require Logger

  alias ReportServer.Reports

  @impl true
  def mount(_params, _session, %{assigns: %{user: user, live_action: :my_runs}} = socket) do
    report_runs = Reports.list_user_report_runs(user)
    page_title = "Your Runs"

    socket = socket
      |> assign(:report_runs, report_runs)
      |> assign(:page_title, page_title)

    {:ok, socket}
  end

  @impl true
  def mount(_params, _session, %{assigns: %{user: user, live_action: :all_runs}} = socket) do
    if user.portal_is_admin do
      report_runs = Reports.list_all_report_runs()
      page_title = "All Runs"

      socket = socket
        |> assign(:report_runs, report_runs)
        |> assign(:page_title, page_title)

      {:ok, socket}
    else
      socket = socket
        |> put_flash(:error, "Sorry, you don't have access to that page.")
        |> redirect(to: "/reports")

      {:ok, socket}
    end
  end

  # this is a catch-all mount function that will redirect to the reports when there is no user
  @impl true
  def mount(_params, _session, socket) do
    socket = socket
      |> put_flash(:error, "Sorry, you don't have access to that page.")
      |> redirect(to: "/reports")

    {:ok, socket}
  end
end
