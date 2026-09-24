defmodule ReportServerWeb.PortalTokenFixture do
  @moduledoc """
  Two rigse signing keys standing in for a staging and a production portal, generated once per
  test run, and helpers that sign test tokens with them. `install!/0` configures report-server
  to trust both, each for its own issuer.
  """

  @keys %{
    staging: %{kid: "staging-test", iss: "https://learn.portal.staging.concord.org/"},
    production: %{kid: "production-test", iss: "https://learn.concord.org/"}
  }

  def install! do
    Application.put_env(:report_server, :portal_public_keys, public_keys_json())
  end

  def public_keys_json do
    @keys
    |> Enum.map(fn {name, %{kid: kid, iss: iss}} -> %{kid: kid, iss: iss, pem: public_pem(name)} end)
    |> Jason.encode!()
  end

  def kid(name), do: @keys[name].kid
  def iss(name), do: @keys[name].iss

  @doc "The claims rigse puts in a token for `audience` from the `key` portal, expiring in two minutes."
  def claims(key, audience, overrides \\ %{}) do
    now = System.system_time(:second)

    Map.merge(
      %{"iss" => iss(key), "aud" => audience, "uid" => 42, "iat" => now, "exp" => now + 120},
      overrides
    )
  end

  @doc """
  Signs `claims` with the `key` portal's private key. `:kid` overrides the header's kid, and
  `:without` drops claims.
  """
  def sign(key, claims, opts \\ []) do
    header = %{"kid" => Keyword.get(opts, :kid, kid(key))}
    claims = Map.drop(claims, Keyword.get(opts, :without, []))
    signer = Joken.Signer.create("RS256", %{"pem" => private_pem(key)}, header)
    {:ok, token} = Joken.Signer.sign(claims, signer)
    token
  end

  @doc """
  An HS256 token whose HMAC secret is the `key` portal's public PEM: the alg-confusion attack.
  `:header_alg` sets the alg the header claims, which is HS256 unless overridden.
  """
  def sign_hs256_with_public_pem(key, claims, opts \\ []) do
    header = %{"alg" => Keyword.get(opts, :header_alg, "HS256"), "typ" => "JWT", "kid" => kid(key)}
    signing_input = "#{encode(header)}.#{encode(claims)}"
    signature = :crypto.mac(:hmac, :sha256, public_pem(key), signing_input)
    "#{signing_input}.#{Base.url_encode64(signature, padding: false)}"
  end

  @doc "An unsigned `alg: none` token naming the `key` portal's kid."
  def unsigned(key, claims) do
    "#{encode(%{"alg" => "none", "typ" => "JWT", "kid" => kid(key)})}.#{encode(claims)}."
  end

  defp encode(map), do: map |> Jason.encode!() |> Base.url_encode64(padding: false)

  def public_pem(key) do
    {_meta, pem} = key |> jwk() |> JOSE.JWK.to_public() |> JOSE.JWK.to_pem()
    pem
  end

  defp private_pem(key) do
    {_meta, pem} = key |> jwk() |> JOSE.JWK.to_pem()
    pem
  end

  defp jwk(key) do
    term_key = {__MODULE__, key}

    case :persistent_term.get(term_key, nil) do
      nil ->
        jwk = JOSE.JWK.generate_key({:rsa, 2048, 65537})
        :persistent_term.put(term_key, jwk)
        jwk

      jwk ->
        jwk
    end
  end
end
