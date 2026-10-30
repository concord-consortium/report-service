defmodule ReportServer.Repo.Migrations.AllowRunlessDataAccessLog do
  use Ecto.Migration

  def change do
    alter table(:data_access_log) do
      modify :report_run_id, :"bigint unsigned", null: true, from: {:"bigint unsigned", null: false}
    end
  end
end
