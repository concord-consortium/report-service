defmodule ReportServerWeb.Api.PortalTokenTest do
  use ReportServerWeb.ConnCase, async: false

  import ReportServerWeb.PortalTokenFixture

  alias ReportServerWeb.Api.{PortalToken, PortalTokenPlug}

  @audience "report-server"
  @catalog "https://report-server.example"
  @capability "packages:read"

  describe "verify/2" do
    test "accepts a token signed by the key its kid names, for that key's issuer" do
      token = sign(:staging, claims(:staging, @audience))

      assert {:ok, %{"uid" => 42, "aud" => @audience}} = PortalToken.verify(token, @audience)
    end

    test "refuses the staging key claiming the production issuer" do
      token = sign(:staging, claims(:staging, @audience, %{"iss" => iss(:production)}))

      assert PortalToken.verify(token, @audience) == {:error, :wrong_issuer}
    end

    test "refuses the production key under the staging kid" do
      token = sign(:production, claims(:staging, @audience), kid: kid(:staging))

      assert PortalToken.verify(token, @audience) == {:error, :signature_error}
    end

    test "refuses an unknown kid rather than falling back to a configured key" do
      token = sign(:staging, claims(:staging, @audience), kid: "retired-2025")

      assert PortalToken.verify(token, @audience) == {:error, :unknown_kid}
    end

    test "refuses a token with no kid" do
      token = sign(:staging, claims(:staging, @audience)) |> drop_kid()

      assert PortalToken.verify(token, @audience) == {:error, :unsupported_header}
    end

    test "refuses HS256 signed with the configured public key as the HMAC secret" do
      token = sign_hs256_with_public_pem(:staging, claims(:staging, @audience))

      assert PortalToken.verify(token, @audience) == {:error, :unsupported_header}
    end

    test "refuses an HMAC signature under a header that claims RS256" do
      token = sign_hs256_with_public_pem(:staging, claims(:staging, @audience), header_alg: "RS256")

      assert PortalToken.verify(token, @audience) == {:error, :signature_error}
    end

    test "refuses alg none" do
      token = unsigned(:staging, claims(:staging, @audience))

      assert PortalToken.verify(token, @audience) == {:error, :unsupported_header}
    end

    test "refuses another audience" do
      token = sign(:staging, claims(:staging, "report-service-functions"))

      assert PortalToken.verify(token, @audience) == {:error, :wrong_audience}
    end

    test "refuses a token with no aud" do
      token = sign(:staging, claims(:staging, @audience), without: ["aud"])

      assert PortalToken.verify(token, @audience) == {:error, :wrong_audience}
    end

    test "refuses an aud list even when it contains the expected audience" do
      token = sign(:staging, claims(:staging, @audience, %{"aud" => [@audience]}))

      assert PortalToken.verify(token, @audience) == {:error, :wrong_audience}
    end

    test "refuses an access token naming several services, this one among them" do
      token = sign(:staging, access_claims(:staging, [iss(:staging), @audience], @capability))

      assert PortalToken.verify(token, @audience) == {:error, :wrong_audience}
    end

    test "refuses an expired token" do
      token = sign(:staging, claims(:staging, @audience, %{"exp" => System.system_time(:second) - 1}))

      assert PortalToken.verify(token, @audience) == {:error, :expired}
    end

    test "refuses a token with no exp" do
      token = sign(:staging, claims(:staging, @audience), without: ["exp"])

      assert PortalToken.verify(token, @audience) == {:error, :no_expiry}
    end

    test "refuses garbage" do
      assert {:error, _} = PortalToken.verify("not.a.jwt", @audience)
      assert {:error, _} = PortalToken.verify("", @audience)
    end

    @tag :capture_log
    test "trusts no key when PORTAL_PUBLIC_KEYS is malformed" do
      token = sign(:staging, claims(:staging, @audience))

      with_portal_keys("{not json", fn ->
        assert PortalToken.verify(token, @audience) == {:error, :unknown_kid}
      end)
    end
  end

  describe "PORTAL_PUBLIC_KEYS" do
    @describetag :capture_log

    test "ignores an entry whose PEM is unreadable, so its kid is unknown" do
      token = sign(:staging, claims(:staging, @audience))
      keys = Jason.encode!([%{kid: kid(:staging), iss: iss(:staging), pem: "not a pem"}])

      with_portal_keys(keys, fn ->
        assert PortalToken.verify(token, @audience) == {:error, :unknown_kid}
      end)
    end

    test "trusts neither entry when a kid is listed twice, even if the repeat is malformed" do
      token = sign(:staging, claims(:staging, @audience))

      keys =
        Jason.encode!([
          %{kid: kid(:staging), iss: iss(:staging), pem: public_pem(:staging)},
          %{kid: kid(:staging), iss: iss(:production), pem: "not a pem"}
        ])

      with_portal_keys(keys, fn ->
        assert PortalToken.verify(token, @audience) == {:error, :unknown_kid}
      end)
    end

    test "trusts neither entry when a kid is listed twice" do
      token = sign(:staging, claims(:staging, @audience))
      pem = public_pem(:staging)

      keys =
        Jason.encode!([
          %{kid: kid(:staging), iss: iss(:staging), pem: pem},
          %{kid: kid(:staging), iss: iss(:production), pem: pem}
        ])

      with_portal_keys(keys, fn ->
        assert PortalToken.verify(token, @audience) == {:error, :unknown_kid}
      end)
    end
  end

  describe "verify_access_token/3" do
    test "accepts a token whose aud names this deployment and whose scope holds the capability" do
      token = sign(:staging, access_claims(:staging, [iss(:staging), @catalog], @capability))

      assert {:ok, %{"uid" => 42}} = PortalToken.verify_access_token(token, @catalog, @capability)
    end

    test "reads the capability out of a space-separated scope" do
      token = sign(:staging, access_claims(:staging, [iss(:staging), @catalog], "class:researcher-read #{@capability} class:researcher-run"))

      assert {:ok, _} = PortalToken.verify_access_token(token, @catalog, @capability)
    end

    test "refuses a token whose scope does not hold the capability" do
      token = sign(:staging, access_claims(:staging, [iss(:staging), @catalog], "class:researcher-read"))

      assert PortalToken.verify_access_token(token, @catalog, @capability) == {:error, :missing_capability}
    end

    test "refuses a token with no scope" do
      token = sign(:staging, claims(:staging, [iss(:staging), @catalog]))

      assert PortalToken.verify_access_token(token, @catalog, @capability) == {:error, :missing_capability}
    end

    test "refuses a token whose aud list does not name this deployment" do
      token = sign(:staging, access_claims(:staging, [iss(:staging), "https://report-server.elsewhere"], @capability))

      assert PortalToken.verify_access_token(token, @catalog, @capability) == {:error, :wrong_audience}
    end

    test "refuses an assertion, whose aud is one string, even when it is this deployment" do
      token = sign(:staging, access_claims(:staging, [@catalog], @capability, %{"aud" => @catalog}))

      assert PortalToken.verify_access_token(token, @catalog, @capability) == {:error, :wrong_audience}
    end

    test "refuses a token presented as the old launch audience" do
      token = sign(:staging, access_claims(:staging, ["researcher-dashboard"], @capability))

      assert PortalToken.verify_access_token(token, @catalog, @capability) == {:error, :wrong_audience}
    end

    test "checks the key, the issuer and the expiry as an assertion does" do
      claims = access_claims(:staging, [iss(:staging), @catalog], @capability)

      assert PortalToken.verify_access_token(sign(:staging, claims, kid: "retired-2025"), @catalog, @capability) == {:error, :unknown_kid}
      assert PortalToken.verify_access_token(sign(:production, claims, kid: kid(:staging)), @catalog, @capability) == {:error, :signature_error}
      assert PortalToken.verify_access_token(sign(:staging, %{claims | "iss" => iss(:production)}), @catalog, @capability) == {:error, :wrong_issuer}
      assert PortalToken.verify_access_token(sign(:staging, %{claims | "exp" => System.system_time(:second) - 1}), @catalog, @capability) == {:error, :expired}
    end
  end

  describe "access_token_audience/0" do
    test "is this endpoint's own URL, with no path and no default port, as rigse holds it" do
      assert PortalToken.access_token_audience() == @catalog
    end
  end

  describe "PortalTokenPlug" do
    test "assigns the claims of an access token for its capability", %{conn: conn} do
      token = sign(:staging, access_claims(:staging, [iss(:staging), @catalog], @capability))

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> PortalTokenPlug.call(PortalTokenPlug.init(capability: @capability, optional: true))

      refute conn.halted
      assert %{"uid" => 42} = conn.assigns.portal_claims
    end

    test "refuses an access token without the capability rather than treating it as anonymous", %{conn: conn} do
      token = sign(:staging, access_claims(:staging, [iss(:staging), @catalog], "class:researcher-read"))

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> PortalTokenPlug.call(PortalTokenPlug.init(capability: @capability, optional: true))

      assert conn.halted
      assert json_response(conn, 401)["error"] == "NOT_AUTHENTICATED"
    end

    test "lets a request with no bearer through when it is optional", %{conn: conn} do
      conn = PortalTokenPlug.call(conn, PortalTokenPlug.init(capability: @capability, optional: true))

      refute conn.halted
      refute Map.has_key?(conn.assigns, :portal_claims)
    end

    test "assigns the verified claims for its audience", %{conn: conn} do
      token = sign(:staging, claims(:staging, @audience))

      conn = call_plug(conn, token, @audience)

      refute conn.halted
      assert %{"uid" => 42} = conn.assigns.portal_claims
    end

    test "answers NOT_AUTHENTICATED for a token of another audience", %{conn: conn} do
      token = sign(:staging, claims(:staging, "report-service-functions"))

      conn = call_plug(conn, token, @audience)

      assert conn.halted
      assert json_response(conn, 401)["error"] == "NOT_AUTHENTICATED"
      refute Map.has_key?(conn.assigns, :portal_claims)
    end

    test "answers NOT_AUTHENTICATED with no bearer", %{conn: conn} do
      conn = PortalTokenPlug.call(conn, PortalTokenPlug.init(audience: @audience))

      assert conn.halted
      assert json_response(conn, 401)["error"] == "NOT_AUTHENTICATED"
    end
  end

  defp call_plug(conn, token, audience) do
    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> PortalTokenPlug.call(PortalTokenPlug.init(audience: audience))
  end

  defp drop_kid(token) do
    [header, payload, signature] = String.split(token, ".")
    decoded = header |> Base.url_decode64!(padding: false) |> Jason.decode!() |> Map.delete("kid")
    "#{Base.url_encode64(Jason.encode!(decoded), padding: false)}.#{payload}.#{signature}"
  end

  defp with_portal_keys(value, fun) do
    previous = Application.get_env(:report_server, :portal_public_keys)
    Application.put_env(:report_server, :portal_public_keys, value)

    try do
      fun.()
    after
      Application.put_env(:report_server, :portal_public_keys, previous)
    end
  end
end
