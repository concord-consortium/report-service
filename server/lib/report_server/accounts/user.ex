defmodule ReportServer.Accounts.User do
  use Ecto.Schema

  import Ecto.Changeset

  alias ReportServer.Reports.ReportRun

  @all_fields [:portal_server, :portal_user_id, :portal_login, :portal_first_name, :portal_last_name, :portal_email, :portal_is_admin]

  schema "users" do
    field :portal_server, :string
    field :portal_user_id, :integer
    field :portal_login, :string
    field :portal_first_name, :string
    field :portal_last_name, :string
    field :portal_email, :string
    field :portal_is_admin, :boolean

    has_many :report_runs, ReportRun, foreign_key: :user_id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(user, attrs) do
    user
    |> cast(attrs, @all_fields)
    |> validate_required(@all_fields)
    |> unique_constraint(:portal_server, name: :uniq_server_users)
  end
end
