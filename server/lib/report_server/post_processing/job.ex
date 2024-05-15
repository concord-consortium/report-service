defmodule ReportServer.PostProcessing.Job do
  alias ElixirLS.LanguageServer.Providers.FoldingRange.Helpers
  alias ReportServerWeb.Aws
  alias ReportServer.PostProcessing.JobParams
  alias ReportServer.PostProcessing.Steps.Helpers

  @derive {Jason.Encoder, only: [:id, :steps, :status, :result]}
  defstruct id: nil, steps: [], status: :queued, ref: nil, result: nil

  def run(mode, query_result, steps, workgroup_credentials) do
    case Aws.get_file_stream(mode, workgroup_credentials, query_result.output_location) do
      {:ok, stream } ->
        stream
        |> CSV.decode()
        |> Stream.transform(nil, fn {:ok, row}, acc ->
          if acc == nil do
            # the accumulator is nil on the first line, with the headers which we parse and transform and
            # replace the line with the transformed header in the stream
            header_map = Helpers.get_header_map(row)
            params = %JobParams{
              input_header: row,
              input_header_map: header_map,
              output_header: row,
              output_header_map: header_map
            }
            params = Enum.reduce(steps, params, fn step, acc -> step.init.(acc) end)
            {[params.output_header], params}
          else
            # if the first column is an integer (student id) run the steps on the row, otherwise
            # just pass it through
            case Integer.parse(Enum.at(row, 0, "")) do
              {_, ""} -> {[run_steps(row, steps, acc)], acc}
              _ -> {[row], acc}
            end
          end
        end)
        |> CSV.encode()
        |> output_stream(mode)
      error ->
        error
    end
  end

  defp run_steps(input_row, steps, params = %JobParams{input_header_map: input_header_map, output_header: output_header, output_header_map: output_header_map}) do
    input = Enum.with_index(input_row) |> Enum.map(fn {k,v} -> {v,k} end) |> Map.new()
    output = Map.new(output_header_map, fn {k,_v} -> {k, input[input_header_map[k]] || ""} end)
    {_input, output} = Enum.reduce(steps, {input, output}, fn step, acc ->
      step.process_row.(params, acc)
    end)
    Enum.reduce(output_header, [], fn k, acc ->
      [output[k] | acc]
    end)
    |> Enum.reverse()
  end

  defp output_stream(stream, "demo") do
    stream
    |> Enum.join()
  end

  defp output_stream(stream, _mode) do
    # TODO: for now save the output - later save stream to S3 and return url
    stream
    |> Enum.join()
  end
end
