defmodule ReportServer.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users) do
      add :portal_server, :string
      add :portal_user_id, :integer
      add :portal_login, :string
      add :portal_first_name, :string
      add :portal_last_name, :string
      add :portal_email, :string
      add :portal_is_admin, :boolean

      timestamps(type: :utc_datetime)
    end

    create unique_index(
      :users,
      [:portal_server, :portal_user_id],
      name: :uniq_server_users
    )
  end
end
