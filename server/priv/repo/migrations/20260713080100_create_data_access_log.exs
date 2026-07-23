defmodule ReportServer.Repo.Migrations.CreateDataAccessLog do
  use Ecto.Migration

  def change do
    create table(:data_access_log) do
      add :event, :string, null: false
      add :source, :string, null: false
      add :data_type, :string, null: false
      add :user_id, references(:users, on_delete: :nothing), null: false
      add :report_run_id, references(:report_runs, on_delete: :nothing), null: false
      # denormalized filter snapshot so the log row is self-contained even if the run changes
      add :report_filter, :map
      add :report_slug, :string
      # post-processing job id for job_result rows; null for plain CSV rows
      add :job_id, :integer
      # STORY 3 per-page events fill these; null for URL-issuance rows
      add :cursor, :string
      add :endpoint_set, :map

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:data_access_log, [:user_id])
    create index(:data_access_log, [:report_run_id])
    create index(:data_access_log, [:inserted_at])
  end
end
