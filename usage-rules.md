# Using `dp_exchange_webull`

> **EXPERIMENTAL.** Not run in production. Pin three-part. Maturity is per endpoint —
> read `capabilities/0`, not this banner.

Everything general is in
[`dp_exchange_core`'s usage rules](https://hexdocs.pm/dp_exchange_core/usage-rules.html).
This file is only what is **specific to Webull**.

## Credentials are required for market data

There is no anonymous endpoint on this venue. Every OpenAPI call is signed, including the
ones that look public, so `get_price/2` needs credentials that the same call on Coinbase or
Gemini does not:

```elixir
{:ok, quote} = DpExchange.Webull.get_price("BTC-USD", credentials: %{
  app_key: "…", app_secret: "…"
})
```

`capabilities/0` declares `credential_benefit: :required` — the only venue in the family
that does. Branch on that rather than assuming market data is free; the alternative is
finding out from a 401.

You keep the credentials. This package signs one request with them and holds nothing.

## Start it, and it brings its own rate limiter

```elixir
children = [{DpExchange.Webull, credentials: my_credentials()}]
```

Passing credentials at start is what lets the package **replay your subscriptions after a
reconnect** — see below. Without them, a reconnect cannot re-subscribe.

## Subscribing is two protocols, and you see neither

Market data arrives over MQTT on a WebSocket. Subscriptions are HTTP calls. They are joined
by a session identifier this package generates and gives to both.

```elixir
:ok = DpExchange.Webull.subscribe(["BTC-USD"], credentials: creds, to: self())
```

**The venue does not restore subscriptions after a reconnect.** This package replays them
for you, which is the whole reason you never have to notice a reconnect. That replay uses
the credentials you supplied — at start, or on the subscribe call.

### Coverage means delivering, not accepted

On this venue there are three different moments: you asked, the HTTP subscribe returned
200, and data is arriving. `coverage/1` reports only the third. A 200 on the subscribe does
not mean the stream is flowing.

## The venue's connection budget shapes what you can ask for

| Constraint | Value |
|---|---|
| Concurrent connections per App Key | **5** |
| Server-side session retention after disconnect | **~1 minute** |
| Push rate per connection | **3 messages/second** |

This package opens **one** connection and never exposes sockets, so you cannot cause a
sixth. The one-minute retention is why reconnect backoff matters: reconnecting immediately
after hitting the limit fails until the venue ages the old sessions out.

If two instances ever shared a session id, the venue would disconnect whichever connected
first — each instance looking healthy in isolation. The id is generated per feed, so this
cannot happen unless you pass one explicitly.

## UAT has REST but no stream

```elixir
{:ok, quote} = DpExchange.Webull.get_price("BTC-USD", environment: :uat, credentials: creds)
```

`environment: :uat` gives authenticated REST against test data. There is **no UAT broker** —
the hostname does not resolve — so:

```elixir
DpExchange.Webull.subscribe(["BTC-USD"], environment: :uat)
#=> {:error, {:streaming_unavailable, :uat}}
```

It refuses rather than falling back to production, because a consumer testing against UAT
that received production prices would be reading real market data believing it was fake.

Ask first if you need to branch:

```elixir
if DpExchange.Webull.streaming?(environment: :uat), do: …
```

Production and UAT can run side by side — supervisor, feed and limiter names all derive
from the environment, so the two neither collide nor share a rate-limit bucket.

**`:production` is the default and a typo raises.** `environment: :uatt` is an
`ArgumentError`, not a quiet fallback: meaning UAT and getting production sends a real
order to a real broker.

## There is no trade volume, anywhere

Not on the bars, not on the snapshot, not on the stream. `volume` is `nil`, never `0` —
zero would look like a real measurement of no trading. `capabilities/0` says
`reports_trade_volume: false`, so route volume-dependent work to another venue rather than
reading a column of nils.

## Eight candle widths, and `1w` is deliberately not one

`1m 5m 15m 30m 1h 2h 4h 1d`.

The venue does serve a weekly bar. It is excluded because a weekly boundary depends on
which weekday the venue starts its week, `Core.Timeframe` models no alignment rule for it,
and a bar whose boundary cannot be verified is a bar that should not be stored.

Asking for a width outside that list is an error, never the nearest one.

## Timestamps come from the venue, or the call fails

A bar or quote the venue did not date returns `{:error, :missing_venue_timestamp}`. The
local clock is never substituted — an undated bar stamped with your own clock is
indistinguishable from a real one, which is how a gap becomes invisible.

## What this package does not do yet

Order placement, balances, accounts, fees, transfers, trade history, the order book and the
market overview are all `:unsupported` in this release. That is a statement about this
package, not about the venue — Webull serves all of them, and they have not been ported.
Read `capabilities/0` rather than assuming.
