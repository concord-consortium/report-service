defmodule ReportServer.Repo.Migrations.CreateUsedPortalAssertions do
  use Ecto.Migration

  def change do
    create table(:used_portal_assertions) do
      add :jti, :string, null: false
      add :expires_at, :utc_datetime, null: false
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:used_portal_assertions, [:jti])
    create index(:used_portal_assertions, [:expires_at])
  end
end
