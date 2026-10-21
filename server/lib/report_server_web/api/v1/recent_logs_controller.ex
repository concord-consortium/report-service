defmodule ReportServerWeb.Api.V1.RecentLogsController do
  @moduledoc """
  A class's recent log rows, read from `logs_by_hour` as the caller.
  """
  use ReportServerWeb, :controller

  require Logger

  alias ReportServer.{AthenaDB, AthenaQueryPoller, PortalDownloadLimiter, RecentLogs}
  alias ReportServer.RecentLogs.Access
  alias ReportServerWeb.Api.ErrorHelpers

  @rows_per_chunk 500

  def preflight(conn, _params), do: send_resp(conn, 204, "")

  def show(conn, params) do
    # one instant for the window, the bounds check and `query_started_at`, so the envelope
    # describes a single day even when the portal lookups cross 00:00 UTC
    now = clock().()
    window = RecentLogs.window(now)

    with {:ok, class_id} <- class_id(params["class_id"]),
         {:ok, bounds} <- RecentLogs.bounds(params, class_id, window),
         {:ok, user} <- Access.caller(conn, class_id),
         {:ok, learners} <- Access.learners(user, class_id) do
      envelope = [
        class_id: class_id,
        window_start: window.window_start,
        nightly_through: Date.to_iso8601(window.nightly_through),
        since: bounds.since,
        until: bounds.until,
        query_started_at: now
      ]

      answer(conn, user, learners, bounds, envelope)
    else
      {:error, :bad_class} -> ErrorHelpers.bad_request(conn, "class_id must be a positive integer.")
      {:error, :cursor_with_bounds} -> ErrorHelpers.bad_request(conn, "A cursor cannot be combined with start or end.")
      {:error, :bad_bound} -> ErrorHelpers.bad_request(conn, "start and end must be epoch milliseconds at or after #{window.window_start} (00:00 UTC yesterday), with end after start; read earlier days with a Student Actions run.")
      {:error, :bad_cursor} -> ErrorHelpers.bad_request(conn, "The cursor is not valid for this class.")
      {:error, :expired_cursor} -> ErrorHelpers.render_error(conn, "EXPIRED_CURSOR", "The cursor is older than the recent window (#{window.window_start}); start again without one, and read the days before it with a Student Actions run.")
      {:error, :forbidden} -> ErrorHelpers.render_error(conn, "FORBIDDEN", "You may not read this class's logs.")
      {:error, :not_authenticated} -> ErrorHelpers.not_authenticated(conn)
      {:error, :portal_unavailable} -> ErrorHelpers.service_unavailable(conn, "The portal could not be asked; retry shortly.")
    end
  end

  defp class_id(value) when is_binary(value) do
    if Regex.match?(~r/\A[1-9][0-9]{0,17}\z/, value), do: {:ok, String.to_integer(value)}, else: {:error, :bad_class}
  end

  defp class_id(_), do: {:error, :bad_class}

  defp answer(conn, _user, [], bounds, envelope) do
    body = envelope ++ [rows: [], count: 0, latest_timestamp: nil, next_cursor: next_cursor(envelope, bounds)]

    json(conn, Jason.OrderedObject.new(body))
  end

  defp answer(conn, user, learners, bounds, envelope) do
    case PortalDownloadLimiter.try_acquire(ReportServer.RecentLogsLimiter) do
      :full ->
        ErrorHelpers.service_unavailable(conn, "Too many recent-log reads; retry shortly.")

      :ok ->
        try do
          query_and_answer(conn, user, learners, bounds, envelope)
        after
          PortalDownloadLimiter.release(ReportServer.RecentLogsLimiter)
        end
    end
  end

  defp query_and_answer(conn, user, learners, bounds, envelope) do
    too_large = AthenaDB.query_too_large_error()

    with {:ok, query_id, _state} <- athena_db().query(RecentLogs.sql(learners, bounds), UUID.uuid4(), user),
         {:ok, location} <- wait_for(query_id),
         {:ok, stream} <- aws_file_store().get_file_stream(location) do
      rows_answer(conn, user, learners, stream, bounds, envelope)
    else
      {:error, ^too_large} ->
        ErrorHelpers.unprocessable(conn, "This class has too many learners for one recent-logs query.")

      {:error, {:athena_query, query_id, reason}} ->
        Logger.error("Recent-logs Athena query #{query_id} did not finish: #{inspect(reason)}")
        ErrorHelpers.service_unavailable(conn, "The logs could not be read; retry shortly.")

      {:error, reason} ->
        Logger.error("Recent-logs read failed: #{inspect(reason)}")
        ErrorHelpers.service_unavailable(conn, "The logs could not be read; retry shortly.")
    end
  end

  defp wait_for(query_id) do
    case AthenaQueryPoller.wait_for(query_id, timeout_ms: config(:timeout_ms), interval_ms: config(:poll_interval_ms)) do
      {:ok, location} -> {:ok, location}
      {:error, reason} -> {:error, {:athena_query, query_id, reason}}
    end
  end

  defp rows_answer(conn, user, learners, stream, bounds, envelope) do
    endpoints = Enum.map(learners, & &1.run_remote_endpoint)

    case audit_log().log_recent_logs_read(user, envelope[:class_id], bounds.since, endpoints) do
      {:error, reason} ->
        Logger.error("Recent-logs audit write failed: #{inspect(reason)}")
        ErrorHelpers.server_error(conn)

      {:ok, _entry} ->
        opening = envelope |> Jason.OrderedObject.new() |> Jason.encode!() |> String.trim_trailing("}")
        conn = conn |> put_resp_content_type("application/json") |> send_chunked(200)
        {:ok, conn} = chunk(conn, opening <> ~s(,"rows":[))

        {conn, count, latest} = stream_rows(conn, stream)

        closing = [count: count, latest_timestamp: latest, next_cursor: next_cursor(envelope, bounds)]
        closing_json = closing |> Jason.OrderedObject.new() |> Jason.encode!() |> String.trim_leading("{")
        {:ok, conn} = chunk(conn, "]," <> closing_json)
        conn
    end
  end

  defp stream_rows(conn, stream) do
    stream
    |> decode()
    |> Stream.map(&RecentLogs.row/1)
    |> Stream.chunk_every(@rows_per_chunk)
    |> Enum.reduce({conn, 0, nil}, fn rows, {conn, count, latest} ->
      prefix = if count == 0, do: "", else: ","
      {:ok, conn} = chunk(conn, prefix <> Enum.map_join(rows, ",", &Jason.encode!/1))
      batch_latest = rows |> Enum.map(fn row -> row["timestamp"] end) |> Enum.reject(&is_nil/1) |> Enum.max(fn -> nil end)
      {conn, count + length(rows), max_timestamp(latest, batch_latest)}
    end)
  rescue
    error ->
      Logger.error("Recent-logs stream failed after the first chunk: #{Exception.message(error)}")
      reraise error, __STACKTRACE__
  end

  defp max_timestamp(nil, b), do: b
  defp max_timestamp(a, nil), do: a
  defp max_timestamp(a, b), do: max(a, b)

  defp decode(stream) do
    stream
    |> CSV.decode(headers: true, validate_row_length: true)
    |> Stream.map(fn
      {:ok, row} -> row
      {:error, message} -> raise "unreadable Athena result: #{message}"
    end)
  end

  defp next_cursor(_envelope, %{until: until}) when until != nil, do: nil

  defp next_cursor(envelope, _bounds),
    do: RecentLogs.next_cursor(envelope[:class_id], envelope[:query_started_at], config(:settle_ms))

  defp config(key), do: Application.get_env(:report_server, :recent_logs) |> Keyword.fetch!(key)

  defp clock, do: Application.get_env(:report_server, :recent_logs_clock, fn -> System.system_time(:millisecond) end)
  defp athena_db, do: Application.get_env(:report_server, :athena_db, AthenaDB)
  defp aws_file_store, do: Application.get_env(:report_server, :aws_file_store, ReportServerWeb.Aws)
  defp audit_log, do: Application.get_env(:report_server, :audit_log, ReportServer.AuditLog)
end
