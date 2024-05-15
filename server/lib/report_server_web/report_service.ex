defmodule ReportServerWeb.ReportService do

  # answer for "Test Student One" in demo data
  def get_answer("demo", "activity-player.concord.org", "https://learn.portal.staging.concord.org/dataservice/external_activity_data/36bd3464-f63a-4d0c-a7a1-aefebba85d02", "managed_interactive_5849") do
    answer = Jason.decode!("""
      {
        "resource_url": "https://authoring.lara.staging.concord.org/activities/598",
        "remote_endpoint": "https://learn.portal.staging.concord.org/dataservice/external_activity_data/36bd3464-f63a-4d0c-a7a1-aefebba85d02",
        "run_key": "",
        "question_type": "open_response",
        "tool_id": "activity-player.concord.org/branch/master/",
        "resource_link_id": "328",
        "question_id": "managed_interactive_5849",
        "version": 1,
        "submitted": null,
        "platform_id": "https://learn.portal.staging.concord.org",
        "context_id": "e55400d0c0f7a5ff11284c104b1bbaecc3c1b5396e506d9b",
        "id": "4dbeaabe-8877-4aff-89ff-39f1c6a4436d",
        "platform_user_id": "27",
        "source_key": "activity-player.concord.org",
        "type": "open_response_answer",
        "answer_text": "this is my text answer",
        "answer": "this is my text answer",
        "attachments": {
          "audio1710336429832.mp3": {
            "folder": {
              "id": "LkoDyh1plMT5ndzNNaIU",
              "ownerId": "https://learn.portal.staging.concord.org/dataservice/external_activity_data/36bd3464-f63a-4d0c-a7a1-aefebba85d02"
            },
            "publicPath": "interactive-attachments/LkoDyh1plMT5ndzNNaIU/6728163b-483a-4425-a6e4-adeefe0e16ad/audio1710336429832.mp3",
            "contentType": "audio/mpeg"
          },
          "audio1710344319695.mp3": {
            "folder": {
              "id": "LkoDyh1plMT5ndzNNaIU",
              "ownerId": "https://learn.portal.staging.concord.org/dataservice/external_activity_data/36bd3464-f63a-4d0c-a7a1-aefebba85d02"
            },
            "publicPath": "interactive-attachments/LkoDyh1plMT5ndzNNaIU/7caeb5d5-0e3f-4f31-a17b-202fa5af35f9/audio1710344319695.mp3",
            "contentType": "audio/mpeg"
          }
        },
        "report_state": "{\"mode\":\"report\",\"authoredState\":\"{\\\"version\\\":1,\\\"questionType\\\":\\\"open_response\\\",\\\"audioEnabled\\\":true}\",\"interactiveState\":\"{\\\"answerType\\\":\\\"open_response_answer\\\",\\\"answerText\\\":\\\"this is my text answer\\\",\\\"audioFile\\\":\\\"audio1710344319695.mp3\\\"}\",\"interactive\":{\"id\":\"managed_interactive_5849\",\"name\":\"\"},\"version\":1}",
        "created": "Wed, 13 Mar 2024 15:38:48 UTC"
      }
      """
    )
    {:ok, answer}
  end

  def get_answer("demo", _source, _remote_endpoint, _question_id) do
    {:error, "Answer not found"}
  end

  def get_answer(_mode, source, remote_endpoint, question_id) do
    with {:ok, resp} <- request_answer(source, remote_endpoint, question_id),
         {:ok, answer} <- get_answer_from_response(resp.body) do
      {:ok, answer}
    else
      error -> error
    end
  end

  defp request_answer(source, remote_endpoint, question_id) do
    {url, token} = get_endpoint("answer")
    get_request()
    |> Req.get(url: url,
      auth: {:bearer, token },
      params: [source: source, remote_endpoint: remote_endpoint, question_id: question_id],
      debug: false
    )
  end

  def get_answer_from_response(%{"success" => true, "answer" => answer}), do: {:ok, answer}
  def get_answer_from_response(%{"success" => false, "error" => error}), do: {:error, error}
  def get_answer_from_response(_), do: {:error, "Something went wrong getting the answer"}

  defp get_endpoint(endpoint) do
    report_service = Application.get_env(:report_server, :report_service)
    url = report_service |> Keyword.get(:url, "https://us-central1-report-service-dev.cloudfunctions.net/api")
    token = report_service |> Keyword.get(:token)
    {"#{url}/#{endpoint}", token}
  end

  defp get_request() do
    Req.new()
    |> Req.Request.register_options([:debug])
    |> Req.Request.append_request_steps(debug: &debug/1)
  end

  defp debug(request) do
    if request.options[:debug] do
      IO.inspect(request)
    end
    request
  end
end
