defmodule ReportServer.PostProcessing.Steps.LinkToHistory do
  alias ReportServer.PostProcessing.JobParams
  alias ReportServer.PostProcessing.Step
  alias ReportServer.PostProcessing.Steps.Helpers
  alias ReportServer.{ReportService, PortalReport}
  alias ReportServer.Reports.Athena.AthenaConfig

  @id "link_to_history"
  @insert_after_col "time"
  @link_to_history_col "link_to_history"

  def step do
    %Step{
      id: @id,
      label: "Add \"link_to_history\" column to \"Student Actions\" or \"Student Actions with Metadata\" reports",
      init: &init/1,
      process_row: &process_row/3,
      preprocess_learners: true
    }
  end

  def init(params) do
    Helpers.add_output_column(params, @link_to_history_col, :after, @insert_after_col)
  end

  # process each log row
  def process_row(job_params = %JobParams{preprocessed: preprocessed, portal_url: portal_url}, row = {input, output = %{"extras" => extras, "run_remote_endpoint" => run_remote_endpoint}}, _data_row?) do
    learner = Map.get(preprocessed.learners, run_remote_endpoint)

    if learner do
      case Jason.decode(extras) do
        {:ok, %{"interactiveStateHistoryId" => history_id, "interactive_id" => interactive_id, "url" => url}} when not is_nil(history_id) and not is_nil(interactive_id) and not is_nil(url) ->
          link_to_history = generate_link_to_history(portal_url, learner, history_id, interactive_id, url)
          {input, Map.put(output, @link_to_history_col, link_to_history)}

        _ -> row
      end
    else
      row
    end
  end

  def process_row(_job_params, row, _data_row?), do: row

  defp generate_link_to_history(portal_url, _learner = %{offering_id: offering_id, class_id: class_id, student_id: student_id}, history_id, interactive_id, url) do

    source_key = AthenaConfig.get_source_key()
    portal_report_url = PortalReport.get_url()
    firebase_app = ReportService.get_firebase_app()

    question_id = convert_id(interactive_id)
    auth_domain_with_scheme = ensure_auth_domain_with_scheme(portal_url)

    answers_source_key = case URI.parse(url) do
      %URI{host: host} -> ensure_auth_domain_with_scheme(host)
      _ -> ""
    end

    link_to_history = portal_report_url <>
        "?auth-domain=#{URI.encode_www_form(auth_domain_with_scheme)}" <>
        "&firebase-app=#{firebase_app}" <>
        "&sourceKey=#{source_key}" <>
        "&iframeQuestionId=#{question_id}" <>
        "&class=#{URI.encode_www_form("#{auth_domain_with_scheme}/api/v1/classes/#{class_id}")}" <>
        "&offering=#{URI.encode_www_form("#{auth_domain_with_scheme}/api/v1/offerings/#{offering_id}")}" <>
        "&studentId=#{student_id}" <>
        "&answersSourceKey=#{answers_source_key}" <>
        "&interactiveStateHistoryId=#{history_id}"

    link_to_history
  end

  defp ensure_auth_domain_with_scheme(auth_domain) do
    cond do
      String.starts_with?(auth_domain, "http") -> auth_domain
      String.starts_with?(auth_domain, "localhost") -> "http://#{auth_domain}"
      true -> "https://#{auth_domain}"
    end
  end

  @doc """
  Converts an ID from "prefix_id_number" format to "id_number-Prefix" format,
  where id_number is always the last part of the string.

  ## Examples
      iex> convert_id("managed_interactive_10200")
      "10200-ManagedInteractive"
  """
  defp convert_id(id) when is_binary(id) do
    # use rsplit to ensure the last part is always separated as the ID number.
    case String.rsplit(id, "_", parts: 2) do
      [prefix_string, id_number] ->
        prefix_parts = String.split(prefix_string, "_")

        prefix =
          prefix_parts
          |> Enum.map(&String.capitalize/1)
          |> Enum.join("")

        "#{id_number}-#{prefix}"

      _ ->
        id
    end
  end
  defp convert_id(id), do: id
end
