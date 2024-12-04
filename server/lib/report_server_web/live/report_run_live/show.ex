defmodule ReportServerWeb.ReportRunLive.Show do
  use ReportServerWeb, :live_view

  require Logger

  alias ReportServer.Accounts.User
  alias ReportServer.PortalDbs
  alias ReportServer.AthenaDB
  alias ReportServer.Reports
  alias ReportServer.Reports.{Report, ReportQuery, ReportRun, Tree}

  @row_limit 100

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
    report_run = Reports.get_report_run_with_user!(id)
    report = Tree.find_report(report_run.report_slug)

    # allow only the report run creator or admins to use run
    if report_run.user_id == user.id || user.portal_is_admin do

      breadcrumbs = Enum.map(report.parents, fn {_slug, title, path} -> {title, path} end) ++ [{report.title, report.path}]

      live_view_pid = self()

      socket = socket
      |> assign(:report, report)
      |> assign(:report_run, report_run)
      |> assign(:breadcrumbs, breadcrumbs)
      |> assign_async(:row_count, fn -> get_row_count(report, report_run, user) end)
      |> assign_async(:report_results, fn -> run_report(report, report_run, [], @row_limit, live_view_pid) end)

      {:noreply, socket}
    else
      socket = socket
        |> put_flash(:error, "You are not authorized to access the requested report.")
        |> redirect(to: "/new-reports")
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("sort_column", %{"column" => column}, %{assigns: %{report: report, report_run: report_run, sort: sort}} = socket) do

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
      |> assign_async(:report_results, fn -> run_report(report, report_run, new_sort, @row_limit, nil) end)

    {:noreply, socket}
  end

  @impl true
  def handle_event("download_report", _params, %{assigns: %{report: %{type: :athena}}} = socket) do
    download_athena_report(socket)
  end

  @impl true
  def handle_event("download_report", %{"filetype" => filetype}, socket) do
    download_portal_report(filetype, socket)
  end

  @impl true
  def handle_info(:poll_query_state, socket = %{assigns: %{report_run: report_run}}) do
    # need to load report run each time as it is set async in run_report
    report_run = Reports.get_report_run_with_user!(report_run.id)

    socket = socket
      |> assign(:report_run, check_query_state(report_run, self()))
    {:noreply, socket}
  end

  defp get_row_count(_report = %Report{type: :athena}, _report_run, _user) do
    {:ok, %{row_count: 0}}
  end

  defp get_row_count(report = %Report{}, report_run = %ReportRun{}, user = %User{}) do
    with {:ok, query} <- report.get_query.(report_run.report_filter, user),
      {:ok, sql} <- ReportQuery.get_count_sql(query),
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

  defp run_report(nil, report_run, _sort_columns, _row_limit, _live_view_pid) do
    error = "Unable to find report: #{report_run.report_slug}"
    Logger.error(error)
    {:error, error}
  end

  defp run_report(report = %Report{type: :athena}, report_run = %ReportRun{id: report_run_id, athena_query_id: nil}, _sort_columns, _row_limit, live_view_pid) do
    with {:ok, query} <- report.get_query.(report_run.report_filter, report_run.user),
         {:ok, sql} <- ReportQuery.get_sql(query),
         {:ok, athena_query_id, athena_query_state} <- AthenaDB.query(sql, report_run_id, report_run.user),
         {:ok, _report_run} <- Reports.update_report_run(report_run, %{athena_query_id: athena_query_id, athena_query_state: athena_query_state}) do

      send(live_view_pid, :poll_query_state)

      # return nil - the template will use the report_run to provide status updates
      {:ok, %{report_results: nil}}

    else
      {:error, error} ->
        Logger.error(error)
        {:error, error}
    end
  end

  defp run_report(%Report{type: :athena}, report_run = %ReportRun{}, _sort_columns, _row_limit, live_view_pid) do
    maybe_poll_query_state(report_run, live_view_pid)

    # return nil - the template will use the report_run to provide status updates
    {:ok, %{report_results: nil}}
  end

  defp run_report(report = %Report{}, report_run = %ReportRun{}, sort_columns, row_limit, _live_view_pid) do
    with {:ok, query} <- report.get_query.(report_run.report_filter, report_run.user),
         ordered_query <- ReportQuery.add_sort_columns(query, sort_columns),
         {:ok, sql} <- ReportQuery.get_sql(ordered_query, row_limit),
         {:ok, results} <- PortalDbs.query(report_run.user.portal_server, sql, []) do
      {:ok, %{report_results: results}}

    else
      {:error, error} ->
        Logger.error(error)
        {:error, error}
    end
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
  defp format_results(_result, filetype) do
    {:error, "Unknown file type or malformed data: #{filetype}"}
  end

  defp check_query_state(report_run = %ReportRun{athena_query_id: athena_query_id}, live_view_pid) do
    if poll_query_state?(report_run) do
      with {:ok, athena_query_state, athena_result_url} <- AthenaDB.get_query_info(athena_query_id),
           {:ok, report_run} <- Reports.update_report_run(report_run, %{athena_query_state: athena_query_state, athena_result_url: athena_result_url}) do
        maybe_poll_query_state(report_run, live_view_pid)
        report_run
      else
        _ ->
          report_run
      end
    else
      report_run
    end
  end

  defp maybe_poll_query_state(report_run = %ReportRun{}, live_view_pid) do
    if poll_query_state?(report_run) do
      Process.send_after(live_view_pid, :poll_query_state, 1000)
    end
  end

  defp poll_query_state?(%ReportRun{athena_query_state: nil}), do: true
  defp poll_query_state?(%ReportRun{athena_query_state: "queued"}), do: true
  defp poll_query_state?(%ReportRun{athena_query_state: "running"}), do: true
  defp poll_query_state?(_), do: false

  defp get_download_filename(filetype, report_run = %ReportRun{}), do: "#{report_run.report_slug}-run-#{report_run.id}.#{filetype}"

  defp download_portal_report(filetype, %{assigns: %{report: report, report_run: report_run, sort: sort}} = socket) do
    filename = get_download_filename(filetype, report_run)

    with {:ok, %{ report_results: report_results }} <- run_report(report, report_run, sort, nil, nil),
      {:ok, data} <- format_results(report_results, filetype) do
        socket = socket |> push_event("download_report", %{data: data, filename: filename})
        {:noreply, socket}

    else
      {:error, error} ->
        socket = put_flash(socket, :error, "Failed to format results: #{error}")
        {:noreply, socket}
    end
  end

  defp download_athena_report(%{assigns: %{report_run: report_run}} = socket) do
    filename = get_download_filename("csv", report_run)

    with {:ok, athena_result_url} <- get_athena_result_url(report_run),
         {:ok, download_url} = AthenaDB.get_download_url(athena_result_url, filename) do
      socket = socket |> push_event("download_report", %{download_url: download_url, filename: filename})
      {:noreply, socket}
    else
      {:error, error} ->
        socket = put_flash(socket, :error, error)
        {:noreply, socket}
    end
  end

  defp get_athena_result_url(%ReportRun{athena_result_url: nil}), do: {:error, "Athena report result url not found!"}
  defp get_athena_result_url(%ReportRun{athena_result_url: athena_result_url}), do: {:ok, athena_result_url}

end
