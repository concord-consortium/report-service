defmodule ReportServerWeb.TokenService do

  def get_firebase_jwt(portal_credentials) do
    with {:ok, resp} <- request_firebase_jwt(portal_credentials),
         {:ok, token} <- get_token_from_response(resp.body) do
        {:ok, token}
    else
      error -> error
    end
  end

  def get_env(%{portal_url: portal_url} = _portal_credentials) do
    uri = URI.parse(portal_url)
    # use "production" token service env only if we're on the production url
    # this is the same code ported from the report-service app with the domain updated
    if uri.host == "report-server.concord.org" && !String.contains?(uri.path, "branch") do
      {:ok, "production"}
    else
      {:ok, "staging"}
    end
  end

  def get_athena_workgroup(env, jwt) do
    with {:ok, resp} <- request_list_workgroup_resources(env, jwt),
         {:ok, workgroup} <- get_first_resource_from_response(resp.body) do
        {:ok, workgroup}
    else
      error -> error
    end
  end

  def get_workgroup_credentials(env, jwt, workgroup) do
    with {:ok, resp} <- request_create_workgroup_credentials(env, jwt, workgroup),
         {:ok, workgroup_credentials} <- get_workgroup_credentials_from_response(resp.body) do
        {:ok, workgroup_credentials}
    else
      error -> error
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

  defp request_list_workgroup_resources(env, jwt) do
    url = get_token_service_url(env)
    params = [
      type: "athenaWorkgroup",
      tool: "researcher-report",
      amOwner: "true"
    ]
    get_request()
    |> Req.get(url: url,
      auth: {:bearer, jwt},
      params: params,
      debug: false
    )
  end

  def get_first_resource_from_response(%{"error" => error}), do: {:error, error}
  def get_first_resource_from_response(%{"result" => []}), do: {:error, "You do not have an Athena Workgroup assigned to you."}
  def get_first_resource_from_response(%{"result" => [first|_]}), do: {:ok, first}
  def get_first_resource_from_response(_), do: {:error, "Something went wrong getting the Athena Workgroup"}

  defp request_create_workgroup_credentials(env, jwt, workgroup) do
    url = get_token_service_url(env, "/#{workgroup["id"]}/credentials")

    get_request()
    |> Req.post(url: url,
      auth: {:bearer, jwt},
      json: %{},
      debug: false
    )
  end

  def get_workgroup_credentials_from_response(%{"error" => error}), do: {:error, error}
  def get_workgroup_credentials_from_response(%{"result" => raw_credentials}) do
    %{"accessKeyId" => access_key_id, "secretAccessKey" => secret_access_key, "sessionToken" => session_token} = raw_credentials
    {:ok, %{access_key_id: access_key_id, secret_access_key: secret_access_key, session_token: session_token}}
  end
  def get_workgroup_credentials_from_response(_), do: {:error, "Something went wrong getting the AWS credentials"}

  defp get_token_service_url(env, path \\ "") do
    url = Application.get_env(:report_server, :token_service)
      |> Keyword.get(:url, "https://token-service-staging.firebaseapp.com/api/v1/resources")

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
