defmodule ReportServer.PostProcessing.Steps.ClueLinkToWork do
  alias ReportServer.PostProcessing.JobParams
  alias ReportServer.PostProcessing.Step
  alias ReportServer.PostProcessing.Steps.Helpers
  alias ReportServer.Reports.Clue.HistoryLink

  @id "clue_link_to_work"
  @insert_after_col "time"
  @link_to_work_col "link_to_work"

  def step do
    %Step{
      id: @id,
      label: "Add \"link_to_work\" column to CLUE Student Actions report",
      init: &init/1,
      process_row: &process_row/3,
      preprocess_learners: true
    }
  end

  def init(params) do
    Helpers.add_output_column(params, @link_to_work_col, :after, @insert_after_col)
  end

  # process each CLUE log row
  def process_row(job_params = %JobParams{preprocessed: preprocessed}, row = {input, output = %{"application" => "CLUE", "parameters" => parameters, "run_remote_endpoint" => run_remote_endpoint}}, _data_row?) do
    learner = Map.get(preprocessed.learners, run_remote_endpoint)

    if learner do
      case Jason.decode(parameters) do
        {:ok, json = %{"documentKey" => document_key, "documentUid" => document_uid}} ->
          link_to_work = generate_link_to_work(job_params, learner, document_key, document_uid, json["documentHistoryId"])
          {input, Map.put(output, @link_to_work_col, link_to_work)}

        _ -> row
      end
    else
      row
    end
  end

  def process_row(_job_params, row, _data_row?), do: row

  defp generate_link_to_work(%JobParams{portal_url: portal_url}, _learner = %{offering_id: offering_id, class_id: class_id}, document_key, document_uid, maybe_document_history_id) do
    HistoryLink.format_link_to_work(%HistoryLink{portal_url: portal_url, offering_id: offering_id, class_id: class_id,
      document_key: document_key, document_uid: document_uid, maybe_document_history_id: maybe_document_history_id})
  end

end
