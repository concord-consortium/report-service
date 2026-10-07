defmodule ReportServer.Packages.Identity do
  @moduledoc """
  A package's identity is `<origin>/<name>`, immutable, where the origin is `users/<id>` or
  `projects/<id>` on the package's portal. The name grammar excludes `_`, which is what keeps
  `__` unambiguous as the separator when an identity becomes a Firestore document id, and keeps
  that id clear of Firestore's reserved `__.*__` pattern.
  """

  @name ~r/\A[a-z0-9][a-z0-9-]{0,62}\z/
  @origin ~r/\A(users|projects)\/([1-9][0-9]{0,17})\z/

  def valid_name?(name), do: is_binary(name) and Regex.match?(@name, name)

  @doc "Parses an origin or a maintainer, which share one grammar."
  @spec parse_origin(term()) :: {:ok, {:users | :projects, pos_integer()}} | :error
  def parse_origin(origin) when is_binary(origin) do
    case Regex.run(@origin, origin) do
      [_, "users", id] -> {:ok, {:users, String.to_integer(id)}}
      [_, "projects", id] -> {:ok, {:projects, String.to_integer(id)}}
      nil -> :error
    end
  end

  def parse_origin(_), do: :error

  def origin(:users, id), do: "users/#{id}"
  def origin(:projects, id), do: "projects/#{id}"

  def identity(origin, name), do: "#{origin}/#{name}"

  @doc "Splits an identity into its origin and name, validating both."
  @spec parse(term()) :: {:ok, %{origin: String.t(), name: String.t()}} | :error
  def parse(identity) when is_binary(identity) do
    with [kind, id, name] <- String.split(identity, "/"),
         origin = "#{kind}/#{id}",
         {:ok, _} <- parse_origin(origin),
         true <- valid_name?(name) do
      {:ok, %{origin: origin, name: name}}
    else
      _ -> :error
    end
  end

  def parse(_), do: :error

  def s3_key(identity, version, ext), do: "packages/#{identity}/#{version}.#{ext}"
end
