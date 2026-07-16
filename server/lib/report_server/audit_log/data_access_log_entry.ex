defmodule ReportServer.AuditLog.DataAccessLogEntry do
  use Ecto.Schema

  import Ecto.Changeset

  alias ReportServer.Accounts.User
  alias ReportServer.Reports.ReportRun

  schema "data_access_log" do
    field :event, :string
    field :source, :string
    field :data_type, :string
    field :report_filter, :map
    field :report_slug, :string
    field :job_id, :integer
    field :cursor, :string

    # custom type (top-level JSON array of remote_endpoint strings); pathless JSON_CONTAINS filter unchanged
    field :endpoint_set, ReportServer.Types.EctoJsonArray
    field :export_id, :string

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
      :export_id
    ])
    |> validate_required([:event, :source, :data_type, :user_id, :report_run_id])
    |> validate_inclusion(:event, [
      "download_url_issued",
      "export_scoped",
      "bulk_read",
      "attachment_urls_issued"
    ])
    |> validate_inclusion(:source, ["web", "api"])
    |> validate_inclusion(:data_type, [
      "run_csv",
      "job_result",
      "answers_bulk",
      "history_bulk",
      "export_scoped",
      "attachment"
    ])
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:report_run_id)
  end
end
