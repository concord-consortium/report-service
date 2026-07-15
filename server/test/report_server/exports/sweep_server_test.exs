defmodule ReportServer.Exports.SweepServerTest do
  use ReportServer.DataCase

  import ReportServer.AccountsFixtures

  alias ReportServer.Exports
  alias ReportServer.Exports.{ExportScratch, SweepServer}
  alias ReportServer.Reports

  defp report_run_fixture(user) do
    {:ok, run} = Reports.create_report_run(%{user_id: user.id, report_slug: "student-answers"})
    run
  end

  defp insert_scratch!(user, run, expires_at) do
    {:ok, scratch} =
      %ExportScratch{}
      |> ExportScratch.changeset(%{
        scratch_id: Exports.mint_scratch_id(),
        report_run_id: run.id,
        user_id: user.id,
        data_type: "answers_bulk",
        endpoint_set: [%{"remote_endpoint" => "re-1", "source" => "s"}],
        expires_at: expires_at
      })
      |> Repo.insert()

    scratch
  end

  test "the supervised sweeper is disabled in the test env (no Repo work under the sandbox)" do
    assert SweepServer.disabled?()
  end

  test "a manually-driven instance reclaims only expired rows" do
    user = user_fixture()
    run = report_run_fixture(user)

    insert_scratch!(user, run, DateTime.utc_now(:second) |> DateTime.add(-60))
    insert_scratch!(user, run, DateTime.utc_now(:second) |> DateTime.add(3600))

    # start a SECOND instance under a different name (the supervised singleton owns __MODULE__), allow its pid
    # onto the test's sandboxed connection, and drive one sweep by hand.
    {:ok, pid} = SweepServer.start_link(name: :sweep_test)
    Ecto.Adapters.SQL.Sandbox.allow(ReportServer.Repo, self(), pid)

    send(pid, :sweep)
    :sys.get_state(pid)

    assert Repo.aggregate(ExportScratch, :count) == 1
  end
end
