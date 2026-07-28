defmodule ReportServer.PortalDbsStub do
  @moduledoc """
  Test double for the swappable `portal_db` seam. Implements only `stream_query/4`; it delegates
  to a configured function so each test can drive the caller's reducer with canned
  `%MyXQL.Result{}` envelopes (or raise) without a live portal DB. It deliberately does not stub
  `get_allowed_project_ids`/`query`; the query-build path is kept DB-free at the fixture level by
  seeding a super-admin run (see the download tests).
  """
  def start(responses), do: Agent.start_link(fn -> responses end, name: __MODULE__)

  def stream_query(server, statement, params, opts),
    do: apply_stub(:stream_query, [server, statement, params, opts])

  defp apply_stub(name, args) do
    Agent.get(__MODULE__, &Map.fetch!(&1, name)) |> apply(args)
  end
end
