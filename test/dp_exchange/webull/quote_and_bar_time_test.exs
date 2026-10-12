defmodule DpExchange.Webull.QuoteAndBarTimeTest do
  @moduledoc """
  Two time readings the decoders got subtly wrong.

  - A bid and an ask are dated by the snapshot's `quote_time`, not by the `last_trade_time`
    that sits beside it on the crypto, option and futures rows.
  - A weekly, monthly or yearly bar still forming is dropped from a stock read exactly as a
    daily or intraday one is; `Core.Timeframe` cannot size those widths, and "cannot size"
    used to mean "keep every bar".
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

  defp responding(body) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end
  end

  describe "a top of book is dated by its quote" do
    @last_trade_ms 1_787_000_000_000
    @quote_ms 1_787_936_147_000

    defp snapshot_row(extra) do
      Map.merge(
        %{"symbol" => "BTCUSD", "price" => "40000", "bid" => "39990", "ask" => "40010"},
        extra
      )
    end

    test "quote_time wins over last_trade_time when the row carries both" do
      row = snapshot_row(%{"last_trade_time" => @last_trade_ms, "quote_time" => @quote_ms})

      assert {:ok, top} =
               Rest.get_top_of_book("BTC-USD", @credentials,
                 plug: responding([row]),
                 retry_attempts: 0
               )

      assert top.venue_time == DateTime.from_unix!(@quote_ms, :millisecond)
    end

    test "a row with only last_trade_time, as the stock snapshot has, is undated: nil" do
      # The last trade is a different event from the quote; dating the quote with it made a
      # staleness check judge the trade (family convention MD7).
      row = snapshot_row(%{"symbol" => "AAPL", "last_trade_time" => @last_trade_ms})

      assert {:ok, top} =
               Rest.get_top_of_book("AAPL", @credentials,
                 category: "US_STOCK",
                 plug: responding([row]),
                 retry_attempts: 0
               )

      assert top.venue_time == nil
    end

    test "a quote_time with no last_trade_time does not date the traded price" do
      row = snapshot_row(%{"quote_time" => @quote_ms})

      assert {:ok, quote_struct} =
               Rest.get_price("BTC-USD", @credentials,
                 plug: responding([row]),
                 retry_attempts: 0
               )

      assert quote_struct.venue_time == nil
    end

    test "a bid or ask of zero is no resting order on that side: nil, and no size" do
      row = snapshot_row(%{"bid" => "0", "bid_size" => "5", "ask" => "0.00", "ask_size" => "7"})

      assert {:ok, top} =
               Rest.get_top_of_book("BTC-USD", @credentials,
                 plug: responding([row]),
                 retry_attempts: 0
               )

      assert top.bid == nil
      assert top.bid_size == nil
      assert top.ask == nil
      assert top.ask_size == nil
    end

    test "a negative bid, or a bid that is not a number, refuses the reply" do
      for {bid, expected} <- [
            {"-1", {:non_positive_price, :bid, "-1"}},
            {"abc", {:invalid_decimal, :bid, "abc"}}
          ] do
        assert {:error, ^expected} =
                 Rest.get_top_of_book("BTC-USD", @credentials,
                   plug: responding([snapshot_row(%{"bid" => bid})]),
                   retry_attempts: 0
                 )
      end
    end

    test "a traded price of zero or less refuses the reply" do
      for bad <- ["0", "-3"] do
        assert {:error, {:non_positive_price, :price, ^bad}} =
                 Rest.get_price("BTC-USD", @credentials,
                   plug: responding([snapshot_row(%{"price" => bad})]),
                   retry_attempts: 0
                 )
      end
    end

    test "an unparseable quote_time is nil, not the trade's time" do
      row = snapshot_row(%{"last_trade_time" => @last_trade_ms, "quote_time" => "yesterday"})

      assert {:ok, top} =
               Rest.get_top_of_book("BTC-USD", @credentials,
                 plug: responding([row]),
                 retry_attempts: 0
               )

      assert top.venue_time == nil
    end

    test "a size is kept only with the price it belongs to" do
      # A bid of "null" (the venue's no-price spelling) beside a real bid size is no level at
      # all; the size must not read as depth on an empty side. The ask side is untouched.
      row =
        snapshot_row(%{
          "bid" => "null",
          "bid_size" => "5",
          "ask_size" => "7"
        })

      assert {:ok, top} =
               Rest.get_top_of_book("BTC-USD", @credentials,
                 plug: responding([row]),
                 retry_attempts: 0
               )

      assert top.bid == nil
      assert top.bid_size == nil
      assert Decimal.equal?(top.ask, Decimal.new("40010"))
      assert Decimal.equal?(top.ask_size, Decimal.new("7"))
    end

    test "an empty bid is no resting order, not a refused reply" do
      row = snapshot_row(%{"bid" => "", "bid_size" => "5"})

      assert {:ok, top} =
               Rest.get_top_of_book("BTC-USD", @credentials,
                 plug: responding([row]),
                 retry_attempts: 0
               )

      assert top.bid == nil
      assert top.bid_size == nil
      assert Decimal.equal?(top.ask, Decimal.new("40010"))
    end

    test "the traded price is still dated by the trade" do
      row = snapshot_row(%{"last_trade_time" => @last_trade_ms, "quote_time" => @quote_ms})

      assert {:ok, quote_struct} =
               Rest.get_price("BTC-USD", @credentials,
                 plug: responding([row]),
                 retry_attempts: 0
               )

      assert quote_struct.venue_time == DateTime.from_unix!(@last_trade_ms, :millisecond)
    end
  end

  describe "a forming bar is dropped at every width a stock read serves" do
    defp bar(ms) do
      %{"time" => ms, "open" => "1", "high" => "2", "low" => "1", "close" => "1.5"}
    end

    defp bars_body(times) do
      %{"result" => [%{"symbol" => "AAPL", "result" => Enum.map(times, &bar/1)}]}
    end

    for timeframe <- ~w(1w 1M 1y) do
      test "#{timeframe}: the bar that opened an hour ago is forming, the old one is kept" do
        old_ms = 1_640_688_000_000

        forming_ms =
          DateTime.utc_now()
          |> DateTime.add(-3600, :second)
          |> DateTime.to_unix(:millisecond)

        opts = [
          category: "US_STOCK",
          plug: responding(bars_body([old_ms, forming_ms])),
          retry_attempts: 0
        ]

        assert {:ok, [done]} =
                 Rest.get_historical_prices("AAPL", unquote(timeframe), [], @credentials, opts)

        assert done.opened_at == DateTime.from_unix!(old_ms, :millisecond)

        # A caller who asks for the forming bar keeps it.
        assert {:ok, [_done, forming]} =
                 Rest.get_historical_prices(
                   "AAPL",
                   unquote(timeframe),
                   [],
                   @credentials,
                   [include_partial: true] ++ opts
                 )

        assert forming.opened_at == DateTime.from_unix!(forming_ms, :millisecond)
      end
    end

    test "a microsecond epoch is no bar time, not a year 58,000 one" do
      micros = 1_787_936_147_000_000

      assert {:error, :invalid_unix_time} =
               Rest.get_historical_prices("AAPL", "1d", [], @credentials,
                 category: "US_STOCK",
                 plug: responding(bars_body([micros])),
                 retry_attempts: 0
               )
    end

    test "a top of book with a microsecond quote_time has no venue time" do
      row = snapshot_row(%{"quote_time" => 1_787_936_147_000_000})

      assert {:ok, top} =
               Rest.get_top_of_book("BTC-USD", @credentials,
                 plug: responding([row]),
                 retry_attempts: 0
               )

      assert top.venue_time == nil
    end

    test "a completed weekly bar from last month is kept" do
      last_month_ms =
        DateTime.utc_now()
        |> DateTime.add(-30 * 86_400, :second)
        |> DateTime.to_unix(:millisecond)

      assert {:ok, [_bar]} =
               Rest.get_historical_prices("AAPL", "1w", [], @credentials,
                 category: "US_STOCK",
                 plug: responding(bars_body([last_month_ms])),
                 retry_attempts: 0
               )
    end
  end
end
