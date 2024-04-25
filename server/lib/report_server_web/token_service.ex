defmodule ReportServerWeb.TokenService do
  def get_aws_data(portal_credentials) do
    with {:ok, jwt} <- get_firebase_jwt(portal_credentials),
         {:ok, workgroup} <- get_athena_workgroup(jwt) do
      {:ok, %{
        aws_data: %{
          jwt: jwt,
          workgroup: workgroup
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

  defp get_athena_workgroup(jwt) do
    with {:ok, resp} <- request_list_workgroup_resources(jwt),
         {:ok, workgroup} <- get_first_resource_from_response(resp.body) do
        {:ok, workgroup}
    else
      error -> error
    end
  end

  defp request_list_workgroup_resources(jwt) do
    url = get_token_service_url()
    params = [
      env: get_token_service_env(),
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

  defp get_token_service_url() do
    Application.get_env(:report_server, :token_service)
    |> Keyword.get(:url, "https://token-service-staging.firebaseapp.com/api/v1/resources")
  end

  defp get_token_service_env() do
    Application.get_env(:report_server, :token_service)
    |> Keyword.get(:env, "staging")
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
