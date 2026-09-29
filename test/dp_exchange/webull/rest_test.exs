defmodule DpExchange.Webull.RestTest do
  use ExUnit.Case, async: true

  alias DpExchange.Core.{Config, Instrument, Types}
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

  @credentials %{app_key: "test-key", app_secret: "test-secret"}

  defp responding(body, status \\ 200) do
    fn conn -> Req.Test.json(%{conn | status: status}, body) end
  end

  describe "every call is signed, because this venue has no anonymous endpoint" do
    test "the signing headers reach the wire even for market data" do
      plug = fn conn ->
        assert Plug.Conn.get_req_header(conn, "x-app-key") == ["test-key"]
        assert [_signature] = Plug.Conn.get_req_header(conn, "x-signature")
        assert Plug.Conn.get_req_header(conn, "x-signature-algorithm") == ["HMAC-SHA1"]

        Req.Test.json(conn, [%{"price" => "1", "time" => 1_787_936_147_000}])
      end

      assert {:ok, _quote} =
               Rest.get_price("BTC-USD", @credentials, plug: plug, retry_attempts: 0)
    end

    test "without credentials it refuses rather than sending an unsigned request" do
      assert {:error, {:missing_credentials, :webull}} =
               Rest.get_price("BTC-USD", %{}, retry_attempts: 0)
    end
  end

  describe "get_price/3" do
    @snapshot [%{"symbol" => "BTCUSD", "price" => "77845.79", "time" => 1_787_936_147_000}]

    test "returns a Quote with the canonical symbol and a Decimal price" do
      assert {:ok, %Types.Quote{} = quote_struct} =
               Rest.get_price("BTC-USD", @credentials,
                 plug: responding(@snapshot),
                 retry_attempts: 0
               )

      assert quote_struct.symbol == "BTC-USD"
      assert Decimal.equal?(quote_struct.price, Decimal.new("77845.79"))
      assert quote_struct.provider == :webull
    end

    test "volume is nil, because this venue reports none — not zero" do
      # Zero would look like a real measurement of no trading.
      assert {:ok, quote_struct} =
               Rest.get_price("BTC-USD", @credentials,
                 plug: responding(@snapshot),
                 retry_attempts: 0
               )

      assert quote_struct.volume == nil
    end

    test "accepts any of the venue's three spellings for the last price" do
      for key <- ["price", "lastPrice", "last_trade_price"] do
        body = [%{key => "1.5", "time" => 1_787_936_147_000}]

        assert {:ok, quote_struct} =
                 Rest.get_price("BTC-USD", @credentials,
                   plug: responding(body),
                   retry_attempts: 0
                 )

        assert Decimal.equal?(quote_struct.price, Decimal.new("1.5"))
      end
    end

    test "a non-numeric price string refuses the quote rather than raising or delivering price: nil" do
      # Filed as a live bug: a delisted crypto pair returns the literal string "null" for
      # a price field, and Decimal.new/1 raised. The fix must not trade that crash for a
      # Quote whose required :price is silently nil, which is the same substitution
      # wearing a quieter shape.
      body = [%{"price" => "null", "time" => 1_787_936_147_000}]

      assert {:error, {:invalid_decimal, :price, "null"}} =
               Rest.get_price("BTC-USD", @credentials, plug: responding(body), retry_attempts: 0)
    end

    test "an empty-string price refuses the quote" do
      body = [%{"price" => "", "time" => 1_787_936_147_000}]

      assert {:error, :unexpected_response_shape} =
               Rest.get_price("BTC-USD", @credentials, plug: responding(body), retry_attempts: 0)
    end

    for nan_or_inf <- ["NaN", "Inf", "-Inf"] do
      test "a #{nan_or_inf} price refuses the quote rather than admitting it as real" do
        # Decimal.parse/1 alone was not a sufficient guard for the "null" fix above:
        # #{unquote(nan_or_inf)} fully parses, and would have flowed through as a real
        # Quote.price without the nan?/inf? check.
        body = [%{"price" => unquote(nan_or_inf), "time" => 1_787_936_147_000}]

        assert {:error, {:invalid_decimal, :price, unquote(nan_or_inf)}} =
                 Rest.get_price("BTC-USD", @credentials,
                   plug: responding(body),
                   retry_attempts: 0
                 )
      end
    end

    test "a response with no venue timestamp is nil, and never the local clock" do
      # "Rather than substituting now" is the guarantee, and it is now asserted directly
      # instead of inferred from an error — which could not tell a `nil` from a substitution
      # in the first place. `Core.Types.Quote` enforces `[:symbol, :price, :observed_at,
      # :provider]`, so refusing threw away a real, guarded traded price over an optional
      # field. `top_of_book_time/1` has always answered this way for the sibling call on the
      # same endpoint.
      body = [%{"price" => "1"}]

      assert {:ok, quoted} =
               Rest.get_price("BTC-USD", @credentials, plug: responding(body), retry_attempts: 0)

      assert Decimal.equal?(quoted.price, Decimal.new("1"))
      assert quoted.venue_time == nil
      assert quoted.observed_at
      refute quoted.venue_time == quoted.observed_at
    end

    test "a response with no price is an unreadable snapshot, not a nil-priced quote" do
      body = [%{"time" => 1_787_936_147_000}]

      assert {:error, :unexpected_response_shape} =
               Rest.get_price("BTC-USD", @credentials, plug: responding(body), retry_attempts: 0)
    end

    test "a 401 is a refusal carrying the venue's own message" do
      body = %{"code" => "AUTH_FAILED", "msg" => "signature mismatch"}

      assert {:refused, {:venue_error, 401, "signature mismatch"}} =
               Rest.get_price("BTC-USD", @credentials,
                 plug: responding(body, 401),
                 retry_attempts: 0
               )
    end

    test "400, 401 and 403 are told apart, because their remedies differ" do
      # The property the status exists for. All three are refusals — permanent for the
      # request as sent — and a caller does something different with each:
      #
      #   400 → fix the request; sending it again unchanged cannot work
      #   401 → refresh the token and call again, which is a different request
      #   403 → a person must change what this credential is entitled to
      #
      # Before this, all three arrived as `{:venue_error, message}` and were indistinguishable
      # unless the venue's prose happened to say. The clause that raises the refusal even
      # documents the 401 remedy — the code knew which status it had matched and then
      # discarded it.
      body = %{"msg" => "no"}

      assert {:refused, {:venue_error, 400, "no"}} =
               Rest.get_price("BTC-USD", @credentials,
                 plug: responding(body, 400),
                 retry_attempts: 0
               )

      assert {:refused, {:venue_error, 401, "no"}} =
               Rest.get_price("BTC-USD", @credentials,
                 plug: responding(body, 401),
                 retry_attempts: 0
               )

      assert {:refused, {:venue_error, 403, "no"}} =
               Rest.get_price("BTC-USD", @credentials,
                 plug: responding(body, 403),
                 retry_attempts: 0
               )
    end

    test "a 500 stays an error the caller may retry" do
      assert {:error, _reason} =
               Rest.get_price("BTC-USD", @credentials,
                 plug: responding(%{}, 500),
                 retry_attempts: 0
               )
    end
  end

  describe "get_historical_prices/5 with a forwarded `category: nil`" do
    # `case Keyword.get(opts, :category, "US_CRYPTO")` — `Keyword.get/3` only substitutes its
    # default for an ABSENT key, so a forwarded `category: nil` reached the `case` itself,
    # matched none of the named categories, and fell through to the `_stock` clause. A
    # caller who said nothing, on a package whose documented default is crypto, got EQUITY
    # bars for the same ticker.
    #
    # That is the substitution this family names first — a plausible value where the answer
    # should have been the default — and it does not surface as a failure: a stock and a
    # coin can share a symbol, and the bars that come back are real bars.
    defp path_recording(test_pid) do
      fn conn ->
        send(test_pid, {:path, conn.request_path})
        Req.Test.json(conn, [])
      end
    end

    test "is crypto, the documented default — not the stock branch" do
      Rest.get_historical_prices("BTC-USD", "1m", [], @credentials,
        category: nil,
        plug: path_recording(self()),
        retry_attempts: 0
      )

      assert_receive {:path, path}
      assert path =~ "/crypto/", "category: nil was routed to #{path}"
    end

    test "an unknown category still means stocks — only `nil` changed" do
      # The `_stock` catch-all is the package's own answer for a named category it does not
      # recognise, and that stays as it was. The fix is about "nothing was said", not about
      # what an unrecognised word means.
      Rest.get_historical_prices("AAPL", "1m", [], @credentials,
        category: "US_STOCK",
        plug: path_recording(self()),
        retry_attempts: 0
      )

      assert_receive {:path, path}
      assert path =~ "/stocks/"
    end
  end

  describe "get_historical_prices/5 — the nesting that once returned all-nil bars" do
    @groups [
      %{
        "symbol" => "BTCUSD",
        "result" => [
          %{
            "open" => "1",
            "high" => "2",
            "low" => "0.5",
            "close" => "1.5",
            "time" => 1_787_935_740_000
          },
          %{
            "open" => "2",
            "high" => "3",
            "low" => "1.5",
            "close" => "2.5",
            "time" => 1_787_935_680_000
          }
        ]
      }
    ]

    test "flattens each group's result rows" do
      # Mapping the row decoder over the GROUPS yields all-nil bars, which reads as "the
      # venue has no data" — exactly what happened before this was found.
      assert {:ok, bars} =
               Rest.get_historical_prices("BTC-USD", "1m", [], @credentials,
                 plug: responding(@groups),
                 retry_attempts: 0
               )

      assert length(bars) == 2
      assert Enum.all?(bars, &match?(%Decimal{}, &1.open))
    end

    test "a flat bar still decodes, in case the shape changes back" do
      flat = [
        %{
          "open" => "1",
          "high" => "2",
          "low" => "0.5",
          "close" => "1.5",
          "time" => 1_787_935_740_000
        }
      ]

      assert {:ok, [bar]} =
               Rest.get_historical_prices("BTC-USD", "1m", [], @credentials,
                 plug: responding(flat),
                 retry_attempts: 0
               )

      assert Decimal.equal?(bar.close, Decimal.new("1.5"))
    end

    test "bars come back oldest-first" do
      assert {:ok, [first, second]} =
               Rest.get_historical_prices("BTC-USD", "1m", [], @credentials,
                 plug: responding(@groups),
                 retry_attempts: 0
               )

      assert DateTime.compare(first.opened_at, second.opened_at) == :lt
    end

    test "a bar with no venue timestamp fails the whole call" do
      # The prior adapter ended its decoder with `|| DateTime.utc_now()`, so an undated bar
      # was stamped with the client's clock and became indistinguishable from a real one.
      body = [%{"result" => [%{"open" => "1", "close" => "1"}]}]

      assert {:error, :missing_venue_timestamp} =
               Rest.get_historical_prices("BTC-USD", "1m", [], @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )
    end

    test "a bar dated zero or earlier is refused, not opened in 1970" do
      # `DateTime.from_unix/2` answers `{:ok, ~U[1970-01-01 00:00:00Z]}` for 0 and a 1969
      # instant for negatives. Both are valid `DateTime`s, which is why they are the
      # dangerous case: `from_epoch/1`'s own comment called 1970 "loud", and it is not — a
      # consumer that logs or charts the timestamp shows 1970 and calls it data, and `0` is a
      # common venue sentinel for "unknown". The family settled this for level timestamps
      # ("an unreadable level timestamp does not become the epoch") and it holds here too.
      for bad <- [0, -1, "0"] do
        body = [
          %{
            "symbol" => "BTCUSD",
            "result" => [
              %{"open" => "1", "high" => "2", "low" => "1", "close" => "1", "time" => bad}
            ]
          }
        ]

        assert {:error, _reason} =
                 Rest.get_historical_prices("BTC-USD", "1m", [], @credentials,
                   plug: responding(body),
                   retry_attempts: 0
                 ),
               "a bar dated #{inspect(bad)} must be refused"
      end
    end

    test "bars carry no volume" do
      assert {:ok, [bar | _rest]} =
               Rest.get_historical_prices("BTC-USD", "1m", [], @credentials,
                 plug: responding(@groups),
                 retry_attempts: 0
               )

      assert bar.volume == nil
    end

    test "maps canonical widths to the venue's own timespan codes" do
      for {canonical, code} <- [{"1m", "M1"}, {"1h", "M60"}, {"2h", "M120"}, {"1d", "D"}] do
        plug = fn conn ->
          assert conn.query_string =~ "timespan=#{code}"
          Req.Test.json(conn, @groups)
        end

        assert {:ok, _bars} =
                 Rest.get_historical_prices("BTC-USD", canonical, [], @credentials,
                   plug: plug,
                   retry_attempts: 0
                 )
      end
    end

    test "a width the venue does not serve is an error, before any request" do
      # `1w` is served by the venue and deliberately excluded: a weekly bar's boundary
      # depends on the venue's week start, which nothing here can verify.
      for width <- ~w(12h 1w 3d) do
        assert {:error, {:unsupported_timeframe, ^width}} =
                 Rest.get_historical_prices("BTC-USD", width, [], @credentials, retry_attempts: 0)
      end
    end

    test "a range filters the bars here" do
      start = DateTime.from_unix!(1_787_935_700_000, :millisecond)

      assert {:ok, [bar]} =
               Rest.get_historical_prices("BTC-USD", "1m", [start: start], @credentials,
                 plug: responding(@groups),
                 retry_attempts: 0
               )

      assert bar.opened_at == DateTime.from_unix!(1_787_935_740_000, :millisecond)
    end
  end

  describe "epoch precision" do
    test "milliseconds and seconds are told apart by magnitude" do
      # Guessing wrong puts a 2026 bar in 1970 or in the year 58,000 — both loud, which is
      # why this is a threshold rather than a silent fallback.
      seconds = [%{"price" => "1", "time" => 1_787_936_147}]
      millis = [%{"price" => "1", "time" => 1_787_936_147_000}]

      assert {:ok, from_seconds} =
               Rest.get_price("BTC-USD", @credentials,
                 plug: responding(seconds),
                 retry_attempts: 0
               )

      assert {:ok, from_millis} =
               Rest.get_price("BTC-USD", @credentials,
                 plug: responding(millis),
                 retry_attempts: 0
               )

      assert from_seconds.venue_time.year == 2026
      assert from_millis.venue_time.year == 2026
    end

    test "an ISO-8601 timestamp is read too" do
      body = [%{"price" => "1", "time" => "2026-08-28T17:00:01Z"}]

      assert {:ok, quote_struct} =
               Rest.get_price("BTC-USD", @credentials, plug: responding(body), retry_attempts: 0)

      assert quote_struct.venue_time == ~U[2026-08-28 17:00:01Z]
    end

    test "an unparseable timestamp is nil, not a guess" do
      # Still not a guess: nothing is inferred from a string this package cannot read, and
      # the venue's field stays empty rather than being filled with an arrival time. What
      # changed is that an unreadable OPTIONAL field no longer discards the required one
      # beside it. `get_historical_prices/5` keeps refusing, because `Core.Types.Candle`
      # enforces `:opened_at` and a bar at an invented minute is a different kind of wrong.
      body = [%{"price" => "1", "time" => "whenever"}]

      assert {:ok, quoted} =
               Rest.get_price("BTC-USD", @credentials, plug: responding(body), retry_attempts: 0)

      assert quoted.venue_time == nil
      assert Decimal.equal?(quoted.price, Decimal.new("1"))
    end
  end

  describe "get_symbols/2" do
    test "returns canonical symbols, sorted and deduplicated" do
      body = [%{"symbol" => "BTCUSD"}, %{"symbol" => "ETHUSD"}, %{"symbol" => "BTCUSD"}]

      assert {:ok, ["BTC-USD", "ETH-USD"]} =
               Rest.get_symbols(@credentials, plug: responding(body), retry_attempts: 0)
    end

    test "rows with no symbol are skipped rather than becoming nil entries" do
      body = [%{"symbol" => "BTCUSD"}, %{"instrument_id" => "123"}]

      assert {:ok, ["BTC-USD"]} =
               Rest.get_symbols(@credentials, plug: responding(body), retry_attempts: 0)
    end
  end

  describe "list_instruments/2" do
    test "OC is :tradable; CO and NT are both :unknown; base/quote come from currency" do
      body = %{
        "data" => [
          %{"symbol" => "BTCUSD", "status" => "OC", "currency" => "USD"},
          %{"symbol" => "ALTUSD", "status" => "CO", "currency" => "USD"},
          %{"symbol" => "ETHBTC", "status" => "NT", "currency" => "BTC"}
        ]
      }

      assert {:ok, instruments} =
               Rest.list_instruments(@credentials, plug: responding(body), retry_attempts: 0)

      assert [
               %Instrument{symbol: "BTC-USD", base: "BTC", quote: "USD", status: :tradable},
               %Instrument{symbol: "ALT-USD", base: "ALT", quote: "USD", status: :unknown},
               %Instrument{symbol: "ETH-BTC", base: "ETH", quote: "BTC", status: :unknown}
             ] = instruments

      assert Enum.all?(instruments, &(&1.instrument == :spot))
    end

    test "an absent status is :unknown, never guessed tradable" do
      body = %{"data" => [%{"symbol" => "BTCUSD", "currency" => "USD"}]}

      assert {:ok, [%Instrument{status: :unknown}]} =
               Rest.list_instruments(@credentials, plug: responding(body), retry_attempts: 0)
    end

    test "a row whose symbol does not end in its own currency is dropped, not guessed" do
      body = %{
        "data" => [
          %{"symbol" => "BTCUSD", "status" => "OC", "currency" => "USD"},
          # `currency` here does not suffix `symbol` at all — nothing honest to strip.
          %{"symbol" => "BTCUSD", "status" => "OC", "currency" => "EUR"},
          # Degenerate: `symbol == currency` would leave an empty `base`.
          %{"symbol" => "USD", "status" => "OC", "currency" => "USD"}
        ]
      }

      assert {:ok, [%Instrument{symbol: "BTC-USD"}]} =
               Rest.list_instruments(@credentials, plug: responding(body), retry_attempts: 0)
    end

    test "a row with no currency at all is dropped rather than left with a nil quote" do
      body = %{"data" => [%{"symbol" => "BTCUSD", "status" => "OC"}]}

      assert {:ok, []} =
               Rest.list_instruments(@credentials, plug: responding(body), retry_attempts: 0)
    end

    test "US_STOCK and US_ETF are refused by name, not served" do
      assert {:error, {:unsupported_instrument_category, "US_STOCK"}} =
               Rest.list_instruments(@credentials, category: "US_STOCK", retry_attempts: 0)

      assert {:error, {:unsupported_instrument_category, "US_ETF"}} =
               Rest.list_instruments(@credentials, category: "US_ETF", retry_attempts: 0)
    end

    test "walks pagination_key to the end, across pages" do
      me = self()

      page1 = %{
        "data" => [%{"symbol" => "BTCUSD", "status" => "OC", "currency" => "USD"}],
        "pagination_key" => "next"
      }

      page2 = %{"data" => [%{"symbol" => "ALTUSD", "status" => "NT", "currency" => "USD"}]}

      plug = fn conn ->
        {:ok, _raw, conn} = Plug.Conn.read_body(conn)
        send(me, {:page, conn.query_string})

        body =
          if String.contains?(conn.query_string || "", "pagination_key="), do: page2, else: page1

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end

      assert {:ok, [%Instrument{symbol: "BTC-USD"}, %Instrument{symbol: "ALT-USD"}]} =
               Rest.list_instruments(@credentials, plug: plug, retry_attempts: 0)

      assert_receive {:page, first_query}
      refute String.contains?(first_query || "", "pagination_key=")
      assert_receive {:page, second_query}
      assert String.contains?(second_query, "pagination_key=next")
    end
  end

  describe "the environment reaches the request" do
    test "UAT sends to the UAT host, and signs that host" do
      plug = fn conn ->
        # The host is part of the signature, so it must be the host actually reached.
        assert Plug.Conn.get_req_header(conn, "host") == ["us-openapi-alb.uat.webullbroker.com"]
        Req.Test.json(conn, [%{"price" => "1", "time" => 1_787_936_147_000}])
      end

      assert {:ok, _quote} =
               Rest.get_price("BTC-USD", @credentials,
                 plug: plug,
                 environment: :uat,
                 retry_attempts: 0
               )
    end
  end

  describe "get_fees/2" do
    test "returns the published crypto spread, sourced and dated" do
      assert {:ok, fees} = Rest.get_fees(@credentials, [])
      assert Decimal.equal?(fees.crypto_spread_pct, Decimal.new("1.00"))
      assert fees.charged_by == "Webull Pay/Bakkt"
      assert fees.source == :published_rate
      assert fees.captured_at == ~D[2026-09-03]
    end

    test "answers without credentials, because it builds no request — regression for the 2026-09-06 gate" do
      assert {:ok, fees} = Rest.get_fees(%{}, [])
      assert fees.source == :published_rate
    end
  end

  describe "quantization/3" do
    @crypto_row %{
      "symbol" => "BTCUSD",
      "price_step" => "0.01",
      "lot_size" => "0.00000001",
      "min_trade_qty" => "0.0001",
      "max_trade_qty" => "1000",
      "min_trade_amt" => "1.00",
      "max_trade_amt" => "100000",
      "status" => "OC"
    }

    @stock_row %{
      "symbol" => "AAPL",
      "lot_size" => "1.0",
      "status" => "OC"
    }

    test "a crypto pair (dash in the symbol) reads all six fields" do
      assert {:ok, quantum} =
               Rest.quantization("BTC-USD", @credentials,
                 plug: responding(%{"data" => [@crypto_row]}),
                 retry_attempts: 0
               )

      assert Decimal.equal?(quantum.price_increment, Decimal.new("0.01"))
      assert Decimal.equal?(quantum.quantity_increment, Decimal.new("0.00000001"))
      assert Decimal.equal?(quantum.min_quantity, Decimal.new("0.0001"))
      assert Decimal.equal?(quantum.max_quantity, Decimal.new("1000"))
      assert Decimal.equal?(quantum.min_quote_size, Decimal.new("1.00"))
      assert Decimal.equal?(quantum.max_quote_size, Decimal.new("100000"))
      assert quantum.status == "OC"
    end

    test "a stock ticker (no dash) reads only lot_size — the venue's schema has nothing else" do
      assert {:ok, quantum} =
               Rest.quantization("AAPL", @credentials,
                 plug: responding(%{"data" => [@stock_row]}),
                 retry_attempts: 0
               )

      assert Decimal.equal?(quantum.quantity_increment, Decimal.new("1.0"))
      assert quantum.price_increment == nil
      assert quantum.min_quantity == nil
      assert quantum.max_quantity == nil
      assert quantum.min_quote_size == nil
      assert quantum.max_quote_size == nil
    end
  end

  describe "an envelope is never a row" do
    # `rows/1`'s bare-object clause caught envelopes too: `{"code": "200", "data": null}`
    # failed the list guard, landed on `%{} = body`, and came back as a one-row list whose
    # row WAS the envelope. Measured: `get_orders/2` answered a phantom
    # `%Order{id: nil, symbol: nil, …}`, `get_transfers/2` returned the envelope as a
    # transfer, and `get_positions/2` refused it as a malformed position.
    @empty_envelope %{"code" => "200", "msg" => "ok", "data" => nil}

    defp answering(body), do: fn conn -> Req.Test.json(conn, body) end

    test "data: null is no rows, on every endpoint that reads rows" do
      opts = [plug: answering(@empty_envelope), retry_attempts: 0, account_id: "acct"]

      assert {:ok, []} = Rest.get_orders(@credentials, opts)
      assert {:ok, []} = Rest.get_transfers(@credentials, opts)
      assert {:ok, []} = Rest.get_positions(@credentials, opts)
    end

    test "data: {object} is that object as one row, not its wrapper" do
      # `/trading/orders/get`-shaped rows: a GROUP — `{combo_type, orders: [leg]}`
      # (order-detail.md:163,182) — not a flat row. `rows/1`'s own unwrapping (a `data`
      # object becomes a one-element list) is the thing under test here; `to_order/1`'s own
      # group-vs-leg parsing is covered separately in `order_mapping_test.exs`.
      group = %{
        "combo_type" => "NORMAL",
        "orders" => [%{"client_order_id" => "c-1", "symbol" => "AAPL", "side" => "BUY"}]
      }

      envelope = %{"code" => "200", "data" => group}

      assert {:ok, [%{id: "c-1", symbol: "AAPL"}]} =
               Rest.get_orders(@credentials,
                 plug: answering(envelope),
                 retry_attempts: 0,
                 account_id: "acct"
               )
    end

    test "an order list with a row that cannot be read is refused, and names it" do
      # This asserted the row was DROPPED, on `to_watchlist/2`'s precedent. For orders that
      # is the dangerous direction: a list missing a working order reads as "nothing is
      # working there", and a caller reconciling from it may place the order again.
      rows = [
        %{"combo_type" => "NORMAL", "orders" => [%{"symbol" => "AAPL", "side" => "BUY"}]},
        %{
          "combo_type" => "NORMAL",
          "orders" => [%{"client_order_id" => "c-2", "side" => "SELL"}]
        }
      ]

      assert {:error, {:unreadable_orders, [nil]}} =
               Rest.get_orders(@credentials,
                 plug: answering(rows),
                 retry_attempts: 0,
                 account_id: "acct"
               )

      assert {:error, {:missing_required_field, :id}} =
               Rest.get_order(@credentials, "c-1",
                 plug:
                   answering(%{
                     "combo_type" => "NORMAL",
                     "orders" => [%{"symbol" => "AAPL"}]
                   }),
                 retry_attempts: 0,
                 account_id: "acct"
               )
    end

    test "a working multi-leg combo is not silently missing from the order list" do
      rows = [
        %{
          "client_order_id" => "oco-1",
          "combo_type" => "OCO",
          "orders" => [
            %{"client_order_id" => "oco-1a", "symbol" => "AAPL", "side" => "SELL"},
            %{"client_order_id" => "oco-1b", "symbol" => "AAPL", "side" => "SELL"}
          ]
        },
        %{
          "combo_type" => "NORMAL",
          "orders" => [%{"client_order_id" => "c-2", "side" => "SELL"}]
        }
      ]

      assert {:error, {:unreadable_orders, ["oco-1"]}} =
               Rest.get_orders(@credentials,
                 plug: answering(rows),
                 retry_attempts: 0,
                 account_id: "acct"
               )
    end
  end

  describe "a `data` that is present and not a list, an object or null is unreadable" do
    # `rows/1` used to fall through the same clause `null` takes for ANY value it could not
    # place — a string, a number, a boolean — and answer `{:ok, []}`, indistinguishable from
    # a genuine empty page. `get_orders/2`, `get_positions/2` and every list endpoint built
    # on `rows/1` then reported "no orders" / "no positions" from a response this package
    # never actually read. The family rule is fail closed, never substitute: `null` stays a
    # documented, deliberate "nothing here"; anything else under `data` is a shape this
    # package could not read and must say so.
    @unreadable_envelope %{"code" => "200", "msg" => "ok", "data" => "x"}

    test "get_orders/2 refuses rather than reporting no orders" do
      assert {:error, :unexpected_response_shape} =
               Rest.get_orders(@credentials,
                 plug: answering(@unreadable_envelope),
                 retry_attempts: 0,
                 account_id: "acct"
               )
    end

    test "get_positions/2 refuses rather than reporting no positions" do
      assert {:error, :unexpected_response_shape} =
               Rest.get_positions(@credentials,
                 plug: answering(@unreadable_envelope),
                 retry_attempts: 0,
                 account_id: "acct"
               )
    end

    test "get_transfers/2 refuses rather than reporting no transfers" do
      assert {:error, :unexpected_response_shape} =
               Rest.get_transfers(@credentials,
                 plug: answering(@unreadable_envelope),
                 retry_attempts: 0,
                 account_id: "acct"
               )
    end

    test "get_accounts/2 refuses rather than reporting no accounts" do
      assert {:error, :unexpected_response_shape} =
               Rest.get_accounts(@credentials,
                 plug: answering(@unreadable_envelope),
                 retry_attempts: 0
               )
    end

    test "list_event_categories/2 refuses, same as every other rows/1-built list" do
      assert {:error, :unexpected_response_shape} =
               Rest.list_event_categories(@credentials,
                 plug: answering(@unreadable_envelope),
                 retry_attempts: 0
               )
    end

    test "data: null is still no rows — the one shape that stays a deliberate empty" do
      empty = %{"code" => "200", "msg" => "ok", "data" => nil}

      assert {:ok, []} =
               Rest.get_orders(@credentials,
                 plug: answering(empty),
                 retry_attempts: 0,
                 account_id: "acct"
               )

      assert {:ok, []} =
               Rest.get_accounts(@credentials, plug: answering(empty), retry_attempts: 0)
    end

    test "get_balances/2 refuses when account_currency_assets is present and unreadable" do
      # get_balances/2 does not read `rows/1`'s "data" envelope at all — the venue answers
      # the account object directly, with `account_currency_assets` as one of its fields —
      # so this is `currency_assets/1`'s own clause, not `rows/1`'s, and is exercised
      # separately for that reason.
      body = %{"account_currency_assets" => "x"}

      assert {:error, :unexpected_response_shape} =
               Rest.get_balances(@credentials,
                 plug: answering(body),
                 retry_attempts: 0,
                 account_id: "acct"
               )
    end

    test "get_balances/2 still answers no balances when the key is absent — a kept decision" do
      # `account_currency_assets` missing entirely (or explicitly null, which `value/2`
      # cannot tell apart from absent) is NOT this failure: it is the venue naming no
      # currencies for the account, already pinned by
      # accounts_test.exs "a body with no currency assets key is an empty list too".
      assert {:ok, []} =
               Rest.get_balances(@credentials,
                 plug: answering(%{}),
                 retry_attempts: 0,
                 account_id: "acct"
               )
    end
  end

  describe "a retried request" do
    # A retry that replayed the first attempt's `x-signature-nonce` was a replay the venue is
    # built to refuse — every retry of a signed call wasted itself on an authentication error.
    test "is signed again, with its own nonce" do
      test_pid = self()
      counter = :counters.new(1, [])

      plug = fn conn ->
        :counters.add(counter, 1, 1)
        send(test_pid, {:nonce, Plug.Conn.get_req_header(conn, "x-signature-nonce")})

        case :counters.get(counter, 1) do
          1 -> Req.Test.json(%{conn | status: 503}, %{})
          _later -> Req.Test.json(conn, [%{"price" => "1", "time" => 1_787_936_147_000}])
        end
      end

      assert {:ok, _price} =
               Rest.get_price("BTC-USD", @credentials, plug: plug, retry_attempts: 2)

      assert_received {:nonce, [first]}
      assert_received {:nonce, [second]}
      refute first == second
    end

    test "is not made for an order, which is sent once unless the caller asks otherwise" do
      counter = :counters.new(1, [])

      plug = fn conn ->
        :counters.add(counter, 1, 1)
        Req.Test.json(%{conn | status: 503}, %{})
      end

      request = %{
        symbol: "BTC-USD",
        side: :buy,
        quantity: Decimal.new("0.5"),
        price: Decimal.new("40000"),
        order_type: :limit,
        time_in_force: :gtc
      }

      assert {:error, _reason} =
               Rest.place_order(@credentials, request, plug: plug, account_id: "acct")

      assert :counters.get(counter, 1) == 1
    end
  end

  describe "a nested result list that cannot be read is refused, not wrapped" do
    # `List.wrap/1` turned a string `result` into a one-element list and an object into a
    # one-row list of the wrong thing, and a row that was not an object read as none.
    defp nested_opts(body), do: [plug: responding(body), retry_attempts: 0]

    test "get_trades/3" do
      for body <- [[%{"symbol" => "BTCUSD", "result" => "x"}], ["not a row"]] do
        assert {:error, :unexpected_response_shape} =
                 Rest.get_trades("BTC-USD", @credentials, nested_opts(body))
      end
    end

    test "get_event_trades/3" do
      body = [%{"symbol" => "KXCPI", "result" => %{"yes_price" => "0.05"}}]

      assert {:error, :unexpected_response_shape} =
               Rest.get_event_trades("KXCPI", @credentials, nested_opts(body))
    end

    test "get_watchlist/3" do
      body = [%{"watchlist_id" => "wl-1", "instruments" => "AAPL"}]

      assert {:error, :unexpected_response_shape} =
               Rest.get_watchlist("wl-1", @credentials, nested_opts(body))
    end

    test "an absent result is still none" do
      assert {:ok, []} =
               Rest.get_event_trades("KXCPI", @credentials, nested_opts([%{"symbol" => "KXCPI"}]))
    end
  end
end
