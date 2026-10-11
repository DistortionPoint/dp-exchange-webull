defmodule DpExchange.Webull.ShardReopenBackoffTest do
  @moduledoc """
  A shard torn down for INVALID_SESSION is reopened on the same crash-window ladder a
  crashed socket uses. Without it a venue answering INVALID_SESSION on every fresh session
  made a reconnect storm: a new websocket and its HTTP round trips on every cycle.

  Nothing here is wanted, so the reopen that does fire opens nothing and no network is
  touched; what is under test is the scheduling.
  """

  use DpExchange.Webull.FeedCase, async: true

  alias DpExchange.Webull.Feed

  defp socket do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
  end

  defp put_shard(feed, session_id) do
    shard = %{connected_shard(session_id) | connected?: false, socket: socket()}
    :sys.replace_state(feed, fn state -> put_in(state.shards[0], shard) end)
  end

  defp invalidate(feed, session_id) do
    put_shard(feed, session_id)
    send(feed, {:reconcile_done, {:link_up, 0}, {:error, {:invalid_session, session_id}}})
    # A call after the send: the mailbox is ordered, so the message above is handled first.
    _settled = Feed.coverage(feed)
    :sys.get_state(feed)
  end

  defp await_state(feed, fun, waited \\ 0) do
    state = :sys.get_state(feed)

    cond do
      fun.(state) ->
        state

      waited >= 5_000 ->
        flunk("state never satisfied the condition: #{inspect(state.reopen_timers)}")

      true ->
        Process.sleep(25)
        await_state(feed, fun, waited + 25)
    end
  end

  test "the first INVALID_SESSION reopens at once, a repeated one is delayed" do
    feed = start_feed(shards: %{}, open_retry_base_ms: 600_000, open_retry_max_ms: 600_000)

    first = invalidate(feed, "s1")
    assert first.crashes[0].count == 1
    assert first.reopen_timers == %{}
    refute Map.has_key?(first.shards, 0)

    second = invalidate(feed, "s2")
    assert second.crashes[0].count == 2
    assert {token, timer} = second.reopen_timers[0]
    assert is_reference(token)
    assert is_integer(Process.read_timer(timer))
    refute Map.has_key?(second.shards, 0), "the slot stays empty while the delay runs"
  end

  test "a socket crash and an INVALID_SESSION share one run counter" do
    feed = start_feed(shards: %{}, open_retry_base_ms: 600_000, open_retry_max_ms: 600_000)

    # A crash first: the slot's socket exits, which `isolate_crashed_shard/3` reopens at once.
    put_shard(feed, "s1")
    send(feed, {:EXIT, :sys.get_state(feed).shards[0].socket, :boom})
    _settled = Feed.coverage(feed)
    after_crash = :sys.get_state(feed)

    assert after_crash.crashes[0].count == 1
    assert after_crash.reopen_timers == %{}

    # An INVALID_SESSION right after is the SECOND teardown of the index within the window,
    # so it is delayed rather than reopened at once.
    second = invalidate(feed, "s2")
    assert second.crashes[0].count == 2
    assert {_token, old_timer} = second.reopen_timers[0]
    assert is_integer(Process.read_timer(old_timer))

    # And a crash after that climbs the same counter and replaces the pending timer.
    put_shard(feed, "s3")
    send(feed, {:EXIT, :sys.get_state(feed).shards[0].socket, :boom})
    _settled = Feed.coverage(feed)
    third = :sys.get_state(feed)

    assert third.crashes[0].count == 3
    assert Process.read_timer(old_timer) == false
    assert {_new_token, new_timer} = third.reopen_timers[0]
    assert is_integer(Process.read_timer(new_timer))
  end

  test "a newer teardown replaces and cancels the pending timer" do
    feed = start_feed(shards: %{}, open_retry_base_ms: 600_000, open_retry_max_ms: 600_000)

    _first = invalidate(feed, "s1")
    second = invalidate(feed, "s2")
    {old_token, old_timer} = second.reopen_timers[0]

    third = invalidate(feed, "s3")
    {new_token, new_timer} = third.reopen_timers[0]

    assert third.crashes[0].count == 3
    refute new_token == old_token
    assert Process.read_timer(old_timer) == false, "the superseded timer must be cancelled"
    assert is_integer(Process.read_timer(new_timer))
  end

  test "a delayed reopen carrying a stale token is ignored" do
    feed = start_feed(shards: %{}, open_retry_base_ms: 600_000, open_retry_max_ms: 600_000)

    _first = invalidate(feed, "s1")
    current = invalidate(feed, "s2")
    {token, _timer} = current.reopen_timers[0]

    send(feed, {:open_shard, 0, [], [], make_ref()})
    _settled = Feed.coverage(feed)

    assert {^token, _timer} = :sys.get_state(feed).reopen_timers[0]

    # The current token is honoured and consumed.
    send(feed, {:open_shard, 0, [], [], token})
    _settled = Feed.coverage(feed)

    assert :sys.get_state(feed).reopen_timers == %{}
  end

  test "the delayed reopen fires on its own timer and clears its entry" do
    feed = start_feed(shards: %{}, open_retry_base_ms: 50, open_retry_max_ms: 50)

    _first = invalidate(feed, "s1")
    second = invalidate(feed, "s2")
    assert Map.has_key?(second.reopen_timers, 0)

    state = await_state(feed, fn state -> state.reopen_timers == %{} end)

    assert Process.alive?(feed)
    refute Map.has_key?(state.shards, 0), "nothing is wanted, so nothing is opened"
  end
end
