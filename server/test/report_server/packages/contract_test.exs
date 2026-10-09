defmodule ReportServer.Packages.ContractTest do
  use ExUnit.Case, async: true
  alias ReportServer.Packages.{Identity, Manifest}

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
end
