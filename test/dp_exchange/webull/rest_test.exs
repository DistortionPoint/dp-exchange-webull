defmodule DpExchange.Webull.RestTest do
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

    test "a response with no venue timestamp FAILS rather than substituting now" do
      body = [%{"price" => "1"}]

      assert {:error, :missing_venue_timestamp} =
               Rest.get_price("BTC-USD", @credentials, plug: responding(body), retry_attempts: 0)
    end

    test "a response with no price is an unreadable snapshot, not a nil-priced quote" do
      body = [%{"time" => 1_787_936_147_000}]

      assert {:error, :unexpected_response_shape} =
               Rest.get_price("BTC-USD", @credentials, plug: responding(body), retry_attempts: 0)
    end

    test "a 401 is a refusal carrying the venue's own message" do
      body = %{"code" => "AUTH_FAILED", "msg" => "signature mismatch"}

      assert {:refused, {:venue_error, "signature mismatch"}} =
               Rest.get_price("BTC-USD", @credentials,
                 plug: responding(body, 401),
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

      assert from_seconds.timestamp.year == 2026
      assert from_millis.timestamp.year == 2026
    end

    test "an ISO-8601 timestamp is read too" do
      body = [%{"price" => "1", "time" => "2026-08-28T17:00:01Z"}]

      assert {:ok, quote_struct} =
               Rest.get_price("BTC-USD", @credentials, plug: responding(body), retry_attempts: 0)

      assert quote_struct.timestamp == ~U[2026-08-28 17:00:01Z]
    end

    test "an unparseable timestamp is an error, not a guess" do
      body = [%{"price" => "1", "time" => "whenever"}]

      assert {:error, {:unparseable_venue_timestamp, "whenever"}} =
               Rest.get_price("BTC-USD", @credentials, plug: responding(body), retry_attempts: 0)
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
end
