defmodule DpExchange.Webull.ShardStaggerTest do
  @moduledoc """
  Shards a plan has to open are opened one spacing apart, not all at once.

  `@shard_spacing_ms` is documented as the gap "between opening each shard's socket", but every
  background shard of a plan waited the same constant, so three or four sockets were dialled in
  the same instant - the connect burst the constant exists to avoid.

  The spacing is armed at plan time (`spacing * position`) and is ALSO enforced when the open
  is handled: a Feed busy past several deadlines receives the timers back to back (seen under
  the full gate, 4 microseconds apart), and used to dial in a burst.
  """

  use DpExchange.Webull.FeedCase, async: true

  alias DpExchange.Webull.Feed

  @spacing_ms 300

  # `open_socket/2` refuses before it dials when the credentials carry no app key.
  defp unopenable_opts, do: [credentials: %{app_secret: "s"}, retry_attempts: 0]

  defp micros({mega, sec, micro}), do: (mega * 1_000_000 + sec) * 1_000_000 + micro

  # Every arrival of `{:open_staggered, index, ...}` seen within `window_ms`, as microseconds.
  defp arrivals(feed, index, window_ms) do
    receive do
      {:trace_ts, ^feed, :receive, {:open_staggered, ^index, _symbols, _opts}, at} ->
        [micros(at) | arrivals(feed, index, window_ms)]
    after
      window_ms -> []
    end
  end

  test "background shards of one plan open a spacing apart" do
    feed = start_feed(shards: %{}, shard_spacing_ms: @spacing_ms)
    :erlang.trace(feed, true, [:receive, :timestamp])

    # Two hundred and fifty symbols plan into shards 0, 1 and 2. Shard 0 is the caller's own
    # and fails at once for want of an app key (a deterministic refusal needing no socket);
    # shards 1 and 2 are the background opens under test.
    symbols = for n <- 1..250, do: "S#{n}-USD"
    assert {:error, _reason} = Feed.subscribe(feed, symbols, credentials: %{app_secret: "s"})

    assert_receive {:trace_ts, ^feed, :receive, {:open_staggered, 1, _, _}, first}, 5_000

    # A Feed busy past both deadlines receives the two back to back and re-arms the second, so
    # what spaces the opens is the LAST arrival of shard 2's message, not the first.
    [_first | _rest] = second = arrivals(feed, 2, @spacing_ms * 4)

    # Half the spacing, for scheduler jitter. Before the fix the gap was a few microseconds.
    assert Enum.max(second) - micros(first) >= @spacing_ms * 1_000 / 2
  end

  test "an open handled less than a spacing after the last one is re-armed for the remainder" do
    # Deterministic: both opens are sent back to back, so the second is handled with no time
    # elapsed since the first, whatever the scheduler is doing.
    feed = start_feed(shards: %{}, shard_spacing_ms: @spacing_ms)
    :erlang.trace(feed, true, [:receive, :timestamp])

    assert :sys.get_state(feed).last_background_open == nil

    send(feed, {:open_staggered, 1, ["AAA-USD"], unopenable_opts()})
    send(feed, {:open_staggered, 2, ["BBB-USD"], unopenable_opts()})

    # Shard 1 was handled at once: its open is on record.
    assert is_integer(:sys.get_state(feed).last_background_open)

    # Shard 2 arrived twice: once back to back, once re-armed about a spacing later.
    assert [_first | _rest] = arrived = arrivals(feed, 2, @spacing_ms * 4)
    assert length(arrived) >= 2
    [first_arrival | rest] = Enum.sort(arrived)
    assert Enum.max(rest) - first_arrival >= @spacing_ms * 1_000 / 2
  end

  test "an open for a shard that is already open neither waits nor counts as an open" do
    feed = start_feed(shards: %{1 => connected_shard("already-open")}, shard_spacing_ms: 60_000)

    send(feed, {:open_staggered, 1, ["AAA-USD"], unopenable_opts()})

    state = :sys.get_state(feed)
    assert state.last_background_open == nil
    assert Map.has_key?(state.shards, 1)
  end
end
