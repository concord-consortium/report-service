defmodule ReportServer.PostProcessing.Step do
  @derive {Jason.Encoder, only: [:id, :label]}
  defstruct id: nil, label: nil, init: nil, process_row: nil, preprocess_learners: false
end
