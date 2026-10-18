defmodule DpExchange.Webull.UnknownOptionTest do
  @moduledoc """
  Tick AJ follow-up: a facade function given an option it does not read answers
  `{:error, {:unknown_option, key}}` instead of ignoring it, and a non-keyword `opts` is
  `{:error, {:invalid_options, opts}}`. Both `DpExchange.Webull` and `DpExchange.Webull.Fake`,
  with nothing sent and no injected outcome consulted.

  One table drives it: every function in `DpExchange.Webull.Options`' table is called on the
  facade and on the Fake with valid positional arguments and a stray key.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.{FakeInjection, Venue}
  alias DpExchange.Webull
  alias DpExchange.Webull.{Fake, Options}

  @credentials %{app_key: "k", app_secret: "s"}
  @order_id "5f1e9c0a7b2d4e68a3c4d5e6f7081920"
  @injected {:error, :injected}
  @stray :definitely_not_an_option
  @plain_reads ~w(coverage wanted coverage_by_kind streaming? live?)a

  # Every function the options table holds that answers with an error channel.
  @names ~w(
    get_price get_prices get_top_of_book get_historical_prices get_symbols list_instruments
    get_order_book get_trades get_volume_profile get_auction_imbalance quantization
    get_accounts get_fees get_balances get_positions get_orders get_order cancel_order
    place_order place_orders preview_order replace_order get_transfers get_transactions
    subscribe unsubscribe update_symbols subscribe_notices
    get_option_chain get_option_expirations list_futures_contracts list_futures_product_classes
    list_event_categories list_event_series list_event_events list_event_markets
    get_event_trades get_event_order_book
    list_watchlists get_watchlist create_watchlist update_watchlist delete_watchlist
    add_watchlist_instruments remove_watchlist_instruments sort_watchlist_instruments
    get_financials get_corporate_events get_filings get_news get_screener get_fundamental
    create_token check_token oauth_token
  )a

  defp equity_request do
    %{
      instrument_type: :equity,
      symbol: "AAPL",
      side: :buy,
      quantity: Decimal.new("10"),
      price: Decimal.new("190"),
      order_type: :limit,
      time_in_force: :day
    }
  end

  defp crypto_request do
    %{
      symbol: "BTC-USD",
      side: :buy,
      quantity: Decimal.new("0.5"),
      price: Decimal.new("40000"),
      order_type: :limit,
      time_in_force: :gtc
    }
  end

  defp batch_entry do
    Map.put(equity_request(), :support_trading_session, :core)
  end

  # A call of each function with arguments that pass its positional checks, so the only thing
  # wrong with it is `opts`. `m` is the module under test: the facade or the Fake.
  defp call(:get_price, m, o), do: m.get_price("BTC-USD", o)
  defp call(:get_prices, m, o), do: m.get_prices(["BTC-USD"], o)
  defp call(:get_top_of_book, m, o), do: m.get_top_of_book("BTC-USD", o)
  defp call(:get_historical_prices, m, o), do: m.get_historical_prices("BTC-USD", "1m", [], o)
  defp call(:get_symbols, m, o), do: m.get_symbols(o)
  defp call(:list_instruments, m, o), do: m.list_instruments(o)
  defp call(:get_order_book, m, o), do: m.get_order_book("AAPL", o)
  defp call(:get_trades, m, o), do: m.get_trades("AAPL", o)
  defp call(:get_volume_profile, m, o), do: m.get_volume_profile("AAPL", "5m", o)
  defp call(:get_auction_imbalance, m, o), do: m.get_auction_imbalance("AAPL", o)
  defp call(:quantization, m, o), do: m.quantization("BTC-USD", o)
  defp call(:get_accounts, m, o), do: m.get_accounts(@credentials, o)
  defp call(:get_fees, m, o), do: m.get_fees(@credentials, o)
  defp call(:get_balances, m, o), do: m.get_balances(@credentials, o)
  defp call(:get_positions, m, o), do: m.get_positions(o)
  defp call(:get_orders, m, o), do: m.get_orders(@credentials, o)
  defp call(:get_order, m, o), do: m.get_order(@credentials, @order_id, o)
  defp call(:cancel_order, m, o), do: m.cancel_order(@credentials, @order_id, o)
  defp call(:place_order, m, o), do: m.place_order(@credentials, crypto_request(), o)
  defp call(:place_orders, m, o), do: m.place_orders(@credentials, [batch_entry()], o)
  defp call(:preview_order, m, o), do: m.preview_order(@credentials, equity_request(), o)

  defp call(:replace_order, m, o),
    do: m.replace_order(@credentials, @order_id, %{price: Decimal.new("1")}, o)

  defp call(:get_transfers, m, o), do: m.get_transfers(@credentials, o)
  defp call(:get_transactions, m, o), do: m.get_transactions(@credentials, o)
  defp call(:subscribe, m, o), do: m.subscribe(["BTC-USD"], o)
  defp call(:unsubscribe, m, o), do: m.unsubscribe(["BTC-USD"], o)
  defp call(:update_symbols, m, o), do: m.update_symbols(["BTC-USD"], o)
  defp call(:subscribe_notices, m, o), do: m.subscribe_notices(o)
  defp call(:get_option_chain, m, o), do: m.get_option_chain("AAPL", o)
  defp call(:get_option_expirations, m, o), do: m.get_option_expirations("AAPL", o)
  defp call(:list_futures_contracts, m, o), do: m.list_futures_contracts(o)
  defp call(:list_futures_product_classes, m, o), do: m.list_futures_product_classes(o)
  defp call(:list_event_categories, m, o), do: m.list_event_categories(o)
  defp call(:list_event_series, m, o), do: m.list_event_series(o)
  defp call(:list_event_events, m, o), do: m.list_event_events(o)
  defp call(:list_event_markets, m, o), do: m.list_event_markets(o)
  defp call(:get_event_trades, m, o), do: m.get_event_trades("KXGDP-26-T3", o)
  defp call(:get_event_order_book, m, o), do: m.get_event_order_book("KXGDP-26-T3", o)
  defp call(:list_watchlists, m, o), do: m.list_watchlists(o)
  defp call(:get_watchlist, m, o), do: m.get_watchlist("wl-1", o)
  defp call(:create_watchlist, m, o), do: m.create_watchlist("Tech", ["AAPL"], o)
  defp call(:update_watchlist, m, o), do: m.update_watchlist("wl-1", o)
  defp call(:delete_watchlist, m, o), do: m.delete_watchlist("wl-1", o)
  defp call(:add_watchlist_instruments, m, o), do: m.add_watchlist_instruments("wl-1", ["A"], o)

  defp call(:remove_watchlist_instruments, m, o),
    do: m.remove_watchlist_instruments("wl-1", ["A"], o)

  defp call(:sort_watchlist_instruments, m, o), do: m.sort_watchlist_instruments("wl-1", o)
  defp call(:get_financials, m, o), do: m.get_financials("AAPL", :income, o)
  defp call(:get_corporate_events, m, o), do: m.get_corporate_events(o)
  defp call(:get_filings, m, o), do: m.get_filings("AAPL", o)
  defp call(:get_news, m, o), do: m.get_news(o)
  defp call(:get_screener, m, o), do: m.get_screener("top_actives", o)
  defp call(:get_fundamental, m, o), do: m.get_fundamental(:company_profile, "AAPL", o)
  defp call(:create_token, m, o), do: m.create_token(o)
  defp call(:check_token, m, o), do: m.check_token("t", o)
  defp call(:oauth_token, m, o), do: m.oauth_token("id", "secret", o)

  # Every key here is one the facade accepts for any function, so the stray one is the only
  # thing wrong. The plug reports a request instead of answering it: a test that sees one has
  # found a call that went to the wire before its options were checked.
  defp transport_opts do
    me = self()

    [
      credentials: @credentials,
      plug: fn conn ->
        send(me, {:request, conn.request_path})
        conn
      end,
      retry_attempts: 0
    ]
  end

  describe "the table" do
    test "has a row for every function this test calls, and the five plain reads" do
      for name <- @names ++ @plain_reads do
        assert is_list(Options.own_keys(name)), "#{name} has no row"
      end
    end

    test "names functions that exist on the facade and on the Fake" do
      for module <- [Webull, Fake], name <- @names ++ @plain_reads do
        assert Enum.any?(module.__info__(:functions), fn {fun, _arity} -> fun == name end),
               "#{inspect(module)} has no #{name}"
      end
    end

    test "every key it names is accepted, even holding nil" do
      for name <- @names ++ @plain_reads do
        own = Enum.map(Options.own_keys(name), &{&1, nil})
        assert :ok == Options.check(name, own), "#{name} refuses one of its own keys"
      end
    end
  end

  describe "the facade" do
    test "every function refuses a stray key, and nothing is sent" do
      for name <- @names do
        result = call(name, Webull, transport_opts() ++ [{@stray, true}])

        assert result == {:error, {:unknown_option, @stray}},
               "#{name} answered #{inspect(result)} for a stray key"
      end

      # One window for all of them: a request from any call above is already in the mailbox.
      refute_receive {:request, _path}, 500
    end

    test "every function refuses a non-keyword opts" do
      for name <- @names do
        result = call(name, Webull, [:oops])

        assert result == {:error, {:invalid_options, [:oops]}},
               "#{name} answered #{inspect(result)} for a non-keyword opts"
      end
    end
  end

  describe "the fake" do
    test "every function refuses a stray key without consulting an injected outcome" do
      FakeInjection.fail_always(:webull, @injected)

      for name <- @names do
        result = call(name, Fake, transport_opts() ++ [{@stray, true}])

        assert result == {:error, {:unknown_option, @stray}},
               "#{name} answered #{inspect(result)} for a stray key"
      end

      # Still queued: nothing above reached `FakeInjection`.
      assert Fake.get_symbols(credentials: @credentials) == @injected
    end

    test "every function refuses a non-keyword opts without consulting an injected outcome" do
      FakeInjection.fail_always(:webull, @injected)

      for name <- @names do
        result = call(name, Fake, [:oops])

        assert result == {:error, {:invalid_options, [:oops]}},
               "#{name} answered #{inspect(result)} for a non-keyword opts"
      end
    end
  end

  describe "shared transport keys that no call reads" do
    @no_environment ~w(get_fees coverage wanted coverage_by_kind subscribe_notices)a

    test "base_url is refused by every function, on the facade and the Fake" do
      for module <- [Webull, Fake], name <- @names do
        result = call(name, module, transport_opts() ++ [base_url: "http://localhost:1"])

        assert result == {:error, {:unknown_option, :base_url}},
               "#{inspect(module)}.#{name} answered #{inspect(result)} for base_url"
      end

      refute_receive {:request, _path}, 500
    end

    test "base_url is refused by the plain reads, which raise" do
      for name <- @plain_reads do
        assert_raise ArgumentError, fn -> Options.check!(name, base_url: "http://x") end
      end
    end

    test "environment is refused where nothing reads it and accepted where something does" do
      for name <- @no_environment do
        assert {:error, {:unknown_option, :environment}} =
                 Options.check(name, environment: :uat),
               "#{name} accepted environment"
      end

      for name <- [:get_symbols, :subscribe, :streaming?, :live?, :oauth_token, :create_token] do
        assert :ok == Options.check(name, environment: :uat), "#{name} refused environment"
      end
    end
  end

  describe "a misspelt key, as a caller would type it" do
    test "limt: on a book and sinse: on a tape are not read as limit: or since:" do
      for module <- [Webull, Fake] do
        assert {:error, {:unknown_option, :limt}} =
                 module.get_order_book("AAPL", credentials: @credentials, limt: 5)

        assert {:error, {:unknown_option, :sinse}} =
                 module.get_trades("AAPL", credentials: @credentials, sinse: 1)
      end
    end

    test "an account key on a read that has no account is refused, not ignored" do
      for module <- [Webull, Fake] do
        assert {:error, {:unknown_option, :account_id}} =
                 module.get_accounts(@credentials, account_id: "acct")
      end
    end

    test "to: names a subscriber only where there is one to name" do
      for module <- [Webull, Fake] do
        assert {:error, {:unknown_option, :to}} = module.update_symbols(["BTC-USD"], to: self())
        assert {:error, {:unknown_option, :to}} = module.unsubscribe(["BTC-USD"], to: self())
      end
    end

    test "the first stray key in the caller's order is the one named" do
      assert {:error, {:unknown_option, :zzz}} =
               Fake.get_symbols(credentials: @credentials, zzz: 1, aaa: 2)
    end
  end

  describe "the family check order" do
    test "a bad positional argument is answered before a stray option" do
      for module <- [Webull, Fake] do
        assert module.get_price(nil, [{@stray, true}]) == {:error, {:invalid_symbol, nil}}
        assert module.get_prices(:nope, [{@stray, true}]) == {:error, {:invalid_symbols, :nope}}
        assert module.subscribe(nil, [{@stray, true}]) == {:error, {:invalid_symbols, nil}}

        assert module.cancel_order(@credentials, nil, [{@stray, true}]) ==
                 {:error, {:invalid_order_id, nil}}

        assert module.get_watchlist("", [{@stray, true}]) ==
                 {:error, {:invalid_watchlist_id, ""}}

        assert module.get_fundamental(:nope, "AAPL", [{@stray, true}]) ==
                 {:error, {:unknown_fundamental, :nope}}

        assert module.get_screener("nope", [{@stray, true}]) ==
                 {:error, {:unknown_screener, "nope"}}
      end
    end

    test "a stray option is answered before the credentials are looked at" do
      for module <- [Webull, Fake] do
        assert module.get_price("BTC-USD", [{@stray, true}]) ==
                 {:error, {:unknown_option, @stray}}
      end
    end
  end

  describe "keys that depend on the endpoint" do
    test "a fundamentals kind takes only the query keys its own page documents" do
      assert :ok == Options.check_fundamental(:balance_sheet, "AAPL", type: "ANNUAL", count: 3)

      for module <- [Webull, Fake] do
        assert {:error, {:unknown_option, :count}} =
                 module.get_fundamental(:company_profile, "AAPL", count: 3)
      end
    end

    test "a screener takes its own keys, and hot_stocks takes no category" do
      assert :ok == Options.check_screener("top_actives", category: "US_STOCK", rank_type: "X")

      for module <- [Webull, Fake] do
        assert {:error, {:unknown_option, :category}} =
                 module.get_screener("hot_stocks", category: "US_STOCK")
      end
    end
  end

  describe "a function that answers :not_supported keeps doing so" do
    test "whatever it is given" do
      not_supported = Venue.not_supported()

      for module <- [Webull, Fake] do
        assert module.get_market_overview([{@stray, true}]) == not_supported
        assert module.get_market_overview([:oops]) == not_supported
        assert module.market_status([{@stray, true}]) == not_supported
        assert module.cancel_all_orders(@credentials, [{@stray, true}]) == not_supported
        assert module.get_funding("BTC-USD", [{@stray, true}]) == not_supported
      end
    end
  end

  describe "a read with no error channel raises ArgumentError" do
    for name <- [:coverage, :wanted, :coverage_by_kind, :streaming?, :live?] do
      test "#{name} on a stray key and on a non-keyword opts, facade and fake" do
        for module <- [Webull, Fake] do
          assert_raise ArgumentError, fn -> apply(module, unquote(name), [[{@stray, true}]]) end
          assert_raise ArgumentError, fn -> apply(module, unquote(name), [[:oops]]) end
        end
      end
    end

    test "and still answers for the key it reads" do
      assert Webull.coverage(feed: :no_such_feed_for_unknown_option_test) == %{}
      assert Webull.wanted(feed: :no_such_feed_for_unknown_option_test) == []
      assert Webull.coverage_by_kind(feed: :no_such_feed_for_unknown_option_test) == %{}
      assert Webull.live?(environment: :uat) == false
      assert Webull.streaming?(environment: :uat) == false
    end
  end
end
