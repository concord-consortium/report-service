defmodule ReportServer.PortalDownloadLimiterTest do
  use ExUnit.Case, async: true

  alias ReportServer.PortalDownloadLimiter, as: Limiter

  defp start_limiter(cap) do
    {:ok, pid} = GenServer.start_link(Limiter, [cap: cap], [])
    pid
  end

  # acquire/release from a separate short-lived process so we can drive multiple holders
  defp acquire_from_new_process(server) do
    parent = self()

    holder =
      spawn(fn ->
        reply = GenServer.call(server, :try_acquire)
        send(parent, {self(), reply})

        receive do
          :stop -> :ok
        end
      end)

    receive do
      {^holder, reply} -> {holder, reply}
    end
  end

  test "admits up to cap concurrent holders and rejects the rest with :full" do
    server = start_limiter(2)

    {h1, r1} = acquire_from_new_process(server)
    {h2, r2} = acquire_from_new_process(server)
    {h3, r3} = acquire_from_new_process(server)

    assert r1 == :ok
    assert r2 == :ok
    assert r3 == :full

    send(h1, :stop)
    send(h2, :stop)
    send(h3, :stop)
  end

  test "explicit release frees a slot" do
    server = start_limiter(1)

    assert GenServer.call(server, :try_acquire) == :ok
    GenServer.cast(server, {:release, self()})
    # cast is async; a synchronous call flushes the mailbox ordering
    _ = :sys.get_state(server)

    {_h, reply} = acquire_from_new_process(server)
    assert reply == :ok
  end

  test "a holder dying auto-releases its slot" do
    server = start_limiter(1)

    {holder, :ok} = acquire_from_new_process(server)
    assert %{holders: holders} = :sys.get_state(server)
    assert map_size(holders) == 1

    ref = Process.monitor(holder)
    send(holder, :stop)
    assert_receive {:DOWN, ^ref, :process, ^holder, _}

    # let the limiter process the monitor :DOWN
    _ = :sys.get_state(server)
    assert %{holders: after_holders} = :sys.get_state(server)
    assert map_size(after_holders) == 0
  end
end
