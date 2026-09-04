defmodule ReportServer.Reports.ReportRunTest do
  use ReportServer.DataCase, async: true

  import ReportServer.AccountsFixtures

  alias ReportServer.Reports
  alias ReportServer.Reports.AthenaFailure

  # Long enough to exceed varchar(255) but well inside the text column, so it isolates the column
  # type from the bound applied in the changeset.
  @long_reason "CONSTRAINT_VIOLATION: " <>
                 String.duplicate(
                   "s3://report-service-output/partitions/application=activity-player/",
                   5
                 )

  defp run_fixture(attrs \\ %{}) do
    user = user_fixture()

    {:ok, run} =
      Reports.create_report_run(
        Map.merge(%{user_id: user.id, report_slug: "student-answers"}, attrs)
      )

    run
  end

  describe "athena_query_error" do
    test "a reason longer than varchar(255) round-trips unchanged" do
      assert String.length(@long_reason) > 255

      run = run_fixture()
      assert {:ok, updated} = Reports.update_report_run(run, %{athena_query_error: @long_reason})

      assert updated.athena_query_error == @long_reason
      assert Reports.get_report_run!(run.id).athena_query_error == @long_reason
    end

    test "is persisted through update_report_run/2, so it must be cast" do
      run = run_fixture()
      assert run.athena_query_error == nil

      assert {:ok, _} =
               Reports.update_report_run(run, %{athena_query_error: "HIVE_S3_THROTTLING: x"})

      assert Reports.get_report_run!(run.id).athena_query_error == "HIVE_S3_THROTTLING: x"
    end

    test "a run written without it reads back nil" do
      run = run_fixture()
      assert Reports.get_report_run!(run.id).athena_query_error == nil
    end

    test "an over-ceiling reason is bounded rather than raising" do
      run = run_fixture()
      oversized = String.duplicate("x", 70_000)

      assert {:ok, updated} = Reports.update_report_run(run, %{athena_query_error: oversized})

      stored = Reports.get_report_run!(run.id).athena_query_error
      assert byte_size(stored) <= AthenaFailure.max_reason_bytes()
      assert stored == updated.athena_query_error
      assert String.ends_with?(stored, " ... (truncated)")
    end
  end
end
