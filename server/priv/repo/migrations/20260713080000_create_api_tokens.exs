defmodule ReportServer.Repo.Migrations.CreateApiTokens do
  use Ecto.Migration

  def change do
    create table(:api_tokens) do
      add :token_hash, :string, null: false
      add :label, :string
      add :last_used_at, :utc_datetime
      add :revoked_at, :utc_datetime
      add :user_id, references(:users, on_delete: :nothing), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:api_tokens, [:token_hash])
    create index(:api_tokens, [:user_id])
  end
end
