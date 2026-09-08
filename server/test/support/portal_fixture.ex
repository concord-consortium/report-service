defmodule ReportServer.PortalFixture do
  @moduledoc """
  Creates the `portal` schema `PortalDbs` connects to and seeds the learners the portal report
  tests read.

  The schema is created outside `PortalDbs`, because its pool hardcodes `database: "portal"` and
  cannot connect until that database exists.
  """

  alias ReportServer.PortalDbs

  @server "portal-test.example.com"
  @database "portal"

  def server, do: @server

  def env_var do
    "#{@server}_DB"
    |> String.replace(".", "_")
    |> String.replace("-", "_")
    |> String.upcase()
  end

  @doc "True when the fixture database can actually be queried, not merely configured."
  def reachable? do
    with {:ok, _} <- ensure_database(),
         {:ok, _} <- PortalDbs.query(@server, "SELECT 1", [], timeout: 2_000) do
      true
    else
      _ -> false
    end
  end

  @doc "Rebuilds the fixture tables from scratch. Raises if any statement fails."
  def setup! do
    {:ok, _} = ensure_database()

    Path.join(__DIR__, "portal_fixture.sql")
    |> File.read!()
    |> String.split(";\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.each(fn statement ->
      case PortalDbs.query(@server, statement) do
        {:ok, result} -> result
        {:error, reason} -> raise "portal fixture statement failed: #{reason}\n#{statement}"
      end
    end)
  end

  defp ensure_database do
    with {:ok, opts} <- connection_opts(),
         {:ok, conn} <- MyXQL.start_link(opts ++ [queue_target: 500, queue_interval: 500]) do
      result = MyXQL.query(conn, "CREATE DATABASE IF NOT EXISTS #{@database}")
      GenServer.stop(conn)
      result
    end
  end

  defp connection_opts do
    case System.get_env(env_var()) do
      nil ->
        {:error, "#{env_var()} is not set"}

      url ->
        uri = URI.parse(url)

        case String.split(uri.userinfo || "", ":") do
          [username, password] ->
            {:ok, [hostname: uri.host, port: uri.port, username: username, password: password]}

          _ ->
            {:error, "#{env_var()} is missing username:password"}
        end
    end
  end
end
