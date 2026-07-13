defmodule ReportServer.PostProcessing.JobsFile do
  alias ReportServer.PostProcessing.Output

  defp aws(), do: Application.get_env(:report_server, :aws_file_store, ReportServerWeb.Aws)

  def list_jobs(nil), do: {:ok, []}
  def list_jobs(athena_query_id) do
    jobs_url = Output.get_jobs_url("#{athena_query_id}_jobs.json")

    case aws().fetch_file_contents(jobs_url) do
      {:ok, contents} -> parse_jobs(contents)
      {:error, :not_found} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  def find_job(athena_query_id, job_id) when is_integer(job_id) do
    with {:ok, jobs} <- list_jobs(athena_query_id) do
      case Enum.find(jobs, fn job -> job["id"] == job_id end) do
        nil -> {:error, :not_found}
        job -> {:ok, job}
      end
    end
  end

  defp parse_jobs(contents) do
    case Jason.decode(contents) do
      {:ok, %{"jobs" => jobs}} when is_list(jobs) -> {:ok, jobs}
      {:ok, _} -> {:error, :malformed_jobs_file}
      {:error, reason} -> {:error, reason}
    end
  end
end
