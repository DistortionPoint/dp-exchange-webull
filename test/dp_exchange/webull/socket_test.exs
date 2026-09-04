defmodule DpExchange.Webull.SocketTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias DpExchange.Core.Notice
  alias DpExchange.Core.Types.{Quote, TopOfBook}
  alias DpExchange.Webull.Socket

  @moduletag :capture_log

  # The frame handlers are pure given a state, so they are driven directly. No socket is
  # opened and no venue is reached — a tier-1 test that dials a venue is a tier-2 test
  # wearing the wrong tag.
  defp state,
    do: %{subscriber: self(), session_id: "s1", app_key: "k", buffer: <<>>, connected?: false}

  defp varint(value) when value < 0x80, do: <<value>>
  defp varint(value), do: <<1::1, band(value, 0x7F)::7, varint(bsr(value, 7))::binary>>

  defp proto_field(number, value) do
    varint(bsl(number, 3) ||| 2) <> varint(byte_size(value)) <> value
  end

  defp snapshot_payload(symbol, price, timestamp \\ "1787936147000") do
    basic = proto_field(1, symbol) <> proto_field(3, timestamp)
    proto_field(1, basic) <> proto_field(3, price)
  end

  defp publish(topic, payload) do
    body = <<byte_size(topic)::16>> <> topic <> payload
    <<3::4, 0::4>> <> varint(byte_size(body)) <> body
  end

  defp connack(code), do: <<2::4, 0::4, 2, 0, code>>

  describe "CONNACK is where the link actually comes up" do
    test "code 0 raises link_up" do
      # The WebSocket being open is not the venue being reachable. Reporting a live link
      # before the CONNACK would report the transport, not the venue.
      assert {:ok, state} = Socket.handle_frame({:binary, connack(0)}, state())

      assert_receive {:dp_exchange, :webull, %Notice{kind: :link_up}}
      assert state.connected?
    end

    test "credential codes are reported as credentials, not as a link failure" do
      for code <- [3, 103, 104] do
        assert {:ok, _state} = Socket.handle_frame({:binary, connack(code)}, state())

        assert_receive {:dp_exchange, :webull, %Notice{kind: :credentials_rejected} = notice}
        assert notice.details.connack == code
      end
    end

    test "the connection-limit code is NOT reported as a credential problem" do
      # 104 and 105 are one integer apart and mean entirely different things. Reporting a
      # limit breach as rejected credentials sends an operator to rotate a key that is fine.
      assert {:ok, _state} = Socket.handle_frame({:binary, connack(105)}, state())

      assert_receive {:dp_exchange, :webull, %Notice{kind: :degraded} = notice}
      assert notice.details.reason == :connection_limit
      assert notice.message =~ "five concurrent connections"
    end

    test "any other refusal is a link failure carrying the code" do
      assert {:ok, _state} = Socket.handle_frame({:binary, connack(1)}, state())

      assert_receive {:dp_exchange, :webull, %Notice{kind: :link_down} = notice}
      assert notice.details.connack == 1
    end
  end

  describe "payloads become Quotes" do
    test "a snapshot carries the price and the canonical symbol" do
      frame = publish("snapshot", snapshot_payload("BTCUSD", "77845.79"))

      assert {:ok, _state} = Socket.handle_frame({:binary, frame}, state())

      assert_receive {:dp_exchange, :webull, %Quote{} = quote_struct}
      assert quote_struct.symbol == "BTC-USD"
      assert Decimal.equal?(quote_struct.price, Decimal.new("77845.79"))
      assert quote_struct.provider == :webull
    end

    test "volume is nil, because this venue reports none on the stream either" do
      frame = publish("snapshot", snapshot_payload("BTCUSD", "1"))

      assert {:ok, _state} = Socket.handle_frame({:binary, frame}, state())

      assert_receive {:dp_exchange, :webull, %Quote{volume: nil}}
    end

    test "a payload with no venue timestamp delivers nothing" do
      basic = proto_field(1, "BTCUSD")
      frame = publish("snapshot", proto_field(1, basic) <> proto_field(3, "1"))

      assert {:ok, _state} = Socket.handle_frame({:binary, frame}, state())

      refute_receive {:dp_exchange, :webull, %Quote{}}, 50
    end

    test "a non-numeric price in a real frame does not crash the socket" do
      # Decimal.new/1 used to raise on this exact shape, taking the whole connection down
      # over one malformed field on one symbol.
      frame = publish("snapshot", snapshot_payload("BTCUSD", "null"))

      assert {:ok, _state} = Socket.handle_frame({:binary, frame}, state())

      refute_receive {:dp_exchange, :webull, %Quote{}}, 50
    end

    for nan_or_inf <- ["NaN", "Inf", "-Inf"] do
      test "a #{nan_or_inf} price is dropped rather than admitted as real" do
        # Decimal.parse/1 alone was not a sufficient guard for the "null" fix above:
        # #{unquote(nan_or_inf)} fully parses, and would have flowed through as a real
        # Quote.price without the nan?/inf? check.
        frame = publish("snapshot", snapshot_payload("BTCUSD", unquote(nan_or_inf)))

        assert {:ok, _state} = Socket.handle_frame({:binary, frame}, state())

        refute_receive {:dp_exchange, :webull, %Quote{}}, 50
      end
    end

    test "a book message delivers top-of-book, and never a price" do
      # This asserted the opposite until 2026-08-31: that `price` became the bid, with a
      # comment calling the bid "a real quoted number, labelled as the bid too". It is
      # real, and it is not a price — a bid is a resting order and a price is an execution.
      # The same substitution was found on two other venues in this family.
      basic = proto_field(1, "BTCUSD") <> proto_field(3, "1787936147000")
      bid_level = proto_field(1, "77845.79")
      frame = publish("quote", proto_field(1, basic) <> proto_field(3, bid_level))

      assert {:ok, _state} = Socket.handle_frame({:binary, frame}, state())

      assert_receive {:dp_exchange, :webull, %TopOfBook{} = top}
      assert Decimal.equal?(top.bid, Decimal.new("77845.79"))
      assert top.ask == nil
      refute Map.has_key?(top, :price)

      refute_receive {:dp_exchange, :webull, %Quote{}}, 50
    end

    test "a book with no levels at all delivers nothing" do
      basic = proto_field(1, "BTCUSD") <> proto_field(3, "1787936147000")
      frame = publish("quote", proto_field(1, basic))

      assert {:ok, _state} = Socket.handle_frame({:binary, frame}, state())

      refute_receive {:dp_exchange, :webull, %Quote{}}, 50
    end
  end

  describe "topics carry different encodings, and one handler must not assume otherwise" do
    test "a JSON notice becomes a notice, not a dropped protobuf" do
      # Three topics are protobuf, one is JSON, one is empty. The prior adapter called
      # Jason.decode/1 on all of them and would have dropped four fifths of the traffic.
      frame = publish("notice", Jason.encode!(%{"type" => "rate", "msg" => "slow down"}))

      assert {:ok, _state} = Socket.handle_frame({:binary, frame}, state())

      assert_receive {:dp_exchange, :webull, %Notice{kind: :degraded} = notice}
      assert notice.details.venue_notice["type"] == "rate"
    end

    test "an echo heartbeat carries no payload and produces nothing" do
      assert {:ok, _state} = Socket.handle_frame({:binary, publish("echo", "")}, state())

      refute_receive {:dp_exchange, :webull, _anything}, 50
    end

    test "an unparseable protobuf is dropped without costing the connection" do
      frame = publish("snapshot", <<0xFF, 0xFF, 0xFF>>)

      assert {:ok, _state} = Socket.handle_frame({:binary, frame}, state())

      refute_receive {:dp_exchange, :webull, %Quote{}}, 50
    end
  end

  describe "the buffer, because frames are not packets" do
    test "two packets in one frame both arrive" do
      # Assuming frame boundaries are packet boundaries loses everything after the first
      # — quietly, because the socket stays up and the first message parses fine.
      frame =
        publish("snapshot", snapshot_payload("BTCUSD", "1")) <>
          publish("snapshot", snapshot_payload("ETHUSD", "2"))

      assert {:ok, state} = Socket.handle_frame({:binary, frame}, state())

      assert_receive {:dp_exchange, :webull, %Quote{symbol: "BTC-USD"}}
      assert_receive {:dp_exchange, :webull, %Quote{symbol: "ETH-USD"}}
      assert state.buffer == <<>>
    end

    test "half a packet is retained until the rest arrives" do
      full = publish("snapshot", snapshot_payload("BTCUSD", "77845.79"))
      {head, tail} = String.split_at(full, byte_size(full) - 4)

      assert {:ok, state} = Socket.handle_frame({:binary, head}, state())
      refute_receive {:dp_exchange, :webull, %Quote{}}, 50
      assert state.buffer == head

      assert {:ok, state} = Socket.handle_frame({:binary, tail}, state)
      assert_receive {:dp_exchange, :webull, %Quote{symbol: "BTC-USD"}}
      assert state.buffer == <<>>
    end

    test "an unresynchronisable stream drops the buffer and SAYS so" do
      # Retaining bytes that can never parse leaves a live socket delivering nothing,
      # which is the failure mode this family ranks worst.
      garbage = <<3::4, 0::4, 0x80, 0x80, 0x80, 0x80, 0x80>>

      assert {:ok, state} = Socket.handle_frame({:binary, garbage}, state())

      assert_receive {:dp_exchange, :webull, %Notice{kind: :data_quality} = notice}
      assert notice.details.dropped == :malformed_frame
      assert state.buffer == <<>>
    end
  end

  describe "connection lifecycle" do
    test "connecting sends CONNECT rather than declaring the link up" do
      assert {:ok, _state} = Socket.handle_connect(:conn, state())
      assert_receive :send_connect

      assert {:reply, {:binary, packet}, _state} = Socket.handle_info(:send_connect, state())
      assert <<1::4, 0::4, _rest::binary>> = packet
      assert packet =~ "s1"
    end

    test "a ping goes out on the keep-alive schedule" do
      assert {:reply, {:binary, <<12::4, 0::4, 0>>}, _state} = Socket.handle_info(:ping, state())
    end

    test "disconnecting clears the buffer, because a half packet cannot span a reconnect" do
      dirty = %{state() | buffer: <<1, 2, 3>>, connected?: true}

      assert {:reconnect, state} = Socket.handle_disconnect(%{reason: :closed}, dirty)

      assert state.buffer == <<>>
      refute state.connected?
      assert_receive {:dp_exchange, :webull, %Notice{kind: :link_down}}
    end

    test "a text frame is ignored — this venue speaks binary" do
      assert {:ok, _state} = Socket.handle_frame({:text, "hello"}, state())
    end
  end
end
