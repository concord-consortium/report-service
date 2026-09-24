defmodule ReportServer.Packages.Archive do
  @moduledoc """
  Validates an uploaded package zip and reads only its `manifest.json`, without trusting any
  size the archive declares about itself.

  Entry offsets and compressed sizes come from the central directory, because Go's
  `archive/zip` (cc-data-cli) sets flag 0x8 and leaves the local header's sizes zero. The
  manifest is inflated through `:zlib.safeInflate/2` and abandoned once its actual output passes
  the cap, since an entry can declare 100 bytes and inflate to gigabytes.
  """

  @max_archive_bytes 10 * 1024 * 1024
  @max_declared_total 50 * 1024 * 1024
  @max_manifest_bytes 64 * 1024

  @local_header_signature 0x04034B50
  @stored 0
  @deflated 8

  def max_archive_bytes, do: @max_archive_bytes

  @doc """
  Returns the decoded manifest and the archive's file entry names, or a message naming why the
  archive is refused.
  """
  @spec read_manifest(binary()) :: {:ok, map(), [String.t()]} | {:error, String.t()}
  def read_manifest(bin) when is_binary(bin) do
    with :ok <- check_size(bin),
         {:ok, entries} <- list_entries(bin),
         :ok <- check_paths(entries),
         :ok <- check_declared_total(entries),
         {:ok, entry} <- manifest_entry(entries),
         {:ok, json} <- read_entry(bin, entry),
         {:ok, manifest} <- decode(json) do
      {:ok, manifest, for(%{name: name, type: :regular} <- entries, do: name)}
    end
  end

  defp check_size(bin) when byte_size(bin) > @max_archive_bytes, do: {:error, "the archive exceeds 10 MiB"}
  defp check_size(_bin), do: :ok

  defp list_entries(bin) do
    case :zip.list_dir(bin) do
      {:ok, listing} ->
        entries =
          for {:zip_file, name, info, _comment, offset, comp_size} <- listing do
            # file_info's second and third fields are the uncompressed size and the type
            %{name: List.to_string(name), size: elem(info, 1), type: elem(info, 2), offset: offset, comp_size: comp_size}
          end

        {:ok, entries}

      _ ->
        {:error, "the archive is not a readable zip"}
    end
  rescue
    _ -> {:error, "the archive is not a readable zip"}
  end

  defp check_paths(entries) do
    case Enum.find(entries, &unsafe_path?(&1.name)) do
      nil -> :ok
      entry -> {:error, "the archive entry #{inspect(entry.name)} is absolute or climbs out of the archive"}
    end
  end

  def unsafe_path?(name) do
    segments = String.split(name, ["/", "\\"])
    String.starts_with?(name, ["/", "\\"]) or ".." in segments or String.match?(name, ~r/\A[A-Za-z]:/)
  end

  defp check_declared_total(entries) do
    if Enum.sum(Enum.map(entries, & &1.size)) > @max_declared_total,
      do: {:error, "the archive declares more than 50 MiB uncompressed"},
      else: :ok
  end

  defp manifest_entry(entries) do
    case Enum.filter(entries, &(&1.name == "manifest.json")) do
      [entry] -> {:ok, entry}
      [] -> {:error, "the archive has no manifest.json at its root"}
      _ -> {:error, "the archive has more than one manifest.json"}
    end
  end

  defp read_entry(bin, %{offset: offset, comp_size: comp_size}) do
    with <<_::binary-size(offset), @local_header_signature::little-32, _version::16, flags::little-16,
           method::little-16, _time_date_crc::binary-size(8), _sizes::binary-size(8),
           name_len::little-16, extra_len::little-16, rest::binary>> <- bin,
         <<_name::binary-size(name_len), _extra::binary-size(extra_len), data::binary-size(comp_size), _::binary>> <- rest do
      cond do
        Bitwise.band(flags, 1) == 1 -> {:error, "manifest.json is encrypted"}
        method == @stored and comp_size > @max_manifest_bytes -> manifest_too_large()
        method == @stored -> {:ok, data}
        method == @deflated -> inflate(data)
        true -> {:error, "manifest.json uses an unsupported compression method"}
      end
    else
      _ -> {:error, "the archive is not a readable zip"}
    end
  end

  defp inflate(data) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z, -15)
      inflate_bounded(z, :zlib.safeInflate(z, data), [], 0)
    rescue
      _ -> {:error, "manifest.json is not a valid deflate stream"}
    after
      :zlib.close(z)
    end
  end

  defp inflate_bounded(z, {status, output}, acc, total) do
    total = total + IO.iodata_length(output)

    cond do
      total > @max_manifest_bytes -> manifest_too_large()
      status == :continue -> inflate_bounded(z, :zlib.safeInflate(z, []), [acc, output], total)
      status == :finished -> {:ok, IO.iodata_to_binary([acc, output])}
    end
  end

  defp manifest_too_large, do: {:error, "manifest.json exceeds 64 KiB"}

  defp decode(json) do
    case Jason.decode(json) do
      {:ok, manifest} when is_map(manifest) -> {:ok, manifest}
      _ -> {:error, "manifest.json is not a JSON object"}
    end
  end
end
