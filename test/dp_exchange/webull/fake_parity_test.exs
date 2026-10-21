defmodule DpExchange.Webull.FakeParityTest do
  @moduledoc """
  The fake must expose every public function the facade does, and refuse what the real path
  refuses, in the same order, with the same tags. A function missing from the fake is an
  `UndefinedFunctionError` in a consumer's suite and an answer in production.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Webull
  alias DpExchange.Webull.Fake

  @opts [credentials: %{app_key: "key", app_secret: "secret"}]
  @missing {:error, {:missing_credentials, :webull}}

  describe "the public surface" do
    # Fake-only control functions, by {name, arity}, that the facade deliberately lacks.
    # Empty today: the fake's injection, coverage and reset seams all live in
    # `DpExchange.Core.Config` and the process dictionary, not in extra exports. Add a
    # name here only with a comment saying why a consumer needs it and the facade must not.
    @fake_only_control []

    test "the facade's public exports minus the fake's exports is empty" do
      facade = Webull.__info__(:functions)
      fake = Fake.__info__(:functions)

      assert facade -- fake == []
    end

    test "the fake's public exports minus the facade's, minus the named control list, is empty" do
      facade = Webull.__info__(:functions)
      fake = Fake.__info__(:functions)

      # An extra short arity on the fake (a default argument the facade lacks) is a call a
      # consumer's suite can make that fails in production with UndefinedFunctionError.
      assert Enum.sort((fake -- facade) -- @fake_only_control) == []
    end

    test "the two export sets are exactly equal, arity for arity" do
      facade = Enum.sort(Webull.__info__(:functions))
      fake = Enum.sort(Fake.__info__(:functions) -- @fake_only_control)

      # Guards the comparison against being vacuous.
      assert {:get_positions, 1} in facade
      refute {:get_positions, 0} in fake
      assert length(facade) > 100

      assert fake == facade
    end
  end

  describe "futures" do
    test "contracts need symbols or a code, before credentials" do
      assert {:error, :symbols_or_code_required} = Fake.list_futures_contracts([])
      assert {:error, :symbols_or_code_required} = Fake.list_futures_contracts(symbols: [])

      assert {:error, {:invalid_option, :status, %{}}} =
               Fake.list_futures_contracts(symbols: "ESZ5", status: %{})

      assert @missing = Fake.list_futures_contracts(symbols: "ESZ5")
    end

    test "contracts are narrowed by symbols, code and status" do
      assert {:ok, [%{"symbol" => "ESZ5"}]} =
               Fake.list_futures_contracts([symbols: ["ESZ5"]] ++ @opts)

      assert {:ok, [_one, _two]} = Fake.list_futures_contracts([code: "ES"] ++ @opts)
      assert {:ok, []} = Fake.list_futures_contracts([code: "ES", status: "NT"] ++ @opts)
    end

    test "product classes need credentials and answer the venue's two fields" do
      assert @missing = Fake.list_futures_product_classes([])

      assert {:ok, [%{"product_class_id" => _id, "product_class_name" => _name}]} =
               Fake.list_futures_product_classes(@opts)
    end
  end

  describe "event contracts" do
    test "categories need credentials" do
      assert @missing = Fake.list_event_categories([])
      assert {:ok, [%{"category_code" => _code}]} = Fake.list_event_categories(@opts)
    end

    test "series is one page whose key is nil, and rejects an unreadable option" do
      assert {:error, {:invalid_option, :category, %{}}} = Fake.list_event_series(category: %{})
      assert @missing = Fake.list_event_series([])

      assert {:ok, %{rows: [%{"symbol" => "KXGDP"}], pagination_key: nil}} =
               Fake.list_event_series(@opts)

      assert {:ok, %{rows: [], pagination_key: nil}} =
               Fake.list_event_series([category: "SPORTS"] ++ @opts)
    end

    test "events need a series symbol before anything else" do
      assert {:error, :series_symbol_required} = Fake.list_event_events([])
      assert @missing = Fake.list_event_events(series_symbol: "KXGDP")

      assert {:ok, [%{"status" => "ACTIVE"}]} =
               Fake.list_event_events([series_symbol: "KXGDP"] ++ @opts)

      assert {:ok, []} = Fake.list_event_events([series_symbol: "OTHER"] ++ @opts)

      assert {:ok, []} =
               Fake.list_event_events([series_symbol: "KXGDP", status: "INACTIVE"] ++ @opts)
    end

    test "markets keep status and tradable_status as two fields" do
      assert @missing = Fake.list_event_markets([])

      assert {:ok, %{rows: [market], pagination_key: nil}} = Fake.list_event_markets(@opts)
      assert market["status"] == "LISTING"
      assert market["tradable_status"] == "OC"

      assert {:ok, %{rows: []}} = Fake.list_event_markets([event_symbol: "NOPE"] ++ @opts)
    end

    test "the tape refuses an over-large limit and a bad symbol before credentials" do
      assert {:error, {:invalid_option, :limit, 1_201}} =
               Fake.get_event_trades("X", limit: 1_201)

      assert {:error, {:invalid_symbol, 5}} = Fake.get_event_trades(5, [])
      assert @missing = Fake.get_event_trades("KXGDP-26-T3", [])

      assert {:ok, [%{"yes_price" => _yes, "no_price" => _no, "side" => side}]} =
               Fake.get_event_trades("KXGDP-26-T3", [limit: 1] ++ @opts)

      assert side in ["yes", "no"]
    end

    test "the book has four sides and refuses a bad depth before credentials" do
      assert {:error, {:invalid_option, :depth, 0}} = Fake.get_event_order_book("X", depth: 0)
      assert @missing = Fake.get_event_order_book("KXGDP-26-T3", [])

      assert {:ok, book} = Fake.get_event_order_book("KXGDP-26-T3", @opts)
      assert book.symbol == "KXGDP-26-T3"
      assert [_level] = book.yes_bids
      assert [_level] = book.no_asks
      assert is_integer(book.quote_time)
    end
  end

  describe "watchlist membership" do
    test "symbols, then the id, then credentials" do
      assert {:error, :symbols_required} = Fake.add_watchlist_instruments("wl-1", [], [])
      assert {:error, {:invalid_symbols, [1]}} = Fake.add_watchlist_instruments("wl-1", [1], [])

      assert {:error, {:invalid_watchlist_id, ""}} =
               Fake.add_watchlist_instruments("", ["A"], [])

      assert @missing = Fake.add_watchlist_instruments("wl-1", ["MSFT"], [])
    end

    test "add and remove change what get_watchlist reads back, for a created list" do
      assert {:ok, %{id: id}} = Fake.create_watchlist("mine", ["AAPL"], @opts)

      assert {:ok, %{"success" => true}} = Fake.add_watchlist_instruments(id, ["MSFT"], @opts)
      assert {:ok, %{symbols: ["AAPL", "MSFT"]}} = Fake.get_watchlist(id, @opts)

      assert {:ok, %{"success" => true}} = Fake.remove_watchlist_instruments(id, ["AAPL"], @opts)
      assert {:ok, %{symbols: ["MSFT"]}} = Fake.get_watchlist(id, @opts)
    end

    test "an id this process does not hold is refused as not found" do
      assert {:refused, :not_found} = Fake.add_watchlist_instruments("nope", ["A"], @opts)
      assert {:refused, :not_found} = Fake.remove_watchlist_instruments("nope", ["A"], @opts)

      assert {:refused, :not_found} =
               Fake.sort_watchlist_instruments("nope", [sorts: %{"A" => 1}] ++ @opts)
    end

    test "sorting needs a map of symbol to whole-number position" do
      assert {:error, :sorts_required} = Fake.sort_watchlist_instruments("wl-1", [])
      assert {:error, :sorts_required} = Fake.sort_watchlist_instruments("wl-1", sorts: %{})

      assert {:error, {:invalid_sorts, %{"A" => 1.5}}} =
               Fake.sort_watchlist_instruments("wl-1", sorts: %{"A" => 1.5})

      assert @missing = Fake.sort_watchlist_instruments("wl-1", sorts: %{"A" => 1})

      assert {:ok, %{"success" => true}} =
               Fake.sort_watchlist_instruments("wl-1", [sorts: %{"AAPL" => 1}] ++ @opts)
    end
  end

  describe "fundamentals" do
    test "an unknown kind is refused before credentials, as on the real path" do
      assert {:error, {:unknown_fundamental, :nope}} = Fake.get_fundamental(:nope, "AAPL", [])
      assert {:error, {:invalid_symbol, 1}} = Fake.get_fundamental(:company_profile, 1, [])

      assert {:error, {:limit_out_of_range, 21, max: 20}} =
               Fake.get_fundamental(:balance_sheet, "AAPL", count: 21)

      assert @missing = Fake.get_fundamental(:company_profile, "AAPL", [])
    end

    test "a known kind answers the venue's rows, and a crypto pair is not listed" do
      assert {:ok, [%{"symbol" => "AAPL"}]} =
               Fake.get_fundamental(:company_profile, "AAPL", @opts)

      assert {:refused, :not_listed} = Fake.get_fundamental(:company_profile, "BTC-USD", @opts)
    end

    test "the kind and screener lists are the real ones" do
      assert Fake.fundamental_kinds() == Webull.fundamental_kinds()
      assert Fake.screeners() == Webull.screeners()
    end
  end

  describe "tokens" do
    test "create answers a PENDING token and needs credentials" do
      assert @missing = Fake.create_token([])

      assert {:ok, %{"token" => token, "status" => "PENDING", "expires_at" => ms}} =
               Fake.create_token(@opts)

      assert is_binary(token)
      assert is_integer(ms)
    end

    test "check refuses a non-text token first, then credentials, then reads the status" do
      assert {:error, {:invalid_field, :token}} = Fake.check_token(5, [])
      assert @missing = Fake.check_token("t", [])

      {:ok, %{"token" => token}} = Fake.create_token(@opts)
      assert {:ok, %{"status" => "PENDING"}} = Fake.check_token(token, @opts)
      assert {:ok, %{"status" => "INVALID"}} = Fake.check_token("other", @opts)
    end

    test "oauth validates its arguments in the real order and needs no venue credentials" do
      assert {:error, {:invalid_field, :client_id}} = Fake.oauth_token(1, "s", code: "c")
      assert {:error, {:invalid_field, :client_secret}} = Fake.oauth_token("i", nil, code: "c")
      assert {:error, :code_or_refresh_token_required} = Fake.oauth_token("i", "s", [])

      assert {:error, :code_and_refresh_token_are_exclusive} =
               Fake.oauth_token("i", "s", code: "c", refresh_token: "r")

      assert {:ok, %{"access_token" => _access, "rt_expires_in" => _rt}} =
               Fake.oauth_token("i", "s", code: "c")

      assert {:ok, %{"access_token" => _access}} = Fake.oauth_token("i", "s", refresh_token: "r")
    end
  end

  describe "small facade helpers" do
    test "they answer what the facade answers" do
      assert Fake.adjusted?("1d") == Webull.adjusted?("1d")
      assert Fake.adjusted?("nope") == nil
      assert Fake.quotes() == Webull.quotes()
      assert Fake.venue_does_not_serve() == Webull.venue_does_not_serve()
      assert Fake.streaming?(environment: :uat) == Webull.streaming?(environment: :uat)
      assert Fake.live?(environment: :uat) == Webull.live?(environment: :uat)

      # The comparisons above hold for two constants that agree by accident, so the values
      # themselves are pinned: UAT has no broker and moves no money, production has both.
      refute Fake.streaming?(environment: :uat)
      refute Fake.live?(environment: :uat)
      assert Fake.streaming?(environment: :production)
      assert Fake.live?(environment: :production)
      assert Fake.adjusted?("1d") == true
      assert Webull.adjusted?("1d") == true
      assert Fake.adjusted?("nope") == nil
      assert Webull.adjusted?("nope") == nil
    end
  end
end
