defmodule ReportServerWeb.Api.V1.FilterOptionsControllerTest do
  use ReportServerWeb.ConnCase

  @moduletag :portal_db

  import ReportServer.AccountsFixtures

  alias ReportServer.{AccountsFixtures, PortalFixture}

  @server PortalFixture.server()
  @envelope ~w(items next_page_token count count_skipped count_skipped_reason)

  defp conn_for(conn, attrs) do
    user = user_fixture(Map.merge(%{portal_server: @server}, attrs))
    {raw_token, _} = AccountsFixtures.api_token_fixture(user)
    Plug.Conn.put_req_header(conn, "authorization", "Bearer #{raw_token}")
  end

  defp admin_conn(conn),
    do: conn_for(conn, %{portal_user_id: 555, portal_is_project_admin: true, portal_is_project_researcher: false})

  defp researcher_conn(conn), do: conn_for(conn, %{portal_user_id: 557, portal_is_project_researcher: true})

  defp post_options(conn, body), do: post(conn, ~p"/api/v1/reports/filter-options", body)

  defp body_for(conn, body) do
    conn |> post_options(body) |> json_response(200)
  end

  defp labels(conn, body), do: body_for(conn, body)["items"] |> Enum.map(& &1["label"])
  defp ids(conn, body), do: body_for(conn, body)["items"] |> Enum.map(& &1["id"])

  describe "the envelope" do
    test "carries the paged shape plus the three count fields", %{conn: conn} do
      body = body_for(admin_conn(conn), %{"dimension" => "class"})

      assert Enum.sort(Map.keys(body)) == Enum.sort(@envelope)
      assert body["count"] == 9
      assert body["count_skipped"] == false
      assert body["count_skipped_reason"] == nil
      assert body["next_page_token"] == nil
      assert Enum.all?(body["items"], &(is_binary(&1["id"]) and is_binary(&1["label"])))
    end

    test "an item is exactly an id and a label", %{conn: conn} do
      [first | _] = body_for(admin_conn(conn), %{"dimension" => "cohort"})["items"]

      assert first == %{"id" => "1", "label" => "Cohort One"}
    end
  end

  describe "paging" do
    test "a page token walks the dimension and never repeats", %{conn: conn} do
      conn = admin_conn(conn)

      {visited, tokens} =
        Enum.reduce_while(1..20, {[], nil, []}, fn _, {acc, token, tokens} ->
          body = body_for(conn, %{"dimension" => "class", "limit" => 2, "page_token" => token})
          acc = acc ++ Enum.map(body["items"], & &1["id"])

          case body["next_page_token"] do
            nil -> {:halt, {acc, tokens}}
            next -> {:cont, {acc, next, [next | tokens]}}
          end
        end)

      assert visited == ids(conn, %{"dimension" => "class", "limit" => 100})
      assert length(Enum.uniq(tokens)) == length(tokens)
    end

    test "limit is accepted as a JSON number and as a string", %{conn: conn} do
      conn = admin_conn(conn)

      assert length(body_for(conn, %{"dimension" => "class", "limit" => 2})["items"]) == 2
      assert length(body_for(conn, %{"dimension" => "class", "limit" => "2"})["items"]) == 2
    end

    test "paging parameters are read from the query string as well as the body", %{conn: conn} do
      conn = admin_conn(conn)
      body = %{"dimension" => "class"}

      unpaged = body_for(conn, body)
      assert length(unpaged["items"]) == 9
      assert unpaged["next_page_token"] == nil

      first =
        conn
        |> post(~p"/api/v1/reports/filter-options?limit=2", body)
        |> json_response(200)

      assert length(first["items"]) == 2
      assert is_binary(first["next_page_token"])

      second =
        conn
        |> post(~p"/api/v1/reports/filter-options?limit=2&page_token=#{first["next_page_token"]}", body)
        |> json_response(200)

      assert length(second["items"]) == 2
      assert second["items"] == Enum.slice(unpaged["items"], 2, 2)
    end

    test "a malformed page token is a client error", %{conn: conn} do
      body = admin_conn(conn) |> post_options(%{"dimension" => "class", "page_token" => "!!"}) |> json_response(400)

      assert body["error"] == "BAD_REQUEST"
      assert body["message"] =~ "page_token"
    end
  end

  describe "the count's three states" do
    test "a first page counts, a later page does not, and the flag overrides both", %{conn: conn} do
      conn = admin_conn(conn)
      first = body_for(conn, %{"dimension" => "class", "limit" => 2})

      assert first["count"] == 9
      assert first["count_skipped"] == false

      token = first["next_page_token"]
      later = body_for(conn, %{"dimension" => "class", "limit" => 2, "page_token" => token})

      assert later["count"] == nil
      assert later["count_skipped"] == false
      assert later["count_skipped_reason"] == nil

      asked = body_for(conn, %{"dimension" => "class", "limit" => 2, "page_token" => token, "include_count" => true})

      assert asked["count"] == 9

      declined = body_for(conn, %{"dimension" => "class", "limit" => 2, "include_count" => false})

      assert declined["count"] == nil
      assert declined["count_skipped"] == false
    end

    test "a refused count is null with the flag set and a reason", %{conn: conn} do
      body = body_for(admin_conn(conn), %{"dimension" => "student"})

      assert body["count"] == nil
      assert body["count_skipped"] == true
      assert body["count_skipped_reason"] =~ "unbounded"
    end
  end

  describe "validation" do
    test "an unknown dimension is a client error naming the valid ones", %{conn: conn} do
      body = admin_conn(conn) |> post_options(%{"dimension" => "nope"}) |> json_response(400)

      assert body["message"] =~ "dimension must be one of"
      assert body["message"] =~ "class"
      assert body["message"] =~ "app"
    end

    test "a missing dimension is a client error", %{conn: conn} do
      body = admin_conn(conn) |> post_options(%{}) |> json_response(400)

      assert body["message"] =~ "dimension is required"
    end

    test "a non-string dimension is reported as invalid, not as missing", %{conn: conn} do
      body = admin_conn(conn) |> post_options(%{"dimension" => 5}) |> json_response(400)

      assert body["message"] =~ "dimension must be one of"
    end

    test "a malformed include_count is a client error", %{conn: conn} do
      body =
        admin_conn(conn)
        |> post_options(%{"dimension" => "class", "include_count" => "yes"})
        |> json_response(400)

      assert body["message"] =~ "include_count must be true or false"
    end

    test "an overlong search is a client error", %{conn: conn} do
      body =
        admin_conn(conn)
        |> post_options(%{"dimension" => "class", "search" => String.duplicate("x", 201)})
        |> json_response(400)

      assert body["message"] =~ "search must be at most"
    end

    test "a non-integer id is a client error, not a crash", %{conn: conn} do
      body =
        admin_conn(conn)
        |> post_options(%{"dimension" => "student", "report_filter" => %{"class" => ["abc"]}})
        |> json_response(400)

      assert body["message"] =~ "class values must be integer ids"
    end

    test "a non-string state value is a client error", %{conn: conn} do
      body =
        admin_conn(conn)
        |> post_options(%{"dimension" => "country", "report_filter" => %{"state" => [5]}})
        |> json_response(400)

      assert body["message"] =~ "state values must be strings"
    end

    test "an unknown report slug is not found", %{conn: conn} do
      conn = admin_conn(conn) |> post_options(%{"dimension" => "class", "report_slug" => "no-such"})

      assert json_response(conn, 404)["error"] == "NOT_FOUND"
    end

    test "a dimension the report does not filter on is a client error", %{conn: conn} do
      body =
        admin_conn(conn)
        |> post_options(%{"dimension" => "student", "report_slug" => "school-metrics"})
        |> json_response(400)

      assert body["message"] =~ "does not filter on student"
    end

    test "a malformed exclude_internal is a client error, not a silent false", %{conn: conn} do
      # "true" as a string is the common JSON mistake, and treating it as false quietly hands back
      # the internal teachers the caller asked to exclude.
      body = %{"dimension" => "teacher", "report_filter" => %{"exclude_internal" => "true"}}

      assert admin_conn(conn) |> post_options(body) |> json_response(400) |> Map.get("message") ==
               "exclude_internal must be true or false"
    end

    test "a wrong-typed field is a client error naming it, not a crash", %{conn: conn} do
      conn = admin_conn(conn)

      cases = [
        {%{"dimension" => "class", "report_filter" => "not-an-object"}, "report_filter must be an object"},
        {%{"dimension" => "student", "report_filter" => %{"class" => 5}}, "class must be a list or null"},
        {%{"dimension" => "class", "report_slug" => 5}, "report_slug must be a string"},
        {%{"dimension" => "class", "search" => 5}, "search must be a string"}
      ]

      for {body, message} <- cases do
        assert conn |> post_options(body) |> json_response(400) |> Map.get("message") == message
      end
    end

    test "a dimension the report does filter on is accepted", %{conn: conn} do
      assert %{"items" => _} =
               body_for(admin_conn(conn), %{"dimension" => "class", "report_slug" => "student-actions"})
    end
  end

  describe "the report filter" do
    test "fields the API emits on every run are accepted", %{conn: conn} do
      round_tripped = %{
        "filters" => ["class"],
        "start_date" => "2020-01-01",
        "end_date" => "2020-12-31",
        "hide_names" => false,
        "exclude_internal" => false,
        "app" => [],
        "cohort" => nil,
        "state" => nil
      }

      conn = admin_conn(conn)

      assert ids(conn, %{"dimension" => "class", "report_filter" => round_tripped}) ==
               ids(conn, %{"dimension" => "class"})
    end

    test "an unknown key inside the filter is ignored", %{conn: conn} do
      conn = admin_conn(conn)
      body = %{"dimension" => "class", "report_filter" => %{"invented_later" => [1]}}

      assert ids(conn, body) == ids(conn, %{"dimension" => "class"})
    end

    test "null and an empty list mean different things", %{conn: conn} do
      conn = admin_conn(conn)
      unset = ids(conn, %{"dimension" => "student", "report_filter" => %{"class" => nil}})

      assert unset == ids(conn, %{"dimension" => "student"})
      assert ids(conn, %{"dimension" => "student", "report_filter" => %{"class" => []}}) == []
    end

    test "a narrowing selection narrows", %{conn: conn} do
      narrowed = labels(admin_conn(conn), %{"dimension" => "student", "report_filter" => %{"class" => [601]}})

      assert "Stu One <101>" in narrowed
      refute "Stu Three <103>" in narrowed
    end

    test "exclude_internal narrows the teacher dimension", %{conn: conn} do
      conn = admin_conn(conn)
      all = labels(conn, %{"dimension" => "teacher"})
      excluded = labels(conn, %{"dimension" => "teacher", "report_filter" => %{"exclude_internal" => true}})

      assert "Eve Internal <eve@concord.org>" in all
      refute "Eve Internal <eve@concord.org>" in excluded
    end

    test "search narrows and is neither an injection nor a wildcard escape hatch", %{conn: conn} do
      conn = admin_conn(conn)

      assert labels(conn, %{"dimension" => "class", "search" => "lincoln"}) ==
               ["Lincoln High (sec)", "Lincoln High (sec)", "Lincoln High (sec)"]

      assert labels(conn, %{"dimension" => "class", "search" => "' OR '1'='1"}) == []
      # A portal dimension interpolates the text into LIKE, where these are wildcards; a static one
      # compares it as a substring, where they are not. The same search has to mean the same thing.
      for wildcard <- ["%", "%%", "_"] do
        assert labels(conn, %{"dimension" => "class", "search" => wildcard}) == []
      end

      # And a literal underscore still matches the one application whose name carries one, which is
      # what tells "escaped" apart from "stripped".
      assert labels(conn, %{"dimension" => "app", "search" => "_"}) == ["Activity_Player"]
      assert labels(conn, %{"dimension" => "app", "search" => "%"}) == []
    end
  end

  describe "privacy" do
    test "a researcher gets id-shaped student labels whatever the request asks for", %{conn: conn} do
      body = %{"dimension" => "student", "report_filter" => %{"hide_names" => false}}

      assert labels(researcher_conn(conn), body) == ["101", "102", "103", "104"]
    end

    test "an admin sees the names", %{conn: conn} do
      assert "Stu One <101>" in labels(admin_conn(conn), %{"dimension" => "student"})
    end
  end

  describe "static dimensions" do
    test "every caller who may use it at all sees the same options", %{conn: conn} do
      as_admin = labels(admin_conn(conn), %{"dimension" => "app"})
      as_researcher = labels(researcher_conn(conn), %{"dimension" => "app"})

      assert as_admin == as_researcher
      assert as_admin != []
    end

    # A static vocabulary lives in this application's own code and needs no scoping, so a portal
    # outage must not take it down. The pair is the assertion: the permission lookup raises on an
    # unreachable portal, so a portal dimension is a 500 and a static one must not be.
    test "app is served when the portal is unreachable, and a portal dimension is not", %{conn: conn} do
      conn = conn_for(conn, %{portal_server: "portal-unreachable.example.com", portal_user_id: 559, portal_is_project_admin: true})

      body = conn |> post_options(%{"dimension" => "app"}) |> json_response(200)
      assert %{"id" => "none", "label" => "none (no application recorded)"} in body["items"]

      assert_error_sent 500, fn -> post_options(conn, %{"dimension" => "cohort"}) end
    end

    test "app answers with the same envelope as a portal dimension", %{conn: conn} do
      body = body_for(admin_conn(conn), %{"dimension" => "app"})

      assert Enum.sort(Map.keys(body)) == Enum.sort(@envelope)
      assert %{"id" => "none", "label" => "none (no application recorded)"} in body["items"]
      assert body["count"] == length(body["items"])
      assert body["count_skipped"] == false
    end

    test "app pages like a portal dimension", %{conn: conn} do
      conn = admin_conn(conn)
      first = body_for(conn, %{"dimension" => "app", "limit" => 3})

      assert length(first["items"]) == 3
      assert is_binary(first["next_page_token"])
    end

    test "a report that offers the app filter accepts it and one that does not rejects it", %{conn: conn} do
      conn = admin_conn(conn)

      assert %{"items" => _} = body_for(conn, %{"dimension" => "app", "report_slug" => "student-actions"})

      body =
        conn
        |> post_options(%{"dimension" => "app", "report_slug" => "teacher-actions"})
        |> json_response(400)

      assert body["message"] =~ "does not filter on app"
    end
  end

  test "the endpoint requires a token", %{conn: conn} do
    assert post_options(conn, %{"dimension" => "class"}) |> json_response(401)
  end
end
