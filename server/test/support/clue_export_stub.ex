defmodule ReportServer.ClueExportStub do
  def start(responses), do: Agent.start_link(fn -> responses end, name: __MODULE__)

  def url_for(portal_server), do: apply_stub(:url_for, [portal_server])
  def call(portal_server, req), do: apply_stub(:call, [portal_server, req])

  defp apply_stub(name, args) do
    Agent.get(__MODULE__, &Map.fetch!(&1, name)) |> apply(args)
  end
end
