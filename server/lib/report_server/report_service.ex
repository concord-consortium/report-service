defmodule ReportServer.ReportService do
  require Logger

  # must exceed the ~300s Node/Cloud-Function ceiling (Req default is 15_000)
  @bulk_receive_timeout 310_000

  @doc """
  Bulk Firestore read (STORY 3). `req` is the internal wire request:
    %{collection: "answers"|"history", source_endpoints: [...], inner_cursor: nil|map,
      limit: int, endpoint_limit: int, read_limit: int}
  Returns {:ok, body_without_success_key} | {:error, reason}. Node stays stateless; Elixir owns cursor assembly.
  """
  def bulk_read(req) do
    {url, token} = get_endpoint("bulk_read")

    result =
      get_request()
      |> Req.post(
        url: url,
        auth: {:bearer, token},
        json: req,
        receive_timeout: @bulk_receive_timeout,
        debug: false
      )

    case result do
      {:ok, %{status: 200, body: %{"success" => true} = body}} ->
        {:ok, Map.delete(body, "success")}

      {:ok, %{body: %{"error" => error}}} ->
        {:error, error}

      {:ok, %{status: status}} ->
        {:error, "unexpected bulk_read status #{status}"}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Batch attachment metadata (STORY 3). `req` is %{items: [%{collection, source, doc_id, name}, ...]}.
  Returns {:ok, %{"results" => [...]}} | {:error, reason}. Mirrors bulk_read/1's wire contract.
  """
  def fetch_attachment_meta(req) do
    {url, token} = get_endpoint("fetch_attachment_meta")

    result =
      get_request()
      |> Req.post(
        url: url,
        auth: {:bearer, token},
        json: req,
        debug: false
      )

    case result do
      {:ok, %{status: 200, body: %{"success" => true} = body}} ->
        {:ok, Map.delete(body, "success")}

      {:ok, %{body: %{"error" => error}}} ->
        {:error, error}

      {:ok, %{status: status}} ->
        {:error, "unexpected fetch_attachment_meta status #{status}"}

      {:error, error} ->
        {:error, error}
    end
  end

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
