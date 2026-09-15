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

    test "a level's size is the venue's own and is carried, not discarded" do
      # `AskBid { string price = 1; string size = 2; }` — the venue's schema, verbatim in
      # docs/reference/webull/streaming-api.md. Field 2 was decoded off the wire and then
      # thrown away, while `Socket`'s own comment said "the venue's book message carries
      # prices and no sizes". It carries both, and the fixtures in this very file have been
      # building levels with sizes all along.
      ask = field(1, "77846.48") <> field(2, "0.014")
      bid = field(1, "77845.79") <> field(2, "0.045")

      payload = field(1, basic("BTCUSD")) <> field(2, ask) <> field(3, bid)

      assert {:ok, quote_msg} = QuoteProto.decode_quote(payload)
      assert quote_msg.ask_size == "0.014"
      assert quote_msg.bid_size == "0.045"
    end

    test "a level that states no size reports nil, which is not a size of zero" do
      # `Core.Types.TopOfBook`: "`nil` means 'not published', never 'none available'". A zero
      # would say the level is empty, which is a different and much stronger claim.
      payload = field(1, basic("BTCUSD")) <> field(3, field(1, "77845.79"))

      assert {:ok, quote_msg} = QuoteProto.decode_quote(payload)
      assert quote_msg.bid == "77845.79"
      assert quote_msg.bid_size == nil
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

  describe "a wrong wire type on a field the SCHEMA uses" do
    # The compatibility tests above all put the unknown field at a field number the schema
    # does not use — 99, 50, 51, 52. That is the easy half. The hard half is the same
    # unknown wire type arriving at a number the schema DOES use, because then the junk and
    # the real value accumulate into one list under one key, and whichever reader takes that
    # key has to cope with a list that is not all binaries.
    #
    # `scalar/1` and `decode_nested/1` both filtered for `is_binary/1` already.
    # `first_repeated/2` took `[first | _rest]` unfiltered and handed the junk to a function
    # with clauses for a binary and for `nil` and none for an integer. The result was a
    # `FunctionClauseError` raised inside the socket process — no `rescue` between there and
    # `handle_frame/2` — so the connection dropped and reconnected to be handed the same
    # frame again. This module's moduledoc promises the opposite in as many words: "one
    # malformed frame must not cost the connection".
    defp varint_field(number, value) do
      varint(Bitwise.bsl(number, 3) ||| 0) <> varint(value)
    end

    test "a varint at the asks field number does not raise, and the real level survives" do
      ask = field(1, "77846.48") <> field(2, "0.014")
      bid = field(1, "77845.79") <> field(2, "0.045")

      payload =
        field(1, basic("BTCUSD")) <> varint_field(2, 7) <> field(2, ask) <> field(3, bid)

      assert {:ok, quote_msg} = QuoteProto.decode_quote(payload)
      assert quote_msg.ask == "77846.48"
      assert quote_msg.ask_size == "0.014"
      assert quote_msg.bid == "77845.79"
    end

    test "a 32-bit at the bids field number still yields the level behind it" do
      bid = field(1, "77845.79") <> field(2, "0.045")
      fixed32 = varint(Bitwise.bsl(3, 3) ||| 5) <> <<0::32>>

      payload = field(1, basic("BTCUSD")) <> fixed32 <> field(3, bid)

      assert {:ok, quote_msg} = QuoteProto.decode_quote(payload)
      assert quote_msg.bid == "77845.79"
      assert quote_msg.bid_size == "0.045"
    end

    test "junk at a schema field number never fabricates a level" do
      # The other direction: refusing to raise must not turn into inventing. With nothing
      # but junk under the asks number, there is no ask, and `nil` is the answer.
      payload = field(1, basic("BTCUSD")) <> varint_field(2, 7) <> field(3, field(1, "1.00"))

      assert {:ok, quote_msg} = QuoteProto.decode_quote(payload)
      assert quote_msg.ask == nil
      assert quote_msg.ask_size == nil
    end
  end

  describe "wire order survives the accumulator" do
    # `accumulate/3` prepends and `decode_message/1` reverses once at the end, rather than
    # appending with `existing ++ [value]` — which is O(n) per entry and O(n²) per message.
    # Measured on a synthetic book before the change: 5 levels a side 2.8us, 50 levels
    # 12.7us, 100 levels 33.6us, 200 levels 120.1us. After: 2.7us, 8.2us and 35.4us — and
    # `AskBid` carries `repeated Order` and `repeated Broker`, so a level binary runs the
    # same accumulator again for every market maker quoted at that price.
    #
    # Both readers depend on the order, in OPPOSITE directions, which is why the reversal is
    # load-bearing rather than tidiness: `first_repeated/2` wants the first entry on the wire
    # and `scalar/1` wants the last. A reversal applied to one and not the other, or dropped
    # entirely, would leave each of them reading the far end of the book.
    test "a repeated field still reads FIRST-on-the-wire" do
      payload =
        field(1, basic("BTCUSD")) <>
          field(2, field(1, "1.00")) <>
          field(2, field(1, "2.00")) <> field(2, field(1, "3.00"))

      assert {:ok, quote_msg} = QuoteProto.decode_quote(payload)
      assert quote_msg.ask == "1.00"
    end

    test "a scalar field still reads LAST-on-the-wire" do
      payload =
        field(1, basic("BTCUSD")) <>
          field(3, "111.00") <> field(3, "222.00") <> field(3, "333.00")

      assert {:ok, snapshot} = QuoteProto.decode_snapshot(payload)
      assert snapshot.price == "333.00"
    end

    test "decode_message/1 hands back repeats in wire order" do
      assert %{7 => ["a", "b", "c"]} =
               QuoteProto.decode_message(field(7, "a") <> field(7, "b") <> field(7, "c"))
    end

    test "a stepped-over field holds its place in the repeat rather than being replaced" do
      # `accumulate/3` reads with `Map.fetch/2`, because `decode_value/2` stores `nil` as the
      # value of a 64-bit or 32-bit field it stepped over and `Map.get/2` cannot tell that
      # from an absent key — under `Map.get/2` the `"a"` REPLACED the placeholder and this
      # map came back as `%{7 => "a"}`.
      #
      # Stated precisely, because the first version of this test claimed more than it could
      # show: **no decoded field changes value either way.** Every reader in the module
      # filters for `is_binary/1`, so the placeholder is invisible to all of them, and the
      # difference surfaces only here, through the public `decode_message/1`. This is the
      # assertion that the conflation is gone; it is not evidence that a level was being
      # dropped, because it was not.
      fixed32 = varint(Bitwise.bsl(7, 3) ||| 5) <> <<0::32>>

      assert %{7 => [nil, "a"]} = QuoteProto.decode_message(fixed32 <> field(7, "a"))
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
