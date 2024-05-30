defmodule ReportServerWeb.TokenService do
  require Logger

  @production_hosts ["learn.concord.org", "learn-report.concord.org", "ngss-assessment.portal.concord.org", "ngss-assessment-report.portal.concord.org"]

  def get_firebase_jwt("demo", _portal_credentials) do
    {:ok, "demo-jwt"}
  end

  def get_firebase_jwt(_mode, portal_credentials) do
    with {:ok, resp} <- request_firebase_jwt(portal_credentials),
         {:ok, token} <- get_token_from_response(resp.body) do
        {:ok, token}
    else
      {:error, error} ->
        Logger.error("Unable to get firebase JWT: #{error}")
        {:error, error}
    end
  end

  def get_env("demo", _portal_credentials) do
    {:ok, "demo-env"}
  end

  def get_env(_mode, %{portal_url: portal_url} = _portal_credentials) do
    uri = URI.parse(portal_url)
    # use "production" token service env only if we're using a production portal
    if Enum.any?(@production_hosts, &(&1 == uri.host)) do
      {:ok, "production"}
    else
      {:ok, "staging"}
    end
  end

  def get_env(_mode,  _portal_credentials) do
    {:ok, "staging"}
  end

  def get_athena_workgroup("demo", _env, _jwt) do
    {:ok, "demo-workgroup"}
  end

  def get_athena_workgroup(_mode, env, jwt) do
    with {:ok, resp} <- request_list_workgroup_resources(env, jwt),
         {:ok, workgroup} <- get_first_resource_from_response(resp.body) do
        {:ok, workgroup}
    else
      {:error, error} ->
        Logger.error("Unable to get Athena workgroup: #{error}")
        {:error, error}
    end
  end

  def get_workgroup_credentials("demo", _env, _jwt, _workgroup) do
    {:ok, %{access_key_id: "demo_access_key_id", secret_access_key: "demo_secret_access_key", session_token: "demo_session_token"}}
  end

  def get_workgroup_credentials(_mode, env, jwt, workgroup) do
    with {:ok, resp} <- request_create_workgroup_credentials(env, jwt, workgroup),
         {:ok, workgroup_credentials} <- get_workgroup_credentials_from_response(resp.body) do
        {:ok, workgroup_credentials}
    else
      {:error, error} ->
        Logger.error("Unable to get Athena workgroup credentials: #{error}")
        {:error, error}
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

  def get_private_bucket() do
    Application.get_env(:report_server, :token_service)
      |> Keyword.get(:private_bucket, "token-service-files-private")
  end

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

  def get_token_service_url(env, path \\ "") do
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
