defmodule ReportServerWeb.Dashboard do
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

end
