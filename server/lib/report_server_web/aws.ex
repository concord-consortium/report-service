# NOTE: this module uses two different AWS dependencies, AWS and ExAWS.
# AWS was the original dependency used and it has a nicer API than ExAWS but it turns out it is missing a method
# to pre-sign urls that is needed.  ExAWS has that functionality so, for now, both dependencies are used.

defmodule ReportServerWeb.Aws do
  require Logger

  alias ReportServer.Demo
  alias ReportServer.PostProcessing.Output

  def get_workgroup_query_ids("demo", _workgroup_credentials, _workgroup) do
    {:ok, ["1", "2", "3", "4", "5"]}
  end

  def get_workgroup_query_ids(_mode, workgroup_credentials, _workgroup = %{"name" => name, "id" => id}) do
    client = get_aws_client(workgroup_credentials)
    case AWS.Athena.list_query_executions(client, %{"WorkGroup" => "#{name}-#{id}"}) do
      {:ok, %{"QueryExecutionIds" => query_ids}, _resp} ->
        {:ok, query_ids}
      {:error, error} ->
        Logger.error("Something went wrong listing the queries: #{error}")
        {:error, "Something went wrong listing the queries"}
    end
  end

  def get_query_execution("demo", _workgroup_credentials, query_id) do
    state = case query_id do
      "1" -> "SUCCEEDED"
      "2" -> "QUEUED"
      "3" -> "RUNNING"
      "4" -> "FAILED"
      "5" -> "CANCELLED"
    end

    # the actual AWS response is bigger but these are the only fields we currently need
    {:ok, %{
      "Query" => "-- name Demo Query ##{query_id}\n  -- type activity\n",
      "QueryExecutionId" => query_id,
      "ResultConfiguration" => %{
        "OutputLocation" => "/reports/demo.csv"
      },
      "Status" => %{
        "State" => state,
        "SubmissionDateTime" => 1714579921
      }
    }}
  end

  def get_query_execution(_mode, workgroup_credentials, query_id) do
    client = get_aws_client(workgroup_credentials)
    case AWS.Athena.get_query_execution(client, %{"QueryExecutionId" => query_id}) do
      {:ok, %{"QueryExecution" => query}, _resp} ->
        {:ok, query}
      {:error, error} ->
        Logger.error("Something went wrong get the query execution info: #{error}")
        {:error, "Something went wrong get the query execution info"}
    end
  end

  def get_presigned_url("demo", _workgroup_credentials, _s3_url, _filename) do
    {:ok, "/reports/demo.csv"}
  end

  def get_presigned_url(_mode, workgroup_credentials, s3_url, filename) do
    client = get_exaws_client(workgroup_credentials)

    {bucket, path} = get_bucket_and_path(s3_url)
    :s3
    |> ExAws.Config.new(client)
    |> ExAws.S3.presigned_url(:get, bucket, path, expires_in: 60*10, query_params: [{"response-content-disposition", "attachment; filename=#{filename}"}])
  end

  def get_file_stream("demo", _s3_url) do
    {:ok, io} = Demo.raw_demo_csv() |> StringIO.open()
    {:ok, IO.stream(io, :line)}
  end
  def get_file_stream(_mode, s3_url) do
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

  def put_file_stream("demo", _s3_url, _stream) do
    {:error, "No stream output in demo mode"}
  end
  def put_file_stream(_mode, s3_url, stream) do
    client = get_exaws_client(get_server_credentials())
    {bucket, path} = get_bucket_and_path(s3_url)
    ExAws.S3.upload(stream, bucket, path)
    |> ExAws.request(client)
  end

  def get_file_contents(mode, s3_url) do
    case get_file_stream(mode, s3_url) do
      {:ok, stream} ->
        {:ok, Enum.join(stream)}
      error ->
        Logger.error("Unable to get file contents for #{s3_url}")
        error
    end
  end

  def put_file_contents("demo", _s3_url, _contents) do
    {:error, "Not implemented for demo"}
  end
  def put_file_contents(_mode, s3_url, contents) do
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
