defmodule ReportServerWeb.ReportRunLive.Show do
  use ReportServerWeb, :live_view

  require Logger

  alias ReportServer.Accounts.User
  alias ReportServer.PortalDbs
  alias ReportServer.Reports
  alias ReportServer.Reports.{Report, ReportQuery, ReportRun, Tree}

  @row_limit 10

  @impl true
  def mount(_params, _session, socket) do
    socket = socket
      |> assign(:sort, [])
      |> assign(:row_count, nil)
      |> assign(:row_limit, @row_limit)
      |> assign(:primary_sort, nil)
      |> assign(:sort_direction, :asc)

    {:ok, socket, temporary_assigns: [report_results: nil]}
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
      |> assign_async(:row_count, fn -> get_row_count(report, report_run, user) end)
      |> assign_async(:report_results, fn -> run_report(report, report_run, [], @row_limit, user) end)

      {:noreply, socket}
    else
      socket = socket
        |> put_flash(:error, "You are not authorized to access the requested report.")
        |> redirect(to: "/new-reports")
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("sort_column", %{"column" => column}, %{assigns: %{report: report, report_run: report_run, user: user, sort: sort}} = socket) do

    dir = if socket.assigns.primary_sort == column do
      if socket.assigns.sort_direction == :asc, do: :desc, else: :asc
    else
      :asc
    end

    new_sort = [{column, dir}| sort] |> ReportQuery.uniq_order_by()
    socket = socket
      |> assign(:sort, new_sort)
      |> assign(:primary_sort, column)
      |> assign(:sort_direction, dir)
      |> assign_async(:report_results, fn -> run_report(report, report_run, new_sort, @row_limit, user) end)

    {:noreply, socket}
  end

  def handle_event("download_report", %{"filetype" => filetype}, %{assigns: %{report: report, report_run: report_run, user: user, sort: sort}} = socket) do
    filename = "#{report_run.report_slug}-run-#{report_run.id}.#{filetype}"
    with {:ok, %{ report_results: report_results }} <- run_report(report, report_run, sort, nil, user),
      {:ok, data} <- format_results(report_results, filetype) do
        # Ask browser to download the file
        # See https://elixirforum.com/t/download-or-export-file-from-phoenix-1-7-liveview/58484/10
        {:noreply, request_download(socket, data, filename)}

    else
      {:error, error} ->
        socket = put_flash(socket, :error, "Failed to format results: #{error}")
        {:noreply, socket}
    end
  end

  defp get_row_count(report = %Report{}, report_run = %ReportRun{}, user = %User{}) do
    with {:ok, query} <- report.get_query.(report_run.report_filter),
      sql <- ReportQuery.get_count_sql(query),
      {:ok, results} <- PortalDbs.query(user.portal_server, sql, []) do
        # Count will be the first value in the first (only) row of results
        count = Enum.at(results.rows, 0) |> Enum.at(0)
        {:ok, %{row_count: count}}

    else
      {:error, error} ->
        Logger.error(error)
        {:error, error}
    end
  end

  defp run_report(nil, report_run, _sort_columns, _row_limit, _user) do
    error = "Unable to find report: #{report_run.report_slug}"
    Logger.error(error)
    {:error, error}
  end

  defp run_report(report = %Report{}, report_run = %ReportRun{}, sort_columns, row_limit, user = %User{}) do
    with {:ok, query} <- report.get_query.(report_run.report_filter),
      ordered_query <- ReportQuery.add_sort_columns(query, sort_columns),
      sql <- ReportQuery.get_sql(ordered_query, row_limit),
      {:ok, results} <- PortalDbs.query(user.portal_server, sql, []) do
        {:ok, %{report_results: results}}

    else
      {:error, error} ->
        Logger.error(error)
        {:error, error}
    end
  end

  defp request_download(socket, data, filename) do
    socket
    |> push_event("download_report", %{data: data, filename: filename}) # TODO: more informative filename
  end

  defp format_results(%MyXQL.Result{} = result, "csv") do
    csv = result
      |> PortalDbs.map_columns_on_rows()
      |> Stream.map(&(&1))
      |> CSV.encode(headers: result.columns |> Enum.map(&String.to_atom/1), delimiter: "\n")
      |> Enum.to_list()
      |> Enum.join("")
    {:ok, csv}
  end
  defp format_results(%MyXQL.Result{} = result, "json") do
    result
      |> PortalDbs.map_columns_on_rows()
      |> Jason.encode()
  end
  defp format_results(result, filetype) do
    {:error, "Unknown file type or malformed data: #{filetype}"}
  end

end
