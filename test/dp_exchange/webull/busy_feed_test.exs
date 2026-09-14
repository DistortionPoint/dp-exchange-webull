defmodule DpExchange.Webull.BusyFeedTest do
  @moduledoc """
  A public call answers on the feed's own timeout, not `GenServer.call/2`'s default.

  Split out of `feed_test.exs` for wall clock. This test must block a live feed for longer
  than the five-second default it is proving is no longer in force, so six seconds of
  waiting is the substance of it rather than slack that could be trimmed. ExUnit
  parallelises across FILES and serialises within one, so sitting beside ninety other tests
  meant those six seconds ran end to end instead of alongside them.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Config
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
    :ok
  end

  defp connected_shard do
    %{
      session_id: "session-#{System.unique_integer([:positive])}",
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

  describe "subscribe_notices/2 survives a busy feed" do
    @describetag timeout: 60_000

    test "it waits @call_timeout, not GenServer.call/2's five-second default" do
      # `subscribe_notices` was the one public call in `Feed` left on the default timeout.
      # Every sibling call is given `@call_timeout` — 15 seconds, the authors' own statement
      # of how long this feed may legitimately take to answer — and this one had five.
      #
      # The blocker runs INSIDE the feed process: `:sys.replace_state/2` applies its function
      # there, so the sleep occupies the feed exactly as a slow callback would, and the call
      # under test queues behind it on the real mailbox. Six seconds is chosen to sit between
      # the two timeouts: comfortably past the five-second default that used to fire, and
      # nowhere near the fifteen the call is now allowed.
      #
      # A `GenServer.call/3` timeout exits in the CALLER, so before the fix this test would
      # not have failed an assertion — it would have killed the test process with
      # `{:timeout, ...}`, which is the same thing that happened to a host registering for
      # notices while the feed was starting up.
      feed = start_feed()

      blocked = make_ref()
      test_pid = self()

      # `spawn`, not `spawn_link`, and `:sys.replace_state/3` rather than `/2`: the two-arity
      # form carries its own five-second timeout, which the six-second block deliberately
      # outlasts, and a linked blocker would then have killed the test with that exit before
      # the assertion below could run.
      spawn(fn ->
        :sys.replace_state(
          feed,
          fn state ->
            send(test_pid, blocked)
            Process.sleep(6_000)
            state
          end,
          30_000
        )
      end)

      assert_receive ^blocked, 5_000

      started = System.monotonic_time(:millisecond)
      assert :ok = Feed.subscribe_notices(feed, to: self())
      waited = System.monotonic_time(:millisecond) - started

      # Proves the call actually queued behind the block rather than being answered before
      # it started — without which this would pass on the unfixed code too.
      assert waited > 5_000
    end
  end
end
