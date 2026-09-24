defmodule ReportServer.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed: bin/report_server eval "ReportServer.Release.migrate"
  """
  @app :report_server

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  Grants the package publisher role, which may set `official`, to a user who has logged in to
  report-server at least once:
  bin/report_server eval 'ReportServer.Release.grant_package_publisher("learn.concord.org", 123)'
  """
  def grant_package_publisher(portal_server, portal_user_id),
    do: set_package_publisher(portal_server, portal_user_id, true)

  def revoke_package_publisher(portal_server, portal_user_id),
    do: set_package_publisher(portal_server, portal_user_id, false)

  defp set_package_publisher(portal_server, portal_user_id, value) do
    load_app()

    {:ok, result, _} =
      Ecto.Migrator.with_repo(ReportServer.Repo, fn _repo ->
        ReportServer.Packages.set_publisher(portal_server, portal_user_id, value)
      end)

    case result do
      :ok -> IO.puts("package_publisher is now #{value} for #{portal_server} user #{portal_user_id}")
      {:error, :not_found} -> IO.puts("no report-server user #{portal_user_id} on #{portal_server}")
    end

    result
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
