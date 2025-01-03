defmodule ReportServer.Repo.Migrations.AddProjectInfoToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :portal_is_project_admin, :boolean, default: false
      add :portal_is_project_researcher, :boolean, default: false
    end
  end
end
