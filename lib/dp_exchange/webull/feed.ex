defmodule DpExchange.Webull.Feed do
  @moduledoc """
  This venue's subscription lifecycle — internal, and the place where its two transports
  are joined.

  ## Subscribing here is two operations on two protocols

  Market data arrives over **MQTT**; subscriptions are **HTTP** calls. Each MQTT session
  is joined to its own HTTP subscriptions by one value: the `session_id` a shard
  generates, registers as its MQTT client id, and then names in every HTTP subscribe for
  that shard.

  A consumer calls `subscribe/3` with symbols. It never learns that a socket was dialled,
  how many, that an HTTP call followed, or that transport and subscription had to agree on
  an identifier — which is the facade doing precisely what D12 asks of it, on the venue
  where it costs the most to deliver.

  ## Re-subscribing after a reconnect is this package's job

  > If the connection is dropped due to network issues, previous subscriptions are **not**
  > automatically restored. You must re-subscribe after reconnecting.

  So a reconnect is followed by a replay of everything wanted **on that shard**. A
  consumer that had to notice reconnects and replay its own subscriptions would be doing
  the venue's bookkeeping through an interface designed to hide reconnects entirely.

  ## Coverage is observed, never intended

  A symbol enters the coverage map when **a payload for it arrives** — not when it is
  subscribed, and not when the HTTP subscribe returns 200. On this venue those are three
  genuinely different moments, and only the last one means data.

  ## Sharded — one session tops out at 100 symbols, this package's scope does not

  A single MQTT session caps out at the venue's own stated ceiling —
  `"Maximum number of subscribe tickers:100"`, confirmed against a real collection run
  that hit it (`dp-exchange-core` issue #13). A consumer with more than 100 symbols on
  this venue could not reach full coverage through one session no matter how the HTTP
  calls were split, because the limit is per-session, not per-request.

  This is not new ground for the family — `DpExchange.Coinbase.Feed` shards for the
  identical reason, and its shape (recompute from the full wanted set, touch only what
  changed, one shard synchronous per call and the rest staggered) is the template this
  adapts. What differs is the leaf operation: Coinbase subscribes channels on an
  always-usable socket; this venue's shard identity is *also* its MQTT session, so a
  brand-new shard has to wait for its own CONNACK (see below) before its first HTTP
  subscribe means anything to the venue.

  `@pairs_per_socket` is exactly the venue's own stated **100** — not a guessed margin
  below it. See `docs/design/2026-09-04_webull-sharding-and-fake-injection.md` §3.1 for
  why padding a number the venue already stated would be exactly the unlabeled guess this
  family's own conventions rule out.

  **Five connections per App Key is the hard ceiling this can never exceed** — a consumer
  cannot cause a sixth socket, because a consumer cannot ask for sockets at all. Five
  shards of 100 is 500 symbols; a universe larger than that on this venue needs a second
  App Key, not a bigger number here.

  ## A shard that rejects a batch is this package's problem to solve, not the host's

  If a shard's HTTP subscribe comes back `TOO_MANY_SYMBOLS_SUBSCRIPTION` despite this
  package's own accounting — a bug, a race, or the venue's real ceiling turning out lower
  in practice than its own stated one — the affected symbols are moved to another shard
  with room (opening one if needed, within the five-connection ceiling) and retried
  internally. The host is never handed a `session_id` or a shard index to reason about;
  it only ever sees whether its symbols ended up covered. Only running out of shards
  entirely — five sessions full and the venue still refuses — is a genuine capacity
  ceiling this package cannot paper over, and that surfaces as a real refusal.

  ## A socket process is not a connected socket

  `Socket.start_link/1` returns once the WebSocket is up; MQTT is not authenticated until
  the venue answers the CONNECT with a CONNACK, which arrives later as a `:link_up`
  notice carrying the shard's `session_id`. The first subscribe against a fresh shard
  does not call the HTTP endpoint itself — it waits for that notice, exactly as a
  reconnect already did, so the session id it names is one the venue has actually
  registered.

  ## A subscribed, connected session can still go quiet on its own

  Not a reconnect, not an error, not an unsubscribe — the venue simply stops pushing to
  an otherwise-healthy session shortly after each subscribe, with nothing on the wire to
  say so. `dp_crypto_management`'s own pre-existing MQTT client found this the hard way,
  empirically: a blind, unconditional resubscribe on a timer, independent of whether the
  wanted set had changed, took its live coverage from 47 symbols back to ~240
  (DpCryptoManagement's issue #17). `reshard/4` alone cannot recover from this — it only
  touches a shard whose *wanted* symbol set changed, and re-asking for exactly what is
  already wanted computes an empty diff and asserts nothing.

  So every connected shard's current subscription is re-issued unconditionally every
  `@resubscribe_interval_ms`, regardless of whether anything is believed to have
  changed — the same shape Coinbase's `Feed` already carries for its own reconnect case,
  applied here to a steady-state failure mode Coinbase does not have.

  ## A shard's socket crash is contained to that shard

  `Socket.start_link/1` links to `Feed` — ordinary `WebSockex.start_link/4` behaviour — so
  an uncaught exception inside a socket's own callbacks, or any other abnormal exit,
  propagates as a linked EXIT. `Feed` traps exits for exactly this reason: without it, one
  shard's crash killed every shard's connection and every symbol's coverage, not just the
  one that failed — the opposite of the isolation `reshard/4`, `resync/1` and the
  resubscribe timer above all work to provide. A crashed shard's socket is reopened at the
  same index with the same wanted symbols; the venue issues a fresh session, and the
  ordinary CONNACK-then-resubscribe path brings it back exactly as a first open would. A
  caller with a reply pending on the crashed shard is answered `{:error, {:shard_crashed,
  reason}}` rather than left to time out.

  ## Control-plane HTTP never runs on the mailbox that also carries ticks

  Every `Subscription.subscribe/unsubscribe` call this module makes — reconciling a
  shard's diff, replaying a reconnect, or the unconditional 60s resubscribe above — runs in
  its own short-lived, supervised task rather than inline inside a `handle_call` or
  `handle_info`. A caller's `subscribe/3` still does not get its reply until the real HTTP
  round trip finishes (the same observable contract as before, kept via a deferred
  `GenServer.reply/2`), but the Feed process itself stays free to keep draining incoming
  ticks — from this shard and every other one — while that round trip is in flight. Before
  this, a single blind resubscribe tick chained up to five sequential ~118ms HTTP calls
  inside one message, stalling delivery for every shard, every 60 seconds, by design.

  ## Shard assignment is sticky, not recomputed from scratch

  A symbol already assigned to a shard keeps that shard for as long as it stays wanted,
  even as other symbols are added or removed. Deriving shards by sorting the *entire*
  wanted set and cutting it into fixed-size chunks — the original approach — meant one
  newly-added symbol that happened to sort early could shift every symbol after it across
  every shard boundary, so an unrelated add unsubscribed and resubscribed symbols that were
  already healthy. `derive_shards/3` instead starts from what each shard already carries,
  drops only what stopped being wanted or no longer fits that shard's measured capacity,
  and places everything else — new symbols, and anything just evicted by a capacity
  reduction — into whichever shard (in index order) still has room. `reshard/4`'s
  `touched` computation is what actually limits HTTP calls to changed shards; this is what
  makes that set small in the first place.
  """

  use GenServer

  alias DpExchange.Core.Notice
  alias DpExchange.Webull.{Environment, Socket, Subscription}

  require Logger

  @frame_window_ms 5_000
  @call_timeout @frame_window_ms * 3

  # The venue's own stated ceiling. See the moduledoc and the design doc §3.1 — not a
  # padded-down guess.
  @pairs_per_socket 100

  # "Each App Key supports a maximum of 5 concurrent connections" —
  # docs/reference/webull/streaming-api.md.
  @max_shards 5

  # Between opening each shard's socket, when one call touches more than one newly-
  # opening shard. A connect burst is answered with resets — same reasoning as
  # Coinbase's Feed, not a Webull-specific measurement.
  @shard_spacing_ms 5_000

  # Re-issue every connected shard's current subscriptions on this cadence,
  # unconditionally — see the moduledoc. Same interval, same reasoning as Coinbase's
  # Feed for the reconnect case; here it is load-bearing for a case Coinbase does not
  # have — see DpCryptoManagement's issue #17.
  @resubscribe_interval_ms 60_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec subscribe(GenServer.server(), [String.t()], keyword()) :: :ok | {:error, term()}
  def subscribe(feed, symbols, opts) do
    GenServer.call(
      feed,
      {:subscribe, symbols, Keyword.get(opts, :to, self()), opts},
      @call_timeout
    )
  end

  @spec unsubscribe(GenServer.server(), [String.t()], keyword()) :: :ok | {:error, term()}
  def unsubscribe(feed, symbols, opts),
    do: GenServer.call(feed, {:unsubscribe, symbols, opts}, @call_timeout)

  @spec update_symbols(GenServer.server(), [String.t()], keyword()) :: :ok | {:error, term()}
  def update_symbols(feed, symbols, opts),
    do: GenServer.call(feed, {:update_symbols, symbols, opts}, @call_timeout)

  @spec coverage(GenServer.server()) :: %{String.t() => :stream | :internal_poll | :not_covered}
  def coverage(feed), do: GenServer.call(feed, :coverage)

  @spec subscribe_notices(GenServer.server(), keyword()) :: :ok
  def subscribe_notices(feed, opts),
    do: GenServer.call(feed, {:subscribe_notices, Keyword.get(opts, :to, self())})

  # --- server -------------------------------------------------------------

  @impl true
  def init(opts) do
    # Every shard's socket links here (WebSockex's ordinary behaviour), and every
    # control-plane HTTP call now runs in a task this owns — trapping exits is what keeps
    # either kind of crash from taking the whole Feed (and every other shard) down with it.
    # See the moduledoc's "A shard's socket crash is contained to that shard".
    Process.flag(:trap_exit, true)
    {:ok, task_supervisor} = Task.Supervisor.start_link()

    Process.send_after(self(), :resubscribe, @resubscribe_interval_ms)

    {:ok,
     %{
       task_supervisor: task_supervisor,
       socket_opts: Keyword.take(opts, [:url, :environment]),
       # Retained so a reconnect (or a rebalance) can replay a shard's subscription. The
       # venue restores nothing, and a replay needs credentials — so a consumer that
       # wants automatic recovery hands them to the tree at start, exactly as the other
       # venues in this family do. Per-call options still override these for calls made
       # directly against a caller's own request.
       resubscribe_opts: Keyword.take(opts, [:credentials, :environment, :limiter, :plug]),
       subscribers: MapSet.new(),
       notice_subscribers: MapSet.new(),
       wanted: MapSet.new(),
       delivering: %{},
       # index => %{session_id:, socket:, connected?:, symbols:, reply_to:}. `symbols` is
       # what this shard is meant to carry as of the last reshard, independent of whether
       # the HTTP call that asks the venue for it has actually gone out yet. `reply_to`
       # is set only while this shard is the primary of a call still waiting on this
       # shard's own CONNACK — see handle_call({:subscribe, ...}) and on_link_up/2.
       #
       # An init option, not just internal state, for the same reason Coinbase's Feed
       # accepts an `injected_socket` — a test standing up an already-connected shard
       # needs to say so without driving a real MQTT handshake to get there.
       shards: Keyword.get(opts, :shards, %{}),
       # index => capacity, present only once a shard has been measured (by the venue's
       # own refusal) to hold fewer than @pairs_per_socket. Absent means the venue's
       # stated ceiling applies unmodified. See handle_subscribe_result/3. Also an init
       # option, so a test can exercise rebalancing without needing @pairs_per_socket
       # real symbols to do it.
       shard_capacity: Keyword.get(opts, :shard_capacity, %{})
     }}
  end

  @impl true
  def handle_call({:subscribe, symbols, subscriber, opts}, from, state) do
    if Environment.streaming?(environment(state, opts)) do
      wanted = MapSet.union(state.wanted, MapSet.new(symbols))

      state = %{
        state
        | subscribers: MapSet.put(state.subscribers, subscriber),
          wanted: wanted,
          resubscribe_opts: replayable(opts, state)
      }

      reshard(state, opts, from)
    else
      # UAT has REST but no broker — `mqtt-uat.webullbroker.com` is NXDOMAIN. Falling back
      # to the production stream would hand a consumer real market data while it believed
      # it was testing.
      {:reply, {:error, {:streaming_unavailable, environment(state, opts)}}, state}
    end
  end

  def handle_call({:unsubscribe, symbols, opts}, from, state) do
    wanted = MapSet.difference(state.wanted, MapSet.new(symbols))
    state = %{state | wanted: wanted, delivering: Map.drop(state.delivering, symbols)}
    reshard(state, opts, from)
  end

  def handle_call({:update_symbols, symbols, opts}, from, state) do
    wanted = MapSet.new(symbols)

    state = %{
      state
      | wanted: wanted,
        delivering: Map.take(state.delivering, symbols),
        resubscribe_opts: replayable(opts, state)
    }

    reshard(state, opts, from)
  end

  def handle_call(:coverage, _from, state) do
    {:reply, Map.new(state.delivering, fn {symbol, _at} -> {symbol, :stream} end), state}
  end

  def handle_call({:subscribe_notices, subscriber}, _from, state) do
    {:reply, :ok, %{state | notice_subscribers: MapSet.put(state.notice_subscribers, subscriber)}}
  end

  def handle_call(_other, _from, state), do: {:reply, {:error, :unknown_call}, state}

  @impl true
  def handle_info(
        {:dp_exchange, :webull, %Notice{kind: :link_up, details: %{session_id: session_id}}} =
          message,
        state
      ) do
    state =
      case shard_index_for_session(state, session_id) do
        nil -> state
        index -> on_link_up(state, index)
      end

    fan_out(state.notice_subscribers, message)
    {:noreply, state}
  end

  def handle_info(
        {:dp_exchange, :webull, %Notice{kind: :link_down, details: %{session_id: session_id}}} =
          message,
        state
      ) do
    state =
      case shard_index_for_session(state, session_id) do
        nil -> state
        index -> put_in(state.shards[index].connected?, false)
      end

    fan_out(state.notice_subscribers, message)
    {:noreply, state}
  end

  def handle_info({:dp_exchange, :webull, %Notice{}} = message, state) do
    fan_out(state.notice_subscribers, message)
    {:noreply, state}
  end

  def handle_info({:dp_exchange, :webull, quote_struct} = message, state) do
    fan_out(state.subscribers, message)

    {:noreply,
     %{
       state
       | delivering: Map.put(state.delivering, quote_struct.symbol, :os.system_time(:millisecond))
     }}
  end

  def handle_info({:open_shard, index, symbols, opts}, state) do
    case Map.get(state.shards, index) do
      nil ->
        case open_socket(state, opts) do
          {:ok, session_id, socket} ->
            shard = %{
              session_id: session_id,
              socket: socket,
              connected?: false,
              symbols: symbols,
              reply_to: nil
            }

            {:noreply, put_in(state.shards[index], shard)}

          {:error, reason} ->
            Logger.warning(
              "[Webull Feed] shard #{index} did not open (#{inspect(reason)}) — its " <>
                "#{length(symbols)} symbol(s) are not covered until a later reshard opens it"
            )

            {:noreply, state}
        end

      _already_open ->
        # A reshard already handled this index by the time the stagger elapsed (a fast-
        # follow call, or a rebalance) — nothing left to do.
        {:noreply, state}
    end
  end

  def handle_info({:reconcile_shard, index, session_id, added, removed, opts}, state) do
    # `session_id` rides in the message rather than being looked up from
    # `state.shards[index]` when this fires — it is what the operation actually needs,
    # captured at the moment it was decided, the same reason Coinbase's own staggered
    # messages carry a socket directly rather than re-deriving one from state later.
    #
    # The HTTP round trip itself runs off this process — see the moduledoc's "Control-plane
    # HTTP never runs on the mailbox that also carries ticks" — so this handler only spawns
    # it; `handle_info({:reconcile_done, {:background, ^index}, result}, state)` below does
    # what this used to do inline once the real answer comes back.
    {:noreply,
     spawn_reconcile(state, {:background, index}, fn ->
       reconcile_by_session(session_id, added, removed, opts)
     end)}
  end

  # This venue keeps a session's MQTT connection alive and subscribed while quietly
  # stopping publication to it — no error, no disconnect, no unsubscribe, nothing a
  # health check can see. The only recovery ever found for it is re-issuing the
  # subscription for symbols already believed subscribed, unconditionally, on a timer —
  # see the moduledoc and DpCryptoManagement's issue #17. `reshard/4` alone cannot do
  # this: it only touches a shard whose *wanted* symbol set changed, and re-asking for
  # exactly what is already wanted computes an empty diff.
  def handle_info(:resubscribe, state) do
    Process.send_after(self(), :resubscribe, @resubscribe_interval_ms)
    {:noreply, Enum.reduce(state.shards, state, &resubscribe_shard/2)}
  end

  # A shard's socket links here (`Socket.start_link/1` -> `WebSockex.start_link/4`), and
  # every control-plane HTTP call now runs in a task under `state.task_supervisor` — see
  # the moduledoc. Either kind of linked process dying abnormally arrives here rather than
  # taking this GenServer down, because `init/1` traps exits.
  def handle_info({:EXIT, pid, reason}, %{task_supervisor: pid} = state) do
    # The task supervisor dying is not one shard's problem — every in-flight reconcile
    # loses its answer with it. Rebuilding it here and hoping every caller's deferred
    # reply still lands correctly is exactly the kind of nearby substitute this family's
    # conventions rule out; stopping and letting the consumer's own supervisor restart
    # this Feed cleanly is the fail-closed choice.
    {:stop, {:task_supervisor_down, reason}, state}
  end

  def handle_info({:EXIT, pid, reason}, state) do
    case shard_index_for_socket(state, pid) do
      nil -> {:noreply, state}
      index -> {:noreply, isolate_crashed_shard(state, index, reason)}
    end
  end

  def handle_info(
        {:reconcile_done, {:primary, index, from, overflow, retries_left, opts}, result},
        state
      ) do
    {state, _rebalanced?} = handle_subscribe_result(state, index, result)

    case result do
      {:error, :oversubscribed} when retries_left > 0 ->
        {:noreply, reshard_step(state, opts, from, retries_left - 1)}

      _settled ->
        GenServer.reply(from, combine_overflow(result, overflow))
        {:noreply, state}
    end
  end

  def handle_info({:reconcile_done, {:background, index}, result}, state) do
    {state, rebalanced?} = handle_subscribe_result(state, index, result)
    state = if rebalanced?, do: resync(state), else: state
    {:noreply, state}
  end

  def handle_info({:reconcile_done, {:link_up, index}, result}, state) do
    {:noreply, complete_link_up(state, index, result)}
  end

  def handle_info({:reconcile_done, {:resubscribe, index}, result}, state) do
    case result do
      {:error, reason} ->
        symbols = state.shards |> Map.get(index, %{symbols: []}) |> Map.fetch!(:symbols)

        Logger.warning(
          "[Webull Feed] shard #{index} blind resubscribe failed: #{inspect(reason)} — " <>
            "its #{length(symbols)} symbol(s) stay on whatever they last delivered " <>
            "until the next resubscribe tick"
        )

      :ok ->
        :ok
    end

    {state, rebalanced?} = handle_subscribe_result(state, index, result)
    state = if rebalanced?, do: resync(state), else: state
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # A shard that has never linked up has nothing subscribed yet — on_link_up/2's own
  # unconditional replay covers it once it does. A shard with nothing wanted has nothing
  # to re-assert.
  defp resubscribe_shard({_index, %{connected?: false}}, state), do: state
  defp resubscribe_shard({_index, %{symbols: []}}, state), do: state

  defp resubscribe_shard({index, shard}, state) do
    spawn_reconcile(state, {:resubscribe, index}, fn ->
      Subscription.subscribe(shard.session_id, shard.symbols, state.resubscribe_opts)
    end)
  end

  # --- resharding -----------------------------------------------------------

  # The single entry point for every call that can change what is wanted. Recomputes
  # shards from the full wanted set, touches only the shards whose symbol set actually
  # changed, hands the first touched shard's HTTP work to a task whose result becomes the
  # call's eventual reply (same observable contract as the single-connection design this
  # replaces — the caller still waits for the real outcome) and stages the rest — see the
  # moduledoc and the design doc §3 for the full rationale.
  defp reshard(state, opts, from), do: {:noreply, reshard_step(state, opts, from, @max_shards)}

  defp reshard_step(state, opts, from, retries_left) do
    {touched, new_shards, overflow} = plan_reshard(state)

    case touched do
      [] ->
        GenServer.reply(from, combine_overflow(:ok, overflow))
        state

      [primary | rest] ->
        state =
          touch_primary_shard(state, primary, new_shards, opts, from, overflow, retries_left)

        Enum.reduce(rest, state, fn index, state ->
          touch_background_shard(state, index, new_shards, opts)
        end)
    end
  end

  # Rebalance-triggered resync: nobody is waiting on a `GenServer.call` for this one, so
  # every touched shard is background — there is no caller to hand a primary's outcome
  # to. Uses `resubscribe_opts` for the same reason `on_link_up/2` does: this runs off a
  # venue-pushed event, not a caller's own request.
  defp resync(state) do
    {touched, new_shards, _overflow} = plan_reshard(state)

    Enum.reduce(touched, state, fn index, state ->
      touch_background_shard(state, index, new_shards, state.resubscribe_opts)
    end)
  end

  # Shared by reshard_step/4 and resync/1: which shards changed, and what each should now
  # carry. Never drops a shard's bookkeeping for being momentarily unwanted — a shard
  # not needed by *this* pass can still be needed moments later by a retry
  # (reshard_step/4's own oversubscribed branch) or an asynchronous rebalance triggered by
  # a DIFFERENT shard's later CONNACK (resync/1, from on_link_up/2), and neither can be
  # predicted in advance. Capped at five shards regardless, keeping an idle one costs
  # nothing worth trading away the correctness of not reopening a connection that never
  # actually needed to close.
  defp plan_reshard(state) do
    {new_shards, overflow} = derive_shards(state.wanted, state.shard_capacity, state.shards)
    existing_indices = Map.keys(state.shards)
    wanted_indices = Map.keys(new_shards)
    new_indices = wanted_indices -- existing_indices
    vanishing_indices = existing_indices -- wanted_indices
    new_shards = Enum.reduce(vanishing_indices, new_shards, &Map.put(&2, &1, []))

    touched =
      (wanted_indices ++ vanishing_indices)
      |> Enum.uniq()
      |> Enum.filter(fn index ->
        index in new_indices or shard_changed?(state, index, new_shards)
      end)
      |> Enum.sort()

    {touched, new_shards, overflow}
  end

  defp touch_primary_shard(state, index, new_shards, opts, from, overflow, retries_left) do
    wanted_symbols = Map.fetch!(new_shards, index)

    case Map.get(state.shards, index) do
      nil ->
        open_primary_shard(state, index, wanted_symbols, opts, from, overflow)

      %{connected?: true} = shard ->
        added = wanted_symbols -- shard.symbols
        removed = shard.symbols -- wanted_symbols
        state = put_in(state.shards[index].symbols, wanted_symbols)

        spawn_reconcile(
          state,
          {:primary, index, from, overflow, retries_left, opts},
          fn -> reconcile_now(shard, added, removed, opts) end
        )

      _still_connecting ->
        # A fresh open or a reconnect is already in flight for this index. Defer to
        # on_link_up/2, exactly as the single-connection design did — see issue #9.
        state = put_in(state.shards[index].symbols, wanted_symbols)
        put_in(state.shards[index].reply_to, {from, overflow})
    end
  end

  defp open_primary_shard(state, index, symbols, opts, from, overflow) do
    case open_socket(state, opts) do
      {:ok, session_id, socket} ->
        shard = %{
          session_id: session_id,
          socket: socket,
          connected?: false,
          symbols: symbols,
          reply_to: {from, overflow}
        }

        put_in(state.shards[index], shard)

      {:error, reason} ->
        GenServer.reply(from, combine_overflow({:error, reason}, overflow))
        state
    end
  end

  defp touch_background_shard(state, index, new_shards, opts) do
    wanted_symbols = Map.fetch!(new_shards, index)

    case Map.get(state.shards, index) do
      nil ->
        Process.send_after(self(), {:open_shard, index, wanted_symbols, opts}, @shard_spacing_ms)
        state

      shard ->
        added = wanted_symbols -- shard.symbols
        removed = shard.symbols -- wanted_symbols

        Process.send_after(
          self(),
          {:reconcile_shard, index, shard.session_id, added, removed, opts},
          0
        )

        put_in(state.shards[index].symbols, wanted_symbols)
    end
  end

  defp on_link_up(state, index) do
    shard = state.shards[index]
    state = put_in(state.shards[index].connected?, true)

    case shard.symbols do
      [] ->
        complete_link_up(state, index, :ok)

      symbols ->
        spawn_reconcile(state, {:link_up, index}, fn ->
          Subscription.subscribe(shard.session_id, symbols, state.resubscribe_opts)
        end)
    end
  end

  # The tail of `on_link_up/2`, shared with the async completion of the HTTP subscribe it
  # may have started — see `handle_info({:reconcile_done, {:link_up, index}, result}, ...)`.
  defp complete_link_up(state, index, result) do
    {state, rebalanced?} = handle_subscribe_result(state, index, result)
    state = if rebalanced?, do: resync(state), else: state

    case Map.get(state.shards, index) do
      %{reply_to: nil} ->
        state

      %{reply_to: {from, overflow}} ->
        GenServer.reply(from, combine_overflow(result, overflow))
        put_in(state.shards[index].reply_to, nil)

      nil ->
        # The shard was removed from under this reply — e.g. its socket crashed and was
        # isolated (see isolate_crashed_shard/3) while its subscribe was in flight. That
        # path already answered any pending caller; nothing left to do here.
        state
    end
  end

  defp reconcile_now(shard, added, removed, opts),
    do: reconcile_by_session(shard.session_id, added, removed, opts)

  defp reconcile_by_session(session_id, added, removed, opts) do
    with :ok <- Subscription.unsubscribe(session_id, removed, opts) do
      Subscription.subscribe(session_id, added, opts)
    end
  end

  # Runs `fun` in its own supervised task rather than inline, so a control-plane HTTP call
  # never blocks this GenServer's mailbox — see the moduledoc. The result comes back as
  # `{:reconcile_done, tag, result}`, handled above; `tag` carries whatever the caller of
  # this function needs to know what to do with it.
  defp spawn_reconcile(state, tag, fun) do
    me = self()

    {:ok, _pid} =
      Task.Supervisor.start_child(state.task_supervisor, fn ->
        send(me, {:reconcile_done, tag, fun.()})
      end)

    state
  end

  # A shard's socket crashing abnormally is contained here rather than taking the whole
  # Feed down — see the moduledoc's "A shard's socket crash is contained to that shard".
  # Any caller still waiting on this shard is answered immediately rather than left to
  # time out; the shard itself is dropped and reopened at the same index with the same
  # wanted symbols, exactly as a fresh shard open would be.
  defp isolate_crashed_shard(state, index, reason) do
    shard = state.shards[index]

    Logger.warning(
      "[Webull Feed] shard #{index} socket crashed (#{inspect(reason)}) — reopening it; " <>
        "its #{length(shard.symbols)} symbol(s) go dark until it reconnects, while every " <>
        "other shard keeps delivering"
    )

    fan_out(
      state.notice_subscribers,
      {:dp_exchange, :webull,
       Notice.new(:link_down, :webull,
         details: %{session_id: shard.session_id, reason: inspect(reason)}
       )}
    )

    case shard.reply_to do
      nil ->
        :ok

      {from, overflow} ->
        GenServer.reply(from, combine_overflow({:error, {:shard_crashed, reason}}, overflow))
    end

    state = %{state | shards: Map.delete(state.shards, index)}
    send(self(), {:open_shard, index, shard.symbols, state.resubscribe_opts})
    state
  end

  defp open_socket(state, opts) do
    case app_key_from(opts) do
      nil ->
        # Credentials arrive per call in this family, same as every other venue's
        # facade — a caller with none cannot open a shard. The venue accepts any
        # password on CONNECT but authenticates by App Key, so an empty one would
        # connect and then sit unauthenticated rather than fail visibly.
        {:error, {:missing_required_field, :app_key}}

      app_key ->
        session_id = generate_session_id()

        socket_opts =
          state.socket_opts
          |> Keyword.put_new(:url, Environment.streaming_url(environment(state, opts)))
          |> Keyword.merge(subscriber: self(), session_id: session_id, app_key: app_key)

        case Socket.start_link(socket_opts) do
          {:ok, socket} -> {:ok, session_id, socket}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp app_key_from(opts) do
    case Keyword.get(opts, :credentials) do
      %{app_key: app_key} when is_binary(app_key) -> app_key
      _no_usable_credentials -> nil
    end
  end

  # A shard's HTTP subscribe rejected as oversubscribed measures, directly, that this
  # shard can carry fewer symbols than assumed — not a guess, the venue's own answer.
  # Capping it here and resyncing moves the overflow to another shard automatically; the
  # design doc §3.5 is explicit that a host must never see this as something to route
  # around itself.
  defp handle_subscribe_result(state, _index, :ok), do: {state, false}

  defp handle_subscribe_result(state, index, {:error, :oversubscribed}) do
    current_size = length(Map.get(state.shards, index, %{symbols: []}).symbols)
    new_capacity = max(current_size - 1, 0)

    Logger.warning(
      "[Webull Feed] shard #{index} rejected #{current_size} symbols as oversubscribed " <>
        "(venue's own stated ceiling is #{@pairs_per_socket}); capping this shard at " <>
        "#{new_capacity} and moving the rest to another shard"
    )

    {%{state | shard_capacity: Map.put(state.shard_capacity, index, new_capacity)}, true}
  end

  defp handle_subscribe_result(state, _index, {:error, _other}), do: {state, false}

  # The only case §3.5 says cannot be absorbed internally: every shard already at
  # capacity and there is nowhere left to put a symbol. Reported, never silently dropped
  # or silently subscribed somewhere already full.
  defp combine_overflow(:ok, []), do: :ok
  defp combine_overflow(:ok, overflow), do: {:error, {:capacity_exceeded, overflow}}
  defp combine_overflow({:error, reason}, []), do: {:error, reason}

  defp combine_overflow({:error, reason}, overflow),
    do: {:error, {:partial_failure, failed: reason, capacity_exceeded: overflow}}

  # Sticky assignment — see the moduledoc's "Shard assignment is sticky, not recomputed
  # from scratch". A symbol already carried by `existing_shards` keeps that shard for as
  # long as it (a) is still wanted and (b) still fits that shard's measured capacity;
  # everything else — genuinely new symbols, and anything just evicted by a capacity
  # reduction — is placed into whichever shard, in index order, still has room. This is
  # what keeps an unrelated insertion from re-sorting the whole wanted set and touching
  # every shard boundary the way a from-scratch chunking would.
  #
  # A symbol that still does not fit anywhere within the venue's five-shard ceiling is
  # overflow — the venue's real ceiling for one App Key, reached.
  defp derive_shards(wanted, shard_capacity, existing_shards) do
    kept =
      Map.new(existing_shards, fn {index, shard} ->
        capacity = Map.get(shard_capacity, index, @pairs_per_socket)
        {index, shard.symbols |> Enum.filter(&MapSet.member?(wanted, &1)) |> Enum.take(capacity)}
      end)

    already_assigned = kept |> Map.values() |> List.flatten() |> MapSet.new()

    # Sorted so which shard an unassigned symbol lands in is reproducible run to run, the
    # same guarantee the original from-scratch sort gave for a fresh wanted set.
    fresh = wanted |> MapSet.difference(already_assigned) |> MapSet.to_list() |> Enum.sort()

    place_fresh_symbols(kept, fresh, shard_capacity)
  end

  defp place_fresh_symbols(kept, fresh, shard_capacity) do
    {shards, overflow} =
      Enum.reduce(0..(@max_shards - 1), {kept, fresh}, fn index, {shards, remaining} ->
        current = Map.get(shards, index, [])
        room = max(Map.get(shard_capacity, index, @pairs_per_socket) - length(current), 0)
        {take, rest} = Enum.split(remaining, room)
        shards = if take == [], do: shards, else: Map.put(shards, index, current ++ take)
        {shards, rest}
      end)

    {Map.reject(shards, fn {_index, symbols} -> symbols == [] end), overflow}
  end

  defp shard_changed?(state, index, new_shards) do
    case Map.get(state.shards, index) do
      nil -> false
      %{symbols: current} -> current != Map.get(new_shards, index, [])
    end
  end

  defp shard_index_for_session(state, session_id) do
    Enum.find_value(state.shards, fn {index, shard} ->
      if shard.session_id == session_id, do: index
    end)
  end

  defp shard_index_for_socket(state, pid) do
    Enum.find_value(state.shards, fn {index, shard} ->
      if shard.socket == pid, do: index
    end)
  end

  # Only what a replay needs, and per-call values win over the ones the tree started
  # with — a caller that named credentials for one subscribe meant them for its replay.
  defp replayable(opts, state) do
    Keyword.merge(
      state.resubscribe_opts,
      Keyword.take(opts, [:credentials, :environment, :limiter, :plug, :req_adapter])
    )
  end

  defp environment(state, opts), do: Environment.resolve(Keyword.merge(state.socket_opts, opts))

  # A subscriber may be a raw pid or a registered name — `subscribe/2`'s `to:` accepts
  # either, matching ordinary OTP practice (a consumer registering itself by name and
  # handing that name to a producer). `Process.alive?/1` only accepts a pid and raises on
  # anything else, so a registered-name subscriber crashed this whole GenServer on every
  # delivery (same defect, same fix, as `dp-exchange-coinbase`'s `Feed.fan_out/2` —
  # DpCryptoManagement's issue #15). Resolving first, uniformly, fixes both: a dead pid
  # resolves to itself and `Process.alive?/1` filters it; an unregistered name resolves
  # to `nil` and is silently skipped, the same as a dead subscriber already was.
  defp fan_out(subscribers, message) do
    Enum.each(subscribers, fn subscriber ->
      case resolve_subscriber(subscriber) do
        pid when is_pid(pid) -> send(pid, message)
        nil -> :ok
      end
    end)
  end

  defp resolve_subscriber(pid) when is_pid(pid) do
    if Process.alive?(pid), do: pid
  end

  defp resolve_subscriber(name) when is_atom(name), do: Process.whereis(name)

  # Unique per shard. The venue disconnects an older connection presenting the same id.
  defp generate_session_id do
    16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
  end
end
