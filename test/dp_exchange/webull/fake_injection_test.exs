defmodule DpExchange.Webull.FakeInjectionTest do
  @moduledoc """
  Proves `Fake` actually consults `Core.FakeInjection` — the shared mechanism itself is
  tested in `dp_exchange_core`; this is the wiring, per function, in this package.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.FakeInjection
  alias DpExchange.Webull.Fake

  @credentials %{app_key: "k", app_secret: "s"}
  @injected {:error, :injected}

  # Function names only are compile-time module attributes (plain strings, escapable);
  # the closures themselves live in ordinary functions below and are built at runtime —
  # a map of closures cannot be embedded in a module attribute at all.
  @whole_call_names ~w(
    get_symbols/1 get_balances/2 get_accounts/2 get_fees/2 get_transfers/2
    get_transactions/2 preview_order/3 replace_order/4 market_status/1 get_positions/1
    list_watchlists/1 get_watchlist/2 create_watchlist/3 update_watchlist/2
    delete_watchlist/2 get_corporate_events/1 get_news/1 get_screener/2 place_order/3
    cancel_order/3 get_order/3 get_orders/2
  )

  @symbol_names ~w(
    get_price/2 get_top_of_book/2 get_historical_prices/4 get_order_book/2 get_trades/2
    get_volume_profile/3 get_auction_imbalance/2 quantization/2 get_option_chain/2
    get_option_expirations/2 get_financials/3 get_filings/2
  )

  # Every function with a real success path that does NOT take a symbol as its
  # meaningfully-injectable argument. One call each, built lazily so nothing runs before
  # a test sets its own override.
  defp whole_call_calls do
    %{
      "get_symbols/1" => fn -> Fake.get_symbols(credentials: @credentials) end,
      "get_balances/2" => fn -> Fake.get_balances(@credentials, account_id: "1") end,
      "get_accounts/2" => fn -> Fake.get_accounts(@credentials, []) end,
      "get_fees/2" => fn -> Fake.get_fees(@credentials, []) end,
      "get_transfers/2" => fn -> Fake.get_transfers(@credentials, account_id: "1") end,
      "get_transactions/2" => fn -> Fake.get_transactions(@credentials, account_id: "1") end,
      "preview_order/3" => fn ->
        Fake.preview_order(@credentials, %{instrument_type: :equity}, account_id: "1")
      end,
      "replace_order/4" => fn ->
        Fake.replace_order(@credentials, "id", %{price: 1}, account_id: "1")
      end,
      "market_status/1" => fn -> Fake.market_status([]) end,
      "get_positions/1" => fn -> Fake.get_positions(account_id: "1") end,
      "list_watchlists/1" => fn -> Fake.list_watchlists([]) end,
      "get_watchlist/2" => fn -> Fake.get_watchlist("wl-1", []) end,
      "create_watchlist/3" => fn -> Fake.create_watchlist("name", ["AAPL"], []) end,
      "update_watchlist/2" => fn -> Fake.update_watchlist("wl-1", name: "x") end,
      "delete_watchlist/2" => fn -> Fake.delete_watchlist("wl-1", []) end,
      "get_corporate_events/1" => fn -> Fake.get_corporate_events(symbol: "AAPL") end,
      "get_news/1" => fn -> Fake.get_news(symbols: ["AAPL"]) end,
      "get_screener/2" => fn -> Fake.get_screener("top-actives", []) end,
      "place_order/3" => fn ->
        Fake.place_order(@credentials, %{symbol: "BTC-USD", side: :buy}, account_id: "1")
      end,
      "cancel_order/3" => fn ->
        Fake.cancel_order(@credentials, "fake-webull-order-1", account_id: "1")
      end,
      "get_order/3" => fn ->
        Fake.get_order(@credentials, "fake-webull-order-1", account_id: "1")
      end,
      "get_orders/2" => fn -> Fake.get_orders(@credentials, account_id: "1") end
    }
  end

  # Every function whose call is meaningfully targeted by symbol, paired with a symbol
  # the fake actually answers for.
  defp symbol_calls do
    %{
      "get_price/2" => fn symbol -> Fake.get_price(symbol, credentials: @credentials) end,
      "get_top_of_book/2" => fn symbol ->
        Fake.get_top_of_book(symbol, credentials: @credentials)
      end,
      "get_historical_prices/4" => fn symbol ->
        Fake.get_historical_prices(symbol, "1m", [], credentials: @credentials)
      end,
      "get_order_book/2" => fn symbol ->
        Fake.get_order_book(symbol, credentials: @credentials)
      end,
      "get_trades/2" => fn symbol -> Fake.get_trades(symbol, credentials: @credentials) end,
      "get_volume_profile/3" => fn symbol ->
        Fake.get_volume_profile(symbol, "1m", credentials: @credentials)
      end,
      "get_auction_imbalance/2" => fn symbol ->
        Fake.get_auction_imbalance(symbol, auction: :opening, credentials: @credentials)
      end,
      "quantization/2" => fn symbol -> Fake.quantization(symbol, []) end,
      "get_option_chain/2" => fn symbol -> Fake.get_option_chain(symbol, []) end,
      "get_option_expirations/2" => fn symbol -> Fake.get_option_expirations(symbol, []) end,
      "get_financials/3" => fn symbol -> Fake.get_financials(symbol, :income_statement, []) end,
      "get_filings/2" => fn symbol -> Fake.get_filings(symbol, []) end
    }
  end

  describe "whole-call injection reaches every function with a real, non-symbol success path" do
    for name <- @whole_call_names do
      test name do
        FakeInjection.fail_always(:webull, @injected)
        call = whole_call_calls()[unquote(name)]
        assert call.() == @injected
      end
    end

    test "with nothing queued, normal Fake behaviour is unaffected" do
      assert {:ok, _symbols} = Fake.get_symbols(credentials: @credentials)
    end
  end

  describe "symbol-targeted injection reaches every symbol-taking function, and only the targeted symbol" do
    for name <- @symbol_names do
      test name do
        FakeInjection.fail_always(:webull, "BTC-USD", @injected)
        call = symbol_calls()[unquote(name)]

        assert call.("BTC-USD") == @injected
        refute call.("ETH-USD") == @injected
      end
    end

    test "a whole-call queue still reaches a symbol-taking function with no symbol-specific override" do
      FakeInjection.fail_always(:webull, @injected)
      assert Fake.get_price("BTC-USD", credentials: @credentials) == @injected
    end
  end

  describe "queue_failures/2 is deterministic and pops in order" do
    test "returns queued outcomes, then resumes normal behaviour" do
      FakeInjection.queue_failures(:webull, [{:error, :first}, {:error, :second}])

      assert Fake.get_symbols(credentials: @credentials) == {:error, :first}
      assert Fake.get_symbols(credentials: @credentials) == {:error, :second}
      assert {:ok, _symbols} = Fake.get_symbols(credentials: @credentials)
    end
  end

  describe "bypass_credentials/1" do
    test "skips the venue-faithful credential refusal" do
      assert Fake.get_symbols([]) == {:refused, :missing_credentials}

      FakeInjection.bypass_credentials(:webull)

      assert {:ok, _symbols} = Fake.get_symbols([])
    end

    test "the default, without calling bypass_credentials/1, is still venue-faithful" do
      assert Fake.get_price("BTC-USD", []) == {:refused, :missing_credentials}
    end
  end

  describe "subscribe/2, unsubscribe/2 and update_symbols/2 are deliberately not wired" do
    test "fail_always/2 does not reach subscribe/2" do
      FakeInjection.fail_always(:webull, @injected)
      assert Fake.subscribe(["BTC-USD"], credentials: @credentials) == :ok
    end
  end
end
