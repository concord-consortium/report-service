defmodule ReportServer.ClueClassHashesStub do
  def start(fetch), do: Agent.start_link(fn -> fetch end, name: __MODULE__)

  def fetch(portal_server, class_ids), do: Agent.get(__MODULE__, & &1).(portal_server, class_ids)
end
