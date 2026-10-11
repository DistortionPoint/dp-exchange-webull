defmodule DpExchange.Webull.ShardStaggerTest do
  @moduledoc """
  Shards a plan has to open are opened one spacing apart, not all at once.

  `@shard_spacing_ms` is documented as the gap "between opening each shard's socket", but every
  background shard of a plan waited the same constant, so three or four sockets were dialled in
  the same instant - the connect burst the constant exists to avoid.
  """

  use DpExchange.Webull.FeedCase, async: true

  alias DpExchange.Webull.Feed

  @spacing_ms 300

  defp micros({mega, sec, micro}), do: (mega * 1_000_000 + sec) * 1_000_000 + micro

  test "background shards of one plan open a spacing apart" do
    feed = start_feed(shards: %{}, shard_spacing_ms: @spacing_ms)
    :erlang.trace(feed, true, [:receive, :timestamp])

    # Two hundred and fifty symbols plan into shards 0, 1 and 2. Shard 0 is the caller's own
    # and fails at once for want of an app key (a deterministic refusal needing no socket);
    # shards 1 and 2 are the background opens under test.
    symbols = for n <- 1..250, do: "S#{n}-USD"
    assert {:error, _reason} = Feed.subscribe(feed, symbols, credentials: %{app_secret: "s"})

    assert_receive {:trace_ts, ^feed, :receive, {:open_shard, 1, _, _}, first}, 5_000
    assert_receive {:trace_ts, ^feed, :receive, {:open_shard, 2, _, _}, second}, 5_000

    # Half the spacing, for scheduler jitter. Before the fix the gap was a few microseconds.
    assert micros(second) - micros(first) >= @spacing_ms * 1_000 / 2
  end
end
