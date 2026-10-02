defmodule DpExchange.Webull.SpecExamplesTest do
  @moduledoc """
  Every endpoint this package calls, driven through a fixture built from the vendor's own
  documented example response — never a fixture invented to agree with the code.

  ## Why this file exists

  This family's worst bugs came from test fixtures written to agree with the code instead
  of with the vendor: a fixture with the field name and shape the decoder already expected
  proves nothing about whether that decoder reads what Webull actually sends.
  `documented_paths_test.exs` closed the same gap for paths alone — three of five endpoints
  it audited had also changed shape, and nothing before it would have caught that. This
  file does the same thing for every endpoint, on both sides of the wire: the RESPONSE
  fixture is the vendor's own worked example (or, where none exists, a value built strictly
  from the schema's own documented properties and JSON types — stated as such), and the
  REQUEST assertion checks the method, path, and documented parameter/body field names and
  types against the same page.

  Every fixture's provenance — which page, which lines, whether it is a literal worked
  example or schema-derived — is recorded in `test/fixtures/spec_examples/README.md`.

  ## Known, documented divergences — tested as the code's actual behavior, not "fixed"

  A handful of endpoints have a code comment elsewhere in this package recording a
  deliberate divergence from what the vendor page says, because a *measured, live* result
  contradicts the page. These are tested here as the code's real wire behavior, with a
  citation back to that comment — not treated as bugs:

  - `Subscription.subscribe/3` and `unsubscribe/3` send `sub_types` uppercase (not the
    lowercase MQTT topic names) and `category: "US_CRYPTO"` (not `subscribe.md`'s
    documented `US_STOCK`/`US_ETF` enum), and omit `grab` entirely — all three confirmed
    live, `subscription.ex`'s own moduledoc.
  - `crypto_bars/5` sends `real_time_required: "false"` under `crypto-bars.md:95`'s own
    self-contradicting prose about what the two values mean — `rest.ex`'s `crypto_bars/5`
    moduledoc.

  ## Where a mismatch WAS a real bug, it is fixed in `rest.ex`, not test-bent

  Building this suite found several real gaps between what Webull documents and what this
  package sent or decoded. Each is now fixed at its own site in `rest.ex`, with a comment
  citing the page and the consequence, and this file's tests assert the *fixed* behavior:
  `industry_comparisons` and `fund_net_values` were dropping a documented optional
  parameter (`sort_by`, `last_date`); three screeners (`top_actives`, `week52_high_low`,
  `high_dividend_ranks`) were doing the same for their own `sort_by`; `update_watchlist/3`
  was not checking the venue's own `{"success": false}`; `sort` was going out as a JSON
  string where `create-watchlist.md`/`update-watchlist.md` document an integer;
  `place_orders/3` was decoding the documented batch envelope as one row instead of one row
  per order; and `support_trading_session` — present in `common-order-place.md`'s own
  worked example — never reached the wire from `preview_order/3`/`place_order/3` at all.
  """

  use ExUnit.Case, async: true

  import Bitwise

  alias DpExchange.Core.{Config, Instrument, Types}
  alias DpExchange.Webull.{QuoteProto, Rest, Subscription, SymbolFormat}

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

  @credentials %{app_key: "test-key", app_secret: "test-secret"}

  defp fixture!(name) do
    [__DIR__, "..", "..", "fixtures", "spec_examples", name]
    |> Path.join()
    |> File.read!()
    |> Jason.decode!()
  end

  defp responding(body, status \\ 200) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, Jason.encode!(body))
    end
  end

  defp capturing(body, test_pid, status \\ 200) do
    fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request, conn.method, conn.request_path, conn.query_string, raw})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, Jason.encode!(body))
    end
  end

  # Server-Sent Events — the shape `news-summary.md:195` documents for
  # `POST /market-data/news/summaries/get`, the only endpoint in this file that answers
  # this way rather than with JSON.
  defp sse_body(events),
    do: Enum.map_join(events, "\n\n", &"event:message\ndata:#{Jason.encode!(&1)}")

  defp sse_responding(events) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.resp(200, sse_body(events))
    end
  end

  defp sse_capturing(events, test_pid) do
    fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request, conn.method, conn.request_path, conn.query_string, raw})

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.resp(200, sse_body(events))
    end
  end

  # --- protobuf streaming wire encoding (QuoteProto half) --------------------------------
  #
  # `streaming-api.md` documents field NAMES, TYPES and NUMBERS, never wire bytes —
  # protobuf isn't human-readable, so there is no literal vendor byte example to fixture
  # from. Each `stream_*_fields.json` fixture is SCHEMA-DERIVED (see
  # `test/fixtures/spec_examples/README.md`): one representative value per documented
  # field. These helpers hand-encode that fixture into real protobuf wire bytes using the
  # documented field NUMBERS (cross-checked against `QuoteProto`'s own field-number
  # comments), so the decode assertions below prove the field-number mapping against the
  # schema, not against this file's own assumptions.

  defp varint(value) when value < 0x80, do: <<value>>
  defp varint(value), do: <<1::1, band(value, 0x7F)::7, varint(bsr(value, 7))::binary>>

  defp field(number, value) when is_binary(value) do
    varint(bsl(number, 3) ||| 2) <> varint(byte_size(value)) <> value
  end

  # Basic { string symbol = 1; string instrument_id = 2; string timestamp = 3; } —
  # streaming-api.md:161-165.
  defp encode_basic(%{"symbol" => symbol, "instrument_id" => iid, "timestamp" => ts}) do
    field(1, symbol) <> field(2, iid) <> field(3, ts)
  end

  # Snapshot — streaming-api.md:183-195. basic=1, trade_time=2, price=3, open=4, high=5,
  # low=6, pre_close=7, volume=8, change=9, change_ratio=10.
  defp encode_snapshot(fixture) do
    field(1, encode_basic(fixture["basic"])) <>
      field(2, fixture["trade_time"]) <>
      field(3, fixture["price"]) <>
      field(4, fixture["open"]) <>
      field(5, fixture["high"]) <>
      field(6, fixture["low"]) <>
      field(7, fixture["pre_close"]) <>
      field(8, fixture["volume"]) <>
      field(9, fixture["change"]) <>
      field(10, fixture["change_ratio"])
  end

  # Tick — streaming-api.md:197-203. basic=1, time=2, price=3, volume=4, side=5.
  defp encode_tick(fixture) do
    field(1, encode_basic(fixture["basic"])) <>
      field(2, fixture["time"]) <>
      field(3, fixture["price"]) <>
      field(4, fixture["volume"]) <>
      field(5, fixture["side"])
  end

  # Order { string mpid = 1; string size = 2; } — streaming-api.md:180.
  defp encode_order(%{"mpid" => mpid, "size" => size}), do: field(1, mpid) <> field(2, size)

  # Broker { string bid = 1; string name = 2; } — streaming-api.md:181.
  defp encode_broker(%{"bid" => bid, "name" => name}), do: field(1, bid) <> field(2, name)

  # AskBid { string price = 1; string size = 2; repeated Order order = 3;
  #          repeated Broker broker = 4; } — streaming-api.md:173-178. Encoding the full
  # shape, order/broker included, is the point: `QuoteProto`'s own comment records that an
  # AskBid is NOT a two-field message, and a decoder that only survives the simplified
  # two-field version would not prove the schema match this fixture is for.
  defp encode_ask_bid(level) do
    base = field(1, level["price"]) <> field(2, level["size"])

    orders =
      level |> Map.get("order", []) |> Enum.reduce(<<>>, &(&2 <> field(3, encode_order(&1))))

    brokers =
      level |> Map.get("broker", []) |> Enum.reduce(<<>>, &(&2 <> field(4, encode_broker(&1))))

    base <> orders <> brokers
  end

  # Quote { Basic basic = 1; repeated AskBid asks = 2; repeated AskBid bids = 3; } —
  # streaming-api.md:167-171.
  defp encode_quote(fixture) do
    asks = fixture["asks"] |> Enum.reduce(<<>>, &(&2 <> field(2, encode_ask_bid(&1))))
    bids = fixture["bids"] |> Enum.reduce(<<>>, &(&2 <> field(3, encode_ask_bid(&1))))
    field(1, encode_basic(fixture["basic"])) <> asks <> bids
  end

  # =========================================================================================
  # Quotes, top-of-book, instrument symbols, quantization
  # =========================================================================================

  # `crypto-snapshot.md:27` — GET /market-data/crypto/snapshots/list
  describe "get_price/3 against the crypto snapshot" do
    test "reads the vendor's documented fields and sends the crypto wire shape" do
      me = self()

      assert {:ok, %Types.Quote{} = quote} =
               Rest.get_price("BTC-USD", @credentials,
                 plug: capturing(fixture!("quote_crypto_snapshot.json"), me),
                 retry_attempts: 0
               )

      assert quote.symbol == "BTC-USD"
      assert Decimal.equal?(quote.price, Decimal.new("100.5"))
      # No crypto volume anywhere on this venue — nil, never zero.
      assert quote.volume == nil
      assert quote.venue_time == DateTime.from_unix!(1_640_688_000_000, :millisecond)

      assert_receive {:request, "GET", "/market-data/crypto/snapshots/list", query, _raw}
      decoded = URI.decode_query(query)
      assert decoded["symbols"] == "BTCUSD"
      assert decoded["category"] == "US_CRYPTO"
      # Crypto takes neither extend_hour_required nor overnight_required.
      refute Map.has_key?(decoded, "extend_hour_required")
      refute Map.has_key?(decoded, "overnight_required")
    end
  end

  # `snapshot.md:27` — GET /market-data/stocks/snapshots/list
  describe "get_price/3 against the stock snapshot" do
    test "reads a real volume and sends the stock session flags explicitly" do
      me = self()

      assert {:ok, %Types.Quote{} = quote} =
               Rest.get_price("AAPL", @credentials,
                 category: "US_STOCK",
                 plug: capturing(fixture!("quote_stock_snapshot.json"), me),
                 retry_attempts: 0
               )

      assert quote.symbol == "AAPL"
      assert Decimal.equal?(quote.price, Decimal.new("100"))
      assert Decimal.equal?(quote.volume, Decimal.new("1000"))
      assert quote.venue_time == DateTime.from_unix!(1_640_688_000_000, :millisecond)

      assert_receive {:request, "GET", "/market-data/stocks/snapshots/list", query, _raw}
      decoded = URI.decode_query(query)
      assert decoded["symbols"] == "AAPL"
      assert decoded["category"] == "US_STOCK"
      assert decoded["extend_hour_required"] == "false"
      assert decoded["overnight_required"] == "false"
    end
  end

  # `option-snapshot.md:27` — GET /market-data/options/snapshots/list
  describe "get_price/3 against the option snapshot" do
    test "reads the option's own price and volume" do
      me = self()

      assert {:ok, %Types.Quote{} = quote} =
               Rest.get_price("AAPL260522C00300000", @credentials,
                 category: "US_OPTION",
                 plug: capturing(fixture!("quote_option_snapshot.json"), me),
                 retry_attempts: 0
               )

      assert quote.symbol == "AAPL260522C00300000"
      assert Decimal.equal?(quote.price, Decimal.new("47.35"))
      assert Decimal.equal?(quote.volume, Decimal.new("48906"))

      assert_receive {:request, "GET", "/market-data/options/snapshots/list", query, _raw}
      decoded = URI.decode_query(query)
      assert decoded["symbols"] == "AAPL260522C00300000"
      assert decoded["category"] == "US_OPTION"
      refute Map.has_key?(decoded, "extend_hour_required")
    end
  end

  # `futures-snapshot.md:27` — GET /market-data/futures/snapshots/list
  describe "get_price/3 against the futures snapshot" do
    test "reads the futures contract's own price and volume" do
      me = self()

      assert {:ok, %Types.Quote{} = quote} =
               Rest.get_price("SILZ5", @credentials,
                 category: "US_FUTURES",
                 plug: capturing(fixture!("quote_futures_snapshot.json"), me),
                 retry_attempts: 0
               )

      assert quote.symbol == "SILZ5"
      assert Decimal.equal?(quote.price, Decimal.new("47.35"))
      assert Decimal.equal?(quote.volume, Decimal.new("48906"))

      assert_receive {:request, "GET", "/market-data/futures/snapshots/list", query, _raw}
      decoded = URI.decode_query(query)
      assert decoded["symbols"] == "SILZ5"
      assert decoded["category"] == "US_FUTURES"
      refute Map.has_key?(decoded, "extend_hour_required")
    end
  end

  describe "get_top_of_book/3" do
    test "crypto sizes are real, not nil, on the crypto snapshot" do
      assert {:ok, %Types.TopOfBook{} = book} =
               Rest.get_top_of_book("BTC-USD", @credentials,
                 plug: responding(fixture!("quote_crypto_snapshot.json")),
                 retry_attempts: 0
               )

      assert book.symbol == "BTC-USD"
      assert Decimal.equal?(book.bid, Decimal.new("0.6217"))
      assert Decimal.equal?(book.ask, Decimal.new("0.6343"))
      assert Decimal.equal?(book.bid_size, Decimal.new("3817.29798008"))
      assert Decimal.equal?(book.ask_size, Decimal.new("1387.5"))
    end

    test "the stock snapshot's bid/ask carry through the same way" do
      assert {:ok, %Types.TopOfBook{} = book} =
               Rest.get_top_of_book("AAPL", @credentials,
                 category: "US_STOCK",
                 plug: responding(fixture!("quote_stock_snapshot.json")),
                 retry_attempts: 0
               )

      assert book.symbol == "AAPL"
      assert Decimal.equal?(book.bid, Decimal.new("13.9"))
      assert Decimal.equal?(book.ask, Decimal.new("13.9"))
      assert Decimal.equal?(book.bid_size, Decimal.new("5"))
      assert Decimal.equal?(book.ask_size, Decimal.new("5"))
    end

    # `event-snapshot.md:27` publishes yes_bid/yes_ask/no_bid/no_ask, not one bid/ask — see
    # `Rest.get_top_of_book/3`'s own moduledoc note. No request is made: the refusal
    # happens before a path is even chosen.
    test "US_EVENT is refused before a request is made, per the moduledoc's own reasoning" do
      exploding = fn _conn -> raise "must not call the venue for a refused category" end

      assert {:error, {:use_get_event_order_book, "US_EVENT"}} =
               Rest.get_top_of_book("KXCPI-26JAN-T0.3", @credentials,
                 category: "US_EVENT",
                 plug: exploding,
                 retry_attempts: 0
               )
    end
  end

  # `crypto-instrument-list.md:27,75,276` — GET /trading/instruments/crypto/profiles/list,
  # paginated via `pagination_key`; "If absent, indicates this is the last page."
  describe "get_symbols/2" do
    test "walks pagination_key to the end and returns canonical symbols" do
      me = self()
      page1 = fixture!("quote_symbols_page1.json")
      page2 = fixture!("quote_symbols_page2.json")

      plug = fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(me, {:request, conn.method, conn.request_path, conn.query_string, raw})

        body =
          if String.contains?(conn.query_string || "", "pagination_key=") do
            page2
          else
            page1
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end

      assert {:ok, symbols} = Rest.get_symbols(@credentials, plug: plug, retry_attempts: 0)
      assert symbols == ["BTC-USD"]

      assert_receive {:request, "GET", "/trading/instruments/crypto/profiles/list", query1, _}
      decoded1 = URI.decode_query(query1)
      assert decoded1["category"] == "US_CRYPTO"
      refute Map.has_key?(decoded1, "pagination_key")

      assert_receive {:request, "GET", "/trading/instruments/crypto/profiles/list", query2, _}
      decoded2 = URI.decode_query(query2)
      # The vendor's own example key (`crypto-instrument-list.md:279`), echoed back exactly.
      assert decoded2["pagination_key"] == "eyJ2IjoxLCJsYXN0SWQiOiI5MTMyNDQ3NjkiLCJwYWdlSW===="
    end
  end

  # `crypto-instrument-list.md:27,56,61-72,198-270,276-280` — same endpoint and pagination
  # as `get_symbols/2` above; see `test/fixtures/spec_examples/README.md` for the fixtures'
  # own provenance, including why the `CO`/`NT` rows substitute the schema's own other
  # enum members into its one worked-example row rather than inventing a second one.
  describe "list_instruments/2" do
    test "walks pagination_key, maps OC/CO/NT and derives base/quote from currency" do
      me = self()
      page1 = fixture!("list_instruments_page1.json")
      page2 = fixture!("list_instruments_page2.json")

      plug = fn conn ->
        {:ok, _raw, conn} = Plug.Conn.read_body(conn)
        send(me, {:request, conn.query_string})

        body =
          if String.contains?(conn.query_string || "", "pagination_key=") do
            page2
          else
            page1
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end

      assert {:ok, instruments} =
               Rest.list_instruments(@credentials, plug: plug, retry_attempts: 0)

      assert [
               %Instrument{symbol: "BTC-USD", base: "BTC", quote: "USD", status: :tradable},
               %Instrument{symbol: "ALT-USD", base: "ALT", quote: "USD", status: :unknown},
               %Instrument{symbol: "BTC-USD", base: "BTC", quote: "USD", status: :unknown}
             ] = instruments

      assert Enum.all?(instruments, &(&1.instrument == :spot))

      assert_receive {:request, first_query}
      refute String.contains?(first_query || "", "pagination_key=")
      assert_receive {:request, second_query}
      # The vendor's own example key (`crypto-instrument-list.md:279`), echoed back exactly.
      decoded = URI.decode_query(second_query)
      assert decoded["pagination_key"] == "eyJ2IjoxLCJsYXN0SWQiOiI5MTMyNDQ3NjkiLCJwYWdlSW===="
    end
  end

  describe "quantization/3" do
    # `crypto-instrument-list.md:27,236-265` — the crypto row publishes all six fields.
    test "a crypto symbol reads all six quantization fields" do
      me = self()

      assert {:ok, quantum} =
               Rest.quantization("BTC-USD", @credentials,
                 plug: capturing(fixture!("quote_quantization_crypto.json"), me),
                 retry_attempts: 0
               )

      assert Decimal.equal?(quantum.price_increment, Decimal.new("2.0"))
      assert Decimal.equal?(quantum.quantity_increment, Decimal.new("1.0"))
      assert Decimal.equal?(quantum.min_quantity, Decimal.new("2.0"))
      assert Decimal.equal?(quantum.max_quantity, Decimal.new("2.0"))
      assert Decimal.equal?(quantum.min_quote_size, Decimal.new("2.0"))
      assert Decimal.equal?(quantum.max_quote_size, Decimal.new("2.0"))
      assert quantum.status == "OC"

      assert_receive {:request, "GET", "/trading/instruments/crypto/profiles/list", query, _raw}
      decoded = URI.decode_query(query)
      assert decoded["category"] == "US_CRYPTO"
      assert decoded["symbols"] == "BTCUSD"
    end

    # `instrument-list.md:27,217-350` — the stock row has no price step and no per-unit or
    # per-cash min/max anywhere; only `lot_size` is quantization vocabulary here.
    test "a stock symbol reads only quantity_increment, the rest nil" do
      me = self()

      assert {:ok, quantum} =
               Rest.quantization("AAPL", @credentials,
                 plug: capturing(fixture!("quote_quantization_stock.json"), me),
                 retry_attempts: 0
               )

      assert quantum.price_increment == nil
      assert Decimal.equal?(quantum.quantity_increment, Decimal.new("1.0"))
      assert quantum.min_quantity == nil
      assert quantum.max_quantity == nil
      assert quantum.min_quote_size == nil
      assert quantum.max_quote_size == nil
      assert quantum.status == "OC"

      assert_receive {:request, "GET", "/trading/instruments/stocks/profiles/list", query, _raw}
      decoded = URI.decode_query(query)
      assert decoded["category"] == "US_STOCK"
      assert decoded["symbols"] == "AAPL"
    end
  end

  # =========================================================================================
  # Historical bars
  # =========================================================================================

  describe "crypto bars — GET /market-data/crypto/bars/list (crypto-bars.md)" do
    setup do: %{fixture: fixture!("bars_crypto.json")}

    test "decodes the vendor's documented example bar", %{fixture: fixture} do
      assert {:ok, [%Types.Candle{} = bar]} =
               Rest.get_historical_prices("BTC-USD", "1m", [], @credentials,
                 plug: responding(fixture),
                 retry_attempts: 0
               )

      assert bar.symbol == "BTC-USD"
      assert bar.timeframe == "1m"
      assert bar.opened_at == ~U[2021-12-28 09:00:09.945Z]
      assert Decimal.equal?(bar.open, Decimal.new("150.25"))
      assert Decimal.equal?(bar.high, Decimal.new("153.15"))
      assert Decimal.equal?(bar.low, Decimal.new("149.8"))
      assert Decimal.equal?(bar.close, Decimal.new("152.3"))
      # crypto-bars.md's own bar schema (`BarDetailVo`, crypto-bars.md:226-258) carries no
      # `volume` property at all — this is not an omission on the fixture's part.
      assert bar.volume == nil
    end

    test "sends the documented query params, including the known real_time_required divergence",
         %{fixture: fixture} do
      me = self()

      assert {:ok, [_bar]} =
               Rest.get_historical_prices("BTC-USD", "1m", [], @credentials,
                 plug: capturing(fixture, me),
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", path, query, _raw}
      assert path == "/market-data/crypto/bars/list"
      assert query =~ "symbols=BTCUSD"
      assert query =~ "category=US_CRYPTO"
      assert query =~ "timespan=M1"
      # `crypto_bars/5`'s moduledoc (rest.ex, above the function) records that
      # `crypto-bars.md:95`'s own prose about this parameter contradicts its name and
      # documented default (`"default": "true"`, crypto-bars.md:99) — the bullets read
      # `true` => completed-only, `false` => include in-progress, backwards from what the
      # name/default imply. The code deliberately sends `"false"` under that
      # contradiction, reasoning that an in-progress bar is not one this package will
      # store. This assertion documents the code's actual wire behavior, not a fix.
      assert query =~ "real_time_required=false"
    end
  end

  describe "futures bars — GET /market-data/futures/bars/list (futures-historical-bars.md)" do
    setup do: %{fixture: fixture!("bars_futures.json")}

    test "decodes the vendor's documented example bar", %{fixture: fixture} do
      assert {:ok, [%Types.Candle{} = bar]} =
               Rest.get_historical_prices("SILZ5", "1m", [], @credentials,
                 category: "US_FUTURES",
                 plug: responding(fixture),
                 retry_attempts: 0
               )

      assert bar.opened_at == ~U[2021-12-28 09:00:09.945Z]
      assert Decimal.equal?(bar.open, Decimal.new("1.3362"))
      assert Decimal.equal?(bar.high, Decimal.new("1.3362"))
      assert Decimal.equal?(bar.low, Decimal.new("1.3362"))
      assert Decimal.equal?(bar.close, Decimal.new("1.3362"))
      assert Decimal.equal?(bar.volume, Decimal.new("10"))
    end

    test "sends the documented query params — no range, count required", %{fixture: fixture} do
      me = self()

      assert {:ok, [_bar]} =
               Rest.get_historical_prices("SILZ5", "1m", [], @credentials,
                 category: "US_FUTURES",
                 plug: capturing(fixture, me),
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", path, query, _raw}
      assert path == "/market-data/futures/bars/list"
      assert query =~ "symbols=SILZ5"
      assert query =~ "category=US_FUTURES"
      assert query =~ "timespan=M1"
      # futures-historical-bars.md marks `count` `"required": true` (line 72) with a
      # documented default of 200 — sent explicitly so the page size does not drift.
      assert query =~ "count=200"
      refute query =~ "real_time_required"
    end
  end

  describe "event bars — GET /market-data/event-contracts/bars/list (event-bars.md)" do
    setup do: %{fixture: fixture!("bars_event.json")}

    test "decodes the vendor's documented example bar", %{fixture: fixture} do
      assert {:ok, [%Types.Candle{} = bar]} =
               Rest.get_historical_prices("KXCPI-26JAN-T0.3", "1m", [], @credentials,
                 category: "US_EVENT",
                 plug: responding(fixture),
                 retry_attempts: 0
               )

      assert bar.opened_at == ~U[2021-12-28 09:00:09.945Z]
      assert Decimal.equal?(bar.open, Decimal.new("0.05"))
      assert Decimal.equal?(bar.high, Decimal.new("0.05"))
      assert Decimal.equal?(bar.low, Decimal.new("0.05"))
      assert Decimal.equal?(bar.close, Decimal.new("0.05"))
      assert Decimal.equal?(bar.volume, Decimal.new("1"))
    end

    test "sends the documented query params, real_time_required defaulting false",
         %{fixture: fixture} do
      me = self()

      assert {:ok, [_bar]} =
               Rest.get_historical_prices("KXCPI-26JAN-T0.3", "1m", [], @credentials,
                 category: "US_EVENT",
                 plug: capturing(fixture, me),
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", path, query, _raw}
      assert path == "/market-data/event-contracts/bars/list"
      assert query =~ "symbols=KXCPI-26JAN-T0.3"
      assert query =~ "category=US_EVENT"
      assert query =~ "timespan=M1"
      # event-bars.md marks `real_time_required` `"required": true` (line 94) with a
      # documented default of `"false"` (line 97) — name and default agree here, unlike
      # crypto, so no divergence to record.
      assert query =~ "real_time_required=false"
    end
  end

  describe "option bars — GET /market-data/options/bars/list (option-historical-bars.md)" do
    setup do: %{fixture: fixture!("bars_option.json")}

    test "decodes the vendor's documented example bar, flattening the result-wrapped group",
         %{fixture: fixture} do
      assert {:ok, [%Types.Candle{} = bar]} =
               Rest.get_historical_prices("AAPL260522C00300000", "1m", [], @credentials,
                 category: "US_OPTION",
                 plug: responding(fixture),
                 retry_attempts: 0
               )

      assert bar.opened_at == ~U[2021-12-28 09:00:09.945Z]
      assert Decimal.equal?(bar.open, Decimal.new("1.3362"))
      assert Decimal.equal?(bar.close, Decimal.new("1.3362"))
      assert Decimal.equal?(bar.volume, Decimal.new("10"))
    end

    test "sends the documented query params — no real_time_required, no range",
         %{fixture: fixture} do
      me = self()

      assert {:ok, [_bar]} =
               Rest.get_historical_prices("AAPL260522C00300000", "1m", [], @credentials,
                 category: "US_OPTION",
                 plug: capturing(fixture, me),
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", path, query, _raw}
      assert path == "/market-data/options/bars/list"
      assert query =~ "symbols=AAPL260522C00300000"
      assert query =~ "category=US_OPTION"
      assert query =~ "timespan=M1"
      # option-historical-bars.md documents `real_time_required` as `"required": false`
      # (line 96) — `option_bars/5` sends no such param, which is a valid reading of an
      # optional field, not the crypto divergence.
      refute query =~ "real_time_required"
    end

    test "a start/end range is refused before a request is sent" do
      start = DateTime.utc_now()

      assert {:error, {:unsupported_bar_range, :option}} =
               Rest.get_historical_prices(
                 "AAPL260522C00300000",
                 "1m",
                 [start: start],
                 @credentials,
                 category: "US_OPTION",
                 retry_attempts: 0
               )
    end
  end

  describe "stock bars — POST /market-data/stocks/bars/list (historical-bars.md)" do
    setup do: %{fixture: fixture!("bars_stock_grouped.json")}

    test "flattens the object-wrapped result envelope (the group-vs-row bug this decoder now handles)",
         %{fixture: fixture} do
      assert {:ok, [%Types.Candle{} = bar]} =
               Rest.get_historical_prices("AAPL", "1m", [], @credentials,
                 category: "US_STOCK",
                 plug: responding(fixture),
                 retry_attempts: 0
               )

      # `decode_bar/3` uses the caller's own `symbol` argument, not the response group's
      # `"symbol"`/`"instrument_id"` fields — those exist only to key the group, and this
      # fixture's group carries `"SILZ5"` exactly as `historical-bars.md`'s response
      # schema documents it (`historical-bars.md:249-257`), even though that is a stock
      # endpoint page describing a futures-shaped example — the vendor page reuses the
      # futures schema's own field examples here, and this fixture is quoted verbatim
      # rather than "corrected" to a more plausible stock symbol.
      assert bar.symbol == "AAPL"
      assert bar.opened_at == ~U[2021-12-28 09:00:09.945Z]
      assert Decimal.equal?(bar.open, Decimal.new("1.3362"))
      assert Decimal.equal?(bar.high, Decimal.new("1.3362"))
      assert Decimal.equal?(bar.low, Decimal.new("1.3362"))
      assert Decimal.equal?(bar.close, Decimal.new("1.3362"))
      assert Decimal.equal?(bar.volume, Decimal.new("10"))
    end

    test "sends the documented JSON body — symbols as a list, real_time_required as a JSON boolean",
         %{fixture: fixture} do
      me = self()

      assert {:ok, [_bar]} =
               Rest.get_historical_prices("AAPL", "1m", [], @credentials,
                 category: "US_STOCK",
                 plug: capturing(fixture, me),
                 retry_attempts: 0
               )

      assert_receive {:request, "POST", path, _query, raw}
      assert path == "/market-data/stocks/bars/list"

      body = Jason.decode!(raw)
      assert body["symbols"] == ["AAPL"]
      assert body["category"] == "US_STOCK"
      assert body["timespan"] == "M1"
      # `historical-bars.md`'s requestBody schema types `real_time_required` as a JSON
      # `boolean` (historical-bars.md:192-196), not a stringified query param — `false`
      # by this package's own choice ("Completed bars only.") against the vendor's
      # documented default of `Y`/true.
      assert body["real_time_required"] == false
      refute Map.has_key?(body, "start_time")
      refute Map.has_key?(body, "end_time")
    end

    test "a range reaches the body as start_time/end_time epoch milliseconds",
         %{fixture: fixture} do
      me = self()
      start = ~U[2024-03-24 06:49:58.500Z]
      finish = ~U[2024-03-25 06:49:58.500Z]

      # The fixture's own bar is dated 2021-12-28 (`historical-bars.md`'s documented
      # `time` example), outside this range, so `within?/2` filters it client-side after
      # decoding — expected, and irrelevant here: this test is about what reaches the
      # wire, not what comes back.
      assert {:ok, _bars} =
               Rest.get_historical_prices(
                 "AAPL",
                 "1m",
                 [start: start, end: finish],
                 @credentials,
                 category: "US_STOCK",
                 plug: capturing(fixture, me),
                 retry_attempts: 0
               )

      assert_receive {:request, "POST", _path, _query, raw}
      body = Jason.decode!(raw)
      # `historical-bars.md`'s requestBody carries this exact worked example pair
      # (`jsonRequestBodyExample`, historical-bars.md:387-399): `start_time: 1711262998500`,
      # `end_time: 1711349398500`, which is what these two `DateTime`s convert to.
      assert body["start_time"] == 1_711_262_998_500
      assert body["end_time"] == 1_711_349_398_500
    end
  end

  # =========================================================================================
  # Order book depth, volume profile (footprint), auction imbalance, trades/ticks
  # =========================================================================================

  describe "order book depth — /market-data/stocks/depths/list (quotes.md)" do
    test "REQUEST: symbol, category, depth and overnight_required all reach the venue" do
      me = self()

      assert {:ok, %Types.OrderBook{}} =
               Rest.get_order_book("F", @credentials,
                 plug: capturing(fixture!("depth_order_book_stock.json"), me),
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", "/market-data/stocks/depths/list", query, _raw}
      assert query =~ "symbol=F"
      assert query =~ "category=US_STOCK"
      assert query =~ "depth=10"
      assert query =~ "overnight_required=false"
    end

    test "RESPONSE: the vendor's own example values decode into the book" do
      assert {:ok, %Types.OrderBook{} = book} =
               Rest.get_order_book("F", @credentials,
                 plug: responding(fixture!("depth_order_book_stock.json")),
                 retry_attempts: 0
               )

      assert book.symbol == "F"
      assert [{bid_price, bid_size}] = book.bids
      assert Decimal.equal?(bid_price, Decimal.new("13.9"))
      assert Decimal.equal?(bid_size, Decimal.new("5"))

      assert [{ask_price, ask_size}] = book.asks
      assert Decimal.equal?(ask_price, Decimal.new("13.9"))
      assert Decimal.equal?(ask_size, Decimal.new("5"))

      # quotes.md's `quote_time` example is "1640688000000", a millisecond epoch string.
      assert book.venue_time == DateTime.from_unix!(1_640_688_000_000, :millisecond)
      assert book.provider == :webull
    end
  end

  describe "futures order book depth — /market-data/futures/depths/list (futures-depth-of-book.md)" do
    test "REQUEST: symbol, category, depth reach the venue and overnight_required is NOT sent" do
      me = self()

      assert {:ok, %Types.OrderBook{}} =
               Rest.get_order_book("SILZ5", @credentials,
                 category: "US_FUTURES",
                 plug: capturing(fixture!("depth_order_book_futures.json"), me),
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", "/market-data/futures/depths/list", query, _raw}
      assert query =~ "symbol=SILZ5"
      assert query =~ "category=US_FUTURES"
      assert query =~ "depth=10"
      refute query =~ "overnight_required"
    end

    test "RESPONSE: the vendor's own example values decode into the book" do
      assert {:ok, %Types.OrderBook{} = book} =
               Rest.get_order_book("SILZ5", @credentials,
                 category: "US_FUTURES",
                 plug: responding(fixture!("depth_order_book_futures.json")),
                 retry_attempts: 0
               )

      assert book.symbol == "SILZ5"
      assert [{bid_price, bid_size}] = book.bids
      assert Decimal.equal?(bid_price, Decimal.new("6770.75"))
      assert Decimal.equal?(bid_size, Decimal.new("10"))

      assert [{ask_price, ask_size}] = book.asks
      assert Decimal.equal?(ask_price, Decimal.new("6770.75"))
      assert Decimal.equal?(ask_size, Decimal.new("10"))

      # futures-depth-of-book.md's `quote_time` example is an integer millisecond epoch.
      assert book.venue_time == DateTime.from_unix!(1_761_131_409_276, :millisecond)
    end
  end

  describe "volume profile — /market-data/stocks/footprints/list (footprint.md)" do
    test "REQUEST: symbols, category, timespan, real_time_required=false, trading_sessions" do
      me = self()

      assert {:ok, [_profile]} =
               Rest.get_volume_profile("AAPL", "5m", @credentials,
                 session: "RTH",
                 plug: capturing(fixture!("depth_footprint.json"), me),
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", "/market-data/stocks/footprints/list", query, _raw}
      assert query =~ "symbols=AAPL"
      assert query =~ "category=US_STOCK"
      assert query =~ "timespan=M5"
      assert query =~ "real_time_required=false"
      assert query =~ "trading_sessions=RTH"
    end

    test "RESPONSE: the vendor's own example values decode into the profile" do
      assert {:ok, [%Types.VolumeProfile{} = profile]} =
               Rest.get_volume_profile("AAPL", "5m", @credentials,
                 plug: responding(fixture!("depth_footprint.json")),
                 retry_attempts: 0
               )

      assert profile.symbol == "AAPL"
      assert profile.timeframe == "5m"
      assert Decimal.equal?(profile.total_volume, Decimal.new("1000"))
      assert Decimal.equal?(profile.delta, Decimal.new("200"))
      assert Decimal.equal?(profile.buy_volume, Decimal.new("600"))
      assert Decimal.equal?(profile.sell_volume, Decimal.new("400"))
      assert Decimal.equal?(profile.buy_at_price["24.20"], Decimal.new("100"))
      assert Decimal.equal?(profile.buy_at_price["24.21"], Decimal.new("60"))
      assert Decimal.equal?(profile.sell_at_price["24.20"], Decimal.new("50"))
      assert Decimal.equal?(profile.sell_at_price["24.21"], Decimal.new("50"))
      assert profile.session == :regular
      assert profile.provider == :webull

      # footprint.md's `time` example is an ISO-8601-ish string, "+0000" (no colon), not
      # an epoch. `DateTime.from_iso8601/1` on this project's toolchain accepts that
      # offset form.
      assert profile.opened_at == ~U[2025-09-30 05:47:00.000Z]
    end
  end

  describe "auction imbalance snapshot — /market-data/stocks/noii-snapshots/list (get-noii-snapshot.md)" do
    test "REQUEST: symbol, category, imbalance_action_type reach the venue" do
      me = self()

      assert {:ok, [_imbalance]} =
               Rest.get_auction_imbalance("AAPL", @credentials,
                 auction: :opening,
                 plug: capturing(fixture!("depth_auction_imbalance.json"), me),
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", "/market-data/stocks/noii-snapshots/list", query, _raw}
      assert query =~ "symbol=AAPL"
      assert query =~ "category=US_STOCK"
      assert query =~ "imbalance_action_type=PRE_OPEN"
    end

    test "RESPONSE: the vendor's own example values decode into the imbalance" do
      assert {:ok, [%Types.AuctionImbalance{} = imbalance]} =
               Rest.get_auction_imbalance("AAPL", @credentials,
                 auction: :opening,
                 plug: responding(fixture!("depth_auction_imbalance.json")),
                 retry_attempts: 0
               )

      assert imbalance.symbol == "AAPL"
      assert imbalance.auction == :opening
      assert Decimal.equal?(imbalance.paired_quantity, Decimal.new("701859"))
      assert Decimal.equal?(imbalance.imbalance_quantity, Decimal.new("5715"))
      assert imbalance.side == "2"
      assert Decimal.equal?(imbalance.reference_price, Decimal.new("253.83"))
      assert Decimal.equal?(imbalance.near_price, Decimal.new("253.93"))
      assert Decimal.equal?(imbalance.far_price, Decimal.new("253.98"))
      assert imbalance.venue_time == DateTime.from_unix!(1_774_272_599_000, :millisecond)
      assert imbalance.provider == :webull
    end
  end

  describe "auction imbalance bars — /market-data/stocks/noii-bars/list (get-noii-bars.md)" do
    test "REQUEST: history: true reads the bars path" do
      me = self()

      assert {:ok, [_bar]} =
               Rest.get_auction_imbalance("AAPL", @credentials,
                 auction: :opening,
                 history: true,
                 plug: capturing(fixture!("depth_auction_imbalance_bars.json"), me),
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", "/market-data/stocks/noii-bars/list", query, _raw}
      assert query =~ "symbol=AAPL"
      assert query =~ "category=US_STOCK"
      assert query =~ "imbalance_action_type=PRE_OPEN"
    end

    test "RESPONSE: the vendor's own bars example carries prices and time and nothing else" do
      assert {:ok, [%Types.AuctionImbalance{} = bar]} =
               Rest.get_auction_imbalance("AAPL", @credentials,
                 auction: :opening,
                 history: true,
                 plug: responding(fixture!("depth_auction_imbalance_bars.json")),
                 retry_attempts: 0
               )

      assert bar.paired_quantity == nil
      assert bar.imbalance_quantity == nil
      assert bar.side == nil
      assert Decimal.equal?(bar.reference_price, Decimal.new("172.35"))
      assert Decimal.equal?(bar.near_price, Decimal.new("173.1"))
      assert Decimal.equal?(bar.far_price, Decimal.new("175.5"))
      assert bar.venue_time == DateTime.from_unix!(1_711_262_998_500, :millisecond)
    end
  end

  describe "trades (stock) — /market-data/stocks/ticks/list (tick.md)" do
    test "REQUEST: symbol, category, count, trading_sessions reach the venue" do
      me = self()

      assert {:ok, [_trade]} =
               Rest.get_trades("AAPL", @credentials,
                 plug: capturing(fixture!("depth_trades_stock.json"), me),
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", "/market-data/stocks/ticks/list", query, _raw}
      assert query =~ "symbol=AAPL"
      assert query =~ "category=US_STOCK"
      assert query =~ "count=30"
      assert query =~ "trading_sessions=RTH"
    end

    test "RESPONSE: the vendor's own example values decode into the trade" do
      assert {:ok, [%Types.Trade{} = trade]} =
               Rest.get_trades("AAPL", @credentials,
                 plug: responding(fixture!("depth_trades_stock.json")),
                 retry_attempts: 0
               )

      assert trade.symbol == "AAPL"
      assert Decimal.equal?(trade.price, Decimal.new("48.07"))
      assert Decimal.equal?(trade.quantity, Decimal.new("1"))
      assert trade.side == :sell
      assert trade.broken == false
      assert trade.provider == :webull
      assert trade.timestamp == DateTime.from_unix!(1_761_182_953_043, :millisecond)
    end
  end

  describe "trades (option) — /market-data/options/ticks/list (option-tick.md)" do
    test "REQUEST: symbol, category, count reach the venue; trading_sessions is NOT sent" do
      me = self()

      assert {:ok, [_trade]} =
               Rest.get_trades("AAPL260522C00300000", @credentials,
                 category: "US_OPTION",
                 plug: capturing(fixture!("depth_trades_option.json"), me),
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", "/market-data/options/ticks/list", query, _raw}
      assert query =~ "symbol=AAPL260522C00300000"
      assert query =~ "category=US_OPTION"
      assert query =~ "count=30"
      refute query =~ "trading_sessions"
    end

    test "RESPONSE: the vendor's own example values decode into the trade" do
      assert {:ok, [%Types.Trade{} = trade]} =
               Rest.get_trades("AAPL260522C00300000", @credentials,
                 category: "US_OPTION",
                 plug: responding(fixture!("depth_trades_option.json")),
                 retry_attempts: 0
               )

      assert Decimal.equal?(trade.price, Decimal.new("48.07"))
      assert Decimal.equal?(trade.quantity, Decimal.new("1"))
      assert trade.side == :sell
    end
  end

  describe "trades (futures) — /market-data/futures/ticks/list (futures-tick.md)" do
    test "REQUEST: symbol, category, count reach the venue; trading_sessions is NOT sent" do
      me = self()

      assert {:ok, [_trade]} =
               Rest.get_trades("SILZ5", @credentials,
                 category: "US_FUTURES",
                 plug: capturing(fixture!("depth_trades_futures.json"), me),
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", "/market-data/futures/ticks/list", query, _raw}
      assert query =~ "symbol=SILZ5"
      assert query =~ "category=US_FUTURES"
      assert query =~ "count=30"
      refute query =~ "trading_sessions"
    end

    test "RESPONSE: the vendor's own example values decode into the trade" do
      assert {:ok, [%Types.Trade{} = trade]} =
               Rest.get_trades("SILZ5", @credentials,
                 category: "US_FUTURES",
                 plug: responding(fixture!("depth_trades_futures.json")),
                 retry_attempts: 0
               )

      assert Decimal.equal?(trade.price, Decimal.new("48.07"))
      assert Decimal.equal?(trade.quantity, Decimal.new("1"))
      assert trade.side == :sell
    end
  end

  # =========================================================================================
  # Accounts, balances, positions, transfers, transactions
  # =========================================================================================

  describe "get_accounts/2 — /trading/accounts/list, account-list.md" do
    test "the vendor's own example row decodes whole" do
      body = fixture!("account_list.json")

      assert {:ok, [account]} =
               Rest.get_accounts(@credentials, plug: responding(body), retry_attempts: 0)

      assert account["account_id"] == "LOJOQITOD49R6G9BPQM489CISA"
      assert account["account_number"] == "10010048"
      assert account["account_type"] == "CASH"
      assert account["account_label"] == "Individual Cash"
      assert account["account_class"] == "INDIVIDUAL_CASH"
    end

    test "GET /trading/accounts/list, no account_id sent" do
      me = self()
      body = fixture!("account_list.json")

      assert {:ok, [_account]} =
               Rest.get_accounts(@credentials, plug: capturing(body, me), retry_attempts: 0)

      assert_receive {:request, "GET", path, query, _raw}
      assert path == "/trading/accounts/list"
      refute query =~ "account_id"
    end
  end

  describe "get_balances/2 — /trading/assets/balances/get, account-balance.md" do
    test "the vendor's own example currency asset decodes to a Balance" do
      body = fixture!("account_balance.json")

      assert {:ok, [balance]} =
               Rest.get_balances(@credentials,
                 plug: responding(body),
                 account_id: "LOJOQITOD49R6G9BPQM489CISA",
                 retry_attempts: 0
               )

      assert %Types.Balance{} = balance
      assert balance.currency == "USD"
      assert Decimal.equal?(balance.balance, Decimal.new("485705.95"))
      assert Decimal.equal?(balance.hold, Decimal.new("485705"))
      assert balance.available_balance == nil
      assert balance.provider == :webull
    end

    test "GET /trading/assets/balances/get with account_id" do
      me = self()
      body = fixture!("account_balance.json")

      assert {:ok, [_balance]} =
               Rest.get_balances(@credentials,
                 plug: capturing(body, me),
                 account_id: "LOJOQITOD49R6G9BPQM489CISA",
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", path, query, _raw}
      assert path == "/trading/assets/balances/get"
      assert query =~ "account_id=LOJOQITOD49R6G9BPQM489CISA"
    end
  end

  describe "get_positions/2 — /trading/assets/positions/list, account-position.md" do
    test "the vendor's own example OPTION row decodes to a Position" do
      body = fixture!("account_position.json")

      assert {:ok, [position]} =
               Rest.get_positions(@credentials,
                 plug: responding(body),
                 account_id: "LOJOQITOD49R6G9BPQM489CISA",
                 retry_attempts: 0
               )

      assert %Types.Position{} = position
      assert position.symbol == "AAPL"
      assert position.side == :long
      assert Decimal.equal?(position.quantity, Decimal.new("1"))
      assert position.instrument_type == :option
      assert Decimal.equal?(position.average_cost, Decimal.new("11.12"))
      assert Decimal.equal?(position.mark_price, Decimal.new("10.0"))
      assert Decimal.equal?(position.unrealised_pnl, Decimal.new("0.08"))
      assert position.liquidation_price == nil
      assert position.leverage == nil
    end

    test "GET /trading/assets/positions/list with account_id" do
      me = self()
      body = fixture!("account_position.json")

      assert {:ok, [_position]} =
               Rest.get_positions(@credentials,
                 plug: capturing(body, me),
                 account_id: "LOJOQITOD49R6G9BPQM489CISA",
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", path, query, _raw}
      assert path == "/trading/assets/positions/list"
      assert query =~ "account_id=LOJOQITOD49R6G9BPQM489CISA"
    end
  end

  describe "get_transfers/2 — /trading/activities/cash-activities/list, trade-cash-activity-by-type.md" do
    test "the vendor's own DEPOSIT/ACH row decodes whole" do
      body = fixture!("account_transfers.json")

      assert {:ok, [row]} =
               Rest.get_transfers(@credentials,
                 plug: responding(body),
                 account_id: "943a9802f6c14983b3b4755c69c01717",
                 retry_attempts: 0
               )

      assert row["id"] == "a1b2c3d4e5f6g7h8i9j0"
      assert row["activity_type"] == "DEPOSIT"
      assert row["activity_sub_type"] == "ACH"
      assert row["currency"] == "USD"
      assert row["net_amount"] == "1500.0"
      assert row["biz_time"] == "2024-05-01T10:15:30.691Z"
    end

    test "GET .../cash-activities/list, account_id and default activity_types, no page_size/last_activity_id" do
      me = self()
      body = fixture!("account_transfers.json")

      assert {:ok, [_row]} =
               Rest.get_transfers(@credentials,
                 plug: capturing(body, me),
                 account_id: "943a9802f6c14983b3b4755c69c01717",
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", path, query, _raw}
      assert path == "/trading/activities/cash-activities/list"
      assert query =~ "account_id=943a9802f6c14983b3b4755c69c01717"
      assert query =~ "activity_types=DEPOSIT%2CWITHDRAW%2CTRANSFER"
      refute query =~ "page_size"
      refute query =~ "last_activity_id"
    end
  end

  describe "get_transactions/2 — same endpoint, unfiltered" do
    test "the vendor's own TRADE/BUY row decodes whole" do
      body = fixture!("account_transactions.json")

      assert {:ok, [row]} =
               Rest.get_transactions(@credentials,
                 plug: responding(body),
                 account_id: "943a9802f6c14983b3b4755c69c01717",
                 retry_attempts: 0
               )

      assert row["id"] == "a1b2c3d4e5f6g7h8i9j0"
      assert row["activity_type"] == "TRADE"
      assert row["activity_sub_type"] == "BUY"
      assert row["net_amount"] == "1500.0"
      assert row["biz_time"] == "2024-05-01T10:15:30.691Z"
    end

    test "GET .../cash-activities/list, no activity_types sent, no page_size/last_activity_id" do
      me = self()
      body = fixture!("account_transactions.json")

      assert {:ok, [_row]} =
               Rest.get_transactions(@credentials,
                 plug: capturing(body, me),
                 account_id: "943a9802f6c14983b3b4755c69c01717",
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", path, query, _raw}
      assert path == "/trading/activities/cash-activities/list"
      assert query =~ "account_id=943a9802f6c14983b3b4755c69c01717"
      refute query =~ "activity_types"
      refute query =~ "page_size"
      refute query =~ "last_activity_id"
    end
  end

  # =========================================================================================
  # Order placement and order reading
  # =========================================================================================

  defp batch_order_leaf(fixture_leaf) do
    %{
      symbol: fixture_leaf["symbol"],
      side: fixture_leaf["side"] |> String.downcase() |> String.to_existing_atom(),
      order_type: :limit,
      time_in_force: :day,
      quantity: Decimal.new(fixture_leaf["quantity"]),
      price: Decimal.new(fixture_leaf["limit_price"]),
      instrument_type: :equity,
      support_trading_session: :core,
      client_order_id: fixture_leaf["client_order_id"]
    }
  end

  describe "preview_order/3 against the vendor's documented example" do
    test "builds the documented request body and decodes the documented response" do
      fixture = fixture!("order_preview.json")
      req_order = fixture["request"]["new_orders"] |> List.first()
      me = self()

      request = %{
        instrument_type: :equity,
        symbol: req_order["symbol"],
        side: :buy,
        quantity: Decimal.new(req_order["quantity"]),
        price: Decimal.new(req_order["limit_price"]),
        order_type: :limit,
        time_in_force: :day,
        client_order_id: req_order["client_order_id"]
      }

      assert {:ok, preview} =
               Rest.preview_order(@credentials, request,
                 plug: capturing([fixture["response"]], me),
                 account_id: fixture["request"]["account_id"],
                 retry_attempts: 0
               )

      assert_receive {:request, "POST", path, _query, raw}
      assert path == "/trading/orders/preview"

      sent = Jason.decode!(raw)
      assert sent["account_id"] == fixture["request"]["account_id"]
      leaf = sent["new_orders"] |> List.first()
      assert leaf["symbol"] == req_order["symbol"]
      assert leaf["combo_type"] == req_order["combo_type"]
      assert leaf["instrument_type"] == req_order["instrument_type"]
      assert leaf["market"] == req_order["market"]
      assert leaf["order_type"] == req_order["order_type"]
      assert leaf["limit_price"] == req_order["limit_price"]
      assert leaf["quantity"] == req_order["quantity"]
      assert leaf["side"] == req_order["side"]
      assert leaf["time_in_force"] == req_order["time_in_force"]
      assert leaf["entrust_type"] == req_order["entrust_type"]

      assert Decimal.equal?(
               preview.estimated_cost,
               Decimal.new(fixture["response"]["estimated_cost"])
             )

      assert Decimal.equal?(
               preview.estimated_fee,
               Decimal.new(fixture["response"]["estimated_transaction_fee"])
             )

      assert preview.instrument_type == :equity
    end

    # `common-order-place.md`'s (and `common-order-preview.md`'s) own "Equity" example
    # includes `support_trading_session: "CORE"` as part of a normal, realistic order — a
    # real, documented, optional field. `order_leaf/3` (shared by `preview_order/3` and
    # `place_order/3`) used to never read `:support_trading_session` from the request at
    # all, so a caller who supplied it had it silently dropped — fixed in `rest.ex`'s
    # `support_trading_session/1` (added alongside `order_leaf/3`).
    test "support_trading_session reaches the wire, uppercased" do
      fixture = fixture!("order_preview.json")
      req_order = fixture["request"]["new_orders"] |> List.first()
      me = self()

      request = %{
        instrument_type: :equity,
        symbol: req_order["symbol"],
        side: :buy,
        quantity: Decimal.new(req_order["quantity"]),
        price: Decimal.new(req_order["limit_price"]),
        order_type: :limit,
        time_in_force: :day,
        support_trading_session: :night,
        client_order_id: req_order["client_order_id"]
      }

      assert {:ok, _preview} =
               Rest.preview_order(@credentials, request,
                 plug: capturing([fixture["response"]], me),
                 account_id: fixture["request"]["account_id"],
                 retry_attempts: 0
               )

      assert_receive {:request, "POST", _path, _query, raw}
      leaf = raw |> Jason.decode!() |> Map.get("new_orders") |> List.first()
      assert leaf["support_trading_session"] == "NIGHT"
    end
  end

  describe "place_order/3 against the vendor's documented example" do
    test "builds the documented request body and decodes the documented response" do
      fixture = fixture!("order_place.json")
      req_order = fixture["request"]["new_orders"] |> List.first()
      me = self()

      request = %{
        instrument_type: :equity,
        symbol: req_order["symbol"],
        side: :buy,
        quantity: Decimal.new(req_order["quantity"]),
        price: Decimal.new(req_order["limit_price"]),
        order_type: :limit,
        time_in_force: :day,
        client_order_id: req_order["client_order_id"]
      }

      assert {:ok, order} =
               Rest.place_order(@credentials, request,
                 plug: capturing(fixture["response"], me),
                 account_id: fixture["request"]["account_id"],
                 retry_attempts: 0
               )

      assert_receive {:request, "POST", path, _query, raw}
      assert path == "/trading/orders/place"

      sent = Jason.decode!(raw)
      leaf = sent["new_orders"] |> List.first()
      assert leaf["symbol"] == req_order["symbol"]
      assert leaf["combo_type"] == req_order["combo_type"]
      assert leaf["instrument_type"] == req_order["instrument_type"]
      assert leaf["market"] == req_order["market"]
      assert leaf["order_type"] == req_order["order_type"]
      assert leaf["limit_price"] == req_order["limit_price"]
      assert leaf["quantity"] == req_order["quantity"]
      assert leaf["side"] == req_order["side"]
      assert leaf["time_in_force"] == req_order["time_in_force"]
      assert leaf["entrust_type"] == req_order["entrust_type"]

      assert order.id == fixture["response"]["client_order_id"]
      assert order.status == :pending
      assert order.provider == :webull
      assert order.order_type == :limit
      assert order.time_in_force == :day
    end
  end

  describe "place_orders/3 against the vendor's documented batch example" do
    test "the documented request field names are what place_orders/3 sends" do
      fixture = fixture!("order_place_batch.json")
      fixture_leaf = fixture["request"]["batch_orders"] |> List.first()
      me = self()

      assert {:ok, _results} =
               Rest.place_orders(@credentials, [batch_order_leaf(fixture_leaf)],
                 account_id: fixture["request"]["account_id"],
                 plug: capturing(fixture["response"], me),
                 retry_attempts: 0
               )

      assert_receive {:request, "POST", path, _query, raw}
      assert path == "/trading/orders/batch-place"

      sent = Jason.decode!(raw)
      assert sent["account_id"] == fixture["request"]["account_id"]
      leaf = sent["batch_orders"] |> List.first()
      assert leaf["symbol"] == fixture_leaf["symbol"]
      assert leaf["combo_type"] == fixture_leaf["combo_type"]
      assert leaf["instrument_type"] == fixture_leaf["instrument_type"]
      assert leaf["market"] == fixture_leaf["market"]
      assert leaf["entrust_type"] == fixture_leaf["entrust_type"]
      assert leaf["support_trading_session"] == fixture_leaf["support_trading_session"]
      assert leaf["time_in_force"] == fixture_leaf["time_in_force"]
      assert leaf["quantity"] == fixture_leaf["quantity"]
      assert leaf["limit_price"] == fixture_leaf["limit_price"]
      refute Map.has_key?(leaf, "qty")
    end

    # `order-batch-place.md:266-328` documents the response as `{total, success, failed,
    # batch_orders: [...]}` — its own envelope, not the generic `{"data": [...]}` shape
    # `rows/1` reads elsewhere. `place_orders/3` used to call that same generic `rows/1`
    # on this response, whose bare-object fallback wrapped the WHOLE envelope as a single
    # one-element list — fixed in `rest.ex` with `batch_rows/1`, which reads the
    # documented `"batch_orders"` key.
    test "the documented batch response decodes to one row per order" do
      fixture = fixture!("order_place_batch.json")
      fixture_leaf = fixture["request"]["batch_orders"] |> List.first()

      assert {:ok, results} =
               Rest.place_orders(@credentials, [batch_order_leaf(fixture_leaf)],
                 account_id: fixture["request"]["account_id"],
                 plug: responding(fixture["response"]),
                 retry_attempts: 0
               )

      # order-batch-place.md's own documented example: two order results, one accepted
      # and one refused.
      assert length(results) == 2

      [first, second] = results
      assert first["client_order_id"] == "0KGOHL4PR2SLC0DKIND4TI0001"
      assert first["order_id"] == "80HG7CPSFDPCAL3TP66LKBAS69"
      assert second["client_order_id"] == "0KGOHL4PR2SLC0DKIND4TI0002"
      assert second["error_code"] == "OAUTH_OPENAPI_NO_TRADING_TIME"
    end
  end

  describe "replace_order/4 against the vendor's documented example" do
    test "sends the documented modify_orders shape and reads the order back" do
      fixture = fixture!("order_replace.json")
      detail = fixture!("order_detail.json")
      modify = fixture["request"]["modify_orders"] |> List.first()
      me = self()

      plug = fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(me, {:request, conn.request_path, raw})

        body =
          if conn.request_path =~ "replace",
            do: fixture["ack_response"],
            else: detail["response_filled"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end

      assert {:ok, order} =
               Rest.replace_order(
                 @credentials,
                 modify["client_order_id"],
                 %{
                   price: Decimal.new(modify["limit_price"]),
                   quantity: Decimal.new(modify["quantity"]),
                   time_in_force: :day
                 },
                 order_type: :limit,
                 plug: plug,
                 account_id: fixture["request"]["account_id"],
                 retry_attempts: 0
               )

      assert_receive {:request, "/trading/orders/replace", raw}
      sent = Jason.decode!(raw)
      assert sent["account_id"] == fixture["request"]["account_id"]
      refute Map.has_key?(sent, "client_order_id")

      sent_mod = sent["modify_orders"] |> List.first()
      assert sent_mod["client_order_id"] == modify["client_order_id"]
      assert sent_mod["limit_price"] == modify["limit_price"]
      assert sent_mod["quantity"] == modify["quantity"]
      assert sent_mod["time_in_force"] == modify["time_in_force"]

      assert_receive {:request, "/trading/orders/get", _raw2}

      detail_row = detail["response_filled"]["orders"] |> List.first()
      assert order.id == detail_row["client_order_id"]
      assert order.status == :filled
      assert Decimal.equal?(order.price, Decimal.new(detail_row["limit_price"]))
    end
  end

  describe "cancel_order/3 against the vendor's documented example" do
    test "sends exactly the documented cancel body" do
      fixture = fixture!("order_cancel.json")
      me = self()

      assert {:ok, :cancelled} =
               Rest.cancel_order(@credentials, fixture["request"]["client_order_id"],
                 plug: capturing(fixture["response"], me),
                 account_id: fixture["request"]["account_id"],
                 retry_attempts: 0
               )

      assert_receive {:request, "POST", path, _query, raw}
      assert path == "/trading/orders/cancel"
      assert Jason.decode!(raw) == fixture["request"]
    end
  end

  describe "get_order/3 against the vendor's documented example" do
    test "decodes the documented FILLED example" do
      fixture = fixture!("order_detail.json")

      assert {:ok, order} =
               Rest.get_order(@credentials, fixture["request_query"]["client_order_id"],
                 plug: responding(fixture["response_filled"]),
                 account_id: fixture["request_query"]["account_id"],
                 retry_attempts: 0
               )

      row = fixture["response_filled"]["orders"] |> List.first()
      assert order.id == row["client_order_id"]
      assert order.symbol == "AAPL"
      assert order.side == :buy
      assert order.order_type == :market
      assert order.time_in_force == :day
      assert order.status == :filled
      assert Decimal.equal?(order.quantity, Decimal.new(row["total_quantity"]))
      assert Decimal.equal?(order.filled_quantity, Decimal.new(row["filled_quantity"]))
      assert Decimal.equal?(order.average_price, Decimal.new(row["filled_price"]))
      assert Decimal.equal?(order.price, Decimal.new(row["limit_price"]))
      assert Decimal.equal?(order.stop_price, Decimal.new(row["stop_price"]))
      assert order.provider == :webull
    end

    test "the vendor's own documented SUBMITTED example decodes to nil, not a guess" do
      fixture = fixture!("order_detail.json")

      assert {:ok, order} =
               Rest.get_order(@credentials, fixture["request_query"]["client_order_id"],
                 plug: responding(fixture["response_submitted"]),
                 account_id: fixture["request_query"]["account_id"],
                 retry_attempts: 0
               )

      assert order.status == nil
    end
  end

  describe "get_orders/2 against the vendor's documented open-orders example" do
    test "decodes the documented page and follows pagination_key to completion" do
      fixture = fixture!("order_open_list.json")
      me = self()

      plug = fn conn ->
        send(me, {:seen, conn.request_path, conn.query_string})

        body =
          if String.contains?(conn.query_string || "", "pagination_key="),
            do: %{"data" => []},
            else: fixture["response"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end

      assert {:ok, [order]} =
               Rest.get_orders(@credentials,
                 plug: plug,
                 account_id: fixture["request_query"]["account_id"],
                 retry_attempts: 0
               )

      row = fixture["response"]["data"] |> List.first() |> Map.get("orders") |> List.first()
      assert order.id == row["client_order_id"]
      assert order.symbol == "AAPL"
      assert order.side == :buy
      assert order.order_type == :limit
      assert order.time_in_force == :day
      # the fixture's status is the field's own literal documented example, "SUBMITTED" —
      # rest.ex's status_atom/1 has no stated vendor equivalence for it.
      assert order.status == nil
      assert Decimal.equal?(order.quantity, Decimal.new(row["total_quantity"]))
      assert Decimal.equal?(order.price, Decimal.new(row["limit_price"]))

      assert_receive {:seen, path, _query}
      assert path == "/trading/orders/open-orders/list"
    end
  end

  describe "get_orders/2 with history: true against the vendor's documented history example" do
    test "sends the documented start_time/end_time and decodes the documented page" do
      fixture = fixture!("order_history_list.json")
      me = self()

      plug = fn conn ->
        send(me, {:seen, conn.request_path, conn.query_string})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(fixture["response"]))
      end

      assert {:ok, [order]} =
               Rest.get_orders(@credentials,
                 history: true,
                 since: ~U[2025-01-05 22:59:59.012Z],
                 until: ~U[2025-01-05 22:59:59.012Z],
                 plug: plug,
                 account_id: fixture["request_query"]["account_id"],
                 retry_attempts: 0
               )

      row = fixture["response"]["data"] |> List.first() |> Map.get("orders") |> List.first()
      assert order.id == row["client_order_id"]
      assert order.status == :filled
      assert Decimal.equal?(order.filled_quantity, Decimal.new(row["filled_quantity"]))
      assert Decimal.equal?(order.average_price, Decimal.new(row["filled_price"]))

      assert_receive {:seen, path, query}
      assert path == "/trading/orders/historical-orders/list"
      assert query =~ "start_time=2025-01-05T22%3A59%3A59.012Z"
      assert query =~ "end_time=2025-01-05T22%3A59%3A59.012Z"
    end
  end

  # =========================================================================================
  # Watchlists (CRUD + membership) and auth/token endpoints
  # =========================================================================================

  describe "create_token/2 — create-token.md" do
    test "the vendor's own TokenRespVo example survives unmapped" do
      body = fixture!("auth_create_token.json")

      assert {:ok, token} =
               Rest.create_token(@credentials, plug: responding(body), retry_attempts: 0)

      # create-token.md:139-160
      assert token["token"] == "ccb071f764864b65a1fb48484e940a56"
      assert token["expires_at"] == 1_755_486_723_000
      assert token["status"] == "PENDING"
    end

    test "posts to the documented path with no body fields" do
      me = self()

      assert {:ok, _token} =
               Rest.create_token(@credentials,
                 plug: capturing(fixture!("auth_create_token.json"), me),
                 retry_attempts: 0
               )

      # create-token.md:27-28 — no requestBody is documented for this endpoint.
      assert_receive {:request, "POST", "/auth/tokens/create", _query, "{}"}
    end
  end

  describe "check_token/3 — check-token.md" do
    test "the documented request body is exactly {token}" do
      me = self()

      assert {:ok, checked} =
               Rest.check_token("ccb071f764864b65a1fb48484e940a56", @credentials,
                 plug: capturing(fixture!("auth_check_token.json"), me),
                 retry_attempts: 0
               )

      # check-token.md:161-182 (response) and :257-259 (jsonRequestBodyExample)
      assert checked["token"] == "ccb071f764864b65a1fb48484e940a56"
      assert checked["status"] == "PENDING"

      assert_receive {:request, "POST", "/auth/tokens/check", _query, raw}
      assert Jason.decode!(raw) == %{"token" => "ccb071f764864b65a1fb48484e940a56"}
    end
  end

  describe "oauth_token/3 — no vendor OpenAPI page found" do
    # No `connect-api/create-and-refresh-token` OpenAPI page was retrievable — its docs
    # viewer renders the field-level schema client-side, and a plain fetch of the page
    # returned only the description and status-code list, no schema. This fixture is
    # therefore NOT a vendor worked example: it is built from the field names
    # `usage-rules/auth.md` (this package's own prior reading of the vendor) documents
    # this endpoint returning — `access_token`, `refresh_token`, `expires_in`,
    # `rt_expires_in`, two expiries on two different clocks. See
    # `docs/reference/webull/openapi/README.md`.
    test "a code exchange reaches the OAuth host with the documented grant fields" do
      me = self()

      assert {:ok, tokens} =
               Rest.oauth_token("CLIENT", "secret",
                 code: "auth-code",
                 plug: capturing(fixture!("auth_oauth_token.json"), me),
                 retry_attempts: 0
               )

      assert tokens["access_token"] == "a"
      assert tokens["refresh_token"] == "r"
      assert tokens["expires_in"] == "1800"
      assert tokens["rt_expires_in"] == "1296000"
      refute tokens["expires_in"] == tokens["rt_expires_in"]

      assert_receive {:request, "POST", "/oauth2/tokens/create", _query, raw}
      form = URI.decode_query(raw)
      assert form["grant_type"] == "authorization_code"
      assert form["code"] == "auth-code"
    end
  end

  describe "list_watchlists/2 — get-watchlist.md (titled \"List Watchlists\")" do
    test "the vendor's WatchlistVo example maps to a Watchlist with symbols unread" do
      body = fixture!("watchlist_list.json")

      assert {:ok, [watchlist]} =
               Rest.list_watchlists(@credentials, plug: responding(body), retry_attempts: 0)

      # get-watchlist.md:145-171
      assert %Types.Watchlist{id: "12345678", name: "My Tech Stocks"} = watchlist
      assert watchlist.symbols == nil
    end

    test "reaches the documented path with no query parameters" do
      me = self()

      assert {:ok, _watchlists} =
               Rest.list_watchlists(@credentials,
                 plug: capturing(fixture!("watchlist_list.json"), me),
                 retry_attempts: 0
               )

      # get-watchlist.md:27-28; only headers are documented, no query params.
      assert_receive {:request, "GET", "/market-data/watchlists/list", "", _raw}
    end
  end

  describe "get_watchlist/3 — get-watchlist-instruments.md (titled \"List Watchlist Instruments\")" do
    test "the vendor's WatchlistInstrumentVo example maps to symbols with no name" do
      body = fixture!("watchlist_get.json")

      assert {:ok, watchlist} =
               Rest.get_watchlist("627b139c79619a70b3f91dba", @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      # get-watchlist-instruments.md:153-198
      assert watchlist.id == "12345678"
      assert watchlist.symbols == ["AAPL"]
      assert watchlist.name == nil
    end

    test "the documented query parameter example reaches the wire" do
      me = self()

      assert {:ok, _watchlist} =
               Rest.get_watchlist("627b139c79619a70b3f91dba", @credentials,
                 plug: capturing(fixture!("watchlist_get.json"), me),
                 retry_attempts: 0
               )

      # get-watchlist-instruments.md:36-44 — request example "627b139c79619a70b3f91dba"
      assert_receive {:request, "GET", "/market-data/watchlists/instruments/list", query, _raw}
      assert query =~ "watchlist_id=627b139c79619a70b3f91dba"
    end
  end

  describe "create_watchlist/4 — create-watchlist.md" do
    test "the request body matches the vendor's jsonRequestBodyExample exactly" do
      me = self()

      assert {:ok, watchlist} =
               Rest.create_watchlist("My Tech Stocks", [], @credentials,
                 sort: 1,
                 plug: capturing(fixture!("watchlist_create.json"), me),
                 retry_attempts: 0
               )

      # create-watchlist.md:169-179 (response) and :250-253 (jsonRequestBodyExample)
      assert watchlist.id == "12345678"

      assert_receive {:request, "POST", "/market-data/watchlists/create", _query, raw}

      # `sort` is documented as `"type": "integer"` (create-watchlist.md:150-155) — fixed
      # in `rest.ex`'s `put_present/3`, which used to run every non-Decimal value
      # (including integers) through `to_string/1` and sent `"sort":"1"` on the wire.
      assert Jason.decode!(raw) == %{"name" => "My Tech Stocks", "sort" => 1}
    end
  end

  describe "update_watchlist/3 — update-watchlist.md" do
    test "the request body matches the vendor's jsonRequestBodyExample exactly" do
      me = self()

      assert {:ok, watchlist} =
               Rest.update_watchlist("12345678", @credentials,
                 name: "My Updated Stocks",
                 sort: 2,
                 plug: capturing(fixture!("watchlist_update.json"), me),
                 retry_attempts: 0
               )

      assert watchlist.name == "My Updated Stocks"

      assert_receive {:request, "POST", "/market-data/watchlists/update", _query, raw}

      # Same `put_present/3` integer fix as `create_watchlist/4`, above —
      # update-watchlist.md documents `sort` as an integer too.
      assert Jason.decode!(raw) == %{
               "watchlist_id" => "12345678",
               "name" => "My Updated Stocks",
               "sort" => 2
             }
    end

    # `update-watchlist.md:168-186` documents the same `SuccessResponseVo`
    # `{"success": boolean}` shape as delete/add/remove/sort — fixed in `rest.ex`:
    # `update_watchlist/3` now routes its response through `watchlist_success/1`, the same
    # guard every other watchlist write already used.
    test "a venue-documented {success: false} is reported as a refusal, not a success" do
      assert {:refused, :watchlist_write_rejected} =
               Rest.update_watchlist("12345678", @credentials,
                 name: "X",
                 plug: responding(%{"success" => false}),
                 retry_attempts: 0
               )
    end
  end

  describe "delete_watchlist/3 — delete-watchlist.md" do
    test "the vendor's SuccessResponseVo example is :ok, and the request body matches" do
      me = self()

      assert {:ok, :ok} =
               Rest.delete_watchlist("12345678", @credentials,
                 plug: capturing(fixture!("watchlist_delete.json"), me),
                 retry_attempts: 0
               )

      # delete-watchlist.md:145-159 (requestBody) and :244-246 (jsonRequestBodyExample)
      assert_receive {:request, "POST", "/market-data/watchlists/delete", _query, raw}
      assert Jason.decode!(raw) == %{"watchlist_id" => "12345678"}
    end
  end

  describe "add_watchlist_instruments/4 — add-watchlist-instruments.md" do
    test "the request body matches the vendor's jsonRequestBodyExample" do
      me = self()

      assert {:ok, _result} =
               Rest.add_watchlist_instruments("12345678", ["AAPL"], @credentials,
                 plug: capturing(fixture!("watchlist_add_instruments.json"), me),
                 retry_attempts: 0
               )

      # add-watchlist-instruments.md:279-289 (jsonRequestBodyExample). This function has
      # no per-instrument `sort` option, so the optional `sort` in the vendor's example is
      # not sent — `sort` is documented optional (not in the item's `required` array).
      assert_receive {:request, "POST", "/market-data/watchlists/instruments/add", _query, raw}

      assert Jason.decode!(raw) == %{
               "watchlist_id" => "12345678",
               "instruments" => [%{"symbol" => "AAPL", "category" => "US_STOCK"}]
             }
    end
  end

  describe "remove_watchlist_instruments/4 — remove-watchlist-instruments.md" do
    test "the request body matches the vendor's jsonRequestBodyExample" do
      me = self()

      assert {:ok, _result} =
               Rest.remove_watchlist_instruments("12345678", ["AAPL"], @credentials,
                 plug: capturing(fixture!("watchlist_remove_instruments.json"), me),
                 retry_attempts: 0
               )

      assert_receive {:request, "POST", "/market-data/watchlists/instruments/remove", _query, raw}

      assert Jason.decode!(raw) == %{
               "watchlist_id" => "12345678",
               "instruments" => [%{"symbol" => "AAPL", "category" => "US_STOCK"}]
             }
    end
  end

  describe "sort_watchlist_instruments/3 — update-watchlist-instruments.md" do
    test "the request body matches the vendor's jsonRequestBodyExample, sort included" do
      me = self()

      assert {:ok, _result} =
               Rest.sort_watchlist_instruments("12345678", @credentials,
                 sorts: %{"AAPL" => 1},
                 plug: capturing(fixture!("watchlist_sort_instruments.json"), me),
                 retry_attempts: 0
               )

      # update-watchlist-instruments.md:279-289 (jsonRequestBodyExample) — the one
      # instrument-write endpoint whose caller does supply `sort`, and it survives as an
      # integer because `sort_watchlist_instruments/3` builds the map literally rather
      # than through `put_present/3`.
      assert_receive {:request, "POST", "/market-data/watchlists/instruments/update", _query, raw}

      assert Jason.decode!(raw) == %{
               "watchlist_id" => "12345678",
               "instruments" => [%{"symbol" => "AAPL", "category" => "US_STOCK", "sort" => 1}]
             }
    end
  end

  # =========================================================================================
  # Fundamentals — statement-shaped kinds (get_fundamental/4 and get_financials/4)
  # =========================================================================================

  describe "analyst_ratings — get-analyst-rating.md:166-210" do
    test "response: fields match the venue's own per-property examples" do
      body = fixture!("fund_stmt_analyst_ratings.json")

      assert {:ok, [row]} =
               Rest.get_fundamental(:analyst_ratings, "00700", @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert row["number"] == "58"
      assert row["buy"] == "11"
      assert row["strong_buy"] == "43"
      assert row["hold"] == "4"
      assert row["sell"] == "0"
      assert row["under_perform"] == "0"
      assert row["effective_start_date"] == "2021-12-29T06:24:56.038+0000"
    end

    test "request: only symbol and category — the page defines no optional params" do
      me = self()

      assert {:ok, []} =
               Rest.get_fundamental(:analyst_ratings, "AAPL", @credentials,
                 type: "ANNUAL",
                 count: 20,
                 plug: capturing([], me),
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", path, query, _raw}
      assert path == "/market-data/fundamentals/analysis/ratings/get"
      assert query =~ "symbol=AAPL"
      assert query =~ "category=US_STOCK"
      refute query =~ "type="
      refute query =~ "count="
    end
  end

  describe "analyst_target_prices — get-analyst-target-price.md:166-205" do
    test "response: fields match the venue's own per-property examples" do
      body = fixture!("fund_stmt_analyst_target_prices.json")

      assert {:ok, [row]} =
               Rest.get_fundamental(:analyst_target_prices, "00700", @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert row["mean"] == "420.5"
      assert row["low"] == "350.0"
      assert row["high"] == "500.0"
      assert row["median"] == "425.0"
      assert row["currency"] == "HKD"
    end

    test "request: only symbol and category — the page defines no optional params" do
      me = self()

      assert {:ok, []} =
               Rest.get_fundamental(:analyst_target_prices, "AAPL", @credentials,
                 type: "ANNUAL",
                 count: 20,
                 plug: capturing([], me),
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", path, query, _raw}
      assert path == "/market-data/fundamentals/analysis/target-prices/get"
      refute query =~ "type="
      refute query =~ "count="
    end
  end

  describe "company_profile — get-company-profile.md:166-223" do
    test "response: fields match the venue's own per-property examples" do
      body = fixture!("fund_stmt_company_profile.json")

      assert {:ok, [row]} =
               Rest.get_fundamental(:company_profile, "00700", @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert row["company_name"] == "Tencent Holdings Ltd."
      assert row["ceo"] == "Ma Huateng"
      assert row["employees"] == "108436"
      assert row["industries"] == ["Internet Content & Information", "Communication Services"]
    end

    test "request: only symbol and category — type/count are not this page's vocabulary" do
      me = self()

      assert {:ok, []} =
               Rest.get_fundamental(:company_profile, "AAPL", @credentials,
                 type: "ANNUAL",
                 count: 20,
                 plug: capturing([], me),
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", path, query, _raw}
      assert path == "/market-data/fundamentals/company-profiles/get"
      refute query =~ "type="
      refute query =~ "count="
    end
  end

  describe "financial_alerts — financial-alert.md:166-212" do
    test "response: fields match the venue's own per-property examples" do
      body = fixture!("fund_stmt_financial_alerts.json")

      assert {:ok, [row]} =
               Rest.get_fundamental(:financial_alerts, "TSLA", @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert row["fiscal_year"] == 2026
      # The raw venue code, untranslated — `financial_alerts` never reaches
      # `get_financials/4`, so nothing here maps it through the FY/Q1-4 legend.
      assert row["fiscal_period"] == 1
      assert row["eps_est"] == "1.9439"
      assert row["rev_est"] == "109614867330"
    end

    test "request: only symbol and category — the page defines no optional params" do
      me = self()

      assert {:ok, []} =
               Rest.get_fundamental(:financial_alerts, "AAPL", @credentials,
                 type: "ANNUAL",
                 count: 20,
                 plug: capturing([], me),
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", path, query, _raw}
      assert path == "/market-data/fundamentals/financial-alerts/get"
      refute query =~ "type="
      refute query =~ "count="
    end
  end

  describe "forecast_eps — forecast-eps.md:164-199 (bare array response)" do
    test "response: fields match the venue's own per-property examples" do
      body = fixture!("fund_stmt_forecast_eps.json")

      assert {:ok, [row]} =
               Rest.get_fundamental(:forecast_eps, "AAPL", @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert row["fiscal_year"] == 2025
      assert row["fiscal_period"] == 1
      assert row["actual"] == "-0.02"
      assert row["est"] == "0.01"
      assert row["reported"] == true
    end

    test "request: only symbol and category — the page defines no optional params" do
      me = self()

      assert {:ok, []} =
               Rest.get_fundamental(:forecast_eps, "AAPL", @credentials,
                 type: "ANNUAL",
                 count: 20,
                 plug: capturing([], me),
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", path, query, _raw}
      assert path == "/market-data/fundamentals/forecast-eps/get"
      refute query =~ "type="
      refute query =~ "count="
    end
  end

  describe "capital_flows — capital-flow.md:174-218 (count, not type)" do
    test "response: fields match the venue's own per-property examples" do
      body = fixture!("fund_stmt_capital_flows.json")

      assert {:ok, [row]} =
               Rest.get_fundamental(:capital_flows, "AAPL", @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert row["date"] == "20260522"
      assert row["large_in"] == "1.78524330946E8"
      assert row["small_out"] == "5.447926690503E8"
    end

    test "request: count reaches it, type is dropped" do
      me = self()

      assert {:ok, []} =
               Rest.get_fundamental(:capital_flows, "AAPL", @credentials,
                 type: "ANNUAL",
                 count: 3,
                 plug: capturing([], me),
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", path, query, _raw}
      assert path == "/market-data/fundamentals/capital-flows/get"
      assert query =~ "count=3"
      refute query =~ "type="
    end
  end

  describe "balance_sheet — financial-balancesheet.md:186-435 (type and count)" do
    test "response: fields match the venue's own per-property examples" do
      body = fixture!("fund_stmt_balance_sheet.json")

      assert {:ok, [row]} =
               Rest.get_fundamental(:balance_sheet, "TSLA", @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert row["fiscal_year"] == 2026
      # Raw venue code here — get_fundamental/4 never translates it.
      assert row["fiscal_period"] == 0
      assert row["end_date"] == "2025-12-27"
      assert row["total_assets"] == "379297000000"
      assert row["total_liab_sh_equity"] == "379297000000"
      assert row["non_redeemable_preferred_stock"] == "0"
    end

    test "request: type and count both reach this endpoint" do
      me = self()

      assert {:ok, []} =
               Rest.get_fundamental(:balance_sheet, "TSLA", @credentials,
                 type: "ANNUAL",
                 count: 20,
                 plug: capturing([], me),
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", path, query, _raw}
      assert path == "/market-data/fundamentals/balance-sheets/get"
      assert query =~ "type=ANNUAL"
      assert query =~ "count=20"
    end
  end

  describe "cash_flow — financial-cashflow.md:186-306 (type and count)" do
    test "response: fields match the venue's own per-property examples" do
      body = fixture!("fund_stmt_cash_flow.json")

      assert {:ok, [row]} =
               Rest.get_fundamental(:cash_flow, "AAPL", @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert row["cfo"] == "14747000000"
      assert row["net_income"] == "3855000000"
      assert row["capex"] == "-8527000000"
    end

    test "request: type and count both reach this endpoint" do
      me = self()

      assert {:ok, []} =
               Rest.get_fundamental(:cash_flow, "AAPL", @credentials,
                 type: "QUARTERLY",
                 count: 4,
                 plug: capturing([], me),
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", path, query, _raw}
      assert path == "/market-data/fundamentals/cash-flows/get"
      assert query =~ "type=QUARTERLY"
      assert query =~ "count=4"
    end
  end

  describe "income_statement — financial-income.md:186-370 (type and count)" do
    test "response: fields match the venue's own per-property examples" do
      body = fixture!("fund_stmt_income_statement.json")

      assert {:ok, [row]} =
               Rest.get_fundamental(:income_statement, "AAPL", @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert row["total_revenue"] == "416161000000"
      assert row["net_income"] == "112010000000"
      assert row["diluted_eps_incl_extra"] == "7.464996"
    end

    test "request: type and count both reach this endpoint" do
      me = self()

      assert {:ok, []} =
               Rest.get_fundamental(:income_statement, "AAPL", @credentials,
                 type: "ANNUAL",
                 count: 5,
                 plug: capturing([], me),
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", path, query, _raw}
      assert path == "/market-data/fundamentals/income-statements/get"
      assert query =~ "type=ANNUAL"
      assert query =~ "count=5"
    end
  end

  describe "indicators — financial-indicators.md:186-228 (nested values shape)" do
    test "response: the whole nested object is the one row — rows/1's bare-object fallback" do
      body = fixture!("fund_stmt_indicators.json")

      assert {:ok, [row]} =
               Rest.get_fundamental(:indicators, "AAPL", @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert row["currency"] == "USD"

      assert [%{"fiscal_year" => 2025, "fiscal_period" => 4, "value" => "0.2133"}] =
               row["values"]["roa"]
    end

    test "request: type and count both reach this endpoint" do
      me = self()

      assert {:ok, []} =
               Rest.get_fundamental(:indicators, "AAPL", @credentials,
                 type: "ANNUAL",
                 count: 5,
                 plug: capturing([], me),
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", path, query, _raw}
      assert path == "/market-data/fundamentals/indicators/get"
      assert query =~ "type=ANNUAL"
      assert query =~ "count=5"
    end
  end

  describe "industry_comparisons — industry-comparison.md:174-234" do
    test "response: the 'data' array unwraps to the comparison items" do
      body = fixture!("fund_stmt_industry_comparisons.json")

      assert {:ok, [row]} =
               Rest.get_fundamental(:industry_comparisons, "AAPL", @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert row["symbol"] == "AAPL"
      assert row["name"] == "Apple"
      assert row["rank"] == 1
      assert row["value"] == "8.266"
    end

    # `industry-comparison.md:58-67` documents an optional `sort_by` (default `EPS_TTM`) —
    # fixed in `rest.ex`'s `@fundamentals` map, which used to allow no caller-suppliable
    # params at all for this kind.
    test "request: sort_by reaches the endpoint" do
      me = self()

      assert {:ok, []} =
               Rest.get_fundamental(:industry_comparisons, "AAPL", @credentials,
                 sort_by: "MARKET_CAP",
                 plug: capturing([], me),
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", path, query, _raw}
      assert path == "/market-data/fundamentals/industry-comparisons/get"
      assert query =~ "sort_by=MARKET_CAP"
    end
  end

  describe "get_financials/4 — same wire calls, decoded into FinancialStatement" do
    test "balance_sheet: struct fields, fiscal_period translated through the venue's legend" do
      body = fixture!("fund_stmt_balance_sheet.json")

      assert {:ok, [statement]} =
               Rest.get_financials("TSLA", :balance_sheet, @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert statement.symbol == "TSLA"
      assert statement.kind == :balance_sheet
      assert statement.line_items["total_assets"] == "379297000000"
      assert statement.period_end == ~D[2025-12-27]
      assert statement.currency == "USD"
      # fiscal_period 0 → "FY", per the venue's own legend and rest.ex's
      # fiscal_period_label/1.
      assert statement.fiscal_period == "FY"
    end

    test "cash_flow: struct fields" do
      body = fixture!("fund_stmt_cash_flow.json")

      assert {:ok, [statement]} =
               Rest.get_financials("AAPL", :cash_flow, @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert statement.kind == :cash_flow
      assert statement.line_items["cfo"] == "14747000000"
      assert statement.period_end == ~D[2025-12-31]
      assert statement.fiscal_period == "FY"
    end

    test "income (contract kind :income, venue endpoint income_statement): struct fields" do
      body = fixture!("fund_stmt_income_statement.json")

      assert {:ok, [statement]} =
               Rest.get_financials("AAPL", :income, @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert statement.kind == :income
      assert statement.line_items["net_income"] == "112010000000"
      assert statement.period_end == ~D[2025-09-27]
      assert statement.fiscal_period == "FY"
    end

    # `financial-indicators.md:186-228` documents this endpoint's row as ONE object per
    # call: `{currency, values: {<metric>: [{fiscal_year, fiscal_period, value}, ...]}}` —
    # not an array of per-period rows with a top-level `fiscal_period`/`end_date` the way
    # balance_sheet/cash_flow/income_statement are shaped. `to_statement/3` reads
    # `value(row, ["end_date"])`/`value(row, ["fiscal_period"])` off the row's own top
    # level, which this shape never has. This documents the actual, silently-lossy
    # behavior rather than a fix — the right shape for `:indicators` here (one statement
    # per metric×period? per period only?) is a design decision left open.
    test "indicators: period_end and fiscal_period are nil — venue row has no top-level dates" do
      body = fixture!("fund_stmt_indicators.json")

      assert {:ok, [statement]} =
               Rest.get_financials("AAPL", :indicators, @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert statement.kind == :indicators
      assert statement.currency == "USD"
      assert statement.period_end == nil
      assert statement.fiscal_period == nil
      assert statement.line_items["values"]["roa"] != nil
    end
  end

  # =========================================================================================
  # Fund reports, dividend/earnings calendars, filings, news
  # =========================================================================================

  describe "get_fundamental(:fund_allocations, ...)" do
    # fund-allocation.md:168-215 — no worked example on the page, so this fixture is the
    # schema's own per-field example values assembled into one row.
    test "returns the venue's row unmapped, and sends no count" do
      me = self()
      body = fixture!("fund_report_allocations.json")

      assert {:ok, [row]} =
               Rest.get_fundamental(:fund_allocations, "QQQ", @credentials,
                 plug: capturing(body, me),
                 retry_attempts: 0
               )

      assert row["date"] == "2026-04-21"
      assert row["aum"] == "4.22219392815E11"
      assert row["cash"] == %{"value" => "2.9858225645E10", "ratio" => "99.9174"}

      assert_receive {:request, "GET", path, query, _raw}
      assert path == "/market-data/fundamentals/fund-allocations/get"
      assert query =~ "symbol=QQQ"
      assert query =~ "category=US_STOCK"
      refute query =~ "count="
    end
  end

  describe "get_fundamental(:fund_brief, ...)" do
    # fund-brief.md:168-215 — schema's own per-field examples; top-level shape is a bare
    # object (FundBriefVo), not an array.
    test "a bare object comes back as a single-element list" do
      body = fixture!("fund_report_brief.json")

      assert {:ok, [row]} =
               Rest.get_fundamental(:fund_brief, "QQQ", @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert row["name"] == "ProShares UltraPro QQQ"
      assert row["issuer"] == "ProShares"
      assert [%{"name" => "Michael Neches", "tenure_days" => 4587}] = row["managers"]
    end
  end

  describe "get_fundamental(:fund_dividends, ...)" do
    # fund-dividends.md:182-216 — the one fund_* kind that paginates via pagination_key,
    # and takes no count (fund-dividends.md:34-57 lists only symbol/category/pagination_key).
    test "follows pagination_key bounded, concatenates rows, and sends no count" do
      me = self()
      pages = fixture!("fund_report_dividends.json")
      page_1 = pages["page_1"]
      page_2 = pages["page_2"]
      cursor = page_1["pagination_key"]

      plug = fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(me, {:request, conn.method, conn.request_path, conn.query_string, raw})

        body =
          if String.contains?(conn.query_string || "", "pagination_key=") do
            page_2
          else
            page_1
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end

      assert {:ok, [row]} =
               Rest.get_fundamental(:fund_dividends, "QQQ", @credentials,
                 plug: plug,
                 retry_attempts: 0
               )

      assert row["share_date"] == "2026-03-15T00:00:00.000+0000"
      assert row["dps"] == "0.071616"

      assert_receive {:request, "GET", first_path, first_query, _r1}
      assert_receive {:request, "GET", second_path, second_query, _r2}

      assert first_path == "/market-data/fundamentals/fund-dividends/get"
      assert second_path == "/market-data/fundamentals/fund-dividends/get"
      refute first_query =~ "pagination_key="
      assert second_query =~ "pagination_key=#{URI.encode_www_form(cursor)}"
      refute first_query =~ "count="
      refute second_query =~ "count="
    end
  end

  describe "get_fundamental(:fund_files, ...)" do
    # fund-files.md:167-193 — schema's own example values; count is not documented on
    # this endpoint (fund-files.md:34-57 lists only symbol/category).
    test "returns the venue's rows and drops count, which this endpoint does not document" do
      me = self()
      body = fixture!("fund_report_files.json")

      assert {:ok, [row]} =
               Rest.get_fundamental(:fund_files, "QQQ", @credentials,
                 count: 5,
                 plug: capturing(body, me),
                 retry_attempts: 0
               )

      assert row["file_name"] == "Prospectus"
      assert row["type"] == 76

      assert row["url"] ==
               "https://quotes-static.webullfintech.com/qbd/fundFile/202502/570364948.PDF"

      assert_receive {:request, "GET", path, query, _raw}
      assert path == "/market-data/fundamentals/fund-files/get"
      refute query =~ "count="
    end
  end

  describe "get_fundamental(:fund_holdings, ...)" do
    # fund-holdings.md:167-202 — schema's own example values; count is not documented on
    # this endpoint either (fund-holdings.md:34-57).
    test "returns the venue's rows and drops count" do
      me = self()
      body = fixture!("fund_report_holdings.json")

      assert {:ok, [row]} =
               Rest.get_fundamental(:fund_holdings, "QQQ", @credentials,
                 count: 5,
                 plug: capturing(body, me),
                 retry_attempts: 0
               )

      assert row["target_symbol"] == "NVDA"
      assert row["share_held_pct"] == "8.91904"

      assert_receive {:request, "GET", path, query, _raw}
      assert path == "/market-data/fundamentals/fund-holdings/get"
      refute query =~ "count="
    end
  end

  describe "get_fundamental(:fund_net_values, ...)" do
    # fund-net-value.md:191-205 — schema's own example values. count IS documented here
    # (fund-net-value.md:71-77) and is one of two allowed extras for this kind.
    test "sends count, which this endpoint documents" do
      me = self()
      body = fixture!("fund_report_net_values.json")

      assert {:ok, [row]} =
               Rest.get_fundamental(:fund_net_values, "QQQ", @credentials,
                 count: 5,
                 plug: capturing(body, me),
                 retry_attempts: 0
               )

      assert row["net_value"] == "60.2908"
      assert row["currency"] == "USD"

      assert_receive {:request, "GET", path, query, _raw}
      assert path == "/market-data/fundamentals/fund-net-values/get"
      assert query =~ "count=5"
    end

    # fund-net-value.md:58-66 also documents `last_date` ("Last Query Date") — fixed in
    # `rest.ex`'s `@fundamentals` map, which used to allow only `[:count]` for this kind.
    test "sends last_date, which this endpoint also documents" do
      me = self()
      body = fixture!("fund_report_net_values.json")

      assert {:ok, [_row]} =
               Rest.get_fundamental(:fund_net_values, "QQQ", @credentials,
                 last_date: "2026-04-01",
                 plug: capturing(body, me),
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", _path, query, _raw}
      assert query =~ "last_date=2026-04-01"
    end
  end

  describe "get_fundamental(:fund_performances, ...)" do
    # fund-performance.md:167-201 — schema's own example values; bare object shape.
    test "a bare object comes back as a single-element list" do
      body = fixture!("fund_report_performances.json")

      assert {:ok, [row]} =
               Rest.get_fundamental(:fund_performances, "QQQ", @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert row["return_1y"] == "4.78693"
      assert row["end_date"] == "2025-11-03"
    end
  end

  describe "get_fundamental(:fund_ratings, ...)" do
    # fund-rating.md:169-190 — schema's own example values.
    test "returns the venue's rows" do
      body = fixture!("fund_report_ratings.json")

      assert {:ok, [row]} =
               Rest.get_fundamental(:fund_ratings, "QQQ", @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert row["rating_agency"] == "Morningstar"
      assert row["rating_results"] == 5
    end
  end

  describe "get_fundamental(:fund_splits, ...)" do
    # fund-splits.md:167-199 — schema's own example values; count is not documented on
    # this endpoint (fund-splits.md:34-57).
    test "returns the venue's rows and drops count" do
      me = self()
      body = fixture!("fund_report_splits.json")

      assert {:ok, [row]} =
               Rest.get_fundamental(:fund_splits, "QQQ", @credentials,
                 count: 5,
                 plug: capturing(body, me),
                 retry_attempts: 0
               )

      assert row["split_type"] == "MERGE"
      assert row["split_ratio"] == "1:2"

      assert_receive {:request, "GET", path, query, _raw}
      assert path == "/market-data/fundamentals/fund-splits/get"
      refute query =~ "count="
    end
  end

  describe "get_corporate_events/2 (dividend and earnings calendars)" do
    # dividend-calendar.md:168-225 and earnings-calendar.md:168-212 — the vendor's own
    # per-field example values for each calendar.
    test "a dividend row maps ex_div_date/declare_date/record_date/pay_date/amount" do
      body = fixture!("fund_report_dividend_calendar.json")

      assert {:ok, [event]} =
               Rest.get_corporate_events(@credentials,
                 symbol: "AAPL",
                 kind: :dividend,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert event.kind == :dividend
      assert event.ex_date == ~D[2026-05-08]
      assert event.record_date == ~D[2026-05-11]
      assert event.pay_date == ~D[2026-05-15]
      assert event.announced_date == ~D[2026-05-01]
      assert Decimal.equal?(event.amount, Decimal.new("0.25"))
      assert event.currency == "USD"
    end

    test "an earnings row maps expected_publish_date under announced_date" do
      body = fixture!("fund_report_earnings_calendar.json")

      assert {:ok, [event]} =
               Rest.get_corporate_events(@credentials,
                 symbol: "AAPL",
                 kind: :earnings,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert event.kind == :earnings
      assert event.announced_date == ~D[2026-02-05]
      assert event.ex_date == nil
      assert event.currency == "USD"
    end

    test "both calendars are read without a kind, each on its own request" do
      me = self()
      dividend_body = fixture!("fund_report_dividend_calendar.json")

      plug = fn conn ->
        send(me, {:request, conn.method, conn.request_path, conn.query_string})

        body =
          if conn.request_path == "/market-data/fundamentals/dividend-calendars/list" do
            dividend_body
          else
            fixture!("fund_report_earnings_calendar.json")
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end

      assert {:ok, events} =
               Rest.get_corporate_events(@credentials,
                 symbol: "AAPL",
                 plug: plug,
                 retry_attempts: 0
               )

      assert length(events) == 2
      assert Enum.sort(Enum.map(events, & &1.kind)) == [:dividend, :earnings]

      assert_receive {:request, "GET", "/market-data/fundamentals/dividend-calendars/list", q1}
      assert_receive {:request, "GET", "/market-data/fundamentals/earnings-calendars/list", q2}
      assert q1 =~ "symbol=AAPL"
      assert q2 =~ "symbol=AAPL"
    end
  end

  describe "get_filings/3" do
    # filings.md:164-205 — the list is under "filings", not "data".
    test "a filing maps title/url/publish_date, and the list is read from the filings key" do
      body = fixture!("fund_report_filings.json")

      assert {:ok, [filing]} =
               Rest.get_filings("AAPL", @credentials, plug: responding(body), retry_attempts: 0)

      assert filing.symbol == "AAPL"
      assert filing.title == "8-K | Apple Inc. (0000320193)"

      assert filing.url ==
               "https://www.sec.gov/Archives/edgar/data/0000320193/000032019325000071/aapl-20250731.htm"

      assert filing.filed_at == DateTime.new!(~D[2025-07-31], ~T[00:00:00], "Etc/UTC")
    end
  end

  describe "get_news/2" do
    # news-summary.md:195 — the vendor's own worked SSE example stream, verbatim.
    test "concatenates the text chunks and takes the id from the meta event's convId" do
      events = fixture!("fund_report_news_sse.json")

      assert {:ok, [item]} =
               Rest.get_news(@credentials,
                 symbols: ["AAPL", "GOOG"],
                 plug: sse_responding(events),
                 retry_attempts: 0
               )

      assert item.id == "451107711450219"
      assert item.summary == "Hi, I'm Wally and I'll help you with this question"
      assert item.source == "webull"
      assert item.symbols == ["AAPL", "GOOG"]
    end

    test "sends symbols under the venue's nested category_symbols shape" do
      me = self()
      events = fixture!("fund_report_news_sse.json")

      assert {:ok, _news} =
               Rest.get_news(@credentials,
                 symbols: ["AAPL", "GOOG"],
                 lang: "en",
                 plug: sse_capturing(events, me),
                 retry_attempts: 0
               )

      assert_receive {:request, "POST", path, _query, raw}
      assert path == "/market-data/news/summaries/get"
      body = Jason.decode!(raw)

      assert body["category_symbols"] == [
               %{"category" => "US_STOCK", "symbols" => ["AAPL", "GOOG"]}
             ]

      assert body["lang"] == "en"
    end
  end

  # =========================================================================================
  # Screeners and futures reference data
  # =========================================================================================

  describe "get_screener/3 \"gainers_losers\" — vendor field-example fixture" do
    # `get-gainers-losers.md` documents no single example RESPONSE, only a per-field
    # `example` on each of the seventeen properties of `ScreenerStockVo`. This fixture is
    # every one of those per-field examples assembled into one row — no example invented
    # to agree with the code.
    test "decodes every field, keeps the venue's rank, and asserts each value" do
      fixture = fixture!("screener_gainers_losers.json")
      me = self()

      assert {:ok, [result]} =
               Rest.get_screener("gainers_losers", @credentials,
                 plug: capturing(fixture, me),
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", path, query, _raw}
      assert path == "/market-data/screeners/gainers-losers/list"
      # Required parameters go with the venue's own documented defaults
      # (`get-gainers-losers.md` parameters: `rank_type` default `DAY_1`, `sort_by`
      # default `CHANGE_RATIO`).
      assert query =~ "rank_type=DAY_1"
      assert query =~ "sort_by=CHANGE_RATIO"
      assert query =~ "category=US_STOCK"

      [row] = fixture
      assert result.symbol == row["symbol"]
      assert result.screener == "gainers_losers"
      assert result.rank == 1
      assert result.venue_time == nil
      assert result.provider == :webull
      assert result.metrics["instrument_id"] == row["instrument_id"]
      assert result.metrics["name"] == row["name"]
      assert result.metrics["exchange_code"] == row["exchange_code"]
      assert result.metrics["currency_code"] == row["currency_code"]

      for field <- ~w(pre_close open high low close price change change_ratio volume
                      turnover turnover_rate market_value amplitude relative_volume_10d) do
        assert Decimal.equal?(Decimal.new(result.metrics[field]), Decimal.new(row[field])),
               "#{field} did not round-trip: #{inspect(result.metrics[field])}"
      end
    end

    test "a caller's own rank_type and direction win over the venue's default" do
      me = self()

      assert {:ok, _rows} =
               Rest.get_screener("gainers_losers", @credentials,
                 rank_type: "WEEK_52",
                 sort_by: "VOLUME",
                 direction: "ASC",
                 plug: capturing([], me),
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", _path, query, _raw}
      assert query =~ "rank_type=WEEK_52"
      assert query =~ "sort_by=VOLUME"
      assert query =~ "direction=ASC"
    end
  end

  describe "get_screener/3 \"top_actives\" — vendor field-example fixture" do
    # `get-top-active.md:51-57` documents `rank_type` defaulting to `VOLUME`, distinct
    # from `gainers_losers`'s `DAY_1`.
    test "defaults rank_type to VOLUME and decodes the documented fields" do
      fixture = fixture!("screener_top_actives.json")
      me = self()

      assert {:ok, [result]} =
               Rest.get_screener("top_actives", @credentials,
                 plug: capturing(fixture, me),
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", path, query, _raw}
      assert path == "/market-data/screeners/top-actives/list"
      assert query =~ "rank_type=VOLUME"
      assert query =~ "category=US_STOCK"

      [row] = fixture
      assert result.symbol == row["symbol"]
      assert result.rank == 1

      assert Decimal.equal?(
               Decimal.new(result.metrics["relative_volume_10d"]),
               Decimal.new("11.91")
             )

      assert Decimal.equal?(Decimal.new(result.metrics["volume"]), Decimal.new(row["volume"]))
    end

    # `get-top-active.md` documents `sort_by` as a fourth query parameter (default
    # `VOLUME`) alongside `category`, `rank_type` and `direction` — fixed in `rest.ex`'s
    # `@screeners` map, which used to allow only `[:rank_type, :direction]`.
    test "sort_by reaches the request" do
      me = self()

      assert {:ok, _rows} =
               Rest.get_screener("top_actives", @credentials,
                 sort_by: "TURNOVER",
                 plug: capturing([], me),
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", _path, query, _raw}
      assert query =~ "sort_by=TURNOVER"
    end
  end

  describe "get_screener/3 \"week52_high_low\" — vendor field-example fixture" do
    test "requires rank_type (no documented default) and decodes the documented fields" do
      fixture = fixture!("screener_week52.json")
      me = self()

      exploding = fn _conn -> raise "must not guess a rank_type this endpoint never defaulted" end

      assert {:error, :rank_type_required} =
               Rest.get_screener("week52_high_low", @credentials,
                 plug: exploding,
                 retry_attempts: 0
               )

      assert {:ok, [result]} =
               Rest.get_screener("week52_high_low", @credentials,
                 rank_type: "NEW_HIGH",
                 plug: capturing(fixture, me),
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", path, query, _raw}
      assert path == "/market-data/screeners/week52-high-low/list"
      assert query =~ "rank_type=NEW_HIGH"

      [row] = fixture
      assert result.symbol == row["symbol"]
      assert result.rank == 1

      assert Decimal.equal?(
               Decimal.new(result.metrics["price_52w"]),
               Decimal.new(row["price_52w"])
             )

      assert Decimal.equal?(
               Decimal.new(result.metrics["change_ratio_52w"]),
               Decimal.new(row["change_ratio_52w"])
             )
    end

    # `get-week-52-high-low.md` documents `sort_by` alongside `rank_type`, `category` and
    # `direction` — fixed in `rest.ex`'s `@screeners` map.
    test "sort_by reaches the request" do
      me = self()

      assert {:ok, _rows} =
               Rest.get_screener("week52_high_low", @credentials,
                 rank_type: "NEW_HIGH",
                 sort_by: "YIELD",
                 plug: capturing([], me),
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", _path, query, _raw}
      assert query =~ "sort_by=YIELD"
    end
  end

  describe "get_screener/3 \"high_dividend_ranks\" — vendor field-example fixture" do
    test "decodes the documented fields with no rank_type at all" do
      fixture = fixture!("screener_high_dividend.json")
      me = self()

      assert {:ok, [result]} =
               Rest.get_screener("high_dividend_ranks", @credentials,
                 plug: capturing(fixture, me),
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", path, query, _raw}
      assert path == "/market-data/screeners/high-dividend-ranks/list"
      refute query =~ "rank_type"

      [row] = fixture
      assert result.symbol == row["symbol"]
      assert result.rank == 1
      assert Decimal.equal?(Decimal.new(result.metrics["yield"]), Decimal.new(row["yield"]))
      assert Decimal.equal?(Decimal.new(result.metrics["dividend"]), Decimal.new(row["dividend"]))
      assert result.metrics["ex_date"] == row["ex_date"]
    end

    # `get-high-dividend.md` documents `sort_by` (default `YIELD`) alongside `category`
    # and `direction` — fixed in `rest.ex`'s `@screeners` map.
    test "sort_by reaches the request" do
      me = self()

      assert {:ok, _rows} =
               Rest.get_screener("high_dividend_ranks", @credentials,
                 sort_by: "DIVIDEND",
                 plug: capturing([], me),
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", _path, query, _raw}
      assert query =~ "sort_by=DIVIDEND"
    end
  end

  describe "get_screener/3 \"market_sectors\" (plural, /list) — vendor field-example fixture" do
    test "sends agg_type not sort_by, and decodes the nested envelope" do
      fixture = fixture!("screener_market_sectors.json")
      me = self()

      # `market_sectors` is paginated; the fixture's own `pagination_key` is stripped from
      # what the plug serves so this single fixture page reads as the last page —
      # pagination itself is exercised separately below.
      assert {:ok, [result]} =
               Rest.get_screener("market_sectors", @credentials,
                 agg_type: "VOLUME",
                 period: "MO1",
                 plug: capturing(Map.delete(fixture, "pagination_key"), me),
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", path, query, _raw}
      assert path == "/market-data/screeners/market-sectors/list"
      assert query =~ "agg_type=VOLUME"
      assert query =~ "period=MO1"
      refute query =~ "sort_by"

      [sector] = fixture["data"]
      assert result.symbol == sector["name"]
      assert result.rank == 1

      assert Decimal.equal?(
               Decimal.new(result.metrics["change_ratio"]),
               Decimal.new(sector["change_ratio"])
             )

      assert Decimal.equal?(
               Decimal.new(result.metrics["market_value"]),
               Decimal.new(sector["market_value"])
             )

      assert result.metrics["data"] == sector["data"]
    end
  end

  describe "get_screener/3 \"market_sector\" (singular, /get) — vendor field-example fixture" do
    test "sends sort_by not agg_type, requires sector_id, and decodes the sector's stock rows" do
      fixture = fixture!("screener_market_sector_detail.json")
      me = self()

      # `market_sector` is paginated too; strip the fixture's own `pagination_key` so this
      # single fixture page reads as the last page (pagination is exercised separately
      # below).
      assert {:ok, [result]} =
               Rest.get_screener("market_sector", @credentials,
                 sector_id: "6391",
                 sort_by: "VOLUME",
                 plug: capturing(Map.delete(fixture, "pagination_key"), me),
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", path, query, _raw}
      assert path == "/market-data/screeners/market-sectors/get"
      assert query =~ "sector_id=6391"
      assert query =~ "sort_by=VOLUME"
      refute query =~ "agg_type"

      [stock_row] = fixture["data"]
      assert result.symbol == stock_row["symbol"]
      assert result.rank == 1
      assert Decimal.equal?(Decimal.new(result.metrics["price"]), Decimal.new(stock_row["price"]))

      assert Decimal.equal?(
               Decimal.new(result.metrics["market_value"]),
               Decimal.new(stock_row["market_value"])
             )
    end

    test "market_sectors and market_sector both follow the fixture's own pagination_key, bounded" do
      for name <- ["market_sectors", "market_sector"] do
        base_fixture =
          if name == "market_sectors",
            do: fixture!("screener_market_sectors.json"),
            else: fixture!("screener_market_sector_detail.json")

        plug = fn conn ->
          body =
            if String.contains?(conn.query_string || "", "pagination_key=") do
              Map.delete(base_fixture, "pagination_key")
            else
              base_fixture
            end

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, Jason.encode!(body))
        end

        assert {:ok, [_first, _second]} =
                 Rest.get_screener(name, @credentials,
                   sector_id: "6391",
                   plug: plug,
                   retry_attempts: 0
                 )
      end
    end
  end

  describe "list_futures_contracts/2 — vendor field-example fixture" do
    test "decodes the documented FuturesInstrumentVo fields, including the integer field" do
      fixture = fixture!("futures_contracts.json")
      me = self()

      assert {:ok, [row]} =
               Rest.list_futures_contracts(@credentials,
                 symbols: ["ESZ5"],
                 plug: capturing(fixture, me),
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", path, query, _raw}
      assert path == "/trading/instruments/futures/contracts/list"
      assert query =~ "symbols=ESZ5"
      assert query =~ "category=US_FUTURES"
      refute query =~ "status="

      [fixture_row] = fixture
      assert row["symbol"] == fixture_row["symbol"]
      assert row["instrument_id"] == fixture_row["instrument_id"]
      assert row["exchange_code"] == fixture_row["exchange_code"]
      assert row["code"] == fixture_row["code"]
      assert row["name"] == fixture_row["name"]
      # `product_class_id` is `"type": "integer"` in `futures-instrument-list.md`'s
      # schema — unlike every screener field above, which are all `"type": "string"`.
      assert row["product_class_id"] == 2
      assert is_integer(row["product_class_id"])
      assert row["product_class_name"] == fixture_row["product_class_name"]
      assert row["status"] == fixture_row["status"]
      assert row["contract_type"] == fixture_row["contract_type"]
      assert row["settlement"] == fixture_row["settlement"]
    end

    test "a code alone satisfies symbols_or_code, and no status filter is sent unasked" do
      me = self()

      assert {:ok, []} =
               Rest.list_futures_contracts(@credentials,
                 code: "ES",
                 plug: capturing([], me),
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", _path, query, _raw}
      assert query =~ "code=ES"
      refute query =~ "status="
    end

    test "neither symbols nor code is refused before a request is made" do
      exploding = fn _conn -> raise "must not request with neither symbols nor code" end

      assert {:error, :symbols_or_code_required} =
               Rest.list_futures_contracts(@credentials, plug: exploding, retry_attempts: 0)
    end
  end

  describe "list_futures_product_classes/2 — vendor field-example fixture" do
    test "takes only category and decodes the two documented fields" do
      fixture = fixture!("futures_product_classes.json")
      me = self()

      assert {:ok, [row]} =
               Rest.list_futures_product_classes(@credentials,
                 plug: capturing(fixture, me),
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", path, query, _raw}
      assert path == "/trading/instruments/futures/product-classes/list"
      assert query =~ "category=US_FUTURES"

      [fixture_row] = fixture
      assert row["product_class_id"] == fixture_row["product_class_id"]
      assert is_integer(row["product_class_id"])
      assert row["product_class_name"] == fixture_row["product_class_name"]
    end
  end

  # =========================================================================================
  # Event-contract reference data and options
  # =========================================================================================

  describe "list_event_categories/2 — event-categories-list.md" do
    test "returns the venue's own category rows, and takes no parameters" do
      me = self()
      body = fixture!("event_categories.json")

      assert {:ok, [category]} =
               Rest.list_event_categories(@credentials,
                 plug: capturing(body, me),
                 retry_attempts: 0
               )

      # event-categories-list.md:150-165
      assert category["category_id"] == 1
      assert category["category_code"] == "ECONOMICS"
      assert category["category_name"] == "Economics"

      assert_receive {:request, "GET", "/trading/instruments/event-contracts/categories/list",
                      query, _raw}

      assert query == ""
    end
  end

  describe "list_event_series/2 — event-series-list.md" do
    test "returns rows and the page's own pagination_key" do
      me = self()
      body = fixture!("event_series.json")

      assert {:ok, %{rows: [series], pagination_key: pagination_key}} =
               Rest.list_event_series(@credentials,
                 category: "ECONOMICS",
                 symbols: ["KXRATECUTCOUNT", "KXFEDDECISION"],
                 pagination_key: "prior-page",
                 plug: capturing(body, me),
                 retry_attempts: 0
               )

      # event-series-list.md:197-240
      assert series["category"] == "ECONOMICS"
      assert series["series_id"] == "151750"
      assert series["symbol"] == "KXRATECUTCOUNT"
      assert series["name"] == "Number of Rate Cuts"
      assert series["frequency"] == "ANNUAL"
      assert pagination_key == "eyJ2IjoxLCJsYXN0SWQiOiI5MTMyNDQ3NjkiLCJwYWdlSW===="

      assert_receive {:request, "GET", "/trading/instruments/event-contracts/series/list", query,
                      _raw}

      # event-series-list.md:36-75 — category, symbols (comma-joined), pagination_key
      assert query =~ "category=ECONOMICS"
      assert query =~ "symbols=KXRATECUTCOUNT%2CKXFEDDECISION"
      assert query =~ "pagination_key=prior-page"
    end
  end

  describe "list_event_events/2 — event-events-list.md" do
    test "series_symbol is required and refused before any request" do
      assert {:error, :series_symbol_required} = Rest.list_event_events(@credentials, [])
    end

    test "returns the venue's own event rows and sends the filters given" do
      me = self()
      body = fixture!("event_events.json")

      assert {:ok, [event]} =
               Rest.list_event_events(@credentials,
                 series_symbol: "KXGDP",
                 symbols: ["KXGDP-27JAN30"],
                 status: "INACTIVE",
                 plug: capturing(body, me),
                 retry_attempts: 0
               )

      # event-events-list.md:187-230
      assert event["series_id"] == "151950"
      assert event["symbol"] == "KXGDP-27JAN30"
      assert event["name"] == "US GDP growth in Q4 2026?"
      assert event["status"] == "inactive"
      assert event["short_name"] == "In Q4 2026"
      assert event["mutually_exclusive"] == false

      assert_receive {:request, "GET", "/trading/instruments/event-contracts/events/list", query,
                      _raw}

      # event-events-list.md:36-68 — series_symbol (required), symbols, status
      assert query =~ "series_symbol=KXGDP"
      assert query =~ "symbols=KXGDP-27JAN30"
      assert query =~ "status=INACTIVE"
    end
  end

  describe "list_event_markets/2 — event-market-list.md" do
    test "returns rows and pagination_key, sending series/event/date filters" do
      me = self()
      body = fixture!("event_markets.json")

      assert {:ok, %{rows: [market], pagination_key: pagination_key}} =
               Rest.list_event_markets(@credentials,
                 series_symbol: "KXRATECUTCOUNT",
                 event_symbol: "KXRATECUTCOUNT-26DEC31",
                 symbols: ["KXRATECUTCOUNT-25DEC31-T3"],
                 expiring_after: ~D[2026-12-31],
                 pagination_key: "prior-page",
                 plug: capturing(body, me),
                 retry_attempts: 0
               )

      # event-market-list.md:218-314
      assert market["series_id"] == "151750"
      assert market["series_symbol"] == "KXRATECUTCOUNT"
      assert market["event_symbol"] == "KXRATECUTCOUNT-26DEC31"
      assert market["instrument_id"] == "502257268"
      assert market["symbol"] == "KXRATECUTCOUNT-25DEC31-T3"
      assert market["name"] == "Will the Fed cut rates 3 times?"
      assert market["status"] == "LISTING"
      assert market["tradable_status"] == "NT"
      assert pagination_key == "eyJ2IjoxLCJsYXN0SWQiOiI5MTMyNDQ3NjkiLCJwYWdlSW===="

      assert_receive {:request, "GET", "/trading/instruments/event-contracts/markets/list", query,
                      _raw}

      # event-market-list.md:36-84
      assert query =~ "series_symbol=KXRATECUTCOUNT"
      assert query =~ "event_symbol=KXRATECUTCOUNT-26DEC31"
      assert query =~ "symbols=KXRATECUTCOUNT-25DEC31-T3"
      assert query =~ "expiration_date_after=2026-12-31"
      assert query =~ "pagination_key=prior-page"
    end
  end

  describe "get_event_trades/3 — event-tick.md" do
    test "keeps both prices and the venue's own side, and sends the count filter" do
      me = self()
      body = fixture!("event_trades.json")

      assert {:ok, [tick]} =
               Rest.get_event_trades("KXCPI-26JAN-T0.3", @credentials,
                 limit: 30,
                 plug: capturing(body, me),
                 retry_attempts: 0
               )

      # event-tick.md:209-238
      assert tick["time"] == "1772730554000"
      assert tick["yes_price"] == "0.05"
      assert tick["no_price"] == "0.95"
      assert tick["volume"] == "1.0"
      assert tick["side"] == "no"
      assert tick["trade_id"] == "604d16d9-9000-4266-68f9-1ec898e2acf6"

      assert_receive {:request, "GET", "/market-data/event-contracts/ticks/list", query, _raw}
      # event-tick.md:36-69 — symbol, category (hard-coded US_EVENT), count
      assert query =~ "symbol=KXCPI-26JAN-T0.3"
      assert query =~ "category=US_EVENT"
      assert query =~ "count=30"
    end
  end

  describe "get_event_order_book/3 — event-depth.md" do
    test "returns four books and the venue's own quote_time, sending the depth filter" do
      me = self()
      body = fixture!("event_order_book.json")

      assert {:ok, book} =
               Rest.get_event_order_book("KXCPI-26JAN-T0.3", @credentials,
                 depth: 10,
                 plug: capturing(body, me),
                 retry_attempts: 0
               )

      # event-depth.md:187-302
      assert book.symbol == "KXCPI-26JAN-T0.3"
      assert book.quote_time == 1_768_872_168_870
      assert book.yes_bids == [%{"price" => "0.13", "size" => "543"}]
      assert book.yes_asks == [%{"price" => "0.13", "size" => "543"}]
      assert book.no_bids == [%{"price" => "0.13", "size" => "543"}]
      assert book.no_asks == [%{"price" => "0.13", "size" => "543"}]

      assert_receive {:request, "GET", "/market-data/event-contracts/depths/list", query, _raw}
      # event-depth.md:36-67 — symbol, category (hard-coded US_EVENT), depth
      assert query =~ "symbol=KXCPI-26JAN-T0.3"
      assert query =~ "category=US_EVENT"
      assert query =~ "depth=10"
    end
  end

  describe "get_option_chain/3 and get_option_expirations/3 — option-contract-list.md" do
    test "the chain carries the venue's documented contract at its expiry and strike" do
      me = self()
      body = fixture!("option_contract_list.json")

      assert {:ok, chain} =
               Rest.get_option_chain("AAPL", @credentials,
                 expiry: ~D[2025-06-20],
                 strike: Decimal.new("150"),
                 plug: capturing(body, me),
                 retry_attempts: 0
               )

      assert %Types.OptionChain{} = chain
      call = chain.expiries[~D[2025-06-20]][Decimal.new("150.0")].call

      # option-contract-list.md:293-382
      assert call.venue_symbol == "AAPL250620C00150000"
      assert call.right == :call
      assert Decimal.equal?(call.strike, Decimal.new("150.0"))
      assert call.expiry == ~D[2025-06-20]
      assert Decimal.equal?(call.multiplier, Decimal.new("100"))
      assert call.settlement_type == "PHYSICAL"
      assert call.expiration_type == "MONTHLY"
      assert chain.expiries[~D[2025-06-20]][Decimal.new("150.0")].put == nil
      assert chain.underlying_price == nil

      assert_receive {:request, "GET", "/trading/instruments/options/contracts/list", query, _raw}

      # option-contract-list.md:60-148 — underlying_symbols (plural), start_date,
      # strike_price_gte/_lte as a range pinned to one value
      assert query =~ "underlying_symbols=AAPL"
      assert query =~ "start_date=2025-06-20"
      assert query =~ "strike_price_gte=150"
      assert query =~ "strike_price_lte=150"
    end

    test "expirations are the distinct expiries on the venue's own contracts" do
      body = fixture!("option_contract_list.json")

      assert {:ok, [~D[2025-06-20]]} =
               Rest.get_option_expirations("AAPL", @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )
    end
  end

  # =========================================================================================
  # Streaming — HTTP subscribe/unsubscribe and the MQTT protobuf decoders
  # =========================================================================================

  describe "Subscription.subscribe/3 — subscribe.md's own documented request, and where the wire diverges from it" do
    test "session_id and symbols match the vendor's example; sub_types/category/grab diverge exactly as subscription.ex records" do
      fixture = fixture!("stream_subscribe_request.json")
      response = fixture!("stream_subscribe_response.json")
      me = self()

      assert :ok =
               Subscription.subscribe(fixture["session_id"], fixture["symbols"],
                 credentials: @credentials,
                 plug: capturing(response, me),
                 retry_attempts: 0
               )

      assert_receive {:request, "POST", "/market-data/streaming/subscribe", _query, raw}
      body = Jason.decode!(raw)

      # subscribe.md:148-151 / :153-166 — carried through unchanged.
      assert body["session_id"] == fixture["session_id"]
      assert body["symbols"] == fixture["symbols"]

      # Divergence (a) — subscription.ex's own moduledoc: uppercase, and TICK joins the
      # pair the venue actually accepted (issue #19). subscribe.md:176-191's own example
      # is ["SNAPSHOT"].
      # `TICK` requested again (dp_exchange_webull issue #7): the venue accepted it in #40's
      # measurement, so asking costs nothing, and a tick that arrives is a trade delivered.
      assert body["sub_types"] == ["SNAPSHOT", "QUOTE", "TICK"]
      refute body["sub_types"] == fixture["sub_types"]

      # Divergence (b) — subscription.ex: US_CRYPTO, confirmed live (issue #19), against
      # subscribe.md:167-175's documented enum of US_STOCK/US_ETF only.
      assert body["category"] == "US_CRYPTO"
      refute body["category"] == fixture["category"]

      # Already-recorded third divergence — subscription.ex: `grab` is required by
      # subscribe.md:139-145/193-197 and is never sent; months of live SNAPSHOT/QUOTE
      # subscribes worked without it (issue #19), so guessing a value is refused.
      refute Map.has_key?(body, "grab")
      refute Map.has_key?(body, "depth")
      refute Map.has_key?(body, "overnight_required")
    end

    test "an empty symbol list is :ok without spending a call" do
      exploding = fn _conn -> raise "must not call the venue for zero symbols" end

      assert :ok =
               Subscription.subscribe("session-1", [],
                 credentials: @credentials,
                 plug: exploding,
                 retry_attempts: 0
               )
    end

    test "INVALID_SYMBOL names the offending symbols, converted back to canonical — issue #24" do
      rejection = fixture!("stream_invalid_symbol_rejection.json")

      assert {:error, {:invalid_symbols, symbols}} =
               Subscription.subscribe("session-1", ["BTC-USD", "ETH-USD"],
                 credentials: @credentials,
                 plug: responding(rejection, 417),
                 retry_attempts: 0
               )

      assert symbols == [
               SymbolFormat.to_canonical_symbol("GYENUSD"),
               SymbolFormat.to_canonical_symbol("GALAUSD")
             ]

      assert symbols == ["GYEN-USD", "GALA-USD"]
    end

    test "TOO_MANY_SYMBOLS_SUBSCRIPTION becomes :oversubscribed" do
      rejection = fixture!("stream_oversubscribed_rejection.json")

      assert {:error, :oversubscribed} =
               Subscription.subscribe("session-1", ["BTC-USD"],
                 credentials: @credentials,
                 plug: responding(rejection, 417),
                 retry_attempts: 0
               )
    end

    test "INVALID_SESSION carries the dead session id out of the venue's prose — dp-exchange-core issue #30" do
      rejection = fixture!("stream_invalid_session_rejection.json")

      assert {:error, {:invalid_session, "3c4fdabd54097164fbd0f66d95743aae"}} =
               Subscription.subscribe("session-1", ["BTC-USD"],
                 credentials: @credentials,
                 plug: responding(rejection, 417),
                 retry_attempts: 0
               )
    end
  end

  describe "Subscription.unsubscribe/3 — unsubscribe.md's own documented request, same divergences" do
    test "session_id and symbols match the vendor's example; sub_types/category diverge the same way subscribe does" do
      fixture = fixture!("stream_unsubscribe_request.json")
      response = fixture!("stream_unsubscribe_response.json")
      me = self()

      assert :ok =
               Subscription.unsubscribe(fixture["session_id"], fixture["symbols"],
                 credentials: @credentials,
                 plug: capturing(response, me),
                 retry_attempts: 0
               )

      assert_receive {:request, "POST", "/market-data/streaming/unsubscribe", _query, raw}
      body = Jason.decode!(raw)

      assert body["session_id"] == fixture["session_id"]
      assert body["symbols"] == fixture["symbols"]
      # `TICK` requested again (dp_exchange_webull issue #7): the venue accepted it in #40's
      # measurement, so asking costs nothing, and a tick that arrives is a trade delivered.
      assert body["sub_types"] == ["SNAPSHOT", "QUOTE", "TICK"]
      refute body["sub_types"] == fixture["sub_types"]
      assert body["category"] == "US_CRYPTO"
      refute body["category"] == fixture["category"]
    end
  end

  describe "QuoteProto.decode_snapshot/1 against the schema-derived Snapshot fixture" do
    test "every field decoded matches the fixture, proving the field-number mapping" do
      fixture = fixture!("stream_snapshot_fields.json")
      payload = encode_snapshot(fixture)

      assert {:ok, snapshot} = QuoteProto.decode_snapshot(payload)
      assert snapshot.symbol == fixture["basic"]["symbol"]
      assert snapshot.price == fixture["price"]
      assert snapshot.volume == fixture["volume"]
      # trade_time (field 2) preferred over Basic.timestamp (field 3) —
      # `QuoteProto.decode_snapshot/1`'s own comment.
      assert snapshot.timestamp == fixture["trade_time"]
    end
  end

  describe "QuoteProto.decode_tick/1 against the schema-derived Tick fixture" do
    test "every field decoded matches the fixture" do
      fixture = fixture!("stream_tick_fields.json")
      payload = encode_tick(fixture)

      assert {:ok, tick} = QuoteProto.decode_tick(payload)
      assert tick.symbol == fixture["basic"]["symbol"]
      assert tick.price == fixture["price"]
      assert tick.volume == fixture["volume"]
      assert tick.side == fixture["side"]
      assert tick.timestamp == fixture["time"]
    end
  end

  describe "QuoteProto.decode_quote/1 against the schema-derived Quote fixture" do
    test "the first level of each side is read, including through a full AskBid with order/broker" do
      fixture = fixture!("stream_quote_fields.json")
      payload = encode_quote(fixture)
      [first_ask | _rest_asks] = fixture["asks"]
      [first_bid | _rest_bids] = fixture["bids"]

      assert {:ok, quote_msg} = QuoteProto.decode_quote(payload)
      assert quote_msg.symbol == fixture["basic"]["symbol"]
      assert quote_msg.ask == first_ask["price"]
      assert quote_msg.ask_size == first_ask["size"]
      assert quote_msg.bid == first_bid["price"]
      assert quote_msg.bid_size == first_bid["size"]
      assert quote_msg.timestamp == fixture["basic"]["timestamp"]
    end
  end
end
