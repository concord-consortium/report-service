defmodule ReportServer.ReportServiceStub do
  def start(responses), do: Agent.start_link(fn -> responses end, name: __MODULE__)

  def bulk_read(req), do: apply_stub(:bulk_read, [req])
  def fetch_attachment_meta(req), do: apply_stub(:fetch_attachment_meta, [req])

  defp apply_stub(name, args) do
    Agent.get(__MODULE__, &Map.fetch!(&1, name)) |> apply(args)
  end
end
