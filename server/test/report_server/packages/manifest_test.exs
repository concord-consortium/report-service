defmodule ReportServer.Packages.ManifestTest do
  use ExUnit.Case, async: true

  alias ReportServer.Packages.{Archive, Manifest}

  @fixtures Path.expand("../../support/fixtures/packages", __DIR__)

  # The fixture's manifest.json, as build.sh writes it. Every field the contract adds lands here
  # first, and the drift test fails until the projection accounts for it.
  @fixture_manifest %{
    "name" => "class-counts",
    "title" => "Class counts",
    "version" => "1.0.6",
    "description" => "Counts the students in a class who answered each question.",
    "urls" => %{"all" => [], "any" => ["*collaborative-learning/*unit=dataflow*"], "none" => []},
    "clue_prepull" => true,
    "entrypoint" => "run.py",
    "expected_duration_seconds" => 120
  }

  # read by the runner from the archive and never stored in the catalog
  @unprojected ["entrypoint"]

  defp valid(overrides \\ %{}), do: Map.merge(@fixture_manifest, overrides)
  defp project(manifest), do: Manifest.project(manifest, ["manifest.json", "run.py"])

  for fixture <- ["class-counts-1.0.6.zip", "class-counts-go-1.0.6.zip"] do
    test "the projection of #{fixture} matches its manifest field for field" do
      {:ok, manifest, entries} = Archive.read_manifest(File.read!(Path.join(@fixtures, unquote(fixture))))
      assert manifest == @fixture_manifest

      {:ok, projection} = Manifest.project(manifest, entries)
      projected = Map.new(projection, fn {k, v} -> {Atom.to_string(k), v} end)

      assert Enum.sort(Map.keys(projected)) == Enum.sort(Map.keys(manifest) -- @unprojected)
      for {key, value} <- projected, do: assert(value == manifest[key], "#{key} drifted")
    end
  end

  test "defaults urls to three empty groups, clue_prepull to false and description to nil" do
    manifest = valid() |> Map.drop(["urls", "clue_prepull", "description"])
    assert {:ok, %{urls: %{"all" => [], "any" => [], "none" => []}, clue_prepull: false, description: nil}} = project(manifest)
    assert {:ok, %{urls: %{"all" => ["*a*"], "any" => [], "none" => []}}} = project(valid(%{"urls" => %{"all" => ["*a*"]}}))
  end

  test "accepts a prerelease version and a 20-pattern, 256-character limit" do
    assert {:ok, %{version: "2.0.0-rc.1"}} = project(valid(%{"version" => "2.0.0-rc.1"}))
    patterns = [String.duplicate("a", 256) | List.duplicate("*x*", 19)]
    assert {:ok, _} = project(valid(%{"urls" => %{"any" => patterns}}))
  end

  test "measures lengths in code points, as the columns do" do
    assert {:ok, _} = project(valid(%{"title" => String.duplicate("t", 200)}))
    assert {:error, _} = project(valid(%{"title" => String.duplicate("e\u0301", 101)}))
  end

  test "refuses catalog state in the manifest" do
    for key <- ~w(owner maintainer origin visibility project official) do
      assert {:error, message} = project(valid(%{key => "x"}))
      assert message =~ key
    end
  end

  test "ignores other unknown keys" do
    assert {:ok, _} = project(valid(%{"platforms" => ["clue"]}))
  end

  test "refuses each malformed field" do
    cases = [
      {"name", "Class_Counts", "name"},
      {"name", nil, "name"},
      {"version", "1.0", "version"},
      {"version", "01.0.0", "version"},
      {"version", "1.0.0/x", "version"},
      {"version", "1.0.0-" <> String.duplicate("a", 60), "version"},
      {"title", "", "title"},
      {"title", "  ", "title"},
      {"title", String.duplicate("t", 201), "title"},
      {"description", "two\nlines", "description"},
      {"description", String.duplicate("d", 501), "description"},
      {"description", 5, "description"},
      {"urls", ["*"], "urls"},
      {"urls", %{"anyy" => ["*"]}, "unknown keys anyy"},
      {"urls", %{"any" => "*"}, "urls.any"},
      {"clue_prepull", "yes", "clue_prepull"},
      {"entrypoint", "missing.py", "entrypoint"},
      {"entrypoint", "../run.py", "entrypoint"},
      {"entrypoint", "/run.py", "entrypoint"},
      {"entrypoint", nil, "entrypoint"},
      {"expected_duration_seconds", 0, "expected_duration_seconds"},
      {"expected_duration_seconds", 28_801, "expected_duration_seconds"},
      {"expected_duration_seconds", 1.5, "expected_duration_seconds"},
      {"expected_duration_seconds", nil, "expected_duration_seconds"}
    ]

    for {field, value, fragment} <- cases do
      assert {:error, message} = project(valid(%{field => value})), "#{field}: #{inspect(value)} was accepted"
      assert message =~ fragment
    end
  end

  test "bounds the patterns" do
    assert {:error, m} = project(valid(%{"urls" => %{"all" => List.duplicate("*a*", 7), "any" => List.duplicate("*b*", 7), "none" => List.duplicate("*c*", 7)}}))
    assert m =~ "more than 20 patterns"
    assert {:error, m} = project(valid(%{"urls" => %{"any" => [String.duplicate("a", 257)]}}))
    assert m =~ "256"
    for bad <- ["*a b*", "*a\tb*", "*a\u0000*", "", 5] do
      assert {:error, _} = project(valid(%{"urls" => %{"none" => [bad]}})), "#{inspect(bad)} was accepted"
    end
  end
end
