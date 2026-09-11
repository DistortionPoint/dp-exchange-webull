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

  ## Coverage by kind, because this venue's streamed kinds really are independent

  Every subscribe asks the venue for `SNAPSHOT`, `QUOTE` and `TICK` (see `Subscription`),
  and the three arrive on separate MQTT topics decoded by `Socket` into three different
  structs: `snapshot` becomes `Core.Types.Quote` (kind `:quotes`, a traded price), `quote`
  becomes `Core.Types.TopOfBook` (kind `:top_of_book`, bid/ask), `tick` becomes
  `Core.Types.Trade` (kind `:trades`, one print). `coverage/1` folds all three into one
  `:stream` per symbol, so a symbol whose `snapshot` topic goes dark while its `quote`
  topic keeps arriving — or any other combination — is invisible there;
  `coverage_by_kind/1` exists to split exactly that apart, one kind map per struct type
  actually observed. `kind_for/1` derives the kind from the struct that arrived rather
  than assuming it, so a future new kind reaching this clause without a matching case
  here is caught (logged, loudly) instead of silently folded into an existing kind.

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
  below it. See `dp_exchange_core`'s
  `docs/design/closed/2026-09-04_webull-sharding-and-fake-injection.md` §3.1 for why
  padding a number the venue already stated would be exactly the unlabeled guess this
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

  ## The resubscribe timer must never fail-fast

  A moduledoc worth carrying from `dp_exchange_robinhood`'s `Feed`, which named this
  exact shape first (`acquire`, not `check` — DpCryptoManagement's issue #16). This
  package reproduced it independently, live, at a worse scale: DpCryptoManagement's
  issue #23 — a node restart, all 4 MQTT shards linking up cleanly, then **58
  consecutive blind-resubscribe failures across 13 minutes**, every one the identical
  refusal:

      {:exchange_error, :webull, "Throttled by our own rate limiter (not the venue) —
       retry after 1s; callers that can wait should set rate_limit_blocking: true"}

  `Core.HttpClient`'s own message names the fix. The refusal asks for a **one-second**
  wait; `@resubscribe_interval_ms` is 60,000. Fail-fast (`check/3`) on this timer means
  the request is dropped for a whole minute to avoid waiting a second — a self-inflicted
  outage the venue never asked for. Measured consumer impact: 0 of 342 pairs streaming,
  every one of them falling back to REST polling, for as long as the rate limiter stayed
  contended.

  It compounds with the venue's own transient `INVALID_SYMBOL` rejections on an initial
  subscribe (ordinarily self-healing, since the very next resubscribe tick re-asks for
  the same symbol) — because recovery from *that* runs through this same blind
  resubscribe, a recoverable error became permanent for exactly as long as the timer
  could never issue a request at all.

  **Documenting that design was not the same as wiring it — again.** `:rate_limit_blocking`
  — the option `Core.HttpClient.check_rate_limits/1` reads to choose `acquire/3` over
  `check/3` — was missing from every allowlist on the path a blind resubscribe actually
  takes: this module's own `resubscribe_opts` (built once in `init/1`), `replayable/2`
  (what carries it forward across every later subscribe), and `Subscription.request_opts/1`
  (the last allowlist before `Core.HttpClient` itself). Fixing only the two in this module
  and leaving `Subscription`'s allowlist untouched would have shipped a change that reads
  as a fix and does nothing: the option would still be stripped one layer down, silently,
  with every test that stops at "the keyword list contains `:rate_limit_blocking`" passing
  regardless.

  All three now forward it. Only `Feed`'s own opts — `resubscribe_opts` at `init/1`, and
  `replayable/2` on every call after — default it to `true`: the resubscribe timer runs
  off a 60-second clock with no caller waiting on its result, so blocking for as long as a
  second is free. `Subscription.request_opts/1` forwards the option without defaulting
  it, on purpose — a caller invoking `Subscription.subscribe/3` directly, one-off, may
  legitimately want fail-fast, and this module must not decide that for it.

  ## A generic resubscribe failure is reported too, latched per shard

  The blind resubscribe timer already had two callers-visible outcomes when the venue's
  answer was structured: `:oversubscribed` rebalances silently (see
  `handle_subscribe_result/3` — it is a capacity measurement, not a failure), and
  `{:error, {:invalid_symbols, symbols}}` gets its own `:refusal` notice (see "A
  venue-rejected symbol is excluded, timed, and reported" above). Everything else an
  `{:error, reason}` could be — the rate-limiter throttling of DpCryptoManagement's issue
  #23, an HTTP 5xx, a transport error — fell through `handle_subscribe_result/3`'s
  catch-all clause to a `Logger.warning` and nothing else: a real, ongoing failure with no
  facade-level signal a consumer could act on.

  Issue #23 is the concrete incident this closes visibility on: a node restart, all 4
  shards linking up cleanly, then 58 consecutive blind-resubscribe failures across 13
  minutes, every one the identical rate-limiter refusal — discovered only by grepping this
  module's own log for the sentence it had been repeating the whole time. `PollingFeed`'s
  own `:on_notice` (DpCryptoManagement's issue #21, the poll-feed sibling of this same
  gap) is the pattern this follows: a `Core.Notice{kind: :coverage_change}` fires the
  instant a shard's blind resubscribe crosses INTO this generic failure, `severity: :info`
  fires the instant it crosses back OUT, and neither fires again while the shard's own
  state stays put.

  Latched **per shard**, not globally — `state.resubscribe_failed`, a `MapSet` of shard
  indices currently in this state — because each shard is its own independent MQTT
  session with its own independent failure and recovery schedule. A global latch would
  either swallow a second shard's own transition while the first stayed latched, or
  (unlatched entirely) fire a fresh notice from up to five shards every single
  `@resubscribe_interval_ms` during a widespread outage — a notice storm being its own
  defect, exactly as issue #21's design established. The existing `Logger.warning` above
  keeps firing every tick regardless, unchanged — this notice is additive, not a
  replacement for it.

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

  ## A venue-rejected symbol is excluded, timed, and reported — DpCryptoManagement's issue #24

  `Subscription`'s `INVALID_SYMBOL` handling (see its own moduledoc) hands this module
  `{:error, {:invalid_symbols, [canonical_symbol, ...]}}` instead of an opaque string. The
  reason this module, not `Subscription`, has to be the one to act on it: rejection here is
  per-**request**, so one symbol the venue's streaming category does not carry fails the
  *entire* shard's batch — measured live as 17 of one consumer's 342 symbols, named
  byte-for-byte identically every 60-second resubscribe tick, taking `stream_covered` to
  0/342 and every pair to REST polling (the sustained 429 storm DpCryptoManagement's issue
  #23 first surfaced).

  Handled the same way `:oversubscribed` already is — see `handle_subscribe_result/3` and
  the retry branch in `reshard_step/4` — because the shape is the same: a structured venue
  answer this package can act on automatically rather than a caller-visible failure. The
  named symbols are recorded in `state.rejected` with an expiry and excluded from
  `plan_reshard/1`'s effective wanted set (`active_rejections/1`), so the *next* chunk built
  for that shard carries only the symbols the venue actually accepts, and every other shard
  is untouched.

  **`state.wanted` is never pruned.** Only what `plan_reshard/1` treats as *wantable right
  now* shrinks — a rejected symbol stays in `wanted` for exactly the reason `coverage/1` is
  observed rather than intended: the host asked for it, and whether the venue currently
  carries it is a separate, time-bound fact. `active_rejections/1` returning it to eligibility
  the moment its entry expires is what lets it flow straight back into a shard on the very
  next reshard-triggering event — the same 60-second resubscribe tick that discovered the
  rejection, once `resync/1` runs off it again — with nobody calling `update_symbols/2`.

  **`@rejected_symbol_ttl_ms` defaults to 24 hours, deliberately matching
  `DpCryptoManagement.Data.Collection.VenueRefusals`' own TTL for exactly this shape of
  fact**: a venue's streaming catalogue is true at a point in time, not permanently, and a
  symbol it refuses today can be listed later. Picked to be the same order of magnitude as
  that consumer-side cache rather than independently guessed — two different TTLs for the
  same underlying fact would mean the two layers disagree about how stale a "the venue
  refuses this" belief is allowed to get. Overridable per call via `opts[:rejected_symbol_ttl_ms]`
  for a consumer with a documented reason to want a different number.

  **Reported, not just filtered.** A filtered symbol that only ever disappears from shard
  composition is coverage silently shrinking — this module's data stream never reports it
  either way (see "Coverage is observed, never intended" above: it was never delivering, so
  it was never in `coverage/1` to begin with), so the *only* way a consumer learns 17 of its
  342 symbols stopped being tried is a `Core.Notice`. Emitted as `:refusal` — Core's own
  documented kind for exactly this ("a symbol the venue will not carry"), not a
  package-invented one — naming the rejected symbols in canonical form, the same reason
  `Subscription` converts them before this module ever sees them: a notice is public, gets
  pasted into issues, and must never carry a venue-native string a consumer has no mapping
  for.

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

  alias DpExchange.Core.{Fanout, Notice}
  alias DpExchange.Core.Types.{Quote, TopOfBook, Trade}
  alias DpExchange.Webull.{Credentials, Environment, Socket, Subscription}

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

  # See the moduledoc's "A venue-rejected symbol is excluded, timed, and reported" —
  # deliberately the same order of magnitude as
  # `DpCryptoManagement.Data.Collection.VenueRefusals`' own 24h TTL for exactly this shape
  # of fact (a venue catalogue is true at a point in time, not permanently). Overridable via
  # `opts[:rejected_symbol_ttl_ms]`.
  @rejected_symbol_ttl_ms 24 * 60 * 60 * 1000

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

  # NOTE — reads carry `@call_timeout` explicitly, exactly as the writes above do.
  #
  # They used to take `GenServer.call/2`'s implicit five seconds, and that asymmetry is what
  # turned a bounded delay into a dead caller in dp-exchange-core issue #28: `coverage/1` is
  # the call a consumer's health check makes, so any moment this Feed was busy for longer
  # than five seconds turned a health check into an EXIT — killing the consumer's own
  # process when it read from inside its own `handle_call/3`. Asking whether the venue was
  # healthy was what made it unhealthy.
  #
  # The blocking is fixed at its sources rather than papered over here; this is the second
  # line of defence. A read that has to queue behind something should WAIT for it, never
  # die of it.
  @spec coverage(GenServer.server()) :: %{String.t() => :stream | :internal_poll | :not_covered}
  def coverage(feed), do: GenServer.call(feed, :coverage, @call_timeout)

  @spec coverage_by_kind(GenServer.server()) :: %{
          DpExchange.Core.Capabilities.data_kind() => %{
            String.t() => :stream | :internal_poll | :not_covered
          }
        }
  def coverage_by_kind(feed), do: GenServer.call(feed, :coverage_by_kind, @call_timeout)

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

    resubscribe_interval_ms =
      (Keyword.get(opts, :resubscribe_interval_ms) || @resubscribe_interval_ms)
      |> validate_resubscribe_interval_ms!()

    Process.send_after(self(), :resubscribe, resubscribe_interval_ms)

    {:ok,
     %{
       task_supervisor: task_supervisor,
       resubscribe_interval_ms: resubscribe_interval_ms,
       socket_opts:
         Keyword.take(opts, [
           :url,
           :environment,
           # Forwarded so a consumer can tune the connect budget. `Socket` chooses
           # deliberate defaults rather than inheriting websockex's, which do not fit
           # inside this module's own `@call_timeout` — see `Socket.connection_opts/1`.
           :socket_connect_timeout,
           :socket_recv_timeout
         ]),
       # Retained so a reconnect (or a rebalance) can replay a shard's subscription. The
       # venue restores nothing, and a replay needs credentials — so a consumer that
       # wants automatic recovery hands them to the tree at start, exactly as the other
       # venues in this family do. Per-call options still override these for calls made
       # directly against a caller's own request.
       #
       # `:rate_limit_blocking` is forwarded and defaulted to `true` here — see the
       # moduledoc's "The resubscribe timer must never fail-fast" and
       # DpCryptoManagement's issue #23. `replayable/2` carries this default forward on
       # every later subscribe/update_symbols unless a caller's own opts override it.
       resubscribe_opts:
         opts
         |> Keyword.take([:credentials, :environment, :limiter, :plug, :rate_limit_blocking])
         |> Keyword.put_new(:rate_limit_blocking, true)
         # Wrapped immediately, before this list ever reaches `state` — see
         # `Credentials`'s moduledoc. Every downstream use (`Subscription.subscribe/3`,
         # `Auth.headers/2`, the `{:open_shard, ...}` message `isolate_crashed_shard/2`
         # sends to self) keeps working unchanged: a struct is a map.
         |> Credentials.wrap_opt(),
       subscribers: MapSet.new(),
       notice_subscribers: MapSet.new(),
       # Back-pressure, per `Core.Venue`'s `subscribe/2` doc and implemented by
       # `Core.Fanout`: `dropping` is the set of subscribers currently over their mailbox
       # bound, carried across calls so a stalled consumer produces one `:degraded` notice
       # when delivery to it stops and one when it resumes — never one per dropped message,
       # which would arrive at the rate of the stream it already cannot keep up with.
       dropping: MapSet.new(),
       max_queue_len: Fanout.max_queue_len!(opts, :webull),
       wanted: MapSet.new(),
       delivering: %{},
       # kind() => %{symbol => timestamp}, built alongside `delivering` above from the
       # same arriving payloads — never from `wanted` or from what was subscribed. See
       # the moduledoc's "Coverage by kind" and `kind_for/1`.
       delivering_by_kind: %{},
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
       shard_capacity: Keyword.get(opts, :shard_capacity, %{}),
       # symbol => expiry (`:os.system_time(:millisecond)`). Excluded from
       # `plan_reshard/1`'s effective wanted set while unexpired — see the moduledoc's "A
       # venue-rejected symbol is excluded, timed, and reported". Never removed from
       # `state.wanted` itself; `active_rejections/1` is what makes the exclusion time-bound.
       rejected: %{},
       rejected_symbol_ttl_ms:
         Keyword.get(opts, :rejected_symbol_ttl_ms, @rejected_symbol_ttl_ms),
       # Shard indices currently latched into a generic blind-resubscribe failure — see the
       # moduledoc's "A generic resubscribe failure is reported too, latched per shard".
       # A top-level set rather than a field on each shard's own map: `isolate_crashed_shard/3`
       # deletes and rebuilds a shard's entry wholesale on a crash, and this latch's own
       # lifecycle is deliberately independent of that — see the comment there.
       resubscribe_failed: MapSet.new()
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

    state = %{
      state
      | wanted: wanted,
        delivering: Map.drop(state.delivering, symbols),
        delivering_by_kind: drop_symbols_by_kind(state.delivering_by_kind, symbols)
    }

    reshard(state, opts, from)
  end

  def handle_call({:update_symbols, symbols, opts}, from, state) do
    wanted = MapSet.new(symbols)

    state = %{
      state
      | wanted: wanted,
        delivering: Map.take(state.delivering, symbols),
        delivering_by_kind: take_symbols_by_kind(state.delivering_by_kind, symbols),
        resubscribe_opts: replayable(opts, state)
    }

    reshard(state, opts, from)
  end

  def handle_call(:coverage, _from, state) do
    {:reply, Map.new(state.delivering, fn {symbol, _at} -> {symbol, :stream} end), state}
  end

  def handle_call(:coverage_by_kind, _from, state) do
    by_kind =
      Map.new(state.delivering_by_kind, fn {kind, per_symbol} ->
        {kind, Map.new(per_symbol, fn {symbol, _at} -> {symbol, :stream} end)}
      end)

    {:reply, by_kind, state}
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
        nil ->
          state

        index ->
          # A TRANSPORT drop, not a shard crash, and until this the two were handled
          # differently for no reason. `Socket.handle_disconnect/2` returns
          # `{:reconnect, …}`, so the socket process survives and no `:EXIT` reaches
          # `isolate_crashed_shard/3` — which meant this clause flipped `connected?` and
          # left the delivery records from the connection that just died answering
          # `:stream` for symbols arriving from nowhere. Worse, a reconnect that restored
          # the socket while the venue silently failed to restore a symbol left that symbol
          # answering `:stream` indefinitely: the 325-subscribed/174-delivering shape
          # `coverage/1` exists to make visible.
          #
          # `isolate_crashed_shard/3` already says why, and the reason does not depend on
          # what killed the link — *"`coverage/1`/`coverage_by_kind/1` must not keep
          # answering `:stream` for a shard that just crashed … until this, `coverage/1`
          # itself kept lying in the meantime."* Dropped the same way, for the same reason,
          # and scoped to that one shard: the other three shards are on their own sockets
          # and untouched. See `Core.Venue`'s `coverage/1` doc.
          #
          # The shard KEEPS its entry, unlike the crash path — it is reconnecting rather
          # than dead, and its symbols return as frames arrive after the next resubscribe.
          shard = Map.fetch!(state.shards, index)

          %{
            put_in(state.shards[index].connected?, false)
            | delivering: Map.drop(state.delivering, shard.symbols),
              delivering_by_kind: drop_symbols_by_kind(state.delivering_by_kind, shard.symbols)
          }
      end

    fan_out(state.notice_subscribers, message)
    {:noreply, state}
  end

  def handle_info({:dp_exchange, :webull, %Notice{}} = message, state) do
    fan_out(state.notice_subscribers, message)
    {:noreply, state}
  end

  # `delivering` is recorded whether or not the payload reached anybody — see `deliver/2`.
  # `coverage/1` reports what the VENUE delivered to this package, not what this package
  # forwarded.
  def handle_info({:dp_exchange, :webull, quote_struct} = message, state) do
    state = deliver(state, message)

    now = :os.system_time(:millisecond)
    symbol = quote_struct.symbol
    delivering = Map.put(state.delivering, symbol, now)

    delivering_by_kind =
      case kind_for(quote_struct) do
        {:ok, kind} ->
          Map.update(state.delivering_by_kind, kind, %{symbol => now}, &Map.put(&1, symbol, now))

        :error ->
          # `coverage/1` above still counts this arrival — it is truthful about *any*
          # payload. This struct just cannot be named as one of `Capabilities.data_kind()`,
          # which means `coverage_by_kind/1` cannot report it under any kind without
          # guessing one. Logged loudly rather than silently dropped or folded into an
          # existing kind — see the moduledoc's "Coverage by kind".
          Logger.warning(
            "DpExchange.Webull.Feed: #{inspect(quote_struct.__struct__)} for #{symbol} " <>
              "has no known data_kind mapping in kind_for/1 — coverage/1 counts it, " <>
              "coverage_by_kind/1 cannot"
          )

          state.delivering_by_kind
      end

    {:noreply, %{state | delivering: delivering, delivering_by_kind: delivering_by_kind}}
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
    Process.send_after(self(), :resubscribe, state.resubscribe_interval_ms)
    state = Enum.reduce(state.shards, state, &resubscribe_shard/2)

    # A TTL-expired rejection (see the moduledoc's "A venue-rejected symbol is excluded,
    # timed, and reported") only ever returns to a shard's own symbol list through
    # `plan_reshard/1` — this ordinary blind reassert above sends exactly what a shard
    # already remembers, which no longer includes a symbol trimmed off it after a
    # rejection. Guarded on `state.rejected` being non-empty rather than run
    # unconditionally: an always-on `resync/1` here would recompute composition against
    # `state.wanted` for every shard on every tick regardless of whether this package has
    # ever recorded a rejection, which is a real behaviour change this fix has no reason
    # to make.
    state = if state.rejected == %{}, do: state, else: resync(state)

    {:noreply, state}
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

      {:error, {:invalid_symbols, _symbols}} when retries_left > 0 ->
        # Same reasoning as :oversubscribed above: the batch this shard just tried included
        # a symbol the venue refuses, which failed the WHOLE request — retrying immediately
        # with `plan_reshard/1` now excluding it (via `handle_subscribe_result/3` just above,
        # which recorded the rejection before this case runs) is what lets the caller's own
        # reply be a clean `:ok` for the rest despite this shard's first attempt being
        # refused. See the moduledoc's "A venue-rejected symbol is excluded, timed, and
        # reported".
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
    state =
      case result do
        {:error, reason} ->
          symbols = state.shards |> Map.get(index, %{symbols: []}) |> Map.fetch!(:symbols)

          Logger.warning(
            "[Webull Feed] shard #{index} blind resubscribe failed: #{inspect(reason)} — " <>
              "its #{length(symbols)} symbol(s) stay on whatever they last delivered " <>
              "until the next resubscribe tick"
          )

          if generic_resubscribe_error?(reason) do
            latch_resubscribe_failure(state, index, symbols, reason)
          else
            state
          end

        :ok ->
          clear_resubscribe_failure(state, index)
      end

    {state, rebalanced?} = handle_subscribe_result(state, index, result)
    state = if rebalanced?, do: resync(state), else: state
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # Runs only for the ordinary shutdown reasons GenServer treats as "normal termination"
  # — see its own `c:terminate/2` docs. `init/1` already traps exits, which is what makes
  # this actually run rather than being skipped the way it is by default: a `GenServer`
  # that traps exits and receives one from its own parent (the process that called
  # `start_link/1` — here, `DpExchange.Webull.Supervisor`) invokes `terminate/2` before
  # exiting, without needing a `handle_info({:EXIT, ...})` clause of its own for that case.
  #
  # A crash reason is deliberately excluded: sending `DISCONNECT` on every shard's socket
  # is real network I/O, on connections that may themselves be why this process is
  # crashing, and slowing a supervisor's restart down to attempt it is the wrong trade —
  # "let it crash" means the reconnect-and-resubscribe path this module already has
  # handles recovery, not that shutdown must also clean up the wire.
  @impl true
  def terminate(:normal, state), do: disconnect_connected_shards(state)
  def terminate(:shutdown, state), do: disconnect_connected_shards(state)
  def terminate({:shutdown, _reason}, state), do: disconnect_connected_shards(state)
  def terminate(_crash_reason, _state), do: :ok

  # Best-effort, one MQTT `DISCONNECT` per shard still connected — see `Socket.disconnect/2`
  # and `MqttPacket.disconnect/0` for what this sends and why. A shard that never linked up
  # has no session to close cleanly; `resubscribe_shard/2`'s own `connected?: false` clause
  # makes the same distinction for the same reason.
  defp disconnect_connected_shards(state) do
    state.shards
    |> Enum.filter(fn {_index, shard} -> shard.connected? end)
    |> Enum.each(fn {index, shard} ->
      case Socket.disconnect(shard.socket) do
        :ok ->
          :ok

        {:error, reason} ->
          log_disconnect_failure(index, reason)
      end
    end)

    :ok
  end

  # `:not_alive` and `:calling_self` are structural, not a failed send — see
  # `Socket.disconnect/2`'s own moduledoc. `:not_alive` means the socket process is
  # already gone, which on the normal shutdown path (every socket's supervisor is
  # shutting down at the same time this `Feed` is) is the ordinary case, not a failure
  # worth a warning: this ran on *every* test teardown before this fix, training whoever
  # read CI output to stop reading `[Webull Feed]` warnings at all — the exact failure
  # mode a red build for a non-failure caused earlier. `:calling_self` can only happen
  # through a test fixture that hands `terminate/2` its own pid, never in production.
  #
  # Any OTHER reason means the socket was alive and reachable and the send still failed —
  # a real send failure the venue will see as an abrupt disconnect, worth surfacing at the
  # level it was before.
  defp log_disconnect_failure(index, reason) when reason in [:not_alive, :calling_self] do
    Logger.debug(
      "[Webull Feed] shard #{index} DISCONNECT on shutdown skipped: #{inspect(reason)} — " <>
        "the socket was already gone, which is the ordinary shape of a shutdown, not a " <>
        "failed send"
    )
  end

  defp log_disconnect_failure(index, reason) do
    Logger.warning(
      "[Webull Feed] shard #{index} DISCONNECT on shutdown failed: " <>
        "#{inspect(reason)} — the venue will see an abrupt disconnect instead of a " <>
        "clean one"
    )
  end

  # Overridable at start, defaulting to `@resubscribe_interval_ms`.
  #
  # It was a hardcoded attribute until dp-exchange-core issue #33, where a consumer watching
  # "Permission grabbed by other session, category : us-crypto" arrive ~3.5 times a minute
  # across four shards asked whether this package's own shards were taking the category from
  # each other. That rate is very close to what this timer produces — four connected shards
  # re-asserting once per 60_000 ms is 4/min, and they measured 230 in 66 minutes — but
  # arithmetic agreeing is a hypothesis, not a finding, and nothing here can probe a venue
  # that needs a credential this repository must never hold.
  #
  # **A consumer can settle it, and could not before**: raise this to 300_000 and the notice
  # rate should fall to a fifth if this timer is the trigger, and not move at all if it is
  # not. `dp_exchange_coinbase` already exposed the identical knob; this venue's staying
  # private is what made a live degradation undiagnosable from outside.
  #
  # Validated rather than coerced, the same way that package validates its own: a value that
  # cannot schedule anything fails `init/1` loudly instead of silently reverting to the
  # default and leaving the experiment looking like a negative result.
  defp validate_resubscribe_interval_ms!(value) when is_integer(value) and value >= 1_000,
    do: value

  defp validate_resubscribe_interval_ms!(value) do
    raise ArgumentError,
          "DpExchange.Webull.Feed :resubscribe_interval_ms must be an integer of at least " <>
            "1_000 ms, got #{inspect(value)}. Below a second this re-asserts every shard's " <>
            "whole subscription faster than the venue can answer it, which is a load " <>
            "problem rather than a safety net."
  end

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
    effective_wanted = MapSet.difference(state.wanted, active_rejections(state))
    {new_shards, overflow} = derive_shards(effective_wanted, state.shard_capacity, state.shards)
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

    # A crash tears this index's shard identity down wholesale and rebuilds it as a fresh
    # open below — the same treatment a brand-new shard gets. Any resubscribe-failure latch
    # is cleared with it: it was tracking THIS connection's own generic failures, and a
    # freshly reopened shard has never failed a resubscribe yet. Left uncleared, a shard
    # that crashed while latched would fire a misleading "recovered" notice the moment its
    # fresh session's first resubscribe merely succeeded, for a failure the new connection
    # never actually had — the crash itself is already reported separately, via the
    # `:link_down` notice just above and whatever `:link_up`/`:link_down` pair follows.
    # `coverage/1`/`coverage_by_kind/1` must not keep answering `:stream` for a shard
    # that just crashed — the same "silent half-dead feed" this module's moduledoc is
    # about, one step earlier: the shard IS reported (via the `:link_down` notice above),
    # but until this, `coverage/1` itself kept lying in the meantime. Dropped the same
    # way `unsubscribe/2` already drops a departing symbol's delivery record — see
    # `drop_symbols_by_kind/2` above — because a symbol whose only shard just died has
    # exactly as little arriving for it as one that was never subscribed.
    state = %{
      state
      | shards: Map.delete(state.shards, index),
        resubscribe_failed: MapSet.delete(state.resubscribe_failed, index),
        delivering: Map.drop(state.delivering, shard.symbols),
        delivering_by_kind: drop_symbols_by_kind(state.delivering_by_kind, shard.symbols)
    }

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

  # `symbols` arrives already canonical — `Subscription`'s own job, see its moduledoc — so
  # nothing venue-shaped reaches `state.rejected` or the `Notice` below. See the moduledoc's
  # "A venue-rejected symbol is excluded, timed, and reported" (DpCryptoManagement's issue
  # #24): recorded with an expiry so `plan_reshard/1` excludes them from this shard's next
  # chunk (`true` below runs `resync/1` on every caller of this function except the
  # synchronous primary retry, which instead loops back through `reshard_step/4` itself),
  # and surfaced as a `:refusal` notice — Core's own documented kind for this — because a
  # symbol that only ever disappears from shard composition is coverage silently shrinking
  # with no way for a consumer to learn why.
  defp handle_subscribe_result(state, index, {:error, {:invalid_symbols, symbols}}) do
    # `System.monotonic_time/1`, NOT `:os.system_time/1`, and `active_rejections/1`
    # compares on the same scale. This is an in-VM duration — "exclude this symbol for
    # 24 hours from now" — and the wall clock is not a duration source: an NTP step, a
    # host resync after a bad RTC, or a VM resuming from a snapshot moves it backwards,
    # and every unexpired entry silently gains that much extra life. The default TTL is
    # 24 hours precisely so a "the venue refuses this" belief has a bound; a belief that
    # can outlive its own bound by however far the clock jumped is the bound not holding.
    # A forward step is the mirror image: every rejection expires at once and the shard
    # re-subscribes symbols the venue is still refusing.
    #
    # `Core.PollingFeed` already computes its own staleness window this way. This was the
    # only in-VM duration in the family still measured on the wall clock — the auth token
    # expiries and the nonce next to it are wall-clock on purpose, because those instants
    # come from the venue and are compared against the venue's clock, not ours.
    expires_at = System.monotonic_time(:millisecond) + state.rejected_symbol_ttl_ms
    rejected = Enum.reduce(symbols, state.rejected, &Map.put(&2, &1, expires_at))

    Logger.warning(
      "[Webull Feed] shard #{index} rejected #{length(symbols)} symbol(s) as " <>
        "INVALID_SYMBOL (#{inspect(symbols)}) — excluded from shard composition for " <>
        "#{div(state.rejected_symbol_ttl_ms, 3_600_000)}h or until the venue relists them"
    )

    fan_out(
      state.notice_subscribers,
      {:dp_exchange, :webull,
       Notice.new(:refusal, :webull,
         message: "webull refuses #{length(symbols)} symbol(s): #{Enum.join(symbols, ", ")}",
         details: %{symbols: symbols}
       )}
    )

    {%{state | rejected: rejected}, true}
  end

  # See `rebuild_stale_shard/3`. Placed in this shared funnel rather than in one
  # `{:reconcile_done, ...}` clause so every subscribe path — a caller's own `subscribe/2`,
  # a background reconcile, a post-CONNACK replay and the blind resubscribe timer — recovers
  # the same way. The blind resubscribe is merely where it was first observed.
  defp handle_subscribe_result(state, index, {:error, {:invalid_session, session_id}}),
    do: {rebuild_stale_shard(state, index, session_id), false}

  defp handle_subscribe_result(state, _index, {:error, _other}), do: {state, false}

  # A subscribe answered `INVALID_SESSION`: the session this shard is addressed to no longer
  # exists venue-side, so its MQTT connection is gone whatever the socket process still
  # believes. Re-sending the identical subscribe is the ONE action guaranteed not to help —
  # which is exactly what this package did, once a minute, for fourteen hours across all
  # four shards (dp-exchange-core issue #30: 1,479 identical warnings, 260 of 325 symbols
  # receiving nothing, and a human restarting the feed as the only recovery). The venue was
  # handing out working sessions the whole time; only the path to ask for one was missing.
  #
  # The recovery is the one this module already has for a crashed socket: drop the shard
  # wholesale and reopen it. It has to be a reopen rather than a retry because the session
  # id is minted in `open_socket/2` when the socket opens — a fresh session REQUIRES a fresh
  # socket, so there is no subscribe-level fix available here at all.
  #
  # ORDER MATTERS. The shard leaves `state.shards` BEFORE its socket is stopped, so the
  # `{:EXIT, ...}` that stopping it produces finds no shard for that pid and is ignored by
  # `handle_info({:EXIT, ...})`, rather than driving a second concurrent rebuild of the same
  # index through `isolate_crashed_shard/3`.
  #
  # The socket is stopped, not abandoned. Unlike a crash, the process here is very likely
  # still alive, holding a WebSocket the venue has already discarded. This venue allows
  # **five concurrent connections per App Key**, so leaking one per stale session would
  # exhaust the budget after a handful of these and turn a recoverable outage into an
  # unrecoverable one. No MQTT `DISCONNECT` is sent first: `Socket.disconnect/2` addresses
  # the session, and the session is precisely what no longer exists.
  #
  # No reply is sent to `shard.reply_to` here, deliberately — unlike `isolate_crashed_shard/3`,
  # which is reached from an `{:EXIT, ...}` nobody is waiting on. This runs inside a
  # `{:reconcile_done, ...}` clause that already owns the caller's reply and answers it with
  # this same error, so replying again would be a double `GenServer.reply/2`.
  defp rebuild_stale_shard(state, index, session_id) do
    case Map.fetch(state.shards, index) do
      :error ->
        state

      {:ok, shard} ->
        named = session_id || shard.session_id

        Logger.warning(
          "[Webull Feed] shard #{index} session #{inspect(named)} no longer exists " <>
            "venue-side (INVALID_SESSION) — reopening the shard on a fresh session; its " <>
            "#{length(shard.symbols)} symbol(s) go dark until it reconnects, while every " <>
            "other shard keeps delivering"
        )

        fan_out(
          state.notice_subscribers,
          {:dp_exchange, :webull,
           Notice.new(:link_down, :webull,
             details: %{
               session_id: named,
               reason: "INVALID_SESSION — reopening the shard on a fresh session"
             }
           )}
        )

        state = %{
          state
          | shards: Map.delete(state.shards, index),
            resubscribe_failed: MapSet.delete(state.resubscribe_failed, index),
            delivering: Map.drop(state.delivering, shard.symbols),
            delivering_by_kind: drop_symbols_by_kind(state.delivering_by_kind, shard.symbols)
        }

        stop_socket(shard.socket)
        send(self(), {:open_shard, index, shard.symbols, state.resubscribe_opts})
        state
    end
  end

  # `:shutdown` rather than `:kill`: the socket does not trap exits, so either terminates
  # it, and `:shutdown` is the reason that reads as intentional in any report it produces.
  defp stop_socket(socket) when is_pid(socket) do
    if Process.alive?(socket), do: Process.exit(socket, :shutdown)
    :ok
  end

  defp stop_socket(_no_socket), do: :ok

  # Mirrors, on purpose, the exact classification `handle_subscribe_result/3` just applied
  # above: `:oversubscribed` self-heals silently (a capacity measurement, not a failure to
  # report) and `{:invalid_symbols, _}` already gets its own `:refusal` notice. Both are
  # excluded here rather than re-derived some other way, so this clause's own notice never
  # drifts out of step with what the two clauses above actually handle. Everything else —
  # the rate-limiter throttling of DpCryptoManagement's issue #23, an HTTP 5xx, a transport
  # error — is the generic shape this module's own `:coverage_change` notice exists for.
  defp generic_resubscribe_error?(:oversubscribed), do: false
  defp generic_resubscribe_error?({:invalid_symbols, _symbols}), do: false
  # Not generic: it has a real recovery (`rebuild_stale_shard/3`) and emits its own
  # `:link_down` notice, so latching it as an unexplained failure would report the same
  # event twice and in the less useful shape.
  defp generic_resubscribe_error?({:invalid_session, _session_id}), do: false
  defp generic_resubscribe_error?(_other), do: true

  # Fires once per transition into a shard's blind-resubscribe failing generically — see
  # the moduledoc's "A generic resubscribe failure is reported too, latched per shard" and
  # DpCryptoManagement's issue #23 (58 consecutive failures across 13 minutes, all of it
  # invisible outside a log grep). Latched per shard, not globally: each shard is its own
  # MQTT session with its own independent failure and recovery schedule, and a global latch
  # would either miss a second shard's own transition or fire on every tick once ANY shard
  # is already latched. A latched shard's every later tick re-enters this same branch (the
  # `Logger.warning` above keeps firing with it, unchanged, by design) but short-circuits
  # here rather than notifying again — a notice per tick on a sustained outage is still a
  # storm, just a slower one.
  defp latch_resubscribe_failure(state, index, symbols, reason) do
    if MapSet.member?(state.resubscribe_failed, index) do
      state
    else
      notice =
        Notice.new(:coverage_change, :webull,
          severity: :warning,
          message:
            "shard #{index} resubscribe has failed (#{inspect(reason)}) — " <>
              "#{length(symbols)} symbol(s) stay on whatever they last delivered " <>
              "until it recovers",
          details: %{shard: index, symbol_count: length(symbols), reason: inspect(reason)}
        )

      fan_out(state.notice_subscribers, {:dp_exchange, :webull, notice})
      %{state | resubscribe_failed: MapSet.put(state.resubscribe_failed, index)}
    end
  end

  # The other half of the transition above: a shard latched into failure whose blind
  # resubscribe just succeeded again. A consumer that learned a shard's resubscribe broke
  # and never learned it recovered is only half-served — the same reasoning
  # `Core.PollingFeed`'s own `record_success/2` applies to its sibling case.
  defp clear_resubscribe_failure(state, index) do
    if MapSet.member?(state.resubscribe_failed, index) do
      symbols = state.shards |> Map.get(index, %{symbols: []}) |> Map.fetch!(:symbols)

      notice =
        Notice.new(:coverage_change, :webull,
          severity: :info,
          message:
            "shard #{index} resubscribe recovered — #{length(symbols)} symbol(s) are " <>
              "being reasserted normally again",
          details: %{shard: index, symbol_count: length(symbols)}
        )

      fan_out(state.notice_subscribers, {:dp_exchange, :webull, notice})
      %{state | resubscribe_failed: MapSet.delete(state.resubscribe_failed, index)}
    else
      state
    end
  end

  # Unexpired entries in `state.rejected` — the symbols `plan_reshard/1` must exclude from
  # this pass's effective wanted set. An expired entry is treated as no longer rejected
  # without needing to be actively pruned from the map first; see the moduledoc.
  defp active_rejections(state) do
    now = System.monotonic_time(:millisecond)

    state.rejected
    |> Enum.filter(fn {_symbol, expires_at} -> expires_at > now end)
    |> MapSet.new(fn {symbol, _expires_at} -> symbol end)
  end

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
  # `:rate_limit_blocking` rides along here too: an explicit `false` from a caller's own
  # opts overrides `state.resubscribe_opts`' defaulted `true` (Keyword.merge/2 keeps the
  # right-hand value), and a caller with no opinion leaves the default in place.
  defp replayable(opts, state) do
    Keyword.merge(
      state.resubscribe_opts,
      opts
      |> Keyword.take([
        :credentials,
        :environment,
        :limiter,
        :plug,
        :req_adapter,
        :rate_limit_blocking
      ])
      # Wrapped only if THIS call actually supplied fresh credentials — see
      # `Credentials.wrap_opt/1`'s moduledoc. A caller with no opinion here must leave
      # `state.resubscribe_opts`' already-wrapped credentials as the value `Keyword.merge/2`
      # keeps, not get them silently replaced with `nil`.
      |> Credentials.wrap_opt()
    )
  end

  defp environment(state, opts), do: Environment.resolve(Keyword.merge(state.socket_opts, opts))

  # The venue's data stream, bounded — see `Core.Fanout`. Only a subscriber under its
  # mailbox bound is sent to; one past it is skipped and reported once, in a `:degraded`
  # notice, and reported again when it catches up.
  #
  # Notices keep going through `fan_out/2` unbounded, and must: the notice saying a
  # subscriber is being dropped cannot be the first casualty of that same subscriber being
  # dropped.
  defp deliver(state, message) do
    {_sent, dropping, transitions} =
      Fanout.deliver(state.subscribers, message, state.dropping,
        max_queue_len: state.max_queue_len
      )

    Enum.each(transitions, fn transition ->
      fan_out(
        state.notice_subscribers,
        {:dp_exchange, :webull, Fanout.notice_for(transition, :webull, state.max_queue_len)}
      )
    end)

    %{state | dropping: dropping}
  end

  # The UNBOUNDED path — notices only. See `deliver/2` above for why the data stream does
  # not come through here and why notices deliberately still do.
  #
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
      case Fanout.resolve(subscriber) do
        pid when is_pid(pid) -> send(pid, message)
        nil -> :ok
      end
    end)
  end

  # Unique per shard. The venue disconnects an older connection presenting the same id.
  defp generate_session_id do
    16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
  end

  # The struct that actually arrived names its own kind — never assumed from
  # `capabilities().streamable` or from how many kinds this venue is believed to stream.
  # See `Socket`'s `emit/3` clauses: `snapshot` decodes to `Quote`, `quote` decodes to
  # `TopOfBook`, `tick` decodes to `Trade`. A struct with no clause here falls to `:error`
  # rather than picking the nearest match, so a future new kind is caught rather than
  # silently absorbed.
  defp kind_for(%Quote{}), do: {:ok, :quotes}
  defp kind_for(%TopOfBook{}), do: {:ok, :top_of_book}
  defp kind_for(%Trade{}), do: {:ok, :trades}
  defp kind_for(_other), do: :error

  defp drop_symbols_by_kind(delivering_by_kind, symbols) do
    Map.new(delivering_by_kind, fn {kind, per_symbol} -> {kind, Map.drop(per_symbol, symbols)} end)
  end

  defp take_symbols_by_kind(delivering_by_kind, symbols) do
    Map.new(delivering_by_kind, fn {kind, per_symbol} -> {kind, Map.take(per_symbol, symbols)} end)
  end
end
