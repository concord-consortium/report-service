defmodule ReportServer.Reports.FilterValidationTest do
  use ExUnit.Case, async: true

  alias ReportServer.Reports.{FilterValidation, ReportFilter, Tree}
  alias ReportServer.Reports.Athena.AthenaConfig

  defp report(slug), do: Tree.find_report(slug)

  # student-actions offers the application filter and the seven person-bearing dimensions;
  # school-metrics offers neither the filter nor any of them.
  defp app_report, do: report("student-actions")
  defp taxonomy_report, do: report("school-metrics")

  defp known_app, do: AthenaConfig.get_log_apps() |> List.first()

  describe "check_app_supported/2" do
    test "a known application on a report that offers the filter" do
      assert FilterValidation.check_app_supported(%ReportFilter{app: [known_app()]}, app_report()) == :ok
    end

    test "an unknown application is rejected" do
      assert {:error, :invalid, message} =
               FilterValidation.check_app_supported(%ReportFilter{app: ["NOPE"]}, app_report())

      assert message =~ "Unknown application: NOPE"
    end

    test "two unknown applications are both named" do
      assert {:error, :invalid, message} =
               FilterValidation.check_app_supported(%ReportFilter{app: ["NOPE", "ALSO"]}, app_report())

      assert message =~ "Unknown applications: NOPE, ALSO"
    end

    test "a known application on a report without the filter is rejected" do
      assert {:error, :invalid, message} =
               FilterValidation.check_app_supported(%ReportFilter{app: [known_app()]}, taxonomy_report())

      assert message =~ "does not support an application filter"
    end

    test "no application is accepted on every report" do
      assert FilterValidation.check_app_supported(%ReportFilter{}, taxonomy_report()) == :ok
      assert FilterValidation.check_app_supported(%ReportFilter{app: []}, taxonomy_report()) == :ok
    end
  end

  describe "check_dimensions_offered/2" do
    test "a dimension the report offers" do
      assert FilterValidation.check_dimensions_offered(%ReportFilter{cohort: [1]}, app_report()) == :ok
    end

    test "a dimension the report does not offer is named" do
      assert {:error, :invalid, message} =
               FilterValidation.check_dimensions_offered(%ReportFilter{country: [1]}, app_report())

      assert message =~ "does not filter on: country"
    end

    test "a dimension set to an empty list still has to be offered" do
      assert {:error, :invalid, _message} =
               FilterValidation.check_dimensions_offered(%ReportFilter{country: []}, app_report())
    end

    test "an unset dimension is not a selection" do
      assert FilterValidation.check_dimensions_offered(%ReportFilter{country: nil}, app_report()) == :ok
    end
  end

  describe "offered?/2" do
    test "a static dimension is judged by its own module" do
      assert FilterValidation.offered?(:app, app_report())
      refute FilterValidation.offered?(:app, taxonomy_report())
    end

    test "a portal dimension is judged by the report's include_filters" do
      assert FilterValidation.offered?(:cohort, app_report())
      refute FilterValidation.offered?(:cohort, taxonomy_report())
      assert FilterValidation.offered?(:country, taxonomy_report())
    end
  end

  describe "validate/2" do
    test "applies both rules" do
      assert FilterValidation.validate(%ReportFilter{cohort: [1], app: [known_app()]}, app_report()) == :ok

      assert {:error, :invalid, _} =
               FilterValidation.validate(%ReportFilter{app: ["NOPE"]}, app_report())

      assert {:error, :invalid, _} =
               FilterValidation.validate(%ReportFilter{country: [1]}, app_report())
    end

    test "does not reject an empty value list, which is the API's rule alone" do
      assert FilterValidation.validate(%ReportFilter{cohort: []}, app_report()) == :ok
    end
  end

  describe "check_no_empty_selections/1" do
    test "an empty list is rejected and named" do
      assert {:error, :invalid, message} =
               FilterValidation.check_no_empty_selections(%ReportFilter{cohort: []})

      assert message =~ "no values selected for: cohort"
    end

    test "every empty dimension is named in one message" do
      assert {:error, :invalid, message} =
               FilterValidation.check_no_empty_selections(%ReportFilter{cohort: [], school: []})

      assert message =~ "no values selected for: cohort, school"
    end

    test "an unset dimension and a filled one are both accepted" do
      assert FilterValidation.check_no_empty_selections(%ReportFilter{cohort: nil}) == :ok
      assert FilterValidation.check_no_empty_selections(%ReportFilter{cohort: [1]}) == :ok
    end
  end

  describe "check_dates/1" do
    test "an ISO date, a nil and an empty string are accepted" do
      assert FilterValidation.check_dates(%ReportFilter{start_date: "2026-01-01"}) == :ok
      assert FilterValidation.check_dates(%ReportFilter{start_date: nil, end_date: nil}) == :ok
      assert FilterValidation.check_dates(%ReportFilter{start_date: "", end_date: ""}) == :ok
    end

    test "a payload that would reach the portal statement is rejected" do
      assert {:error, :invalid, message} =
               FilterValidation.check_dates(%ReportFilter{start_date: "2026-01-01' OR '1'='1"})

      assert message =~ "start_date must be an ISO 8601 date"
    end

    test "a non-string date is rejected" do
      assert {:error, :invalid, _} = FilterValidation.check_dates(%ReportFilter{start_date: 20_260_101})
    end

    test "both bad dates are named in one message" do
      assert {:error, :invalid, message} =
               FilterValidation.check_dates(%ReportFilter{start_date: "nope", end_date: "also"})

      assert message =~ "start_date, end_date must be an ISO 8601 date"
    end
  end

  describe "check_constrains_anything/1" do
    test "an empty filter constrains nothing" do
      assert {:error, :invalid, message} = FilterValidation.check_constrains_anything(%ReportFilter{})
      assert message =~ "at least one dimension, date or application"
    end

    test "the modifiers are not constraints" do
      assert {:error, :invalid, _} =
               FilterValidation.check_constrains_anything(%ReportFilter{hide_names: true})

      assert {:error, :invalid, _} =
               FilterValidation.check_constrains_anything(%ReportFilter{exclude_internal: true})
    end

    test "a dimension, a date or an application each constrain" do
      assert FilterValidation.check_constrains_anything(%ReportFilter{cohort: [1]}) == :ok
      assert FilterValidation.check_constrains_anything(%ReportFilter{start_date: "2026-01-01"}) == :ok
      assert FilterValidation.check_constrains_anything(%ReportFilter{end_date: "2026-01-01"}) == :ok
      assert FilterValidation.check_constrains_anything(%ReportFilter{app: ["CODAP"]}) == :ok
    end

    test "a dimension selecting nothing constrains nothing" do
      assert {:error, :invalid, _} = FilterValidation.check_constrains_anything(%ReportFilter{cohort: []})
    end
  end
end
