defmodule ReportServerWeb.AuthCliController do
  use ReportServerWeb, :controller

  alias ReportServer.Accounts
  alias ReportServer.PortalDbs
  alias ReportServerWeb.Auth
  alias ReportServerWeb.Auth.PortalStrategy
  alias ReportServerWeb.Api.ErrorHelpers

  def cli(conn, params) do
    case validate_cli_request(conn, params) do
      {:ok, request} ->
        session = get_session(conn)
        user = session["user"]

        if Auth.logged_in?(session) && user && portal_matches?(user, request.portal_url) do
          authorize_or_reject(conn, user, request)
        else
          conn
          |> put_session(:cli_auth_request, request)
          |> put_session(:portal_url, request.portal_url)
          |> put_session(:return_to, ~p"/auth/cli/resume")
          |> redirect(external: PortalStrategy.get_authorize_url(request.portal_url))
        end

      {:error, message} ->
        render_cli_error(conn, message)
    end
  end

  def resume(conn, _params) do
    request = get_session(conn, :cli_auth_request)
    session = get_session(conn)
    user = session["user"]

    cond do
      request == nil ->
        render_cli_error(conn, "No CLI login is in progress. Start again from your terminal.")

      !(Auth.logged_in?(session) && user && portal_matches?(user, request.portal_url)) ->
        render_cli_error(conn, "Portal login did not complete. Start again from your terminal.")

      true ->
        conn
        |> delete_session(:cli_auth_request)
        |> authorize_or_reject(user, request)
    end
  end

  def token(conn, _params) do
    query_secrets? =
      Map.has_key?(conn.query_params, "code") or Map.has_key?(conn.query_params, "code_verifier")

    case {query_secrets?, conn.body_params} do
      {false, %{"code" => code, "code_verifier" => code_verifier}}
      when is_binary(code) and is_binary(code_verifier) ->
        case Accounts.exchange_auth_grant(code, code_verifier) do
          {:ok, raw_token, _api_token} ->
            json(conn, %{token: raw_token})

          _ ->
            ErrorHelpers.bad_request(conn, "Invalid code or verifier.")
        end

      _ ->
        ErrorHelpers.bad_request(conn, "Invalid code or verifier.")
    end
  end

  defp authorize_or_reject(conn, user, request) do
    if Auth.can_access_reports?(%{"user" => user}) do
      case Accounts.create_auth_grant(user, request.code_challenge, request.portal_url) do
        {:ok, raw_code, _auth_grant} ->
          query = URI.encode_query(%{"code" => raw_code, "state" => request.state})

          conn
          |> delete_session(:cli_auth_request)
          |> redirect(external: "#{request.redirect_uri}?#{query}")

        {:error, _changeset} ->
          render_cli_error(conn, "Something went wrong starting the CLI login. Please try again.")
      end
    else
      render_cli_error(conn, "Sorry, you are not a portal admin, project admin, or project researcher so you don't have report access.")
    end
  end

  defp portal_matches?(user, portal_url) do
    user.portal_server == PortalDbs.get_server_for_portal_url(portal_url)
  end

  defp render_cli_error(conn, message) do
    conn
    |> put_status(:bad_request)
    |> render(:error, message: message, page_title: "CLI Login Error")
  end

  defp validate_cli_request(conn, params) do
    with {:ok, redirect_uri} <- validate_redirect_uri(params["redirect_uri"]),
         {:ok, state} <- require_param(params, "state"),
         {:ok, code_challenge} <- validate_code_challenge(params["code_challenge"]),
         :ok <- validate_challenge_method(params["code_challenge_method"]),
         {:ok, portal_url} <- validate_portal(conn, params["portal"]) do
      {:ok, %{redirect_uri: redirect_uri, state: state, code_challenge: code_challenge, portal_url: portal_url}}
    end
  end

  defp validate_redirect_uri(redirect_uri) when is_binary(redirect_uri) do
    uri = URI.parse(redirect_uri)

    if uri.scheme == "http" && uri.host == "127.0.0.1" && uri.userinfo == nil &&
         is_integer(uri.port) && uri.port in 1..65535 &&
         uri.authority == "127.0.0.1:#{uri.port}" &&
         uri.path == "/callback" && uri.query == nil && uri.fragment == nil do
      {:ok, redirect_uri}
    else
      {:error, "redirect_uri must be http://127.0.0.1:<port>/callback"}
    end
  end
  defp validate_redirect_uri(_), do: {:error, "redirect_uri must be http://127.0.0.1:<port>/callback"}

  defp require_param(params, name) do
    case params[name] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "#{name} is required"}
    end
  end

  defp validate_code_challenge(code_challenge) when is_binary(code_challenge) do
    if Regex.match?(~r/^[A-Za-z0-9_-]{43}$/, code_challenge) do
      {:ok, code_challenge}
    else
      {:error, "code_challenge must be a base64url-encoded SHA-256 digest"}
    end
  end
  defp validate_code_challenge(_), do: {:error, "code_challenge must be a base64url-encoded SHA-256 digest"}

  defp validate_challenge_method("S256"), do: :ok
  defp validate_challenge_method(_), do: {:error, "code_challenge_method must be S256"}

  defp validate_portal(conn, nil), do: {:ok, Auth.get_portal_url(conn)}
  defp validate_portal(_conn, portal_url) do
    uri = URI.parse(portal_url)

    valid_origin? =
      uri.scheme == "https" && uri.userinfo == nil && is_binary(uri.host) && uri.host != "" &&
        uri.path in [nil, "/"] && uri.query == nil && uri.fragment == nil &&
        is_integer(uri.port) && uri.port in 1..65535 &&
        uri.authority in [uri.host, "#{uri.host}:#{uri.port}"]

    if valid_origin? do
      normalized =
        if uri.port == 443, do: "https://#{uri.host}", else: "https://#{uri.host}:#{uri.port}"

      server = PortalDbs.get_server_for_portal_url(normalized)

      if PortalDbs.has_db_connection?(server) do
        {:ok, normalized}
      else
        {:error, "unknown portal"}
      end
    else
      {:error, "portal must be an https origin (https://host[:port])"}
    end
  end
end
