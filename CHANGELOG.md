# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Status: EXPERIMENTAL

Stated here rather than only per-release, because a reader arriving at a specific version
needs it as much as one reading the top.

This package has not run in production. While it is `0.x` the API may change without a
major version. Coverage is uneven by design: the fake and the stubbed HTTP transport are
well covered, order placement and authenticated flows are not. Nothing here runs against
the live venue — every Webull call is signed, so there is no public endpoint a
credential-less repository could test against.

**Whenever an endpoint moves to `:proven`, the entry that does it states the evidence** —
what was run against the live venue, and when. "Marked proven" with no evidence is not an
acceptable changelog line.

## [Unreleased]

### Fixed

- **BREAKING: twelve more `Fake` callbacks on the widened surface still succeeded with no
  credentials — the same defect as the entry below, on the endpoints assertion 17
  structurally cannot reach.** `get_option_chain/2`, `get_option_expirations/2`,
  `list_watchlists/1`, `get_watchlist/2`, `create_watchlist/3`, `update_watchlist/2`,
  `delete_watchlist/2`, `get_financials/3`, `get_corporate_events/1`, `get_filings/2`,
  `get_news/1` and `get_screener/2` all bound their options as `_opts` and never inspected
  `credentials`, while every one of their real counterparts reaches the venue through
  `Rest`'s signed request path and answers `{:error, {:missing_credentials, :webull}}`
  without one. All twelve now gate through the same `authenticated/1` →
  `Auth.present?/1` helper the rest of the fake already used, checked **before** the
  argument validation they already did, matching `Rest`'s own order — so
  `Fake.get_news(symbols: ["AAPL"])` with no credentials is now a credential error rather
  than a success, and `Fake.get_corporate_events()` with neither is the credential error
  rather than `:symbol_required`.

  **Why the earlier fix missed them.** Assertion 17 gates on
  `Core.AdapterContract`'s hardcoded `@credentialed` list — `get_balances`,
  `get_accounts`, `get_fees`, `get_transfers`, `place_order`, `cancel_order`, `get_order`,
  `get_orders`, `get_trade_history` — which names none of the twelve. The list predates the
  widened callback surface and was never extended with it, so a venue can pass assertion 17
  with the whole options/watchlists/fundamentals/news/screener surface ungated. This was
  found by a cross-package audit that compared all five venue packages against each other,
  which also found the identical gap in `dp_exchange_schwab`'s fake on its own widened
  surface — it is a property of the assertion's fixed list, not of either venue, and the
  durable fix belongs in Core rather than here.

- **BREAKING: `Fake` let several credentialed account and order calls succeed with no
  credentials at all — the venue declares `credential_benefit: :required` and the fake
  did not honour it.** Found by `dp_exchange_core` 0.1.57's new assertion 17 ("credential
  gate"), which reported `get_fees/2` first; auditing every credentialed callback against
  its real `Rest` counterpart turned up the same defect on `get_accounts/2`,
  `get_balances/2`, `get_transfers/2`, `get_transactions/2`, `get_positions/1`,
  `quantization/2`, `place_order/3`, `place_orders/3`, `preview_order/3`,
  `replace_order/4`, `cancel_order/3`, `get_order/3` and `get_orders/2`. Three different
  shapes of the same gap: `get_fees/2` and `get_accounts/2` discarded the `credentials`
  argument outright (`_credentials`) and checked nothing; `get_balances/2` and
  `get_transfers/2` gated only on `fake_account(opts)`, an account-id check that is a
  different question from a credential check; the rest simply never referenced
  `credentials` at all. A consumer's own suite calling any of these with no credentials
  and asserting success was going green against behaviour the real venue does not have —
  every one of these hits a signed endpoint and gets a real 401.

  All now gate through `DpExchange.Webull.Auth.present?/1` — the same
  `%{app_key: <binary>, app_secret: <binary>}` shape check `Auth.headers/2` runs for
  every real signed request — checked in the same order the real `Rest` call checks it
  (account id before credentials, where both apply), so the fake's refusal point matches
  the real one, not just its final answer. `get_fees/2`'s real counterpart
  (`Rest.get_fees/2`) builds no HTTP request at all — it is a published flat rate, not a
  query — so it never ran through `Auth.headers/2` to get this check for free; it now
  calls `Auth.present?/1` directly, which is the one behaviour change on the real facade
  in this fix (previously `{:ok, _}` for any input whatsoever, including no credential;
  now `{:error, {:missing_credentials, :webull}}` without one). Every other real `Rest`
  function was already correctly gated — only the fake had drifted from it.

  **The refusal shape changed too, and this was wrong independently of assertion 17.**
  `Fake.get_price/2` and the rest of the market-data surface answered
  `{:refused, :missing_credentials}` for a missing credential. `DpExchange.Core.Venue`'s
  own moduledoc reserves `{:refused, reason}` for the venue's own **permanent** word about
  a request it **received** — a request built with no credential never reaches the venue
  at all; `Auth.headers/2` refuses it locally first. Every credentialed callback,
  market-data and account/order alike, now answers `{:error, {:missing_credentials,
  :webull}}` instead — `Auth.headers/2`'s own return value, echoed rather than invented.
  `market_status/1` is the one callback left unchanged: the real venue answers it with no
  credential too, so the fake doing the same is not a gap.

  `FakeInjection.credentials_bypassed?/1` still short-circuits every one of these gates,
  unchanged, for a test that needs to skip the check deliberately.

- **A clean-shutdown `DISCONNECT` warning fired on the ordinary shutdown path, on every
  test teardown in this package's own suite.** `Feed.terminate/2`'s `DISCONNECT` sweep
  (added the same day, above) logged `Logger.warning/1` for every `Socket.disconnect/2`
  failure without distinguishing why it failed. Two of `disconnect/2`'s three error
  reasons are structural, not a failed send: `:not_alive` means the socket process was
  already gone — the *ordinary* shape of shutdown, since a shard's socket and the `Feed`
  supervising it are usually torn down together — and `:calling_self` can only happen
  through a test fixture handing `terminate/2` its own pid, never in production. Neither
  is "the venue will see an abrupt disconnect instead of a clean one," which is what the
  warning said every time. A warning that fires on the normal path is noise that trains
  a reader to stop reading `[Webull Feed]` warnings at all — the same failure mode a red
  CI run for a non-failure was fixed for earlier in this package's history.

  `Feed.terminate/2` now logs `:not_alive` and `:calling_self` at `:debug`, and warns as
  before for every other reason — a genuine send failure against a socket that was alive
  and reachable, where the venue really will see an abrupt disconnect. Nothing about
  *when* `DISCONNECT` is attempted changed; only which outcomes are worth a warning.

- **`capabilities/0` under-declared `historical_timeframes` and `reports_trade_volume` —
  both true crypto-only facts generalised to the whole venue.** Found by a
  documentation-accuracy sweep (the one behind commit `94ea0a8`) that deliberately left
  code untouched; this is the code-side fix it called for, run through the full gates.
  `historical_timeframes` named the eight crypto/event-contract widths only
  (`1m 5m 15m 30m 1h 2h 4h 1d`) and omitted `1w`, `1M` and `1y`, which
  `Rest.get_stock_bars/5`'s `@stock_timespans` map has served — and this package's own
  tests have exercised — on the equity, option and futures bars since that endpoint
  shipped. `reports_trade_volume` was unconditionally `false`, though `Rest.get_price/3`
  with `category: "US_STOCK"`/`"US_ETF"` has always carried a real day-aggregate
  `volume`. `Core.Capabilities` has one flat list and one flat boolean for the whole
  package, with no way to say "true for equities, false for crypto" — reported upstream
  as a gap in `dp_exchange_core`'s expressiveness rather than worked around here.
  `historical_timeframes` is now `Rest.wide_timeframes/0` minus `1y` (see below);
  `reports_trade_volume` is now `true`. Both fields' crypto exception is spelled out in
  `measured_against`, `Webull`'s and `Rest`'s moduledocs, and `usage-rules.md`, and both
  are still enforced per-call: a crypto or event-contract `get_historical_prices/5` still
  refuses `1w`/`1M`/`1y` rather than degrading to the nearest width, and a crypto
  `get_price/2` still returns `nil` volume rather than a number.

  **`1y` surfaced a genuine `dp_exchange_core` gap and is reported, not worked around.**
  `Rest.get_stock_bars/5` serves `1w`, `1M` **and `1y`**, but `dp_exchange_core` 0.1.48's
  `Timeframe.nameable/0` — the vocabulary `Capabilities.new/1` validates
  `historical_timeframes` against — admits `1w` and `1M` beyond what it can bucket and has
  no entry for `1y` at all. Declaring `1y` here raises `Capabilities.new/1`'s own
  validation, so `historical_timeframes` names ten widths, not eleven, and `1y` stays
  reachable only by calling `Rest.get_stock_bars/5`/`get_historical_prices/5` directly.
  This is a Core vocabulary gap, not a decision made here — flagged for
  `dp_exchange_core` to widen `Timeframe.nameable/0` by one more width rather than
  silently narrowed to fit, invented a boundary rule for, or substituted with a
  neighbouring width. See `webull.ex`'s `@core_unnameable_widths` for the full account.

  **A consumer routing on the old declaration changes behaviour.** One that read
  `reports_trade_volume: false` and routed all Webull volume work to another venue was
  needlessly discarding a real, reachable equity signal; one that read
  `historical_timeframes` as the ceiling of what `get_historical_prices/5` could serve
  and never asked for `1w`/`1M` on an equity, option or futures symbol was doing the
  same for those three widths. Neither previously received a wrong *value* — the
  under-declaration only ever caused a consumer to route around a call it could safely
  have made.

### Removed — breaking

- **`MqttPacket.subscribe/2` deleted.** Found by `dp_exchange_core`'s new "16. internal
  wiring" conformance assertion: nothing in this package's `lib/` ever called it. Traced
  rather than assumed dead — this venue's own documentation
  (`docs/reference/webull/streaming-api.md`) states plainly that "subscriptions are not
  managed over MQTT" and are HTTP calls instead (`DpExchange.Webull.Subscription`), so an
  MQTT `SUBSCRIBE` packet was never the mechanism this venue uses. `SUBACK` decoding
  (private, unreachable without a `SUBSCRIBE` ever going out) is removed with it. Anyone
  who called `MqttPacket.subscribe/2` directly — an internal module, not part of the
  facade, but a public function until now — has it removed under them; the real
  subscription surface is unchanged: the facade's own `subscribe/2`.

### Added

