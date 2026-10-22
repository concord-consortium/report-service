defmodule ReportServer.Repo.Migrations.RemoveCluePrepullFromPackageVersions do
  use Ecto.Migration

  def change do
    alter table(:package_versions) do
      remove :clue_prepull, :boolean, null: false, default: false
    end
  end
end
