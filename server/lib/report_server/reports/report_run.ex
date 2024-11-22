defmodule ReportServer.Reports.ReportRun do
  use Ecto.Schema

  import Ecto.Changeset

  alias ReportServer.Accounts.User
  alias ReportServer.Types.EctoReportFilter

  schema "report_runs" do
    field :report_slug, :string
    field :report_filter, EctoReportFilter
    field :report_filter_values, :map
    field :athena_query_id, :string
    field :athena_query_state, :string
    field :athena_result_url, :string

    belongs_to :user, User, foreign_key: :user_id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(report_run, attrs) do
    report_run
    |> cast(attrs, [:user_id, :report_slug, :report_filter, :report_filter_values, :athena_query_id, :athena_query_state, :athena_result_url])
    |> validate_required([:user_id, :report_slug])
  end
end
