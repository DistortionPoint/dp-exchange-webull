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
