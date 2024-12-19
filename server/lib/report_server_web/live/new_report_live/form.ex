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
  alias ReportServer.Reports.{Report, Tree, ReportFilter, ReportQuery, ReportFilterQuery}

  @filter_types %{
    :school => "Schools",
    :cohort => "Cohorts",
    :teacher => "Teachers",
    :assignment => "Assignments",
    :permission_form => "Permission Forms",
  }

  # These fields have few enough options that we can query them without a search string
  @no_search_required_fields [:cohort]

  @dev Application.compile_env(:report_server, :dev_routes)

  @impl true
  def handle_params(%{"slug" => slug}, _uri, %{assigns: %{user: user}} = socket) do
    report = Tree.find_report(slug)
    %{title: title, subtitle: subtitle, report_runs: report_runs} = get_report_info(user, slug, report)
    filter_type_options = report.include_filters |> Enum.map(fn filter -> {@filter_types[filter], filter} end)
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
    |> assign(:filter_types_included, filter_type_options)
    |> assign(:filter_type_options, [filter_type_options])
    |> assign(:filter_options, [[]])
    |> assign(:form_options, get_form_options(report))
    |> assign(:placeholder_text, [""])
    |> assign(:dev, @dev)

    {:noreply, socket}
  end

  @impl true
  def handle_event("live_select_change", %{"field" => field, "text" => text, "id" => live_select_id}, socket = %{assigns: %{form: form}}) do
    filter_index = get_filter_index(field)
    report_filter = ReportFilter.from_form(form, filter_index)
    field_name = report_filter.filters |> Enum.at(filter_index - 1)
    if Enum.member?(@no_search_required_fields, field_name) || String.length(text) >= 3 do
      case ReportFilterQuery.get_options(report_filter, text) do
        {:ok, options, sql, params} ->
          send_update(LiveSelect.Component, id: live_select_id, options: options)
          new_placeholder_text = socket.assigns.placeholder_text
          |> List.replace_at(filter_index - 1, describe_options(field, text, options))
          socket = socket
            |> assign(:error, nil)
            |> assign(:debug, debug_filter(sql ,params))
            |> assign(:placeholder_text, new_placeholder_text)
          {:noreply, socket}

        {:error, error, sql, params} ->
          socket = socket
            |> assign(:error, error)
            |> assign(:debug, debug_filter(sql ,params))
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("form_updated", %{"_target" => ["filter_form", field], "filter_form" => form_values}, socket) do
    filter = String.replace_suffix(field, "_type", "")
    type_change? = String.ends_with?(field, "_type")
    exclusion_change? = (field == "exclude_internal")

    filter_index = if type_change?, do: get_filter_index(filter), else: 0
    live_select_id = "live_select#{filter_index}"

    form_values = if type_change? do
      # remove any existing filter values
      send_update(LiveSelect.Component, id: live_select_id, options: [])
      form_values |> Map.put(filter, [])
    else
      form_values
    end
    form = to_form(form_values, as: "filter_form")

    socket = assign(socket, :form, form)

    socket = if type_change? do
     update_options(socket, filter_index, form, field, live_select_id)
    else
      # Not a filter-type change event
      # If the change was adding or removing a value from one of the filters, we'll get a field like "filter1" or "filter1_empty_selection"
      changed_filter_index = if exclusion_change? do
        # The user has toggled the "exclude internal" checkbox; need to re-evaluate all filters
        0
      else
        case Regex.run(~r/^filter(\d+)(_empty_selection)?$/, field) do
          [_, numerals] ->
            # The user has added or deleted a value for this filter
            String.to_integer(numerals)
          [_, numerals, "_empty_selection"] ->
            # This means the user has deleted the last value for this filter, so now it's empty
            String.to_integer(numerals)
          _ -> nil
        end
      end

      if changed_filter_index && changed_filter_index < socket.assigns.num_filters do
        # There was a change in the filter values, so we need to update the options for any following filters
        Enum.reduce((changed_filter_index+1)..socket.assigns.num_filters, socket, fn i, acc ->
          update_options(acc, i, form, form["filter#{i}_type"].value, "live_select#{i}")
        end)
      else
        socket
      end

    end
    {:noreply, socket}
  end

  def handle_event("add_filter", _unsigned_params, socket) do
    num_filters = socket.assigns.num_filters
    form_params = socket.assigns.form.params

    filter_options = Enum.take(socket.assigns.filter_options, num_filters)
    filter_type_options = Enum.take(socket.assigns.filter_type_options, num_filters)

    new_num_filters = num_filters + 1

    existing_filters = Enum.map(1..num_filters, &(String.to_atom(form_params["filter#{&1}_type"])))
    new_filter_type_options = Enum.filter(socket.assigns.filter_types_included, fn {_key, value} -> !Enum.member?(existing_filters, value) end)

    socket = socket
      |> assign(:num_filters, new_num_filters)
      |> assign(:filter_options, filter_options ++ [[]])
      |> assign(:placeholder_text, socket.assigns.placeholder_text ++ [""])
      |> assign(:filter_type_options, filter_type_options ++ [new_filter_type_options])

    {:noreply, socket}
  end

  def handle_event("remove_filter", _unsigned_params, socket) do
    num_filters = socket.assigns.num_filters
    new_num_filters = num_filters - 1
    new_filter_options = Enum.take(socket.assigns.filter_options, new_num_filters)
    new_placeholder_text = Enum.take(socket.assigns.placeholder_text, new_num_filters)
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
      |> assign(:placeholder_text, new_placeholder_text)
      |> assign(:filter_type_options, new_filter_type_options)
      |> assign(:form, new_form)

    {:noreply, socket}
  end

  @impl true
  def handle_event("debug_form", _unsigned_params, %{assigns: %{report: %Report{} = report, form: form, num_filters: num_filters, user: user}} = socket) do
    if @dev do
      report_filter = ReportFilter.from_form(form, num_filters)

      with {:ok, query} <- report.get_query.(report_filter, user),
          {:ok, sql} <- ReportQuery.get_sql(query) do
        {:noreply, assign(socket, :debug, sql)}
      else
        {:error, error} ->
          {:noreply, assign(socket, :debug, "ERROR: #{error}")}
      end
    else
      # noop on production
      {:noreply, socket}
    end
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

  # Query for the set of options for one of the filters in the form and send an update to the LiveSelect component.
  # The values and placeholder text are also updated and socket values are assigned.
  # Returns the new socket structure.
  defp update_options(socket, filter_index, form, field, live_select_id) do
    report_filter = ReportFilter.from_form(form, filter_index)
    primary_filter = List.first(report_filter.filters)
    if (filter_index > 1 || Enum.member?(@no_search_required_fields, primary_filter)) do
      ## cohorts and subfilters we query the options right away, since there should be few
      case ReportFilterQuery.get_options(report_filter) do
        {:ok, options, sql, params} ->
          filter_options = socket.assigns.filter_options
            |> List.replace_at(filter_index - 1, options)
          send_update(LiveSelect.Component, id: live_select_id, options: options)

          # Remove any selected items in the filter value that are no longer among the options
          current_value = form["filter#{filter_index}"].value
          new_value =
            if current_value do
              valid_ids = Enum.map(options, fn {_name, id} -> id end)
              current_value
              |> Enum.filter(fn id -> Enum.member?(valid_ids, id) end)
            else
              []
            end
          send_update(LiveSelect.Component, id: live_select_id, value: new_value)

          placeholder_text = socket.assigns.placeholder_text
            |> List.replace_at(filter_index - 1, describe_options(form[field].value, "", options))

          socket
            |> assign(:error, nil)
            |> assign(:filter_options, filter_options)
            |> assign(:placeholder_text, placeholder_text)
            |> assign(:debug, debug_filter(sql ,params))

        {:error, error, sql, params} ->
          socket
            |> assign(:error, error)
            |> assign(:debug, debug_filter(sql ,params))
      end
    else
      ## Top level filter change that requires search: we just clear the options
      filter_options = socket.assigns.filter_options
        |> List.replace_at(filter_index - 1, [])
      send_update(LiveSelect.Component, id: live_select_id, options: [])
      placeholder_text = socket.assigns.placeholder_text
        |> List.replace_at(filter_index - 1, describe_options(form[field].value, "", nil))
      socket
        |> assign(:error, nil)
        |> assign(:filter_options, filter_options)
        |> assign(:placeholder_text, placeholder_text)
    end


  end

  defp describe_options(_field, search_text, options) do
    text_message = if search_text == "", do: "", else: "*#{search_text}*: "
    if options == nil do
        "#{text_message}Type at least 3 characters to search"
    else
      case Enum.count(options) do
        0 -> "#{text_message}No options available"
        1 -> "#{text_message}1 option available"
        n -> "#{text_message}#{n} options available"
      end
    end
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

  defp get_form_options(%Report{form_options: form_options}) do
    %{
      enable_hide_names: Keyword.get(form_options, :enable_hide_names, false)
    }
  end

end
