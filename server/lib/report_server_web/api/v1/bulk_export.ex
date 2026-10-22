defmodule ReportServerWeb.Api.V1.BulkExport do
  @moduledoc """
  Page helpers shared by the paged bulk export controllers: the no-store headers, the audit row
  attributes and the raw page token the access row records.
  """
  import Plug.Conn

  alias ReportServer.AuditLog

  def put_no_store(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("pragma", "no-cache")
  end

  def audit_attrs(user, report_run, event, data_type, export_id, cursor, endpoint_set, item_count \\ nil) do
    %{
      event: event,
      source: "api",
      data_type: data_type,
      user_id: user.id,
      report_run_id: report_run.id,
      report_slug: report_run.report_slug,
      report_filter: AuditLog.dump_filter(report_run.report_filter),
      cursor: cursor,
      export_id: export_id,
      endpoint_set: endpoint_set,
      item_count: item_count
    }
  end

  def raw_page_token(conn), do: conn.query_params["page_token"]
end
