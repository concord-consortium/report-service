defmodule ReportServerWeb.Api.V1.PackageControllerValidateTest do
  use ReportServerWeb.ConnCase, async: false

  import ReportServer.PackagesFixtures

  alias ReportServer.{PackagesMemoryStore, PackagesPortalStub, Repo}
  alias ReportServer.Packages.{Package, PackageEvent, PackageVersion}

  setup :register_and_put_bearer_token

  setup do
    {:ok, _} = PackagesMemoryStore.start()
    PackagesPortalStub.set(%{})
    on_exit(&PackagesPortalStub.reset/0)
  end

  defp post_zip(conn, path, body, query \\ "", content_type \\ "application/zip") do
    conn
    |> put_req_header("content-type", content_type)
    |> put_req_header("content-length", Integer.to_string(byte_size(body)))
    |> post(path <> query, body)
  end

  defp validate(conn, body, query \\ "", content_type \\ "application/zip"),
    do: post_zip(conn, "/api/v1/packages/validate", body, query, content_type)

  # a fresh conn with the same bearer, since a conn is spent once it has been sent
  defp again(conn), do: build_conn() |> put_req_header("authorization", hd(get_req_header(conn, "authorization")))

  defp written,
    do: {Repo.aggregate(Package, :count), Repo.aggregate(PackageVersion, :count), Repo.aggregate(PackageEvent, :count), PackagesMemoryStore.objects()}

  test "answers what a publish would record and writes nothing", %{conn: conn, user: user} do
    before = written()
    body = package_zip()

    assert json_response(validate(conn, body), 200) == %{
             "identity" => "users/#{user.portal_user_id}/counts",
             "version" => "1.0.0",
             "checksum" => "sha256:" <> Base.encode16(:crypto.hash(:sha256, body), case: :lower),
             "visibility" => "private",
             "already_published" => false,
             "publishing_unavailable" => nil
           }

    assert written() == before
  end

  test "gives publish's refusal for the same zip, with the same status and body", %{conn: conn} do
    link = File.read!(Path.expand("../../../support/fixtures/packages/symlink-entrypoint.zip", __DIR__))

    for {body, content_type} <- [
          {package_zip(%{"expected_duration_seconds" => 7_201}), "application/zip"},
          {package_zip(%{"name" => "Bad"}), "application/zip"},
          {link, "application/zip"},
          {package_zip(), "text/plain"}
        ] do
      validated = validate(again(conn), body, "", content_type)
      published = post_zip(again(conn), "/api/v1/packages", body, "", content_type)
      assert validated.status in [400, 422]
      assert {validated.status, validated.resp_body} == {published.status, published.resp_body}
    end
  end

  test "a new package under a project the caller holds no grant on is 403", %{conn: conn} do
    PackagesPortalStub.set(%{allowed_project_ids: [21]})
    assert %{"error" => "FORBIDDEN"} = json_response(validate(conn, package_zip(), "?origin=projects/20"), 403)

    PackagesPortalStub.set(%{allowed_project_ids: [20]})
    assert %{"identity" => "projects/20/counts"} = json_response(validate(again(conn), package_zip(), "?origin=projects/20"), 200)
  end

  test "an already-published version is reported, not refused", %{conn: conn, user: user} do
    publish_fixture(user)
    assert %{"already_published" => true} = json_response(validate(conn, package_zip()), 200)
    assert %{"already_published" => false} = json_response(validate(again(conn), package_zip(%{"version" => "1.0.1"})), 200)
  end

  test "a portal with no bucket is reported, while publish refuses it and every other check still runs", %{conn: conn, user: user} do
    user |> Ecto.Changeset.change(portal_server: "unconfigured.example.org") |> Repo.update!()

    assert %{"publishing_unavailable" => "publishing is not configured for unconfigured.example.org"} =
             json_response(validate(conn, package_zip()), 200)

    assert %{"error" => "UNPROCESSABLE", "message" => "publishing is not configured for unconfigured.example.org"} =
             json_response(post_zip(again(conn), "/api/v1/packages", package_zip()), 422)

    assert %{"error" => "UNPROCESSABLE"} = json_response(validate(again(conn), package_zip(%{"expected_duration_seconds" => 7_201})), 422)

    PackagesPortalStub.set(%{allowed_project_ids: [21]})
    assert %{"error" => "FORBIDDEN"} = json_response(validate(again(conn), package_zip(), "?origin=projects/20"), 403)
  end

  test "official=true needs the publisher role, and with it answers public", %{conn: conn, user: user} do
    assert %{"error" => "FORBIDDEN"} = json_response(validate(conn, package_zip(), "?official=true"), 403)

    user |> Ecto.Changeset.change(package_publisher: true) |> Repo.update!()
    assert %{"visibility" => "public"} = json_response(validate(again(conn), package_zip(), "?official=true"), 200)
  end

  test "needs a token" do
    assert %{"error" => "NOT_AUTHENTICATED"} = json_response(validate(build_conn(), package_zip()), 401)
  end
end
