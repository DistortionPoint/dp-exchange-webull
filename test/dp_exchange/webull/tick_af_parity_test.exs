defmodule DpExchange.Webull.TickAFParityTest do
  @moduledoc """
  Fake-versus-real input validation (tick AF). Every case drives the SAME input through the
  real `Rest` path (with a plug that raises if the venue is reached, so the answer is the
  local validation's) and through `DpExchange.Webull.Fake`, and requires the same refusal.

  Also pins the Feed's per-caller and per-slot timers: each is cancelled when its subject goes
  away, not left to fire and find nothing.
  """

  use DpExchange.Webull.FeedCase, async: true

  alias DpExchange.Core.Config
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

  @creds %{app_key: "key", app_secret: "secret"}
  @account "93IUJ28O9VO2KBGHDHR4H9"

  defp exploding, do: fn _conn -> raise "must not reach the venue" end

  # `:sessions` values the venue's `PRE`/`RTH`/`ATH`/`OVN` enum does not list, or a list that
  # cannot be one comma-joined value: each used to go to the wire as typed.
  @bad_sessions ["rth", "ALL", "", [], ["RTH", "RTH"], ["RTH", "XYZ"], 5, ["PRE", :RTH]]

  describe "tape and bar :sessions name sessions the venue lists" do
    test "the real tape and the fake refuse the same values" do
      for bad <- @bad_sessions do
        error = {:error, {:invalid_option, :sessions, bad}}

        assert error == Rest.get_trades("AAPL", @creds, sessions: bad, plug: exploding())
        assert error == Fake.get_trades("AAPL", credentials: @creds, sessions: bad)
      end
    end

    test "the real equity bars and the fake refuse the same values" do
      for bad <- @bad_sessions do
        error = {:error, {:invalid_option, :sessions, bad}}
        opts = [category: "US_STOCK", sessions: bad, plug: exploding()]

        assert error == Rest.get_historical_prices("AAPL", "1m", [], @creds, opts)
        assert error == Rest.get_stock_bars("AAPL", "1m", [], @creds, opts)

        assert error ==
                 Fake.get_historical_prices("AAPL", "1m", [],
                   credentials: @creds,
                   category: "US_STOCK",
                   sessions: bad
                 )
      end
    end

    test "a listed session, several, or none are still accepted" do
      for good <- [nil, "PRE", "OVN", :RTH, ["PRE", "RTH"], ["PRE", "RTH", "ATH", "OVN"]] do
        assert {:ok, _ticks} = Fake.get_trades("AAPL", credentials: @creds, sessions: good)
      end
    end
  end

  describe ":history is a boolean" do
    test "get_orders refuses anything else on the real path and the fake" do
      for bad <- ["false", "true", 0, 1, :no, []] do
        error = {:error, {:invalid_option, :history, bad}}
        opts = [account_id: @account, history: bad]

        assert error == Rest.get_orders(@creds, [{:plug, exploding()} | opts])
        assert error == Fake.get_orders(@creds, opts)
      end
    end

    test "get_auction_imbalance refuses anything else on the real path and the fake" do
      for bad <- ["false", 0, 1, :no] do
        error = {:error, {:invalid_option, :history, bad}}
        opts = [auction: :opening, history: bad]

        assert error == Rest.get_auction_imbalance("AAPL", @creds, [{:plug, exploding()} | opts])
        assert error == Fake.get_auction_imbalance("AAPL", [{:credentials, @creds} | opts])
      end
    end

    test "true, false and absent are still accepted by the fake" do
      for good <- [true, false] do
        assert {:ok, [_row]} =
                 Fake.get_auction_imbalance("AAPL",
                   credentials: @creds,
                   auction: :closing,
                   history: good
                 )

        assert {:ok, _orders} = Fake.get_orders(@creds, account_id: @account, history: good)
      end
    end
  end

  describe "get_prices checks the hours flags get_price checks" do
    test "the real path and the fake refuse them for the whole call" do
      for {key, bad} <- [extended_hours: "yes", overnight: 1, extended_hours: %{}] do
        error = {:error, {:invalid_option, key, bad}}
        opts = [{key, bad}]

        assert error == Rest.get_prices(["BTC-USD"], @creds, [{:plug, exploding()} | opts])
        assert error == Fake.get_prices(["BTC-USD"], [{:credentials, @creds} | opts])
      end
    end

    test "a boolean flag is still accepted by the fake" do
      assert {:ok, %{"BTC-USD" => {:ok, _quote}}} =
               Fake.get_prices(["BTC-USD"], credentials: @creds, extended_hours: false)
    end
  end

  describe "a batch cannot repeat a client order id" do
    defp batch_order(id) do
      %{
        symbol: "AAPL",
        side: :buy,
        order_type: :limit,
        time_in_force: :day,
        quantity: Decimal.new("10"),
        price: Decimal.new("180"),
        instrument_type: :equity,
        support_trading_session: :core,
        client_order_id: id
      }
    end

    test "the real path and the fake refuse the repeat by its index" do
      batch = [batch_order("dup-1"), batch_order("other"), batch_order("dup-1")]
      error = {:error, {:batch_order_rejected, 2, {:duplicate_client_order_id, "dup-1"}}}

      assert error == Rest.validate_batch_orders(batch)
      assert error == Rest.place_orders(@creds, batch, account_id: "a", plug: exploding())
      assert error == Fake.place_orders(@creds, batch, account_id: @account)
    end

    test "the fake refuses an id it already holds, and applies nothing of the batch" do
      held = batch_order("held-1")
      assert {:ok, _order} = Fake.place_order(@creds, held, account_id: @account)

      assert {:refused, {:duplicate_client_order_id, "held-1"}} =
               Fake.place_order(@creds, held, account_id: @account)

      batch = [batch_order("fresh-1"), batch_order("held-1")]
      error = {:error, {:batch_order_rejected, 1, {:duplicate_client_order_id, "held-1"}}}

      assert error == Fake.place_orders(@creds, batch, account_id: @account)
      assert {:refused, :not_found} = Fake.get_order(@creds, "fresh-1", account_id: @account)
    end

    test "distinct ids, and entries naming none, are accepted" do
      no_id = Map.delete(batch_order("x"), :client_order_id)

      assert :ok = Rest.validate_batch_orders([batch_order("a"), batch_order("b")])
      assert :ok = Rest.validate_batch_orders([no_id, no_id])
    end
  end

  describe "a parked caller's CONNACK timer is cancelled with the caller" do
    test "a refusal that answers the caller leaves no connack timer behind" do
      session = "connack-#{System.unique_integer([:positive])}"
      feed = start_feed(shards: %{0 => %{connected_shard(session) | connected?: false}})
      test_pid = self()
      from = {test_pid, make_ref()}

      # Armed inside the feed, as `arm_connack_timer/4` arms it, so the feed owns the timer.
      :sys.replace_state(feed, fn state ->
        timer = Process.send_after(self(), :never, 60_000)
        send(test_pid, {:timer, timer})
        state = put_in(state.shards[0].reply_to, [{from, []}])
        %{state | connack_timers: Map.put(state.connack_timers, from, [timer])}
      end)

      assert_receive {:timer, timer}, 5_000

      details = %{session_id: session, connack: 4}
      refused = DpExchange.Core.Notice.new(:credentials_rejected, :webull, details: details)
      send(feed, {:dp_exchange, :webull, refused})

      {_pid, tag} = from
      assert_receive {^tag, {:error, {:connection_refused, _details}}}, 5_000

      assert :sys.get_state(feed).connack_timers == %{}
      assert timer_remaining(feed, timer) == false
    end
  end

  describe "an open-retry chain's pending timer is cancelled when the chain ends" do
    test "the chain's own successful reopen leaves no timer" do
      feed = start_feed(shards: %{}, open_retry_base_ms: 60_000, open_retry_max_ms: 60_000)
      want(feed, ["BTCUSD"])
      bad = [credentials: %{app_secret: "s"}, retry_attempts: 0]

      send(feed, {:open_shard, 0, ["BTCUSD"], bad})
      state = :sys.get_state(feed)
      assert %{0 => token} = state.open_chains
      assert %{0 => timer} = state.open_timers
      assert is_integer(timer_remaining(feed, timer))

      send(feed, {:reopen_shard, 0, ["BTCUSD"], [credentials: credentials()], 2, token})
      _settled = DpExchange.Webull.Feed.coverage(feed)

      state = :sys.get_state(feed)
      assert state.open_chains == %{}
      assert state.open_timers == %{}
      assert timer_remaining(feed, timer) == false
    end

    test "a staggered open that the slot's other route filled is cancelled" do
      feed = start_feed(shards: %{})
      want(feed, ["BTCUSD"])
      test_pid = self()

      :sys.replace_state(feed, fn state ->
        timer = Process.send_after(self(), :never, 60_000)
        send(test_pid, {:timer, timer})
        %{state | staggered_timers: %{0 => [timer]}}
      end)

      assert_receive {:timer, timer}, 5_000

      send(feed, {:open_shard, 0, ["BTCUSD"], [credentials: credentials()]})
      _settled = DpExchange.Webull.Feed.coverage(feed)

      assert :sys.get_state(feed).staggered_timers == %{}
      assert timer_remaining(feed, timer) == false
    end
  end

  # Read from the feed, which owns the timer.
  defp timer_remaining(feed, timer) do
    test_pid = self()

    :sys.replace_state(feed, fn state ->
      send(test_pid, {:remaining, Process.read_timer(timer)})
      state
    end)

    assert_receive {:remaining, remaining}, 5_000
    remaining
  end
end