- **The MQTT `tick` topic is now streamed as `DpExchange.Core.Types.Trade` — the third
  kind `subscribe/2` delivers, alongside `Quote` and `TopOfBook`.** Found by the same
  conformance assertion as above: `QuoteProto.decode_tick/1` fully decoded the venue's
  documented `Tick` message and nothing ever called it — `Subscription`'s default
  `sub_types` never asked the venue for `TICK`, and `Socket` had no `tick`-topic clause to
  route a payload to if one had arrived. A genuine venue capability, built and never wired
  end to end. Fixed in all three places it broke: `Subscription`'s default `sub_types` now
  includes `"TICK"` (was `["SNAPSHOT", "QUOTE"]`, now `["SNAPSHOT", "QUOTE", "TICK"]`);
  `Socket` decodes the `tick` topic to `%DpExchange.Core.Types.Trade{}`; `Feed.kind_for/1`
  recognises it for `coverage_by_kind/1`. `capabilities/0`'s `streamable` now includes
  `:trades`. `Trade.id` is always `nil` on this venue — the streamed tape carries no
  per-print identifier, matching `get_trades/2`'s REST tape, which has the identical gap
  and already says so.

  **`TICK`'s inclusion in the default `sub_types` is read from
  `streaming-api.md`'s topic table, not yet confirmed against the live venue** — unlike
  `SNAPSHOT`/`QUOTE`, which are confirmed live (DpCryptoManagement's issue #19).
  `capabilities/0`'s `measured_against` says so explicitly. If the venue answers `TICK`
  differently than documented, that surfaces through `Feed`'s existing generic-subscribe-
  failure handling, the same as any other refusal `Subscription` hands back.

- **`DpExchange.Webull.live?/1`** — whether the environment `opts` resolves to moves real
  money, resolved through the same precedence every call on this venue uses. Same shape
  and same reasoning as `DpExchange.Gemini.live?/1`. Found unwired: `Environment.live?/1`
  existed and nothing in `lib/` called it — a safety check built and never given a way for
  a consumer to reach it, since only the facade is public API on this venue.

- **`DpExchange.Webull.adjusted?/1`** — whether bars of a timeframe on the equity/ETF tape
  are forward-adjusted. `Rest.adjusted?/1` was already fully built and documented for
  exactly this question ("a caller stitching two widths together needs to know") but had
  no facade entry point to be called through; `Core.Types.Candle` has no field to carry
  the answer on the bar itself, so this was always meant to be asked of the package
  directly, not read off a returned candle.

### Fixed

- **A clean shutdown now sends MQTT `DISCONNECT` on every still-connected shard.**
  `MqttPacket.disconnect/0` built the packet and nothing ever sent it — found by the same
  conformance assertion, and the one violation worth reasoning through rather than just
  wiring: MQTT 3.1.1 §3.14 makes `DISCONNECT` the protocol's normal-close signal, and its
  absence is what makes a broker treat a closed connection as abnormal. That is a protocol
  fact, not a venue-specific one, and this venue's documentation is silent on whether it
  changes the ~1-minute session-retention window either way — nothing here claims it does.
  `Socket.disconnect/2` sends the packet via `WebSockex.send_frame/3`, the only way to put
  a frame on an already-running `Socket` from outside its own callbacks; `Feed.terminate/2`
  calls it once per connected shard, and only for the reasons `GenServer` treats as normal
  termination (`:normal`, `:shutdown`, `{:shutdown, _}`) — never for a crash, where extra
  socket I/O on a connection that may be the reason for the crash is the wrong trade
  against a fast supervisor restart. `Feed.init/1` already traps exits (for shard-crash
  isolation), which is what makes `terminate/2` actually run on an ordinary supervised
  shutdown, without needing its own `handle_info({:EXIT, ...})` clause for that case.

  Found and fixed live during this work: `WebSockex.send_frame/3` answers `client ==
  self()` by *raising* `WebSockex.CallingSelfError` rather than returning an error, which
  a bare `catch :exit` does not stop. `Socket.disconnect/2` now guards `pid == self()`
  explicitly and its `catch` clause is broadened to any exception kind, so it holds its
  own "never raises" contract regardless of how `send_frame` fails underneath it.

- **`capabilities/0`'s `supported_instrument_types` no longer hand-copies
  `Rest.order_instrument_types/0`'s list — it derives from it.** The prior comment
  ("Five, because the order builder builds five... so this cannot drift") asserted the
  equivalence without anything checking it; `order_instrument_types/0` was itself unwired
  — nothing in `lib/` called it, the declaration it was "exposed because" of read a
  separate literal instead. A private `supported_instrument_types/0` now maps the
  order builder's five instrument types (`:crypto`, `:equity`, `:option`, `:futures`,
  `:event`) onto Core's four asset classes (`:crypto`/`:equity` both collapse to `:spot`)
  and the declaration is now the mapping, not a second list that could silently disagree
  with it.

- **`Environment.validate!/1` now checks membership in `known/0` instead of carrying its
  own separate, literal `[:production, :uat]` guard** — the same fix, same reasoning, as
  `DpExchange.Gemini.Environment`. `known/0` existed and nothing in `lib/` called it.

- **`SymbolFormat.to_canonical_symbol/1` and `to_exchange_symbol/1` now read the mapping
  through `mapping/0` instead of the private `@mapping` attribute directly** — the module's
  own moduledoc has always argued both directions must run through one mapping so they
  cannot drift; the accessor sitting unused beside the attribute it exposes was exactly
  that risk, even though the two held the same value today. `mapping/0` existed only as a
  conformance-suite seam and nothing in this package's own `lib/` called it.

- **Documented usage — `children = [{DpExchange.Webull, []}]`, no `:limiter` anywhere —
  made every streaming HTTP call fail closed with "Rate limiter unavailable", silently,
  for the whole tree's lifetime.** `Supervisor`'s own `init/1` started `Feed`
  with the bare `opts` the tree was given, so `Feed`'s own `resubscribe_opts` — built once
  there and replayed on every reconnect and every 60-second blind resubscribe thereafter —
  carried no `:limiter`. `Core.HttpClient.check_rate_limits/1` then resolved the limiter by
  `Config.opt(opts, :limiter, DpExchange.Core.DefaultRateLimiter)` — the bare module name —
  and nothing in this venue's supervision tree starts a rate limiter under that name, only
  under `Supervisor.limiter_name(opts)`, registered one line above the broken `Feed` child
  spec. `GenServer.whereis/1` on the bare name returns `nil`, and every subscribe,
  unsubscribe and blind resubscribe this package ever issued under the documented
  supervision form failed with `{:error, "Rate limiter unavailable"}` — proven live against
  a connected shard. `Feed.subscribe/3`'s own synchronous path for an already-connected
  shard (`touch_primary_shard/7`, via `reconcile_now/4`) has the identical gap one layer up:
  it reconciles using the **caller's** own `opts`, not `resubscribe_opts`, so the facade's
  `subscribe/2`, `unsubscribe/2` and `update_symbols/2` needed the same default a caller who
  never names `:limiter` was always going to hit. Fixed in both places —
  `Supervisor`'s own `init/1` now defaults `Feed`'s child spec `:limiter` the same way
  `with_limiter/1` already does for every REST-backed facade function, and `subscribe/2`,
  `unsubscribe/2` and `update_symbols/2` now call `with_limiter/1` too, where before they
  forwarded `opts` unchanged. Tests added in `test/dp_exchange/webull_test.exs` prove both
  halves: that a tree started the documented way wires `Feed`'s own `resubscribe_opts` to
  the limiter it actually started, and that `subscribe/2` reaches the venue without the
  caller naming one.

- **The protobuf decoder's one nested field (`Basic basic = 1`) kept the FIRST occurrence
  on a repeated wire encoding instead of the LAST, inconsistent with `scalar/1`'s own
  documented proto3 rule for a repeated scalar** — the exact bug class this module's own
  moduledoc already records an incident for, now found in the one place that rule was not
  actually applied. `decode_nested/1`'s list clause now filters to the binary occurrences
  and decodes the last one, matching `scalar/1`.

- **A plain `STOP_LOSS` order built by `place_order/3` carried no trigger price at all, and
  a `TRAILING_STOP_LOSS` order carried no trail distance — an architect-directed audit
  finding.** `replace_order/4`'s own field table (read from the vendor's reference) names
  `stop_price` for **both** `STOP_LOSS` and `STOP_LOSS_LIMIT`, and `trailing_stop_step` for
  `TRAILING_STOP_LOSS` — all three are real, `@combinations`-listed order types for equity,
  option and futures instruments. `order_leaf/3`'s `stop_for/2` only attached `stop_price`
  when the venue's wire name was `"STOP_LOSS_LIMIT"`, and never attached
  `trailing_stop_step` for any order type at all. A caller placing a genuine stop-loss or
  trailing-stop order therefore had the one field that makes it that order type silently
  discarded before the request ever reached the venue — the single most expensive shape of
  substitution this family names, because the order still looks well-formed and the venue
  either rejects it for a reason the caller cannot connect back to a missing field, or
  (worse) accepts it with no trigger configured at all. No test exercised a plain `:stop`
  order's body at all, and the one existing `:trailing_stop` test asserted only
  `order_type`/`time_in_force` on the wire, never `trailing_stop_step` — the exact "test
  proves the wrapper, not the wire" seam this family has shipped bugs through before.

  `price_for/2` was tightened the same pass: it used to attach `limit_price` for any
  non-`MARKET` order type, so a `STOP_LOSS` request built from a limit-order template (with
  `:price` still set) would have sent a `limit_price` the venue's schema for that order type
  does not have. It now attaches `limit_price` only for `LIMIT` and `STOP_LOSS_LIMIT`, the
  two types the vendor's own table lists it for.

  Fixed in `lib/dp_exchange/webull/rest.ex`'s `order_leaf/3`, `price_for/2`, `stop_for/2`
  and a new `trailing_stop_step_for/2`. Tests added in
  `test/dp_exchange/webull/instrument_orders_test.exs` assert the actual wire body for a
  plain `STOP_LOSS` (carries `stop_price`, no `limit_price`), a `STOP_LOSS_LIMIT` (carries
  both), and a `TRAILING_STOP_LOSS` (carries `trailing_stop_step`).

- **The same audit found the read side of the same field missing too: `stop_price` never
  came back on an `Order`, anywhere.** `Core.Types.Order` carries `:stop_price` for exactly
  this purpose, and this package sends it on `place_order/3` and `replace_order/4` (once
  the fix above landed), but:
    - `to_placed_order/4` — the struct `place_order/3` hands back immediately — never
      echoed it from the request, unlike `price` and `quantity`, which it already did.
    - `to_order/1` — the real decode path behind `get_order/3` and `get_orders/2` — never
      read it from the venue's row at all, under either of the venue's usual
      `stop_price`/`stopPrice` names (the same dual-naming convention already proven
      correct for `limit_price`/`limitPrice` on the same row).
    - `Fake.place_order/3` had the identical gap as `to_placed_order/4`, which would have
      let a consumer's suite go green against the fake while the real path answered `nil`
      — a `usage-rules/testing.md` violation ("never differently capable") this audit also
      checked for and found here.

  A caller placing a stop-loss or stop-limit order and then reading it back — by any of
  the three paths this package offers — got `stop_price: nil` regardless of what was sent
  or what the venue reported. Fixed in all three; tests added in
  `test/dp_exchange/webull/order_mapping_test.exs` (both wire-name forms, and that an
  ordinary order still carries `nil` rather than picking up a stray value),
  `place_order_test.exs`, and `fake_test.exs`.

