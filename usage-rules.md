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

**Read `capabilities/0`, not this paragraph.** As of 2026-09-01 the order path, balances,
accounts, transfers, trade history, order book and market overview are all implemented, along
with options, futures, event contracts, fundamentals, screeners, news and watchlists. What
remains `:unsupported` is listed there and per endpoint.

The **money-movement** callbacks are the ones that will not arrive: Webull's published API
moves no money. There is no payment-method endpoint at either scope, no bank registration,
no crypto network list, no allowlist and no transfer between accounts — funding happens in
Webull's own applications, which need a person.

## Five markets, five sets of endpoints, five parameter sets

`opts[:category]` routes: `US_CRYPTO`, `US_STOCK`/`US_ETF`, `US_OPTION`, `US_FUTURES`,
`US_EVENT`. **They are not one endpoint with a filter** — each is its own path with its own
parameters, and this package sends only the ones that endpoint's page documents.

That matters because the sets differ in ways that look arbitrary and are not: futures bars
take no `real_time_required` and no time range; the futures tape and depth take no session
filter; the option snapshot takes no extended-hours block. **A parameter an endpoint does not
know is at best ignored and at worst a refusal, and neither tells you which happened.**

The default is still `US_CRYPTO`, which is what this package served before it widened.
Changing that default would silently re-route existing callers onto a different market.

## Event contracts have two prices and four books

**`get_trades/2` and `get_order_book/2` refuse `US_EVENT`, and that is deliberate.** An event
tick carries a `yes_price` *and* a `no_price` and a side of `yes`/`no`; `Types.Trade` has one
price and a side of `:buy`/`:sell`. An event book returns four arrays; `Types.OrderBook` has
two sides.

Use `get_event_trades/2` and `get_event_order_book/2`, which return the venue's own rows. The
nearest mapping would produce a number that looks right and belongs to **the other instrument
of a two-instrument market**.

The venue notes that in a binary market a yes bid at X equals a no ask at 1−X. That identity
is the venue's; this package does not derive one side from the other, because a derived level
cannot be told from a quoted one.

**Event bars do not say which side they are.** The venue's schema names `open`, `close`,
`high`, `low` and no side. Reconcile against `get_event_trades/2`, which does name both.

## Options: a chain is rebuilt, and greeks do not exist here

`get_option_chain/2` turns the venue's flat contract list into expiry × strike, both sides.
**A contract this package cannot address — no readable expiry, strike or right — is refused,
naming the keys the venue actually sent.** A dropped row leaves a chain with a hole in it
that looks complete.

A strike listed with one side keeps a `nil` on the other. `:underlying_price` is `nil`: this
endpoint lists contracts and does not quote the underlying, and pairing it with a price
fetched separately is two observations at two times.

**`get_option_greeks/2` returns `{:error, :not_supported}` and it is the venue, not the
package.** No Webull endpoint publishes them, and computing them would need a rate and a
volatility surface it does not publish either.

## Fundamentals: twenty-three endpoints, one shape

`get_fundamental/3` reaches any of them; `fundamental_kinds/0` lists them. Every one takes
`symbol` and `category`; **`:type` and `:count` reach only the endpoints that document them**
and are dropped elsewhere.

`get_financials/3` takes the contract's `:balance_sheet`, `:income`, `:cash_flow` or
`:indicators`. **A fundamentals kind that is real but is not a statement is refused** —
`:company_profile` exists and answering `get_financials/3` with it would put a profile in a
statement's shape.

**`fiscal_period` is the venue's code translated through the venue's own legend**
(`0=FY, 1=Q1 …`). The raw integer stays in `line_items`, and a code outside the legend leaves
the label `nil` rather than inventing one.

**`get_corporate_events/1` needs `:symbol`** — these calendars are per issuer, not
market-wide — and without `:kind` reads *both* calendars, which is two requests.

**`get_news/1` is generated, not reported.** The vendor's own description is "invokes LLM to
generate news summaries", so each `summary` is a model's paraphrase and `source` names the
venue rather than a wire. If you quote it, you are quoting a summary.

**A screener's rank is the position the venue returned the row in.** Nothing is re-ranked:
two venues' "top movers" answer different questions, and so do one venue's under two sorts.

## Watchlists: three absences and a boolean

`symbols` is `nil` on a `list_watchlists/1` row — that endpoint names watchlists and does not
read membership, and `[]` would say the watchlist is empty. `name` is `nil` on
`get_watchlist/2`, because the membership endpoint does not return it.

**`update_watchlist/2` refuses `opts[:symbols]`.** This venue's update endpoint touches
properties only; `add_watchlist_instruments/3` and `remove_watchlist_instruments/3` are the
membership writes, and silently skipping the option would leave you believing the list
changed.

**Every watchlist write answers `{"success": …}` rather than an error status**, so a `false`
is a 200 that did nothing — reported here as `{:refused, :watchlist_write_rejected}`.

**Creating with members is two requests.** Where the add fails, the watchlist exists and is
empty: `{:error, {:watchlist_created_without_members, id, reason}}` carries its id so you can
deal with it.

## Batch orders: fifty, equities, and one request

`place_orders/3` is **not `place_order/3` in a loop** — the venue accepts the batch as one
request. Both of its limits are enforced before the request: **50 orders** and **equities
only**. A batch over the cap is refused rather than split, because splitting turns one atomic
request into several.

**The result is per order.** The venue validates each and returns each; a batch where three
of five were accepted is the normal shape. The vendor also notes the endpoint is not
available to every client, so a refusal can mean the account is not entitled.

## Tokens: a token that exists is not a token that works

`create_token/1` returns one that is `PENDING`, and verification happens through an SMS code
in the Webull app — which needs a person. `check_token/2` is the only call that tells
`PENDING` from `EXPIRED` from `INVALID`; all three fail identically at the next request and
each has a different remedy.

`oauth_token/3` is one endpoint doing two jobs on a **different host**, with a form body.
`opts[:code]` exchanges, `opts[:refresh_token]` refreshes, and exactly one is required.
**Two expiries come back and they are not the same clock** — `rt_expires_in` is the one that
ends the session.

## Every negative here is audited

`docs/reference/webull/negative-claims.md` lists each one with the source and date consulted.
**Three were wrong**, all the same mistake: a true statement about the *stock* endpoint
restated as a claim about the venue. It also records why the vendor's pages have to be
**rendered** to be read — their parameter tables are built in JavaScript, and an inventory
captured without them looks finished and cannot be implemented from.
