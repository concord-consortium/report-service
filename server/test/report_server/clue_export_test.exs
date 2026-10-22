defmodule ReportServer.ClueExportTest do
  use ExUnit.Case, async: false

  alias ReportServer.ClueExport

  @portal "learn.portal.staging.concord.org"
  @url "https://clueexport-test.a.run.app"

  setup do
    previous = Application.get_env(:report_server, :clue_export)
    Application.put_env(:report_server, :clue_export, urls: %{@portal => @url}, token: "secret")
    Application.put_env(:report_server, :clue_export_req_options, plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      Application.put_env(:report_server, :clue_export, previous)
      Application.delete_env(:report_server, :clue_export_req_options)
    end)
  end

  defp answer(status, body), do: Req.Test.stub(__MODULE__, fn conn -> conn |> Plug.Conn.put_status(status) |> Req.Test.json(body) end)

  test "url_for/1 names the configured portal's function and nil for any other" do
    assert ClueExport.url_for(@portal) == @url
    assert ClueExport.url_for("learn.concord.org") == nil
  end

  test "a portal with no function URL is not configured and sends nothing" do
    Req.Test.stub(__MODULE__, fn _conn -> flunk("no request should be sent") end)
    assert {:error, :not_configured} = ClueExport.call("learn.concord.org", %{operation: "documents"})
  end

  test "posts the request as JSON with the bearer and answers the body without success" do
    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(self(), {:req, conn.method, Plug.Conn.get_req_header(conn, "authorization"), Jason.decode!(body)})
      Req.Test.json(conn, %{success: true, items: [%{doc_id: "d1"}], stop_owner_offset: 0})
    end)

    assert {:ok, %{"items" => [%{"doc_id" => "d1"}], "stop_owner_offset" => 0} = body} =
             ClueExport.call(@portal, %{operation: "documents", owners: []})

    refute Map.has_key?(body, "success")
    assert_received {:req, "POST", ["Bearer secret"], %{"operation" => "documents", "owners" => []}}
  end

  test "maps every non-200 to an error, with the function's message when it sends one" do
    answer(400, %{success: false, error: "owners[0].uid is malformed"})
    assert {:error, "owners[0].uid is malformed"} = ClueExport.call(@portal, %{})

    answer(500, %{success: false, error: "read failed"})
    assert {:error, "read failed"} = ClueExport.call(@portal, %{})

    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 502, "bad gateway") end)
    assert {:error, "clueExport answered status 502 without success"} = ClueExport.call(@portal, %{})
  end

  test "a 200 without success is not a page" do
    answer(200, %{items: []})
    assert {:error, "clueExport answered status 200 without success"} = ClueExport.call(@portal, %{})
  end

  test "a transport failure is an error and the POST is not retried, even under a retrying default" do
    Application.put_env(:report_server, :clue_export_req_options,
      retry: :transient,
      max_retries: 2,
      retry_delay: fn _attempt -> 0 end,
      adapter: fn request ->
        send(self(), :attempt)
        {request, %Mint.TransportError{reason: :econnrefused}}
      end
    )

    assert {:error, %Mint.TransportError{reason: :econnrefused}} = ClueExport.call(@portal, %{})
    assert_received :attempt
    refute_received :attempt
  end
end
