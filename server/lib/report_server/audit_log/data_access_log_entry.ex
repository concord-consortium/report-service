defmodule ReportServer.AuditLog.DataAccessLogEntry do
  use Ecto.Schema

  import Ecto.Changeset

  alias ReportServer.Accounts.User
  alias ReportServer.Exports.ExportScratch
  alias ReportServer.Reports.ReportRun

  schema "data_access_log" do
    field :event, :string
    field :source, :string
    field :data_type, :string
    field :report_filter, :map
    field :report_slug, :string
    field :job_id, :integer
    field :cursor, :string

    # top-level JSON array of remote_endpoint strings, or clue:<class_hash>:<uid> owner keys for the CLUE
    # data types; the audit page filters it with a pathless JSON_CONTAINS
    field :endpoint_set, ReportServer.Types.EctoJsonArray
    field :export_id, :string
    field :item_count, :integer

    belongs_to :user, User, foreign_key: :user_id
    belongs_to :report_run, ReportRun, foreign_key: :report_run_id

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc false
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [
      :event,
      :source,
      :data_type,
      :user_id,
      :report_run_id,
      :report_filter,
      :report_slug,
      :job_id,
      :cursor,
      :endpoint_set,
      :export_id,
      :item_count
    ])
    |> validate_required([:event, :source, :data_type, :user_id])
    |> validate_run_unless_runless_event()
    |> validate_inclusion(:event, [
      "download_url_issued",
      "export_scoped",
      "bulk_read",
      "attachment_urls_issued",
      "run_csv_streamed",
      "recent_logs_read"
    ])
    |> validate_inclusion(:source, ["web", "api"])
    |> validate_inclusion(:data_type, [
      "run_csv",
      "job_result",
      "answers_bulk",
      "history_bulk",
      "export_scoped",
      "attachment",
      "recent_logs"
      | ExportScratch.clue_data_types()
    ])
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:report_run_id)
  end

  @runless_events ["recent_logs_read"]

  defp validate_run_unless_runless_event(changeset) do
    if get_field(changeset, :event) in @runless_events,
      do: changeset,
      else: validate_required(changeset, [:report_run_id])
  end
end
