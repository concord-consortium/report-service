defmodule ReportServer.PortalDbs do
  require Logger

  # FUTURE WORK: change this to use a connection pool
  def query(server, statement, params \\ [], options \\ []) do
    with {:ok, server_opts} <- get_server_opts(server),
          {:ok, pid} = MyXQL.start_link(server_opts) do

      result = case MyXQL.query(pid, statement, params, options) do
        {:ok, result} ->
          {:ok, result}

        {:error, %DBConnection.ConnectionError{} = error} ->
          Logger.error("Error connecting to #{server}: #{error.message}")
          {:error, error.message}

        {:error, %MyXQL.Error{} = error} ->
          Logger.error("Error executing query on #{server}: #{error.message}")
          {:error, error.message}

        _ ->
          Logger.error("Unknown error query on #{server}")
          {:error, "Unknown error query on #{server}"}
      end

      GenServer.stop(pid)

      result
    else
      error -> error
    end
  end

  # converts columns: ["foo", "bar"], rows:[[1, 2], ...] to [%{:foo => 1, :bar => 2}, ...]
  def map_columns_on_rows(%{columns: columns, rows: rows} = %MyXQL.Result{}) do
    rows
    |> Enum.map(fn row ->
      columns
        |> Enum.map(&String.to_atom/1)
        |> Enum.zip(row)
        |> Enum.into(%{})
    end)
  end

  # Dates do not sort properly with normal <= operator
  defp value_sorter(v1 = %Date{}, v2 = %Date{}), do: Date.compare(v1, v2) != :gt
  defp value_sorter(v1, v2), do: v1 <= v2

  def sort_results(results, column, dir) do
    # Return a new results struct with the rows sorted by the given column
    col_index = results.columns |> Enum.find_index(&(&1 == column))
    sort_fn = if dir == :asc do &value_sorter/2 else &(value_sorter(&2, &1)) end
    new_rows = Enum.sort_by(results.rows, &(Enum.at(&1, col_index)), sort_fn)
    %{results | rows: new_rows}
  end

  def get_server_for_portal_url(portal_url) do
    case URI.parse(portal_url).host do
      "learn-report.concord.org" -> "learn.concord.org"
      "ngss-assessment-report.portal.concord.org" -> "ngss-assessment.portal.concord.org"
      host -> host
    end
  end

  def get_user_info(server, access_token) do
    query(server,
    """
    SELECT
      u.id, u.login, u.first_name, u.last_name, u.email,
      (SELECT count(*)
      FROM
        roles r,
        roles_users ru
      WHERE r.title = 'admin' AND ru.role_id = r.id AND ru.user_id = u.id) AS is_admin
    FROM
      access_grants ag,
      users u
    WHERE ag.access_token = ? AND ag.user_id = u.id
    """, [access_token])
  end

  defp get_server_opts(server) do
    with {:ok, value} <- get_connection_string(server) do
      parsed = URI.parse(value)
      auth = String.split(parsed.userinfo || "", ":")

      if length(auth) == 2 do
        [username, password] = auth
        {:ok, [
          hostname: parsed.host,
          port: parsed.port,
          username: username,
          password: password,
          database: "portal"
        ]}
      else
        {:error, "Missing username:password in connection string for #{server}"}
      end
    else
      error -> error
    end
  end

  defp get_connection_string(server) do
    # ie: learn.portal.staging.concord.org to LEARN_PORTAL_STAGING_CONCORD_ORG_DB
    key = "#{server}_DB"
      |> String.replace(".", "_")
      |> String.replace("-", "_")
      |> String.upcase()

    case System.get_env(key) do
      nil -> {:error, "Unknown server #{server}"}
      value -> {:ok, value}
    end
  end
end
