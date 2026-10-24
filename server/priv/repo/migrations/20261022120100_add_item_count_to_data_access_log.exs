defmodule ReportServer.Repo.Migrations.AddItemCountToDataAccessLog do
  use Ecto.Migration

  def change do
    alter table(:data_access_log) do
      add :item_count, :integer, null: true
    end
  end
end
