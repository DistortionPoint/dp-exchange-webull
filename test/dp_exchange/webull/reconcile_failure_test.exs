defmodule DpExchange.Webull.ReconcileFailureTest do
  @moduledoc """
  What `Feed` believes about a shard after a reconcile fails, answers from a replaced session,
  credentials in its state, and which kinds it counts.

  Every test here pins a defect found 2026-10-10 by reading `Feed`:

    * a failed reconcile left the shard's symbol list at the NEW value, so a retry diffed
      empty and answered `:ok` for a symbol that was never subscribed;
    * a failed unsubscribe cancelled the subscribe of everything added alongside it;
    * an `INVALID_SESSION` or `:oversubscribed` from a replaced session was applied to its
      healthy replacement;
    * only `resubscribe_opts` wrapped credentials, so `app_secret` sat readable in the rest
      of the state;
    * a `Trade` was counted in coverage while `capabilities().streamable` declares no
      `:trades`;
    * a priority shard's empty room could not take overflow, so 3 priority + 450 others
      reported `capacity_exceeded` below the 500-symbol ceiling;
    * a crashed shard was reopened at once, without limit.
  """

  use DpExchange.Webull.FeedCase, async: true

  alias DpExchange.Core.Notice
  alias DpExchange.Core.Types.Trade
  alias DpExchange.Webull.Feed

  @subscribe_path "/market-data/streaming/subscribe"
  @unsubscribe_path "/market-data/streaming/unsubscribe"

  # Answers every request, telling the test which path was hit and with what symbols. A
  # path in `failing` is refused with a 500, which `Subscription` reports as an error.
  defp recording_plug(test_pid, failing \\ []) do
    fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      symbols = body |> Jason.decode!() |> Map.fetch!("symbols") |> Enum.sort()
      send(test_pid, {:hit, conn.request_path, symbols})

      if conn.request_path in failing,
        do: Plug.Conn.send_resp(conn, 500, "boom"),
        else: Req.Test.json(conn, %{"code" => "200"})
    end
  end

  describe "a failed reconcile does not leave its shard believing it subscribed" do
    test "the symbol is put back, and the retry sends it again", %{limiter: limiter} do
      feed = start_feed(shards: %{0 => connected_shard("s0")})
      failing = recording_plug(self(), [@subscribe_path])

      assert {:error, _reason} =
               Feed.subscribe(feed, ["AAA-USD"], subscribe_opts(limiter, plug: failing))

      assert_receive {:hit, @subscribe_path, ["AAAUSD"]}

      state = :sys.get_state(feed)
      assert state.shards[0].symbols == [], "the shard must not claim what was never subscribed"
      assert MapSet.member?(state.unsettled, 0)
      assert MapSet.member?(state.wanted, "AAA-USD"), "the want itself is not undone"

      # Before the fix this diffed empty and answered :ok without sending anything.
      working = recording_plug(self())
      assert :ok = Feed.subscribe(feed, ["AAA-USD"], subscribe_opts(limiter, plug: working))
      assert_receive {:hit, @subscribe_path, ["AAAUSD"]}

      state = :sys.get_state(feed)
      assert state.shards[0].symbols == ["AAA-USD"]
    end

    test "a background reconcile superseded before it answered has its delta reverted" do
      # Found 2026-10-10: the killed attempt's delta stayed on the shard, and its successor
      # sends only its own, so what the first was carrying was never re-sent.
      feed = start_feed(shards: %{0 => %{connected_shard("s0") | symbols: ["AAA-USD"]}})
      want(feed, ["AAA-USD"])

      stalled = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> if Process.alive?(stalled), do: Process.exit(stalled, :kill) end)

      :sys.replace_state(feed, fn state ->
        context = %{session_id: "s0", added: ["AAA-USD"], removed: []}
        ref = Process.monitor(stalled)
        entry = %{pid: stalled, ref: ref, attempt: make_ref(), context: context}
        %{state | reconciling: Map.put(state.reconciling, {:background, 0}, entry)}
      end)

      # The successor: an empty delta, so it needs no HTTP and cannot restore the symbol.
      send(feed, {:reconcile_shard, 0, "s0", [], [], []})
      _settled = Feed.coverage(feed)

      state = :sys.get_state(feed)
      assert state.shards[0].symbols == [], "the killed attempt's symbol is no longer claimed"
      assert MapSet.member?(state.unsettled, 0), "so the next re-plan sends it again"
    end

    test "a failed unsubscribe does not cancel the subscribe of what was added",
         %{limiter: limiter} do
      feed = start_feed(shards: %{0 => %{connected_shard("s0") | symbols: ["OLD-USD"]}})
      want(feed, ["OLD-USD"])
      failing = recording_plug(self(), [@unsubscribe_path])

      assert {:error, _reason} =
               Feed.update_symbols(feed, ["NEW-USD"], subscribe_opts(limiter, plug: failing))

      assert_receive {:hit, @unsubscribe_path, ["OLDUSD"]}

      assert_receive {:hit, @subscribe_path, ["NEWUSD"]},
                     1_000,
                     "the subscribe must still be attempted when the unsubscribe failed"

      # Reverted: OLD may still be subscribed, so the next plan has to see the difference.
      assert :sys.get_state(feed).shards[0].symbols == ["OLD-USD"]

      working = recording_plug(self())
      assert :ok = Feed.update_symbols(feed, ["NEW-USD"], subscribe_opts(limiter, plug: working))
      assert_receive {:hit, @unsubscribe_path, ["OLDUSD"]}
      assert_receive {:hit, @subscribe_path, ["NEWUSD"]}
      assert :sys.get_state(feed).shards[0].symbols == ["NEW-USD"]
    end
  end

  describe "an answer from a replaced session is not applied to its replacement" do
    test "INVALID_SESSION naming an old session leaves the current shard alone" do
      socket = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> if Process.alive?(socket), do: Process.exit(socket, :kill) end)

      feed =
        start_feed(
          shards: %{0 => %{connected_shard("new-session") | socket: socket, symbols: ["BTC-USD"]}}
        )

      Feed.subscribe_notices(feed, to: self())

      stale = {:error, {:invalid_session, "old-session"}}
      send(feed, {:reconcile_done, {:resubscribe, 0}, stale})
      _settled = Feed.coverage(feed)

      state = :sys.get_state(feed)
      assert state.shards[0].session_id == "new-session", "the healthy shard must survive"
      assert state.shards[0].socket == socket
      assert Process.alive?(socket)
      refute_receive {:dp_exchange, :webull, %Notice{kind: :link_down}}, 100
    end

    test ":oversubscribed measured on an old session does not cap the new one" do
      feed =
        start_feed(
          shards: %{0 => %{connected_shard("new-session") | symbols: ["A-USD", "B-USD"]}}
        )

      # The context a background reconcile for the OLD session was started with.
      :sys.replace_state(feed, fn state ->
        context = %{session_id: "old-session", added: ["B-USD"], removed: []}
        %{state | settled: Map.put(state.settled, {:background, 0}, context)}
      end)

      send(feed, {:reconcile_done, {:background, 0}, {:error, :oversubscribed}})
      _settled = Feed.coverage(feed)

      state = :sys.get_state(feed)
      assert state.shard_capacity == %{}, "an old session's answer measures nothing here"
      assert state.shards[0].symbols == ["A-USD", "B-USD"], "and it reverts nothing here"
      assert state.settled == %{}
    end

    test "a link_up replay answer for an old session does not answer the new shard's callers" do
      feed = start_feed(shards: %{0 => connected_shard("new-session")})
      test_pid = self()
      ref = make_ref()

      :sys.replace_state(feed, fn state ->
        state = put_in(state.shards[0].reply_to, [{{test_pid, ref}, []}])
        %{state | settled: Map.put(state.settled, {:link_up, 0}, %{session_id: "old-session"})}
      end)

      send(feed, {:reconcile_done, {:link_up, 0}, {:error, :boom}})
      _settled = Feed.coverage(feed)

      refute_receive {^ref, _reply}, 100
      assert [{{^test_pid, ^ref}, []}] = :sys.get_state(feed).shards[0].reply_to
    end
  end

  describe "credentials never sit raw in the feed's state" do
    test "an in-flight reconcile's tag carries wrapped credentials", %{limiter: limiter} do
      test_pid = self()

      blocking = fn conn ->
        send(test_pid, :in_flight)
        Process.sleep(:infinity)
        conn
      end

      feed = start_feed(shards: %{0 => connected_shard("s0")})

      opts =
        subscribe_opts(limiter,
          plug: blocking,
          credentials: %{app_key: "KEY-CANARY", app_secret: "SECRET-CANARY"}
        )

      caller = spawn(fn -> Feed.subscribe(feed, ["BTC-USD"], opts) end)
      on_exit(fn -> Process.exit(caller, :kill) end)
      assert_receive :in_flight

      printed = inspect(:sys.get_state(feed), limit: :infinity, printable_limit: :infinity)

      refute printed =~ "SECRET-CANARY"
      refute printed =~ "KEY-CANARY"
      assert map_size(:sys.get_state(feed).reconciling) == 1
    end
  end

  describe "a Trade is delivered but not counted" do
    test "coverage and coverage_by_kind report no :trades, which capabilities do not declare",
         %{limiter: limiter} do
      feed = start_feed()
      :ok = Feed.subscribe(feed, ["BTC-USD"], subscribe_opts(limiter))

      trade = %Trade{
        id: nil,
        symbol: "BTC-USD",
        side: nil,
        price: Decimal.new("1"),
        quantity: Decimal.new("1"),
        timestamp: ~U[2026-10-10 12:00:00Z],
        broken: false,
        provider: :webull
      }

      send(feed, {:dp_exchange, :webull, trade})
      _settled = Feed.coverage(feed)

      assert_receive {:dp_exchange, :webull, %Trade{symbol: "BTC-USD"}}
      assert Feed.coverage(feed) == %{}
      refute Map.has_key?(Feed.coverage_by_kind(feed), :trades)

      reported = Feed.coverage_by_kind(feed) |> Map.keys() |> MapSet.new()
      assert MapSet.subset?(reported, MapSet.new(DpExchange.Webull.capabilities().streamable))
    end
  end

  describe "the priority shard's empty room takes the overflow" do
    # Shard 0 holds 4, shard 1 holds 2, the rest none: 6 in all. One priority symbol pins to
    # shard 0, leaving 3 of its slots. Five others fill shard 1's 2 and, before the fix,
    # refused the remaining 3 although shard 0 had exactly that much room.
    defp capped_priority_feed do
      start_feed(
        shards: %{0 => connected_shard("s0"), 1 => connected_shard("s1")},
        shard_capacity: %{0 => 4, 1 => 2, 2 => 0, 3 => 0, 4 => 0},
        priority_symbols: ["AAA-USD"]
      )
    end

    test "everything that fits somewhere is placed", %{limiter: limiter} do
      feed = capped_priority_feed()
      symbols = ["AAA-USD", "B1-USD", "B2-USD", "B3-USD", "B4-USD", "B5-USD"]
      opts = subscribe_opts(limiter, plug: recording_plug(self()))

      assert :ok = Feed.subscribe(feed, symbols, opts)

      state = :sys.get_state(feed)
      assert hd(state.shards[0].symbols) == "AAA-USD", "the priority symbol is pinned first"
      assert length(state.shards[0].symbols) == 4
      assert length(state.shards[1].symbols) == 2
    end

    test "what genuinely exceeds the total is still refused", %{limiter: limiter} do
      feed = capped_priority_feed()
      symbols = ["AAA-USD", "B1-USD", "B2-USD", "B3-USD", "B4-USD", "B5-USD", "B6-USD"]
      opts = subscribe_opts(limiter, plug: recording_plug(self()))

      assert {:error, {:capacity_exceeded, [_one]}} = Feed.subscribe(feed, symbols, opts)
    end
  end

  describe "a crashed shard is reopened on a cooldown, not in a tight loop" do
    defp crash_shard(feed, symbols) do
      crash_pid = spawn(fn -> Process.sleep(:infinity) end)

      :sys.replace_state(feed, fn state ->
        Process.link(crash_pid)
        session = "crashing-#{System.unique_integer([:positive])}"
        shard = %{connected_shard(session) | socket: crash_pid, symbols: symbols}
        put_in(state.shards[0], shard)
      end)

      Process.exit(crash_pid, :kill)
    end

    test "the first crash reopens at once, a second within the window waits" do
      feed =
        start_feed(shards: %{}, credentials: credentials(), open_retry_base_ms: 800)

      want(feed, ["BTC-USD"])
      Feed.subscribe_notices(feed, to: self())

      crash_shard(feed, ["BTC-USD"])
      assert_receive {:dp_exchange, :webull, %Notice{kind: :link_down}}

      # First crash: delay 0, so a fresh socket is installed without waiting for any timer.
      assert_eventually(fn -> match?(%{0 => %{connected?: false}}, shards(feed)) end)
      assert :sys.get_state(feed).crashes[0].count == 1

      crash_shard(feed, ["BTC-USD"])
      assert_receive {:dp_exchange, :webull, %Notice{kind: :link_down}}

      assert :sys.get_state(feed).crashes[0].count == 2
      refute Map.has_key?(shards(feed), 0), "the second reopen is held back by the cooldown"

      # And it does come back once the cooldown elapses.
      assert_eventually(fn -> Map.has_key?(shards(feed), 0) end, 4_000)
    end

    defp shards(feed), do: :sys.get_state(feed).shards

    defp assert_eventually(fun, budget_ms \\ 2_000) do
      deadline = System.monotonic_time(:millisecond) + budget_ms
      wait_until(fun, deadline)
    end

    defp wait_until(fun, deadline) do
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
  end
end
