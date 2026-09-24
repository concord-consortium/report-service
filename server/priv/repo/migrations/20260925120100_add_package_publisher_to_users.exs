defmodule ReportServer.Repo.Migrations.AddPackagePublisherToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :package_publisher, :boolean, null: false, default: false
    end
  end
end
