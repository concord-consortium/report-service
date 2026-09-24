defmodule ReportServer.Packages.PackageVersion do
  use Ecto.Schema

  import Ecto.Changeset

  alias ReportServer.Accounts.User
  alias ReportServer.Packages.Package

  schema "package_versions" do
    field :version, :string
    field :checksum, :string
    field :s3_key, :string
    field :published_at, :utc_datetime
    field :title, :string
    field :description, :string
    field :urls, :map
    field :clue_prepull, :boolean, default: false
    field :expected_duration_seconds, :integer

    belongs_to :package, Package
    belongs_to :publisher, User, foreign_key: :published_by
  end

  @fields [:package_id, :version, :checksum, :s3_key, :published_at, :published_by, :title,
           :description, :urls, :clue_prepull, :expected_duration_seconds]
  @required @fields -- [:description]

  @doc false
  def changeset(version, attrs) do
    version
    |> cast(attrs, @fields)
    |> validate_required(@required)
    |> unique_constraint(:version, name: :package_versions_package_id_version_index)
  end
end
