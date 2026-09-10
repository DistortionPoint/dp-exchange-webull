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

- **A link drop flipped the shard's `connected?` and left `coverage/1` answering `:stream`
  for what that dead connection had been delivering.** `Socket.handle_disconnect/2` returns
  `{:reconnect, …}`, so the socket *process* survives a transport drop and no `:EXIT` ever
  reaches `isolate_crashed_shard/3` — the one path that cleared delivery records. So between
  a drop and a successful resubscribe, that shard's symbols reported as arriving when they
  were arriving from nowhere; and where the reconnect restored the socket while the venue
  silently failed to restore a symbol, it reported `:stream` indefinitely.

  This package had already written down why that is wrong, on the crash path:
  *"`coverage/1`/`coverage_by_kind/1` must not keep answering `:stream` for a shard that just
  crashed … until this, `coverage/1` itself kept lying in the meantime."* The reason does not
  depend on what killed the link, so the `:link_down` clause now drops the same records the
  same way — scoped to that one shard, since the others are on their own sockets. The shard
  keeps its entry, unlike the crash path: it is reconnecting rather than dead, and its
  symbols return as frames arrive after the next resubscribe.

  `dp_exchange_core` 0.2.5 writes the rule into `Core.Venue`'s `coverage/1` doc — observation
  is scoped to the current transport session — and records why it cannot be carried by a
  conformance assertion. All four streaming venues in the family had this wrong in the same
  way and are fixed in the same batch.

## [0.4.5] - 2026-09-10

### Fixed

- **A venue-rejected symbol's 24-hour exclusion was timed on the wall clock, so it could
  outlive its own bound.** `state.rejected` stored `:os.system_time(:millisecond) + ttl` and
  compared against the wall clock again later. That is an in-VM duration — *exclude this
  symbol for 24 hours from now* — and the wall clock is not a duration source. An NTP step,
  a host resync after a bad RTC, or a VM resuming from a snapshot moves it backwards, and
  every unexpired rejection silently gains exactly that much extra life. The TTL is 24 hours
  precisely so a "the venue refuses this" belief has a bound; a belief that can outlive its
  bound by however far the clock jumped is the bound not holding. A forward step is the
  mirror image — every rejection expires at once and the shard re-subscribes symbols the
  venue is still refusing.

  Both sites now use `System.monotonic_time/1`, which is what `Core.PollingFeed` already
  computes its own staleness window with. Nothing in the facade changes; a symbol still
  returns to shard composition on the first reshard after its TTL, and now does so after the
  TTL it was given.

  Found by sweeping every clock read in the family. This was the only in-VM duration still
  measured on the wall clock. The auth-token expiries and the request nonces sitting beside
  it are wall-clock **on purpose** — those instants come from the venue and are compared
  against the venue's clock, not ours — and were left alone. The `delivering` timestamps in
  this and three sibling feeds are written and never compared, so their clock source decides
  nothing today; that is noted here rather than changed, since changing it would be motion
  without a defect behind it.

## [0.4.4] - 2026-09-10

### Fixed

