defmodule DpExchange.Webull.BlindResubscribeTest do
  @moduledoc """
  One tick, one blind resubscribe — a second tick must not start another over it.

  Alone in a file because proving "not duplicated" means watching a whole tick interval go
  by with nothing happening, which is four seconds that cannot be shortened without
  weakening the claim. See `DpExchange.Webull.FeedCase`.
  """

  use DpExchange.Webull.FeedCase, async: true

  describe "a tick does not launch a second blind resubscribe over an unfinished one — issue #3" do
    test "an unfinished blind resubscribe is not duplicated on the next tick", %{
      limiter: limiter
    } do
      # The other half of the same defect, and the reason it is a skip rather than a
      # supersede: a second identical subscribe for a session the venue has not answered for
      # yet is load, not a safety net. `validate_resubscribe_interval_ms!/1` already refuses
      # an interval below a second in those exact words; an in-flight attempt makes the
      # effective interval shorter than the configured one just as surely.
      test_pid = self()

      plug = fn conn ->
        send(test_pid, {:resubscribing, self()})
        Process.sleep(:infinity)
        conn
      end

      feed =
        start_feed(
          shards: %{0 => %{connected_shard("s0") | symbols: ["BTC-USD"]}},
          resubscribe_interval_ms: 1_000,
          reconcile_timeout_ms: 60_000,
          resubscribe_failure_limit: 99,
          credentials: credentials(),
          limiter: limiter,
          plug: plug
        )

      # A deadline far beyond the tick interval, so nothing clears the in-flight attempt:
      # every later tick sees it still running, and must leave it alone.
      assert_receive {:resubscribing, _first_task}, 5_000
      refute_receive {:resubscribing, _second_task}, 3_000

      assert map_size(:sys.get_state(feed).reconciling) == 1
      assert Process.alive?(feed)
    end
  end
end
