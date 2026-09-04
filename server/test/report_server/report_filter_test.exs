defmodule ReportServer.ReportFilterTest do
  use ExUnit.Case, async: true

  alias ReportServer.Reports.ReportFilter

  defp from_params(params),
    do: ReportFilter.from_form(Phoenix.Component.to_form(params, as: "filter_form"), 0)

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
