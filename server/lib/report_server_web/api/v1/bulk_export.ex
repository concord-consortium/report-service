defmodule ReportServerWeb.Api.V1.BulkExport do
  @moduledoc """
  Page helpers shared by the paged bulk export controllers: the no-store headers, the audit row
  attributes, the empty export, the frozen scratch row and the page-token lookup, which hands the serve
  function the raw page token the access row records.
  """
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias ReportServer.{AuditLog, Exports}
  alias ReportServerWeb.Api.ErrorHelpers
  alias ReportServerWeb.Api.V1.BulkParams

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

  @doc """
  An export with nothing in scope: a terminal empty page with no scratch to resume, after its intent row,
  fail-closed like every other audit write. The export id is minted so the row is correlatable.
  """
  def empty_page(conn, user, report_run, data_type) do
    export_id = Exports.mint_scratch_id()
    intent_attrs = audit_attrs(user, report_run, "export_scoped", data_type, export_id, nil, [])

    case AuditLog.create_entry(intent_attrs) do
      {:ok, _entry} -> json(conn, %{items: [], next_page_token: nil, total_endpoints: 0})
      {:error, _reason} -> ErrorHelpers.server_error(conn)
    end
  end

  @doc """
  Freezes an export's endpoint set in a new scratch row together with its intent row, both or neither.
  `audit_keys` are what the intent row names. Returns {:ok, scratch} | :error.
  """
  def freeze(user, report_run, data_type, endpoint_set, audit_keys) do
    scratch_id = Exports.mint_scratch_id()

    scratch_attrs = %{
      scratch_id: scratch_id,
      report_run_id: report_run.id,
      user_id: user.id,
      data_type: data_type,
      endpoint_set: endpoint_set,
      expires_at: Exports.ttl_expires_at()
    }

    intent_attrs = audit_attrs(user, report_run, "export_scoped", data_type, scratch_id, nil, audit_keys)

    case Exports.create_scratch_with_intent(scratch_attrs, intent_attrs) do
      {:ok, %{scratch: scratch}} -> {:ok, scratch}
      {:error, _step, _changeset, _} -> :error
    end
  end

  @doc """
  Resolves a page token: the two-step scratch lookup (404, or 410 once expired) and the checks on its index
  and on its inner cursor for `collection` (400). On success calls `serve.(scratch, raw_page_token)`.
  """
  def with_page_scratch(conn, user, report_run_id, data_type, collection, scratch_id, idx, inner, serve) do
    case Exports.fetch_for_page(scratch_id, user.id, report_run_id, data_type) do
      :not_found ->
        ErrorHelpers.not_found(conn)

      :expired ->
        ErrorHelpers.render_error(conn, "EXPIRED_CURSOR",
          "The export cursor has expired; restart the export from a null page_token.")

      {:ok, scratch} ->
        cond do
          idx < 0 or idx >= length(scratch.endpoint_set) ->
            ErrorHelpers.bad_request(conn, "page_token endpoint index out of range")

          BulkParams.validate_inner_cursor(inner, collection) != :ok ->
            ErrorHelpers.bad_request(conn, "inner_cursor is malformed for this route")

          true ->
            serve.(scratch, raw_page_token(conn))
        end
    end
  end

  defp raw_page_token(conn), do: conn.query_params["page_token"]
end
