defmodule ReportServer.PortalDbsCatalogTest do
  use ExUnit.Case, async: false

  @moduletag :portal_db

  alias ReportServer.{PortalDbs, PortalFixture}
  alias ReportServer.Accounts.User

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
    test "a researcher's expired rows grant no project" do
      researcher = fn id -> %User{portal_server: PortalFixture.server(), portal_user_id: id, portal_is_project_researcher: true} end
      assert [] = PortalDbs.get_allowed_project_ids(researcher.(564), timeout: 5_000)
      assert [] = PortalDbs.get_allowed_project_ids(researcher.(565), timeout: 5_000)
      assert [900] = PortalDbs.get_allowed_project_ids(researcher.(566), timeout: 5_000)
      assert [900] = PortalDbs.get_allowed_project_ids(researcher.(557), timeout: 5_000)
    end
  end

  describe "get_project_names/3" do
    test "maps each id to its name, and asks nothing for no ids" do
      assert {:ok, %{900 => "Proj A", 901 => "Proj B"}} = PortalDbs.get_project_names(PortalFixture.server(), [900, 901, 999], timeout: 5_000)
      assert {:ok, %{}} = PortalDbs.get_project_names("dead.example.com", [], timeout: 5_000)
    end
  end
end
