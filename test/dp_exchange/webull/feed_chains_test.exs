defmodule DpExchange.Webull.FeedChainsTest do
  @moduledoc """
  Two pieces of Feed bookkeeping that used to pile up under load:

  * a caller's `{:caller_due, from}` deadline, which was left to fire after the caller had
    been answered, and
  * shard open-retry chains, one of which was started by every failed open, so an outage
    ran as many side by side as there had been reshards.
  """

  use DpExchange.Webull.FeedCase, async: true

  alias DpExchange.Core.Notice
  alias DpExchange.Webull.Feed

  # `open_socket/2` refuses before it dials when the credentials carry no app key.
  defp unopenable_opts, do: [credentials: %{app_secret: "s"}, retry_attempts: 0]

  describe "a caller's deadline is cancelled with its answer" do
    test "a parked caller answered by a refusal leaves no timer behind" do
      session = "refused-#{System.unique_integer([:positive])}"
      feed = start_feed(shards: %{0 => %{connected_shard(session) | connected?: false}})
      test_pid = self()
      from = {test_pid, make_ref()}

      # Armed inside the feed, as `reshard/3` arms it, so the feed owns the timer.
      :sys.replace_state(feed, fn state ->
        timer = Process.send_after(self(), :never, 60_000)
        send(test_pid, {:timer, timer})
        state = put_in(state.shards[0].reply_to, [{from, []}])
        %{state | caller_timers: Map.put(state.caller_timers, from, timer)}
      end)

      assert_receive {:timer, timer}, 5_000

      details = %{session_id: session, connack: 4}
      refused = Notice.new(:credentials_rejected, :webull, details: details)
      send(feed, {:dp_exchange, :webull, refused})

      {_pid, tag} = from
      assert_receive {^tag, {:error, {:connection_refused, _details}}}, 5_000

      state = :sys.get_state(feed)
      assert state.caller_timers == %{}

      # Read from the feed, which owns the timer.
      :sys.replace_state(feed, fn state ->
        send(test_pid, {:remaining, Process.read_timer(timer)})
        state
      end)

      assert_receive {:remaining, false}, 5_000
    end

    test "a call answered at once holds no timer" do
      feed = start_feed(shards: %{})

      assert {:error, {:missing_required_field, :app_key}} =
               Feed.subscribe(feed, ["AAA-USD"], credentials: %{app_secret: "s"})

      assert :sys.get_state(feed).caller_timers == %{}
    end
  end

  describe "one open-retry chain per shard slot" do
    test "further failed opens join the live chain instead of starting another" do
      feed = start_feed(shards: %{}, open_retry_base_ms: 60_000, open_retry_max_ms: 60_000)
      want(feed, ["BTCUSD"])

      send(feed, {:open_shard, 0, ["BTCUSD"], unopenable_opts()})
      assert %{0 => token} = :sys.get_state(feed).open_chains

      for _reshard <- 1..3 do
        send(feed, {:open_shard, 0, ["BTCUSD"], unopenable_opts()})
        send(feed, {:reopen_shard, 0, ["BTCUSD"], unopenable_opts(), 2})
      end

      # A second chain would have replaced the token.
      assert %{0 => ^token} = :sys.get_state(feed).open_chains
    end

    test "a message from an ended chain is a no-op, and opens no second socket" do
      feed = start_feed(shards: %{}, open_retry_base_ms: 60_000, open_retry_max_ms: 60_000)
      want(feed, ["BTCUSD"])
      Feed.subscribe_notices(feed, to: self())

      send(feed, {:open_shard, 0, ["BTCUSD"], unopenable_opts()})
      assert %{0 => token} = :sys.get_state(feed).open_chains
      assert_receive {:dp_exchange, :webull, %Notice{severity: :warning}}, 5_000

      # A token the slot does not hold: nothing opens, whatever the opts could do.
      stale = {:reopen_shard, 0, ["BTCUSD"], [credentials: credentials()], 2, make_ref()}
      send(feed, stale)
      _settled = Feed.coverage(feed)
      assert :sys.get_state(feed).shards == %{}

      # The live chain's own message opens the shard and ends the chain.
      send(feed, {:reopen_shard, 0, ["BTCUSD"], [credentials: credentials()], 2, token})
      assert_receive {:dp_exchange, :webull, %Notice{severity: :info}}, 5_000

      state = :sys.get_state(feed)
      assert state.open_chains == %{}
      socket = state.shards[0].socket
      assert is_pid(socket)

      # The ended chain's token again, and a stale one: the slot keeps its one socket.
      send(feed, {:reopen_shard, 0, ["BTCUSD"], [credentials: credentials()], 3, token})
      send(feed, stale)
      _settled = Feed.coverage(feed)
      assert :sys.get_state(feed).shards[0].socket == socket
    end
  end
end
