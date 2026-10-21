defmodule DpExchange.Webull.TickAbFeedTest do
  @moduledoc """
  Message orderings of `Feed` that a real node can produce and the happy path never does:
  a cleanup that overtakes another, a tick landing on a link-up replay, an answer that belongs
  to a connection the shard has since lost, a reopen that arrives after a re-plan moved its
  symbols, and a caller's delta overtaken by another's.

  Every test forces its interleaving by hand: it writes the in-flight bookkeeping with
  `:sys.replace_state/2`, delivers the late message itself and asserts on settled state, so no
  timing decides an outcome. Margins are 5_000 ms or more.
  """

  use DpExchange.Webull.FeedCase, async: true

  alias DpExchange.Core.Notice
  alias DpExchange.Webull.Feed

  @subscribe_path "/market-data/streaming/subscribe"
  @unsubscribe_path "/market-data/streaming/unsubscribe"

  # `open_socket/2` refuses before it dials when the credentials carry no app key.
  defp unopenable_opts, do: [credentials: %{app_secret: "s"}, retry_attempts: 0]

  defp stalled_pid do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
  end

  defp stalled_entry(context) do
    pid = stalled_pid()
    %{pid: pid, ref: Process.monitor(pid), attempt: make_ref(), context: context}
  end

  # Tells the test which path was hit and with what symbols, then answers.
  defp recording_plug(test_pid) do
    fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      symbols = body |> Jason.decode!() |> Map.fetch!("symbols") |> Enum.sort()
      send(test_pid, {:hit, conn.request_path, symbols})
      Req.Test.json(conn, %{"code" => "200"})
    end
  end

  # As `recording_plug/1`, but holds the request open until the test releases it, so the
  # reconcile it belongs to is still in flight when the next message is delivered.
  defp holding_plug(test_pid) do
    fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      symbols = body |> Jason.decode!() |> Map.fetch!("symbols") |> Enum.sort()
      send(test_pid, {:hit, conn.request_path, symbols})

      receive do
        :release -> :ok
      after
        30_000 -> :ok
      end

      Req.Test.json(conn, %{"code" => "200"})
    end
  end

  # Records what an in-flight attempt under `tag` was sent, as `spawn_reconcile/4` would have.
  defp settle(feed, tag, context),
    do: :sys.replace_state(feed, &put_in(&1.settled[tag], context))

  defp cleanup_tags(feed) do
    feed
    |> :sys.get_state()
    |> Map.fetch!(:reconciling)
    |> Map.keys()
    |> Enum.filter(&match?({:cleanup, _index, _ref}, &1))
  end

  describe "two cleanups for one shard" do
    test "the second does not kill the first before it has sent", %{limiter: limiter} do
      # Interleaving: a blind resubscribe answers `:ok` having sent ETH-USD, which the shard no
      # longer carries, so a cleanup unsubscribes it. Before that request finishes, a link-up
      # replay answers `:ok` having sent SOL-USD, also no longer carried. Both cleanups used the
      # tag `{:cleanup, 0}`, and spawning under a tag tears down whatever runs under it: the
      # first was killed mid-flight and ETH-USD stayed subscribed venue-side for good.
      feed =
        start_feed(
          shards: %{0 => %{connected_shard("s0") | symbols: ["BTC-USD"]}},
          credentials: credentials(),
          limiter: limiter,
          plug: holding_plug(self())
        )

      settle(feed, {:resubscribe, 0}, %{session_id: "s0", sent: ["ETH-USD"]})
      settle(feed, {:link_up, 0}, %{session_id: "s0", sent: ["SOL-USD"]})

      send(feed, {:reconcile_done, {:resubscribe, 0}, :ok})
      assert_receive {:hit, @unsubscribe_path, ["ETHUSD"]}, 5_000

      send(feed, {:reconcile_done, {:link_up, 0}, :ok})
      assert_receive {:hit, @unsubscribe_path, ["SOLUSD"]}, 5_000

      assert [_first, _second] = cleanup_tags(feed)
    end
  end

  describe "a blind-resubscribe tick over a link-up replay still in flight" do
    test "launches no second identical subscribe for the same session", %{limiter: limiter} do
      # Interleaving: the shard's CONNACK arrives, `on_link_up/2` marks it connected and starts
      # the replay of its whole list (`{:link_up, 0}`), and the 60-second tick lands before the
      # venue has answered it. The shard is connected and has delivered nothing yet, so it
      # counted as quiet and was re-asserted on top of the replay.
      feed =
        start_feed(
          shards: %{0 => %{connected_shard("s0") | symbols: ["BTC-USD"]}},
          credentials: credentials(),
          limiter: limiter,
          plug: recording_plug(self())
        )

      replay = stalled_entry(%{session_id: "s0", sent: ["BTC-USD"]})

      :sys.replace_state(feed, fn state ->
        %{state | reconciling: Map.put(state.reconciling, {:link_up, 0}, replay)}
      end)

      send(feed, :resubscribe)
      _settled = Feed.coverage(feed)

      assert Map.keys(:sys.get_state(feed).reconciling) == [{:link_up, 0}]
      refute_receive {:hit, _path, _symbols}, 500
    end

    test "still re-asserts the shard once the replay is gone", %{limiter: limiter} do
      feed =
        start_feed(
          shards: %{0 => %{connected_shard("s0") | symbols: ["BTC-USD"]}},
          credentials: credentials(),
          limiter: limiter,
          plug: recording_plug(self())
        )

      send(feed, :resubscribe)
      assert_receive {:hit, @subscribe_path, ["BTCUSD"]}, 5_000
    end
  end

  describe "INVALID_SESSION for a request made on an earlier connection" do
    setup do
      # A stand-in socket: tearing a shard down stops its socket, and that must not be the
      # test process (`connected_shard/1` defaults to `self()`).
      {:ok, socket: stalled_pid()}
    end

    test "answered while the shard is reconnecting, it does not tear the shard down",
         %{socket: socket} do
      # Interleaving: a blind resubscribe is sent, the socket drops (`link_down`), the venue
      # answers the request `INVALID_SESSION` because the session has no MQTT connection at
      # that instant, and the answer reaches the feed BEFORE the reconnect's CONNACK. The
      # session id still matches, so the answer looked current and the shard was rebuilt.
      shard = %{connected_shard("s0") | connected?: false, socket: socket, symbols: ["BTC-USD"]}
      feed = start_feed(shards: %{0 => shard})
      :ok = Feed.subscribe_notices(feed, to: self())

      settle(feed, {:resubscribe, 0}, %{session_id: "s0"})
      send(feed, {:reconcile_done, {:resubscribe, 0}, {:error, {:invalid_session, "s0"}}})
      _settled = Feed.coverage(feed)

      state = :sys.get_state(feed)
      assert state.shards[0].session_id == "s0"
      assert state.shards[0].socket == socket
      assert Process.alive?(socket)
      refute_receive {:dp_exchange, :webull, %Notice{kind: :link_down}}
    end

    test "answered after the shard reconnected, it does not tear the new connection down",
         %{socket: socket} do
      # Interleaving: the request is sent on connection 1, the socket drops and reconnects
      # (CONNACK, so connection 2 is up and `connected?` is true again), and only then does
      # the connection-1 answer arrive. Same session id, healthy shard: the verdict is about
      # a connection that no longer exists.
      shard = %{connected_shard("s0") | socket: socket, symbols: ["BTC-USD"]}
      feed = start_feed(shards: %{0 => Map.put(shard, :link, 2)})
      :ok = Feed.subscribe_notices(feed, to: self())

      sent_on_connection_one = %{session_id: "s0", sent: ["BTC-USD"], link: 1}
      settle(feed, {:resubscribe, 0}, sent_on_connection_one)
      send(feed, {:reconcile_done, {:resubscribe, 0}, {:error, {:invalid_session, "s0"}}})
      _settled = Feed.coverage(feed)

      state = :sys.get_state(feed)
      assert state.shards[0].socket == socket
      assert Process.alive?(socket)
      refute_receive {:dp_exchange, :webull, %Notice{kind: :link_down}}
      assert state.resubscribe_failed == %{}
    end

    test "answered for the connection the shard has, it still rebuilds the shard",
         %{socket: socket} do
      # The fix must not blunt the recovery it guards: a live, current connection whose
      # session the venue has discarded is rebuilt, as before.
      shard = %{connected_shard("s0") | socket: socket, symbols: ["BTC-USD"]}
      feed = start_feed(shards: %{0 => Map.put(shard, :link, 2)})
      :ok = Feed.subscribe_notices(feed, to: self())

      settle(feed, {:resubscribe, 0}, %{session_id: "s0", sent: [], link: 2})
      send(feed, {:reconcile_done, {:resubscribe, 0}, {:error, {:invalid_session, "s0"}}})

      assert_receive {:dp_exchange, :webull, %Notice{kind: :link_down} = notice}, 5_000
      assert notice.details.session_id == "s0"
    end

    test "every CONNACK moves the shard's connection count on" do
      feed = start_feed(shards: %{0 => %{connected_shard("s0") | connected?: false}})

      send(feed, {:dp_exchange, :webull, link_up("s0")})
      _settled = Feed.coverage(feed)
      first = :sys.get_state(feed).shards[0]
      assert first.connected? and first.link == 1

      send(feed, {:dp_exchange, :webull, link_down("s0")})
      send(feed, {:dp_exchange, :webull, link_up("s0")})
      _settled = Feed.coverage(feed)
      assert :sys.get_state(feed).shards[0].link == 2
    end
  end

  describe "a reopen that arrives after a re-plan moved its symbols" do
    test "does not plan onto the slot a symbol a sibling shard carries now" do
      # Interleaving: shard 1 crashed and its slot is empty (the reopen is queued, or waits out
      # a backoff). A caller's re-plan finds room on shard 0 and moves BBB-USD there. The queued
      # open then arrives carrying shard 1's OLD list, [BBB-USD, CCC-USD], and kept both: BBB-USD
      # ended up on two sessions.
      feed = start_feed(shards: %{0 => %{connected_shard("s0") | symbols: ["BBB-USD"]}})
      want(feed, ["BBB-USD", "CCC-USD"])
      :ok = Feed.subscribe_notices(feed, to: self())

      send(feed, {:open_shard, 1, ["BBB-USD", "CCC-USD"], unopenable_opts()})

      assert_receive {:dp_exchange, :webull, %Notice{kind: :coverage_change} = notice}, 5_000
      assert notice.details.symbol_count == 1
    end
  end

  describe "a caller's delta overtaken by another caller's" do
    test "a subscribe answered after the symbol was unsubscribed is unsubscribed again",
         %{limiter: limiter} do
      # Interleaving: caller A subscribes ETH-USD (task A in flight); caller B unsubscribes it
      # (task B in flight, shard list already without it). The venue processes B first and A
      # last: ETH-USD is subscribed venue-side and absent from `shard.symbols`, so nothing would
      # ever diff it and it would hold one of the session's 100 slots.
      feed =
        start_feed(
          shards: %{0 => %{connected_shard("s0") | symbols: ["BTC-USD"]}},
          credentials: credentials(),
          limiter: limiter,
          plug: recording_plug(self())
        )

      settle(feed, {:background, 0}, %{session_id: "s0", added: ["ETH-USD"], removed: []})

      send(feed, {:reconcile_done, {:background, 0}, :ok})

      assert_receive {:hit, @unsubscribe_path, ["ETHUSD"]}, 5_000
      refute_receive {:hit, @subscribe_path, _symbols}, 500
    end

    test "an unsubscribe answered after the symbol was subscribed again is subscribed again",
         %{limiter: limiter} do
      # The mirror image: A unsubscribes SOL-USD, B re-subscribes it, the venue processes A
      # last, and a wanted symbol is dark. The blind resubscribe re-asserts only a QUIET shard,
      # which one still streaming BTC-USD is not.
      feed =
        start_feed(
          shards: %{0 => %{connected_shard("s0") | symbols: ["BTC-USD", "SOL-USD"]}},
          credentials: credentials(),
          limiter: limiter,
          plug: recording_plug(self())
        )

      settle(feed, {:background, 0}, %{session_id: "s0", added: [], removed: ["SOL-USD"]})

      send(feed, {:reconcile_done, {:background, 0}, :ok})

      assert_receive {:hit, @subscribe_path, ["SOLUSD"]}, 5_000
      refute_receive {:hit, @unsubscribe_path, _symbols}, 500
    end

    test "answers with nothing overtaken send nothing", %{limiter: limiter} do
      feed =
        start_feed(
          shards: %{0 => %{connected_shard("s0") | symbols: ["BTC-USD", "ETH-USD"]}},
          credentials: credentials(),
          limiter: limiter,
          plug: recording_plug(self())
        )

      overtaken = %{session_id: "s0", added: ["ETH-USD"], removed: ["SOL-USD"]}
      settle(feed, {:background, 0}, overtaken)

      send(feed, {:reconcile_done, {:background, 0}, :ok})
      _settled = Feed.coverage(feed)

      # A cleanup would already be tracked: it is spawned inside the handler that ran.
      assert :sys.get_state(feed).reconciling == %{}
      refute_receive {:hit, _path, _symbols}, 500
    end

    test "an answer for a replaced session repairs nothing", %{limiter: limiter} do
      feed =
        start_feed(
          shards: %{0 => %{connected_shard("new") | symbols: ["BTC-USD"]}},
          credentials: credentials(),
          limiter: limiter,
          plug: recording_plug(self())
        )

      settle(feed, {:background, 0}, %{session_id: "old", added: ["ETH-USD"], removed: []})

      send(feed, {:reconcile_done, {:background, 0}, :ok})
      _settled = Feed.coverage(feed)

      assert :sys.get_state(feed).reconciling == %{}
    end
  end
end
