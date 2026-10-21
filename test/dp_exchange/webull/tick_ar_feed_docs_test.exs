defmodule DpExchange.Webull.TickARFeedDocsTest do
  @moduledoc """
  Tick AR, lens V, on `DpExchange.Webull.Feed`: what its documentation says, held against what
  it does.

  Each test drives the behaviour a `@moduledoc` or `@doc` sentence promises and then checks
  the sentence is still there, so a change to either side fails here rather than going
  unnoticed. The moduledoc text is read from the compiled docs chunk.
  """

  use DpExchange.Webull.FeedCase, async: true

  alias DpExchange.Core.Fanout
  alias DpExchange.Webull.{Feed, Ledger, Options, Socket}

  defp wait_until(fun, deadline \\ System.monotonic_time(:millisecond) + 5_000) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition never became true")

      true ->
        Process.sleep(25)
        wait_until(fun, deadline)
    end
  end

  # A feed whose only shard is still connecting, so a subscribe PARKS (is pending) instead of
  # being answered, and the test decides how each pending call ends.
  defp start_connecting_feed(extra \\ []) do
    session_id = "s-ar-#{System.unique_integer([:positive])}"
    shard = %{connected_shard(session_id) | connected?: false, symbols: []}
    {start_feed(Keyword.merge([shards: %{0 => shard}], extra)), session_id}
  end

  # A call PARKS only when it changes the connecting shard's list: a call whose symbols the
  # shard already carries is answered on the spot and never pending. Two calls that overlap on
  # one symbol therefore each name one more symbol of their own.
  defp park_subscribe(feed, symbols, subscriber, limiter) do
    opts = subscribe_opts(limiter, to: subscriber, environment: :production)
    pending = map_size(:sys.get_state(feed).call_undo)
    task = Task.async(fn -> Feed.subscribe(feed, List.wrap(symbols), opts) end)
    wait_until(fn -> map_size(:sys.get_state(feed).call_undo) > pending end)
    task
  end

  # The `from` the feed holds for the call a task made.
  defp call_of(feed, %Task{pid: pid}) do
    feed
    |> :sys.get_state()
    |> Map.fetch!(:call_undo)
    |> Map.keys()
    |> Enum.find(fn {caller, _tag} -> caller == pid end)
  end

  defp refuse(feed, task) do
    send(feed, {:caller_due, call_of(feed, task)})
    assert {:error, {:connack_timeout, _ms}} = Task.await(task, 10_000)
  end

  defp monitors_by(feed, pid) do
    {:monitored_by, by} = Process.info(pid, :monitored_by)
    Enum.count(by, &(&1 == feed))
  end

  defp moduledoc do
    {:docs_v1, _anno, _lang, _format, %{"en" => text}, _meta, _entries} = Code.fetch_docs(Feed)
    text
  end

  defp function_doc(name, arity) do
    {:docs_v1, _anno, _lang, _format, _moduledoc, _meta, entries} = Code.fetch_docs(Feed)

    Enum.find_value(entries, :missing, fn
      {{:function, ^name, ^arity}, _anno, _signature, doc, _meta} -> doc
      _other_entry -> nil
    end)
  end

  describe "a refused option is refused, never read as absent" do
    test "resubscribe_interval_ms: false is an ArgumentError naming it, not the default" do
      Process.flag(:trap_exit, true)

      for bad <- [false, "60000", 999, 1.5, :soon, 0, -1] do
        assert {:error, {%ArgumentError{message: message}, _stack}} =
                 Feed.start_link(name: nil, resubscribe_interval_ms: bad)

        assert message =~ "resubscribe_interval_ms"
        assert message =~ inspect(bad)
      end
    end

    test "nil is absent and takes the documented default" do
      feed = start_feed(resubscribe_interval_ms: nil)

      assert :sys.get_state(feed).resubscribe_interval_ms == 60_000
    end

    test "priority_symbols that are not a list of strings fail init" do
      Process.flag(:trap_exit, true)

      for bad <- [false, "BTC-USD", [:btc], [1]] do
        assert {:error, {%ArgumentError{message: message}, _stack}} =
                 Feed.start_link(name: nil, priority_symbols: bad)

        assert message =~ ":priority_symbols"
      end
    end
  end

  describe "the documented defaults are the ones the feed starts with" do
    @defaults %{
      resubscribe_interval_ms: {60_000, "60_000"},
      connack_timeout_ms: {10_000, "10_000"},
      reconcile_timeout_ms: {60_000, "60_000"},
      resubscribe_failure_limit: {12, "12"},
      stale_delivery_ms: {300_000, "300_000"},
      rejected_symbol_ttl_ms: {86_400_000, "86_400_000"},
      open_retry_base_ms: {1_000, "1_000"},
      open_retry_max_ms: {60_000, "60_000"},
      shard_spacing_ms: {5_000, "5_000"},
      idle_shard_ms: {600_000, "600_000"}
    }

    test "state and moduledoc agree, key by key" do
      state = :sys.get_state(start_feed())
      lines = String.split(moduledoc(), "\n")

      for {key, {value, shown}} <- @defaults do
        assert Map.fetch!(state, key) == value

        assert Enum.any?(lines, fn line ->
                 String.contains?(line, "`:#{key}`") and String.contains?(line, shown)
               end),
               "the moduledoc does not state #{key} as #{shown}"
      end
    end

    test "the two socket budgets default to what the moduledoc says" do
      options = Socket.connection_opts([])

      assert options[:socket_connect_timeout] == 3_000
      assert options[:socket_recv_timeout] == 2_000
      assert moduledoc() =~ ~r/\(3_000 and\s+2_000 ms\)/
    end

    test "every start key the feed reads is named in the moduledoc and accepted at start" do
      feed_keys =
        ~w(name credentials environment limiter plug rate_limit_blocking max_queue_len ledger
           priority_symbols resubscribe_interval_ms connack_timeout_ms reconcile_timeout_ms
           resubscribe_failure_limit stale_delivery_ms rejected_symbol_ttl_ms open_retry_base_ms
           open_retry_max_ms shard_spacing_ms idle_shard_ms socket_connect_timeout
           socket_recv_timeout url ssl_options shards shard_capacity)a

      assert length(feed_keys) == 25

      for key <- feed_keys do
        assert moduledoc() =~ "`:#{key}`", "the moduledoc does not name :#{key}"
        assert Options.check_start([{key, nil}]) == :ok
      end
    end
  end

  describe "every function that is public has a doc" do
    test "start_link, the three writes, the reads and both checks" do
      for {name, arity} <- [
            start_link: 1,
            subscribe: 3,
            unsubscribe: 3,
            update_symbols: 3,
            coverage: 1,
            wanted: 1,
            coverage_by_kind: 1,
            subscribe_notices: 2,
            check_subscriber: 1,
            check_symbols: 1
          ] do
        assert %{"en" => text} = function_doc(name, arity)
        assert String.length(text) > 40
      end
    end
  end

  describe "the errors the moduledoc lists are the ones the feed returns" do
    test "a malformed list is refused whole, before any state moves" do
      feed = start_feed(shards: %{})

      for bad <- [nil, "BTC-USD", [""], ["  "], [:btc], ["BTC-USD" | "ETH-USD"]] do
        assert Feed.subscribe(feed, bad, to: self()) == {:error, {:invalid_symbols, bad}}
        assert Feed.unsubscribe(feed, bad, []) == {:error, {:invalid_symbols, bad}}
        assert Feed.update_symbols(feed, bad, []) == {:error, {:invalid_symbols, bad}}
      end

      assert Feed.wanted(feed) == []
    end

    test "a subscriber that is not a pid or a registered name is refused" do
      feed = start_feed(shards: %{})

      for bad <- ["worker", {:global, :worker}, true, false] do
        assert Feed.subscribe(feed, ["BTC-USD"], to: bad) == {:error, {:invalid_subscriber, bad}}
        assert Feed.subscribe_notices(feed, to: bad) == {:error, {:invalid_subscriber, bad}}
      end

      assert Feed.wanted(feed) == []
    end

    test "UAT has no broker, and the refusal names the environment" do
      feed = start_feed(shards: %{})

      assert Feed.subscribe(feed, ["BTC-USD"], environment: :uat) ==
               {:error, {:streaming_unavailable, :uat}}

      assert Feed.wanted(feed) == []
    end

    test "a shard that has to open with no usable App Key is refused, and nothing is kept" do
      feed = start_feed(shards: %{})

      for credentials <- [nil, %{}, %{app_key: ""}, %{app_key: "  "}] do
        opts = [environment: :production, credentials: credentials]

        assert Feed.subscribe(feed, ["BTC-USD"], opts) ==
                 {:error, {:missing_required_field, :app_key}}
      end

      assert Feed.wanted(feed) == []
      assert :sys.get_state(feed).shards == %{}
    end

    test "symbols that fit no shard are capacity_exceeded and are not kept as wanted" do
      full = Map.new(0..4, &{&1, 0})
      feed = start_feed(shards: %{}, shard_capacity: full)

      assert Feed.subscribe(feed, ["BTC-USD", "ETH-USD"], environment: :production) ==
               {:error, {:capacity_exceeded, ["BTC-USD", "ETH-USD"]}}

      assert Feed.wanted(feed) == []
    end

    test "a call message the feed does not know is :unknown_call" do
      feed = start_feed()

      assert GenServer.call(feed, :nothing_sends_this) == {:error, :unknown_call}
    end

    test "the moduledoc names every reason and notice reason the code can produce" do
      text = moduledoc()

      for term <- ~w(:invalid_symbols :invalid_subscriber :streaming_unavailable
                     :missing_required_field :connection_refused :shard_crashed :invalid_session
                     :connack_timeout :reconcile_pending :reconcile_timeout :reconcile_task_down
                     :oversubscribed :capacity_exceeded :partial_failure :unknown_call
                     :no_venue_response :feed_restarted :open_failed :resubscribe_failed
                     :socket_crashed :refusal :coverage_change :data_quality) do
        assert text =~ term, "the moduledoc does not name #{term}"
      end
    end
  end

  describe "a refused subscribe changes no state, its subscriber included" do
    test "the pid it named is not registered, monitored or left with a timer" do
      feed = start_feed(shards: %{})

      assert {:error, {:missing_required_field, :app_key}} =
               Feed.subscribe(feed, ["BTC-USD"], environment: :production, to: self())

      state = :sys.get_state(feed)

      assert state.subscribers == MapSet.new()
      assert state.monitors == %{}
      assert state.wanted == MapSet.new()
      assert state.caller_timers == %{}
      assert state.call_undo == %{}
      assert state.connack_timers == %{}
    end

    test "a registered name it named is not registered either" do
      feed = start_feed(shards: %{})
      name = :"tick_ar_#{System.unique_integer([:positive])}"
      Process.register(self(), name)

      assert {:error, {:missing_required_field, :app_key}} =
               Feed.subscribe(feed, ["BTC-USD"], environment: :production, to: name)

      assert :sys.get_state(feed).subscribers == MapSet.new()
    end

    test "a subscriber already registered by an earlier call stays registered" do
      feed = start_feed(shards: %{})
      earlier = spawn(fn -> Process.sleep(:infinity) end)

      :sys.replace_state(feed, fn state ->
        %{state | subscribers: MapSet.put(state.subscribers, earlier)}
      end)

      assert {:error, {:missing_required_field, :app_key}} =
               Feed.subscribe(feed, ["BTC-USD"], environment: :production, to: earlier)

      assert MapSet.member?(:sys.get_state(feed).subscribers, earlier)
    end

    test "a subscriber none of whose symbols fit anywhere is not registered" do
      feed = start_feed(shards: %{}, shard_capacity: Map.new(0..4, &{&1, 0}))

      assert {:error, {:capacity_exceeded, ["BTC-USD"]}} =
               Feed.subscribe(feed, ["BTC-USD"], environment: :production, to: self())

      assert :sys.get_state(feed).subscribers == MapSet.new()
    end

    test "a later caller's payloads do not reach the pid whose own subscribe was refused" do
      feed = start_feed(shards: %{})

      assert {:error, {:missing_required_field, :app_key}} =
               Feed.subscribe(feed, ["BTC-USD"], environment: :production, to: self())

      other = spawn(fn -> Process.sleep(:infinity) end)

      :sys.replace_state(feed, fn state ->
        %{
          state
          | wanted: MapSet.put(state.wanted, "ETH-USD"),
            subscribers: MapSet.put(state.subscribers, other)
        }
      end)

      send(feed, {:dp_exchange, :webull, quote_for("ETH-USD")})
      assert %{"ETH-USD" => :stream} = Feed.coverage(feed)

      refute_receive {:dp_exchange, :webull, _payload}, 500
    end
  end

  describe "overlapping subscribes for one pid register it once, undo only their own" do
    setup do
      subscriber = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(subscriber, :kill) end)
      {:ok, subscriber: subscriber}
    end

    defp sizes(feed) do
      state = :sys.get_state(feed)
      {MapSet.size(state.subscribers), map_size(state.monitors)}
    end

    test "both refused: the pid is not registered and its monitor is gone",
         %{limiter: limiter, subscriber: subscriber} do
      {feed, _session_id} = start_connecting_feed()
      assert sizes(feed) == {0, 0}

      first = park_subscribe(feed, "BTC-USD", subscriber, limiter)
      second = park_subscribe(feed, "ETH-USD", subscriber, limiter)

      during = :sys.get_state(feed)
      assert MapSet.member?(during.subscribers, subscriber)
      assert map_size(during.call_undo) == 2
      assert monitors_by(feed, subscriber) == 1

      refuse(feed, first)

      assert MapSet.member?(:sys.get_state(feed).subscribers, subscriber),
             "the second call is still pending and has not been refused"

      refuse(feed, second)

      state = :sys.get_state(feed)
      refute MapSet.member?(state.subscribers, subscriber)
      refute Map.has_key?(state.monitors, subscriber)
      assert monitors_by(feed, subscriber) == 0
      assert state.call_undo == %{}
      assert sizes(feed) == {0, 0}
    end

    test "both refused in the other order leaves the same nothing",
         %{limiter: limiter, subscriber: subscriber} do
      {feed, _session_id} = start_connecting_feed()

      first = park_subscribe(feed, "BTC-USD", subscriber, limiter)
      second = park_subscribe(feed, "ETH-USD", subscriber, limiter)

      refuse(feed, second)
      assert MapSet.member?(:sys.get_state(feed).subscribers, subscriber)
      refuse(feed, first)

      refute MapSet.member?(:sys.get_state(feed).subscribers, subscriber)
      assert monitors_by(feed, subscriber) == 0
      assert sizes(feed) == {0, 0}
    end

    test "one refused, the later one accepted: registered exactly once, one monitor",
         %{limiter: limiter, subscriber: subscriber} do
      {feed, session_id} = start_connecting_feed()

      refused = park_subscribe(feed, "BTC-USD", subscriber, limiter)
      accepted = park_subscribe(feed, "ETH-USD", subscriber, limiter)

      refuse(feed, refused)
      send(feed, {:dp_exchange, :webull, link_up(session_id)})
      assert Task.await(accepted, 10_000) == :ok

      state = :sys.get_state(feed)
      assert MapSet.to_list(state.subscribers) == [subscriber]
      assert Map.keys(state.monitors) == [subscriber]
      assert monitors_by(feed, subscriber) == 1
      assert state.call_undo == %{}
      assert sizes(feed) == {1, 1}
    end

    test "one accepted first, the other refused after: the accepted call's registration stays",
         %{limiter: limiter, subscriber: subscriber} do
      {feed, session_id} = start_connecting_feed()

      accepted = park_subscribe(feed, "ETH-USD", subscriber, limiter)
      refused = park_subscribe(feed, "BTC-USD", subscriber, limiter)
      refused_from = call_of(feed, refused)

      # A connecting shard answers every caller parked on it together, so the call that is to
      # be refused AFTER the other is accepted is moved to a second connecting shard whose
      # link never comes up: `link_up` for the first then accepts only the other call.
      :sys.replace_state(feed, fn state ->
        waiters = state.shards[0].reply_to
        {mine, others} = Enum.split_with(waiters, &(elem(&1, 0) == refused_from))
        other_shard = %{connected_shard("s-ar-other") | connected?: false, reply_to: mine}
        shards = Map.put(state.shards, 1, other_shard)
        %{state | shards: put_in(shards[0].reply_to, others)}
      end)

      send(feed, {:dp_exchange, :webull, link_up(session_id)})
      assert Task.await(accepted, 10_000) == :ok

      assert MapSet.member?(:sys.get_state(feed).subscribers, subscriber)

      refuse(feed, refused)

      state = :sys.get_state(feed)
      assert MapSet.to_list(state.subscribers) == [subscriber]
      assert Map.keys(state.monitors) == [subscriber]
      assert monitors_by(feed, subscriber) == 1
      assert state.call_undo == %{}
    end

    test "a pid registered before both calls survives both refusals, monitor included",
         %{limiter: limiter, subscriber: subscriber} do
      {feed, _session_id} = start_connecting_feed()

      :sys.replace_state(feed, fn state ->
        %{
          state
          | subscribers: MapSet.put(state.subscribers, subscriber),
            monitors: Fanout.watch(subscriber, state.monitors)
        }
      end)

      assert sizes(feed) == {1, 1}

      first = park_subscribe(feed, "BTC-USD", subscriber, limiter)
      second = park_subscribe(feed, "ETH-USD", subscriber, limiter)
      refuse(feed, first)
      refuse(feed, second)

      state = :sys.get_state(feed)
      assert MapSet.member?(state.subscribers, subscriber)
      assert monitors_by(feed, subscriber) == 1
      assert sizes(feed) == {1, 1}
    end
  end

  describe "overlapping calls naming one symbol undo only what neither still holds" do
    setup do
      first_pid = spawn(fn -> Process.sleep(:infinity) end)
      second_pid = spawn(fn -> Process.sleep(:infinity) end)

      on_exit(fn ->
        Process.exit(first_pid, :kill)
        Process.exit(second_pid, :kill)
      end)

      {:ok, first_pid: first_pid, second_pid: second_pid}
    end

    # Moves the call that is to be refused onto a second connecting shard whose link never comes
    # up, so `link_up` for the first shard accepts only `accepted` and leaves `refused` pending.
    defp accept_only(feed, session_id, accepted, refused) do
      refused_from = call_of(feed, refused)

      :sys.replace_state(feed, fn state ->
        waiters = state.shards[0].reply_to
        {mine, others} = Enum.split_with(waiters, &(elem(&1, 0) == refused_from))
        other_shard = %{connected_shard("s-ar-other") | connected?: false, reply_to: mine}
        shards = Map.put(state.shards, 1, other_shard)
        %{state | shards: put_in(shards[0].reply_to, others)}
      end)

      send(feed, {:dp_exchange, :webull, link_up(session_id)})
      assert Task.await(accepted, 10_000) == :ok
    end

    defp wanted_of(feed), do: :sys.get_state(feed).wanted

    test "one refused first, the other accepted later: the symbol is still wanted",
         %{limiter: limiter, first_pid: first_pid, second_pid: second_pid} do
      {feed, session_id} = start_connecting_feed()

      refused = park_subscribe(feed, ["BTC-USD"], first_pid, limiter)
      accepted = park_subscribe(feed, ["BTC-USD", "ETH-USD"], second_pid, limiter)

      refuse(feed, refused)

      assert MapSet.member?(wanted_of(feed), "BTC-USD"),
             "the second call is still pending and names the symbol"

      # The refused call carried the credentials first; the accepted one still needs them.
      send(feed, {:dp_exchange, :webull, link_up(session_id)})
      assert Task.await(accepted, 10_000) == :ok

      state = :sys.get_state(feed)
      assert Enum.sort(MapSet.to_list(state.wanted)) == ["BTC-USD", "ETH-USD"]
      assert state.call_undo == %{}
    end

    test "one accepted first, the other refused after: the accepted symbol stays wanted",
         %{limiter: limiter, first_pid: first_pid, second_pid: second_pid} do
      {feed, session_id} = start_connecting_feed()

      accepted = park_subscribe(feed, ["BTC-USD"], first_pid, limiter)
      refused = park_subscribe(feed, ["BTC-USD", "ETH-USD"], second_pid, limiter)

      accept_only(feed, session_id, accepted, refused)
      assert MapSet.member?(wanted_of(feed), "BTC-USD")

      refuse(feed, refused)

      # Only what the refused call added alone (ETH) goes; BTC was made real by the accepted one.
      state = :sys.get_state(feed)
      assert MapSet.to_list(state.wanted) == ["BTC-USD"]
      assert state.call_undo == %{}
    end

    test "the earlier call refused after the later one is accepted: still wanted",
         %{limiter: limiter, first_pid: first_pid, second_pid: second_pid} do
      {feed, session_id} = start_connecting_feed()

      refused = park_subscribe(feed, ["BTC-USD"], first_pid, limiter)
      accepted = park_subscribe(feed, ["BTC-USD", "ETH-USD"], second_pid, limiter)

      accept_only(feed, session_id, accepted, refused)
      refuse(feed, refused)

      assert Enum.sort(MapSet.to_list(wanted_of(feed))) == ["BTC-USD", "ETH-USD"]
      assert :sys.get_state(feed).call_undo == %{}
    end

    test "both refused, either order: not wanted, and the wanted set is back to its start",
         %{limiter: limiter, first_pid: first_pid, second_pid: second_pid} do
      {feed, _session_id} = start_connecting_feed()
      start_size = MapSet.size(wanted_of(feed))

      first = park_subscribe(feed, ["BTC-USD"], first_pid, limiter)
      second = park_subscribe(feed, ["BTC-USD", "XRP-USD"], second_pid, limiter)
      assert MapSet.member?(wanted_of(feed), "BTC-USD")

      refuse(feed, first)

      assert MapSet.member?(wanted_of(feed), "BTC-USD"),
             "the second call is still pending and names the symbol"

      refuse(feed, second)

      assert MapSet.size(wanted_of(feed)) == start_size
      refute MapSet.member?(wanted_of(feed), "BTC-USD")
      refute MapSet.member?(wanted_of(feed), "XRP-USD")

      third = park_subscribe(feed, ["ETH-USD"], first_pid, limiter)
      fourth = park_subscribe(feed, ["ETH-USD", "SOL-USD"], second_pid, limiter)
      refuse(feed, fourth)
      assert MapSet.to_list(wanted_of(feed)) == ["ETH-USD"]
      refuse(feed, third)

      assert MapSet.size(wanted_of(feed)) == start_size
      assert :sys.get_state(feed).call_undo == %{}
    end

    test "a symbol wanted before both calls stays wanted after both are refused",
         %{limiter: limiter, first_pid: first_pid, second_pid: second_pid} do
      {feed, _session_id} = start_connecting_feed()

      :sys.replace_state(feed, fn state ->
        %{state | wanted: MapSet.put(state.wanted, "BTC-USD")}
      end)

      # Neither call changes BTC (wanted already), so each claims only what it adds itself.
      first = park_subscribe(feed, ["BTC-USD"], first_pid, limiter)
      second = park_subscribe(feed, ["BTC-USD", "ETH-USD"], second_pid, limiter)
      refuse(feed, first)
      refuse(feed, second)

      assert MapSet.to_list(wanted_of(feed)) == ["BTC-USD"]
    end

    test "the ledger is rewritten on the refusal that takes a pid and a symbol back",
         %{limiter: limiter, first_pid: first_pid, second_pid: second_pid} do
      ledger = :"ar_ledger_#{System.unique_integer([:positive])}"
      start_supervised!({Ledger, name: ledger})
      {feed, session_id} = start_connecting_feed(ledger: ledger)

      refused = park_subscribe(feed, "BTC-USD", first_pid, limiter)
      accepted = park_subscribe(feed, "ETH-USD", second_pid, limiter)

      accept_only(feed, session_id, accepted, refused)

      # The accepted call's reply persisted the pid and the symbol of the call still pending.
      assert {:ok, written} = Ledger.fetch(ledger)
      assert written.wanted == ["BTC-USD", "ETH-USD"]
      assert Enum.sort(written.subscribers) == Enum.sort([first_pid, second_pid])

      refuse(feed, refused)

      state = :sys.get_state(feed)
      assert MapSet.to_list(state.wanted) == ["ETH-USD"]
      assert MapSet.to_list(state.subscribers) == [second_pid]

      assert {:ok, rewritten} = Ledger.fetch(ledger)
      assert rewritten.wanted == ["ETH-USD"]
      assert rewritten.subscribers == [second_pid]
      assert rewritten.notice_subscribers == []
    end
  end

  describe "a pending subscribe and a pending unsubscribe of one symbol undo in order" do
    setup do
      pid = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(pid, :kill) end)
      {:ok, pid: pid}
    end

    # An unsubscribe whose symbol is on the connecting shard changes that shard, so it PARKS
    # on it like a subscribe does and the test decides how it ends (no seeding needed for it).
    # Like a subscribe it parks only when it changes the shard's list, so two unsubscribes that
    # overlap on one symbol each name one more symbol of their own.
    defp park_unsubscribe(feed, symbols, limiter) do
      pending = map_size(:sys.get_state(feed).call_undo)

      task =
        Task.async(fn -> Feed.unsubscribe(feed, List.wrap(symbols), subscribe_opts(limiter)) end)

      wait_until(fn -> map_size(:sys.get_state(feed).call_undo) > pending end)
      task
    end

    # The symbol was wanted, and carried by the connecting shard, before any call was made:
    # seeded with `:sys.replace_state/2` (the only seeding these tests use).
    defp seed_wanted(feed, symbols) do
      symbols = List.wrap(symbols)

      :sys.replace_state(feed, fn state ->
        state = %{state | wanted: MapSet.union(state.wanted, MapSet.new(symbols))}
        put_in(state.shards[0].symbols, symbols)
      end)
    end

    test "subscribe then unsubscribe, both refused, earlier first: never wanted",
         %{limiter: limiter, pid: pid} do
      {feed, _session_id} = start_connecting_feed()
      start = wanted_of(feed)

      subscribed = park_subscribe(feed, "BTC-USD", pid, limiter)
      unsubscribed = park_unsubscribe(feed, "BTC-USD", limiter)
      assert MapSet.size(wanted_of(feed)) == 0

      refuse(feed, subscribed)
      refute MapSet.member?(wanted_of(feed), "BTC-USD")
      refuse(feed, unsubscribed)

      assert wanted_of(feed) == start
      assert :sys.get_state(feed).call_undo == %{}
      refute_receive {:dp_exchange, :webull, _payload}, 500
    end

    test "subscribe then unsubscribe, both refused, later first: never wanted",
         %{limiter: limiter, pid: pid} do
      {feed, _session_id} = start_connecting_feed()
      start = wanted_of(feed)

      subscribed = park_subscribe(feed, "BTC-USD", pid, limiter)
      unsubscribed = park_unsubscribe(feed, "BTC-USD", limiter)

      refuse(feed, unsubscribed)

      assert MapSet.member?(wanted_of(feed), "BTC-USD"),
             "the subscribe is still pending: the refused unsubscribe puts back what it found"

      refuse(feed, subscribed)

      assert wanted_of(feed) == start
      assert :sys.get_state(feed).call_undo == %{}
    end

    test "unsubscribe then subscribe of a wanted symbol, both refused either order: still wanted",
         %{limiter: limiter, pid: pid} do
      {feed, _session_id} = start_connecting_feed()
      seed_wanted(feed, "BTC-USD")

      unsubscribed = park_unsubscribe(feed, "BTC-USD", limiter)
      subscribed = park_subscribe(feed, "BTC-USD", pid, limiter)
      refuse(feed, unsubscribed)
      refuse(feed, subscribed)

      assert MapSet.to_list(wanted_of(feed)) == ["BTC-USD"]
      assert :sys.get_state(feed).call_undo == %{}

      unsubscribed = park_unsubscribe(feed, "BTC-USD", limiter)
      subscribed = park_subscribe(feed, "BTC-USD", pid, limiter)
      refuse(feed, subscribed)
      refuse(feed, unsubscribed)

      assert MapSet.to_list(wanted_of(feed)) == ["BTC-USD"]
      assert :sys.get_state(feed).call_undo == %{}
    end

    test "a refused unsubscribe of an already wanted symbol puts it back", %{limiter: limiter} do
      {feed, _session_id} = start_connecting_feed()
      seed_wanted(feed, "BTC-USD")

      unsubscribed = park_unsubscribe(feed, "BTC-USD", limiter)
      refute MapSet.member?(wanted_of(feed), "BTC-USD")

      refuse(feed, unsubscribed)

      assert MapSet.to_list(wanted_of(feed)) == ["BTC-USD"]
      assert :sys.get_state(feed).call_undo == %{}
    end

    test "two pending unsubscribes of one symbol: the symbol returns only when both are refused",
         %{limiter: limiter} do
      {feed, _session_id} = start_connecting_feed()
      seed_wanted(feed, ["BTC-USD", "ETH-USD"])

      first = park_unsubscribe(feed, ["BTC-USD"], limiter)
      second = park_unsubscribe(feed, ["BTC-USD", "ETH-USD"], limiter)

      refuse(feed, first)

      refute MapSet.member?(wanted_of(feed), "BTC-USD"),
             "the second unsubscribe is still pending and takes the symbol out"

      refuse(feed, second)

      assert Enum.sort(MapSet.to_list(wanted_of(feed))) == ["BTC-USD", "ETH-USD"]
      assert :sys.get_state(feed).call_undo == %{}
    end

    test "subscribe accepted, unsubscribe refused after: the symbol is wanted",
         %{limiter: limiter, pid: pid} do
      {feed, session_id} = start_connecting_feed()

      subscribed = park_subscribe(feed, "BTC-USD", pid, limiter)
      unsubscribed = park_unsubscribe(feed, "BTC-USD", limiter)

      accept_only(feed, session_id, subscribed, unsubscribed)
      refuse(feed, unsubscribed)

      assert MapSet.to_list(wanted_of(feed)) == ["BTC-USD"]
      assert :sys.get_state(feed).call_undo == %{}
    end

    test "unsubscribe accepted, subscribe refused after: the symbol is not wanted",
         %{limiter: limiter, pid: pid} do
      {feed, session_id} = start_connecting_feed()

      subscribed = park_subscribe(feed, "BTC-USD", pid, limiter)
      unsubscribed = park_unsubscribe(feed, "BTC-USD", limiter)

      accept_only(feed, session_id, unsubscribed, subscribed)
      refuse(feed, subscribed)

      assert MapSet.size(wanted_of(feed)) == 0
      assert :sys.get_state(feed).call_undo == %{}
    end

    test "unsubscribe of a wanted symbol accepted, a later subscribe refused: not wanted",
         %{limiter: limiter, pid: pid} do
      {feed, session_id} = start_connecting_feed()
      seed_wanted(feed, "BTC-USD")

      unsubscribed = park_unsubscribe(feed, "BTC-USD", limiter)
      subscribed = park_subscribe(feed, "BTC-USD", pid, limiter)

      accept_only(feed, session_id, unsubscribed, subscribed)
      refuse(feed, subscribed)

      assert MapSet.size(wanted_of(feed)) == 0
      assert :sys.get_state(feed).call_undo == %{}
    end
  end
end
