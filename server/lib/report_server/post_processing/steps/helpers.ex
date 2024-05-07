defmodule ReportServer.PostProcessing.Steps.Helpers do
  alias ReportServer.PostProcessing.JobParams

  def get_header_map(list) do
    Enum.with_index(list) |> Map.new()
  end

  def get_output_header_map(input_row) do
    Enum.with_index(input_row) |> Enum.map(fn {k,v} -> {v,k} end) |> Map.new()
  end

  def get_text_cols(%JobParams{input_header_map: input_header_map}) do
    # get columns that end with _text
    Enum.reduce(input_header_map, [], fn {k,v}, acc ->
      if String.ends_with?(k, "_text") do
        [{k, v} | acc]
      else
        acc
      end
    end)
  end

  def add_output_column(%JobParams{output_header_map: output_header_map} = params, new_column, :before, existing_column) do
    add_output_column(params, new_column, :at, max(0, output_header_map[existing_column] - 1))
  end
  def add_output_column(%JobParams{output_header_map: output_header_map} = params, new_column, :after, existing_column) do
    add_output_column(params, new_column, :at, output_header_map[existing_column] + 1)
  end
  def add_output_column(%JobParams{output_header: output_header} = params, new_column, :at, index) do
    output_header = List.insert_at(output_header, index, new_column)
    output_header_map = get_header_map(output_header)
    %JobParams{params | output_header: output_header, output_header_map: output_header_map}
  end

end
