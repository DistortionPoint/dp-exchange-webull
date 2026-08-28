defmodule DpExchange.Webull.SymbolFormatTest do
  use ExUnit.Case, async: true

  alias DpExchange.Webull.SymbolFormat

  describe "the overlapping-quote ordering" do
    test "USDT and USDC win over USD" do
      # Without longest-first, `BTCUSDT` splits as `BTCUS`/`DT` or `BTCUSD`/`T`, and
      # neither is an asset — it matches no catalogue entry and collects nothing.
      assert SymbolFormat.to_canonical_symbol("BTCUSDT") == "BTC-USDT"
      assert SymbolFormat.to_canonical_symbol("ETHUSDC") == "ETH-USDC"
    end

    test "plain USD still splits" do
      assert SymbolFormat.to_canonical_symbol("BTCUSD") == "BTC-USD"
    end

    test "crypto-quoted pairs split too" do
      assert SymbolFormat.to_canonical_symbol("ETHBTC") == "ETH-BTC"
    end

    test "the quote list is ordered longest-first" do
      lengths = Enum.map(SymbolFormat.quotes(), &String.length/1)

      assert lengths == Enum.sort(lengths, :desc)
    end
  end

  describe "round-tripping, which is what the write path depends on" do
    test "every sample pair survives both directions" do
      # An audit of the adapter this came from found `build_order_body` sending the
      # CANONICAL symbol to the venue un-converted — reads worked, writes silently did
      # not. One mapping, both directions, is the fix.
      for canonical <- ~w(BTC-USD BTC-USDT ETH-USDC ETH-BTC) do
        native = SymbolFormat.to_exchange_symbol(canonical)

        assert SymbolFormat.to_canonical_symbol(native) == canonical,
               "#{canonical} -> #{native} -> #{SymbolFormat.to_canonical_symbol(native)}"
      end
    end

    test "the exchange form carries no separator" do
      assert SymbolFormat.to_exchange_symbol("BTC-USD") == "BTCUSD"
      refute SymbolFormat.to_exchange_symbol("BTC-USDT") =~ "-"
    end

    test "an already-canonical string is not re-split" do
      assert SymbolFormat.to_canonical_symbol("BTC-USD") == "BTC-USD"
    end
  end

  describe "the mapping is exposed so it cannot drift" do
    test "mapping/0 and quotes/0 agree" do
      assert SymbolFormat.mapping().quotes == SymbolFormat.quotes()
      assert SymbolFormat.mapping().sep == ""
    end
  end
end
