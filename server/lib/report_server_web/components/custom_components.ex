defmodule ReportServerWeb.CustomComponents do
  use Phoenix.Component

  import ReportServerWeb.CoreComponents

  def portal_stats(assigns) do
    ~H"""
    <div>
      <div class="text-1xl font-semibold text-gray-800 mb-1">
        Current Stats for <a href={"https://#{@server}"} target="_blank"><%= @server %></a>
        <span class="text-gray-500 text-xs">(auto updates every minute)</span>
      </div>

      <div class="flex gap-4 flex-wrap">
        <.portal_stats_card label="Students" value={@stats.num_students} />
        <.portal_stats_card label="Teachers" value={@stats.num_teachers} />
        <.portal_stats_card label="Classes" value={@stats.num_classes} />
        <.portal_stats_card label="Activities" value={@stats.num_activities} />
        <.portal_stats_card label="Assignments" value={@stats.num_offerings} />
      </div>
    </div>
    """
  end

  def portal_stats_card(assigns) do
    ~H"""
    <div class="bg-white shadow-lg hover:shadow-xl transition-shadow duration-300 rounded-lg p-6 w-40 h-40 flex flex-col justify-center items-center">
      <h2 class="text-[#0592af] text-lg font-semibold"><%= @label %></h2>
      <div class="text-2xl font-bold text-[#fdc32d] mt-2">
        <.formatted_value value={@value} />
      </div>
    </div>
    """
  end

  # formats numbers with commas every three value places
  def formatted_value(assigns) do
    ~H"""
    <%= @value
      |> Integer.to_string()
      |> String.graphemes()
      |> Enum.reverse()
      |> Enum.chunk_every(3)
      |> Enum.join(",")
      |> String.reverse()
    %>
    """
  end

  @doc """
  Renders a navigation link in a square.

  ## Examples

      <.square_link navigate={~p"/reports"}>Reports</.back>
  """
  attr :navigate, :any, required: true
  attr :class, :string, default: nil
  slot :inner_block, required: true

  def square_link(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class={["text-center rounded p-6 text-white text-xl w-40 h-40 bg-orange hover:bg-light-orange hover:text-orange hover:border hover:border-orange flex flex-col justify-center items-center font-bold hover:bg-blue-700", @class]}>
      <%= render_slot(@inner_block) %>
    </.link>
    """
  end

  @doc """
  Renders a square link with a description next to it.
  attr :navigate, :any, required: true
  attr :description, :string, required: true
  attr :inner_block, :any, required: true
  """
  def described_link(assigns) do
    ~H"""
    <div class="flex items-center my-4">
      <.square_link navigate={@navigate} class="flex-shrink-0">
        <%= render_slot(@inner_block) %>
      </.square_link>
      <div class="ml-4">
        <%= @description %>
      </div>
    </div>
    """
  end

  def download_button(assigns) do
    ~H"""
      <button id={"report-download-button-#{@filetype}"} class="my-2 p-2 bg-rose-50 rounded text-sm"
              phx-hook="ReportDownloadButton" phx-click="download_report" phx-value-filetype={@filetype}>
        <.icon name="hero-arrow-down-tray" />
        Download as <%= String.upcase(@filetype) %>
      </button>
    """
  end

  def sort_col_button(assigns) do
    icon = if assigns.column == assigns.primary_sort do
      if assigns.sort_direction == :asc do
        "hero-arrow-down"
      else
        "hero-arrow-up"
      end
    else
      "hero-arrows-up-down"
    end
    assigns = assign(assigns, :icon, icon)
    ~H"""
    <button type="button" phx-click="sort_column" phx-value-column={@column}>
      <.icon name={@icon} class="inline-block w-4 h-4 ml-1 cursor-pointer" />
    </button>
    """
  end

  def report_header(assigns) do
    ~H"""
    <div class="flex justify-between items-center">
      <strong>
        <.async_result :let={count} assign={@row_count}>
          <:loading>Counting records...</:loading>
          <:failed>There was an error in counting the records</:failed>
          <span>Total: <%= count %> rows.</span>
          <span :if={count > @row_limit}>Showing the first <%= @row_limit %>.</span>
        </.async_result>
      </strong>
      <span>
        <.download_button filetype="csv"/>
        <.download_button filetype="json"/>
      </span>
    </div>
    """
  end

  @doc """
  Renders the report results
  """
  attr :results, :any, required: true
  attr :primary_sort, :string, default: nil
  attr :sort_direction, :string, default: nil
  def report_results(assigns) do
    ~H"""
    <div class="bg-white text-sm overflow-auto sm:overflow-auto">
      <table class="w-full border-collapse">
        <thead class="bg-gray-100 text-left leading-6 text-zinc-500">
          <tr>
            <th :for={col <- @results.columns} class={["p-2 whitespace-nowrap border-b capitalize", (if col == @primary_sort, do: "font-bold", else: "font-normal")]}>
              <%= String.replace(col, "_", " ") %>
              <.sort_col_button column={col} primary_sort={@primary_sort} sort_direction={@sort_direction} />
            </th>
          </tr>
        </thead>
        <tbody>
          <tr :for={row <- @results.rows} class="group hover:bg-zinc-200 even:bg-gray-50">
            <td :for={col <- row} class="p-2 font-normal border-b">
              <%= col %>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr :report, :any, required: true
  def report_breadcrumbs(assigns) do
    ~H"""
    <span :for={{_slug, title, path} <- @report.parents}>
      <.link navigate={path} class="hover:underline"><%= title %></.link>
      <span>›</span>
    </span>
    <%= @report.title %>
    """
  end

  attr :previous, :any, required: true
  attr :current, :string, required: true
  def breadcrumbs(assigns) do
    ~H"""
    <span :for={{title, path} <- @previous}>
      <.link navigate={path} class="hover:underline"><%= title %></.link>
      <span>›</span>
    </span>
    <%= @current %>
    """
  end

  attr :report_run, :any, required: true
  def report_filter_values(assigns) do
    ~H"""
    <div class="table">
      <div class="table-row" :for={filter <- Enum.reverse(@report_run.report_filter.filters)}>
        <div class="table-cell capitalize font-bold"><%= filter %>s</div>
        <div class="table-cell pl-3"><%= Enum.join(Map.values(@report_run.report_filter_values[filter] || %{}), ", ") %></div>
      </div>
    </div>
    """
  end

  attr :timestamp, :string, required: true
  def relative_time(assigns) do
    now = DateTime.utc_now() |> DateTime.to_unix()
    diff = now - DateTime.to_unix(assigns.timestamp)

    relative_time_result = cond do
      diff < 60 ->
        "Just now"

      diff < 3600 ->
        minutes = div(diff, 60)
        "#{minutes} #{pluralize(minutes, "minute")} ago"

      diff < 86_400 ->
        hours = div(diff, 3600)
        "#{hours} #{pluralize(hours, "hour")} ago"

      true ->
        days = div(diff, 86_400)
        "#{days} #{pluralize(days, "day")} ago"
    end

    assigns = assign(assigns, :relative_time_result, relative_time_result)

    ~H"<%= @relative_time_result %>"
  end

  attr :report_runs, :any, required: true
  attr :include_report_titles, :boolean, default: false
  attr :include_user, :boolean, default: false
  def report_runs(assigns) do
    report_titles = Enum.reduce(assigns.report_runs, %{}, fn %{report_slug: report_slug}, acc ->
      report = ReportServer.Reports.Tree.find_report(report_slug)
      title = if report, do: report.title, else: "Unknown report: #{report_slug}"
      Map.put(acc, report_slug, title)
    end)
    assigns = assign(assigns, :report_titles, report_titles)

    ~H"""
      <table class="w-full border-collapse bg-white text-sm">
        <thead class="bg-gray-100 text-left leading-6 text-zinc-500">
          <tr>
            <th class="p-2 font-normal border-b">Run</th>
            <th class="p-2 font-normal border-b" :if={@include_user}>User</th>
            <th class="p-2 font-normal border-b" :if={@include_report_titles}>Report</th>
            <th class="p-2 font-normal border-b">Filters</th>
            <th class="p-2 font-normal border-b">Ran</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={report_run <- @report_runs} class="group hover:bg-zinc-200 even:bg-gray-50">
            <td class="p-2 font-normal border-b align-top"><.link class="underline" href={"/new-reports/runs/#{report_run.id}"}><%= report_run.id %></.link></td>
            <td class="p-2 font-normal border-b align-top" :if={@include_user}><%= report_run.user.portal_first_name %> <%= report_run.user.portal_last_name %></td>
            <td class="p-2 font-normal border-b align-top" :if={@include_report_titles}><%= @report_titles[report_run.report_slug] %></td>
            <td class="p-2 font-normal border-b align-top"><.report_filter_values report_run={report_run} /></td>
            <td class="p-2 font-normal border-b align-top"><.relative_time timestamp={report_run.inserted_at} /></td>
          </tr>
        </tbody>
      </table>
    """
  end

  defp pluralize(count, word) do
    if count == 1, do: word, else: word <> "s"
  end

end
