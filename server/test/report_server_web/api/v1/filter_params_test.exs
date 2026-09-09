defmodule ReportServerWeb.Api.V1.FilterParamsTest do
  use ExUnit.Case, async: true

  alias ReportServer.Reports.{ReportFilter, ReportUtils}
  alias ReportServerWeb.Api.V1.FilterParams

  describe "the whole filter" do
    test "an absent object is the empty filter" do
      assert FilterParams.parse(nil) == {:ok, %ReportFilter{}}
    end

    test "a non-object is a client error" do
      assert {:error, message} = FilterParams.parse("cohort=1")
      assert message =~ "report_filter must be an object"
    end

    test "a client-supplied filters list never reaches the struct" do
      assert {:ok, filter} = FilterParams.parse(%{"filters" => ["cohort"], "cohort" => [1]})
      assert filter.filters == []
    end
  end

  describe "dimensions" do
    test "ids are parsed, and null and [] stay apart" do
      assert {:ok, filter} = FilterParams.parse(%{"cohort" => [1, "2"], "school" => [], "class" => nil})

      assert filter.cohort == [1, 2]
      assert filter.school == []
      assert filter.class == nil
    end

    test "the state dimension takes strings and the rest take ids" do
      assert {:ok, %ReportFilter{state: ["NH"]}} = FilterParams.parse(%{"state" => ["NH"]})
      assert {:error, message} = FilterParams.parse(%{"state" => [5]})
      assert message =~ "state values must be strings"

      assert {:error, message} = FilterParams.parse(%{"cohort" => ["abc"]})
      assert message =~ "cohort values must be integer ids"
    end
  end

  describe "the dates" do
    test "a valid ISO date round-trips" do
      assert {:ok, %ReportFilter{start_date: "2026-01-01", end_date: "2026-02-01"}} =
               FilterParams.parse(%{"start_date" => "2026-01-01", "end_date" => "2026-02-01"})
    end

    test "an empty string is absent, matching what a blank control submits" do
      assert {:ok, %ReportFilter{start_date: nil, end_date: nil}} =
               FilterParams.parse(%{"start_date" => "", "end_date" => ""})
    end

    test "a payload that would be interpolated into the portal statement is rejected" do
      payload = "2026-01-01' OR '1'='1"

      assert {:error, message} = FilterParams.parse(%{"start_date" => payload})
      assert message =~ "start_date must be an ISO 8601 date"

      # and the statement builder refuses it too, so no stored run can carry one into SQL
      assert_raise ArgumentError, fn -> ReportUtils.apply_start_date([], payload) end
    end

    test "a non-string date is rejected" do
      assert {:error, message} = FilterParams.parse(%{"end_date" => 20_260_101})
      assert message =~ "end_date must be a string"
    end
  end

  describe "app" do
    test "a list of strings is carried" do
      assert {:ok, %ReportFilter{app: ["CODAP", "AP"]}} =
               FilterParams.parse(%{"app" => ["CODAP", "AP"]})
    end

    test "an absent app is nil and an empty list is carried as itself" do
      assert {:ok, %ReportFilter{app: nil}} = FilterParams.parse(%{})
      assert {:ok, %ReportFilter{app: []}} = FilterParams.parse(%{"app" => []})
    end

    test "a non-list and a non-string member are both client errors" do
      assert {:error, message} = FilterParams.parse(%{"app" => "CODAP"})
      assert message =~ "app must be a list or null"

      assert {:error, message} = FilterParams.parse(%{"app" => ["CODAP", 7]})
      assert message =~ "app values must be strings"
    end
  end

  describe "the booleans" do
    test "hide_names and exclude_internal are carried" do
      assert {:ok, %ReportFilter{hide_names: true, exclude_internal: true}} =
               FilterParams.parse(%{"hide_names" => true, "exclude_internal" => true})

      assert {:ok, %ReportFilter{hide_names: false, exclude_internal: false}} = FilterParams.parse(%{})
    end

    test "anything but a boolean is a client error" do
      assert {:error, message} = FilterParams.parse(%{"hide_names" => "true"})
      assert message =~ "hide_names must be true or false"

      assert {:error, message} = FilterParams.parse(%{"exclude_internal" => 1})
      assert message =~ "exclude_internal must be true or false"
    end
  end
end