- **Every venue notice arrived with `message: nil` while the venue's own words sat in
  `details.venue_notice["content"]` (dp-exchange-core issue #33).** A consumer rendering
  `notice.message` printed nothing while this package held the text — 230 times in 66
  minutes on the reporter's node, over *"Permission grabbed by other session, category :
  us-crypto"*, which is not a line to make look like noise.

  `:message` is now set from the venue's field, with the raw body still in `:details`.
  `handle_packet(state, {:connack, 105})` already did this; the `notice` topic path simply
  never had.

  **`"content"` is an observed key, not a documented one** — the vendor publishes that the
  topic carries JSON and never publishes its field schema, so this is labelled as such at
  the code. Reading it is safe rather than a guess: absent or non-string yields `nil`, the
  raw body is untouched, and `nil` keeps meaning *the venue sent no text* — which is the
  right answer for the code-only shape the same reporter saw alongside it.

  A notice that is **not JSON at all** used to be dropped silently. That is the same defect
  one level down, so its text is now carried too — unless the payload is not valid UTF-8, in
  which case there are no words to keep and forcing them into a log line only produces
  mojibake that reads like a bug in whatever renders it.

### Added

- **`:resubscribe_interval_ms` is a start option**, defaulting to the previous hardcoded
  60_000 and validated at `init/1`.

  It exists because of the second half of that issue. The reporter asked whether this
  package's four shards are taking the `us-crypto` category from each other, and the rate is
  suggestive: four connected shards re-asserting once per 60 s is **4/min**, against their
  measured **230 in 66 minutes (3.48/min)**. Arithmetic agreeing is a hypothesis, not a
  finding, and nothing here can probe a venue that needs a credential this repository must
  never hold.

  So what shipped is the knob that lets them settle it: raise it to 300_000 and the notice
  rate should fall to a fifth if this timer is the trigger, and not move at all if it is not.
  `dp_exchange_coinbase` already exposed the identical option — this venue keeping it private
  is what made a live degradation undiagnosable from outside.

## [0.4.3] - 2026-09-10

### Documentation

- **`Rest.wide_timeframes/0`'s reasoning is now the family's written rule, not a local
  inference.** It explained why a width reachable on any path belongs in a flat
  `historical_timeframes` — correctly, and before anything said so. `dp_exchange_core`
  0.2.4 writes that rule into `Core.Capabilities` and cites this function as its worked
  example, so the doc here points at it instead of re-deriving it.

  The half worth keeping visible is the second one: a union declaration is only honest
  because `get_historical_prices/5` **fails closed** — `{:error, {:unsupported_timeframe, _}}`
  for a crypto or event-contract category — rather than degrading to the nearest width it
  does serve.


## [0.4.2] - 2026-09-10

### Fixed

- **No published version was attributable to a changelog entry (dp-exchange-core issue
  #32).** Every entry in this repository's `CHANGELOG.md` sat under `## [Unreleased]` — in
  the **published tarball**, since `CHANGELOG.md` ships inside it — so a consumer could not
  tell which version introduced a breaking change, or whether they had already taken one.

  That mapping is load-bearing here rather than cosmetic. This family signals a breaking
  change with a **minor bump**, and those changes are repeatedly a refusal tuple or struct
  gaining a field: invisible to the compiler, and invisible to a test that pins the old
  shape. The reporting consumer's written upgrade procedure is *"read `CHANGELOG.md` for a
  `### Changed — BREAKING` section, then grep for every clause matching the old shape"* —
  which needs version → change. Without it, `### Changed — BREAKING` says *that* the shape
  changed and never whether they already have it.

  They gave two incidents from the same three days, and the difference between them is the
  whole argument: `dp_exchange_gemini` 0.1.42's refusal-shape change was found **after
  shipping**, by reading a fix comment, while `dp_exchange_webull` 0.4.0's was caught
  **before** — because that entry happened to name the version in its prose.

  **Two halves, because fixing only one would have let it recur immediately:**

  - **Going forward**, the release pipeline cuts a `## [x.y.z] - YYYY-MM-DD` heading itself,
    in the publish job and **before `mix hex.publish`** — a heading added after the upload
    would describe a tarball nobody can read.
  - **Retroactively**, the accumulated block now sits under a `## [<version>] and earlier`
    heading. Attributing each of ~1,600 lines to the exact release that carried it is
    archaeology; this restores the one fact a consumer needs from it — that none of it is
    pending — which is what the reporter suggested.

  The issue measured five packages, from their `deps/`. `dp_exchange_schwab` has the same
  defect and is not one of their dependencies, so it could not appear in their table: six
  instances, all fixed here.


## [0.4.1] and earlier - 2026-09-10

**Everything below this line is published.** Entries were accumulated under
`[Unreleased]` from the first release to `0.4.1`, so no reader could tell shipped work
from pending — dp-exchange-core issue #32. Attributing each entry to the exact version
that carried it would be archaeology across hundreds of releases; this heading restores
the one fact a consumer actually needs from it, which is that none of it is pending.

Releases from here on cut their own `## [x.y.z]` heading at publish time, so this is
the last block that will ever need a range.

### Changed — BREAKING

- **A refusal now carries the venue's HTTP status as well as its words.**
  `{:refused, {:venue_error, 401, "signature mismatch"}}`, where it used to be
  `{:refused, {:venue_error, "signature mismatch"}}`.

  This package refuses on `400`, `401` and `403`, and **all three arrived at a caller looking
  identical** — while their remedies are opposite: a `400` means fix the request, a `401`
  means refresh the token and call again, a `403` means a person must change what the
  credential is entitled to. The clause raising the refusal even documents the `401` remedy
  in a comment, so the code knew which status it had matched and then discarded the only
  thing that could tell a caller which one it was.

  An unrecognised body keeps its status too — `{:venue_error, 403}` rather than a bare
  `:refused`. Thin, but it is the difference between "the venue rejected this and here is
  which kind" and "something went wrong". `oauth_token/3` was worse still: it returned the
  **raw body** as the reason, with no classification at all, on a call where `400` (bad
  grant) and `401` (bad client credentials) again mean different things.

  **This venue was the outlier.** `dp_exchange_coinbase`, `dp_exchange_robinhood` and
  `dp_exchange_schwab` all already used `{:venue_error, status, detail}`. Found by sweeping
  the family for the principle a consumer named on dp-exchange-gemini#1 — *a known reason is
  never less informative than an unknown one* — generalised to: **a caller must never be
  handed less than this package already had.**

  **If you pattern-match refusal reasons, check that clause before upgrading.** A caller
  matching `{:venue_error, message}` now falls through to whatever catch-all follows it,
  silently, with nothing raising. That exact trap cost a consumer a canonical error mapping
  on `dp_exchange_gemini`, which is why it is called out here rather than left to be found.

### Documentation

- **`usage-rules.md` now answers the question a consumer actually has after 0.2.0: when is
  `venue_time` `nil` here?** The migration note said what the fields mean; it did not say
  what this venue does with them, which is the part a caller writes a branch for.

  **Never**, on this venue: every `Quote` and `OrderBook` parses a time the venue sent and
  fails closed when it cannot, so a `nil` branch here is dead code.

### Changed — BREAKING

- **`Core.Types.Quote` and `Core.Types.OrderBook` no longer carry `:timestamp`.** They carry
  **`:venue_time`** (the venue's own, `nil` where the venue publishes none) and
  **`:observed_at`** (when this package read it, always present). Requires
  `dp_exchange_core ~> 0.2.1`; this package's own version takes a minor bump to signal it.

  `:timestamp` was documented as the venue's own and "never invented", and two packages in
  this family could not keep that promise, because the frames they decode carry no venue time
  at all. With one field their only options were to lie or drop real data, and they lied.

  **This venue always had a venue time to give**, on every `Quote` and `OrderBook` it
  builds, so `:venue_time` carries exactly what `:timestamp` did and `:observed_at` is new
  information rather than a replacement.

  The full reasoning, the three options weighed and the consumer's own argument for this one
  are in `dp_exchange_core`'s
  `docs/design/closed/2026-09-09_venue-time-and-observed-time.md`, announced and answered as
  dp-exchange-core issue #31. `Trade`, `Fill`, `Balance` and `OrderBookDelta` are unchanged.

### Added

- **`script/check_endpoint_inventory.sh` and `docs/reference/webull/endpoint-pages.txt`** —
  a weekly, non-blocking diff of the vendor's published endpoint reference pages against a
  committed capture, via `.github/workflows/inventory-check.yml`. One HTTP request: this
  vendor publishes no machine-readable specification, but its `sitemap.xml` lists one
  `docs/reference/*` page per endpoint, so that set is the closest thing to an operation
  list available here.

  **This venue is why the mechanism exists.** The identical sitemap search found
  `developer.webull.com/apis/docs/rate-limits/` — a per-endpoint rate-limit table that had
  been published since 2026-08-14 while this package declared a REST ceiling **five times
  too permissive**, against a venue whose documented penalty for exceeding it is a
  temporary IP block. Nobody found it for weeks because nobody was comparing indexes. A
  page appearing here now says so.

  Baseline: **248 reference pages**, captured 2026-09-09, unchanged on the check's first
  run.

### Fixed

- **Reads now carry `@call_timeout` explicitly, exactly as writes already did.**
  `coverage/1`, `coverage_by_kind/1`, `status/1` and `wanted/1` took `GenServer.call/2`'s
  implicit **five seconds** while every write named a generous one, and that asymmetry is
  what turned a bounded delay into a dead caller in dp-exchange-core issue #28: `coverage/1`
  is the call a consumer's health check makes, so any moment the Feed was legitimately busy
  for longer than five seconds turned a health check into an **exit** — and into a dead
  consumer process, when the read happened inside the consumer's own `handle_call/3`. The
  blocking is fixed at its sources rather than papered over here; this is the second line of
  defence. A read that has to queue behind something should wait for it, not die of it.

### Fixed

- **`INVALID_SESSION` was retried as a subscribe failure forever — dp-exchange-core issue
  #30.** All four MQTT shards stopped delivering and the blind resubscribe timer kept
  firing against sessions the venue had already discarded: **1,479 identical warnings over
  fourteen hours**, 260 of 325 symbols receiving nothing, and a manual `Feed` restart as
  the only recovery. `INVALID_SESSION` says the session a subscribe is addressed to no
  longer exists, so re-sending that same subscribe is the one action guaranteed not to
  help — and nothing escalated from "subscribe failed" to "reconnect", so it could not
  recover in-process.

  Two causes, both fixed. **`Subscription` collapsed the venue's answer into the opaque
  `{:exchange_error, :webull, "HTTP 417: ..."}` string**, which `Feed` could log and could
  not match on; a `417` carrying `INVALID_SESSION` is now
  `{:error, {:invalid_session, session_id}}`, with the dead session id parsed out of the
  venue's prose (`"...not exist for session:<id>"`) because on a sharded venue three of
  four sessions may be perfectly fine. A message this parser cannot read still returns
  `:invalid_session` with a `nil` id — the recovery does not depend on the id, and refusing
  to name the failure over a missing detail would restore the fourteen-hour loop.

  **`Feed` now rebuilds the shard** rather than retrying it, through the recovery it
  already had for a crashed socket: drop the shard and reopen it, which mints a fresh
  session id in `open_socket/2`. It has to be a reopen and not a retry, because the session
  id is minted when the socket opens — there is no subscribe-level fix available at all.
  Handled in the shared `handle_subscribe_result/3` funnel, so every subscribe path
  recovers the same way; the blind resubscribe is merely where it was first observed.

  Two details that would be easy to get wrong, both recorded at the code: the shard leaves
  `state.shards` **before** its socket is stopped, so the resulting `{:EXIT, ...}` finds no
  shard and cannot drive a second concurrent rebuild through `isolate_crashed_shard/3`; and
  the socket is **stopped**, not abandoned, because unlike a crash the process is very
  likely still alive holding a connection the venue has already discarded — this venue
  allows five concurrent connections per App Key, so leaking one per stale session would
  turn a recoverable outage into an unrecoverable one.

  It is reported as a `:link_down` notice naming `INVALID_SESSION`, rather than latched as
  a generic resubscribe failure. The reporting consumer's point stands on its own: the only
  signal before this was a WARN line saying the symbols were stuck, offering no path out.
  This is the **third** failure mode of the resubscribe path — #17 added it (symbols going
  quiet on a live session), #23 fixed it failing throttled, and this is the session
  underneath it being gone.

  A note on why it stayed invisible for fourteen hours, worth carrying: the failure is
  *partial by construction*. Dead sessions strand their symbols while surviving ones keep
  delivering, so venue-wide "has this gone quiet" answered **no** the entire time — the
  reported `min` stream age was 81s while the p50 was 3,497s.

### Documentation

- **`Credentials`' moduledoc now says that the redaction wrap lives in `child_spec/1`, and
  that bypassing `child_spec/1` bypasses it.** Requested by the consumer who verified the
  dp-exchange-core #29 fix and then went looking for their canary in their own supervisor's
  state — and found it. Their supervision code builds the child spec itself
  (`start: {__MODULE__, :start_feed, [module, opts, pairs]}`) for a legitimate reason: a
  `Core.PollingFeed`-shaped facade defaults `subscriber` to `self()`, which resolves to the
  *supervisor* when `start_link/1` is called from `init/1`, so a different delivery target
  can only be set at `start_link` time. On that path `child_spec/1` never runs, their
  supervisor stores the raw map, and OTP renders the live key on the next crash exactly as
  before. **Upgrading does not fix it, because nothing from this package is on that path.**

  No code change: `wrap/1` and `wrap_opt/1` were already public, which was all that path
  needed. What was missing was anyone saying so — the natural assumption, "upgraded,
  therefore redacted", is wrong there, and assertion 22 cannot see it because it asks about
  `child_spec/1`'s own rendering. `dp_exchange_core`'s `usage-rules/auth.md` carries the
  full version, including the reshaping case that bit them: a host mapping its own key
  names into a venue's and returning a bare map re-introduces the leak in its own code,
  downstream of anything a package can reach.

### Fixed

- **Credentials were written to the log in cleartext by any crash — dp-exchange-core issue
  #29.** A supervisor stores the `{module, :start_link, [opts]}` MFA its child spec names,
  and OTP writes that argument list through `inspect/1` into the `Start Call:` line of the
  report it logs on **any** child termination. `:credentials` arrived as a plain map, so
  every crash printed the live secret in full. It needs no unusual conditions, it lands in
  ordinary application logs — the artifact most likely to be shipped to an aggregator or
  attached to a bug report — and it defeats credential hygiene upstream of it: a consumer
  can hold the key encrypted at rest and still have it written out in the clear. The
  reporting consumer found live keys this way and nearly pasted them into a GitHub issue
  while reporting a different bug.

  `child_spec/1` now wraps `:credentials` with `DpExchange.Webull.Credentials.wrap_opt/1`, and
  **the placement is the fix**: wrapping in `start_link/1` or `init/1` does nothing,
  because by then the supervisor above has already captured the raw list. Redacting the
  value rather than setting the `:sensitive` process flag is deliberate — that flag
  suppresses the whole report, including the stack trace that made the unrelated bug
  diagnosable. This keeps the report and removes only the secret. `dp_exchange_core`'s
  conformance suite gains **assertion 22** for exactly this, so it cannot come back here or
  arrive in a new venue.

### Fixed

- **The REST ceiling was five times too permissive, and the entry below it in this same
  unreleased section is what made it so.** `public_ceiling`/`authenticated_ceiling` are
  now `%{limit: 60, per_ms: 60_000}` — 60 requests per 60-second window, the venue's own
  units — replacing the `%{limit: 5, per_ms: 1_000}` the next entry describes arriving at.
  That `5` came from Webull's Market Data FAQ ("a rate limit of 300 requests per 60
  seconds"). The FAQ is real and still says that. It is also contradicted by **the
  venue's own per-endpoint rate-limit table**, `developer.webull.com/apis/docs/rate-limits/`,
  which caps *every* market-data endpoint — crypto, stock, option, future, event
  contract, display and non-display, including the HTTP `streaming/subscribe` calls — at
  `60/60s` in production and `30/60s` in sandbox. A second, independently maintained set
  of pages corroborates it in different units: each endpoint's own reference page states
  "1 request per second per App Key", which *is* 60/60s.

  The venue contradicts itself, so this was decided by rule, not preference: the
  per-endpoint table is more specific, newer, states its own units, is corroborated, and
  is the **stricter** of the two. Fail closed. The asymmetry matters more than usual here
  — that page also states that repeatedly exceeding a limit "may result in temporary
  IP-level blocking", so guessing high does not cost latency, it costs the connection.

  **This number has now been wrong twice in a row, in the same direction, and the second
  time it carried a citation.** That is the part worth keeping: a citation makes a number
  checkable, it does not make it right. Operationally the tightening costs nothing —
  `Subscription.subscribe/3` batches symbols into one call per shard rather than one per
  symbol, and `get_price/3`/`get_top_of_book/3` are per-symbol calls a consumer paces
  itself.

- **UAT was metered against production's budget.** `Supervisor`'s `limits/1` (was
  `limits/0`, now taking `opts`) halves the declared ceiling to `30/60s` when
  `Environment.resolve/1` says `:uat`, which is the venue's own relationship between its
  two columns rather than a margin invented here. The Supervisor already gave production
  and UAT separately *named* limiters precisely so one could not spend the other's budget;
  handing both the same limits left that separation cosmetic in the direction that bites —
  UAT pacing itself against an allowance the sandbox refuses, surfacing as a `429` on a
  test run with nothing pointing at the cause. `capabilities/0` still declares the
  production figure and can declare nothing else: it takes no arguments. `limits/1` is now
  public and documented, matching its already-public siblings `limiter_name/1` and
  `feed_name/1`, so the derivation is checkable; `test/dp_exchange/webull/rate_ceiling_test.exs`
  pins both environments and the burst that follows each.

- **A cited vendor page 404s, and that is how all of the above was found.**
  `docs/reference/webull/rest-rate-limits.md` cited
  `.../docs/reference/option-market-data/`; the page is `options-market-data`, plural.
  Three bullets in that file carried per-endpoint figures — "40 requests per 2 seconds"
  for orders, "600 requests per minute" for futures, "60 requests per minute" for option
  tick data — each attributed to a reference page. **Every reference page on this vendor's
  site was fetched and searched: none of them contains any rate-limit text of that form.**
  Those bullets are deleted rather than corrected — unsourced numbers wearing a citation
  are worse than missing ones. The real per-endpoint figures, from the table that does
  publish them, are now recorded in full.

- **`public_ceiling`/`authenticated_ceiling` were `%{limit: 10, per_ms: 1_000}` with no
  comment and no mention anywhere in `capabilities/0`'s own `measured_against` string —
  unlabelled and inherited, and load-bearing: `Supervisor`'s private `limits/0` feeds
  this straight into the real `DefaultRateLimiter` this package starts, so the
  unexamined number was actually throttling (or failing to throttle) every REST call.**
  Found by a
  family-wide sweep for the `@pairs_per_socket`/`@shard_spacing_ms` defect class in
  `dp_exchange_coinbase` — an unverified number sitting where a cited one belongs.
  Webull's own Data API FAQ (`developer.webull.com/apis/docs/market-data-api/faq/`,
  read 2026-09-08) states "a rate limit of 300 requests per 60 seconds" — `300 / 60 = 5`
  — now `docs/reference/webull/rest-rate-limits.md`. Both ceilings are now `5`, not `10`;
  every endpoint here is signed (`credential_benefit: :required`), so there is no
  separate public/authenticated figure to distinguish. This *lowers* the rate this
  package will request against the venue — a caller running close to the old,
  unverified `10` may now see requests queue that previously went straight through — but
  the old number rested on nothing, and this one rests on the venue's own stated ceiling.
  Two smaller citation gaps found in the same sweep, values unchanged: `Rest.place_orders/3`'s
  50-orders-equities-only batch limit now cites `docs/reference/webull/batch-orders.md`
  (previously "its page says so" with no committed source); `Rest.get_order_book/3`'s
  `depth` default of `10` is now labelled as generalised from the event-contracts
  endpoint's documented default rather than confirmed for the stock/futures endpoints it
  actually applies to — the stock endpoint's own parameter table has never been captured
  (JS-rendered, same limitation `negative-claims.md` already records elsewhere), and the
  futures endpoint's own page states `depth` is `1–10, required` with **no** default,
  making the prior "L2 defaults to 10" doc comment an overgeneralisation for that case.

- **A malformed WebSocket close frame from Webull crashed a shard's socket before
  `handle_disconnect/2` ever ran — dp-exchange-core issue #27.** Webull sometimes closes
  this venue's MQTT-over-WebSocket connection with a close frame carrying **prose**
  where RFC 6455 §5.5.1 requires a 2-byte status code — measured live:
  `<<136, 10, 98, 121, 101, 45, 98, 121, 101, 33, 33, 33>>`, i.e. `"bye-bye!!!"`. The
  first two bytes parse as `"by"` = 25209, outside every valid close-code range
  (1000–1015, 3000–4999). `WebSockex.Frame.parse_frame/1` correctly returns
  `{:error, %WebSockex.FrameError{reason: :invalid_close_code}}` for this; `websocket_loop/3`
  one level up matched only `{:ok, frame, buffer}` and `:incomplete}` even though
  `parse_frame/1`'s own `@spec` names the error tuple as a real return value, so the
  process raised an uncaught `CaseClauseError` and died **before any callback ran** —
  `Socket.handle_disconnect/2` never fired. Measured consumer impact: 117 crashes in 7
  minutes across three shards, roughly one close every 10 seconds per shard, sustained.
  `Feed`'s own supervision reopened each shard, so nothing alarmed; the venue simply
  never reached full coverage (one consumer's fresh-tick count oscillated between 76 and
  243 against a 325-symbol scope, all day).

  websockex 0.5.1 is the latest Hex release and still has this; confirmed the same
  unguarded `case` is still present, unreleased, on `dominicletz/websockex`'s current
  `master` (2026-09-08) — the maintained upstream repo (`Azolo/websockex` is
  abandoned). There is no upstream fix to wait for.

  **Fixed by vendoring, not by switching transport.** A transport swap
  (`Mint.WebSocket`, `:gun`, `fresh`) was evaluated and rejected: this package already
  owns its transport by design (`CLAUDE.md`: "Core ships no venue-specific dependency…
  a venue that speaks WebSocket ships what it needs to speak it"), but websockex
  already supplies TCP/TLS connection handling, the HTTP upgrade handshake, frame
  fragmentation reassembly and automatic reconnect — replacing all of that to work
  around a two-line defect would have meant hand-rebuilding a WebSocket client on a
  production incident's timeline, a strictly larger and riskier change for the same
  outcome. Intercepting the buffer before `WebSockex.Frame.parse_frame/1` sees it was
  considered and ruled out on inspection, not assumption: every byte from the socket
  reaches `websockex`'s own private process loop directly (`WebSockex.Conn.
  controlling_process/2` + `set_active/2`), with no seam in the callback model for a
  consumer to sit in front of it.

  A **git-dependency fork was rejected** because Hex refuses to publish a package that
  depends on git — shipping a fork this way would mean publishing an entire separate
  package under a new name on Hex, a maintenance commitment (a new repo, its own CI, its
  own releases, tracking every future upstream websockex release for anything beyond
  this one fix) out of proportion to a two-line defect, and one this package's own
  authority does not extend to unilaterally taking on.

  Instead, `lib/vendor/websockex.ex` vendors `websockex` 0.5.1's single process-loop
  file (not the whole package — `WebSockex.Frame`, `WebSockex.Conn`, WebSockex.Utils
  (hidden from its own docs, so plain text here),
  `WebSockex.Application` and every `WebSockex.*Error` struct stay the real,
  unmodified dependency; none of those carried the bug), private to this package,
  under `DpExchange.Webull.Vendor.WebSockex` — never bare `WebSockex`, so a consumer
  who also depends on the real `websockex` package (directly, or through another venue
  in this family) is unaffected. Exactly two things changed from upstream, both marked
  `## VENDORED FIX` at their call site: (1) `websocket_loop/3` gains a clause for
  `{:error, %WebSockex.FrameError{}}`, routed through the *already-existing*
  `handle_close({:error, reason}, ...)` path `sync_send/5` already used for a
  send-time framing error — RFC 6455 §7.1.7's specified response to a peer's malformed
  frame is to close the connection, not crash reading it, and that path already sends
  this side's own close frame and runs the ordinary disconnect flow, so no new recovery
  logic was written; (2) WebSockex.Utils.spawn/5 (hidden from its own docs, so plain
  text here) hardcodes the literal atom
  `WebSockex` as its `:proc_lib` entry module, which would have booted every vendored
  socket into the real, unpatched module regardless of the rename — `do_spawn/2` is
  reimplemented locally using `__MODULE__` to close that one gap. See the vendored
  module's own moduledoc for the full incident, and an upstream PR was opened against
  `dominicletz/websockex` alongside this fix (it cannot be the fix that ships today,
  but it is worth landing regardless).

  `mix.exs` now pins `{:websockex, "== 0.5.1"}` exactly rather than `~> 0.5.1`: the
  vendored file calls `WebSockex.Conn`'s and `WebSockex.Frame`'s functions the same
  private-in-spirit way the original did, an internal API those modules never promised
  to keep stable across releases the way their own public behaviour is — a `~>` floor
  would invite the exact failure this same dependency already caused this family once
  (the `send_frame/3` arity floor, this file's own earlier entry). `lib/vendor/` sits
  outside `test/dp_exchange/webull_contract_test.exs`'s (narrowed) `package_root`,
  `.credo.exs`'s scanned paths and `mix.exs`'s coverage `ignore_modules` — all for the
  same reason: this is third-party code carried for a two-line necessity, not code
  written to this family's own conventions, and none of those checks can see the OTP
  dynamic dispatch (`:proc_lib`, `:sys`) that keeps several of its exports legitimately
  public with no caller `:xref` can find.

  **Proven by `test/dp_exchange/webull/socket_malformed_close_test.exs`**: a real
  `Socket.start_link/1` against a real local TCP server that completes the WebSocket
  handshake and then sends the exact 12-byte frame from the incident. Confirmed to fail
  with the pre-fix `CaseClauseError` when the fix's one clause is removed, and to pass
  with it restored — `handle_disconnect/2` runs (`:link_down` notice received, naming
  the `WebSockex.FrameError` and `:invalid_close_code` reason), and the socket process
  is still alive afterward rather than crashed.

- **Why the venue closes the connection at all — investigated, not fully resolved.**
  Fixing the crash turns each of these into a clean reconnect instead of a crash, but
  does not by itself explain why Webull sends this close so often. Ruled out with
  evidence already in hand before this fix: the 60s keep-alive/30s `PINGREQ` schedule
  cannot explain a ~10s close cadence, and shards do not share an MQTT client id (each
  socket, and each reopen, gets its own `generate_session_id()`), so the venue's
  documented "a new connection with the same session_id kicks the previous one" rule
  does not apply at the shard level. The consumer's own hypothesis — a crashed socket
  never sent a clean MQTT `DISCONNECT`, so the broker held the dead session for its
  documented ~1 minute retention window while shards kept reopening, and enough
  overlapping zombie sessions eventually hit the "5 concurrent connections per App Key"
  ceiling (Webull's own docs: exceeding it returns error code 105, and duplicate/expired
  sessions get kicked with no more specific reason given at the WebSocket layer) — is
  plausible, evidence-consistent, and testable, but **not established**: this repo holds
  no Webull credential and cannot run it live. This fix is the fix that makes the
  hypothesis testable at all, since before it no shard ever sent a clean `DISCONNECT` in
  the first place.

  **The exact probe**, for a consumer running this live (as the reporting consumer has
  offered to): after upgrading, watch a shard's `:link_down` notices across an extended
  run. If the ~10-second-per-shard close cadence stops or drops substantially, the
  zombie-session hypothesis is confirmed. If it persists at the same rate with clean
  reconnects now happening every time, the hypothesis is falsified and the cause is
  something else — a concurrent-connection cap behaving differently than documented, an
  idle-connection policy independent of MQTT keep-alive, or something the CONNECT
  packet itself triggers — and would need a second, separate investigation with the
  close reason now visible on every occurrence (this fix logs `WebSockex.FrameError`'s
  full detail on the malformed case; an *unrelated* future close would carry its own,
  different `reason`, distinguishable in the same `:link_down` notice).

- **`dp_exchange_core` was pinned to `~> 0.1.48`, a floor this package has not actually
  run against since `capabilities/0` started declaring `no_venue_contact: [{:get_fees,
  2}]`.** `Capabilities.new/1` builds the struct with `struct!/2`, and `no_venue_contact`
  is a key Core only defines from **0.1.68** — any lower resolution raises `KeyError` the
  first time `capabilities/0` is called, which is every conformance run and every host
  that calls it during venue discovery. `~> 0.1.48` compiled and every test passed
  because CI always resolves the newest allowed version (0.1.68, per `mix.lock`);
  a consumer whose own dependency graph forced an older Core would not resolve that.
  Found in a family-wide audit of declared-vs-actual dependency floors, prompted by the
  same defect class already fixed in `websockex` (`~> 0.4` → `~> 0.5`, next entry below —
  which itself needed a second correction the same day; see that entry).
  Raised to `~> 0.1.68`. This also covers `Timeframe.nameable/0` admitting `1y`, needed
  since Core 0.1.57 (see the "capabilities/0 withheld 1y" entry below) — 0.1.68 is the
  binding constraint of the two. A new test in `webull_test.exs` asserts the resolved
  Core's `Capabilities` struct defines `:no_venue_contact`, so a future loosening of this
  pin without a matching code change fails loudly instead of only failing for a consumer.

- **`websockex` was corrected twice in one day, and the first correction was itself
  wrong.** `Socket.disconnect/2` calls `WebSockex.send_frame/3`; `mix.exs` declared
  `~> 0.4`, which does not have that arity at all. The first fix (`0646201`, this
  package's own commit, undocumented here at the time — a gap this entry also closes)
  raised the floor to `~> 0.5`, reasoning that the third `send_frame` argument "only
  exists from 0.5". It does not: `send_frame/3` is new in **0.5.1**, and `~> 0.5` still
  permits `0.5.0`, which lacks it — confirmed by reading both resolved sources directly
  (`deps/websockex/lib/websockex.ex` defines only `send_frame/2` at `0.5.0`; the same
  file defines `send_frame(client, frame, timeout \\ 5_000)` at `0.5.1`). Caught by
  `script/check_dependency_floor.sh`, added the same day family-wide to close exactly
  this blind spot, on its first real run against this package: resolving `~> 0.5` to its
  actual floor reproduced the original `WebSockex.send_frame/3 is undefined or private`
  warning against `0.5.0` itself. Raised to `~> 0.5.1`. No `mix.lock` change was needed —
  this package already had `0.5.1` locked; only the stated floor, and the comment
  reasoning about it instead of resolving it, were wrong. See
  `docs/design/closed/2026-09-08_dependency-floor-check.md` in `dp_exchange_core` for the
  full family-wide writeup.

- **This reverts and corrects `get_fees/2`'s credential gate, added in the "Fix Fake
  credential gate (Core 0.1.57 assertion 17)" entry below. That earlier entry was
  wrong about this one endpoint.** `get_fees/2` builds no request — it answers a
  crypto spread rate captured from Webull's own published pricing
  (`source: :published_rate`) — and yet, since that sweep, both `Rest.get_fees/2` and
  `Fake.get_fees/2` refused with `{:error, {:missing_credentials, :webull}}` when
  called without one. The sweep's reasoning was that the real path "had never run
  through `Auth.headers/2`", which was true and was exactly the point: there is
  nothing here to sign. The fake should have been matched to the real path's
  ungated behaviour; instead the real path was gated to match the fake's incorrect
  refusal.

  **Reported by a consumer** (DpCryptoManagement) who resolves venue fees to score
  *candidate* strategy genomes before any account is attached — no credential exists
  at that point by design. With `get_fees/2` unanswerable without one, their
  `round_trip_bps` computation lost its input and their fee-overcome admission gate,
  a live-trading gate, could not run.

  **Now `get_fees/2` answers unconditionally on both `Rest` and `Fake`, matching its
  pre-sweep behaviour.** `credentials` is accepted for shape parity with every other
  callback and never inspected. A swept audit of the other twelve callbacks the same
  commit gated (`get_accounts/2`, `get_balances/2`, `get_positions/1`,
  `get_transfers/2`, `get_transactions/2`, `quantization/2`, `place_order/3`,
  `place_orders/3`, `preview_order/3`, `replace_order/4`, `cancel_order/3`,
  `get_order/3`, `get_orders/2`) and the twelve gated by "Gate the widened Fake
  surface on credentials" (`get_option_chain/2`, `get_option_expirations/2`,
  `list_watchlists/1`, `get_watchlist/2`, `create_watchlist/3`, `update_watchlist/2`,
  `delete_watchlist/2`, `get_financials/3`, `get_corporate_events/1`,
  `get_filings/2`, `get_news/1`, `get_screener/2`) confirmed every one of them
  reaches the venue through `Rest`'s signed `get/4` or `post/4` request path — the
  gate on all twenty-four is correct and stays.

  Regression test added asserting `get_fees/2` answers `{:ok, _}` with no credential
  on both `Rest` and `Fake`, so this cannot be re-broken by the next credential-gate
  sweep.

  **Moved to `dp_exchange_core` 0.1.68**, which resolves this the way the false
  positive is actually fixed rather than papered over: assertion 17 gains
  `Capabilities.no_venue_contact`, a per-endpoint declaration a venue makes when a
  specific active endpoint's real implementation never builds a request to the venue.
  `capabilities/0` now declares `no_venue_contact: [{:get_fees, 2}]`.

- **`market_status/1` answered `{:ok, :open}` unconditionally — true only for the one
  asset class this venue does not restrict to trading hours, and a lie for the other
  four.** This venue is not crypto-only: `asset_classes/0` is `[:crypto, :equity,
  :option, :future, :event_contract]`, and equities, options, futures and event
  contracts all trade on real, exchange-set hours. A consumer checking market status
  before placing an equity or options order was told the market was open at 3am on a
  Sunday. Found by `dp_exchange_core` 0.1.66's widened assertion 17 (the credential
  gate): this venue declares `credential_benefit: :required`, and the literal answered
  `{:ok, _}` with no credential because nothing here ever read one.

  **Now `{:error, :not_supported}`, declared `:unsupported` in `capabilities/0`.**
  Checked against the vendor's own documentation before deciding, per this package's
  own rule (fail closed; never substitute) rather than assumed: Webull's OpenAPI
  documents 85 endpoints (`docs/reference/webull/endpoint-inventory.md`) and none of
  them is a market-status or trading-calendar call. The one trading-calendar endpoint
  Webull publishes anywhere, `GET /broker/master-data/trading-calendars/list`, belongs
  to a different product entirely — the **Broker API**, served from
  `broker-api.webull.com` rather than this package's `api.webull.com`, reachable only
  with its own broker-tier credential obtained through a separate business relationship
  this package has none of. Even setting the credential question aside,
  `market_status/1` carries no symbol or asset-class argument — it answers ONE status
  for the whole venue, and this venue spans five asset classes with different calendars,
  so no single value could ever honestly describe it, reachable endpoint or not. Full
  reasoning in `docs/reference/webull/negative-claims.md` and
  `DpExchange.Webull.market_status/1`'s own doc.

  **Breaking for any consumer routing on `market_status/1`.** A caller that previously
  got `{:ok, :open}` now gets `{:error, :not_supported}` and must treat this venue as
  not answerable for market status, the same way it already must for
  `test_connection/2` and `get_rate_limit_status/2`.

  Regression tests added in `webull_test.exs` (`describe "market_status/1"`); the
  existing `capabilities().endpoints[{name, arity}] == :unsupported` sweep in
  `webull_test.exs`'s "the declaration" tests now covers it automatically.
  `fake_test.exs` and `fake_injection_test.exs` updated: `market_status/1` no longer has
  a real success path, so it is removed from `FakeInjection`'s whole-call injection
  surface, the same way `test_connection/2` and `get_rate_limit_status/2` already are.

- **`Fake.get_corporate_events/1` and `Fake.get_news/1` checked credentials before the
  argument `Rest`'s own equivalents require first**, the reverse of `Rest.get_corporate_events/2`
  and `Rest.get_news/2`'s own order (both run `required_symbol/1`/`required_symbols/1`
  before anything reaches `Auth.headers/2`). Calling either with neither the argument nor
  credentials answered `{:error, {:missing_credentials, :webull}}` here and
  `:symbol_required`/`:symbols_required` for real — a narrow but real way this fake was
  differently capable than the venue it stands in for. Found by a cross-package audit.
  Both now check the argument first, matching `Rest`'s order exactly.

- **A crash of `Feed` printed the `app_secret` HMAC-SHA1 signing key — and, if present,
  the account's `access_token` — in cleartext, in OTP's own crash report.** `Feed` keeps
  `state.resubscribe_opts` for its entire lifetime so a reconnect or a rebalance can
  replay a shard's subscription, and that keyword list's `:credentials` entry was a bare
  map. `replayable/2` also let a fresh `:credentials` from a later `subscribe/2` or
  `update_symbols/2` call overwrite it — unwrapped — on every call that supplied one.
  OTP's default crash report prints a `GenServer`'s state in full on termination, so a
  crash of `Feed` logged the signing key in cleartext — verified by crashing an
  equivalent process holding `%{app_key: "...", app_secret: "...", access_token: "..."}`
  as a bare field and reading the resulting log line back.
  `Process.flag(:sensitive, true)` was tried as an alternative and does not help: the
  same crash, with the flag set, printed the same cleartext state.

  Now `Feed` wraps the triple in `DpExchange.Webull.Credentials`, a struct whose
  `Inspect` is derived with `except:` naming all three fields, at both entry points
  (`init/1` and `replayable/2`) — `replayable/2`'s wrap is conditional on the key
  actually being present in the caller's own opts, because an unconditional default
  would have inserted `credentials: nil` and let `Keyword.merge/2` silently discard the
  already-wrapped credentials sitting in `state.resubscribe_opts` on every call that did
  not itself supply fresh ones. Nothing downstream changes: a struct is a map, so
  `Auth.headers/2`'s `%{app_key: k, app_secret: s} = credentials` still binds the real
  values inside the one function that has to sign with them, and `app_key_from/1`'s
  `%{app_key: app_key} when is_binary(app_key) -> app_key` still extracts it for
  `Socket.start_link/1`. Re-verified against a real crash of the new shape: the log line
  now reads `credentials: #DpExchange.Webull.Credentials<...>`.

  `Socket`'s own `state.app_key` is deliberately left as a bare string — `app_key` is
  sent as a plaintext header (`x-app-key`) on every signed request this venue accepts,
  so it carries none of the confidentiality `app_secret`/`access_token` do, and wrapping
  it would add a call-site change for no reduction in what a crash of `Socket` actually
  exposes.

- **`coverage/1`/`coverage_by_kind/1` kept reporting `:stream` for a shard's symbols
  after that shard's socket crashed.** `isolate_crashed_shard/3` (added for the W2 fix,
  see below) already rebuilt `state.shards` and fanned out a `:link_down` notice on a
  shard crash, but never touched `state.delivering`/`state.delivering_by_kind` — the same
  gap the WS-level `:link_down` handler has (it only flips `connected?: false`). A symbol
  whose only shard had just crashed kept reading as delivering until something else
  happened to overwrite its entry. Found by a 2026-09-07 supervision audit that asked
  directly whether `coverage/1` tells the truth immediately after a crash. Now cleared in
  `isolate_crashed_shard/3` the same way `unsubscribe/2` already clears a departing
  symbol's delivery record — a symbol whose only shard just died has exactly as little
  arriving for it as one that was never subscribed.

