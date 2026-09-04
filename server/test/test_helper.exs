cond do
  ReportServer.PortalFixture.reachable?() ->
    ReportServer.PortalFixture.setup!()

  # excluding the portal tests is a local-development convenience; in CI it would let the suite
  # pass green with every result-level test silently skipped
  System.get_env("CI") ->
    raise """
    The portal fixture database is unreachable, so the :portal_db tests would be excluded.
    Set #{ReportServer.PortalFixture.env_var()} to a reachable MySQL, or start the container.
    """

  true ->
    IO.puts("portal fixture database unreachable; excluding :portal_db tests")
    ExUnit.configure(exclude: [:portal_db])
end

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(ReportServer.Repo, :manual)
