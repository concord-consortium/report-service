defmodule ReportServer.Reports.PartitionEstimateTest do
  # reads and writes global application env, so it must not overlap async cases
  use ExUnit.Case, async: false

  alias ReportServer.Reports.Athena.AthenaConfig
  alias ReportServer.Reports.PartitionEstimate

  setup do
    on_exit(fn -> Application.delete_env(:report_server, :partition_warning_threshold) end)
    :ok
  end

  describe "period_months/2" do
    test "an unbounded range admits every projected pair" do
      assert PartitionEstimate.period_months(nil, nil) == 444
    end

    test "the empty strings an untouched date input submits are unbounded" do
      assert PartitionEstimate.period_months("", "") == 444
    end

    test "a partial-year range counts the pairs the predicate admits, not years times months" do
      assert PartitionEstimate.period_months("2024-09-01", "2025-06-30") == 10
    end

    test "a multi-year range counts the pairs the predicate admits" do
      assert PartitionEstimate.period_months("2023-09-01", "2025-06-30") == 22
    end

    test "a single month is one pair" do
      assert PartitionEstimate.period_months("2024-03-01", "2024-03-31") == 1
    end

    test "a range whose end precedes its start admits nothing" do
      assert PartitionEstimate.period_months("2025-06-30", "2024-09-01") == 0
    end

    test "a start-only range runs to the end of the projection" do
      assert PartitionEstimate.period_months("2024-09-01", nil) == 316
    end

    test "an end-only range runs from the start of the projection" do
      assert PartitionEstimate.period_months(nil, "2025-06-30") == 138
    end

    test "a start before the projection is clamped to it" do
      assert PartitionEstimate.period_months("2000-01-01", "2050-12-31") == 444
    end

    test "bounds outside the projection on both ends are clamped to it" do
      assert PartitionEstimate.period_months("1990-01-01", "2060-12-31") == 444
    end

    test "a range entirely before the projection admits nothing" do
      assert PartitionEstimate.period_months("2000-01-01", "2013-12-31") == 0
    end

    test "a range entirely after the projection admits nothing" do
      assert PartitionEstimate.period_months("2051-01-01", "2060-12-31") == 0
    end

    test "an unparseable bound is treated as no bound" do
      assert PartitionEstimate.period_months("not-a-date", "also-not-a-date") == 444
    end
  end

  describe "projected_partitions/4" do
    test "an unfiltered learner expands across every application and pair" do
      assert PartitionEstimate.projected_partitions(1, nil, nil, nil) == 7_104
    end

    test "setting the application divides by the length of the list, not by a literal" do
      unfiltered = PartitionEstimate.projected_partitions(100, nil, nil, nil)
      filtered = PartitionEstimate.projected_partitions(100, "CLUE", nil, nil)

      assert unfiltered == filtered * length(AthenaConfig.get_log_apps())
    end

    test "selecting several applications divides by how many were selected" do
      assert PartitionEstimate.app_count(["CLUE", "Dataflow"]) == 2

      assert PartitionEstimate.projected_partitions(100, ["CLUE", "Dataflow"], nil, nil) ==
               100 * 2 * 444
    end

    test "an empty selection is unfiltered" do
      assert PartitionEstimate.app_count([]) == length(AthenaConfig.get_log_apps())
    end

    test "the empty string the control submits counts as unfiltered" do
      assert PartitionEstimate.projected_partitions(100, "", nil, nil) ==
               PartitionEstimate.projected_partitions(100, nil, nil, nil)
    end

    test "the unfiltered learner ceiling sits between 140 and 141" do
      assert PartitionEstimate.projected_partitions(140, nil, nil, nil) == 994_560

      assert PartitionEstimate.projected_partitions(140, nil, nil, nil) <
               PartitionEstimate.athena_partition_limit()

      assert PartitionEstimate.projected_partitions(141, nil, nil, nil) >
               PartitionEstimate.athena_partition_limit()
    end

    test "a date range brings a large cohort back under the limit" do
      assert PartitionEstimate.projected_partitions(694, nil, nil, nil) >
               PartitionEstimate.athena_partition_limit()

      assert PartitionEstimate.projected_partitions(694, "CLUE", "2024-09-01", "2025-06-30") <
               PartitionEstimate.athena_partition_limit()
    end
  end

  describe "warning_threshold/0" do
    test "defaults to the Athena limit when nothing is configured" do
      assert PartitionEstimate.warning_threshold() == PartitionEstimate.athena_partition_limit()
    end

    test "a configured threshold above the Athena limit is capped at it" do
      Application.put_env(:report_server, :partition_warning_threshold, 2_000_000)

      # otherwise a run Athena is certain to reject would produce no warning at all
      assert PartitionEstimate.warning_threshold() == PartitionEstimate.athena_partition_limit()
      assert 1_500_000 > PartitionEstimate.warning_threshold()
    end

    test "a configured threshold lowers the warning without moving the Athena limit" do
      Application.put_env(:report_server, :partition_warning_threshold, 250_000)

      assert PartitionEstimate.warning_threshold() == 250_000
      assert PartitionEstimate.athena_partition_limit() == 1_000_000
    end
  end
end
