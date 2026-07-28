defmodule ReportServer.Reports.Portal.Csv do
  @delimiter "\n"

  def header_row(columns) do
    [columns] |> CSV.encode(delimiter: @delimiter) |> Enum.join("")
  end

  def encode_batch([]), do: ""
  def encode_batch(rows) do
    rows |> CSV.encode(delimiter: @delimiter) |> Enum.join("")
  end
end
