defmodule ReportServer.AuditLog do
  import Ecto.Query, warn: false

  require Logger

  alias ReportServer.Pagination
  alias ReportServer.Repo
  alias ReportServer.AuditLog.DataAccessLogEntry
  alias ReportServer.Reports.ReportRun

  @doc """
  Fail-closed download-URL issuance, in the order pinned by the requirements:
  1. presign (via `presign_fun`) — on failure return {:error, :presign, reason}, write no row
  2. write the audit row — on failure discard the URL and return {:error, :audit, reason}
  3. only then return {:ok, url}
  """
  def issue_download_url(source, data_type, report_run = %ReportRun{}, user_id, presign_fun, opts \\ []) do
    case presign_fun.() do
      {:ok, url} ->
        attrs = %{
          event: "download_url_issued",
          source: source,
          data_type: data_type,
          user_id: user_id,
          report_run_id: report_run.id,
          report_slug: report_run.report_slug,
          report_filter: dump_filter(report_run.report_filter),
          job_id: Keyword.get(opts, :job_id)
        }

        case create_entry(attrs) do
          {:ok, _entry} ->
            {:ok, url}

          {:error, reason} ->
            Logger.error("Audit write failed for report run #{report_run.id}: #{inspect(reason)}")
            {:error, :audit, reason}
        end

      {:error, reason} ->
        {:error, :presign, reason}
    end
  end

  def create_entry(attrs) do
    %DataAccessLogEntry{}
    |> DataAccessLogEntry.changeset(attrs)
    |> Repo.insert()
  end

  def list_entries_paginated(page) do
    from(e in DataAccessLogEntry, order_by: [desc: e.inserted_at, desc: e.id], preload: [:user])
    |> Pagination.paginate(page)
  end

  defp dump_filter(nil), do: nil
  defp dump_filter(report_filter), do: Map.from_struct(report_filter)
end
