# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Status: EXPERIMENTAL

Stated here rather than only per-release, because a reader arriving at a specific version
needs it as much as one reading the top.

This package has not run in production. While it is `0.x` the API may change without a
major version. Coverage is uneven by design: fakes and live public endpoints are well
covered, order placement and authenticated flows are not.

**Whenever an endpoint moves to `:proven`, the entry that does it states the evidence** —
what was run against the live venue, and when. "Marked proven" with no evidence is not an
acceptable changelog line.

## [Unreleased]

### Added

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
