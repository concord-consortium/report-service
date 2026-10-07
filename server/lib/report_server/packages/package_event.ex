defmodule ReportServer.Packages.PackageEvent do
  @moduledoc """
  One audit row per change to a package's state: who changed which field, from what, to what.
  """
  use Ecto.Schema

  alias ReportServer.Accounts.User
  alias ReportServer.Packages.Package

  schema "package_events" do
    field :field, :string
    field :previous_value, :string
    field :new_value, :string

    belongs_to :package, Package
    belongs_to :user, User

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
