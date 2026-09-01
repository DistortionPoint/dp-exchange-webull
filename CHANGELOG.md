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
