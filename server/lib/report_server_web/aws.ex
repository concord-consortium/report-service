# NOTE: this module uses two different AWS dependencies, AWS and ExAWS.
# AWS was the original dependency used and it has a nicer API than ExAWS but it turns out it is missing a method
# to pre-sign urls that is needed.  ExAWS has that functionality so, for now, both dependencies are used.

defmodule ReportServerWeb.Aws do
  alias ReportServer.Demo

  def get_workgroup_query_ids("demo", _workgroup_credentials, _workgroup) do
    {:ok, ["1", "2", "3", "4", "5"]}
  end

  def get_workgroup_query_ids(_mode, workgroup_credentials, _workgroup = %{"name" => name, "id" => id}) do
    client = get_aws_client(workgroup_credentials)
    case AWS.Athena.list_query_executions(client, %{"WorkGroup" => "#{name}-#{id}"}) do
      {:ok, %{"QueryExecutionIds" => query_ids}, _resp} ->
        {:ok, query_ids}
      {:error, _} ->
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
      {:error, _} ->
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

  def get_file_stream("demo", _workgroup_credentials, _s3_url) do
    {:ok, io} = Demo.raw_demo_csv() |> StringIO.open()
    {:ok, IO.stream(io, :line)}
  end
  def get_file_stream(_mode, workgroup_credentials, s3_url) do
    try do
      client = get_exaws_client(workgroup_credentials)
      {bucket, path} = get_bucket_and_path(s3_url)
      stream = ExAws.S3.download_file(bucket, path, :memory)
      |> ExAws.stream!(client)
      {:ok, stream}
    rescue
      _ -> {:error, "Unable to get stream"}
    end
  end

  def put_file_stream("demo", _workgroup_credentials, _s3_url, _stream) do
    {:error, "No stream output in demo mode"}
  end
  def put_file_stream(_mode, workgroup_credentials, s3_url, stream) do
    client = get_exaws_client(workgroup_credentials)
    {bucket, path} = get_bucket_and_path(s3_url)
    ExAws.S3.upload(stream, bucket, path)
    |> ExAws.request(client)
  end

  def get_file_contents("demo", _workgroup_credentials, _s3_url) do
    {:error, "No files in demo mode"}
  end

  def get_file_contents(mode, workgroup_credentials, s3_url) do
    case get_file_stream(mode, workgroup_credentials, s3_url) do
      {:ok, stream} ->
        {:ok, Enum.join(stream)}
      error -> error
    end
  end

  def put_file_contents("demo", _workgroup_credentials, _s3_url, _contents) do
    {:error, "Not implemented for demo"}
  end
  def put_file_contents(_mode, workgroup_credentials, s3_url, contents) do
    client = get_aws_client(workgroup_credentials)
    {bucket, path} = get_bucket_and_path(s3_url)
    AWS.S3.put_object(client, bucket, path, %{"Body" => contents})
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
