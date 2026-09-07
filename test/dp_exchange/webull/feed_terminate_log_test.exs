defmodule DpExchange.Webull.FeedTerminateLogTest do
  @moduledoc """
  `Feed.terminate/2`'s shutdown-DISCONNECT logging, split out of `FeedTest` and run
  `async: false` on purpose.

  Every test here calls `ExUnit.CaptureLog.capture_log/1,2` and asserts on its *content*
  — not just that it ran, but which specific substring appears. `capture_log`'s isolation
  depends on a global swap of the Logger backend's output device; a *content* assertion
  raced against it is exactly the case `async: true` breaks, because a message another
  test happens to log during the capture window's real concurrency leaks into this one's
  buffer. `FeedTest` itself has 60+ other tests that log at `:debug` (including several
  in this exact `terminate/2` shape, before this file existed) and Req/Finch's own
  request logging elsewhere in the suite, so under `max_cases: 20` a manual `capture_log`
  content assertion here occasionally saw a *different* test's "skipped" or "DISCONNECT"
  line rather than — or in addition to — its own.

  Found by a cross-package audit running the full suite on multiple explicit seeds, which
  this family's CI does not do by default: seed 1 and 999 passed; seed 42 failed on
  `refute log =~ "skipped"` with a captured blob of unrelated HTTP request debug logs
  from concurrently-running tests. `async: false` is the correct fix, not a wider
  `assert_receive` timeout or a narrower substring — the underlying mechanism genuinely
  is not concurrency-safe for content assertions, and nothing about timing tunes that
  away.
  """

  use ExUnit.Case, async: false

  alias DpExchange.Webull.Feed

  @moduletag :capture_log

  # A pre-connected shard 0, standing in for one that already opened and saw its
  # CONNACK. `session_id` is overridable because one test in `FeedTest` asserts on it;
  # nothing here needs that, but the helper is kept identical to `FeedTest`'s own so the
  # two files stay obviously equivalent at a glance.
  defp connected_shard(session_id \\ nil) do
    %{
      session_id: session_id || "session-#{System.unique_integer([:positive])}",
      socket: self(),
      connected?: true,
      symbols: [],
      reply_to: nil
    }
  end

  # A real pid, guaranteed dead by the time it is used — `Socket.disconnect/2` must
  # answer with `{:error, :not_alive}` for one rather than raise, and asserting on that
  # from here doubles as an observable signal that `terminate/2` actually attempted the
  # shard: a shard it skips never calls `disconnect/2` at all, so it never logs.
  defp dead_pid do
    pid = spawn(fn -> :ok end)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    pid
  end

  describe "terminate/2" do
    # A clean shutdown attempts `DISCONNECT` on every shard `terminate/2` believes is
    # connected — see `Socket.disconnect/2` and `MqttPacket.disconnect/0`. Driven
    # directly against `terminate/2`, the same way `SocketTest` drives frame handlers
    # directly: no process lifecycle is needed to exercise a plain function of state.
    #
    # `dead_pid/0` doubles as the observable here — `Socket.disconnect/2` returns
    # `{:error, :not_alive}` for a dead pid it was asked to send to, and `terminate/2`
    # logs that at `:debug` (an already-dead socket on shutdown is the ordinary case, not
    # a failure — see `log_disconnect_failure/2`'s own comment), so a debug line naming a
    # shard's index is proof `terminate/2` attempted that shard, and its absence is proof
    # it did not.
    test "attempts every connected shard, for an ordinary shutdown" do
      shards = %{
        0 => %{connected_shard("s0") | socket: dead_pid()},
        1 => %{connected_shard("s1") | socket: dead_pid()}
      }

      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          assert Feed.terminate(:normal, %{shards: shards}) == :ok
        end)

      assert log =~ "shard 0 DISCONNECT on shutdown skipped"
      assert log =~ "shard 1 DISCONNECT on shutdown skipped"
    end

    test "skips a shard that never connected — it has no session to close" do
      shards = %{0 => %{connected_shard("s0") | socket: dead_pid(), connected?: false}}

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Feed.terminate(:shutdown, %{shards: shards}) == :ok
        end)

      refute log =~ "DISCONNECT"
    end

    test "runs for every reason GenServer treats as normal termination" do
      for reason <- [:normal, :shutdown, {:shutdown, :some_reason}] do
        shards = %{0 => %{connected_shard("s0") | socket: dead_pid()}}

        log =
          ExUnit.CaptureLog.capture_log([level: :debug], fn ->
            assert Feed.terminate(reason, %{shards: shards}) == :ok
          end)

        assert log =~ "shard 0 DISCONNECT on shutdown skipped"
      end
    end

    test "a crash reason skips the sweep — extra socket I/O is the wrong thing mid-crash" do
      shards = %{0 => %{connected_shard("s0") | socket: dead_pid()}}

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Feed.terminate({:some_crash, :reason}, %{shards: shards}) == :ok
        end)

      refute log =~ "DISCONNECT"
    end

    test "no shards at all is a no-op" do
      assert Feed.terminate(:normal, %{shards: %{}}) == :ok
    end

    test "a shard whose socket happens to be the caller's own pid does not crash" do
      # Found live: `:sys.replace_state/2` runs its function inside the target process,
      # so a fixture built that way with `socket: self()` (as one test elsewhere in the
      # family, and one in `WebullTest`, both do) captures `Feed`'s own pid, not a
      # distinct fake. `terminate/2` calling `disconnect/2` on itself must not crash the
      # shutdown that is already in progress — see `SocketTest`'s matching case for why
      # `WebSockex.send_frame/3` makes this a real, not hypothetical, risk.
      shards = %{0 => %{connected_shard("s0") | socket: self()}}

      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          assert Feed.terminate(:normal, %{shards: shards}) == :ok
        end)

      # `:calling_self` is structural too — see `log_disconnect_failure/2` — so this is
      # `:debug`, not a warning, the same as the dead-pid cases above.
      assert log =~ "shard 0 DISCONNECT on shutdown skipped"
    end

    test "a live socket that fails to send still warns — that one is a real failure" do
      # `:not_alive` and `:calling_self` are the two structural reasons `terminate/2`
      # demotes to `:debug` (see `log_disconnect_failure/2`). Neither is "the DISCONNECT
      # could have been sent and was not" — this fixture is: a genuinely alive process
      # that never answers, the same shape `SocketTest`'s "an alive process that never
      # answers times out as an error, not a hang" uses. The venue really will see an
      # abrupt disconnect here, so this must stay a warning.
      unresponsive = spawn(fn -> Process.sleep(:infinity) end)
      shards = %{0 => %{connected_shard("s0") | socket: unresponsive}}

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Feed.terminate(:normal, %{shards: shards}) == :ok
        end)

      assert log =~ "shard 0 DISCONNECT on shutdown failed"
      refute log =~ "skipped"

      Process.exit(unresponsive, :kill)
    end
  end
end
