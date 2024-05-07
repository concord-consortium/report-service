defmodule ReportServer.PostProcessing.Steps.DemoUpperCase do
  alias ReportServer.PostProcessing.JobParams
  alias ReportServer.PostProcessing.Step
  alias ReportServer.PostProcessing.Steps.Helpers

  @id "demo_upper_case"

  def step do
    %Step{
      id: @id,
      label: "Demo: Convert answer text to upper case",
      init: &init/1,
      process_row: &process_row/2
    }
  end

  def init(%JobParams{step_state: step_state} = params) do
    # get columns that end with _text
    text_cols = Helpers.get_text_cols(params)
    step_state = Map.put(step_state, @id, text_cols)
    %{params | step_state: step_state}
  end

  def process_row(%JobParams{step_state: step_state}, row) do
    # convert all the text columns to uppercase
    text_cols = Map.get(step_state, @id)
    Enum.reduce(text_cols, row, fn {k, v}, {input, output} ->
      {input, Map.put(output, k, String.upcase(input[v]))}
    end)
  end
end
