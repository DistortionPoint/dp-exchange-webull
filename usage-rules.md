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

`capabilities/0` declares `credential_benefit: :required` — the first venue in the family
to, and not the only one (`dp_exchange_robinhood` and `dp_exchange_schwab` declare it too).
Branch on that rather than assuming market data is free; the alternative is finding out
from a 401.

You keep the credentials. This package signs one request with them and holds nothing.

### It is not only market data, and the fake enforces all of it

Every account and order call — `get_accounts/2`, `get_balances/2`,
`get_transfers/2`, `get_transactions/2`, `get_positions/1`, `quantization/2`,
`place_order/3`, `place_orders/3`, `preview_order/3`, `replace_order/4`,
`cancel_order/3`, `get_order/3`, `get_orders/2` — and every options, watchlist,
fundamentals, news and screener call — `get_option_chain/2`, `get_option_expirations/2`,
`list_watchlists/1`, `get_watchlist/2`, `create_watchlist/3`, `update_watchlist/2`,
`delete_watchlist/2`, `get_financials/3`, `get_corporate_events/1`, `get_filings/2`,
`get_news/1`, `get_screener/2` — refuses the same way market data does
without a credential: `{:error, {:missing_credentials, :webull}}`, never `{:ok, _}`. Not
`{:refused, _}` either — a missing local credential never reaches the venue at all
(`Core.Venue`'s `:refused` is the venue's own permanent word about a request it
*received*), so this is `Auth.headers/2`'s own return value, not an invented one.

**`DpExchange.Webull.Fake` enforces this too, and it did not before.** Before this
fix, `Fake.get_accounts/2`, `Fake.get_balances/2`,
`Fake.get_transfers/2`, `Fake.get_transactions/2`, `Fake.place_order/3`,
`Fake.place_orders/3`, `Fake.preview_order/3`, `Fake.replace_order/4`,
`Fake.cancel_order/3`, `Fake.get_order/3`, `Fake.get_orders/2`, `Fake.get_positions/1`
and `Fake.quantization/2` answered `{:ok, _}` regardless of whether credentials were
supplied at all — several ignored the argument outright, and two checked only
`opts[:account_id]`, a different question. A consuming test suite that called any of
these without credentials and asserted success was passing against behaviour the real
venue does not have. If your own tests do this, they need updating; that is the point of
the fix, not a regression in it.

**`market_status/1` and `get_fees/2` are the exceptions, and stay exceptions.**
`market_status/1` answers `{:error, :not_supported}` regardless of credentials — this
venue publishes no reachable market-status endpoint, so there is nothing to gate.
`get_fees/2` answers `{:ok, _}` with no credential at all: it builds no request and
returns a crypto spread rate captured from Webull's own published pricing
(`source: :published_rate`), so there is nothing here for a credential to gate either.
A 2026-09-06 sweep gated `get_fees/2` behind a credential anyway, reasoning that its
real path "had never run through `Auth.headers/2`" — true, and the reason there is
nothing to gate, not a reason to add a check. That broke a real consumer resolving fees
before any account is attached, and was reverted 2026-09-07. If your code passes no
credential to `get_fees/2`, that is correct usage, not a workaround.

The same gap survived one round longer on the options, watchlist, fundamentals, news and
screener callbacks, and is now closed as well: `Fake.get_option_chain/2`,
`Fake.get_option_expirations/2`, `Fake.list_watchlists/1`, `Fake.get_watchlist/2`,
`Fake.create_watchlist/3`, `Fake.update_watchlist/2`, `Fake.delete_watchlist/2`,
`Fake.get_financials/3`, `Fake.get_corporate_events/1`, `Fake.get_filings/2`,
`Fake.get_news/1` and `Fake.get_screener/2` all answered `{:ok, _}` with no credentials.
The credential check now runs **before** each call's own argument validation, matching the
real `Rest` order — so `Fake.get_corporate_events()` with neither a credential nor a
`:symbol` is `{:error, {:missing_credentials, :webull}}`, not `{:error, :symbol_required}`.
These were missed by the earlier sweep because `dp_exchange_core`'s assertion 17 checks a
fixed list of nine callback names that predates this surface and does not include any of
them — passing that assertion is not evidence that the rest of your fake gates credentials.

## Start it, and it brings its own rate limiter

```elixir
children = [{DpExchange.Webull, credentials: my_credentials()}]
```

Passing credentials at start is what lets the package **replay your subscriptions after a
reconnect** — see below. Without them, a reconnect cannot re-subscribe.

