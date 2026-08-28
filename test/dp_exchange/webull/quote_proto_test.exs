defmodule DpExchange.Webull.QuoteProtoTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias DpExchange.Webull.QuoteProto

  doctest DpExchange.Webull.QuoteProto

  # Building the wire format by hand rather than with an encoder: the point of these tests
  # is that the decoder reads what a proto3 encoder produces, and generating both sides
  # from the same code would prove only that it agrees with itself.
  defp varint(value) when value < 0x80, do: <<value>>

  defp varint(value),
    do: <<1::1, Bitwise.band(value, 0x7F)::7, varint(Bitwise.bsr(value, 7))::binary>>

  defp field(number, value) when is_binary(value) do
    varint(Bitwise.bsl(number, 3) ||| 2) <> varint(byte_size(value)) <> value
  end

  defp basic(symbol, timestamp \\ "1787936147000") do
    field(1, symbol) <> field(3, timestamp)
  end

  describe "decode_snapshot/1" do
    test "reads the nested symbol and the price" do
      payload = field(1, basic("BTCUSD")) <> field(3, "77845.79") <> field(8, "183.72")

      assert {:ok, snapshot} = QuoteProto.decode_snapshot(payload)
      assert snapshot.symbol == "BTCUSD"
      assert snapshot.price == "77845.79"
      assert snapshot.volume == "183.72"
    end

    test "prefers trade_time over the message-assembly timestamp" do
      # They differ, and only the first describes the trade. Taking `Basic.timestamp`
      # would date a print by when the venue built the frame around it.
      payload =
        field(1, basic("BTCUSD", "1111111111111")) <>
          field(2, "2222222222222") <>
          field(3, "77845.79")

      assert {:ok, snapshot} = QuoteProto.decode_snapshot(payload)
      assert snapshot.timestamp == "2222222222222"
    end

    test "falls back to the assembly timestamp when there is no trade time" do
      payload = field(1, basic("BTCUSD", "1111111111111")) <> field(3, "77845.79")

      assert {:ok, snapshot} = QuoteProto.decode_snapshot(payload)
      assert snapshot.timestamp == "1111111111111"
    end

    test "a payload with no price is an error, not a snapshot with a nil price" do
      payload = field(1, basic("BTCUSD"))

      assert QuoteProto.decode_snapshot(payload) == :error
    end

    test "a payload with no symbol is an error" do
      payload = field(3, "77845.79")

      assert QuoteProto.decode_snapshot(payload) == :error
    end

    test "an EMPTY string is an absent field, not a value" do
      # Proto3 does not distinguish them on the wire. Passing "" on as a price turns a
      # missing field into an unparseable number one layer down.
      payload = field(1, basic("BTCUSD")) <> field(3, "")

      assert QuoteProto.decode_snapshot(payload) == :error
    end

    test "an empty volume is nil rather than an empty string" do
      payload = field(1, basic("BTCUSD")) <> field(3, "77845.79") <> field(8, "")

      assert {:ok, snapshot} = QuoteProto.decode_snapshot(payload)
      assert snapshot.volume == nil
    end

    test "garbage is an error rather than a crash" do
      # This runs in the socket process. One malformed frame must not cost the connection.
      assert QuoteProto.decode_snapshot(<<0xFF, 0xFF, 0xFF>>) == :error
      assert QuoteProto.decode_snapshot("") == :error
      assert QuoteProto.decode_snapshot(:not_a_binary) == :error
    end
  end

  describe "decode_tick/1" do
    test "reads price, volume and side" do
      payload =
        field(1, basic("BTCUSD")) <>
          field(2, "1787936147000") <>
          field(3, "77845.79") <>
          field(4, "0.5") <> field(5, "BUY")

      assert {:ok, tick} = QuoteProto.decode_tick(payload)
      assert tick.price == "77845.79"
      assert tick.volume == "0.5"
      assert tick.side == "BUY"
    end

    test "a tick with no price is an error" do
      assert QuoteProto.decode_tick(field(1, basic("BTCUSD"))) == :error
    end
  end

  describe "decode_quote/1" do
    test "takes the FIRST level of each side, which is the venue's own best" do
      ask = field(1, "77846.48") <> field(2, "0.014")
      ask2 = field(1, "77850.00") <> field(2, "1.0")
      bid = field(1, "77845.79") <> field(2, "0.045")

      payload = field(1, basic("BTCUSD")) <> field(2, ask) <> field(2, ask2) <> field(3, bid)

      assert {:ok, quote_msg} = QuoteProto.decode_quote(payload)
      assert quote_msg.ask == "77846.48"
      assert quote_msg.bid == "77845.79"
    end

    test "computes no mid — that is the caller's decision" do
      payload = field(1, basic("BTCUSD")) <> field(2, field(1, "2")) <> field(3, field(1, "1"))

      assert {:ok, quote_msg} = QuoteProto.decode_quote(payload)
      refute Map.has_key?(quote_msg, :mid)
      refute Map.has_key?(quote_msg, :price)
    end

    test "one-sided books yield a nil for the missing side, not a fabricated level" do
      payload = field(1, basic("BTCUSD")) <> field(3, field(1, "77845.79"))

      assert {:ok, quote_msg} = QuoteProto.decode_quote(payload)
      assert quote_msg.bid == "77845.79"
      assert quote_msg.ask == nil
    end
  end

  describe "proto3 compatibility rules" do
    test "an unknown field is skipped rather than breaking the walk" do
      # The rule that keeps a venue adding a field from taking the socket down.
      unknown = field(99, "something new")
      payload = field(1, basic("BTCUSD")) <> unknown <> field(3, "77845.79")

      assert {:ok, snapshot} = QuoteProto.decode_snapshot(payload)
      assert snapshot.price == "77845.79"
    end

    test "an unknown VARINT field is stepped over correctly" do
      varint_field = varint(Bitwise.bsl(50, 3) ||| 0) <> varint(300)
      payload = field(1, basic("BTCUSD")) <> varint_field <> field(3, "77845.79")

      assert {:ok, snapshot} = QuoteProto.decode_snapshot(payload)
      assert snapshot.price == "77845.79"
    end

    test "unknown 64-bit and 32-bit fields are stepped over" do
      fixed64 = varint(Bitwise.bsl(51, 3) ||| 1) <> <<0::64>>
      fixed32 = varint(Bitwise.bsl(52, 3) ||| 5) <> <<0::32>>
      payload = field(1, basic("BTCUSD")) <> fixed64 <> fixed32 <> field(3, "77845.79")

      assert {:ok, snapshot} = QuoteProto.decode_snapshot(payload)
      assert snapshot.price == "77845.79"
    end

    test "a scalar sent TWICE takes the last, and does not reject the message" do
      # Legal on the wire and specified by proto3. The adapter this was ported from turned
      # a repeated scalar into a list, its `is_binary` guard then failed, and the whole
      # message was dropped — silently, for input the specification calls valid.
      payload = field(1, basic("BTCUSD")) <> field(3, "111.00") <> field(3, "222.00")

      assert {:ok, snapshot} = QuoteProto.decode_snapshot(payload)
      assert snapshot.price == "222.00"
    end

    test "a truncated tail ends the walk with what was read" do
      payload = field(1, basic("BTCUSD")) <> field(3, "77845.79") <> <<0x1A, 0xFF>>

      assert {:ok, snapshot} = QuoteProto.decode_snapshot(payload)
      assert snapshot.price == "77845.79"
    end
  end

  describe "scalar/2" do
    test "reads a single value" do
      assert QuoteProto.scalar(%{1 => "x"}, 1) == "x"
    end

    test "takes the last of a repeat" do
      assert QuoteProto.scalar(%{1 => ["a", "b", "c"]}, 1) == "c"
    end

    test "an absent field is nil" do
      assert QuoteProto.scalar(%{}, 1) == nil
    end

    test "ignores non-binary entries from skipped wire types" do
      assert QuoteProto.scalar(%{1 => [nil, "b"]}, 1) == "b"
    end
  end
end
