defmodule ReportServerWeb.Api.V1.ClueExportController do
  @moduledoc """
  Pages a report run's CLUE documents, document history and document content out of CLUE's own
  project through its `clueExport` function. Authorization and paging are the bulk export's; the scope
  is the run's CLUE scope owners, derived and frozen on the first page.
  """
  use ReportServerWeb, :controller

  require Logger

  alias ReportServer.{AuditLog, Clue}
  alias ReportServer.Clue.Scope
  alias ReportServer.Exports.ExportScratch
  alias ReportServer.Reports
  alias ReportServerWeb.Api.ErrorHelpers
  alias ReportServerWeb.Api.V1.{BulkExport, BulkParams, EndpointSet, Params}

  @owner_limit 250
  @read_limit 5000

  @data_types Map.new(Enum.zip(["documents", "history", "content"], ExportScratch.clue_data_types()))

  def documents(conn, params), do: serve(conn, params, @data_types["documents"], "documents")
  def history(conn, params), do: serve(conn, params, @data_types["history"], "history")
  def content(conn, params), do: serve(conn, params, @data_types["content"], "content")

  defp serve(conn, %{"id" => id_param} = params, data_type, operation) do
    user = conn.assigns.current_user

    with {:ok, id} <- Params.parse_id(id_param),
         {:ok, report_run} <- Reports.get_api_report_run(user, id),
         {:ok, limit} <- BulkParams.parse_limit(params),
         {:ok, token} <- BulkParams.parse_page_token(params),
         :ok <- ensure_configured(user) do
      conn = BulkExport.put_no_store(conn)

      case token do
        nil ->
          first_page(conn, user, report_run, data_type, operation, limit)

        %{scratch_id: sid, endpoint_index: idx, inner_cursor: inner} ->
          next_page(conn, user, report_run, id, data_type, operation, limit, sid, idx, inner)
      end
    else
      {:error, :not_found} -> ErrorHelpers.not_found(conn)
      {:error, :bad_request, msg} -> ErrorHelpers.bad_request(conn, msg)
      {:error, :not_configured} -> ErrorHelpers.service_unavailable(conn, "CLUE export is not configured for this portal.")
    end
  end

  defp ensure_configured(user) do
    if clue_export().url_for(user.portal_server), do: :ok, else: {:error, :not_configured}
  end

  defp first_page(conn, user, report_run, data_type, operation, limit) do
    with {:ok, learners} <- EndpointSet.fetch_learners(user, report_run),
         {:ok, owners} <- derive_owners(user, learners) do
      if owners == [] do
        BulkExport.empty_page(conn, user, report_run, data_type)
      else
        freeze_and_serve(conn, user, report_run, data_type, operation, limit, owners)
      end
    else
      {:error, :not_learner_derivable} ->
        ErrorHelpers.unprocessable(conn, "This report does not support per-learner endpoints.")

      {:error, _reason} ->
        ErrorHelpers.server_error(conn)
    end
  end

  defp derive_owners(user, learners) do
    clue_learners = Enum.filter(learners, &Clue.writes_clue_documents?(&1.runnable_url))
    class_ids = clue_learners |> Enum.map(& &1.class_id) |> Enum.uniq()

    with {:ok, hashes} <- class_hashes().fetch(user.portal_server, class_ids) do
      case Scope.student_owners(clue_learners, hashes) do
        [] ->
          {:ok, []}

        students ->
          class_owners = students |> Scope.class_owners() |> Scope.order()

          with {:ok, groups} <- fetch_groups(user.portal_server, class_owners) do
            {:ok, Scope.order(students ++ class_owners ++ Scope.group_owners(groups, class_owners))}
          end
      end
    end
  end

  defp fetch_groups(portal, class_owners) do
    class_owners
    |> Scope.classes()
    |> Enum.chunk_every(@owner_limit)
    |> Enum.reduce_while({:ok, []}, fn chunk, {:ok, acc} ->
      with {:ok, answer} <- clue_export().call(portal, %{operation: "owners", portal: portal, classes: chunk}),
           {:ok, groups} <- valid_groups(answer, chunk) do
        {:cont, {:ok, acc ++ groups}}
      else
        {:error, reason} ->
          Logger.error("clueExport owners failed: #{inspect(reason)}")
          {:halt, {:error, :owners_failed}}
      end
    end)
  end

  defp valid_groups(%{"groups" => groups}, chunk) when is_list(groups) do
    offerings = Map.new(chunk, &{&1["class_hash"], &1["offerings"]})

    if Enum.all?(groups, &valid_group?(&1, offerings)),
      do: {:ok, groups},
      else: {:error, "an owners answer names a class, offering or group outside its request"}
  end

  defp valid_groups(_answer, _chunk), do: {:error, "an owners answer has no groups list"}

  defp valid_group?(%{"class_hash" => hash, "uid" => uid, "offering" => offering}, offerings)
       when is_binary(uid) and is_integer(offering) do
    offering in Map.get(offerings, hash, []) and String.starts_with?(uid, "group_#{offering}_")
  end

  defp valid_group?(_group, _offerings), do: false

  defp freeze_and_serve(conn, user, report_run, data_type, operation, limit, owners) do
    case BulkExport.freeze(user, report_run, data_type, owners, Enum.map(owners, &Scope.key/1)) do
      {:ok, scratch} -> serve_page(conn, user, report_run, scratch, operation, data_type, 0, nil, limit, nil)
      :error -> ErrorHelpers.server_error(conn)
    end
  end

  defp next_page(conn, user, report_run, id, data_type, operation, limit, scratch_id, idx, inner) do
    BulkExport.with_page_scratch(conn, user, id, data_type, "clue_" <> operation, scratch_id, idx, inner, fn scratch, raw_token ->
      serve_page(conn, user, report_run, scratch, operation, data_type, idx, inner, limit, raw_token)
    end)
  end

  defp serve_page(conn, user, report_run, scratch, operation, data_type, index, inner, limit, raw_token) do
    owners = scratch.endpoint_set
    slice = owners |> Enum.drop(index) |> Enum.take(@owner_limit)

    req = %{
      operation: operation,
      portal: user.portal_server,
      owners: slice,
      inner_cursor: inner,
      limit: limit,
      owner_limit: @owner_limit,
      read_limit: @read_limit
    }

    case clue_export().call(user.portal_server, req) do
      {:ok, %{"items" => items, "stop_owner_offset" => off, "inner_cursor" => next_inner,
              "owner_exhausted" => exhausted, "served_owner_offsets" => served} = body}
      when is_list(items) and is_boolean(exhausted) and is_integer(off) and off >= 0 and
             off < length(slice) and is_list(served) ->
        # an offset the function cannot have reached, or a cursor the next request would refuse, must not become a token
        if valid_offsets?(served, off, items) and valid_next_cursor?(exhausted, next_inner, operation) do
          {next_index, next_cursor} =
            if exhausted, do: {index + off + 1, nil}, else: {index + off, next_inner}

          next_token =
            if next_index >= length(owners),
              do: nil,
              else: BulkParams.encode_page_token(scratch.scratch_id, next_index, next_cursor)

          served_keys = served |> Enum.uniq() |> Enum.map(&Scope.key(Enum.at(slice, &1)))

          access_attrs =
            BulkExport.audit_attrs(user, report_run, "bulk_read", data_type, scratch.scratch_id, raw_token,
              served_keys, length(items))

          case AuditLog.create_entry(access_attrs) do
            {:ok, _entry} -> json(conn, %{items: items, next_page_token: next_token, total_endpoints: length(owners)})
            {:error, _reason} -> ErrorHelpers.server_error(conn)
          end
        else
          log_unexpected(body)
          ErrorHelpers.server_error(conn)
        end

      {:ok, unexpected} ->
        log_unexpected(unexpected)
        ErrorHelpers.server_error(conn)

      {:error, reason} ->
        Logger.error("clueExport #{operation} failed: #{inspect(reason)}")
        ErrorHelpers.server_error(conn)
    end
  end

  # a page with items names at least one owner, so its audit row is never ownerless
  defp valid_offsets?(served, off, items),
    do: (items == [] or served != []) and Enum.all?(served, &(is_integer(&1) and &1 >= 0 and &1 <= off))

  defp valid_next_cursor?(true, nil, _operation), do: true
  defp valid_next_cursor?(false, next_inner, operation) when is_map(next_inner),
    do: BulkParams.validate_inner_cursor(next_inner, "clue_" <> operation) == :ok

  defp valid_next_cursor?(_exhausted, _next_inner, _operation), do: false

  # the items are student work, so only the shape is logged
  defp log_unexpected(body),
    do: Logger.error("clueExport returned an unexpected page: keys #{inspect(Map.keys(body))}, stop_owner_offset #{inspect(body["stop_owner_offset"])}")

  defp clue_export, do: Application.get_env(:report_server, :clue_export_client, ReportServer.ClueExport)

  defp class_hashes, do: Application.get_env(:report_server, :clue_class_hashes, ReportServer.Clue.ClassHashes)
end
