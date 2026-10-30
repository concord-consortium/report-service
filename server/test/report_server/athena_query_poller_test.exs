defmodule ReportServer.AthenaQueryPollerTest do
  # Stubs :athena_db through the application environment, which is global.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ReportServer.AthenaQueryPoller

  # Shaped like a reason that echoes the generated query, which is what the poller must not log:
  # the log stream is outside both of the owner-gated surfaces the reason was analyzed against.
  @reason "SYNTAX_ERROR: line 5:12: Column cannot be resolved; near " <>
            "IN ('a1b2c3d4e5f6','9f8e7d6c5b4a') " <>
            "https://learn.concord.org/dataservice/external_activity_data/a1b2c3d4e5f6"

  setup do
    on_exit(fn -> Application.delete_env(:report_server, :athena_db) end)
    :ok
  end

  defp start_athena_stub(state) do
    Application.put_env(:report_server, :athena_db, ReportServer.AthenaDBStub)

    {:ok, pid} =
      ReportServer.AthenaDBStub.start(%{
        get_query_info: fn _query_id -> {:ok, state, nil, @reason} end
      })

    on_exit(fn -> if Process.alive?(pid), do: Agent.stop(pid) end)
  end

  defp assert_logs_the_code_only(log) do
    assert log =~ "qid-1"
    assert log =~ "SYNTAX_ERROR"
    refute log =~ "Column cannot be resolved"
    refute log =~ "a1b2c3d4e5f6"
    refute log =~ "dataservice"
  end

  describe "wait_for/1 logging" do
    test "logs the error code and no message text for a failed query" do
      start_athena_stub("failed")

      log =
        capture_log(fn ->
          assert AthenaQueryPoller.wait_for("qid-1") == {:error, "Query failed"}
        end)

      assert_logs_the_code_only(log)
    end

    test "logs the error code and no message text for a cancelled query" do
      start_athena_stub("cancelled")

      log =
        capture_log(fn ->
          assert AthenaQueryPoller.wait_for("qid-1") == {:error, "Query cancelled"}
        end)

      assert_logs_the_code_only(log)
    end

    test "logs nothing for a succeeded query" do
      start_athena_stub("succeeded")

      log = capture_log(fn -> assert AthenaQueryPoller.wait_for("qid-1") == {:ok, nil} end)

      refute log =~ "qid-1"
    end
  end

  describe "wait_for/2 options" do
    test "answers :timeout once the next poll would pass the deadline" do
      start_athena_stub("running")

      {elapsed_us, result} =
        :timer.tc(fn -> AthenaQueryPoller.wait_for("qid-1", timeout_ms: 50, interval_ms: 10) end)

      assert result == {:error, :timeout}
      assert elapsed_us < 1_000_000
    end

    test "polls at the given interval until the query succeeds" do
      Application.put_env(:report_server, :athena_db, ReportServer.AthenaDBStub)
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      {:ok, pid} =
        ReportServer.AthenaDBStub.start(%{
          get_query_info: fn _query_id ->
            case Agent.get_and_update(counter, &{&1 + 1, &1 + 1}) do
              3 -> {:ok, "succeeded", "s3://bucket/out.csv", nil}
              _ -> {:ok, "running", nil, nil}
            end
          end
        })

      on_exit(fn -> if Process.alive?(pid), do: Agent.stop(pid) end)

      assert AthenaQueryPoller.wait_for("qid-1", interval_ms: 1, timeout_ms: 1_000) == {:ok, "s3://bucket/out.csv"}
      assert Agent.get(counter, & &1) == 3
    end
  end
end
