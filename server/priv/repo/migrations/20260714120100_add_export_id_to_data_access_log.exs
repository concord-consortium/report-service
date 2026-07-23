defmodule ReportServer.Repo.Migrations.AddExportIdToDataAccessLog do
  use Ecto.Migration

  def change do
    alter table(:data_access_log) do
      # nullable; correlates all rows of one bulk export (= scratch_id). Null on STORY 1 CSV/job rows.
      add :export_id, :string
    end

    create index(:data_access_log, [:export_id])
  end
end
