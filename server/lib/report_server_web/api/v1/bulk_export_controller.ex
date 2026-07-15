defmodule ReportServerWeb.Api.V1.BulkExportController do
  use ReportServerWeb, :controller

  require Logger

  alias ReportServer.{AuditLog, Exports}
  alias ReportServerWeb.Api.ErrorHelpers
  alias ReportServerWeb.Api.V1.{BulkParams, EndpointSet, Params}
  alias ReportServer.Reports

  @endpoint_limit 250
  @read_limit 5000

  def answers(conn, params), do: serve(conn, params, "answers_bulk", "answers")

  # /history lands in the next step; until then it 404s (never a 500)
  def history(conn, _params), do: ErrorHelpers.not_found(conn)

  defp serve(conn, %{"id" => id_param} = params, data_type, collection) do
    user = conn.assigns.current_user

    with {:ok, id} <- Params.parse_id(id_param),
         {:ok, report_run} <- Reports.get_api_report_run(user, id),
         {:ok, limit} <- BulkParams.parse_limit(params),
         {:ok, token} <- BulkParams.parse_page_token(params) do
      conn = put_no_store(conn)

      case token do
        nil ->
          first_page(conn, user, report_run, data_type, collection, limit)

        %{scratch_id: sid, endpoint_index: idx, inner_cursor: inner} ->
          next_page(conn, user, report_run, id, data_type, collection, limit, sid, idx, inner)
      end
    else
      {:error, :not_found} -> ErrorHelpers.not_found(conn)
      {:error, :bad_request, msg} -> ErrorHelpers.bad_request(conn, msg)
    end
  end

  # ---- page 1: derive-once, mint scratch + intent row atomically, serve from index 0 / null cursor ----
  defp first_page(conn, user, report_run, data_type, collection, limit) do
    case EndpointSet.derive_endpoint_set(user, report_run) do
      {:ok, []} ->
        # empty export: terminal empty page, no scratch to resume — but still record the intent row for audit
        # completeness, fail-closed like every other audit write. export_id is minted so the row is correlatable.
        export_id = Exports.mint_scratch_id()
        intent_attrs = audit_attrs(user, report_run, "export_scoped", "export_scoped", export_id, nil, [])

        case AuditLog.create_entry(intent_attrs) do
          {:ok, _entry} -> json(conn, %{items: [], next_page_token: nil})
          {:error, _reason} -> ErrorHelpers.server_error(conn)
        end

      {:ok, endpoints} ->
        scratch_id = Exports.mint_scratch_id()

        scratch_attrs = %{
          scratch_id: scratch_id,
          report_run_id: report_run.id,
          user_id: user.id,
          data_type: data_type,
          endpoint_set: endpoints,
          expires_at: Exports.ttl_expires_at()
        }

        intent_attrs =
          audit_attrs(user, report_run, "export_scoped", "export_scoped", scratch_id, nil,
            Enum.map(endpoints, & &1["remote_endpoint"]))

        case Exports.create_scratch_with_intent(scratch_attrs, intent_attrs) do
          {:ok, %{scratch: scratch}} ->
            serve_page(conn, user, report_run, scratch, collection, data_type, 0, nil, limit, nil)

          {:error, _step, _changeset, _} ->
            ErrorHelpers.server_error(conn)
        end

      {:error, _reason} ->
        ErrorHelpers.server_error(conn)
    end
  end

  # ---- page N: two-step scratch lookup (404 vs 410), bounds-check index + inner cursor, serve ----
  defp next_page(conn, user, report_run, id, data_type, collection, limit, scratch_id, idx, inner) do
    case Exports.fetch_for_page(scratch_id, user.id, id, data_type) do
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
            raw_token = raw_page_token(conn)
            serve_page(conn, user, report_run, scratch, collection, data_type, idx, inner, limit, raw_token)
        end
    end
  end

  # ---- shared: slice from index, call Node, reassemble cursor, return envelope (per-page audit in next step) ----
  defp serve_page(conn, _user, _report_run, scratch, collection, _data_type, index, inner, limit, _raw_token) do
    endpoints = scratch.endpoint_set
    slice = Enum.drop(endpoints, index)

    req = %{
      collection: collection,
      source_endpoints: slice,
      inner_cursor: inner,
      limit: limit,
      endpoint_limit: @endpoint_limit,
      read_limit: @read_limit
    }

    case report_service().bulk_read(req) do
      {:ok, %{"items" => items, "stop_endpoint_offset" => off, "inner_cursor" => next_inner,
              "endpoint_exhausted" => exhausted, "touched_endpoints" => touched}} ->
        Exports.merge_touched_endpoints(scratch, touched)

        {next_index, next_cursor} =
          if exhausted, do: {index + off + 1, nil}, else: {index + off, next_inner}

        next_token =
          if next_index >= length(endpoints),
            do: nil,
            else: BulkParams.encode_page_token(scratch.scratch_id, next_index, next_cursor)

        # NOTE: per-page audit access row is added in the next step (fail-closed, before returning)
        json(conn, %{items: items, next_page_token: next_token})

      {:error, _reason} ->
        # Node read failure (or a collapsed Node 4xx from a hand-crafted cursor Elixir already pre-validates):
        # no audit row, no cursor advance; the CLI retries the same token idempotently.
        ErrorHelpers.server_error(conn)
    end
  end

  defp audit_attrs(user, report_run, event, data_type, export_id, cursor, endpoint_set) do
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
      endpoint_set: endpoint_set
    }
  end

  defp put_no_store(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("pragma", "no-cache")
  end

  defp raw_page_token(conn), do: conn.query_params["page_token"]

  defp report_service,
    do: Application.get_env(:report_server, :report_service_client, ReportServer.ReportService)
end
