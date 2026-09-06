defmodule ReportServer.Reports.AthenaFailure do
  @moduledoc """
  Bounding and interpreting the `StateChangeReason` Athena returns for a failed or cancelled query.
  """

  alias ReportServer.Reports.Report

  # An over-limit write to the 65,535-byte column raises rather than truncating, leaving the run
  # non-terminal. 4,000 is well above the longest reason seen, and the column's limit is in bytes.
  @max_reason_bytes 4_000
  @truncation_marker " ... (truncated)"

  # A reason carrying no colon is returned whole, so the code is bounded independently.
  @max_code_length 60

  # The wording is specified externally and must ship verbatim. It must never suggest narrowing:
  # Slowdown is an internal Athena condition that neither the researcher nor this server can act on.
  @slowdown "Your query was delayed due to high traffic in AWS Athena. Please try again in a few moments. This is a temporary issue caused by heavy usage."

  # `secure_key` is an injected projection column, so Athena expands the query's IN list into
  # partition values during planning and rejects the query outright once that list is too long.
  # Rejection happens before any data is read, which is why the advice here names the cohort alone:
  # a date range and an application both leave the IN list exactly as long as it was.
  @too_many_students "This report covers too many students for Athena to plan the query. Narrow the cohort, for example to fewer classes or assignments, and run it again."

  def max_reason_bytes, do: @max_reason_bytes

  @doc "Bounds a reason for storage or for a log line."
  def truncate(nil), do: nil
  def truncate(reason) when byte_size(reason) <= @max_reason_bytes, do: reason

  def truncate(reason) do
    keep = @max_reason_bytes - byte_size(@truncation_marker)
    <<prefix::binary-size(keep), _rest::binary>> = reason
    trim_to_valid(prefix) <> @truncation_marker
  end

  @doc """
  The leading error code of a reason, bounded, for use in logs.

  Only the code, never the message after it: Athena's message can echo the query, and the queries
  this server generates embed secure keys and learner endpoint urls. The code is the part an
  operator acts on, and the query id logged beside it retrieves the full reason from Athena.
  """
  def error_code(nil), do: nil

  def error_code(reason) do
    reason
    |> String.split(":", parts: 2)
    |> hd()
    |> String.trim()
    |> String.slice(0, @max_code_length)
  end

  @doc """
  The one-line suggestion for a recognized reason, or nil. Advice to narrow by application is
  included only when the run's report offers that filter.
  """
  def guidance_for(report, reason)
  def guidance_for(_report, nil), do: nil

  def guidance_for(report, reason) do
    downcased = String.downcase(reason)

    report
    |> offers_app_filter?()
    |> guidance()
    |> Enum.find_value(fn {pattern, advice} -> String.contains?(downcased, pattern) && advice end)
  end

  # Reports without the filter carry no such key, and the default reads that as false.
  def offers_app_filter?(%Report{form_options: form_options}) do
    Keyword.get(form_options, :enable_app_filter, false)
  end

  def offers_app_filter?(_report), do: false

  @doc """
  The reason-to-suggestion table, ordered, first match wins.

  Patterns are lowercase because `guidance_for/2` downcases the reason: S3 spells its throttling code
  `SlowDown` while Athena spells the generic condition `Slowdown`. `hive_s3_throttling` must precede
  `slowdown`, which its reason also carries, because the two have deliberately opposite advice.

  Two patterns match message wording rather than an error code. `injected projected partition column`
  is matched instead of the `CONSTRAINT_VIOLATION` code that carries it, because that code covers
  unrelated failures whose fix is not a smaller cohort, and `query timeout` has no code at all. AWS
  rewording either one costs the suggestion, not the raw reason, which is always shown.
  """
  def guidance(app_filter?) do
    narrowing = narrowing(app_filter?)

    [
      {"hive_exceeded_partition_limit",
       "This query covers too many Athena partitions. Narrow it with #{narrowing} and run it again."},
      {"injected projected partition column", @too_many_students},
      {"hive_s3_throttling",
       "AWS throttled this query. Narrowing it with #{narrowing} will help, and running it outside peak hours will too."},
      {"query timeout",
       "This query ran out of time. Narrow it with #{narrowing} and consider running it outside peak hours."},
      {"slowdown", @slowdown}
    ]
  end

  defp narrowing(true), do: "a date range or one or more applications"
  defp narrowing(false), do: "a date range"

  # The prefix can split a codepoint, so step back until it is valid UTF-8.
  defp trim_to_valid(binary) do
    if String.valid?(binary) do
      binary
    else
      trim_to_valid(binary_part(binary, 0, byte_size(binary) - 1))
    end
  end
end
