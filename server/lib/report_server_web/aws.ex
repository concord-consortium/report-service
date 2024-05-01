# NOTE: this module uses two different AWS dependencies, AWS and ExAWS.
# AWS was the original dependency used and it has a nicer API than ExAWS but it turns out it is missing a method
# to pre-sign urls that is needed.  ExAWS has that functionality so, for now, both dependencies are used.

defmodule ReportServerWeb.Aws do
  def get_workgroup_query_ids("demo", _workgroup_credentials, _workgroup) do
    {:ok, ["1", "2", "3", "4", "5"]}
  end

  def get_workgroup_query_ids(_mode, workgroup_credentials, _workgroup = %{"name" => name, "id" => id}) do
    client = get_client(workgroup_credentials)
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
        "OutputLocation" => "fake-demo-url"
      },
      "Status" => %{
        "State" => state,
        "SubmissionDateTime" => 1714579921
      }
    }}
  end

  def get_query_execution(_mode, workgroup_credentials, query_id) do
    client = get_client(workgroup_credentials)
    case AWS.Athena.get_query_execution(client, %{"QueryExecutionId" => query_id}) do
      {:ok, %{"QueryExecution" => query}, _resp} ->
        {:ok, query}
      {:error, _} ->
        {:error, "Something went wrong get the query execution info"}
    end
  end

  def get_presigned_url("demo", _workgroup_credentials, _s3_url, _filename) do
    {:ok, "fake-demo-url"}
  end

  def get_presigned_url(_mode, workgroup_credentials, s3_url, filename) do
    %{access_key_id: access_key_id, secret_access_key: secret_access_key, session_token: session_token} = workgroup_credentials

    uri = URI.parse(s3_url)
    key = String.slice(uri.path, 1..-1//1) # remove starting /
    :s3
    |> ExAws.Config.new([access_key_id: access_key_id, secret_access_key: secret_access_key, security_token: session_token])
    |> ExAws.S3.presigned_url(:get, uri.host, key, expires_in: 60*10, query_params: [{"response-content-disposition", "attachment; filename=#{filename}"}])
  end

  defp get_client(workgroup_credentials) do
    %{access_key_id: access_key_id, secret_access_key: secret_access_key, session_token: session_token} = workgroup_credentials
    AWS.Client.create(access_key_id, secret_access_key, session_token, "us-east-1")
  end
end
