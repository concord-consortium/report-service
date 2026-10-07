defmodule ReportServerWeb.Api.PortalToken do
  @moduledoc """
  Verifies an RS256 token rigse signed. The key comes from the kid, the issuer must be that
  key's, the algorithm is pinned, and aud and exp are checked here: `Joken.verify/2` checks
  neither, and would accept an aud list.

  rigse signs two kinds. An assertion names one service in a single-string `aud`; `verify/2`
  refuses a list even when it contains the expected audience, so a token addressed to several
  services can never pass as one. A scoped access token names every service it may be used at
  in an `aud` list and carries a space-separated `scope`; `verify_access_token/3` requires this
  deployment's own URL among those audiences and the capability the route needs in that scope.
  rigse marks an access token with the header `typ: at+jwt` (RFC 9068), and `verify_access_token/3`
  requires it, so no other token rigse signs can pass as one whatever its claims say.
  """
  alias ReportServerWeb.Api.PortalKeys

  @spec verify(String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def verify(token, audience) when is_binary(token) and is_binary(audience) do
    with {:ok, claims} <- decode(token),
         :ok <- check(claims["aud"] == audience, :wrong_audience) do
      {:ok, claims}
    end
  end

  def verify(_, _), do: {:error, :invalid}

  @spec verify_access_token(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def verify_access_token(token, audience, capability)
      when is_binary(token) and is_binary(audience) and is_binary(capability) do
    with {:ok, claims} <- decode(token),
         :ok <- check(access_token_type?(token), :wrong_type),
         :ok <- check(names?(claims["aud"], audience), :wrong_audience),
         :ok <- check(holds?(claims["scope"], capability), :missing_capability) do
      {:ok, claims}
    end
  end

  def verify_access_token(_, _, _), do: {:error, :invalid}

  @doc """
  The audience rigse names this deployment by in an access token: this endpoint's own URL,
  which is `PHX_HOST` in a deployed environment. Phoenix builds it with no path and drops the
  scheme's default port, which is the form rigse holds as its `REPORT_SERVER_URL`, and both
  sides compare it as an exact string.
  """
  @spec access_token_audience() :: String.t()
  def access_token_audience, do: ReportServerWeb.Endpoint.url()

  defp decode(token) do
    # The header's alg only refuses early; the verifying key and algorithm come from config.
    with {:ok, %{"alg" => "RS256", "kid" => kid}} <- peek_header(token),
         {:ok, %{pem: pem, iss: iss}} <- PortalKeys.lookup(kid),
         {:ok, claims} <- Joken.verify(token, Joken.Signer.create("RS256", %{"pem" => pem})),
         :ok <- check(claims["iss"] == iss, :wrong_issuer),
         :ok <- check_expiry(claims["exp"]) do
      {:ok, claims}
    else
      {:ok, _header} -> {:error, :unsupported_header}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :invalid}
    end
  end

  defp peek_header(token) do
    case Joken.peek_header(token) do
      {:ok, header} when is_map(header) -> {:ok, header}
      _ -> {:error, :malformed}
    end
  rescue
    _ -> {:error, :malformed}
  end

  # RFC 9068 section 4 allows the full media type too, and media types compare case-insensitively.
  defp access_token_type?(token) do
    case peek_header(token) do
      {:ok, %{"typ" => typ}} when is_binary(typ) -> String.downcase(typ) in ["at+jwt", "application/at+jwt"]
      _ -> false
    end
  end

  # Requiring a list keeps an assertion, which names its one service in a string, from
  # authenticating a route that wants an access token.
  defp names?(aud, audience) when is_list(aud), do: audience in aud
  defp names?(_, _), do: false

  # scope is RFC 6749 section 3.3's space-separated capability names.
  defp holds?(scope, capability) when is_binary(scope),
    do: capability in String.split(scope, " ", trim: true)

  defp holds?(_, _), do: false

  defp check(true, _), do: :ok
  defp check(_, reason), do: {:error, reason}

  defp check_expiry(exp) when is_integer(exp) do
    if exp > System.system_time(:second), do: :ok, else: {:error, :expired}
  end

  defp check_expiry(_), do: {:error, :no_expiry}
end
