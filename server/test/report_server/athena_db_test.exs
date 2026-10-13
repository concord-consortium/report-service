defmodule ReportServer.AthenaDBTest do
  use ExUnit.Case, async: true

  alias ReportServer.AthenaDB
  alias ReportServer.Accounts.User

  describe "query/3" do
    test "rejects a query over 256 KB of UTF-8 before contacting AWS, though it has fewer characters" do
      sql = "SELECT '" <> String.duplicate("é", 131_070) <> "'"
      assert String.length(sql) < 262_144
      assert byte_size(sql) > 262_144

      assert AthenaDB.query(sql, 1, %User{}) == {:error, AthenaDB.query_too_large_error()}
    end
  end
end
