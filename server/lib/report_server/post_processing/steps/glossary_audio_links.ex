defmodule ReportServer.PostProcessing.Steps.GlossaryAudioLinks do
  alias ReportServer.PostProcessing.JobParams
  alias ReportServer.PostProcessing.Step
  alias ReportServer.PostProcessing.Steps.Helpers

  @id "glossary_audio_link"
  @glossary_map "glossary_map"

  def step do
    %Step{
      id: @id,
      label: "Add glossary_audio_link column",
      init: &init/1,
      process_row: &process_row/3
    }
  end

  def init(%JobParams{step_state: step_state} = params) do
    # get all the resource url columns for later use
    resource_url_cols = Helpers.get_cols_ending_with(params, "_resource_url")

    # add a column after each resource url column
    params = Enum.reduce(resource_url_cols, params, fn {resource_url_col, _v}, acc ->
      Helpers.add_output_column(acc, glossary_audio_link_col(resource_url_col), :after, resource_url_col)
    end)

    step_state = Map.put(step_state, @id, resource_url_cols)
    %{params | step_state: step_state}
  end

  # header row
  def process_row(%JobParams{step_state: step_state}, row, _data_row? = false) do
    # copy headers to new columns
    resource_url_cols = Map.get(step_state, @id)
    Enum.reduce(resource_url_cols, row, fn {resource_url_col, index}, {input, output} ->
      {input, Map.put(output, glossary_audio_link_col(resource_url_col), input[index])}
    end)
  end

  # data rows
  def process_row(%JobParams{mode: mode, step_state: step_state}, row, _data_row? = true) do
    resource_url_cols = Map.get(step_state, @id)

    glossary_map = Map.get(step_state, @glossary_map, fn ->
      get_glossary_map(row, resource_url_cols)
    end)

    Enum.reduce(resource_url_cols, row, fn {resource_url_col, _index}, {input, output} ->
      {input, Map.put(output, glossary_audio_link_col(resource_url_col), glossary_audio_link?(mode, output, resource_url_col, glossary_map))}
    end)
  end

  defp glossary_audio_link?(_mode, _output, _glossary_col, _glossary_map) do
    # TODO: look up plugin state and see if there are audio glossary definitions
    "https://portal-report.concord.org/branch/master/?glossary-audio=true"
  end

  defp glossary_audio_link_col(glossary_col), do: "#{glossary_col}_glossary_audio_link"

  # TODO: parse the resource urls and get the activity/sequence JSON and then fetch that and see if the glossary is being used
  defp get_glossary_map(_row, _resource_url_cols), do: %{}
end
