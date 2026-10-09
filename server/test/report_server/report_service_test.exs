defmodule ReportServer.ReportServiceTest do
  use ExUnit.Case, async: false
  alias ReportServer.ReportService

  setup do
    Application.put_env(:report_server, :report_service_req_options, plug: {Req.Test, __MODULE__})
    on_exit(fn -> Application.delete_env(:report_server, :report_service_req_options) end)
  end

  defp answer(status, body), do: Req.Test.stub(__MODULE__, fn conn -> conn |> Plug.Conn.put_status(status) |> Req.Test.json(body) end)

  test "maps the function's answers" do
    answer(200, %{success: true, interactive_urls: ["a"], unread: [], truncated: false, extra: 1})
    assert {:ok, %{"interactive_urls" => ["a"], "unread" => [], "truncated" => false}} = ReportService.derive_urls(["x"])
    answer(400, %{success: false, error: "too many"})
    assert {:error, {:bad_request, "too many"}} = ReportService.derive_urls(["x"])
    for status <- [404, 500, 503] do
      answer(status, %{success: false, error: "no"})
      assert {:error, :unavailable} = ReportService.derive_urls(["x"])
    end
  end

  test "a connection that fails or times out is unavailable" do
    for reason <- [:econnrefused, :timeout] do
      fail = fn request -> {request, %Mint.TransportError{reason: reason}} end
      Application.put_env(:report_server, :report_service_req_options, adapter: fail)
      assert {:error, :unavailable} = ReportService.derive_urls(["x"])
    end
  end

  test "sends the assignment URLs with the bearer" do
    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(self(), {:req, conn.request_path, Plug.Conn.get_req_header(conn, "authorization"), Jason.decode!(body)})
      Req.Test.json(conn, %{success: true, interactive_urls: [], unread: [], truncated: false})
    end)
    assert {:ok, _} = ReportService.derive_urls(["x"])
    assert_received {:req, path, ["Bearer " <> _], %{"assignment_urls" => ["x"]}}
    assert String.ends_with?(path, "/derive_urls")
  end
end
