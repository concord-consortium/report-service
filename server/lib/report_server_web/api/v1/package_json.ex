defmodule ReportServerWeb.Api.V1.PackageJSON do
  @moduledoc """
  The catalog's read shapes, which the dashboard app lists and matches and rigse resolves on
  the run path.
  """

  def index(entries), do: %{packages: Enum.map(entries, &entry/1)}

  defp entry(%{package: p, version: v, mine: mine, project: project}) do
    %{
      catalog_id: p.id,
      identity: p.identity,
      origin: p.origin,
      name: p.name,
      maintainer: p.maintainer,
      visibility: p.visibility,
      official: p.official,
      runnable: ReportServer.Packages.runnable?(p),
      mine: mine,
      project: project,
      current_version: %{
        version: v.version,
        checksum: v.checksum,
        title: v.title,
        description: v.description,
        urls: v.urls,
        clue_prepull: v.clue_prepull,
        expected_duration_seconds: v.expected_duration_seconds,
        published_at: v.published_at
      }
    }
  end

  def resolve(%{package: p, version: v, runnable: runnable, reason: reason}) do
    %{
      catalog_id: p.id,
      identity: p.identity,
      version: v.version,
      checksum: v.checksum,
      expected_duration_seconds: v.expected_duration_seconds,
      clue_prepull: v.clue_prepull,
      archived: p.archived,
      runnable: runnable,
      reason: reason
    }
  end
end
