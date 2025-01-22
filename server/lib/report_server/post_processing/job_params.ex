defmodule ReportServer.PostProcessing.JobParams do
  defstruct mode: nil, input_header: [], input_header_map: %{}, output_header: [], output_header_map: %{}, step_state: %{}, rows_processed: 0, portal_url: nil, preprocessed: %{}
end
