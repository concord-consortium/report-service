defmodule ReportServerWeb.CustomComponents do
  use Phoenix.Component

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
      <button id="report-download-button" class="my-2 p-2 bg-rose-50 rounded"
              phx-hook="ReportDownloadButton" phx-click="download_report" phx-value-filetype={@filetype}>
        Download as <%= @filetype %>
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
      <table class="w-full">
        <thead class="text-left leading-6 text-zinc-500">
          <tr>
            <th :for={col <- @results.columns} class="p-2 font-normal"><%= col %></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={row <- @results.rows} class="group hover:bg-zinc-200">
            <td :for={col <- row} class="p-2 font-normal">
              <%= col %>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

end
