defmodule ReportServer.PortalDbsCatalogTest do
  use ExUnit.Case, async: false

  @moduletag :portal_db

  alias ReportServer.{PortalDbs, PortalFixture}
  alias ReportServer.Accounts.User
  alias ReportServer.Reports.AllowedProjects

  describe "get_user_roles/3" do
    test "reads each flag fresh from the portal" do
      server = PortalFixture.server()
      assert {:ok, %{is_admin: true, is_project_admin: false, is_project_researcher: false}} = PortalDbs.get_user_roles(server, 560, timeout: 5_000)
      assert {:ok, %{is_admin: false, is_project_admin: true, is_project_researcher: false}} = PortalDbs.get_user_roles(server, 555, timeout: 5_000)
      assert {:ok, %{is_admin: false, is_project_admin: false, is_project_researcher: true}} = PortalDbs.get_user_roles(server, 557, timeout: 5_000)
      assert {:ok, %{is_admin: false, is_project_admin: false, is_project_researcher: false}} = PortalDbs.get_user_roles(server, 131, timeout: 5_000)
    end

    test "counts a researcher row only while it has not expired" do
      server = PortalFixture.server()
      assert {:ok, %{is_project_researcher: false}} = PortalDbs.get_user_roles(server, 564, timeout: 5_000)
      assert {:ok, %{is_project_researcher: false}} = PortalDbs.get_user_roles(server, 565, timeout: 5_000)
      assert {:ok, %{is_project_researcher: true}} = PortalDbs.get_user_roles(server, 566, timeout: 5_000)
      assert {:ok, %{is_project_researcher: true}} = PortalDbs.get_user_roles(server, 557, timeout: 5_000)
    end

    test "is not_found for an unknown user" do
      assert {:error, :not_found} = PortalDbs.get_user_roles(PortalFixture.server(), 999_999, timeout: 5_000)
    end
  end

  describe "get_allowed_project_ids/2" do
    defp lookup(id, flags) do
      user = struct(%User{portal_server: PortalFixture.server(), portal_user_id: id}, flags)
      PortalDbs.get_allowed_project_ids(user, timeout: 5_000)
    end

    defp researcher(id), do: lookup(id, portal_is_project_researcher: true)

    test "splits a user's live rows into the projects they administer and the ones they research" do
      assert %AllowedProjects{admin: [900], researcher: []} = lookup(555, portal_is_project_admin: true)
      assert %AllowedProjects{admin: [], researcher: [900]} = researcher(557)

      assert %AllowedProjects{admin: [900], researcher: [902]} =
               lookup(562, portal_is_project_admin: true, portal_is_project_researcher: true)
    end

    test "a researcher's expired rows grant no project" do
      assert :none = researcher(564)
      assert :none = researcher(565)
      assert %AllowedProjects{admin: [], researcher: [900]} = researcher(566)
    end

    test "a project the user both administers and researches is in the admin list only" do
      assert %AllowedProjects{admin: [900], researcher: []} =
               lookup(567, portal_is_project_admin: true, portal_is_project_researcher: true)
    end

    test "a site admin is :all even with a live researcher row" do
      assert :all = lookup(570, portal_is_admin: true, portal_is_project_researcher: true)
    end

    test "a researcher row with a NULL is_admin still counts" do
      assert %AllowedProjects{admin: [], researcher: [901]} = researcher(568)
    end
  end

  describe "get_project_names/3" do
    test "maps each id to its name, and asks nothing for no ids" do
      assert {:ok, %{900 => "Proj A", 901 => "Proj B"}} = PortalDbs.get_project_names(PortalFixture.server(), [900, 901, 999], timeout: 5_000)
      assert {:ok, %{}} = PortalDbs.get_project_names("dead.example.com", [], timeout: 5_000)
    end
  end
end