- **Two `feed_test.exs` tests synchronised on async work with a fixed `Process.sleep/1`
  instead of an event — flaky under load, and exactly the anti-pattern this family has
  shipped CI-only failures through before.** One slept 20ms hoping a `send/2`'s
  `handle_info` had already run before asserting `Process.alive?/1`; fixed by replacing the
  sleep with a `Feed.coverage/1` call, which — being a `GenServer.call` — queues behind the
  earlier `send` in the mailbox and so cannot return before it was processed, the same
  pattern already used elsewhere in this file. The other slept 100ms hoping
  `isolate_crashed_shard/3` had already rebuilt `state.shards` before asserting on
  `:sys.get_state/1` — `:sys.get_state/1` answers over OTP's system-message channel and is
  not guaranteed ordered after a regular mailbox message, so the sleep was load-bearing
  and still a race even with it; fixed by subscribing to notices first and asserting
  `assert_receive {:dp_exchange, :webull, %Notice{kind: :link_down}}`, which
  `isolate_crashed_shard/3` fans out synchronously inside the same handler that rebuilds
  the shard map.

- **A third `feed_test.exs` test — the `rate_limit_blocking` regression test itself —
  flaked under full-suite load with a too-tight `assert_receive` window, not a
  `Process.sleep/1` this time.** "the blind resubscribe defaults to blocking" forces a
  real ~300ms wait inside `acquire/3` (via `exhausted_limiter/0`'s spent single-token
  bucket) before its stubbed HTTP call is even sent, on top of the process-hop latency
  `test_helper.exs`'s own `assert_receive_timeout: 1_000` exists to absorb — so the global
  1_000ms default was not enough headroom for this test specifically, on top of that. It
  reproduced under a full 700-test async run (`mix test --seed 849478`) while passing in
  isolation every time. Given its own explicit `assert_receive/2` timeout, widened to
  `5_000` — margin over the ~300ms wait, not a weakened assertion, since the test still
  fails if the message never arrives at all.

### Added

