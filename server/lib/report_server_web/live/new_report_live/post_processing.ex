defmodule ReportServerWeb.NewReportLive.PostProcessingComponent do
  use ReportServerWeb, :live_component

  require Logger

  alias Phoenix.PubSub
  alias ReportServer.AthenaDB
  alias ReportServer.PostProcessing.{JobServer, JobSupervisor}
  alias ReportServer.Reports.{Report, ReportRun}

  @button_class "rounded px-2 py-1 text-xs bg-orange border border-orange text-white text-sm hover:bg-light-orange hover:text-orange hover:border hover:border-orange disabled:bg-slate-500 disabled:border-slate-500 disabled:text-white disabled:opacity-35"

  # always use live mode for post processing in this component
  @mode "live"


  # initial load
  @impl true
  def update(%{report: report, report_run: report_run} = assigns, socket) do
    show_component = show_component?(report, report_run)

    socket = socket
    |> assign(assigns)
    |> assign(:show_component, show_component)

    if show_component do
      {:ok, init(report_run, socket)}
    else
      {:ok, socket}
    end
  end

  # when sent a list of jobs by parent
  @impl true
  def update(%{jobs: jobs}, socket) do
    {:ok, socket |> assign(%{loading_jobs: false, jobs: jobs})}
  end

  def init(report_run, socket) do
    query_id = report_run.athena_query_id

    # listen for pubsub messages from the post processing server
    PubSub.subscribe(ReportServer.PubSub, JobServer.query_topic(query_id))

    JobSupervisor.maybe_start_server(query_id, @mode)
    JobServer.register_client(query_id, self())
    JobServer.request_job_status(query_id)

    report_type = get_report_type(report_run)

    steps = JobServer.get_steps(@mode, report_type)
    default_form_params =  steps |> Enum.map(fn step -> {step.id, false} end) |> Enum.into(%{})
    form = to_form(default_form_params)

    socket
      |> assign(%{
        :query_id => query_id,
        :button_class => @button_class,
        :form_disabled => true,
        :form_version => 1,  # hacky way to reset form after a submit
        :loading_jobs => true,
        :jobs => [],
        :steps => steps,
        :default_form_params => default_form_params,
        :form => form
      })
  end

  @impl true
  def render(assigns) do
    if assigns.show_component do
      ~H"""
      <div class="my-2 p-2 bg-slate-100 border-slate-300 border-2 hover:bg-white hover:border-slate-500">
        <div class="flex gap-2 w-full">
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
                <div :if={job.result == nil} class="italic">
                  Processing row: <%= job.rows_processed %>
                </div>
                <button
                  :if={job.result != nil}
                  id={"download_job_#{@query_id}_#{job.id}"}
                  phx-hook="DownloadButton"
                  data-id={@myself}
                  data-type="job"
                  data-job-id={job.id}
                  class={@button_class}
                  disabled={job.result == nil}
                >
                  Download Result
                </button>
                <button
                  :if={job.result != nil}
                  id={"copy_job_#{@query_id}_#{job.id}"}
                  phx-hook="DownloadButton"
                  data-id={@myself}
                  data-type="job"
                  data-job-id={job.id}
                  data-copy="true"
                  class={@button_class}
                  disabled={job.result == nil}
                >
                  Copy Result URL
                </button>
              </div>
            </div>
          </div>
        </div>
      </div>
      """
    else
      ~H"""
      <div></div>
      """
    end
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
  def handle_event("submit_form", params, socket = %{assigns: %{query_id: query_id, steps: steps, form_version: form_version, report_run: report_run, default_form_params: default_form_params, portal_server: portal_server}}) do
    steps =
      params
      |> Enum.reduce([], fn
        {step_id, "true"}, acc ->
          step = Enum.find(steps, fn step -> step.id == step_id end)
          [step | acc]
        _, acc -> acc
      end)
      |> JobServer.sort_steps()

    JobServer.add_job(query_id, %{id: query_id, output_location: report_run.athena_result_url}, steps, portal_server)

    {:noreply, socket
      |> assign(:form_version, form_version + 1)
      |> assign(:form_disabled, true)
      |> assign(:form, to_form(default_form_params))
    }
  end

  @impl true
  def handle_event("download", params = %{"type" => type}, socket = %{assigns: %{report_run: report_run, jobs: jobs}}) do
    presigned_url = case type do
      "job" ->
        job = Enum.find(jobs, fn %{id: id} -> "#{id}" == params["jobId"] end)
        filename = "#{report_run.report_slug}-run-#{report_run.id}-job-#{job.id}.csv"

        case AthenaDB.get_download_url(job.result, filename) do
          {:ok, download_url} -> download_url
          _ -> nil
        end

      _ -> nil
    end

    {:reply, %{url: presigned_url}, socket}
  end

  # for backwards compatibility with the job server use "details" for the student-answers report
  defp get_report_type(%{report_slug: "student-answers"} = %ReportRun{}), do: "details"
  defp get_report_type(%{report_slug: report_slug} = %ReportRun{}), do: report_slug

  def show_component?(report = %Report{}, report_run = %ReportRun{}) do
    if report.type == :athena && report_run.athena_query_state == "succeeded" do
      report_type = get_report_type(report_run)
      steps = JobServer.get_steps(@mode, report_type)
      length(steps) > 0
    else
      false
    end
  end

end
