defmodule ReportServer.Exports.ExportScratch do
  use Ecto.Schema

  import Ecto.Changeset

  alias ReportServer.Accounts.User
  alias ReportServer.Reports.ReportRun

  @bulk_data_types ["answers_bulk", "history_bulk"]
  @clue_data_types ["clue_documents_bulk", "clue_history_bulk", "clue_content_bulk"]

  schema "export_scratch" do
    field :scratch_id, :string
    field :data_type, :string

    # array of per-learner objects: %{"remote_endpoint" => ..., "source" => ..., "lti_tuple" => %{...} | nil}
    # for the bulk data types, or CLUE scope owners: %{"class_hash", "uid", "kind", "portal_class_id", "offerings"}
    field :endpoint_set, ReportServer.Types.EctoJsonArray
    field :expires_at, :utc_datetime

    belongs_to :user, User, foreign_key: :user_id
    belongs_to :report_run, ReportRun, foreign_key: :report_run_id

    timestamps(type: :utc_datetime)
  end

  def clue_data_types, do: @clue_data_types

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
    |> validate_inclusion(:data_type, @bulk_data_types ++ @clue_data_types)
    |> unique_constraint(:scratch_id)
  end
end
