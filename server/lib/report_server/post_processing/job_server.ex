defmodule ReportServer.PostProcessing.JobServer do
  use GenServer

  require Logger

  alias Phoenix.PubSub
  alias ReportServerWeb.Aws
  alias ReportServer.PostProcessing.{Job, Output}
  alias ReportServer.PostProcessing.Steps.{HasAudio, TranscribeAudio, GlossaryData, ClueLinkToWork, MergeToPrimaryUser}

  @client_check_interval :timer.minutes(1)

  def start_link({query_id}) do
    GenServer.start_link(__MODULE__, %{query_id: query_id, jobs: [], clients: %{}}, name: {:via, Registry, {ReportServer.PostProcessingRegistry, query_id}})
  end

  def get_steps("details"), do: [
    HasAudio.step(),
    TranscribeAudio.step(),
    GlossaryData.step(),
    MergeToPrimaryUser.step(),
  ] |> sort_steps()

  def get_steps("student-actions"), do: [
    ClueLinkToWork.step(),
  ] |> sort_steps()

  def get_steps("student-actions-with-metadata"), do: [
    ClueLinkToWork.step(),
  ] |> sort_steps()

  def get_steps(_report_type), do: []

  def sort_steps(steps) do
    Enum.sort(steps, &(&1.label < &2.label))
  end

  def register_client(query_id, client_pid) do
    GenServer.cast(get_server_pid(query_id), {:register_client, client_pid})
  end

  def request_job_status(query_id) do
    GenServer.cast(get_server_pid(query_id), :request_job_status)
  end

  def add_job(query_id, query_result, steps, portal_url) do
    GenServer.cast(get_server_pid(query_id), {:add_job, query_result, steps, portal_url})
  end

  def query_topic(query_id), do: "job_server_#{query_id}"

  def init(state) do
    schedule_client_check()
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

  def handle_cast({:register_client, client_pid}, state) do
    state = %{state | clients: Map.put(state.clients, client_pid, true)}
    {:noreply, state}
  end

  def handle_cast({:add_job, query_result, steps, portal_url}, state = %{jobs: jobs}) do
    job = %Job{id: length(jobs) + 1, query_id: query_result.id, steps: steps, status: :started, started_at: :os.system_time(:millisecond), portal_url: portal_url, ref: nil, result: nil}
    step_labels = Enum.map(steps, &(&1.label)) |> Enum.join(", ")
    Logger.info("Adding job ##{job.id} for query #{query_result.id} (#{step_labels})")

    job_server = self()
    task = Task.Supervisor.async_nolink(ReportServer.PostProcessingTaskSupervisor, fn ->
      Job.run(job, query_result, job_server)
    end)

    job = Map.put(job, :ref, task.ref)

    state = %{state | jobs: jobs ++ [job]}
      |> broadcast_jobs()
      |> save_jobs_file()
    {:noreply, state}
  end

  def handle_info({:processed_row, job_id, row_num}, state) do
    state = update_rows_processed(state, job_id, row_num)
    {:noreply, state}
  end

  # The job task completed
  def handle_info({ref, result}, state) do
    Process.demonitor(ref, [:flush])

    {status, final_result} = case result do
      {:ok, final_result} -> {:completed, final_result}
      {:error, _} -> {:failed, nil}
    end

    state = state
      |> update_job(ref, status, final_result)
      |> save_jobs_file()
    {:noreply, state}
  end

  # The job task threw an exception
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    state = state
      |> update_job(ref, :failed)
      |> save_jobs_file()
    {:noreply, state}
  end

  def handle_info(:check_clients, %{clients: clients, jobs: jobs} = state) do
    non_completed_jobs = Enum.reduce(jobs, 0, fn job, non_completed_jobs ->
      if job.status == :started do
        non_completed_jobs + 1
      else
        non_completed_jobs
      end
    end)

    clients = Enum.reduce(clients, %{}, fn {pid, _}, acc ->
      if Process.alive?(pid) do
        Map.put(acc, pid, true)
      else
        acc
      end
    end)

    state = %{state | clients: clients}

    # all the clients are gone and all the jobs are completed or failed so stop the server
    if map_size(clients) == 0 && non_completed_jobs == 0 do
      {:stop, :normal, state}
    else
      schedule_client_check()
      {:noreply, state}
    end
  end

  defp schedule_client_check() do
    Process.send_after(self(), :check_clients, @client_check_interval)
  end

  defp broadcast_jobs(%{query_id: query_id, jobs: jobs} = state) do
    PubSub.broadcast(ReportServer.PubSub, query_topic(query_id), {:jobs, query_id, jobs})
    state
  end

  defp read_jobs_file(state) do
    case Aws.get_file_contents(get_jobs_file_url(state)) do
      {:ok, contents} ->
        json = keys_to_atoms(Jason.decode!(contents))
        jobs = Enum.map(json.jobs, fn job -> struct(Job, job) end)
        %{state | jobs: jobs}
      _ ->
        state
    end
  end

  defp save_jobs_file(%{query_id: _query_id, jobs: jobs} = state) do
    contents = Jason.encode!(%{
      version: 1,
      jobs: jobs
    })
    Aws.put_file_contents(get_jobs_file_url(state), contents)
    state
  end

  defp get_server_pid(query_id) do
    [{pid, _}] = Registry.lookup(ReportServer.PostProcessingRegistry, query_id)
    pid
  end

  def update_job(%{jobs: jobs} = state, ref, status, result \\ nil) do
    job_index = Enum.find_index(jobs, fn %{ref: job_ref} -> job_ref == ref end)
    update_job_at(state, job_index, fn job ->
      if status == :completed do
        run_time = :os.system_time(:millisecond) - job.started_at
        Logger.info("Status change of job ##{job.id} for query #{job.query_id}: #{status}. Elapsed time: #{run_time} ms.")
      else
        Logger.info("Status change of job ##{job.id} for query #{job.query_id}: #{status}")
      end
      %{job | status: status, result: result}
    end)
  end

  def update_rows_processed(%{jobs: jobs} = state, job_id, rows_processed) do
    job_index = Enum.find_index(jobs, fn %{id: id} -> job_id == id end)
    update_job_at(state, job_index, &(%{&1 | rows_processed: rows_processed}))
  end

  def update_job_at(%{jobs: jobs} = state, job_index, callback) do
    if job_index != nil do
      job = callback.(Enum.at(jobs, job_index))
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

  defp reduce_keys_to_atoms({key, val}) when is_map(val), do: {String.to_existing_atom(key), keys_to_atoms(val)}
  defp reduce_keys_to_atoms({key, val}) when is_list(val), do: {String.to_existing_atom(key), Enum.map(val, &keys_to_atoms(&1))}
  defp reduce_keys_to_atoms({key, val}), do: {String.to_existing_atom(key), val}
end
