defmodule ReportServer.ReportFilterTest do
  use ExUnit.Case, async: true

  alias ReportServer.Reports.ReportFilter

  defp from_params(params, filter_index \\ 0),
    do: ReportFilter.from_form(Phoenix.Component.to_form(params, as: "filter_form"), filter_index)

  describe "app_list/1" do
    test "treats every shape of unset as no applications" do
      for unset <- [nil, "", []] do
        assert ReportFilter.app_list(unset) == []
      end
    end

    test "is identity on its own empty list" do
      assert ReportFilter.app_list([]) == []
    end

    test "keeps a selection in order" do
      assert ReportFilter.app_list(["CLUE", "Dataflow"]) == ["CLUE", "Dataflow"]
    end

    test "drops the empty entries a select can submit alongside real ones" do
      assert ReportFilter.app_list(["", "CLUE", ""]) == ["CLUE"]
    end

    test "wraps a bare string, which is how a run stored before multi-select reads back" do
      assert ReportFilter.app_list("CLUE") == ["CLUE"]
    end
  end

  describe "from_form/2" do
    test "carries a selected application across" do
      assert from_params(%{"app" => "CLUE"}).app == "CLUE"
    end

    test "carries the empty string an unselected control submits" do
      assert from_params(%{"app" => ""}).app == ""
    end

    test "leaves the application nil when the control was never rendered" do
      assert from_params(%{}).app == nil
    end

    test "the application does not become a numbered filter" do
      assert from_params(%{"app" => "CLUE"}).filters == []
    end

    test "a filter row with no type chosen is skipped rather than parsed" do
      filter = from_params(%{"filter1_type" => "cohort", "filter1" => ["1"], "filter2_type" => "", "filter2" => ["2"]}, 2)

      assert filter.cohort == [1]
      assert filter.filters == [:cohort]
    end

    test "a state row keeps its codes while an id row is parsed to integers" do
      filter = from_params(%{"filter1_type" => "state", "filter1" => ["NH"], "filter2_type" => "school", "filter2" => ["51"]}, 2)

      assert filter.state == ["NH"]
      assert filter.school == [51]
    end

    test "the other scalars still cross the bridge" do
      filter =
        from_params(%{
          "start_date" => "2024-09-01",
          "end_date" => "2025-06-30",
          "hide_names" => "true"
        })

      assert filter.start_date == "2024-09-01"
      assert filter.end_date == "2025-06-30"
      assert filter.hide_names
    end
  end
end
