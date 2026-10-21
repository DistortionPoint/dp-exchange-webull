defmodule DpExchange.Webull.TickArRestDocsATest do
  @moduledoc """
  Tick AR lens V on `Rest` (lines 1-4200): the error tuples its `@doc`s now name are the
  ones the code returns, and the one code defect the audit found is closed.

  The defect: `update_watchlist/3` wrote `name:` to the wire through `to_string/1`, so a
  number went out as its text and a map raised in the caller. It is now
  `{:error, {:invalid_watchlist_name, name}}` before a request, in `Fake` too.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Config
  alias DpExchange.Webull.{Fake, Rest}

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
  @earlier ~U[2026-01-01 00:00:00Z]
  @later ~U[2026-02-01 00:00:00Z]

  defp reporting(body, test_pid) do
    fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:ar_request, conn.request_path, raw})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end
  end

  defp served(body), do: [plug: reporting(body, self()), retry_attempts: 0]

  describe "update_watchlist/3 name" do
    test "a name that is not text is refused before any request, in Rest and in Fake" do
      opts = served(%{"success" => true})

      for bad <- [123, %{"a" => 1}, :atom, ["x"]] do
        assert {:error, {:invalid_watchlist_name, ^bad}} =
                 Rest.update_watchlist("wl-1", @credentials, [name: bad] ++ opts)

        assert {:error, {:invalid_watchlist_name, ^bad}} =
                 Fake.update_watchlist("wl-1", name: bad)
      end

      refute_receive {:ar_request, _path, _body}, 500
    end

    test "a text name is sent as written (the negative above can fail)" do
      opts = served(%{"success" => true})

      assert {:ok, %{id: "wl-1", name: "Oil"}} =
               Rest.update_watchlist("wl-1", @credentials, [name: "Oil"] ++ opts)

      assert_receive {:ar_request, "/market-data/watchlists/update", raw}, 5_000
      assert Jason.decode!(raw) == %{"watchlist_id" => "wl-1", "name" => "Oil"}
    end

    test "validate_watchlist_rename/1: absent and nil change nothing, text passes" do
      assert Rest.validate_watchlist_rename([]) == :ok
      assert Rest.validate_watchlist_rename(name: nil) == :ok
      assert Rest.validate_watchlist_rename(name: "x") == :ok
      assert Rest.validate_watchlist_rename(name: 5) == {:error, {:invalid_watchlist_name, 5}}
    end
  end

  describe "list_instruments/2 refuses an unreadable row (the doc said it dropped it)" do
    test "a row whose symbol does not end in its currency refuses the whole listing" do
      body = [
        %{"symbol" => "BTCUSD", "currency" => "USD", "status" => "OC"},
        %{"symbol" => "FOO", "currency" => "USD", "status" => "OC"}
      ]

      assert {:error, :unexpected_response_shape} ==
               Rest.list_instruments(@credentials, served(body))

      assert_receive {:ar_request, "/trading/instruments/crypto/profiles/list", _raw}, 5_000
    end

    test "a readable listing is returned whole" do
      body = [%{"symbol" => "BTCUSD", "currency" => "USD", "status" => "OC"}]

      assert {:ok, [%{base: "BTC", quote: "USD", status: :tradable}]} =
               Rest.list_instruments(@credentials, served(body))
    end
  end

  describe "get_historical_prices/5 refusals named in its doc" do
    test "options, futures and event bars refuse a range" do
      kinds = [{"US_OPTION", :option}, {"US_FUTURES", :future}, {"US_EVENT", :event}]

      for {category, kind} <- kinds do
        opts = [category: category]
        range = [start: @earlier]

        assert {:error, {:unsupported_bar_range, ^kind}} =
                 Rest.get_historical_prices("SYM", "1m", range, @credentials, opts)
      end
    end

    test "an inverted range, a bad limit, a width and a category the path does not serve" do
      inverted = [start: @later, end: @earlier]

      assert {:error, {:invalid_range, ^inverted}} =
               Rest.get_historical_prices("BTC-USD", "1m", inverted, @credentials, [])

      assert {:error, {:invalid_option, :limit, 1_201}} =
               Rest.get_historical_prices("BTC-USD", "1m", [], @credentials, limit: 1_201)

      assert {:error, {:unsupported_timeframe, "1w"}} =
               Rest.get_historical_prices("BTC-USD", "1w", [], @credentials, [])

      assert {:error, {:unsupported_timeframe, "1w"}} =
               Rest.get_historical_prices("SYM", "1w", [], @credentials, category: "US_EVENT")

      assert {:error, {:unsupported_book_category, "FOO"}} =
               Rest.get_historical_prices("SYM", "1d", [], @credentials, category: "FOO")
    end

    test "the stock one-minute page maximum is 1650 and every other width is 1200" do
      assert Rest.validate_bars_request("1m", [], category: "US_STOCK", limit: 1_650) == :ok

      assert {:error, {:invalid_option, :limit, 1_651}} =
               Rest.validate_bars_request("1m", [], category: "US_STOCK", limit: 1_651)

      assert Rest.validate_bars_request("5m", [], category: "US_STOCK", limit: 1_200) == :ok

      assert {:error, {:invalid_option, :limit, 1_201}} =
               Rest.validate_bars_request("5m", [], category: "US_STOCK", limit: 1_201)
    end
  end

  describe "order book, footprint and tape refusals named in their docs" do
    test "get_order_book/3 and validate_book_request/2" do
      assert {:error, {:unsupported_option, :limit}} =
               Rest.get_order_book("AAPL", @credentials, limit: 5)

      assert {:error, {:invalid_option, :depth, 11}} =
               Rest.get_order_book("ESZ5", @credentials, category: "US_FUTURES", depth: 11)

      assert {:error, {:invalid_option, :depth, 0}} =
               Rest.get_order_book("AAPL", @credentials, depth: 0)

      assert {:error, {:unsupported_book_category, "US_CRYPTO"}} =
               Rest.get_order_book("BTCUSD", @credentials, category: "US_CRYPTO")

      assert Rest.validate_book_request("US_FUTURES", depth: 10) == :ok
      assert Rest.validate_book_request("US_STOCK", depth: 50) == :ok
    end

    test "get_volume_profile/4 and validate_footprint_request/2 agree" do
      cases = [
        {[category: "US_ETF"], {:unsupported_footprint_category, "US_ETF"}},
        {[session: "OVN"], {:unsupported_session, "OVN"}},
        {[count: 1_201], {:limit_out_of_range, 1_201, max: 1_200}}
      ]

      for {opts, reason} <- cases do
        assert {:error, ^reason} = Rest.get_volume_profile("AAPL", "1m", @credentials, opts)
        assert {:error, ^reason} = Rest.validate_footprint_request("1m", opts)
      end

      assert Rest.validate_footprint_request("1m", count: 1_200, session: "RTH") == :ok
    end

    test "get_trades/3 and validate_trades_request/1 agree" do
      cases = [
        {[since: 1], {:unsupported_option, :since}},
        {[limit: 1_001], {:invalid_option, :limit, 1_001}},
        {[sessions: ["RTH", "RTH"]], {:invalid_option, :sessions, ["RTH", "RTH"]}},
        {[category: "US_FUTURES", limit: 1_201], {:invalid_option, :limit, 1_201}}
      ]

      for {opts, reason} <- cases do
        assert {:error, ^reason} = Rest.get_trades("AAPL", @credentials, opts)
        assert {:error, ^reason} = Rest.validate_trades_request(opts)
      end

      assert Rest.validate_trades_request(category: "US_FUTURES", limit: 1_200) == :ok
      assert Rest.validate_trades_request(limit: 1_000) == :ok
    end

    test "get_auction_imbalance/3" do
      assert {:error, :auction_required} = Rest.get_auction_imbalance("AAPL", @credentials, [])

      assert {:error, {:unsupported_auction, :midday}} =
               Rest.get_auction_imbalance("AAPL", @credentials, auction: :midday)

      bad_history = [auction: :opening, history: "yes"]

      assert {:error, {:invalid_option, :history, "yes"}} =
               Rest.get_auction_imbalance("AAPL", @credentials, bad_history)
    end
  end

  describe "cash-activity refusals named in the get_transfers/2 doc" do
    test "cross-year, inverted, unreadable bound and bad activity types" do
      base = [account_id: "acct-1"]
      across = [start: ~U[2025-12-31 23:00:00Z], end: ~U[2026-01-01 01:00:00Z]]
      inverted = [start: @later, end: @earlier]

      assert {:error, {:cross_year_range, 2025, 2026}} =
               Rest.get_transfers(@credentials, base ++ across)

      assert {:error, {:invalid_option, :start, @later}} =
               Rest.get_transfers(@credentials, base ++ inverted)

      assert {:error, {:invalid_time, :start, "2026-01-01"}} =
               Rest.get_transfers(@credentials, base ++ [start: "2026-01-01"])

      assert {:error, {:invalid_activity_types, [1]}} =
               Rest.get_transactions(@credentials, base ++ [activity_types: [1]])

      assert Rest.validate_activity_range(start: @earlier, end: @later) == :ok
    end
  end

  describe "replace validation named in the validate_replace/3 doc" do
    @replace_opts [instrument_type: :equity, order_type: :limit]

    test "an unplaceable instrument, an outside field and a bad number" do
      bogus = [instrument_type: :bogus, order_type: :limit]

      assert {:error, {:unsupported_instrument_type, :bogus}} =
               Rest.validate_replace("id-1", %{quantity: 1}, bogus)

      assert {:error, {:unsupported_order_edit, :limit, [:stop_price]}} =
               Rest.validate_replace("id-1", %{stop_price: 1}, @replace_opts)

      assert {:error, {:invalid_price, nil}} =
               Rest.validate_replace("id-1", %{price: nil}, @replace_opts)

      assert {:error, {:invalid_quantity, 0}} =
               Rest.validate_replace("id-1", %{quantity: 0}, @replace_opts)

      assert Rest.validate_replace("id-1", %{quantity: 1}, @replace_opts) == :ok
    end

    test "an event contract quantity takes two places; a futures type change one way" do
      event = [instrument_type: :event, order_type: :limit]
      futures = [instrument_type: :futures, order_type: :limit]
      three_places = %{quantity: Decimal.new("1.234")}

      assert {:error, {:invalid_quantity, _quantity}} =
               Rest.validate_replace("id-1", three_places, event)

      assert {:error, {:unsupported_order_type_change, :limit, :stop}} =
               Rest.validate_replace("id-1", %{order_type: :stop}, futures)

      assert Rest.validate_replace("id-1", %{order_type: :market}, futures) == :ok
    end
  end

  describe "token and OAuth refusals named in their docs" do
    test "check_token/3 refuses a token that is not text without echoing it" do
      assert {:error, {:invalid_field, :token}} = Rest.check_token(123, @credentials, [])
    end

    test "oauth_token/3 refusals are plain errors decided before sending" do
      assert {:error, {:invalid_field, :client_id}} = Rest.oauth_token(1, "s", code: "c")
      assert {:error, {:invalid_field, :client_secret}} = Rest.oauth_token("i", nil, code: "c")

      assert {:error, :code_and_refresh_token_are_exclusive} =
               Rest.oauth_token("i", "s", code: "c", refresh_token: "r")

      assert {:error, :code_or_refresh_token_required} = Rest.oauth_token("i", "s", [])

      assert {:error, {:insecure_url, :webull}} =
               Rest.oauth_token("i", "s", code: "c", oauth_url: "http://example.com")
    end

    test "a 2xx with no access_token is :write_unconfirmed carrying the missing field" do
      opts = [code: "c"] ++ served(%{"token_type" => "Bearer"})

      assert {:error, {:write_unconfirmed, nil, {:missing_required_field, :access_token}}} =
               Rest.oauth_token("i", "s", opts)

      assert_receive {:ar_request, "/oauth2/tokens/create", _raw}, 5_000
    end
  end

  describe "watchlist refusals named in their docs" do
    test "get_watchlist/3, update_watchlist/3 and delete_watchlist/3 refuse an unusable id" do
      assert {:error, {:invalid_watchlist_id, nil}} = Rest.get_watchlist(nil, @credentials, [])
      assert {:error, {:invalid_watchlist_id, ""}} = Rest.update_watchlist("", @credentials, [])
      assert {:error, {:invalid_watchlist_id, 5}} = Rest.delete_watchlist(5, @credentials, [])
    end

    test "create_watchlist/4 refuses a bad category or name before creating anything" do
      opts = served(%{"watchlist_id" => "wl-9"})

      assert {:error, {:invalid_category, "US_OPTION"}} =
               Rest.create_watchlist("Tech", [], @credentials, [category: "US_OPTION"] ++ opts)

      assert {:error, {:invalid_watchlist_name, 7}} =
               Rest.create_watchlist(7, [], @credentials, opts)

      refute_receive {:ar_request, _path, _body}, 500
    end

    test "update_watchlist/3 refuses membership" do
      assert {:error, :membership_not_updatable_here} =
               Rest.update_watchlist("wl-1", @credentials, symbols: ["AAPL"])
    end
  end
end
