defmodule ReportServer.PostProcessing.JobServer do
  alias Phoenix.PubSub
  use GenServer

  alias ReportServerWeb.Aws
  alias ReportServer.PostProcessing.{Job, Output}
  alias ReportServer.PostProcessing.Steps.{DemoUpperCase, DemoAddAnswerLength, HasAudio, TranscribeAudio}

  def start_link(query_id, mode) do
    GenServer.start_link(__MODULE__, %{query_id: query_id, mode: mode, jobs: []}, name: {:via, Registry, {ReportServer.PostProcessingRegistry, query_id}})
  end

  def get_steps("demo"), do: [
    DemoUpperCase.step(),
    DemoAddAnswerLength.step(),
    HasAudio.step(),
    TranscribeAudio.step()
  ] |> sort_steps()
  def get_steps(_mode), do: [
    HasAudio.step(),
    TranscribeAudio.step()
  ] |> sort_steps()

  def sort_steps(steps) do
    Enum.sort(steps, &(&1.label < &2.label))
  end

  def request_job_status(query_id) do
    GenServer.cast(get_server_pid(query_id), :request_job_status)
  end

  def add_job(query_id, query_result, steps) do
    GenServer.cast(get_server_pid(query_id), {:add_job, query_result, steps})
  end

  def query_topic(query_id), do: "job_server_#{query_id}"

  def init(state) do
    state = state
      |> Map.put(:jobs, [])
    # the :continue lets us return early and then kick off the read_jobs_file
    {:ok, state, {:continue, :read_jobs_file}}
  end

  def handle_continue(:read_jobs_file, state) do
    state = state
    |> read_jobs_file()
    |> broadcast_jobs()
    {:noreply, state}
  end

  def handle_cast(:request_job_status, state) do
    broadcast_jobs(state)
    {:noreply, state}
  end

  def handle_cast({:add_job, query_result, steps}, state = %{mode: mode, jobs: jobs}) do
    job = %Job{id: length(jobs) + 1, steps: steps, status: :started, ref: nil, result: nil}

    task = Task.Supervisor.async_nolink(ReportServer.PostProcessingTaskSupervisor, fn ->
      Job.run(mode, job, query_result)
    end)

    job = Map.put(job, :ref, task.ref)

    state = %{state | jobs: jobs ++ [job]}
      |> broadcast_jobs()
      |> save_jobs_file()
    {:noreply, state}
  end

  # The job completed successfully
  def handle_info({ref, result}, state) do
    Process.demonitor(ref, [:flush])
    state = state
      |> update_job(ref, :completed, result)
      |> save_jobs_file()
    {:noreply, state}
  end

  # The job failed
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    state = state
      |> update_job(ref, :failed)
      |> save_jobs_file()
    {:noreply, state}
  end

  defp broadcast_jobs(%{query_id: query_id, jobs: jobs} = state) do
    PubSub.broadcast(ReportServer.PubSub, query_topic(query_id), {:jobs, query_id, jobs})
    state
  end

  defp read_jobs_file(%{mode: "demo"} = state) do
    # no saved jobs file in demo mode
    state
  end
  defp read_jobs_file(%{mode: mode} = state) do
    case Aws.get_file_contents(mode, get_jobs_file_url(state)) do
      {:ok, contents} ->
        json = keys_to_atoms(Jason.decode!(contents))
        jobs = Enum.map(json.jobs, fn job -> struct(Job, job) end)
        %{state | jobs: jobs}
      _ ->
        state
    end
  end

  defp save_jobs_file(%{mode: "demo"} = state) do
    # no saved jobs file in demo mode
    state
  end
  defp save_jobs_file(%{mode: mode, query_id: _query_id, jobs: jobs} = state) do
    contents = Jason.encode!(%{
      version: 1,
      jobs: jobs
    })
    Aws.put_file_contents(mode, get_jobs_file_url(state), contents)
    state
  end

  defp get_server_pid(query_id) do
    [{pid, _}] = Registry.lookup(ReportServer.PostProcessingRegistry, query_id)
    pid
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

  defp get_jobs_file_url(%{query_id: query_id}) do
    Output.get_jobs_url("#{query_id}_jobs.json")
  end

  defp keys_to_atoms(json) when is_map(json) do
    Map.new(json, &reduce_keys_to_atoms/1)
  end

  def reduce_keys_to_atoms({key, val}) when is_map(val), do: {String.to_existing_atom(key), keys_to_atoms(val)}
  def reduce_keys_to_atoms({key, val}) when is_list(val), do: {String.to_existing_atom(key), Enum.map(val, &keys_to_atoms(&1))}
  def reduce_keys_to_atoms({key, val}), do: {String.to_existing_atom(key), val}
end
