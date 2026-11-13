defmodule ReportServer.Reports.CohortFilterDbTest do
  use ExUnit.Case, async: false

  @moduletag :portal_db

  alias ReportServer.{PortalDbs, PortalFixture}
  alias ReportServer.Accounts.User
  alias ReportServer.Reports.{CohortFilter, ReportFilter, ReportQuery}
  alias ReportServer.Reports.Athena.LearnerData
  alias ReportServer.Reports.Portal.StudentIdMappingReport

  @server PortalFixture.server()

  defp activities(cohort_ids) do
    sql = "SELECT ea.id FROM external_activities ea WHERE #{CohortFilter.activity_in_cohorts("ea.id", cohort_ids)} ORDER BY ea.id"
    {:ok, result} = PortalDbs.query(@server, sql)
    List.flatten(result.rows)
  end

  defp cohorts(activity_ids) do
    sql = "SELECT ac.id FROM admin_cohorts ac WHERE #{CohortFilter.cohort_admits_activities("ac", activity_ids)} ORDER BY ac.id"
    {:ok, result} = PortalDbs.query(@server, sql)
    List.flatten(result.rows)
  end

  test "a cohort admits its own activity items" do
    assert activities([3]) == [801]
  end

  test "a cohort admits its project's materials" do
    assert activities([6]) == [801, 803]
  end

  # Cohort 2's 803 and project 901's 802 are of other types, so neither counts.
  test "a cohort admits no activity that is neither its item nor its project's material" do
    assert activities([2]) == []
    assert activities([5]) == []
  end

  test "read from the cohort's side, the rule admits the same pairs" do
    assert cohorts([803]) == [1, 6]
    assert cohorts([801]) == [1, 3, 4, 6]
    assert cohorts([802]) == []
  end

  describe "the learner reports" do
    defp user(id, flags), do: struct(%User{portal_server: @server, portal_user_id: id}, flags)

    defp learner_ids(user, cohort_ids) do
      filter = %ReportFilter{filters: [:cohort], cohort: cohort_ids}
      {:ok, query} = StudentIdMappingReport.get_query(filter, user)
      {:ok, sql} = ReportQuery.get_sql(query)
      {:ok, result} = PortalDbs.query(@server, sql)
      result |> PortalDbs.map_columns_on_rows() |> Enum.map(& &1.learner_id) |> Enum.sort()
    end

    defp athena_learner_ids(user, cohort_ids) do
      filter = %ReportFilter{filters: [:cohort], cohort: cohort_ids}
      {:ok, groups} = LearnerData.fetch(filter, user, allow_empty: true)
      groups |> Enum.flat_map(& &1.learners) |> Enum.map(& &1.learner_id) |> Enum.sort()
    end

    # Teacher 31 also teaches learner 902, whose activity 802 no project holds, so 902 is absent.
    test "a cohort keeps learners on its project's materials, for every kind of caller" do
      admin = user(555, portal_is_project_admin: true)
      researcher = user(557, portal_is_project_researcher: true)
      site_admin = user(560, portal_is_admin: true)

      assert learner_ids(admin, [6]) == [901, 903, 904]
      assert learner_ids(researcher, [6]) == [901]
      assert learner_ids(site_admin, [6]) == [901, 903, 904]

      assert athena_learner_ids(admin, [6]) == [901, 903, 904]
      assert athena_learner_ids(researcher, [6]) == [901]
    end

    # Teacher 36 is in cohort 5 and teaches learners on 801, which project 904 does not hold.
    test "a cohort's teacher is not enough when the activity is neither its item nor its material" do
      assert learner_ids(user(560, portal_is_admin: true), [5]) == []
    end
  end
end
