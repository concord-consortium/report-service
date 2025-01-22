defmodule ReportServer.PostProcessing.Steps.ClueLinkToWork do
  alias ReportServer.PostProcessing.JobParams
  alias ReportServer.PostProcessing.Step
  alias ReportServer.PostProcessing.Steps.Helpers
  alias ReportServer.PortalReport

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

  def init(%JobParams{step_state: step_state} = params) do
    params = Helpers.add_output_column(params, @link_to_work_col, :after, @insert_after_col)
    step_state = Map.put(step_state, @id, PortalReport.get_url())

    %{params | step_state: step_state}
  end

  # process each CLUE log row
  def process_row(job_params = %JobParams{preprocessed: preprocessed}, row = {input, output = %{"application" => "CLUE", "parameters" => parameters, "run_remote_endpoint" => run_remote_endpoint}}, _data_row?) do
    learner = Map.get(preprocessed.learners, run_remote_endpoint)

    if learner do
      case Jason.decode(parameters) do
        {:ok, %{"documentKey" => document_key, "documentHistoryId" => document_history_id}} ->
          link_to_work = generate_link_to_work(job_params, learner, document_key, document_history_id)
          {input, Map.put(output, @link_to_work_col, link_to_work)}

        _ -> row
      end
    else
      row
    end
  end

  def process_row(_job_params, row, _data_row?), do: row

  defp generate_link_to_work(%JobParams{step_state: step_state, portal_url: portal_url}, _learner = %{offering_id: offering_id, class_id: class_id}, document_key, document_history_id) do
    portal_report_url = Map.get(step_state, @id)

    class_url = "https://#{portal_url}/api/v1/classes/#{class_id}"
    offering_url = "https://#{portal_url}/api/v1/offerings/#{offering_id}"
    auth_domain_url = "https://#{portal_url}/"

    portal_report_url <>
      "?class=#{URI.encode_www_form(class_url)}" <>
      "&offering=#{URI.encode_www_form(offering_url)}" <>
      "&reportType=offering" <>
      "&authDomain=#{URI.encode_www_form(auth_domain_url)}" <>
      "&resourceLinkId=#{offering_id}" <>
      "&studentDocument=#{document_key}" <>
      "&studentDocumentHistoryId=#{document_history_id}"
  end

end
