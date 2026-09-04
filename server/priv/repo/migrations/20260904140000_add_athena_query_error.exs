defmodule ReportServer.Repo.Migrations.AddAthenaQueryError do
  use Ecto.Migration

  def change do
    alter table(:report_runs) do
      # :text, not :string. Athena's StateChangeReason can exceed varchar(255), and under
      # STRICT_TRANS_TABLES an over-length value errors the write rather than truncating.
      add :athena_query_error, :text, default: nil
    end
  end
end
