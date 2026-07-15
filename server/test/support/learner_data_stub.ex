defmodule ReportServer.LearnerDataStub do
  def start(responses), do: Agent.start_link(fn -> responses end, name: __MODULE__)

  def fetch(report_filter, user, opts \\ []), do: apply_stub(:fetch, [report_filter, user, opts])
  def get_allowed_project_ids(user), do: apply_stub(:get_allowed_project_ids, [user])

  defp apply_stub(name, args) do
    Agent.get(__MODULE__, &Map.fetch!(&1, name)) |> apply(args)
  end
end
