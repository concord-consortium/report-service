defmodule ReportServerWeb.Api.PortalAssertion do
  @moduledoc """
  Verifies the short-lived claim the portal signs when it asks for a dashboard token on a
  researcher's behalf.

  HS256 with the secret shared with the portal. An HMAC verifier is also a minter, so this
  key must never travel to something whose only job is to relay an assertion; if a relay
  ever has to verify one, this becomes RS256 against a portal public key.

  The audience and expiry are checked here rather than left to the caller, because an
  assertion is a bearer credential for the few minutes it lives: anyone holding one can
  exchange it for that researcher's API token.
  """

  @algorithm "HS256"
  @audience "report-server"

  @spec verify(String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def verify(assertion, secret) do
    signer = Joken.Signer.create(@algorithm, secret)

    with {:ok, claims} <- Joken.verify(assertion, signer),
         :ok <- check_audience(claims),
         :ok <- check_expiry(claims) do
      {:ok, claims}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # Without this an assertion minted for another service that happens to share the secret
  # would be accepted here.
  defp check_audience(%{"aud" => @audience}), do: :ok
  defp check_audience(_), do: {:error, :wrong_audience}

  # A missing expiry is refused rather than treated as "no limit", so a claim that never
  # dies cannot be accepted by omission.
  defp check_expiry(%{"exp" => exp}) when is_integer(exp) do
    if exp > System.system_time(:second), do: :ok, else: {:error, :expired}
  end

  defp check_expiry(_), do: {:error, :no_expiry}
end
