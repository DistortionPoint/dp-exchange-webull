defmodule DpExchange.Webull.ResubscribeTimerTest do
  @moduledoc """
  The periodic blind re-assert, and how it behaves against a rate limiter.

  This venue can stop delivering to an already-subscribed, already-connected session with
  nothing wrong to react to, so the timer is the only recovery — and both describes here
  wait out real tick boundaries and real limiter waits to prove it. Split out for wall
  clock; see `DpExchange.Webull.FeedCase`.
  """

  use DpExchange.Webull.FeedCase, async: true

  alias DpExchange.Core.{DefaultRateLimiter, Notice}
  alias DpExchange.Webull.Feed

  describe "the resubscribe timer — DpCryptoManagement issue #17" do
    test "re-issues a connected shard's current subscription with no wanted-set change at all",
         %{limiter: limiter} do
      # The whole point: this venue can stop delivering to an already-subscribed,
      # already-connected session with nothing wrong to react to, so the only recovery
      # is a blind, unconditional re-assert — never gated on whether reshard/4 would see
      # any diff (it would see none here).
      test_pid = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        send(test_pid, {:request, decoded["session_id"], decoded["symbols"]})
        Req.Test.json(conn, %{"code" => "200"})
      end

      shard = %{connected_shard("shard-0") | symbols: ["BTCUSD"]}

      feed =
        start_feed(
          shards: %{0 => shard},
          credentials: credentials(),
          limiter: limiter,
          plug: plug,
          retry_attempts: 0
        )

      :sys.replace_state(feed, &%{&1 | wanted: MapSet.new(["BTC-USD"])})

      send(feed, :resubscribe)

      assert_receive {:request, "shard-0", ["BTCUSD"]}
    end

    test "INVALID_SESSION reopens the shard instead of re-asking the dead session forever",
         %{limiter: limiter} do
      # dp-exchange-core issue #30. `INVALID_SESSION` says the session this subscribe is
      # addressed to no longer exists, so re-sending the identical subscribe is the one
      # action guaranteed not to help — and it is what this Feed did, once a minute, for
      # fourteen hours across all four shards. 1,479 identical warnings; 260 of 325 symbols
      # receiving nothing; a human restarting the feed as the only recovery. The venue was
      # handing out working sessions the whole time.
      #
      # A distinct socket process stands in for the shard's, NOT `self()` the way
      # `connected_shard/1` defaults: the recovery stops that process, and pointing it at
      # the test process would kill the test.
      test_pid = self()
      socket = spawn(fn -> Process.sleep(:infinity) end)
      socket_ref = Process.monitor(socket)

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        session_id = Jason.decode!(body)["session_id"]
        send(test_pid, {:subscribe_attempt, session_id})

        conn
        |> Plug.Conn.put_status(417)
        |> Req.Test.json(%{
          "error_code" => "INVALID_SESSION",
          "message" => "Mqtt connection not exist for session:#{session_id}"
        })
      end

      shard = %{connected_shard("dead-session") | socket: socket, symbols: ["BTCUSD"]}

      feed =
        start_feed(
          shards: %{0 => shard},
          credentials: credentials(),
          limiter: limiter,
          plug: plug,
          retry_attempts: 0,
          # The reopen this triggers is real. Pointed at a closed local port so it fails
          # fast and offline — the assertion here is about the DECISION to reopen, and a
          # tier-1 test must never reach the venue.
          url: "ws://127.0.0.1:1"
        )

      :ok = Feed.subscribe_notices(feed, to: self())
      :sys.replace_state(feed, &%{&1 | wanted: MapSet.new(["BTC-USD"])})

      send(feed, :resubscribe)
      assert_receive {:subscribe_attempt, "dead-session"}, 1_000

      # The stale socket is torn down rather than left holding a connection the venue has
      # already discarded. This venue allows five concurrent connections per App Key, so
      # leaking one per dead session would turn a recoverable outage into an unrecoverable
      # one.
      assert_receive {:DOWN, ^socket_ref, :process, ^socket, _reason}, 1_000

      # Reported as a link_down naming the cause, not latched as an unexplained generic
      # resubscribe failure — a consumer watching notices can now see WHY the shard went
      # dark, which is what fourteen hours of WARN lines never said.
      assert_receive {:dp_exchange, :webull, %Notice{kind: :link_down} = notice}, 1_000
      assert notice.details.session_id == "dead-session"
      assert notice.details.reason =~ "INVALID_SESSION"

      # The defect itself: the next tick must NOT re-ask the same dead session. The shard
      # is gone from state, so there is nothing left addressed to `"dead-session"`.
      send(feed, :resubscribe)
      refute_receive {:subscribe_attempt, "dead-session"}, 300

      assert Process.alive?(feed)
    end

    test "a shard that has never linked up is skipped, not asked to subscribe before it can" do
      plug = fn _conn -> flunk("a shard with no CONNACK yet must never be asked to subscribe") end

      shard = %{
        session_id: "shard-0",
        socket: self(),
        connected?: false,
        symbols: ["BTC-USD"],
        reply_to: nil
      }

      feed = start_feed(shards: %{0 => shard}, plug: plug)

      send(feed, :resubscribe)
      _settled = Feed.coverage(feed)

      assert Process.alive?(feed)
    end

    test "a shard with nothing wanted is skipped, not asked to subscribe to an empty list" do
      plug = fn _conn -> flunk("a shard with nothing wanted must never be asked to subscribe") end
      feed = start_feed(shards: %{0 => connected_shard("shard-0")}, plug: plug)

      send(feed, :resubscribe)
      _settled = Feed.coverage(feed)

      assert Process.alive?(feed)
    end

    test "reschedules itself, so the safety net keeps running rather than firing once",
         %{limiter: limiter} do
      test_pid = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request, Jason.decode!(body)["symbols"]})
        Req.Test.json(conn, %{"code" => "200"})
      end

      shard = %{connected_shard("shard-0") | symbols: ["BTCUSD"]}

      # Driven by the feed's own timer rather than by two hand-sent `:resubscribe` messages.
      # The hand-sent version tested that the handler can run twice, which is not what this
      # test is named for, and it only passed by racing: the second send beat the first
      # attempt's `{:reconcile_done, _}` back to the mailbox, so what it actually exercised
      # was the overlap that issue #3 turned out to be about. A real interval proves the
      # rescheduling this claims to prove, and leaves each attempt time to answer.
      feed =
        start_feed(
          shards: %{0 => shard},
          credentials: credentials(),
          limiter: limiter,
          plug: plug,
          retry_attempts: 0,
          resubscribe_interval_ms: 1_000
        )

      :sys.replace_state(feed, &%{&1 | wanted: MapSet.new(["BTC-USD"])})

      assert_receive {:request, ["BTCUSD"]}, 4_000
      assert_receive {:request, ["BTCUSD"]}, 4_000
    end
  end

  describe "rate_limit_blocking — DpCryptoManagement issue #23" do
    # A limiter with a single, already-spent allowance: `record/3` commits usage the way
    # `acquire/3` does, without `acquire/3`'s own wait — so the bucket starts genuinely
    # empty and the next request against it has to wait out one whole emission interval
    # (~300ms) regardless of which mode reaches it. That wait is the one observable
    # difference between blocking (`acquire/3`, which waits it out and then succeeds) and
    # fail-fast (`check/3`, which refuses immediately and never retries before the next
    # 60-second resubscribe tick) — proving `rate_limit_blocking` actually reaches
    # `Core.HttpClient` through every allowlist between `Feed` and there (`resubscribe_opts`,
    # `replayable/2`, `Subscription.request_opts/1`), not just one of them. A partial fix
    # that stopped at `Feed` would still fail this test, because `Subscription.request_opts/1`
    # would silently strip the option one layer down.
    defp exhausted_limiter do
      name = :"limiter_#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        DefaultRateLimiter.start_link(
          name: name,
          limits: %{default: %{limit: 1, per_ms: 300, burst: 0}}
        )

      :ok = DefaultRateLimiter.record(:webull, 1, limiter: name)
      name
    end

    test "the blind resubscribe defaults to blocking, matching the moduledoc's documented design: a slow tick, not a permanent failure" do
      test_pid = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request, Jason.decode!(body)["symbols"]})
        Req.Test.json(conn, %{"code" => "200"})
      end

      shard = %{connected_shard("shard-0") | symbols: ["BTCUSD"]}

      feed =
        start_feed(
          shards: %{0 => shard},
          credentials: credentials(),
          limiter: exhausted_limiter(),
          plug: plug,
          retry_attempts: 0
        )

      send(feed, :resubscribe)

      # check/3 would refuse immediately and never retry inside this window (the next
      # tick is 60s away) — only acquire/3 (the default) delivers here at all.
      #
      # `exhausted_limiter/0`'s own bucket forces a real ~300ms wait inside `acquire/3`
      # before this request is even sent, on top of the process-hop latency
      # `test_helper.exs`'s `assert_receive_timeout: 1_000` already exists to absorb —
      # so the global default is not enough headroom here specifically. Measured flaky
      # under full-suite load (700 async tests contending for schedulers): failed against
      # the global 1_000ms default while passing in isolation every time. 5_000ms is
      # margin over the ~300ms wait, not a weakened assertion — the test still fails if
      # the message never arrives at all.
      assert_receive {:request, ["BTCUSD"]}, 5_000
    end

    test "a caller can still opt into fail-fast explicitly, and it costs the resubscribe cycle" do
      test_pid = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request, Jason.decode!(body)["symbols"]})
        Req.Test.json(conn, %{"code" => "200"})
      end

      shard = %{connected_shard("shard-0") | symbols: ["BTCUSD"]}

      feed =
        start_feed(
          shards: %{0 => shard},
          credentials: credentials(),
          limiter: exhausted_limiter(),
          plug: plug,
          retry_attempts: 0,
          rate_limit_blocking: false
        )

      send(feed, :resubscribe)

      refute_receive {:request, ["BTCUSD"]}, 1_000
      assert Process.alive?(feed)
    end

    test "a later subscribe's explicit rate_limit_blocking: false overrides the default on the next resubscribe" do
      # Proves replayable/2 — not just init/1's own default — carries an explicit
      # per-call override forward into the next blind resubscribe.
      test_pid = self()
      # Canonical form, matching `wanted` below exactly — unlike the issue #17 tests
      # above, this test also runs `Feed.subscribe/3` (to reach `replayable/2`), and a
      # format mismatch here would make `reshard/4` see a diff that is not really one,
      # triggering a real (unstubbed) HTTP call from inside `Feed.subscribe/3` itself.
      shard = %{connected_shard("shard-0") | symbols: ["BTC-USD"]}
      limiter = exhausted_limiter()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request, Jason.decode!(body)["symbols"]})
        Req.Test.json(conn, %{"code" => "200"})
      end

      feed =
        start_feed(
          shards: %{0 => shard},
          credentials: credentials(),
          limiter: limiter,
          plug: plug,
          retry_attempts: 0
        )

      # Zero-diff subscribe: the shard already carries exactly this symbol, so reshard/4
      # touches nothing and no HTTP call is made here — only `resubscribe_opts` changes,
      # via `replayable/2`.
      :sys.replace_state(feed, &%{&1 | wanted: MapSet.new(["BTC-USD"])})

      :ok =
        Feed.subscribe(feed, ["BTC-USD"], credentials: credentials(), rate_limit_blocking: false)

      send(feed, :resubscribe)

      refute_receive {:request, ["BTCUSD"]}, 1_000
      assert Process.alive?(feed)
    end
  end
end
