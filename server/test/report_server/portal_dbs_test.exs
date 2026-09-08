defmodule ReportServer.PortalDbsTest do
  use ExUnit.Case, async: false

  @moduletag :portal_db

  alias ReportServer.{PortalDbs, PortalFixture}

  @server PortalFixture.server()

  # A host nothing listens on, so the pool starts but can never hand out a connection.
  @unreachable "dead.example.com"
  @unreachable_env "DEAD_EXAMPLE_COM_DB"

  setup do
    System.put_env(@unreachable_env, "mysql://root:xyzzy@127.0.0.1:9")
    on_exit(fn -> System.delete_env(@unreachable_env) end)
    :ok
  end

  describe "query_with_reason/4" do
    test "a query that consumes its budget is a timeout" do
      assert {:error, :timeout, message} =
               PortalDbs.query_with_reason(@server, "SELECT SLEEP(1)", [], timeout: 100)

      assert is_binary(message)
    end

    test "a database that cannot hand out a connection is busy, not a timeout" do
      assert {:error, :busy, message} =
               PortalDbs.query_with_reason(@unreachable, "SELECT 1", [], timeout: 30_000)

      assert message =~ "connection not available"
    end

    test "a broken statement is a database error" do
      assert {:error, :db, message} =
               PortalDbs.query_with_reason(@server, "SELECT * FROM no_such_table")

      assert message =~ "no_such_table"
    end

    test "a server with no connection string never reaches the driver" do
      assert PortalDbs.query_with_reason("no.such.host", "SELECT 1") ==
               {:error, "Unknown server no.such.host"}
    end

    test "a successful query returns the result unchanged" do
      assert {:ok, result} = PortalDbs.query_with_reason(@server, "SELECT 1")
      assert result.rows == [[1]]
    end
  end

  describe "query/4 delegates without changing its own contract" do
    test "success passes through" do
      assert {:ok, result} = PortalDbs.query(@server, "SELECT 1")
      assert result.rows == [[1]]
    end

    test "a failure keeps the driver message the reason tuple carried" do
      for {statement, options} <- [
            {"SELECT SLEEP(1)", [timeout: 100]},
            {"SELECT * FROM no_such_table", []}
          ] do
        {:error, _kind, message} = PortalDbs.query_with_reason(@server, statement, [], options)

        assert PortalDbs.query(@server, statement, [], options) == {:error, message}
      end
    end

    # the busy message embeds the elapsed milliseconds, so only its shape is stable
    test "a pool that cannot hand out a connection flattens too" do
      assert {:error, message} = PortalDbs.query(@unreachable, "SELECT 1", [], timeout: 30_000)
      assert message =~ "connection not available"
    end

    test "an unknown server still returns its two element tuple" do
      assert PortalDbs.query("no.such.host", "SELECT 1") ==
               {:error, "Unknown server no.such.host"}
    end
  end
end
