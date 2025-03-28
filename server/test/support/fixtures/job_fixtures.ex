defmodule ReportServer.JobFixtures do

  alias ReportServer.PostProcessing.Job
  alias ReportServer.PostProcessing.Job.JobOverrides

  @doc """
  Generate a job.
  """
  def job_fixture(input \\ "", steps \\ [], learners \\ %{}) do
    job = %Job{id: 1, query_id: "test", steps: steps, status: :started, started_at: :os.system_time(:millisecond), portal_url: "portal.example.com", ref: nil, result: nil}
    query_result = %{id: "test_result"}

    {:ok, output_io} = StringIO.open("")
    overrides = %JobOverrides{
      output: IO.stream(output_io, :line),
      get_input: fn ->
        {:ok, input_io} = StringIO.open(input)
        IO.stream(input_io, :line)
      end,
      learners: learners
    }

    get_output = fn ->
      {_input, output} = StringIO.contents(output_io)
      output
    end

    {job, query_result, overrides, get_output}
  end
end
