defmodule ReportServer.Repo.Migrations.CreatePackages do
  use Ecto.Migration

  def change do
    create table(:packages) do
      # the portal the origin's and maintainer's ids belong to; one report-server serves several
      add :portal_server, :string, null: false
      add :identity, :string, null: false
      add :origin, :string, null: false
      add :name, :string, null: false
      add :maintainer, :string, null: false
      add :visibility, :string, null: false, default: "private"
      add :project_id, :integer
      add :official, :boolean, null: false, default: false
      add :archived, :boolean, null: false, default: false
      add :current_version, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:packages, [:portal_server, :identity])
    create index(:packages, [:portal_server, :official, :archived])
    create index(:packages, [:portal_server, :visibility, :archived])
    create index(:packages, [:portal_server, :maintainer])

    create table(:package_versions) do
      add :package_id, references(:packages, on_delete: :restrict), null: false
      add :version, :string, null: false
      add :checksum, :string, null: false
      add :s3_key, :string, null: false
      add :published_at, :utc_datetime, null: false
      add :published_by, references(:users, on_delete: :restrict), null: false
      add :title, :string, null: false
      add :description, :string, size: 500
      add :urls, :map, null: false
      add :clue_prepull, :boolean, null: false, default: false
      add :expected_duration_seconds, :integer, null: false
    end

    create unique_index(:package_versions, [:package_id, :version])

    create table(:package_events) do
      add :package_id, references(:packages, on_delete: :restrict), null: false
      add :user_id, references(:users, on_delete: :restrict), null: false
      add :field, :string, null: false
      add :previous_value, :string
      add :new_value, :string

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:package_events, [:package_id])
  end
end
