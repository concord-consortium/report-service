defmodule ReportServerWeb.Api.PortalKeys do
  @moduledoc """
  rigse's public keys, one entry per portal key: its kid, the PEM, and the one issuer (portal
  site URL) that key may sign for. One report-server serves the staging and the production
  portals, so a key is trusted only for its own issuer; picking by kid alone would let the
  staging key sign for production.

  Configured from `PORTAL_PUBLIC_KEYS`, a JSON array of `{"kid", "iss", "pem"}` objects. An
  entry that cannot be trusted as written is logged and ignored, so its kid is unknown.
  """
  require Logger

  @spec lookup(String.t() | nil) :: {:ok, %{pem: String.t(), iss: String.t()}} | {:error, :unknown_kid}
  def lookup(kid) when is_binary(kid) do
    case Map.fetch(keys(), kid) do
      {:ok, key} -> {:ok, key}
      :error -> {:error, :unknown_kid}
    end
  end

  def lookup(_), do: {:error, :unknown_kid}

  defp keys do
    case Application.get_env(:report_server, :portal_public_keys) do
      json when is_binary(json) and json != "" -> parse(json)
      _ -> %{}
    end
  end

  defp parse(json) do
    case Jason.decode(json) do
      {:ok, entries} when is_list(entries) ->
        repeated = repeated_kids(entries)

        entries
        |> Enum.reject(&(kid_of(&1) in repeated))
        |> Enum.flat_map(&valid_entry/1)
        |> Map.new()

      _ ->
        Logger.error("PORTAL_PUBLIC_KEYS is not a JSON array; no portal key is trusted")
        %{}
    end
  end

  # Counted before any entry is validated, so a malformed repeat still makes its kid ambiguous.
  defp repeated_kids(entries) do
    entries
    |> Enum.map(&kid_of/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
    |> Enum.filter(fn {_kid, count} -> count > 1 end)
    |> Enum.map(fn {kid, _count} ->
      # which issuer the kid is bound to would be a guess, so no entry for it is trusted
      Logger.error("PORTAL_PUBLIC_KEYS lists kid #{kid} more than once; ignoring it")
      kid
    end)
  end

  defp kid_of(%{"kid" => kid}) when is_binary(kid), do: kid
  defp kid_of(_entry), do: nil

  defp valid_entry(%{"kid" => kid, "iss" => iss, "pem" => pem})
       when is_binary(kid) and is_binary(iss) and is_binary(pem) do
    if readable_pem?(pem) do
      [{kid, %{iss: iss, pem: pem}}]
    else
      Logger.error("PORTAL_PUBLIC_KEYS entry #{kid} has an unreadable PEM; ignoring it")
      []
    end
  end

  defp valid_entry(_entry) do
    Logger.error("PORTAL_PUBLIC_KEYS has an entry without a string kid, iss and pem; ignoring it")
    []
  end

  defp readable_pem?(pem) do
    match?(%JOSE.JWK{}, JOSE.JWK.from_pem(pem))
  rescue
    _ -> false
  end
end
