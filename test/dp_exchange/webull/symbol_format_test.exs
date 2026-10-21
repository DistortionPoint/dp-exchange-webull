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

    # `quotes/0` is defined as `mapping().quotes`, so the test above holds for ANY mapping,
    # including an empty one. This pins what the venue's mapping actually is.
    test "the mapping is the venue's: no separator, and exactly these quote currencies" do
      assert SymbolFormat.mapping() == %{sep: "", quotes: ~w(USDT USDC USD BTC ETH)}
    end
  end

  describe "concrete conversions, so a mapping that round-trips wrongly cannot pass" do
    # A round trip passes however the cut is made (`BTCUSDT` -> `BTCUS`/`DT` -> `BTCUSDT`),
    # so each direction is also asserted against the value the venue actually uses.
    test "native to canonical" do
      assert SymbolFormat.to_canonical_symbol("BTCUSDT") == "BTC-USDT"
      assert SymbolFormat.to_canonical_symbol("ETHUSDC") == "ETH-USDC"
      assert SymbolFormat.to_canonical_symbol("BTCETH") == "BTC-ETH"
      assert SymbolFormat.to_canonical_symbol("ETHBTC") == "ETH-BTC"
      assert SymbolFormat.to_canonical_symbol("GYENUSD") == "GYEN-USD"
    end

    test "canonical to native" do
      assert SymbolFormat.to_exchange_symbol("BTC-USDT") == "BTCUSDT"
      assert SymbolFormat.to_exchange_symbol("ETH-USDC") == "ETHUSDC"
      assert SymbolFormat.to_exchange_symbol("ETH-BTC") == "ETHBTC"
      assert SymbolFormat.to_exchange_symbol("GALA-USD") == "GALAUSD"
    end

    test "case is normalised in both directions" do
      assert SymbolFormat.to_canonical_symbol("btcusd") == "BTC-USD"
      assert SymbolFormat.to_exchange_symbol("btc-usd") == "BTCUSD"
    end

    # A symbol that is not a pair comes back as it was and is never decorated, so a ticker
    # or a bare quote is not turned into a pair nobody listed.
    test "a symbol with no base, or no quote, is not split or decorated" do
      assert SymbolFormat.to_canonical_symbol("AAPL") == "AAPL"
      assert SymbolFormat.to_canonical_symbol("USD") == "USD"
      assert SymbolFormat.to_exchange_symbol("AAPL") == "AAPL"
      assert SymbolFormat.to_exchange_symbol("-USD") == "-USD"
    end

    # The hazard `Rest` guards by splitting only crypto pairs: this module cuts at ANY
    # trailing quote, so an equity ticker ending in one is a pair to it. Pinned so nobody
    # routes a stock ticker through it believing it is safe.
    test "an equity ticker ending in a quote currency IS split, which is why Rest never asks" do
      assert SymbolFormat.to_canonical_symbol("GBTC") == "G-BTC"
    end

    test "a non-binary is refused rather than converted" do
      assert_raise FunctionClauseError, fn -> SymbolFormat.to_canonical_symbol(nil) end
      assert_raise FunctionClauseError, fn -> SymbolFormat.to_exchange_symbol(:btc_usd) end
    end
  end
end
