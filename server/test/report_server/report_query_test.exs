defmodule ReportServer.ReportQueryTest do
  use ExUnit.Case, async: true
  alias ReportServer.Reports.ReportQuery

  def normalized_sql(query = %ReportQuery{}) do
    {:ok, sql} = ReportQuery.get_sql(query)
    sql |> String.replace(~r/\s+/, " ") |> String.trim()
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

end
