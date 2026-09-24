defmodule ReportServerWeb.Api.V1.PackageControllerStateTest do
  use ReportServerWeb.ConnCase, async: false

  import Ecto.Query
  import ReportServer.PackagesFixtures

  alias ReportServer.{PackagesMemoryStore, PackagesPortalStub, Repo}
  alias ReportServer.Packages.{PackageEvent, PackageVersion}

  setup :register_and_put_bearer_token

  setup %{user: user} do
    {:ok, _} = PackagesMemoryStore.start()
    PackagesPortalStub.set(%{})
    on_exit(&PackagesPortalStub.reset/0)

    %{package: package} = publish_fixture(user)
    %{package: package, path: "/api/v1/packages/#{package.identity}"}
  end

  defp change(conn, path, state, body), do: post(conn, "#{path}/#{state}", body)
  defp events(package), do: Repo.all(from e in PackageEvent, where: e.package_id == ^package.id, order_by: e.id)
  defp later_events(package), do: package |> events() |> Enum.drop(1)
  defp as_publisher(user), do: user |> Ecto.Changeset.change(package_publisher: true) |> Repo.update!()

  describe "each state" do
    test "visibility moves to public with one audit row naming the previous value", %{conn: conn, path: path, package: package, user: user} do
      assert %{"visibility" => "public"} = json_response(change(conn, path, "visibility", %{visibility: "public"}), 200)
      assert [%{field: "visibility", previous_value: "private", new_value: "public", user_id: user_id}] = later_events(package)
      assert user_id == user.id
    end

    test "project visibility needs a grant, records the project, and leaving it clears the project", %{conn: conn, path: path, package: package} do
      PackagesPortalStub.set(%{allowed_project_ids: [20]})

      assert %{"visibility" => "project", "project_id" => 20} =
               json_response(change(conn, path, "visibility", %{visibility: "project", project_id: 20}), 200)

      assert %{"visibility" => "private", "project_id" => nil} = json_response(change(conn, path, "visibility", %{visibility: "private"}), 200)

      assert [
               %{field: "visibility", new_value: "project"},
               %{field: "project_id", previous_value: nil, new_value: "20"},
               %{field: "visibility", previous_value: "project", new_value: "private"},
               %{field: "project_id", previous_value: "20", new_value: nil}
             ] = later_events(package)
    end

    test "project visibility without a grant is 403", %{conn: conn, path: path} do
      PackagesPortalStub.set(%{allowed_project_ids: [21]})
      assert %{"error" => "FORBIDDEN"} = json_response(change(conn, path, "visibility", %{visibility: "project", project_id: 20}), 403)
    end

    test "archived moves, and the version stays", %{conn: conn, path: path, package: package} do
      assert %{"archived" => true} = json_response(change(conn, path, "archived", %{archived: true}), 200)
      assert [%{field: "archived", previous_value: "false", new_value: "true"}] = later_events(package)
      assert Repo.get_by!(PackageVersion, package_id: package.id, version: "1.0.0")
    end

    test "rolling current_version back leaves every version and stored object in place", %{conn: conn, path: path, package: package, user: user} do
      publish_fixture(user, %{"version" => "1.1.0"})
      stored = PackagesMemoryStore.objects()

      assert %{"current_version" => "1.0.0"} = json_response(change(conn, path, "current_version", %{current_version: "1.0.0"}), 200)
      assert %{field: "current_version", previous_value: "1.1.0", new_value: "1.0.0"} = List.last(events(package))
      assert Repo.aggregate(from(v in PackageVersion, where: v.package_id == ^package.id), :count) == 2
      assert PackagesMemoryStore.objects() == stored
    end

    test "an unknown version is 422", %{conn: conn, path: path} do
      assert %{"error" => "UNPROCESSABLE"} = json_response(change(conn, path, "current_version", %{current_version: "9.9.9"}), 422)
    end

    test "setting a value to itself writes nothing and succeeds", %{conn: conn, path: path, package: package} do
      assert json_response(change(conn, path, "visibility", %{visibility: "private"}), 200)
      assert json_response(change(conn, path, "current_version", %{current_version: "1.0.0"}), 200)
      assert later_events(package) == []
    end
  end

  describe "a project-maintained package" do
    setup %{user: user} do
      PackagesPortalStub.set(%{allowed_project_ids: [20]})
      %{package: package} = publish_fixture(user, %{"name" => "team"}, origin: "projects/20")
      %{team_path: "/api/v1/packages/#{package.identity}"}
    end

    test "is administered through a grant on its project", %{conn: conn, team_path: path} do
      assert %{"archived" => true} = json_response(change(conn, path, "archived", %{archived: true}), 200)
    end

    test "is refused without that grant", %{conn: conn, team_path: path} do
      PackagesPortalStub.set(%{allowed_project_ids: [21]})
      assert %{"error" => "FORBIDDEN"} = json_response(change(conn, path, "archived", %{archived: true}), 403)
    end

    test "is 503 when the portal cannot answer for the grant", %{conn: conn, team_path: path} do
      PackagesPortalStub.set(%{allowed_project_ids: {:error, "timeout"}})
      assert %{"error" => "SERVICE_UNAVAILABLE"} = json_response(change(conn, path, "archived", %{archived: true}), 503)
    end
  end

  describe "official" do
    test "a maintainer without the role is 403", %{conn: conn, path: path} do
      assert %{"error" => "FORBIDDEN"} = json_response(change(conn, path, "official", %{official: true}), 403)
    end

    test "the role holder sets it, which also makes the package public", %{conn: conn, path: path, package: package, user: user} do
      as_publisher(user)
      assert %{"official" => true, "visibility" => "public"} = json_response(change(conn, path, "official", %{official: true}), 200)
      assert [%{field: "official"}, %{field: "visibility", new_value: "public"}] = later_events(package)
    end

    test "the role holder need not administer the package", %{path: path, package: package, user: user} do
      publisher = ReportServer.AccountsFixtures.user_fixture(portal_server: user.portal_server, package_publisher: true)
      {raw, _} = ReportServer.AccountsFixtures.api_token_fixture(publisher)
      conn = build_conn() |> put_req_header("authorization", "Bearer #{raw}")

      assert %{"official" => true} = json_response(change(conn, path, "official", %{official: true}), 200)
      assert %{"error" => "FORBIDDEN"} = json_response(change(conn, path, "archived", %{archived: true}), 403)
      assert Repo.reload!(package).official
    end

    test "the role holder clears it, which leaves the package public; a maintainer may not", %{conn: conn, path: path, package: package, user: user} do
      as_publisher(user)
      assert json_response(change(conn, path, "official", %{official: true}), 200)
      assert %{"official" => false, "visibility" => "public"} = json_response(change(conn, path, "official", %{official: false}), 200)
      assert %{field: "official", previous_value: "true", new_value: "false"} = List.last(events(package))

      user |> Repo.reload!() |> Ecto.Changeset.change(package_publisher: false) |> Repo.update!()
      assert json_response(change(conn, path, "official", %{official: true}), 403)
    end

    test "setting it on a project-visible package clears the project", %{conn: conn, path: path, package: package, user: user} do
      PackagesPortalStub.set(%{allowed_project_ids: [20]})
      assert json_response(change(conn, path, "visibility", %{visibility: "project", project_id: 20}), 200)
      as_publisher(user)

      assert %{"official" => true, "visibility" => "public", "project_id" => nil} =
               json_response(change(conn, path, "official", %{official: true}), 200)

      assert [_, _, %{field: "official"}, %{field: "visibility", previous_value: "project"}, %{field: "project_id", previous_value: "20", new_value: nil}] =
               later_events(package)
    end

    test "setting official asks the portal nothing", %{conn: conn, path: path, user: user} do
      as_publisher(user)
      PackagesPortalStub.set(%{allowed_project_ids: fn _ -> raise "the portal was asked" end})
      assert json_response(change(conn, path, "official", %{official: true}), 200)
    end

    test "an official package cannot leave public", %{conn: conn, path: path, user: user} do
      as_publisher(user)
      assert json_response(change(conn, path, "official", %{official: true}), 200)
      assert %{"error" => "UNPROCESSABLE"} = json_response(change(conn, path, "visibility", %{visibility: "private"}), 422)
    end
  end

  describe "refusals" do
    test "a non-maintainer is 403", %{path: path, user: user} do
      other = ReportServer.AccountsFixtures.user_fixture(portal_server: user.portal_server)
      {raw, _} = ReportServer.AccountsFixtures.api_token_fixture(other)
      conn = build_conn() |> put_req_header("authorization", "Bearer #{raw}")
      assert %{"error" => "FORBIDDEN"} = json_response(change(conn, path, "archived", %{archived: true}), 403)
    end

    test "another portal's package is 404", %{conn: conn, path: path, package: package} do
      package |> Ecto.Changeset.change(portal_server: "ngss-assessment.portal.concord.org") |> Repo.update!()
      assert %{"error" => "NOT_FOUND"} = json_response(change(conn, path, "archived", %{archived: true}), 404)
    end

    test "an unknown state is 404, and a malformed value is 400", %{conn: conn, path: path} do
      assert %{"error" => "NOT_FOUND"} = json_response(change(conn, path, "maintainer", %{maintainer: "users/1"}), 404)
      assert %{"error" => "BAD_REQUEST"} = json_response(change(conn, path, "archived", %{archived: "yes"}), 400)
      assert %{"error" => "BAD_REQUEST"} = json_response(change(conn, path, "visibility", %{visibility: "project"}), 400)
      assert %{"error" => "BAD_REQUEST"} = json_response(change(conn, path, "visibility", %{visibility: "project", project_id: 3_000_000_000}), 400)
    end

    test "a malformed identity is 404", %{conn: conn} do
      assert %{"error" => "NOT_FOUND"} = json_response(change(conn, "/api/v1/packages/groups/1/x", "archived", %{archived: true}), 404)
    end

    test "without a token is 401", %{path: path} do
      assert %{"error" => "NOT_AUTHENTICATED"} = json_response(change(build_conn(), path, "archived", %{archived: true}), 401)
    end
  end

end
