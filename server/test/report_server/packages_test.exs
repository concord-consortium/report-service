defmodule ReportServer.PackagesTest do
  use ReportServer.DataCase

  alias ReportServer.Packages
  alias ReportServer.Packages.Package
  alias ReportServer.Accounts
  alias ReportServer.Accounts.User
  alias ReportServer.PortalDbs.PortalUserInfo

  import ReportServer.AccountsFixtures

  describe "administers?/3" do
    test "a user maintainer administers only as that user" do
      package = %Package{maintainer: "users/136"}
      assert Packages.administers?(package, 136, :none)
      refute Packages.administers?(package, 137, :all)
    end

    test "a project maintainer is administered through an allowed project id" do
      package = %Package{maintainer: "projects/20"}
      assert Packages.administers?(package, 1, [20, 21])
      refute Packages.administers?(package, 1, [21])
      refute Packages.administers?(package, 1, :none)
      refute Packages.administers?(package, 20, [])
    end

    test "a site admin's :all administers every project-maintained package" do
      assert Packages.administers?(%Package{maintainer: "projects/20"}, 1, :all)
    end
  end

  describe "publisher?/1" do
    test "holds for the granted flag and for every site admin" do
      assert Packages.publisher?(%User{package_publisher: true, portal_is_admin: false})
      assert Packages.publisher?(%User{package_publisher: false, portal_is_admin: true})
    end

    test "does not hold for a project admin or a researcher" do
      refute Packages.publisher?(%User{portal_is_project_admin: true, portal_is_admin: false})
      refute Packages.publisher?(%User{portal_is_project_researcher: true, portal_is_admin: false})
    end
  end

  describe "set_publisher/3" do
    test "sets and clears the flag on an existing user" do
      user = user_fixture(portal_server: "learn.concord.org")
      refute Repo.reload!(user).package_publisher

      assert :ok = Packages.set_publisher("learn.concord.org", user.portal_user_id, true)
      assert Repo.reload!(user).package_publisher

      assert :ok = Packages.set_publisher("learn.concord.org", user.portal_user_id, false)
      refute Repo.reload!(user).package_publisher
    end

    test "a portal login neither sets nor clears the flag" do
      user = user_fixture(portal_server: "learn.concord.org")
      assert :ok = Packages.set_publisher("learn.concord.org", user.portal_user_id, true)

      info = %PortalUserInfo{
        id: user.portal_user_id, server: "learn.concord.org", login: "renamed", first_name: "R",
        last_name: "N", email: "r@example.com", is_admin: false, is_project_admin: false,
        is_project_researcher: true
      }

      assert {:ok, _} = Accounts.find_or_create_user(info)
      assert Repo.reload!(user).package_publisher

      refute Map.has_key?(User.changeset(%User{}, %{package_publisher: true}).changes, :package_publisher)
    end

    test "finds no user on another portal" do
      user = user_fixture(portal_server: "learn.concord.org")
      assert {:error, :not_found} = Packages.set_publisher("ngss-assessment.portal.concord.org", user.portal_user_id, true)
    end
  end

  describe "the packages table" do
    defp insert(attrs) do
      %Package{}
      |> Package.create_changeset(Map.merge(%{origin: "users/136", name: "counts", maintainer: "users/136"}, attrs))
      |> Repo.insert()
    end

    test "derives the identity from the origin and name, private by default" do
      assert {:ok, package} = insert(%{portal_server: "learn.concord.org"})
      assert package.identity == "users/136/counts"
      assert package.visibility == "private"
      refute package.official
      refute package.archived
    end

    test "an identity is unique per portal, not globally" do
      assert {:ok, _} = insert(%{portal_server: "learn.concord.org"})
      assert {:error, changeset} = insert(%{portal_server: "learn.concord.org"})
      assert %{identity: ["has already been taken"]} = errors_on(changeset)
      assert {:ok, _} = insert(%{portal_server: "ngss-assessment.portal.concord.org"})
    end

    test "refuses a malformed name or origin" do
      assert {:error, changeset} = insert(%{portal_server: "learn.concord.org", name: "bad_name"})
      assert %{name: ["is invalid"]} = errors_on(changeset)
      assert {:error, changeset} = insert(%{portal_server: "learn.concord.org", origin: "groups/1"})
      assert %{origin: ["is invalid"]} = errors_on(changeset)
    end
  end
end
