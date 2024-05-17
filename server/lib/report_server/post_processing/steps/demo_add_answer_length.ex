defmodule ReportServer.PostProcessing.Steps.DemoAddAnswerLength do
  alias ReportServer.PostProcessing.JobParams
  alias ReportServer.PostProcessing.Step
  alias ReportServer.PostProcessing.Steps.Helpers

  @id "demo_add_answer_length"

  def step do
    %Step{
      id: @id,
      label: "Demo: Add column for answer text length",
      init: &init/1,
      process_row: &process_row/2
    }
  end

  def init(%JobParams{step_state: step_state} = params) do
    text_cols = Helpers.get_text_cols(params)

    params = Enum.reduce(text_cols, params, fn {text_col, _index}, acc ->
      Helpers.add_output_column(acc, length_col(text_col), :after, text_col)
    end)

    step_state = Map.put(step_state, @id, text_cols)
    %{params | step_state: step_state}
  end

  def process_row(%JobParams{step_state: step_state}, row) do
    # measure the length of each text answer
    text_cols = Map.get(step_state, @id)
    Enum.reduce(text_cols, row, fn {text_col, index}, {input, output} ->
      {input, Map.put(output, length_col(text_col), String.length(input[index]))}
    end)
  end

  defp length_col(text_col), do: "#{text_col}_length"
end
