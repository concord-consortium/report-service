defmodule ReportServerWeb.ReportLive.QueryComponent do
  use ReportServerWeb, :live_component

  alias ReportServerWeb.Aws

  @name_regex ~r/-- name ([^\n]*)\n/
  @type_regex ~r/-- type ([^\n]*)\n/

  @poll_interval 5_000 # 5 seconds

  # initial load
  @impl true
  def update(%{id: _, workgroup_credentials: _, mode: _} = assigns, socket) do
    # save the initial assigns
    socket = socket |> assign(assigns)

    {:ok, get_query_info(assigns, socket)}
  end

  # when commanded to poll by parent after the trigger_poll send timeout
  @impl true
  def update(%{poll: true}, socket) do
    {:ok, get_query_info(socket.assigns, socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="my-2 p-2 bg-slate-100 border-slate-300 border-2 hover:bg-white hover:border-slate-500">
      <.async_result :let={query} assign={@query}>
        <:loading><div class="italic">Loading report...</div></:loading>
        <:failed :let={{:error, reason}}><div class="text-red-500">There was an error loading the report: <%= reason %></div></:failed>
        <div class="flex justify-between">
          <div>
            <div :if={query.name}>Name: <span class="font-bold"><%= query.name %></span></div>
            <div :if={!query.name}>Name: <span class="font-bold italic">Unnamed Report</span></div>
            <div :if={query.type} class="text-sm">Type: <span class="capitalize"><%= query.type %></span></div>
            <div :if={!query.type} class="text-sm">Type: <span class="font-bold italic">Unknown Type</span></div>
            <div class="text-sm">Creation date: <span id={"date_#{query.id}"} phx-hook="QueryDate" data-date={query.submission_date_time} /></div>
            <div class="text-sm">Completion status: <span class={"capitalize #{state_class(query.state)}"}><%= query.state %></span></div>
          </div>
          <div :if={query.state == "succeeded" && query.output_location}>
            <button
              id={"download_original_#{query.id}"}
              phx-hook="DownloadButton"
              data-id={@myself}
              data-type="original"
              class="rounded px-3 py-2 bg-orange text-white text-sm hover:bg-light-orange hover:text-orange hover:border hover:border-orange">Download CSV</button>
          </div>
        </div>
      </.async_result>
    </div>
    """
  end

  @impl true
  def handle_event("download", %{"type" => type}, socket) do
    download = case type do
      "original" ->
        query = socket.assigns.query
        if query.ok? do
          {query.result.output_location, "#{query.result.name || "unnamed"}-#{query.result.id}", "csv"}
        else
          nil
        end
      _ -> nil
    end

    workgroup_credentials = socket.assigns.workgroup_credentials
    presigned_url = if download && workgroup_credentials do
      mode = socket.assigns.mode
      {s3_url, basename, extension} = download
      basename = basename |> String.downcase() |> String.replace(~r/\W/, "-")
      case Aws.get_presigned_url(mode, workgroup_credentials, s3_url, "#{basename}.#{extension}") do
        {:ok, url} -> url
        _ -> nil
      end
    else
      nil
    end

    {:reply, %{url: presigned_url}, socket}
  end

  defp get_query_info(%{id: query_id, workgroup_credentials: workgroup_credentials, mode: mode}, socket) do
    # the assign_async callback runs in a task so get the current pid to pass to it to use to start the poller
    self = self()
    socket |> assign_async(:query, fn -> async_get_query_info(mode, workgroup_credentials, query_id, self) end)
  end

  defp async_get_query_info(mode, workgroup_credentials, query_id, self) do
    case Aws.get_query_execution(mode, workgroup_credentials, query_id) do
      {:ok, raw_query} ->
        query = parse_query(query_id, raw_query)
        if trigger_poll?(query.state) do
          # this sends a message to the parent liveview after @poll_interval milliseconds which then sends a message back to this component to poll for changes
          Process.send_after(self, {:trigger_poll, query_id}, @poll_interval)
        end
        {:ok, %{query: query}}
      error -> error
    end
  end

  defp parse_query(query_id, query = %{"Query" => sql, "Status" => %{"State" => state, "SubmissionDateTime" => submission_date_time}}) do
    name = case Regex.run(@name_regex, sql) do
      [_, name] -> name
      _ -> nil
    end
    type = case Regex.run(@type_regex, sql) do
      [_, type] -> type
      _ -> nil
    end

    %{
      id: query_id,
      name: name,
      type: type,
      state: String.downcase(state),
      submission_date_time: submission_date_time,
      output_location: query["ResultConfiguration"] && query["ResultConfiguration"]["OutputLocation"]
    }
  end

  defp state_class("queued"), do: "text-blue-700"
  defp state_class("running"), do: "text-blue-700"
  defp state_class("succeeded"), do: "text-green-700"
  defp state_class("failed"), do: "text-red-700"
  defp state_class("cancelled"), do: "text-red-700"
  defp state_class(_), do: ""

  defp trigger_poll?("queued"), do: true
  defp trigger_poll?("running"), do: true
  defp trigger_poll?(_), do: false
end
