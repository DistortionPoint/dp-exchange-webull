defmodule DpExchange.Webull.ArgumentValidationTest do
  @moduledoc """
  Arguments that cannot be used are refused locally, in one shape, before credentials and
  before any request (family conventions 1-4, 8, 10-12), by the real code and by the Fake
  alike:

  * a single-symbol read of a nil, non-text or blank symbol is `{:invalid_symbol, value}`;
  * a historical range that is not a keyword list of `DateTime` bounds is
    `{:invalid_range, range}`, and no request is made for it;
  * a streaming call refuses a bad symbol list, then a bad subscriber, in the CALLER, before
    `{:error, :feed_not_started}`;
  * `ssl_options: nil` never turns certificate verification off.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Config
  alias DpExchange.Webull
  alias DpExchange.Webull.{Credentials, Fake, Feed, Rest, Socket}

  @moduletag :capture_log

  defmodule PermissiveLimiter do
    @moduledoc false
    @behaviour DpExchange.Core.RateLimitBehaviour

    @impl true
    def acquire(_provider, _weight, _opts), do: :ok
    @impl true
    def check(_provider, _weight, _opts), do: :ok
    @impl true
    def record(_provider, _weight, _opts), do: :ok
  end

  setup do
    Config.put_override(:rate_limit_module, PermissiveLimiter)
    :ok
  end

  @credentials %{app_key: "key", app_secret: "secret"}
  @bad_symbols [nil, :btc, 5, "", "   ", ["BTC-USD"]]

  defp exploding, do: fn _conn -> raise "a refused argument must not reach the wire" end

  defp opts(extra), do: [plug: exploding(), retry_attempts: 0] ++ extra

  defp absent_feed, do: :"absent_feed_#{System.unique_integer([:positive])}"

  describe "single-symbol reads" do
    test "price and top of book refuse a bad symbol before credentials, on every category" do
      for bad <- @bad_symbols, category <- ["US_CRYPTO", "US_STOCK", "US_OPTION"] do
        expected = {:error, {:invalid_symbol, bad}}

        assert Rest.get_price(bad, %{}, category: category) == expected
        assert Rest.get_top_of_book(bad, %{}, category: category) == expected
      end

      # Default category (crypto): the case that raised `FunctionClauseError` in the mapper.
      assert Rest.get_price(nil, %{}, []) == {:error, {:invalid_symbol, nil}}
      assert Rest.get_top_of_book(:btc, %{}, []) == {:error, {:invalid_symbol, :btc}}
    end

    test "order book and trades refuse a bad symbol before credentials" do
      for bad <- @bad_symbols do
        assert Rest.get_order_book(bad, %{}, []) == {:error, {:invalid_symbol, bad}}
        assert Rest.get_trades(bad, %{}, []) == {:error, {:invalid_symbol, bad}}
      end
    end

    test "a bad symbol sends no request even with credentials" do
      for bad <- @bad_symbols do
        assert Rest.get_price(bad, @credentials, opts([])) == {:error, {:invalid_symbol, bad}}

        assert Rest.get_order_book(bad, @credentials, opts([])) ==
                 {:error, {:invalid_symbol, bad}}
      end
    end

    test "a category error still comes first" do
      assert Rest.get_price(nil, %{}, category: "US_NOPE") ==
               {:error, {:unsupported_snapshot_category, "US_NOPE"}}
    end

    test "bars refuse a bad symbol on every category, before credentials" do
      for bad <- @bad_symbols,
          category <- ["US_CRYPTO", "US_STOCK", "US_OPTION", "US_FUTURES", "US_EVENT"] do
        assert Rest.get_historical_prices(bad, "1d", [], %{}, category: category) ==
                 {:error, {:invalid_symbol, bad}}
      end
    end

    test "the Fake answers each of them identically, in the same order" do
      bypass = [credentials: @credentials]

      for bad <- @bad_symbols do
        expected = {:error, {:invalid_symbol, bad}}

        # Without credentials too: the symbol is decided before the credential check.
        assert Fake.get_price(bad, []) == expected
        assert Fake.get_price(bad, bypass) == expected
        assert Fake.get_top_of_book(bad, []) == expected
        assert Fake.get_order_book(bad, []) == expected
        assert Fake.get_trades(bad, []) == expected
        assert Fake.get_historical_prices(bad, "1d", [], []) == expected
      end
    end

    test "a well-formed symbol with no credentials is still the credential error" do
      assert Fake.get_price("BTC-USD", []) == {:error, {:missing_credentials, :webull}}
    end
  end

  describe "every other single-symbol read" do
    @every_bad [nil, :atom, 42, "", "  "]

    defp rest_reads(bad, creds, o) do
      [
        Rest.get_volume_profile(bad, "1m", creds, o),
        Rest.get_auction_imbalance(bad, creds, [auction: :opening] ++ o),
        Rest.get_fundamental(:filings, bad, creds, o),
        Rest.get_financials(bad, :income, creds, o),
        Rest.get_financials(bad, :balance_sheet, creds, o),
        Rest.get_filings(bad, creds, o),
        Rest.get_event_trades(bad, creds, o),
        Rest.get_event_order_book(bad, creds, o),
        Rest.quantization(bad, creds, o),
        Rest.get_option_chain(bad, creds, o),
        Rest.get_option_expirations(bad, creds, o),
        Rest.get_stock_bars(bad, "1d", [], creds, o),
        Rest.get_trades(bad, creds, o),
        Rest.get_order_book(bad, creds, o)
      ]
    end

    test "each refuses a bad symbol with no request, with credentials" do
      for bad <- @every_bad, result <- rest_reads(bad, @credentials, opts([])) do
        assert result == {:error, {:invalid_symbol, bad}}
      end
    end

    test "each refuses it before credentials too" do
      for bad <- @every_bad, result <- rest_reads(bad, %{}, []) do
        assert result == {:error, {:invalid_symbol, bad}}
      end
    end

    test "get_stock_bars/5 refuses a bad range itself, with no request" do
      assert Rest.get_stock_bars("AAPL", "1d", :nope, @credentials, opts([])) ==
               {:error, {:invalid_range, :nope}}
    end

    test "the facade and the Fake answer the same for the reads the Fake models" do
      for bad <- @every_bad do
        expected = {:error, {:invalid_symbol, bad}}

        assert Webull.get_volume_profile(bad, "1m", []) == expected
        assert Webull.get_filings(bad, []) == expected
        assert Webull.quantization(bad, []) == expected
        assert Webull.get_event_trades(bad, []) == expected
        assert Webull.get_event_order_book(bad, []) == expected

        assert Fake.get_volume_profile(bad, "1m", []) == expected
        assert Fake.get_auction_imbalance(bad, auction: :opening) == expected
        assert Fake.get_financials(bad, :income, []) == expected
        assert Fake.get_filings(bad, []) == expected
        assert Fake.quantization(bad, []) == expected
        assert Fake.get_option_chain(bad, []) == expected
        assert Fake.get_option_expirations(bad, []) == expected
      end
    end
  end

  describe "get_prices/3" do
    test "a symbol list that is not a proper list is refused, not raised on" do
      for bad <- [nil, "BTC-USD", :x, ["BTC-USD" | :tail]] do
        assert Rest.get_prices(bad, @credentials, opts([])) ==
                 {:error, {:invalid_symbols, bad}}

        assert Fake.get_prices(bad, credentials: @credentials) ==
                 {:error, {:invalid_symbols, bad}}
      end
    end

    test "a bad member costs only itself, without a request of its own" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!([%{"symbol" => "BTCUSD", "price" => "100.5"}]))
      end

      assert {:ok, results} =
               Rest.get_prices(["BTC-USD", nil, "", "  "], @credentials,
                 plug: plug,
                 retry_attempts: 0
               )

      assert %{"BTC-USD" => {:ok, %{price: price}}} = results
      assert Decimal.equal?(price, "100.5")
      assert results[nil] == {:error, {:invalid_symbol, nil}}
      assert results[""] == {:error, {:invalid_symbol, ""}}
      assert results["  "] == {:error, {:invalid_symbol, "  "}}
    end

    test "only bad members: nothing is sent" do
      assert {:ok, %{nil => {:error, {:invalid_symbol, nil}}}} =
               Rest.get_prices([nil], @credentials, opts([]))
    end
  end

  describe "historical range" do
    @bad_ranges [
      :nope,
      [start: "2026-01-01"],
      [end: 5],
      [start: ~D[2026-01-01]],
      [start: ~N[2026-01-01 00:00:00]],
      [{:start, nil} | :tail],
      [:start]
    ]

    test "a range that is not DateTime bounds is refused before any request, on every path" do
      for range <- @bad_ranges,
          category <- ["US_CRYPTO", "US_STOCK", "US_OPTION", "US_FUTURES", "US_EVENT"] do
        assert Rest.get_historical_prices(
                 "BTC-USD",
                 "1d",
                 range,
                 @credentials,
                 opts(category: category)
               ) == {:error, {:invalid_range, range}}
      end
    end

    test "the range is refused before credentials as well, and the Fake agrees" do
      for range <- @bad_ranges do
        assert Rest.get_historical_prices("BTC-USD", "1d", range, %{}, []) ==
                 {:error, {:invalid_range, range}}

        assert Fake.get_historical_prices("BTC-USD", "1d", range, []) ==
                 {:error, {:invalid_range, range}}
      end
    end

    test "DateTime bounds and nil bounds are accepted" do
      assert Rest.validate_range([]) == :ok
      assert Rest.validate_range(start: nil, end: nil) == :ok
      assert Rest.validate_range(start: ~U[2026-01-01 00:00:00Z]) == :ok
      both = [start: ~U[2026-01-01 00:00:00Z], end: ~U[2026-01-02 00:00:00Z]]
      assert Rest.validate_range(both) == :ok
    end
  end

  describe "streaming calls refuse bad arguments in the caller" do
    test "a bad symbol list is refused whether or not a feed runs" do
      feed = absent_feed()

      for bad <- [nil, "BTC-USD", [nil], [""], [" "], ["BTC-USD", "\t"], ["BTC-USD" | :tail]] do
        assert {:error, {:invalid_symbols, _offenders}} = Webull.subscribe(bad, feed: feed)
        assert {:error, {:invalid_symbols, _offenders}} = Webull.unsubscribe(bad, feed: feed)
        assert {:error, {:invalid_symbols, _offenders}} = Webull.update_symbols(bad, feed: feed)
        assert {:error, {:invalid_symbols, _offenders}} = Fake.subscribe(bad)
        assert {:error, {:invalid_symbols, _offenders}} = Fake.unsubscribe(bad)
        assert {:error, {:invalid_symbols, _offenders}} = Fake.update_symbols(bad)
      end

      assert Webull.subscribe([" "], feed: feed) == {:error, {:invalid_symbols, [" "]}}
    end

    test "a well-formed call with no feed is still :feed_not_started (unsubscribe: :ok)" do
      feed = absent_feed()

      assert Webull.subscribe(["BTC-USD"], feed: feed) == {:error, :feed_not_started}
      assert Webull.update_symbols(["BTC-USD"], feed: feed) == {:error, :feed_not_started}
      assert Webull.unsubscribe(["BTC-USD"], feed: feed) == :ok
    end

    test "a bad subscriber is refused ahead of :feed_not_started; true and false included" do
      feed = absent_feed()

      for bad <- [true, false, "nobody", 42, {:global, :x}] do
        assert Webull.subscribe(["BTC-USD"], feed: feed, to: bad) ==
                 {:error, {:invalid_subscriber, bad}}

        assert Webull.subscribe_notices(feed: feed, to: bad) ==
                 {:error, {:invalid_subscriber, bad}}

        assert Fake.subscribe(["BTC-USD"], to: bad) == {:error, {:invalid_subscriber, bad}}
        assert Fake.subscribe_notices(to: bad) == {:error, {:invalid_subscriber, bad}}
        assert Feed.check_subscriber(bad) == {:error, {:invalid_subscriber, bad}}
      end

      assert Feed.check_subscriber(self()) == :ok
      assert Feed.check_subscriber(:a_registered_name) == :ok
    end

    test "symbols are checked before the subscriber" do
      assert Webull.subscribe([""], feed: absent_feed(), to: true) ==
               {:error, {:invalid_symbols, [""]}}
    end

    test "the Feed refuses a whitespace-only symbol itself, for direct callers" do
      name = :"validation_feed_#{System.unique_integer([:positive])}"
      {:ok, feed} = Feed.start_link(name: name)

      assert Feed.subscribe(feed, [" "], to: self()) == {:error, {:invalid_symbols, [" "]}}
      assert Feed.update_symbols(feed, ["\n"], []) == {:error, {:invalid_symbols, ["\n"]}}
      assert :sys.get_state(feed).wanted == MapSet.new()
    end

    test "the default-options arities refuse a bad symbol list the same way" do
      assert Webull.subscribe([" "]) == {:error, {:invalid_symbols, [" "]}}
      assert Webull.unsubscribe([" "]) == {:error, {:invalid_symbols, [" "]}}
      assert Webull.update_symbols([" "]) == {:error, {:invalid_symbols, [" "]}}
    end
  end

  describe "Feed.start_link/1 wraps credentials" do
    test "the credentials in the process are the redacting struct" do
      name = :"wrapped_feed_#{System.unique_integer([:positive])}"
      # A secret that differs from every field name, so a leak cannot hide behind `app_secret`.
      leaky = %{app_key: "key-zq9", app_secret: "value-zq9-hunter2"}
      {:ok, feed} = Feed.start_link(name: name, credentials: leaky)

      state = :sys.get_state(feed)
      assert %Credentials{} = state.resubscribe_opts[:credentials]
      refute inspect(state.resubscribe_opts) =~ "value-zq9-hunter2"
    end
  end

  describe "Socket TLS" do
    test "the defaults verify the peer and the hostname" do
      ssl = Socket.connection_opts([])[:ssl_options]

      assert ssl[:verify] == :verify_peer
      assert is_list(ssl[:cacerts])
      assert Keyword.has_key?(ssl, :customize_hostname_check)
    end

    test "ssl_options: nil and [] do not turn verification off" do
      for none <- [nil, [], :none, [:not_a_keyword_list]] do
        ssl = Socket.connection_opts(ssl_options: none)[:ssl_options]

        assert ssl[:verify] == :verify_peer
        assert Keyword.has_key?(ssl, :cacerts)
      end
    end

    test "a caller override is merged over the verified defaults" do
      custom = [{:Certificate, <<1, 2, 3>>, :not_encrypted}]
      ssl = Socket.connection_opts(ssl_options: [cacerts: custom])[:ssl_options]

      assert ssl[:cacerts] == custom
      assert ssl[:verify] == :verify_peer
      assert Keyword.has_key?(ssl, :customize_hostname_check)
    end
  end
end
