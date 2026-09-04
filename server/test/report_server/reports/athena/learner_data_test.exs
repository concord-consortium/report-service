defmodule ReportServer.Reports.Athena.LearnerDataTest do
  use ExUnit.Case, async: true

  alias ReportServer.Accounts.User
  alias ReportServer.Reports.Athena.LearnerData
  alias ReportServer.Reports.{ReportFilter, ReportQuery}

  # a super admin resolves allowed projects without a portal round trip, and exclude_internal is
  # left off so the build stays free of its own query
  defp user, do: %User{portal_is_admin: true, portal_server: "learn.concord.org"}

  defp filter, do: %ReportFilter{filters: [:cohort], cohort: [1, 2]}

  defp sql_for(query) do
    {:ok, sql} = ReportQuery.get_sql(query)
    sql |> String.replace(~r/\s+/, " ") |> String.trim()
  end

  defp built_query do
    {:ok, query} = LearnerData.build_query(filter(), user())
    query
  end

  describe "count_query/1" do
    test "counts distinct learners rather than rows" do
      sql = built_query() |> LearnerData.count_query() |> sql_for()

      assert sql =~ "COUNT(DISTINCT rl.learner_id)"
      refute sql =~ "COUNT(*)"
    end

    test "selects only the count, so the learner columns are gone" do
      select = built_query() |> LearnerData.count_query() |> sql_for() |> select_list()

      assert select =~ "COUNT(DISTINCT rl.learner_id)"
      refute select =~ "rl.student_id"
      refute select =~ "ea.url"
    end

    test "is the fetch query from the FROM onward, so it counts the same learners" do
      fetch_sql = built_query() |> sql_for()
      count_sql = built_query() |> LearnerData.count_query() |> sql_for()

      assert from_onward(count_sql) == from_onward(fetch_sql)
    end

    # the LEFT JOIN portal_runs is what makes a row count differ from a learner count, so the
    # count has to carry the same joins as the query it is estimating for
    test "keeps the join that makes a naive row count wrong" do
      sql = built_query() |> LearnerData.count_query() |> sql_for()

      assert sql =~ "LEFT JOIN portal_runs"
    end
  end

  describe "build_query/2" do
    test "still selects distinct learners for the fetch path" do
      assert sql_for(built_query()) =~ "DISTINCT rl.learner_id"
    end

    test "carries the filter into the WHERE" do
      assert sql_for(built_query()) =~ "aci_teacher.admin_cohort_id in (1,2)"
    end
  end

  defp from_onward(sql), do: sql |> String.split(" FROM ", parts: 2) |> List.last()
  defp select_list(sql), do: sql |> String.split(" FROM ", parts: 2) |> List.first()
end
