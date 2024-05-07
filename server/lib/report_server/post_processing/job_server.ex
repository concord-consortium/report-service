defmodule ReportServer.PostProcessing.JobServer do
  alias Phoenix.PubSub
  use GenServer

  alias ReportServer.PostProcessing.Job
  alias ReportServer.PostProcessing.Steps.{DemoUpperCase, DemoAddAnswerLength}

  def start_link(query_id, mode) do
    GenServer.start_link(__MODULE__, %{query_id: query_id, mode: mode, jobs: []}, name: {:via, Registry, {ReportServer.PostProcessingRegistry, query_id}})
  end

  def get_steps("demo"), do: [
    DemoUpperCase.step(),
    DemoAddAnswerLength.step()
  ]
  def get_steps(_mode), do: [

  ]

  def request_job_status(query_id) do
    GenServer.cast(get_server_pid(query_id), :request_job_status)
  end

  def add_job(query_id, query_result, steps, workgroup_credentials) do
    GenServer.cast(get_server_pid(query_id), {:add_job, query_result, steps, workgroup_credentials})
  end

  def query_topic(query_id), do: "job_server_#{query_id}"

  def init(state) do
    state = state
      |> Map.put(:jobs, [])
    {:ok, state, {:continue, :read_job_file}}
  end

  def handle_continue(:read_job_file, state = %{mode: "demo"}) do
    # no existing jobs in demo mode
    broadcast_jobs(state)
    {:noreply, state}
  end

  def handle_continue(:read_job_file, state) do
    # TBD: read the job file from S3
    broadcast_jobs(state)
    {:noreply, state}
  end

  def handle_cast(:request_job_status, state) do
    broadcast_jobs(state)
    {:noreply, state}
  end

  def handle_cast({:add_job, query_result, steps, workgroup_credentials}, state = %{mode: mode, jobs: jobs}) do
    task = Task.Supervisor.async_nolink(ReportServer.PostProcessingTaskSupervisor, fn ->
      Job.run(mode, query_result, steps, workgroup_credentials)
    end)

    jobs = jobs ++ [%Job{id: length(jobs) + 1, steps: steps, status: :started, ref: task.ref, result: nil}]
    state = %{state | jobs: jobs}
    broadcast_jobs(state)
    {:noreply, state}
  end

  # The job completed successfully
  def handle_info({ref, result}, state) do
    Process.demonitor(ref, [:flush])
    {:noreply, update_job(state, ref, :completed, result)}
  end

  # The job failed
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {:noreply, update_job(state, ref, :failed)}
  end

  defp broadcast_jobs(%{query_id: query_id, jobs: jobs}) do
    PubSub.broadcast(ReportServer.PubSub, query_topic(query_id), {:jobs, query_id, jobs})
  end

  defp get_server_pid(query_id) do
    [{pid, _}] = Registry.lookup(ReportServer.PostProcessingRegistry, query_id)
    pid
  end

  def get_job_index(jobs, ref) do
    Enum.find_index(jobs, fn %{ref: job_ref} -> job_ref == ref end)
  end

  def update_job(%{jobs: jobs} = state, ref, status, result \\ nil) do
    job_index = Enum.find_index(jobs, fn %{ref: job_ref} -> job_ref == ref end)
    if job_index != nil do
      job = %Job{Enum.at(jobs, job_index) | status: status, result: result}
      jobs = List.replace_at(jobs, job_index, job)
      state = %{state | jobs: jobs}
      broadcast_jobs(state)
      state
    else
      state
    end
  end
end
