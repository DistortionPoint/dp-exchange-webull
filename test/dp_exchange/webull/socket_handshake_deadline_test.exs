defmodule DpExchange.Webull.SocketHandshakeDeadlineTest do
  @moduledoc """
  The opening handshake has a deadline: `socket_connect_timeout` plus `socket_recv_timeout`.

  Upstream websockex 0.5.1 bounds each `recv` of the HTTP upgrade response separately, and
  every chunk restarts that timer. A peer that trickles the response, never finishing its
  headers, held a start or a reconnect open indefinitely. Measured 2026-09-27 against a
  local server sending one byte every 200 ms: still connecting at 12 s. See the vendored
  module's "What changed from upstream 0.5.1", item 3.

  Real `Socket.start_link/1` against a real TCP server on `127.0.0.1`: tier 1, no network.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Webull.Socket

  @moduletag :capture_log

  @handshake_guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  # 200 + 300: the deadline under test is 500 ms.
  @timeouts [socket_connect_timeout: 200, socket_recv_timeout: 300]

  test "a start whose upgrade response trickles in fails at the deadline" do
    {listen_socket, port} = listen()
    server = serve(listen_socket, [&trickle/1])
    on_exit(fn -> Process.exit(server, :kill) end)

    started = System.monotonic_time(:millisecond)

    task = Task.async(fn -> Socket.start_link(socket_opts(port)) end)

    # Without the deadline this call does not return at all, so the yield is what fails.
    assert {:ok, {:error, %WebSockex.ConnError{original: :timeout}}} =
             Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill)

    assert System.monotonic_time(:millisecond) - started < 3_000
  end

  test "a reconnect whose upgrade response trickles in fails at the deadline and retries" do
    test_pid = self()
    {listen_socket, port} = listen()

    server =
      serve(listen_socket, [
        &upgrade_then_close/1,
        &trickle/1,
        fn socket ->
          send(test_pid, :third_connection)
          :gen_tcp.close(socket)
        end
      ])

    on_exit(fn -> Process.exit(server, :kill) end)

    {:ok, socket_pid} = Socket.start_link(socket_opts(port))
    on_exit(fn -> if Process.alive?(socket_pid), do: Process.exit(socket_pid, :kill) end)

    # The first reconnect trickles. Only a deadline ends it, and only then can the socket
    # make its next attempt: attempt 2 waits one second of backoff, so this lands at about
    # 1.5 s. Without the deadline it never arrives.
    assert_receive :third_connection, 10_000
  end

  test "a wss peer whose certificate nothing trusts is refused" do
    # websockex's own default is `verify: :verify_none`. Against this server, the TLS
    # handshake used to complete and the upgrade request went out.
    key = [key: {:rsa, 2048, 65_537}]

    %{server_config: server} =
      :public_key.pkix_test_data(%{
        server_chain: %{root: key, intermediates: [], peer: key},
        client_chain: %{root: key, intermediates: [], peer: key}
      })

    {:ok, listen_socket} = :ssl.listen(0, [:binary, active: false, reuseaddr: true] ++ server)
    on_exit(fn -> :ssl.close(listen_socket) end)
    {:ok, {_address, port}} = :ssl.sockname(listen_socket)
    test_pid = self()

    spawn(fn ->
      {:ok, transport} = :ssl.transport_accept(listen_socket, 10_000)
      send(test_pid, {:server_handshake, elem(:ssl.handshake(transport, 5_000), 0)})
    end)

    opts = Keyword.put(socket_opts(port), :url, "wss://localhost:#{port}/")

    assert {:error, %WebSockex.ConnError{original: {:tls_alert, _alert}}} =
             Socket.start_link(opts)

    assert_receive {:server_handshake, :error}, 5_000
  end

  defp socket_opts(port) do
    [
      url: "ws://127.0.0.1:#{port}/mqtt",
      subscriber: self(),
      session_id: "handshake-deadline",
      app_key: "test-app-key"
    ] ++ @timeouts
  end

  defp listen do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    on_exit(fn -> :gen_tcp.close(listen_socket) end)
    {:ok, port} = :inet.port(listen_socket)
    {listen_socket, port}
  end

  # Each handler serves one accepted connection, in order.
  defp serve(listen_socket, handlers) do
    spawn(fn ->
      Enum.each(handlers, fn handler ->
        {:ok, client_socket} = :gen_tcp.accept(listen_socket, 10_000)
        handler.(client_socket)
      end)
    end)
  end

  defp trickle(socket) do
    {:ok, _request} = recv_until_headers_end(socket, "")
    :ok = :gen_tcp.send(socket, "HTTP/1.1 101 Switching Protocols\r\n")
    drip(socket)
  end

  # One byte every 100 ms, which restarts a per-`recv` timer of 300 ms forever. Stops when
  # the client closes, which is what the deadline does.
  defp drip(socket) do
    case :gen_tcp.send(socket, "X") do
      :ok ->
        Process.sleep(100)
        drip(socket)

      {:error, _closed} ->
        :ok
    end
  end

  defp upgrade_then_close(socket) do
    {:ok, request} = recv_until_headers_end(socket, "")

    :ok =
      :gen_tcp.send(
        socket,
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" <>
          "Sec-WebSocket-Accept: #{accept_header(request)}\r\n\r\n"
      )

    :gen_tcp.close(socket)
  end

  defp recv_until_headers_end(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      {:ok, acc}
    else
      case :gen_tcp.recv(socket, 0, 5_000) do
        {:ok, data} -> recv_until_headers_end(socket, acc <> data)
        {:error, _reason} = error -> error
      end
    end
  end

  defp accept_header(request) do
    [_full_match, key] = Regex.run(~r/Sec-WebSocket-Key:\s*(\S+)/i, request)

    :sha
    |> :crypto.hash(key <> @handshake_guid)
    |> Base.encode64()
  end
end
