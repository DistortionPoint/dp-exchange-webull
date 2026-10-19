# Using `dp_exchange_webull`

> **EXPERIMENTAL.** Not run in production. Pin three-part. Maturity is per endpoint —
> read `capabilities/0`, not this banner.

Everything general is in
[`dp_exchange_core`'s usage rules](https://hexdocs.pm/dp_exchange_core/usage-rules.html).
This file is only what is **specific to Webull**.

## BREAKING — an option a function does not read is refused, not ignored

Requires `dp_exchange_core ~> 0.3.101`. A misspelt `limt:` used to return an answer to a
question you did not ask. Every function that takes `opts` — on `DpExchange.Webull` and on
`DpExchange.Webull.Fake` alike — now answers

```elixir
{:error, {:unknown_option, :limt}}      # the first key (in your order) the function does not read
{:error, {:invalid_options, opts}}       # opts is not a keyword list
```

before anything is sent, before the credentials are looked at, and after the positional
arguments (`{:invalid_symbol, _}`, `{:invalid_order_id, _}`, ... are answered first). A key
that holds `nil` is still a key.

**A shared transport key is accepted only where the call reads it, and every one accepted
is forwarded.** A call that sends a request (every REST call, and `subscribe/2`,
`unsubscribe/2`, `update_symbols/2`, whose subscription call is one) takes `:credentials`,
`:environment`, `:plug`, `:adapter`, `:req_adapter`, `:limiter`, `:rate_limit_blocking`,
`:weight`, `:timeout`, `:retry_attempts`, `:retry_delay`, `:max_retry_after_s`,
`:max_body_bytes` and `:log_requests`; each reaches `Core.HttpClient`. (The writes that are
always sent once take neither `:retry_attempts` nor `:retry_delay`; see "A write is sent
once".) `:adapter`, `:weight`,
`:retry_delay`, `:max_retry_after_s` and `:max_body_bytes` were accepted and dropped before:
`max_body_bytes: 1_024` bounded nothing. They are forwarded now.

  * **`:base_url` is refused on every function** (`{:error, {:unknown_option, :base_url}}`):
    no call reads it, the hosts come from `:environment`, and a `base_url:` that did nothing
    would let a caller believe a request had been redirected.
  * **`oauth_token/3` refuses `:credentials`**: the client id and secret are its arguments.
  * **A call that sends no request takes no HTTP key.** `get_fees/2`, `coverage/1`,
    `wanted/1`, `coverage_by_kind/1` and `subscribe_notices/1` take `:credentials` (one set
    is handed to every call; it changes no answer) and their own keys, so `timeout: 5_000`
    is `{:error, {:unknown_option, :timeout}}` (a raise on the plain reads), and so is
    `environment:`. `streaming?/1` and `live?/1` take `:credentials` and `:environment`
    (which they resolve) and nothing else.

A function that answers `{:error, :not_supported}` does so whatever it is given.

`coverage/1`, `wanted/1`, `coverage_by_kind/1`, `streaming?/1` and `live?/1` have no error
channel (a map, a list, a boolean), so they **raise `ArgumentError`** on a stray key or a
non-keyword `opts` rather than answer `%{}` for a misspelt `feed:`.

**What changed for a caller that shared one `opts` list across calls:** an `:account_id` on
`get_accounts/2`, a `:to` on `update_symbols/2` or `unsubscribe/2`, a `:limit` on
`get_orders/2` (never sent to the venue) and the like were silently dropped before and are
errors now. `:limit` on `get_order_book/2`, `:since` on `get_trades/2`, `:real_time` on the
bars and `:since`/`:until` on the open-orders listing keep their own, more specific
`{:error, {:unsupported_option, key}}`; `:symbols` on `update_watchlist/2` keeps
`{:error, :membership_not_updatable_here}`.

### The keys each function reads (beyond the transport keys above)

The table is written once, in `DpExchange.Webull.Options` (`own_keys/1`); `Fake` uses the
same one.

| Function | Keys |
|---|---|
| `get_price/2`, `get_prices/2`, `get_top_of_book/2` | `:category`, `:extended_hours`, `:overnight` |
| `get_historical_prices/4` | `:category`, `:limit`, `:include_partial`, `:sessions` (`:real_time` is refused) |
| `get_symbols/1`, `list_instruments/1` | `:category` |
| `get_order_book/2` | `:category`, `:depth`, `:overnight`, `:extended_hours` (`:limit` is refused) |
| `get_trades/2` | `:category`, `:limit`, `:sessions` (`:since` is refused) |
| `get_volume_profile/3` | `:category`, `:session`, `:count` |
| `get_auction_imbalance/2` | `:auction`, `:history` |
| `quantization/2`, `get_accounts/2`, `get_fees/2` | none |
| `get_balances/2`, `get_positions/1`, `get_order/3`, `cancel_order/3`, `place_order/3`, `place_orders/3`, `preview_order/3` | `:account_id` |
| `replace_order/4` | `:account_id`, `:instrument_type`, `:order_type` |
| `get_orders/2` | `:account_id`, `:history`, `:since`, `:until` |
| `get_transfers/2`, `get_transactions/2` | `:account_id`, `:activity_types`, `:start`, `:end` |
| `subscribe/2` | `:to`, `:feed`, `:sub_types` |
| `unsubscribe/2`, `update_symbols/2` | `:feed`, `:sub_types` |
| `subscribe_notices/1` | `:to`, `:feed` |
| `coverage/1`, `wanted/1`, `coverage_by_kind/1` | `:feed` |
| `streaming?/1`, `live?/1` | none (they take only `:credentials` and `:environment`) |
| `get_option_chain/2`, `get_option_expirations/2` | `:expiry`, `:strike` |
| `list_futures_contracts/1` | `:symbols`, `:code`, `:status` |
| `list_futures_product_classes/1`, `list_event_categories/1` | none |
| `list_event_series/1` | `:category`, `:symbols`, `:pagination_key` |
| `list_event_events/1` | `:series_symbol`, `:symbols`, `:status` |
| `list_event_markets/1` | `:series_symbol`, `:event_symbol`, `:symbols`, `:expiring_after`, `:pagination_key` |
| `get_event_trades/2` | `:limit` |
| `get_event_order_book/2` | `:depth` |
| `list_watchlists/1`, `get_watchlist/2`, `delete_watchlist/2` | none |
| `create_watchlist/3` | `:sort`, `:category` |
| `update_watchlist/2` | `:name`, `:sort` (`:symbols` is refused) |
| `add_watchlist_instruments/3`, `remove_watchlist_instruments/3` | `:category` |
| `sort_watchlist_instruments/2` | `:sorts`, `:category` |
| `get_financials/3` | `:category`, `:type`, `:count` |
| `get_corporate_events/1` | `:symbol`, `:kind`, `:category` |
| `get_filings/2` | `:category` |
| `get_news/1` | `:symbols`, `:category`, `:sentiment`, `:limit` (items per symbol) |
| `get_fundamental/3` | `:category`, plus the query keys that kind's own page documents (`:type`, `:count`, `:last_date`, `:sort_by`; see `Rest.fundamental_option_keys/1`) |
| `get_screener/2` | the screener's own keys (`:rank_type`, `:sort_by`, `:direction`, `:agg_type`, `:period`, `:sector_id`) and `:category` except on `hot_stocks`, which takes none |
| `create_token/1`, `check_token/2` | none |
| `oauth_token/3` | `:code`, `:refresh_token`, `:oauth_url` |

A kind or screener the venue does not publish is `{:error, {:unknown_fundamental, kind}}` /
`{:error, {:unknown_screener, name}}`, answered before the options.

The watchlist `:category` is `"US_STOCK"` (the default), the one value the instrument endpoints'
enum lists; any other is `{:error, {:invalid_category, v}}` before a request, in `Fake` too.
A futures `replace_order/4` changes `:order_type` one way only (limit or stop to `:market`,
stop-limit to `:limit`), else `{:error, {:unsupported_order_type_change, from, to}}`.
Every 4xx but 408 and 429, on a REST read as on a REST write, is
`{:refused, {:venue_error, status, reason}}` (404 is `{:refused, :not_found}`) and is never
retried. The streaming calls (`subscribe/2` and its two siblings) answer their own HTTP
failures in their own shapes, listed under "Every answer a streaming call can give".

## BREAKING — a refusal now carries the venue's status as well as its words

```elixir
# before
{:refused, {:venue_error, "signature mismatch"}}

# after
{:refused, {:venue_error, 401, "signature mismatch"}}
```

This package refuses on every 4xx but `408` and `429`. Three of them have a remedy a caller
can act on, and **all three used to look identical to a caller** even though their remedies
are opposite:

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

**A malformed credential is `{:error, {:invalid_credentials, :webull}}`.** An `:app_key`,
`:app_secret` or `:access_token` with surrounding whitespace or a control character (a `.env`
value pasted with its trailing newline signed as `"key\n"`) is refused before signing, never
sent, and never echoed in the reason. Real and Fake alike. Blank is still
`:missing_credentials`.

**Plaintext URLs are refused as `{:error, {:insecure_url, :webull}}`**: a non-loopback `ws://`
stream URL and a non-https `:oauth_url`. These were `{:insecure_url, :wss_required}` and
`{:insecure_oauth_url, :https_required}`.

**`wanted/1` is what you asked to stream; `coverage/1` is what is arriving.** `wanted/1` answers
the sorted symbol list (`[]` with no feed), and a dark or rejected symbol stays in it.

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
Each call's own argument validation runs **before** the credential check, matching the real
`Rest` order (it refuses before it builds a request) — so `Fake.get_corporate_events()` with
neither a credential nor a `:symbol` is `{:error, :symbol_required}`, and an unknown
screener or a non-statement `kind` is refused the same way the real path refuses it,
credential or not. The fake calls `Rest`'s own validators for these rather than copying the
rules, so the two cannot drift: `Fake.preview_order/3`, `Fake.get_financials/3`,
`Fake.get_corporate_events/1` (which now also honours `:kind`), `Fake.get_news/1` (which
also takes one symbol as a string), `Fake.get_screener/2` (`week52_high_low` requires
`:rank_type`), `Fake.update_watchlist/2`, `Fake.get_volume_profile/3`,
`Fake.get_historical_prices/4` (a `:limit` over 1200 is `{:invalid_option, :limit, n}`; it was `{:limit_out_of_range, n, max: 1200}`), and the cash-activity
calls (a range across two calendar years is refused, and `get_transactions/2` honours
`:activity_types`). A fake order placed under a caller-chosen `client_order_id` can now be
read back and cancelled under it. An order placed with no `client_order_id` is issued a new
one in the venue's format (32 lower-case hex characters, as `Rest` generates), and
`Fake.place_orders/3` rows carry the `client_order_id` that `get_order/3` and
`cancel_order/3` take, with the system `order_id` on an accepted row and `error_code` and
`message` on a refused one, as `order-batch-place.md` documents. A watchlist made with
`Fake.create_watchlist/3` gets its own id, is read back by `get_watchlist/2` with the symbols
it was created with, appears in `list_watchlists/1` under its name (and its renames), and
reads as no rows (`{:error, :unexpected_response_shape}`) once deleted; `wl-1` is the canned
one before you create any. Deleting an id the Fake does not hold (never created, or already
deleted) is `{:refused, :not_found}`, as the real path answers a 404.
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

**The request ceiling is the vendor's Display tier, documented and never measured.** The
limiter meters each endpoint at 60 requests per 60 seconds with a burst of 1, and all
endpoints together at 600 per 60 seconds (`capabilities/0`'s `public_ceiling` is the first
figure). Those are the vendor's Display Solution numbers as read on 2026-09-09. Its
rate-limit page read on 2026-10-18 also lists a Non-Display Solution tier at 300 per 60
seconds in production; which tier your App Key is on is not something this package can read,
so it stays at the stricter figure and an App Key on the higher tier is under-used, not
over-used. Sandbox is metered at half. Neither figure was measured against a live key.

**`opts[:sub_types]` on `subscribe/2`** (`"SNAPSHOT"`, `"QUOTE"`, `"TICK"`; default all three)
is remembered by the feed and used for the replay after a reconnect and for the blind
resubscribe, not only for the request that call made. A value that is not a non-empty list of
strings is `{:error, {:invalid_sub_types, value}}` before anything is sent.

## A shard's socket crash costs one shard, never your whole subscription

Each shard's MQTT-over-WebSocket connection is a **linked** child of `Feed` — not a
supervised sibling you can restart independently. `Feed` traps exits, so a shard's
socket dying abnormally does not take `Feed` down with it: only that shard's symbols
drop out of `coverage/1` and `coverage_by_kind/1` (cleared immediately, not left to
report `:stream` for a connection that no longer exists), you get a `:link_down`
`Core.Notice` naming the crashed shard, and this package reopens it on its own — you
never need to call `subscribe/2` again. The first crash reopens at once. A shard that crashes
again within a minute of its last crash waits first, 1 s doubling to 60 s, so a socket that
connects and dies cannot spin through the venue's five-connections-per-key budget. The same
goes for a socket that reaches the broker's CONNACK and drops within 30 s: it counts as a
failed attempt toward the reconnect backoff instead of resetting it.

**That reconnect backoff is jittered.** A shard's socket redials at once on its first failure,
then waits 1 s doubling to 30 s. Each wait is shortened by a random amount of up to a quarter
(`Socket.jittered_delay_ms/1`, never lengthened), so five shards the venue dropped together
do not all redial on the same turn. The `delay_ms` its telemetry event reports is the delay
actually waited. The wait ends when `Feed` stops the socket, so a stopped or orphaned shard
does not dial the venue once more after its parent has gone.

**Your `app_secret` and `access_token` will not appear in `Feed`'s crash log.** `Feed`
keeps what you passed at start (or on a later `subscribe/2`) so it can replay your
subscriptions after a reconnect — see above — and a crash of `Feed` logs its state via
OTP's default crash report, which is where you *would* see it, because a crash report
prints unredacted `Logger` metadata otherwise. The credential map is wrapped in a struct
before it ever reaches state, so the crash line reads `credentials:
#DpExchange.Webull.Credentials<...>` rather than the key pair itself. That now holds for the
credentials you pass to `subscribe/2`, `unsubscribe/2` and `update_symbols/2` as well, which
used to sit unwrapped in in-flight reconcile state and in the messages that reopen a shard.
A shard's socket holds its `app_key` wrapped the same way, so its crash report reads
`#DpExchange.Webull.Credentials<...>` too (the key is sent as a plaintext header, `x-app-key`,
on every signed request by design, so this is hygiene rather than secrecy). Starting the tree
through `DpExchange.Webull.start_link/1` directly wraps the credentials as `child_spec/1`
does; a child spec you build yourself still hands your supervisor the raw map.

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
error rather than connecting unverified. Pass your own `:ssl_options` to override: a list is
merged over those defaults (so `cacerts:` alone keeps `verify_peer` and the hostname check),
and `ssl_options: nil`, `[]` or anything that is not a keyword list means "none given", never
"no verification". Only an explicit `verify:` of yours changes that.

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

`to:` names who receives the stream and defaults to the caller. It must be a pid or a
registered name (an atom); anything else is `{:error, {:invalid_subscriber, to}}` and nothing
is subscribed. `subscribe_notices/1` takes `to:` under the same rule.

**The venue does not restore subscriptions after a reconnect.** This package replays them
for you, which is the whole reason you never have to notice a reconnect. That replay uses
the credentials you supplied — at start, or on a `subscribe/2` or `update_symbols/2` call.

**What the replay uses is only ever replaced by credentials this package can sign with, and
only by a call that was not refused.** A call naming `credentials: nil`, `%{}` or a map whose
`:app_key` or `:app_secret` is blank leaves the stored credentials alone (such a call that
changes nothing answers `:ok`, one that has to open a shard is `{:error,
{:missing_required_field, :app_key}}` and one that has to sign is `{:error,
{:missing_credentials, :webull}}`), and a call refused for any reason puts back what the feed
was replaying with.
Before this, one such call emptied them, and the next reconnect or shard reopen was answered
`{:error, {:missing_required_field, :app_key}}` by a feed that had been streaming: that error is
this package's own, never the venue's.

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
arriving, because a declaration states what was measured. **Until then a `Trade` that does
arrive is delivered to you but not counted:** `coverage/1` and `coverage_by_kind/1` never
report `:trades`, because Core requires every reported kind to be a declared one and
`coverage/1` to be exactly their union. Do not read an empty `:trades` as "no ticks arrived";
a `Trade` on your mailbox is the evidence.

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
splits them apart — a symbol can show `:quotes` healthy while `:top_of_book` has gone dark
for it, or the reverse, and `coverage/1` alone cannot tell you which. Only the declared kinds
(`:quotes`, `:top_of_book`) appear; see the note on `:trades` above:

```elixir
DpExchange.Webull.coverage_by_kind(credentials: creds)
#=> %{
#=>   quotes: %{"BTC-USD" => :stream},
#=>   top_of_book: %{"BTC-USD" => :stream}
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

### Bars: the forming bar, the range, the grid (family conventions, BREAKING)

* **The bar still forming is not returned** (its `opened_at` plus the width is after now, on
  this machine's clock - the venue sends none) unless you pass **`include_partial: true`**,
  on every category. `Candle` has no partial flag, so with it the last bar may still change.
  **`real_time:` is gone**: it is `{:error, {:unsupported_option, :real_time}}` (stock and
  event bars used to read it), and a non-boolean `:include_partial`
  is `{:error, {:invalid_option, :include_partial, v}}`. Whether the crypto endpoint's
  `real_time_required` includes the forming bar for `"false"` or `"true"` is the vendor
  page's own contradiction (see `Rest.crypto_bars/5`), so `include_partial: true` there
  returns the bar only if the page's bullets are right - **unmeasured**. Event bars send
  `real_time_required` as `true` only for `include_partial: true`; option bars (where the
  parameter is optional, default `false`) send it only then; stock bars always ask for
  `true` and drop the forming bar here; futures bars take no such parameter.
* **`:start` is inclusive and `:end` is exclusive**, on `opened_at` (it was inclusive).
* **A range is never answered short.** Stock bars send `count` (your `:limit`, else the
  maximum - 1200, 1650 for `1m` - when a `:start` is given; no range and no limit leaves the
  venue's default of 200). A full page whose oldest bar is still after `:start` is
  `{:error, {:range_too_wide, count}}` (it was `{:range_exceeds_count, count}`, crypto only).
  Whether the venue returns the latest or the oldest `count` bars of a range is unmeasured.
* **A bar's `time` must sit on its width's grid** or the whole reply is `{:error,
  {:unaligned_candle, time}}`: the pages say "Bar UTC time", not "open time", and their own
  example (`09:00:09.945`) is on no grid. **Crypto** uses the strict UTC grid
  (`DpExchange.Core.Timeframe.aligned?/2`). **Stock, option, futures and event** bars are
  session-anchored: 30 minutes and under keep the UTC grid; `1h` and wider intraday widths
  need only minute 0 or 30 and no seconds (13:30Z accepted, 13:45Z refused); a `1d`, `1w`,
  `1M` or `1y` bar stamped at 00:00Z or New York midnight (04:00Z EDT, 05:00Z EST) is mapped
  to 00:00 UTC of that date (as Schwab does), and a `1d` bar at any other time is refused.
  `1w`, `1M` and `1y` have no grid rule in Core, so another time is left as sent.
  **Unmeasured** against a live venue. Crypto with a `:start` and no `:limit` sends
  `count=1200`.
* **An open, high, low or close of zero or less** is `{:error, {:non_positive_price, field,
  raw}}`; so is a trade or quote price. A book level with no readable price or a price of zero
  or less refuses the whole book (it was dropped), a level of size zero is dropped, and a
  negative size is `{:error, {:non_positive_size, :size, raw}}`. **A tape row's or a footprint
  level's negative size is refused the same way** (`:quantity`, `:buy_detail`, `:sell_detail`),
  and a streamed tick of negative size is dropped with a `:data_quality` notice. A negative
  snapshot `volume` or top-of-book size (REST or stream) is `nil`, "not published", never a
  negative number. A figure written in more than 1,024 characters is unreadable. A zero-size
  print is delivered: nothing measured says it is not a real one.
* **A query option that is a map, a tuple or a list of non-text** (fundamentals `:type`,
  `:count`; a screener's `:sort_by`, `:rank_type`; a futures or event `:symbols`; the tape's and
  stock bars' `:sessions`) **is `{:error, {:invalid_option, key, value}}`** before any request.
  A list where one value belongs (`type: ["ANNUAL", "QUARTERLY"]`) is refused too.
  `:sessions` must also name sessions the venue lists (`"PRE"`, `"RTH"`, `"ATH"`, `"OVN"`; one,
  or a list without repeats), and `:history` (`get_orders/2`, `get_auction_imbalance/2`) must
  be a boolean: `"false"` is `{:error, {:invalid_option, :history, "false"}}`, not history.
  `get_prices/2` checks `:extended_hours` / `:overnight` as `get_price/2` does, and a
  `place_orders/3` batch repeating a `client_order_id` is
  `{:error, {:batch_order_rejected, index, {:duplicate_client_order_id, id}}}`. The Fake
  refuses the same way for an entry whose id it already holds (and applies none of the
  batch), as its `place_order/3` refuses a reused id with
  `{:refused, {:duplicate_client_order_id, id}}`; the venue's own wording is unmeasured.
* **A row that is not an object** in a `[map()]` answer (`get_accounts/2`, `get_transfers/2`,
  `get_fundamental/4`, the futures and event lists, the event tape) is
  `{:error, :unexpected_response_shape}`, and a `pagination_key` that is not text is
  `{:error, :unexpected_pagination_key}`.
* **A candle or trade `:limit` over the page's maximum** (1200; 1650 for stock `1m`; 1000 for
  the stock tape) **is `{:error, {:invalid_option, :limit, value}}`**, as is one that is not a
  positive whole number; it was `{:limit_out_of_range, n, max: max}`.
* **A streamed `TopOfBook` side priced `0`, `"null"` (the venue's no-price spelling) or empty
  is `nil` with no size**; a side that is present but unreadable (`NaN`, text, negative)
  refuses that frame's top of book (a `:data_quality` notice, once per
  connection), as REST does for a non-numeric or negative bid/ask. A streamed trade with no
  time of its own still takes the frame's `Basic.timestamp` (`Trade.timestamp` is required).
* **`capabilities/0` declares `max_candles_per_request: 1_200`** - *documented*, from each bars
  page's `count` maximum (stock `1m`: 1650), never measured against a live response.

## `get_orders/2` follows `pagination_key` to the end, bounded

`/trading/orders/open-orders/list` and `/trading/orders/historical-orders/list` both
document `pagination_key` — the venue's own reference pages, not just its endpoint
inventory — and this package walks it the same way `get_symbols/2` walks the instrument
catalogue's: to the end, or `{:error, :history_truncated}` on the page bound (was
`{:too_many_pages, n}` / `:too_many_instrument_pages`), or
`{:error, :pagination_key_did_not_advance}` on a repeated key, or
`{:error, :unexpected_pagination_key}` on a key that is not text. `get_orders/2` returns the
whole set the venue holds for the request, not a prefix.

**`opts[:limit]` is no longer read.** Neither endpoint documents a `page_size` parameter —
sending one asked the venue a field it does not define, and did not actually bound the
walk (there was no walk). `history: true` accepts `opts[:since]`/`opts[:until]`
(`DateTime`s) instead, sent as the documented `start_time`/`end_time`; omitted, the venue
answers the last 7 days, its own default. `since:`/`until:` on the open listing (no
`history: true`) are `{:error, {:unsupported_option, key}}`, and `since:` after `until:` is
`{:error, {:invalid_option, :since, value}}`; likewise `get_order_book/2` with `limit:`
(use `depth:`) and `get_trades/2` with `since:` are `{:unsupported_option, key}`, and a
candle range with `:start` after `:end` is `{:invalid_range, range}`.

## `get_symbols/1` lists everything; `list_instruments/1` says which of it you can trade

`get_symbols/1` is Core's contract, unfiltered: **every** symbol this venue lists, tradable
or not. A catalogue row that names no readable symbol refuses the whole listing
(`{:error, :unexpected_response_shape}`); rows are never skipped, because a hole would make a
listed symbol read as unlisted. The same holds for `list_instruments/1` (a row whose symbol
does not end in its own `currency`), `get_watchlist/2` (a member with no text symbol),
`get_screener/2` (a row naming nothing) and `get_news/1` (a page without its `data` array,
or an item whose `related_symbols` is not a list of tickers): each is
`{:error, :unexpected_response_shape}`, never a shorter answer. Some of what it lists is `"NT"` (Non-Tradable) or `"CO"` (Liquidate only — only a
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
chunk the venue rejects because of one symbol it calls invalid is halved and retried down to
that symbol, so the rest of the chunk still gets its quotes. A
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
* **`venue_time` is the time of the event the struct describes, and nothing nearby.** A
  `Quote`'s is the last trade's (`last_trade_time`; on the stream the snapshot's `trade_time`,
  **never** `Basic.timestamp`, which is when the message was assembled); a `TopOfBook`'s is the
  quote's (`quote_time`), and the REST stock snapshot, which states only `last_trade_time`,
  answers `nil` for it. A `Quote` from a row that states only a `quote_time` is `nil` too.
* **A trade's `side` is `nil`.** The tape's `B`/`S`/`G`/`L`/`N` are defined nowhere the venue
  publishes (taker, buyer or resting order is unmeasured), and `Core.Types.Trade` says an
  undocumented code is `nil`. It was `B -> :buy`, `S -> :sell`.

**Units.** An epoch is read as seconds up to ten digits and milliseconds up to thirteen; one
longer (microseconds, nanoseconds) is not a time this package can read and is refused
(`{:error, :invalid_unix_time}` on REST, an undated frame on the stream) rather than becoming a
`DateTime` tens of thousands of years out. The streaming schema states no unit or format for
`timestamp`/`time` at all, so the same reading there is **unmeasured**.

**An order's `created_at` is the venue's `place_time_at`** (ISO8601 UTC, per
`order-detail.md`), and `updated_at` is `filled_time_at` ("time of the last executed trade")
**only** for a `:filled` or `:partially_filled` order; for any other status it is `nil`, since
the order changed after its last fill and the venue states no time for that. Both are `nil`
where the venue sent none or sent something that is not ISO8601. Unmeasured against a live
order.

**`get_symbols/1`, and the symbols on positions and orders, are split into `BASE-QUOTE` only
for crypto.** An equity, option, future or event row keeps the ticker or code the venue named
(`GBTC` is not `G-BTC`).

**A volume profile's price maps hold `Decimal`s only.** A level whose size is not a number
refuses the profile (`{:error, {:invalid_decimal, :buy_detail | :sell_detail, value}}`)
instead of storing `nil` where `VolumeProfile.point_of_control/1` adds sizes.

## An order book is sorted, so `hd(bids)` is the best bid

`get_order_book/2` guarantees it as of 0.4.39 — **bids descending, asks ascending** — and it
is `Core.Types.OrderBook`'s contract rather than this package's convenience. You do not need
to sort what you receive, and you should not assume the venue's row order means anything.

**Books exist for `US_STOCK` (the default), `US_ETF` and `US_FUTURES` only**; crypto and
option categories are refused before any request, `{:error, {:unsupported_book_category,
category}}`. `opts[:depth]` is levels per side and defaults to `10`. A `depth` that is not a
positive whole number is `{:error, {:invalid_option, :depth, value}}` (it was
`depth_out_of_range`), and on `US_FUTURES`, where the venue states 1 to 10, so is one
outside that range. Nothing is clamped to the nearest depth the venue would accept.

**A level whose price this package cannot read refuses the whole book**, and so does a price
of zero or less (`{:error, {:missing_required_field, :price}}`, `{:invalid_decimal, :price,
value}` or `{:non_positive_price, :price, value}`): `level/0` is `{Decimal.t(), Decimal.t()}`
and `hd(bids)` must be able to answer with a real number, and dropping the level would publish
a hole in the book as "no liquidity at that price". The same goes for a level with a readable
price and **no readable size** - `{:error, {:missing_required_field, :size}}`, or
`{:error, {:invalid_decimal, :size, value}}` for text that is not a number - and for a
negative size (`{:non_positive_size, :size, value}`). Only a level whose size is exactly zero
is dropped: no liquidity there, and nothing hidden. (Earlier releases passed `{price, nil}`
through, a pair `OrderBook.new/1` refuses.)

## A row the venue did not identify refuses the read, and is never given an empty id

Since 0.4.38 no row is published with `""` for an identifying field it could not supply. It
used to be dropped; it now refuses the whole read. **`get_screener/2`: a row that names
nothing is `{:error, :unexpected_response_shape}`.** **`list_watchlists/1`: a listing row
with no text `watchlist_id` refuses the whole reply as `{:error, {:missing_required_field,
:id}}`**, because a list missing a watchlist reads as "that watchlist does not exist".

An empty string is worse than the `nil` it replaced: a `nil` is detectable and `""` is a
value, so a consumer keying coverage by symbol used to get a live entry named `""`.

**`get_news/1` refuses rather than drops.** An item with no text `news_id` is
`{:error, {:missing_required_field, :id}}`, an unparseable `publish_time` is
`{:error, {:unparseable_venue_timestamp, text}}`, and a `related_symbols` that is not a list
of tickers is `{:error, :unexpected_response_shape}` — each for the whole read. The id is the
venue's `news_id`, never a ticker stand-in: an old JSON-row fallback once used the symbol,
which looks like an id and collides for every story about that symbol.

**The venue's own ranking is preserved.** A screener's `rank` is the position the venue
returned the row in, and nothing is renumbered or re-ranked: because an unnamed row refuses
the read, a `rank` is never missing from the middle of a list.

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

**A venue notice that did not parse is `:data_quality`, not `:degraded`.** A `notice` payload
that is not JSON (the venue sends plain text such as `Permission grabbed by other session`) is
`kind: :data_quality` with `details: %{reason: :unparsed_venue_notice, message: text,
session_id: id}`; `message` is the venue's own words, cut at 1,024 bytes with a marker. (It
was `:degraded` with `details.venue_notice_unparsed`; that key is gone.)

**`details.reason` is always an atom; the text is `details.message`.** `:link_down` from a
dropped socket is `reason: :disconnected`, from a crashed shard `:socket_crashed`, from a dead
session `:invalid_session`; a `:coverage_change` for a shard that could not open is
`:open_failed` and for a failed resubscribe `:resubscribe_failed`. The free text (what the
transport or venue said) is `details.message`. These carried an `inspect/1` string in
`details.reason` before: that is a breaking change of the notice shape.

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

Six things to know before you build on them:

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
- **`delay_ms` on `[:dp_exchange, :link, :reconnect_attempt]` is the delay actually waited**,
  not the ladder's rung. A socket whose session dropped waits 0 ms on the first attempt, then
  1 s doubling to 30 s, each wait shortened by a random amount of up to a quarter so that five
  shards the venue dropped together do not redial together. Only shortened, never lengthened:
  30 s stays the ceiling. A session that lived under 30 s counts as another failed attempt, not
  a reset. The wait ends at once if the socket's parent stops it.
- **`[:dp_exchange, :link, :down]` is emitted once per lost link, and only for a link that
  came up** (`:link, :up` fires at CONNACK 0). A failed reconnect that never got a session
  emits `:reconnect_attempt`, not `:down`, and a refused CONNACK (any non-zero code) emits no
  `:down` at all, only its notice (`:credentials_rejected` for codes 3, 4, 5, 103 and 104,
  `:degraded` for 105, `:link_down` for any other). A socket process that crashed, and a shard rebuilt on
  INVALID_SESSION, each emit one `:down` if their link was up, with `reason` as bounded text.
  `:down` is emitted only to close a `:up`.

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
not-yet-ported rather than as an absence at the venue (so are `get_funding/2`,
`get_contract_stats/2`, `get_rate_limit_status/2` and `test_connection/2`). What remains `:unsupported` is listed
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

`get_fundamental/3` reaches any of them; `fundamental_kinds/0` lists them. These are the
fundamentals endpoints this package serves, **not all the venue publishes**: the vendor's
index also lists `get-insider-holdings`, `list-insider-transactions`, `list-institutions`,
`list-institution-holdings`, `list-institution-holding-changes` and `list-economic-calendars`
(noticed 2026-10-18, not reached), and the screeners `get-fear-and-greed-index` and
`list-stock-unusual-activities`. A kind or screener absent from the lists here is therefore
"not served by this package", not "the venue has none". Every one takes
`symbol` and `category`; **`:type` and `:count` reach only the endpoints that document them**
and are dropped elsewhere.

`get_financials/3` takes the contract's `:balance_sheet`, `:income`, `:cash_flow` or
`:indicators`. **A fundamentals kind that is real but is not a statement is refused** —
`:company_profile` exists and answering `get_financials/3` with it would put a profile in a
statement's shape.

**`fiscal_period` is the venue's code translated through the venue's own legend**
(`0=FY, 1=Q1 …`). The raw integer stays in `line_items`, and a code outside the legend leaves
the label `nil` rather than inventing one.

**`:indicators` answers one statement per fiscal period, oldest first.** The venue sends one
object whose metrics each list their own `{fiscal_year, fiscal_period, value}` readings;
those are regrouped by period, with that period's metrics (the venue's names, string values)
in `line_items` beside `fiscal_year`, the raw `fiscal_period` and `currency`. `period_end`
is `nil` for them — the venue publishes no end date for an indicator.

**A dividend's `amount` is a cash amount only for a `CASH_DIVIDEND`** (or a row naming no
`div_type`). Stock, scrip and the other types leave it `nil`; `details` holds the venue's row,
`div_type` included.

**`get_corporate_events/1` needs `:symbol`** — these calendars are per issuer, not
market-wide — and without `:kind` reads *both* calendars, which is two requests.

**`get_news/1` returns the venue's own news items, one page per symbol.** Since 2026-10-18 it
reads `GET /market-data/news/stock-news/list` (the vendor's `list-stock-news` page): each item
has the venue's `news_id`, headline, summary, link, publisher (`source`), `publish_time` (as
UTC `published_at`) and `related_symbols`. `:symbols` on an item is the symbol it was returned
for plus the venue's tags, and an item returned for two requested symbols appears once. The
cursor is followed: `:limit` is the number of items wanted per symbol (positive integer; the
list is cut to exactly that), and without it the feed is read to its end. A repeated cursor is
`{:error, :pagination_key_did_not_advance}`, and the page cap reached first is
`{:error, :history_truncated}` rather than a short list, so pass `:limit` for a busy symbol.
The venue's `sentiment` label is a filter (`:sentiment`) only —
`Types.NewsItem` has no field for it. **Before 2026-10-18 this was the venue's LLM-generated
summary endpoint** (`POST /market-data/news/summaries/get`): one paraphrase per call, no
headline, link or time. That endpoint is no longer called, and its `:lang` option is gone.

**A screener's rank is the position the venue returned the row in.** Nothing is re-ranked:
two venues' "top movers" answer different questions, and so do one venue's under two sorts.

`"hot_stocks"` ranks stocks by **community activity**, not by price or volume, so it is not a
movers list. It takes no options (the venue documents no query parameter, so not even
`category` is sent), and each row's `metrics` is the venue's own `rank`, `symbol` and
`category`.

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

**A watchlist write that may have reached the venue and is not proven is
`{:error, {:write_unconfirmed, nil, reason}}`** - `create_watchlist/3`, `update_watchlist/2`,
`delete_watchlist/2` and the membership writes `add_watchlist_instruments/3`,
`remove_watchlist_instruments/3` and `sort_watchlist_instruments/2`: a transport error or timeout, a 5xx, a 2xx whose body is unreadable,
has no `success`, or (on create) names no id. The write may have happened, so do not retry it
blind: list the watchlists first (`nil` is the key - this venue takes no idempotency key for a
watchlist write). Failures decided before anything is sent (no credentials, our own rate
limiter, an invalid argument) stay plain `{:error, reason}`, and the venue's own refusals stay
`{:refused, _}`.

**`delete_watchlist/2` of an id the venue does not hold is `{:refused, :not_found}`** (a 404),
on `Fake` too; the Fake used to answer `{:ok, :ok}`.

**Creating with members is two requests.** Where the add fails, the watchlist exists and is
empty: `{:error, {:watchlist_created_without_members, id, reason}}` carries its id so you can
deal with it. Where the add is itself unproven (it may have landed) the answer is
`{:error, {:watchlist_created_members_unconfirmed, id, reason}}`: the watchlist exists and its
membership is unknown, so read it with `get_watchlist/2` before adding again.

## A stop order needs `:stop_price`; a trailing stop needs `:trailing_stop_step` and `:trailing_type`

`place_order/3`'s `request` map takes the same field names for every instrument type, and
which ones matter depends on `:order_type`:

| `:order_type` | fields it needs |
|---|---|
| `:market` | `:quantity` or `:amount` |
| `:limit` | the above, plus `:price` |
| `:stop` | the sizing field, plus `:stop_price` — **no `:price`**, this order type has no limit leg |
| `:stop_limit` | the sizing field, plus `:price` and `:stop_price` |
| `:trailing_stop` | the sizing field, plus `:trailing_stop_step` and `:trailing_type` |

**`:trailing_type` is `:amount` or `:percentage` (or `"AMOUNT"` / `"PERCENTAGE"`) and has no
default.** The step alone is a dollar distance or a fraction of the price, and the venue
documents the type beside it (`common-order-place.md`: `"trailing_type": "AMOUNT",
"trailing_stop_step": "1"`). A trailing stop without it is `{:error, {:missing_field,
:trailing_type}}`, any other value `{:error, {:invalid_trailing_type, v}}`, and on any other
order type it is `{:error, {:unexpected_field, :trailing_type}}`. A `:percentage` step is a
fraction (`0.01` is 1%) and one above `1` is `{:error, {:invalid_trailing_stop_step, v}}`.

A field a given order type does not use is **refused, not dropped**
(`{:error, {:unexpected_field, key}}`) — a `:stop` request built from a `:limit` template
(with `:price` left over) is told so instead of going out without the limit the caller
believed was in force. Read the fields back the
same way: `get_order/3` and the struct `place_order/3` hands back both carry `:stop_price`
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
request into several: `{:error, {:batch_too_large, count, 50}}`. An empty list is
`{:error, :empty_batch}` and a non-list `{:error, :invalid_batch}`.

**The result is per order.** The venue validates each and returns each; a batch where three
of five were accepted is the normal shape. The vendor also notes the endpoint is not
available to every client, so a refusal can mean the account is not entitled.

**The batch endpoint's own matrix is narrower than `place_order/3`'s, and it is checked
against, not discovered.** `order_type` is `MARKET` or `LIMIT` only — no `STOP_LOSS`,
`STOP_LOSS_LIMIT` or `TRAILING_STOP_LOSS`, all real for a single order.
`order_type` and `time_in_force` are **required per row** (`{:missing_field, key}`, never
defaulted). `time_in_force` is `DAY`, the one member of this endpoint's own enum; a caller who
asks for anything else is refused rather than silently switched to `DAY`
(`{:unsupported_batch_time_in_force, v}`, and `{:unsupported_batch_order_type, v}` for the
order type). Sizing is `QTY`
only — `:amount` is refused here, where `place_order/3` accepts it for equities. And
`:support_trading_session` (`:core`, `:all` or `:night`) is **required per order**, with
no documented venue default, unlike on `place_order/3` where it is optional.

**A batch that may have been placed is never a bare error.** A timeout, a 5xx, or a 2xx whose
envelope holds no rows is `{:error, {:order_unconfirmed, ids, reason}}` where `ids` is the
list of every `client_order_id` sent, in order (the ones this package generated included; it
was a bare `{:error, reason}` and the generated ids were lost, so a retry placed every order
again). Settle each with `get_order/3`. Missing credentials and our own limiter refusing a
write stay the plain `{:error, reason}` (`place_order/3`, `replace_order/4` and the watchlist
writes likewise).

An entry with no `:symbol` or `:side` (`{:invalid_symbol, nil}` / `{:missing_field, :side}`),
or a `LIMIT` entry with no `:price` (`{:missing_field, :price}`), is refused by index before
anything is sent: `{:error, {:batch_order_rejected, index, reason}}`. So is a key the batch
builder does not read (`{:unsupported_order_field, key}`, e.g. `:stop_price`), a `:price`
on a market entry (`{:unexpected_field, :price}`), neither `:quantity` nor `:amount`
(`{:missing_field, :quantity}`), any `:amount` (`{:unexpected_field, :amount}`) and no
`:support_trading_session` (`{:missing_field, :support_trading_session}`). These three were
the bare atoms `:missing_order_size`, `:cash_sizing_not_supported_for_batch` and
`:support_trading_session_required`.

`place_order/3` answers `{:error, {:order_unconfirmed, client_order_id,
:unexpected_response_shape}}` when the venue accepts (2xx) but its row names no order **or
the response has no row at all** (`{}`, an empty or unreadable `data`; it was a bare
`{:error, :unexpected_response_shape}`, which a caller retries into a duplicate). The order
may be live: settle it with `get_order/3` and the id in the tuple. **Only an outcome that may
have reached the venue is wrapped**: no credentials (`{:error, {:missing_credentials,
:webull}}`, the same as the Fake), our own rate limiter refusing and a signing failure are
decided before anything is sent and are the plain `{:error, reason}`. `replace_order/4`
follows the same rule for its own send (`{:order_unconfirmed, order_id, reason}`).

## `place_order/3` and `preview_order/3` check the request, in this order, before signing

A map (`{:invalid_order_request, r}`), then **no key the builder does not read**
(`{:unsupported_order_field, key}`: `post_only`, `reduce_only`, `end_time` were ignored), the
symbol (`{:invalid_symbol, v}`, blank counts), the side (`{:missing_field, :side}` when
absent - it was `{:invalid_side, nil}` - otherwise `{:invalid_side, v}`: `:buy`/`:sell`,
or text in any case; **`:short` is refused**, `capabilities/0` says
`supports_short_selling: false`, where it used to be sent and come back as `side: nil`),
**`:order_type` and `:time_in_force`, both required, never defaulted**
(`{:missing_field, key}`: an absent type used to become a limit order and an absent duration
a GTC one), a type the instrument does not use (`{:unsupported_order_type, type}`), a
duration it does not serve for that type (`{:unsupported_order_combination, type, tif}`, the
instrument no longer in the tuple), **a GTD order's expiry with the duration**
(`{:missing_field, :expire_date}`; an `:expire_date` on any other duration is
`{:unexpected_field, :expire_date}` - it used to be checked after the prices), the size
(`{:missing_field, :quantity}` for neither `:quantity` nor `:amount`;
`{:unexpected_field, :amount}` for both, and for `:amount` on a stop-limit order - these
were the bare atoms `:ambiguous_order_size` and `:cash_sizing_not_supported_for_stop`), the price
fields (`{:unexpected_field, key}` for a `:price` on a market or stop order, a `:stop_price`
on a limit or market one, a `:trailing_stop_step` on anything else; `{:missing_field, key}`
for one the type needs), the numbers (`{:invalid_quantity, v}`, `{:invalid_amount, v}`,
`{:invalid_price, v}`, `{:invalid_stop_price, v}`, `{:invalid_trailing_stop_step, v}`; **a
float is refused**, it has lost digits - use a `Decimal`, an integer or numeric text), the
caller's `client_order_id` (`{:invalid_client_order_id, v}`, 32 characters at most, blank
refused), then the account option
(`{:error, {:missing_option, :account_id}}`) and the credentials. `Fake` answers the same, in
the same order, from the same function. A preview that is not a map is
`{:invalid_order_request, r}` (it raised), and a preview of crypto is still
`{:preview_not_supported, :crypto}` first.

**`replace_order/4` is told which order it edits.** `opts[:instrument_type]` and
`opts[:order_type]` (the type of the order being amended, whose edit table applies) are
required: absent, each is `{:error, {:missing_option, key}}`. They used to default to an equity
limit order, where `place_order/3` defaults to crypto. `changes` that is not a map is
`{:error, {:invalid_order_request, changes}}` (it raised).

**Order ids** (`get_order/3`, `cancel_order/3`, `replace_order/4`): `nil`, non-text or blank
(`"  "` was sent) is `{:error, {:invalid_order_id, v}}`, checked **before** the account option
and the credentials (it was `{:invalid_client_order_id, v}`, after the account). The tag
`{:invalid_client_order_id, v}` now means only the `client_order_id` inside a placement.

**A 404 is a permanent refusal**: `{:refused, :not_found}` from every REST read and write (it
was `{:error, {:exchange_error, :webull, "HTTP 404..."}}`, which Core calls retryable). The
Fake answers the same for an order id it never issued.

**A symbol the venue does not list is `{:refused, :not_listed}`** on every single-symbol read
(`get_price/2`, `get_top_of_book/2`, `get_order_book/2`, `get_trades/2`, `get_historical_prices/4`,
`quantization/1`, and every other read of exactly one symbol: futures/option/event/stock bars,
`get_volume_profile/3`, `get_auction_imbalance/2`, `get_financials/3`, `get_filings/2`,
`get_event_trades/2`, `get_event_order_book/2`), real and Fake alike (the Fake answers it for a
crypto-shaped pair on the equity-only reads): a 404, or a 4xx whose body names `INVALID_SYMBOL`. A
417 `INVALID_SYMBOL` used to surface as the retryable `{:error, {:exchange_error, :webull,
"HTTP 417..."}}` and a 404 as `{:refused, :not_found}` here; both changed, which is a breaking
change of a returned reason. No venue text rides in the reason. A 404 on an order or a
watchlist is still `:not_found`.

**The Fake refuses a reused `client_order_id`** as `{:refused, {:duplicate_client_order_id,
id}}` instead of overwriting the stored order: the venue requires the id unique per account.
The vendor reference does not state the venue's own wording for a duplicate, so that wording
is unmeasured; the shape (a refusal, never a second order) is what to rely on.

## Tokens: a token that exists is not a token that works

`create_token/1` returns one that is `PENDING`, and verification happens through an SMS code
in the Webull app — which needs a person. `check_token/2` is the only call that tells
`PENDING` from `EXPIRED` from `INVALID`; all three fail identically at the next request and
each has a different remedy. A response with no `token`, or a `status` outside the venue's
four (`PENDING`, `NORMAL`, `INVALID`, `EXPIRED`), is refused —
`{:error, {:missing_required_field, field}}` / `{:error, {:unknown_token_status, status}}` —
and `oauth_token/3` does not take a 2xx with no `access_token` for a grant (see below).
`NORMAL` is never inferred.

**`create_token/1` is a write.** A create that may have reached the venue and is not proven
(a transport error or timeout, a 5xx, a 2xx whose body is unreadable, names no token or states
a status outside the four) is `{:error, {:write_unconfirmed, nil, reason}}` - `reason` is the
refusal above for a 2xx - since a token may now exist and the SMS verification may be
waiting; the `nil` is the idempotency key the request does not carry. Missing credentials and
our own limiter refusing stay the plain `{:error, reason}`; a 4xx is `{:refused, reason}`.
`check_token/2` is a read and keeps the unwrapped refusals.

`oauth_token/3` is one endpoint doing two jobs on a **different host**, with a form body.
`opts[:code]` exchanges, `opts[:refresh_token]` refreshes, and exactly one is required.
**Two expiries come back and they are not the same clock** — `rt_expires_in` is the one that
ends the session.

**`oauth_token/3` is a write too.** An authorization code is single-use and a refresh token
may rotate, so a grant whose answer was lost may still have been honoured. A transport error
or timeout, a 5xx or 408, and a 2xx that is undecodable, is not an object or carries no
`access_token` are `{:error, {:write_unconfirmed, nil, reason}}` (it was a bare `{:error,
reason}`, which invites a retry with a credential that no longer works): do not retry the same
code or refresh token, start the consent flow again. A 4xx but 408 and 429 is
`{:refused, {:venue_error, status, reason}}` (a 404 included, unlike the REST reads), and our
own limiter refusing stays the plain `{:error, reason}`.

## Rows this package will not flatten, and rows that are not yours

**An answer is for the symbol you asked, not the first row.** `get_price/3`,
`get_top_of_book/3`, `quantization/2` and `get_event_order_book/3` answer
`{:error, :not_in_response}` when the venue's rows name other symbols than the one asked for.

**`get_positions/1` refuses what a `Position` cannot say**: a multi-leg option strategy and any
event-contract row answer `{:error, {:unsupported_position, symbol, reason}}` for the whole
list, rather than a position that drops the legs or the yes/no outcome. A `SINGLE` option
row's `symbol` is the venue's, unverified as the contract symbol.

**`get_auction_imbalance/2` labels each row with the auction the row names**
(`PRE_OPEN` is `:opening`, `PRE_CLOSE` is `:closing`), which outside the publication windows can
differ from the one you asked for.

**`get_option_chain/2` keys strikes by value**: `"150.0"` and `"150"` are one cell at
`Decimal.new("150")`.

**`get_watchlist/2` takes its `id` from the venue's reply** and refuses a reply that names none.

## A write is sent once; a read is retried

Every request is signed afresh for each attempt, so a retry after a timeout or a 5xx is a
real second request rather than a replay the venue refuses. That makes a retried write able
to take effect twice, and the venue documents no idempotency key that would deduplicate a
repeated order. So `place_order`, `place_orders`, `replace_order`, `cancel_order`,
`create_token`, `oauth_token` (an authorization code is single-use and a refresh token may
rotate) and every watchlist write are **sent once**. A timeout on one of them means
"unknown": read the order or watchlist back before sending it again. This is a guarantee:
these calls read neither `:retry_attempts` nor `:retry_delay`, so passing either (any value,
including 0 or 1) is `{:error, {:unknown_option, key}}` before anything is sent, in `Fake`
too. Before, a `:retry_attempts` was accepted and silently overridden with 1.

**Event contract orders sized by `:amount` are BUY-only and FOK-only** (the vendor page
states both): a sell is `{:invalid_side, side}` and any other duration
`{:unsupported_order_combination, :amount, time_in_force}`, before the request, in `Fake`
too. Sizing by `:quantity` is not restricted.

## An order's numbers and ids are checked before anything is signed

`quantity`, `amount`, and the price fields the order type sends (`price`, `stop_price`,
`trailing_stop_step`) must be a finite number above zero, in any of `Decimal`, integer or
numeric text (a float is refused): otherwise `{:error, {:invalid_quantity, v}}` /
`{:invalid_amount, v}` / `{:invalid_price, v}` / `{:invalid_stop_price, v}` /
`{:invalid_trailing_stop_step, v}` (it was `{:invalid_number, field, v}`), by index inside a
batch. They go out as the venue's strings in full notation (`"0.00000001"`, never `"1.0e-8"`
and never a JSON number). `replace_order/4` holds its `changes` to the same rule, treats a
present `nil` as `place_order/3` judges it (`%{price: nil}` is `{:invalid_price, nil}`; an empty
map is `{:invalid_order_request, %{}}`), and refuses an
`:order_type` or `:time_in_force` it has no wire name for
(`{:unsupported_order_type, v}` / `{:unsupported_time_in_force, v}`) instead of dropping it.
`cancel_order/3`, `get_order/3` and `replace_order/4` refuse a missing, empty or blank
order id as `{:error, {:invalid_order_id, id}}`. `get_order_book/3` on
`US_FUTURES` takes `depth` 1 to 10 (`{:invalid_option, :depth, n}`), as the venue's page
states. The fake refuses all of these identically.

**An order's `expire_date` and `event_outcome` are checked before a request**, in
`place_order/3` and `preview_order/3` (and the fake). A GTD `expire_date` is a `Date` or one
real `yyyy-MM-dd` string (`{:error, {:invalid_expire_date, v}}` otherwise; a missing one is
`{:missing_field, :expire_date}`); `event_outcome` is `:yes`, `:no`, `"yes"` or `"no"`
(`{:error, {:invalid_event_outcome, v}}`). `:support_trading_session` is `:core`, `:all` or
`:night` (`{:error, {:unsupported_support_trading_session, v}}` otherwise); optional on
`place_order/3`, left off the wire when absent. **Time bounds** (`:start`/`:end` on
`get_transfers/2` and `get_transactions/2`, `:since`/`:until` on a `history: true`
`get_orders/2`) are `DateTime`s or absent: anything else is
`{:error, {:invalid_time, key, value}}`. A `get_positions/2` side is read from the sign of
`quantity` (negative is `:short`), which the vendor page does not document and which has not
been measured against a live short position.

**`opts[:account_id]` must be non-blank text** on every account and order call; `nil`, a number,
`false`, `""` and whitespace are `{:error, {:missing_option, :account_id}}` (it was the bare
atom `:account_id_required`), here and in the fake (`place_orders/3` included). `:activity_types` on `get_transfers/2` and `get_transactions/2` is a non-empty list
of text or the venue's own comma-joined string; anything else is
`{:error, {:invalid_activity_types, value}}`.

**An `Order` that `place_order/3` hands back is in the contract's vocabulary, not in your
spelling of the request**: `side` is `:buy` or `:sell` (a read-back of a `SHORT` order is `nil`,
which `Order` has no word for; placing one is refused), and `quantity`, `price` and `stop_price` are `Decimal`s
whatever you sent (an integer, a numeric string). The fake builds its orders with the same
function. **A replace the venue accepted whose read-back then fails** is
`{:error, {:replace_accepted_unread, client_order_id, reason}}`: the amendment took effect,
so read the order with `get_order/3` rather than sending the replace again.

**`get_positions/1` refuses a row with no readable `quantity`** (`{:error,
{:missing_required_field, :quantity}}`, or `{:invalid_decimal, :quantity, value}`) for the
whole list: the venue's page lists it as required and `Position` has no `nil` quantity or side.

**The fake narrows what the venue narrows.** `Fake.get_option_chain/2` and
`Fake.get_option_expirations/2` honour `:expiry` and `:strike`; `Fake.get_price/2` and
`Fake.get_top_of_book/2` refuse a snapshot category the venue has no endpoint for
(`{:unsupported_snapshot_category, c}`) and `Fake.get_top_of_book/2` refuses `US_EVENT`;
`Fake.get_historical_prices/4` checks the category, width, range and `:limit` of whichever of
the five bars endpoints the category names; `Fake.get_trades/2` checks the category and
`:limit`; `Fake.get_financials/3` refuses a `:count` over 20; and `Fake.get_news/1` refuses an
unlisted `:category` or `:sentiment` as the real path does. A request those endpoints would accept for a symbol
the fake does not model is `{:refused, :not_listed}`.

**A single-symbol read refuses a symbol it cannot send, locally.** `get_price/2`,
`get_top_of_book/2`, `get_order_book/2`, `get_trades/2` and `get_historical_prices/4` answer
`{:error, {:invalid_symbol, value}}` for a symbol that is `nil`, not a string, or blank after
trimming - before credentials and before any request, on every category (the default
`US_CRYPTO` used to raise `FunctionClauseError`, the others sent `symbols=`). The category's own
refusal comes first. `get_prices/2` refuses a list that is not a proper list as
`{:error, {:invalid_symbols, value}}`, and gives a bad member its own
`{:error, {:invalid_symbol, member}}` result without a request, so the others still price.
A historical `range` must be a keyword list whose `:start` and `:end` are `DateTime`s (or
absent); anything else is `{:error, {:invalid_range, range}}`, before any request is charged
(a non-`DateTime` bound used to raise after it). `Fake` answers all of these identically, in
the same order: category, range and the rest of the request, symbol, then credentials.

**`Fake` streaming matches the feed.** `subscribe/2` pushes a `Quote` and a `TopOfBook` for
each symbol it models, and `coverage_by_kind/1` reports both (`:quotes` and `:top_of_book`).
A symbol is covered only once it was delivered to a reachable subscriber; a `to:` atom that
names no process is skipped, never raised on. `update_symbols/2` delivers the symbols it adds
to the existing subscribers (it takes no `:to`, as the feed does), and covers nothing for a
symbol it did not push. `subscribe_notices/1` sends no `:link_up`: the fake has no link.

**`Fake` streaming needs credentials where the feed does.** A `subscribe/2`,
`unsubscribe/2` or `update_symbols/2` that changes what is wanted needs `credentials:` in its
own options: with no shard open yet it is `{:error, {:missing_required_field, :app_key}}`
(the feed cannot open its socket without the App Key), and with one open it is
`{:error, {:missing_credentials, :webull}}` (the HTTP request is signed from the call's own
credentials). A call that changes nothing needs none. A refused call changes nothing.

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

This holds wherever the call has got to, including after the package moved your symbols to
another shard because the first was full or the venue refused one: the ten seconds run from
when your call arrived, not from the latest internal retry.

A list that is not made of non-blank strings (empty or whitespace-only is blank) is refused at
once with `{:error, {:invalid_symbols, symbols}}` (your argument exactly as given, whole, even
an improper list), and nothing is subscribed or removed. This is decided in **your** process,
before `{:error, :feed_not_started}`: a malformed list answers the same whether or not the feed
runs, and `unsubscribe(nil)` is refused rather than `:ok`. After the symbols, `subscribe/2` and
`subscribe_notices/1` check `to:`: anything but a pid or a registered-name atom - `true` and
`false` included - is `{:error, {:invalid_subscriber, to}}`. `subscribe/2`, `unsubscribe/2`,
`update_symbols/2` and `subscribe_notices/1` all take `opts \\ []`.

**Neither needs a retry.** Your symbols are already recorded. The subscribe finishes or
the shard connects, and your symbols go out with it. `coverage/1` tells you when they
start arriving.

## Every answer a streaming call can give

`subscribe/2`, `unsubscribe/2` and `update_symbols/2` answer `:ok` or one of these, all
wrapped as `{:error, reason}`:

| `reason` | Meaning |
|---|---|
| `{:invalid_symbols, symbols}` | Your list was malformed (decided in your process), **or** the venue refused those symbols (a list of canonical names). The venue's refusals are excluded and the rest is retried, so you see this only when no retry is left. |
| `{:invalid_subscriber, to}` | `to:` is not a pid or a registered-name atom. |
| `{:streaming_unavailable, :uat}` | There is no UAT broker. |
| `{:missing_required_field, :app_key}` | A shard had to be opened and the credentials in use carried no usable `:app_key` (absent, not text, or blank). This package's own answer, not the venue's. |
| `{:connection_refused, details}` | The venue refused the shard's MQTT session. `details.connack` is its code and `details.session_id` names the shard; `details.reason: :connection_limit` is code 105 (five connections per App Key), which is not a credentials problem. |
| `{:shard_crashed, reason}` | The shard's socket died while you waited. It is reopened; retry. |
| `{:invalid_session, session_id}` | The venue discarded the shard's session. The shard is reopened on a fresh one; retry. |
| `{:reconcile_pending, ms}` / `{:connack_timeout, ms}` | Still in progress; see above. Your symbols are recorded. |
| `{:reconcile_timeout, ms, :no_venue_response}` | The HTTP subscribe never answered. |
| `{:reconcile_task_down, reason}` | The task making the HTTP subscribe died. |
| `{:capacity_exceeded, symbols}` | Every shard is full (five of 100): these symbols fit nowhere. |
| `{:partial_failure, failed: reason, capacity_exceeded: symbols}` | Both of the above kinds at once. |
| `:oversubscribed` | The venue's per-session ceiling; the feed moves the overflow to another shard and retries, so it reaches you only when that retry is spent. |

HTTP and signing failures of the subscribe itself keep their ordinary shapes
(`{:error, {:refused, status, body}}` for a 400, 401 or 403,
`{:error, {:exchange_error, :webull, text}}` for the rest, and
`{:error, {:missing_credentials, :webull}}`).

**Symbols are released when the last data subscriber dies.** A subscriber that dies is
dropped (it is monitored, and so is a `subscribe_notices/1` receiver). When the death empties
the set of data subscribers, the feed releases every wanted symbol through the same path
`unsubscribe/2` takes: the venue subscription is removed and no socket is held for nobody
(`wanted/1` and `coverage/1` become empty). A restarted consumer calls `subscribe/2` again
with its new pid. A notice-only receiver's death releases nothing. A registered name is never
monitored and stays in the set, so it keeps the symbols: the holder of the name may die and
be restarted under it. Subscribing twice from one pid is one subscriber, and delivers once.

**A payload for a symbol you just unsubscribed is dropped**, even if the venue sends a few
more, and it does not count toward `coverage/1`.

### Options of the feed itself

Passed in the options of `{DpExchange.Webull, opts}`. Every one is optional.

| Option | Default | What it does |
|---|---|---|
| `:credentials` | none | Kept (wrapped) to replay subscriptions after a reconnect. A later call's own credentials replace them only if they can be signed with and the call is not refused. |
| `:max_queue_len` | see the slow-subscriber section | Mailbox bound before a subscriber is skipped. |
| `:priority_symbols` | none | See `priority_symbols:` below. |
| `:resubscribe_interval_ms` | 60_000, at least 1_000 | Blind re-assert cadence. A smaller value raises `ArgumentError` at start. |
| `:resubscribe_failure_limit` | 12 | Consecutive failed re-asserts before a silent shard is reopened. |
| `:stale_delivery_ms` | 300_000 | How long a shard must deliver nothing before a reopen is allowed. |
| `:connack_timeout_ms` | 10_000 | How long a call waits for a connecting shard. |
| `:reconcile_timeout_ms` | 60_000 | Deadline of one HTTP subscribe. |
| `:rejected_symbol_ttl_ms` | 24 hours | How long a venue-refused symbol is excluded. |
| `:open_retry_base_ms`, `:open_retry_max_ms` | 1_000, 60_000 | Backoff of a shard that failed to open. |
| `:shard_spacing_ms` | 5_000 | Gap between background socket opens. |
| `:socket_connect_timeout`, `:socket_recv_timeout` | 3_000, 2_000 | TCP connect and upgrade budget per socket. |
| `:url` | the venue's endpoint | Socket URL; `ws://` is refused except to a loopback host. |

### Options some reads require

A missing required option is refused before any request, as a bare atom:
`get_auction_imbalance/2` needs `:auction` (`:opening` or `:closing`; absent is
`{:error, :auction_required}`, anything else `{:error, {:unsupported_auction, v}}`),
`list_event_events/1` needs `:series_symbol` (`{:error, :series_symbol_required}`), and
`sort_watchlist_instruments/2` needs `:sorts`, a non-empty map of symbol to integer position
(`{:error, :sorts_required}`, or `{:error, {:invalid_sorts, v}}`). `list_event_markets/1`
takes `:series_symbol`, `:event_symbol`, `:symbols`, `:expiring_after` (a `Date` or text) and
`:pagination_key`; `list_event_events/1` takes `:status` (`ACTIVE` or `INACTIVE`, never
defaulted); `get_news/1` requires `:symbols`, takes `:category` (`US_STOCK` default, or `HK_STOCK`) and
`:sentiment` (`POSITIVE`, `NEGATIVE`, `NEUTRAL`), and refuses a value outside those as
`{:error, {:invalid_option, key, value}}`.

## Every negative here is audited

`docs/reference/webull/negative-claims.md` lists each one with the source and date consulted.
**Three were wrong**, all the same mistake: a true statement about the *stock* endpoint
restated as a claim about the venue. It also records why the vendor's pages have to be
**rendered** to be read — their parameter tables are built in JavaScript, and an inventory
captured without them looks finished and cannot be implemented from.

## `priority_symbols:` — keep the stream on the pairs you trade

The account holds the `us-crypto` stream on **one session at a time**. A consumer measured this
on 0.4.110: each of three shards streamed one contiguous minute in three, never two at once.
By default the permission rotates, so every pair streams about a third of the time.

To keep the pairs you actually trade on the stream continuously, name them at start:

```elixir
{DpExchange.Webull, credentials: creds, priority_symbols: ~w(BTC-USD ETH-USD SOL-USD)}
```

Those symbols, up to one session's capacity (100), are planned into one shard. That shard
keeps the stream: it is re-asserted the moment it goes quiet, and no other shard is ever
re-asserted against it. **The price is that the other shards do not rotate.** With one holder,
any of them streaming would mean the priority shard is not. Plan to cover those pairs from REST
(`get_prices/2`, twenty per request). Priority symbols past one session's capacity are placed
with the rest. A value that is not a list of strings fails at start.

The guarantee holds while shard 0 really is the priority shard. If none of the priority
symbols is subscribed, shard 0 is an ordinary shard and every shard rotates as without the
option. While the priority shard is disconnected, the others are repaired and rotated as
usual, and the priority shard takes the stream back when it reconnects. Subscribing a priority
symbol later re-plans shard 0 so the priority symbols come first. The ordinary symbols it
held move to the other shards, and those re-subscribes take the stream briefly.

**Shard 0's unused room is not wasted, and only overflow uses it.** Ordinary symbols are
planned into shards 1 to 4 first. Only when those are full does what would otherwise be
refused as `capacity_exceeded` fill the room left in shard 0 after the priority symbols. So
three priority symbols and 450 others fit, where they used to be refused below the 500-symbol
ceiling. This costs the priority guarantee nothing, because the permission is per session: an
ordinary symbol in shard 0 streams on the session that already holds it, and a priority symbol
always takes its place first. Such a symbol therefore streams continuously while the total is
high, unlike the symbols on the other shards, which fall back to REST.

## A shard reopens its own socket only once it has stopped delivering

Each shard reasserts its symbols on a timer, **but only once it has gone quiet**: a shard where
any of its symbols arrived within the last interval (60 s) is left alone. Each completed
re-assert grabs the `us-crypto` permission from a sibling session, and on 2026-10-08 a
consumer measured that costing a streaming shard 30 s or more of silence every minute (issue
#10). **The account cannot stream every shard at once** (issue #11, measured across
0.4.107–0.4.109): re-asserting every quiet shard made two shards flap, each losing half its
minutes, and never re-asserting while a sibling streamed left them with no stream at all. So the
permission is **rotated**. While any shard streams, each tick re-asserts exactly one quiet
shard, the one longest since it last streamed or last had a turn, and announces it with an `:info` `:coverage_change` naming
the shard, its `session_id` and its symbols. A sibling may go quiet in turn, and that is the
rotation, not a fault. When no shard streams at all, every quiet shard is re-asserted at once.
Venue notices carry `session_id` in `details`. If one shard's blind resubscribe fails
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

(A socket that *was* up and dropped is a different thing again: it reconnects itself, with the
jittered backoff described under Telemetry.)

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
all three cases, which means "not observed", and `wanted/1` answers `[]`. Treat `:feed_timeout` as transient and retry.
Treat the other two as a feed your supervision tree has to bring back.

**`:feed_timeout` means "no answer", not "not applied".** The request is already in the
feed's mailbox and is applied when the feed reaches it. Retrying is safe because each of
these calls is idempotent (add, remove or replace a symbol set, applied in order), and
`coverage/1` shows what is being delivered once the feed answers.

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

**The same holds for the other two topics.** A `snapshot` with no readable price
(`details.dropped == {:snapshot, {:invalid_decimal, :price}}`, or `{:snapshot, :undecodable}`),
a `quote` book that states no readable level (`{:quote, :no_readable_level}` or
`{:quote, :undecodable}`) and an MQTT packet type this package does not handle
(`{:unhandled_packet, type}`) each raise one `:data_quality` `Notice` per reason per
connection, with the venue's strings in `details`. The reason never contains the venue's
offending value, and a connection reports at most 64 distinct reasons, so a venue sending
something different every message cannot make the notices, or this package's memory, grow
with it. Before this, an unreadable snapshot or book was dropped in silence.

A streamed `TopOfBook` carries a `bid_size` only with a readable `bid`, and an `ask_size`
only with a readable `ask`. A level whose price is `"null"` but whose size is a number used
to arrive as `bid: nil, bid_size: 5`.

**Credential refusals.** A CONNACK of 3, 4, 5, 103 or 104 is a `:credentials_rejected`
`Notice`. 4 (bad user name or password) and 5 (not authorised) are MQTT's own codes, which
the venue's table does not list; they used to be a bare `:link_down`.

**MQTT acknowledgements.** The QoS a session is delivered at is the venue's choice, not this
package's, and the documentation states none. A QoS 1 or 2 message is acknowledged
(`PUBACK`, `PUBREC`, `PUBCOMP`) and delivered as any other. Unacknowledged, a broker's
in-flight window fills and delivery stops on a connection that still looks healthy.

**Duplicates by QoS (MQTT 3.1.1 §4.3).** QoS 2 is delivered once: a retransmitted `PUBLISH`
(`DUP` set, or a packet id reused before its `PUBREL`) is acknowledged again but not handed
to you a second time. The packet ids held for that are bounded at 65,535 and dropped on
disconnect. QoS 1 is at-least-once by the spec: a repeat of an acknowledged id is a new
publication whatever `DUP` says, so it is delivered again. For a quote feed the newest value
wins and a repeat is harmless; the venue's own `venue_time` is on every struct if you need to
tell a repeat from a new value.
