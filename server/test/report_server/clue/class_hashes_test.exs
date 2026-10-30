defmodule ReportServer.Clue.ClassHashesTest do
  use ExUnit.Case, async: true

  alias ReportServer.Clue.ClassHashes

  test "answers an empty map for no classes without querying" do
    assert ClassHashes.fetch("unconfigured.example.org", []) == {:ok, %{}}
  end
end
