defmodule ReportServer.ReportService do
  require Logger

  # answer for "Test Student One" in demo data
  def get_answer("demo", "activity-player.concord.org", "https://learn.portal.staging.concord.org/dataservice/external_activity_data/36bd3464-f63a-4d0c-a7a1-aefebba85d02", "managed_interactive_5849") do
    {:ok, %{
      "answer" => "this is my text answer",
      "answer_text" => "this is my text answer",
      "attachments" => %{
        "audio1710336429832.mp3" => %{
          "contentType" => "audio/mpeg",
          "folder" => %{
            "id" => "LkoDyh1plMT5ndzNNaIU",
            "ownerId" => "https://learn.portal.staging.concord.org/dataservice/external_activity_data/36bd3464-f63a-4d0c-a7a1-aefebba85d02"
          },
          "publicPath" => "interactive-attachments/LkoDyh1plMT5ndzNNaIU/6728163b-483a-4425-a6e4-adeefe0e16ad/audio1710336429832.mp3"
        },
        "audio1710344319695.mp3" => %{
          "contentType" => "audio/mpeg",
          "folder" => %{
            "id" => "LkoDyh1plMT5ndzNNaIU",
            "ownerId" => "https://learn.portal.staging.concord.org/dataservice/external_activity_data/36bd3464-f63a-4d0c-a7a1-aefebba85d02"
          },
          "publicPath" => "interactive-attachments/LkoDyh1plMT5ndzNNaIU/7caeb5d5-0e3f-4f31-a17b-202fa5af35f9/audio1710344319695.mp3"
        }
      },
      "context_id" => "e55400d0c0f7a5ff11284c104b1bbaecc3c1b5396e506d9b",
      "created" => "Wed, 13 Mar 2024 15:38:48 UTC",
      "id" => "4dbeaabe-8877-4aff-89ff-39f1c6a4436d",
      "platform_id" => "https://learn.portal.staging.concord.org",
      "platform_user_id" => "27",
      "question_id" => "managed_interactive_5849",
      "question_type" => "open_response",
      "remote_endpoint" => "https://learn.portal.staging.concord.org/dataservice/external_activity_data/36bd3464-f63a-4d0c-a7a1-aefebba85d02",
      "report_state" => "{\"mode\":\"report\",\"authoredState\":\"{\\\"version\\\":1,\\\"questionType\\\":\\\"open_response\\\",\\\"audioEnabled\\\":true}\",\"interactiveState\":\"{\\\"answerType\\\":\\\"open_response_answer\\\",\\\"answerText\\\":\\\"this is my text answer\\\",\\\"audioFile\\\":\\\"audio1710344319695.mp3\\\"}\",\"interactive\":{\"id\":\"managed_interactive_5849\",\"name\":\"\"},\"version\":1}",
      "resource_link_id" => "328",
      "resource_url" => "https://authoring.lara.staging.concord.org/activities/598",
      "run_key" => "",
      "source_key" => "activity-player.concord.org",
      "submitted" => nil,
      "tool_id" => "activity-player.concord.org/branch/master/",
      "type" => "open_response_answer",
      "version" => 1
    }}
  end

  def get_answer("demo", _source, _remote_endpoint, _question_id) do
    # this mimics the Firebase function error result
    {:error, "Error: Answer not found!"}
  end

  def get_answer(_mode, source, remote_endpoint, question_id) do
    with {:ok, resp} <- request_answer(source, remote_endpoint, question_id),
         {:ok, answer} <- get_answer_from_response(resp.body) do
      {:ok, answer}
    else
      {:error, error} ->
        Logger.error("Error getting answer: #{error}")
        {:error, error}
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

  # plugin states for "Test Student One" in demo data
  def get_plugin_states("demo", "activity-player.concord.org", "https://learn.portal.staging.concord.org/dataservice/external_activity_data/36bd3464-f63a-4d0c-a7a1-aefebba85d02") do
    {:ok, %{"demo" => %{
      "definitions" => %{
        "Test": ["recordingData://demo/demo-class/1", "recordingData://demo/demo-class/2", "This a test definition", "This is another test definition"],
        "Second": ["This is the definition of second."]
      }
    }}}
  end
  def get_plugin_states("demo", _source, _remote_endpoint) do
    # api returns an empty object when no plugin states are found
    {:ok, %{}}
  end

  def get_plugin_states(_mode, source, remote_endpoint) do
    with {:ok, resp} <- request_plugin_states(source, remote_endpoint),
         {:ok, plugin_states} <- get_plugin_states_from_response(resp.body) do
      {:ok, plugin_states}
    else
      {:error, error} ->
        Logger.error("Error getting plugin states: #{error}")
        {:error, error}
    end
  end

  defp request_plugin_states(source, remote_endpoint) do
    {url, token} = get_endpoint("plugin_states")
    get_request()
    |> Req.get(url: url,
      auth: {:bearer, token },
      params: [source: source, remote_endpoint: remote_endpoint],
      debug: false
    )
  end

  def get_plugin_states_from_response(%{"success" => true, "plugin_states" => plugin_states}), do: {:ok, plugin_states}
  def get_plugin_states_from_response(%{"success" => false, "error" => error}), do: {:error, error}
  def get_plugin_states_from_response(_), do: {:error, "Something went wrong getting the plugin states"}

  def get_endpoint(endpoint) do
    report_service = Application.get_env(:report_server, :report_service)
    url = report_service |> Keyword.get(:url, "https://us-central1-report-service-dev.cloudfunctions.net/api")
    token = report_service |> Keyword.get(:token)
    {"#{url}/#{endpoint}", token}
  end

  def get_firebase_app() do
    Application.get_env(:report_server, :report_service)
    |> Keyword.get(:firebase_app, "report-service-dev")
  end

  def get_request() do
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
