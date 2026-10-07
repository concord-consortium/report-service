defmodule ReportServer.Repo.Migrations.AddExpiresAtToApiTokens do
  use Ecto.Migration

  def change do
    alter table(:api_tokens) do
      # set only on dashboard tokens; cc-data's CLI tokens share the table and never expire
      add :expires_at, :utc_datetime
    end
  end
end
