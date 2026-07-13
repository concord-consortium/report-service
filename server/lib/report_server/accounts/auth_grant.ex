defmodule ReportServer.Accounts.AuthGrant do
  use Ecto.Schema

  import Ecto.Changeset

  alias ReportServer.Accounts.User

  schema "auth_grants" do
    field :code_hash, :string
    field :code_challenge, :string
    field :portal_url, :string
    field :expires_at, :utc_datetime
    field :used_at, :utc_datetime

    belongs_to :user, User, foreign_key: :user_id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(auth_grant, attrs) do
    auth_grant
    |> cast(attrs, [:user_id, :code_hash, :code_challenge, :portal_url, :expires_at, :used_at])
    |> validate_required([:user_id, :code_hash, :code_challenge, :portal_url, :expires_at])
    |> unique_constraint(:code_hash)
  end
end
