defmodule DpExchange.Webull.CountLimitsTest do
  @moduledoc """
  A bar or tick count over the maximum the endpoint's own page states is refused before the
  request, in the shape the crypto-bars check has always used,
  `{:error, {:limit_out_of_range, n, max: max}}`. Only pages that state a maximum are
  checked; the cases here are each cited to the page.
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

  defp exploding, do: fn _conn -> raise "must not send a count over the stated maximum" end

  defp opts(extra), do: [plug: exploding(), retry_attempts: 0] ++ extra

  defp empty_ok do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!([]))
    end
  end

  describe "stock bars (historical-bars.md: 1200, M1 up to 1650)" do
    test "1m allows 1650 and refuses 1651" do
      assert {:error, {:limit_out_of_range, 1_651, max: 1_650}} =
               Rest.get_stock_bars("AAPL", "1m", [], @credentials, opts(limit: 1_651))

      refute match?(
               {:error, {:limit_out_of_range, _n, _max}},
               Rest.get_stock_bars(
                 "AAPL",
                 "1m",
                 [],
                 @credentials,
                 plug: empty_ok(),
                 retry_attempts: 0,
                 limit: 1_650
               )
             )
    end

    test "every other width stops at 1200" do
      assert {:error, {:limit_out_of_range, 1_201, max: 1_200}} =
               Rest.get_stock_bars("AAPL", "1d", [], @credentials, opts(limit: 1_201))
    end

    test "zero and non-integers are out of range" do
      for bad <- [0, -5, "10"] do
        assert {:error, {:limit_out_of_range, ^bad, max: 1_200}} =
                 Rest.get_stock_bars("AAPL", "1d", [], @credentials, opts(limit: bad))
      end
    end
  end

  describe "option, futures and event bars (1200)" do
    test "each refuses 1201" do
      for category <- ["US_OPTION", "US_FUTURES", "US_EVENT"] do
        assert {:error, {:limit_out_of_range, 1_201, max: 1_200}} =
                 Rest.get_historical_prices(
                   "SYM",
                   "1d",
                   [],
                   @credentials,
                   opts(category: category, limit: 1_201)
                 )
      end
    end
  end

  describe "ticks" do
    test "the stock tape stops at 1000 (tick.md)" do
      assert {:error, {:limit_out_of_range, 1_001, max: 1_000}} =
               Rest.get_trades("AAPL", @credentials, opts(limit: 1_001))
    end

    test "option and futures tapes stop at 1200 (option-tick.md, futures-tick.md)" do
      for category <- ["US_OPTION", "US_FUTURES"] do
        assert {:error, {:limit_out_of_range, 1_201, max: 1_200}} =
                 Rest.get_trades("SYM", @credentials, opts(category: category, limit: 1_201))
      end
    end

    test "the event tape stops at 1200 (event-tick.md)" do
      assert {:error, {:limit_out_of_range, 1_201, max: 1_200}} =
               Rest.get_event_trades("KXCPI-26JAN-T0.3", @credentials, opts(limit: 1_201))
    end
  end

  describe "footprint (footprint.md: 1200)" do
    test "a count over it is refused" do
      assert {:error, {:limit_out_of_range, 1_201, max: 1_200}} =
               Rest.get_volume_profile("AAPL", "1m", @credentials, opts(count: 1_201))

      assert {:error, {:limit_out_of_range, 1_201, max: 1_200}} =
               Rest.validate_footprint_request("1m", count: 1_201)
    end
  end

  describe "statements (financial-*.md, fund-net-value.md: maximum 20)" do
    test "a count over 20 is refused" do
      for kind <- [:balance_sheet, :income, :cash_flow, :indicators] do
        assert {:error, {:limit_out_of_range, 21, max: 20}} =
                 Rest.get_financials("AAPL", kind, @credentials, opts(count: 21))
      end

      assert {:error, {:limit_out_of_range, 21, max: 20}} =
               Rest.get_fundamental(:fund_net_values, "VTI", @credentials, opts(count: 21))
    end

    test "capital flows state no maximum and are not checked locally" do
      refute match?(
               {:error, {:limit_out_of_range, _n, _max}},
               Rest.get_fundamental(
                 :capital_flows,
                 "AAPL",
                 @credentials,
                 plug: empty_ok(),
                 retry_attempts: 0,
                 count: 5_000
               )
             )
    end
  end
end
