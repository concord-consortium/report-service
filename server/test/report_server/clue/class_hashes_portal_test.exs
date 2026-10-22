defmodule ReportServer.Clue.ClassHashesPortalTest do
  use ExUnit.Case, async: false

  @moduletag :portal_db

  alias ReportServer.Clue.ClassHashes
  alias ReportServer.PortalFixture

  test "maps each class with a hash to it and leaves out a class with a NULL or empty one" do
    assert ClassHashes.fetch(PortalFixture.server(), [601, 602, 603]) == {:ok, %{601 => String.duplicate("a", 48)}}
  end
end
