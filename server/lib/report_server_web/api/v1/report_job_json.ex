defmodule ReportServerWeb.Api.V1.ReportJobJSON do
  def index(jobs) do
    %{
      items: Enum.map(jobs, &job_json/1),
      next_page_token: nil
    }
  end

  defp job_json(job) do
    %{
      id: job["id"],
      steps: Enum.map(job["steps"] || [], fn step -> %{id: step["id"], label: step["label"]} end),
      status: job["status"],
      has_result: job["result"] != nil
    }
  end
end
