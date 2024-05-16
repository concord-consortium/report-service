defmodule ReportServerWeb.ReportLive.QueryComponent do
  alias ReportServer.PostProcessing.JobServer
  alias Phoenix.PubSub
  alias ReportServer.PostProcessing.JobManager
  use ReportServerWeb, :live_component

  alias ReportServerWeb.Aws

  @name_regex ~r/-- name ([^\n]*)\n/
  @type_regex ~r/-- type ([^\n]*)\n/

  @poll_interval 5_000 # 5 seconds

  @button_class "rounded px-3 py-2 bg-orange border border-orange text-white text-sm hover:bg-light-orange hover:text-orange hover:border hover:border-orange disabled:bg-slate-500 disabled:border-slate-500 disabled:text-white disabled:opacity-35"
  @small_button_class "#{@button_class} px-2 py-1 text-xs"

  # initial load
  @impl true
  def update(%{id: id, workgroup_credentials: _, mode: mode} = assigns, socket) do

    # listen for pubsub messages from the post processing server
    PubSub.subscribe(ReportServer.PubSub, JobServer.query_topic(id))

    steps = JobServer.get_steps(mode)
    default_form_params =  steps |> Enum.map(fn step -> {step.id, false} end) |> Enum.into(%{})

    # save the initial assigns
    socket = socket
      |> assign(assigns)
      |> assign(%{
        :button_class => @button_class,
        :small_button_class => @small_button_class,
        :show_form => false,
        :steps => steps,
        :default_form_params => default_form_params,
        :form => to_form(default_form_params),
        :form_disabled => true,
        :form_version => 1,  # hacky way to reset form after a submit
        :loading_jobs => true,
        :jobs => []
      })

    {:ok, get_query_info(assigns, socket)}
  end

  # when commanded to poll by parent after the trigger_poll send timeout
  @impl true
  def update(%{poll: true}, socket) do
    {:ok, get_query_info(socket.assigns, socket)}
  end

  # when sent a list of jobs by parent
  @impl true
  def update(%{jobs: jobs}, socket) do
    {:ok, socket |> assign(%{loading_jobs: false, jobs: jobs})}
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
            <div class="flex flex-col gap-2">
              <button
                id={"download_original_#{query.id}"}
                phx-hook="DownloadButton"
                data-id={@myself}
                data-type="original"
                class={@button_class}>
                Download CSV
              </button>
              <button :if={length(@steps) > 0}
                class={@button_class}
                phx-click="show_form"
                phx-target={@myself}>
                Toggle Post Processing
              </button>
            </div>
          </div>
        </div>
        <div :if={query.state == "succeeded" && @show_form} class="flex gap-2 w-full">
          <div class="grow w-full my-2">
            <div class="font-bold text-sm">Select Post Processing Steps:</div>
            <.form id={"form_#{@form_version}"} for={@form} phx-change="validate_form" phx-submit="submit_form" phx-target={@myself} class="mt-2">
              <div class="space-y-1">
                <.input :for={step <- @steps} type="checkbox" field={@form[step.id]} label={step.label} />
              </div>
              <div class="mt-3">
                <button class={@button_class} disabled={@form_disabled}>Create New Post Processing Job</button>
              </div>
            </.form>
          </div>
          <div class="grow w-full my-2 text-sm">
            <div :if={@loading_jobs} class="h-full flex justify-center items-center">
              Loading jobs...
            </div>
            <div :if={!@loading_jobs && length(@jobs) == 0} class="h-full flex justify-center items-center">
              No past or current post processing jobs were found
            </div>
            <div :if={!@loading_jobs && length(@jobs) > 0} class="flex gap-2 flex-col">
              <div :for={job <- @jobs}>
                <div class="font-bold">Job: <%= job.id %> (<span class="capitalize"><%= job.status %></span>)</div>
                <ul :for={step <- job.steps}>
                  <li><%= step.label %></li>
                </ul>
                <button
                  id={"download_job_#{query.id}_#{job.id}"}
                  phx-hook="DownloadButton"
                  data-id={@myself}
                  data-type="job"
                  data-job-id={job.id}
                  class={@small_button_class}
                  disabled={job.result == nil}
                >
                  Download Result
                </button>
              </div>
            </div>
          </div>
        </div>
      </.async_result>
    </div>
    """
  end

  @impl true
  def handle_event("show_form", _params, socket = %{assigns: %{id: id, mode: mode, show_form: show_form}}) do
    show_form = !show_form
    if show_form do
      JobManager.maybe_start_server(id, mode)
      JobServer.request_job_status(id)
    end
    {:noreply, socket |> assign(:show_form, show_form)}
  end

  @impl true
  def handle_event("validate_form", params, socket = %{assigns: %{steps: steps}}) do
    # form is disabled if all the step checkboxes are false
    form_disabled = Enum.reduce(params, true, fn {k, v}, acc ->
      acc && (Enum.find(steps, fn step -> step.id == k end) == nil || v == "false")
    end)
    {:noreply, socket
      |> assign(:form_disabled, form_disabled)
      |> assign(:form, to_form(params))
    }
  end

  @impl true
  def handle_event("submit_form", params, socket = %{assigns: %{id: id, query: query, steps: steps, form_version: form_version, default_form_params: default_form_params}}) do
    steps =
      params
      |> Enum.reduce([], fn
        {step_id, "true"}, acc ->
          step = Enum.find(steps, fn step -> step.id == step_id end)
          [step | acc]
        _, acc -> acc
      end)
    JobServer.add_job(id, query.result, steps)

    {:noreply, socket
      |> assign(:form_version, form_version + 1)
      |> assign(:form_disabled, true)
      |> assign(:form, to_form(default_form_params))
    }
  end

  @impl true
  def handle_event("download", params = %{"type" => type}, socket = %{assigns: %{mode: "demo", jobs: jobs}}) do
    presigned_url = case type do
      "original" -> "/reports/demo.csv"

      "job" ->
        job = Enum.find(jobs, fn %{id: id} -> "#{id}" == params["jobId"] end)
        result = Base.encode64(job.result)
        "/reports/job.csv?filename=job-#{job.id}.csv&result=#{result}"

      _ -> nil
    end

    {:reply, %{url: presigned_url}, socket}
  end


  @impl true
  def handle_event("download", params = %{"type" => type}, socket = %{assigns: %{query: query, workgroup_credentials: workgroup_credentials, mode: mode, jobs: jobs}}) do
    {download, credentials} = case type do
      "original" ->
        query = query
        if query.ok? do
          {{query.result.output_location, "#{query.result.name || "unnamed"}-#{query.result.id}", "csv"}, workgroup_credentials}
        else
          {nil, nil}
        end

      "job" ->
        job = Enum.find(jobs, fn %{id: id} -> "#{id}" == params["jobId"] end)
        {{job.result, "#{query.result.name || "unnamed"}-#{query.result.id}-job-#{job.id}", "csv"}, Aws.get_server_credentials()}

      _ -> {nil, nil}
    end

    presigned_url = if download && credentials do
      {s3_url, basename, extension} = download
      basename = basename |> String.downcase() |> String.replace(~r/\W/, "-")
      case Aws.get_presigned_url(mode, credentials, s3_url, "#{basename}.#{extension}") do
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
