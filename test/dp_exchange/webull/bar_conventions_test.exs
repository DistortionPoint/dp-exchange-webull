defmodule DpExchange.Webull.BarConventionsTest do
  @moduledoc """
  The family's market-data conventions for bars (tick R), on every path and in the fake:

    * the bar still forming is dropped unless `include_partial: true` (`real_time:` is gone);
    * `:start` is inclusive and `:end` exclusive, and a range is never answered short;
    * a bar's time must sit on its width's grid, else the reply is refused;
    * a price of zero or less refuses the bar;
    * `max_candles_per_request` is declared, as documented and not measured.

  Every plug here answers from the test process; nothing waits on a timer.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.{Config, Timeframe}
  alias DpExchange.Webull
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
  @past ~U[2021-12-28 00:00:00Z]

  @paths [
    {"US_CRYPTO", "BTC-USD"},
    {"US_STOCK", "AAPL"},
    {"US_OPTION", "AAPL260522C00300000"},
    {"US_FUTURES", "SILZ5"},
    {"US_EVENT", "KXCPI-26JAN-T0.3"}
  ]

  defp responding(body) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end
  end

  defp capturing(body, test_pid) do
    fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request, conn.method, conn.request_path, conn.query_string, raw})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end
  end

  defp bar(%DateTime{} = at, overrides \\ %{}) do
    Map.merge(
      %{
        "time" => DateTime.to_unix(at, :millisecond),
        "open" => "1",
        "high" => "2",
        "low" => "1",
        "close" => "1.5",
        "volume" => "10"
      },
      overrides
    )
  end

  # The bare array of per-symbol groups: every bars decoder in this package reads it.
  defp groups(bars), do: [%{"symbol" => "SYM", "result" => bars}]

  # A bar that has certainly not ended: a day-grid bucket ten years ahead. Deterministic,
  # where "the current bucket" would race the midnight rollover.
  defp forming_at do
    DateTime.utc_now() |> DateTime.add(3_650, :day) |> Timeframe.boundary("1d")
  end

  describe "the forming bar" do
    for {category, symbol} <- @paths do
      test "#{category}: dropped by default, kept with include_partial: true" do
        forming = forming_at()
        body = groups([bar(@past), bar(forming)])

        opts = [category: unquote(category), plug: responding(body), retry_attempts: 0]

        assert {:ok, [only]} =
                 Rest.get_historical_prices(unquote(symbol), "1d", [], @credentials, opts)

        assert only.opened_at.year == 2021

        assert {:ok, [_done, partial]} =
                 Rest.get_historical_prices(
                   unquote(symbol),
                   "1d",
                   [],
                   @credentials,
                   [include_partial: true] ++ opts
                 )

        assert DateTime.compare(partial.opened_at, forming) == :eq

        assert {:ok, [_only]} =
                 Rest.get_historical_prices(
                   unquote(symbol),
                   "1d",
                   [],
                   @credentials,
                   [include_partial: false] ++ opts
                 )
      end
    end

    test "the event path asks the venue for the forming bar only when the caller does" do
      me = self()
      opts = [category: "US_EVENT", plug: capturing(groups([bar(@past)]), me), retry_attempts: 0]

      assert {:ok, [_bar]} =
               Rest.get_historical_prices("KXCPI-26JAN-T0.3", "1d", [], @credentials, opts)

      assert_receive {:request, "GET", _path, default_query, _raw}
      assert default_query =~ "real_time_required=false"

      assert {:ok, [_bar]} =
               Rest.get_historical_prices(
                 "KXCPI-26JAN-T0.3",
                 "1d",
                 [],
                 @credentials,
                 [include_partial: true] ++ opts
               )

      assert_receive {:request, "GET", _path, partial_query, _raw}
      assert partial_query =~ "real_time_required=true"
    end

    test "real_time: is refused on every path and in the fake, never ignored" do
      exploding = fn _conn -> raise "must not reach the venue with a renamed option" end

      for {category, symbol} <- @paths do
        assert {:error, {:unsupported_option, :real_time}} =
                 Rest.get_historical_prices(symbol, "1d", [], @credentials,
                   category: category,
                   real_time: true,
                   plug: exploding,
                   retry_attempts: 0
                 )
      end

      assert {:error, {:unsupported_option, :real_time}} =
               Rest.get_stock_bars("AAPL", "1d", [], @credentials,
                 real_time: false,
                 plug: exploding,
                 retry_attempts: 0
               )

      assert {:error, {:unsupported_option, :real_time}} =
               Fake.get_historical_prices("BTC-USD", "1m", [],
                 real_time: true,
                 credentials: @credentials
               )
    end

    test "include_partial: must be a boolean" do
      exploding = fn _conn -> raise "must not reach the venue with a bad option" end

      assert {:error, {:invalid_option, :include_partial, "yes"}} =
               Rest.get_historical_prices("BTC-USD", "1d", [], @credentials,
                 include_partial: "yes",
                 plug: exploding,
                 retry_attempts: 0
               )

      assert {:error, {:invalid_option, :include_partial, 1}} =
               Fake.get_historical_prices("BTC-USD", "1m", [],
                 include_partial: 1,
                 credentials: @credentials
               )
    end
  end

  describe "the range" do
    for {category, symbol} <- [{"US_CRYPTO", "BTC-USD"}, {"US_STOCK", "AAPL"}] do
      test "#{category}: :start is inclusive and :end exclusive on opened_at" do
        day1 = ~U[2021-12-28 00:00:00Z]
        day2 = ~U[2021-12-29 00:00:00Z]
        day3 = ~U[2021-12-30 00:00:00Z]
        body = groups([bar(day1), bar(day2), bar(day3)])

        assert {:ok, bars} =
                 Rest.get_historical_prices(
                   unquote(symbol),
                   "1d",
                   [start: day1, end: day3],
                   @credentials,
                   category: unquote(category),
                   plug: responding(body),
                   retry_attempts: 0
                 )

        assert Enum.map(bars, &DateTime.to_unix(&1.opened_at)) ==
                 [DateTime.to_unix(day1), DateTime.to_unix(day2)]
      end
    end

    test "the fake agrees: :start inclusive, :end exclusive" do
      {:ok, [bar]} = Fake.get_historical_prices("BTC-USD", "1d", [], credentials: @credentials)
      assert Timeframe.aligned?(bar.opened_at, "1d")

      assert {:ok, []} =
               Fake.get_historical_prices("BTC-USD", "1d", [end: bar.opened_at],
                 credentials: @credentials
               )

      assert {:ok, [_bar]} =
               Fake.get_historical_prices("BTC-USD", "1d", [start: bar.opened_at],
                 credentials: @credentials
               )
    end

    test "stock: a full page that does not reach :start is range_too_wide, never short" do
      base = ~U[2022-01-03 00:00:00Z]
      body = groups([bar(base), bar(DateTime.add(base, 86_400, :second))])
      earlier = ~U[2021-01-01 00:00:00Z]

      opts = [category: "US_STOCK", limit: 2, plug: responding(body), retry_attempts: 0]

      assert {:error, {:range_too_wide, 2}} =
               Rest.get_historical_prices("AAPL", "1d", [start: earlier], @credentials, opts)

      # A page shorter than `count` is the venue's whole history, and is answered.
      assert {:ok, [_one, _two]} =
               Rest.get_historical_prices(
                 "AAPL",
                 "1d",
                 [start: earlier],
                 @credentials,
                 Keyword.put(opts, :limit, 3)
               )

      # A full page that does reach :start is answered.
      assert {:ok, [_one, _two]} =
               Rest.get_historical_prices("AAPL", "1d", [start: base], @credentials, opts)
    end

    test "stock: a :start with no :limit asks for the maximum count, and checks against it" do
      me = self()
      base = ~U[2018-01-01 00:00:00Z]
      full = for i <- 0..1_199, do: bar(DateTime.add(base, i * 86_400, :second))

      assert {:error, {:range_too_wide, 1_200}} =
               Rest.get_historical_prices(
                 "AAPL",
                 "1d",
                 [start: ~U[2017-01-01 00:00:00Z]],
                 @credentials,
                 category: "US_STOCK",
                 plug: capturing(groups(full), me),
                 retry_attempts: 0
               )

      assert_receive {:request, "POST", _path, _query, raw}
      assert Jason.decode!(raw)["count"] == 1_200
    end

    test "stock: no range and no :limit leaves the venue's own default (no count sent)" do
      me = self()

      assert {:ok, [_bar]} =
               Rest.get_historical_prices("AAPL", "1d", [], @credentials,
                 category: "US_STOCK",
                 plug: capturing(groups([bar(@past)]), me),
                 retry_attempts: 0
               )

      assert_receive {:request, "POST", _path, _query, raw}
      refute Map.has_key?(Jason.decode!(raw), "count")
    end

    test "stock: the caller's :limit is the count sent" do
      me = self()

      assert {:ok, [_bar]} =
               Rest.get_historical_prices("AAPL", "1d", [], @credentials,
                 category: "US_STOCK",
                 limit: 25,
                 plug: capturing(groups([bar(@past)]), me),
                 retry_attempts: 0
               )

      assert_receive {:request, "POST", _path, _query, raw}
      assert Jason.decode!(raw)["count"] == 25
    end
  end

  describe "a bar's time is a bucket start" do
    test "a bar off the width's grid refuses the whole reply, on every path" do
      off = ~U[2021-12-28 00:07:00Z]

      for {category, symbol} <- @paths do
        assert {:error, {:unaligned_candle, got}} =
                 Rest.get_historical_prices(symbol, "5m", [], @credentials,
                   category: category,
                   plug: responding(groups([bar(@past), bar(off)])),
                   retry_attempts: 0
                 )

        assert DateTime.compare(got, off) == :eq
      end
    end

    test "crypto keeps the strict UTC grid: a 1h bar at 13:30Z is refused" do
      at = ~U[2021-12-28 13:30:00Z]

      assert {:error, {:unaligned_candle, got}} =
               Rest.get_historical_prices("BTC-USD", "1h", [], @credentials,
                 plug: responding(groups([bar(at)])),
                 retry_attempts: 0
               )

      assert DateTime.compare(got, at) == :eq
    end

    test "session-traded 1h bars are session-anchored: 13:30Z is accepted, 13:45Z refused" do
      half = ~U[2021-12-28 14:30:00Z]
      session_open = ~U[2021-12-28 13:30:00Z]
      quarter = ~U[2021-12-28 13:45:00Z]

      for {category, symbol} <- @paths, category != "US_CRYPTO" do
        opts = [category: category, retry_attempts: 0]
        wide = "1h"

        assert {:ok, [first, second]} =
                 Rest.get_historical_prices(
                   symbol,
                   wide,
                   [],
                   @credentials,
                   [plug: responding(groups([bar(session_open), bar(half)]))] ++ opts
                 )

        assert DateTime.compare(first.opened_at, session_open) == :eq
        assert DateTime.compare(second.opened_at, half) == :eq

        assert {:error, {:unaligned_candle, got}} =
                 Rest.get_historical_prices(
                   symbol,
                   wide,
                   [],
                   @credentials,
                   [plug: responding(groups([bar(quarter)]))] ++ opts
                 )

        assert DateTime.compare(got, quarter) == :eq
      end
    end

    test "a daily stock bar at exchange-local midnight maps to 00:00Z of that date" do
      # 04:00Z is New York midnight in summer (EDT), 05:00Z in winter (EST).
      for {stamp, date} <- [
            {~U[2021-07-06 04:00:00Z], ~U[2021-07-06 00:00:00Z]},
            {~U[2021-12-28 05:00:00Z], ~U[2021-12-28 00:00:00Z]},
            {~U[2021-12-28 00:00:00Z], ~U[2021-12-28 00:00:00Z]}
          ] do
        assert {:ok, [candle]} =
                 Rest.get_historical_prices("AAPL", "1d", [], @credentials,
                   category: "US_STOCK",
                   plug: responding(groups([bar(stamp)])),
                   retry_attempts: 0
                 )

        assert DateTime.compare(candle.opened_at, date) == :eq
      end
    end

    test "a daily stock bar at any other time of day is refused" do
      at = ~U[2021-12-28 09:00:00Z]

      assert {:error, {:unaligned_candle, got}} =
               Rest.get_historical_prices("AAPL", "1d", [], @credentials,
                 category: "US_STOCK",
                 plug: responding(groups([bar(at)])),
                 retry_attempts: 0
               )

      assert DateTime.compare(got, at) == :eq
    end

    test "a width Core has no grid for is not checked" do
      odd = ~U[2021-12-29 13:17:00Z]

      assert {:ok, [_bar]} =
               Rest.get_historical_prices("AAPL", "1w", [], @credentials,
                 category: "US_STOCK",
                 plug: responding(groups([bar(odd)])),
                 retry_attempts: 0
               )
    end
  end

  describe "prices" do
    for {field, atom} <- [{"open", :open}, {"high", :high}, {"low", :low}, {"close", :close}],
        bad <- ["0", "-1"] do
      test "a bar with #{field} #{bad} refuses the reply" do
        assert {:error, {:non_positive_price, unquote(atom), unquote(bad)}} =
                 Rest.get_historical_prices("BTC-USD", "1d", [], @credentials,
                   plug: responding(groups([bar(@past, %{unquote(field) => unquote(bad)})])),
                   retry_attempts: 0
                 )
      end
    end
  end

  describe "declarations and the fake" do
    test "max_candles_per_request is the documented 1200, labelled as not measured" do
      capabilities = Webull.capabilities()

      assert capabilities.max_candles_per_request == 1_200
      assert capabilities.measured_against =~ "DOCUMENTED"
    end

    test "the fake's tape claims no side, as the real one" do
      assert {:ok, trades} = Fake.get_trades("AAPL", credentials: @credentials)
      assert trades != []
      assert Enum.all?(trades, &(&1.side == nil))
    end
  end
end
