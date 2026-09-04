defmodule ReportServer.Reports.PartitionEstimate do
  @moduledoc """
  Projects how many Athena partitions a log report would need to probe.

  A log query is constrained by the `app`, `year`, `month` and `secure_key` partitions, so every
  learner expands across each combination the remaining partitions still admit. Left unconstrained
  that is 15 applications over 444 (year, month) pairs, or 6,660 prefixes per learner, which reaches
  Athena's limit at 151 learners.
  """

  alias ReportServer.Reports.Athena.AthenaConfig
  alias ReportServer.Reports.ReportQuery

  # Athena refuses a query that could touch more than this many partitions. The warning threshold
  # below is policy and defaults to it by reference, so the number appears once.
  @athena_partition_limit 1_000_000

  def athena_partition_limit, do: @athena_partition_limit

  def warning_threshold do
    Application.get_env(:report_server, :partition_warning_threshold) || @athena_partition_limit
  end

  @doc """
  The number of (year, month) pairs the emitted date predicate admits.

  This is not `years * months`: a range that does not start in January and end in December admits
  fewer pairs than that product, and for a multi-year range the product is negative.
  """
  def period_months(start_date, end_date) do
    years = AthenaConfig.get_log_projection_years()
    months = AthenaConfig.get_log_projection_months()

    {start_year, start_month} = to_ym(start_date, {years.first, months.first})
    {end_year, end_month} = to_ym(end_date, {years.last, months.last})

    max(end_year * 12 + end_month - (start_year * 12 + start_month) + 1, 0)
  end

  def projected_partitions(learner_count, app, start_date, end_date) do
    learner_count * app_count(app) * period_months(start_date, end_date)
  end

  @doc """
  How many applications a query must probe: every projected one unless the filter names one.
  """
  # derived from the list, never a literal, so adding an application cannot leave the estimate low
  def app_count(app) when app in [nil, ""], do: length(AthenaConfig.get_log_apps())
  def app_count(_app), do: 1

  # an absent or unparseable bound falls back to the projection's edge, so a half-open range runs to it
  defp to_ym(bound, default) do
    case ReportQuery.normalize_date(bound) do
      {:ok, date} -> {date.year, date.month}
      _ -> default
    end
  end
end
