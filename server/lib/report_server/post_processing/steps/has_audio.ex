defmodule ReportServer.PostProcessing.Steps.HasAudio do
  alias ReportServer.PostProcessing.JobParams
  alias ReportServer.PostProcessing.Step
  alias ReportServer.PostProcessing.Steps.Helpers

  @id "has_audio"

  def step do
    %Step{
      id: @id,
      label: "Add has_audio column for open response answers",
      init: &init/1,
      process_row: &process_row/2
    }
  end

  def init(%JobParams{step_state: step_state} = params) do
    # get columns that end with _text
    text_cols = Helpers.get_text_cols(params)

    # add a column after each text column
    params = Enum.reduce(text_cols, params, fn {k, _v}, acc ->
      Helpers.add_output_column(acc, has_audio_col(k), :after, k)
    end)

    step_state = Map.put(step_state, @id, text_cols)
    %{params | step_state: step_state}
  end

  def process_row(%JobParams{mode: mode, step_state: step_state}, row) do
    text_cols = Map.get(step_state, @id)
    Enum.reduce(text_cols, row, fn {k, v}, {input, output} ->
      {input, Map.put(output, has_audio_col(k), has_audio?(mode, output, k))}
    end)
  end

  defp has_audio?(mode, output, text_col) do
    with {:ok, answer} <- Helpers.get_answer(mode, output, text_col),
         {:ok, %{ interactive_state: interactive_state }} <- Helpers.parse_report_state(answer["report_state"]) do
        interactive_state["audioFile"] != nil
    else
      _ ->
        false
    end
  end

  defp has_audio_col(k), do: "#{k}_has_audio"
end
