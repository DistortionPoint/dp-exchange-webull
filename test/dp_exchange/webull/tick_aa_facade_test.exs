defmodule DpExchange.Webull.TickAAFacadeTest do
  @moduledoc """
  The facade's defaulted-argument forms, and the way it answers when the feed it was pointed
  at misbehaves.

  Every function below is public and callable without its trailing `opts`. This venue signs
  every request, so with no credentials each one must refuse and say so as an `{:error, _}`
  before a request is built - never raise, never answer with data it did not fetch.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Config
  alias DpExchange.Webull

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

  describe "called without opts, a signed read refuses rather than raising" do
    test "get_prices/1 with no symbols asked for answers an empty map" do
      assert Webull.get_prices([]) == {:ok, %{}}
    end

    test "market data" do
      for result <- [
            Webull.get_top_of_book("BTC-USD"),
            Webull.get_order_book("AAPL"),
            Webull.get_trades("AAPL"),
            Webull.get_volume_profile("AAPL", "1m"),
            Webull.get_auction_imbalance("AAPL"),
            Webull.quantization("BTC-USD"),
            Webull.get_option_chain("AAPL"),
            Webull.get_option_expirations("AAPL")
          ] do
        assert {:error, _reason} = result
      end
    end

    test "futures and event contracts" do
      for result <- [
            Webull.list_futures_contracts(),
            Webull.list_futures_product_classes(),
            Webull.list_event_categories(),
            Webull.list_event_series(),
            Webull.list_event_events(),
            Webull.list_event_markets(),
            Webull.get_event_trades("EVENT-1"),
            Webull.get_event_order_book("EVENT-1")
          ] do
        assert {:error, _reason} = result
      end
    end

    test "watchlists" do
      for result <- [
            Webull.list_watchlists(),
            Webull.get_watchlist("watchlist-1"),
            Webull.create_watchlist("tech", ["AAPL"]),
            Webull.update_watchlist("watchlist-1"),
            Webull.delete_watchlist("watchlist-1"),
            Webull.add_watchlist_instruments("watchlist-1", ["AAPL"]),
            Webull.remove_watchlist_instruments("watchlist-1", ["AAPL"]),
            Webull.sort_watchlist_instruments("watchlist-1")
          ] do
        assert {:error, _reason} = result
      end
    end

    test "fundamentals, filings, screeners and tokens" do
      for result <- [
            Webull.get_financials("AAPL", :income),
            Webull.get_corporate_events(),
            Webull.get_filings("AAPL"),
            Webull.get_screener(hd(Webull.screeners())),
            Webull.get_fundamental(hd(Webull.fundamental_kinds()), "AAPL"),
            Webull.create_token(),
            Webull.check_token("token-not-real")
          ] do
        assert {:error, _reason} = result
      end
    end
  end

  describe "the feed-facing reads without opts, with no feed running" do
    test "coverage_by_kind/0 is the empty map" do
      assert Webull.coverage_by_kind() == %{}
    end

    test "subscribe_notices/0 says the feed is not started" do
      assert Webull.subscribe_notices() == {:error, :feed_not_started}
    end
  end

  describe "a feed that dies or stalls under a call is an answer, not an exit" do
    defp dying_feed do
      spawn(fn ->
        receive do
          _message -> exit(:boom)
        end
      end)
    end

    test "a read of coverage_by_kind/1 that exits is the empty answer" do
      assert Webull.coverage_by_kind(feed: dying_feed()) == %{}
    end

    test "a notice subscription whose feed exits names the reason" do
      assert {:error, {:feed_exited, :boom}} =
               Webull.subscribe_notices(feed: dying_feed(), to: self())
    end

    @tag timeout: 60_000
    test "a feed that never answers is :feed_timeout after its call budget" do
      stalled =
        spawn(fn ->
          receive do
            :never_sent -> :ok
          end
        end)

      on_exit(fn -> Process.exit(stalled, :kill) end)

      assert {:error, :feed_timeout} = Webull.subscribe_notices(feed: stalled, to: self())
    end
  end
end
