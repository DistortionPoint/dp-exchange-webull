defmodule DpExchange.Webull.TickAPTest do
  @moduledoc """
  Tick AP: time, clocks and timers. A tick's documented-millisecond `time` is read as
  milliseconds and never reinterpreted by magnitude. The connack and reopen timers are
  per-caller and jittered. Every test names what the old code did with the input.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Config
  alias DpExchange.Webull.Rest

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

  @credentials %{app_key: "key", app_secret: "secret"}

  defp answer(body) do
    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end

    [plug: plug, retry_attempts: 0]
  end

  defp tape(time) do
    [%{"symbol" => "AAPL", "result" => [%{"time" => time, "price" => "10", "volume" => "1"}]}]
  end

  describe "a signed request is stamped per attempt" do
    test "a retry carries a later x-timestamp and a different x-signature-nonce" do
      # The clock advances one second on every read, so a stamp minted once for the call (and
      # replayed on the retry) would show the SAME timestamp twice; one minted per attempt
      # never goes backwards. A replayed nonce is a request the venue refuses outright.
      ticks = :atomics.new(1, [])

      Config.put_override(:webull_clock, fn ->
        DateTime.add(~U[2026-10-20 12:00:00Z], :atomics.add_get(ticks, 1, 1), :second)
      end)

      test_pid = self()
      sent = :atomics.new(1, [])

      plug = fn conn ->
        headers = Map.new(conn.req_headers)
        send(test_pid, {:stamped, headers["x-timestamp"], headers["x-signature-nonce"]})

        if :atomics.add_get(sent, 1, 1) == 1 do
          Plug.Conn.resp(conn, 500, "unavailable")
        else
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, Jason.encode!([%{"price" => "1", "time" => 1_787_936_147_000}]))
        end
      end

      assert {:ok, _quote} =
               Rest.get_price("BTC-USD", @credentials,
                 plug: plug,
                 retry_attempts: 2,
                 retry_delay: 1
               )

      assert_receive {:stamped, first_at, first_nonce}, 5_000
      assert_receive {:stamped, second_at, second_nonce}, 5_000
      {:ok, first, _offset} = DateTime.from_iso8601(first_at)
      {:ok, second, _offset} = DateTime.from_iso8601(second_at)

      assert DateTime.compare(second, first) in [:gt, :eq]
      assert first_at =~ ~r/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z/
      refute first_nonce == second_nonce
    end
  end

  describe "a tick's time is documented in milliseconds (tick.md:223)" do
    test "a millisecond time, as a number or as the string the page types it, is read as one" do
      for time <- [1_787_936_147_000, "1787936147000"] do
        assert {:ok, [trade]} = Rest.get_trades("AAPL", @credentials, answer(tape(time)))
        assert trade.timestamp == DateTime.from_unix!(1_787_936_147_000, :millisecond)
      end
    end

    test "a seconds-sized value is refused, where the magnitude guess dated it as seconds" do
      # Old: 1_787_936_147 had ten digits, was read as seconds, and delivered a 2026 trade
      # for a field the venue documents in milliseconds, which would be January 1970.
      for time <- [1_787_936_147, "1787936147", 100_000_000_000] do
        assert {:error, :invalid_unix_time} =
                 Rest.get_trades("AAPL", @credentials, answer(tape(time)))
      end
    end

    test "a microsecond-sized or non-positive value is refused" do
      for time <- [1_787_936_147_000_000, 0, -5, "0"] do
        assert {:error, :invalid_unix_time} =
                 Rest.get_trades("AAPL", @credentials, answer(tape(time)))
      end
    end
  end
end

defmodule DpExchange.Webull.TickAPReopenJitterTest do
  @moduledoc """
  The reopen ladder is jittered. Not async: it reads the feed's warning out of the captured
  log, and a concurrent feed test's own "reopening it in" line would be a second reader of the
  same capture.
  """

  use DpExchange.Webull.FeedCase, async: false

  alias DpExchange.Webull.Feed

  defp invalidate(feed, session_id) do
    socket = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> if Process.alive?(socket), do: Process.exit(socket, :kill) end)
    shard = %{connected_shard(session_id) | connected?: false, socket: socket}
    :sys.replace_state(feed, fn state -> put_in(state.shards[0], shard) end)
    send(feed, {:reconcile_done, {:link_up, 0}, {:error, {:invalid_session, session_id}}})
    # A call after the send: the mailbox is ordered, so the message above is handled first.
    _settled = Feed.coverage(feed)
    :sys.get_state(feed)
  end

  test "the delayed reopen is shortened by jitter, never lengthened past the cap" do
    # Shards torn down by one venue fault share a ladder, and identical delays reopen them
    # together on every rung. The shortening is at least 1ms, so a logged delay equal to the
    # cap means no jitter was applied.
    feed = start_feed(shards: %{}, open_retry_base_ms: 600_000, open_retry_max_ms: 600_000)
    _first = invalidate(feed, "s1")

    log = ExUnit.CaptureLog.capture_log(fn -> invalidate(feed, "s2") end)

    assert [_whole, delay_text] = Regex.run(~r/reopening it in (\d+)ms/, log)
    delay = String.to_integer(delay_text)
    assert delay < 600_000
    assert delay >= 450_000
  end
end

defmodule DpExchange.Webull.TickAPDeliveryClockTest do
  @moduledoc """
  The feed's delivery records are an interval source, so they are monotonic. A wall-clock
  stamp made "did this shard deliver in the last minute" a question a clock step answers
  wrongly; and a monotonic reading is negative on the BEAM, so "never delivered" cannot be 0.
  """

  use DpExchange.Webull.FeedCase, async: true

  alias DpExchange.Webull.Feed

  test "an arrival is stamped on the monotonic clock" do
    feed = start_feed()
    want(feed, ["BTC-USD"])

    before = System.monotonic_time(:millisecond)
    send(feed, {:dp_exchange, :webull, quote_for("BTC-USD")})
    _settled = Feed.coverage(feed)
    after_ms = System.monotonic_time(:millisecond)

    stamped = :sys.get_state(feed).delivering["BTC-USD"]
    assert stamped >= before and stamped <= after_ms
  end

  test "a shard that never delivered is quiet and is re-asserted, whatever the clock reads",
       %{limiter: limiter} do
    # Read against a default of 0, a monotonic cutoff (about -5.8e11 on the BEAM) is below 0 and
    # every shard looked as if it had just delivered: nothing was ever re-asserted.
    test_pid = self()

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request, Jason.decode!(body)["session_id"]})
      Req.Test.json(conn, %{"code" => "200"})
    end

    shard = %{connected_shard("shard-0") | symbols: ["BTC-USD"]}

    feed =
      start_feed(
        shards: %{0 => shard},
        credentials: credentials(),
        limiter: limiter,
        plug: plug,
        retry_attempts: 0
      )

    send(feed, :resubscribe)

    assert_receive {:request, "shard-0"}, 5_000
  end
end
