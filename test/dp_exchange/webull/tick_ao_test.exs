defmodule DpExchange.Webull.TickAoTest do
  @moduledoc """
  Tick AO: resource safety on the stream path, process identity at shutdown, and what an
  error message or a status dump may print.

    * a protobuf length prefix beyond the buffer ends the walk without being matched;
    * unknown text from the wire does not become an atom;
    * a WebSocket frame, or a fragmented message, past the bound closes the connection
      instead of being buffered for as long as the peer keeps sending;
    * a `Feed` stopped with reason `:normal` stops the sockets it opened (a non-trapping
      process ignores a `:normal` exit signal, so the link does not do it);
    * `:sys.get_status/1` of a feed holding credentials, and the message of the exception
      `Options.check!/2` raises, print no secret.

  The server is a plain `:gen_tcp` listener on `127.0.0.1` with an OS-assigned port, as in the
  other socket tests: tier 1, `async: true` safe.
  """

  use ExUnit.Case, async: true

  import Bitwise

  alias DpExchange.Core.Notice
  alias DpExchange.Webull.{Feed, QuoteProto, Socket}

  @moduletag :capture_log

  @handshake_guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  describe "protobuf length prefixes" do
    defp field(number, value), do: <<number * 8 + 2, byte_size(value), value::binary>>

    # Field 3, length-delimited, then a ten-byte varint: 2^64 - 1, and just over 2^70 (the
    # largest ten bytes can hold), each followed by two bytes that are nowhere near enough.
    defp oversized_lengths do
      nine_ones = :binary.copy(<<255>>, 9)

      [<<26, nine_ones::binary, 1, "xx">>, <<26, nine_ones::binary, 127, "xx">>]
    end

    test "a length beyond the buffer ends the walk with what was read, and raises nothing" do
      for oversized <- oversized_lengths() do
        assert QuoteProto.decode_message(field(1, "a") <> oversized) == %{1 => "a"}
        assert QuoteProto.decode_message(oversized) == %{}
      end
    end

    test "every decoder answers :error for a message that is only such a length" do
      for oversized <- oversized_lengths() do
        assert QuoteProto.decode_snapshot(oversized) == :error
        assert QuoteProto.decode_tick(oversized) == :error
        assert QuoteProto.decode_quote(oversized) == :error
      end
    end
  end

  describe "text from the wire" do
    defp socket_state do
      %{
        subscriber: self(),
        parent: self(),
        session_id: "ao-atoms",
        app_key: "k",
        buffer: <<>>,
        qos2_pending: MapSet.new(),
        connected?: false,
        ping: nil,
        last_heard_at: nil
      }
    end

    test "a topic nothing decodes is reported and never becomes an atom" do
      topic = "ao-topic-" <> Integer.to_string(System.unique_integer([:positive]))
      packet = <<0x30, 2 + byte_size(topic) + 3, byte_size(topic)::16, topic::binary, "abc">>

      assert {:ok, _state} = Socket.handle_frame({:binary, packet}, socket_state())

      assert_receive {:dp_exchange, :webull,
                      %Notice{
                        kind: :data_quality,
                        details: %{reason: :unrecognised_topic, topic: ^topic}
                      }},
                     5_000

      assert_raise ArgumentError, fn -> String.to_existing_atom(topic) end
    end
  end

  describe "WebSocket frame bound" do
    test "a frame announcing a length past the bound is closed with 1011, not waited for" do
      # FIN + binary opcode, no mask, 127 (a 64-bit length follows): 2^40 bytes.
      announcement = <<0x82, 127, 1_099_511_627_776::64>>

      {listen_socket, port} = listen()
      server = serve_upgrade(listen_socket, fn client -> send_frames(client, [announcement]) end)
      on_exit(fn -> Process.exit(server, :kill) end)

      {:ok, socket_pid} = start_socket(port, "ao-frame-bound")
      on_exit(fn -> if Process.alive?(socket_pid), do: Process.exit(socket_pid, :kill) end)

      # The client said so on the wire, before the server closed anything.
      assert_receive {:client_close, 1011}, 25_000

      assert_receive {:dp_exchange, :webull,
                      %Notice{
                        kind: :link_down,
                        details: %{session_id: "ao-frame-bound", message: message}
                      }},
                     25_000

      assert message =~ "frame_too_large"
    end

    test "fragments that add up past the bound close the connection with 1009" do
      chunk = :binary.copy(<<0>>, 65_535)
      first = <<0x02, 126, 65_535::16, chunk::binary>>
      continuation = <<0x00, 126, 65_535::16, chunk::binary>>

      # 66 x 65,535 bytes is 4.3 MB, over the 4 MiB bound, and no single frame is near it.
      frames = [first | List.duplicate(continuation, 65)]

      {listen_socket, port} = listen()
      server = serve_upgrade(listen_socket, fn client -> send_frames(client, frames) end)
      on_exit(fn -> Process.exit(server, :kill) end)

      {:ok, socket_pid} = start_socket(port, "ao-fragment-bound")
      on_exit(fn -> if Process.alive?(socket_pid), do: Process.exit(socket_pid, :kill) end)

      assert_receive {:client_close, 1009}, 25_000

      assert_receive {:dp_exchange, :webull,
                      %Notice{
                        kind: :link_down,
                        details: %{session_id: "ao-fragment-bound", message: message}
                      }},
                     25_000

      assert message =~ "1009"
    end
  end

  describe "a feed stopped with reason :normal" do
    test "stops the sockets it opened, connected or not" do
      connected = sleeper()
      connecting = sleeper()

      shards = %{
        0 => %{
          session_id: "ao-s0",
          socket: connected,
          connected?: true,
          symbols: [],
          reply_to: nil
        },
        1 => %{
          session_id: "ao-s1",
          socket: connecting,
          connected?: false,
          symbols: [],
          reply_to: nil
        }
      }

      {:ok, feed} =
        Feed.start_link(name: :"ao_feed_#{System.unique_integer([:positive])}", shards: shards)

      monitors = for pid <- [connected, connecting], do: {pid, Process.monitor(pid)}

      assert GenServer.stop(feed) == :ok

      for {pid, ref} <- monitors do
        assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}, 10_000
      end
    end

    test "a stop with the supervisor's reason leaves the sockets to their link" do
      socket = sleeper()
      on_exit(fn -> Process.exit(socket, :kill) end)

      shards = %{
        0 => %{
          session_id: "ao-s0",
          socket: socket,
          connected?: false,
          symbols: [],
          reply_to: nil
        }
      }

      assert Feed.terminate(:shutdown, %{shards: shards}) == :ok
      assert Process.alive?(socket)
    end
  end

  describe "what is printed" do
    test "a feed's status dump holds the credentials wrapped, and prints no secret" do
      credentials = %{
        app_key: "AO_KEY_NOT_FOR_LOGS",
        app_secret: "AO_SECRET_NOT_FOR_LOGS",
        access_token: "AO_TOKEN_NOT_FOR_LOGS"
      }

      {:ok, feed} =
        Feed.start_link(
          name: :"ao_status_#{System.unique_integer([:positive])}",
          credentials: credentials
        )

      printed = inspect(:sys.get_status(feed), limit: :infinity, printable_limit: :infinity)

      for secret <- Map.values(credentials), do: refute(printed =~ secret)

      # Wrapped, not dropped: the feed still holds what a replay signs with.
      assert %DpExchange.Webull.Credentials{app_secret: "AO_SECRET_NOT_FOR_LOGS"} =
               :sys.get_state(feed).resubscribe_opts[:credentials]
    end

    test "the exception for options that are not a keyword list does not echo them" do
      options = %{credentials: %{app_key: "k", app_secret: "AO_OPTS_SECRET_NOT_FOR_LOGS"}}

      error = assert_raise ArgumentError, fn -> DpExchange.Webull.coverage(options) end

      refute Exception.message(error) =~ "AO_OPTS_SECRET_NOT_FOR_LOGS"
      assert Exception.message(error) =~ "keyword list"
    end
  end

  # --- helpers ----------------------------------------------------------------------------

  defp sleeper do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp start_socket(port, session_id) do
    Socket.start_link(
      url: "ws://127.0.0.1:#{port}/mqtt",
      subscriber: self(),
      session_id: session_id,
      app_key: "test-app-key"
    )
  end

  defp listen do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    on_exit(fn -> :gen_tcp.close(listen_socket) end)
    {:ok, port} = :inet.port(listen_socket)
    {listen_socket, port}
  end

  # Accepts one connection, upgrades it, runs `after_upgrade`, then reads the client's frames
  # until it sees a close frame, reports its code to the test and closes the connection.
  defp serve_upgrade(listen_socket, after_upgrade) do
    test_pid = self()

    spawn(fn ->
      {:ok, client} = :gen_tcp.accept(listen_socket, 20_000)
      {:ok, request} = recv_until_headers_end(client, "")

      :ok =
        :gen_tcp.send(
          client,
          "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" <>
            "Sec-WebSocket-Accept: #{accept_header(request)}\r\n\r\n"
        )

      after_upgrade.(client)
      send(test_pid, {:client_close, await_close_code(client, <<>>)})
      :gen_tcp.close(client)
    end)
  end

  defp send_frames(client, frames) do
    # The client may already have closed, which is the point; a failed send is not a failure.
    Enum.each(frames, fn frame -> _sent = :gen_tcp.send(client, frame) end)
  end

  defp await_close_code(client, acc) do
    case close_code(acc) do
      nil -> await_close_code(client, acc <> recv_more(client))
      code -> code
    end
  end

  defp recv_more(client) do
    {:ok, data} = :gen_tcp.recv(client, 0, 20_000)
    data
  end

  # The close code of the first close frame in what a client has sent so far, or `nil`.
  # Client frames are masked (RFC 6455 section 5.3) and every one here has a payload under 126
  # bytes, so each is: opcode byte, mask-and-length byte, 4 mask bytes, the payload.
  defp close_code(<<first, second, rest::binary>>) do
    length = second &&& 0x7F

    case rest do
      <<mask::binary-size(4), payload::binary-size(length), more::binary>> ->
        frame_close_code(first &&& 0x0F, mask, payload, more)

      _incomplete ->
        nil
    end
  end

  defp close_code(_too_short), do: nil

  defp frame_close_code(8, mask, payload, _more) do
    key = binary_part(:binary.copy(mask, div(byte_size(payload), 4) + 1), 0, byte_size(payload))
    <<code::16, _reason::binary>> = :crypto.exor(payload, key)
    code
  end

  defp frame_close_code(_other_opcode, _mask, _payload, more), do: close_code(more)

  defp recv_until_headers_end(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      {:ok, acc}
    else
      case :gen_tcp.recv(socket, 0, 20_000) do
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
