defmodule ReportServer.Repo.Migrations.CreateAuthGrants do
  use Ecto.Migration

  def change do
    create table(:auth_grants) do
      add :code_hash, :string, null: false
      add :code_challenge, :string, null: false
      add :portal_url, :string, null: false
      add :expires_at, :utc_datetime, null: false
      add :used_at, :utc_datetime
      add :user_id, references(:users, on_delete: :nothing), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:auth_grants, [:code_hash])
    create index(:auth_grants, [:user_id])
  end
end
