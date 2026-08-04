# The :pending tag marks tests written ahead of the code they exercise. Today
# that is ReportServer.ClueTest (REPORT-36), which needs the testability seam in
# implementation sequencing step 2 before it can run. Run them with:
#
#     mix test --include pending
#
ExUnit.start(exclude: [:pending])
Ecto.Adapters.SQL.Sandbox.mode(ReportServer.Repo, :manual)
