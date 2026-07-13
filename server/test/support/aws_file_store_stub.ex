defmodule ReportServer.AwsFileStoreStub do
  def start(responses), do: Agent.start_link(fn -> responses end, name: __MODULE__)

  def fetch_file_contents(s3_url), do: apply_stub(:fetch_file_contents, [s3_url])

  defp apply_stub(name, args) do
    Agent.get(__MODULE__, &Map.fetch!(&1, name)) |> apply(args)
  end
end