- **`FeedTest`'s `terminate/2` describe block asserted on `ExUnit.CaptureLog` *content*
  under `async: true`, and lost the race on seed 42.** `capture_log/1,2`'s isolation
  depends on a global swap of the Logger backend's output device; a content assertion
  raced against it is exactly the case concurrency breaks, and this file has 60+ other
  tests logging at `:debug` alongside unrelated HTTP request logging elsewhere in the
  suite under `max_cases: 20`. `refute log =~ "skipped"` failed against a blob of another
  test's log output that happened to contain it. Split into
  `FeedTerminateLogTest`, `async: false`, which removes the race structurally rather than
  narrowing the substring or widening a timeout — the underlying mechanism genuinely
  is not concurrency-safe for content assertions. Found by a cross-package audit running
  the full suite on multiple explicit seeds, which this family's CI does not do by
  default.

- **`child_spec/1` did not declare `type: :supervisor`, so OTP defaulted it to `:worker`**
  — which also defaults `:shutdown` to `5_000`ms instead of `:infinity`. A consumer
  terminating this child gave the whole nested tree (shards, MQTT sessions, rate limiter)
  only five seconds to shut down gracefully before `:kill`, rather than letting it unwind
  on its own terms. Invisible to any single-package review, and found only by diffing
  `child_spec/1` across all five venue packages against each other; `dp_exchange_schwab`
  was the only one that already declared it.

