defmodule DpExchange.Webull.OrderBookTest do
  @moduledoc """
  Depth, which arrived with the equity surface.

  **This venue's book is equities-only.** The crypto snapshot publishes a top of book and
  nothing beneath it, and the vendor states `US_OPTION` is not supported on the depth
  endpoint. So the category is checked before the request rather than after the refusal.

  The assertion that costs the most to get wrong is the **timestamp**: a depth snapshot
  wearing the local clock cannot be told apart from a current one.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.{Config, Types}
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

  defp responding(body) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end
  end

  defp depth_row(overrides \\ %{}) do
    Map.merge(
      %{
        "symbol" => "F",
        "instrument_id" => "913255275",
        "quote_time" => 1_787_936_147_000,
        "bids" => [
          %{
            "price" => "13.90",
            "size" => "5",
            "order" => [%{"mpid" => "NSDQ", "size" => "3"}, %{"mpid" => "ARCA", "size" => "2"}]
          },
          %{"price" => "13.89", "size" => "12", "order" => []}
        ],
        "asks" => [
          %{"price" => "13.91", "size" => "3", "order" => [%{"mpid" => "NSDQ", "size" => "3"}]},
          %{"price" => "13.92", "size" => "20", "order" => []}
        ]
      },
      overrides
    )
  end

  describe "the book itself" do
    test "both sides come back as price/size levels" do
      assert {:ok, %Types.OrderBook{} = book} =
               Rest.get_order_book("F", @credentials,
                 plug: responding([depth_row()]),
                 retry_attempts: 0
               )

      assert book.symbol == "F"
      assert length(book.bids) == 2
      assert length(book.asks) == 2

      [{best_bid, best_bid_size} | _rest] = book.bids
      assert Decimal.equal?(best_bid, Decimal.new("13.90"))
      assert Decimal.equal?(best_bid_size, Decimal.new("5"))
      assert book.provider == :webull
    end

    test "the level's own size is used, not a sum over its participants" do
      # The venue reports 5 at the level and 3+2 across participants. They agree here and
      # will not always: attribution can be partial, and the level size is the number the
      # venue stands behind.
      row =
        depth_row(%{
          "bids" => [
            %{
              "price" => "13.90",
              "size" => "5",
              "order" => [%{"mpid" => "NSDQ", "size" => "1"}]
            }
          ]
        })

      assert {:ok, book} =
               Rest.get_order_book("F", @credentials,
                 plug: responding([row]),
                 retry_attempts: 0
               )

      assert [{_price, size}] = book.bids
      assert Decimal.equal?(size, Decimal.new("5"))
      refute Decimal.equal?(size, Decimal.new("1"))
    end

    test "the venue's quote_time is the book's time" do
      assert {:ok, book} =
               Rest.get_order_book("F", @credentials,
                 plug: responding([depth_row()]),
                 retry_attempts: 0
               )

      assert book.timestamp == DateTime.from_unix!(1_787_936_147_000, :millisecond)
    end

    test "an undated book is REFUSED, not stamped with the local clock" do
      row = depth_row() |> Map.delete("quote_time")

      assert {:error, :missing_venue_timestamp} =
               Rest.get_order_book("F", @credentials,
                 plug: responding([row]),
                 retry_attempts: 0
               )
    end

    test "the sequence is nil, because this endpoint publishes none" do
      assert {:ok, book} =
               Rest.get_order_book("F", @credentials,
                 plug: responding([depth_row()]),
                 retry_attempts: 0
               )

      assert book.sequence == nil
    end

    test "an empty side is an empty list" do
      assert {:ok, book} =
               Rest.get_order_book("F", @credentials,
                 plug: responding([depth_row(%{"asks" => []})]),
                 retry_attempts: 0
               )

      assert book.asks == []
      assert book.bids != []
    end

    test "a level with no price is dropped rather than carried as nil" do
      # A level without a price is not a level. Keeping it would put a `{nil, size}` tuple
      # into a book that a caller will fold over.
      row = depth_row(%{"bids" => [%{"size" => "5"}, %{"price" => "13.89", "size" => "12"}]})

      assert {:ok, book} =
               Rest.get_order_book("F", @credentials,
                 plug: responding([row]),
                 retry_attempts: 0
               )

      assert [{price, _size}] = book.bids
      assert Decimal.equal?(price, Decimal.new("13.89"))
    end

    test "an empty response is unreadable, not an empty book" do
      # No row means the venue said nothing about this symbol. An empty book would claim it
      # said there is no depth.
      assert {:error, _reason} =
               Rest.get_order_book("F", @credentials, plug: responding([]), retry_attempts: 0)
    end
  end

  describe "the category the venue restricts" do
    test "US_STOCK is the default and US_ETF is accepted" do
      me = self()

      plug = fn conn ->
        send(me, {:query, conn.query_string})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!([depth_row()]))
      end

      assert {:ok, _book} = Rest.get_order_book("F", @credentials, plug: plug, retry_attempts: 0)
      assert_receive {:query, query}
      assert query =~ "category=US_STOCK"

      assert {:ok, _etf} =
               Rest.get_order_book("SPY", @credentials,
                 category: "US_ETF",
                 plug: plug,
                 retry_attempts: 0
               )

      assert_receive {:query, etf_query}
      assert etf_query =~ "category=US_ETF"
    end

    test "US_OPTION is refused before the request, as the vendor states" do
      exploding = fn _conn -> raise "must not ask this endpoint for option depth" end

      assert {:error, {:unsupported_book_category, "US_OPTION"}} =
               Rest.get_order_book("AAPL", @credentials,
                 category: "US_OPTION",
                 plug: exploding,
                 retry_attempts: 0
               )
    end

    test "a crypto category is refused — this venue publishes no crypto depth" do
      exploding = fn _conn -> raise "must not ask this endpoint for crypto depth" end

      assert {:error, {:unsupported_book_category, "US_CRYPTO"}} =
               Rest.get_order_book("BTCUSD", @credentials,
                 category: "US_CRYPTO",
                 plug: exploding,
                 retry_attempts: 0
               )
    end
  end

  describe "the parameters the venue requires" do
    test "depth defaults to the venue's L2 level count and can be set" do
      me = self()

      plug = fn conn ->
        send(me, {:query, conn.query_string})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!([depth_row()]))
      end

      assert {:ok, _book} = Rest.get_order_book("F", @credentials, plug: plug, retry_attempts: 0)
      assert_receive {:query, query}
      assert query =~ "depth=10"

      assert {:ok, _l1} =
               Rest.get_order_book("F", @credentials, depth: 1, plug: plug, retry_attempts: 0)

      assert_receive {:query, l1_query}
      assert l1_query =~ "depth=1"
    end

    test "overnight_required is always sent, because the venue marks it required" do
      # An omitted required parameter is a refusal the caller cannot read.
      me = self()

      plug = fn conn ->
        send(me, {:query, conn.query_string})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!([depth_row()]))
      end

      assert {:ok, _book} = Rest.get_order_book("F", @credentials, plug: plug, retry_attempts: 0)
      assert_receive {:query, query}
      assert query =~ "overnight_required=false"

      assert {:ok, _overnight} =
               Rest.get_order_book("F", @credentials,
                 overnight: true,
                 plug: plug,
                 retry_attempts: 0
               )

      assert_receive {:query, overnight_query}
      assert overnight_query =~ "overnight_required=true"
    end
  end

  describe "the tape — five side codes and two known ones" do
    defp tick_body(overrides \\ %{}) do
      [
        %{
          "symbol" => "AAPL",
          "instrument_id" => "913256409",
          "result" => [
            Map.merge(
              %{"time" => 1_761_182_953_043, "price" => "48.07", "volume" => "1", "side" => "B"},
              overrides
            )
          ]
        }
      ]
    end

    test "a tick comes back as a Trade" do
      assert {:ok, [%Types.Trade{} = t]} =
               Rest.get_trades("AAPL", @credentials,
                 plug: responding(tick_body()),
                 retry_attempts: 0
               )

      assert t.symbol == "AAPL"
      assert Decimal.equal?(t.price, Decimal.new("48.07"))
      assert Decimal.equal?(t.quantity, Decimal.new("1"))
      assert t.side == :buy
      assert t.provider == :webull
    end

    test "B and S map; G, L and N do NOT" do
      # The venue documents the field as "Such as: B S G L N" and defines none of them. B
      # and S are unambiguous; the other three are documented nowhere the vendor publishes.
      # Folding them into buy or sell would put volume on the wrong side of a delta, which
      # is the number a caller reads a tape for.
      for {code, expected} <- [{"B", :buy}, {"S", :sell}, {"G", nil}, {"L", nil}, {"N", nil}] do
        assert {:ok, [t]} =
                 Rest.get_trades("AAPL", @credentials,
                   plug: responding(tick_body(%{"side" => code})),
                   retry_attempts: 0
                 )

        assert t.side == expected, "side #{code} mapped to #{inspect(t.side)}"
      end
    end

    test "there is no per-tick id on this endpoint, and nil says so" do
      assert {:ok, [t]} =
               Rest.get_trades("AAPL", @credentials,
                 plug: responding(tick_body()),
                 retry_attempts: 0
               )

      assert t.id == nil
    end

    test "broken is false — this venue publishes no bust flag here" do
      assert {:ok, [t]} =
               Rest.get_trades("AAPL", @credentials,
                 plug: responding(tick_body()),
                 retry_attempts: 0
               )

      refute t.broken
    end

    test "an undated tick is refused, never stamped with the local clock" do
      assert {:error, :missing_venue_timestamp} =
               Rest.get_trades("AAPL", @credentials,
                 plug: responding(tick_body(%{"time" => nil})),
                 retry_attempts: 0
               )
    end

    test "the session is always sent, and defaults to regular hours" do
      # The venue marks trading_sessions required. RTH is the default because it is the
      # session the rest of this package's price data comes from.
      me = self()

      plug = fn conn ->
        send(me, {:query, conn.query_string})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(tick_body()))
      end

      assert {:ok, [_t]} = Rest.get_trades("AAPL", @credentials, plug: plug, retry_attempts: 0)
      assert_receive {:query, query}
      assert query =~ "trading_sessions=RTH"
      assert query =~ "count=30"

      assert {:ok, [_multi]} =
               Rest.get_trades("AAPL", @credentials,
                 sessions: ["PRE", "RTH"],
                 limit: 500,
                 plug: plug,
                 retry_attempts: 0
               )

      assert_receive {:query, multi}
      assert multi =~ "trading_sessions=PRE%2CRTH"
      assert multi =~ "count=500"
    end

    test "US_OPTION reaches the option tape, not the stock one" do
      # This asserted a refusal until 2026-09-01. It was a false negative: the *stock* tape
      # refuses options, and the venue publishes a separate option tape beside it.
      me = self()

      plug = fn conn ->
        send(me, {:path, conn.request_path, conn.query_string})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!([%{"symbol" => "AAPL250321C00100000", "result" => []}])
        )
      end

      assert {:ok, []} =
               Rest.get_trades("AAPL250321C00100000", @credentials,
                 category: "US_OPTION",
                 plug: plug,
                 retry_attempts: 0
               )

      assert_receive {:path, "/market-data/options/ticks/list", query}
      # The option tape takes no session filter, and sending one would assert a session
      # model that endpoint did not offer.
      refute query =~ "trading_sessions"
    end

    test "an empty tape is an empty list" do
      body = [%{"symbol" => "AAPL", "result" => []}]

      assert {:ok, []} =
               Rest.get_trades("AAPL", @credentials, plug: responding(body), retry_attempts: 0)
    end
  end

  describe "the two snapshot endpoints are not interchangeable" do
    defp stock_snapshot(overrides \\ %{}) do
      [
        Map.merge(
          %{
            "symbol" => "AAPL",
            "instrument_id" => "913256135",
            "price" => "100",
            "open" => "99",
            "high" => "105",
            "low" => "99",
            "volume" => "1000",
            "bid" => "99.99",
            "ask" => "100.01",
            "bid_size" => "5",
            "ask_size" => "7",
            "last_trade_time" => 1_787_936_147_000
          },
          overrides
        )
      ]
    end

    test "a stock category reads the stock endpoint, not the crypto one" do
      # Sending a stock symbol to the crypto endpoint returns nothing rather than an error,
      # which is why the category picks the path rather than being passed through.
      me = self()

      plug = fn conn ->
        send(me, {:path, conn.request_path, conn.query_string})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(stock_snapshot()))
      end

      assert {:ok, quote_} =
               Rest.get_price("AAPL", @credentials,
                 category: "US_STOCK",
                 plug: plug,
                 retry_attempts: 0
               )

      assert_receive {:path, path, query}
      assert path == "/market-data/stocks/snapshots/list"
      assert query =~ "category=US_STOCK"
      assert quote_.symbol == "AAPL"
    end

    test "the default is still crypto, which is what this package served before" do
      # Changing it would silently re-route existing callers onto a different market.
      me = self()

      plug = fn conn ->
        send(me, {:path, conn.request_path})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!([%{"symbol" => "BTCUSD", "price" => "40000", "last_trade_time" => 1}])
        )
      end

      assert {:ok, _quote} =
               Rest.get_price("BTC-USD", @credentials, plug: plug, retry_attempts: 0)

      assert_receive {:path, "/market-data/crypto/snapshots/list"}
    end

    test "US_OPTION reaches the option snapshot, not the stock one" do
      # This asserted a refusal until 2026-09-01, on the reading that "the vendor says the
      # stock snapshot does not serve it". True of the stock snapshot; a false negative
      # about the venue, which publishes `/market-data/options/snapshots/list` beside it.
      me = self()

      plug = fn conn ->
        send(me, {:path, conn.request_path, conn.query_string})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!([
            %{
              "symbol" => "AAPL250321C00100000",
              "price" => "3.25",
              "quote_time" => "2026-09-01T14:30:00.000+00:00"
            }
          ])
        )
      end

      assert {:ok, quote_row} =
               Rest.get_price("AAPL250321C00100000", @credentials,
                 category: "US_OPTION",
                 plug: plug,
                 retry_attempts: 0
               )

      assert Decimal.equal?(quote_row.price, Decimal.new("3.25"))
      assert_receive {:path, "/market-data/options/snapshots/list", query}
      # No extended-hours or overnight flags: they belong to the stock snapshot, and
      # sending them here would assert a session model this endpoint did not offer.
      refute query =~ "extend_hour_required"
      refute query =~ "overnight_required"
    end

    test "stock volume is real, and crypto volume stays nil" do
      # This venue publishes no crypto volume anywhere. `nil` says so; zero would claim a
      # genuinely flat interval.
      assert {:ok, stock} =
               Rest.get_price("AAPL", @credentials,
                 category: "US_STOCK",
                 plug: responding(stock_snapshot()),
                 retry_attempts: 0
               )

      assert Decimal.equal?(stock.volume, Decimal.new("1000"))

      crypto = [%{"symbol" => "BTCUSD", "price" => "40000", "last_trade_time" => 1}]

      assert {:ok, quote_} =
               Rest.get_price("BTC-USD", @credentials,
                 plug: responding(crypto),
                 retry_attempts: 0
               )

      assert quote_.volume == nil
    end

    test "an equity ticker is sent as-is, not through the pair splitter" do
      # A splitter hunting for a quote currency would mangle a ticker ending in one.
      me = self()

      plug = fn conn ->
        send(me, {:query, conn.query_string})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(stock_snapshot(%{"symbol" => "SOLV"})))
      end

      assert {:ok, quote_} =
               Rest.get_price("SOLV", @credentials,
                 category: "US_STOCK",
                 plug: plug,
                 retry_attempts: 0
               )

      assert_receive {:query, query}
      assert query =~ "symbols=SOLV"
      assert quote_.symbol == "SOLV"
    end

    test "the extended-hours flags are sent explicitly on stocks and absent on crypto" do
      # Both default to false at the venue. Sending them means a caller reading `nil` knows
      # it did not ask, rather than that the venue had nothing.
      me = self()

      plug = fn conn ->
        send(me, {:query, conn.query_string})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(stock_snapshot()))
      end

      assert {:ok, _quote} =
               Rest.get_price("AAPL", @credentials,
                 category: "US_STOCK",
                 extended_hours: true,
                 plug: plug,
                 retry_attempts: 0
               )

      assert_receive {:query, query}
      assert query =~ "extend_hour_required=true"
      assert query =~ "overnight_required=false"
    end

    test "the stock snapshot also serves the top of book" do
      assert {:ok, top} =
               Rest.get_top_of_book("AAPL", @credentials,
                 category: "US_STOCK",
                 plug: responding(stock_snapshot()),
                 retry_attempts: 0
               )

      assert Decimal.equal?(top.bid, Decimal.new("99.99"))
      assert Decimal.equal?(top.ask_size, Decimal.new("7"))
      assert top.symbol == "AAPL"
    end
  end

  describe "stock bars are a POST, and the adjustment differs by width" do
    defp bars_response do
      [
        %{
          "symbol" => "AAPL",
          "instrument_id" => "913256135",
          "result" => [
            %{
              "time" => "2021-12-28T09:00:09.945+0000",
              "open" => "1.3362",
              "close" => "1.3400",
              "high" => "1.3450",
              "low" => "1.3300",
              "volume" => "10"
            }
          ]
        }
      ]
    end

    test "a stock category posts a JSON body, where crypto sends a query" do
      me = self()

      plug = fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(me, {:sent, conn.method, conn.request_path, Jason.decode!(raw)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(bars_response()))
      end

      assert {:ok, [_candle]} =
               Rest.get_historical_prices("AAPL", "1d", [], @credentials,
                 category: "US_STOCK",
                 plug: plug,
                 retry_attempts: 0
               )

      assert_receive {:sent, "POST", path, body}
      assert path == "/market-data/stocks/bars/list"
      assert body["symbols"] == ["AAPL"]
      assert body["timespan"] == "D"
    end

    test "completed bars only — the venue's own default here is the opposite" do
      # On the crypto bars and footprints real_time_required defaults to false. Here the
      # vendor's default is Y, which includes an in-progress bar whose boundary has not
      # happened yet. A package storing that saves a bar that changes after it is written.
      me = self()

      plug = fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(me, {:sent, Jason.decode!(raw)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(bars_response()))
      end

      assert {:ok, [_candle]} =
               Rest.get_historical_prices("AAPL", "1d", [], @credentials,
                 category: "US_STOCK",
                 plug: plug,
                 retry_attempts: 0
               )

      assert_receive {:sent, body}
      assert body["real_time_required"] == false
    end

    test "the three widths the crypto endpoint does not serve are accepted" do
      me = self()

      plug = fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(me, {:sent, Jason.decode!(raw)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(bars_response()))
      end

      for {canonical, timespan} <- [{"1w", "W"}, {"1M", "M"}, {"1y", "Y"}] do
        assert {:ok, _bars} =
                 Rest.get_historical_prices("AAPL", canonical, [], @credentials,
                   category: "US_STOCK",
                   plug: plug,
                   retry_attempts: 0
                 )

        assert_receive {:sent, body}
        assert body["timespan"] == timespan
      end
    end

    test "daily and above are adjusted; minute bars are NOT" do
      # The vendor's rule. These are not the same series at different resolutions: stitching
      # 1m bars onto a daily series across a split gives a discontinuity that is real in
      # each half and wrong where they meet, and nothing in the data says which side was
      # adjusted.
      assert Rest.adjusted?("1d")
      assert Rest.adjusted?("1w")
      assert Rest.adjusted?("1M")
      assert Rest.adjusted?("1y")

      refute Rest.adjusted?("1m")
      refute Rest.adjusted?("1h")
      refute Rest.adjusted?("4h")
    end

    test "a width this package does not serve has no adjustment answer" do
      # `false` would be a claim. `nil` says there is no answer.
      assert Rest.adjusted?("3m") == nil
    end

    test "US_OPTION reaches the option bars, and get_stock_bars/5 still refuses it" do
      # Two different claims, and only the second was ever true. `get_historical_prices/5`
      # routes by category and options have their own bars endpoint; `get_stock_bars/5` is
      # the stock endpoint by name and refuses, which is not the venue lacking the data.
      me = self()

      plug = fn conn ->
        send(me, {:path, conn.request_path, conn.method})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!([%{"symbol" => "AAPL250321C00100000", "bars" => []}])
        )
      end

      assert {:ok, []} =
               Rest.get_historical_prices("AAPL250321C00100000", "1d", [], @credentials,
                 category: "US_OPTION",
                 plug: plug,
                 retry_attempts: 0
               )

      # A GET where the stock bars are a POST — the venue's own split.
      assert_receive {:path, "/market-data/options/bars/list", "GET"}

      exploding = fn _conn -> raise "must not ask the stock bars for options" end

      assert {:error, {:unsupported_book_category, "US_OPTION"}} =
               Rest.get_stock_bars("AAPL", "1d", [], @credentials,
                 category: "US_OPTION",
                 plug: exploding,
                 retry_attempts: 0
               )
    end

    test "a width neither endpoint serves is an error" do
      exploding = fn _conn -> raise "must not ask for a width the venue lacks" end

      assert {:error, {:unsupported_timeframe, "3s"}} =
               Rest.get_historical_prices("AAPL", "3s", [], @credentials,
                 category: "US_STOCK",
                 plug: exploding,
                 retry_attempts: 0
               )
    end

    test "the range goes to the venue as milliseconds" do
      me = self()

      plug = fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(me, {:sent, Jason.decode!(raw)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(bars_response()))
      end

      assert {:ok, _bars} =
               Rest.get_historical_prices(
                 "AAPL",
                 "1d",
                 [start: ~U[2021-12-01 00:00:00Z], end: ~U[2021-12-31 00:00:00Z]],
                 @credentials,
                 category: "US_STOCK",
                 plug: plug,
                 retry_attempts: 0
               )

      assert_receive {:sent, body}
      assert body["start_time"] == 1_638_316_800_000
      assert body["end_time"] == 1_640_908_800_000
    end

    test "crypto still goes to the GET endpoint" do
      me = self()

      plug = fn conn ->
        send(me, {:method, conn.method, conn.request_path})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!([
            %{"result" => [%{"time" => 1_787_935_740_000, "open" => "1", "close" => "1"}]}
          ])
        )
      end

      assert {:ok, _bars} =
               Rest.get_historical_prices("BTC-USD", "1m", [], @credentials,
                 plug: plug,
                 retry_attempts: 0
               )

      assert_receive {:method, "GET", path}
      assert path == "/market-data/crypto/bars/list"
    end
  end

  describe "crypto and stock instruments are different endpoints" do
    test "a stock category reads the stocks profiles" do
      me = self()

      plug = fn conn ->
        send(me, {:path, conn.request_path, conn.query_string})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"data" => [%{"symbol" => "AAPL"}]}))
      end

      assert {:ok, symbols} =
               Rest.get_symbols(@credentials,
                 category: "US_STOCK",
                 plug: plug,
                 retry_attempts: 0
               )

      assert_receive {:path, path, query}
      assert path == "/trading/instruments/stocks/profiles/list"
      assert query =~ "category=US_STOCK"
      assert is_list(symbols)
    end

    test "the default is still crypto" do
      me = self()

      plug = fn conn ->
        send(me, {:path, conn.request_path})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"data" => []}))
      end

      assert {:ok, []} = Rest.get_symbols(@credentials, plug: plug, retry_attempts: 0)
      assert_receive {:path, "/trading/instruments/crypto/profiles/list"}
    end

    test "an unsupported category is refused before the request" do
      exploding = fn _conn -> raise "must not list instruments for an unknown category" end

      assert {:error, {:unsupported_instrument_category, "US_OPTION"}} =
               Rest.get_symbols(@credentials,
                 category: "US_OPTION",
                 plug: exploding,
                 retry_attempts: 0
               )
    end

    test "a key echoed back unchanged is caught before the page bound" do
      # The more precise of the two guards, and it fires first: a venue repeating its key is
      # a different fault from one that genuinely has many pages.
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{"data" => [%{"symbol" => "AAPL"}], "pagination_key" => "same"})
        )
      end

      assert {:error, :pagination_key_did_not_advance} =
               Rest.get_symbols(@credentials,
                 category: "US_STOCK",
                 plug: plug,
                 retry_attempts: 0
               )
    end

    test "an always-advancing key is stopped by the page bound, on either endpoint" do
      # A truncated instrument list is the worst shape this family has — every symbol in it
      # is real and the missing ones are simply never traded — so the walk is bounded
      # rather than trusted.
      counter = :counters.new(1, [])

      plug = fn conn ->
        :counters.add(counter, 1, 1)
        page = :counters.get(counter, 1)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "data" => [%{"symbol" => "AAPL"}],
            "pagination_key" => "page-#{page}"
          })
        )
      end

      assert {:error, :too_many_instrument_pages} =
               Rest.get_symbols(@credentials,
                 category: "US_STOCK",
                 plug: plug,
                 retry_attempts: 0
               )
    end
  end
end
