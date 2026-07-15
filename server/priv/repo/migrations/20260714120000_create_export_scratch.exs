defmodule ReportServer.Repo.Migrations.CreateExportScratch do
  use Ecto.Migration

  def change do
    create table(:export_scratch) do
      # unguessable capability, minted per export (NOT the PK); the client-held page_token references it
      add :scratch_id, :string, null: false
      add :report_run_id, references(:report_runs, on_delete: :nothing), null: false
      add :user_id, references(:users, on_delete: :nothing), null: false
      # "answers_bulk" | "history_bulk" — binds the scratch to its route
      add :data_type, :string, null: false
      # per-learner authorized snapshot: [{remote_endpoint, source, lti_tuple?}, ...]
      # :map compiles to a MySQL `json` column; the schema field uses EctoJsonArray so the array round-trips
      add :endpoint_set, :map, null: false
      add :expires_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:export_scratch, [:scratch_id])
    create index(:export_scratch, [:expires_at])
  end
end
