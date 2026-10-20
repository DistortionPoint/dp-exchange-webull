defmodule DpExchange.Webull.TickAaFeedTest do
  @moduledoc """
  Feed branches that the rest of the suite never ran: the answers to events that arrive at an
  awkward moment (a refusal with nobody waiting, a late answer for a replaced session, a
  shard that is already gone) and the first-open path of a primary subscribe.

  Every test drives the real `Feed` process through the same messages its sockets and tasks
  send, and asserts what the Feed must do about them. Margins are 5_000 ms or more.
  """

  use DpExchange.Webull.FeedCase, async: true

  alias DpExchange.Core.{Config, Notice}
  alias DpExchange.Core.Types.{Position, Trade}
  alias DpExchange.Webull.{Feed, Socket}

  defp await_shard(feed, index, tries \\ 1_000) do
    case Map.get(:sys.get_state(feed).shards, index) do
      nil when tries > 0 ->
        Process.sleep(10)
        await_shard(feed, index, tries - 1)

      nil ->
        flunk("shard #{index} never appeared")

      shard ->
        shard
    end
  end

  defp stalled_entry(context) do
    stalled = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> if Process.alive?(stalled), do: Process.exit(stalled, :kill) end)
    %{pid: stalled, ref: Process.monitor(stalled), attempt: make_ref(), context: context}
  end

  describe "notices" do
    test "a notice of any other kind is forwarded to notice subscribers unchanged" do
      feed = start_feed()
      :ok = Feed.subscribe_notices(feed, to: self())
      notice = Notice.new(:coverage_change, :webull, message: "shard 0 note")

      send(feed, {:dp_exchange, :webull, notice})

      assert_receive {:dp_exchange, :webull, ^notice}
    end

    test "a refusal for a shard nobody is parked on is forwarded and changes nothing" do
      feed = start_feed(shards: %{0 => connected_shard("s0")})
      :ok = Feed.subscribe_notices(feed, to: self())

      notice =
        Notice.new(:credentials_rejected, :webull, details: %{session_id: "s0", connack: 4})

      send(feed, {:dp_exchange, :webull, notice})

      assert_receive {:dp_exchange, :webull, ^notice}
      shard = :sys.get_state(feed).shards[0]
      assert shard.reply_to == nil
      assert shard.connected?
    end

    test "a notice subscriber registered by a name nobody holds is skipped, not fatal" do
      feed = start_feed()
      :ok = Feed.subscribe_notices(feed, to: :tick_aa_nobody_registered_this)

      send(feed, {:dp_exchange, :webull, Notice.new(:coverage_change, :webull, message: "x")})

      assert Feed.coverage(feed) == %{}
      assert Process.alive?(feed)
    end
  end

  describe "messages that arrive after the world moved on" do
    test "an open for a slot a reshard already filled changes nothing", %{limiter: limiter} do
      feed = start_feed(shards: %{0 => connected_shard("s0")})

      send(feed, {:open_shard, 0, ["BTC-USD"], subscribe_opts(limiter)})
      _settled = Feed.coverage(feed)

      shard = :sys.get_state(feed).shards[0]
      assert shard.session_id == "s0"
      assert shard.symbols == []
    end

    test "a background reconcile planned for another session is not run", %{limiter: limiter} do
      connecting = %{connected_shard("s1") | connected?: false}
      feed = start_feed(shards: %{0 => connected_shard("s0"), 1 => connecting})

      opts = subscribe_opts(limiter)
      send(feed, {:reconcile_shard, 0, "a-previous-session", ["BTC-USD"], [], opts})
      send(feed, {:reconcile_shard, 1, "s1", ["BTC-USD"], [], opts})
      _settled = Feed.coverage(feed)

      assert :sys.get_state(feed).reconciling == %{}
    end

    test "a retry for symbols that are no longer wanted opens nothing and clears the latch" do
      feed = start_feed(shards: %{})

      :sys.replace_state(feed, fn state ->
        %{
          state
          | open_failed: MapSet.new([0]),
            open_chains: Map.put(state.open_chains, 0, make_ref())
        }
      end)

      send(feed, {:reopen_shard, 0, ["BTC-USD"], [credentials: credentials()], 2})
      _settled = Feed.coverage(feed)

      state = :sys.get_state(feed)
      refute MapSet.member?(state.open_failed, 0)
      refute Map.has_key?(state.open_chains, 0)
      assert state.shards == %{}
    end

    test "a caller who is not parked anywhere is left alone while others are" do
      connecting = %{connected_shard("s3") | connected?: false}
      feed = start_feed(shards: %{3 => connecting})
      bystander = {self(), make_ref()}
      :sys.replace_state(feed, &put_in(&1.shards[3].reply_to, [{bystander, []}]))

      ref = make_ref()
      send(feed, {:caller_due, {self(), ref}})
      _settled = Feed.coverage(feed)

      refute_received {^ref, _reply}
      assert [{^bystander, []}] = :sys.get_state(feed).shards[3].reply_to
    end

    test "a caller due while only background work is in flight is left alone" do
      feed = start_feed()
      entry = stalled_entry(nil)

      :sys.replace_state(feed, fn state ->
        %{state | reconciling: Map.put(state.reconciling, {:background, 0}, entry)}
      end)

      ref = make_ref()
      send(feed, {:caller_due, {self(), ref}})
      _settled = Feed.coverage(feed)

      refute_received {^ref, _reply}
      assert Map.has_key?(:sys.get_state(feed).reconciling, {:background, 0})
    end

    test "superseding a background reconcile of a replaced session reverts nothing",
         %{limiter: limiter} do
      feed = start_feed(shards: %{0 => %{connected_shard("new") | symbols: ["BTC-USD"]}})
      entry = stalled_entry(%{session_id: "old", added: ["BTC-USD"], removed: []})

      :sys.replace_state(feed, fn state ->
        %{state | reconciling: Map.put(state.reconciling, {:background, 0}, entry)}
      end)

      send(feed, {:reconcile_shard, 0, "new", [], [], subscribe_opts(limiter)})
      _settled = Feed.coverage(feed)

      state = :sys.get_state(feed)
      assert state.shards[0].symbols == ["BTC-USD"]
      refute MapSet.member?(state.unsettled, 0)
    end

    test "a blind resubscribe answered for a replaced session sends no cleanup" do
      feed = start_feed(shards: %{0 => connected_shard("new")})

      attempt = %{session_id: "old", sent: ["BTC-USD"]}
      :sys.replace_state(feed, &put_in(&1.settled[{:resubscribe, 0}], attempt))

      send(feed, {:reconcile_done, {:resubscribe, 0}, :ok})
      _settled = Feed.coverage(feed)

      state = :sys.get_state(feed)
      assert state.reconciling == %{}
      assert state.settled == %{}
    end
  end

  describe "a venue refusal that arrives for a replaced session" do
    test "INVALID_SYMBOL is still recorded, because it is true whichever session carried it" do
      feed = start_feed(shards: %{0 => connected_shard("new")})
      :ok = Feed.subscribe_notices(feed, to: self())

      attempt = %{session_id: "old", added: ["ZZZ-USD"], removed: []}
      :sys.replace_state(feed, &put_in(&1.settled[{:background, 0}], attempt))

      send(feed, {:reconcile_done, {:background, 0}, {:error, {:invalid_symbols, ["ZZZ-USD"]}}})

      assert_receive {:dp_exchange, :webull, %Notice{kind: :refusal} = notice}
      assert notice.details.symbols == ["ZZZ-USD"]
      assert Map.has_key?(:sys.get_state(feed).rejected, "ZZZ-USD")
    end
  end

  describe "INVALID_SESSION" do
    test "naming no session tears down the shard's current one" do
      shard = %{connected_shard("s0") | socket: nil, symbols: ["BTC-USD"]}
      feed = start_feed(shards: %{0 => shard})
      :ok = Feed.subscribe_notices(feed, to: self())

      send(feed, {:reconcile_done, {:background, 0}, {:error, {:invalid_session, nil}}})

      assert_receive {:dp_exchange, :webull, %Notice{kind: :link_down} = notice}
      assert notice.details.session_id == "s0"
      refute Map.has_key?(:sys.get_state(feed).shards, 0)
    end

    test "for a tracked attempt on the current session rebuilds it, leaving nothing unsettled" do
      shard = %{connected_shard("s0") | socket: nil}
      feed = start_feed(shards: %{0 => shard})
      attempt = %{session_id: "s0", added: [], removed: []}

      :sys.replace_state(feed, fn state ->
        state = put_in(state.settled[{:background, 0}], attempt)
        %{state | unsettled: MapSet.new([0])}
      end)

      send(feed, {:reconcile_done, {:background, 0}, {:error, {:invalid_session, "s0"}}})
      _settled = Feed.coverage(feed)

      state = :sys.get_state(feed)
      refute Map.has_key?(state.shards, 0)
      refute MapSet.member?(state.unsettled, 0)
    end

    test "for a shard that is already gone is ignored" do
      feed = start_feed()
      :ok = Feed.subscribe_notices(feed, to: self())

      send(feed, {:reconcile_done, {:background, 7}, {:error, {:invalid_session, "gone"}}})
      _settled = Feed.coverage(feed)

      refute_received {:dp_exchange, :webull, %Notice{kind: :link_down}}
      assert Map.keys(:sys.get_state(feed).shards) == [0]
    end
  end

  describe "a failed answer is reverted against what the Feed actually recorded" do
    test "an answer with no tracked attempt clears the index's unsettled mark" do
      feed = start_feed()
      :sys.replace_state(feed, &%{&1 | unsettled: MapSet.new([0])})

      send(feed, {:reconcile_done, {:background, 0}, {:error, :boom}})
      _settled = Feed.coverage(feed)

      refute MapSet.member?(:sys.get_state(feed).unsettled, 0)
    end

    test "a context that records no delta only clears the mark" do
      feed = start_feed(shards: %{0 => %{connected_shard("s0") | symbols: ["BTC-USD"]}})

      :sys.replace_state(feed, fn state ->
        state = put_in(state.settled[{:background, 0}], %{session_id: "s0"})
        %{state | unsettled: MapSet.new([0])}
      end)

      send(feed, {:reconcile_done, {:background, 0}, {:error, :boom}})
      _settled = Feed.coverage(feed)

      state = :sys.get_state(feed)
      refute MapSet.member?(state.unsettled, 0)
      assert state.shards[0].symbols == ["BTC-USD"]
    end

    test "a context that names no session, for a shard that is gone, changes nothing" do
      feed = start_feed()
      attempt = %{added: ["X"], removed: []}
      :sys.replace_state(feed, &put_in(&1.settled[{:background, 9}], attempt))

      send(feed, {:reconcile_done, {:background, 9}, {:error, :boom}})
      _settled = Feed.coverage(feed)

      state = :sys.get_state(feed)
      assert Map.keys(state.shards) == [0]
      assert state.unsettled == MapSet.new()
      assert state.settled == %{}
    end

    test "a failed blind resubscribe of a shard that is gone does not reopen anything" do
      feed = start_feed(shards: %{}, resubscribe_failure_limit: 1)
      :ok = Feed.subscribe_notices(feed, to: self())

      send(feed, {:reconcile_done, {:resubscribe, 3}, {:error, :boom}})

      assert_receive {:dp_exchange, :webull, %Notice{kind: :coverage_change}}
      state = :sys.get_state(feed)
      assert state.shards == %{}
      assert state.resubscribe_failed == %{3 => 1}
      refute_received {:dp_exchange, :webull, %Notice{kind: :link_down}}
    end
  end

  describe "what a payload does to coverage" do
    test "a struct that names no data kind is delivered and counted, under no kind",
         %{limiter: limiter} do
      feed = start_feed()
      :ok = Feed.subscribe(feed, ["BTC-USD"], subscribe_opts(limiter))

      position = %Position{
        symbol: "BTC-USD",
        side: :long,
        quantity: Decimal.new("1"),
        provider: :webull
      }

      send(feed, {:dp_exchange, :webull, position})

      assert_receive {:dp_exchange, :webull, ^position}
      assert Feed.coverage(feed) == %{"BTC-USD" => :stream}
      by_kind = Feed.coverage_by_kind(feed)
      assert Enum.all?(by_kind, fn {_kind, per_symbol} -> per_symbol == %{} end)
    end

    test "a trade that names no usable symbol is delivered and counted nowhere",
         %{limiter: limiter} do
      feed = start_feed()
      :ok = Feed.subscribe(feed, ["BTC-USD"], subscribe_opts(limiter))

      trade = %Trade{
        id: nil,
        symbol: nil,
        side: nil,
        price: Decimal.new("1"),
        quantity: Decimal.new("1"),
        timestamp: ~U[2026-10-13 12:00:00Z],
        broken: false,
        provider: :webull
      }

      send(feed, {:dp_exchange, :webull, trade})

      assert_receive {:dp_exchange, :webull, ^trade}
      assert Feed.coverage(feed) == %{}
    end
  end

  describe "opening a shard" do
    test "a first subscribe opens a shard and parks the caller until its CONNACK or deadline",
         %{limiter: limiter} do
      feed = start_feed(shards: %{}, connack_timeout_ms: 30_000)

      task = Task.async(fn -> Feed.subscribe(feed, ["BTC-USD"], subscribe_opts(limiter)) end)
      shard = await_shard(feed, 0)

      refute shard.connected?
      assert is_pid(shard.socket)
      assert shard.symbols == ["BTC-USD"]
      assert [{_from, []}] = shard.reply_to

      send(feed, {:connack_timeout, 0, shard.session_id})

      assert {:error, {:connack_timeout, 30_000}} = Task.await(task, 15_000)
      assert :sys.get_state(feed).shards[0].reply_to == nil
    end

    test "with no websocket_url seam, an environment with no stream refuses the open" do
      Config.put_override(:websocket_url, nil)
      test_pid = self()
      feed = start_feed(shards: %{})

      # The Feed resolves overrides through `$callers`, which `GenServer.start_link/3` does
      # not set. Runs inside the Feed, so the override reaches the process that reads it.
      :sys.replace_state(feed, fn state ->
        Process.put(:"$callers", [test_pid])
        state
      end)

      want(feed, ["BTC-USD"])
      :ok = Feed.subscribe_notices(feed, to: self())

      opts = [credentials: credentials(), environment: :uat, retry_attempts: 0]
      send(feed, {:open_shard, 0, ["BTC-USD"], opts})

      assert_receive {:dp_exchange, :webull, %Notice{kind: :coverage_change} = notice}
      assert notice.message =~ "could not be opened"
      assert notice.message =~ "insecure_url"
    end
  end

  describe "failure of the feed's own machinery" do
    test "the task supervisor going down stops the feed rather than answering without it" do
      Process.flag(:trap_exit, true)
      feed = start_feed()
      supervisor = :sys.get_state(feed).task_supervisor
      ref = Process.monitor(feed)

      Process.exit(supervisor, :kill)

      assert_receive {:DOWN, ^ref, :process, ^feed, {:task_supervisor_down, :killed}}, 5_000
    end

    test "a priority list holding a non-string fails at start" do
      Process.flag(:trap_exit, true)

      assert {:error, {%ArgumentError{message: message}, _stacktrace}} =
               Feed.start_link(
                 priority_symbols: ["BTC-USD", :eth_usd],
                 name: :"priority_bad_#{System.unique_integer([:positive])}"
               )

      assert message =~ ":priority_symbols must be a list of symbol strings"
    end

    test "a clean shutdown sends DISCONNECT to a live socket and reports :ok" do
      url = Application.fetch_env!(:dp_exchange_webull, :websocket_url)

      {:ok, socket} =
        Socket.start_link(
          url: url,
          subscriber: self(),
          session_id: "tick-aa-live",
          app_key: "test-key-not-real"
        )

      # 5000 ms, not the 500 ms default: under the full --cover gate the call can queue past it.
      assert Socket.disconnect(socket, 5_000) == :ok

      # A `:normal` stop also stops the socket (tick AO), and this test is the socket's parent:
      # trapping turns the exit it is linked to into a message instead of ending the test.
      Process.flag(:trap_exit, true)

      shards = %{0 => %{connected_shard("tick-aa-live") | socket: socket}}
      assert Feed.terminate(:normal, %{shards: shards}) == :ok
      assert_receive {:EXIT, ^socket, :shutdown}, 5_000
    end
  end
end
