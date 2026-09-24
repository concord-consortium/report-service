defmodule ReportServer.PackagesFixtures do
  @moduledoc """
  Builds package zips for the catalog's tests.
  """

  def manifest(overrides \\ %{}) do
    Map.merge(
      %{
        "name" => "counts",
        "title" => "Counts",
        "version" => "1.0.0",
        "description" => "Counts things.",
        "urls" => %{"any" => ["*question-interactives/*"]},
        "clue_prepull" => false,
        "entrypoint" => "run.py",
        "expected_duration_seconds" => 60
      },
      Map.new(overrides)
    )
  end

  def package_zip(overrides \\ %{}) do
    files = [{~c"manifest.json", Jason.encode!(manifest(overrides))}, {~c"run.py", "print(1)\n"}]
    {:ok, {_, bin}} = :zip.create(~c"package.zip", files, [:memory])
    bin
  end
end
