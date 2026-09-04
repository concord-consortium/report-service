defmodule ReportServer.Reports.HideNamesTest do
  use ExUnit.Case, async: true

  alias ReportServer.Accounts.User
  alias ReportServer.Reports.{HideNames, ReportFilter}

  @admin %User{portal_is_admin: true}
  @project_admin %User{portal_is_project_admin: true}
  @researcher %User{portal_is_project_researcher: true}
  @no_roles %User{}

  describe "allowed?/1" do
    test "admits portal admins and project admins" do
      assert HideNames.allowed?(@admin)
      assert HideNames.allowed?(@project_admin)
    end

    test "refuses everyone else, including project researchers" do
      refute HideNames.allowed?(@researcher)
      refute HideNames.allowed?(@no_roles)
    end
  end

  describe "enforce/2" do
    test "leaves the filter alone for those allowed to see names" do
      filter = %ReportFilter{hide_names: false}

      assert HideNames.enforce(filter, @admin) == filter
      assert HideNames.enforce(filter, @project_admin) == filter
    end

    test "overrides an explicit hide_names: false rather than merely defaulting it" do
      filter = %ReportFilter{hide_names: false}

      for user <- [@researcher, @no_roles] do
        assert HideNames.enforce(filter, user).hide_names
      end
    end

    test "leaves hide_names on when it is already on" do
      filter = %ReportFilter{hide_names: true}

      for user <- [@admin, @project_admin, @researcher, @no_roles] do
        assert HideNames.enforce(filter, user).hide_names
      end
    end

    test "changes nothing else about the filter" do
      filter = %ReportFilter{filters: [:class], class: [601], hide_names: false}
      enforced = HideNames.enforce(filter, @no_roles)

      assert %{enforced | hide_names: false} == filter
    end
  end
end
