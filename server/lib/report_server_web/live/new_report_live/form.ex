defmodule ReportServerWeb.NewReportLive.Form do
  @doc """
  Render the form for a new report.
  May eventually get a different @live_action to show the result of the report.
  """

  use ReportServerWeb, :live_view

  import LiveSelect

  require Logger

  alias Jason
  alias ReportServer.Reports
  alias ReportServer.Reports.{Report, Tree, ReportFilter, ReportFilterQuery}

  @filter_type_options [
    {"Schools", "school"},
    {"Cohorts", "cohort"},
    {"Teachers", "teacher"},
    {"Assignments", "assignment"},
    {"Permission forms", "permission_form"}
  ]

  @impl true
  def handle_params(%{"slug" => slug}, _uri, %{assigns: %{user: user}} = socket) do
    report = Tree.find_report(slug)
    %{title: title, subtitle: subtitle, report_runs: report_runs} = get_report_info(user, slug, report)

    form = to_form(%{}, as: "filter_form")

    socket = socket
    |> assign(:report, report)
    |> assign(:title, title)
    |> assign(:subtitle, subtitle)
    |> assign(:report_runs, report_runs)
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
  def handle_event("submit_form", _unsigned_params, %{assigns: %{report: %Report{} = report, form: form, num_filters: num_filters, user: user}} = socket) do
    report_filter = ReportFilter.from_form(form, num_filters)
    report_filter_values = ReportFilter.get_filter_values(report_filter, user.portal_server)

    report_run_attrs = %{
      report_slug: report.slug,
      report_filter: report_filter,
      report_filter_values: report_filter_values,
      user_id: user.id,
    }

    socket = case Reports.create_report_run(report_run_attrs) do
      {:ok, report_run} ->
        socket
          |> redirect(to: ~p"/new-reports/runs/#{report_run.id}")

      {:error, changeset} ->
        Logger.error(changeset)
        socket
          |> assign(:error, "Unable to create report run!")
    end

    {:noreply, socket}
  end

  defp get_report_info(_user, slug, nil) do
    %{title: "Error: #{slug} is not a known report", subtitle: nil, report_runs: []}
  end
  defp get_report_info(user, slug, report = %Report{}) do
    report_runs = Reports.list_user_report_runs(user, slug)
    %{title: report.title, subtitle: report.subtitle, report_runs: report_runs}
  end

  defp get_filter_index(s), do: Regex.run(~r/(\d+)$/, s) |> List.last() |> String.to_integer()

  defp debug_filter(sql, params), do: "#{sql} (#{params |> Enum.map(&("'#{&1}'")) |> Enum.join(", ")})"

end
