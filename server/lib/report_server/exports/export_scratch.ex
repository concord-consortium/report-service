defmodule ReportServer.Exports.ExportScratch do
  use Ecto.Schema

  import Ecto.Changeset

  alias ReportServer.Accounts.User
  alias ReportServer.Reports.ReportRun

  schema "export_scratch" do
    field :scratch_id, :string
    field :data_type, :string

    # array of per-learner objects: %{"remote_endpoint" => ..., "source" => ..., "lti_tuple" => %{...} | nil}
    field :endpoint_set, ReportServer.Types.EctoJsonArray
    field :expires_at, :utc_datetime

    belongs_to :user, User, foreign_key: :user_id
    belongs_to :report_run, ReportRun, foreign_key: :report_run_id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(scratch, attrs) do
    scratch
    |> cast(attrs, [:scratch_id, :data_type, :endpoint_set, :expires_at, :user_id, :report_run_id])
    |> validate_required([
      :scratch_id,
      :data_type,
      :endpoint_set,
      :expires_at,
      :user_id,
      :report_run_id
    ])
    |> validate_inclusion(:data_type, ["answers_bulk", "history_bulk"])
    |> unique_constraint(:scratch_id)
  end
end
