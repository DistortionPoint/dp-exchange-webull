defmodule DpExchange.Webull.TickAGTest do
  @moduledoc """
  Tick AG: lifecycle sequences that must hold for the streaming feed, driven in message order
  (no sleeps), and the decoder bound found while reading the socket's hot path.
  """

  use DpExchange.Webull.FeedCase, async: true

  import Bitwise

  alias DpExchange.Core.Types.Quote
  alias DpExchange.Webull.{Feed, Socket}

  describe "subscribe, unsubscribe, subscribe of one symbol" do
    test "a frame in the gap is dropped and the timers of answered calls are gone",
         %{limiter: limiter} do
      feed = start_feed()
      opts = subscribe_opts(limiter)

      assert :ok = Feed.subscribe(feed, ["BTC-USD"], opts)
      assert :ok = Feed.unsubscribe(feed, ["BTC-USD"], opts)

      # The venue keeps sending for a moment after an unsubscribe.
      send(feed, {:dp_exchange, :webull, quote_for("BTC-USD")})
      assert Feed.coverage(feed) == %{}
      refute_received {:dp_exchange, :webull, %Quote{}}

      assert :ok = Feed.subscribe(feed, ["BTC-USD"], opts)
      send(feed, {:dp_exchange, :webull, quote_for("BTC-USD")})
      assert %{"BTC-USD" => :stream} = Feed.coverage(feed)
      assert_received {:dp_exchange, :webull, %Quote{symbol: "BTC-USD"}}

      state = :sys.get_state(feed)
      assert state.shards[0].symbols == ["BTC-USD"]
      assert Feed.wanted(feed) == ["BTC-USD"]
      assert state.caller_timers == %{}
      assert state.connack_timers == %{}
    end

    test "the same pid subscribing twice is monitored once and delivered to once",
         %{limiter: limiter} do
      feed = start_feed()
      opts = subscribe_opts(limiter)

      assert :ok = Feed.subscribe(feed, ["BTC-USD"], opts)
      assert :ok = Feed.subscribe(feed, ["ETH-USD"], opts)

      state = :sys.get_state(feed)
      assert MapSet.to_list(state.subscribers) == [self()]
      assert Map.keys(state.monitors) == [self()]

      send(feed, {:dp_exchange, :webull, quote_for("BTC-USD")})
      _settled = Feed.coverage(feed)

      assert_received {:dp_exchange, :webull, %Quote{symbol: "BTC-USD"}}
      refute_received {:dp_exchange, :webull, %Quote{symbol: "BTC-USD"}}
    end
  end

  describe "a subscriber that dies" do
    defp recording_plug do
      test_pid = self()

      fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:req, conn.request_path, Jason.decode!(body)["symbols"]})
        Req.Test.json(conn, %{"code" => "200"})
      end
    end

    defp kill_and_settle(feed, pid) do
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
      # A call is answered only after the feed has handled its own `:DOWN`.
      _settled = Feed.coverage(feed)
      :ok
    end

    defp idle, do: spawn(fn -> Process.sleep(:infinity) end)

    test "the last data subscriber's death releases the symbols and unsubscribes the venue",
         %{limiter: limiter} do
      feed = start_feed()
      doomed = idle()
      opts = subscribe_opts(limiter, to: doomed, plug: recording_plug())

      assert :ok = Feed.subscribe(feed, ["BTC-USD"], opts)
      assert_receive {:req, "/market-data/streaming/subscribe", ["BTCUSD"]}, 5_000
      assert Map.has_key?(:sys.get_state(feed).monitors, doomed)

      send(feed, {:dp_exchange, :webull, quote_for("BTC-USD")})
      assert %{"BTC-USD" => :stream} = Feed.coverage(feed)

      kill_and_settle(feed, doomed)

      state = :sys.get_state(feed)
      assert MapSet.size(state.subscribers) == 0
      assert state.monitors == %{}
      assert Feed.wanted(feed) == []
      assert Feed.coverage(feed) == %{}
      assert state.shards[0].symbols == []
      assert_receive {:req, "/market-data/streaming/unsubscribe", ["BTCUSD"]}, 5_000
    end

    test "one of two data subscribers dying keeps the symbols", %{limiter: limiter} do
      feed = start_feed()
      doomed = idle()
      plug = recording_plug()

      doomed_opts = subscribe_opts(limiter, to: doomed, plug: plug)
      assert :ok = Feed.subscribe(feed, ["BTC-USD"], doomed_opts)
      assert :ok = Feed.subscribe(feed, ["BTC-USD"], subscribe_opts(limiter, plug: plug))
      assert_receive {:req, "/market-data/streaming/subscribe", ["BTCUSD"]}, 5_000

      kill_and_settle(feed, doomed)

      assert Feed.wanted(feed) == ["BTC-USD"]
      assert :sys.get_state(feed).shards[0].symbols == ["BTC-USD"]
      refute_receive {:req, "/market-data/streaming/unsubscribe", _symbols}, 500
    end

    test "a registered name keeps the symbols alive, as it is never monitored",
         %{limiter: limiter} do
      feed = start_feed()
      doomed = idle()
      holder = idle()
      name = :"tick_ag_named_#{System.unique_integer([:positive])}"
      Process.register(holder, name)
      on_exit(fn -> Process.exit(holder, :kill) end)
      plug = recording_plug()

      doomed_opts = subscribe_opts(limiter, to: doomed, plug: plug)
      named_opts = subscribe_opts(limiter, to: name, plug: plug)
      assert :ok = Feed.subscribe(feed, ["BTC-USD"], doomed_opts)
      assert :ok = Feed.subscribe(feed, ["BTC-USD"], named_opts)

      kill_and_settle(feed, doomed)

      assert Feed.wanted(feed) == ["BTC-USD"]
      assert MapSet.member?(:sys.get_state(feed).subscribers, name)
      refute_receive {:req, "/market-data/streaming/unsubscribe", _symbols}, 500
    end

    test "a notice-only subscriber's death releases nothing", %{limiter: limiter} do
      feed = start_feed()
      watcher = idle()
      plug = recording_plug()

      assert :ok = Feed.subscribe(feed, ["BTC-USD"], subscribe_opts(limiter, plug: plug))
      :ok = Feed.subscribe_notices(feed, to: watcher)

      kill_and_settle(feed, watcher)

      refute MapSet.member?(:sys.get_state(feed).notice_subscribers, watcher)
      assert Feed.wanted(feed) == ["BTC-USD"]
      refute_receive {:req, "/market-data/streaming/unsubscribe", _symbols}, 500
    end
  end

  describe "stream: a timestamp longer than any epoch" do
    defp varint(value) when value < 0x80, do: <<value>>
    defp varint(value), do: <<1::1, band(value, 0x7F)::7, varint(bsr(value, 7))::binary>>

    defp field(number, value) when is_binary(value),
      do: varint(bsl(number, 3) ||| 2) <> varint(byte_size(value)) <> value

    defp publish(topic, payload) do
      body = <<byte_size(topic)::16>> <> topic <> payload
      <<3::4, 0::4>> <> varint(byte_size(body)) <> body
    end

    defp socket_state,
      do: %{
        subscriber: self(),
        session_id: "s1",
        app_key: "k",
        buffer: <<>>,
        qos2_pending: MapSet.new(),
        connected?: false,
        ping: nil,
        last_heard_at: nil
      }

    defp deliver(topic, payload) do
      assert {:ok, _state} =
               Socket.handle_frame({:binary, publish(topic, payload)}, socket_state())
    end

    test "is no venue time, without being parsed into a bignum" do
      basic = field(1, field(1, "BTCUSD"))
      absurd = String.duplicate("9", 100_000)

      deliver("snapshot", basic <> field(2, absurd) <> field(3, "10"))

      assert_receive {:dp_exchange, :webull, %Quote{venue_time: nil} = received}, 5_000
      assert Decimal.equal?(received.price, Decimal.new("10"))
    end

    test "a real epoch beside it still dates the quote" do
      basic = field(1, field(1, "BTCUSD"))

      deliver("snapshot", basic <> field(2, "1787936147000") <> field(3, "10"))

      assert_receive {:dp_exchange, :webull, %Quote{venue_time: %DateTime{}}}, 5_000
    end
  end
end
