if ReportServer.PortalFixture.reachable?() do
  ReportServer.PortalFixture.setup!()
else
  IO.puts("portal fixture database unreachable; excluding :portal_db tests")
  ExUnit.configure(exclude: [:portal_db])
end

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(ReportServer.Repo, :manual)
