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
  def issue_download_url(
        source,
        data_type,
        report_run = %ReportRun{},
        user_id,
        presign_fun,
        opts \\ []
      ) do
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

  @doc """
  One fail-closed row per attachment-presign call. `endpoints` are the distinct remote_endpoints actually
  signed. Returns create_entry/1's {:ok, _} | {:error, _} so the controller can gate the response on it.
  """
  def log_attachment_urls(_user = %{id: user_id}, report_run = %ReportRun{}, endpoints) do
    create_entry(%{
      event: "attachment_urls_issued",
      source: "api",
      data_type: "attachment",
      user_id: user_id,
      report_run_id: report_run.id,
      report_slug: report_run.report_slug,
      report_filter: dump_filter(report_run.report_filter),
      cursor: nil,
      export_id: nil,
      endpoint_set: endpoints
    })
  end

  def create_entry(attrs) do
    %DataAccessLogEntry{}
    |> DataAccessLogEntry.changeset(attrs)
    |> Repo.insert()
  end

  def list_entries_paginated(page, filters \\ %{}) do
    from(e in DataAccessLogEntry, order_by: [desc: e.inserted_at, desc: e.id], preload: [:user])
    |> filter_by_export_id(filters[:export_id])
    |> filter_by_remote_endpoint(filters[:remote_endpoint])
    |> Pagination.paginate(page)
  end

  defp filter_by_export_id(query, nil), do: query
  defp filter_by_export_id(query, ""), do: query
  defp filter_by_export_id(query, export_id), do: from(e in query, where: e.export_id == ^export_id)

  defp filter_by_remote_endpoint(query, nil), do: query
  defp filter_by_remote_endpoint(query, ""), do: query

  defp filter_by_remote_endpoint(query, remote_endpoint) do
    # pathless JSON_CONTAINS over the top-level array; BOUND param (never interpolated). Intentionally
    # case-sensitive (JSON binary comparison) for exact secure_key matching. NULL endpoint_set is unmatched.
    from(e in query, where: fragment("JSON_CONTAINS(endpoint_set, JSON_QUOTE(?))", ^remote_endpoint))
  end

  def dump_filter(nil), do: nil
  def dump_filter(report_filter), do: Map.from_struct(report_filter)
end
