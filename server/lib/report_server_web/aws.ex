# NOTE: this module uses two different AWS dependencies, AWS and ExAWS.
# AWS was the original dependency used and it has a nicer API than ExAWS but it turns out it is missing a method
# to pre-sign urls that is needed.  ExAWS has that functionality so, for now, both dependencies are used.

defmodule ReportServerWeb.Aws do
  require Logger

  alias ReportServer.PostProcessing.Output

  def get_workgroup_query_ids(workgroup_credentials, _workgroup = %{"name" => name, "id" => id}) do
    client = get_aws_client(workgroup_credentials)
    case AWS.Athena.list_query_executions(client, %{"WorkGroup" => "#{name}-#{id}"}) do
      {:ok, %{"QueryExecutionIds" => query_ids}, _resp} ->
        {:ok, query_ids}
      {:error, error} ->
        Logger.error("Something went wrong listing the queries: #{error}")
        {:error, "Something went wrong listing the queries"}
    end
  end

  def get_query_execution(workgroup_credentials, query_id) do
    client = get_aws_client(workgroup_credentials)
    case AWS.Athena.get_query_execution(client, %{"QueryExecutionId" => query_id}) do
      {:ok, %{"QueryExecution" => query}, _resp} ->
        {:ok, query}
      {:error, error} ->
        Logger.error("Something went wrong get the query execution info: #{error}")
        {:error, "Something went wrong get the query execution info"}
    end
  end

  def get_presigned_url(workgroup_credentials, s3_url, filename) do
    client = get_exaws_client(workgroup_credentials)

    {bucket, path} = get_bucket_and_path(s3_url)
    :s3
    |> ExAws.Config.new(client)
    |> ExAws.S3.presigned_url(:get, bucket, path, expires_in: 60*10, query_params: [{"response-content-disposition", "attachment; filename=#{filename}"}])
  end

  @presign_ttl_seconds 60 * 10
  def presign_ttl_seconds, do: @presign_ttl_seconds

  # Presign a private-bucket GET with SERVER creds (NOT the workgroup creds get_presigned_url/3 uses — those
  # can't read the attachments bucket). Mirrors how transcribe_audio.ex reaches the private bucket.
  def presign_server_get(s3_url, opts) do
    {bucket, key} = get_bucket_and_path(s3_url)
    client = get_exaws_client(get_server_credentials())

    :s3
    |> ExAws.Config.new(client)
    |> ExAws.S3.presigned_url(:get, bucket, key,
      expires_in: @presign_ttl_seconds,
      query_params: disposition_params(opts)
    )
  end

  # "attachment" (default) forces download; "inline" renders/plays in a browser (the opt-in --inline path)
  defp disposition_params(opts) do
    case Keyword.get(opts, :disposition, "attachment") do
      "inline" ->
        [
          {"response-content-disposition", "inline"},
          {"response-content-type", safe_inline_content_type(Keyword.get(opts, :content_type))}
        ]

      _ ->
        [{"response-content-disposition", ~s(attachment; filename="#{safe_filename(Keyword.fetch!(opts, :name))}")}]
    end
  end

  # The doc's contentType is student-supplied metadata: served inline it must not be able to execute
  # script in the presigned-URL origin (e.g. text/html, image/svg+xml). Allow media/PDF/plain types
  # only; everything else degrades to application/octet-stream (the browser downloads instead).
  @safe_inline_exact ~w(application/pdf application/json text/plain text/csv)
  @safe_inline_prefixes ~w(image/ audio/ video/)

  defp safe_inline_content_type(content_type) when is_binary(content_type) do
    ct = content_type |> String.split(";") |> hd() |> String.trim() |> String.downcase()

    cond do
      ct == "image/svg+xml" ->
        "application/octet-stream"

      ct in @safe_inline_exact ->
        ct

      Enum.any?(@safe_inline_prefixes, &String.starts_with?(ct, &1)) ->
        ct

      true ->
        "application/octet-stream"
    end
  end

  defp safe_inline_content_type(_), do: "application/octet-stream"

  # `name` is a writer-constrained key in the doc's attachments map, but it still flows into a
  # Content-Disposition, so strip CR/LF/quotes/backslashes/control chars and cap the length.
  defp safe_filename(name) do
    name |> String.replace(~r/[\x00-\x1f"\\]/u, "") |> String.slice(0, 255)
  end

  def get_file_stream(s3_url) do
    try do
      client = get_exaws_client(get_server_credentials())
      {bucket, path} = get_bucket_and_path(s3_url)
      stream = ExAws.S3.download_file(bucket, path, :memory)
      |> ExAws.stream!(client)
      {:ok, stream}
    rescue
      _ ->
        Logger.error("Unable to get stream for #{s3_url}")
        {:error, "Unable to get stream"}
    end
  end

  def get_file_contents(s3_url) do
    case get_file_stream(s3_url) do
      {:ok, stream} ->
        {:ok, Enum.join(stream)}
      error ->
        Logger.error("Unable to get file contents for #{s3_url}")
        error
    end
  end

  @doc """
  Like get_file_contents/1 but distinguishes a missing object from other failures.
  Returns {:ok, contents} | {:error, :not_found} | {:error, {:s3_error, reason}}.
  """
  def fetch_file_contents(s3_url) do
    client = get_exaws_client(get_server_credentials())
    {bucket, path} = get_bucket_and_path(s3_url)

    case ExAws.S3.get_object(bucket, path) |> ExAws.request(client) do
      {:ok, %{body: body}} -> {:ok, body}
      {:error, {:http_error, 404, _}} -> {:error, :not_found}
      {:error, reason} -> {:error, {:s3_error, reason}}
    end
  end

  def put_file_contents(s3_url, contents) do
    client = get_aws_client(get_server_credentials())
    {bucket, path} = get_bucket_and_path(s3_url)
    AWS.S3.put_object(client, bucket, path, %{"Body" => contents})
  end

  def get_transcription_job(id) do
    client = get_server_credentials() |> get_aws_client()
    case AWS.Transcribe.get_transcription_job(client, %{"TranscriptionJobName": id}) do
      {:ok, %{
        "TranscriptionJob" => %{
          "TranscriptionJobStatus" => "COMPLETED"
        }
      }, _} -> {:ok, :completed}

      {:ok, %{
        "TranscriptionJob" => %{
          "TranscriptionJobStatus" => "QUEUED"
        }
      }, _} -> {:ok, :queued}

      {:ok, %{
        "TranscriptionJob" => %{
          "TranscriptionJobStatus" => "IN_PROGRESS"
        }
      }, _} -> {:ok, :in_progress}

      {:ok, %{
        "TranscriptionJob" => %{
          "FailureReason" => failure_reason,
          "TranscriptionJobStatus" => "FAILED"
        }
      }, _} -> {:error, failure_reason}

      # instead of 404 AWS returns 400...
      {:error, {:unexpected_response, %{status_code: 400}}} -> {:error, "Job not found"}

      _ ->
        Logger.error("Error getting transcription job info")
        {:error, "An unknown error occurred"}
    end
  end

  def start_transcription_job(id, s3_url) do
    client = get_server_credentials() |> get_aws_client()
    case AWS.Transcribe.start_transcription_job(client, %{
      "TranscriptionJobName": id,
      "Media": %{"MediaFileUri": s3_url},
      "IdentifyLanguage": true,
      "OutputBucketName": Output.get_bucket(),
      "OutputKey": Output.get_transcripts_folder(),
    }) do
      {:ok, _, _} -> {:ok, :started}
      _ ->
        Logger.error("Unable to start transcription job")
        {:error, "Unable to start transcription job"}
    end
  end


  def get_server_credentials do
    credentials = Application.get_env(:report_server, :aws_credentials)
    %{
      access_key_id: Keyword.get(credentials, :access_key_id),
      secret_access_key: Keyword.get(credentials, :secret_access_key)
    }
  end

  defp get_aws_client(workgroup_credentials) do
    %{access_key_id: access_key_id, secret_access_key: secret_access_key} = workgroup_credentials
    if workgroup_credentials[:session_token] do
      AWS.Client.create(access_key_id, secret_access_key, workgroup_credentials[:session_token], "us-east-1")
    else
      AWS.Client.create(access_key_id, secret_access_key, "us-east-1")
    end
  end

  defp get_exaws_client(workgroup_credentials) do
    %{access_key_id: access_key_id, secret_access_key: secret_access_key} = workgroup_credentials
    if workgroup_credentials[:session_token] do
      [access_key_id: access_key_id, secret_access_key: secret_access_key, security_token: workgroup_credentials[:session_token]]
    else
      [access_key_id: access_key_id, secret_access_key: secret_access_key]
    end
  end

  defp get_bucket_and_path(s3_url) do
    uri = URI.parse(s3_url)
    key = String.slice(uri.path, 1..-1//1) # remove starting /
    {uri.host, key}
  end
end
