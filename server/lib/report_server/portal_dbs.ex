defmodule ReportServer.PortalDbs do
  require Logger

  alias ReportServer.Accounts.User

  defmodule PortalUserInfo do
    defstruct id: nil, login: nil, first_name: nil, last_name: nil, email: nil, is_admin: false, is_project_admin: false, is_project_researcher: false, server: nil
  end

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

  def get_server_for_portal_url(portal_url) do
    case URI.parse(portal_url).host do
      "learn-report.concord.org" -> "learn.concord.org"
      "ngss-assessment-report.portal.concord.org" -> "ngss-assessment.portal.concord.org"
      host -> host
    end
  end

  def get_user_info(server, access_token) do
    sql = """
      SELECT
        u.id, u.login, u.first_name, u.last_name, u.email,
        EXISTS (
          SELECT 1
          FROM roles r
          JOIN roles_users ru ON ru.role_id = r.id
          WHERE r.title = 'admin' AND ru.user_id = u.id
        ) AS is_admin,
        EXISTS (
          SELECT 1
          FROM admin_project_users apu
          WHERE apu.is_admin = true AND apu.user_id = u.id
        ) AS is_project_admin,
        EXISTS (
          SELECT 1
          FROM admin_project_users apu
          WHERE apu.is_researcher = true AND apu.user_id = u.id
        ) AS is_project_researcher
      FROM
        access_grants ag
      JOIN
        users u ON ag.user_id = u.id
      WHERE
        ag.access_token = ?;
    """

    case query(server, sql, [access_token]) do
      {:ok, result} ->
        user_info = result
          |> map_columns_on_rows()
          |> hd()
          |> Map.put(:server, server)
          |> cast_user_info()

        {:ok, struct(PortalUserInfo, user_info)}

      error -> error
    end
  end

  def get_allowed_project_ids(user = %User{}) do
    cond do
      user.portal_is_admin -> :all
      user.portal_is_project_admin -> get_project_ids(user, "is_admin")
      user.portal_is_project_researcher -> get_project_ids(user, "is_researcher")
      true -> :none
    end
  end

  defp get_project_ids(user = %User{}, is_column) do
    sql = "SELECT DISTINCT project_id FROM admin_project_users WHERE user_id = ? AND #{is_column} = 1"

    case query(user.portal_server, sql, [user.portal_user_id]) do
      {:ok, result} ->
        result
        |> map_columns_on_rows()
        |> Enum.map(&Map.get(&1, :project_id))

      error -> error
    end
  end

  # mysql returns boolean columns as integers, so we need to convert them to an Elixir boolean
  defp cast_user_info(%{is_admin: is_admin, is_project_admin: is_project_admin, is_project_researcher: is_project_researcher} = user_info) do
    %{user_info | is_admin: is_admin == 1, is_project_admin: is_project_admin == 1, is_project_researcher: is_project_researcher == 1}
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
