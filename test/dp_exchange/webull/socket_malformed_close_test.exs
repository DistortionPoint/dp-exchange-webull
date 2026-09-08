defmodule DpExchange.Webull.SocketMalformedCloseTest do
  @moduledoc """
  dp-exchange-core issue #27 — the deliverable this fix stands or falls on.

  Webull sometimes closes this venue's socket with a WebSocket close frame carrying
  **prose** where RFC 6455 §5.5.1 requires a 2-byte status code:

      <<136, 10, 98, 121, 101, 45, 98, 121, 101, 33, 33, 33>>   # FIN+close, len 10, "bye-bye!!!"

  The first two bytes parse as `"by"` = 25209, outside every valid close-code range
  (1000–1015, 3000–4999). `WebSockex.Frame.parse_frame/1` (real, unmodified dependency)
  correctly returns `{:error, %WebSockex.FrameError{reason: :invalid_close_code}}` for
  this. Upstream websockex 0.5.1 — the latest Hex release, and still true of its
  unreleased successor as of 2026-09-08 — has no clause for that return value in its own
  `websocket_loop/3`, so the process raises `CaseClauseError` and dies before
  `c:handle_disconnect/2` ever runs. Measured live: 117 crashes in 7 minutes across three
  shards.

  This test is a real `Socket.start_link/1` talking a real WebSocket handshake to a real
  TCP server — not the pure frame-handler unit tests in `socket_test.exs`, which drive
  `Socket.handle_frame/2` and `Socket.handle_disconnect/2` directly against a bare state
  map and never touch a socket at all. Proving "the process does not crash" requires an
  actual OS process boundary: a unit-level call to a handler function cannot demonstrate
  that the *library* driving it doesn't raise first. The server is entirely local
  (`127.0.0.1`, an OS-assigned ephemeral port, one accepted connection, no network) — an
  in-process fake in the sense this family's tiers use the term, not a live venue call,
  so this stays tier-1 and `async: true` safe.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Notice
  alias DpExchange.Webull.Socket

  @moduletag :capture_log

  @handshake_guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  # The exact 12 bytes from the issue: FIN + opcode 0x8 (close), length 10, payload
  # "bye-bye!!!". Not a synthesized "some invalid close code" — the literal frame
  # captured live.
  @malformed_close_frame <<136, 10, 98, 121, 101, 45, 98, 121, 101, 33, 33, 33>>

  test "a malformed WebSocket close frame disconnects cleanly instead of crashing the socket" do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    on_exit(fn -> :gen_tcp.close(listen_socket) end)

    {:ok, port} = :inet.port(listen_socket)

    {:ok, server} =
      Task.start_link(fn -> accept_upgrade_then_send_malformed_close(listen_socket) end)

    on_exit(fn -> if Process.alive?(server), do: Process.exit(server, :kill) end)

    {:ok, socket_pid} =
      Socket.start_link(
        url: "ws://127.0.0.1:#{port}/mqtt",
        subscriber: self(),
        session_id: "issue-27-malformed-close",
        app_key: "test-app-key"
      )

    on_exit(fn -> if Process.alive?(socket_pid), do: Process.exit(socket_pid, :kill) end)

    # `c:handle_disconnect/2` ran: it is the only place `Socket` sends a `:link_down`
    # notice, and the pre-fix behaviour is that this callback never fires at all — the
    # process dies with an uncaught `CaseClauseError` first, so this `assert_receive`
    # would time out on the unpatched dependency.
    assert_receive {:dp_exchange, :webull,
                    %Notice{
                      kind: :link_down,
                      details: %{session_id: "issue-27-malformed-close"} = details
                    }}

    # Ties this assertion to the actual defect, not just "something disconnected": the
    # reason WebSockex handed to `handle_disconnect/2` names the exact frame error
    # `WebSockex.Frame.parse_frame/1` returned for these bytes.
    assert details.reason =~ "invalid_close_code"
    assert details.reason =~ "WebSockex.FrameError"

    # The process did not crash — it is the same pid, still alive, mid-reconnect (the
    # ordinary `{:reconnect, state}` `Socket.handle_disconnect/2` already returns for
    # every other disconnect reason). A `CaseClauseError` would have taken this pid down
    # entirely, and there would be no process left to assert on.
    assert Process.alive?(socket_pid)
  end

  defp accept_upgrade_then_send_malformed_close(listen_socket) do
    {:ok, client_socket} = :gen_tcp.accept(listen_socket, 5_000)
    {:ok, request} = recv_until_headers_end(client_socket, "")

    response =
      "HTTP/1.1 101 Switching Protocols\r\n" <>
        "Upgrade: websocket\r\n" <>
        "Connection: Upgrade\r\n" <>
        "Sec-WebSocket-Accept: #{accept_header(request)}\r\n\r\n"

    :ok = :gen_tcp.send(client_socket, response)
    :ok = :gen_tcp.send(client_socket, @malformed_close_frame)
    :gen_tcp.close(client_socket)
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
