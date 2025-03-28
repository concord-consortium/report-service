defmodule ReportServer.JobFixtures do

  alias ReportServer.PostProcessing.Job
  alias ReportServer.PostProcessing.Job.JobOverrides

  @doc """
  Generate a job.
  """
  def job_fixture(input \\ "", steps \\ [], learners \\ %{}) do
    job = %Job{id: 1, query_id: "test", steps: steps, status: :started, started_at: :os.system_time(:millisecond), portal_url: "https://portal.example.com", ref: nil, result: nil}
    query_result = %{id: "test_result"}

    {:ok, input_preprocess_io} = StringIO.open(input)
    {:ok, input_process_io} = StringIO.open(input)
    {:ok, output_io} = StringIO.open("")
    overrides = %JobOverrides{
      input_preprocess: IO.stream(input_preprocess_io, :line),
      input_process: IO.stream(input_process_io, :line),
      output: IO.stream(output_io, :line),
      get_learners: fn -> learners end
    }

    get_output = fn ->
      {_input, output} = StringIO.contents(output_io)
      output
    end

    {job, query_result, overrides, get_output}
  end
end
