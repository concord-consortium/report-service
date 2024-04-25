defmodule ReportServerWeb.TokenService do
  def get_aws_data(portal_credentials) do
    with {:ok, jwt} <- get_firebase_jwt(portal_credentials),
         {:ok, workgroup} <- get_athena_workgroup(jwt),
         {:ok, credentials} <- get_workgroup_credentials(jwt, workgroup),
         {:ok, queries} <- get_workgroup_queries(credentials, workgroup) do
      {:ok, %{
        aws_data: %{
          jwt: jwt,
          workgroup: workgroup,
          credentials: credentials,
          queries: queries
        }
      }}
    else
      error -> error
    end
  end

  defp get_firebase_jwt(portal_credentials) do
    with {:ok, resp} <- request_firebase_jwt(portal_credentials),
         {:ok, token} <- get_token_from_response(resp.body) do
        {:ok, token}
    else
      error -> error
    end
  end

  defp get_athena_workgroup(jwt) do
    with {:ok, resp} <- request_list_workgroup_resources(jwt),
         {:ok, workgroup} <- get_first_resource_from_response(resp.body) do
        {:ok, workgroup}
    else
      error -> error
    end
  end

  defp get_workgroup_credentials(jwt, workgroup) do
    with {:ok, resp} <- request_create_workgroup_credentials(jwt, workgroup),
         {:ok, credentials} <- get_credentials_from_response(resp.body) do
        {:ok, credentials}
    else
      error -> error
    end
  end

  def get_workgroup_queries(workgroup_credentials, workgroup) do
    %{"accessKeyId" => accessKeyId, "secretAccessKey" => secretAccessKey, "sessionToken" => sessionToken} = workgroup_credentials
    %{"name" => name, "id" => id} = workgroup

    client = AWS.Client.create(accessKeyId, secretAccessKey, sessionToken, "us-east-1")
    case AWS.Athena.list_query_executions(client, %{"WorkGroup" => "#{name}-#{id}"}) do
      {:ok, %{"QueryExecutionIds" => queries}, _resp} ->
        {:ok, queries}
      {:error, _} ->
        {:error, "Something went wrong listing the queries"}
    end
  end

  defp request_firebase_jwt(%{access_token:  access_token, portal_url: portal_url}) do
    url = "#{portal_url}/api/v1/jwt/firebase?firebase_app=token-service"
    get_request()
    |> Req.get(url: url,
      auth: {:bearer, access_token },
      json: true,
      debug: false
    )
  end

  defp get_token_from_response(%{"token" => token}), do: {:ok, token}
  defp get_token_from_response(_), do: {:error, "Token not found in Firebase JWT response"}

  defp request_list_workgroup_resources(jwt) do
    url = get_token_service_url()
    params = [
      type: "athenaWorkgroup",
      tool: "researcher-report",
      amOwner: "true"
    ]
    get_request()
    |> Req.get(url: url,
      auth: {:bearer, jwt},
      params: params,
      json: true,
      debug: false
    )
  end

  def get_first_resource_from_response(%{"error" => error}), do: {:error, error}
  def get_first_resource_from_response(%{"result" => []}), do: {:error, "You do not have an Athena Workgroup assigned to you."}
  def get_first_resource_from_response(%{"result" => [first|_]}), do: {:ok, first}
  def get_first_resource_from_response(_), do: {:error, "Something went wrong getting the Athena Workgroup"}

  defp request_create_workgroup_credentials(jwt, workgroup) do
    url = get_token_service_url("/#{workgroup["id"]}/credentials")

    get_request()
    |> Req.post(url: url,
      auth: {:bearer, jwt},
      json: %{},
      debug: false
    )
  end

  def get_credentials_from_response(%{"error" => error}), do: {:error, error}
  def get_credentials_from_response(%{"result" => credentials}), do: {:ok, credentials}
  def get_credentials_from_response(_), do: {:error, "Something went wrong getting the AWS credentials"}

  defp get_token_service_url(path \\ "") do
    token_service = Application.get_env(:report_server, :token_service)

    url = token_service |> Keyword.get(:url, "https://token-service-staging.firebaseapp.com/api/v1/resources")
    env = token_service |> Keyword.get(:env, "staging")

    "#{url}#{path}?env=#{env}"
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
