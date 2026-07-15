defmodule ReportServerWeb.Api.V1.BulkParams do
  @default_limit 500
  # server max == default: `limit` can only LOWER the page cap. Kept at 500 (not higher) because a page's
  # JSON is only byte-guarded by the Node walker's response budget; 500 large report_state docs is what keeps
  # a page comfortably under the 10 MB gen1 response cap.
  @max_limit 500

  # Firestore Timestamp valid range (0001-01-01T00:00:00Z .. 9999-12-31T23:59:59Z). A history cursor whose
  # seconds is an integer but out of this range would make Node's new Timestamp(s,_) throw a RangeError.
  @ts_min_seconds -62_135_596_800
  @ts_max_seconds 253_402_300_799

  def parse_limit(params) do
    case Map.fetch(params, "limit") do
      :error ->
        {:ok, @default_limit}

      {:ok, v} when is_binary(v) ->
        case Integer.parse(v) do
          {n, ""} -> {:ok, n |> max(1) |> min(@max_limit)}
          _ -> {:error, :bad_request, "limit must be an integer"}
        end

      {:ok, _} ->
        {:error, :bad_request, "limit must be an integer"}
    end
  end

  # {:ok, nil} | {:ok, %{scratch_id, endpoint_index, inner_cursor}} | {:error, :bad_request, msg}
  def parse_page_token(params) do
    case Map.fetch(params, "page_token") do
      :error ->
        {:ok, nil}

      {:ok, token} when is_binary(token) ->
        with {:ok, json} <- Base.url_decode64(token, padding: false),
             {:ok, %{"s" => s, "i" => i} = decoded} when is_binary(s) and is_integer(i) and i >= 0 <-
               Jason.decode(json) do
          {:ok, %{scratch_id: s, endpoint_index: i, inner_cursor: Map.get(decoded, "c")}}
        else
          _ -> {:error, :bad_request, "page_token is not valid"}
        end

      {:ok, _} ->
        {:error, :bad_request, "page_token is not valid"}
    end
  end

  def encode_page_token(scratch_id, endpoint_index, inner_cursor) do
    %{"s" => scratch_id, "i" => endpoint_index, "c" => inner_cursor}
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  # inner-cursor shape/range validation. Elixir is the gate that produces the client-facing 400 (Node 4xx is
  # collapsed to 500 by the controller), so it must reject everything Firestore would throw on.
  def validate_inner_cursor(nil, _collection), do: :ok
  def validate_inner_cursor(%{"docId" => d}, "answers"), do: check_doc_id(d)

  def validate_inner_cursor(%{"seconds" => s, "nanoseconds" => n, "docId" => d}, "history")
      when is_integer(s) and s >= @ts_min_seconds and s <= @ts_max_seconds and
             is_integer(n) and n >= 0 and n <= 999_999_999,
      do: check_doc_id(d)

  def validate_inner_cursor(_, _), do: {:error, "inner_cursor is malformed for this route"}

  # A Firestore cursor docId must be a PLAIN document id: a non-empty binary with no "/". Otherwise Node's
  # startAfter(...) on a documentId ordering throws synchronously -> uncaught 500.
  defp check_doc_id(d) when is_binary(d) and d != "" do
    if String.contains?(d, "/"),
      do: {:error, "inner_cursor docId must be a plain document id (no '/')"},
      else: :ok
  end

  defp check_doc_id(_), do: {:error, "inner_cursor docId must be a non-empty plain document id"}
end
