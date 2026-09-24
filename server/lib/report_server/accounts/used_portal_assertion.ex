defmodule ReportServer.Accounts.UsedPortalAssertion do
  use Ecto.Schema

  import Ecto.Changeset

  schema "used_portal_assertions" do
    field :jti, :string
    field :expires_at, :utc_datetime

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc false
  def changeset(used_portal_assertion, attrs) do
    used_portal_assertion
    |> cast(attrs, [:jti, :expires_at])
    |> validate_required([:jti, :expires_at])
    |> validate_length(:jti, max: 255)
    |> unique_constraint(:jti)
  end
end