**You never need to pass `:limiter` yourself.** The supervision tree above starts and names
its own rate limiter, and every call this package makes on your behalf — the reconnect
replay, the 60-second blind resubscribe, and `subscribe/2`/`unsubscribe/2`/`update_symbols/2`
called with no `:limiter` in `opts` — is wired to it automatically. If you do pass one
explicitly, it wins.

## A shard's socket crash costs one shard, never your whole subscription

Each shard's MQTT-over-WebSocket connection is a **linked** child of `Feed` — not a
supervised sibling you can restart independently. `Feed` traps exits, so a shard's
socket dying abnormally does not take `Feed` down with it: only that shard's symbols
drop out of `coverage/1` and `coverage_by_kind/1` (cleared immediately, not left to
report `:stream` for a connection that no longer exists), you get a `:link_down`
`Core.Notice` naming the crashed shard, and this package reopens it on its own — you
never need to call `subscribe/2` again.

**Your `app_secret` and `access_token` will not appear in `Feed`'s crash log.** `Feed`
keeps what you passed at start (or on a later `subscribe/2`) so it can replay your
subscriptions after a reconnect — see above — and a crash of `Feed` logs its state via
OTP's default crash report, which is where you *would* see it, because a crash report
prints unredacted `Logger` metadata otherwise. The credential map is wrapped in a struct
before it ever reaches state, so the crash line reads `credentials:
#DpExchange.Webull.Credentials<...>` rather than the key pair itself. This does not
extend to `app_key` on a live shard's socket — `app_key` is sent as a plaintext header
(`x-app-key`) on every signed request this venue accepts by design, so it carries none of
the confidentiality `app_secret` does, and a shard's own crash report still shows it.

**A specific cause of that per-shard crash is now a clean reconnect instead — see
dp-exchange-core issue #27.** Webull sometimes closes a shard's socket with a WebSocket
close frame that carries prose instead of an RFC 6455 status code (observed:
`"bye-bye!!!"`). Every published version of `websockex` through 0.5.1 (the current Hex
release) raises on that frame and kills the socket process outright — before this
package's own reconnect logic runs at all — which is indistinguishable from any other
crash from where you sit, except that it can repeat every few seconds under sustained
conditions, holding a shard's coverage down well below its symbol count even though
nothing alarms (each crash is caught and reopened, so supervision "works"). This package
now vendors a two-line fix ahead of upstream — see `DpExchange.Webull.Vendor.WebSockex`'s
own moduledoc if you want the mechanism — so this specific cause no longer crashes the
shard: it is an ordinary `:link_down` / reconnect-and-resubscribe cycle, the same as any
other disconnect reason. If you were seeing elevated shard-crash `:link_down` notices or
a Webull coverage ceiling well below your symbol count before this fix, that is the most
likely explanation; if it persists after upgrading, the venue is closing the connection
for a different, still-open reason — see this package's own CHANGELOG entry for what was
and was not established about why.

**What still costs you your whole subscription: `Feed` itself crashing** — a bug outside
the per-shard crash path, or anything that kills the `Feed` pid directly.
`DpExchange.Webull.Supervisor` restarts `Feed` under `:one_for_one`, but from the
*static* `opts` your supervision tree started it with; every `subscribe/2`,
`update_symbols/2` and `subscribe_notices/1` call you made afterward is gone. Nothing
inside this package can replay those calls — it never held onto the functions or the
process that made them. If your consumer needs to survive a `Feed` restart unattended,
monitor the `Feed` pid (or the `DpExchange.Webull` pid it sits under) yourself and
re-issue `subscribe/2` on `:DOWN`.

## Subscribing is two protocols, and you see neither

Market data arrives over MQTT on a WebSocket. Subscriptions are HTTP calls. They are joined
by a session identifier this package generates and gives to both.

```elixir
:ok = DpExchange.Webull.subscribe(["BTC-USD"], credentials: creds, to: self())
```

**The venue does not restore subscriptions after a reconnect.** This package replays them
for you, which is the whole reason you never have to notice a reconnect. That replay uses
the credentials you supplied — at start, or on the subscribe call.

### Three kinds arrive on the same subscription, not one

A subscribe asks the venue for its `SNAPSHOT`, `QUOTE` and `TICK` topics, and all three
are forwarded to you: `%DpExchange.Core.Types.Quote{}` (a traded price),
`%DpExchange.Core.Types.TopOfBook{}` (bid/ask) and `%DpExchange.Core.Types.Trade{}` (one
print — the tape). Match on the struct, not on having subscribed once — a handler that
only matches `%Quote{}` silently drops every top-of-book message and every trade rather
than erroring.

