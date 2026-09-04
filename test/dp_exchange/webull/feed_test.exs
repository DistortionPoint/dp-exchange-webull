defmodule DpExchange.Webull.FeedTest do
  use ExUnit.Case, async: true

  alias DpExchange.Core.{Config, DefaultRateLimiter, Notice}
  alias DpExchange.Core.Types.Quote
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
end
