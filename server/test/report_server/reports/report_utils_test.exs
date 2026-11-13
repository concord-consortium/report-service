defmodule ReportServer.Reports.ReportUtilsTest do
  use ExUnit.Case, async: true

  alias ReportServer.Reports.{AllowedProjects, AllowedProjectsLookupError}
  alias ReportServer.Reports.ReportUtils

  describe "the run date bounds" do
    test "an ISO date is applied to both ends" do
      assert ReportUtils.apply_start_date([], "2026-01-01") == ["run.start_time >= '2026-01-01'"]
      assert ReportUtils.apply_end_date([], "2026-02-01") == ["run.start_time < '2026-02-02'"]
    end

    test "an absent bound is not applied" do
      assert ReportUtils.apply_start_date(["w"], nil) == ["w"]
      assert ReportUtils.apply_start_date(["w"], "") == ["w"]
      assert ReportUtils.apply_end_date(["w"], nil) == ["w"]
      assert ReportUtils.apply_end_date(["w"], "") == ["w"]
    end

    test "the end bound is the next day across a month, a year and a leap day" do
      assert ReportUtils.apply_end_date([], "2026-01-31") == ["run.start_time < '2026-02-01'"]
      assert ReportUtils.apply_end_date([], "2025-12-31") == ["run.start_time < '2026-01-01'"]
      assert ReportUtils.apply_end_date([], "2024-02-28") == ["run.start_time < '2024-02-29'"]
    end

    # The bound is interpolated, and a run stored before its filter was validated can carry
    # anything, so a value that is not a date must not reach the statement from any path.
    test "a value that is not a date is refused rather than interpolated" do
      for payload <- ["2026-01-01' OR '1'='1", "2026-01-01 OR 1=1", "not-a-date", "2026-13-01"] do
        assert_raise ArgumentError, fn -> ReportUtils.apply_start_date([], payload) end
        assert_raise ArgumentError, fn -> ReportUtils.apply_end_date([], payload) end
      end
    end
  end

  describe "the log date bounds" do
    test "a date bounds `timestamp` from its midnight to the next" do
      assert ReportUtils.apply_log_start_date([], "2025-06-30") == ["log.timestamp >= 1751241600000"]
      assert ReportUtils.apply_log_end_date([], "2025-06-30") == ["log.timestamp < 1751328000000"]
    end

    test "the end bound crosses a month, a year and a leap day" do
      assert ReportUtils.apply_log_end_date([], "2026-01-31") == ["log.timestamp < 1769904000000"]
      assert ReportUtils.apply_log_end_date([], "2025-12-31") == ["log.timestamp < 1767225600000"]
      assert ReportUtils.apply_log_end_date([], "2024-02-28") == ["log.timestamp < 1709164800000"]
    end

    test "the table name is honored" do
      assert ReportUtils.apply_log_start_date([], "2025-06-30", "l") == ["l.timestamp >= 1751241600000"]
    end

    test "an absent bound is not applied" do
      assert ReportUtils.apply_log_start_date(["w"], nil) == ["w"]
      assert ReportUtils.apply_log_start_date(["w"], "") == ["w"]
      assert ReportUtils.apply_log_end_date(["w"], nil) == ["w"]
      assert ReportUtils.apply_log_end_date(["w"], "") == ["w"]
    end

    test "a value that is not a date is refused" do
      for payload <- ["2026-01-01' OR '1'='1", "2026-01-01 OR 1=1", "not-a-date", "2026-13-01"] do
        assert_raise ArgumentError, fn -> ReportUtils.apply_log_start_date([], payload) end
        assert_raise ArgumentError, fn -> ReportUtils.apply_log_end_date([], payload) end
      end
    end
  end

  describe "scope_by_allowed_projects/6" do
    test ":all applies no scoping" do
      assert ReportUtils.scope_by_allowed_projects(:all, ["j"], ["w"], "ea.id", "pt.id") == {["j"], ["w"]}
    end

    test "allowed projects scope to those projects with a valid IN clause" do
      allowed = %AllowedProjects{admin: [1], researcher: [2]}
      {join, where} = ReportUtils.scope_by_allowed_projects(allowed, [], [], "ea.id", "pt.id")
      where_sql = Enum.join(where, " ")
      assert where_sql =~ "IN (1,2)"
      refute where_sql =~ "IN ()"
      assert length(join) == 5
    end

    test "an admin-only caller's SQL is the same with a student ref as without" do
      allowed = %AllowedProjects{admin: [1, 2], researcher: []}

      assert ReportUtils.scope_by_allowed_projects(allowed, [], [], "ea.id", "pt.id", "rl.student_id") ==
               ReportUtils.scope_by_allowed_projects(allowed, [], [], "ea.id", "pt.id")
    end

    test "a researcher project requires the student's consent to that project" do
      allowed = %AllowedProjects{admin: [], researcher: [3]}
      {_join, [teacher | _]} = ReportUtils.scope_by_allowed_projects(allowed, [], [], "ea.id", "pt.id", "rl.student_id")

      assert teacher ==
               "(ac_teacher_a.project_id IN (3) AND " <>
                 AllowedProjects.consent_exists("rl.student_id", "ac_teacher_a.project_id") <> ")"
    end

    test "a caller with both roles gets an admin branch and a consent branch" do
      allowed = %AllowedProjects{admin: [1], researcher: [3]}
      {_join, [teacher | _]} = ReportUtils.scope_by_allowed_projects(allowed, [], [], "ea.id", "pt.id", "rl.student_id")

      assert teacher =~ ~r/^\(ac_teacher_a\.project_id IN \(1\)\) OR \(ac_teacher_a\.project_id IN \(3\) AND \(NOT EXISTS /
      refute teacher =~ "IN ()"
    end

    test "with no student ref a researcher project takes the admin rule" do
      allowed = %AllowedProjects{admin: [], researcher: [3]}
      {_join, where} = ReportUtils.scope_by_allowed_projects(allowed, [], [], "ea.id", "pt.id")

      refute Enum.join(where, " ") =~ "EXISTS"
      assert hd(where) == "ac_teacher_a.project_id IN (3)"
    end

    test ":none (no roles) constrains to zero rows and adds no scoping joins" do
      assert ReportUtils.scope_by_allowed_projects(:none, [], ["existing"], "ea.id", "pt.id") == {[], ["1 = 0", "existing"]}
    end

    test "a failed permission lookup raises rather than silently returning zero rows" do
      assert_raise AllowedProjectsLookupError, ~r/boom/, fn ->
        ReportUtils.scope_by_allowed_projects({:error, "boom"}, [], [], "ea.id", "pt.id")
      end
    end
  end
end