- **A shard's blind resubscribe failing for a generic reason now surfaces as a
  `Core.Notice` too, latched per shard — DpCryptoManagement's issue #23.** The 60-second
  blind resubscribe timer (see the moduledoc's "The resubscribe timer must never
  fail-fast") already had two structured, caller-visible outcomes for a shard's HTTP
  subscribe failing: `:oversubscribed` rebalances silently, and `{:invalid_symbols,
  symbols}` gets its own `:refusal` notice (issue #24, above). Everything else an
  `{:error, reason}` could be — the rate-limiter throttling that issue #23 itself is
  ("Throttled by our own rate limiter (not the venue)"), an HTTP 5xx, a transport error —
  fell through `handle_subscribe_result/3`'s catch-all clause to a `Logger.warning` and
  nothing else. Issue #23's own numbers are the cost of that gap: a node restart, all 4
  shards linking up cleanly, then 58 consecutive blind-resubscribe failures across 13
  minutes, every one the identical refusal, found only because a human went grepping this
  module's own log for the sentence it had been repeating the whole time.

  `Core.PollingFeed`'s own `:on_notice` — added per DpCryptoManagement's issue #21, the
  poll-feed sibling of this same gap ("a feed that knows it has delivered nothing now
  says so on a channel a consumer can act on, not only in a log line") — is the pattern
  this follows, applied to a shard's resubscribe rather than a whole feed's fetch cycle:
  a `%Core.Notice{kind: :coverage_change}` fires the instant a shard's blind resubscribe
  crosses INTO this generic failure, and a `severity: :info` recovery notice fires the
  instant it crosses back OUT. `:coverage_change` is reused rather than inventing a new
  kind, for the same reason issue #21's own entry gives: "subscribed intent not becoming
  delivery is exactly what a feed delivering nothing is," and a shard whose resubscribe
  keeps failing is exactly that, one shard at a time.

  Latched **per shard** (`state.resubscribe_failed`, a `MapSet` of currently-failing
  shard indices) rather than globally, because each of this venue's up to 5 shards is its
  own independent MQTT session with its own independent failure and recovery schedule —
  a global latch would either swallow a second shard's own transition while the first
  stayed latched, or, left unlatched altogether, fire a fresh notice from every still-
  failing shard on every single 60-second tick during a widespread outage. A notice storm
  is its own defect, exactly as issue #21's design already established. The existing
  `Logger.warning` keeps firing every tick regardless, unchanged — this notice is
  additive, not a replacement. The latch for a crashed shard's index is cleared the
  moment `isolate_crashed_shard/3` tears that shard down for reopening: the freshly
  reopened connection has never itself failed a resubscribe, and firing a "recovered"
  notice for it the moment its first resubscribe merely succeeds would be reporting a
  recovery from a failure the new connection never had — the crash itself is already
  reported separately, via the existing `:link_down` notice.

### Fixed

- **17 venue-rejected symbols were blocking all 342 of a consumer's pairs from streaming,
  permanently — DpCryptoManagement's issue #24.** Webull's subscribe is rejected
  **per request, not per symbol**: one symbol its streaming category does not carry fails
  the entire shard's batch. The venue answers `HTTP 417 INVALID_SYMBOL` and names the
  offending symbols in `message` (`"The symbols does not exist in the category.
  [BNBUSD]"` for one, a comma-separated bracketed list for several — confirmed against the
  real response shape and against `DpCryptoManagement.Data.Collection.VenueRefusalsTest`'s
  own fixture), byte-for-byte identical every 60-second resubscribe tick, forever — because
  nothing downstream could act on it. `Subscription.subscribe/3` collapsed the whole
  response into an opaque `{:exchange_error, :webull, "HTTP 417: ..."}` string, the
  treatment its sibling `TOO_MANY_SYMBOLS_SUBSCRIPTION` was deliberately spared (see that
  clause's own comment). Measured consumer impact: `stream_covered` 0/342, every pair
  falling back to REST polling, which is where the sustained HTTP 429 storm from issue #23
  came from.

  `Subscription` now matches `INVALID_SYMBOL` specifically, parses the venue's own named
  symbols out of `message`, and converts them back to canonical form
  (`SymbolFormat.to_canonical_symbol/1`) before returning `{:error, {:invalid_symbols,
  [canonical_symbol, ...]}}` — mirroring `:oversubscribed`'s existing structured shape. A
  message the parser cannot attribute to any symbol falls through to the previous opaque
  error rather than inventing an empty exclusion list — a rejection nobody can attribute is
  not one `Feed` can act on.

  `Feed` records each rejected symbol with a 24-hour expiry (`state.rejected`, overridable
  via `opts[:rejected_symbol_ttl_ms]` — deliberately the same order of magnitude as
  `DpCryptoManagement.Data.Collection.VenueRefusals`' own TTL for exactly this shape of
  fact: a venue's streaming catalogue is true at a point in time, not permanently) and
  excludes unexpired entries from `plan_reshard/1`'s effective wanted set, so the next
  chunk built for an affected shard carries only symbols the venue actually accepts. A
  rejection is retried immediately within the same call via the existing
  `reshard_step/4` retry (same mechanism as `:oversubscribed`), so a caller's own
  `subscribe/3` still returns a clean `:ok` for the good symbols despite the shard's first
  attempt being refused. `state.wanted` is never pruned — only what's currently eligible for
  shard composition shrinks — so a symbol's exclusion lapses on its own once the TTL expires
  and the next resubscribe tick's `resync/1` (now also run whenever `state.rejected` is
  non-empty) places it back into a shard, with nobody calling `update_symbols/2`.

  Also emitted as a `Core.Notice` — `:refusal`, Core's own documented kind for "a symbol
  the venue will not carry" — naming the rejected symbols in canonical form, since a symbol
  excluded from shard composition never appears (or fails to appear) in `coverage/1` either
  way, and a notice is the only way a consumer learns why 17 of its 342 symbols stopped
  being tried. This is what lets a consumer's own venue-refusal cache (e.g.
  `DpCryptoManagement.Data.Collection.VenueRefusals`) populate for this venue for the first
  time.

### Added

- **`coverage_by_kind/1`, `dp_exchange_core`'s new optional contract callback (`~> 0.1.48`,
  bumped from `~> 0.1.36`).** `coverage/1` reports one `:stream`/`:not_covered` boolean per
  symbol, folding every streamed kind into it — which is exactly how a Coinbase venue in
  this family once reported full coverage for hundreds of symbols while one of its two
  streamed kinds had gone dark for nearly all of them, the discrepancy hidden behind the
  single boolean across two issues. This venue genuinely has the same shape to protect
  against, not a formality adopted only for cross-venue uniformity: every subscribe asks
  for both `SNAPSHOT` and `QUOTE`, and `Socket` decodes them on separate topics into two
  different structs that can go dark independently — `snapshot` into `Core.Types.Quote`
  (kind `:quotes`), `quote` into `Core.Types.TopOfBook` (kind `:top_of_book`). `Feed` now
  tracks arrivals per kind (`delivering_by_kind`, alongside the existing `delivering`) and
  derives the kind from the struct type that actually arrived (`kind_for/1`) rather than
  assuming it from `capabilities/0` — so a third kind reaching the feed without a matching
  case here is logged loudly instead of silently folded into an existing one. Verified
  against Core's own conformance suite, assertion group 15, which asserts
  `coverage_by_kind/1`'s symbol union equals `coverage/1`'s keys exactly and that every kind
  key it reports is one `capabilities().streamable` declares — both now run against this
  venue for the first time (previously skipped: the callback did not exist) and both pass.
  `Fake.coverage_by_kind/1` reports a single `:quotes` key, honestly: the fake's
  `subscribe/2` only ever builds a `Types.Quote`, never a `Types.TopOfBook`, and "less
  capable is allowed, differently capable is not" means it must not claim a second kind it
  cannot produce.

### Fixed

- **`capabilities().streamable` said `[:quotes]`; this venue has always also streamed
  `:top_of_book`.** Found while implementing `coverage_by_kind/1` above, which requires
  naming a kind for every struct actually delivered — deriving one honestly for
  `Core.Types.TopOfBook` and then declaring it undeclared would have been exactly the kind
  of self-contradiction Core's own conformance suite checks for. Not a new venue capability:
  `Subscription`'s default `sub_types` has always requested both `SNAPSHOT` and `QUOTE`,
  and `Socket`'s `quote`-topic clause has decoded to `Core.Types.TopOfBook` since the
  bid/ask-as-price fix recorded in its own comment (a real quoted number is not a traded
  price — a bid is a resting order, a price is an execution). Both kinds have therefore
  always reached a subscriber; `streamable` simply never caught up when the `TopOfBook` fix
  landed. A consumer reading `streamable: [:quotes]` had no reason to expect a
  `%DpExchange.Core.Types.TopOfBook{}` on its subscriber's mailbox at all, and may not even
  have pattern-matched on one. `usage-rules.md` and `README.md` are corrected alongside —
  both are shipped in the Hex tarball and both previously implied a single streamed kind.

### Documentation

- **`README.md` and `docs/reference/webull/endpoint-inventory.md` both stated stale
  endpoint counts — "44 of 87 `:experimental`, 43 `:unsupported`" — a snapshot from
  db17ff3 (2026-09-03 09:33) that went stale that same afternoon when `2f6c65b`
  (2026-09-03 13:43) moved `get_fees/2` and `quantization/1` out of `@not_ported`, and
  neither document was told. Verified by calling `capabilities/0` directly rather than
  reading `@unsupported`/`@not_ported` by eye: `mix run -e` against
  `DpExchange.Webull.capabilities().endpoints` on 2026-09-05 counts 46 `:experimental` and
  41 `:unsupported` (87 total, unchanged), of which `venue_does_not_serve/0` still names
  30 as the venue's own absence and 11 remain not yet ported (was 13). Both documents
  corrected to 46/41/11; `endpoint-inventory.md` also now records the correction with its
  own evidence rather than silently overwriting the old figure.

  Audited against this release's other claim under the same suspicion — that
  `order_type`/`time_in_force` round-trip for all five declared values each, per the W1 fix
  below — by actually running the encode/decode round trip in code for every declared
  value of both, rather than trusting the fix's own description: all five order types
  (`market`, `limit`, `stop`, `stop_limit`, `trailing_stop`) and all five time-in-force
  values (`ioc`, `day`, `gtc`, `gtd`, `fok`) decode back to the atom that encoded them.
  Neither `usage-rules.md` nor `README.md` made a claim about this narrower than what
  `capabilities/0` already declares, so there was no stale warning to remove — this is
  recorded here as the evidence that the audit looked, not as a document fix.

### Added

- **`Fake` wired to `Core.FakeInjection` — DpCryptoManagement's issue #14.** Every
  function with a real success path (not an unconditional `Venue.not_supported()`) now
  checks a queued or always-set outcome first. Symbol-taking functions
  (`get_price/2`, `get_top_of_book/2`, `get_historical_prices/4`, `get_order_book/2`,
  `get_trades/2`, `get_volume_profile/3`, `get_auction_imbalance/2`, `quantization/2`,
  `get_option_chain/2`, `get_option_expirations/2`, `get_financials/3`, `get_filings/2`)
  support per-symbol targeting; the rest (`get_symbols/1`, `get_balances/2`,
  `get_accounts/2`, `get_fees/2`, `get_transfers/2`, `get_transactions/2`,
  `preview_order/3`, `replace_order/4`, `market_status/1`, `get_positions/1`, the
  watchlist functions, `get_corporate_events/1`, `get_news/1`, `get_screener/2`,
  `place_order/3`, `cancel_order/3`, `get_order/3`, `get_orders/2`) support whole-call
  injection. `authenticated/1` also honours `FakeInjection.credentials_bypassed?/1` for
  wiring-only tests, without changing the venue-faithful default for anyone who doesn't
  opt in. `subscribe/2`, `unsubscribe/2`, `update_symbols/2` and `place_orders/3` are
  deliberately not wired — each takes a list (symbols or orders) in one call, which
  whole-call injection cannot express partial failure for. Follows the reference
  implementation shipped in `dp-exchange-robinhood`; the shared mechanism itself lives in
  `dp_exchange_core`.

- **`Feed` shards across multiple MQTT sessions — DpCryptoManagement's issue #13.** A
  single session caps out at the venue's own stated ceiling
  (`"Maximum number of subscribe tickers:100"`); a consumer with more than 100 symbols on
  this venue could not reach full coverage through one session no matter how the HTTP
  calls were split, since the limit is per-session, not per-request. `Feed` now opens up
  to five sessions (the venue's own per-App-Key ceiling) and partitions symbols across
  them internally — the host still only ever calls `subscribe/3` with a symbol list and
  never learns a shard, session id, or connection count exists.

  Adapted from `dp-exchange-coinbase`'s own `Feed`, which shards for the identical
  reason: recompute from the full wanted set on every call, touch only what changed, one
  shard synchronous per call (its outcome is the reply) and the rest staggered. What
  differs here is the leaf operation — this venue's shard identity is *also* its MQTT
  session, so a brand-new shard waits for its own CONNACK (reusing the #9 fix, now
  per-shard) before its first HTTP subscribe means anything to the venue.

  **A shard that rejects a batch as oversubscribed is rebalanced internally, never
  surfaced to the host as something to route around** — the affected symbols move to
  another shard with room (opening one if needed) and the subscribe is retried. Per the
  design doc §3.5, this was an explicit architectural requirement, not a nice-to-have:
  the host must never be handed a shard index or session id to reason about. Only every
  shard already full and the venue still refusing — a genuine capacity ceiling this
  package cannot paper over — surfaces as a real `{:error, {:capacity_exceeded, symbols}}`.

  `@pairs_per_socket` is exactly the venue's own stated **100**, not a guessed margin
  below it — see the design doc §3.1 for why padding an already-stated number would be
  the same unlabeled guess this family's conventions rule out elsewhere.

  See `docs/design/2026-09-04_webull-sharding-and-fake-injection.md` in
  `dp-exchange-core` for the full design.

- **`get_fees/2` and `quantization/1` are implemented.** Both had sat in `@not_ported`
  since Phase 2 with no comment recording why — DpCryptoManagement's own filed questions
  (issues #5, #6 against `dp_exchange_core`) were right that the classification did not
  distinguish "checked and absent" from "never looked".

  `quantization/1` reads the same `instruments/.../profiles/list` endpoint `get_symbols/1`
  already calls. Checked the vendor's live schema before writing anything: **crypto and
  stock rows are disjoint, not the same shape with some fields blank.** Crypto carries
  `price_step`, `lot_size`, `min_trade_qty`, `max_trade_qty`, `min_trade_amt`,
  `max_trade_amt` — all six. Stock/ETF carries `lot_size` alone; no price step, no per-unit
  or per-cash min or max anywhere on the row. A stock symbol now answers with
  `quantity_increment` and every other field `nil`, not the crypto shape reused because it
  was already written.

  `get_fees/2` required checking two different products before answering. Trading API — the
  one this package speaks — has no fee-schedule endpoint anywhere in its surface, checked
  across `Instruments`, `Accounts`, `Assets` and `Activities`. What carries the name "Fees
  and Credits" lives entirely in **Broker API**, and is an administrative interface for a
  broker crediting or debiting a sub-account — not a schedule a caller queries, and out of
  reach on principle (D8) as well as on credentials. What the venue does publish, on
  `webull.com/pricing`: a single flat **1.00% crypto spread, charged by Webull Pay/Bakkt**,
  the same for every account. `get_fees/2` returns that captured, dated rate rather than a
  live per-credential lookup, because there is no live lookup to make — the rate does not
  vary by credential to look up.

### Fixed

- **The blind resubscribe timer's own rate-limit retry could never actually reach
  `Core.HttpClient` — DpCryptoManagement's issue #23.** Live evidence, from a node
  restart: all 4 MQTT shards linked up cleanly, then **58 consecutive blind-resubscribe
  failures across 13 minutes**, every one the identical refusal —
  `{:exchange_error, :webull, "Throttled by our own rate limiter (not the venue) — retry
  after 1s; callers that can wait should set rate_limit_blocking: true"}`. The refusal
  asks for a one-second wait; `@resubscribe_interval_ms` is 60,000 — so fail-fast
  (`check/3`) on this timer meant every tick was dropped for a full minute to avoid
  waiting a second. Measured consumer impact: **0 of 342 pairs streaming**, all of them
  falling back to REST polling. It also made the venue's own transient, ordinarily
  self-healing `INVALID_SYMBOL` rejections on an initial subscribe permanent, because
  recovery from those runs through this same blind resubscribe.

  `:rate_limit_blocking` — the option `Core.HttpClient.check_rate_limits/1` reads to
  choose `acquire/3` over `check/3` — was missing from every allowlist on the path a
  blind resubscribe actually takes: `Feed`'s own `resubscribe_opts` (built once in
  `init/1`), `replayable/2` (what carries it forward across every later subscribe), and
  `Subscription.request_opts/1` (the last allowlist before `Core.HttpClient` itself).
  **Fixing only the two in `Feed` — what the filed issue suggested — would have shipped a
  change that reads as a fix and does nothing**: the option would still be silently
  stripped one layer down, by `Subscription.request_opts/1`, before `Core.HttpClient`
  ever saw it. All three now forward it. Only `Feed`'s own opts default it to `true` —
  the resubscribe timer runs off a 60-second clock with nothing waiting on its result, so
  blocking for a second is free — following `dp_exchange_robinhood`'s `Feed` precedent
  for the identical shape (its own issue #16) exactly: `Subscription.request_opts/1`
  forwards the option without defaulting it, since a caller invoking `Subscription`
  directly, one-off, may legitimately want fail-fast, and this module must not decide
  that for it. An explicit caller-supplied `rate_limit_blocking: false` still wins over
  the default, at both `init/1` and every later `replayable/2` call.

  Proven end to end with a real, pre-exhausted `Core.DefaultRateLimiter` (named, passed
  via `:limiter` — a `Config.put_override` in the test process is not visible inside the
  separately-started `Feed` GenServer): the resubscribe's HTTP call reaches the stubbed
  venue in blocking mode by default, an explicit `rate_limit_blocking: false` at start
  keeps it fail-fast, and a later `subscribe/3` call's own explicit `false` overrides the
  default on the very next resubscribe tick via `replayable/2`.

  **Additional gap found while tracing this, and fixed for consistency**:
  `Webull.Rest.request_opts/1` (the allowlist for every other REST call this package
  makes — accounts, orders, market data) had the identical missing-allowlist gap, for the
  same reason a one-off `Subscription.subscribe/3` call must not have blocking imposed on
  it: not defaulted, forwarded only, matching `dp_exchange_robinhood`'s `Rest`.

- **The socket's connect budget was inherited by accident, not chosen — family-wide defect
  sweep, W6.** `Socket.start_link/1` passed no options to `WebSockex.start_link/4`, so it
  silently accepted the dependency's general-purpose defaults: `socket_connect_timeout:
  6_000` and `socket_recv_timeout: 5_000` (measured in
  `deps/websockex/lib/websockex/conn.ex:10-11`). That is 11 seconds of `Feed`'s own 15-second
  `@call_timeout` spent on TCP and the HTTP upgrade *before* this venue's CONNACK is even
  awaited — and a shard is not usable until the broker accepts its session id, so the
  CONNACK wait and the HTTP subscribe both have to fit in the same call too. `Feed` is a
  named, shared process, so an unreachable venue made every other consumer's queued
  `subscribe`/`unsubscribe`/`coverage` wait out that window as well.

  Now set deliberately to 3s and 2s, chosen against that budget and documented with the
  arithmetic, both overridable and forwarded from `Feed.start_link/1`. This changes no
  failure semantics — `start_link/1` still returns `{:error, reason}` synchronously exactly
  as before. The regression test asserts the values reach `WebSockex` and that overrides
  win, so a later refactor cannot quietly fall back to the dependency's defaults.

- **`order_type`/`time_in_force` silently lost 2 of 5 declared values each on
  round-trip — family-wide defect sweep, W1.** `order_type_atom/1` and `tif_atom/1`
  hand-listed only 3 of the 5 values their own forward encoders (`@order_type_names`,
  `@tif_names`) produce; `capabilities/0` declares all five of each supported. A caller
  placing or reading back a `:stop`, `:trailing_stop`, `:gtd` or `:fok` order — every one
  a genuinely real order this package itself sent — got `nil` on that field, not an
  error. Fixed by deriving the reverse lookup maps from the same source maps the forward
  encoders use, so the two vocabularies cannot drift apart again; a value this package
  truly does not recognise still decodes to `nil`, unchanged. `Fake.place_order/3` was
  also changed to round-trip an order's type and TIF through the real encode/decode
  functions (now exposed publicly for this reason) instead of handing the caller's atom
  straight back — the previous shape could not have caught this class of bug at all.

- **A shard's socket crash took down the whole `Feed`, not just that shard —
  family-wide defect sweep, W2.** `Socket.start_link/1` links to `Feed` (ordinary
  `WebSockex.start_link/4` behaviour), and `Feed` never trapped exits, so any abnormal
  socket exit — an uncaught exception in a callback, an internal `websockex`/`gun`
  failure — killed every shard's connection and every symbol's coverage, not just the one
  that failed. The opposite of the isolation `reshard/4`, `resync/1` and the resubscribe
  timer all otherwise provide. `Feed` now traps exits; a crashed shard is logged, reported
  as a `:link_down` notice, any caller with a reply pending on it answered
  `{:error, {:shard_crashed, reason}}` rather than left to time out, and the shard is
  reopened at the same index with the same wanted symbols — the ordinary
  CONNACK-then-resubscribe path brings it back exactly as a first open would. Every other
  shard is untouched throughout.

- **The unconditional 60s resubscribe (and every other control-plane HTTP call) ran
  inline inside `Feed`'s own `handle_call`/`handle_info`, blocking the same mailbox that
  carries ticks — family-wide defect sweep, W3.** Worst case, up to five shards' blocking
  `Subscription.subscribe` round-trips (measured ~118ms each) ran sequentially inside one
  `handle_info`, once a minute, stalling delivery for every shard — including shards the
  resubscribe was not even touching — for the whole duration, by design. Every such call
  now runs in its own task under a `Task.Supervisor` `Feed` owns; a caller's `subscribe/3`
  still does not receive its reply until the real HTTP round trip finishes (unchanged
  observable contract, via a deferred `GenServer.reply/2`), but the mailbox stays free to
  keep draining ticks from every shard while that round trip is in flight. The
  oversubscribed-retry behaviour and the capacity-aware rebalance are unchanged.

- **Shard assignment was recomputed from scratch on every call, so one newly-added
  symbol could touch every shard — family-wide defect sweep, W4.** `derive_shards/2`
  sorted the *entire* wanted set and cut it into fixed-size chunks; a symbol that
  happened to sort early shifted every symbol after it across every shard boundary,
  unsubscribing and resubscribing symbols that had nothing to do with the change —
  contradicting the moduledoc's own "touch only what changed" design claim and spending
  calls from the tightest budget in the family. `derive_shards/3` now takes the existing
  shard assignment and is sticky: a symbol already assigned keeps its shard for as long
  as it is still wanted and still fits that shard's measured capacity; only genuinely new
  symbols, and anything just evicted by a capacity reduction, get placed into whichever
  shard (in index order) still has room.

- **`sub_types` was sent lowercase, and every subscribe was rejected `HTTP 417
  UNSUPPORTED_SUB_TYPE "Subtype not supported:quotesnapshot"` — DpCryptoManagement's
  issue #19, filed immediately after issue #18's fix unblocked the request enough to
  reach this validation for the first time.** `Subscription.post/4` defaulted
  `"sub_types"` to `["snapshot", "quote"]`, a comment mislabelling them as "the venue's
  own topic names" — they are not: `quote`/`snapshot` lowercase is the MQTT topic
  namespace a connected session receives on, a different field on a different protocol
  from the REST subscribe body's `sub_types`. The reporter's own retired in-repo client
  proved the working values: `["SNAPSHOT", "QUOTE"]` uppercase, sent against this same
  endpoint for months. The venue's own error text is the two rejected values joined with
  no separator — `"quote"` + `"snapshot"` — which is what made the fix legible rather
  than a guess. Default changed to uppercase; nothing else about the request shape
  changed, since it was already sending a proper array, never a joined string.

- **Every signed request went out with no `Content-Type` at all, and the venue's
  streaming-subscribe endpoint rejected every one with `HTTP 415 "Request media type
  not support"` — DpCryptoManagement's issue #18. Streaming never delivered a tick.**
  `Auth.headers/2` never declared a media type for any request, signed or not. The
  reported symptom was specifically the streaming subscribe/unsubscribe calls, but the
  same gap reached every JSON-bodied signed POST this package makes, `place_order`
  included — found while reading `Auth.headers/2` directly rather than patching only the
  reported call site. Fixed at the source: `Content-Type: application/json` is added
  whenever a signed request carries a body; a GET's body is `""` and stays bare, correctly.
  Not one of the six header pairs the signature itself covers, so this cannot desync a
  request from what was actually signed.

- **`Feed` had no periodic resubscribe safety net, unlike the sibling `dp_exchange_coinbase`
  package this one's sharding adapts from — DpCryptoManagement's issue #17.** This venue
  can stop delivering to an already-subscribed, already-connected session on its own —
  no error, no disconnect, no unsubscribe, nothing a health check can see.
  `dp_crypto_management`'s own prior MQTT client found this empirically: a blind,
  unconditional resubscribe on a timer, independent of whether the wanted set had
  changed, took live coverage from 47 symbols back to ~240. `reshard/4` alone cannot
  recover from this — it only touches a shard whose *wanted* symbol set changed, and
  re-asking for exactly what is already wanted computes an empty diff. Every connected
  shard's current subscription is now re-issued unconditionally every 60 seconds,
  matching the shape Coinbase's `Feed` already carries for its own reconnect case,
  applied here to a steady-state failure mode Coinbase does not have.

- **`Feed.fan_out/2` crashed on a subscriber registered by name — DpCryptoManagement's
  issue #15, same defect found on the sibling `dp_exchange_coinbase` package.**
  `subscribe/2`'s `to:` option accepts any value, and `fan_out/2` called
  `Process.alive?/1` on it directly — which only accepts a pid and raises on anything
  else. A consumer registering itself under a name (ordinary OTP practice) and handing
  that name to `to:` crash-looped the whole `Feed` GenServer on every delivery. Fixed by
  resolving a subscriber (pid or name) to a pid first, treating an unregistered name the
  same as a dead pid: silently skipped, never a crash.

- **`Feed` dropped `app_key` entirely, and never waited for the venue's CONNACK before
  subscribing over HTTP — DpCryptoManagement's issues #8 and #9.**

  `Feed.init/1` kept only `:url`/`:environment` from its own start opts, so `app_key`
  never reached `ensure_socket/2` — which silently defaulted to `""` rather than refusing.
  Credentials arrive per call in this family, same as every other venue, so the fix reads
  `app_key` from the subscribe call's own `credentials`, and refuses
  (`{:error, {:missing_required_field, :app_key}}`) rather than opening a socket that
  would connect and then sit unauthenticated where nothing visible said why.

  Separately, `ensure_socket/2` treated a live socket *process* as a ready socket — it
  returned as soon as `Socket.start_link/1` did, which is once the WebSocket is up, not
  once the venue's CONNACK has actually arrived. The HTTP subscribe that followed could
  race the venue's own auth handshake and name a session id it had not yet registered. A
  reconnect already waited for the `:link_up` notice before replaying; the first-ever
  subscribe against a fresh socket now does too — the reply is deferred and answered from
  the same `:link_up` handler, rather than fired inline.

- **`decimal/1` (`rest.ex`, `socket.ex`) admitted `"NaN"`, `"Inf"` and `"-Inf"` as real
  prices — DpCryptoManagement's issue #11.** The `Decimal.parse/1` fix for the `"null"`
  crash below was not a sufficient guard on its own: all three fully parse, and a NaN or
  Infinity flowing into downstream arithmetic as a real price is worse than the crash it
  replaced, since it poisons a calculation silently instead of failing where it happened.
  Both now also refuse via `Decimal.nan?/1` and `Decimal.inf?/1`.

- **`Decimal.new/1` raised on a non-numeric price string — the exact crash filed as
  DpCryptoManagement's issue #3.** Reproduced first: `Decimal.new("null")` raises, and a
  delisted Webull crypto pair is a real, previously observed shape that returns exactly
  that string for a price field. Fixed in both copies (`rest.ex`, `socket.ex`) with
  `Decimal.parse/1`, requiring the whole string be consumed — the family's established
  idiom, already used by `chain_strike/1` elsewhere in this package.

  The lenient fix alone would have introduced a second, quieter defect: a malformed
  required field silently becoming `nil` instead of raising, which `@enforce_keys` does
  not catch. `get_price/3`, the socket's own `emit_decoded/2`, `to_trade/2` and
  `decode_bar/3` now refuse the record instead (`{:error, {:invalid_decimal, field,
  value}}` or `{:error, {:missing_required_field, field}}`), rather than delivering a
  `Quote`, `Trade` or `Candle` with a fabricated-looking `nil` in a field the type
  promises is real. One test fixture in `order_book_test.exs` had itself been supplying
  an incomplete bar (missing `high`/`low`) that only worked because the old lenient
  behaviour tolerated it; corrected to a complete bar rather than loosened back.

### Documentation

- **`docs/reference/webull/endpoint-inventory.md`'s open question on the old
  `/openapi/...` paths is answered — family-wide defect sweep, W5.** It previously said
  "whether the old paths still resolve is not established here." Live-probed
  unauthenticated against `api.webull.com`, 2026-09-05: the current paths answer from
  `server: WEBULL OPENAPI` with a `400` naming a missing signing header (reaches the real
  backend); the old `/openapi/...` paths answer from `server: APISIX` with a `404 Route
  Not Found` (never leave the gateway in front of it). The old paths do not still
  resolve — the vendor retired the routes, not just their documentation — and this
  package no longer calls any of them (`documented_paths_test.exs` already guards that).
  No code change; the doc now records the answer with its evidence and date rather than
  leaving the question open.

- **The `:unsupported` list is now split.** `venue_does_not_serve/0` names the 30 endpoints
  that are Webull's own absence — staking, one-step convert, funding rails, greeks, bulk
  cancel, position closing — each with the source and date behind it; 13 stay under
  `@not_ported`, including `list_instruments/1`, which the instrument profile endpoints
  already back through `get_symbols/1` but which this callback has not been built against.
- **`README.md` states what the contract covers** — 44 of 87 callbacks `:experimental`
  across five asset classes.
- **`docs/reference/webull/endpoint-inventory.md`'s counts refreshed.** It read "5 of 85"
  until this release, from the pre-Phase-8 capture.

### Documentation

- **Every negative this package makes is audited** —
  `docs/reference/webull/negative-claims.md`, fourteen claims with the source and date
  consulted for each. Eleven hold; **three were wrong, and all three were the same mistake**:
  a true statement about the *stock* endpoint restated as a claim about the venue. The tell
  is in the wording — "the vendor states the stock snapshot does not serve it" is correct,
  and was used to justify a refusal that was not.

  It also records why this vendor's pages have to be **rendered** to be read: their
  parameter and schema tables are built in JavaScript, so a plain fetch returns the method,
  the path and a one-line description. **An inventory captured that way looks finished and
  cannot be implemented from** — which is exactly what the 2026-08-31 capture was.

- **`usage-rules.md` is rewritten around the surface this release added.** Its "what this
  package does not do yet" section listed order placement, balances and accounts as
  unimplemented; all of them ship. What replaces it points at `capabilities/0` and states the
  one group that will not arrive — money movement, which this venue's API does not do.

  New sections cover the five categories and why their parameter sets differ, event
  contracts' two prices and four books, the option chain and the greeks that do not exist
  here, the twenty-three fundamentals endpoints, watchlists' three absences and their
  boolean, batch orders, and the token lifecycle.

- **`AGENTS.md` gains a pointer** to this package's own `usage-rules.md`.

### Added

- **`place_orders/3` — batch order placement**, `POST /trading/orders/batch-place`. This is
  the last open endpoint in the coverage plan's implementation phases.

  **Not `place_order/3` in a loop.** The venue accepts the batch as one request; a caller
  that looped would reconcile N outcomes instead of reading one response, and the
  reconciliation is what goes wrong when the third of five fails.

  **Both of the venue's limits are enforced before the request.** A maximum of **50** orders,
  and **equities only** — its page says so in both cases. A batch over the cap is refused
  rather than split, because splitting turns one atomic request into several and undoes the
  only reason to call this. A non-equity order, or one outside the venue's own order matrix,
  is refused **by index**: a caller with fifty orders needs to know which.

  **The result is per order, because a partial batch is the normal shape.** The venue
  validates each and returns each; collapsing that into ok-or-error would let a caller
  believe "the batch failed" while holding four positions it does not know about.

  The vendor notes the endpoint is not available to every client, so a refusal can mean the
  account is not entitled rather than that the batch was wrong — the venue's own message is
  carried through unchanged.


- **The token lifecycle** — `create_token/1`, `check_token/2` and `oauth_token/3`.

  **A token that exists is not a token that works.** `create_token/1` returns one that is
  `PENDING`, and the venue's own note says verification happens through an SMS code in the
  Webull app — which needs a person and is not something this package can do. A caller
  treating a successful response as an authenticated session finds every subsequent call
  refused.

  **`check_token/2` is the only call that distinguishes the four states.** `PENDING` has
  never been verified, `EXPIRED` has run out, `INVALID` was revoked or never existed — all
  three fail identically at the next request and each has a different remedy, so the venue's
  own string travels unmapped rather than being collapsed into a boolean.

  **`oauth_token/3` is one endpoint doing two jobs on a different host.** `opts[:code]`
  exchanges the authorization code the host obtained; `opts[:refresh_token]` refreshes.
  Exactly one is required — both together is refused, because the venue would choose and the
  response would not say which. The host is `oauth-open-api…` and the body is a form, where
  every other endpoint in this package signs JSON: the same URL serves the host's code
  exchange and the package's refresh, which is why the boundary cannot be read off a path.

  **Two expiries come back and they are not the same clock.** `expires_in` is the access
  token's; `rt_expires_in` is the refresh token's, and it is the one that ends the session.


- **Reference data and watchlists** — thirty-eight endpoints: twenty-three fundamentals, six
  screeners, news summaries, and the eight watchlist calls.

  **The fundamentals table is the design.** Every one of the twenty-three takes `symbol` and
  `category` and differs only in what it adds, so the table names each endpoint's own extras
  and `type`/`count` are **dropped** on the endpoints that do not document them — an unknown
  parameter is at best ignored and at worst a refusal, and neither tells the caller which
  happened. `get_fundamental/3` reaches any of them, `fundamental_kinds/0` lists them, and a
  kind this venue does not publish is refused before a request is made.

  **`fiscal_period` is translated through the venue's own legend** — its page states
  `0=FY, 1=Q1, 2=Q2, 3=Q3, 4=Q4` — because the contract wants a label and the venue publishes
  a code. The raw integer stays in `line_items`, and a code outside the legend leaves the
  label `nil` rather than inventing one.

  **`get_financials/3` refuses a fundamentals kind that is real but is not a statement.**
  `:company_profile` exists on this venue and answering `get_financials/3` with it would put
  a profile in a statement's shape.

  **`get_corporate_events/1` has no `:split`.** Webull publishes `fund-splits` for funds and
  nothing for equities, so a split kind would be answerable for some symbols and silently
  empty for the rest. Without `opts[:kind]` both calendars are read, which is two requests,
  and `opts[:symbol]` is required — these calendars are per issuer, not market-wide.

  **`get_news/1` is generated, not reported.** The vendor's own description is "invokes LLM
  to generate news summaries", so each `summary` is a model's paraphrase and `source` names
  the venue rather than a wire. A caller quoting it is quoting a summary.

  **A screener's rank is the position the venue returned the row in.** Nothing is merged or
  re-ranked: two venues' "top movers" answer different questions. Each screener sends only
  the parameters its own page documents, and the venue's documented defaults are sent
  explicitly where it marks them required.

  **Watchlists: three absences and a boolean.** `symbols` is `nil` on a listing row — that
  endpoint names watchlists and does not read membership, where `[]` would say the watchlist
  is empty. `name` is `nil` on a membership read, because that endpoint does not return it.
  `update_watchlist/2` **refuses** `opts[:symbols]` rather than silently skipping it: this
  venue's update endpoint touches properties only, and `add_watchlist_instruments/3` and
  `remove_watchlist_instruments/3` are the membership writes.

  **Every watchlist write answers `{"success": …}` rather than an error status**, so a
  `false` is a 200 that did nothing — reported as `{:refused, :watchlist_write_rejected}`.
  And **creating with members is two requests**: where the add fails, the watchlist exists
  and is empty, and that returns `{:error, {:watchlist_created_without_members, id, reason}}`
  carrying the id rather than an `{:ok, watchlist}` a caller would read as complete.


- **Futures and event contracts** — sixteen endpoints, and a reference document
  (`docs/reference/webull/futures-and-event-contracts.md`) recording every parameter and
  response field.

  **The parameters needed a browser to read.** These pages render their tables in
  JavaScript: a plain fetch returns the method, the path and a one-line description and
  nothing else, which is exactly what the 2026-08-31 inventory captured. A capture that
  stops at the method and path looks complete and cannot be implemented from.

  Futures route by `US_FUTURES` through the existing callbacks — `get_price/2`,
  `get_historical_prices/4`, `get_trades/2`, `get_order_book/2` and `get_volume_profile/3`,
  each to its own endpoint with **its own parameter set**, which is not the union of all of
  them: futures bars take no `real_time_required` and no range, the futures tape and depth
  take no session flags, and the futures snapshot takes no extended-hours block.

  Event contracts add the venue's four-level hierarchy — `list_event_categories/1`,
  `list_event_series/1`, `list_event_events/1`, `list_event_markets/1` — alongside
  `list_futures_contracts/1` and `list_futures_product_classes/1`.

  **Two event endpoints are deliberately not behind the contract's callbacks.** An event
  tick carries a `yes_price` *and* a `no_price` and a side of `yes`/`no`; `Types.Trade` has
  one price and a side of `:buy`/`:sell`. An event book returns `yes_bids`, `yes_asks`,
  `no_bids` and `no_asks`; `Types.OrderBook` has two sides. In both cases the nearest
  mapping produces a number that looks right and belongs to **the other instrument of a
  two-instrument market**, so `get_trades/2` and `get_order_book/2` refuse `US_EVENT` and
  `get_event_trades/2` and `get_event_order_book/2` return the venue's own rows. The venue
  notes that a yes bid at X equals a no ask at 1−X; this package does not derive one side
  from the other, because a derived level cannot be told from a quoted one.

  **Paged lists return their key.** `list_event_series/1` and `list_event_markets/1` answer
  `%{rows: [...], pagination_key: key_or_nil}`; a bare list would make the last page and a
  truncated one look identical.

  **`status` and `tradable_status` are two fields on an event market**, and both survive: a
  market can be `LISTING` and `NT` at once, and one boolean would route an order at a market
  that is listed and not accepting one.

  Recorded as found, not resolved: the futures footprint page's `category` prose says "Only
  US_STOCK type queries are supported" while its own enum lists only `US_FUTURES`. The enum
  is what this package sends.

  `asset_classes/0` gains `:future` and `:event_contract`.


- **`get_transactions/2`** — the same `/trading/activities/cash-activities/list` endpoint
  `get_transfers/2` narrows, asked without the filter.

  `get_transfers/2` sends `DEPOSIT,WITHDRAW,TRANSFER` because the contract documents it as
  deposit and withdrawal history. This sends no `activity_types` at all, which is what asks
  the venue for everything it carries — `TRADE`, `FEES`, `DIVIDENDS`, `TAX`, `INTERESTS`,
  `CORPORATE_ACTION`, `OPTION_EA`, `JOURNAL`, `EC_SETTLEMENT` and `OTHER` beside the three.
  A default list here would be this package deciding what "every activity" means.

  **The two are not interchangeable in either direction.** A dividend and a deposit both
  credit cash and neither is the other: a caller computing contributions uses
  `get_transfers/2`, and one reconciling a balance uses this — summing the former leaves out
  the fees. Summing either is still not a balance; `get_balances/2` is the authority.

### Changed

- **Core dependency moves to `~> 0.1.34`**, and eleven further callbacks are declared rather
  than missing — all of them **absent, with the reason**, checked against the venue's own
  endpoint list on 2026-09-01.

  **Webull's published API moves no money.** There is no payment-method endpoint at either
  scope, no bank registration, no crypto network list, no allowlist and no transfer between
  accounts; funding happens in Webull's own applications, which need a person.
  `/trading/activities/cash-activities/list` *reports* money that moved and does not move
  any. No fee-promotion list, FX publication, notional valuation or custody product either.


- **The options surface**: `get_option_chain/2`, `get_option_expirations/2`, and `US_OPTION`
  on the snapshot, bars and tape — `/trading/instruments/options/contracts/list`,
  `/market-data/options/snapshots/list`, `/market-data/options/bars/list` and
  `/market-data/options/ticks/list`.

  **Three of those four were previously recorded as refusals, and the refusals were false
  negatives.** This package held that `US_OPTION` "is refused: the vendor states the stock
  snapshot does not serve it" — true of the *stock* snapshot, and wrong about the venue,
  which publishes a separate option endpoint beside each one. Three tests asserted the
  refusal, which is how a claim about the venue survived being wrong.

  **A chain is expiry × strike, and Webull publishes a flat list.** The grid is rebuilt
  here, because a flat list is lossless in data and answers none of the questions a chain is
  asked. **A contract this package cannot address is refused, naming the keys the venue
  actually sent** — an expiry, a strike and a right are what address a contract, and a
  dropped row leaves a chain with a hole in it that looks complete. A strike listed with one
  side keeps a `nil` on the other rather than being absent.

  `:underlying_price` is `nil`: this endpoint lists contracts and does not quote the
  underlying, and fetching it separately would be two observations at two times presented
  as one.

  **`get_option_greeks/2` stays absent, and that one is real.** Webull publishes no delta,
  gamma or implied volatility on any endpoint. Computing them would need a rate and a
  volatility surface it does not publish either — every number would be this package's model
  presented as the venue's, which is the most tempting substitution available here.

  `asset_classes/0` gains `:option`.


- **`get_symbols/2` reaches the stock instrument profiles**,
  `/trading/instruments/stocks/profiles/list`, routed by `opts[:category]`. Both endpoints
  paginate the same way and both are bounded — a truncated instrument list is the worst
  shape this family has, because every symbol in it is real and the missing ones are simply
  never traded.


- **`get_historical_prices/5` reaches the stock bars**, `POST /market-data/stocks/bars/list`,
  routed by `opts[:category]`. **A POST where the crypto bars are a GET**, with its
  parameters in a JSON body.

  **Daily and above are forward-adjusted; minute bars are not** — the vendor states it, and
  it means these are *not the same series at different resolutions*. Stitching 1m bars onto
  a daily series across a split gives a discontinuity that is entirely real in each half and
  wrong where they meet, and nothing in the bar data says which side was adjusted. This
  package cannot fix that, so it reports it: **`adjusted?/1`** answers it for a width, and
  returns `nil` for a width it does not serve rather than `false`, which would be a claim.

  **`real_time_required` defaults to `Y` on this endpoint**, unlike every other one here —
  that is an in-progress bar whose boundary has not happened yet. `false` is sent unless
  asked, matching the crypto path: a package that stored the venue's default would save a
  bar that changes after it is written.

  Three widths the crypto endpoint does not serve — `1w`, `1M`, `1y` — are available here.

  The body sends `count`, `start_time` and `end_time` as **numbers, not strings**: the venue
  types them `int32`/`int64`, and a quoted number in a typed JSON field is a different value.


- **`get_price/3` and `get_top_of_book/3` reach the stock snapshot**,
  `/market-data/stocks/snapshots/list`, chosen by `opts[:category]`.

  **The two snapshot endpoints are not interchangeable and the category picks the path.**
  Sending a stock symbol to the crypto endpoint returns *nothing* rather than an error, so
  passing the category through to one endpoint would have produced silence. `US_OPTION` is
  refused — the vendor states the stock snapshot does not serve it.

  **The default is still `US_CRYPTO`**, which is what this package served before its asset
  classes widened; changing it would silently re-route existing callers onto a different
  market.

  **Volume is real on stocks and stays `nil` on crypto.** The venue publishes no crypto
  volume anywhere, and `nil` says so where zero would claim a genuinely flat interval. The
  stock figure is the day's aggregate, which is what the venue names on this endpoint.

  `extend_hour_required` and `overnight_required` are sent explicitly on stocks so a caller
  reading `nil` knows it did not ask, rather than that the venue had nothing. Equity tickers
  bypass the canonical pair mapper, as they do on the order path.


- **`get_trades/2` — tick-by-tick public trades**, `/market-data/stocks/ticks/list`.

  **The venue documents `side` as "Such as: B S G L N" and defines none of them.** `B` and
  `S` are unambiguous; `G`, `L` and `N` are documented nowhere the vendor publishes, so they
  map to `nil` — a real trade with an unknown aggressor. Folding them into the nearer of buy
  or sell would put volume on the wrong side of a delta, which is the number a caller reads
  a tape for.

  `trading_sessions` is required by the venue and defaults to `RTH` here, which is the
  session the rest of this package's price data comes from. There is no per-tick id on this
  endpoint and `nil` says so; `broken` is `false` because the venue publishes no bust flag.

- **`get_volume_profile/3` — stock footprints**, `/market-data/stocks/footprints/list`.
  Traded volume split by price and by side within each interval.

  **`delta` is the venue's own figure and is not recomputed from the totals.** A venue that
  classifies some prints as neither aggressive buy nor aggressive sell reports numbers that
  do not reconcile, and that gap is information about its classifier rather than a fault to
  correct. The price maps keep the venue's own price strings — two strings that parse to
  equal decimals are the same level, and re-keying would silently merge two of its rows.

  **Five widths, where `get_historical_prices/4` serves more**: `5s`, `15s`, `1m`, `5m`,
  `30m`. Anything else is `{:unsupported_timeframe, width}` rather than the nearest one this
  endpoint happens to have. `OVN` is in the venue's session enum and its own note says it is
  unsupported, so it is refused rather than sent. `real_time_required` is `false` —
  completed intervals only, because an unfinished footprint's split still moves.

  Requires a separate Webull subscription, which the vendor states on the endpoint.

- **`get_auction_imbalance/2` — the NOII snapshot and the published series**,
  `/market-data/stocks/noii-snapshots/list`. `opts[:auction]` is required: `:opening` and
  `:closing` are different auctions with different windows.

  **Two endpoints.** `history: true` reads `/noii-bars/list` instead of
  `/noii-snapshots/list`, and **the bars publish the three prices and the time and nothing
  else** — no paired quantity, no imbalance quantity, no side. Those come back `nil`, which
  says the venue did not publish them there; a caller computing a ratio over the series
  gets `nil` rather than a number that looks balanced.

  **Outside the auction window the venue returns the last imbalance, not nothing** — its own
  documentation says so. Both the venue's `imbalance_time` and this package's `observed_at`
  are carried, because together they are the only way a caller tells a live imbalance from
  this morning's. An undated one leaves `venue_time` `nil` rather than borrowing
  `observed_at`, which would make a stale imbalance look fresh.

  `side` is the venue's own code, carried as sent — it documents `imbalance_side` with the
  example `"2"` and does not say what 2 means.

  Requires a Nasdaq TotalView non-display subscription.

- **`get_order_book/2` — stock and ETF depth**, `/market-data/stocks/depths/list`. The first
  endpoint of the equity market-data surface.

  **The book is equities-only on this venue.** The crypto snapshot publishes a top of book
  and nothing beneath it, and the vendor states `US_OPTION` is not supported here — so the
  category is checked before the request rather than after the venue's refusal.

  **The attribution is dropped, and that is worth saying out loud.** Each level carries the
  venue's `order` array of market-participant IDs with per-participant sizes, and `broker`
  names beneath that. `Core.Types.OrderBook` levels are `{price, size}`, so on a lit book
  this package discards who is quoting. The size that survives is the venue's own level
  size, **not a sum over the participants** — attribution can be partial, and the level
  size is the number the venue stands behind.

  A book the venue did not stamp is refused; a depth snapshot wearing the local clock
  cannot be told apart from a current one. `sequence` is `nil`, so a caller cannot use a
  REST book to detect a gap in a stream. `overnight_required` is always sent because the
  venue marks it required, and an omitted required parameter is a refusal a caller cannot
  read.

- **BREAKING: this package is no longer crypto-only. `asset_classes` is
  `[:crypto, :equity]`.**

  The order builder now serves all five instrument types the venue names, and **the matrix
  is per type because the venue's rules differ per type**:

      CRYPTO   MARKET/IOC, LIMIT/DAY|GTC, STOP_LOSS_LIMIT/DAY|GTC
      EQUITY   MARKET, LIMIT, STOP_LOSS, STOP_LOSS_LIMIT, TRAILING_STOP_LOSS × DAY|GTC
      OPTION   as EQUITY minus TRAILING_STOP_LOSS ("Options not supported")
      FUTURES  as OPTION
      EVENT    LIMIT only, and DAY|GTC|IOC|GTD|FOK

  One matrix for all five would be wrong four times, and wrong in the direction that gets an
  order rejected after it was sent. `{:unsupported_order_combination, instrument, type, tif}`
  now names the instrument, and the fake enforces the same matrix from the same source —
  `Rest.order_combinations/1` — rather than a hand-copied list that drifts.

  **A request that does not say `instrument_type` is still crypto.** Changing that default
  would silently re-route existing callers' orders onto a different market.

  **Only crypto symbols go through the canonical pair mapper.** An equity ticker is already
  the venue's own identifier, and pushing `SOLV` through a splitter that hunts for a quote
  currency would mangle it.

  Cash sizing (`AMOUNT`) is refused on futures and options, naming the instrument — the
  vendor states it for U.S. stock and event contract trading only. `GTD` carries an expire
  date and nothing else does; a missing one is left missing rather than defaulted, because a
  date chosen here would be an expiry the caller never asked for.

- **`preview_order/3` and `replace_order/4`.** Both endpoints exist and both exclude crypto,
  which they refuse before sending — the vendor's own words, rather than a business error a
  caller cannot tell from a rejected order.

  `preview_order/3` builds the **same body a placement would**, so a preview cannot diverge
  from the order it previews. It returns the venue's `estimated_cost` and
  `estimated_transaction_fee`, **with the instrument type alongside them**: for stocks and
  options the cost is total consideration, for futures it is initial margin, and a caller
  reading one as the other is off by the whole notional.

  `replace_order/4` enforces the venue's per-type edit surface — a MARKET order takes
  quantity only, a trailing stop takes only its step — and **reads the order back**, because
  the venue's response carries no order and reporting the requested change as though it were
  confirmed is a different claim.

- **`get_transfers/2` — cash activities.**

  **The endpoint is much wider than transfers.** It lists `TRADE`, `FEES`, `DIVIDENDS`,
  `TAX`, `INTERESTS`, `CORPORATE_ACTION`, `OPTION_EA`, `JOURNAL`, `EC_SETTLEMENT` and
  `OTHER` alongside `DEPOSIT`, `WITHDRAW` and `TRANSFER`. The contract asks
  `get_transfers/2` for deposit and withdrawal history, and returning all of it under that
  name would be wrong in a way that costs money: a dividend and a deposit both credit cash
  and neither is the other, so a caller computing what it put in would count income as
  contribution. This asks the venue for the three, and `opts[:activity_types]` widens it.

  **The venue's two constraints are enforced rather than discovered.** Without a range it
  answers the last 7 days — its default, stated in the docs here so an empty list is not
  read as "no deposits ever". `start_time` and `end_time` must be in the same calendar year,
  and a cross-year range is refused up front rather than sent: a venue that silently
  truncates returns a real list missing the other half.

  Rows come back whole. `activity_sub_type` alone has 60-odd values carrying the difference
  between an ACH deposit and a wire, and no struct in this contract has anywhere to put them.

- **`get_accounts/2`, `get_balances/2` and `get_positions/1`.** The package could not say
  what the credential holds or what it is exposed to.

  **`account_class` is where this venue's breadth shows.** The documented values are
  `INDIVIDUAL_CASH`, `INDIVIDUAL_MARGIN`, four IRA classes, `CRYPTO`, `FUTURES` and
  `EVENTS_CASH` — one credential reaches all of them. `get_accounts/2` returns the venue's
  rows whole rather than filtered, because an account is not a value type here and
  normalising `account_label` away would lose the field a caller picking an account needs.

  **`available_balance` is `nil`, deliberately.** The venue publishes `frozen_amount`,
  `held_amount` (in transit), `unsettled_cash`, `buying_power` and `available_withdrawal` —
  five different numbers that do not agree. `available_withdrawal` is what can leave the
  account; `buying_power` is what can be traded and on a margin account exceeds the cash.
  Each is "available" to a different caller, and labelling one of them as *the* available
  balance would be right once and wrong four times. `balance` is `cash_balance` and `hold`
  is `frozen_amount`, both single-meaning fields of the venue's own. The rest is a gap in
  `Core.Types.Balance` rather than in this venue.

  **A position's side comes from the sign of the quantity**, via
  `Position.from_signed_quantity/1`. It is the only place this venue states direction, and a
  package that assumed `:long` because equities usually are would report a short that is
  exactly backwards with every number in it still plausible. `liquidation_price` and
  `leverage` stay `nil` — the venue publishes neither here, and `nil` means "not stated",
  never "no liquidation risk".

  `get_balances/2` and `get_positions/1` require `opts[:account_id]`, as every account call
  on this venue does. `get_accounts/2` takes none: the credential decides what it sees.

- **`place_order/3`.** This venue could not place an order; it can now.

  **The venue documents which crypto pairs it accepts, and the list is short**: `MARKET`
  takes `IOC` only, `LIMIT` and `STOP_LOSS_LIMIT` take `DAY` or `GTC`. There is no market
  GTC and no limit IOC. A pair outside that list is **refused before the request is sent**,
  so a caller gets both halves of what was wrong rather than the venue's business error.

  **`account_id` is required and never inferred.** An account is where the money is, and a
  package that looked one up and chose would place a real order against the wrong balance
  for a caller holding several. It comes from `opts[:account_id]` or the call fails.

  **`QTY` and `AMOUNT` are different orders.** Sizing in units and sizing in cash are named
  separately by the venue; giving neither is an error rather than a default, and giving both
  is refused as ambiguous. Cash sizing on a stop-limit is refused outright — the venue allows
  it on a buy and not on a sell, and accepting it on one side invites a surprise on the other.

  Crypto orders are sent as `NORMAL` combos only, which is what the venue supports; MASTER,
  OTO, OCO and OTOCO are equities groupings.

- **`cancel_order/3`, `get_order/3` and `get_orders/2`.** The order lifecycle, which stopped
  at placement.

  **This venue's order API is keyed on the client order id, not the venue's.** Both
  `/trading/orders/cancel` and `/trading/orders/get` take `client_order_id`, so `Order.id`
  now carries it and `place_order/3` was corrected to return it. Returning the venue's own
  `order_id` handed a caller an identifier that round-trips nowhere: place, then cancel, and
  the cancel fails on an id the venue does not accept.

  **Open and historical orders are two endpoints, not one with a filter.**
  `/orders/open-orders/list` and `/orders/historical-orders/list` answer different questions,
  and a caller asking for "orders" without saying which gets the open ones — the set that can
  still change. `history: true` asks for the other.

  `account_id` is required on all three, as it is on placement.

- **`Rest.post/4`, which signs the body.** Unlike Coinbase's URI-scoped JWT, this venue signs
  the payload, so the encoded string is built **once** and used for both the signature and
  the request. Encoding twice risks two orderings of the same map and a signature that does
  not match what was sent — which the venue would reject as an authentication failure rather
  than as the encoding bug it is.

### Changed

- **`convert/4` and `get_trade_volume/2` (Core 0.1.22) are declared unsupported.** The venue
  publishes neither a one-step conversion nor the two-step quote/commit pair, and no
  account-volume report. Summing fills here would be this package's arithmetic rather than
  the venue's ledger, which is the number its fee tiers actually come from.


- **Core 0.1.21's three new callbacks are declared, each with the venue checked.**
  `preview_replace/4` follows `replace_order/4`: the venue excludes **crypto** from the
  amendment endpoint, and crypto is what this package declares today — so it is
  **unimplemented rather than unavailable**, and it unblocks when this package's
  `asset_classes` widen to the stocks, options and futures Webull also serves.
  `cancel_all_orders/2` has no endpoint at all: `/trading/orders/cancel` takes one
  `client_order_id` and the venue publishes no cancel-all or cancel-session.
  `close_position/3` likewise — `/trading/assets/positions/list` reads positions and
  nothing closes one, at any asset class.


- **Corrected a false claim about the venue.** `@unsupported` said `preview_order/3` "has
  no endpoint at all". `/trading/orders/preview` exists and is documented; what the vendor
  says is *"For crypto trading, this feature is currently not supported"*, and the same
  sentence appears on `/trading/orders/replace`. `/trading/orders/batch-place` is stocks
  only and gated per client.
  **They are unimplemented, not unavailable.** `asset_classes: [:crypto]` describes this
  package as it stands, not a boundary of the venue, and treating the two as the same is
  the same mistake in a different place. Widening the package reaches all three.

- **BREAKING: `get_historical_prices/4` returns `Core.Types.Candle` structs, and the bar's
  time is `opened_at`.** It returned bare maps keyed on `:timestamp`.

  `timestamp` did not say *which* time it was. A bar covers an interval, and the only time
  a venue publishes for it is the interval's opening — a caller reading `timestamp` as "when
  this bar closed" is off by exactly one interval, in a value that looks entirely reasonable.
  `opened_at` says which end it is. The struct also brings `Candle.coherent?/1`, which
  catches a high below the close at the boundary rather than downstream in a range or
  volatility calculation that will not error on it.

- **Every endpoint moved to its documented path (D6).** All five calls used an `/openapi/…`
  prefix that appears nowhere in Webull's current documentation; they were inherited from an
  older reading of the site.

      /openapi/market-data/crypto/snapshot       ->  /market-data/crypto/snapshots/list
      /openapi/market-data/crypto/bars           ->  /market-data/crypto/bars/list
      /openapi/instrument/crypto/list            ->  /trading/instruments/crypto/profiles/list
      /openapi/market-data/streaming/subscribe   ->  /market-data/streaming/subscribe
      /openapi/market-data/streaming/unsubscribe ->  /market-data/streaming/unsubscribe

  **Three of the five changed more than their path**, and a path-only rewrite would have
  compiled and passed:
  - snapshots stamp rows `last_trade_time` / `quote_time`; the timestamp reader accepted
    neither, so every quote would have failed `:missing_venue_timestamp`
  - bars renamed `symbol` to `symbols` and added a **required** `real_time_required`
  - instruments made `category` required and is now **paginated**

- **`get_symbols/1` follows pagination.** The replacement returns one page per call, so a
  single request would have returned a plausible, silently truncated catalogue. The walk is
  bounded (`@max_pages`) and refuses a key that does not advance.

### Added
- `DocumentedPathsTest` — asserts the documented paths are called and the `/openapi/` ones
  are not. **No test asserted any path before this**, which is why the wrong ones survived.

### Added
- Repo scaffold from the DpExchange standard; extraction pinned to the host's `553fa787`
  with per-file SHA-256, since the Webull subtree was dirty at extraction time — the third
  venue running.
- `docs/reference/webull/streaming-api.md`: the venue's MQTT-over-WebSocket streaming
  contract, committed verbatim, with its connection limits and protobuf schema.

### Added — the package
- Market data (snapshot, bars, catalogue), streaming, and the whole supervision
  tree. 214 tests including Core's 28 conformance assertions, passing first run.
- **Credentials are required for market data** — every OpenAPI call is signed and
  there is no anonymous endpoint, so this is the family's first
  `credential_benefit: :required`.
- **`environment: :uat`** points REST at the UAT host. Streaming there refuses with
  `{:streaming_unavailable, :uat}` rather than falling back to production: the venue
  has no UAT broker, and a consumer testing against UAT that received production
  prices would be reading real market data believing it was fake.
- **No trade volume anywhere** on this venue, so `volume` is `nil` rather than `0`.
  Zero would look like a real measurement of no trading.

### Measured against the live venue, 2026-08-28
- **The documented "TCP/IP" endpoint speaks TLS, not plaintext MQTT.** Sending a
  well-formed MQTT 3.1.1 CONNECT to `data-api.webull.com:1883` returns
  `15 03 01 00 02 01 00` — a TLS `close_notify` alert. The prior adapter reached the right
  conclusion (use WebSocket) from the wrong evidence ("never speaks MQTT", "no TLS
  handshake"); there is a TLS peer there, refusing a malformed ClientHello.
  `wss://data-api.webull.com:8883/mqtt` answers `101` immediately.
