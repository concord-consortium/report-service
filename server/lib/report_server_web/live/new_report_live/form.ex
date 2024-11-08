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
  alias ReportServer.Reports.Report

  @filter_type_options [{"Select a filter...", ""}, {"Schools", "school"}, {"Cohorts", "cohort"}, {"Teachers", "teacher"}, {"Assignments", "assignment"}]

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(unsigned_params, _uri, socket) do
    slug = unsigned_params |> Map.get("slug")
    report = slug |> Reports.find()
    %{title: title, subtitle: subtitle} = get_report_info(slug, report)

    form = to_form(%{}, as: "filter_form")

    socket = socket
    |> assign(:report, report)
    |> assign(:title, title)
    |> assign(:subtitle, subtitle)
    |> assign(:page_title, "Reports: #{title}")
    |> assign(:results, nil)
    |> assign(:sort, nil)
    |> assign(:sort_direction, :asc)
    |> assign(:error, nil)
    |> assign(:form, form)
    |> assign(:num_filters, 1)
    |> assign(:filter_type_options, [@filter_type_options])

    {:noreply, socket}
  end

  @impl true
  def handle_event("live_select_change", %{"field" => field, "text" => text, "id" => live_select_id}, socket) do
    filter_index = get_filter_index(field)
    filter_type = socket.assigns.form.params["filter#{filter_index}_type"]

    if filter_type do
      # this would be replaced by a database query...
      options = Enum.map(1..5, &({"#{text} #{filter_type} #{&1}", "#{text}_#{filter_type}_#{&1}"}))
      send_update(LiveSelect.Component, id: live_select_id, options: options)
    end

    {:noreply, socket}
  end

  def handle_event("filters_updated", %{"filter_form" => form_values}, socket) do
    form = to_form(form_values, as: "filter_form")

    socket = socket
    |> assign(:form, form)

    {:noreply, socket}
  end

  def handle_event("add_filter", _unsigned_params, socket) do
    num_filters = socket.assigns.num_filters
    form_params = socket.assigns.form.params

    filter_type_options = Enum.take(socket.assigns.filter_type_options, num_filters)

    new_num_filters = num_filters + 1

    existing_filters = Enum.map(1..num_filters, &(form_params["filter#{&1}_type"]))
    new_filter_type_options = Enum.filter(@filter_type_options, fn {_key, value} -> !Enum.member?(existing_filters, value) end)

    socket = socket
      |> assign(:num_filters, new_num_filters)
      |> assign(:filter_type_options, filter_type_options ++ [new_filter_type_options])

    {:noreply, socket}
  end

  def handle_event("remove_filter", _unsigned_params, socket) do
    num_filters = socket.assigns.num_filters
    new_num_filters = num_filters - 1
    new_filter_type_options = Enum.take(socket.assigns.filter_type_options, new_num_filters)

    # remove the form values
    filter_key_prefix = "filter#{num_filters}"
    new_form = socket.assigns.form.params
      |> Enum.filter(fn {key, _value} -> !String.starts_with?(key, filter_key_prefix) end)
      |> Enum.into(%{})
      |> to_form(as: "filter_form")

    socket = socket
      |> assign(:num_filters, new_num_filters)
      |> assign(:filter_type_options, new_filter_type_options)
      |> assign(:form, new_form)

    {:noreply, socket}
  end

  @impl true
  def handle_event("submit_form", _unsigned_params, %{assigns: %{report: %Report{} = report}} = socket) do
    # when this is real the params would become the filters passed to the report run function
    socket = case report.run.([]) do
      {:ok, results} ->
        socket
        |> assign(:results, results)
        |> assign(:error, nil)
        |> assign(:sort, nil)
        |> assign(:sort_direction, :asc)

      {:error, error} ->
        socket
        |> assign(:results, nil)
        |> assign(:error, error)
    end

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

  def request_download(socket, data, filename) do
    socket
    |> push_event("download_report", %{data: data, filename: filename}) # TODO: more informative filename
  end

  def format_results(results, :CSV) do
    csv = results
      |> PortalDbs.map_columns_on_rows()
      |> tap(&IO.inspect(&1))
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

  defp get_filter_index(s), do: Regex.run(~r/(\d+)$/, s) |> List.last()

end