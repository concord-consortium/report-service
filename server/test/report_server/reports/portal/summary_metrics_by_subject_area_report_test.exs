defmodule ReportServer.Reports.Portal.SummaryMetricsBySubjectAreaReportTest do
  use ExUnit.Case, async: true
  alias ReportServer.Reports.{ReportFilter, ReportQuery}
  alias ReportServer.Reports.Portal.SummaryMetricsBySubjectAreaReport
  alias ReportServer.Accounts.User

  def normalized_sql({:ok, query = %ReportQuery{}}) do
    {:ok, sql} = ReportQuery.get_sql(query)
    sql |> String.replace(~r/\s+/, " ") |> String.trim()
  end

  def test_user do
    %User{portal_server: "portal.example.com"}
  end

  describe "get_query/2 basic structure" do
    test "constructs basic query with scope filter" do
      report_filter = %ReportFilter{
        country: nil,
        state: nil,
        subject_area: nil,
        exclude_internal: false,
        start_date: nil,
        end_date: nil
      }

      query = SummaryMetricsBySubjectAreaReport.get_query(report_filter, test_user())
      sql = normalized_sql(query)

      # Verify basic structure
      assert String.contains?(sql, "SELECT")
      assert String.contains?(sql, "FROM admin_tags at")
      assert String.contains?(sql, "GROUP BY at.id")
      assert String.contains?(sql, "ORDER BY subject_area asc")

      # Always includes scope filter
      assert String.contains?(sql, "at.scope = 'subject_areas'")

      # Verify all expected columns are present
      assert String.contains?(sql, "trim(at.tag) AS subject_area")
      assert String.contains?(sql, "count(distinct ps.country_id) AS number_of_countries")
      assert String.contains?(sql, "count(distinct ps.state) AS number_of_states")
      assert String.contains?(sql, "count(distinct ps.id) AS number_of_schools")
      assert String.contains?(sql, "count(distinct pt.id) AS number_of_teachers")
      assert String.contains?(sql, "count(distinct po_class.id) AS number_of_classes")
      assert String.contains?(sql, "count(distinct coalesce(stu.primary_account_id, stu.id)) AS number_of_students")
      assert String.contains?(sql, "group_concat(distinct pg.name order by pg.name separator ', ') AS class_grade_levels")

      # Verify expected joins are present
      assert String.contains?(sql, "join taggings t on (t.tag_id = at.id")
      assert String.contains?(sql, "join external_activities ea")
      assert String.contains?(sql, "join portal_offerings po")
      assert String.contains?(sql, "join portal_clazzes po_class")
      assert String.contains?(sql, "join portal_teachers pt")
      assert String.contains?(sql, "join users u on (u.id = pt.user_id)")
      assert String.contains?(sql, "left join portal_schools ps")
      assert String.contains?(sql, "left join portal_countries pc")
    end
  end

  describe "apply_filters/3 - country filter" do
    test "applies single country filter with scope" do
      report_filter = %ReportFilter{
        country: [1],
        state: nil,
        subject_area: nil,
        exclude_internal: false,
        start_date: nil,
        end_date: nil
      }

      query = SummaryMetricsBySubjectAreaReport.get_query(report_filter, test_user())
      sql = normalized_sql(query)

      # Should have both scope and country filter
      assert String.contains?(sql, "at.scope = 'subject_areas'")
      assert String.contains?(sql, "ps.country_id IN (1)")
    end

    test "applies multiple country filter" do
      report_filter = %ReportFilter{
        country: [1, 2, 3],
        state: nil,
        subject_area: nil,
        exclude_internal: false,
        start_date: nil,
        end_date: nil
      }

      query = SummaryMetricsBySubjectAreaReport.get_query(report_filter, test_user())
      sql = normalized_sql(query)

      assert String.contains?(sql, "ps.country_id IN (1,2,3)")
      assert String.contains?(sql, "at.scope = 'subject_areas'")
    end

    test "handles '(Unknown)' country selection (NULL values)" do
      report_filter = %ReportFilter{
        country: [-1],  # -1 represents "(Unknown)"
        state: nil,
        subject_area: nil,
        exclude_internal: false,
        start_date: nil,
        end_date: nil
      }

      query = SummaryMetricsBySubjectAreaReport.get_query(report_filter, test_user())
      sql = normalized_sql(query)

      assert String.contains?(sql, "ps.country_id IS NULL")
      assert String.contains?(sql, "at.scope = 'subject_areas'")
    end

    test "handles mix of known countries and '(Unknown)'" do
      report_filter = %ReportFilter{
        country: [-1, 1, 2],  # -1 = "(Unknown)", 1 and 2 are real countries
        state: nil,
        subject_area: nil,
        exclude_internal: false,
        start_date: nil,
        end_date: nil
      }

      query = SummaryMetricsBySubjectAreaReport.get_query(report_filter, test_user())
      sql = normalized_sql(query)

      assert String.contains?(sql, "(ps.country_id IS NULL OR ps.country_id IN (1,2))")
      assert String.contains?(sql, "at.scope = 'subject_areas'")
    end
  end

  describe "apply_filters/3 - state filter" do
    test "applies single state filter with scope" do
      report_filter = %ReportFilter{
        country: nil,
        state: ["CA"],
        subject_area: nil,
        exclude_internal: false,
        start_date: nil,
        end_date: nil
      }

      query = SummaryMetricsBySubjectAreaReport.get_query(report_filter, test_user())
      sql = normalized_sql(query)

      assert String.contains?(sql, "ps.state IN ('CA')")
      assert String.contains?(sql, "at.scope = 'subject_areas'")
    end

    test "applies multiple state filter" do
      report_filter = %ReportFilter{
        country: nil,
        state: ["CA", "NY", "TX"],
        subject_area: nil,
        exclude_internal: false,
        start_date: nil,
        end_date: nil
      }

      query = SummaryMetricsBySubjectAreaReport.get_query(report_filter, test_user())
      sql = normalized_sql(query)

      assert String.contains?(sql, "ps.state IN ('CA','NY','TX')")
    end

    test "handles '(Unknown)' state selection (NULL values)" do
      report_filter = %ReportFilter{
        country: nil,
        state: ["(Unknown)"],
        subject_area: nil,
        exclude_internal: false,
        start_date: nil,
        end_date: nil
      }

      query = SummaryMetricsBySubjectAreaReport.get_query(report_filter, test_user())
      sql = normalized_sql(query)

      assert String.contains?(sql, "ps.state IS NULL")
      assert String.contains?(sql, "at.scope = 'subject_areas'")
    end

    test "handles mix of known states and '(Unknown)'" do
      report_filter = %ReportFilter{
        country: nil,
        state: ["(Unknown)", "CA", "NY"],
        subject_area: nil,
        exclude_internal: false,
        start_date: nil,
        end_date: nil
      }

      query = SummaryMetricsBySubjectAreaReport.get_query(report_filter, test_user())
      sql = normalized_sql(query)

      assert String.contains?(sql, "(ps.state IS NULL OR ps.state IN ('CA','NY'))")
      assert String.contains?(sql, "at.scope = 'subject_areas'")
    end
  end

  describe "apply_filters/3 - subject_area filter" do
    test "applies single subject_area filter" do
      report_filter = %ReportFilter{
        country: nil,
        state: nil,
        subject_area: [5],
        exclude_internal: false,
        start_date: nil,
        end_date: nil
      }

      query = SummaryMetricsBySubjectAreaReport.get_query(report_filter, test_user())
      sql = normalized_sql(query)

      assert String.contains?(sql, "at.id IN (5)")
      assert String.contains?(sql, "at.scope = 'subject_areas'")
    end

    test "applies multiple subject_area filter" do
      report_filter = %ReportFilter{
        country: nil,
        state: nil,
        subject_area: [5, 7, 9],
        exclude_internal: false,
        start_date: nil,
        end_date: nil
      }

      query = SummaryMetricsBySubjectAreaReport.get_query(report_filter, test_user())
      sql = normalized_sql(query)

      assert String.contains?(sql, "at.id IN (5,7,9)")
      assert String.contains?(sql, "at.scope = 'subject_areas'")
    end
  end

  describe "apply_filters/3 - combined filters" do
    test "applies country and state filters together" do
      report_filter = %ReportFilter{
        country: [1],
        state: ["CA"],
        subject_area: nil,
        exclude_internal: false,
        start_date: nil,
        end_date: nil
      }

      query = SummaryMetricsBySubjectAreaReport.get_query(report_filter, test_user())
      sql = normalized_sql(query)

      assert String.contains?(sql, "ps.country_id IN (1)")
      assert String.contains?(sql, "ps.state IN ('CA')")
      assert String.contains?(sql, "at.scope = 'subject_areas'")
    end

    test "applies country and subject_area filters together" do
      report_filter = %ReportFilter{
        country: [1, 2],
        state: nil,
        subject_area: [5],
        exclude_internal: false,
        start_date: nil,
        end_date: nil
      }

      query = SummaryMetricsBySubjectAreaReport.get_query(report_filter, test_user())
      sql = normalized_sql(query)

      assert String.contains?(sql, "ps.country_id IN (1,2)")
      assert String.contains?(sql, "at.id IN (5)")
      assert String.contains?(sql, "at.scope = 'subject_areas'")
    end

    test "applies state and subject_area filters together" do
      report_filter = %ReportFilter{
        country: nil,
        state: ["CA", "NY"],
        subject_area: [5, 7],
        exclude_internal: false,
        start_date: nil,
        end_date: nil
      }

      query = SummaryMetricsBySubjectAreaReport.get_query(report_filter, test_user())
      sql = normalized_sql(query)

      assert String.contains?(sql, "ps.state IN ('CA','NY')")
      assert String.contains?(sql, "at.id IN (5,7)")
      assert String.contains?(sql, "at.scope = 'subject_areas'")
    end

    test "applies all three filters together" do
      report_filter = %ReportFilter{
        country: [1],
        state: ["CA"],
        subject_area: [5],
        exclude_internal: false,
        start_date: nil,
        end_date: nil
      }

      query = SummaryMetricsBySubjectAreaReport.get_query(report_filter, test_user())
      sql = normalized_sql(query)

      assert String.contains?(sql, "ps.country_id IN (1)")
      assert String.contains?(sql, "ps.state IN ('CA')")
      assert String.contains?(sql, "at.id IN (5)")
      assert String.contains?(sql, "at.scope = 'subject_areas'")
    end
  end

  describe "apply_filters/3 - date filters" do
    test "applies start_date filter with scope" do
      report_filter = %ReportFilter{
        country: nil,
        state: nil,
        subject_area: nil,
        exclude_internal: false,
        start_date: "2023-01-01",
        end_date: nil
      }

      query = SummaryMetricsBySubjectAreaReport.get_query(report_filter, test_user())
      sql = normalized_sql(query)

      assert String.contains?(sql, "run.start_time >= '2023-01-01'")
      assert String.contains?(sql, "at.scope = 'subject_areas'")
    end

    test "applies end_date filter" do
      report_filter = %ReportFilter{
        country: nil,
        state: nil,
        subject_area: nil,
        exclude_internal: false,
        start_date: nil,
        end_date: "2023-12-31"
      }

      query = SummaryMetricsBySubjectAreaReport.get_query(report_filter, test_user())
      sql = normalized_sql(query)

      assert String.contains?(sql, "run.start_time <= '2023-12-31'")
      assert String.contains?(sql, "at.scope = 'subject_areas'")
    end

    test "applies both start_date and end_date filters" do
      report_filter = %ReportFilter{
        country: nil,
        state: nil,
        subject_area: nil,
        exclude_internal: false,
        start_date: "2023-01-01",
        end_date: "2023-12-31"
      }

      query = SummaryMetricsBySubjectAreaReport.get_query(report_filter, test_user())
      sql = normalized_sql(query)

      assert String.contains?(sql, "run.start_time >= '2023-01-01'")
      assert String.contains?(sql, "run.start_time <= '2023-12-31'")
    end
  end

  describe "apply_filters/3 - exclude_internal flag" do
    test "constructs query when exclude_internal is true" do
      report_filter = %ReportFilter{
        country: nil,
        state: nil,
        subject_area: nil,
        exclude_internal: true,
        start_date: nil,
        end_date: nil
      }

      query = SummaryMetricsBySubjectAreaReport.get_query(report_filter, test_user())
      sql = normalized_sql(query)

      # The exclude_internal flag calls exclude_internal_accounts which looks up
      # internal teacher IDs from the portal server. In tests without a database,
      # this will return an empty list, so no filter will be added. Just verify
      # the query constructs successfully.
      assert String.contains?(sql, "SELECT")
      assert String.contains?(sql, "FROM admin_tags at")
      assert String.contains?(sql, "at.scope = 'subject_areas'")
    end

    test "constructs query when exclude_internal is false" do
      report_filter = %ReportFilter{
        country: nil,
        state: nil,
        subject_area: nil,
        exclude_internal: false,
        start_date: nil,
        end_date: nil
      }

      query = SummaryMetricsBySubjectAreaReport.get_query(report_filter, test_user())
      sql = normalized_sql(query)

      # Verify the query constructs successfully
      assert String.contains?(sql, "SELECT")
      assert String.contains?(sql, "FROM admin_tags at")
    end
  end

  describe "apply_filters/3 - complex scenarios" do
    test "applies all filters together" do
      report_filter = %ReportFilter{
        country: [1, 2],
        state: ["CA", "NY"],
        subject_area: [5, 7],
        exclude_internal: true,
        start_date: "2023-01-01",
        end_date: "2023-12-31"
      }

      query = SummaryMetricsBySubjectAreaReport.get_query(report_filter, test_user())
      sql = normalized_sql(query)

      # Verify all explicit filters are present (exclude_internal may not show up without real DB)
      assert String.contains?(sql, "ps.country_id IN (1,2)")
      assert String.contains?(sql, "ps.state IN ('CA','NY')")
      assert String.contains?(sql, "at.id IN (5,7)")
      assert String.contains?(sql, "run.start_time >= '2023-01-01'")
      assert String.contains?(sql, "run.start_time <= '2023-12-31'")
      assert String.contains?(sql, "at.scope = 'subject_areas'")
    end

    test "handles NULL handling with multiple filters" do
      report_filter = %ReportFilter{
        country: [-1, 1],  # "(Unknown)" and USA
        state: ["(Unknown)", "CA"],  # NULL and California
        subject_area: [5],
        exclude_internal: false,
        start_date: nil,
        end_date: nil
      }

      query = SummaryMetricsBySubjectAreaReport.get_query(report_filter, test_user())
      sql = normalized_sql(query)

      # Verify NULL handling
      assert String.contains?(sql, "(ps.country_id IS NULL OR ps.country_id IN (1))")
      assert String.contains?(sql, "(ps.state IS NULL OR ps.state IN ('CA'))")
      assert String.contains?(sql, "at.id IN (5)")
      assert String.contains?(sql, "at.scope = 'subject_areas'")
    end

    test "always includes scope filter even with no other filters" do
      report_filter = %ReportFilter{
        country: nil,
        state: nil,
        subject_area: nil,
        exclude_internal: false,
        start_date: nil,
        end_date: nil
      }

      query = SummaryMetricsBySubjectAreaReport.get_query(report_filter, test_user())
      sql = normalized_sql(query)

      # Scope filter is ALWAYS present
      assert String.contains?(sql, "WHERE (at.scope = 'subject_areas')")
    end
  end
end
