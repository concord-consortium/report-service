defmodule ReportServerWeb.Api.AuthPlugTest do
  use ReportServerWeb.ConnCase

  import ReportServer.AccountsFixtures

  alias ReportServer.Accounts
  alias ReportServer.Accounts.ApiToken
  alias ReportServer.Repo

  @not_authenticated %{
    "error" => "NOT_AUTHENTICATED",
    "message" => "You must supply a valid API token."
  }

  describe "bearer authentication" do
    test "rejects a request with no authorization header", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/reports")

      assert json_response(conn, 401) == @not_authenticated
    end

    test "rejects a garbage token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer ccd_nonsense")
        |> get(~p"/api/v1/reports")

      assert json_response(conn, 401) == @not_authenticated
    end

    test "rejects a revoked token", %{conn: conn} do
      user = user_fixture()
      {raw_token, api_token} = api_token_fixture(user)
      {:ok, _revoked} = Accounts.revoke_api_token(api_token, user.id)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_token}")
        |> get(~p"/api/v1/reports")

      assert json_response(conn, 401) == @not_authenticated
    end

    test "rejects a valid token whose user fails the role gate", %{conn: conn} do
      user =
        user_fixture(%{
          portal_is_admin: false,
          portal_is_project_admin: false,
          portal_is_project_researcher: false
        })

      {raw_token, _api_token} = api_token_fixture(user)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_token}")
        |> get(~p"/api/v1/reports")

      # indistinguishable from a bad token: no role leak
      assert json_response(conn, 401) == @not_authenticated
    end

    test "rejects a non-bearer scheme", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Basic xyz")
        |> get(~p"/api/v1/reports")

      assert json_response(conn, 401) == @not_authenticated
    end

    test "accepts a valid token, assigns the owning user and touches the token" do
      %{conn: conn, user: user, api_token: api_token} =
        register_and_put_bearer_token(%{conn: build_conn()})

      assert Repo.get!(ApiToken, api_token.id).last_used_at == nil

      conn = get(conn, ~p"/api/v1/reports")

      assert json_response(conn, 200) == %{"items" => [], "next_page_token" => nil}
      assert conn.assigns.current_user.id == user.id
      assert Repo.get!(ApiToken, api_token.id).last_used_at != nil
    end
  end

  describe "contract error shape for unrouted and raised errors" do
    test "an unknown /api/v1 path renders the contract 404 with no Accept header", %{conn: conn} do
      conn = get(conn, "/api/v1/nonexistent")

      assert json_response(conn, 404) == %{"error" => "NOT_FOUND", "message" => "Not found."}
    end

    test "an unknown /api/v1 path renders the contract 404 with Accept: application/json", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept", "application/json")
        |> get("/api/v1/nonexistent")

      assert json_response(conn, 404) == %{"error" => "NOT_FOUND", "message" => "Not found."}
    end

    test "an unknown /api/v1 path renders the contract 404 with Accept: text/html", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept", "text/html")
        |> get("/api/v1/nonexistent")

      assert json_response(conn, 404) == %{"error" => "NOT_FOUND", "message" => "Not found."}
    end

    test "a routed API request with Accept: text/html and no token gets the contract 401", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept", "text/html")
        |> get(~p"/api/v1/reports")

      assert json_response(conn, 401) == @not_authenticated
    end

    test "a malformed JSON body raised before routing renders the contract 400", %{conn: conn} do
      {400, _headers, body} =
        assert_error_sent 400, fn ->
          conn
          |> put_req_header("accept", "application/json")
          |> put_req_header("content-type", "application/json")
          |> post("/auth/cli/token", "{not json")
        end

      assert Jason.decode!(body) == %{"error" => "BAD_REQUEST", "message" => "Bad Request"}
    end
  end

  describe "ErrorJSON contract clause" do
    test "renders the contract SERVER_ERROR shape for an API path, with no exception detail" do
      assert ReportServerWeb.ErrorJSON.render("500.json", %{
               conn: %Plug.Conn{request_path: "/api/v1/reports"}
             }) == %{error: "SERVER_ERROR", message: "Internal Server Error"}
    end

    test "covers the code-exchange endpoint" do
      assert ReportServerWeb.ErrorJSON.render("400.json", %{
               conn: %Plug.Conn{request_path: "/auth/cli/token"}
             }) == %{error: "BAD_REQUEST", message: "Bad Request"}
    end

    test "leaves non-API paths on the existing ErrorJSON shape" do
      assert ReportServerWeb.ErrorJSON.render("404.json", %{
               conn: %Plug.Conn{request_path: "/reports"}
             }) == %{errors: %{detail: "Not Found"}}

      assert ReportServerWeb.ErrorJSON.render("500.json", %{}) ==
               %{errors: %{detail: "Internal Server Error"}}
    end

    test "handles request paths shorter than the API prefix without crashing" do
      assert ReportServerWeb.ErrorJSON.render("404.json", %{
               conn: %Plug.Conn{request_path: "/"}
             }) == %{errors: %{detail: "Not Found"}}

      assert ReportServerWeb.ErrorJSON.render("500.json", %{
               conn: %Plug.Conn{request_path: ""}
             }) == %{errors: %{detail: "Internal Server Error"}}
    end
  end
end
