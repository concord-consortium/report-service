defmodule ReportServer.Reports.TreeTest do
  use ExUnit.Case, async: true

  alias ReportServer.Reports.Report
  alias ReportServer.Reports.Tree
  alias ReportServer.Reports.Tree.ReportGroup

  @learner_narrowing ~w(cohort school teacher assignment class student permission_form)a

  defp all_reports(%Report{} = report), do: [report]
  defp all_reports(%ReportGroup{children: children}), do: Enum.flat_map(children, &all_reports/1)

  test "every report with no learner-narrowing include_filters is marked derives_learner_data: false" do
    Tree.root()
    |> all_reports()
    |> Enum.each(fn report ->
      if Enum.all?(@learner_narrowing, &(&1 not in report.include_filters)) do
        assert report.derives_learner_data == false,
               "#{report.slug} has no learner-narrowing filter but is not derives_learner_data: false"
      end
    end)
  end
end
