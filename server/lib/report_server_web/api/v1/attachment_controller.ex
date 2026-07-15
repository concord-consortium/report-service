defmodule ReportServerWeb.Api.V1.AttachmentController do
  use ReportServerWeb, :controller

  alias ReportServer.AuditLog
  alias ReportServer.Reports
  alias ReportServerWeb.{Aws, TokenService}
  alias ReportServerWeb.Api.ErrorHelpers
  alias ReportServerWeb.Api.V1.{AttachmentJSON, BulkParams, EndpointSet, Params}

  def create(conn, params) do
    user = conn.assigns.current_user

    with {:ok, report_run_id} <- Params.parse_id(params["id"]),
         {:ok, disposition} <- BulkParams.parse_disposition(params["disposition"]),
         {:ok, items} <- BulkParams.parse_attachment_items(params["attachments"]),
         {:ok, report_run} <- Reports.get_api_report_run(user, report_run_id),
         {:ok, endpoint_set} <- EndpointSet.derive_endpoint_set(user, report_run),
         {:ok, %{"results" => metas}} <- report_service_client().fetch_attachment_meta(%{items: items}),
         :ok <- validate_meta_count(metas, items) do
      allowed = MapSet.new(endpoint_set, & &1["remote_endpoint"])
      signed = Enum.zip(items, metas) |> Enum.map(&sign_one(&1, allowed, disposition))
      results = Enum.map(signed, &elem(&1, 0))
      # distinct learners ACTUALLY signed -> the audit endpoint_set (the public results omit remote_endpoint)
      endpoints = signed |> Enum.flat_map(fn {_r, re} -> List.wrap(re) end) |> Enum.uniq()

      # fail-CLOSED: the audit result GATES the response. no-store so no proxy/cache retains the credential-free URLs.
      case AuditLog.log_attachment_urls(user, report_run, endpoints) do
        {:ok, _} ->
          conn
          |> put_resp_header("cache-control", "no-store")
          |> json(AttachmentJSON.results(results, Aws.presign_ttl_seconds()))

        {:error, _} ->
          ErrorHelpers.server_error(conn)
      end
    else
      {:error, :bad_request, msg} -> ErrorHelpers.bad_request(conn, msg)
      {:error, :not_found} -> ErrorHelpers.not_found(conn)
      {:error, _} -> ErrorHelpers.server_error(conn)
    end
  end

  # Node returns exactly one result per item, positionally. A length mismatch is a Node-contract violation -> 500.
  defp validate_meta_count(metas, items) when length(metas) == length(items), do: :ok
  defp validate_meta_count(_metas, _items), do: {:error, :meta_count_mismatch}

  # per-item, partial-success. Returns {public_result_map, signed_endpoint | nil}.
  defp sign_one({item, %{"meta" => nil}}, _allowed, _disposition),
    do: {%{doc_id: item["doc_id"], name: item["name"], error: "not_found"}, nil}

  defp sign_one({item, %{"meta" => %{"remote_endpoint" => re, "publicPath" => key, "contentType" => ct}}}, allowed, disposition) do
    # authorize on the DOC's learner (re); re == nil (out-of-scope/anonymous) -> not_authorized. NOT folder.ownerId.
    if re != nil and MapSet.member?(allowed, re) do
      s3_url = "s3://#{TokenService.get_private_bucket()}/#{key}"

      case Aws.presign_server_get(s3_url, name: item["name"], disposition: disposition, content_type: ct) do
        {:ok, url} -> {%{doc_id: item["doc_id"], name: item["name"], url: url}, re}
        {:error, _} -> {%{doc_id: item["doc_id"], name: item["name"], error: "not_found"}, nil}
      end
    else
      {%{doc_id: item["doc_id"], name: item["name"], error: "not_authorized"}, nil}
    end
  end

  defp report_service_client,
    do: Application.get_env(:report_server, :report_service_client, ReportServer.ReportService)
end
