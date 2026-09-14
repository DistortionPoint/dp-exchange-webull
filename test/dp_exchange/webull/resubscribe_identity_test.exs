defmodule DpExchange.Webull.ResubscribeIdentityTest do
  @moduledoc """
  A tick, a deadline and an answer each belong to ONE attempt.

  Split out of `feed_test.exs` for wall clock, not for tidiness. These tests wait on real
  timers — a tick boundary, a deadline expiring, a successor surviving its predecessor's
  deadline — and ExUnit parallelises across FILES but serialises within one. All of them
  living beside ninety other tests meant eight seconds of unavoidable waiting ran end to
  end instead of alongside the rest: that one file took 24.7s while the package's other
  742 tests took 4.5s between them.

  Nothing here is timing-*sensitive*. The margins are deliberately wide (see each test),
  and shrinking them to buy speed is how a suite becomes flaky under load, which this
  family has already paid for three times.
  """

  use DpExchange.Webull.FeedCase, async: true

  alias DpExchange.Webull.Feed

  describe "a tick does not launch a second blind resubscribe over an unfinished one — issue #3" do
    test "the task a reconcile timeout tears down is the task that timer was armed for", %{
      limiter: limiter
    } do
      # `@resubscribe_interval_ms` and `@reconcile_timeout_ms` are both 60_000, and
      # `handle_info(:resubscribe, _)` re-arms its own timer BEFORE spawning, so at every
      # tick boundary the tick is enqueued ahead of the deadline it is racing. The tick was
      # overwriting `reconciling[{:resubscribe, index}]` with a brand-new task, and the
      # previous tick's timer then found that successor under the tag it was armed for and
      # killed it microseconds old — so the blind resubscribe, which is the only recovery
      # this venue has for a silently-stalled session, could never run to completion.
      #
      # Asserted on identity rather than on elapsed time: the invariant is that a deadline
      # tears down the attempt it was armed for and no other, which a timing bound would
      # only ever approximate.
      test_pid = self()

      plug = fn conn ->
        send(test_pid, {:resubscribing, self()})
        Process.sleep(:infinity)
        conn
      end

      feed =
        start_feed(
          shards: %{0 => %{connected_shard("s0") | symbols: ["BTC-USD"]}},
          resubscribe_interval_ms: 1_000,
          reconcile_timeout_ms: 1_000,
          resubscribe_failure_limit: 99,
          credentials: credentials(),
          limiter: limiter,
          plug: plug
        )

      assert_receive {:resubscribing, first_task}, 5_000
      ref = Process.monitor(first_task)

      assert_receive {:DOWN, ^ref, :process, ^first_task, _reason}, 5_000
      assert Process.alive?(feed)
    end
  end

  describe "a reconcile superseded under its own tag — issue #3" do
    test "the superseded attempt is torn down, and its deadline cannot reach its successor",
         %{limiter: limiter} do
      # `{:resubscribe, _}` is now skipped while one is in flight, but `{:link_up, _}` is
      # not and must not be: a shard that links up again genuinely wants the newer replay.
      # `on_link_up/2` is fully re-entrant, so a reconnect arriving while the previous
      # replay is still running lands a second attempt on the same tag.
      #
      # Two things have to hold for that to be safe, and neither did. The superseded attempt
      # must be TORN DOWN rather than orphaned — an orphan's monitor ref belongs to nothing,
      # so its `:DOWN` reaches `drop_dead_subscriber/2` as though a subscriber had died, and
      # if it ever answers, the `{:reconcile_done, tag, _}` clause forgets its successor and
      # hands that successor's callers a stale result. And the superseded attempt's DEADLINE
      # must not reach the successor now holding the tag, which is what `ref` in the timeout
      # message is for.
      test_pid = self()

      plug = fn conn ->
        send(test_pid, {:replaying, self()})
        Process.sleep(:infinity)
        conn
      end

      feed =
        start_feed(
          shards: %{
            0 => %{connected_shard("s0") | symbols: ["BTCUSD"], connected?: false}
          },
          reconcile_timeout_ms: 2_000,
          credentials: credentials(),
          limiter: limiter,
          plug: plug
        )

      send(feed, {:dp_exchange, :webull, link_up("s0")})

      # The attempt's pid is read from the feed's own state, NOT from the plug's message.
      #
      # Waiting on the plug meant waiting for a whole HTTP path to be scheduled and entered
      # inside a two-second deadline that this same test configures — which is a race the
      # test sets up against itself, and it lost it 6 runs in 35 under the full suite. The
      # deadline is armed when the attempt is SPAWNED, not when its request reaches the
      # plug, so nothing about the timing below depends on how fast that path gets going;
      # only the test's knowledge of the pid did, and the feed already has it.
      first = reconcile_pid(feed)
      first_ref = Process.monitor(first)

      # Long enough that the first attempt's deadline lands INSIDE the refute window below
      # while the second attempt holds the tag, and far enough from the second's own
      # deadline that the two cannot be confused for each other.
      Process.sleep(1_200)

      send(feed, {:dp_exchange, :webull, link_up("s0")})
      second = reconcile_pid(feed, first)
      second_ref = Process.monitor(second)

      assert_receive {:DOWN, ^first_ref, :process, ^first, _reason}, 1_000

      refute_receive {:DOWN, ^second_ref, :process, ^second, _reason}, 1_200

      assert map_size(:sys.get_state(feed).reconciling) == 1,
             "one tag, one tracked attempt — the superseded one must not still be counted"

      assert Process.alive?(feed)
    end

    # The pid of the single in-flight reconcile attempt, once one is there and (when
    # `unless_pid` is given) once it is a DIFFERENT attempt from the one named.
    #
    # `:sys.get_state/1` is an ordinary call answered by the feed itself, so this observes
    # the spawn directly instead of inferring it from something the spawned work later did.
    defp reconcile_pid(feed, unless_pid \\ nil, waited \\ 0) do
      pid =
        case Map.values(:sys.get_state(feed).reconciling) do
          [%{pid: pid}] when pid != unless_pid -> pid
          _none_or_stale -> nil
        end

      cond do
        pid -> pid
        waited >= 2_000 -> flunk("no new reconcile attempt after 2000ms")
        true -> Process.sleep(5) && reconcile_pid(feed, unless_pid, waited + 5)
      end
    end
  end

  describe "an answer is routed by the attempt that produced it, not by its tag — issue #3" do
    test "a superseded attempt's answer does not settle its successor's tag" do
      # The window tearing the superseded attempt down cannot close: `send/2` completes
      # before the kill does, so an attempt that answers between its successor's trigger
      # arriving and that trigger being PROCESSED has already put its result in the mailbox.
      # Routed by tag alone, that stale result forgets the successor — demonitoring it and
      # dropping its bookkeeping — and is then handed to the successor's callers as theirs.
      feed = start_feed(shards: %{0 => connected_shard("s0")}, resubscribe_failure_limit: 99)

      live = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> if Process.alive?(live), do: Process.exit(live, :kill) end)

      current = %{pid: live, ref: Process.monitor(live), attempt: make_ref()}

      :sys.replace_state(feed, fn state ->
        %{state | reconciling: Map.put(state.reconciling, {:resubscribe, 0}, current)}
      end)

      # The answer a superseded predecessor left behind: same tag, its own attempt.
      send(feed, {:reconcile_done, {:resubscribe, 0}, make_ref(), {:error, :stale}})
      _settled = Feed.coverage(feed)

      assert :sys.get_state(feed).reconciling[{:resubscribe, 0}] == current,
             "the successor must still be tracked, with its deadline still its own"

      refute Map.has_key?(:sys.get_state(feed).resubscribe_failed, 0),
             "a predecessor's failure must not be counted against its successor"

      assert Process.alive?(feed)
    end

    test "an answer arriving after its tag was settled is dropped, not applied twice" do
      # A deadline that has already been reported as `:no_venue_response` is not retracted by
      # the answer turning up afterwards. The caller has been answered and the failure
      # counted; applying the late result would un-count it and make a shard that is
      # reliably too slow indistinguishable from one that is healthy.
      feed = start_feed(shards: %{0 => connected_shard("s0")}, resubscribe_failure_limit: 99)

      send(feed, {:reconcile_done, {:resubscribe, 0}, {:error, :boom}})
      _settled = Feed.coverage(feed)
      assert :sys.get_state(feed).resubscribe_failed == %{0 => 1}

      # Nothing is tracked under the tag now. A task's own answer arriving late must not
      # reach the success path and reset what the deadline already recorded.
      send(feed, {:reconcile_done, {:resubscribe, 0}, make_ref(), :ok})
      _settled = Feed.coverage(feed)

      assert :sys.get_state(feed).resubscribe_failed == %{0 => 1}
      assert Process.alive?(feed)
    end
  end
end
