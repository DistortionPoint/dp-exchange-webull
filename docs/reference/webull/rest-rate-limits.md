# REST (Data API) rate limits — reference

**Source**: `https://developer.webull.com/apis/docs/market-data-api/faq/`.
**Read and measured 2026-09-08.**

Committed rather than linked, per D13. This is the number `capabilities/0`'s
`public_ceiling`/`authenticated_ceiling` rest on, and the number that configures the real
`DefaultRateLimiter` this package starts (`DpExchange.Webull.Supervisor`'s private `limits/0`) — not
narrative decoration, the thing that gates every REST call this package makes.

## The stated ceiling

> The Data API (HTTP) has a rate limit of 300 requests per 60 seconds.

Every endpoint here is signed — `credential_benefit: :required`, no anonymous quote
endpoint exists on this venue — so there is no separate "public" number to distinguish from
an "authenticated" one; the same 300/60s ceiling is the only general REST figure the venue
publishes for the Data API.

`300 / 60 = 5` requests per second.

## What this does not cover

The same FAQ page and its siblings document per-endpoint-class ceilings that are tighter or
looser than the general figure and are not folded into the single number this package
declares, because `Core.Capabilities`'s `public_ceiling`/`authenticated_ceiling` shape has
no per-endpoint-class dimension (the same shape gap `historical_timeframes` already has for
per-asset-class widths — see `webull.ex`'s own `measured_against`):

- **Order operations**: 40 requests per 2 seconds (`https://developer.webull.com/apis/docs/reference/order-open/` and sibling pages) — looser than the general ceiling.
- **Futures market data**: 600 requests per minute for most endpoints; the batch-query interface is 1 call per second per App Key (`https://developer.webull.com/apis/docs/reference/futures-market-data/`).
- **Option market data**: 60 requests per minute for tick data; batch bar queries are 1 call per second per App Key (`https://developer.webull.com/apis/docs/reference/option-market-data/`).
- **Data Streaming API (MQTT) subscribe/unsubscribe**: no stated rate limit — a different transport, already covered by `@pairs_per_socket`/`@max_shards` in `Feed`, not this figure.

The general 300/60s figure is the more conservative of these for ordinary market-data
reads, which is what this package's shared limiter mostly gates, so it is the one declared.
A future per-endpoint-class limiter would need each of the numbers above individually.

## Corroborating evidence already in this repo

`Supervisor`'s own moduledoc records "the prior adapter measured 118 ms per call across 342
symbols" in production — about 8.5 req/s sustained. That is empirical evidence from a
different measurement (wall-clock pacing observed in a live deployment, not a probe of the
documented ceiling itself) and is *higher* than the 5 req/s this page documents; it is
noted here for a future reader reconciling the two, not treated as overriding the vendor's
own stated number.
