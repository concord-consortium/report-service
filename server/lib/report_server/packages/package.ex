defmodule ReportServer.Packages.Package do
  use Ecto.Schema

  import Ecto.Changeset

  alias ReportServer.Packages.{Identity, PackageVersion}

  @visibilities ~w(private project public)

  schema "packages" do
    field :portal_server, :string
    field :identity, :string
    field :origin, :string
    field :name, :string
    field :maintainer, :string
    field :visibility, :string, default: "private"
    field :project_id, :integer
    field :official, :boolean, default: false
    field :archived, :boolean, default: false
    field :current_version, :string

    has_many :versions, PackageVersion

    timestamps(type: :utc_datetime)
  end

  def visibilities, do: @visibilities

  @doc false
  def create_changeset(package, attrs) do
    package
    |> cast(attrs, [:portal_server, :origin, :name, :maintainer, :visibility, :official])
    |> validate_required([:portal_server, :origin, :name, :maintainer])
    |> validate_change(:name, fn :name, name -> if Identity.valid_name?(name), do: [], else: [name: "is invalid"] end)
    |> validate_change(:origin, &validate_origin/2)
    |> validate_change(:maintainer, &validate_origin/2)
    |> validate_inclusion(:visibility, @visibilities)
    |> put_identity()
    |> unique_constraint(:identity, name: :packages_portal_server_identity_index)
  end

  @doc false
  def state_changeset(package, attrs) do
    package
    |> cast(attrs, [:visibility, :project_id, :official, :archived, :current_version])
    |> validate_inclusion(:visibility, @visibilities)
  end

  defp validate_origin(field, value) do
    case Identity.parse_origin(value) do
      {:ok, _} -> []
      :error -> [{field, "is invalid"}]
    end
  end

  defp put_identity(changeset) do
    case {get_field(changeset, :origin), get_field(changeset, :name)} do
      {origin, name} when is_binary(origin) and is_binary(name) ->
        put_change(changeset, :identity, Identity.identity(origin, name))

      _ ->
        changeset
    end
  end
end
