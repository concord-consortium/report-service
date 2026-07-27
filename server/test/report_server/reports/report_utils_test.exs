defmodule ReportServer.Reports.ReportUtilsTest do
  use ExUnit.Case, async: true

  alias ReportServer.Reports.ReportUtils

  describe "scope_by_allowed_projects/5" do
    test ":all applies no scoping" do
      assert ReportUtils.scope_by_allowed_projects(:all, ["j"], ["w"], "ea.id", "pt.id") == {["j"], ["w"]}
    end

    test "a non-empty list scopes to those projects with a valid IN clause" do
      {join, where} = ReportUtils.scope_by_allowed_projects([1, 2], [], [], "ea.id", "pt.id")
      where_sql = Enum.join(where, " ")
      assert where_sql =~ "IN (1,2)"
      refute where_sql =~ "IN ()"
      assert length(join) == 5
    end

    test "an empty list constrains to zero rows instead of emitting IN ()" do
      {join, where} = ReportUtils.scope_by_allowed_projects([], [], ["existing"], "ea.id", "pt.id")
      assert where == ["1 = 0", "existing"]
      refute Enum.join(where, " ") =~ "IN ()"
      # no scoping joins are added for a user who can see nothing
      assert join == []
    end

    test ":none (no roles) also constrains to zero rows" do
      assert ReportUtils.scope_by_allowed_projects(:none, [], [], "ea.id", "pt.id") == {[], ["1 = 0"]}
    end

    test "a lookup error constrains to zero rows rather than raising in list_to_in" do
      assert ReportUtils.scope_by_allowed_projects({:error, "boom"}, [], [], "ea.id", "pt.id") ==
               {[], ["1 = 0"]}
    end
  end
end
