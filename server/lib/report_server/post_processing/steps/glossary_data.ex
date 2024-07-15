defmodule ReportServer.PostProcessing.Steps.GlossaryData do
  require Logger

  alias ReportServer.PostProcessing.JobParams
  alias ReportServer.PostProcessing.Step
  alias ReportServer.PostProcessing.Steps.Helpers
  alias ReportServerWeb.ReportService

  @id "glossary_data"
  @remote_endpoint "remote_endpoint"
  @resource_url "resource_url"

  def step do
    %Step{
      id: @id,
      label: "Add glossary data column",
      init: &init/1,
      process_row: &process_row/3
    }
  end

  def init(%JobParams{step_state: step_state} = params) do
    # get all the resource columns
    all_resource_cols = Helpers.get_resource_cols(params)

    # add a column after each resource url column
    params = Enum.reduce(all_resource_cols, params, fn {resource, resource_cols}, acc ->
      {remote_endpoint_col, _index} = resource_cols[@remote_endpoint]
      Helpers.add_output_column(acc, glossary_data_col(resource), :after, remote_endpoint_col)
    end)

    step_state = Map.put(step_state, @id, all_resource_cols)
    %{params | step_state: step_state}
  end

  # header row
  def process_row(%JobParams{step_state: step_state}, row, _data_row? = false) do
    # copy headers to new columns
    all_resource_cols = Map.get(step_state, @id)
    Enum.reduce(all_resource_cols, row, fn {resource, resource_cols}, {input, output} ->
      {_remote_endpoint_col, index} = resource_cols[@remote_endpoint]
      {input, Map.put(output, glossary_data_col(resource), input[index])}
    end)
  end

  # data rows
  def process_row(%JobParams{mode: mode, step_state: step_state}, row, _data_row? = true) do
    all_resource_cols = Map.get(step_state, @id)

    Enum.reduce(all_resource_cols, row, fn {resource, resource_cols}, {input, output} ->
      {_remote_endpoint_col, remote_endpoint_col_index} = resource_cols[@remote_endpoint]
      {_resource_url_col, resource_url_col_index} = resource_cols[@resource_url]
      glossary_data = case get_glossary_data(mode, input[remote_endpoint_col_index], input[resource_url_col_index]) do
        {:ok, {key, plugin_state}} -> Jason.encode!(%{"key" => key, "plugin_state" => plugin_state})
        _ -> ""
      end
      {input, Map.put(output, glossary_data_col(resource), glossary_data)}
    end)
  end

  defp get_glossary_data(mode, remote_endpoint, resource_url) do
    source = URI.parse(resource_url).host
    with {:ok, plugin_states} <- ReportService.get_plugin_states(mode, source, remote_endpoint),
         {:ok, glossary_plugin_key_and_state} <- get_first_glossary_plugin_key_and_state(plugin_states) do
      {:ok, glossary_plugin_key_and_state}
    else
      {:error, error} ->
        Logger.error(error)
        {:error, error}
    end
  end

  defp glossary_data_col(resource), do: "#{resource}_glossary_data"

  defp get_first_glossary_plugin_key_and_state(plugin_states) do
    first_plugin_state = Enum.find(plugin_states, fn {_k, v} ->
      is_map(v) && Map.has_key?(v, "definitions") && is_map(v["definitions"])
    end)
    if first_plugin_state != nil do
      {:ok, first_plugin_state}
    else
      {:error, "No glossary plugin state found"}
    end
  end
end
