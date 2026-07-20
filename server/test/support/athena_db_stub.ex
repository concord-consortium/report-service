defmodule ReportServer.AthenaDBStub do
  def start(responses), do: Agent.start_link(fn -> responses end, name: __MODULE__)

  def query(sql, report_run_id, user), do: apply_stub(:query, [sql, report_run_id, user])
  def get_query_info(query_id), do: apply_stub(:get_query_info, [query_id])
  def get_download_url(s3_url, filename), do: apply_stub(:get_download_url, [s3_url, filename])
  def put_file_contents(path, contents), do: apply_stub(:put_file_contents, [path, contents])

  defp apply_stub(name, args) do
    Agent.get(__MODULE__, &Map.fetch!(&1, name)) |> apply(args)
  end
end
