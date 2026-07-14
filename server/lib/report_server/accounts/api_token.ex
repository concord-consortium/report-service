defmodule ReportServer.Accounts.ApiToken do
  use Ecto.Schema

  import Ecto.Changeset

  alias ReportServer.Accounts.User

  schema "api_tokens" do
    field :token_hash, :string
    field :label, :string
    field :last_used_at, :utc_datetime
    field :revoked_at, :utc_datetime

    belongs_to :user, User, foreign_key: :user_id
    belongs_to :revoked_by, User, foreign_key: :revoked_by_user_id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(api_token, attrs) do
    api_token
    |> cast(attrs, [:user_id, :token_hash, :label, :last_used_at, :revoked_at])
    |> validate_required([:user_id, :token_hash])
    |> unique_constraint(:token_hash)
  end
end