- **`capabilities/0` withheld `1y`, a width this venue serves, three Core releases after
  the reason stopped applying.** `historical_timeframes` was
  `Rest.wide_timeframes() -- @core_unnameable_widths`, where the subtracted list was
  `~w(1y)`. That workaround was correct when written: `dp_exchange_core` 0.1.48's
  `Timeframe.nameable/0` had no entry for `1y`, so `Capabilities.new/1` raised on it, and
  the package chose to report the gap upstream rather than invent a boundary rule or
  substitute a neighbouring width. Core 0.1.57's `@unbucketable` is `~w(1w 1M 1y)`; the gap
  closed and the subtraction did not. The declaration is now `Rest.wide_timeframes()`
  directly, so it tracks what `Rest` actually serves instead of a hand-maintained list, and
  a test asserts the two are equal rather than asserting a literal.

  Worth stating because it will recur: **nothing failed while this was stale.** The
  workaround was documented, dated, tested and correct on the day it was written, and its
  own comment said to remove it "the day `nameable/0` adds `1y`" — a condition no test
  could check, in a package whose tests all passed. Found only by a cross-package audit
  reading each venue's declaration against the Core version it now depends on.

- **`authenticated_streamable` was `[]` on a venue where every call is signed.** It reads
  as "none of the streamed kinds needs a credential", on a package that declares
  `credential_benefit: :required`, builds its MQTT token from `Auth.headers/2` in
  `Subscription`, and whose broker answers CONNACK `103`/`104` to anything unsigned. A host
  asking whether it needed a credential to stream quotes, top-of-book or trades was told
  no. Now `[:quotes, :top_of_book, :trades]` — the whole of `streamable`, since there is no
  anonymous path to any of them.

  Note the direction, which is easy to get backwards and which `usage-rules/feeds.md`
  currently states the wrong way round: `Capabilities.new/1` enforces
  `authenticated_streamable` as a **subset** of `streamable` — "of the kinds you stream,
  which need a credential" — and raises with "a kind that needs credentials must first be a
  kind the venue streams". Found by a cross-package audit; `dp_exchange_robinhood` carried
  the identical `[]` for the identical reason.