```elixir
receive do
  {:dp_exchange, :webull, %DpExchange.Core.Types.Quote{} = q} -> handle_price(q)
  {:dp_exchange, :webull, %DpExchange.Core.Types.TopOfBook{} = t} -> handle_book(t)
  {:dp_exchange, :webull, %DpExchange.Core.Types.Trade{} = t} -> handle_trade(t)
end
```

`capabilities/0` declares `streamable: [:quotes, :top_of_book, :trades]` for exactly this
reason. **`Trade.id` is always `nil` on this venue** — the streamed tape carries no
per-print identifier, on this topic or on `get_trades/2`'s REST tape, and `nil` says that
truthfully rather than inventing one.

Unlike `SNAPSHOT`/`QUOTE`, `TICK`'s presence in the default subscribe is read from the
venue's own documentation and has not been confirmed against the live venue — see
`capabilities/0`'s `measured_against`. If the venue answers `TICK` differently than
documented, that surfaces the same way any other subscribe refusal does.

### Coverage means delivering, not accepted

On this venue there are three different moments: you asked, the HTTP subscribe returned
200, and data is arriving. `coverage/1` reports only the third. A 200 on the subscribe does
not mean the stream is flowing.

`coverage/1` folds all three kinds above into one `:stream` per symbol. `coverage_by_kind/1`
splits them apart — a symbol can show `:quotes` healthy while `:top_of_book` or `:trades`
has gone dark for it, or the reverse, and `coverage/1` alone cannot tell you which:

```elixir
DpExchange.Webull.coverage_by_kind(credentials: creds)
#=> %{
#=>   quotes: %{"BTC-USD" => :stream},
#=>   top_of_book: %{"BTC-USD" => :stream},
#=>   trades: %{"BTC-USD" => :stream}
#=> }
```

## The venue's connection budget shapes what you can ask for

| Constraint | Value |
|---|---|
| Concurrent connections per App Key | **5** |
| Server-side session retention after disconnect | **~1 minute** |
| Push rate per connection | **3 messages/second** |

This package shards across **at most five** connections — the venue's own ceiling — because
a single MQTT session caps at 100 subscribed tickers. It never exposes sockets, so you
cannot cause a sixth: five shards of 100 is 500 symbols, and a larger universe on this venue
needs a second App Key rather than a bigger number here. The one-minute retention is why
reconnect backoff matters: reconnecting immediately after hitting the limit fails until the
venue ages the old sessions out.

If two instances ever shared a session id, the venue would disconnect whichever connected
first — each instance looking healthy in isolation. The id is generated per shard, inside
this package, so this cannot happen.

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

`live?/1` answers the money question directly, resolving `opts` the same way every call
here does, so a caller can confirm before a money-moving call rather than trust a default:

```elixir
if DpExchange.Webull.live?(opts) do
  # confirm with a human before place_order/3 goes out
end
```

## There is no *aggregate* trade volume on crypto — but there is on stocks

Not on the bars, not on the crypto snapshot's `Quote.volume`. On a crypto symbol that field
is `nil`, never `0` — zero would look like a real measurement of no trading.

**The stock snapshot is different**: `get_price/2` with `category: "US_STOCK"` or
`"US_ETF"` carries a real `volume`, the day's aggregate rather than the last trade's size.
`capabilities/0` says `reports_trade_volume: true` because that path is real — a single
package-wide boolean cannot say "true for equities, false for crypto," and `false` would
be an under-declaration of a venue capability this package already reaches. Branch on
`opts[:category]`, not on the boolean alone, if the distinction matters to you: `nil` on a
crypto call, a real aggregate on a stock or ETF call. Bars carry no volume on any category,
and `get_volume_profile/3` is the equity endpoint that splits traded volume by price and
side.

That is a different claim from `Trade.quantity` — the streamed tape and `get_trades/2`
both report **one print's own size**, which the venue does publish. This package does not
sum sizes into an aggregate figure of its own; that would be this package's arithmetic
wearing the venue's name.

## Eleven declared candle widths

`1m 5m 15m 30m 1h 2h 4h 1d 1w 1M 1y` — the full `capabilities/0` `historical_timeframes`
list, as of 2026-09-07. Two under-declarations were corrected to get here. Until 2026-09-06
this declared only the first eight, the crypto and event-contract default generalised to the
whole venue, which was false for the equity, option and futures bars that have always served
`1w` and `1M` too. `1y` was then withheld for a real reason that stopped being true:
`dp_exchange_core` 0.1.48's `Timeframe.nameable/0` had no entry for it and
`Capabilities.new/1` raised on it. Core 0.1.57 names it, and the workaround outlived the gap
by three releases — nothing fails when a documented workaround goes stale, which is exactly
why a served width stayed hidden from consumers reading `capabilities/0`.

