defmodule ReportServer.AthenaDB do
  require Logger

  alias ReportServer.Accounts.User

  def query(sql, report_run_id, user = %User{}) do
    case ensure_workgroup(user) do
      {:ok, workgroup_name} ->
         start_query_execution(sql, report_run_id, workgroup_name)
      error -> error
    end
  end

  def get_query_info(athena_query_id) do
    client = get_aws_client()

    case AWS.Athena.get_query_execution(client, %{"QueryExecutionId" => athena_query_id}) do
      {:ok, %{"QueryExecution" => %{"Status" => %{"State" => state}} = result}, _} ->
        output_location = (result["ResultConfiguration"] && result["ResultConfiguration"]["OutputLocation"]) || nil
        {:ok, String.downcase(state), output_location}
      error ->
        transform_aws_error(error)
    end
  end

  def get_download_url(s3_url, filename) do
    client = get_exaws_client()
    {bucket, path} = get_bucket_and_path(s3_url)
    :s3
    |> ExAws.Config.new(client)
    |> ExAws.S3.presigned_url(:get, bucket, path, expires_in: 60*10, query_params: [{"response-content-disposition", "attachment; filename=#{filename}"}])
  end

  defp ensure_workgroup(user = %User{}) do
    client = get_aws_client()

    case get_workgroup(client, user) do
      {:ok, workgroup_name} ->
        {:ok, workgroup_name}
      {:error, _error} ->
        case create_workgroup(client, user) do
          {:ok, workgroup_name} ->
            {:ok, workgroup_name}
          error ->
            transform_aws_error(error)
        end
    end
  end

  defp start_query_execution(sql, report_run_id, workgroup_name) do
    client = get_aws_client()
    client_request_token = get_client_request_token(report_run_id, workgroup_name)

    query = %{
      ClientRequestToken: client_request_token,
      QueryString: sql,
      QueryExecutionContext: %{
        Database: "report-service"
      },
      WorkGroup: workgroup_name
    }

    case AWS.Athena.start_query_execution(client, query) do
      {:ok, %{"QueryExecutionId" => athena_query_id}, _} ->
        {:ok, athena_query_id, "queued"}
      error ->
        transform_aws_error(error)
    end
  end

  defp get_aws_keys() do
    credentials = Application.get_env(:report_server, :aws_credentials)
    access_key_id = Keyword.get(credentials, :access_key_id)
    secret_access_key = Keyword.get(credentials, :secret_access_key)
    {access_key_id, secret_access_key}
  end

  defp get_aws_client() do
    {access_key_id, secret_access_key} = get_aws_keys()
    AWS.Client.create(access_key_id, secret_access_key, "us-east-1")
  end

  # NOTE: the exaws library is also used as the AWS client library doesn't have url signing
  defp get_exaws_client() do
    {access_key_id, secret_access_key} = get_aws_keys()
    [access_key_id: access_key_id, secret_access_key: secret_access_key]
  end

  defp get_workgroup_name(%User{portal_server: portal_server, portal_user_id: portal_user_id, portal_email: portal_email}) do
    "#{portal_server} #{portal_user_id} #{portal_email}"
      |> String.replace(~r/[^a-z0-9]/, "-")
  end

  defp get_client_request_token(report_run_id, workgroup_name) do
    key = "run-#{report_run_id}-#{workgroup_name}"
    :crypto.hash(:sha256, key) |> Base.encode16(case: :lower)
  end

  defp get_workgroup(client, user = %User{}) do
    workgroup_name = get_workgroup_name(user)

    case AWS.Athena.get_work_group(client, %{WorkGroup: workgroup_name}) do
      {:ok, _, _} ->
        {:ok, workgroup_name}
      error ->
        transform_aws_error(error)
    end
  end

  defp create_workgroup(client, user = %User{portal_server: portal_server, portal_email: portal_email}) do
    output_bucket = Application.get_env(:report_server, :athena) |> Keyword.get(:bucket, "concord-report-data")
    workgroup_name = get_workgroup_name(user)

    workgroup = %{
      Name: workgroup_name,
      Configuration: %{
        ResultConfiguration: %{
          OutputLocation: "s3://#{output_bucket}/workgroup-output/#{workgroup_name}"
        }
      },
      Description: "Workgroup for #{portal_email} at #{portal_server}",
      Tags: [
        %{
          Key: "email",
          Value: portal_email
        }
      ]
    }

    case AWS.Athena.create_work_group(client, workgroup) do
      {:ok, _, _} ->
        {:ok, workgroup_name}
      error -> transform_aws_error(error)
    end
  end

  defp transform_aws_error({:error, %{"Message" => message}}) do
    {:error, message}
  end
  defp transform_aws_error({:error, {:unexpected_response, %{body: body}}}) do
    case Jason.decode(body) do
      {:ok, json} ->
        {:error, json["Message"] || "An unknown error occurred"}
      _error -> {:error, "An unknown error occurred"}
    end
  end
  defp transform_aws_error(error) do
    Logger.error(error)
    {:error, "An unknown error occurred"}
  end

  defp get_bucket_and_path(s3_url) do
    uri = URI.parse(s3_url)
    key = String.slice(uri.path, 1..-1//1) # remove starting /
    {uri.host, key}
  end
end
