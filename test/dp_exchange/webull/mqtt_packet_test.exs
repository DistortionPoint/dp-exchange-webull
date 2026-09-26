defmodule DpExchange.Webull.MqttPacketTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias DpExchange.Webull.MqttPacket

  describe "CONNECT" do
    test "carries the protocol name, level and the three payload strings" do
      packet = MqttPacket.connect("session-1", "app-key", "anything")

      assert <<1::4, 0::4, _length, rest::binary>> = packet
      assert <<4::16, "MQTT", 4, flags, keep_alive::16, payload::binary>> = rest

      # bit 7 username, bit 6 password, bit 1 clean session
      assert flags == 0b1100_0010
      assert keep_alive == 60

      assert <<9::16, "session-1", 7::16, "app-key", 8::16, "anything">> = payload
    end

    test "the client id is the session id the HTTP subscribe will also name" do
      # The only thing joining the two transports. A mismatch means an MQTT connection
      # that is up and a subscription that feeds a different one.
      packet = MqttPacket.connect("shared-session", "key", "pw")

      assert packet =~ "shared-session"
    end

    test "the keep-alive is configurable" do
      assert <<1::4, 0::4, _len, 4::16, "MQTT", 4, _flags, 30::16, _rest::binary>> =
               MqttPacket.connect("s", "u", "p", 30)
    end
  end

  # SUBSCRIBE and SUBACK used to be here. Deleted, not merely unused: this venue's own
  # documentation states subscriptions are HTTP calls, not MQTT ones (see
  # `DpExchange.Webull.Subscription` and `MqttPacket`'s own moduledoc), and nothing in
  # `lib/` ever sent one — every test that exercised a live-feeling socket, including
  # `SocketTest`'s and `Feed`'s, did so without a `SUBSCRIBE` going out.

  describe "PINGREQ and DISCONNECT" do
    test "are two bytes with a zero remaining length" do
      assert MqttPacket.pingreq() == <<12::4, 0::4, 0>>
      assert MqttPacket.disconnect() == <<14::4, 0::4, 0>>
    end
  end

  describe "decode/1 — CONNACK" do
    test "surfaces the return code verbatim" do
      # 0 accepted, and the rest demand completely different fixes: 4 is bad credentials,
      # 1 is a protocol version mismatch.
      for code <- [0, 1, 2, 3, 4, 5] do
        assert {:ok, {:connack, ^code}, ""} = MqttPacket.decode(<<2::4, 0::4, 2, 0, code>>)
      end
    end
  end

  describe "decode/1 — PUBLISH" do
    defp publish_packet(topic, payload, qos \\ 0) do
      flags = bsl(qos, 1)
      body = <<byte_size(topic)::16>> <> topic <> payload
      <<3::4, flags::4>> <> <<byte_size(body)>> <> body
    end

    test "splits topic from payload at QoS 0" do
      packet = publish_packet("quote", <<1, 2, 3>>)

      assert {:ok, {:publish, "quote", <<1, 2, 3>>}, ""} = MqttPacket.decode(packet)
    end

    test "a QoS 1 publish does NOT leak its packet id into the payload" do
      # The bug this guards: at QoS 1 the two bytes after the topic are a packet
      # identifier. Read as payload they become the head of the protobuf, which does not
      # fail — it decodes into a slightly wrong message.
      body = <<5::16, "quote", 7::16, 1, 2, 3>>
      packet = <<3::4, bsl(1, 1)::4>> <> <<byte_size(body)>> <> body

      assert {:ok, {:publish, "quote", <<1, 2, 3>>}, ""} = MqttPacket.decode(packet)
    end

    test "an empty payload is still a publish" do
      assert {:ok, {:publish, "echo", ""}, ""} = MqttPacket.decode(publish_packet("echo", ""))
    end
  end

  describe "decode/1 — buffering, because frames are not packets" do
    test "returns the remainder so a caller can loop" do
      first = publish_packet("quote", <<1>>)
      second = publish_packet("tick", <<2>>)

      assert {:ok, {:publish, "quote", <<1>>}, rest} = MqttPacket.decode(first <> second)
      assert {:ok, {:publish, "tick", <<2>>}, ""} = MqttPacket.decode(rest)
    end

    test "a half-arrived packet is :incomplete, which is an ordinary state" do
      full = publish_packet("quote", <<1, 2, 3>>)
      half = binary_part(full, 0, byte_size(full) - 2)

      assert MqttPacket.decode(half) == {:error, :incomplete}
    end

    test "an empty buffer is :incomplete" do
      assert MqttPacket.decode("") == {:error, :incomplete}
    end

    test "a length whose bytes have not arrived is :incomplete" do
      assert MqttPacket.decode(<<3::4, 0::4, 0x80>>) == {:error, :incomplete}
    end
  end

  describe "remaining length" do
    test "encodes and decodes a multi-byte length" do
      # 300 bytes needs two length bytes; the boundary at 128 is where naive encoders
      # break. This used to decode the CONNECT it encoded, which `decode/1` now rightly
      # refuses: a broker never sends one (see `valid_header?/3`). So the two halves are
      # checked on their own: `connect/4` writes the two-byte length, and a server-sent
      # PUBLISH carrying one decodes.
      long_client_id = String.duplicate("t", 300)
      <<1::4, 0::4, low, high, body::binary>> = MqttPacket.connect(long_client_id, "k", "pw")

      assert low >= 0x80 and high < 0x80
      assert Bitwise.band(low, 0x7F) + Bitwise.bsl(high, 7) == byte_size(body)

      payload = String.duplicate("p", 300)
      publish_body = <<5::16>> <> "quote" <> payload
      len = byte_size(publish_body)
      header = <<3::4, 0::4, 1::1, Bitwise.band(len, 0x7F)::7, Bitwise.bsr(len, 7)>>

      assert {:ok, {:publish, "quote", ^payload}, ""} = MqttPacket.decode(header <> publish_body)
    end

    test "a header no broker may send is malformed, not waited on" do
      # MQTT 3.1.1 §2.2. A PINGRESP declaring a body used to swallow that many bytes of the
      # real packets after it. See `decode/1`'s doc.
      for bad <- [
            <<13::4, 0::4, 26>>,
            <<2::4, 0::4, 3, 0, 0, 0>>,
            <<2::4, 1::4, 2, 0, 0>>,
            <<3::4, 6::4, 10>>,
            <<8::4, 2::4, 5>>,
            <<1::4, 0::4, 2>>,
            <<0::4, 0::4, 0>>
          ] do
        assert MqttPacket.decode(bad) == {:error, :malformed_header}, "#{inspect(bad)}"
      end
    end

    test "every header a broker may send still decodes" do
      assert {:ok, {:connack, 0}, ""} = MqttPacket.decode(<<2::4, 0::4, 2, 0, 0>>)
      assert {:ok, :pingresp, ""} = MqttPacket.decode(<<13::4, 0::4, 0>>)
      assert {:ok, {:publish, "t", "x"}, ""} = MqttPacket.decode(<<3::4, 0::4, 4, 0, 1, ?t, ?x>>)
    end

    test "a FIFTH continuation byte is malformed, not incomplete" do
      # The bug this guards: returning `:incomplete` tells the caller to wait for more
      # bytes, and no future byte can repair a length that is already invalid. The read
      # buffer would park forever with the socket up and the subscription live — silence,
      # which is the worst failure mode this family has.
      assert MqttPacket.decode(<<3::4, 0::4, 0x80, 0x80, 0x80, 0x80, 0x80>>) ==
               {:error, :malformed_length}
    end
  end

  describe "packets this venue does not use" do
    test "are reported rather than silently dropped" do
      # PUBACK (4). Seeing one means an assumption about QoS is wrong somewhere, which is
      # worth knowing rather than discarding.
      assert {:ok, {:unhandled, 4, <<1, 2>>}, ""} = MqttPacket.decode(<<4::4, 0::4, 2, 1, 2>>)
    end
  end
end
