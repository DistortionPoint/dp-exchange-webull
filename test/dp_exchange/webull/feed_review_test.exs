defmodule DpExchange.Webull.FeedReviewTest do
  @moduledoc """
  Defects found 2026-10-11 by reading all of `Feed`, top to bottom:

    * a symbol list that was not a list of strings raised inside the one process every caller
      shares, and the restart discarded everyone's subscriptions;
    * a re-plan sent HTTP at a shard that was still connecting or reconnecting, drew
      `INVALID_SESSION`, and had the shard torn down and reopened;
    * a blind resubscribe or link-up replay could overtake an `unsubscribe/3` at the venue
      and leave the symbol subscribed with nothing tracking it;
    * `state.rejected` was never pruned, and every reconcile left its 60-second deadline timer
      running after it had answered.
  """

  use DpExchange.Webull.FeedCase, async: true

  alias DpExchange.Webull.{Fake, Feed}

  @subscribe_path "/market-data/streaming/subscribe"
  @unsubscribe_path "/market-data/streaming/unsubscribe"

  defp wait_until(fun, deadline \\ System.monotonic_time(:millisecond) + 5_000) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition never became true")

      true ->
        Process.sleep(25)
        wait_until(fun, deadline)
    end
  end

  describe "a symbol list that cannot be used is refused before any state moves" do
    test "subscribe/3 names the offenders and leaves the feed untouched", %{limiter: limiter} do
      feed = start_feed()
      opts = subscribe_opts(limiter)

      assert {:error, {:invalid_symbols, [:eth, nil, ""]}} =
               Feed.subscribe(feed, ["BTC-USD", :eth, nil, ""], opts)

      assert {:error, {:invalid_symbols, nil}} = Feed.subscribe(feed, nil, opts)
      assert {:error, {:invalid_symbols, "BTC-USD"}} = Feed.subscribe(feed, "BTC-USD", opts)

      assert {:error, {:invalid_symbols, [1, 2, 3, 4, 5]}} =
               Feed.subscribe(feed, [1, 2, 3, 4, 5, 6, 7], opts)

      state = :sys.get_state(feed)
      assert state.wanted == MapSet.new()
      assert state.subscribers == MapSet.new(), "a refused call registers no subscriber"
    end

    test "unsubscribe/3 refuses a non-list and a non-binary element", %{limiter: limiter} do
      feed = start_feed()
      opts = subscribe_opts(limiter)
      want(feed, ["BTC-USD"])

      assert {:error, {:invalid_symbols, :btc}} = Feed.unsubscribe(feed, :btc, opts)
      assert {:error, {:invalid_symbols, [42]}} = Feed.unsubscribe(feed, ["BTC-USD", 42], opts)

      assert :sys.get_state(feed).wanted == MapSet.new(["BTC-USD"]),
             "a refused unsubscribe removes nothing"
    end

    test "update_symbols/3 refuses a non-list and a non-binary element", %{limiter: limiter} do
      feed = start_feed()
      opts = subscribe_opts(limiter)
      want(feed, ["BTC-USD"])

      assert {:error, {:invalid_symbols, nil}} = Feed.update_symbols(feed, nil, opts)
      assert {:error, {:invalid_symbols, [:x]}} = Feed.update_symbols(feed, ["ETH-USD", :x], opts)

      assert :sys.get_state(feed).wanted == MapSet.new(["BTC-USD"]),
             "a refused update replaces nothing"
    end

    test "the feed still serves a valid call afterwards", %{limiter: limiter} do
      feed = start_feed()
      opts = subscribe_opts(limiter)

      assert {:error, {:invalid_symbols, nil}} = Feed.subscribe(feed, nil, opts)
      assert :ok = Feed.subscribe(feed, ["BTC-USD"], opts)

      assert :sys.get_state(feed).wanted == MapSet.new(["BTC-USD"])
    end

    test "the fake answers the same way, because it may not be differently capable" do
      assert {:error, {:invalid_symbols, nil}} = Fake.subscribe(nil)
      assert {:error, {:invalid_symbols, [:x]}} = Fake.subscribe(["BTC-USD", :x])
      assert {:error, {:invalid_symbols, "BTC-USD"}} = Fake.unsubscribe("BTC-USD")
      assert {:error, {:invalid_symbols, [""]}} = Fake.update_symbols([""])
    end
  end

  describe "a re-plan never sends HTTP at a shard that is not connected" do
    test "a connecting shard's removal is recorded, not unsubscribed over HTTP",
         %{limiter: limiter} do
      # Shard 1 is mid-connect: its session is not registered with the venue, so a request
      # naming it is answered INVALID_SESSION, which `Feed` takes to mean "discard and reopen".
      test_pid = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        symbols = body |> Jason.decode!() |> Map.fetch!("symbols") |> Enum.sort()
        send(test_pid, {:hit, conn.request_path, symbols})
        Req.Test.json(conn, %{"code" => "200"})
      end

      connecting = %{connected_shard("s1") | connected?: false, symbols: ["BBB-USD"]}
      feed = start_feed(shards: %{0 => connected_shard("s0"), 1 => connecting})

      # Shard 0 is the primary (the first touched), and takes CCC; shard 1 loses BBB.
      assert :ok = Feed.update_symbols(feed, ["CCC-USD"], subscribe_opts(limiter, plug: plug))
      assert_receive {:hit, @subscribe_path, ["CCCUSD"]}

      # The deferred message is handled after the call returns; let it run before looking.
      _settled = Feed.coverage(feed)
      refute_receive {:hit, @unsubscribe_path, _symbols}, 300

      shard = :sys.get_state(feed).shards[1]
      assert shard.symbols == [], "the new list is recorded for the link-up replay"
      refute shard.connected?
    end
  end

  describe "an unsubscribe overtaken by a whole-list subscribe is sent again" do
    test "a blind resubscribe answering after an unsubscribe re-unsubscribes what it sent",
         %{limiter: limiter} do
      test_pid = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        symbols = body |> Jason.decode!() |> Map.fetch!("symbols") |> Enum.sort()
        send(test_pid, {:hit, conn.request_path, symbols, self()})

        # Only the subscribe is held, so the unsubscribe below can overtake it.
        if conn.request_path == @subscribe_path do
          receive do
            :release -> :ok
          end
        end

        Req.Test.json(conn, %{"code" => "200"})
      end

      shard = %{connected_shard("s0") | symbols: ["AAA-USD", "BBB-USD"]}

      feed =
        start_feed(
          shards: %{0 => shard},
          credentials: credentials(),
          limiter: limiter,
          plug: plug,
          retry_attempts: 0
        )

      want(feed, ["AAA-USD", "BBB-USD"])

      send(feed, :resubscribe)
      assert_receive {:hit, @subscribe_path, ["AAAUSD", "BBBUSD"], held}, 5_000

      assert :ok = Feed.unsubscribe(feed, ["BBB-USD"], subscribe_opts(limiter, plug: plug))
      assert_receive {:hit, @unsubscribe_path, ["BBBUSD"], _first_unsubscribe}, 5_000
      refute_receive {:hit, @unsubscribe_path, _symbols, _task}, 100

      # The older, larger subscribe is the one the venue now finishes last.
      send(held, :release)

      assert_receive {:hit, @unsubscribe_path, ["BBBUSD"], _second_unsubscribe},
                     5_000,
                     "the symbol the late subscribe re-added must be unsubscribed again"
    end

    test "nothing is re-sent when the shard still carries everything the subscribe sent",
         %{limiter: limiter} do
      test_pid = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        symbols = body |> Jason.decode!() |> Map.fetch!("symbols") |> Enum.sort()
        send(test_pid, {:hit, conn.request_path, symbols})
        Req.Test.json(conn, %{"code" => "200"})
      end

      shard = %{connected_shard("s0") | symbols: ["AAA-USD"]}

      feed =
        start_feed(
          shards: %{0 => shard},
          credentials: credentials(),
          limiter: limiter,
          plug: plug,
          retry_attempts: 0
        )

      want(feed, ["AAA-USD"])

      send(feed, :resubscribe)
      assert_receive {:hit, @subscribe_path, ["AAAUSD"]}, 5_000

      wait_until(fn -> :sys.get_state(feed).reconciling == %{} end)
      refute_receive {:hit, @unsubscribe_path, _symbols}, 200
    end
  end

  describe "state and timers that used to outlive their purpose" do
    test "expired rejections are pruned on the tick and live ones stay" do
      feed = start_feed()
      now = System.monotonic_time(:millisecond)

      :sys.replace_state(feed, fn state ->
        %{state | rejected: %{"OLD-USD" => now - 1_000, "LIVE-USD" => now + 3_600_000}}
      end)

      send(feed, :resubscribe)
      _settled = Feed.coverage(feed)

      assert :sys.get_state(feed).rejected |> Map.keys() == ["LIVE-USD"]
    end

    test "a reconcile that answered has cancelled its deadline timer", %{limiter: limiter} do
      test_pid = self()

      plug = fn conn ->
        send(test_pid, {:in_flight, self()})

        receive do
          :release -> :ok
        end

        Req.Test.json(conn, %{"code" => "200"})
      end

      shard = %{connected_shard("s0") | symbols: ["AAA-USD"]}

      feed =
        start_feed(
          shards: %{0 => shard},
          credentials: credentials(),
          limiter: limiter,
          plug: plug,
          retry_attempts: 0,
          reconcile_timeout_ms: 600_000
        )

      want(feed, ["AAA-USD"])

      send(feed, :resubscribe)
      assert_receive {:in_flight, task}, 5_000

      %{timer: timer} = :sys.get_state(feed).reconciling[{:resubscribe, 0}]
      assert is_integer(Process.read_timer(timer)), "the deadline is armed while it runs"

      send(task, :release)
      wait_until(fn -> :sys.get_state(feed).reconciling == %{} end)

      assert Process.read_timer(timer) == false, "and gone once the reconcile has answered"
    end
  end

  describe "a caller's deadline is keyed by the caller, not by a shard index" do
    # The retry after `:oversubscribed` or `INVALID_SYMBOL` can move the primary to another
    # index or park the caller on a connecting shard. The deadline must find the caller in
    # either place, so these put it where an index-keyed timer would not look.
    test "a caller parked on any shard is answered and removed from its reply_to" do
      connecting = %{connected_shard("s3") | connected?: false}
      feed = start_feed(shards: %{0 => connected_shard("s0"), 3 => connecting})

      ref = make_ref()
      other_ref = make_ref()
      from = {self(), ref}
      other = {self(), other_ref}

      :sys.replace_state(feed, &put_in(&1.shards[3].reply_to, [{from, []}, {other, []}]))

      send(feed, {:caller_due, from})

      assert_receive {^ref, {:error, {:connack_timeout, _ms}}}
      refute_receive {^other_ref, _reply}, 50
      assert [{^other, []}] = :sys.get_state(feed).shards[3].reply_to

      send(feed, {:caller_due, other})

      assert_receive {^other_ref, {:error, {:connack_timeout, _ms}}}
      assert :sys.get_state(feed).shards[3].reply_to == nil
    end

    test "a caller riding a primary reconcile on a different index is answered" do
      feed = start_feed()
      stalled = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> if Process.alive?(stalled), do: Process.exit(stalled, :kill) end)

      ref = make_ref()
      from = {self(), ref}

      :sys.replace_state(feed, fn state ->
        entry = %{
          pid: stalled,
          ref: Process.monitor(stalled),
          attempt: make_ref(),
          context: nil
        }

        tag = {:primary, 3, from, ["ZZZ-USD"], 0, []}
        %{state | reconciling: Map.put(state.reconciling, tag, entry)}
      end)

      send(feed, {:caller_due, from})

      assert_receive {^ref, {:error, {:partial_failure, failed: failed, capacity_exceeded: over}}}
      assert {:reconcile_pending, _ms} = failed
      assert over == ["ZZZ-USD"]
    end

    test "a caller nobody is holding is left alone" do
      feed = start_feed()
      ref = make_ref()

      send(feed, {:caller_due, {self(), ref}})
      _settled = Feed.coverage(feed)

      refute_receive {^ref, _reply}, 50
    end

    test "a call on a stalled reconcile is answered at the deadline the call armed",
         %{limiter: limiter} do
      plug = fn conn ->
        Process.sleep(:infinity)
        conn
      end

      feed = start_feed(connack_timeout_ms: 200)

      assert {:error, {:reconcile_pending, 200}} =
               Feed.subscribe(feed, ["BTC-USD"], subscribe_opts(limiter, plug: plug))
    end
  end
end
