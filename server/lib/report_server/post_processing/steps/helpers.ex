defmodule ReportServer.PostProcessing.Steps.Helpers do
  require Logger

  alias ReportServer.PostProcessing.JobParams
  alias ReportServerWeb.ReportService

  @col_regex ~r/(?<res>res_\d+)_(?<question_id>.+)_/

  def get_header_map(list) do
    Enum.with_index(list) |> Map.new()
  end

  def get_output_header_map(input_row) do
    Enum.with_index(input_row) |> Enum.map(fn {k,v} -> {v,k} end) |> Map.new()
  end

  def get_text_cols(%JobParams{} = params) do
    get_cols_ending_with(params, "_text")
  end

  def get_remote_endpoint_cols(%JobParams{} = params) do
    get_cols_ending_with(params, "_remote_endpoint")
  end

  def get_resource_cols(%JobParams{input_header_map: input_header_map}) do
    Enum.reduce(input_header_map, %{}, fn {k,v}, acc ->
      case Regex.run(~r/^(res_\d+)_(.*)/, k) do
        [_, res, rest] ->
          acc
          |> Map.put_new(res, %{})
          |> put_in([res, rest], {k,v})
        nil ->
          acc
      end
    end)
  end

  def get_cols_ending_with(%JobParams{input_header_map: input_header_map}, ending) do
    Enum.reduce(input_header_map, [], fn {k,v}, acc ->
      if String.ends_with?(k, ending) do
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

  def get_res_and_question_id(col) do
    %{"question_id" => question_id, "res" => res} = Regex.named_captures(@col_regex, col)
    {res, question_id}
  end

  def get_answer(mode, output, col) do
    with {:ok, question_id, remote_endpoint, url} <- parse_res_answer_col(output, col),
         {:ok, source} <- get_source_from_url(url) do
      ReportService.get_answer(mode, source, remote_endpoint, question_id)
    else
      {:error, error} ->
        Logger.error("Error getting answer: #{error}")
        {:error, error}
    end
  end

  def parse_report_state(report_state_string) do
    with {:ok, report_state} <- Jason.decode(report_state_string),
         {:ok, authored_state} <- Jason.decode(report_state["authoredState"] || "{}"),
         {:ok, interactive_state} <- Jason.decode(report_state["interactiveState"] || "{}") do
      {:ok, %{report_state: report_state, authored_state: authored_state, interactive_state: interactive_state}}
    else
      {:error, error} ->
        Logger.error("Error parsing report state: #{error}")
        {:error, error}
    end
  end

  def parse_res_answer_col(output, col) do
    {res, question_id} = get_res_and_question_id(col)
    remote_endpoint = output["#{res}_remote_endpoint"]
    url = output["#{res}_#{question_id}_url"]

    if remote_endpoint != nil && url != nil do
      {:ok, question_id, remote_endpoint, url}
    else
      {:error, "Unable to get remote_endpoint or url"}
    end
  end

  def get_source_from_url(url) do
    uri = URI.parse(url)
    query = if uri.query != nil, do: URI.decode_query(uri.query), else: %{}
    source = query["answersSourceKey"]
    if source != nil do
      {:ok, source}
    else
      {:error, "Unable to get source from url"}
    end
  end

end
