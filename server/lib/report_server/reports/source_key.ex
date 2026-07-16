defmodule ReportServer.Reports.SourceKey do
  @moduledoc "Derives the Firestore `source` for a run from its runnable_url, matching the report's own SQL."

  @offline "activity-player-offline.concord.org"
  @online "activity-player.concord.org"

  def from_runnable_url(runnable_url) when is_binary(runnable_url) do
    uri = URI.parse(runnable_url)

    (answers_source_key(uri.query) || uri.host)
    |> remap_offline()
  end

  defp answers_source_key(nil), do: nil

  defp answers_source_key(query) do
    case URI.decode_query(query) |> Map.get("answersSourceKey") do
      nil -> nil
      "" -> nil
      key -> key
    end
  end

  defp remap_offline(@offline), do: @online
  defp remap_offline(source), do: source
end
