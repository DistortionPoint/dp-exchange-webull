defmodule DpExchange.Webull.Issue13PermissionCoverageTest do
  @moduledoc """
  Issue #13: a session that lost the us-crypto permission to a sibling kept its pairs in
  `coverage/1` as `:stream`, on the strength of frames from before the grab. Measured on four
  sessions with `priority_symbols:`: 93 of 152 pairs reported streaming had not ticked for 1
  to 15 minutes.

  A symbol now counts only if it arrived after its session was last judged to have lost the
  stream: on a "Permission grabbed" notice for that session, or on a tick that finds its
  shard silent for a whole interval while a sibling streams. Its next frame restores it.
  """

  use DpExchange.Webull.FeedCase, async: true

  alias DpExchange.Core.Notice
  alias DpExchange.Webull.Feed

  @grab "Permission grabbed by other session, category : us-crypto"

  defp two_shard_feed(limiter, extra \\ []) do
    feed =
      start_feed(
        Keyword.merge(
          [
            shards: %{
              0 => %{connected_shard("shard-0") | symbols: ["BTC-USD", "DOGE-USD"]},
              1 => %{connected_shard("shard-1") | symbols: ["SOL-USD", "ETH-USD"]}
            },
            credentials: credentials(),
            limiter: limiter,
            plug: fn conn -> Req.Test.json(conn, %{"code" => "200"}) end,
            retry_attempts: 0
          ],
          extra
        )
      )

    want(feed, ["BTC-USD", "DOGE-USD", "SOL-USD", "ETH-USD"])
    feed
  end

  # Delivery times relative to now, in ms ago.
  defp delivered(feed, ago) do
    now = System.monotonic_time(:millisecond)

    :sys.replace_state(feed, fn state ->
      %{state | delivering: Map.new(ago, fn {symbol, ms} -> {symbol, now - ms} end)}
    end)
  end

  defp frame(feed, struct), do: send(feed, {:dp_exchange, :webull, struct})

  defp grab(session_id),
    do: Notice.new(:degraded, :webull, message: @grab, details: %{session_id: session_id})

  describe "the tick" do
    test "drops a shard silent for an interval while a sibling streams; its frame restores it",
         %{limiter: limiter} do
      feed = two_shard_feed(limiter)
      # Shard 0 ticked once, 5 minutes ago, right after the start. Shard 1 streams.
      delivered(feed, %{"BTC-USD" => 300_000, "SOL-USD" => 1_000, "ETH-USD" => 2_000})
      assert Map.keys(Feed.coverage(feed)) == ["BTC-USD", "ETH-USD", "SOL-USD"]

      send(feed, :resubscribe)

      assert Feed.coverage(feed) == %{"ETH-USD" => :stream, "SOL-USD" => :stream}

      frame(feed, quote_for("BTC-USD"))

      assert Feed.coverage(feed) == %{
               "BTC-USD" => :stream,
               "ETH-USD" => :stream,
               "SOL-USD" => :stream
             }
    end

    test "narrows nothing when every shard is silent: that is the whole stream quiet",
         %{limiter: limiter} do
      feed = two_shard_feed(limiter)
      delivered(feed, %{"BTC-USD" => 300_000, "SOL-USD" => 300_000})

      send(feed, :resubscribe)

      assert Feed.coverage(feed) == %{"BTC-USD" => :stream, "SOL-USD" => :stream}
    end

    test "an illiquid pair on a streaming shard stays covered however long it is quiet",
         %{limiter: limiter} do
      feed = two_shard_feed(limiter)

      delivered(feed, %{
        "BTC-USD" => 1_000,
        "DOGE-USD" => 3_600_000,
        "SOL-USD" => 1_000
      })

      send(feed, :resubscribe)

      assert Map.keys(Feed.coverage(feed)) == ["BTC-USD", "DOGE-USD", "SOL-USD"]
    end

    test "with priority_symbols:, the starved non-priority shard drops out (the issue's case)",
         %{limiter: limiter} do
      feed = two_shard_feed(limiter, priority_symbols: ["BTC-USD"])
      delivered(feed, %{"BTC-USD" => 1_000, "SOL-USD" => 600_000, "ETH-USD" => 600_000})

      send(feed, :resubscribe)

      assert Feed.coverage(feed) == %{"BTC-USD" => :stream}
    end

    test "coverage_by_kind/1 is narrowed the same way and stays a union equal to coverage/1",
         %{limiter: limiter} do
      feed = two_shard_feed(limiter)
      frame(feed, quote_for("BTC-USD"))
      frame(feed, top_of_book_for("SOL-USD"))
      # Age shard 0's arrival past the interval; shard 1 keeps streaming.
      delivered(feed, %{"BTC-USD" => 300_000, "SOL-USD" => 1_000})

      :sys.replace_state(feed, fn state ->
        old = System.monotonic_time(:millisecond) - 300_000
        put_in(state.delivering_by_kind[:quotes]["BTC-USD"], old)
      end)

      send(feed, :resubscribe)

      by_kind = Feed.coverage_by_kind(feed)
      assert by_kind[:quotes] == %{}
      assert by_kind[:top_of_book] == %{"SOL-USD" => :stream}

      union = by_kind |> Map.values() |> Enum.reduce(%{}, &Map.merge/2)
      assert union == Feed.coverage(feed)

      # A bid/ask frame restores BTC-USD, but only under the kind that ticked: its
      # `snapshot` arrival predates the loss and is not revived.
      frame(feed, top_of_book_for("BTC-USD"))

      by_kind = Feed.coverage_by_kind(feed)
      assert by_kind[:quotes] == %{}
      assert by_kind[:top_of_book] == %{"BTC-USD" => :stream, "SOL-USD" => :stream}

      union = by_kind |> Map.values() |> Enum.reduce(%{}, &Map.merge/2)
      assert union == Feed.coverage(feed)
    end

    test "a frame handled right after the judgement restores at once, whatever the clock says",
         %{limiter: limiter} do
      feed = two_shard_feed(limiter)
      delivered(feed, %{"BTC-USD" => 1_000, "SOL-USD" => 1_000})

      for _round <- 1..50 do
        frame(feed, grab("shard-0"))
        frame(feed, quote_for("BTC-USD"))
        assert Map.has_key?(Feed.coverage(feed), "BTC-USD")
      end
    end
  end

  describe "the venue's grab notice" do
    test "drops its own session's symbols at once, and only those", %{limiter: limiter} do
      feed = two_shard_feed(limiter)
      delivered(feed, %{"BTC-USD" => 1_000, "SOL-USD" => 1_000, "ETH-USD" => 1_000})

      frame(feed, grab("shard-1"))

      assert Feed.coverage(feed) == %{"BTC-USD" => :stream}

      frame(feed, top_of_book_for("ETH-USD"))

      assert Feed.coverage(feed) == %{"BTC-USD" => :stream, "ETH-USD" => :stream}
    end

    test "other degraded text, an unknown session, or no session changes nothing",
         %{limiter: limiter} do
      feed = two_shard_feed(limiter)
      delivered(feed, %{"BTC-USD" => 1_000, "SOL-USD" => 1_000})

      for notice <- [
            Notice.new(:degraded, :webull,
              message: "heartbeat late",
              details: %{session_id: "shard-0"}
            ),
            grab("no-such-session"),
            Notice.new(:degraded, :webull, message: @grab, details: %{}),
            Notice.new(:degraded, :webull, details: %{session_id: "shard-0"})
          ] do
        frame(feed, notice)
      end

      assert Feed.coverage(feed) == %{"BTC-USD" => :stream, "SOL-USD" => :stream}
    end

    test "is still fanned out to notice subscribers", %{limiter: limiter} do
      feed = two_shard_feed(limiter)
      :ok = Feed.subscribe_notices(feed, to: self())

      frame(feed, grab("shard-0"))

      assert_receive {:dp_exchange, :webull, %Notice{kind: :degraded, message: @grab}}
    end
  end

  test "an unsubscribed symbol forgets its judgement, so a later want starts clean",
       %{limiter: limiter} do
    feed = two_shard_feed(limiter)
    delivered(feed, %{"BTC-USD" => 1_000})
    frame(feed, grab("shard-0"))
    assert Map.has_key?(:sys.get_state(feed).starved_at, "BTC-USD")

    :ok = Feed.unsubscribe(feed, ["BTC-USD"], subscribe_opts(limiter))

    refute Map.has_key?(:sys.get_state(feed).starved_at, "BTC-USD")
  end

  test "the moduledoc names the rule" do
    {:docs_v1, _anno, _lang, _format, %{"en" => doc}, _meta, _docs} = Code.fetch_docs(Feed)
    assert doc =~ "A session that lost the us-crypto permission is not streaming"
  end
end
