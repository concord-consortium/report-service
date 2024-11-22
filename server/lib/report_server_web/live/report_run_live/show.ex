defmodule ReportServerWeb.ReportRunLive.Show do
  use ReportServerWeb, :live_view

  require Logger

  alias ReportServer.Accounts.User
  alias ReportServer.PortalDbs
  alias ReportServer.Reports
  alias ReportServer.Reports.{Report, ReportQuery, ReportRun, Tree}

  @impl true
  def mount(_params, _session, socket) do
    socket = socket
      |> assign(:sort, nil)
      |> assign(:sort_direction, :asc)

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"id" => id}, _url, %{assigns: %{user: user = %User{}}} = socket) do
    report_run = Reports.get_report_run!(id)
    report = Tree.find_report(report_run.report_slug)

    # allow only the report run creator or admins to use run
    if report_run.user_id == user.id || user.portal_is_admin do

      breadcrumbs = Enum.map(report.parents, fn {_slug, title, path} -> {title, path} end) ++ [{report.title, report.path}]

      socket = socket
      |> assign(:report, report)
      |> assign(:report_run, report_run)
      |> assign(:breadcrumbs, breadcrumbs)
      |> assign_async(:report_results, fn -> run_report(report, report_run, user) end)

      {:noreply, socket}
    else
      socket = socket
        |> put_flash(:error, "You are not authorized to access the requested report.")
        |> redirect(to: "/new-reports")
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("sort_column", %{"column" => column}, %{assigns: %{report_results: report_results}} = socket) do
    dir = if socket.assigns.sort == column do
      if socket.assigns.sort_direction == :asc, do: :desc, else: :asc
    else
      :asc
    end

    %MyXQL.Result{columns: columns, rows: rows} = report_results.result
    col_index = columns |> Enum.find_index(&(&1 == column))
    sort_fn = if dir == :asc do &value_sorter/2 else &(value_sorter(&2, &1)) end
    new_rows = Enum.sort_by(rows, &(Enum.at(&1, col_index)), sort_fn)
    report_results = put_in(report_results.result.rows, new_rows)

    socket = socket
      |> assign(:sort, column)
      |> assign(:sort_direction, dir)
      |> assign(:report_results, report_results)
    {:noreply, socket}
  end

  def handle_event("download_report", %{"filetype" => filetype}, %{assigns: %{report_results: report_results}} = socket) do
    case format_results(report_results, filetype) do
      {:ok, data} ->
        # Ask browser to download the file
        # See https://elixirforum.com/t/download-or-export-file-from-phoenix-1-7-liveview/58484/10
        {:noreply, request_download(socket, data, "report.#{filetype}")}

      {:error, error} ->
        socket = put_flash(socket, :error, "Failed to format results: #{error}")
        {:noreply, socket}
    end
  end

  defp run_report(nil, report_run, _user) do
    error = "Unable to find report: #{report_run.report_slug}"
    Logger.error(error)
    {:error, error}
  end

  defp run_report(report = %Report{}, report_run = %ReportRun{}, user = %User{}) do
    with {:ok, query} <- report.get_query.(report_run.report_filter),
      sql <- ReportQuery.get_sql(query),
      {:ok, results} <- PortalDbs.query(user.portal_server, sql, []) do
        {:ok, %{report_results: results}}

    else
      {:error, error} ->
        Logger.error(error)
        {:error, error}
    end
  end

  def request_download(socket, data, filename) do
    socket
    |> push_event("download_report", %{data: data, filename: filename}) # TODO: more informative filename
  end

  def format_results(report_results = %Phoenix.LiveView.AsyncResult{result: result}, "csv") do
    csv = result
      |> PortalDbs.map_columns_on_rows()
      |> Stream.map(&(&1))
      |> CSV.encode(headers: report_results.result.columns |> Enum.map(&String.to_atom/1), delimiter: "\n")
      |> Enum.to_list()
      |> Enum.join("")
    {:ok, csv}
  end
  def format_results(%Phoenix.LiveView.AsyncResult{result: result}, "json") do
    result
      |> PortalDbs.map_columns_on_rows()
      |> Jason.encode()
  end
  def format_results(_report_results, filetype) do
    {:error, "Unknown file type: #{filetype}"}
  end

  # Dates do not sort properly with normal <= operator
  defp value_sorter(v1 = %Date{}, v2 = %Date{}), do: Date.compare(v1, v2) != :gt
  defp value_sorter(v1, v2), do: v1 <= v2
end
