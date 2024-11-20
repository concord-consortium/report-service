defmodule ReportServer.Repo.Migrations.CreateReportRuns do
  use Ecto.Migration

  def change do
    create table(:report_runs) do
      add :report_slug, :string
      add :report_filter, :map
      add :report_filter_values, :map
      add :user_id, references(:users, on_delete: :nothing)

      timestamps(type: :utc_datetime)
    end

    create index(:report_runs, [:user_id])
  end
end
