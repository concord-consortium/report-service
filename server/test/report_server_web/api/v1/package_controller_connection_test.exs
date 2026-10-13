defmodule ReportServerWeb.Api.V1.PackageControllerConnectionTest do
  # Against a real Bandit listener, since Phoenix.ConnTest never reaches the socket a refusal could leave unread.
  use ReportServerWeb.ConnCase, async: false

  import ReportServer.PackagesFixtures

  alias ReportServer.{PackagesMemoryStore, PackagesPortalStub}

  setup :register_and_put_bearer_token

  setup do
    {:ok, _} = PackagesMemoryStore.start()
    PackagesPortalStub.set(%{})
    on_exit(&PackagesPortalStub.reset/0)
  end

  defp listen(opts \\ []) do
    pid = start_supervised!({Bandit, [plug: ReportServerWeb.Endpoint, ip: :loopback, port: 0, startup_log: false] ++ opts})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    socket
  end

  defp request_head(path, token, length) do
    "POST #{path} HTTP/1.1\r\nhost: localhost\r\nauthorization: Bearer #{token}\r\n" <>
      "content-type: application/zip\r\ncontent-length: #{length}\r\n\r\n"
  end

  defp send_whole(socket, path, token, body), do: :ok = :gen_tcp.send(socket, request_head(path, token, byte_size(body)) <> body)

  defp receive_response(socket) do
    :ok = :inet.setopts(socket, packet: :http_bin)
    {:ok, {:http_response, _version, status, _reason}} = :gen_tcp.recv(socket, 0, 5_000)
    headers = receive_headers(socket, %{})
    :ok = :inet.setopts(socket, packet: :raw)

    body =
      case String.to_integer(Map.get(headers, "content-length", "0")) do
        0 -> ""
        length -> with({:ok, body} <- :gen_tcp.recv(socket, length, 5_000), do: body)
      end

    {status, body}
  end

  defp receive_headers(socket, headers) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, {:http_header, _, name, _, value}} -> receive_headers(socket, Map.put(headers, String.downcase(to_string(name)), value))
      {:ok, :http_eoh} -> headers
    end
  end

  defp assert_next_validate_answered(socket, token) do
    send_whole(socket, "/api/v1/packages/validate", token, package_zip(%{"version" => "1.0.2"}))
    {status, body} = receive_response(socket)
    assert status == 200
    assert %{"version" => "1.0.2"} = Jason.decode!(body)
  end

  for {route, path} <- [{"validate", "/api/v1/packages/validate"}, {"create", "/api/v1/packages"}] do
    test "a #{route} refused after its body is read leaves the next request on the connection intact", %{raw_token: token} do
      socket = listen()
      refused = package_zip(%{"expected_duration_seconds" => 7_201})

      # the body must arrive after the headers: read together, nothing is left for a stale conn to drain
      :ok = :gen_tcp.send(socket, request_head(unquote(path), token, byte_size(refused)))
      Process.sleep(100)
      :ok = :gen_tcp.send(socket, refused)

      {status, body} = receive_response(socket)
      assert status == 422
      assert %{"error" => "UNPROCESSABLE"} = Jason.decode!(body)

      assert_next_validate_answered(socket, token)
    end
  end

  test "a validate whose body stalls past the read timeout leaves the next request on the connection intact", %{raw_token: token} do
    socket = listen(thousand_island_options: [read_timeout: 1_000])
    declared = 2_500_000
    sent = 1_500_000

    :ok = :gen_tcp.send(socket, request_head("/api/v1/packages/validate", token, declared) <> :binary.copy("x", sent))

    {status, body} = receive_response(socket)
    assert status == 422
    assert Jason.decode!(body) == %{"error" => "UNPROCESSABLE", "message" => "the archive exceeds 10 MiB"}

    :ok = :gen_tcp.send(socket, :binary.copy("x", declared - sent))
    assert_next_validate_answered(socket, token)
  end
end
