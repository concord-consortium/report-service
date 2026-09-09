defmodule ReportServer.Reports.FilterValidation do
  @moduledoc """
  The rules a report filter must satisfy before a run is created from it. Not authorization:
  `HideNames` and the report queries' project scoping own that.

  `validate/2` is the set both the web form and the API apply. `check_no_empty_selections/1` is
  applied by the API only, and is public rather than folded in so that stays a decision someone
  made rather than an omission: a half-filled filter row is a live editing state in the form,
  where the submit gate already prevents the common case, and a finished request over the API.
  """

  alias ReportServer.Reports.Athena.AthenaConfig
  alias ReportServer.Reports.{AthenaFailure, FilterOptions, Report, ReportFilter}

  def validate(report_filter = %ReportFilter{}, report = %Report{}) do
    with :ok <- check_app_supported(report_filter, report) do
      check_dimensions_offered(report_filter, report)
    end
  end

  # `[]` narrows a filter-options request to nothing and constrains a run to nothing, because the
  # report queries gate every dimension on have_filter?/1. Accepting it would answer a request to
  # select nothing with a run over everything the caller can see.
  def check_no_empty_selections(report_filter = %ReportFilter{}) do
    case Enum.filter(ReportFilter.dimensions(), &(Map.get(report_filter, &1) == [])) do
      [] -> :ok
      empty -> {:error, :invalid, "no values selected for: #{Enum.join(empty, ", ")}"}
    end
  end

  # The dates are interpolated raw into the portal statement by apply_start_date/3, so nothing
  # downstream can make an unparseable one safe. Applied by the API parser and again by the context
  # function, because a duplicate is built from a stored filter and skips the parser.
  def check_dates(report_filter = %ReportFilter{}) do
    dates = [start_date: report_filter.start_date, end_date: report_filter.end_date]

    case Enum.reject(dates, &valid_date?/1) do
      [] ->
        :ok

      bad ->
        {:error, :invalid,
         "#{Enum.map_join(bad, ", ", fn {key, _value} -> key end)} must be an ISO 8601 date (YYYY-MM-DD)"}
    end
  end

  defp valid_date?({_key, value}) when value in [nil, ""], do: true
  defp valid_date?({_key, value}) when is_binary(value), do: match?({:ok, _}, Date.from_iso8601(value))
  defp valid_date?(_date), do: false

  @doc """
  Whether the filter expresses any constraint at all, which is what an Athena create is judged by
  because its report's query builder is not affordable in a request.

  `hide_names` and `exclude_internal` are modifiers rather than constraints: neither narrows
  anything on its own, and `exclude_internal` contributes no clause at all when the portal has no
  Concord schools.
  """
  def check_constrains_anything(report_filter = %ReportFilter{}) do
    dimensions = Enum.any?(ReportFilter.dimensions(), &(Map.get(report_filter, &1) not in [nil, []]))
    dates = Enum.any?([report_filter.start_date, report_filter.end_date], &(to_string(&1) != ""))

    if dimensions or dates or ReportFilter.app_list(report_filter.app) != [] do
      :ok
    else
      {:error, :invalid, "a filter must name at least one dimension, date or application"}
    end
  end

  def check_app_supported(%ReportFilter{app: app}, report = %Report{}) do
    case ReportFilter.app_list(app) do
      [] ->
        :ok

      apps ->
        if AthenaFailure.offers_app_filter?(report) do
          check_apps_known(apps)
        else
          {:error, :invalid, "This report does not support an application filter."}
        end
    end
  end

  # get_athena_query/3 rejects an unknown value too, but only after the report has run the portal
  # join and uploaded the learner data, so the researcher sees a failed run instead of a form error
  def check_apps_known(apps) do
    case Enum.reject(apps, &(&1 in AthenaConfig.get_log_apps())) do
      [] -> :ok
      unknown -> {:error, :invalid, "Unknown application#{if length(unknown) > 1, do: "s"}: #{Enum.join(unknown, ", ")}"}
    end
  end

  def check_dimensions_offered(report_filter = %ReportFilter{}, report = %Report{}) do
    selected = Enum.filter(ReportFilter.dimensions(), &(Map.get(report_filter, &1) != nil))

    case Enum.reject(selected, &offered?(&1, report)) do
      [] -> :ok
      unoffered -> {:error, :invalid, "This report does not filter on: #{Enum.join(unoffered, ", ")}"}
    end
  end

  @doc "Whether `report` offers `dimension` at all, static dimensions included."
  def offered?(dimension, report = %Report{}) do
    case FilterOptions.static_dimension(dimension) do
      {:ok, module} -> module.enabled_for_report?(report)
      :error -> dimension in report.include_filters
    end
  end
end
