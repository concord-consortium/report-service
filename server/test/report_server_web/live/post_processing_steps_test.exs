defmodule ReportServerWeb.ReportLive.PostProcessingStepsTest do
  use ExUnit.Case, async: true

  alias ReportServer.Reports.{ReportFilter, ReportRun}
  alias ReportServerWeb.ReportLive.PostProcessingComponent

  defp step_ids(slug, report_filter) do
    %ReportRun{report_slug: slug, report_filter: report_filter}
    |> PostProcessingComponent.steps_for_run()
    |> Enum.map(& &1.id)
    |> Enum.sort()
  end

  @all_answers_steps ["glossary_data", "has_audio", "merge_to_primary_user", "transcribe_audio"]

  test "a student answers run offers every details step by default" do
    assert step_ids("student-answers", %ReportFilter{}) == @all_answers_steps
  end

  test "a run without the open response link column offers no audio step" do
    assert step_ids("student-answers", %ReportFilter{remove_open_response_urls: true}) ==
             ["glossary_data", "merge_to_primary_user"]
  end

  test "a run stored without a filter offers every details step" do
    assert step_ids("student-answers", nil) == @all_answers_steps
  end

  test "the option leaves another report's steps alone" do
    steps = step_ids("student-actions", %ReportFilter{})
    assert steps != []

    assert step_ids("student-actions", %ReportFilter{remove_open_response_urls: true}) == steps
  end
end
