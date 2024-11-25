defmodule ReportServer.ReportQueryTest do
  use ExUnit.Case, async: true
  alias ReportServer.Reports.ReportQuery

  describe "get_sql/1" do
    test "constructs a SQL query" do
      query = %ReportQuery{
        select: "*",
        from: "table",
        join: ["JOIN table2 ON table.id = table2.id"],
        where: ["table.id = 1"],
        group_by: "table.id",
        order_by: "table.id DESC"
      }
      assert ReportQuery.get_sql(query) == "SELECT * FROM table JOIN table2 ON table.id = table2.id WHERE (table.id = 1) GROUP BY table.id ORDER BY table.id DESC"
    end

    test "correctly orders WHERE clauses" do
      query = %ReportQuery{
        select: "*",
        from: "table",
        join: [],
        where: [
          "final",
          [ "subA1", "subA2"],
          [ "subB1", "subB2"],
          "initial"
        ],
        group_by: "",
        order_by: ""
      }
      normalized = ReportQuery.get_sql(query) |> String.replace(~r/\s+/, " ") |> String.trim()
      assert normalized == "SELECT * FROM table WHERE (initial) AND (subB1) AND (subB2) AND (subA1) AND (subA2) AND (final)"
    end

    @tag :skip # FIXME: ReportFilterQuery removes duplicates by ReportQuery does not
    test "removes duplicate JOIN clauses" do
      query = %ReportQuery{
        select: "*",
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
        order_by: ""
      }
      normalized = ReportQuery.get_sql(query) |> String.replace(~r/\s+/, " ") |> String.trim()
      assert normalized == "SELECT * FROM table JOIN table3 ON table.id = table3.id JOIN table2 ON table.id = table2.id WHERE (table.id = 1)"

    end

  end

  describe "update_query/2" do

    test "adds JOIN and WHERE clauses" do
      query = %ReportQuery{
        select: "*",
        from: "table",
        join: [],
        where: ["table.id = 1"],
        group_by: "table.id",
        order_by: "table.id DESC"
      }
      updated = ReportQuery.update_query(query,
        join: ["JOIN table2 ON table.id = table2.id"],
        where: ["table2.id = 1"])
      assert updated == {:ok, %ReportQuery{
        select: "*",
        from: "table",
        join: [["JOIN table2 ON table.id = table2.id"]],
        where: [["table2.id = 1"], "table.id = 1"],
        group_by: "table.id",
        order_by: "table.id DESC"
      }}
    end

    test "rejects empty query" do
      query = %ReportQuery{
        select: "*",
        from: "table",
        join: [],
        where: [],
        group_by: "table.id",
        order_by: "table.id"
      }
      updated = ReportQuery.update_query(query, join: [], where: [])
      assert updated == {:error, "Cannot run query with no filters"}
    end

  end

end
