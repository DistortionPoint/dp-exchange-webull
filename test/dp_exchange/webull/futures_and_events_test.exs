defmodule DpExchange.Webull.FuturesAndEventsTest do
  @moduledoc """
  Futures and event contracts.

  **Two refusals carry this file, and both are about a shape that does not fit.**

  An event tick has a `yes_price`, a `no_price` and a side of `yes`/`no`; `Types.Trade` has
  one price and a side of `:buy`/`:sell`. An event book has four sides; `Types.OrderBook`
  has two. In both cases the nearest mapping produces a number that looks right and belongs
  to the other instrument of a two-instrument market, so `get_trades/3` and
  `get_order_book/3` refuse `US_EVENT` and the venue's own rows are returned instead.

  The rest is routing: five categories, five snapshot endpoints, five bar endpoints, and a
  parameter set per endpoint that is **not** the union of all of them.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Config
  alias DpExchange.Webull.Rest

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

  defp capturing(body, test_pid) do
    fn conn ->
      send(test_pid, {:request, conn.request_path, conn.query_string})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end
  end

  defp responding(body) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end
  end

  describe "futures market data reaches the futures endpoints" do
    test "the snapshot has its own path and takes no session flags" do
      me = self()

      body = [
        %{
          "symbol" => "ESZ5",
          "price" => "6770.75",
          "volume" => "48906",
          "quote_time" => 1_761_131_409_276
        }
      ]

      assert {:ok, quote_row} =
               Rest.get_price("ESZ5", @credentials,
                 category: "US_FUTURES",
                 plug: capturing(body, me),
                 retry_attempts: 0
               )

      assert Decimal.equal?(quote_row.price, Decimal.new("6770.75"))
      assert_receive {:request, "/market-data/futures/snapshots/list", query}
      # Extended hours and overnight belong to the stock snapshot.
      refute query =~ "extend_hour_required"
      refute query =~ "overnight_required"
    end

    test "the futures volume is real, unlike crypto's" do
      body = [
        %{
          "symbol" => "ESZ5",
          "price" => "1",
          "volume" => "48906",
          "quote_time" => 1_761_131_409_276
        }
      ]

      assert {:ok, quote_row} =
               Rest.get_price("ESZ5", @credentials,
                 category: "US_FUTURES",
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert Decimal.equal?(quote_row.volume, Decimal.new("48906"))
    end

    test "bars send count and no real_time_required, which this endpoint does not take" do
      me = self()
      body = [%{"symbol" => "ESZ5", "result" => []}]

      assert {:ok, []} =
               Rest.get_historical_prices("ESZ5", "1d", [], @credentials,
                 category: "US_FUTURES",
                 limit: 500,
                 plug: capturing(body, me),
                 retry_attempts: 0
               )

      assert_receive {:request, "/market-data/futures/bars/list", query}
      assert query =~ "count=500"
      assert query =~ "category=US_FUTURES"
      refute query =~ "real_time_required"
    end

    test "bars default to the venue's own count rather than leaving it unsent" do
      # `count` is marked REQUIRED. Sending it explicitly keeps the page size this package
      # asked for rather than one that can change under it.
      me = self()

      assert {:ok, []} =
               Rest.get_historical_prices("ESZ5", "1d", [], @credentials,
                 category: "US_FUTURES",
                 plug: capturing([%{"symbol" => "ESZ5", "result" => []}], me),
                 retry_attempts: 0
               )

      assert_receive {:request, _path, query}
      assert query =~ "count=200"
    end

    test "the tape reaches the futures ticks endpoint with no session filter" do
      me = self()

      assert {:ok, []} =
               Rest.get_trades("ESZ5", @credentials,
                 category: "US_FUTURES",
                 plug: capturing([%{"symbol" => "ESZ5", "result" => []}], me),
                 retry_attempts: 0
               )

      assert_receive {:request, "/market-data/futures/ticks/list", query}
      refute query =~ "trading_sessions"
    end

    test "the book reaches the futures depths endpoint without overnight_required" do
      me = self()

      body = [
        %{
          "symbol" => "ESZ5",
          "quote_time" => 1_761_131_409_276,
          "bids" => [%{"price" => "6770.75", "size" => "10"}],
          "asks" => [%{"price" => "6771.00", "size" => "4"}]
        }
      ]

      assert {:ok, book} =
               Rest.get_order_book("ESZ5", @credentials,
                 category: "US_FUTURES",
                 depth: 5,
                 plug: capturing(body, me),
                 retry_attempts: 0
               )

      assert length(book.bids) == 1
      assert_receive {:request, "/market-data/futures/depths/list", query}
      assert query =~ "depth=5"
      refute query =~ "overnight_required"
    end

    test "footprints reach the futures path" do
      me = self()

      assert {:ok, []} =
               Rest.get_volume_profile("ESZ5", "1m", @credentials,
                 category: "US_FUTURES",
                 plug: capturing([%{"symbol" => "ESZ5", "result" => []}], me),
                 retry_attempts: 0
               )

      assert_receive {:request, "/market-data/futures/footprints/list", query}
      assert query =~ "category=US_FUTURES"
    end

    test "a category with no footprint endpoint is refused" do
      assert {:error, {:unsupported_footprint_category, "US_CRYPTO"}} =
               Rest.get_volume_profile("BTC-USD", "1m", @credentials, category: "US_CRYPTO")
    end
  end

  describe "event contracts refuse the shapes that do not fit" do
    test "get_trades/3 refuses US_EVENT and names where to go instead" do
      # yes/no is not buy/sell. Mapping one to the other files the print against the other
      # instrument of a two-instrument market, and the number looks right.
      exploding = fn _conn -> raise "must not ask the tick decoder for an event" end

      assert {:error, {:use_get_event_trades, "US_EVENT"}} =
               Rest.get_trades("KXCPI-26JAN-T0.3", @credentials,
                 category: "US_EVENT",
                 plug: exploding,
                 retry_attempts: 0
               )
    end

    test "get_order_book/3 refuses US_EVENT, because four books are not two" do
      exploding = fn _conn -> raise "must not ask the book decoder for an event" end

      assert {:error, {:unsupported_book_category, "US_EVENT"}} =
               Rest.get_order_book("KXCPI-26JAN-T0.3", @credentials,
                 category: "US_EVENT",
                 plug: exploding,
                 retry_attempts: 0
               )
    end

    test "get_event_trades/3 keeps both prices and the venue's own side" do
      body = [
        %{
          "symbol" => "KXCPI-26JAN-T0.3",
          "result" => [
            %{
              "time" => 1_772_730_554_000,
              "yes_price" => "0.05",
              "no_price" => "0.95",
              "volume" => "1.0",
              "side" => "no",
              "trade_id" => "abc"
            }
          ]
        }
      ]

      assert {:ok, [tick]} =
               Rest.get_event_trades("KXCPI-26JAN-T0.3", @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert tick["yes_price"] == "0.05"
      assert tick["no_price"] == "0.95"
      assert tick["side"] == "no"
    end

    test "get_event_order_book/3 returns four books and derives none of them" do
      # The venue says a yes bid at X equals a no ask at 1−X. That identity is the venue's;
      # a derived level cannot be told from a quoted one.
      body = [
        %{
          "symbol" => "KXCPI-26JAN-T0.3",
          "quote_time" => 1_768_872_168_870,
          "yes_bids" => [%{"price" => "0.08", "size" => "2115"}],
          "yes_asks" => [%{"price" => "0.13", "size" => "543"}],
          "no_bids" => [%{"price" => "0.87", "size" => "543"}],
          "no_asks" => [%{"price" => "0.92", "size" => "2115"}]
        }
      ]

      assert {:ok, book} =
               Rest.get_event_order_book("KXCPI-26JAN-T0.3", @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert length(book.yes_bids) == 1
      assert length(book.no_asks) == 1
      assert book.quote_time == 1_768_872_168_870
    end

    test "event bars reach their own endpoint and send the required flag" do
      me = self()

      assert {:ok, []} =
               Rest.get_historical_prices("KXCPI-26JAN-T0.3", "1m", [], @credentials,
                 category: "US_EVENT",
                 plug: capturing([%{"symbol" => "KXCPI-26JAN-T0.3", "result" => []}], me),
                 retry_attempts: 0
               )

      assert_receive {:request, "/market-data/event-contracts/bars/list", query}
      assert query =~ "real_time_required=false"
    end

    test "a width the event endpoint does not serve is an error, not the nearest one" do
      # The event enum stops at D — no weekly, monthly or yearly.
      exploding = fn _conn -> raise "must not ask for a width the venue lacks" end

      assert {:error, {:unsupported_timeframe, "1w"}} =
               Rest.get_historical_prices("KXCPI-26JAN-T0.3", "1w", [], @credentials,
                 category: "US_EVENT",
                 plug: exploding,
                 retry_attempts: 0
               )
    end

    test "the event snapshot has its own path" do
      me = self()

      body = [
        %{
          "symbol" => "KXCPI-26JAN-T0.3",
          "price" => "0.13",
          "volume" => "32",
          "last_trade_time" => 1_768_861_137_000
        }
      ]

      assert {:ok, quote_row} =
               Rest.get_price("KXCPI-26JAN-T0.3", @credentials,
                 category: "US_EVENT",
                 plug: capturing(body, me),
                 retry_attempts: 0
               )

      assert Decimal.equal?(quote_row.price, Decimal.new("0.13"))
      assert_receive {:request, "/market-data/event-contracts/snapshots/list", _query}
    end
  end

  describe "the instrument hierarchies" do
    test "futures contracts need symbols or code, and refuse before the request" do
      assert {:error, :symbols_or_code_required} =
               Rest.list_futures_contracts(@credentials, [])
    end

    test "a code alone is enough" do
      me = self()

      assert {:ok, []} =
               Rest.list_futures_contracts(@credentials,
                 code: "ES",
                 plug: capturing([], me),
                 retry_attempts: 0
               )

      assert_receive {:request, "/trading/instruments/futures/contracts/list", query}
      assert query =~ "code=ES"
      assert query =~ "category=US_FUTURES"
    end

    test "a symbol list is joined for the venue" do
      me = self()

      assert {:ok, []} =
               Rest.list_futures_contracts(@credentials,
                 symbols: ["ESZ5", "NQZ5"],
                 plug: capturing([], me),
                 retry_attempts: 0
               )

      assert_receive {:request, _path, query}
      assert query =~ "symbols=ESZ5%2CNQZ5"
    end

    test "no status filter is sent unless the caller asked for one" do
      # A filter this package chose would hide contracts the caller did not ask to hide.
      me = self()

      assert {:ok, []} =
               Rest.list_futures_contracts(@credentials,
                 code: "ES",
                 plug: capturing([], me),
                 retry_attempts: 0
               )

      assert_receive {:request, _path, query}
      refute query =~ "status="
    end

    test "product classes take only the category" do
      me = self()

      assert {:ok, [_class]} =
               Rest.list_futures_product_classes(@credentials,
                 plug: capturing([%{"product_class_id" => 2}], me),
                 retry_attempts: 0
               )

      assert_receive {:request, "/trading/instruments/futures/product-classes/list", query}
      assert query =~ "category=US_FUTURES"
    end

    test "event categories take no parameters at all" do
      me = self()

      assert {:ok, [_category]} =
               Rest.list_event_categories(@credentials,
                 plug: capturing([%{"category_code" => "ECONOMICS"}], me),
                 retry_attempts: 0
               )

      assert_receive {:request, "/trading/instruments/event-contracts/categories/list", query}
      assert query == ""
    end

    test "a series page carries its pagination key" do
      body = %{"data" => [%{"symbol" => "KXRATECUTCOUNT"}], "pagination_key" => "next-page"}

      assert {:ok, page} =
               Rest.list_event_series(@credentials, plug: responding(body), retry_attempts: 0)

      assert page.pagination_key == "next-page"
      assert length(page.rows) == 1
    end

    test "the last page has a nil key, which is how it is told from a truncation" do
      body = %{"data" => [%{"symbol" => "KXRATECUTCOUNT"}]}

      assert {:ok, page} =
               Rest.list_event_series(@credentials, plug: responding(body), retry_attempts: 0)

      assert page.pagination_key == nil
    end

    test "an empty pagination key is also the end" do
      body = %{"data" => [], "pagination_key" => ""}

      assert {:ok, %{rows: [], pagination_key: nil}} =
               Rest.list_event_series(@credentials, plug: responding(body), retry_attempts: 0)
    end

    test "events require a series symbol, refused before the request" do
      assert {:error, :series_symbol_required} = Rest.list_event_events(@credentials, [])
    end

    test "events send no status unless asked, because a settled event is still an event" do
      me = self()

      assert {:ok, []} =
               Rest.list_event_events(@credentials,
                 series_symbol: "KXRATECUTCOUNT",
                 plug: capturing([], me),
                 retry_attempts: 0
               )

      assert_receive {:request, "/trading/instruments/event-contracts/events/list", query}
      assert query =~ "series_symbol=KXRATECUTCOUNT"
      refute query =~ "status="
    end

    test "markets keep listing status and tradable status apart" do
      # A market can be LISTING and NT at the same time. One boolean would route an order at
      # a market that is listed and not accepting one.
      body = %{
        "data" => [
          %{
            "symbol" => "KXRATECUTCOUNT-25DEC31-T3",
            "status" => "LISTING",
            "tradable_status" => "NT"
          }
        ]
      }

      assert {:ok, %{rows: [market]}} =
               Rest.list_event_markets(@credentials, plug: responding(body), retry_attempts: 0)

      assert market["status"] == "LISTING"
      assert market["tradable_status"] == "NT"
    end

    test "an expiry filter is sent as a date the venue reads" do
      me = self()

      assert {:ok, _page} =
               Rest.list_event_markets(@credentials,
                 series_symbol: "KXRATECUTCOUNT",
                 expiring_after: ~D[2026-12-31],
                 plug: capturing(%{"data" => []}, me),
                 retry_attempts: 0
               )

      assert_receive {:request, "/trading/instruments/event-contracts/markets/list", query}
      assert query =~ "expiration_date_after=2026-12-31"
    end
  end

  describe "the facade reaches all of it" do
    test "each venue-specific function delegates" do
      assert {:ok, []} =
               DpExchange.Webull.list_futures_contracts(
                 credentials: @credentials,
                 code: "ES",
                 plug: responding([]),
                 retry_attempts: 0
               )

      assert {:ok, []} =
               DpExchange.Webull.list_futures_product_classes(
                 credentials: @credentials,
                 plug: responding([]),
                 retry_attempts: 0
               )

      assert {:ok, []} =
               DpExchange.Webull.list_event_categories(
                 credentials: @credentials,
                 plug: responding([]),
                 retry_attempts: 0
               )

      assert {:ok, %{rows: []}} =
               DpExchange.Webull.list_event_series(
                 credentials: @credentials,
                 plug: responding(%{"data" => []}),
                 retry_attempts: 0
               )

      assert {:ok, []} =
               DpExchange.Webull.list_event_events(
                 credentials: @credentials,
                 series_symbol: "KX",
                 plug: responding([]),
                 retry_attempts: 0
               )

      assert {:ok, %{rows: []}} =
               DpExchange.Webull.list_event_markets(
                 credentials: @credentials,
                 plug: responding(%{"data" => []}),
                 retry_attempts: 0
               )

      assert {:ok, []} =
               DpExchange.Webull.get_event_trades("KX-T1",
                 credentials: @credentials,
                 plug: responding([%{"symbol" => "KX-T1", "result" => []}]),
                 retry_attempts: 0
               )

      assert {:ok, %{yes_bids: []}} =
               DpExchange.Webull.get_event_order_book("KX-T1",
                 credentials: @credentials,
                 plug: responding([%{"symbol" => "KX-T1", "quote_time" => 1}]),
                 retry_attempts: 0
               )
    end
  end
end
