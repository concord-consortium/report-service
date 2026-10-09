defmodule ReportServer.Packages.ContractTest do
  use ExUnit.Case, async: true
  alias ReportServer.Packages.{Archive, Identity, Manifest}
  import ReportServer.PackagesFixtures, only: [package_zip: 1]

  @fixture Path.expand("../../../../fixtures/package-contract.json", __DIR__) |> File.read!() |> Jason.decode!()

  test "every identity case" do
    assert length(@fixture["identity"]) > 0

    for %{"value" => value, "valid" => valid} <- @fixture["identity"] do
      assert match?({:ok, _}, Identity.parse(value)) == valid, "identity #{inspect(value)}"
    end
  end

  test "every version case" do
    assert length(@fixture["version"]) > 0

    for %{"value" => value, "valid" => valid} <- @fixture["version"] do
      assert Manifest.valid_version?(value) == valid, "version #{inspect(value)}"
    end
  end

  test "the duration ceiling is the contract's" do
    max = @fixture["limits"]["max_duration_seconds"]

    project = fn seconds ->
      {:ok, manifest, entries} = Archive.read_manifest(package_zip(%{"expected_duration_seconds" => seconds}))
      Manifest.project(manifest, entries)
    end

    assert {:ok, _} = project.(max)
    assert {:error, _} = project.(max + 1)
  end
end
