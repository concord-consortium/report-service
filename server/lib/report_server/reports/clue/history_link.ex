defmodule ReportServer.Reports.Clue.HistoryLink do

  @clue_url "https://collaborative-learning.concord.org/"

  defstruct portal_url: nil, offering_id: nil, class_id: nil, document_key: nil, document_uid: nil, maybe_document_history_id: nil

  def format_link_to_work(params = %__MODULE__{}) do
    %{portal_url: portal_url, offering_id: offering_id, class_id: class_id,
     document_key: document_key, document_uid: document_uid, maybe_document_history_id: maybe_document_history_id} = params
    class_url = "https://#{portal_url}/api/v1/classes/#{class_id}"
    offering_url = "https://#{portal_url}/api/v1/offerings/#{offering_id}"
    auth_domain_url = "https://#{portal_url}/"

    @clue_url <>
      "?class=#{URI.encode_www_form(class_url)}" <>
      "&offering=#{URI.encode_www_form(offering_url)}" <>
      "&researcher=true" <>
      "&reportType=offering" <>
      "&authDomain=#{URI.encode_www_form(auth_domain_url)}" <>
      "&resourceLinkId=#{offering_id}" <>
      "&targetUserId=#{document_uid}" <>
      "&studentDocument=#{document_key}" <>
      (if maybe_document_history_id, do: "&studentDocumentHistoryId=#{maybe_document_history_id}", else: "")
  end

end
