defmodule ReportServerWeb.Api.PortalToken do
  @moduledoc """
  Verifies an RS256 token rigse signed. The key comes from the kid, the issuer must be that
  key's, the algorithm is pinned, and aud and exp are checked here: `Joken.verify/2` checks
  neither, and would accept an aud list.
  """
  alias ReportServerWeb.Api.PortalKeys

  @spec verify(String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def verify(token, audience) when is_binary(token) and is_binary(audience) do
    # The header's alg only refuses early; the verifying key and algorithm come from config.
    with {:ok, %{"alg" => "RS256", "kid" => kid}} <- peek_header(token),
         {:ok, %{pem: pem, iss: iss}} <- PortalKeys.lookup(kid),
         {:ok, claims} <- Joken.verify(token, Joken.Signer.create("RS256", %{"pem" => pem})),
         :ok <- check(claims["iss"] == iss, :wrong_issuer),
         :ok <- check(claims["aud"] == audience, :wrong_audience),
         :ok <- check_expiry(claims["exp"]) do
      {:ok, claims}
    else
      {:ok, _header} -> {:error, :unsupported_header}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :invalid}
    end
  end

  def verify(_, _), do: {:error, :invalid}

  defp peek_header(token) do
    case Joken.peek_header(token) do
      {:ok, header} when is_map(header) -> {:ok, header}
      _ -> {:error, :malformed}
    end
  rescue
    _ -> {:error, :malformed}
  end

  defp check(true, _), do: :ok
  defp check(_, reason), do: {:error, reason}

  defp check_expiry(exp) when is_integer(exp) do
    if exp > System.system_time(:second), do: :ok, else: {:error, :expired}
  end

  defp check_expiry(_), do: {:error, :no_expiry}
end
