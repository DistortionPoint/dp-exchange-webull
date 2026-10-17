defmodule DpExchange.Webull.TickAITest do
  @moduledoc """
  Tick AI: a shard's socket that CRASHES (an `:EXIT`, so `Socket.handle_disconnect/2` never
  runs) must still move a consumer's link gauge, exactly once and only for a link that was up.
  """

  use DpExchange.Webull.FeedCase, async: true

  alias DpExchange.Core.Notice
  alias DpExchange.Webull.Feed

  # `:telemetry` handlers are VM-global, so each test filters on a marker unique to it, carried
  # in the crash reason, and never sees another test's emissions.
  defp attach_down_handler(marker) do
    test_pid = self()
    handler_id = "tick-ai-down-#{marker}"

    :telemetry.attach(
      handler_id,
      [:dp_exchange, :link, :down],
      fn _event, measurements, metadata, _config ->
        if is_binary(metadata.reason) and String.contains?(metadata.reason, marker),
          do: send(test_pid, {:link_down, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp crash_shard(connected?, marker) do
    crash_pid = spawn(fn -> Process.sleep(:infinity) end)

    shard0 = %{
      connected_shard("shard-ai-#{marker}")
      | socket: crash_pid,
        symbols: ["BTC-USD"],
        connected?: connected?
    }

    feed =
      start_feed(
        shards: %{0 => shard0},
        credentials: credentials(),
        url: "ws://127.0.0.1:1/nowhere"
      )

    :sys.replace_state(feed, fn state ->
      Process.link(crash_pid)
      state
    end)

    :ok = Feed.subscribe_notices(feed, to: self())
    Process.exit(crash_pid, {:tick_ai_crash, marker})

    feed
  end

  defp stale_shard(connected?, marker) do
    socket = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> if Process.alive?(socket), do: Process.exit(socket, :kill) end)

    session = "s-#{marker}"

    feed =
      start_feed(
        shards: %{
          0 => %{connected_shard(session) | connected?: connected?, socket: socket}
        },
        url: "ws://127.0.0.1:1/nowhere"
      )

    :ok = Feed.subscribe_notices(feed, to: self())
    {feed, session}
  end

  describe "a shard rebuilt on INVALID_SESSION closes its link_up" do
    test "a connected shard emits link_down exactly once" do
      marker = "tick_ai_marker_#{System.unique_integer([:positive])}"
      attach_down_handler(marker)
      {feed, session} = stale_shard(true, marker)

      send(feed, {:reconcile_done, {:resubscribe, 0}, {:error, {:invalid_session, session}}})

      assert_receive {:dp_exchange, :webull, %Notice{kind: :link_down}}, 5_000
      assert_receive {:link_down, %{count: 1}, metadata}, 5_000
      assert metadata.reason =~ marker
      refute_receive {:link_down, _measurements, _metadata}, 500
    end

    test "a shard that never came up emits none" do
      marker = "tick_ai_marker_#{System.unique_integer([:positive])}"
      attach_down_handler(marker)
      {feed, session} = stale_shard(false, marker)

      send(feed, {:reconcile_done, {:link_up, 0}, {:error, {:invalid_session, session}}})

      assert_receive {:dp_exchange, :webull, %Notice{kind: :link_down}}, 5_000
      refute_receive {:link_down, _measurements, _metadata}, 500
    end
  end

  describe "a crashed shard socket reports its lost link on the metrics channel" do
    test "a live link that crashed emits link_down exactly once" do
      marker = "tick_ai_marker_#{System.unique_integer([:positive])}"
      attach_down_handler(marker)

      crash_shard(true, marker)

      assert_receive {:dp_exchange, :webull, %Notice{kind: :link_down}}, 5_000
      assert_receive {:link_down, %{count: 1}, metadata}, 5_000
      assert metadata.provider == :webull
      assert metadata.reason =~ marker

      refute_receive {:link_down, _measurements, _metadata}, 500
    end

    test "a shard whose link was never up emits no link_down for it" do
      marker = "tick_ai_marker_#{System.unique_integer([:positive])}"
      attach_down_handler(marker)

      crash_shard(false, marker)

      assert_receive {:dp_exchange, :webull, %Notice{kind: :link_down}}, 5_000
      refute_receive {:link_down, _measurements, _metadata}, 500
    end
  end
end
