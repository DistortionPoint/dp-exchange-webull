defmodule DpExchange.Webull.TickARTransportDocsTest do
  @moduledoc """
  Tick AR, lens V over the transport modules: each claim a `@doc` or `@moduledoc` in `Socket`,
  `MqttPacket` and `QuoteProto` makes about a return shape, a default or an error, held to
  the code. The proto fixtures use the field numbers of the venue's own schema in
  `docs/reference/webull/streaming-api.md`, written out here rather than built by the decoder.
  """

  use ExUnit.Case, async: true

  import Bitwise

  alias DpExchange.Core.Notice
  alias DpExchange.Webull.{MqttPacket, QuoteProto, Socket}

  @moduletag :capture_log

  defp varint(value) when value < 0x80, do: <<value>>
  defp varint(value), do: <<1::1, band(value, 0x7F)::7, varint(bsr(value, 7))::binary>>

  # One length-delimited field: tag (field number, wire type 2), length, bytes.
  defp field(number, value),
    do: varint(bsl(number, 3) ||| 2) <> varint(byte_size(value)) <> value

  defp live_state do
    %{
      subscriber: self(),
      session_id: "ar-s1",
      app_key: "k",
      buffer: <<>>,
      qos2_pending: MapSet.new(),
      connected?: true,
      connected_at: System.monotonic_time(:millisecond) - 60_000,
      link_down_sent?: false,
      ping: nil,
      last_heard_at: nil
    }
  end

  describe "Socket: one :link_down notice per outage" do
    test "a venue that stays down sends one, and the next outage sends another" do
      assert {:reconnect, down} = Socket.handle_disconnect(%{reason: :closed}, live_state())

      assert_receive {:dp_exchange, :webull,
                      %Notice{
                        kind: :link_down,
                        details: %{reason: :disconnected, session_id: "ar-s1"}
                      }},
                     5_000

      assert down.link_down_sent?

      # A reconnect that failed: the same outage, so no second notice.
      assert {:reconnect, still_down} =
               Socket.handle_disconnect(%{reason: :econnrefused, attempt_number: 2}, down)

      refute_receive {:dp_exchange, :webull, %Notice{kind: :link_down}}, 500
      assert still_down.link_down_sent?

      # The broker accepts the CONNECT: the outage is over and the flag is cleared.
      assert {:ok, up} = Socket.handle_frame({:binary, <<2::4, 0::4, 2, 0, 0>>}, still_down)
      assert_receive {:dp_exchange, :webull, %Notice{kind: :link_up}}, 5_000
      refute up.link_down_sent?

      aged = %{up | connected_at: System.monotonic_time(:millisecond) - 60_000}
      assert {:reconnect, _again} = Socket.handle_disconnect(%{reason: :closed}, aged)

      assert_receive {:dp_exchange, :webull, %Notice{kind: :link_down}}, 5_000
    end
  end

  describe "Socket.connection_opts/1 as documented" do
    test "defaults, and every other key dropped" do
      opts = Socket.connection_opts(url: "wss://x", subscriber: self(), session_id: "s")

      assert opts[:socket_connect_timeout] == 3_000
      assert opts[:socket_recv_timeout] == 2_000

      assert opts |> Keyword.keys() |> Enum.sort() ==
               [:socket_connect_timeout, :socket_recv_timeout, :ssl_options]
    end

    test "the two timeouts are taken from the caller when given" do
      opts = Socket.connection_opts(socket_connect_timeout: 111, socket_recv_timeout: 222)

      assert {opts[:socket_connect_timeout], opts[:socket_recv_timeout]} == {111, 222}
    end

    test "nothing given, an empty list or a non-keyword value is verified TLS, never none" do
      for given <- [nil, [], :bogus, [1, 2], "x"] do
        ssl = Socket.connection_opts(ssl_options: given)[:ssl_options]

        assert ssl[:verify] == :verify_peer, "ssl_options #{inspect(given)} must verify"
        assert is_list(ssl[:cacerts])
        assert Keyword.has_key?(ssl, :customize_hostname_check)
      end
    end

    test "a keyword list is merged over the defaults, and only an explicit verify changes it" do
      kept = Socket.connection_opts(ssl_options: [cacerts: [:mine]])[:ssl_options]
      assert kept[:cacerts] == [:mine]
      assert kept[:verify] == :verify_peer

      off = Socket.connection_opts(ssl_options: [verify: :verify_none])[:ssl_options]
      assert off[:verify] == :verify_none
    end
  end

  describe "Socket.disconnect/2 errors as documented" do
    test "the calling process's own pid is :calling_self, not a wrapped exception" do
      assert {:error, :calling_self} = Socket.disconnect(self())
    end

    test "a process that has gone is :not_alive" do
      pid = spawn(fn -> :ok end)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000

      assert {:error, :not_alive} = Socket.disconnect(pid)
    end

    test "a live process that never answers is an {:exit, _} error, not a raise" do
      pid = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(pid, :kill) end)

      assert {:error, {:exit, _reason}} = Socket.disconnect(pid, 100)
    end
  end

  describe "Socket.start_link/1 refuses an insecure URL as documented" do
    test "without echoing the URL" do
      assert {:error, {:insecure_url, :webull}} =
               Socket.start_link(
                 url: "ws://user:pw@example.com/mqtt",
                 subscriber: self(),
                 session_id: "s",
                 app_key: "k"
               )
    end

    test "a missing required option raises KeyError rather than returning a tuple" do
      assert_raise KeyError, fn ->
        Socket.start_link(url: "wss://example.com/mqtt", subscriber: self(), session_id: "s")
      end
    end
  end

  describe "MqttPacket decode as documented" do
    test "the acknowledgements and SUBACK and UNSUBACK a server may send are :unhandled" do
      assert {:ok, {:unhandled, 4, <<0, 7>>}, <<>>} = MqttPacket.decode(<<4::4, 0::4, 2, 0, 7>>)
      assert {:ok, {:unhandled, 5, <<0, 7>>}, <<>>} = MqttPacket.decode(<<5::4, 0::4, 2, 0, 7>>)
      assert {:ok, {:unhandled, 7, <<0, 7>>}, <<>>} = MqttPacket.decode(<<7::4, 0::4, 2, 0, 7>>)

      assert {:ok, {:unhandled, 9, <<0, 1, 0>>}, <<>>} =
               MqttPacket.decode(<<9::4, 0::4, 3, 0, 1, 0>>)

      assert {:ok, {:unhandled, 11, <<0, 1>>}, <<>>} =
               MqttPacket.decode(<<11::4, 0::4, 2, 0, 1>>)
    end

    test "a packet no server sends is :malformed_header" do
      assert {:error, :malformed_header} = MqttPacket.decode(<<12::4, 0::4, 0>>)
      assert {:error, :malformed_header} = MqttPacket.decode(<<1::4, 0::4, 0>>)
    end

    test "a remaining length past 1 MiB is :malformed_length, exactly 1 MiB is waited for" do
      # 1_048_577 and 1_048_576 as MQTT varints.
      assert {:error, :malformed_length} = MqttPacket.decode(<<3::4, 0::4, 0x81, 0x80, 0x40>>)
      assert {:error, :incomplete} = MqttPacket.decode(<<3::4, 0::4, 0x80, 0x80, 0x40>>)
    end

    test "a fifth length byte is :malformed_length" do
      assert {:error, :malformed_length} =
               MqttPacket.decode(<<3::4, 0::4, 0x80, 0x80, 0x80, 0x80, 0x01>>)
    end
  end

  describe "MqttPacket.connect/4 as documented" do
    test "a string of 65,535 bytes is encoded, one byte more raises ArgumentError" do
      assert is_binary(MqttPacket.connect("s", "u", String.duplicate("x", 65_535)))

      assert_raise ArgumentError, ~r/at most 65,535 bytes/, fn ->
        MqttPacket.connect("s", "u", String.duplicate("x", 65_536))
      end
    end

    test "a keep-alive outside 1..65,535 matches no clause" do
      # Bound from a list, so the compiler cannot see a call that always fails.
      for keep_alive <- [0, 65_536] do
        assert_raise FunctionClauseError, fn ->
          MqttPacket.connect("s", "u", "p", keep_alive)
        end
      end
    end

    test "the keep-alive and the clean-session flag are on the wire" do
      <<1::4, 0::4, _length, 4::16, "MQTT", 4, flags, keep_alive::16, _rest::binary>> =
        MqttPacket.connect("session", "key", "x", 60)

      assert flags == 0b1100_0010
      assert keep_alive == 60
    end
  end

  describe "QuoteProto decoders return what their docs list" do
    test "decode_snapshot: symbol, price, volume (field 8) and trade_time (field 2)" do
      basic = field(1, "BTCUSD") <> field(3, "1787936147000")

      fields = [field(1, basic), field(2, "1787936148000"), field(3, "100.5"), field(8, "42")]
      payload = IO.iodata_to_binary(fields)

      assert {:ok, got} = QuoteProto.decode_snapshot(payload)

      assert got == %{
               symbol: "BTCUSD",
               price: "100.5",
               volume: "42",
               timestamp: "1787936148000"
             }
    end

    test "decode_snapshot: no trade_time is a nil timestamp, never Basic.timestamp" do
      basic = field(1, "BTCUSD") <> field(3, "1787936147000")

      assert {:ok, %{timestamp: nil, volume: nil}} =
               QuoteProto.decode_snapshot(field(1, basic) <> field(3, "100.5"))
    end

    test "decode_snapshot: a missing symbol or price is :error" do
      assert :error = QuoteProto.decode_snapshot(field(3, "100.5"))
      assert :error = QuoteProto.decode_snapshot(field(1, field(1, "BTCUSD")))
      assert :error = QuoteProto.decode_snapshot(:not_binary)
    end

    test "decode_tick: time (2) else Basic.timestamp, price 3, volume 4, side 5" do
      basic = field(1, "BTCUSD") <> field(3, "1787936147000")

      fields = [field(1, basic), field(2, ""), field(3, "9.5"), field(4, "2"), field(5, "B")]
      payload = IO.iodata_to_binary(fields)

      assert {:ok, got} = QuoteProto.decode_tick(payload)

      assert got == %{
               symbol: "BTCUSD",
               price: "9.5",
               volume: "2",
               side: "B",
               timestamp: "1787936147000",
               basic_timestamp: "1787936147000"
             }
    end

    test "decode_tick: its own time wins over Basic.timestamp, and :error without a price" do
      basic = field(1, "BTCUSD") <> field(3, "1787936147000")

      own_time = field(1, basic) <> field(2, "1787936149000") <> field(3, "1")

      assert {:ok, %{timestamp: "1787936149000", basic_timestamp: "1787936147000"}} =
               QuoteProto.decode_tick(own_time)

      assert :error = QuoteProto.decode_tick(field(1, basic))
      assert :error = QuoteProto.decode_tick(nil)
    end

    test "decode_quote: the first entry of asks (2) and of bids (3), with both sizes" do
      basic = field(1, "BTCUSD") <> field(3, "1787936147000")

      level = fn price, size -> field(1, price) <> field(2, size) end

      payload =
        IO.iodata_to_binary([
          field(1, basic),
          field(2, level.("101", "3")),
          field(2, level.("102", "9")),
          field(3, level.("99", "7"))
        ])

      assert {:ok, got} = QuoteProto.decode_quote(payload)

      assert got == %{
               symbol: "BTCUSD",
               ask: "101",
               ask_size: "3",
               bid: "99",
               bid_size: "7",
               timestamp: "1787936147000"
             }
    end

    test "decode_quote: an absent side is nil, a missing symbol is :error" do
      basic = field(1, "BTCUSD")

      assert {:ok, %{ask: nil, ask_size: nil, bid: "99", bid_size: nil, timestamp: nil}} =
               QuoteProto.decode_quote(field(1, basic) <> field(3, field(1, "99")))

      assert :error = QuoteProto.decode_quote(field(2, field(1, "101")))
      assert :error = QuoteProto.decode_quote(42)
    end

    test "decode_message: a field seen once is a binary, seen again a list, in wire order" do
      assert QuoteProto.decode_message(field(3, "a") <> field(3, "b") <> field(4, "c")) ==
               %{3 => ["a", "b"], 4 => "c"}
    end

    test "scalar/2 is the last occurrence, and nil for an absent field" do
      fields = QuoteProto.decode_message(field(3, "a") <> field(3, "b"))

      assert QuoteProto.scalar(fields, 3) == "b"
      assert QuoteProto.scalar(fields, 9) == nil
    end
  end
end
