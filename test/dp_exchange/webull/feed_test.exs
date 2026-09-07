defmodule DpExchange.Webull.FeedTest do
  use ExUnit.Case, async: true

  alias DpExchange.Core.{Config, DefaultRateLimiter, Notice}
  alias DpExchange.Core.Types.{Quote, TopOfBook}
  alias DpExchange.Webull.Feed

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

    # The feed's HTTP subscribe runs inside the GenServer, so a real limiter is started
    # and named rather than relying on a process-scoped override the feed cannot see.
    limiter = :"limiter_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      DefaultRateLimiter.start_link(
        name: limiter,
        limits: %{default: %{limit: 1000, per_ms: 1000, burst: 1000}}
      )

    {:ok, limiter: limiter}
  end

  @credentials %{app_key: "k", app_secret: "s"}

  # The HTTP half of subscribing, answered without a network. Every subscribe on this
  # venue is a REST call, so a feed test that did not stub one would reach the venue.
  defp subscribe_opts(limiter, extra \\ []) do
    plug = fn conn -> Req.Test.json(conn, %{"code" => "200"}) end

    Keyword.merge(
      [credentials: @credentials, plug: plug, retry_attempts: 0, limiter: limiter],
      extra
    )
  end

  # A pre-connected shard 0, standing in for one that already opened and saw its
  # CONNACK — what every test below except the ones about the connecting window itself
  # wants to assume. `session_id` is overridable because one test asserts on it.
  defp connected_shard(session_id \\ nil) do
    %{
      session_id: session_id || "session-#{System.unique_integer([:positive])}",
      socket: self(),
      connected?: true,
      symbols: [],
      reply_to: nil
    }
  end

  # A real pid, guaranteed dead by the time it is used — `Socket.disconnect/2` must
  # answer with `{:error, :not_alive}` for one rather than raise, and asserting on that
  # from here doubles as an observable signal that `terminate/2` actually attempted the
  # shard: a shard it skips never calls `disconnect/2` at all, so it never logs.
  defp dead_pid do
    pid = spawn(fn -> :ok end)
    # Not pinned to `:normal` — the process can finish and exit before `Process.monitor/1`
    # runs, in which case the monitor reports `:noproc` instead. Either way it is dead,
    # which is all this helper promises. See `SocketTest`'s matching helper.
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    pid
  end

  defp start_feed(opts \\ []) do
    name = :"feed_#{System.unique_integer([:positive])}"
    defaults = [name: name, shards: %{0 => connected_shard()}]
    {:ok, pid} = Feed.start_link(Keyword.merge(defaults, opts))
    pid
  end

  defp quote_for(symbol) do
    %Quote{
      symbol: symbol,
      price: Decimal.new("1"),
      timestamp: ~U[2026-08-28 12:00:00Z],
      provider: :webull
    }
  end

  defp top_of_book_for(symbol) do
    %TopOfBook{
      symbol: symbol,
      bid: Decimal.new("1"),
      ask: Decimal.new("2"),
      bid_size: nil,
      ask_size: nil,
      venue_time: ~U[2026-08-28 12:00:00Z],
      observed_at: ~U[2026-08-28 12:00:00Z],
      provider: :webull
    }
  end

  defp link_up(session_id), do: Notice.new(:link_up, :webull, details: %{session_id: session_id})

  defp link_down(session_id),
    do: Notice.new(:link_down, :webull, details: %{session_id: session_id})

  describe "the two transports are joined by one session id" do
    test "the shard's own session id is used for the HTTP subscribe", %{limiter: limiter} do
      # A mismatch fails in the most expensive way available: the HTTP call succeeds, the
      # broker publishes to a session nobody listens on, and the socket sits connected and
      # idle with no error anywhere.
      test_pid = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:subscribed, Jason.decode!(body)})
        Req.Test.json(conn, %{"code" => "200"})
      end

      feed = start_feed(shards: %{0 => connected_shard("fixed-session")})
      :ok = Feed.subscribe(feed, ["BTC-USD"], subscribe_opts(limiter, plug: plug))

      assert_receive {:subscribed, body}
      assert body["session_id"] == "fixed-session"
      assert body["symbols"] == ["BTCUSD"]
    end
  end

  describe "coverage is observed, never intended" do
    test "a subscribed symbol that has delivered nothing is absent", %{limiter: limiter} do
      # On this venue there are three distinct moments: asked, HTTP-accepted, delivering.
      # Only the last means data.
      feed = start_feed()
      :ok = Feed.subscribe(feed, ["BTC-USD"], subscribe_opts(limiter))

      assert Feed.coverage(feed) == %{}
    end

    test "a symbol appears once a payload arrives", %{limiter: limiter} do
      feed = start_feed()
      :ok = Feed.subscribe(feed, ["BTC-USD"], subscribe_opts(limiter))

      send(feed, {:dp_exchange, :webull, quote_for("BTC-USD")})
      _settled = Feed.coverage(feed)

      assert Feed.coverage(feed) == %{"BTC-USD" => :stream}
    end
  end

  describe "coverage by kind — this venue's two streamed kinds are independent" do
    test "a symbol delivering a snapshot appears under :quotes", %{limiter: limiter} do
      feed = start_feed()
      :ok = Feed.subscribe(feed, ["BTC-USD"], subscribe_opts(limiter))

      send(feed, {:dp_exchange, :webull, quote_for("BTC-USD")})
      _settled = Feed.coverage(feed)

      assert Feed.coverage_by_kind(feed) == %{quotes: %{"BTC-USD" => :stream}}
    end

    test "a symbol delivering a book message appears under :top_of_book", %{limiter: limiter} do
      feed = start_feed()
      :ok = Feed.subscribe(feed, ["BTC-USD"], subscribe_opts(limiter))

      send(feed, {:dp_exchange, :webull, top_of_book_for("BTC-USD")})
      _settled = Feed.coverage(feed)

      assert Feed.coverage_by_kind(feed) == %{top_of_book: %{"BTC-USD" => :stream}}
    end

    test "the two kinds are genuinely isolated: one symbol's snapshot topic can be dark " <>
           "while its book topic stays healthy, and the reverse",
         %{limiter: limiter} do
      # Nothing in `Socket` or `Feed` requires both topics to arrive for the same symbol —
      # each is decoded and forwarded independently. This is reachable on the real
      # delivery path, not a manufactured case: a venue can genuinely stop publishing one
      # topic for a symbol while the other keeps arriving.
      feed = start_feed()
      :ok = Feed.subscribe(feed, ["BTC-USD", "ETH-USD"], subscribe_opts(limiter))

      # BTC-USD: snapshot only. ETH-USD: book only.
      send(feed, {:dp_exchange, :webull, quote_for("BTC-USD")})
      send(feed, {:dp_exchange, :webull, top_of_book_for("ETH-USD")})
      _settled = Feed.coverage(feed)

      by_kind = Feed.coverage_by_kind(feed)

      assert by_kind[:quotes] == %{"BTC-USD" => :stream}
      assert by_kind[:top_of_book] == %{"ETH-USD" => :stream}
      refute Map.has_key?(by_kind[:quotes], "ETH-USD")
      refute Map.has_key?(by_kind[:top_of_book], "BTC-USD")
    end

    test "a symbol delivering both kinds appears under both, and the union matches coverage/1",
         %{limiter: limiter} do
      feed = start_feed()
      :ok = Feed.subscribe(feed, ["BTC-USD"], subscribe_opts(limiter))

      send(feed, {:dp_exchange, :webull, quote_for("BTC-USD")})
      send(feed, {:dp_exchange, :webull, top_of_book_for("BTC-USD")})
      _settled = Feed.coverage(feed)

      by_kind = Feed.coverage_by_kind(feed)
      union = by_kind |> Map.values() |> Enum.flat_map(&Map.keys/1) |> Enum.uniq() |> Enum.sort()

      assert union == Feed.coverage(feed) |> Map.keys() |> Enum.sort()
    end

    test "unsubscribing a symbol drops it from every kind it appeared under", %{limiter: limiter} do
      feed = start_feed()
      :ok = Feed.subscribe(feed, ["BTC-USD"], subscribe_opts(limiter))

      send(feed, {:dp_exchange, :webull, quote_for("BTC-USD")})
      send(feed, {:dp_exchange, :webull, top_of_book_for("BTC-USD")})
      _settled = Feed.coverage(feed)

      :ok = Feed.unsubscribe(feed, ["BTC-USD"], subscribe_opts(limiter))

      assert Feed.coverage_by_kind(feed) == %{quotes: %{}, top_of_book: %{}}
    end

    test "every kind key this venue reports is one its own capabilities declare streamable",
         %{limiter: limiter} do
      feed = start_feed()
      :ok = Feed.subscribe(feed, ["BTC-USD"], subscribe_opts(limiter))

      send(feed, {:dp_exchange, :webull, quote_for("BTC-USD")})
      send(feed, {:dp_exchange, :webull, top_of_book_for("BTC-USD")})
      _settled = Feed.coverage(feed)

      reported = Feed.coverage_by_kind(feed) |> Map.keys() |> MapSet.new()
      declared = MapSet.new(DpExchange.Webull.capabilities().streamable)

      assert MapSet.subset?(reported, declared)
    end
  end

  describe "reconnects replay the subscription, because the venue does not" do
    test "a link_up notice triggers a re-subscribe for everything wanted on that shard",
         %{limiter: limiter} do
      test_pid = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:subscribed, Jason.decode!(body)["symbols"]})
        Req.Test.json(conn, %{"code" => "200"})
      end

      session_id = "reconnect-session"
      feed = start_feed(shards: %{0 => connected_shard(session_id)})
      :ok = Feed.subscribe(feed, ["BTC-USD"], subscribe_opts(limiter, plug: plug))
      assert_receive {:subscribed, ["BTCUSD"]}

      # A fresh link on the same shard. The venue restores nothing, so the feed must.
      send(feed, {:dp_exchange, :webull, link_up(session_id)})

      assert_receive {:subscribed, ["BTCUSD"]}
    end

    test "a link_up for a session this feed no longer tracks is ignored", %{limiter: _limiter} do
      feed = start_feed()

      send(feed, {:dp_exchange, :webull, link_up("some-other-session")})
      _settled = Feed.coverage(feed)

      assert Process.alive?(feed)
    end

    test "a reconnect with nothing wanted sends no request", %{limiter: _limiter} do
      session_id = "quiet-session"
      feed = start_feed(shards: %{0 => connected_shard(session_id)})

      send(feed, {:dp_exchange, :webull, link_up(session_id)})
      _settled = Feed.coverage(feed)

      assert Process.alive?(feed)
    end
  end

  describe "UAT has no broker" do
    test "subscribing there refuses instead of using the production stream", %{limiter: limiter} do
      # A consumer testing against UAT that received production prices would be reading
      # real market data believing it was fake.
      feed = start_feed()

      assert {:error, {:streaming_unavailable, :uat}} =
               Feed.subscribe(feed, ["BTC-USD"], subscribe_opts(limiter, environment: :uat))
    end

    test "and nothing is registered as wanted", %{limiter: limiter} do
      feed = start_feed()
      _refused = Feed.subscribe(feed, ["BTC-USD"], subscribe_opts(limiter, environment: :uat))

      assert Feed.coverage(feed) == %{}
    end
  end

  describe "app_key must come from the caller's own credentials" do
    test "a subscribe with no usable app_key is refused rather than opening a socket with an empty one",
         %{limiter: limiter} do
      # No pre-seeded shard here — this exercises the path that actually opens one, which
      # needs a real app_key. Silently defaulting to "" would connect and then sit
      # unauthenticated instead of failing where the caller can see it.
      name = :"feed_#{System.unique_integer([:positive])}"
      {:ok, feed} = Feed.start_link(name: name)

      assert {:error, {:missing_required_field, :app_key}} =
               Feed.subscribe(feed, ["BTC-USD"], subscribe_opts(limiter, credentials: %{}))
    end

    test "a subscribe with a real app_key proceeds to actually open a socket", %{
      limiter: limiter
    } do
      # An unreachable local address, so the refusal this asserts is unambiguously the
      # connection failing rather than the app_key check — proving app_key was read from
      # credentials and reached Socket.start_link rather than being refused up front.
      name = :"feed_#{System.unique_integer([:positive])}"
      {:ok, feed} = Feed.start_link(name: name, url: "ws://127.0.0.1:1/nowhere")

      assert {:error, reason} = Feed.subscribe(feed, ["BTC-USD"], subscribe_opts(limiter))
      refute reason == {:missing_required_field, :app_key}
    end
  end

  describe "a subscribe against a freshly-opening shard waits for the CONNACK" do
    test "the reply is deferred until that shard's :link_up, not sent the moment the socket exists",
         %{limiter: limiter} do
      # `connected?: false` alongside a pre-seeded shard models the window between the
      # socket process starting and the venue's CONNACK arriving — the exact window the
      # old single-connection code skipped past by treating "a socket pid exists" as
      # "ready".
      session_id = "connecting-session"

      shard = %{
        session_id: session_id,
        socket: self(),
        connected?: false,
        symbols: [],
        reply_to: nil
      }

      name = :"feed_#{System.unique_integer([:positive])}"
      {:ok, feed} = Feed.start_link(name: name, shards: %{0 => shard})

      test_pid = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:subscribed, Jason.decode!(body)["symbols"]})
        Req.Test.json(conn, %{"code" => "200"})
      end

      task =
        Task.async(fn ->
          Feed.subscribe(feed, ["BTC-USD"], subscribe_opts(limiter, plug: plug))
        end)

      refute_receive {:subscribed, _symbols}, 200
      refute Task.yield(task, 0)

      send(feed, {:dp_exchange, :webull, link_up(session_id)})

      assert_receive {:subscribed, ["BTCUSD"]}
      assert {:ok, :ok} = Task.yield(task, 1_000)
    end

    test "a link_down clears that shard's :connected?, so the next subscribe waits again", %{
      limiter: limiter
    } do
      session_id = "flapping-session"
      feed = start_feed(shards: %{0 => connected_shard(session_id)})
      :ok = Feed.subscribe(feed, ["BTC-USD"], subscribe_opts(limiter))

      send(feed, {:dp_exchange, :webull, link_down(session_id)})
      # Synchronise on the notice having been handled before subscribing again.
      _settled = Feed.coverage(feed)

      task =
        Task.async(fn ->
          Feed.subscribe(feed, ["ETH-USD"], subscribe_opts(limiter))
        end)

      refute Task.yield(task, 200)

      send(feed, {:dp_exchange, :webull, link_up(session_id)})

      assert {:ok, :ok} = Task.yield(task, 1_000)
    end
  end

  describe "fan-out" do
    test "a quote reaches the subscriber", %{limiter: limiter} do
      feed = start_feed()
      :ok = Feed.subscribe(feed, ["BTC-USD"], subscribe_opts(limiter))

      send(feed, {:dp_exchange, :webull, quote_for("BTC-USD")})

      assert_receive {:dp_exchange, :webull, %Quote{symbol: "BTC-USD"}}
    end

    test "notices go to notice subscribers", %{limiter: _limiter} do
      feed = start_feed()
      :ok = Feed.subscribe_notices(feed, to: self())

      send(feed, {:dp_exchange, :webull, Notice.new(:degraded, :webull)})

      assert_receive {:dp_exchange, :webull, %Notice{kind: :degraded}}
    end

    test "a dead subscriber does not stop delivery to a live one", %{limiter: limiter} do
      feed = start_feed()
      dead = spawn(fn -> :ok end)
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, :process, ^dead, _reason}

      :ok = Feed.subscribe(feed, ["BTC-USD"], subscribe_opts(limiter, to: dead))
      :ok = Feed.subscribe(feed, ["BTC-USD"], subscribe_opts(limiter, to: self()))

      send(feed, {:dp_exchange, :webull, quote_for("BTC-USD")})

      assert_receive {:dp_exchange, :webull, %Quote{}}
    end

    test "a subscriber registered by name (not a raw pid) is delivered to rather than crashing the feed",
         %{limiter: limiter} do
      # Filed as a live bug on the sibling Coinbase package: Process.alive?/1 only
      # accepts a pid and raises on anything else, so a consumer that registers itself
      # under a name and hands that name to `to:` — ordinary OTP practice — crashed the
      # whole feed on the very first delivery.
      name = :"webull_feed_test_subscriber_#{System.unique_integer([:positive])}"
      Process.register(self(), name)
      feed = start_feed()

      :ok = Feed.subscribe(feed, ["BTC-USD"], subscribe_opts(limiter, to: name))
      send(feed, {:dp_exchange, :webull, quote_for("BTC-USD")})

      assert_receive {:dp_exchange, :webull, %Quote{}}
      assert Process.alive?(feed)

      Process.unregister(name)
    end

    test "a name that is not (or no longer) registered is silently skipped, not a crash",
         %{limiter: limiter} do
      name = :"webull_feed_test_unregistered_#{System.unique_integer([:positive])}"
      refute Process.whereis(name)
      feed = start_feed()

      :ok = Feed.subscribe(feed, ["BTC-USD"], subscribe_opts(limiter, to: name))
      send(feed, {:dp_exchange, :webull, quote_for("BTC-USD")})
      # A GenServer.call queues behind the earlier `send` in the mailbox, so its answer
      # is proof the fan_out/2 for the send above already ran — not a fixed sleep that
      # may or may not outlast it on a loaded runner.
      _settled = Feed.coverage(feed)

      assert Process.alive?(feed)
    end
  end

  describe "unsubscribe and update" do
    test "unsubscribing drops the symbol from coverage", %{limiter: limiter} do
      feed = start_feed()
      :ok = Feed.subscribe(feed, ["BTC-USD"], subscribe_opts(limiter))
      send(feed, {:dp_exchange, :webull, quote_for("BTC-USD")})
      _settled = Feed.coverage(feed)

      :ok = Feed.unsubscribe(feed, ["BTC-USD"], subscribe_opts(limiter))

      assert Feed.coverage(feed) == %{}
    end

    test "update_symbols narrows to the new set", %{limiter: limiter} do
      feed = start_feed()
      :ok = Feed.subscribe(feed, ["BTC-USD", "ETH-USD"], subscribe_opts(limiter))
      send(feed, {:dp_exchange, :webull, quote_for("BTC-USD")})
      send(feed, {:dp_exchange, :webull, quote_for("ETH-USD")})
      _settled = Feed.coverage(feed)

      :ok = Feed.update_symbols(feed, ["BTC-USD"], subscribe_opts(limiter))

      assert Feed.coverage(feed) == %{"BTC-USD" => :stream}
    end

    test "an empty symbol list makes no request at all", %{limiter: limiter} do
      # Asking the venue to subscribe to nothing spends a call from the budget this venue
      # is already tightest on.
      feed = start_feed()

      plug = fn _conn -> flunk("a request was made for an empty symbol list") end

      assert :ok = Feed.unsubscribe(feed, [], subscribe_opts(limiter, plug: plug))
    end

    test "unsubscribing a symbol never subscribed makes no request and does not error",
         %{limiter: limiter} do
      feed = start_feed()

      plug = fn _conn -> flunk("a request was made for a never-subscribed symbol") end

      assert :ok =
               Feed.unsubscribe(feed, ["NEVER-SUBSCRIBED"], subscribe_opts(limiter, plug: plug))
    end
  end

  describe "unknown messages" do
    test "an unexpected call is refused rather than crashing the feed", %{limiter: _limiter} do
      feed = start_feed()

      assert GenServer.call(feed, :nonsense) == {:error, :unknown_call}
      assert Process.alive?(feed)
    end

    test "an unexpected info is ignored", %{limiter: _limiter} do
      feed = start_feed()

      send(feed, :something_else)

      assert Feed.coverage(feed) == %{}
    end
  end

  describe "sharding: more than one session's worth of symbols" do
    test "150 symbols across a fresh feed spans two shards, and the primary shard's outcome is the reply",
         %{limiter: limiter} do
      test_pid = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        send(test_pid, {:subscribed, decoded["session_id"], length(decoded["symbols"])})
        Req.Test.json(conn, %{"code" => "200"})
      end

      shard0 = connected_shard("shard-0")
      shard1 = connected_shard("shard-1")
      feed = start_feed(shards: %{0 => shard0, 1 => shard1})

      symbols = for i <- 1..150, do: "SYM#{i}-USD"
      assert :ok = Feed.subscribe(feed, symbols, subscribe_opts(limiter, plug: plug))

      assert_receive {:subscribed, "shard-0", 100}
      assert_receive {:subscribed, "shard-1", 50}
    end

    test "a shard that rejects as oversubscribed moves the overflow to another shard, invisibly to the caller",
         %{limiter: limiter} do
      # `shard_capacity: %{0 => 2}` stands in for this package's own accounting being
      # wrong about what shard 0 can actually carry — the venue's real answer, simulated
      # by the plug below, is 1. The host never sees a session id or a shard index, and
      # per the design doc §3.5 it must not see this rejection either: the retry inside
      # reshard/4 is what makes the caller's own reply a clean :ok despite the venue
      # having refused the first attempt.
      test_pid = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        send(test_pid, {:request, conn.request_path, decoded["session_id"], decoded["symbols"]})

        if decoded["session_id"] == "shard-0" and
             conn.request_path == "/market-data/streaming/subscribe" and
             length(decoded["symbols"]) > 1 do
          conn
          |> Plug.Conn.put_status(417)
          |> Req.Test.json(%{"error_code" => "TOO_MANY_SYMBOLS_SUBSCRIPTION"})
        else
          Req.Test.json(conn, %{"code" => "200"})
        end
      end

      shard0 = connected_shard("shard-0")
      shard1 = connected_shard("shard-1")

      feed =
        start_feed(shards: %{0 => shard0, 1 => shard1}, shard_capacity: %{0 => 2})

      assert :ok =
               Feed.subscribe(feed, ["AAA-USD", "BBB-USD"], subscribe_opts(limiter, plug: plug))

      # The rejected attempt (both symbols on shard 0)...
      assert_receive {:request, "/market-data/streaming/subscribe", "shard-0",
                      ["AAAUSD", "BBBUSD"]}

      # ...the retry that trims shard 0 back down to what it actually measured...
      assert_receive {:request, "/market-data/streaming/unsubscribe", "shard-0", ["BBBUSD"]}

      # ...and the overflow landing on shard 1, all without the caller seeing a refusal.
      assert_receive {:request, "/market-data/streaming/subscribe", "shard-1", ["BBBUSD"]}
    end

    test "a link_down for a session this feed no longer tracks is ignored", %{limiter: _limiter} do
      feed = start_feed()

      send(feed, {:dp_exchange, :webull, link_down("some-other-session")})
      _settled = Feed.coverage(feed)

      assert Process.alive?(feed)
    end

    test "five shards already at capacity refuse a sixth symbol as capacity_exceeded, never silently dropped or oversubscribed",
         %{limiter: limiter} do
      # Every shard capped at 1 and already carrying its one symbol models the venue's
      # real, hard ceiling being reached — the one case §3.5 says cannot be absorbed
      # internally. No HTTP call should even be attempted: nothing about any existing
      # shard's symbol set changes.
      plug = fn _conn -> flunk("no shard's symbol set changes; no request should fire") end

      existing = for i <- 0..4, do: {i, "S#{i}-USD"}

      shards =
        Map.new(existing, fn {i, symbol} ->
          {i, %{connected_shard("s-#{i}") | symbols: [symbol]}}
        end)

      capacity = Map.new(existing, fn {i, _symbol} -> {i, 1} end)

      feed = start_feed(shards: shards, shard_capacity: capacity)
      existing_symbols = Enum.map(existing, fn {_i, symbol} -> symbol end)
      :sys.replace_state(feed, &%{&1 | wanted: MapSet.new(existing_symbols)})

      assert {:error, {:capacity_exceeded, ["ZZZ-USD"]}} =
               Feed.subscribe(feed, ["ZZZ-USD"], subscribe_opts(limiter, plug: plug))
    end

    test "an oversubscribed rejection discovered on a shard's own CONNACK rebalances via resync, not the caller's retry",
         %{limiter: limiter} do
      # `connected?: false` on shard 0 means the subscribe below defers instead of
      # attempting anything — the actual (and, here, rejected) subscribe only happens
      # once :link_up fires, which is the on_link_up/2 path rather than the synchronous
      # retry in reshard/4. Unlike that synchronous path, this one does not retry before
      # answering the original caller — see the moduledoc note on that scope.
      test_pid = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        send(test_pid, {:request, conn.request_path, decoded["session_id"], decoded["symbols"]})

        if decoded["session_id"] == "shard-0" and
             conn.request_path == "/market-data/streaming/subscribe" and
             length(decoded["symbols"]) > 1 do
          conn
          |> Plug.Conn.put_status(417)
          |> Req.Test.json(%{"error_code" => "TOO_MANY_SYMBOLS_SUBSCRIPTION"})
        else
          Req.Test.json(conn, %{"code" => "200"})
        end
      end

      shard0 = %{
        session_id: "shard-0",
        socket: self(),
        connected?: false,
        symbols: [],
        reply_to: nil
      }

      shard1 = connected_shard("shard-1")

      feed =
        start_feed(shards: %{0 => shard0, 1 => shard1}, shard_capacity: %{0 => 2})

      task =
        Task.async(fn ->
          Feed.subscribe(feed, ["AAA-USD", "BBB-USD"], subscribe_opts(limiter, plug: plug))
        end)

      refute Task.yield(task, 100)

      send(feed, {:dp_exchange, :webull, link_up("shard-0")})

      # The rejected attempt, surfaced to the original caller as-is...
      assert {:ok, {:error, :oversubscribed}} = Task.yield(task, 1_000)

      assert_receive {:request, "/market-data/streaming/subscribe", "shard-0",
                      ["AAAUSD", "BBBUSD"]}

      # ...and resync/1 moving the overflow to shard 1 in the background regardless.
      assert_receive {:request, "/market-data/streaming/unsubscribe", "shard-0", ["BBBUSD"]}
      assert_receive {:request, "/market-data/streaming/subscribe", "shard-1", ["BBBUSD"]}
    end
  end

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
          credentials: @credentials,
          limiter: limiter,
          plug: plug,
          retry_attempts: 0
        )

      :sys.replace_state(feed, &%{&1 | wanted: MapSet.new(["BTC-USD"])})

      send(feed, :resubscribe)

      assert_receive {:request, "shard-0", ["BTCUSD"]}
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

      feed =
        start_feed(
          shards: %{0 => shard},
          credentials: @credentials,
          limiter: limiter,
          plug: plug,
          retry_attempts: 0
        )

      :sys.replace_state(feed, &%{&1 | wanted: MapSet.new(["BTC-USD"])})

      send(feed, :resubscribe)
      assert_receive {:request, ["BTCUSD"]}

      send(feed, :resubscribe)
      assert_receive {:request, ["BTCUSD"]}
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
          credentials: @credentials,
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
          credentials: @credentials,
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
          credentials: @credentials,
          limiter: limiter,
          plug: plug,
          retry_attempts: 0
        )

      # Zero-diff subscribe: the shard already carries exactly this symbol, so reshard/4
      # touches nothing and no HTTP call is made here — only `resubscribe_opts` changes,
      # via `replayable/2`.
      :sys.replace_state(feed, &%{&1 | wanted: MapSet.new(["BTC-USD"])})

      :ok =
        Feed.subscribe(feed, ["BTC-USD"], credentials: @credentials, rate_limit_blocking: false)

      send(feed, :resubscribe)

      refute_receive {:request, ["BTCUSD"]}, 1_000
      assert Process.alive?(feed)
    end
  end

  describe "a shard socket crash is isolated to its own shard — W2" do
    test "an abnormal exit from one shard's socket does not take down the feed or other shards" do
      # A real link, the same relationship `Socket.start_link/1` -> `WebSockex.start_link/4`
      # creates for real. Before W2, `Feed` did not trap exits, so this killed the whole
      # GenServer — every shard, every symbol's coverage, not just this one's.
      crash_pid = spawn(fn -> Process.sleep(:infinity) end)

      shard0 = %{connected_shard("shard-0") | socket: crash_pid, symbols: ["BTC-USD"]}
      shard1 = %{connected_shard("shard-1") | symbols: ["ETH-USD"]}

      feed =
        start_feed(
          shards: %{0 => shard0, 1 => shard1},
          credentials: @credentials,
          # Unreachable but fails fast — the reopen attempt this triggers must not hang
          # the test or reach a real network.
          url: "ws://127.0.0.1:1/nowhere"
        )

      # `:sys.replace_state/2` runs its function *inside* the target process, so
      # `Process.link/1` here links Feed itself to `crash_pid` — not the test process.
      :sys.replace_state(feed, fn state ->
        Process.link(crash_pid)
        state
      end)

      :ok = Feed.subscribe_notices(feed, to: self())

      Process.exit(crash_pid, :kill)

      # `isolate_crashed_shard/3` fans this notice out synchronously, inside the same
      # handler that rebuilds `state.shards` — receiving it is a reliable barrier before
      # asserting on `:sys.get_state/1` below. `:sys.get_state/1` answers via OTP's system
      # message channel and is not guaranteed ordered after a regular mailbox message, so
      # a fixed sleep here would still be a race, just a usually-winning one.
      assert_receive {:dp_exchange, :webull, %Notice{kind: :link_down}}

      assert Process.alive?(feed)

      state = :sys.get_state(feed)

      # Shard 1's own bookkeeping is untouched by shard 0's crash.
      assert state.shards[1].session_id == "shard-1"
      assert state.shards[1].symbols == ["ETH-USD"]

      # Shard 0 was dropped — not left on record pointing at a dead pid.
      refute match?(%{socket: ^crash_pid}, Map.get(state.shards, 0))

      # The feed's own mailbox is still healthy for everything else.
      send(feed, {:dp_exchange, :webull, quote_for("ETH-USD")})
      assert Feed.coverage(feed) == %{"ETH-USD" => :stream}
    end

    test "a caller waiting on the crashed shard is answered rather than left to time out",
         %{limiter: limiter} do
      crash_pid = spawn(fn -> Process.sleep(:infinity) end)

      shard0 = %{
        session_id: "shard-0",
        socket: crash_pid,
        connected?: false,
        symbols: [],
        reply_to: nil
      }

      feed = start_feed(shards: %{0 => shard0})

      :sys.replace_state(feed, fn state ->
        Process.link(crash_pid)
        state
      end)

      task =
        Task.async(fn ->
          Feed.subscribe(feed, ["BTC-USD"], subscribe_opts(limiter))
        end)

      # `connected?: false` means the subscribe above is deferred, waiting on this
      # shard's own CONNACK — exactly the window a crash can land in.
      refute Task.yield(task, 100)

      Process.exit(crash_pid, :kill)

      assert {:ok, {:error, {:shard_crashed, _reason}}} = Task.yield(task, 1_000)
    end
  end

  describe "control-plane HTTP never blocks the data-plane mailbox — W3" do
    test "a tick is delivered and coverage still answers while a resubscribe's HTTP call is in flight",
         %{limiter: limiter} do
      test_pid = self()

      plug = fn conn ->
        send(test_pid, {:blocked, self()})
        # Held open until the test explicitly releases it, so the assertions below run
        # while this HTTP call is genuinely, deterministically still in flight.
        receive do
          :release -> :ok
        end

        Req.Test.json(conn, %{"code" => "200"})
      end

      shard = %{connected_shard("shard-0") | symbols: ["BTCUSD"]}

      feed =
        start_feed(
          shards: %{0 => shard},
          credentials: @credentials,
          limiter: limiter,
          plug: plug,
          retry_attempts: 0
        )

      :sys.replace_state(feed, &%{&1 | wanted: MapSet.new(["BTC-USD"])})

      send(feed, :resubscribe)
      assert_receive {:blocked, blocked_pid}
      on_exit(fn -> if Process.alive?(blocked_pid), do: send(blocked_pid, :release) end)

      # A different symbol's tick, while shard 0's resubscribe HTTP call is still
      # blocked above. Before W3, `Subscription.subscribe` ran inline inside
      # `handle_info(:resubscribe, ...)`, so the feed's single mailbox could not take
      # this — or answer the coverage call below — until that call finished.
      send(feed, {:dp_exchange, :webull, quote_for("ETH-USD")})

      coverage_task = Task.async(fn -> Feed.coverage(feed) end)
      assert {:ok, coverage} = Task.yield(coverage_task, 300)
      assert coverage == %{"ETH-USD" => :stream}

      send(blocked_pid, :release)
    end
  end

  describe "shard assignment is stable under insertion — W4" do
    test "a new symbol that sorts before everything else does not touch already-full, healthy shards",
         %{limiter: limiter} do
      test_pid = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        # The original chunk-the-whole-set algorithm would re-sort ["AAA-USD" | ...] and
        # shift every symbol after it across shard boundaries — unsubscribing and
        # resubscribing BBB/CCC/DDD/EEE despite none of them changing. Stable assignment
        # must leave both existing shards alone.
        if decoded["session_id"] in ["shard-0", "shard-1"] do
          flunk(
            "shard #{decoded["session_id"]} was touched by an unrelated insertion: " <>
              inspect(decoded["symbols"])
          )
        end

        send(test_pid, {:request, decoded["session_id"], decoded["symbols"]})
        Req.Test.json(conn, %{"code" => "200"})
      end

      # Both existing shards start full, and a third is already open with room — so the
      # only possible destination for the new symbol is shard 2, and opening a fresh
      # socket (with everything that would entail) is not part of what this test needs
      # to prove.
      shard0 = %{connected_shard("shard-0") | symbols: ["BBB-USD", "CCC-USD"]}
      shard1 = %{connected_shard("shard-1") | symbols: ["DDD-USD", "EEE-USD"]}
      shard2 = connected_shard("shard-2")

      feed =
        start_feed(
          shards: %{0 => shard0, 1 => shard1, 2 => shard2},
          shard_capacity: %{0 => 2, 1 => 2}
        )

      :sys.replace_state(
        feed,
        &%{&1 | wanted: MapSet.new(["BBB-USD", "CCC-USD", "DDD-USD", "EEE-USD"])}
      )

      assert :ok = Feed.subscribe(feed, ["AAA-USD"], subscribe_opts(limiter, plug: plug))

      assert_receive {:request, session_id, ["AAAUSD"]}
      assert session_id not in ["shard-0", "shard-1"]
    end
  end

  describe "a venue-rejected symbol is excluded, timed, and reported — DpCryptoManagement's issue #24" do
    # The reporter's own shape: 17 bad symbols among 342, spread across four shards, each
    # shard's WHOLE batch rejected because one (or several) of its symbols are unrecognised.
    # This proves the blast radius is actually gone: the good symbols on both shards end up
    # subscribed, not just the ones on an untouched shard.
    test "several bad symbols across shards are excluded while every good symbol keeps subscribing",
         %{limiter: limiter} do
      test_pid = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        session_id = decoded["session_id"]
        symbols = decoded["symbols"]
        send(test_pid, {:request, conn.request_path, session_id, symbols})

        cond do
          session_id == "shard-0" and conn.request_path == "/market-data/streaming/subscribe" and
              "BADONEUSD" in symbols ->
            conn
            |> Plug.Conn.put_status(417)
            |> Req.Test.json(%{
              "error_code" => "INVALID_SYMBOL",
              "message" => "The symbols does not exist in the category. [BADONEUSD]"
            })

          session_id == "shard-1" and conn.request_path == "/market-data/streaming/subscribe" and
              Enum.any?(symbols, &(&1 in ["BADTWOUSD", "BADTHREEUSD"])) ->
            conn
            |> Plug.Conn.put_status(417)
            |> Req.Test.json(%{
              "error_code" => "INVALID_SYMBOL",
              "message" => "The symbols does not exist in the category. [BADTWOUSD, BADTHREEUSD]"
            })

          true ->
            Req.Test.json(conn, %{"code" => "200"})
        end
      end

      shard0 = %{connected_shard("shard-0") | symbols: ["AAA-USD", "BADONE-USD", "CCC-USD"]}

      shard1 = %{
        connected_shard("shard-1")
        | symbols: ["DDD-USD", "BADTWO-USD", "BADTHREE-USD"]
      }

      feed =
        start_feed(
          shards: %{0 => shard0, 1 => shard1},
          credentials: @credentials,
          limiter: limiter,
          plug: plug,
          retry_attempts: 0
        )

      :sys.replace_state(
        feed,
        &%{
          &1
          | wanted:
              MapSet.new([
                "AAA-USD",
                "BADONE-USD",
                "CCC-USD",
                "DDD-USD",
                "BADTWO-USD",
                "BADTHREE-USD"
              ])
        }
      )

      send(feed, :resubscribe)

      # Both shards' first attempt, rejected whole — one bad symbol failed each shard's
      # entire batch, exactly the blast radius the issue reports.
      assert_receive {:request, "/market-data/streaming/subscribe", "shard-0",
                      ["AAAUSD", "BADONEUSD", "CCCUSD"]}

      assert_receive {:request, "/market-data/streaming/subscribe", "shard-1",
                      ["DDDUSD", "BADTWOUSD", "BADTHREEUSD"]}

      # The rejection triggers a background trim on each shard, dropping only the symbols
      # the venue actually named.
      assert_receive {:request, "/market-data/streaming/unsubscribe", "shard-0", ["BADONEUSD"]}

      assert_receive {:request, "/market-data/streaming/unsubscribe", "shard-1", removed1}
      assert Enum.sort(removed1) == Enum.sort(["BADTWOUSD", "BADTHREEUSD"])

      # The next tick reasserts each shard with only the good symbols — and it succeeds.
      send(feed, :resubscribe)

      assert_receive {:request, "/market-data/streaming/subscribe", "shard-0", good0}
      assert Enum.sort(good0) == Enum.sort(["AAAUSD", "CCCUSD"])

      assert_receive {:request, "/market-data/streaming/subscribe", "shard-1", ["DDDUSD"]}
    end

    test "a subscribe naming bad symbols excludes them and still returns :ok for the rest, in the same call",
         %{limiter: limiter} do
      # Mirrors the existing oversubscribed synchronous-retry test: the retry inside
      # reshard_step/4 is what makes the caller's own reply a clean :ok despite the venue
      # having refused the first attempt.
      test_pid = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        send(test_pid, {:request, conn.request_path, decoded["symbols"]})

        if conn.request_path == "/market-data/streaming/subscribe" and
             "BADUSD" in decoded["symbols"] do
          conn
          |> Plug.Conn.put_status(417)
          |> Req.Test.json(%{
            "error_code" => "INVALID_SYMBOL",
            "message" => "The symbols does not exist in the category. [BADUSD]"
          })
        else
          Req.Test.json(conn, %{"code" => "200"})
        end
      end

      feed = start_feed(shards: %{0 => connected_shard("shard-0")})

      assert :ok =
               Feed.subscribe(feed, ["GOOD-USD", "BAD-USD"], subscribe_opts(limiter, plug: plug))

      assert_receive {:request, "/market-data/streaming/subscribe", ["BADUSD", "GOODUSD"]}
      assert_receive {:request, "/market-data/streaming/unsubscribe", ["BADUSD"]}
    end

    test "a :refusal notice names the rejected symbols in canonical form", %{limiter: limiter} do
      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        if conn.request_path == "/market-data/streaming/subscribe" and
             "BADUSD" in decoded["symbols"] do
          conn
          |> Plug.Conn.put_status(417)
          |> Req.Test.json(%{
            "error_code" => "INVALID_SYMBOL",
            "message" => "The symbols does not exist in the category. [BADUSD]"
          })
        else
          Req.Test.json(conn, %{"code" => "200"})
        end
      end

      feed = start_feed(shards: %{0 => connected_shard("shard-0")})
      :ok = Feed.subscribe_notices(feed, to: self())

      assert :ok =
               Feed.subscribe(feed, ["GOOD-USD", "BAD-USD"], subscribe_opts(limiter, plug: plug))

      assert_receive {:dp_exchange, :webull, %Notice{kind: :refusal, details: details}}
      assert details.symbols == ["BAD-USD"]
    end

    test "a rejection's TTL expiring returns the symbol to shard composition automatically",
         %{limiter: limiter} do
      test_pid = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        send(test_pid, {:request, conn.request_path, decoded["symbols"]})

        if conn.request_path == "/market-data/streaming/subscribe" and
             "BADUSD" in decoded["symbols"] do
          conn
          |> Plug.Conn.put_status(417)
          |> Req.Test.json(%{
            "error_code" => "INVALID_SYMBOL",
            "message" => "The symbols does not exist in the category. [BADUSD]"
          })
        else
          Req.Test.json(conn, %{"code" => "200"})
        end
      end

      shard = %{connected_shard("shard-0") | symbols: ["GOOD-USD", "BAD-USD"]}

      feed =
        start_feed(
          shards: %{0 => shard},
          credentials: @credentials,
          limiter: limiter,
          plug: plug,
          retry_attempts: 0,
          rejected_symbol_ttl_ms: 20
        )

      :sys.replace_state(feed, &%{&1 | wanted: MapSet.new(["GOOD-USD", "BAD-USD"])})

      send(feed, :resubscribe)

      assert_receive {:request, "/market-data/streaming/subscribe", ["GOODUSD", "BADUSD"]}
      # This trim only completes (updating the shard's own remembered symbol list) once
      # this unsubscribe fires — a reliable barrier for the next tick to observe it.
      assert_receive {:request, "/market-data/streaming/unsubscribe", ["BADUSD"]}

      # Well inside the TTL: BAD-USD stays excluded.
      send(feed, :resubscribe)
      assert_receive {:request, "/market-data/streaming/subscribe", ["GOODUSD"]}

      # Past the TTL: the same tick's own resync picks BAD-USD back up as eligible.
      Process.sleep(30)
      send(feed, :resubscribe)

      assert_receive {:request, "/market-data/streaming/subscribe", symbols_a}
      assert_receive {:request, "/market-data/streaming/subscribe", symbols_b}
      assert "BADUSD" in (symbols_a ++ symbols_b)
    end
  end

  describe "a generic resubscribe failure is reported too, latched per shard — DpCryptoManagement's issue #23" do
    # Driven by sending `:reconcile_done` straight to the feed, the same way `:resubscribe`
    # itself is driven elsewhere in this file — the deterministic way to exercise a specific
    # shard's tick outcome without waiting a real 60 seconds or standing up a fake HTTP layer
    # for the rate-limiter-throttle shape this reason stands in for.
    test "a shard's blind resubscribe failing generically emits a :coverage_change warning naming it",
         %{limiter: limiter} do
      shard = %{connected_shard("shard-0") | symbols: ["AAA-USD", "BBB-USD"]}
      feed = start_feed(shards: %{0 => shard}, credentials: @credentials, limiter: limiter)
      :ok = Feed.subscribe_notices(feed, to: self())

      reason = {:exchange_error, :webull, "Throttled by our own rate limiter (not the venue)"}
      send(feed, {:reconcile_done, {:resubscribe, 0}, {:error, reason}})

      assert_receive {:dp_exchange, :webull,
                      %Notice{kind: :coverage_change, severity: :warning, details: details}}

      assert details.shard == 0
      assert details.symbol_count == 2
    end

    test "does not fire a second notice for the same shard while it stays failed",
         %{limiter: limiter} do
      shard = %{connected_shard("shard-0") | symbols: ["AAA-USD"]}
      feed = start_feed(shards: %{0 => shard}, credentials: @credentials, limiter: limiter)
      :ok = Feed.subscribe_notices(feed, to: self())

      reason = {:error, :timeout}
      send(feed, {:reconcile_done, {:resubscribe, 0}, {:error, reason}})
      assert_receive {:dp_exchange, :webull, %Notice{kind: :coverage_change, severity: :warning}}

      send(feed, {:reconcile_done, {:resubscribe, 0}, {:error, reason}})
      refute_receive {:dp_exchange, :webull, %Notice{kind: :coverage_change}}, 200
    end

    test "the shard's next successful resubscribe emits a severity: :info recovery notice",
         %{limiter: limiter} do
      shard = %{connected_shard("shard-0") | symbols: ["AAA-USD"]}
      feed = start_feed(shards: %{0 => shard}, credentials: @credentials, limiter: limiter)
      :ok = Feed.subscribe_notices(feed, to: self())

      send(feed, {:reconcile_done, {:resubscribe, 0}, {:error, :timeout}})
      assert_receive {:dp_exchange, :webull, %Notice{kind: :coverage_change, severity: :warning}}

      send(feed, {:reconcile_done, {:resubscribe, 0}, :ok})

      assert_receive {:dp_exchange, :webull,
                      %Notice{kind: :coverage_change, severity: :info, details: details}}

      assert details.shard == 0
    end

    test "an :ok tick on a shard that was never latched emits no recovery notice",
         %{limiter: limiter} do
      shard = %{connected_shard("shard-0") | symbols: ["AAA-USD"]}
      feed = start_feed(shards: %{0 => shard}, credentials: @credentials, limiter: limiter)
      :ok = Feed.subscribe_notices(feed, to: self())

      send(feed, {:reconcile_done, {:resubscribe, 0}, :ok})
      refute_receive {:dp_exchange, :webull, %Notice{kind: :coverage_change}}, 200
    end

    test "two shards' failure and recovery latches stay independent of each other",
         %{limiter: limiter} do
      shard0 = %{connected_shard("shard-0") | symbols: ["AAA-USD"]}
      shard1 = %{connected_shard("shard-1") | symbols: ["BBB-USD"]}

      feed =
        start_feed(
          shards: %{0 => shard0, 1 => shard1},
          credentials: @credentials,
          limiter: limiter
        )

      :ok = Feed.subscribe_notices(feed, to: self())

      # Shard 0 fails; shard 1 stays healthy and must not be warned about.
      send(feed, {:reconcile_done, {:resubscribe, 0}, {:error, :timeout}})

      assert_receive {:dp_exchange, :webull,
                      %Notice{kind: :coverage_change, severity: :warning, details: %{shard: 0}}}

      send(feed, {:reconcile_done, {:resubscribe, 1}, :ok})

      refute_receive {:dp_exchange, :webull,
                      %Notice{kind: :coverage_change, details: %{shard: 1}}},
                     200

      # Shard 1 now fails independently — shard 0 stays latched and silent this tick.
      send(feed, {:reconcile_done, {:resubscribe, 1}, {:error, :timeout}})

      assert_receive {:dp_exchange, :webull,
                      %Notice{kind: :coverage_change, severity: :warning, details: %{shard: 1}}}

      send(feed, {:reconcile_done, {:resubscribe, 0}, {:error, :timeout}})

      refute_receive {:dp_exchange, :webull,
                      %Notice{kind: :coverage_change, details: %{shard: 0}}},
                     200

      # Shard 0 recovers; shard 1 stays latched.
      send(feed, {:reconcile_done, {:resubscribe, 0}, :ok})

      assert_receive {:dp_exchange, :webull,
                      %Notice{kind: :coverage_change, severity: :info, details: %{shard: 0}}}
    end

    test "the two specifically-handled shapes do not also trigger this generic latch",
         %{limiter: limiter} do
      # Both branches below run a real `handle_subscribe_result/3` clause that recomputes
      # and resyncs shard composition in the background — a plug is required so that
      # in-flight HTTP call resolves against a fake rather than reaching the network.
      plug = fn conn -> Req.Test.json(conn, %{"code" => "200"}) end
      shard = %{connected_shard("shard-0") | symbols: ["AAA-USD"]}

      feed =
        start_feed(shards: %{0 => shard}, credentials: @credentials, limiter: limiter, plug: plug)

      :ok = Feed.subscribe_notices(feed, to: self())

      send(feed, {:reconcile_done, {:resubscribe, 0}, {:error, :oversubscribed}})
      refute_receive {:dp_exchange, :webull, %Notice{kind: :coverage_change}}, 200

      send(feed, {:reconcile_done, {:resubscribe, 0}, {:error, {:invalid_symbols, ["AAA-USD"]}}})
      refute_receive {:dp_exchange, :webull, %Notice{kind: :coverage_change}}, 200
    end
  end

  describe "terminate/2" do
    # A clean shutdown attempts `DISCONNECT` on every shard `terminate/2` believes is
    # connected — see `Socket.disconnect/2` and `MqttPacket.disconnect/0`. Driven
    # directly against `terminate/2`, the same way `SocketTest` drives frame handlers
    # directly: no process lifecycle is needed to exercise a plain function of state.
    #
    # `dead_pid/0` doubles as the observable here — `Socket.disconnect/2` returns
    # `{:error, :not_alive}` for a dead pid it was asked to send to, and `terminate/2`
    # logs that at `:debug` (an already-dead socket on shutdown is the ordinary case, not
    # a failure — see `log_disconnect_failure/2`'s own comment), so a debug line naming a
    # shard's index is proof `terminate/2` attempted that shard, and its absence is proof
    # it did not.
    test "attempts every connected shard, for an ordinary shutdown" do
      shards = %{
        0 => %{connected_shard("s0") | socket: dead_pid()},
        1 => %{connected_shard("s1") | socket: dead_pid()}
      }

      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          assert Feed.terminate(:normal, %{shards: shards}) == :ok
        end)

      assert log =~ "shard 0 DISCONNECT on shutdown skipped"
      assert log =~ "shard 1 DISCONNECT on shutdown skipped"
    end

    test "skips a shard that never connected — it has no session to close" do
      shards = %{0 => %{connected_shard("s0") | socket: dead_pid(), connected?: false}}

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Feed.terminate(:shutdown, %{shards: shards}) == :ok
        end)

      refute log =~ "DISCONNECT"
    end

    test "runs for every reason GenServer treats as normal termination" do
      for reason <- [:normal, :shutdown, {:shutdown, :some_reason}] do
        shards = %{0 => %{connected_shard("s0") | socket: dead_pid()}}

        log =
          ExUnit.CaptureLog.capture_log([level: :debug], fn ->
            assert Feed.terminate(reason, %{shards: shards}) == :ok
          end)

        assert log =~ "shard 0 DISCONNECT on shutdown skipped"
      end
    end

    test "a crash reason skips the sweep — extra socket I/O is the wrong thing mid-crash" do
      shards = %{0 => %{connected_shard("s0") | socket: dead_pid()}}

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Feed.terminate({:some_crash, :reason}, %{shards: shards}) == :ok
        end)

      refute log =~ "DISCONNECT"
    end

    test "no shards at all is a no-op" do
      assert Feed.terminate(:normal, %{shards: %{}}) == :ok
    end

    test "a shard whose socket happens to be the caller's own pid does not crash" do
      # Found live: `:sys.replace_state/2` runs its function inside the target process,
      # so a fixture built that way with `socket: self()` (as one test elsewhere in this
      # file, and one in `WebullTest`, both do) captures `Feed`'s own pid, not a
      # distinct fake. `terminate/2` calling `disconnect/2` on itself must not crash the
      # shutdown that is already in progress — see `SocketTest`'s matching case for why
      # `WebSockex.send_frame/3` makes this a real, not hypothetical, risk.
      shards = %{0 => %{connected_shard("s0") | socket: self()}}

      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          assert Feed.terminate(:normal, %{shards: shards}) == :ok
        end)

      # `:calling_self` is structural too — see `log_disconnect_failure/2` — so this is
      # `:debug`, not a warning, the same as the dead-pid cases above.
      assert log =~ "shard 0 DISCONNECT on shutdown skipped"
    end

    test "a live socket that fails to send still warns — that one is a real failure" do
      # `:not_alive` and `:calling_self` are the two structural reasons `terminate/2`
      # demotes to `:debug` (see `log_disconnect_failure/2`). Neither is "the DISCONNECT
      # could have been sent and was not" — this fixture is: a genuinely alive process
      # that never answers, the same shape `SocketTest`'s "an alive process that never
      # answers times out as an error, not a hang" uses. The venue really will see an
      # abrupt disconnect here, so this must stay a warning.
      unresponsive = spawn(fn -> Process.sleep(:infinity) end)
      shards = %{0 => %{connected_shard("s0") | socket: unresponsive}}

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Feed.terminate(:normal, %{shards: shards}) == :ok
        end)

      assert log =~ "shard 0 DISCONNECT on shutdown failed"
      refute log =~ "skipped"

      Process.exit(unresponsive, :kill)
    end
  end
end
