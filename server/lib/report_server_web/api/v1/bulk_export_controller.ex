defmodule ReportServerWeb.Api.V1.BulkExportController do
  use ReportServerWeb, :controller

  require Logger

  alias ReportServer.{AuditLog, Exports}
  alias ReportServerWeb.Api.ErrorHelpers
  alias ReportServerWeb.Api.V1.{BulkExport, BulkParams, EndpointSet, Params}
  alias ReportServer.Reports

  @endpoint_limit 250
  @read_limit 5000

  def answers(conn, params), do: serve(conn, params, "answers_bulk", "answers")
  def history(conn, params), do: serve(conn, params, "history_bulk", "history")

  defp serve(conn, %{"id" => id_param} = params, data_type, collection) do
    user = conn.assigns.current_user

    with {:ok, id} <- Params.parse_id(id_param),
         {:ok, report_run} <- Reports.get_api_report_run(user, id),
         {:ok, limit} <- BulkParams.parse_limit(params),
         {:ok, token} <- BulkParams.parse_page_token(params) do
      conn = BulkExport.put_no_store(conn)

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
        BulkExport.empty_page(conn, user, report_run, data_type)

      {:ok, endpoints} ->
        case BulkExport.freeze(user, report_run, data_type, endpoints, Enum.map(endpoints, & &1["remote_endpoint"])) do
          {:ok, scratch} -> serve_page(conn, user, report_run, scratch, collection, data_type, 0, nil, limit, nil)
          :error -> ErrorHelpers.server_error(conn)
        end

      {:error, :not_learner_derivable} ->
        ErrorHelpers.unprocessable(conn, "This report does not support per-learner endpoints.")

      {:error, _reason} ->
        ErrorHelpers.server_error(conn)
    end
  end

  # ---- page N: two-step scratch lookup (404 vs 410), bounds-check index + inner cursor, serve ----
  defp next_page(conn, user, report_run, id, data_type, collection, limit, scratch_id, idx, inner) do
    BulkExport.with_page_scratch(conn, user, id, data_type, collection, scratch_id, idx, inner, fn scratch, raw_token ->
      serve_page(conn, user, report_run, scratch, collection, data_type, idx, inner, limit, raw_token)
    end)
  end

  # ---- shared: slice from index, call Node, reassemble cursor, write the fail-closed access row, return envelope ----
  defp serve_page(conn, user, report_run, scratch, collection, data_type, index, inner, limit, raw_token) do
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

    slice_length = length(slice)

    case report_service().bulk_read(req) do
      # Semantics guard on top of the shape match: an out-of-range offset or non-boolean exhausted would
      # silently mis-advance (or truncate) the cursor; such a response falls through to {:ok, unexpected}.
      {:ok, %{"items" => items, "stop_endpoint_offset" => off, "inner_cursor" => next_inner,
              "endpoint_exhausted" => exhausted, "touched_endpoints" => touched}}
      when is_list(items) and is_boolean(exhausted) and is_integer(off) and off >= 0 and
             off < slice_length ->
        Exports.merge_touched_endpoints(scratch, touched)

        {next_index, next_cursor} =
          if exhausted, do: {index + off + 1, nil}, else: {index + off, next_inner}

        next_token =
          if next_index >= length(endpoints),
            do: nil,
            else: BulkParams.encode_page_token(scratch.scratch_id, next_index, next_cursor)

        served = items |> Enum.map(& &1["remote_endpoint"]) |> Enum.uniq()

        access_attrs =
          BulkExport.audit_attrs(user, report_run, "bulk_read", data_type, scratch.scratch_id, raw_token, served)

        case AuditLog.create_entry(access_attrs) do
          {:ok, _entry} -> json(conn, %{items: items, next_page_token: next_token, total_endpoints: length(endpoints)})
          {:error, _reason} -> ErrorHelpers.server_error(conn)
        end

      {:ok, unexpected} ->
        # Node returned success with an unexpected body shape (contract violation) -> fail closed, don't crash.
        Logger.error("bulk_read returned an unexpected body shape: #{inspect(unexpected)}")
        ErrorHelpers.server_error(conn)

      {:error, _reason} ->
        # Node read failure (or a collapsed Node 4xx from a hand-crafted cursor Elixir already pre-validates):
        # no audit row, no cursor advance; the CLI retries the same token idempotently.
        ErrorHelpers.server_error(conn)
    end
  end

  defp report_service,
    do: Application.get_env(:report_server, :report_service_client, ReportServer.ReportService)
end
