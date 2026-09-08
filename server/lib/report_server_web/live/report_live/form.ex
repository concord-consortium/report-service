defmodule ReportServerWeb.ReportLive.Form do
  @doc """
  Render the form for a new report.
  May eventually get a different @live_action to show the result of the report.
  """

  use ReportServerWeb, :live_view

  import LiveSelect

  require Logger

  alias Jason
  alias ReportServer.Accounts.User
  alias ReportServer.PortalDbs
  alias ReportServer.Reports
  alias ReportServer.Reports.{HideNames, Report, Tree, ReportFilter, ReportQuery, ReportFilterQuery}
  alias ReportServer.Reports.Athena.{AthenaConfig, LearnerData}
  alias ReportServer.Reports.PartitionEstimate

  @filter_types %{
    :school => "Schools",
    :cohort => "Cohorts",
    :teacher => "Teachers",
    :assignment => "Assignments",
    :class => "Classes",
    :student => "Students",
    :permission_form => "Permission Forms",
    :country => "Countries",
    :state => "States",
    :subject_area => "Subject Areas",
  }

  @max_auto_options_length 200
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
    |> assign(:form_options, get_form_options(report, user))
    |> assign(:app_options, AthenaConfig.app_options())
    |> assign(:checking_partitions, false)
    |> assign(:count_task_ref, nil)
    |> assign(:pending_report_filter, nil)
    |> assign(:partition_warning, nil)
    |> assign(:placeholder_text, [""])
    |> assign(:dev, @dev)
    |> assign(:allowed_project_ids, PortalDbs.get_allowed_project_ids(user))

    {:noreply, socket}
  end

  ## Called when the text in one of the search boxes changes
  @impl true
  def handle_event("live_select_change", %{"field" => field, "text" => text, "id" => live_select_id}, socket = %{assigns: %{form: form, user: user, allowed_project_ids: allowed_project_ids}}) do
    filter_index = get_filter_index(field)
    report_filter = ReportFilter.from_form(form, filter_index)
      |> HideNames.enforce(user)
    if String.length(text) >= 3 || has_few_options?(report_filter, filter_index, user, allowed_project_ids, text) do
      case ReportFilterQuery.get_options(report_filter, user, allowed_project_ids, text) do
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

  ## Called when the pulldowns are changed, selections are added/removed, or the "exclude internal" checkbox is toggled
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
    {:noreply, clear_stale_warning(socket)}
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

    {:noreply, clear_stale_warning(socket)}
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

    {:noreply, clear_stale_warning(socket)}
  end

  @impl true
  def handle_event("debug_form", _unsigned_params, %{assigns: %{report: %Report{} = report, form: form, num_filters: num_filters, user: user}} = socket) do
    if @dev do
      report_filter = ReportFilter.from_form(form, num_filters)
        |> HideNames.enforce(user)

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

  # the form still submits on Enter while the Run Report button is disabled, and a second count
  # would orphan the first, whose reply would then match no clause
  @impl true
  def handle_event("submit_form", _unsigned_params, %{assigns: %{checking_partitions: true}} = socket) do
    {:noreply, socket}
  end

  def handle_event("submit_form", _unsigned_params, %{assigns: %{form: form, num_filters: num_filters, user: user, form_options: form_options}} = socket) do
    report_filter = ReportFilter.from_form(form, num_filters)
      |> HideNames.enforce(user)

    case check_app_supported(report_filter, form_options) do
      :ok ->
        if warning_applicable?(form_options) do
          {:noreply, start_count_task(socket, report_filter)}
        else
          {:noreply, create_run(socket, report_filter)}
        end

      {:error, message} ->
        {:noreply, assign(socket, :error, message)}
    end
  end

  @impl true
  def handle_event("submit_form_confirmed", _unsigned_params, %{assigns: %{pending_report_filter: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event("submit_form_confirmed", _unsigned_params, %{assigns: %{pending_report_filter: report_filter}} = socket) do
    {:noreply, create_run(socket, report_filter)}
  end

  # only the reports reading the partitioned log table can hit the partition ceiling, and they are
  # exactly the ones offering the filter
  defp warning_applicable?(%{enable_app_filter: enable_app_filter}), do: enable_app_filter

  # a blocking call in a handler cannot render a checking state, so the count runs as a task
  defp start_count_task(%{assigns: %{user: user}} = socket, report_filter) do
    task = Task.Supervisor.async_nolink(ReportServer.PostProcessingTaskSupervisor, fn ->
      learner_data().count(report_filter, user)
    end)

    socket
      |> assign(:checking_partitions, true)
      |> assign(:count_task_ref, task.ref)
      |> assign(:pending_report_filter, report_filter)
      |> assign(:partition_warning, nil)
      |> assign(:error, nil)
  end

  @impl true
  def handle_info({ref, {:ok, learner_count}}, socket) when ref == socket.assigns.count_task_ref do
    Process.demonitor(ref, [:flush])
    socket = count_finished(socket)
    report_filter = socket.assigns.pending_report_filter

    case partition_warning(learner_count, report_filter) do
      nil -> {:noreply, create_run(socket, report_filter)}
      warning -> {:noreply, assign(socket, :partition_warning, warning)}
    end
  end

  # the estimate is advisory, so a count that fails or crashes creates the run rather than
  # blocking it
  @impl true
  def handle_info({ref, {:error, error}}, socket) when ref == socket.assigns.count_task_ref do
    Process.demonitor(ref, [:flush])
    Logger.error("Unable to count learners for the partition estimate: #{inspect(error)}")
    socket = count_finished(socket)

    {:noreply, create_run(socket, socket.assigns.pending_report_filter)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, socket) when ref == socket.assigns.count_task_ref do
    Logger.error("Learner count for the partition estimate crashed: #{inspect(reason)}")
    socket = count_finished(socket)

    {:noreply, create_run(socket, socket.assigns.pending_report_filter)}
  end

  # the warning describes the filter the count was made against, so an edited form invalidates it.
  # An in-flight count keeps its snapshot: the completion handlers pattern match %ReportFilter{},
  # so clearing it mid-count would crash the view. Nothing is shielded once a warning is on screen,
  # because count_finished/1 runs before the warning is assigned.
  defp clear_stale_warning(%{assigns: %{checking_partitions: true}} = socket), do: socket

  defp clear_stale_warning(socket) do
    socket
      |> assign(:partition_warning, nil)
      |> assign(:pending_report_filter, nil)
  end

  defp count_finished(socket) do
    socket
      |> assign(:checking_partitions, false)
      |> assign(:count_task_ref, nil)
  end

  defp partition_warning(learner_count, %ReportFilter{app: app, start_date: start_date, end_date: end_date}) do
    partitions = PartitionEstimate.projected_partitions(learner_count, app, start_date, end_date)
    apps = PartitionEstimate.app_count(app)
    months = PartitionEstimate.period_months(start_date, end_date)
    threshold = PartitionEstimate.warning_threshold()

    if partitions > threshold do
      "This report covers #{delimit(learner_count)} learners. Athena would need to check " <>
        "#{delimit(learner_count)} learners x #{delimit(apps)} applications x #{delimit(months)} months = " <>
        "#{delimit(partitions)} partitions, over the #{delimit(threshold)} limit. Selecting fewer " <>
        "applications, or narrowing the date range, will reduce it. You can run it anyway."
    end
  end

  defp learner_data,
    do: Application.get_env(:report_server, :learner_data, LearnerData)

  defp delimit(number) do
    number
      |> Integer.to_string()
      |> String.reverse()
      |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
      |> String.reverse()
  end

  defp create_run(%{assigns: %{report: %Report{} = report, user: user}} = socket, report_filter = %ReportFilter{}) do
    report_filter_values = ReportFilter.get_filter_values(report_filter, user)

    report_run_attrs = %{
      report_slug: report.slug,
      report_filter: report_filter,
      report_filter_values: report_filter_values,
      user_id: user.id,
    }

    case Reports.create_report_run(report_run_attrs) do
      {:ok, report_run} ->
        socket
          |> redirect(to: ~p"/reports/runs/#{report_run.id}")

      {:error, changeset} ->
        Logger.error(changeset)
        socket
          |> assign(:partition_warning, nil)
          |> assign(:pending_report_filter, nil)
          |> assign(:error, "Unable to create report run!")
    end
  end

  # Query for the set of options for one of the filters in the form and send an update to the LiveSelect component.
  # The values and placeholder text are also updated and socket values are assigned.
  # Returns the new socket structure.
  defp update_options(socket = %{assigns: %{user: user, allowed_project_ids: allowed_project_ids}}, filter_index, form, field, live_select_id) do
    report_filter = ReportFilter.from_form(form, filter_index)
      |> HideNames.enforce(user)

    set_options_immediately = has_few_options?(report_filter, filter_index, user, allowed_project_ids)
    if set_options_immediately do
      case ReportFilterQuery.get_options(report_filter, user, allowed_project_ids) do
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

  defp has_few_options?(report_filter, filter_index, user, allowed_project_ids, like_text \\ "")

  # since there are a lot of students in the system, we should skip getting the count
  # when it is the first filter
  defp has_few_options?(%ReportFilter{filters: [:student]}, 1, _user, _allowed_project_ids, _like_text) do
    Logger.debug("Skipping student count for first filter")
    false
  end

  defp has_few_options?(report_filter, filter_index, user, allowed_project_ids, like_text) do
    cond do
      filter_index > 1 -> true
      {:ok, count } = ReportFilterQuery.get_option_count(report_filter, user, allowed_project_ids, like_text) ->
        Logger.debug("Count of options for filter #{filter_index}: #{inspect(count)}")
        count <= @max_auto_options_length
      true -> false
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

  defp get_form_options(%Report{form_options: form_options}, user = %User{}) do
    %{
      enable_hide_names: HideNames.allowed?(user) && Keyword.get(form_options, :enable_hide_names, false),
      enable_app_filter: Keyword.get(form_options, :enable_app_filter, false)
    }
  end

  defp check_app_supported(%ReportFilter{app: app}, form_options) do
    apps = ReportFilter.app_list(app)

    cond do
      # a blank app is acceptable on every report, including those with no control
      apps == [] -> :ok
      !form_options.enable_app_filter -> {:error, "This report does not support an application filter."}
      true -> check_apps_known(apps)
    end
  end

  # get_athena_query/3 rejects an unknown value too, but only after the report has run the portal
  # join and uploaded the learner data, so the researcher sees a failed run instead of a form error
  defp check_apps_known(apps) do
    case Enum.reject(apps, &(&1 in AthenaConfig.get_log_apps())) do
      [] -> :ok
      unknown -> {:error, "Unknown application#{if length(unknown) > 1, do: "s"}: #{Enum.join(unknown, ", ")}"}
    end
  end
end
