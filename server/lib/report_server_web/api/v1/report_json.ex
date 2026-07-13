defmodule ReportServerWeb.Api.V1.ReportJSON do
  alias ReportServer.AthenaDB
  alias ReportServer.Reports.{ReportFilter, ReportRun}
  alias ReportServerWeb.Api.V1.Params

  @id_dimensions [:cohort, :school, :teacher, :assignment, :class, :student, :permission_form, :country, :subject_area]

  def index(report_runs, limit) do
    %{
      items: Enum.map(report_runs, &run_json/1),
      next_page_token: next_page_token(report_runs, limit)
    }
  end

  def show(report_run), do: run_json(report_run)

  def download(download_url, filename) do
    %{download_url: download_url, filename: filename, expires_in_seconds: AthenaDB.download_url_ttl_seconds()}
  end

  defp next_page_token(report_runs, limit) when length(report_runs) < limit, do: nil
  defp next_page_token(report_runs, _limit), do: Params.encode_page_token(List.last(report_runs).id)

  defp run_json(report_run = %ReportRun{}) do
    %{
      id: report_run.id,
      report_slug: report_run.report_slug,
      report_filter: report_filter_json(report_run.report_filter),
      report_filter_values: report_run.report_filter_values || %{},
      athena_query_state: report_run.athena_query_state,
      inserted_at: DateTime.to_iso8601(report_run.inserted_at),
      updated_at: DateTime.to_iso8601(report_run.updated_at)
    }
  end

  def report_filter_json(nil), do: report_filter_json(%ReportFilter{})
  def report_filter_json(report_filter = %ReportFilter{}) do
    base = %{
      filters: Enum.map(report_filter.filters, &to_string/1),
      state: report_filter.state,
      start_date: presence(report_filter.start_date),
      end_date: presence(report_filter.end_date),
      hide_names: !!report_filter.hide_names,
      exclude_internal: !!report_filter.exclude_internal
    }

    Enum.reduce(@id_dimensions, base, fn dimension, acc ->
      Map.put(acc, dimension, Map.get(report_filter, dimension))
    end)
  end

  defp presence(""), do: nil
  defp presence(value), do: value
end
