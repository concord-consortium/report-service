defmodule ReportServer.Reports.Portal.CsvTest do
  use ExUnit.Case, async: true

  alias ReportServer.PortalDbs
  alias ReportServer.Reports.Portal.Csv

  # the pre-refactor LiveView format_results/2 recipe, reproduced here as the byte-compat reference
  defp legacy_csv(columns, rows) do
    %MyXQL.Result{columns: columns, rows: rows, num_rows: length(rows)}
    |> PortalDbs.map_columns_on_rows()
    |> Stream.map(& &1)
    |> CSV.encode(headers: columns |> Enum.map(&String.to_atom/1), delimiter: "\n")
    |> Enum.to_list()
    |> Enum.join("")
  end

  @columns ["a", "b,c", "d"]
  @rows [
    ["1", "has,comma", "x"],
    ["2", "has\"quote", "y"],
    ["3", "has\nnewline", "z"],
    ["4", nil, ""]
  ]

  test "is byte-identical to the legacy encoder for a non-empty result" do
    expected = legacy_csv(@columns, @rows)
    assert Csv.header_row(@columns) <> Csv.encode_batch(@rows) == expected
  end

  test "per-batch encoding equals a single materialized encode" do
    {batch1, batch2} = Enum.split(@rows, 2)
    assert Csv.encode_batch(batch1) <> Csv.encode_batch(batch2) == Csv.encode_batch(@rows)
  end

  test "an empty result is a header-only line, not an empty body" do
    # the legacy encoder emitted a zero-byte body for zero rows (the pre-existing bug)
    assert legacy_csv(@columns, []) == ""

    body = Csv.header_row(@columns) <> Csv.encode_batch([])
    refute body == ""
    assert body == Csv.header_row(@columns)
    assert body == "a,\"b,c\",d\n"
  end
end
