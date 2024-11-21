defmodule ReportServerWeb.NewReportLive.Form do
  @doc """
  Render the form for a new report.
  May eventually get a different @live_action to show the result of the report.
  """

  use ReportServerWeb, :live_view

  import LiveSelect

  require Logger

  alias Jason
  alias ReportServer.PortalDbs
  alias ReportServer.Reports
  alias ReportServer.Reports.{Report, Tree, ReportFilter, ReportFilterQuery, ReportQuery}

  @filter_type_options [{"Schools", "school"}, {"Cohorts", "cohort"}, {"Teachers", "teacher"}, {"Assignments", "assignment"}]

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(%{"slug" => slug}, _uri, socket) do
    report = Tree.find_report(slug)
    %{title: title, subtitle: subtitle} = get_report_info(slug, report)

    form = to_form(%{}, as: "filter_form")

    socket = socket
    |> assign(:report, report)
    |> assign(:title, title)
    |> assign(:subtitle, subtitle)
    |> assign(:page_title, "Reports: #{title}")
    |> assign(:root_path, Reports.get_root_path())
    |> assign(:results, nil)
    |> assign(:debug, nil)
    |> assign(:sort, nil)
    |> assign(:sort_direction, :asc)
    |> assign(:error, nil)
    |> assign(:form, form)
    |> assign(:num_filters, 1)
    |> assign(:filter_type_options, [@filter_type_options])
    |> assign(:filter_options, [[]])

    {:ok, socket}

    {:noreply, socket}
  end

  @impl true
  def handle_event("live_select_change", %{"field" => field, "text" => text, "id" => live_select_id}, socket = %{assigns: %{form: form}}) do
    filter_index = get_filter_index(field)
    report_filter = ReportFilter.from_form(form, filter_index)

    case ReportFilterQuery.get_options(report_filter, text) do
      {:ok, options, sql, params} ->
        send_update(LiveSelect.Component, id: live_select_id, options: options)
        socket = socket
          |> assign(:error, nil)
          |> assign(:debug, debug_filter(sql ,params))
        {:noreply, socket}

      {:error, error, sql, params} ->
        socket = socket
          |> assign(:error, error)
          |> assign(:debug, debug_filter(sql ,params))
        {:noreply, socket}
    end
  end

  def handle_event("form_updated", %{"_target" => ["filter_form", field], "filter_form" => form_values}, socket) do
    filter = String.replace_suffix(field, "_type", "")
    type_change? = String.ends_with?(field, "_type")
    # empty_selection? = String.ends_with?(field, "empty_selection")

    filter_index = if type_change?, do: get_filter_index(filter), else: 0

    form_values = if type_change? do
      # remove any existing filter values
      form_values |> Map.put(filter, [])
    else
      form_values
    end
    form = to_form(form_values, as: "filter_form")

    socket = assign(socket, :form, form)

    socket = if type_change? && (filter_index > 1 || form_values[field] == "cohort") do
      report_filter = ReportFilter.from_form(form, filter_index)

      case ReportFilterQuery.get_options(report_filter) do
        {:ok, options, sql, params} ->
          filter_options = socket.assigns.filter_options
            |> List.replace_at(filter_index - 1, options)

          socket
            |> assign(:error, nil)
            |> assign(:filter_options, filter_options)
            |> assign(:debug, debug_filter(sql ,params))

        {:error, error, sql, params} ->
          socket
            |> assign(:error, error)
            |> assign(:debug, debug_filter(sql ,params))
      end
    else
      socket
    end

    {:noreply, socket}
  end

  def handle_event("add_filter", _unsigned_params, socket) do
    num_filters = socket.assigns.num_filters
    form_params = socket.assigns.form.params

    filter_options = Enum.take(socket.assigns.filter_options, num_filters)
    filter_type_options = Enum.take(socket.assigns.filter_type_options, num_filters)

    new_num_filters = num_filters + 1

    existing_filters = Enum.map(1..num_filters, &(form_params["filter#{&1}_type"]))
    new_filter_type_options = Enum.filter(@filter_type_options, fn {_key, value} -> !Enum.member?(existing_filters, value) end)

    socket = socket
      |> assign(:num_filters, new_num_filters)
      |> assign(:filter_options, filter_options ++ [[]])
      |> assign(:filter_type_options, filter_type_options ++ [new_filter_type_options])

    {:noreply, socket}
  end

  def handle_event("remove_filter", _unsigned_params, socket) do
    num_filters = socket.assigns.num_filters
    new_num_filters = num_filters - 1
    new_filter_options = Enum.take(socket.assigns.filter_options, new_num_filters)
    new_filter_type_options = Enum.take(socket.assigns.filter_type_options, new_num_filters)

    # remove the form values
    filter_key_prefix = "filter#{num_filters}"
    new_form = socket.assigns.form.params
      |> Enum.filter(fn {key, _value} -> !String.starts_with?(key, filter_key_prefix) end)
      |> Enum.into(%{})
      |> to_form(as: "filter_form")

    socket = socket
      |> assign(:num_filters, new_num_filters)
      |> assign(:filter_options, new_filter_options)
      |> assign(:filter_type_options, new_filter_type_options)
      |> assign(:form, new_form)

    {:noreply, socket}
  end

  @impl true
  def handle_event("submit_form", _unsigned_params, %{assigns: %{report: %Report{} = report, form: form, num_filters: num_filters}} = socket) do
    report_filter = ReportFilter.from_form(form, num_filters)

    # run the report after we reply so the results are cleared
    send(self(), {:run_report, {report, report_filter}})

    socket = socket
      |> assign(:results, nil)
      |> assign(:error, nil)

    {:noreply, socket}
  end

  def handle_event("sort_column", %{"column" => column}, %{assigns: %{results: results}} = socket) do
    dir = if socket.assigns.sort == column do
      if socket.assigns.sort_direction == :asc, do: :desc, else: :asc
    else
      :asc
    end
    results = PortalDbs.sort_results(results, column, dir)
    updates = socket
    |> assign(:sort, column)
    |> assign(:sort_direction, dir)
    |> assign(:results, results)
    {:noreply, updates}
  end

  def handle_event("download_report", %{"filetype" => filetype}, %{assigns: %{results: results}} = socket) do
    case format_results(results, String.to_atom(filetype)) do
      {:ok, data} ->
      file_extension = String.downcase(filetype)
      # Ask browser to download the file
      # See https://elixirforum.com/t/download-or-export-file-from-phoenix-1-7-liveview/58484/10
      {:noreply, request_download(socket, data, "report.#{file_extension}")}

      {:error, error} ->
      socket = put_flash(socket, :error, "Failed to format results: #{error}")
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:run_report, {report, report_filter}}, socket) do
    socket =
      with query <- report.get_query.(report_filter),
           sql <- ReportQuery.get_sql(query),
           {:ok, results} <- PortalDbs.query("learn.concord.org", sql, []) do
        socket
          |> assign(:results, results)
          |> assign(:debug, inspect(report_filter, charlists: :as_lists))
          |> assign(:error, nil)
          |> assign(:sort, nil)
          |> assign(:sort_direction, :asc)

      else
        {:error, error} ->
          socket
            |> assign(:results, nil)
            |> assign(:error, error)
    end

    {:noreply, socket}
  end

  def request_download(socket, data, filename) do
    socket
    |> push_event("download_report", %{data: data, filename: filename}) # TODO: more informative filename
  end

  def format_results(results, :CSV) do
    csv = results
      |> PortalDbs.map_columns_on_rows()
      |> Stream.map(&(&1))
      |> CSV.encode(headers: results.columns |> Enum.map(&String.to_atom/1), delimiter: "\n")
      |> Enum.to_list()
      |> Enum.join("")
    {:ok, csv}
  end

  def format_results(results, :JSON) do
    results
      |> PortalDbs.map_columns_on_rows()
      |> Jason.encode()
  end

  defp get_report_info(slug, nil) do
    %{title: "Error: #{slug} is not a known report", subtitle: nil}
  end
  defp get_report_info(_slug, report = %Report{}) do
    %{title: report.title, subtitle: report.subtitle}
  end

  defp get_filter_index(s), do: Regex.run(~r/(\d+)$/, s) |> List.last() |> String.to_integer()

  defp debug_filter(sql, params), do: "#{sql} (#{params |> Enum.map(&("'#{&1}'")) |> Enum.join(", ")})"

end
