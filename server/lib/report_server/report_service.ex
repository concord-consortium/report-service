defmodule ReportServer.ReportService do
  require Logger

  def get_answer(source, remote_endpoint, question_id) do
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

  def get_plugin_states(source, remote_endpoint) do
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