The crypto and event-contract bar endpoints serve `1m 5m 15m 30m 1h 2h 4h 1d` and nothing
wider. `1w` is left off *those* endpoints deliberately: a weekly boundary depends on which
weekday the venue starts its week, `Core.Timeframe` models no alignment rule for it, and a
bar whose boundary cannot be verified is a bar that should not be stored. That reasoning is
about a continuous, boundary-less crypto week — it does not apply to equities, which trade
on a fixed calendar week the venue's own bar aligns to.

The equity, option and futures bar endpoints take three widths beyond those eight — `1w`,
`1M` and `1y` — because that is the `timespan` vocabulary those endpoints publish
(`Rest.get_stock_bars/5`, tested against it). `Core.Capabilities` has one flat list for the
whole package with no per-asset-class shape, so the declaration is the union every active
path reaches rather than the crypto subset, and it is now derived from
`Rest.wide_timeframes/0` rather than a hand-maintained subtraction from it. Asking a
**crypto or event-contract** category for `1w`, `1M` or `1y` is still an error, never the
nearest width it does serve — branch on `opts[:category]`, not on the flat list alone, if
you need to know which endpoint a width actually reaches.

### Equity/ETF bars are adjusted at daily and above, not below

`get_historical_prices/4` against `US_STOCK`/`US_ETF`: daily and longer widths are
forward-adjusted for splits, minute widths are not — the vendor's own rule, and these are
two different series, not the same one at two resolutions. `adjusted?/1` answers it for a
width before you fetch it, so stitching a daily series onto a minute one across a split
does not join an adjusted half to an unadjusted one silently:

```elixir
DpExchange.Webull.adjusted?("1d")  #=> true
DpExchange.Webull.adjusted?("1m")  #=> false
```

## Timestamps come from the venue, or the call fails

A bar or quote the venue did not date returns `{:error, :missing_venue_timestamp}`. The
local clock is never substituted — an undated bar stamped with your own clock is
indistinguishable from a real one, which is how a gap becomes invisible.

## What this package does not do yet

**Read `capabilities/0`, not this paragraph.** As of 2026-09-01 the order path, balances,
accounts, transfers and order book are all implemented, along with options, futures, event
contracts, fundamentals, screeners, news and watchlists. `get_trade_history/2` and
`get_market_overview/1` are **not** — both still answer `{:error, :not_supported}`, as
not-yet-ported rather than as an absence at the venue. What remains `:unsupported` is listed
there and per endpoint.

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

**The default depends on which endpoint you called.** `get_price/2`, `get_top_of_book/2`,
`get_historical_prices/4` and `get_symbols/1` default to `US_CRYPTO`, which is what this
package served before it widened. `get_order_book/2`, `get_trades/2`, `get_volume_profile/3`
and `get_fundamental/3` default to `US_STOCK`, because this venue publishes no crypto depth,
tape or footprint endpoint for them to have defaulted to. Changing either default would
silently re-route existing callers onto a different market.

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

## A stop order needs `:stop_price`; a trailing stop needs `:trailing_stop_step`

`place_order/3`'s `request` map takes the same field names for every instrument type, and
which ones matter depends on `:order_type`:

| `:order_type` | fields it needs |
|---|---|
| `:market` | `:quantity` or `:amount` |
| `:limit` | the above, plus `:price` |
| `:stop` | the sizing field, plus `:stop_price` — **no `:price`**, this order type has no limit leg |
| `:stop_limit` | the sizing field, plus `:price` and `:stop_price` |
| `:trailing_stop` | the sizing field, plus `:trailing_stop_step` |

A field a given order type does not use is dropped rather than sent — a `:stop` request
built from a `:limit` template (with `:price` left over) will not carry a stray
`limit_price` the venue's schema for `STOP_LOSS` does not have. Read the fields back the
same way: `get_order/2` and the struct `place_order/3` hands back both carry `:stop_price`
on a stop or stop-limit order, `nil` on anything else.

**Which pairs of `:order_type` and `:time_in_force` this venue actually accepts differs by
instrument** — crypto's list is five pairs (`MARKET`/IOC, `LIMIT` and `STOP_LOSS_LIMIT` at
DAY or GTC — no plain `STOP_LOSS`, no `TRAILING_STOP_LOSS`); equity, option and futures
orders add `STOP_LOSS` and (equity only) `TRAILING_STOP_LOSS`; an event contract
takes `LIMIT` only, at any of five time-in-force values. A pair outside the matrix is
refused before the request is sent, naming both halves of what was wrong, rather than being
sent and rejected by the venue.

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
