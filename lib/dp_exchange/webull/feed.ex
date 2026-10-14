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

  Every subscribe asks the venue for `SNAPSHOT`, `QUOTE` and `TICK` (see `Subscription`:
  `TICK` is in the default `sub_types` again since dp_exchange_webull issue #7, although the
  venue has so far published none for us-crypto). The topics arrive separately and
  `Socket` decodes each into its own struct:
  `snapshot` becomes `Core.Types.Quote` (kind `:quotes`, a traded price), `quote`
  becomes `Core.Types.TopOfBook` (kind `:top_of_book`, bid/ask), `tick` becomes
  `Core.Types.Trade` (kind `:trades`, one print). `coverage/1` folds every kind into one
  `:stream` per symbol, so a symbol whose `snapshot` topic goes dark while its `quote`
  topic keeps arriving — or any other combination — is invisible there;
  `coverage_by_kind/1` exists to split exactly that apart, one kind map per struct type
  actually observed. `kind_for/1` derives the kind from the struct that arrived rather
  than assuming it, so a future new kind reaching this clause without a matching case
  here is caught (logged, loudly) instead of silently folded into an existing kind.

  **`:trades` is delivered but never counted here.** `capabilities().streamable` does not
  declare `:trades` (the venue publishes no `TICK` for us-crypto, measured twice — see
  `Subscription`), and Core's `coverage_by_kind/1` contract is that every reported key is a
  declared kind, with `coverage/1` the exact union of them. A `Trade` that does arrive is
  still delivered to subscribers, but `record_quote/3` records no coverage for it: counting
  it would either break that invariant or declare a capability nobody measured. It moves
  into coverage together with the declaration, when a run shows ticks arriving.

  ## A reconcile that fails leaves its shard dirty, not believed-subscribed

  `touch_primary_shard/7` and `touch_background_shard/5` record the shard's NEW symbol list
  before the HTTP reconcile has answered. Found 2026-10-10 by reading the path: when that
  reconcile failed for any reason that does not tear the shard down (a transport error, a
  `:reconcile_timeout`, `:reconcile_pending`, a 429, `:oversubscribed`, `INVALID_SYMBOL`) the
  list was never put back, so a retry diffed the wanted set against a shard that already
  "had" it, found nothing to send and answered `:ok` while the symbol stayed unsubscribed.
  The failure now reverts the delta (`added` leaves the shard's list, `removed` returns to
  it) and records the shard in `state.unsettled`, which makes the 60-second tick re-plan it
  even when nobody calls. `reconcile_by_session/4` also attempts the subscribe when the
  unsubscribe half failed, so one failing half no longer cancels the other.

  A result is only ever applied to the session it was asked of. The context travels with
  the attempt (`state.settled`) and an answer from a session the shard has since replaced is
  dropped: an `INVALID_SESSION` or `:oversubscribed` measured against a dead session says
  nothing about its healthy successor and used to tear it down or cap it.

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

  ## A caller parked on a connecting shard is always answered

  A `subscribe/2`, `unsubscribe/2` or `update_symbols/2` whose symbols land on a shard that
  is not yet connected waits for that shard's `link_up` (`shard.reply_to`). Two things
  could leave such a caller unanswered until its `@call_timeout` ran out, at which point it
  EXITED and took its own process down:

  - Only the branch that OPENS a shard armed a `:connack_timeout`. A caller that arrived
    while an existing shard was reconnecting parked with no timer at all, and
    `Socket.handle_disconnect/2` backs off for up to 30s, twice `@call_timeout`.
  - `reply_to` held ONE caller, and a second caller parking on the same shard overwrote
    the first, who then got no answer from anything.

  `reply_to` is now a list, and every path that answers a parked caller answers all of
  them, each with its own capacity overflow. Every park arms its own `:connack_timeout`,
  so no caller waits past `@connack_timeout_ms`, two thirds of `@call_timeout`.

  ## A caller waiting on a reconcile is answered before its call times out

  On a shard that is already connected, `subscribe/2`, `unsubscribe/2` and
  `update_symbols/2` wait for the HTTP subscribe their call started (a `:primary`
  reconcile). That reconcile is allowed `@reconcile_timeout_ms` (60s), because
  `Core.HttpClient` retries inside it. The caller's own `GenServer.call` gives up at
  `@call_timeout` (15s), so a slow venue made the caller EXIT and take its process down.
  The comment on `@reconcile_timeout_ms` said as much ("a reconcile that outlives the
  caller waiting on it has already lost that caller") and left it there.

  Each call arms ONE `{:caller_due, from}` when it arrives (`reshard/3`), at
  `@connack_timeout_ms`, the same two-thirds-of-`@call_timeout` budget a parked caller gets.
  If the caller is still unanswered then, it is answered: `{:error, {:reconcile_pending, ms}}`
  when it rides a primary reconcile, `{:error, {:connack_timeout, ms}}` when it is parked on a
  shard (and it is removed from that shard's `reply_to`). The work carries on and its result
  is applied. Its own later reply to that `from` is dropped by `gen`, because the call has
  already returned.

  The timer is keyed by `from`, not by shard index and not per reconcile. It used to be armed
  for each primary reconcile and matched on the index, so an `:oversubscribed` or
  `INVALID_SYMBOL` retry that moved the primary to another index, or parked the caller on a
  connecting shard, left it matching nothing, and the timers armed by the retry could fall
  after the caller's own `@call_timeout`.

  ## A subscribed, connected session can still go quiet on its own

  Not a reconnect, not an error, not an unsubscribe — the venue simply stops pushing to
  an otherwise-healthy session shortly after each subscribe, with nothing on the wire to
  say so. `dp_crypto_management`'s own pre-existing MQTT client found this the hard way,
  empirically: a blind, unconditional resubscribe on a timer, independent of whether the
  wanted set had changed, took its live coverage from 47 symbols back to ~240
  (DpCryptoManagement's issue #17). `reshard/3` alone cannot recover from this — it only
  touches a shard whose *wanted* symbol set changed, and re-asking for exactly what is
  already wanted computes an empty diff and asserts nothing.

  So every connected shard's current subscription is re-issued unconditionally every
  `@resubscribe_interval_ms`, regardless of whether anything is believed to have
  changed — the same shape Coinbase's `Feed` already carries for its own reconnect case,
  applied here to a steady-state failure mode Coinbase does not have.

  ## One tick, one attempt

  That unconditional re-issue is the only recovery this venue has for a session it has
  silently stopped publishing to, and for a long time it could not complete once a shard
  actually needed it. `@reconcile_timeout_ms` and `@resubscribe_interval_ms` are both
  60,000, and `handle_info(:resubscribe, _)` re-arms its own timer BEFORE spawning, so at
  every tick boundary the tick was enqueued ahead of the deadline armed during the previous
  one. The tick overwrote `reconciling[{:resubscribe, index}]` with a fresh task; the
  previous deadline then arrived, found that successor under the tag it had been armed for,
  and killed it milliseconds old. Issue #3 measured the consequence over a 2h04m boot: 449
  reconcile timeouts — against 496 ticks that a four-shard, 60-second interval predicts, so
  very nearly all of them — producing 12 recoveries.

  Two changes, because it was two defects wearing one symptom. A tick whose previous attempt
  is still running is now SKIPPED rather than stacked on top of it: a second identical
  subscribe for a session the venue has not answered for yet is load, not a safety net, and
  `validate_resubscribe_interval_ms!/1` already refuses a configured interval under a second
  in those words. And a deadline now names the ATTEMPT, not merely the tag it ran under, so
  a timer can only ever tear down the attempt it was armed for — see `spawn_reconcile/3`.

  A tag is not an identity. Every blind resubscribe for shard 2 runs under
  `{:resubscribe, 2}`, and anything keyed only by the tag — a deadline, a monitor, a reply —
  is keyed to the SLOT rather than to the thing occupying it. So an attempt mints a token of
  its own, and BOTH of the things that conclude one carry it: its deadline and its answer.
  The answer needs it as much as the deadline does, because killing a superseded attempt
  cannot recall a result it has already put in the mailbox.

  `Core.PollingFeed` had already answered the first half of this and said why:
  rescheduling happens in its `finish/3` and nowhere else, "which is what bounds the queue —
  a symbol cannot have a second tick pending until its first has finished". This module
  re-arms at the TOP of `handle_info(:resubscribe, _)` instead, which is the opposite, and
  the two other venues that carry a resubscribe timer are immune only because their re-issue
  is a synchronous socket send inside the callback rather than an async HTTP call. This feed
  is the only one in the family whose periodic re-assert is a task tracked by a reusable key
  with a deadline on it, which is why the defect landed here and nowhere else. Re-arming at
  the top is kept — the timer must survive a crash in the body — and the in-flight skip in
  `resubscribe_quiet_shards/1` is what supplies the bound instead.

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

  Latched **per shard**, not globally — `state.resubscribe_failed`, a map from shard index to
  that shard's count of consecutive failures — because each shard is its own independent MQTT
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
  one that failed — the opposite of the isolation `reshard/3`, `resync/1` and the
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

  `state.rejected` is pruned of expired entries on the resubscribe tick, after the re-plan
  that returns them to a shard. `active_rejections/1` always ignored an expired entry, but
  nothing removed it, so the map only grew.

  ## A symbol list that cannot be used is refused, not crashed on

  `subscribe/3`, `unsubscribe/3` and `update_symbols/3` take a list of non-empty strings and
  answer `{:error, {:invalid_symbols, symbols}}` (the argument exactly as given) before any
  state moves. This is one named process for every caller, and a
  raise inside `handle_call/3` restarted it from its static options with everyone's symbols
  gone. The facade has long returned the same tuple when the VENUE refused a symbol, which is
  what a caller who matches on it wants either way. `DpExchange.Webull.Fake` answers alike.

  ## A shard that is not connected is never sent an HTTP call by a re-plan

  A re-plan that changes a shard other than the one a caller is waiting on used to send its
  subscribe or unsubscribe at once, whatever that shard was doing. For a shard still
  connecting, or reconnecting after a drop (the socket backs off for up to 30s), the session
  was not registered with the venue; the answer was `INVALID_SESSION`, which this module takes
  to mean the session is dead, and the shard was torn down and reopened on a fresh session.
  `touch_background_shard/5` now records the new list and sends nothing, as
  `touch_primary_shard/7` always did: `on_link_up/2` replays the whole list on the CONNACK.
  The deferred `{:reconcile_shard, ...}` message re-checks the session and `connected?` when
  it runs, for the same reason.

  ## An unsubscribe that races a whole-list subscribe is sent again

  A blind resubscribe and a link-up replay send the shard's list as it stood when they were
  spawned. An `unsubscribe/3` that completes while one is in flight can be overtaken at the
  venue by the older, larger subscribe, leaving a symbol subscribed that nothing here tracks
  and nothing will ever diff: it holds one of the session's 100 slots and can make a later
  `TOO_MANY_SYMBOLS` cap the shard too low. When such an attempt answers `:ok`, whatever it
  sent that the shard no longer carries is unsubscribed once more (`unsubscribe_stale/4`).

  ## Shard assignment is sticky, not recomputed from scratch

  A symbol already assigned to a shard keeps that shard for as long as it stays wanted,
  even as other symbols are added or removed. Deriving shards by sorting the *entire*
  wanted set and cutting it into fixed-size chunks — the original approach — meant one
  newly-added symbol that happened to sort early could shift every symbol after it across
  every shard boundary, so an unrelated add unsubscribed and resubscribed symbols that were
  already healthy. `derive_shards/3` instead starts from what each shard already carries,
  drops only what stopped being wanted or no longer fits that shard's measured capacity,
  and places everything else — new symbols, and anything just evicted by a capacity
  reduction — into whichever shard (in index order) still has room. `reshard_step/4`'s
  `touched` computation is what actually limits HTTP calls to changed shards; this is what
  makes that set small in the first place.
  """

  use GenServer

  alias DpExchange.Core.{Config, Fanout, Notice}
  alias DpExchange.Core.Types.{Quote, TopOfBook, Trade}
  alias DpExchange.Webull.{Credentials, Environment, Socket, Subscription}

  require Logger

  @frame_window_ms 5_000
  @call_timeout @frame_window_ms * 3

  # How long a shard may sit connected-but-unacknowledged before a caller parked on it is
  # answered.
  #
  # Bounded against `@call_timeout` rather than picked: a caller that gives up at
  # `@call_timeout` is gone, so a deadline at or past that answers nobody. Two thirds leaves
  # room for the reply to land while the caller is still there, and is still far longer than
  # a CONNACK takes on a venue that is answering at all.
  @connack_timeout_ms div(@call_timeout * 2, 3)

  # How long a control-plane reconcile may run before this feed stops waiting for it.
  #
  # The task body is a `Subscription.subscribe/unsubscribe` HTTP round trip through
  # `Core.HttpClient`, which carries its own per-attempt timeout and retries — so this is the
  # outer bound for a task that has stopped answering entirely, not a second, tighter
  # deadline on a healthy one. Set above `@call_timeout`, because a reconcile that outlives
  # the caller waiting on it has already lost that caller; firing sooner would only replace
  # one lost reply with another while the request was still in flight.
  @reconcile_timeout_ms @call_timeout * 4

  # The venue's own stated ceiling. See the moduledoc and the design doc §3.1 — not a
  # padded-down guess.
  @pairs_per_socket 100

  # "Each App Key supports a maximum of 5 concurrent connections" —
  # docs/reference/webull/streaming-api.md.
  @max_shards 5

  # The shard `priority_symbols:` are planned into — see `derive_shards/4` and
  # `resubscribe_quiet_shards/1`.
  @priority_shard 0

  # Between opening each shard's socket, when one call touches more than one newly-
  # opening shard. A connect burst is answered with resets — same reasoning as
  # Coinbase's Feed, not a Webull-specific measurement.
  @shard_spacing_ms 5_000

  # Re-issue every connected shard's current subscriptions on this cadence,
  # unconditionally — see the moduledoc. Same interval, same reasoning as Coinbase's
  # Feed for the reconnect case; here it is load-bearing for a case Coinbase does not
  # have — see DpCryptoManagement's issue #17.
  @resubscribe_interval_ms 60_000

  # How long to wait before trying again to OPEN a shard whose socket refused to open, and
  # the ceiling that backoff climbs to. Issue #4.
  #
  # A shard that never opened is a different state from a shard that went quiet, and only
  # the second was being watched. `handle_info(:resubscribe, _)` reduces over
  # `state.shards`, and a failed open never put an entry there — so its symbols were
  # orphaned with nothing in the system that would ever revisit them. Reported from a real
  # boot: three of four shards timed out their handshake under load average 54, and stayed
  # dark for 28 minutes across 0 reopen attempts until the node was restarted. The delivery
  # gate that correctly stopped the over-eager reopens of issue #1 cannot help here —
  # **"never worked" is not "stopped working"**, and a shard with no delivery history has no
  # last-delivery instant to age.
  #
  # Backed off rather than retried on a fixed tick because the two failure causes want
  # opposite cadences: a transient handshake timeout on a loaded host clears in seconds, and
  # a venue genuinely refusing connections must not be hammered. Doubling from one second to
  # a minute reaches the first quickly and settles at the second's own resubscribe cadence.
  @open_retry_base_ms 1_000
  @open_retry_max_ms 60_000

  # How soon after a shard's previous crash a new one counts as the SAME run of crashes.
  # Found 2026-10-10 by reading `isolate_crashed_shard/3`: a crashed shard was reopened with
  # a `send(self(), ...)`, no delay and no limit, so a socket that connected and died at
  # once was rebuilt in a tight loop, each turn claiming a fresh session against the venue's
  # five-connections-per-key ceiling. The first crash still reopens at once (the common
  # case is a one-off); a crash within this window of the last one waits
  # `open_retry_base_ms * 2^(n-2)`, capped at `open_retry_max_ms` — the same ladder a failed
  # open already climbs. A shard that stayed up longer than this starts over.
  @crash_window_ms 60_000

  # How many consecutive blind resubscribes one shard may fail before this `Feed` stops
  # repeating the identical call and reopens that shard's socket instead. See
  # `count_resubscribe_failure/2` for the incident (dp-exchange-webull issue #1) and why the
  # escalation reuses `rebuild_stale_shard/3` rather than adding a second recovery path.
  #
  # **Twelve is measured, not picked.** In the reported incident the three shards that
  # self-healed did so after 8, 10 and 10 consecutive failures. A limit at or below ten would
  # have torn down sockets that were about to recover on their own, and every teardown claims
  # a fresh session against the venue's per-account ceiling — the very contention
  # (`Permission grabbed by other session`) that started that incident. That reading of
  # the grab as CONTENTION is wrong in its direction, though not in its arithmetic: the
  # notice tracks a re-subscribe of ours COMPLETING, so a teardown does produce one, and it
  # is not evidence of anything taking the category away. See
  # `validate_resubscribe_interval_ms!/1` for the measurement that settled it. Twelve clears the
  # observed self-heal window with margin while bounding the stuck case to roughly twelve
  # minutes at `@resubscribe_interval_ms` instead of forever.
  #
  # Overridable, because one incident is one sample.
  @resubscribe_failure_limit 12

  # How long a shard must have delivered NOTHING before a reopen is allowed to consider it
  # stale. See `shard_delivering?/2` for the field result that made this gate necessary: the
  # failure-count escalation alone reopened sockets that were still streaming and cost 29% of
  # this venue's coverage.
  #
  # Five minutes, against a `@resubscribe_interval_ms` of one minute, so the shard must be
  # silent across five whole resubscribe cycles. That is deliberately long. A shard carries on
  # the order of a hundred symbols, and the question is not "has this symbol been quiet" — an
  # illiquid pair can easily go minutes without a print — but "has EVERY symbol on this shard
  # been quiet at once", which a live shard does not do. Erring long costs a few more minutes
  # of a stale subscription set; erring short costs live data, which is the mistake already
  # made here once.
  @stale_delivery_ms 300_000

  # See the moduledoc's "A venue-rejected symbol is excluded, timed, and reported" —
  # deliberately the same order of magnitude as
  # `DpCryptoManagement.Data.Collection.VenueRefusals`' own 24h TTL for exactly this shape
  # of fact (a venue catalogue is true at a point in time, not permanently). Overridable via
  # `opts[:rejected_symbol_ttl_ms]`.
  @rejected_symbol_ttl_ms 24 * 60 * 60 * 1000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    # Wrapped (idempotently) before the options reach OTP: a crash report or a child spec
    # prints the start arguments, and raw credentials in them print `app_secret`. The
    # supervisor wraps too; this covers a `Feed` started directly.
    opts = Credentials.wrap_opt(opts)
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec subscribe(GenServer.server(), [String.t()], keyword()) :: :ok | {:error, term()}
  def subscribe(feed, symbols, opts) do
    GenServer.call(
      feed,
      {:subscribe, symbols, Config.opt(opts, :to, self()), opts},
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

  @doc """
  The symbols the consumer asked this feed to stream, sorted; not what is arriving
  (`coverage/1`). A symbol stays here while it is wanted, delivering or not.
  """
  @spec wanted(GenServer.server()) :: [String.t()]
  def wanted(feed), do: GenServer.call(feed, :wanted, @call_timeout)

  @spec coverage_by_kind(GenServer.server()) :: %{
          DpExchange.Core.Capabilities.data_kind() => %{
            String.t() => :stream | :internal_poll | :not_covered
          }
        }
  def coverage_by_kind(feed), do: GenServer.call(feed, :coverage_by_kind, @call_timeout)

  # `@call_timeout`, not `GenServer.call/2`'s five-second default.
  #
  # This was the one public call in this module left on the default, and it is the worst one
  # to leave short. `@call_timeout` is the authors' own statement of how long this feed may
  # legitimately take to answer, and every sibling call — `subscribe/3`, `unsubscribe/2`,
  # `update_symbols/2`, `coverage/1` — is allowed it on the same mailbox. A consumer
  # registers for notices at start-up, which is precisely when that mailbox is deepest: the
  # transport is coming up, symbols are being resolved, and this handler itself may replay a
  # notice to the newly-registered subscriber.
  #
  # A `GenServer.call/3` timeout exits in the CALLER, not in the feed. So the channel a host
  # uses to *hear that something is wrong* was the one call that could kill the host's
  # calling process for asking during exactly the conditions it exists to report.
  @spec subscribe_notices(GenServer.server(), keyword()) :: :ok | {:error, term()}
  def subscribe_notices(feed, opts),
    do: GenServer.call(feed, {:subscribe_notices, Config.opt(opts, :to, self())}, @call_timeout)

  @doc """
  Whether `to` can name a subscriber: a pid or a registered name (an atom).

  Anything else is `{:error, {:invalid_subscriber, to}}`. `Core.Fanout.resolve/1` has a
  clause for a pid and one for an atom and no other, so a subscriber such as a string or a
  `{:global, name}` tuple that reached `subscribers` raised `FunctionClauseError` inside this
  one named process on the first delivery, and the restart that followed dropped every other
  consumer's subscriptions with it. `subscribe/3` and `subscribe_notices/2` refuse it here
  instead, and `DpExchange.Webull.Fake` calls the same function so the two cannot drift.
  """
  @spec check_subscriber(term()) :: :ok | {:error, {:invalid_subscriber, term()}}
  def check_subscriber(subscriber) when is_boolean(subscriber),
    do: {:error, {:invalid_subscriber, subscriber}}

  def check_subscriber(subscriber) when is_pid(subscriber) or is_atom(subscriber), do: :ok
  def check_subscriber(other), do: {:error, {:invalid_subscriber, other}}

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
       # In-flight control-plane reconciles, keyed by their `tag`: `%{ref:, pid:}`. Exists so
       # a task that dies or hangs can still answer whatever is waiting on it — `tag` carries
       # the caller's `from` on the primary path, and `Task.Supervisor.start_child/2` neither
       # links nor monitors, so without this a lost task strands that caller for the whole of
       # `@call_timeout` and then exits it.
       reconciling: %{},
       # See `@connack_timeout_ms`. Overridable so a test proving it fires need not wait.
       connack_timeout_ms: Keyword.get(opts, :connack_timeout_ms) || @connack_timeout_ms,
       # See `@reconcile_timeout_ms`. Overridable so a test proving the timeout fires need
       # not wait out the real one.
       reconcile_timeout_ms: Keyword.get(opts, :reconcile_timeout_ms) || @reconcile_timeout_ms,
       # See `@resubscribe_failure_limit`. Overridable so a test proving the escalation fires
       # need not drive twelve real resubscribe ticks, and so an operator with a different
       # tolerance than the one incident behind that number can set their own.
       resubscribe_failure_limit:
         Keyword.get(opts, :resubscribe_failure_limit) || @resubscribe_failure_limit,
       # See `@stale_delivery_ms`. Overridable so a test proving the delivery gate need not
       # wait out five real minutes of silence.
       stale_delivery_ms: Keyword.get(opts, :stale_delivery_ms) || @stale_delivery_ms,
       # See `@priority_shard`. Symbols to plan into one shard that keeps the stream.
       priority: priority_symbols(opts),
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
       # Monitor references for pid subscribers, so a dead one is dropped rather than walked
       # on every message for the life of this feed — see the `:DOWN` clause and
       # `Core.Fanout.watch/2`. A registered-name subscriber never appears here.
       monitors: %{},
       # Back-pressure, per `Core.Venue`'s `subscribe/2` doc and implemented by
       # `Core.Fanout`: `dropping` is the set of subscribers currently over their mailbox
       # bound, carried across calls so a stalled consumer produces one `:degraded` notice
       # when delivery to it stops and one when it resumes — never one per dropped message,
       # which would arrive at the rate of the stream it already cannot keep up with.
       dropping: MapSet.new(),
       max_queue_len: Fanout.max_queue_len!(opts, :webull),
       wanted: MapSet.new(),
       delivering: %{},
       # shard index => epoch ms its last rotation turn was granted. See
       # `resubscribe_quiet_shards/1`: a turn counts as recent activity, so a shard whose
       # symbols never tick does not win every rotation on a `last_delivery` of zero.
       rotated_at: %{},
       # kind() => %{symbol => timestamp}, built alongside `delivering` above from the
       # same arriving payloads — never from `wanted` or from what was subscribed. See
       # the moduledoc's "Coverage by kind" and `kind_for/1`.
       delivering_by_kind: %{},
       # index => %{session_id:, socket:, connected?:, symbols:, reply_to:}, where `reply_to`
       # is `nil` or the list of callers parked on this shard. `symbols` is
       # what this shard is meant to carry as of the last reshard, independent of whether
       # the HTTP call that asks the venue for it has actually gone out yet. `reply_to`
       # is set only while this shard is the primary of a call still waiting on this
       # shard's own CONNACK — see handle_call({:subscribe, ...}) and on_link_up/2.
       #
       # An init option, not just internal state, for the same reason Coinbase's Feed
       # accepts an `injected_socket` — a test standing up an already-connected shard
       # needs to say so without driving a real MQTT handshake to get there.
       shards: Config.opt(opts, :shards, %{}),
       # index => capacity, present only once a shard has been measured (by the venue's
       # own refusal) to hold fewer than @pairs_per_socket. Absent means the venue's
       # stated ceiling applies unmodified. See handle_subscribe_result/3. Also an init
       # option, so a test can exercise rebalancing without needing @pairs_per_socket
       # real symbols to do it.
       shard_capacity: Config.opt(opts, :shard_capacity, %{}),
       # symbol => expiry (`System.monotonic_time(:millisecond)`). Excluded from
       # `plan_reshard/1`'s effective wanted set while unexpired — see the moduledoc's "A
       # venue-rejected symbol is excluded, timed, and reported". Never removed from
       # `state.wanted` itself; `active_rejections/1` is what makes the exclusion time-bound.
       rejected: %{},
       rejected_symbol_ttl_ms: Config.opt(opts, :rejected_symbol_ttl_ms, @rejected_symbol_ttl_ms),
       # Shard indices currently latched into a generic blind-resubscribe failure — see the
       # moduledoc's "A generic resubscribe failure is reported too, latched per shard".
       # A top-level set rather than a field on each shard's own map: `isolate_crashed_shard/3`
       # deletes and rebuilds a shard's entry wholesale on a crash, and this latch's own
       # lifecycle is deliberately independent of that — see the comment there.
       resubscribe_failed: %{},
       # Shard indices whose socket failed to OPEN and are being retried — issue #4. Kept
       # apart from `resubscribe_failed` above: "never opened" and "opened but its blind
       # resubscribe is failing" are different conditions with different recoveries, and one
       # latch for both would let either one's recovery notice clear the other.
       open_failed: MapSet.new(),
       # tag => the context an in-flight reconcile was started with, moved here by
       # `forget_reconcile/2` when the attempt concludes and popped by whichever
       # `{:reconcile_done, ...}` clause settles it. See the moduledoc's "A reconcile that
       # fails leaves its shard dirty".
       settled: %{},
       # from => timer reference of the `{:caller_due, from}` deadline `reshard/3` armed, held
       # until the caller is answered and cancelled then. See `reply_caller/3`.
       caller_timers: %{},
       # index => token of the one live open-retry chain for that slot. See the
       # `{:reopen_shard, ...}` clauses.
       open_chains: %{},
       # Shard indices whose last primary/background reconcile failed and was reverted, so
       # the next `:resubscribe` tick re-plans them even with no caller and no rejection.
       unsettled: MapSet.new(),
       # index => %{count:, at:} of consecutive socket crashes — see `@crash_window_ms`.
       crashes: %{},
       # index => {token, timer_ref} of the one delayed reopen pending for that slot. See
       # `reopen_with_backoff/4`.
       reopen_timers: %{},
       # Overridable for the same reason every other cadence here is: a test proving the
       # retry actually recurs should not have to wait out a real second to see it.
       open_retry_base_ms: Config.opt(opts, :open_retry_base_ms, @open_retry_base_ms),
       open_retry_max_ms: Config.opt(opts, :open_retry_max_ms, @open_retry_max_ms),
       # See `@shard_spacing_ms`. Overridable so a test proving the stagger need not wait
       # out several real five-second gaps.
       shard_spacing_ms: Config.opt(opts, :shard_spacing_ms, @shard_spacing_ms),
       # Monotonic ms of the last background (staggered) open; see `{:open_staggered, ...}`.
       last_background_open: nil
     }}
  end

  @impl true
  def handle_call({:subscribe, symbols, subscriber, opts}, from, state) do
    with :ok <- check_symbols(symbols),
         :ok <- check_subscriber(subscriber) do
      apply_subscribe(symbols, subscriber, opts, from, state)
    else
      {:error, _reason} = refused -> {:reply, refused, state}
    end
  end

  def handle_call({:unsubscribe, symbols, opts}, from, state) do
    case check_symbols(symbols) do
      :ok -> apply_unsubscribe(symbols, opts, from, state)
      {:error, _reason} = refused -> {:reply, refused, state}
    end
  end

  def handle_call({:update_symbols, symbols, opts}, from, state) do
    case check_symbols(symbols) do
      :ok -> apply_update(symbols, opts, from, state)
      {:error, _reason} = refused -> {:reply, refused, state}
    end
  end

  def handle_call(:coverage, _from, state) do
    {:reply, Map.new(state.delivering, fn {symbol, _at} -> {symbol, :stream} end), state}
  end

  def handle_call(:wanted, _from, state) do
    {:reply, state.wanted |> MapSet.to_list() |> Enum.sort(), state}
  end

  def handle_call(:coverage_by_kind, _from, state) do
    by_kind =
      Map.new(state.delivering_by_kind, fn {kind, per_symbol} ->
        {kind, Map.new(per_symbol, fn {symbol, _at} -> {symbol, :stream} end)}
      end)

    {:reply, by_kind, state}
  end

  def handle_call({:subscribe_notices, subscriber}, _from, state) do
    case check_subscriber(subscriber) do
      :ok ->
        state = %{
          state
          | notice_subscribers: MapSet.put(state.notice_subscribers, subscriber),
            monitors: Fanout.watch(subscriber, state.monitors)
        }

        {:reply, :ok, state}

      {:error, _reason} = refused ->
        {:reply, refused, state}
    end
  end

  def handle_call(_other, _from, state), do: {:reply, {:error, :unknown_call}, state}

  # **A symbol list that cannot be used is refused before any state moves.** This Feed is one
  # named process for every caller of the instance. `MapSet.new/1` on a non-list raises, and so
  # do `Map.drop/2` and `Map.take/2`, so one `subscribe(nil)` or `update_symbols("BTC-USD")`
  # raised inside `handle_call/3`: the Feed crashed, its supervisor restarted it from the
  # static options, and every symbol every caller had subscribed was gone, with `coverage/1`
  # reading empty until each of them subscribed again. A non-binary element was worse in a
  # quieter way: it entered `state.wanted`, was planned into a shard, and then raised inside
  # every reconcile task that tried to send it, so the shard it landed on never settled. An
  # empty string is refused as well: it is not a product and would be sent to the venue as one.
  #
  # The same shape `{:error, {:invalid_symbols, ...}}` that `Subscription` uses for a symbol the
  # VENUE refused, because to a caller both mean "these symbols were not accepted"; the facade
  # has always returned it from `subscribe/2` either way. At most five offenders are named.
  #
  # Public so the facade can refuse in the CALLER, before `{:error, :feed_not_started}`: a
  # malformed list answers the same whether or not the feed runs. `Fake` calls it too.
  @doc """
  Whether `symbols` is a proper list of non-blank strings (blank means empty or only
  whitespace after trimming). Anything else is `{:error, {:invalid_symbols, symbols}}` where
  the value is the caller's WHOLE argument exactly as given (the family convention, Core's
  assertion 32): a list with a bad element comes back as that list, an improper list as itself,
  and a non-list as itself.
  """
  @spec check_symbols(term()) :: :ok | {:error, {:invalid_symbols, term()}}
  def check_symbols(symbols) when is_list(symbols) do
    case invalid_symbols(symbols, []) do
      [] -> :ok
      _invalid -> {:error, {:invalid_symbols, symbols}}
    end
  end

  def check_symbols(other), do: {:error, {:invalid_symbols, other}}

  # Walks by hand so an improper list (`[1 | 2]`) is an offender and not a raise inside this
  # one named process, which `Enum.reject/2` on it would be. The improper tail is itself
  # reported, as the single offender that it is.
  defp invalid_symbols([symbol | rest], acc) do
    if is_binary(symbol) and String.trim(symbol) != "",
      do: invalid_symbols(rest, acc),
      else: invalid_symbols(rest, [symbol | acc])
  end

  defp invalid_symbols([], acc), do: acc
  defp invalid_symbols(improper_tail, acc), do: [improper_tail | acc]

  defp apply_subscribe(symbols, subscriber, opts, from, state) do
    # Wrapped before `opts` goes anywhere: it is captured by in-flight reconcile tags, by
    # `{:open_shard, ...}` messages and by the closures of every task, all of which sit in
    # `state` or the mailbox where a crash report prints them. Found 2026-10-10: only
    # `resubscribe_opts` was wrapped, so `app_secret` was readable in the rest. See
    # `Credentials`. Idempotent for the facade, which wraps too.
    opts = Credentials.wrap_opt(opts)

    if Environment.streaming?(environment(state, opts)) do
      wanted = MapSet.union(state.wanted, MapSet.new(symbols))

      state = %{
        state
        | subscribers: MapSet.put(state.subscribers, subscriber),
          monitors: Fanout.watch(subscriber, state.monitors),
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

  defp apply_unsubscribe(symbols, opts, from, state) do
    opts = Credentials.wrap_opt(opts)
    wanted = MapSet.difference(state.wanted, MapSet.new(symbols))

    state = %{
      state
      | wanted: wanted,
        delivering: Map.drop(state.delivering, symbols),
        delivering_by_kind: drop_symbols_by_kind(state.delivering_by_kind, symbols)
    }

    reshard(state, opts, from)
  end

  defp apply_update(symbols, opts, from, state) do
    opts = Credentials.wrap_opt(opts)
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

  # A subscriber that died. Dropped from both sets, and its monitor forgotten.
  #
  # Without this, nothing ever removed a subscriber pid: `Core.Fanout.resolve/1` skips a dead
  # one at send time, so no EVENTS accumulated — which is what the contract asks for and was
  # true — but the pid stayed for the life of this feed. A supervised consumer that restarts
  # leaves one behind on every restart, and `deliver/4` walks the whole set calling
  # `Process.alive?/1` once per message, so the cost is linear in how long the feed has been
  # up. Measured in Core 0.3.3: 0.095 us per fan-out against a clean set, 22.8 us against one
  # carrying a thousand dead pids.
  #
  # Only pids arrive here. A registered-name subscriber is deliberately never monitored — see
  # `Core.Fanout.watch/2` — because a name outlives the process holding it, and pruning on
  # its holder's death would silently unsubscribe a consumer its supervisor is about to
  # restart under the same name.
  # One `:DOWN` clause serving two unrelated monitors, because Elixir takes the first
  # matching clause and there is no falling through from one to the next. The ref decides
  # which: a reconcile task this feed is tracking, or a subscriber it is watching.
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case reconcile_tag_for(state, ref) do
      nil ->
        drop_dead_subscriber(state, pid)

      tag ->
        # The reconcile task died without answering. Synthesised into the ordinary
        # `{:reconcile_done, tag, {:error, _}}` shape and re-dispatched, so every caller and
        # every retry ladder below is answered exactly as it would be for a reconcile that
        # failed by replying. A task that failed by dying is not a different KIND of failure,
        # and giving it its own path is how the two drift.
        #
        # Without this, `tag` — which carries the caller's `from` on the primary path — is
        # simply lost: the caller waits out `@call_timeout` and then EXITS, taking the
        # calling process with it. `Task.Supervisor.start_child/2` gives a child that is
        # neither linked nor monitored, so nothing here learned of the death at all.
        handle_info(
          {:reconcile_done, tag, {:error, {:reconcile_task_down, reason}}},
          forget_reconcile(state, tag)
        )
    end
  end

  # A caller's own deadline, armed once by `reshard/3` when its call arrives and keyed by its
  # `from`, so it holds wherever the call has got to. If the caller is still unanswered it is
  # answered now, and the work carries on: its result is applied when it lands, and its own
  # later reply to this `from` finds a call that has already returned. `gen` drops a reply to
  # a completed call's alias, so it reaches no mailbox. See the moduledoc's "A caller waiting
  # on a reconcile is answered before its call times out".
  def handle_info({:caller_due, from}, state), do: {:noreply, answer_overdue_caller(state, from)}

  # A reconcile task that is still alive and has stopped answering. No `:DOWN` can catch
  # that, and only a timer tells it apart from one about to succeed. A timer for a tag that
  # already answered finds nothing tracked and is ignored, so a slow-but-successful reconcile
  # is never torn down by its own deadline arriving late.
  def handle_info({:reconcile_timeout, tag, attempt}, state) do
    case Map.fetch(state.reconciling, tag) do
      {:ok, %{pid: pid, attempt: ^attempt}} ->
        stop_reconcile_task(pid)

        # `:no_venue_response` is the third element, and it is a statement of fact rather
        # than a guess: this clause runs only because the deadline arrived with no answer, so
        # what is known is precisely that nothing came back — not that the venue refused.
        #
        # dp-exchange-webull issue #1 asked for the distinction because the two cases call
        # for opposite actions: a venue refusing because another session holds the permission
        # must be waited out (reconnecting claims another session against the same ceiling),
        # while a wedged socket of our own must be reconnected. A venue that answers with a
        # refusal reaches a caller as that refusal and never as this tuple; this shape says
        # which of the two a caller is looking at without either being inferred.
        handle_info(
          {:reconcile_done, tag,
           {:error, {:reconcile_timeout, state.reconcile_timeout_ms, :no_venue_response}}},
          forget_reconcile(state, tag)
        )

      # Nothing tracked under this tag, or something tracked that this timer was not armed
      # for. Both are ordinary: the first is a reconcile that already answered, the second
      # an attempt superseded by a newer one, which now carries its own deadline.
      _answered_or_superseded ->
        {:noreply, state}
    end
  end

  # Clears the bookkeeping for a reconcile that answered, then lets the reply fall through to
  # whichever clause below actually handles that `tag`.
  #
  # One clause rather than four: every `{:reconcile_done, ...}` clause would otherwise need
  # the same two lines, and the one somebody forgets is the one that leaks. The guard is what
  # makes the re-dispatch terminate — after `forget_reconcile/2` the tag is gone from
  # `reconciling`, so it cannot match this clause a second time.
  def handle_info({:reconcile_done, tag, _result} = message, %{reconciling: in_flight} = state)
      when is_map_key(in_flight, tag) do
    handle_info(message, forget_reconcile(state, tag))
  end

  # A task's own answer, which carries the attempt that produced it. Routed to the clause
  # above — and from there to whichever clause below handles this `tag` — only when the tag is
  # still tracking THAT attempt. Anything else is an answer to a question already settled:
  #
  #   * a different attempt tracked under the tag means this one was superseded. Tearing a
  #     superseded attempt down does not make this unreachable, because an answer already in
  #     the mailbox cannot be recalled by killing the process that sent it — the send
  #     completed before the kill did. Without this check that stale answer forgets the
  #     SUCCESSOR and is handed to the successor's callers as theirs.
  #   * nothing tracked means the tag's deadline has already fired and been reported as
  #     `:no_venue_response`, or a previous answer already settled it. A deadline that has
  #     been reported as a failure is not retracted by the answer arriving afterwards: one
  #     attempt gets one outcome, and the first one to conclude it is the one that counts.
  #
  # The synthesised `{:reconcile_done, tag, result}` that the deadline and `:DOWN` paths
  # dispatch is a 3-tuple and does not pass through here — those have already decided the
  # outcome and re-dispatch it directly.
  def handle_info({:reconcile_done, tag, attempt, result}, state) do
    case Map.fetch(state.reconciling, tag) do
      {:ok, %{attempt: ^attempt}} ->
        handle_info({:reconcile_done, tag, result}, state)

      _superseded_or_already_settled ->
        {:noreply, state}
    end
  end

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

  # The venue accepted the WebSocket and never answered the MQTT CONNECT. Matched on both
  # `index` and `session_id`, so a timer armed for one attempt cannot answer a caller parked
  # on the shard that replaced it.
  #
  # A shard that has since connected, been refused, or been rebuilt finds no match and the
  # timer is ignored — this only ever fires for a caller still waiting on the exact session it
  # was armed for.
  #
  # The socket is left alone for the same reason the refusal clause leaves it alone: the
  # connection may still come good, and what must not persist is the caller's wait.
  def handle_info({:connack_timeout, index, session_id}, state) do
    case Map.get(state.shards, index) do
      %{session_id: ^session_id, connected?: false, reply_to: [_first | _rest] = waiters} ->
        state = reply_all(state, waiters, {:error, {:connack_timeout, state.connack_timeout_ms}})
        {:noreply, put_in(state.shards[index].reply_to, nil)}

      _connected_refused_or_replaced ->
        {:noreply, state}
    end
  end

  # The venue REFUSED this shard's MQTT session. Ordered above the generic `%Notice{}` clause
  # below, which used to swallow it.
  #
  # This was the most reachable stranded caller in the package, and it needed no failure at
  # all beyond a wrong key. `subscribe/2` on a shard that is still connecting parks the caller
  # in `shard.reply_to` and waits for `on_link_up/2`. A CONNACK carrying 3, 103 or 104
  # (credentials rejected) or 105 (five concurrent connections per App Key) means that
  # `link_up` is never coming — the socket stays `connected?: false` forever — and nothing
  # here answered the caller. It waited out `@call_timeout` and then EXITED, taking the
  # calling process with it. So a consumer with a revoked App Key got a crash rather than
  # `{:error, ...}` on its very first subscribe.
  #
  # Verified by driving it: after a refused CONNACK, `reply_to` was still set and
  # `connected?` still false, with nothing left that could ever change either.
  #
  # The socket is NOT torn down here. `websockex` will reconnect it on its own schedule and a
  # later CONNACK may well succeed — a rotated key, or a concurrent session that has since
  # expired (the venue holds one about a minute). What must not persist is the caller's wait,
  # not the connection attempt.
  def handle_info({:dp_exchange, :webull, %Notice{} = notice} = message, state)
      when notice.kind in [:credentials_rejected, :degraded] do
    state = answer_refused_session(state, notice.details)

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
  #
  # **A payload for a symbol no longer wanted is dropped, not delivered or counted.** A venue
  # keeps sending for a moment after an unsubscribe, and those frames used to reach the
  # subscribers who had just asked to stop. Worse, they re-entered delivery tracking, which
  # `unsubscribe/2` had just pruned, and a streaming route has no staleness window. So one
  # late frame left `coverage/1` answering `:stream` for an unsubscribed symbol
  # indefinitely. Found 2026-09-27 by reading the path, the same shape `Core.PollingFeed`
  # had for an in-flight fetch.
  def handle_info({:dp_exchange, :webull, quote_struct} = message, state) do
    if unwanted?(quote_struct, state.wanted),
      do: {:noreply, state},
      else: record_quote(state, message, quote_struct)
  end

  # The retry arm of `{:open_shard, _, _, _}` — issue #4. Deliberately a message of its own
  # rather than a fifth element on that one: every existing sender of `:open_shard` means
  # "first attempt", and giving them all an attempt number to carry would put the retry
  # count in the hands of code that has nothing to do with retrying.
  #
  # Answers nothing if the slot has since been filled. A `reshard/3` or a `subscribe/2`
  # arriving between two attempts opens the shard by its own route, and the guard below is
  # the same one the first attempt uses.
  #
  # **The symbols in the message are what the shard carried when this was scheduled, not
  # what it should carry now.** Found 2026-10-10 by reading the path: a later re-plan that
  # also found the slot empty queued its own open, and whichever timer fired first filled
  # the slot with ITS plan-time list while the other found the slot taken and did nothing,
  # so a symbol added in between was never subscribed. `symbols_to_open/3` re-derives the
  # list from `wanted` at open time. A list that has become empty opens nothing.
  #
  # **At most one retry chain per slot.** A chain is the run of `{:reopen_shard, ..., token}`
  # messages one failed open starts; `state.open_chains[index]` holds its token. Every later
  # failure while a chain is live (another reshard's `{:open_shard, ...}` finding the slot
  # still empty, a hand-sent untokened reopen) leaves it to that chain instead of starting a
  # second, so an outage of N calls no longer ran N chains side by side, each dialling the
  # venue at its own cadence. A tokened message whose token is not the slot's current one
  # belongs to a chain that has ended (the slot opened, or filled by another route) and is
  # ignored. The untokened form is the first attempt of a chain and is always handled.
  def handle_info({:reopen_shard, index, symbols, opts, attempt}, state),
    do: {:noreply, reopen(state, index, symbols, opts, attempt, nil)}

  def handle_info({:reopen_shard, index, symbols, opts, attempt, token}, state) do
    if Map.get(state.open_chains, index) == token,
      do: {:noreply, reopen(state, index, symbols, opts, attempt, token)},
      else: {:noreply, state}
  end

  # A background open armed by `touch_background_shard/5`. Every open of a plan is armed at plan
  # time (`spacing * position`), so a Feed busy past several deadlines receives them back to
  # back and used to dial in a burst (seen under the full gate, 4 microseconds apart). The
  # spacing is therefore enforced when the message is HANDLED: an open arriving less than
  # `shard_spacing_ms` after the last background open is re-armed for the remainder. A shard
  # already open at that point needs no dial and neither waits nor counts as one.
  def handle_info({:open_staggered, index, symbols, opts} = message, state) do
    now = System.monotonic_time(:millisecond)

    cond do
      Map.has_key?(state.shards, index) ->
        {:noreply, state}

      is_integer(state.last_background_open) and
          now - state.last_background_open < state.shard_spacing_ms ->
        Process.send_after(
          self(),
          message,
          state.shard_spacing_ms - (now - state.last_background_open)
        )

        {:noreply, state}

      true ->
        handle_info({:open_shard, index, symbols, opts}, %{state | last_background_open: now})
    end
  end

  def handle_info({:open_shard, index, symbols, opts}, state) do
    case Map.get(state.shards, index) do
      nil ->
        planned = symbols_to_open(state, index, symbols)
        {:noreply, open_planned(state, index, planned, opts)}

      _already_open ->
        # A reshard already handled this index by the time the stagger elapsed (a fast-
        # follow call, or a rebalance) — nothing left to do.
        {:noreply, state}
    end
  end

  # A delayed reopen from `reopen_with_backoff/4`. Ignored unless its token is the one the
  # slot currently holds: a later teardown of the same index replaced it.
  def handle_info({:open_shard, index, symbols, opts, token}, state) do
    case Map.get(state.reopen_timers, index) do
      {^token, _timer} ->
        handle_info({:open_shard, index, symbols, opts}, %{
          state
          | reopen_timers: Map.delete(state.reopen_timers, index)
        })

      _stale_or_cancelled ->
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
    #
    # Only against the session that was planned for, and only while it is up. This message is
    # sent at plan time and handled later: the shard may have dropped in between (the delta is
    # already on `shard.symbols`, and `on_link_up/2` replays it), or been replaced by a new
    # session that replays its own full list. A request to the old session would be answered
    # INVALID_SESSION and, taken at face value, tear down a healthy replacement.
    case Map.get(state.shards, index) do
      %{session_id: ^session_id, connected?: true} = shard ->
        {:noreply,
         spawn_reconcile(
           state,
           {:background, index},
           fn -> reconcile_by_session(session_id, added, removed, opts) end,
           %{
             session_id: session_id,
             added: added,
             removed: removed,
             link: Map.get(shard, :link, 0)
           }
         )}

      _replaced_or_not_connected ->
        {:noreply, state}
    end
  end

  # This venue keeps a session's MQTT connection alive and subscribed while quietly
  # stopping publication to it — no error, no disconnect, no unsubscribe, nothing a
  # health check can see. The only recovery ever found for it is re-issuing the
  # subscription for symbols already believed subscribed, unconditionally, on a timer —
  # see the moduledoc and DpCryptoManagement's issue #17. `reshard/3` alone cannot do
  # this: it only touches a shard whose *wanted* symbol set changed, and re-asking for
  # exactly what is already wanted computes an empty diff.
  def handle_info(:resubscribe, state) do
    Process.send_after(self(), :resubscribe, state.resubscribe_interval_ms)
    state = resubscribe_quiet_shards(state)

    # A TTL-expired rejection (see the moduledoc's "A venue-rejected symbol is excluded,
    # timed, and reported") only ever returns to a shard's own symbol list through
    # `plan_reshard/1` — this ordinary blind reassert above sends exactly what a shard
    # already remembers, which no longer includes a symbol trimmed off it after a
    # rejection. Guarded on `state.rejected` being non-empty rather than run
    # unconditionally: an always-on `resync/1` here would recompute composition against
    # `state.wanted` for every shard on every tick regardless of whether this package has
    # ever recorded a rejection, which is a real behaviour change this fix has no reason
    # to make.
    #
    # Also when a reconcile failed and was reverted (`state.unsettled`): with no caller to
    # retry, nothing else would ever re-send what that failure left unsubscribed.
    state =
      if state.rejected == %{} and MapSet.size(state.unsettled) == 0,
        do: state,
        else: %{resync(state) | unsettled: MapSet.new()}

    # After the re-plan above, which is what returns an expired symbol to a shard. The entry
    # itself is dead weight from the moment it expires; see `prune_rejections/1`.
    {:noreply, prune_rejections(state)}
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
        {:reconcile_done, {:primary, index, from, overflow, retries_left, opts} = tag, result},
        state
      ) do
    {state, _rebalanced?} = settle_result(state, index, tag, result)

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
        {:noreply, reply_caller(state, from, combine_overflow(result, overflow))}
    end
  end

  def handle_info({:reconcile_done, {:background, index} = tag, result}, state) do
    {state, rebalanced?} = settle_result(state, index, tag, result)
    state = if rebalanced?, do: resync(state), else: state
    {:noreply, state}
  end

  # An answer addressed to a session the shard no longer has is not an answer about this
  # shard. `complete_link_up/3` would hand it to whoever is parked on the REPLACEMENT.
  def handle_info({:reconcile_done, {:link_up, index} = tag, result}, state) do
    {context, settled} = Map.pop(state.settled, tag)
    state = %{state | settled: settled}

    if current_session?(state, index, context) do
      state = complete_link_up(state, index, result)
      {:noreply, unsubscribe_stale(state, index, context, result)}
    else
      {state, rebalanced?} = settle_stale(state, index, result)
      {:noreply, if(rebalanced?, do: resync(state), else: state)}
    end
  end

  def handle_info({:reconcile_done, {:resubscribe, index} = tag, result}, state) do
    {context, settled} = Map.pop(state.settled, tag)
    state = %{state | settled: settled}

    # An answer to a request made on a session, or a CONNECTION of it, that the shard no
    # longer has says nothing about the shard it has now: it is neither counted as a failure of
    # this shard's resubscribe nor allowed to tear the shard down. See `on_link_up/2`.
    if current_attempt?(state, index, context, result) do
      {:noreply, settle_resubscribe(state, index, context, result)}
    else
      {state, rebalanced?} = settle_stale(state, index, result)
      {:noreply, if(rebalanced?, do: resync(state), else: state)}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp settle_resubscribe(state, index, context, result) do
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
            # Notify on the first failure, count every one, escalate at the limit. The two
            # are deliberately on different schedules — see `count_resubscribe_failure/2`.
            state
            |> latch_resubscribe_failure(index, symbols, reason)
            |> count_resubscribe_failure(index)
          else
            state
          end

        :ok ->
          clear_resubscribe_failure(state, index)
      end

    {state, rebalanced?} = handle_subscribe_result(state, index, result)
    state = if rebalanced?, do: resync(state), else: state
    unsubscribe_stale(state, index, context, result)
  end

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
  # has no session to close cleanly; `resubscribe_quiet_shards/1`'s `connected?` filter
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
  # ## Settled on 2026-09-13, by a different experiment than the one proposed
  #
  # The knob was never turned. dp-exchange-webull issue #3 settled it from the other side:
  # on 0.4.33 — with the tag-identity defect fixed, so a tick's re-subscribe is no longer
  # killed at birth by its predecessor's deadline — the grab rate went **UP**, 0.75/min to
  # 3.3/min, and stayed tick-aligned: 69 of 72 notices at second `:42`, that boot's
  # resubscribe offset, one burst per tick instead of one per several.
  #
  # **This timer is the trigger, and the causal direction is the opposite of the one the
  # report assumed.** A grab does not mean a session was taken from us; it means one of our
  # own re-subscribes COMPLETED. Before the fix, attempts were killed before they claimed
  # anything, so a low grab rate was the signature of a broken repair loop rather than of
  # calm.
  #
  # Two things fall out of that, over the same 21.5-minute window: four sessions DO hold
  # `us-crypto` concurrently (255 of 325 symbols, 25% of heartbeats at `sent: 0`, against the
  # ~75% and ~100 symbols that single-session exclusivity predicts), and the
  # `INVALID_SESSION` link_downs that looked like the venue evicting us went to zero with the
  # same fix.
  #
  # What this does NOT settle is whether `Notice.new(:degraded, ...)` is still the honest
  # classification for a line the package now knows it causes itself, roughly four times a
  # minute, while every shard keeps delivering. `Core.Notice` calls severity "a call to
  # action". Left alone deliberately: dp-exchange-core issue #33 decided this notice is not
  # noise after a real consumer incident, and 21.5 minutes is not enough to reverse that.
  # What would settle it is whether a grab ever precedes a delivery gap on a shard that was
  # streaming.
  #
  # Validated rather than coerced, the same way that package validates its own: a value that
  # cannot schedule anything fails `init/1` loudly instead of silently reverting to the
  # default and leaving the experiment looking like a negative result.
  # `priority_symbols:`, canonical and upper-cased, the form every symbol reaches this `Feed` in
  # from the facade. Absent or `nil` is no priority. Anything that is not a list of
  # strings fails `init/1` loudly, because a priority this package silently ignored would
  # leave the pairs a consumer trades rotating with the rest.
  defp priority_symbols(opts) do
    case Keyword.get(opts, :priority_symbols) do
      nil ->
        MapSet.new()

      symbols when is_list(symbols) ->
        if Enum.all?(symbols, &is_binary/1),
          do: MapSet.new(symbols, &String.upcase/1),
          else: raise(ArgumentError, priority_error(symbols))

      other ->
        raise ArgumentError, priority_error(other)
    end
  end

  defp priority_error(value),
    do:
      "DpExchange.Webull.Feed :priority_symbols must be a list of symbol strings, got " <>
        inspect(value)

  defp validate_resubscribe_interval_ms!(value) when is_integer(value) and value >= 1_000,
    do: value

  defp validate_resubscribe_interval_ms!(value) do
    raise ArgumentError,
          "DpExchange.Webull.Feed :resubscribe_interval_ms must be an integer of at least " <>
            "1_000 ms, got #{inspect(value)}. Below a second this re-asserts every shard's " <>
            "whole subscription faster than the venue can answer it, which is a load " <>
            "problem rather than a safety net."
  end

  # ## Which shards a tick re-asserts, and why it is a rotation
  #
  # A shard is a candidate only once it has linked up (`on_link_up/2`'s replay covers one
  # that has not), has something wanted, and has no re-assert still in flight:
  #
  #   A shard whose PREVIOUS blind resubscribe has not finished. Skipped rather than launched
  #   alongside it: a second identical subscribe for a session the venue has not answered for
  #   yet is load, not a safety net. `validate_resubscribe_interval_ms!/1` below refuses a
  #   configured interval under a second in those exact words, and an attempt still in flight
  #   makes the EFFECTIVE interval shorter than the configured one just as surely.
  #
  #   This is the half of issue #3 that reached the venue. `@reconcile_timeout_ms` and
  #   `@resubscribe_interval_ms` are both 60,000, so in the steady state of a stalled shard
  #   every tick landed on top of an unfinished attempt, and the tick won the ordering (see
  #   `spawn_reconcile/3`). What the venue saw was every shard re-asserting its whole
  #   subscription on a rolling 60-second overlap, on one App Key, forever.
  #
  #   The cost is that a shard whose attempt is hung re-asserts on the tick AFTER its deadline
  #   clears rather than the next one — the deadline and the interval being equal, that is
  #   every other tick. Stated rather than tuned away: `@reconcile_timeout_ms` is derived from
  #   `@call_timeout` for a reason that has nothing to do with this timer, and shortening it
  #   here to buy back a cadence would change every other reconcile's deadline with it.
  #
  # Among candidates, only a QUIET shard is re-asserted: one where none of its symbols
  # arrived within `resubscribe_interval_ms`. Each completed re-assert grabs `us-crypto` for
  # that session, and the venue stops delivering to whichever sibling held it. Re-asserting
  # every shard every tick cost a streaming shard 30 s or more of silence per minute
  # (issue #10).
  #
  # **The account cannot stream every shard at once.** Measured by a consumer across
  # 0.4.107–0.4.109 (issue #11), on one App Key with three shards:
  #
  #   * 0.4.107, re-assert every quiet shard: one shard steady and two alternating, each
  #     silent 2 minutes in 4.
  #   * 0.4.108, skip a quiet shard whose own session got a 1002 grab notice: still
  #     alternating, now 1 on and 1 off. The notice does not reliably reach the loser.
  #   * 0.4.109, never re-assert while a sibling streams: no flapping, but the two starved
  #     shards got NO stream, ~190 of 252 pairs on REST alone, a 1m bar a single flat quote.
  #     The consumer reported this as worse for candles than 0.4.107.
  #
  # So the permission is rotated deliberately. While any shard streams, a tick re-asserts
  # exactly ONE quiet shard, the one silent longest, and says so with an `:info`
  # `:coverage_change` naming it, so a consumer can see the schedule. Each starved shard gets
  # the stream in turn, one grab per tick instead of simultaneous ones. When NO shard
  # streams, the whole account has lost the stream, and every quiet shard is re-asserted at
  # once, which is the repair this timer exists for.
  defp resubscribe_quiet_shards(state) do
    window = state.resubscribe_interval_ms

    quiet =
      for {index, shard} <- state.shards,
          shard.connected?,
          shard.symbols != [],
          not Map.has_key?(state.reconciling, {:resubscribe, index}),
          # The post-CONNACK replay is the same whole-list subscribe for the same session. A
          # shard is `connected?` from the moment its `link_up` is handled, and the replay it
          # started can stay in flight for as long as a throttled request is allowed (up to
          # `@reconcile_timeout_ms`), so a tick landing in that window launched a SECOND
          # identical subscribe beside it - the load the in-flight skip above exists to
          # prevent - and re-asserted a shard that had not yet had time to deliver anything.
          not Map.has_key?(state.reconciling, {:link_up, index}),
          not shard_delivered_within?(state, index, window),
          do: {index, shard}

    streaming? = Enum.any?(Map.keys(state.shards), &shard_delivered_within?(state, &1, window))

    cond do
      quiet == [] ->
        state

      # `priority_symbols:` — see `@priority_shard`. The reserved shard keeps the permission:
      # it alone is re-asserted, the moment it is quiet, and no other shard is ever
      # re-asserted against it, because with one holder any other shard streaming means the
      # priority shard is not. The rest stay quiet and are covered by REST.
      #
      # Only while shard 0 really IS the priority shard: connected, and holding a priority
      # symbol. `derive_shards/4` plans shard 0 as an ordinary shard when no priority symbol
      # is wanted, and guarding on the option alone then froze every other shard out of the
      # stream for good. And while shard 0 is down nobody would ever be re-asserted, so the
      # others rotate as usual until it is back; its own `:link_up` subscribe takes the
      # permission back on reconnect.
      priority_shard_held?(state) ->
        case List.keyfind(quiet, @priority_shard, 0) do
          nil -> state
          priority_shard -> reassert_shard(priority_shard, state)
        end

      not streaming? ->
        Enum.reduce(quiet, state, &reassert_shard/2)

      true ->
        {index, shard} = Enum.min_by(quiet, fn {index, _shard} -> rotation_key(state, index) end)
        announce_rotation(state, index, shard)
        state = put_in(state.rotated_at[index], now_ms())
        reassert_shard({index, shard}, state)
    end
  end

  defp priority_shard_held?(%{priority: priority, shards: shards}) do
    case Map.fetch(shards, @priority_shard) do
      {:ok, %{connected?: true, symbols: symbols}} ->
        Enum.any?(symbols, &MapSet.member?(priority, &1))

      _absent_or_down ->
        false
    end
  end

  # Longest since it last streamed OR last had a turn. Delivery alone ranks a shard whose
  # symbols never tick — never-quoted pairs collect together — at zero forever, so it won
  # every rotation: it took the permission from the streaming sibling each tick and then
  # delivered nothing with it. Ties (two shards that have had neither) go to the lower index.
  defp rotation_key(state, index),
    do: {max(last_delivery(state, index), Map.get(state.rotated_at, index, 0)), index}

  # `opts` and `symbols` are bound outside the closure so it captures those and not the whole
  # `state`, which would be copied into the task's heap on every tick: every delivery record,
  # every shard and every tracked reconcile, to send one request.
  #
  # The context records what was sent, so the answer can be checked against what the shard
  # wants by then. See `unsubscribe_stale/4`.
  defp reassert_shard({index, shard}, state) do
    opts = state.resubscribe_opts
    session_id = shard.session_id
    symbols = shard.symbols

    spawn_reconcile(
      state,
      {:resubscribe, index},
      fn -> Subscription.subscribe(session_id, symbols, opts) end,
      %{session_id: session_id, sent: symbols, link: Map.get(shard, :link, 0)}
    )
  end

  defp last_delivery(state, index) do
    state.shards
    |> Map.fetch!(index)
    |> Map.fetch!(:symbols)
    |> Enum.map(&Map.get(state.delivering, &1, 0))
    |> Enum.max(fn -> 0 end)
  end

  defp announce_rotation(state, index, shard) do
    notice =
      Notice.new(:coverage_change, :webull,
        severity: :info,
        message:
          "shard #{index} is quiet while a sibling streams — re-asserting it to take the " <>
            "us-crypto permission in rotation; a sibling shard may go quiet in turn " <>
            "(issue #11). The account cannot stream every shard at once",
        details: %{shard: index, session_id: shard.session_id, symbols: shard.symbols}
      )

    fan_out(state.notice_subscribers, {:dp_exchange, :webull, notice})
  end

  # --- resharding -----------------------------------------------------------

  # The single entry point for every call that can change what is wanted. Recomputes
  # shards from the full wanted set, touches only the shards whose symbol set actually
  # changed, hands the first touched shard's HTTP work to a task whose result becomes the
  # call's eventual reply (same observable contract as the single-connection design this
  # replaces — the caller still waits for the real outcome) and stages the rest — see the
  # moduledoc and the design doc §3 for the full rationale.
  #
  # **The caller's deadline is armed here, once, and keyed by `from`.** It used to be armed per
  # primary reconcile and matched on the shard INDEX, so a retry hop (`:oversubscribed` or
  # `INVALID_SYMBOL` re-plans and may put the primary on another index, or park the caller on
  # a connecting shard) left the first timer matching nothing and the next one armed from the
  # retry, which can fall after the caller's own `@call_timeout`. The caller then exited and
  # took its process down. `answer_overdue_caller/2` finds it wherever it is.
  #
  # The timer's reference is kept in `state.caller_timers` until the caller is answered, and
  # every reply goes through `reply_caller/3` or `reply_all/3`, which cancel it. Left to fire,
  # each call held a timer, and the `from` it names, for the full `connack_timeout_ms` after
  # it had been answered; under a high call rate they piled up.
  defp reshard(state, opts, from) do
    timer = Process.send_after(self(), {:caller_due, from}, state.connack_timeout_ms)
    state = %{state | caller_timers: Map.put(state.caller_timers, from, timer)}
    {:noreply, reshard_step(state, opts, from, @max_shards)}
  end

  # Answers `from` and cancels its deadline. A timer that has already fired cancels to
  # `false` and its message has been (or is about to be) handled by `answer_overdue_caller/2`,
  # which finds nobody waiting and does nothing, so no flush is needed.
  defp reply_caller(state, from, result) do
    GenServer.reply(from, result)
    release_caller(state, from)
  end

  defp release_caller(state, from) do
    case Map.pop(state.caller_timers, from) do
      {nil, _timers} ->
        state

      {timer, timers} ->
        Process.cancel_timer(timer)
        %{state | caller_timers: timers}
    end
  end

  # Answers `from` if it is still waiting: parked on a shard for its `link_up` (removed from
  # `reply_to`, so the late `link_up` does not reply to a returned call), or riding a primary
  # reconcile (left running; see the `{:caller_due, _}` clause).
  defp answer_overdue_caller(state, from) do
    {shards, parked} =
      Enum.reduce(state.shards, {%{}, nil}, fn {index, shard}, {acc, found} ->
        {shard, result} = unpark(shard, from)
        {Map.put(acc, index, shard), found || result}
      end)

    # Its deadline has fired, so there is nothing left to cancel; only the record goes.
    state = %{state | shards: shards, caller_timers: Map.delete(state.caller_timers, from)}

    case parked || primary_overflow(state, from) do
      {:parked, overflow} ->
        GenServer.reply(
          from,
          combine_overflow({:error, {:connack_timeout, state.connack_timeout_ms}}, overflow)
        )

      {:reconciling, overflow} ->
        GenServer.reply(
          from,
          combine_overflow({:error, {:reconcile_pending, state.connack_timeout_ms}}, overflow)
        )

      nil ->
        :ok
    end

    state
  end

  defp unpark(%{reply_to: waiters} = shard, from) when is_list(waiters) do
    case List.keytake(waiters, from, 0) do
      {{^from, overflow}, []} -> {%{shard | reply_to: nil}, {:parked, overflow}}
      {{^from, overflow}, rest} -> {%{shard | reply_to: rest}, {:parked, overflow}}
      nil -> {shard, nil}
    end
  end

  defp unpark(shard, _from), do: {shard, nil}

  defp primary_overflow(state, from) do
    Enum.find_value(Map.keys(state.reconciling), fn
      {:primary, _index, ^from, overflow, _retries_left, _opts} -> {:reconciling, overflow}
      _other_tag -> nil
    end)
  end

  defp reshard_step(state, opts, from, retries_left) do
    {touched, new_shards, overflow} = plan_reshard(state)

    case touched do
      [] ->
        reply_caller(state, from, combine_overflow(:ok, overflow))

      [primary | rest] ->
        state =
          touch_primary_shard(state, primary, new_shards, opts, from, overflow, retries_left)

        rest
        |> Enum.with_index(1)
        |> Enum.reduce(state, fn {index, position}, state ->
          touch_background_shard(state, index, new_shards, opts, position)
        end)
    end
  end

  # Rebalance-triggered resync: nobody is waiting on a `GenServer.call` for this one, so
  # every touched shard is background — there is no caller to hand a primary's outcome
  # to. Uses `resubscribe_opts` for the same reason `on_link_up/2` does: this runs off a
  # venue-pushed event, not a caller's own request.
  defp resync(state) do
    {touched, new_shards, _overflow} = plan_reshard(state)

    touched
    |> Enum.with_index(1)
    |> Enum.reduce(state, fn {index, position}, state ->
      touch_background_shard(state, index, new_shards, state.resubscribe_opts, position)
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

    {new_shards, overflow} =
      derive_shards(effective_wanted, state.shard_capacity, state.shards, state.priority)

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

        state =
          spawn_reconcile(
            state,
            {:primary, index, from, overflow, retries_left, opts},
            fn -> reconcile_now(shard, added, removed, opts) end,
            # What this attempt changed and which session it was asked of, so a failure can
            # put the symbols back and a late answer from a replaced session is ignored.
            %{
              session_id: shard.session_id,
              added: added,
              removed: removed,
              link: Map.get(shard, :link, 0)
            }
          )

        # The caller's deadline is armed once, by `reshard/3`; see there.
        state

      %{session_id: session_id} = still_connecting ->
        # A fresh open or a reconnect is already in flight for this index. Defer to
        # on_link_up/2, exactly as the single-connection design did — see issue #9.
        #
        # Joined to whoever is already waiting, never written over them, and bounded by a
        # CONNACK timer of its own. See the moduledoc's "A caller parked on a connecting
        # shard is always answered".
        state = put_in(state.shards[index].symbols, wanted_symbols)

        Process.send_after(
          self(),
          {:connack_timeout, index, session_id},
          state.connack_timeout_ms
        )

        put_in(
          state.shards[index].reply_to,
          (still_connecting.reply_to || []) ++ [{from, overflow}]
        )
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
          reply_to: [{from, overflow}]
        }

        # The caller is now parked until a CONNACK arrives, and nothing else bounds that
        # wait. `Socket`'s `:socket_connect_timeout` and `:socket_recv_timeout` cover the TCP
        # connect and the HTTP upgrade; once the WebSocket is up, `websockex` simply waits for
        # frames. A venue that accepts the connection and then never answers the MQTT CONNECT
        # leaves this shard `connected?: false` and this caller waiting forever — the same
        # stranding a refused CONNACK caused, with nothing to react to at all.
        #
        # Keyed by `session_id` as well as `index`, so a timer armed for one attempt cannot
        # answer a caller parked on the shard that replaced it.
        Process.send_after(
          self(),
          {:connack_timeout, index, session_id},
          state.connack_timeout_ms
        )

        put_in(state.shards[index], shard)

      {:error, reason} ->
        reply_caller(state, from, combine_overflow({:error, reason}, overflow))
    end
  end

  # `position` is this shard's place among the background shards one plan touches, counted
  # from 1. A shard that has to be OPENED waits `position` spacings: the constant it used to
  # wait was the same for every shard of the plan, so three or four sockets were dialled in
  # the same instant - the connect burst `@shard_spacing_ms` exists to avoid.
  defp touch_background_shard(state, index, new_shards, opts, position) do
    wanted_symbols = Map.fetch!(new_shards, index)

    case Map.get(state.shards, index) do
      nil ->
        Process.send_after(
          self(),
          {:open_staggered, index, wanted_symbols, opts},
          state.shard_spacing_ms * position
        )

        state

      %{connected?: false} ->
        # **Never an HTTP call against a session that is not up.** `touch_primary_shard/7`
        # has always deferred such a shard to `on_link_up/2` ("issue #9"); this path did not,
        # so any re-plan that touched a shard while it was connecting or reconnecting (the
        # socket backs off for up to 30s) sent its subscribe or unsubscribe at a session the
        # venue had not registered, or had already discarded. The venue answers that
        # `INVALID_SESSION`, and `handle_subscribe_result/3` takes `INVALID_SESSION` to mean the
        # session is dead and tears the shard down to reopen it: a socket that was about to come
        # good, replaced on a fresh session, against a five-connection ceiling.
        #
        # Recording the new list is all that is needed. `on_link_up/2` replays the shard's whole
        # `symbols` when the CONNACK arrives, so the delta is carried by the replay.
        put_in(state.shards[index].symbols, wanted_symbols)

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

  # **A session id names the shard's MQTT client id, which survives every reconnect; it does
  # not name a CONNECTION.** `Socket` reconnects inside one process with the same `session_id`,
  # so a request sent on connection 1 and answered after connection 2 is up carries a session
  # id that still matches. The venue answers a subscribe for a session with no live MQTT
  # connection `INVALID_SESSION` (the comment on `touch_background_shard/5` records exactly
  # that), so a request in flight when the link dropped came back `INVALID_SESSION` after the
  # shard had reconnected, and `rebuild_stale_shard/3` tore down a healthy replacement session
  # for a verdict about the dead connection. `:link` counts this shard's CONNACKs and every
  # attempt records the count it was sent on (`current_session?/3`), so an answer from an
  # earlier connection is dropped like one from an earlier session.
  defp on_link_up(state, index) do
    shard = state.shards[index]
    link = Map.get(shard, :link, 0) + 1
    state = update_in(state.shards[index], &Map.merge(&1, %{connected?: true, link: link}))

    case shard.symbols do
      [] ->
        complete_link_up(state, index, :ok)

      symbols ->
        # Bound outside the closure for the reason `reassert_shard/2` gives.
        opts = state.resubscribe_opts
        session_id = shard.session_id

        spawn_reconcile(
          state,
          {:link_up, index},
          fn -> Subscription.subscribe(session_id, symbols, opts) end,
          %{session_id: session_id, sent: symbols, link: link}
        )
    end
  end

  # Answers a caller parked on the shard whose session the venue just refused.
  #
  # Two clauses rather than a `case`, because a refusal notice WITHOUT a session id is a real
  # shape this must tolerate rather than crash on: `Socket` now attaches one to every CONNACK
  # refusal, but a `:degraded` notice can be raised elsewhere in this package for reasons that
  # have nothing to do with a shard, and those must pass straight through.
  #
  # `connack:` is required too. A venue `notice`-topic frame now also carries its shard's
  # `session_id` (issue #11), and it is not a refused session: a "Permission grabbed" notice
  # arriving during a subscribe must not fail that subscribe.
  defp answer_refused_session(state, %{session_id: session_id, connack: _code} = details) do
    case shard_index_for_session(state, session_id) do
      nil -> state
      index -> answer_refused_shard(state, index, details)
    end
  end

  defp answer_refused_session(state, _not_a_refused_session), do: state

  # Answers a caller parked on a shard whose session the venue just refused, and leaves the
  # shard otherwise untouched.
  #
  # `{:error, {:connection_refused, details}}` rather than a bare atom: `details` carries the
  # venue's own CONNACK code and, for 105, the `:connection_limit` reason. A caller acting on
  # this needs to tell "rotate the key" from "you already hold five sessions" — reporting a
  # limit breach as rejected credentials is the exact confusion `Socket`'s own comment warns
  # about, one layer up.
  #
  # `reply_to` is cleared whether or not anyone was waiting, so a second refusal on the same
  # shard cannot reply twice to a `from` that has already been answered.
  defp answer_refused_shard(state, index, details) do
    case Map.get(state.shards, index) do
      %{reply_to: [_first | _rest] = waiters} ->
        state = reply_all(state, waiters, {:error, {:connection_refused, details}})
        put_in(state.shards[index].reply_to, nil)

      _no_one_waiting ->
        state
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

      %{reply_to: [_first | _rest] = waiters} ->
        state = reply_all(state, waiters, result)
        put_in(state.shards[index].reply_to, nil)

      nil ->
        # The shard was removed from under this reply while its subscribe was in flight —
        # its socket crashed and was isolated, or its session came back INVALID_SESSION and
        # it was reopened. Every such path answers whoever was parked on it, through
        # `answer_parked_caller/2`; nothing left to do here.
        #
        # Stated as the funnel rather than as a list of the paths that reach it, because an
        # earlier version of this comment named `isolate_crashed_shard/3` alone — correctly,
        # when it was the only one. `rebuild_stale_shard/3` was then added to
        # `handle_subscribe_result/3`, which is called on the FIRST line of this function,
        # and did not answer anybody; a caller parked on a still-connecting shard whose
        # replay came back INVALID_SESSION waited out `@call_timeout` and took its own
        # process down with it. The invariant held here is what made that invisible, so what
        # is named here is the thing that enforces it.
        state
    end
  end

  defp reconcile_now(shard, added, removed, opts),
    do: reconcile_by_session(shard.session_id, added, removed, opts)

  # Both halves always run. This used to be `with :ok <- unsubscribe do subscribe end`, so a
  # failed unsubscribe silently cancelled the subscribe of everything `added` — found
  # 2026-10-10 by reading the path. The two are independent requests; one failing is not a
  # reason to leave the other's symbols dark. When both fail the SUBSCRIBE error is the one
  # returned, because it is the one `handle_subscribe_result/3` has recoveries for
  # (`INVALID_SYMBOL`, `INVALID_SESSION`, `:oversubscribed`).
  defp reconcile_by_session(session_id, added, removed, opts) do
    unsubscribed = Subscription.unsubscribe(session_id, removed, opts)

    case Subscription.subscribe(session_id, added, opts) do
      :ok -> unsubscribed
      {:error, _reason} = failed -> failed
    end
  end

  # **An unsubscribe that landed while a whole-list subscribe was in flight is sent again.**
  # A blind resubscribe (`reassert_shard/2`) and a link-up replay both send the shard's list as
  # it stood when they were spawned, over HTTP, in a task. A caller's `unsubscribe/2` or
  # `update_symbols/2` runs its own task meanwhile and removes a symbol from `shard.symbols`
  # and from the venue. If the older, larger subscribe is the one the venue processes LAST, the
  # symbol is subscribed again venue-side while this package believes it gone: nothing diffs
  # it (the shard's list no longer holds it), the late frames are dropped as `unwanted?/2`,
  # and it keeps occupying one of the session's 100 slots, so a later `TOO_MANY_SYMBOLS`
  # caps the shard below what it can really carry.
  #
  # So when such an attempt ANSWERS `:ok`, anything it sent that the shard no longer carries is
  # unsubscribed once more, against the same session. Over-sending is idempotent; under-sending
  # is the bug. Only on `:ok`: an `INVALID_SYMBOL` answer has already been trimmed from the list
  # by `resync/1`, and unsubscribing those would draw a second refusal for the same names.
  # Best effort, like the blind resubscribe it follows: a failure is not retried here.
  defp unsubscribe_stale(state, index, %{session_id: session_id, sent: sent}, :ok) do
    case Map.get(state.shards, index) do
      %{session_id: ^session_id, symbols: current} ->
        case sent -- current do
          [] -> state
          stale -> spawn_cleanup(state, index, session_id, [], stale)
        end

      _replaced_or_gone ->
        state
    end
  end

  defp unsubscribe_stale(state, _index, _no_record_of_what_was_sent, _result), do: state

  # **An answer that landed while a caller's own delta was in flight is repaired too.** The
  # same overtaking `unsubscribe_stale/4` handles for a whole-list subscribe happens between
  # two callers' DELTAS: caller A's subscribe of X is in flight on its task, caller B then
  # unsubscribes X on another. Each task is its own HTTP request, so the venue can process B's
  # unsubscribe first and A's subscribe last, leaving X subscribed venue-side and absent from
  # `shard.symbols`, where nothing will ever diff it (the same slot leak). The mirror image
  # leaves a wanted symbol UNSUBSCRIBED: A unsubscribes Y, B re-subscribes it, the venue
  # processes A last, and the blind resubscribe only re-asserts a shard that is quiet, which
  # one still streaming its other symbols is not.
  #
  # So when a primary or background reconcile answers `:ok`, anything it ADDED that the shard no
  # longer carries is unsubscribed again, and anything it REMOVED that the shard carries again is
  # re-subscribed, in one cleanup against the same session. Over-sending is idempotent. In a
  # sequence with no overlap both lists are empty and nothing is sent.
  defp repair_overtaken(
         state,
         index,
         %{session_id: session_id, added: added, removed: removed},
         :ok
       ) do
    case Map.get(state.shards, index) do
      %{session_id: ^session_id, symbols: current} ->
        stale = added -- current
        lost = Enum.filter(removed, &(&1 in current))

        if stale == [] and lost == [],
          do: state,
          else: spawn_cleanup(state, index, session_id, lost, stale)

      _replaced_or_gone ->
        state
    end
  end

  defp repair_overtaken(state, _index, _no_delta_recorded, _result), do: state

  # One cleanup per request, each under a tag of its own. The tag used to be `{:cleanup,
  # index}`, a slot shared by every cleanup for that shard, and `spawn_reconcile/4` tears down
  # whatever is already running under the tag it is given. Two cleanups close together (a
  # blind resubscribe and a link-up replay answering within one HTTP round trip of each other)
  # therefore killed the first before it had sent, and the symbols it carried stayed
  # subscribed venue-side with nothing left that would ever unsubscribe them. Nothing waits on
  # a cleanup's answer, so it needs no slot.
  defp spawn_cleanup(state, index, session_id, subscribe, unsubscribe) do
    opts = state.resubscribe_opts

    spawn_reconcile(state, {:cleanup, index, make_ref()}, fn ->
      reconcile_by_session(session_id, subscribe, unsubscribe, opts)
    end)
  end

  # A subscriber that died. Dropped from both sets, and its monitor forgotten.
  #
  # Without this, nothing ever removed a subscriber pid: `Core.Fanout.resolve/1` skips a dead
  # one at send time, so no EVENTS accumulated — but the pid stayed for the life of this
  # feed, and `deliver/4` walks the whole set calling `Process.alive?/1` once per message.
  # Measured in Core 0.3.3: 0.095 us per fan-out against a clean set, 22.8 us against one
  # carrying a thousand dead pids.
  #
  # Only pids arrive here. A registered-name subscriber is deliberately never monitored — see
  # `Core.Fanout.watch/2` — because a name outlives the process holding it, and pruning on
  # its holder's death would silently unsubscribe a consumer its supervisor is about to
  # restart under the same name.
  defp drop_dead_subscriber(state, pid) do
    state = %{
      state
      | subscribers: MapSet.delete(state.subscribers, pid),
        notice_subscribers: MapSet.delete(state.notice_subscribers, pid),
        monitors: Fanout.forget(pid, state.monitors)
    }

    {:noreply, state}
  end

  # Which in-flight reconcile a monitor ref belongs to, or `nil` for a ref this feed tracks
  # for some other reason. `reconciling` is keyed by TAG rather than by ref, because the tag
  # is what comes back in `{:reconcile_done, tag, result}` and is therefore the only handle
  # both the success and the failure paths share; the ref is carried alongside so a `:DOWN`
  # can find its way back to one.
  defp reconcile_tag_for(state, ref) do
    Enum.find_value(state.reconciling, fn
      {tag, %{ref: ^ref}} -> tag
      _other -> nil
    end)
  end

  # Stops tracking a reconcile and releases its monitor. `flush: true` drops a `:DOWN`
  # already in the mailbox, so a task that finishes and then dies in the same instant cannot
  # have its reply counted once and its death counted again.
  defp forget_reconcile(state, tag) do
    case Map.pop(state.reconciling, tag) do
      # Deliberately defensive: forgetting is idempotent. Every current caller names a tag it
      # has just found in `reconciling`, so this is not reached in production.
      {nil, _reconciling} ->
        state

      {%{ref: ref} = entry, reconciling} ->
        Process.demonitor(ref, [:flush])

        # Entries written by tests carry no `:timer`. A timer that has already fired (the
        # `{:reconcile_timeout, ...}` clause forgets the attempt it just timed out) cancels to
        # `false`, and the message it sent was matched against `attempt` and handled already.
        case Map.get(entry, :timer) do
          nil -> :ok
          timer -> Process.cancel_timer(timer)
        end

        # The attempt's context moves to `settled`, where the clause that settles this tag
        # pops it. Entries written by tests carry no `:context`; that is `nil`, which
        # `current_session?/3` treats as "no claim about a session".
        settled =
          case Map.get(entry, :context) do
            nil -> Map.delete(state.settled, tag)
            context -> Map.put(state.settled, tag, context)
          end

        %{state | reconciling: reconciling, settled: settled}
    end
  end

  # Runs `fun` in its own supervised task rather than inline, so a control-plane HTTP call
  # never blocks this GenServer's mailbox — see the moduledoc. The result comes back as
  # `{:reconcile_done, tag, result}`, handled above; `tag` carries whatever the caller of
  # this function needs to know what to do with it.
  defp spawn_reconcile(state, tag, fun, context \\ nil) do
    me = self()
    state = supersede_reconcile(state, tag)

    # The attempt's identity, minted before it starts so the answer can carry it. A tag names
    # a SLOT — every blind resubscribe for shard 2 runs under `{:resubscribe, 2}` — and both
    # of the things that conclude an attempt, its answer and its deadline, would otherwise be
    # addressed to the slot and land on whichever attempt happened to be occupying it.
    attempt = make_ref()

    {:ok, pid} =
      Task.Supervisor.start_child(state.task_supervisor, fn ->
        send(me, {:reconcile_done, tag, attempt, fun.()})
      end)

    # Monitored and timed, because `Task.Supervisor.start_child/2` gives a child that is
    # neither linked nor monitored: if it dies without sending `{:reconcile_done, ...}`,
    # nothing here ever learns. `tag` carries the caller's `from` on the primary path, so
    # that caller waits out `@call_timeout` and then EXITS, taking the calling process with
    # it. See the `:DOWN` and `{:reconcile_timeout, _, _}` clauses.
    ref = Process.monitor(pid)

    # The deadline carries `ref`, so it names the ATTEMPT and not merely the tag it ran
    # under. A tag is reused — every blind resubscribe for shard 2 runs under
    # `{:resubscribe, 2}` — and a timer that only names the tag will tear down whichever
    # attempt happens to be holding it when the timer arrives. That is not hypothetical
    # ordering: `handle_info(:resubscribe, _)` re-arms its own timer BEFORE spawning, so at
    # a tick boundary the tick is always enqueued ahead of the deadline armed during the
    # previous one. Issue #3 measured the result — 449 reconciles producing 12 recoveries,
    # because each successor was killed microseconds after it started by its predecessor's
    # deadline, and the blind resubscribe is the ONLY recovery this venue has for a session
    # it has silently stopped publishing to.
    #
    # The timer's reference is kept so `forget_reconcile/2` can cancel it. It used to run its
    # full `@reconcile_timeout_ms` (60s) after every reconcile that answered in a hundred
    # milliseconds, each one holding its `tag`: on the primary path that is the caller's `from`
    # and its whole `opts`, credentials struct included. Harmless when it fired (nothing was
    # tracked, so it was ignored), but a busy feed carried a minute's worth of them.
    timer =
      Process.send_after(
        self(),
        {:reconcile_timeout, tag, attempt},
        state.reconcile_timeout_ms
      )

    put_in(state.reconciling[tag], %{
      ref: ref,
      pid: pid,
      attempt: attempt,
      context: context,
      timer: timer
    })
  end

  # An attempt being replaced under a tag that is still tracking one. Torn down here rather
  # than left to its own deadline, because the entry it is tracked by is about to be
  # overwritten: after that its monitor ref belongs to nothing and its `:DOWN` reaches
  # `drop_dead_subscriber/2` as if a subscriber had died.
  #
  # Tearing it down is NOT what stops its stale result being handed to the successor's
  # callers, and an earlier version of this comment claimed it was. An answer already in the
  # mailbox cannot be recalled by killing the process that sent it — `send/2` completed
  # before the kill did — so the window where the attempt answers between its successor's
  # trigger arriving and that trigger being processed stays open however promptly it is
  # killed. What closes it is the attempt token on the answer itself; see
  # `handle_info({:reconcile_done, tag, attempt, result}, _)`.
  #
  # `{:resubscribe, _}` reaches this only when its shard is torn down and reopened
  # (`isolate_crashed_shard/3`, `rebuild_stale_shard/3`): the attempt was for the old
  # connection, and left tracked it held the new shard out of rotation until its deadline
  # and then had its answer latched onto a connection it never ran against. Otherwise
  # `resubscribe_quiet_shards/1` skips a tick whose previous attempt is still running, so
  # what arrives here is a `{:link_up, _}` or
  # `{:background, _}` genuinely superseded by newer intent, where the newest attempt
  # winning is the behaviour wanted. `{:primary, _, from, _, _, _}` carries its caller in
  # the tag and so is unique per caller; two of them never collide.
  defp supersede_reconcile(state, tag) do
    case Map.fetch(state.reconciling, tag) do
      :error ->
        state

      {:ok, %{pid: pid} = entry} ->
        stop_reconcile_task(pid)
        forgotten = forget_reconcile(state, tag)

        # Superseded, not concluded: nothing will settle this attempt, so its context must
        # not wait in `settled` for the next, unrelated answer under the same tag.
        forgotten = %{forgotten | settled: Map.delete(forgotten.settled, tag)}
        revert_superseded(forgotten, tag, Map.get(entry, :context))
    end
  end

  # A background reconcile killed before it answered. Found 2026-10-10: its delta had been
  # recorded on the shard at plan time and the successor only sends ITS OWN delta, so what the
  # killed attempt was carrying was believed subscribed and never re-sent. Its outcome is
  # unknown, so it is treated as failed: reverted and left `unsettled` for the next re-plan
  # (over-sending is idempotent; under-sending is the bug).
  defp revert_superseded(
         state,
         {:background, index},
         %{added: _added, removed: _removed} = context
       ) do
    if current_session?(state, index, context),
      do: revert_failed_delta(state, index, context, {:error, :superseded}),
      else: state
  end

  defp revert_superseded(state, _tag, _context), do: state

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
         details: %{
           session_id: shard.session_id,
           reason: :socket_crashed,
           message: inspect(reason, limit: 50, printable_limit: 1_024)
         }
       )}
    )

    state = answer_parked_caller(state, shard, {:error, {:shard_crashed, reason}})

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
      supersede_reconcile(state, {:resubscribe, index})
      | shards: Map.delete(state.shards, index),
        resubscribe_failed: Map.delete(state.resubscribe_failed, index),
        rotated_at: Map.delete(state.rotated_at, index),
        delivering: Map.drop(state.delivering, shard.symbols),
        delivering_by_kind: drop_symbols_by_kind(state.delivering_by_kind, shard.symbols)
    }

    reopen_after_crash(state, index, shard.symbols)
  end

  # Reopens a crashed shard — at once the first time, then on the `@crash_window_ms` ladder.
  # The shard's slot stays empty meanwhile, which is the honest state: a `reshard/3` arriving
  # in the gap opens it by its own route, and the delayed message then finds it taken.
  defp reopen_after_crash(state, index, symbols),
    do: reopen_with_backoff(state, index, symbols, "crashed")

  # The one reopen policy for a shard torn down because its connection is no good — a socket
  # crash (`isolate_crashed_shard/3`) or an INVALID_SESSION (`rebuild_stale_shard/3`). The two
  # share ONE run counter (`state.crashes`) on purpose: to the venue both are "this index
  # claimed a session and lost it", and a venue answering INVALID_SESSION on every fresh
  # session would otherwise reconnect (a new websocket plus HTTP round trips) with no pause
  # at all. The first teardown reopens at once; ones within `@crash_window_ms` of each other
  # climb the `open_retry_base_ms` ladder, capped at `open_retry_max_ms`.
  #
  # A delayed reopen carries a token held in `state.reopen_timers`. A newer teardown of the
  # same index replaces (and cancels) the earlier timer, and a timer whose token is no longer
  # the index's current one is ignored when it fires — see the tokened `:open_shard` clause.
  defp reopen_with_backoff(state, index, symbols, what) do
    now = System.monotonic_time(:millisecond)

    count =
      case Map.get(state.crashes, index) do
        %{count: previous, at: at} when now - at < @crash_window_ms -> previous + 1
        _first_or_long_ago -> 1
      end

    state = %{
      cancel_reopen_timer(state, index)
      | crashes: Map.put(state.crashes, index, %{count: count, at: now}),
        unsettled: MapSet.delete(state.unsettled, index)
    }

    if count <= 1 do
      send(self(), {:open_shard, index, symbols, state.resubscribe_opts})
      state
    else
      delay = min(state.open_retry_base_ms * 2 ** min(count - 2, 30), state.open_retry_max_ms)

      Logger.warning(
        "[Webull Feed] shard #{index} has been torn down (#{what}) #{count} times within " <>
          "#{div(@crash_window_ms, 1_000)}s of each other — reopening it in #{delay}ms " <>
          "rather than at once"
      )

      token = make_ref()

      timer =
        Process.send_after(
          self(),
          {:open_shard, index, symbols, state.resubscribe_opts, token},
          delay
        )

      %{state | reopen_timers: Map.put(state.reopen_timers, index, {token, timer})}
    end
  end

  defp cancel_reopen_timer(state, index) do
    case Map.pop(state.reopen_timers, index) do
      {nil, _same} ->
        state

      {{_token, timer}, timers} ->
        Process.cancel_timer(timer)
        %{state | reopen_timers: timers}
    end
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
          |> Keyword.put_new(:url, streaming_url(state, opts))
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
  #
  # **Only for the session the shard has NOW.** Found 2026-10-10 by reading the path: the
  # session id the venue names was never compared with the shard's, so a slow answer from a
  # session that had already been replaced (a rebuild, a crash reopen) tore down the healthy
  # replacement, and each teardown mints another stale answer's worth of the same.
  defp handle_subscribe_result(state, index, {:error, {:invalid_session, session_id}}) do
    if stale_invalid_session?(state, index, session_id) do
      Logger.debug(
        "[Webull Feed] shard #{index}: INVALID_SESSION for #{inspect(session_id)} ignored — " <>
          "the shard is on a different session now"
      )

      {state, false}
    else
      {rebuild_stale_shard(state, index, session_id), false}
    end
  end

  defp handle_subscribe_result(state, _index, {:error, _other}), do: {state, false}

  defp stale_invalid_session?(_state, _index, nil), do: false

  defp stale_invalid_session?(state, index, session_id) do
    match?(%{session_id: current} when current != session_id, Map.get(state.shards, index))
  end

  # Applies the answer to a primary or background reconcile — `handle_subscribe_result/3`,
  # plus the two things that need to know which attempt this was. Returns the same
  # `{state, rebalanced?}`.
  #
  # An answer for a session the shard has since replaced is dropped (`settle_stale/3`).
  # Otherwise a failure that leaves the shard standing reverts the attempt's delta, so the
  # shard's list says what the venue was actually told.
  defp settle_result(state, index, tag, result) do
    {context, settled} = Map.pop(state.settled, tag)
    state = %{state | settled: settled}

    if current_attempt?(state, index, context, result) do
      # `handle_subscribe_result/3` first: `:oversubscribed` measures capacity from the
      # size the shard was ATTEMPTED at, which the revert below shrinks.
      {state, rebalanced?} = handle_subscribe_result(state, index, result)
      state = revert_failed_delta(state, index, context, result)
      {repair_overtaken(state, index, context, result), rebalanced?}
    else
      settle_stale(state, index, result)
    end
  end

  # An attempt's answer is applied only when it was asked of the session and connection the
  # shard has, AND is not an `INVALID_SESSION` that arrived while the shard is disconnected.
  #
  # The second condition is the half `:link` cannot see. A request in flight when the socket
  # dropped is answered `INVALID_SESSION` by a venue with no MQTT connection for that client id,
  # and until the reconnect's CONNACK arrives the shard's connection count has not moved, so the
  # answer still looks current. It is a verdict about the connection that just died: the socket
  # is already reconnecting and `on_link_up/2` replays the whole list, whereas treating it as
  # "the session no longer exists" closed a socket that was about to come back and claimed
  # another session against the five-connection ceiling. A shard that is connected when
  # `INVALID_SESSION` arrives is unaffected: that is the venue discarding a live session.
  # (Not applied to the post-CONNACK replay, which is sent after `connected?` is set.)
  defp current_attempt?(state, index, context, result) do
    current_session?(state, index, context) and
      not disconnected_session_refusal?(state, index, result)
  end

  defp disconnected_session_refusal?(state, index, {:error, {:invalid_session, _sid}}),
    do: match?(%{connected?: false}, Map.get(state.shards, index))

  defp disconnected_session_refusal?(_state, _index, _result), do: false

  # `nil` is "no claim about a session" (a result delivered without a tracked attempt), so
  # it is current. A tracked attempt is current only while the shard still has its session.
  defp current_session?(_state, _index, nil), do: true

  # And on the connection it was sent on: a context that records a `:link` is current only
  # while the shard has had no CONNACK since (see `on_link_up/2`). A context that records none
  # (one a test built by hand) makes no claim about a connection.
  defp current_session?(state, index, %{session_id: session_id} = context) do
    case Map.get(state.shards, index) do
      %{session_id: ^session_id} = shard ->
        link = Map.get(shard, :link, 0)
        Map.get(context, :link, link) == link

      _replaced_or_gone ->
        false
    end
  end

  # Deliberately defensive: every context this module records names its session, so this is
  # not reached in production. A record that does not is treated like `nil` (no claim about a
  # session) rather than raising `FunctionClauseError` inside the one process every consumer
  # shares.
  defp current_session?(_state, _index, _context_without_a_session), do: true

  # A venue-level refusal is true whichever session carried it, so `INVALID_SYMBOL` is still
  # recorded. Everything else was measured against a session that is gone.
  defp settle_stale(state, index, {:error, {:invalid_symbols, _symbols}} = result),
    do: handle_subscribe_result(state, index, result)

  defp settle_stale(state, index, _result) do
    Logger.debug(
      "[Webull Feed] shard #{index}: an answer for a replaced session was ignored — it says " <>
        "nothing about the session the shard has now"
    )

    {state, false}
  end

  # `:ok` settles the shard. `INVALID_SESSION` already tore it down and reopened it from its
  # full list. Any other failure reverts: `added` was never subscribed, `removed` may still
  # be, and the next plan must see that difference to send it again.
  defp revert_failed_delta(state, index, nil, _result), do: forget_unsettled(state, index)

  # Not cleared on `:ok`: this attempt succeeding says nothing about a DIFFERENT, superseded
  # attempt's reverted delta. The tick clears the set after the re-plan it triggers.
  defp revert_failed_delta(state, _index, _context, :ok), do: state

  defp revert_failed_delta(state, index, _context, {:error, {:invalid_session, _sid}}),
    do: forget_unsettled(state, index)

  defp revert_failed_delta(state, index, %{added: added, removed: removed}, {:error, _reason}) do
    case Map.fetch(state.shards, index) do
      {:ok, shard} ->
        kept = shard.symbols -- added
        reverted = kept ++ (removed -- kept)

        state = put_in(state.shards[index].symbols, reverted)
        %{state | unsettled: MapSet.put(state.unsettled, index)}

      # Deliberately defensive: a context that names a session only passes
      # `current_session?/3` while that session's shard exists, so the shard is present here
      # in practice. A record that names no session can reach this with the shard gone.
      :error ->
        state
    end
  end

  # Deliberately defensive: a context that carries no `added`/`removed` delta has nothing to
  # revert, so it only clears the index's unsettled mark. Every context recorded for a primary
  # or background reconcile carries both.
  defp revert_failed_delta(state, index, _no_delta, _result), do: forget_unsettled(state, index)

  defp forget_unsettled(state, index),
    do: %{state | unsettled: MapSet.delete(state.unsettled, index)}

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
  # **The reopen is paced, not immediate.** It goes through `reopen_with_backoff/4`, the policy
  # a crashed socket uses: the first teardown of an index reopens at once, repeats within
  # `@crash_window_ms` wait on the `open_retry_base_ms` ladder. A venue that answered
  # INVALID_SESSION to every fresh session otherwise had this package opening a websocket
  # and making its HTTP round trips on every cycle with no pause at all.
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
  # Callers parked on the shard (`shard.reply_to`) ARE answered here, through
  # `answer_parked_caller/2`, before the shard is deleted. That is not a double reply: the
  # `{:reconcile_done, ...}` clause that reached this owns only the caller whose `from` rode in
  # its own tag, and a parked caller is a different one, waiting for this shard's `link_up`,
  # which can no longer arrive for a session that has just been discarded. An earlier version
  # of this comment said no reply was sent here; the code stopped agreeing with it when
  # `complete_link_up/3` was found to read a deleted shard as "nobody left to answer".
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
               reason: :invalid_session,
               message: "INVALID_SESSION — reopening the shard on a fresh session"
             }
           )}
        )

        # Answered BEFORE the delete, for the reason `answer_parked_caller/2` carries: after
        # this the shard is gone, and `complete_link_up/3` reads a missing shard as one whose
        # caller has already been dealt with.
        state = answer_parked_caller(state, shard, {:error, {:invalid_session, named}})

        state = %{
          supersede_reconcile(state, {:resubscribe, index})
          | shards: Map.delete(state.shards, index),
            resubscribe_failed: Map.delete(state.resubscribe_failed, index),
            rotated_at: Map.delete(state.rotated_at, index),
            unsettled: MapSet.delete(state.unsettled, index),
            delivering: Map.drop(state.delivering, shard.symbols),
            delivering_by_kind: drop_symbols_by_kind(state.delivering_by_kind, shard.symbols)
        }

        stop_socket(shard.socket)
        reopen_with_backoff(state, index, shard.symbols, "INVALID_SESSION")
    end
  end

  # `:shutdown` rather than `:kill`, for the same reason `stop_socket/1` below chooses it,
  # and this is the second half of that decision — made for the socket and not carried to
  # the task, which is how dp-exchange-webull issue #2 happened.
  #
  # The task is a `Task.Supervisor` child with `restart: :temporary`. OTP's supervisor skips
  # its child-termination report for the reasons `:normal`, `:shutdown` and `{:shutdown, _}`
  # and emits one at ERROR for every other reason, so `:kill` — reaching the supervisor as
  # `:killed` — put an ERROR-level report on the host's logger for every timed-out reconcile:
  # one per shard per resubscribe tick, 234 of 239 ERROR lines over a single boot on the
  # reporting host. Measured here on 2026-09-12 by exiting a `Task.Supervisor` child both
  # ways with `Logger`'s `:logger_translator` primary filter set to `sasl: true` (the host
  # setting that lets these through; this package's own test env drops them): `:kill`
  # produced `Child :undefined of Supervisor #PID<_> (Task.Supervisor) terminated`, and
  # `:shutdown` produced nothing.
  #
  # Nothing was broken by the noise, and that is exactly the cost. The condition is already
  # reported here at WARN with the shard named; the OTP report names neither this package nor
  # the shard, and it arrives at the level anything watching for trouble keys off. An ERROR
  # stream that is 98% routine is one a reader and an alert rule both learn to ignore, and
  # the next genuine error arrives into that.
  #
  # Safe because no reconcile task traps exits: the body `spawn_reconcile/3` supervises is a
  # bare `send/2` around `fun.()`, and none of the four reconcile funs sets the flag. A
  # trapping task would be free to ignore `:shutdown` — if one is ever introduced, this has
  # to become an untrappable kill again, and the report comes back with it.
  defp stop_reconcile_task(pid) do
    Process.exit(pid, :shutdown)
  end

  # `:shutdown` rather than `:kill`: the socket does not trap exits, so either terminates
  # it, and `:shutdown` is the reason that reads as intentional in any report it produces.
  defp stop_socket(socket) when is_pid(socket) do
    if Process.alive?(socket), do: Process.exit(socket, :shutdown)
    :ok
  end

  # Deliberately defensive: a shard's socket is always a pid when `Socket.start_link/1` has
  # opened it, but stopping a shard must never be the thing that crashes the Feed, so a shard
  # record with no pid to stop is simply left.
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

  defp open_planned(state, _index, [], _opts), do: state

  defp open_planned(state, index, planned, opts) do
    case open_socket(state, opts) do
      {:ok, session_id, socket} ->
        # `resync/1` because `symbols_to_open/3` may have placed a symbol that arrived after
        # the open was scheduled on ANOTHER shard; nothing else would touch that one.
        state
        |> put_in([:shards, index], new_shard(session_id, socket, planned))
        |> end_open_chain(index)
        |> resync()

      {:error, reason} ->
        retry_shard_open(state, index, planned, opts, 1, reason, nil)
    end
  end

  # An open attempt from a retry message. `token` is the chain's, or `nil` for an untokened
  # message; see the `{:reopen_shard, ...}` clauses.
  defp reopen(state, index, symbols, opts, attempt, token) do
    case Map.get(state.shards, index) do
      nil ->
        planned = symbols_to_open(state, index, symbols)
        reopen_planned(state, index, planned, opts, attempt, token)

      _opened_by_something_else ->
        state |> end_open_chain(index) |> clear_open_failure(index)
    end
  end

  defp reopen_planned(state, index, [], _opts, _attempt, _token) do
    state = end_open_chain(state, index)
    %{state | open_failed: MapSet.delete(state.open_failed, index)}
  end

  defp reopen_planned(state, index, planned, opts, attempt, token) do
    case open_socket(state, opts) do
      {:ok, session_id, socket} ->
        Logger.info(
          "[Webull Feed] shard #{index} opened on attempt #{attempt + 1} — its " <>
            "#{length(planned)} symbol(s) are covered again"
        )

        state
        |> put_in([:shards, index], new_shard(session_id, socket, planned))
        |> end_open_chain(index)
        |> clear_open_failure(index)
        |> resync()

      {:error, reason} ->
        retry_shard_open(state, index, planned, opts, attempt + 1, reason, token)
    end
  end

  # The chain for `index` is over: its token no longer matches anything, so a message still in
  # flight for it is ignored.
  defp end_open_chain(state, index),
    do: %{state | open_chains: Map.delete(state.open_chains, index)}

  defp new_shard(session_id, socket, symbols) do
    %{session_id: session_id, socket: socket, connected?: false, symbols: symbols, reply_to: nil}
  end

  # The symbols a shard opening NOW should carry, derived from what is wanted NOW.
  #
  # `carried` (what the shard held when its open was scheduled) is offered to
  # `derive_shards/4` as the slot's existing contents, so it stays sticky: a crashed shard
  # reopens with its own symbols rather than having them spread over its siblings. What
  # changes is that anything unsubscribed, rejected or newly wanted in the meantime is
  # applied. Empty means there is nothing to open.
  #
  # **Never a symbol another shard carries now.** While the slot sat empty (the immediate
  # reopen is queued behind whatever is already in the mailbox, and a delayed one waits up to
  # a minute) a caller's re-plan could place this shard's symbols on a sibling with room. The
  # open then arrived carrying the OLD list, and `derive_shards/4` keeps whatever an existing
  # slot holds, so the same symbol was planned onto two sessions: two subscriptions, two
  # deliveries, and a slot spent twice against the venue's per-session ceiling.
  defp symbols_to_open(state, index, carried) do
    effective = MapSet.difference(state.wanted, active_rejections(state))

    held_elsewhere =
      state.shards
      |> Map.delete(index)
      |> Enum.flat_map(fn {_other, shard} -> shard.symbols end)
      |> MapSet.new()

    carried = Enum.reject(carried, &MapSet.member?(held_elsewhere, &1))
    existing = Map.put(state.shards, index, %{symbols: carried})

    {planned, _overflow} =
      derive_shards(effective, state.shard_capacity, existing, state.priority)

    Map.get(planned, index, [])
  end

  # Logs every failed open, notifies on the FIRST one, and schedules the next attempt.
  #
  # The log keeps firing on every attempt by design — a sustained outage should stay visible
  # in the log — while the notice fires once per outage, which is the same split
  # `latch_resubscribe_failure/4` below already makes and for the same reason: a notice per
  # attempt on a venue that is down is a storm, just a slower one.
  defp retry_shard_open(state, index, symbols, opts, attempt, reason, token) do
    # The exponent is clamped before the power, as `reopen_after_crash/3` does: `attempt`
    # counts every failed open of an outage and has no ceiling of its own, and the cap is
    # reached long before 2^30 for any sane `open_retry_base_ms`.
    delay = min(state.open_retry_base_ms * 2 ** min(attempt - 1, 30), state.open_retry_max_ms)

    Logger.warning(
      "[Webull Feed] shard #{index} did not open (#{inspect(reason)}) on attempt " <>
        "#{attempt} — its #{length(symbols)} symbol(s) are not covered; retrying in " <>
        "#{delay}ms"
    )

    state
    |> schedule_open_retry(index, symbols, opts, attempt, delay, token)
    |> latch_open_failure(index, symbols, reason)
  end

  # The chain's own next link keeps its token. A failure from anywhere else starts a chain only
  # if the slot has none: otherwise the live one already retries it, and a second would dial the
  # venue again at its own cadence for as long as the outage lasted.
  defp schedule_open_retry(state, index, symbols, opts, attempt, delay, nil) do
    if Map.has_key?(state.open_chains, index) do
      state
    else
      token = make_ref()
      Process.send_after(self(), {:reopen_shard, index, symbols, opts, attempt, token}, delay)
      %{state | open_chains: Map.put(state.open_chains, index, token)}
    end
  end

  defp schedule_open_retry(state, index, symbols, opts, attempt, delay, token) do
    Process.send_after(self(), {:reopen_shard, index, symbols, opts, attempt, token}, delay)
    state
  end

  # Same latch shape as `latch_resubscribe_failure/4`, and deliberately a SEPARATE map: a
  # shard that never opened and a shard whose blind resubscribe is failing are different
  # conditions with different recoveries, and folding them into one latch would make the
  # recovery notice for either one clear the other's.
  defp latch_open_failure(state, index, symbols, reason) do
    if MapSet.member?(state.open_failed, index) do
      state
    else
      notice =
        Notice.new(:coverage_change, :webull,
          severity: :warning,
          message:
            "shard #{index} could not be opened (#{inspect(reason)}) — " <>
              "#{length(symbols)} symbol(s) are not covered at all until it opens",
          details: %{
            shard: index,
            symbol_count: length(symbols),
            reason: :open_failed,
            message: inspect(reason, limit: 50, printable_limit: 1_024)
          }
        )

      fan_out(state.notice_subscribers, {:dp_exchange, :webull, notice})
      %{state | open_failed: MapSet.put(state.open_failed, index)}
    end
  end

  # The crossing back out, fired once. A consumer told a shard went dark has to be told when
  # it comes back, or the only way to find out is to notice notices stopping.
  defp clear_open_failure(state, index) do
    if MapSet.member?(state.open_failed, index) do
      notice =
        Notice.new(:coverage_change, :webull,
          severity: :info,
          message: "shard #{index} opened after failing to — its symbols are covered again",
          details: %{shard: index}
        )

      fan_out(state.notice_subscribers, {:dp_exchange, :webull, notice})
      %{state | open_failed: MapSet.delete(state.open_failed, index)}
    else
      state
    end
  end

  # Fires once per transition into a shard's blind-resubscribe failing generically — see
  # the moduledoc's "A generic resubscribe failure is reported too, latched per shard" and
  # DpCryptoManagement's issue #23 (58 consecutive failures across 13 minutes, all of it
  # invisible outside a log grep). Latched per shard, not globally: each shard is its own
  # MQTT session with its own independent failure and recovery schedule, and a global latch
  # would either miss a second shard's own transition or fire on every tick once ANY shard
  # is already latched. A latched shard's every later tick re-enters this same branch (the
  # `Logger.warning` in the `{:resubscribe, _}` handler keeps firing with it, unchanged, by
  # design) but short-circuits here rather than notifying again — a notice per tick on a
  # sustained outage is still a storm, just a slower one.
  defp latch_resubscribe_failure(state, index, symbols, reason) do
    if Map.has_key?(state.resubscribe_failed, index) do
      state
    else
      notice =
        Notice.new(:coverage_change, :webull,
          severity: :warning,
          message:
            "shard #{index} resubscribe has failed (#{inspect(reason)}) — " <>
              "#{length(symbols)} symbol(s) stay on whatever they last delivered " <>
              "until it recovers",
          details: %{
            shard: index,
            symbol_count: length(symbols),
            reason: :resubscribe_failed,
            message: inspect(reason, limit: 50, printable_limit: 1_024)
          }
        )

      fan_out(state.notice_subscribers, {:dp_exchange, :webull, notice})
      %{state | resubscribe_failed: Map.put(state.resubscribe_failed, index, 0)}
    end
  end

  # Counts this shard's consecutive blind-resubscribe failures and escalates once the limit
  # is reached.
  #
  # Separate from `latch_resubscribe_failure/4` above, which is about NOTIFYING once per
  # transition. This one is about acting, and the two have different schedules on purpose:
  # the notice fires on the first failure, the escalation on the twelfth.
  #
  # **dp-exchange-webull issue #1.** After a node restart, all four shards failed their blind
  # resubscribe with `{:reconcile_timeout, 60_000}`. Three recovered on their own within
  # eleven minutes; the fourth failed the identical reconcile 21 consecutive times over 21
  # minutes and never recovered. Whatever state that shard was in, its own retry could not
  # leave it — and nothing here counted, so nothing could notice: `resubscribe_failed` was a
  # `MapSet`, which answers "is this shard failing?" and never "for how long".
  #
  # **The escalation is not new machinery.** `rebuild_stale_shard/3` already stops the
  # socket, drops the shard's bookkeeping and reopens it on a fresh session — it is what
  # `{:invalid_session, _}` has always done. This makes a repeated timeout reach the same
  # remedy, because after a dozen identical failures "this shard's session is no good" is a
  # better hypothesis than "the next attempt will differ".
  defp count_resubscribe_failure(state, index) do
    failures = Map.get(state.resubscribe_failed, index, 0) + 1
    state = %{state | resubscribe_failed: Map.put(state.resubscribe_failed, index, failures)}

    cond do
      failures < state.resubscribe_failure_limit ->
        state

      shard_delivering?(state, index) ->
        # The reconcile keeps timing out and the symbols keep arriving. That is a
        # subscription-management problem on a WORKING transport, and reopening the transport
        # can only lose what it was still delivering. Logged once, on the transition, rather
        # than every tick for as long as the condition lasts.
        if failures == state.resubscribe_failure_limit do
          Logger.warning(
            "[Webull Feed] shard #{index} has failed #{failures} consecutive blind " <>
              "resubscribes but its symbols are still arriving — NOT reopening the socket, " <>
              "because a reopen would drop deliveries this shard is still making. It will " <>
              "reopen if and when those deliveries stop."
          )
        end

        state

      true ->
        Logger.warning(
          "[Webull Feed] shard #{index} has failed #{failures} consecutive blind resubscribes " <>
            "and has delivered nothing for #{state.stale_delivery_ms}ms — reopening its " <>
            "socket on a fresh session rather than attempting the identical reconcile again"
        )

        rebuild_stale_shard(state, index, nil)
    end
  end

  # Has anything this shard is responsible for arrived recently?
  #
  # **This gate exists because the version without it made things worse, measured.** Issue #1
  # shipped an escalation keyed on consecutive failures alone. Run against the live fleet on
  # 0.4.25, three shards hit the limit, reopened, and failed the identical reconcile on the
  # very next tick and every tick after — a fresh session did not change the outcome once.
  # Coverage fell from 226 distinct symbols to ~160 (−29%) while `dp_exchange_coinbase` and
  # `dp_exchange_gemini` stayed flat across the same windows, so a quiet market cannot explain
  # it. The stuck-but-subscribed socket had been delivering; tearing it down is what stopped
  # that. And because `rebuild_stale_shard/3` resets the counter, it had become a cycle: fail
  # twelve times, reopen, fail twelve times, reopen.
  #
  # The inference that failed was mine — that a shard which cannot reconcile is a shard whose
  # session is no good. It is not. A reconcile is a subscription-management call, and it can
  # fail while the transport underneath keeps streaming everything already subscribed to.
  # That is exactly what this `Feed`'s own log line has always promised ("its N symbol(s) stay
  # on whatever they last delivered until the next resubscribe tick"), and a reopen is what
  # breaks the promise.
  #
  # So the reopen is gated on the thing that actually separates the two cases. A reopen can
  # only GAIN something once the shard has stopped delivering; while it is still delivering,
  # the worst case of doing nothing is a stale subscription set, and the worst case of acting
  # is losing live data.
  #
  # `delivering` is `%{symbol => epoch_ms}`, written on every arrival. A shard that has never
  # delivered at all reads as quiet here, which is right: reaching the failure limit takes
  # `resubscribe_failure_limit` minutes, and a working shard delivers well inside that.
  defp shard_delivering?(state, index),
    do: shard_delivered_within?(state, index, state.stale_delivery_ms)

  # Whether any of this shard's symbols arrived within the last `window_ms`. The reopen gate
  # above asks it over `stale_delivery_ms`; the blind resubscribe asks it over one
  # `resubscribe_interval_ms` (see `resubscribe_quiet_shards/1`).
  defp shard_delivered_within?(state, index, window_ms) do
    case Map.fetch(state.shards, index) do
      :error ->
        false

      {:ok, %{symbols: symbols}} ->
        cutoff = now_ms() - window_ms
        Enum.any?(symbols, fn symbol -> Map.get(state.delivering, symbol, 0) > cutoff end)
    end
  end

  # The other half of the transition above: a shard latched into failure whose blind
  # resubscribe just succeeded again. A consumer that learned a shard's resubscribe broke
  # and never learned it recovered is only half-served — the same reasoning
  # `Core.PollingFeed`'s own `record_success/2` applies to its sibling case.
  defp clear_resubscribe_failure(state, index) do
    if Map.has_key?(state.resubscribe_failed, index) do
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
      %{state | resubscribe_failed: Map.delete(state.resubscribe_failed, index)}
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

  # `active_rejections/1` ignores an expired entry but nothing ever REMOVED one, so
  # `state.rejected` only grew: a consumer that rotates through a changing universe over weeks
  # (every symbol the venue ever refused, 24 hours apart) kept each of them for the life of the
  # feed, and `active_rejections/1` filtered the whole map on every reshard. Pruned on the
  # resubscribe tick, after the re-plan that returns an expired symbol to a shard has run.
  defp prune_rejections(%{rejected: rejected} = state) when map_size(rejected) == 0, do: state

  defp prune_rejections(state) do
    now = System.monotonic_time(:millisecond)

    live = Map.filter(state.rejected, fn {_symbol, expires_at} -> expires_at > now end)
    %{state | rejected: live}
  end

  # Every path that removes a shard answers whoever was parked on it, through here.
  #
  # `complete_link_up/3` reads the shard back after `handle_subscribe_result/3` may have
  # removed it, and treats a missing shard as one whose caller has already been answered.
  # That was true while `isolate_crashed_shard/3` was the only thing that could remove one
  # mid-reply. `rebuild_stale_shard/3` was then added, on the line immediately above that
  # read, and deleted the shard on INVALID_SESSION without answering anyone — so a caller
  # parked on a still-connecting shard whose replay subscribe came back `INVALID_SESSION`
  # waited out `@call_timeout` and then EXITED, taking the calling process with it.
  #
  # One funnel rather than the reply written out at each teardown, because the two paths
  # drifting apart is the whole of what went wrong: both of them delete a shard, and only
  # one of them remembered what that means for a caller. A third teardown must come through
  # here too.
  defp answer_parked_caller(state, %{reply_to: nil}, _result), do: state

  defp answer_parked_caller(state, %{reply_to: waiters}, result) when is_list(waiters),
    do: reply_all(state, waiters, result)

  # Every caller parked on one shard gets the same outcome, each with its OWN overflow:
  # what one call could not place is not another call's failure. Each one's deadline is
  # cancelled with its answer; see `reshard/3`.
  defp reply_all(state, waiters, result) do
    Enum.reduce(waiters, state, fn {from, overflow}, state ->
      reply_caller(state, from, combine_overflow(result, overflow))
    end)
  end

  # The only case §3.5 says cannot be absorbed internally: every shard already at capacity and
  # there is nowhere left to put a symbol. Reported, never silently dropped or silently
  # subscribed somewhere already full.
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
  #
  # **With `priority_symbols:`, shard `@priority_shard` is reserved for them** (issue #11's
  # follow-up). The account holds the `us-crypto` permission on one session at a time, so the
  # pairs a consumer actually trades are planned into one shard. `resubscribe_quiet_shards/1`
  # then keeps that shard holding the permission instead of rotating it. The reserved shard is
  # recomputed rather than sticky: it is the wanted priority symbols, sorted, up to its
  # capacity. Anything past that capacity, and every other wanted symbol, is placed in the
  # remaining shards exactly as without a priority.
  #
  # **The priority shard's unused room takes the overflow, and only the overflow.** It used
  # to be reserved outright, so three priority symbols plus 450 others reported
  # `capacity_exceeded` against a 500-symbol ceiling while 97 slots of shard 0 sat empty.
  # Found 2026-10-10 by reading this function. Other symbols are still planned into shards
  # 1..4 first, exactly as before, so nothing changes until those are full; only what would
  # otherwise be refused fills shard 0's remaining room. That is safe for what priority is
  # for: the permission is per SESSION, so a non-priority symbol riding in shard 0 streams on
  # the session that already holds it, `priority_shard_held?/1` and
  # `resubscribe_quiet_shards/1` only ask whether shard 0 holds a PRIORITY symbol, and a
  # filler can never displace one — the priority symbols are pinned first and every plan.
  defp derive_shards(wanted, shard_capacity, existing_shards, priority) do
    pinned =
      priority
      |> MapSet.intersection(wanted)
      |> MapSet.to_list()
      |> Enum.sort()
      |> Enum.take(Map.get(shard_capacity, @priority_shard, @pairs_per_socket))

    case pinned do
      [] ->
        derive_shards(wanted, shard_capacity, existing_shards)

      pinned ->
        rest = MapSet.difference(wanted, MapSet.new(pinned))
        others = Map.delete(existing_shards, @priority_shard)
        reserved = Map.put(shard_capacity, @priority_shard, 0)

        {shards, overflow} = derive_shards(rest, reserved, others)

        room =
          max(Map.get(shard_capacity, @priority_shard, @pairs_per_socket) - length(pinned), 0)

        {fillers, still_over} = Enum.split(overflow, room)
        {Map.put(shards, @priority_shard, pinned ++ fillers), still_over}
    end
  end

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

  # Only asked of an index `plan_reshard/1` has found in `state.shards`: an index that is not
  # there is in `new_indices`, and the `or` in front of this call short-circuits before it
  # runs. So the shard is always present, and the `nil -> false` clause this used to carry
  # could never be reached.
  defp shard_changed?(state, index, new_shards) do
    %{symbols: current} = Map.fetch!(state.shards, index)
    current != Map.get(new_shards, index, [])
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

  # The venue's own endpoint, unless the application config names another with
  # `:websocket_url`. The seam exists for tests. A tier-1 run sets it in `config/test.exs` to
  # a closed local port, so a socket that no test aimed elsewhere fails at once instead of
  # dialling the venue. Measured 2026-09-27: this package's suite had been opening live
  # connections to the venue on every run, from tests that never meant to. A consumer can
  # use it for a proxy. `config/` does not ship, so a consumer's default is still the venue.
  defp streaming_url(state, opts) do
    Config.get(:dp_exchange_webull, :websocket_url, nil) ||
      Environment.streaming_url(environment(state, opts))
  end

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
  # No `%Trade{}` clause: `record_quote/3` delivers a trade without counting it (see there)
  # before this is ever asked, so such a clause could never be reached.
  defp kind_for(_other), do: :error

  defp drop_symbols_by_kind(delivering_by_kind, symbols) do
    Map.new(delivering_by_kind, fn {kind, per_symbol} ->
      {kind, Map.drop(per_symbol, symbols)}
    end)
  end

  defp take_symbols_by_kind(delivering_by_kind, symbols) do
    Map.new(delivering_by_kind, fn {kind, per_symbol} ->
      {kind, Map.take(per_symbol, symbols)}
    end)
  end

  # See the `{:dp_exchange, :webull, quote_struct}` clause of `handle_info/2`.
  defp unwanted?(%{symbol: symbol}, wanted) when is_binary(symbol),
    do: not MapSet.member?(wanted, symbol)

  # Deliberately defensive: a payload that names no usable symbol cannot be matched against
  # `wanted`, so it is not called unwanted. `Socket` only emits structs with a binary symbol,
  # so this is not reached in production; refusing here would instead crash the one process
  # every subscriber shares.
  defp unwanted?(_payload, _wanted), do: false

  # A `Trade` is delivered and not counted — see the moduledoc's "`:trades` is delivered but
  # never counted here". `capabilities().streamable` does not declare `:trades`, and Core's
  # `coverage_by_kind/1` invariant ties every reported kind to a declared one (and
  # `coverage/1` to their union). Found 2026-10-10: `TICK` is requested by default, so a
  # tick that did arrive put `:trades` into `coverage_by_kind/1` while the capability
  # claimed no such kind existed.
  defp record_quote(state, message, %Trade{}), do: {:noreply, deliver(state, message)}

  defp record_quote(state, message, quote_struct) do
    state = deliver(state, message)

    now = now_ms()
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

  # The scale `state.delivering` and `state.rotated_at` are written and compared on:
  # milliseconds since the epoch on the VM's own system time (`System.system_time/1`), not
  # `:os.system_time/1`. Both fields are in-VM durations ("did this shard deliver in the last
  # five minutes", "which shard was rotated longest ago"), and `:os.system_time/1` is the
  # host's clock: an NTP step or a resync after a bad RTC moved it by whatever distance, so a
  # forward step made every delivering shard look silent (and a quiet one eligible for a
  # reopen) and a backward step made a dead shard look alive for that long. The VM's system
  # time is slewed, never stepped, in the default `no_time_warp` mode. Kept epoch-based, not
  # monotonic, because `0` is the "never" default these maps are read with and a monotonic
  # reading can be negative.
  defp now_ms, do: System.system_time(:millisecond)
end
