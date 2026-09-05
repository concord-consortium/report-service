defmodule ReportServer.Reports.TreeTest do
  use ExUnit.Case, async: true

  alias ReportServer.Reports.Report
  alias ReportServer.Reports.Tree
  alias ReportServer.Reports.Tree.ReportGroup

  @learner_narrowing ~w(cohort school teacher assignment class student permission_form)a

  defp all_reports(%Report{} = report), do: [report]
  defp all_reports(%ReportGroup{children: children}), do: Enum.flat_map(children, &all_reports/1)

  defp offers_app_filter?(%Report{form_options: form_options}),
    do: Keyword.get(form_options, :enable_app_filter, false)

  # both the form's gating and the guidance a failed run shows read this key with a `false` default,
  # so renaming it disables them silently rather than breaking anything
  test "the application filter option is spelled the way the reports that offer it spell it" do
    offering =
      Tree.root() |> all_reports() |> Enum.filter(&offers_app_filter?/1) |> Enum.map(& &1.slug)

    assert offering != [], "no report offers :enable_app_filter; has the option been renamed?"
    assert "student-actions" in offering
  end

  test "the portal student reports do not offer the application filter" do
    for slug <- ["student-id-mapping", "student-metadata"] do
      report = Tree.find_report(slug)

      assert report.type == :portal
      refute offers_app_filter?(report),
             "#{slug} queries the portal, where the log table's app partition has no meaning"
    end
  end

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
