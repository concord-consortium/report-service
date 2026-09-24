defmodule ReportServerWeb.Api.V1.PackageControllerReadTest do
  use ReportServerWeb.ConnCase, async: false

  import ReportServer.PackagesFixtures
  import ReportServerWeb.PortalTokenFixture

  alias ReportServer.{AccountsFixtures, PackagesMemoryStore, PackagesPortalStub, Repo}
  alias ReportServer.Packages.Package

  @server "learn.portal.staging.concord.org"
  @db_env "LEARN_PORTAL_STAGING_CONCORD_ORG_DB"
  @uid 42

  setup do
    previous = System.get_env(@db_env)
    System.put_env(@db_env, "mysql://user:pass@localhost:3306")
    install!()
    {:ok, _} = PackagesMemoryStore.start()
    PackagesPortalStub.set(%{})
    packages_config = Application.get_env(:report_server, :packages)

    on_exit(fn ->
      if previous, do: System.put_env(@db_env, previous), else: System.delete_env(@db_env)
      Application.put_env(:report_server, :packages, packages_config)
      PackagesPortalStub.reset()
    end)

    me = AccountsFixtures.user_fixture(portal_server: @server, portal_user_id: @uid)
    other = AccountsFixtures.user_fixture(portal_server: @server)
    elsewhere = AccountsFixtures.user_fixture(portal_server: "learn.concord.org")

    %{me: me, other: other, elsewhere: elsewhere}
  end

  defp put_state(%{package: package} = published, changes),
    do: %{published | package: package |> Ecto.Changeset.change(changes) |> Repo.update!()}

  # One package in each state the visibility rule distinguishes.
  defp catalog(%{me: me, other: other, elsewhere: elsewhere}) do
    PackagesPortalStub.set(%{allowed_project_ids: :all})

    published = %{
      mine: publish_fixture(me, %{"name" => "mine"}) |> put_state(%{}),
      official: publish_fixture(other, %{"name" => "official"}) |> put_state(official: true, visibility: "public"),
      public: publish_fixture(other, %{"name" => "public"}) |> put_state(visibility: "public"),
      private: publish_fixture(other, %{"name" => "private"}) |> put_state(%{}),
      granted: publish_fixture(other, %{"name" => "granted"}) |> put_state(visibility: "project", project_id: 20),
      ungranted: publish_fixture(other, %{"name" => "ungranted"}) |> put_state(visibility: "project", project_id: 21),
      team: publish_fixture(other, %{"name" => "team"}, origin: "projects/20") |> put_state(%{}),
      archived: publish_fixture(other, %{"name" => "archived"}) |> put_state(official: true, visibility: "public", archived: true),
      elsewhere: publish_fixture(elsewhere, %{"name" => "elsewhere"}) |> put_state(official: true, visibility: "public")
    }

    # the readers below hold no grants unless a test says otherwise
    PackagesPortalStub.set(%{})
    published
  end

  defp launch_token(overrides \\ %{}), do: sign(:staging, claims(:staging, "researcher-dashboard", Map.merge(%{"uid" => @uid}, overrides)))
  defp with_bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")
  defp names(conn), do: conn |> json_response(200) |> Map.fetch!("packages") |> Enum.map(& &1["name"]) |> Enum.sort()

  describe "the anonymous list" do
    test "is the named portal's non-archived official packages", %{conn: conn} = context do
      catalog(context)
      assert names(get(conn, "/api/v1/packages?portal=#{@server}")) == ["official"]
      assert names(get(build_conn(), "/api/v1/packages?portal=https://learn.concord.org/")) == ["elsewhere"]
      assert names(get(build_conn(), "/api/v1/packages?portal=learn-report.concord.org")) == ["elsewhere"]
      assert names(get(build_conn(), "/api/v1/packages?portal=unknown.example.org")) == []
    end

    test "needs a portal", %{conn: conn} do
      assert %{"error" => "BAD_REQUEST"} = json_response(get(conn, "/api/v1/packages"), 400)
    end

    test "carries each package's current version and flags", %{conn: conn} = context do
      catalog(context)
      assert [package] = conn |> get("/api/v1/packages?portal=#{@server}") |> json_response(200) |> Map.fetch!("packages")

      assert %{
               "identity" => "users/" <> _,
               "official" => true,
               "runnable" => true,
               "mine" => false,
               "project" => nil,
               "current_version" => %{
                 "version" => "1.0.0",
                 "checksum" => "sha256:" <> _,
                 "title" => "Counts",
                 "urls" => %{"all" => [], "any" => ["*question-interactives/*"], "none" => []},
                 "clue_prepull" => false,
                 "expected_duration_seconds" => 60,
                 "published_at" => _
               }
             } = package
    end
  end

  describe "the list with a launch token" do
    test "adds public, own, project-granted and project-maintained packages", %{conn: conn} = context do
      catalog(context)
      PackagesPortalStub.set(%{allowed_project_ids: [20], project_names: {:ok, %{20 => "Team Twenty"}}})

      conn = conn |> with_bearer(launch_token()) |> get("/api/v1/packages")
      assert names(conn) == ["granted", "mine", "official", "public", "team"]
      assert get_resp_header(conn, "cache-control") == ["no-store"]

      packages = json_response(conn, 200)["packages"] |> Map.new(&{&1["name"], &1})
      assert packages["mine"]["mine"]
      assert packages["team"]["mine"]
      refute packages["public"]["mine"]
      assert packages["granted"]["project"] == %{"id" => 20, "name" => "Team Twenty"}
      refute packages["mine"]["runnable"]
      assert packages["official"]["runnable"]
    end

    test "reads the roles from the portal, not report-server's stored copy", %{conn: conn} = context do
      catalog(context)

      PackagesPortalStub.set(%{
        user_roles: fn @server, @uid -> {:ok, %{is_admin: true, is_project_admin: false, is_project_researcher: false}} end,
        allowed_project_ids: fn user -> if user.portal_is_admin, do: :all, else: :none end
      })

      assert names(conn |> with_bearer(launch_token()) |> get("/api/v1/packages")) ==
               ["granted", "mine", "official", "public", "team", "ungranted"]
    end

    test "a researcher with no grants sees official, public and their own", %{conn: conn} = context do
      catalog(context)
      assert names(conn |> with_bearer(launch_token()) |> get("/api/v1/packages")) == ["mine", "official", "public"]
    end

    test "needs no report-server user row", %{conn: conn} = context do
      catalog(context)
      assert names(conn |> with_bearer(launch_token(%{"uid" => 9_999_999})) |> get("/api/v1/packages")) == ["official", "public"]
    end

    test "a project-name lookup that fails leaves the name null", %{conn: conn} = context do
      catalog(context)
      PackagesPortalStub.set(%{allowed_project_ids: [20], project_names: {:error, "timeout"}})
      packages = conn |> with_bearer(launch_token()) |> get("/api/v1/packages") |> json_response(200) |> Map.fetch!("packages")
      assert %{"project" => %{"id" => 20, "name" => nil}} = Enum.find(packages, &(&1["name"] == "granted"))
    end

    test "a user the portal does not know is 401", %{conn: conn} do
      PackagesPortalStub.set(%{user_roles: {:error, :not_found}})
      assert %{"error" => "NOT_AUTHENTICATED"} = json_response(conn |> with_bearer(launch_token()) |> get("/api/v1/packages"), 401)

      resolve = build_conn() |> with_bearer(launch_token()) |> get("/api/v1/packages/resolve?identity=users/1/x&version=1.0.0")
      assert %{"error" => "NOT_AUTHENTICATED"} = json_response(resolve, 401)
    end

    test "a portal that cannot answer is 503", %{conn: conn} do
      PackagesPortalStub.set(%{user_roles: {:error, "timeout"}})
      assert %{"error" => "SERVICE_UNAVAILABLE"} = json_response(conn |> with_bearer(launch_token()) |> get("/api/v1/packages"), 503)
    end

    test "an expired, wrong-audience or unknown-portal bearer is 401, never the anonymous answer", %{conn: conn} do
      now = System.system_time(:second)
      expired = sign(:staging, claims(:staging, "researcher-dashboard", %{"iat" => now - 7200, "exp" => now - 1}))
      wrong_audience = sign(:staging, claims(:staging, "report-server"))

      for token <- [expired, wrong_audience, "not-a-token"] do
        assert %{"error" => "NOT_AUTHENTICATED"} = json_response(conn |> with_bearer(token) |> get("/api/v1/packages?portal=#{@server}"), 401)
      end

      System.delete_env(@db_env)
      assert %{"error" => "NOT_AUTHENTICATED"} = json_response(conn |> with_bearer(launch_token()) |> get("/api/v1/packages"), 401)
    end
  end

  describe "resolve" do
    defp resolve(conn, identity, version, token \\ launch_token()) do
      conn |> with_bearer(token) |> get("/api/v1/packages/resolve?identity=#{identity}&version=#{version}")
    end

    test "an official package is runnable", %{conn: conn} = context do
      %{official: %{package: p, version: v}} = catalog(context)

      assert %{
               "catalog_id" => id,
               "identity" => identity,
               "version" => "1.0.0",
               "checksum" => checksum,
               "expected_duration_seconds" => 60,
               "clue_prepull" => false,
               "archived" => false,
               "runnable" => true,
               "reason" => nil
             } = json_response(resolve(conn, p.identity, "1.0.0"), 200)

      assert {id, identity, checksum} == {p.id, p.identity, v.checksum}
    end

    test "a package the caller may not see is 404, the same as one that does not exist", %{conn: conn} = context do
      %{private: %{package: p}, ungranted: %{package: u}} = catalog(context)
      assert %{"error" => "NOT_FOUND"} = json_response(resolve(conn, p.identity, "1.0.0"), 404)
      assert %{"error" => "NOT_FOUND"} = json_response(resolve(build_conn(), u.identity, "1.0.0"), 404)
      assert %{"error" => "NOT_FOUND"} = json_response(resolve(build_conn(), "users/1/nothing", "1.0.0"), 404)
    end

    test "another portal's official package is 404", %{conn: conn} = context do
      %{elsewhere: %{package: e}} = catalog(context)
      assert %{"error" => "NOT_FOUND"} = json_response(resolve(conn, e.identity, "1.0.0"), 404)
    end

    test "an archived package still resolves, and is not runnable", %{conn: conn} = context do
      %{archived: %{package: p}} = catalog(context)
      assert %{"archived" => true, "runnable" => false, "reason" => "archived"} = json_response(resolve(conn, p.identity, "1.0.0"), 200)
    end

    test "a private own package runs only once unreviewed runs are enabled", %{conn: conn} = context do
      %{mine: %{package: p}} = catalog(context)
      assert %{"runnable" => false, "reason" => "not official" <> _} = json_response(resolve(conn, p.identity, "1.0.0"), 200)

      Application.put_env(:report_server, :packages, Keyword.put(Application.get_env(:report_server, :packages), :unreviewed_runs, true))
      assert %{"runnable" => true, "reason" => nil} = json_response(resolve(build_conn(), p.identity, "1.0.0"), 200)
    end

    test "a non-current version resolves with its own clue_prepull", %{conn: conn, other: other} = context do
      %{official: %{package: p}} = catalog(context)
      publish_fixture(other, %{"name" => "official", "version" => "2.0.0", "clue_prepull" => true})
      assert Repo.get!(Package, p.id).current_version == "1.0.0"

      assert %{"version" => "2.0.0", "clue_prepull" => true} = json_response(resolve(conn, p.identity, "2.0.0"), 200)
      assert %{"version" => "1.0.0", "clue_prepull" => false} = json_response(resolve(build_conn(), p.identity, "1.0.0"), 200)
    end

    test "needs a launch token, an identity and a version", %{conn: conn} do
      assert %{"error" => "NOT_AUTHENTICATED"} = json_response(get(conn, "/api/v1/packages/resolve?identity=users/1/x&version=1.0.0"), 401)
      assert %{"error" => "BAD_REQUEST"} = json_response(build_conn() |> with_bearer(launch_token()) |> get("/api/v1/packages/resolve?identity=users/1/x"), 400)
    end
  end
end
