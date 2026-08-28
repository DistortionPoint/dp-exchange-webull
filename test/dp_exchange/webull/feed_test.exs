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

  defp start_feed(opts \\ []) do
    name = :"feed_#{System.unique_integer([:positive])}"
    {:ok, pid} = Feed.start_link(Keyword.merge([name: name, socket: self()], opts))
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

  describe "the two transports are joined by one session id" do
    test "the same id is used for the socket and the HTTP subscribe", %{limiter: limiter} do
      # A mismatch fails in the most expensive way available: the HTTP call succeeds, the
      # broker publishes to a session nobody listens on, and the socket sits connected and
      # idle with no error anywhere.
      test_pid = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:subscribed, Jason.decode!(body)})
        Req.Test.json(conn, %{"code" => "200"})
      end

      feed = start_feed(session_id: "fixed-session")
      :ok = Feed.subscribe(feed, ["BTC-USD"], subscribe_opts(limiter, plug: plug))

      assert_receive {:subscribed, body}
      assert body["session_id"] == "fixed-session"
      assert body["symbols"] == ["BTCUSD"]
    end

    test "a generated session id is unique per feed", %{limiter: _limiter} do
      # The venue disconnects an older connection presenting the same id, so two feeds
      # sharing one would take turns killing each other, each healthy in isolation.
      first = :sys.get_state(start_feed()).session_id
      second = :sys.get_state(start_feed()).session_id

      refute first == second
      assert String.length(first) == 32
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
    test "a link_up notice triggers a re-subscribe for everything wanted", %{limiter: limiter} do
      test_pid = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:subscribed, Jason.decode!(body)["symbols"]})
        Req.Test.json(conn, %{"code" => "200"})
      end

      feed = start_feed()
      :ok = Feed.subscribe(feed, ["BTC-USD"], subscribe_opts(limiter, plug: plug))
      assert_receive {:subscribed, ["BTCUSD"]}

      # A fresh link. The venue restores nothing, so the feed must.
      send(feed, {:dp_exchange, :webull, Notice.new(:link_up, :webull)})

      assert_receive {:subscribed, ["BTCUSD"]}
    end

    test "a reconnect with nothing wanted sends no request", %{limiter: _limiter} do
      feed = start_feed()

      send(feed, {:dp_exchange, :webull, Notice.new(:link_up, :webull)})
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
end