- **`FeedTest`'s W3 control-plane test raced under load and failed intermittently on
  certain random seeds.** `assert_receive {:blocked, blocked_pid}` waited only the
  suite's default timeout for a message a blocking test `plug` sends essentially
  synchronously once its process is scheduled — normally near-instant, but too tight
  once this file ran alongside its siblings under `async: true` with `max_cases: 20`.
  Widened to 3,000ms locally; the assertion still returns as soon as the message
  arrives, so this costs nothing on the passing path. Found by a cross-package audit
  running the full suite on multiple explicit seeds, which this family's CI does not do
  by default.

### Added

- **`script/check_doc_sources.sh` and `docs/reference/webull/doc-sources.tsv`** — a weekly,
  non-blocking check that every vendor documentation page this package cites still resolves
  the way it did when a person read it. It records status and redirect destination, and
  does **not** follow redirects or diff content: a permanent redirect is itself the change
  notice (this family lost a streaming API to one), while content diffing a rendered docs
  site would be red every week for reasons that are never the reason we care about. This
  is the instrument that found the 404 above, on its first run. Scheduled Mondays 09:20
  UTC via `.github/workflows/doc-sources-check.yml`, never on push, never in the publish
  chain, and it touches documentation sites only — never a venue API, which tier-2's
  never-on-a-schedule rule still forbids.

### Changed

- `docs/reference/webull/rest-rate-limits.md` rewritten against the per-endpoint table,
  and now records exactly **what is and is not machine-readable** on this vendor's site.
  Endpoint descriptions and their rate-limit blocks live in `<meta>` content and are
  fetchable anonymously; per-endpoint **parameter tables** are not, and still require an
  authenticated console — so `get_order_book/3`'s `depth` default remains uncaptured, as
  `negative-claims.md` already records. The belief that the rate-limit data was likewise
  unreachable was wrong, and it was wrong partly for a mundane reason now written down:
  every `docs/` URL without a trailing slash answers `301`, and the 189-byte redirect stub
  that comes back reads exactly like a JS-rendered shell unless you check the status code.

### Documentation

- **`Fake`'s own moduledoc still described a `{:refused, :missing_credentials}` path
  under `authenticated/1`** after that path was changed to
  `{:error, {:missing_credentials, :webull}}` — the code was already correct, only the
  prose describing it had drifted. Found by a cross-package audit comparing this family's
  credential-refusal vocabulary against each other.

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
