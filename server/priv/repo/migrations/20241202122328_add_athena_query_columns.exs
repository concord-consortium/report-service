defmodule ReportServer.Repo.Migrations.AddAthenaQueryColumns do
  use Ecto.Migration

  def change do
    alter table(:report_runs) do
      add :athena_query_id, :string, default: nil
      add :athena_query_state, :string, default: nil
      add :athena_result_url, :string, default: nil
    end
  end
end
