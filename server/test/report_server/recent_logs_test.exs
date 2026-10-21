defmodule ReportServer.RecentLogsTest do
  # sets the global :athena env, so this must not overlap async cases
  use ExUnit.Case, async: false

  alias ReportServer.RecentLogs

  @window_start 1_792_454_400_000

  setup do
    previous = Application.get_env(:report_server, :athena)
    Application.put_env(:report_server, :athena, log_db_name: "log_ingester_qa")

    on_exit(fn ->
      if previous,
        do: Application.put_env(:report_server, :athena, previous),
        else: Application.delete_env(:report_server, :athena)
    end)
  end

  defp ms(datetime), do: DateTime.to_unix(datetime, :millisecond)
  defp normalized(sql), do: sql |> String.replace(~r/\s+/, " ") |> String.trim()
  defp window, do: RecentLogs.window(ms(~U[2026-10-21 15:00:00Z]))

  defp learners do
    [
      %{run_remote_endpoint: "https://p/dataservice/external_activity_data/K1", user_id: 101, primary_user_id: 101},
      %{run_remote_endpoint: "https://p/dataservice/external_activity_data/K2", user_id: 102, primary_user_id: 99}
    ]
  end

  @select ~s(SELECT "log"."id" AS id, "log"."session" AS session, "log"."application" AS application, ) <>
            ~s("log"."activity" AS activity, "log"."event" AS event, "log"."event_value" AS event_value, ) <>
            ~s("log"."time" AS time, "log"."parameters" AS parameters, "log"."extras" AS extras, ) <>
            ~s("log"."run_remote_endpoint" AS run_remote_endpoint, "log"."timestamp" AS timestamp, ) <>
            ~s("learner"."user_id" AS user_id, "learner"."primary_user_id" AS primary_user_id)

  @from ~s(FROM "log_ingester_qa"."logs_by_hour" log ) <>
          ~s[JOIN (VALUES ('https://p/dataservice/external_activity_data/K1', 101, 101), ] <>
          ~s[('https://p/dataservice/external_activity_data/K2', 102, 99)) ] <>
          ~s[AS learner (run_remote_endpoint, user_id, primary_user_id) ] <>
          ~s(ON learner.run_remote_endpoint = log.run_remote_endpoint)

  describe "window/1" do
    test "starts at 00:00 UTC of the day before the query's date, on either side of midnight" do
      assert RecentLogs.window(ms(~U[2026-10-21 00:00:30Z])) ==
               %{window_start: @window_start, nightly_through: ~D[2026-10-19]}

      assert RecentLogs.window(ms(~U[2026-10-21 23:59:59Z])) ==
               %{window_start: @window_start, nightly_through: ~D[2026-10-19]}
    end

    test "crosses month and year boundaries" do
      assert RecentLogs.window(ms(~U[2026-11-01 00:05:00Z])) ==
               %{window_start: ms(~U[2026-10-31 00:00:00Z]), nightly_through: ~D[2026-10-30]}

      assert RecentLogs.window(ms(~U[2026-01-01 00:00:00Z])) ==
               %{window_start: ms(~U[2025-12-31 00:00:00Z]), nightly_through: ~D[2025-12-30]}
    end
  end

  describe "dt_predicate/1" do
    test "pads the lower bound an hour, and the upper bound when there is one" do
      since = RecentLogs.window(ms(~U[2026-01-01 00:00:00Z])).window_start

      assert RecentLogs.dt_predicate(%{since: since, until: nil}) == "log.dt >= '2025/12/30/23'"

      assert RecentLogs.dt_predicate(%{since: since, until: ms(~U[2026-01-01 05:30:00Z])}) ==
               "log.dt >= '2025/12/30/23' AND log.dt <= '2026/01/01/06'"
    end
  end

  describe "bounds/3" do
    test "with no parameters, reads from the window start with no upper bound" do
      assert RecentLogs.bounds(%{}, 601, window()) == {:ok, %{since: @window_start, until: nil}}
    end

    test "takes start and end inside the window as given" do
      params = %{"start" => "#{@window_start + 1_000}", "end" => "#{@window_start + 3_600_000}"}

      assert RecentLogs.bounds(params, 601, window()) ==
               {:ok, %{since: @window_start + 1_000, until: @window_start + 3_600_000}}
    end

    test "refuses a start or an end before the window" do
      assert RecentLogs.bounds(%{"start" => "#{@window_start - 1}"}, 601, window()) == {:error, :bad_bound}
      assert RecentLogs.bounds(%{"end" => "#{@window_start - 1}"}, 601, window()) == {:error, :bad_bound}
    end

    test "refuses malformed bounds and an end not after start" do
      for params <- [
            %{"start" => "#{@window_start}", "end" => "#{@window_start}"},
            %{"start" => "abc"},
            %{"start" => "-1"},
            %{"end" => "10000000000000"},
            %{"start" => "+#{@window_start}"},
            %{"start" => "0#{@window_start}"},
            %{"start" => "#{@window_start}\n"}
          ] do
        assert RecentLogs.bounds(params, 601, window()) == {:error, :bad_bound}, inspect(params)
      end
    end

    test "refuses a cursor combined with start or end" do
      cursor = RecentLogs.next_cursor(601, @window_start + 700_000, 600_000)

      assert RecentLogs.bounds(%{"cursor" => cursor, "start" => "#{@window_start}"}, 601, window()) ==
               {:error, :cursor_with_bounds}

      assert RecentLogs.bounds(%{"cursor" => cursor, "end" => "#{@window_start + 1}"}, 601, window()) ==
               {:error, :cursor_with_bounds}
    end

    test "a cursor round-trips for its class, with no upper bound" do
      cursor = RecentLogs.next_cursor(601, @window_start + 700_000, 600_000)

      assert RecentLogs.bounds(%{"cursor" => cursor}, 601, window()) ==
               {:ok, %{since: @window_start + 100_000, until: nil}}
    end

    test "refuses a cursor for another class, version or shape" do
      encode = fn payload -> "v1." <> Base.url_encode64(Jason.encode!(payload), padding: false) end

      for cursor <- [
            RecentLogs.next_cursor(602, @window_start + 700_000, 600_000),
            "v2." <> Base.url_encode64(Jason.encode!(%{"c" => 601, "s" => @window_start}), padding: false),
            "v1.%%%",
            encode.(%{"c" => 601, "s" => "#{@window_start}"}),
            encode.(%{"c" => 601, "s" => 10_000_000_000_000})
          ] do
        assert RecentLogs.bounds(%{"cursor" => cursor}, 601, window()) == {:error, :bad_cursor}, cursor
      end
    end

    test "a cursor from before the window has expired" do
      cursor = RecentLogs.next_cursor(601, @window_start - 1, 0)
      assert RecentLogs.bounds(%{"cursor" => cursor}, 601, window()) == {:error, :expired_cursor}
    end
  end

  describe "sql/2" do
    test "reads logs_by_hour for the learners from since, newest rows unbounded" do
      sql = RecentLogs.sql(learners(), %{since: @window_start, until: nil}) |> normalized()

      assert sql ==
               "#{@select} #{@from} WHERE log.dt >= '2026/10/19/23' AND log.timestamp >= 1792454400000 " <>
                 "ORDER BY log.timestamp, log.id"

      refute sql =~ ~s("log"."time" >=)
      refute sql =~ "log.app"
      refute sql =~ ~s("log"."username")
      refute sql =~ "log.timestamp <"
      refute sql =~ "log.dt <="
    end

    test "an until adds both upper bounds" do
      until = @window_start + 3_600_000
      sql = RecentLogs.sql(learners(), %{since: @window_start, until: until}) |> normalized()

      assert sql ==
               "#{@select} #{@from} WHERE log.dt >= '2026/10/19/23' AND log.dt <= '2026/10/20/02' " <>
                 "AND log.timestamp >= 1792454400000 AND log.timestamp < 1792458000000 ORDER BY log.timestamp, log.id"
    end

    test "doubles a quote in a learner endpoint" do
      learner = %{run_remote_endpoint: "https://p/x/K'1", user_id: 1, primary_user_id: 1}
      sql = RecentLogs.sql([learner], %{since: @window_start, until: nil})

      assert sql =~ "('https://p/x/K''1', 1, 1)"
    end
  end

  describe "row/1" do
    defp csv_row(overrides) do
      RecentLogs.columns()
      |> Map.new(&{&1, "x"})
      |> Map.merge(%{"time" => "1792454400", "timestamp" => "1792454400000", "user_id" => "101", "primary_user_id" => "99"})
      |> Map.merge(overrides)
    end

    test "types the integer columns and makes an empty field null" do
      row = RecentLogs.row(csv_row(%{"extras" => "", "parameters" => "{\"a\":\"line1\nline2\"}"}))
      decoded = row |> Jason.encode!() |> Jason.decode!()

      assert decoded["time"] == 1_792_454_400
      assert decoded["timestamp"] == 1_792_454_400_000
      assert decoded["user_id"] == 101
      assert decoded["primary_user_id"] == 99
      assert decoded["extras"] == nil
      assert decoded["parameters"] == "{\"a\":\"line1\nline2\"}"
    end

    test "encodes its keys in the student-actions column order" do
      json = csv_row(%{}) |> RecentLogs.row() |> Jason.encode!()
      keys = Regex.scan(~r/"([a-z_]+)":/, json) |> Enum.map(fn [_, key] -> key end)

      assert keys == RecentLogs.columns()

      assert RecentLogs.columns() ==
               ~w(id session application activity event event_value time parameters extras run_remote_endpoint timestamp user_id primary_user_id)
    end

    test "raises on a CSV missing a column" do
      assert_raise KeyError, fn -> RecentLogs.row(Map.delete(csv_row(%{}), "session")) end
    end
  end
end
