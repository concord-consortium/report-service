defmodule ReportServer.RecentLogs do
  @moduledoc """
  The class-scoped recent-logs read over `logs_by_hour` (server README, "Querying recent logs"):
  its window, its cursor, its SQL and the rows it answers. The window starts at 00:00 UTC of the
  day before the query's date; the day before that is the last one left to the nightly copy, so
  a `student-actions` run ending on it and these rows meet at `window_start`.
  """

  alias ReportServer.Reports.ReportQuery

  @columns ~w(id session application activity event event_value time parameters extras run_remote_endpoint timestamp user_id primary_user_id)
  @integer_columns ~w(time timestamp user_id primary_user_id)
  @cursor_version "v1"
  # 13 digits (year 2286): DateTime can still render the padded `dt` hour, and Athena's bigint holds it
  @max_ms 9_999_999_999_999
  @bound_pattern ~r/\A[0-9]{1,#{length(Integer.digits(@max_ms))}}\z/

  def columns, do: @columns

  @doc "`window_start` in epoch ms and `nightly_through` as a Date, for a query made at `now_ms`."
  def window(now_ms) do
    today = now_ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_date()
    start = DateTime.new!(Date.add(today, -1), ~T[00:00:00], "Etc/UTC")
    %{window_start: DateTime.to_unix(start, :millisecond), nightly_through: Date.add(today, -2)}
  end

  @doc "The opaque cursor for a read made at `query_started_at` (ms): its `since` is that minus the settle margin."
  def next_cursor(class_id, query_started_at, settle_ms) do
    payload = Jason.encode!(%{"c" => class_id, "s" => query_started_at - settle_ms})
    @cursor_version <> "." <> Base.url_encode64(payload, padding: false)
  end

  @doc """
  The bounds a request reads, `{:ok, %{since: ms, until: ms | nil}}`, from its `cursor`, `start`
  and `end` parameters. Nothing reads before `window_start`.
  """
  def bounds(params, class_id, %{window_start: window_start}) do
    case {params["cursor"], params["start"], params["end"]} do
      {nil, start, finish} -> explicit_bounds(start, finish, window_start)
      {cursor, nil, nil} -> cursor_bounds(cursor, class_id, window_start)
      _ -> {:error, :cursor_with_bounds}
    end
  end

  defp explicit_bounds(start, finish, window_start) do
    with {:ok, since} <- bound(start, window_start),
         {:ok, until} <- bound(finish, nil),
         :ok <- inside_window(since, until, window_start) do
      {:ok, %{since: since, until: until}}
    end
  end

  defp bound(nil, default), do: {:ok, default}

  defp bound(value, _default) when is_binary(value) do
    if Regex.match?(@bound_pattern, value), do: {:ok, String.to_integer(value)}, else: {:error, :bad_bound}
  end

  defp bound(_, _), do: {:error, :bad_bound}

  defp inside_window(since, until, window_start) do
    cond do
      since < window_start -> {:error, :bad_bound}
      until != nil and until <= since -> {:error, :bad_bound}
      true -> :ok
    end
  end

  defp cursor_bounds(cursor, class_id, window_start) when is_binary(cursor) do
    with [@cursor_version, encoded] <- String.split(cursor, ".", parts: 2),
         {:ok, json} <- Base.url_decode64(encoded, padding: false),
         {:ok, %{"c" => ^class_id, "s" => since}} when is_integer(since) and since <= @max_ms <- Jason.decode(json) do
      if since < window_start, do: {:error, :expired_cursor}, else: {:ok, %{since: since, until: nil}}
    else
      _ -> {:error, :bad_cursor}
    end
  end

  defp cursor_bounds(_, _, _), do: {:error, :bad_cursor}

  @doc "The `dt` range for `since`..`until`: an hour of padding on each side (conventions 1 and 3)."
  def dt_predicate(%{since: since, until: until}) do
    lower = "log.dt >= '#{dt_hour(since, -3600)}'"
    if until, do: "#{lower} AND log.dt <= '#{dt_hour(until, 3600)}'", else: lower
  end

  defp dt_hour(ms, shift) do
    ms |> DateTime.from_unix!(:millisecond) |> DateTime.add(shift) |> Calendar.strftime("%Y/%m/%d/%H")
  end

  @doc """
  The Athena SQL for `learners` (maps with `run_remote_endpoint`, `user_id`, `primary_user_id`)
  within `bounds`: the 13 columns ordered by `timestamp` then `id`. The learners are an inline
  `VALUES` table rather than the uploaded `learners` table, so a read writes nothing to S3.
  """
  def sql(learners, bounds = %{since: since, until: until}) when learners != [] do
    log_db = ReportQuery.get_log_db_name()
    until_predicate = if until, do: "\n  AND log.timestamp < #{until}", else: ""

    cols = ReportQuery.get_log_cols(remove_username: true) ++ ReportQuery.get_minimal_learner_cols()

    """
    SELECT #{Enum.map_join(cols, ", ", fn {col, name} -> "#{col} AS #{name}" end)}
    FROM "#{log_db}"."logs_by_hour" log
    JOIN (VALUES #{Enum.map_join(learners, ", ", &learner_value/1)})
      AS learner (run_remote_endpoint, user_id, primary_user_id)
      ON learner.run_remote_endpoint = log.run_remote_endpoint
    WHERE #{dt_predicate(bounds)}
      AND log.timestamp >= #{since}#{until_predicate}
    ORDER BY log.timestamp, log.id
    """
  end

  defp learner_value(%{run_remote_endpoint: ep, user_id: user_id, primary_user_id: primary}) do
    "('#{String.replace(ep, "'", "''")}', #{integer!(user_id)}, #{integer!(primary)})"
  end

  defp integer!(value) when is_integer(value), do: value

  @doc """
  One CSV row (a header-keyed map, as `CSV.decode(headers: true)` gives it) as the route answers
  it: an ordered object, so it encodes in the `student-actions` column order. A plain map of 13
  keys encodes in key order.
  """
  def row(csv_row) do
    Jason.OrderedObject.new(Enum.map(@columns, fn col -> {col, typed(col, Map.fetch!(csv_row, col))} end))
  end

  defp typed(_col, ""), do: nil
  defp typed(col, value) when col in @integer_columns, do: String.to_integer(value)
  defp typed(_col, value), do: value
end
