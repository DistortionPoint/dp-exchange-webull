# Using `dp_exchange_webull`

> **EXPERIMENTAL.** Not run in production. Pin three-part. Maturity is per endpoint —
> read `capabilities/0`, not this banner.

Everything general is in
[`dp_exchange_core`'s usage rules](https://hexdocs.pm/dp_exchange_core/usage-rules.html).
This file is only what is **specific to Webull**.



## BREAKING — a refusal now carries the venue's status as well as its words

```elixir
# before
{:refused, {:venue_error, "signature mismatch"}}

# after
{:refused, {:venue_error, 401, "signature mismatch"}}
```

This package refuses on `400`, `401` and `403`, and **all three used to look identical to a
caller** even though their remedies are opposite:

| status | what to do |
|---|---|
| `400` | fix the request — sending it again unchanged cannot work |
| `401` | refresh the token and call again, which is a different request |
| `403` | a person must change what this credential is entitled to |

An unrecognised body now keeps its status too — `{:venue_error, 403}` rather than a bare
`:refused`. Thin, but it is the difference between "the venue rejected this and here is
which kind" and "something went wrong".

This is the shape `dp_exchange_coinbase`, `dp_exchange_robinhood` and `dp_exchange_schwab`
already used; this venue was the outlier.

**If you pattern-match refusal reasons, check that clause before upgrading.** A caller
matching `{:venue_error, message}` will now fall through to whatever catch-all follows it —
silently, with nothing raising. That exact trap cost a consumer a canonical error mapping on
`dp_exchange_gemini` and is worth ten seconds of grep here.

## BREAKING — `Quote` and `OrderBook` no longer carry `:timestamp`

They carry **`:venue_time`** (the venue's own, `nil` where the venue publishes none) and
**`:observed_at`** (when this package read it, always present) — the shape
`Core.Types.TopOfBook` has always had. Requires `dp_exchange_core ~> 0.2.1`.

```elixir
# before
quote.timestamp

# after
quote.venue_time  # may be nil — the venue did not date this
quote.observed_at # always present
```

**Why it had to break.** `:timestamp` was documented as the venue's own, "never invented",
and two packages in this family could not keep that promise: the frames they decode carry no
venue time at all. With one field their only options were to lie or to drop real data, and
they lied. Now they can say `nil` and mean it.

**What to do with `nil`.** Whatever you would have done with a wrong answer, but knowingly.
The consumer who decided this design stores `venue_time` as their time-series point time
where it is present, and where it is `nil` stores `observed_at` **and records that they
did** — so a mis-bucketed value is attributable rather than invisible. That decision was not
expressible before, because there was no way to see which kind of time you had.

`Trade`, `Fill`, `Balance` and `OrderBookDelta` are **unchanged** — they keep a single
`:timestamp`, because every one of them is built from a venue-supplied time and fails closed
without it.


**When is `venue_time` `nil` on this venue? Whenever the venue did not state one — and until
0.4.37 this section said it never is.** It read: "Every `Quote` and `OrderBook` this package
builds parses a time the venue sent … and fails closed when it cannot. A `nil` branch for
this venue is dead code."

That was true and stopped being true in 0.4.36 and 0.4.37, when the REST quote, the REST
order book, and the MQTT quote and book stopped discarding real prices and real levels over
a time the venue had not stated. `Core.Types.Quote` and `Core.Types.OrderBook` do not enforce
`venue_time`, and `observed_at` is what states freshness. **Write the `nil` branch.**

Nothing is ever substituted into that field: it is the venue's own instant or it is `nil`,
never this package's clock. Other venues in the family return `nil` too, which is why the
field is nullable.

Full reasoning and the options that were weighed:
[`dp_exchange_core` issue #31](https://github.com/DistortionPoint/dp-exchange-core/issues/31).

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

**A blank credential counts as a missing one.** An `:app_key` or `:app_secret` that is `""`, or only
whitespace, is refused locally with `{:error, {:missing_credentials, :webull}}` — it is
never signed with. This matters because the usual way a credential goes missing is not a
`nil`: it is a `.env` line reading `NAME=` with nothing after it, and `System.get_env/1`
hands that back as `""`. Signing with it produced a well-formed request the venue refused
for a reason naming signatures, which points at the signing code rather than at the
credential.

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
now vendors a fix ahead of upstream — see `DpExchange.Webull.Vendor.WebSockex`'s
own moduledoc if you want the mechanism — so this specific cause no longer crashes the
shard: it is an ordinary `:link_down` / reconnect-and-resubscribe cycle, the same as any
other disconnect reason. If you were seeing elevated shard-crash `:link_down` notices or
a Webull coverage ceiling well below your symbol count before this fix, that is the most
likely explanation; if it persists after upgrading, the venue is closing the connection
for a different, still-open reason — see this package's own CHANGELOG entry for what was
and was not established about why.

**The same vendored fork gives the opening handshake a deadline** (2026-09-27):
`socket_connect_timeout` plus `socket_recv_timeout`. Upstream bounds each read of the
upgrade response separately, so a peer that trickled the response held a shard's open,
or its reconnect, indefinitely. That kept `Feed` waiting inside a call on open, and kept
the shard delivering nothing on reconnect. A handshake that misses the deadline now fails
with `%WebSockex.ConnError{original: :timeout}`, the error a plain read timeout gives, and
takes the ordinary failed-open or reconnect-with-backoff path.

**The WebSocket verifies the venue's TLS certificate** (2026-09-27). websockex's own
default is not to (`verify: :verify_none`), and until then this package connected with
that default, accepting any certificate. It now uses the operating system's trust store and
HTTPS hostname rules. On a host with no system CA bundle the connection fails with a TLS
error rather than connecting unverified. Pass your own `:ssl_options` to override.

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

### What one subscription delivers, and where its volume comes from

A subscribe asks the venue for its `SNAPSHOT`, `QUOTE` and `TICK` topics. Each is forwarded
to you as its own type: `%DpExchange.Core.Types.Quote{}` (a traded price),
`%DpExchange.Core.Types.TopOfBook{}` (bid/ask) and, whenever the venue sends a tick,
`%DpExchange.Core.Types.Trade{}` (one print). Match on the struct, not on having subscribed
once. A handler that only matches `%Quote{}` silently drops every other message rather than
erroring.

```elixir
receive do
  {:dp_exchange, :webull, %DpExchange.Core.Types.Quote{} = q} -> handle_price(q)
  {:dp_exchange, :webull, %DpExchange.Core.Types.TopOfBook{} = t} -> handle_book(t)
end
```

**A streamed `TopOfBook` now carries `bid_size` and `ask_size`.** Until 0.4.34 they were
always `nil`, on the strength of a comment saying this venue published no depth at the top.
Its own protobuf schema declares `size` on every level and the decoder had been reading it
off the wire and discarding it. A `nil` there still means what `Core.Types.TopOfBook` says
it means — "not published", never "none available" — so a level the venue sends without a
size is `nil`, and one that states `"0"` is a zero.

**Volume comes by two routes, and each says which quantity it is.**

* **The snapshot's `volume`** arrives on every streamed `Quote` that states one, with
  `volume_window: :running_total`: the session's cumulative total. Difference consecutive
  values for an interval's volume, and treat a decrease as a reset. Never sum them.
* **The tick** arrives as a `Trade` whose `quantity` is one print: sum these. `id` is `nil`,
  because the tape carries no per-print identifier.

`TICK` is requested by default again (dp_exchange_webull issue #7). The streaming page lists
it for "Stocks, Futures and Crypto". A consumer on ~325 us-crypto symbols measured none on
2026-09-29 (dp-exchange-core issue #40), from a request the venue accepted with `TICK` in it.
So asking costs nothing, and every tick that does arrive is delivered. `capabilities/0`
declares `streamable: [:quotes, :top_of_book]`. `:trades` joins it once a run shows ticks
arriving, because a declaration states what was measured.

**Measured on 2026-10-02, on 0.4.99: both routes are empty for crypto.** A consumer
subscribed with `TICK` and saw the request accepted and quotes flowing. Its first Webull
quote carried no `volume`, so the snapshot leaves field 8 empty. About 6 minutes in, its
1-minute candles for BTC-USD and ETH-USD read `volume_avg` 0 and OBV 0, so no tick had
arrived for either. Gemini's BTC-USD, built from Gemini's `:trades`, read real volume on the
same consumer at the same moment. **Webull crypto delivers no traded volume on its stream.**
The REST snapshot and the bars read a `volume` field whenever a response carries one, but
their spec documents none for crypto. For volume on a pair Webull trades, use another
venue's `:trades` for the same pair. That choice belongs to the consumer. This package
never puts another venue's volume under Webull's name.

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

Not on the bars, and not on the REST crypto snapshot's `Quote.volume`. On a crypto symbol from
`get_price/2` that field is `nil`, never `0`, because zero would look like a real measurement
of no trading.

**The streamed snapshot is passed through, not assumed away.** A `Quote` from the stream
carries the `Snapshot` frame's own `volume` (field 8) whenever the frame states one, with
`volume_window: :running_total`: the session's cumulative total, to be **differenced, never
summed**. Treat a decrease as a reset. When a frame leaves the field empty, `volume` and
`volume_window` are both `nil`. This package has not measured whether crypto frames fill
it in. Read `volume_window`, not the venue, to know what a `Quote.volume` means: every
quote that carries a volume now says which quantity it is.

**The stock snapshot is different**: `get_price/2` with `category: "US_STOCK"` or
`"US_ETF"` carries a real `volume`, the day's aggregate rather than the last trade's size.
`capabilities/0` says `reports_trade_volume: true` because that path is real — a single
package-wide boolean cannot say "true for equities, false for crypto," and `false` would
be an under-declaration of a venue capability this package already reaches. Branch on
`opts[:category]`, not on the boolean alone, if the distinction matters to you: `nil` on a
crypto call, a real aggregate on a stock or ETF call. **Bars are the same split, not a
blanket "no volume":** the stock, option, futures and event bar endpoints each document a
required `volume` on their own bar row, and this package now carries it through; only the
crypto bar endpoint documents none, and `volume` stays `nil` there — never `0`, for the
same reason as the crypto snapshot. `get_volume_profile/3` remains the separate equity
endpoint that splits traded volume by price and side.

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

## `get_orders/2` follows `pagination_key` to the end, bounded

`/trading/orders/open-orders/list` and `/trading/orders/historical-orders/list` both
document `pagination_key` — the venue's own reference pages, not just its endpoint
inventory — and this package walks it the same way `get_symbols/2` walks the instrument
catalogue's: to the end, or `{:error, {:too_many_pages, n}}` on a bound, or
`{:error, :pagination_key_did_not_advance}` on a repeated key. `get_orders/2` returns the
whole set the venue holds for the request, not a prefix.

**`opts[:limit]` is no longer read.** Neither endpoint documents a `page_size` parameter —
sending one asked the venue a field it does not define, and did not actually bound the
walk (there was no walk). `history: true` accepts `opts[:since]`/`opts[:until]`
(`DateTime`s) instead, sent as the documented `start_time`/`end_time`; omitted, the venue
answers the last 7 days, its own default.

## `get_symbols/1` lists everything; `list_instruments/1` says which of it you can trade

`get_symbols/1` is Core's contract, unfiltered: **every** symbol this venue lists, tradable
or not. Some of what it lists is `"NT"` (Non-Tradable) or `"CO"` (Liquidate only — only a
CLOSING order matches) on the venue's own instrument catalogue, and `get_symbols/1` has no
way to say so — this is exactly why a subscribe to one of those symbols can come back
`INVALID_SYMBOL` even though `get_symbols/1` just handed it to you.

`list_instruments/1` reads the same catalogue and answers `Core.Instrument`s instead of bare
strings, each with a `status`: `:tradable` for `"OC"`, and `:unknown` for `"CO"`, `"NT"`, and
anything absent or unrecognised. Filter on `status == :tradable` before you build an order
book or a strategy universe from a symbol you only got from `get_symbols/1`:

```elixir
{:ok, instruments} = DpExchange.Webull.list_instruments(credentials: creds)
tradable = for i <- instruments, i.status == :tradable, do: i.symbol
```

`:unknown` is not the same claim as `:delisted` — a `"NT"` row is still listed, just not
currently tradable, and this package does not say the venue removed it. `list_instruments/1`
only serves `US_CRYPTO`; `US_STOCK`/`US_ETF` refuse by name
(`{:error, {:unsupported_instrument_category, category}}`) rather than being served with an
invented instrument type or quote currency — see `DpExchange.Webull.Rest.list_instruments/2`.

### `:tradable` does not promise a quote: `{:refused, :no_quote}`

The catalogue and the quote endpoint can disagree. On 2026-10-02, 51 of the ~325 USD pairs
`list_instruments/1` marked `:tradable` answered every `get_price/2` with the venue's literal
`"null"` price, and never ticked on the stream. Examples are MATIC-USD, FTM-USD, FTT-USD,
KLAY-USD and MIOTA-USD, several of them delisted or renamed upstream (issue #8).
`get_price/2` returns **`{:refused, :no_quote}`** for these. That is permanent by contract,
so don't retry it on a timer, and treat the pair as one with no market here. It used to
come back as `{:error, {:invalid_decimal, :price, "null"}}`, which looked like a parser fault
and, as an `:error`, invited endless retries. This package leaves the catalogue's `"OC"`
alone, because that status is the venue's word and the refusal is its other word.

### Many crypto quotes over REST: `get_prices/2`, twenty per request

The crypto snapshot endpoint takes "up to 20 symbols per request". `get_price/2` asks for one,
so polling many pairs with it spends the endpoint's whole 1/s budget at 60 symbols a minute.
`get_prices/2` sends them twenty at a time and answers a result for **every** symbol:

```elixir
{:ok, results} = DpExchange.Webull.get_prices(symbols, credentials: creds)
for {symbol, {:ok, quote}} <- results, do: handle_price(symbol, quote)
```

Each result has `get_price/2`'s own shape. A `{:refused, :no_quote}` is permanent (see
above). `{:error, :not_in_response}` means the venue returned no row for that symbol. A
chunk whose request failed gives each of its own symbols that error and no others.
`US_CRYPTO` only.

## Timestamps come from the venue, or the call fails

**The local clock is never substituted** — an undated bar stamped with your own clock is
indistinguishable from a real one, which is how a gap becomes invisible. That guarantee is
the whole of this section and has never changed.

What an undated value does depends on the TYPE, because the contract differs:

* **A bar, a volume-profile interval or a trade is refused**, with
  `{:error, :missing_venue_timestamp}`. `Core.Types.Candle` and `VolumeProfile` enforce
  `:opened_at` and `Trade` enforces `:timestamp`, so a bar at an invented minute or a print
  that cannot be placed in time is not something this package can report at all.
* **A quote or an order book is delivered with `venue_time: nil`.** Neither type enforces it,
  and refusing threw away a real guarded price, or a whole set of book levels, over an
  optional field. This changed in 0.4.36 and 0.4.37; before then both were refused.

## An order book is sorted, so `hd(bids)` is the best bid

`get_order_book/2` guarantees it as of 0.4.39 — **bids descending, asks ascending** — and it
is `Core.Types.OrderBook`'s contract rather than this package's convenience. You do not need
to sort what you receive, and you should not assume the venue's row order means anything.

A level whose price this package cannot read is dropped rather than passed on with a `nil`
price, because `level/0` is `{Decimal.t(), Decimal.t()}` and `hd(bids)` must be able to
answer with a real number. A level with a readable price and no size keeps a `nil` size —
that is a real shape, not an unreadable one.

## A row the venue did not identify is dropped, not given an empty id

As of 0.4.38, `get_screener/2` and `list_watchlists/1` drop a row that cannot supply its
own identifying field rather than publishing it with `""`.

An empty string is worse than the `nil` it replaced: a `nil` is detectable and `""` is a
value, so a consumer keying coverage by symbol used to get a live entry named `""`.

**`get_news/1` no longer has "rows" to drop.** It reads Server-Sent Events, one generated
reply per call, not a JSON list of independently-published stories each naming their own
id — see the news paragraph above. The old fallback on that JSON shape, before the endpoint
was corrected, was an absent id falling back to the **ticker symbol**, which looks like an
id and collides for every story about that symbol; that whole failure mode is gone with
the JSON-list assumption it depended on. What replaces it: a stream with no conversation id
in its `meta` event is `{:error, {:missing_required_field, :id}}` rather than a fabricated
one, since `Types.NewsItem.id` is required.

**So a shorter list is not an error, and the venue's own ranking is preserved.** A dropped
screener row leaves a gap in `rank` rather than renumbering the survivors, because `rank` is
the position the venue returned the row in and closing the gap would re-rank the list.

**An order list is the exception: it is refused, not thinned.** `get_orders/2` answers
`{:error, {:unreadable_orders, ids}}` when any group in it cannot be read as one `Order`,
most often a multi-leg combo (OCO, OTO, bracket), which this package does not represent.
`ids` are the groups' `client_order_id`s where the venue gave one. Dropping them would
hand you a list of working orders that is missing some, which reads as "nothing working
there"; place against that and you may duplicate an order.

## A `:degraded` notice carries its severity from the frame — read `severity`, not only `kind`

The venue publishes telemetry on its `notice` topic, and most of it says nothing is wrong. A
keepalive reporting `drop: 0` arrives as `severity: :info`. A notice is `:warning` only when
the venue sent **words**, or reported a **non-zero `drop`** — absence of an adverse indicator
is not evidence of degradation.

Every frame used to be `:warning`, which on one live host meant 184 WARN an hour announcing
that nothing had been dropped, crowding out 1,331 genuinely serious warnings underneath. If
you map `Notice.severity` straight to a log level — the honest reading of a field whose own
docs call it "not a log level — a call to action" — this is the distinction you want.

If you route on `kind` alone you will still see `:degraded` for both, and that is a known
limit rather than an oversight: `Core.Notice`'s kinds are a deliberately closed set with no
slot for "the venue reported on itself and nothing is wrong", and widening a shared
vocabulary is not one venue package's call.

## A slow subscriber gets dropped, and told — it does not get an unbounded mailbox

If your process falls far enough behind that its mailbox reaches **10,000 queued
messages**, this package stops sending it events and emits a `Core.Notice`:

```elixir
%Core.Notice{
  kind: :degraded,
  severity: :warning,
  message: "subscriber #PID<0.123.0> is 10000 messages behind, past the 10000 bound — ...",
  details: %{subscriber: "#PID<0.123.0>", queue_len: 10_000, bound: 10_000, dropping: :newest}
}
```

and a second one, `severity: :info`, once you have drained below **half** the bound (5,000 by
default). Not merely back under it: a mailbox hovering at the bound used to flip on every
message, with a notice each time, into the same full mailbox. Now one stall costs one pair.
**Those two notices bracket exactly
the window you have to reconcile** from the pull endpoints — that is what the pair is for,
and why the recovery notice exists at all rather than just the alarm.

Three things are worth knowing about the shape of this:

- **The newest is dropped, not the oldest.** A sender cannot remove a message from your
  mailbox; only you can. So what happens is that nothing further is added while you are over
  the bound. It is also the better trade: a quote that arrives while you are ten thousand
  messages behind is stale by the time you would read it, and the frames it would have
  displaced are no fresher.
- **Only you are affected.** Another subscriber keeping up keeps receiving everything. One
  slow consumer is never allowed to become an outage for the others.
- **`coverage/1` does not change.** It reports what the *venue* delivered to this package,
  not what this package forwarded to you. A symbol whose frames are being dropped for your
  backlog is still arriving, and reporting it as `:not_covered` would point you at the venue
  when the backlog is yours.

Notices themselves are never dropped, whatever your queue looks like — the notice telling
you that you are being dropped must not be the first casualty of it.

Raise or lower the bound at start:

```elixir
{DpExchange.Webull, max_queue_len: 50_000}
```

Any positive integer. It must be an integer — a string or a float raises at `init/1` rather
than quietly falling back to the default, because a back-pressure setting you believe you
configured and did not is worse than not having configured one.

**If you are seeing these notices, the fix is on your side.** Consume in a process that does
nothing else, or hand the payload straight to a queue or an ETS table and do the work
elsewhere. The bound is not a tuning knob for throughput; it is the line past which this
package stops writing into memory you are not reading.

## Telemetry: attach one handler, see every venue

This package emits the `:telemetry` events `DpExchange.Core.Telemetry` documents. Attach to
the names, not to anything venue-specific:

```elixir
:telemetry.attach_many(
  "dp-exchange-metrics",
  DpExchange.Core.Telemetry.event_prefixes(),
  &MyApp.Metrics.handle/4,
  nil
)
```

`:provider` in the metadata is how you tell venues apart — one handler covers the whole
family.

**These names were documented long before anything emitted them.** If you attached a handler
before this version and saw nothing, that was not your venue being quiet:
`:telemetry.attach/4` against a name nobody emits succeeds, so an empty panel was
indistinguishable from no traffic. Every one of them fires now.

Four things to know before you build on them:

- **Telemetry is the metrics channel; `Core.Notice` is the action channel.** Telemetry is
  aggregate and lossy by design. Alarm on notices. Graph telemetry. Alarming on a gauge
  documented as droppable is how a missed sample becomes a page at 3am.
- **`:stop` fires for every outcome**, success or error. That is deliberate: a latency panel
  built on successes alone shows a venue getting *faster* exactly as it starts failing,
  because the slow calls are the ones dropping out of the sample. `:exception` is a separate
  event from a `:stop` carrying an error — an error result is the venue answering badly, an
  exception is this package failing to ask.
- **`retry_after_ms` is always milliseconds**, including where the venue's own header is in
  seconds. A panel summing a mixture of the two is wrong by a factor of a thousand without
  ever looking wrong.
- **`:bytes` may be absent from `[:dp_exchange, :link, :event]`**, and absent is not zero. A
  polling route has no frame, so there is no byte count that means what a socket's does.
  Treat a missing `:bytes` as "this route cannot measure that", not as no data.

`:endpoint` metadata is the request URL with the query string removed. Deliberate: telemetry
metadata reaches logs, aggregators and third-party exporters, and the query string is the one
part of a URL that can carry a token.

## Every capability claim is dated, and says what it was measured against

`capabilities/0` carries two provenance fields, and they are there to be read:

```elixir
caps = DpExchange.Webull.capabilities()
caps.measured_at       # ~D[...] — when someone last checked
caps.measured_against  # what they checked: which documents, which endpoints, live or not
```

**`measured_against` is the one that matters when you are deciding how much to trust a
claim.** It distinguishes a figure measured live against the venue's API from one read off a
documentation page and never probed — and this package's own declarations contain both
kinds, stated per claim rather than as one blanket sentence.

A claim read from documentation is not worse, it is *different*: it is what the vendor says
it will do, which is the right basis for a ceiling you must not exceed and a weaker basis for
behaviour you are about to depend on. If your decision turns on the difference, read the
field rather than assuming.

`measured_at` going stale is a real thing that happens — venues change, and a declaration is
a claim about a real venue. `script/check_doc_sources.sh` reports the age on its weekly run
so it does not quietly get old, but nothing forces it: if you are relying on a capability in
a way you cannot afford to have wrong, check the date and, where it matters, verify against
the venue yourself.

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

**`get_news/1` is generated, not reported — and answers one item, not a list of stories.**
The vendor's own description is "invokes LLM to generate news summaries", and the endpoint
itself answers Server-Sent Events (`event:message\ndata:{"type":"text","message":...}`
chunks), not a JSON list — this package concatenates the chunks into one `summary` and
returns it as a single-element list, `:id` taken from the stream's own conversation id
(`convId`, falling back to `sessionId`). `source` names the venue rather than a wire; if
you quote `summary`, you are quoting a paraphrase, not the publisher's text. Before this
was corrected, every call returned `{:error, {:undecodable_response, :webull}}` — the
generic JSON decoder this package's other POST calls share cannot parse an SSE body, so the
endpoint never actually worked.

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

**The batch endpoint's own matrix is narrower than `place_order/3`'s, and it is checked
against, not discovered.** `order_type` is `MARKET` or `LIMIT` only — no `STOP_LOSS`,
`STOP_LOSS_LIMIT` or `TRAILING_STOP_LOSS`, all real for a single order.
`time_in_force` is `DAY`, the one member of this endpoint's own enum; a caller who asks
for anything else is refused rather than silently switched to `DAY`. Sizing is `QTY`
only — `:amount` is refused here, where `place_order/3` accepts it for equities. And
`:support_trading_session` (`:core`, `:all` or `:night`) is **required per order**, with
no documented venue default, unlike on `place_order/3` where it is optional.

## Tokens: a token that exists is not a token that works

`create_token/1` returns one that is `PENDING`, and verification happens through an SMS code
in the Webull app — which needs a person. `check_token/2` is the only call that tells
`PENDING` from `EXPIRED` from `INVALID`; all three fail identically at the next request and
each has a different remedy.

`oauth_token/3` is one endpoint doing two jobs on a **different host**, with a form body.
`opts[:code]` exchanges, `opts[:refresh_token]` refreshes, and exactly one is required.
**Two expiries come back and they are not the same clock** — `rt_expires_in` is the one that
ends the session.

## A write is sent once; a read is retried

Every request is signed afresh for each attempt, so a retry after a timeout or a 5xx is a
real second request rather than a replay the venue refuses. That makes a retried write able
to take effect twice, and the venue documents no idempotency key that would deduplicate a
repeated order. So `place_order`, `place_orders`, `replace_order`, `cancel_order`,
`create_token` and every watchlist write are **sent once**. A timeout on one of them means
"unknown": read the order or watchlist back before sending it again. Pass `:retry_attempts`
yourself only if you have your own reason to believe a repeat is harmless.

## Error shapes that mean "do not act on this answer"

Returned by calls that previously answered `{:ok, _}` carrying a value you could not act on.
A consumer matching only `{:ok, _}` needs no change; one that enumerates error reasons
should know them.

`{:error, {:undecodable_response, :webull}}` — the venue answered `2xx` with a body this
package could not decode. The realistic cause is not malformed JSON from the venue; it is a
`2xx` that never reached the venue, such as a captive portal or a CDN maintenance page
answering `200 text/html`. **Worth retrying**: nothing about the request was wrong. This
package used to substitute an empty object for such a body, which then decoded into a
well-formed value with every field `nil` and was returned as success.

`{:error, :unexpected_response_shape}` from `get_balances/2` — a balance row the venue did
not attribute to an asset refuses the whole reply. An amount you cannot name an asset for
cannot be sized, booked or reconciled against, and dropping the row silently would read as
"you hold none of that asset", a different and more dangerous claim than "this response could
not be read". **Not retryable on its own.**

A `Balance`'s own `balance` field may still be `nil`, and that is a different statement: the
venue named the asset and did not state a quantity for it. Read that as unknown, never as
zero.

## A subscribe that is still in progress answers before it times out

`subscribe/2`, `unsubscribe/2` and `update_symbols/2` wait for the venue's HTTP subscribe,
or for a connecting shard's CONNACK. Either can be slower than the call's own 15-second
timeout, and a call that times out EXITS the calling process. So after about ten seconds
the call is answered anyway, with one of these:

- `{:error, {:reconcile_pending, ms}}`: the HTTP subscribe is still running.
- `{:error, {:connack_timeout, ms}}`: the shard has not finished connecting.

**Neither needs a retry.** Your symbols are already recorded. The subscribe finishes or
the shard connects, and your symbols go out with it. `coverage/1` tells you when they
start arriving.

## Every negative here is audited

`docs/reference/webull/negative-claims.md` lists each one with the source and date consulted.
**Three were wrong**, all the same mistake: a true statement about the *stock* endpoint
restated as a claim about the venue. It also records why the vendor's pages have to be
**rendered** to be read — their parameter tables are built in JavaScript, and an inventory
captured without them looks finished and cannot be implemented from.

## A shard reopens its own socket only once it has stopped delivering

Each shard reasserts its symbols on a timer. If one shard's blind resubscribe fails
**twelve times in a row** *and* none of that shard's symbols has arrived for **five minutes**,
this package reopens that shard's socket on a fresh session — the same recovery an explicit
`INVALID_SESSION` triggers. A `:link_down` notice says so, naming the shard.

**Both conditions are required, and the second one is the important half.** A reconcile is a
subscription-management call: it can keep failing while the transport underneath streams
everything it is already subscribed to. Reopening in that state loses live data and gains
nothing.

That is not a theory. Version 0.4.25 escalated on the failure count alone. On a live fleet
three shards hit the limit, reopened, and failed the identical reconcile on the very next tick
and every tick after — a fresh session changed nothing — while this venue's coverage fell from
226 distinct symbols to about 160, with two other streaming venues flat across the same
windows. The stuck-but-subscribed sockets had been delivering; tearing them down is what
stopped it.

So while a shard is still delivering, the failures are counted and reported and nothing is
torn down. The log line says which case you are in.

**Why five minutes of silence.** A shard carries on the order of a hundred symbols. The
question is not "has this symbol been quiet" — an illiquid pair can go minutes without a print
— but "has every symbol on this shard been quiet at once", which a live shard does not do.
Erring long costs a few more minutes of a stale subscription set; erring short costs live
data. Both are tunable: `resubscribe_failure_limit:` and `stale_delivery_ms:` on
`start_link/1`.

A success resets the failure count, so only *consecutive* failures count toward the limit.

### A shard that never OPENED is a different case, and retries on its own backoff

Everything above is about a shard whose socket is up and has stopped delivering. A shard
whose socket never opened at all — a handshake that timed out, a venue refusing connections
— cannot be judged that way: it has never delivered anything, so there is no last-delivery
instant to age, and **"never worked" is not "stopped working"**.

Such a shard is retried on its own schedule: one second, doubling, capped at a minute, until
it opens or the slot is filled by a resubscribe of its own. A `:coverage_change` warning
naming the shard fires once when it first fails to open, and a matching `:info` fires once
when it opens — so a shard going dark at boot is something you hear about rather than
something you find by grepping. `open_retry_base_ms:` and `open_retry_max_ms:` on
`start_link/1` tune it.

Until 0.4.30 this case was not handled at all. A failed open logged one WARN line and
returned, leaving the shard untracked — not merely un-reopened, absent — and its symbols
were orphaned for the life of the process. Reported from a real boot under load: three of
four shards timed out their handshake, and stayed dark for 28 minutes across zero reopen
attempts until the node was restarted, with the feed alive and healthy-looking throughout.

## `{:reconcile_timeout, ms, :no_venue_response}` says which of two opposite actions applies

A reconcile that never came back now reports `{:reconcile_timeout, 60_000, :no_venue_response}`
rather than `{:reconcile_timeout, 60_000}`. The third element is a statement of fact: the
deadline arrived and nothing answered.

That matters because the two causes call for opposite responses. **A venue refusing** —
because another session holds the permission, say — must be waited out, since reconnecting
claims a further session against the same ceiling. **A wedged socket of ours** must be
reconnected, which is the only thing that helps. A venue that answers with a refusal reaches
you as that refusal and never as this tuple, so the two are now distinguishable without
either being inferred.

You do not have to act on it: the escalation above is this package taking the reconnect
decision itself, on the one signal it has and you do not.

## Streaming calls answer; they never exit your process

`subscribe/2`, `unsubscribe/2`, `update_symbols/2` and `subscribe_notices/1` return
`{:error, :feed_not_started}` when this venue's feed is not running (`unsubscribe/2`
answers `:ok`: there is nothing to stop). They return `{:error, :feed_timeout}` when the
feed is too busy to answer within its call budget, and `{:error, {:feed_exited, reason}}`
when it dies while answering. `coverage/1` and `coverage_by_kind/1` answer an empty map in
all three cases, which means "not observed". Treat `:feed_timeout` as transient and retry.
Treat the other two as a feed your supervision tree has to bring back.

## `:websocket_url` in application config replaces the default socket endpoint

`config :dp_exchange_webull, websocket_url: "wss://your-proxy.example/..."` sends every socket
this package opens, unless a call passes its own `:url`, to that address instead of the
venue. Unset, the venue is the default. It exists so a test suite never dials the live venue
by accident, and it is equally usable for a proxy.

## A print that cannot be delivered says so

`Trade`s come from the `tick` topic, requested by default, which the vendor lists for
stocks, futures and crypto. A tick this package cannot turn into a `Trade` (undecodable, or
missing a readable time, price or volume) raises a `:data_quality` `Notice` once per reason
per connection, with the raw field strings in `details` (`dropped`, `symbol`, `time`,
`basic_timestamp`, `price`, `volume`). So does a message on a topic this package does not
decode (`details.dropped == {:unrecognised_topic, topic}`). No `Trade` and no such notice
means the venue sent no ticks for those symbols. A notice means it did, and says why each
kind was dropped (dp-exchange-core issue #40). A tick whose own `time` is unreadable falls
back to the frame's `timestamp` before being refused.
