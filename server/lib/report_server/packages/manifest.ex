defmodule ReportServer.Packages.Manifest do
  @moduledoc """
  Validates a package's `manifest.json` and projects it into `package_versions` attributes.
  The projection decides what the catalog offers; the manifest inside the zip decides what the
  runner executes, and the checksum ties the two together.
  """

  alias ReportServer.Packages.{Archive, Identity, Patterns}

  @catalog_state_keys ~w(owner maintainer origin visibility project official)
  @version ~r/\A(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?\z/
  @max_version_length 64
  @max_title_length 200
  @max_description_length 500
  # the runner's own ceiling (its PACKAGE_MAX_DURATION_SECONDS default), so nothing published is refused on the VM
  @max_duration_seconds 2 * 60 * 60

  @type projection :: %{
          name: String.t(),
          version: String.t(),
          title: String.t(),
          description: String.t() | nil,
          urls: %{String.t() => [String.t()]},
          clue_prepull: boolean(),
          expected_duration_seconds: pos_integer()
        }

  @doc """
  Projects a decoded manifest, given the archive's file entries so the entrypoint can be
  checked, or answers a message naming the first field that is wrong.
  """
  @spec project(map(), [String.t()]) :: {:ok, projection()} | {:error, String.t()}
  def project(manifest, entries) when is_map(manifest) do
    with :ok <- refuse_catalog_state(manifest),
         {:ok, name} <- name(manifest["name"]),
         {:ok, version} <- version(manifest["version"]),
         {:ok, title} <- title(manifest["title"]),
         {:ok, description} <- description(manifest["description"]),
         {:ok, urls} <- urls(manifest["urls"]),
         {:ok, clue_prepull} <- clue_prepull(manifest["clue_prepull"]),
         :ok <- entrypoint(manifest["entrypoint"], entries),
         {:ok, duration} <- duration(manifest["expected_duration_seconds"]) do
      {:ok,
       %{
         name: name,
         version: version,
         title: title,
         description: description,
         urls: urls,
         clue_prepull: clue_prepull,
         expected_duration_seconds: duration
       }}
    end
  end

  defp refuse_catalog_state(manifest) do
    case Enum.filter(@catalog_state_keys, &Map.has_key?(manifest, &1)) do
      [] -> :ok
      keys -> invalid("declares #{Enum.join(keys, ", ")}, which the catalog sets and a manifest may not")
    end
  end

  defp name(name) do
    if Identity.valid_name?(name),
      do: {:ok, name},
      else: invalid("name must match ^[a-z0-9][a-z0-9-]{0,62}$")
  end

  @doc "Whether `version` is a version the catalog accepts: the grammar `fixtures/package-contract.json` asserts."
  def valid_version?(version), do: is_binary(version) and chars(version) <= @max_version_length and Regex.match?(@version, version)

  defp version(version) do
    if valid_version?(version),
      do: {:ok, version},
      else: invalid("version must be MAJOR.MINOR.PATCH with an optional -prerelease, at most #{@max_version_length} characters")
  end

  defp title(title) do
    if is_binary(title) and String.trim(title) != "" and chars(title) <= @max_title_length,
      do: {:ok, title},
      else: invalid("title must be a non-empty string of at most #{@max_title_length} characters")
  end

  defp description(nil), do: {:ok, nil}

  defp description(description) do
    if is_binary(description) and chars(description) <= @max_description_length and
         not String.contains?(description, ["\n", "\r"]),
       do: {:ok, description},
       else: invalid("description must be one line of at most #{@max_description_length} characters")
  end

  defp urls(urls) do
    case Patterns.validate(urls) do
      {:ok, groups} -> {:ok, groups}
      {:error, message} -> invalid(message)
    end
  end

  defp clue_prepull(nil), do: {:ok, false}
  defp clue_prepull(value) when is_boolean(value), do: {:ok, value}
  defp clue_prepull(_), do: invalid("clue_prepull must be a boolean")

  defp entrypoint(entrypoint, entries) when is_binary(entrypoint) do
    cond do
      Archive.unsafe_path?(entrypoint) -> invalid("entrypoint must be a relative path inside the archive")
      entrypoint in entries -> :ok
      true -> invalid("entrypoint #{inspect(entrypoint)} is not a file in the archive")
    end
  end

  defp entrypoint(_, _), do: invalid("entrypoint must name a file in the archive")

  defp duration(seconds) when is_integer(seconds) and seconds > 0 and seconds <= @max_duration_seconds,
    do: {:ok, seconds}

  defp duration(_),
    do: invalid("expected_duration_seconds must be a positive integer of at most #{@max_duration_seconds}")

  # code points rather than graphemes, which is what the varchar columns count
  defp chars(string), do: length(String.codepoints(string))

  defp invalid(message), do: {:error, "manifest.json: " <> message}
end
