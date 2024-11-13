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

  def download_button(assigns) do
    ~H"""
      <button id={"report-download-button-#{@filetype}"} class="my-2 p-2 bg-rose-50 rounded text-sm"
              phx-hook="ReportDownloadButton" phx-click="download_report" phx-value-filetype={@filetype}>
        <.icon name="hero-arrow-down-tray" />
        Download as <%= @filetype %>
      </button>
    """
  end

  def sort_col_button(assigns) do
    icon = if assigns.column == assigns.sort do
      if assigns.sort_direction == :asc do
        "hero-arrow-down"
      else
        "hero-arrow-up"
      end
    else
      "hero-arrows-up-down"
    end
    ~H"""
    <button type="button" phx-click="sort_column" phx-value-column={@column}>
      <.icon name={icon} class="inline-block w-4 h-4 ml-1 cursor-pointer" />
    </button>
    """
  end

  @doc """
  Renders a navigation link in a square.
  """
  attr :results, :any, required: true
  def report_results(assigns) do
    ~H"""
    <div class="flex justify-between items-center">
      <strong>Query result: <%= @results.num_rows %> rows</strong>
      <span>
        <.download_button filetype="CSV"/>
        <.download_button filetype="JSON"/>
      </span>
    </div>
    <div class="bg-white text-sm overflow-auto sm:overflow-auto">
      <table class="w-full border-collapse">
        <thead class="bg-gray-100 text-left leading-6 text-zinc-500">
          <tr>
            <th :for={col <- @results.columns} class={["p-2 whitespace-nowrap border-b", (if col == @sort, do: "font-bold", else: "font-normal")]}>
              <%= String.replace(col, "_", " ") %>
              <.sort_col_button column={col} sort={@sort} sort_direction={@sort_direction} />
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
    <span :for={{slug, title, path} <- @report.parents}>
      <.link navigate={path} class="hover:underline"><%= title %></.link>
      <span>›</span>
    </span>
    <%= @report.title %>
    """
  end

end
