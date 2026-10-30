defmodule ReportServer.RecentLogs.AccessTest do
  use ReportServer.DataCase, async: false

  @moduletag :portal_db

  import ReportServer.AccountsFixtures

  alias ReportServer.Accounts.User
  alias ReportServer.PortalFixture
  alias ReportServer.RecentLogs.Access
  alias ReportServer.Repo

  @server PortalFixture.server()
  @iss ReportServerWeb.PortalTokenFixture.iss(:portal_fixture)

  defp researcher, do: user_fixture(%{portal_server: @server, portal_user_id: 557, portal_is_project_researcher: true})

  defp admin do
    user_fixture(%{portal_server: @server, portal_user_id: 560, portal_is_admin: true, portal_is_project_researcher: false})
  end

  defp endpoints(learners), do: learners |> Enum.map(& &1.run_remote_endpoint) |> Enum.sort()

  defp claims_conn(claims), do: Plug.Conn.assign(Phoenix.ConnTest.build_conn(), :portal_claims, claims)

  defp class_claims(class_id, overrides \\ %{}) do
    Map.merge(%{"iss" => @iss, "uid" => 557, "context" => %{"type" => "class", "id" => class_id}}, overrides)
  end

  describe "learners/2" do
    test "a researcher reads the learners their grants reach in a class" do
      assert {:ok, [learner]} = Access.learners(researcher(), 601)

      assert learner.run_remote_endpoint == "https://#{@server}/dataservice/external_activity_data/SECUREKEY123"
      assert learner.user_id == 101
    end

    test "a class in the researcher's grants with no learners is empty, not refused" do
      assert Access.learners(researcher(), 2) == {:ok, []}
    end

    test "a class outside the grants and a class that does not exist are refused alike" do
      user = researcher()

      assert Access.learners(user, 603) == {:error, :forbidden}
      assert Access.learners(user, 999_999) == {:error, :forbidden}
    end

    test "a site admin reads every learner of a class, and classes with no project" do
      user = admin()
      assert {:ok, learners} = Access.learners(user, 601)

      assert endpoints(learners) == [
               "https://#{@server}/dataservice/external_activity_data/",
               "https://#{@server}/dataservice/external_activity_data/SECUREKEY123"
             ]

      assert Access.learners(user, 603) == {:ok, []}
    end
  end

  describe "caller/2" do
    test "an API token's caller is the current user" do
      user = researcher()
      conn = Plug.Conn.assign(Phoenix.ConnTest.build_conn(), :current_user, user)

      assert Access.caller(conn, 601) == {:ok, user}
    end

    test "an access-token caller is resolved to a user row refreshed from the portal" do
      assert {:ok, user} = Access.caller(claims_conn(class_claims(601)), 601)

      assert user.portal_server == @server
      assert user.portal_user_id == 557
      assert user.portal_email == "rae@e.org"
      assert user.portal_is_project_researcher

      assert {:ok, again} = Access.caller(claims_conn(class_claims(601)), 601)
      assert again.id == user.id
      assert Repo.aggregate(from(u in User, where: u.portal_user_id == 557 and u.portal_server == @server), :count) == 1
    end

    test "an existing user row is refreshed from the portal, flags and email included" do
      stale = user_fixture(%{portal_server: @server, portal_user_id: 557, portal_is_project_researcher: false, portal_email: "stale@e.org"})

      assert {:ok, user} = Access.caller(claims_conn(class_claims(601)), 601)

      assert user.id == stale.id
      assert user.portal_is_project_researcher
      assert user.portal_email == "rae@e.org"
    end

    test "a token whose context names another class is refused before any portal lookup" do
      claims = class_claims(602, %{"iss" => "https://unknown-portal.example/"})

      assert Access.caller(claims_conn(claims), 601) == {:error, :forbidden}
    end

    test "a token from a portal report-server has no database for is not authenticated" do
      claims = class_claims(601, %{"iss" => "https://unknown-portal.example/"})

      assert Access.caller(claims_conn(claims), 601) == {:error, :not_authenticated}
    end

    test "a token with no class context is refused" do
      assert Access.caller(claims_conn(class_claims(601, %{"context" => nil})), 601) == {:error, :forbidden}
    end

    test "a portal user with a blank required field is not authenticated, on the first call too" do
      claims = class_claims(601, %{"uid" => 561})

      assert Access.caller(claims_conn(claims), 601) == {:error, :not_authenticated}
      assert Access.caller(claims_conn(claims), 601) == {:error, :not_authenticated}
      refute Repo.exists?(from(u in User, where: u.portal_user_id == 561 and u.portal_server == @server))
    end

    test "a uid that is not an integer is not authenticated" do
      assert Access.caller(claims_conn(class_claims(601, %{"uid" => "557"})), 601) == {:error, :not_authenticated}
    end

    test "a portal that cannot be asked is unavailable, not a refusal" do
      env = "UNREACHABLE_PORTAL_EXAMPLE_DB"
      System.put_env(env, "mysql://user:pass@127.0.0.1:1/portal")
      on_exit(fn -> System.delete_env(env) end)

      claims = class_claims(601, %{"iss" => "https://unreachable-portal.example/"})

      assert Access.caller(claims_conn(claims), 601) == {:error, :portal_unavailable}
    end

    test "a uid the portal does not have is not authenticated" do
      assert Access.caller(claims_conn(class_claims(601, %{"uid" => 424_242})), 601) == {:error, :not_authenticated}
    end
  end
end
