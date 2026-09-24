defmodule ReportServerWeb.Api.V1.PackageControllerCreateTest do
  use ReportServerWeb.ConnCase, async: false

  import Ecto.Query
  import ReportServer.PackagesFixtures

  alias ReportServer.{PackagesMemoryStore, PackagesPortalStub, Repo}
  alias ReportServer.Packages.{Package, PackageEvent, PackageVersion}

  setup :register_and_put_bearer_token

  setup do
    {:ok, _} = PackagesMemoryStore.start()
    PackagesPortalStub.set(%{})
    on_exit(&PackagesPortalStub.reset/0)
  end

  defp publish(conn, body, query \\ "") do
    conn
    |> put_req_header("content-type", "application/zip")
    |> put_req_header("content-length", Integer.to_string(byte_size(body)))
    |> post("/api/v1/packages" <> query, body)
  end

  defp events(package_id), do: Repo.all(from e in PackageEvent, where: e.package_id == ^package_id, order_by: e.id)

  describe "a first publish" do
    test "creates a private package whose pointer is the version, and stores the zip and its checksum", %{conn: conn, user: user} do
      body = package_zip()
      conn = publish(conn, body)

      checksum = "sha256:" <> Base.encode16(:crypto.hash(:sha256, body), case: :lower)
      identity = "users/#{user.portal_user_id}/counts"

      assert %{
               "identity" => ^identity,
               "version" => "1.0.0",
               "checksum" => ^checksum,
               "visibility" => "private",
               "official" => false,
               "current_version" => "1.0.0",
               "catalog_id" => catalog_id
             } = json_response(conn, 201)

      package = Repo.get!(Package, catalog_id)
      assert package.portal_server == user.portal_server
      assert package.maintainer == "users/#{user.portal_user_id}"

      version = Repo.get_by!(PackageVersion, package_id: catalog_id)
      assert version.published_by == user.id
      assert version.title == "Counts"
      assert version.urls == %{"all" => [], "any" => ["*question-interactives/*"], "none" => []}

      assert PackagesMemoryStore.objects() == %{
               {"runner-bucket-learn", "packages/#{identity}/1.0.0.zip"} => body,
               {"runner-bucket-learn", "packages/#{identity}/1.0.0.sha256"} => checksum
             }

      assert [%{field: "current_version", previous_value: nil, new_value: "1.0.0", user_id: user_id}] = events(catalog_id)
      assert user_id == user.id
    end

    test "stores a Go-written archive byte for byte", %{conn: conn, user: user} do
      body = File.read!(Path.expand("../../../support/fixtures/packages/class-counts-go-1.0.6.zip", __DIR__))
      conn = publish(conn, body)
      assert %{"checksum" => checksum} = json_response(conn, 201)

      prefix = "packages/users/#{user.portal_user_id}/class-counts/1.0.6"
      objects = PackagesMemoryStore.objects()
      assert objects[{"runner-bucket-learn", prefix <> ".zip"}] == body
      assert objects[{"runner-bucket-learn", prefix <> ".sha256"}] == checksum
    end
  end

  describe "a later version" do
    test "the same version again is 409 and stores nothing", %{conn: conn} do
      assert json_response(publish(conn, package_zip()), 201)
      stored = PackagesMemoryStore.objects()

      conn = publish(conn, package_zip(%{"title" => "Changed"}))
      assert %{"error" => "ALREADY_EXISTS"} = json_response(conn, 409)
      assert PackagesMemoryStore.objects() == stored
    end

    test "a new version of a private package moves the pointer, with an audit row naming the previous", %{conn: conn} do
      %{"catalog_id" => id} = json_response(publish(conn, package_zip()), 201)
      assert %{"current_version" => "1.1.0"} = json_response(publish(conn, package_zip(%{"version" => "1.1.0"})), 201)

      assert [_, %{field: "current_version", previous_value: "1.0.0", new_value: "1.1.0"}] = events(id)
    end

    test "a new version of a public package leaves the pointer", %{conn: conn} do
      %{"catalog_id" => id} = json_response(publish(conn, package_zip()), 201)
      Repo.get!(Package, id) |> Ecto.Changeset.change(visibility: "public") |> Repo.update!()

      assert %{"current_version" => "1.0.0"} = json_response(publish(conn, package_zip(%{"version" => "1.1.0"})), 201)
      assert length(events(id)) == 1
      assert Repo.get_by!(PackageVersion, package_id: id, version: "1.1.0")
    end

    test "two concurrent publishes of one version: exactly one wins, and the stored bytes are its", %{conn: conn, raw_token: raw_token} do
      assert json_response(publish(conn, package_zip()), 201)
      bodies = for title <- ["A", "B"], do: package_zip(%{"version" => "2.0.0", "title" => title})

      results =
        bodies
        |> Enum.map(fn body ->
          Task.async(fn ->
            build_conn()
            |> put_req_header("authorization", "Bearer #{raw_token}")
            |> publish(body)
            |> then(&{&1.status, body})
          end)
        end)
        |> Enum.map(&Task.await/1)

      assert Enum.sort(Enum.map(results, &elem(&1, 0))) == [201, 409]
      {201, winner} = Enum.find(results, &(elem(&1, 0) == 201))

      assert Enum.find_value(PackagesMemoryStore.objects(), fn {{_, key}, body} ->
               String.ends_with?(key, "/2.0.0.zip") && body
             end) == winner
    end
  end

  # Under the shared sandbox the two share one connection, so this asserts the outcome rather
  # than the InnoDB unique-index wait.
  test "two concurrent first publishes of one package both land, in one package row", %{raw_token: raw_token} do
    ["1.0.0", "1.1.0"]
    |> Enum.map(fn version ->
      Task.async(fn ->
        build_conn()
        |> put_req_header("authorization", "Bearer #{raw_token}")
        |> publish(package_zip(%{"version" => version}))
        |> Map.fetch!(:status)
      end)
    end)
    |> Enum.map(&Task.await/1)
    |> then(&assert(&1 == [201, 201]))

    assert Repo.aggregate(Package, :count) == 1
    assert Repo.aggregate(PackageVersion, :count) == 2
  end

  describe "origin and role" do
    test "publishes under a project the caller holds a grant on", %{conn: conn} do
      PackagesPortalStub.set(%{allowed_project_ids: [20]})
      conn = publish(conn, package_zip(), "?origin=projects/20")
      assert %{"identity" => "projects/20/counts"} = json_response(conn, 201)
      assert Repo.get_by!(Package, identity: "projects/20/counts").maintainer == "projects/20"
    end

    test "a project without a grant is 403 and writes nothing", %{conn: conn} do
      PackagesPortalStub.set(%{allowed_project_ids: [21]})
      assert %{"error" => "FORBIDDEN"} = json_response(publish(conn, package_zip(), "?origin=projects/20"), 403)
      assert Repo.aggregate(Package, :count) == 0
      assert PackagesMemoryStore.objects() == %{}
    end

    test "a portal that cannot answer for project grants is 503", %{conn: conn} do
      PackagesPortalStub.set(%{allowed_project_ids: {:error, "timeout"}})
      assert %{"error" => "SERVICE_UNAVAILABLE"} = json_response(publish(conn, package_zip(), "?origin=projects/20"), 503)
    end

    test "a user origin in the query is refused, since it is always the caller's own", %{conn: conn} do
      assert %{"error" => "UNPROCESSABLE"} = json_response(publish(conn, package_zip(), "?origin=users/1"), 422)
    end

    test "official=true without the publisher role is 403", %{conn: conn} do
      assert %{"error" => "FORBIDDEN"} = json_response(publish(conn, package_zip(), "?official=true"), 403)
    end

    test "official=true from the role makes the package official and public, with its audit rows", %{conn: conn, user: user} do
      user |> Ecto.Changeset.change(package_publisher: true) |> Repo.update!()
      conn = publish(conn, package_zip(), "?official=true")

      assert %{"official" => true, "visibility" => "public", "current_version" => "1.0.0", "catalog_id" => id} =
               json_response(conn, 201)

      assert [
               %{field: "official", previous_value: "false", new_value: "true"},
               %{field: "visibility", previous_value: "private", new_value: "public"},
               %{field: "current_version", new_value: "1.0.0"}
             ] = events(id)
    end

    test "official=true on a later version makes an existing package official", %{conn: conn, user: user} do
      %{"catalog_id" => id} = json_response(publish(conn, package_zip()), 201)
      user |> Ecto.Changeset.change(package_publisher: true) |> Repo.update!()

      conn = publish(conn, package_zip(%{"version" => "1.1.0"}), "?official=true")
      assert %{"official" => true, "visibility" => "public", "current_version" => "1.1.0"} = json_response(conn, 201)
      assert ["current_version", "official", "visibility", "current_version"] = Enum.map(events(id), & &1.field)
    end

    test "official=true on a later version of a public package leaves the pointer", %{conn: conn, user: user} do
      %{"catalog_id" => id} = json_response(publish(conn, package_zip()), 201)
      Repo.get!(Package, id) |> Ecto.Changeset.change(visibility: "public") |> Repo.update!()
      user |> Ecto.Changeset.change(package_publisher: true) |> Repo.update!()

      conn = publish(conn, package_zip(%{"version" => "1.1.0"}), "?official=true")
      assert %{"official" => true, "current_version" => "1.0.0"} = json_response(conn, 201)
    end

    test "another user's package is 403", %{conn: conn, user: user} do
      assert json_response(publish(conn, package_zip()), 201)

      other = ReportServer.AccountsFixtures.user_fixture(portal_user_id: user.portal_user_id + 1)
      Repo.update_all(from(p in Package), set: [maintainer: "users/#{other.portal_user_id}"])

      assert %{"error" => "FORBIDDEN"} = json_response(publish(conn, package_zip(%{"version" => "1.1.0"})), 403)
    end
  end

  describe "refusals" do
    test "a portal with no bucket is 422 naming it", %{conn: conn, user: user} do
      user |> Ecto.Changeset.change(portal_server: "unconfigured.example.org") |> Repo.update!()
      assert %{"error" => "UNPROCESSABLE", "message" => message} = json_response(publish(conn, package_zip()), 422)
      assert message =~ "unconfigured.example.org"
    end

    test "an S3 failure rolls the rows back", %{conn: conn} do
      PackagesMemoryStore.fail!()
      assert %{"error" => "SERVICE_UNAVAILABLE"} = json_response(publish(conn, package_zip()), 503)
      assert Repo.aggregate(Package, :count) == 0
      assert Repo.aggregate(PackageVersion, :count) == 0
      assert Repo.aggregate(PackageEvent, :count) == 0
    end

    test "a lock wait timeout is a retryable 503, and other database errors still raise", %{conn: conn} do
      PackagesMemoryStore.raise!(%MyXQL.Error{message: "Lock wait timeout exceeded", mysql: %{code: 1205, name: :ER_LOCK_WAIT_TIMEOUT}})
      assert %{"error" => "SERVICE_UNAVAILABLE", "message" => message} = json_response(publish(conn, package_zip()), 503)
      assert message =~ "retry"

      PackagesMemoryStore.raise!(%MyXQL.Error{message: "boom", mysql: %{code: 1064, name: :ER_PARSE_ERROR}})
      assert_raise MyXQL.Error, fn -> publish(conn, package_zip()) end
    end

    test "a body longer than it declares is cut off at 10 MiB and refused", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/zip")
        |> put_req_header("content-length", "100")
        |> post("/api/v1/packages", :binary.copy(<<0>>, 10 * 1024 * 1024 + 1))

      assert %{"error" => "UNPROCESSABLE", "message" => "the archive exceeds 10 MiB"} = json_response(conn, 422)
    end

    test "an invalid manifest is 422 naming it", %{conn: conn} do
      assert %{"error" => "UNPROCESSABLE", "message" => "manifest.json: " <> _} =
               json_response(publish(conn, package_zip(%{"official" => true})), 422)
    end

    test "a body without a Content-Length, as a chunked upload sends, is 400", %{conn: conn} do
      conn = conn |> put_req_header("content-type", "application/zip") |> post("/api/v1/packages", package_zip())
      assert %{"error" => "BAD_REQUEST", "message" => "the request must declare its Content-Length"} = json_response(conn, 400)
    end

    test "a declared length over 10 MiB is refused before the body is read", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/zip")
        |> put_req_header("content-length", Integer.to_string(10 * 1024 * 1024 + 1))
        |> post("/api/v1/packages", package_zip())

      assert %{"error" => "UNPROCESSABLE", "message" => "the archive exceeds 10 MiB"} = json_response(conn, 422)
    end

    test "a content type other than application/zip is 400", %{conn: conn} do
      conn = conn |> put_req_header("content-type", "application/octet-stream") |> post("/api/v1/packages", package_zip())
      assert %{"error" => "BAD_REQUEST"} = json_response(conn, 400)
    end

    test "without a token, or with an unknown one, is 401" do
      assert %{"error" => "NOT_AUTHENTICATED"} = json_response(publish(build_conn(), package_zip()), 401)

      conn = build_conn() |> put_req_header("authorization", "Bearer ccd_nope")
      assert %{"error" => "NOT_AUTHENTICATED"} = json_response(publish(conn, package_zip()), 401)
    end
  end
end
