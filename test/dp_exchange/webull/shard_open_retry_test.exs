defmodule DpExchange.Webull.ShardOpenRetryTest do
  @moduledoc """
  A shard whose socket fails to OPEN is retried — issue #4.

  The reported boot: three of four shards timed out their WebSocket handshake under load
  average 54, and stayed dark for 28 minutes across **zero** reopen attempts until the node
  was restarted. The Feed stayed alive and healthy-looking the whole time; the only evidence
  was one WARN line per shard at boot that nothing ever revisited.

  The cause is a gap between two states that look alike. `handle_info(:resubscribe, _)`
  reduces over `state.shards`, and the failed-open branch returned `{:noreply, state}`
  without putting an entry there — so the shard was not merely un-reopened, it was not
  tracked at all, and its symbols were orphaned.

  The delivery gate added for issue #1 could not have caught it either, which is the part
  worth keeping: that gate reopens a shard once **no symbol of its has arrived** for
  `stale_delivery_ms`, and a shard that never opened has never delivered anything to age.
  **"Never worked" is not "stopped working"**, and only the second was being watched.
  """

  use DpExchange.Webull.FeedCase, async: true

  alias DpExchange.Core.Notice
  alias DpExchange.Webull.Feed

  # `open_socket/2` refuses before it dials when the credentials carry no app key, which is
  # a deterministic failure needing no socket, no port and no timing. What is under test is
  # what the Feed does with a refusal, not which refusal it was.
  defp unopenable_opts do
    [credentials: %{app_secret: "s"}, retry_attempts: 0]
  end

  describe "a shard that never opened is retried, not orphaned" do
    test "a failed open is tracked and says so once, rather than being dropped on the floor" do
      feed = start_feed(shards: %{}, open_retry_base_ms: 20)
      Feed.subscribe_notices(feed, to: self())

      send(feed, {:open_shard, 0, ["BTCUSD"], unopenable_opts()})

      assert_receive {:dp_exchange, :webull, %Notice{kind: :coverage_change} = notice}
      assert notice.severity == :warning
      assert notice.message =~ "shard 0 could not be opened"
      assert notice.details.shard == 0
      assert notice.details.symbol_count == 1

      # Tracked, which is the whole difference: before this, a failed open left NOTHING
      # behind — not a shard entry, not a latch, not a scheduled message.
      assert MapSet.member?(:sys.get_state(feed).open_failed, 0)

      # And exactly once while it stays down. The log keeps firing on every attempt by
      # design; a notice per attempt on a sustained outage is a storm, just a slower one.
      refute_receive {:dp_exchange, :webull, %Notice{kind: :coverage_change}}, 200

      assert Process.alive?(feed)
    end

    test "the retry keeps running, and stops once the shard is open" do
      feed = start_feed(shards: %{}, open_retry_base_ms: 20)
      Feed.subscribe_notices(feed, to: self())

      send(feed, {:open_shard, 0, ["BTCUSD"], unopenable_opts()})
      assert_receive {:dp_exchange, :webull, %Notice{severity: :warning}}

      # Something else fills the slot between two attempts — a `reshard/4` or a `subscribe/2`
      # taking its own route to opening it, which is exactly what the guard in the retry
      # clause exists for.
      :sys.replace_state(feed, fn state ->
        put_in(state.shards[0], %{connected_shard("recovered") | symbols: ["BTCUSD"]})
      end)

      # This recovery notice can only be produced by a `{:reopen_shard, ...}` message
      # arriving AFTER the slot was filled — so receiving it proves the retry was still
      # scheduled and still running, which is the claim this test exists to make.
      assert_receive {:dp_exchange, :webull, %Notice{kind: :coverage_change} = recovery}
      assert recovery.severity == :info
      assert recovery.message =~ "shard 0 opened after failing to"
      assert recovery.details.shard == 0

      refute MapSet.member?(:sys.get_state(feed).open_failed, 0)

      # And it does not go on retrying a slot that is filled.
      refute_receive {:dp_exchange, :webull, %Notice{kind: :coverage_change}}, 200
    end

    test "a retry that succeeds installs the shard and clears the latch" do
      feed = start_feed(shards: %{}, open_retry_base_ms: 20)
      Feed.subscribe_notices(feed, to: self())

      send(feed, {:open_shard, 0, ["BTCUSD"], unopenable_opts()})
      assert_receive {:dp_exchange, :webull, %Notice{severity: :warning}}

      # The same retry message the scheduler sends, with opts that can actually open. The
      # socket is this venue's real `Socket`, which connects lazily, so no server is needed.
      send(feed, {:reopen_shard, 0, ["BTCUSD"], [credentials: credentials()], 2})

      assert_receive {:dp_exchange, :webull, %Notice{severity: :info} = recovery}
      assert recovery.message =~ "shard 0 opened after failing to"

      shard = :sys.get_state(feed).shards[0]
      assert is_pid(shard.socket)
      assert shard.symbols == ["BTCUSD"]
      refute MapSet.member?(:sys.get_state(feed).open_failed, 0)
    end
  end
end
