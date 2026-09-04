defmodule ReportServer.ReportQueryTest do
  # the athena query tests set the global :athena env, so this must not overlap async cases
  use ExUnit.Case, async: false
  alias ReportServer.Reports.{ReportFilter, ReportQuery}

  def normalized_sql(query = %ReportQuery{}) do
    {:ok, sql} = ReportQuery.get_sql(query)
    sql |> String.replace(~r/\s+/, " ") |> String.trim()
  end

  defp learner_data do
    [
      %{
        query_id: "Q1",
        learners: [
          %{run_remote_endpoint: "https://example.com/dataservice/external_activity_data/KEY1"},
          %{run_remote_endpoint: "https://example.com/dataservice/external_activity_data/KEY2"}
        ]
      }
    ]
  end

  defp athena_sql(report_filter) do
    {:ok, query} = ReportQuery.get_athena_query(report_filter, learner_data(), [])
    normalized_sql(query)
  end

  describe "get_sql/1" do
    test "constructs a SQL query" do
      query = %ReportQuery{
        cols: [{"table.id", "id"}],
        from: "table",
        join: ["JOIN table2 ON table.id = table2.id"],
        where: ["table.id = 1"],
        group_by: "table.id",
        order_by: [{"id", :asc}]
      }
      assert normalized_sql(query) == "SELECT table.id AS id FROM table JOIN table2 ON table.id = table2.id WHERE (table.id = 1) GROUP BY table.id ORDER BY id asc"
    end

    test "correctly orders WHERE clauses" do
      query = %ReportQuery{
        cols: [{"table.id", "id"}],
        from: "table",
        join: [],
        where: [
          "final",
          [ "subA1", "subA2"],
          [ "subB1", "subB2"],
          "initial"
        ],
        group_by: "",
        order_by: [{"id", :asc}]
      }
      assert normalized_sql(query) == "SELECT table.id AS id FROM table WHERE (initial) AND (subB1) AND (subB2) AND (subA1) AND (subA2) AND (final) ORDER BY id asc"
    end

    @tag :skip # FIXME: ReportFilterQuery removes duplicates by ReportQuery does not
    test "removes duplicate JOIN clauses" do
      query = %ReportQuery{
        cols: [{"table.id", "id"}],
        from: "table",
        join: [
          "JOIN table2 ON table.id = table2.id",
          [
            "JOIN table3 ON table.id = table3.id",
            "JOIN table2 ON table.id = table2.id"
          ]
        ],
        where: [ "table.id = 1" ],
        group_by: "",
        order_by: [{"id", :asc}]
      }
      assert normalized_sql(query) == "SELECT * FROM table JOIN table3 ON table.id = table3.id JOIN table2 ON table.id = table2.id WHERE (table.id = 1) ORDER BY id asc"
    end

  end

  describe "update_query/2" do

    test "adds JOIN and WHERE clauses" do
      query = %ReportQuery{
        cols: [{"table.id", "id"}],
        from: "table",
        join: [],
        where: ["table.id = 1"],
        group_by: "table.id",
        order_by: [{"id", :desc}]
      }
      updated = ReportQuery.update_query(query,
        join: ["JOIN table2 ON table.id = table2.id"],
        where: ["table2.id = 1"])
      assert updated == {:ok, %ReportQuery{
        cols: [{"table.id", "id"}],
        from: "table",
        join: [["JOIN table2 ON table.id = table2.id"]],
        where: [["table2.id = 1"], "table.id = 1"],
        group_by: "table.id",
        order_by: [{"id", :desc}]
      }}
    end

    test "rejects empty query" do
      query = %ReportQuery{
        cols: [{"table.id", "id"}],
        from: "table",
        join: [],
        where: [],
        group_by: "table.id",
        order_by: [{"id", :asc}]
      }
      updated = ReportQuery.update_query(query, join: [], where: [])
      assert updated == {:error, "Cannot run query with no filters"}
    end

  end

  describe "get_athena_query/3" do
    @select_and_join "SELECT \"log\".\"id\" AS id, \"log\".\"session\" AS session, \"log\".\"application\" AS application, \"log\".\"activity\" AS activity, \"log\".\"event\" AS event, \"log\".\"event_value\" AS event_value, \"log\".\"time\" AS time, \"log\".\"parameters\" AS parameters, \"log\".\"extras\" AS extras, \"log\".\"run_remote_endpoint\" AS run_remote_endpoint, \"log\".\"timestamp\" AS timestamp FROM \"log_ingester_production\".\"logs_by_app_and_secure_key\" log INNER JOIN \"report-service\".\"learners\" learner ON ( learner.query_id IN ('Q1') AND learner.run_remote_endpoint = log.run_remote_endpoint )"
    @secure_key_clause "(log.secure_key IN ('KEY1','KEY2'))"
    @date_clauses "(log.time <= 1751327999) AND (log.time >= 1725148800) AND " <>
                    "((log.year < 2025 OR (log.year = 2025 AND log.month <= 6))) AND " <>
                    "((log.year > 2024 OR (log.year = 2024 AND log.month >= 9)))"

    setup do
      previous = Application.get_env(:report_server, :athena)
      Application.put_env(:report_server, :athena, log_db_name: "log_ingester_production")

      on_exit(fn ->
        if previous do
          Application.put_env(:report_server, :athena, previous)
        else
          Application.delete_env(:report_server, :athena)
        end
      end)
    end

    test "a nil application filter emits the unfiltered query" do
      assert athena_sql(%ReportFilter{}) == "#{@select_and_join} WHERE #{@secure_key_clause}"
    end

    test "an empty application filter emits the unfiltered query, which is what the form submits" do
      assert athena_sql(%ReportFilter{app: ""}) == "#{@select_and_join} WHERE #{@secure_key_clause}"
    end

    test "a nil application filter with a date range emits only the date clauses" do
      filter = %ReportFilter{start_date: "2024-09-01", end_date: "2025-06-30"}

      assert athena_sql(filter) ==
               "#{@select_and_join} WHERE #{@date_clauses} AND #{@secure_key_clause}"
    end

    test "an empty application filter with a date range emits only the date clauses" do
      filter = %ReportFilter{app: "", start_date: "2024-09-01", end_date: "2025-06-30"}

      assert athena_sql(filter) ==
               "#{@select_and_join} WHERE #{@date_clauses} AND #{@secure_key_clause}"
    end

    test "a set application filter adds one predicate beside the secure key clause" do
      assert athena_sql(%ReportFilter{app: "CLUE"}) ==
               "#{@select_and_join} WHERE (log.app = 'CLUE') AND #{@secure_key_clause}"
    end

    test "a set application filter stays beside the secure key clause with a date range" do
      filter = %ReportFilter{app: "CLUE", start_date: "2024-09-01", end_date: "2025-06-30"}

      assert athena_sql(filter) ==
               "#{@select_and_join} WHERE #{@date_clauses} AND (log.app = 'CLUE') AND " <>
                 "#{@secure_key_clause}"
    end

    test "the predicate is emitted once, not once per learner or runnable" do
      occurrences = athena_sql(%ReportFilter{app: "CLUE"}) |> String.split("log.app") |> length()

      assert occurrences - 1 == 1
    end

    test "an application outside the projected values is an error" do
      assert {:error, message} =
               ReportQuery.get_athena_query(%ReportFilter{app: "NotAnApp"}, learner_data(), [])

      assert message =~ "Unknown application filter"
    end

    test "a value that would break out of the string literal is an error" do
      for app <- ["CL'UE", "CLUE' OR '1'='1", "CLUE; DROP TABLE learners"] do
        assert {:error, _} =
                 ReportQuery.get_athena_query(%ReportFilter{app: app}, learner_data(), [])
      end
    end

    test "an unknown application is reported ahead of the no learners outcome" do
      assert {:error, message} =
               ReportQuery.get_athena_query(%ReportFilter{app: "NotAnApp"}, [], [])

      assert message =~ "Unknown application filter"
    end

    test "no learners is still reported when the application filter is valid" do
      assert {:error, message} = ReportQuery.get_athena_query(%ReportFilter{app: "CLUE"}, [], [])

      assert message =~ "No learners found"
    end
  end
end
