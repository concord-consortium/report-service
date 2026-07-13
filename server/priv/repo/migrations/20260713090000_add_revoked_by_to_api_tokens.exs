defmodule ReportServer.Repo.Migrations.AddRevokedByToApiTokens do
  use Ecto.Migration

  def change do
    alter table(:api_tokens) do
      add :revoked_by_user_id, references(:users, on_delete: :nothing)
    end
  end
end
