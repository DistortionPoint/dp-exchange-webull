# REST (Data API) rate limits — reference

**Primary source**: `https://developer.webull.com/apis/docs/rate-limits/` — the venue's
per-endpoint rate-limit table, covering Sandbox and Production.
**Corroborating source**: the per-endpoint reference pages' own "Rate Limits" blocks
(e.g. `.../docs/reference/crypto-snapshot/`, `.../crypto-bars/`).
**Read 2026-09-09.** Supersedes the 2026-09-08 revision of this file entirely — see
"What this file got wrong" below, which is the more useful half of it.

Committed rather than linked, per D13. This is the number `capabilities/0`'s
`public_ceiling`/`authenticated_ceiling` rest on, and the number that configures the real
`DefaultRateLimiter` this package starts (`DpExchange.Webull.Supervisor`'s private
`limits/1`) — not narrative decoration, the thing that gates every REST call this package
makes.

## The ceiling

> **60/60s** in Production, **30/60s** in Sandbox — for every market-data endpoint.

The venue states its limits as `N/Ts`: *N* requests per *T*-second window. Every
market-data endpoint in the table carries the same pair, without exception — crypto,
stock, option, future and event contract, display and non-display alike, including the
streaming `subscribe`/`unsubscribe` calls.

Three dimensions, in the venue's own words:

- **Per `app_key`** — "All requests sharing the same `app_key` count toward a single
  quota."
- **Per User** — Connect API only, metered by `account_id`. Not this package's surface.
- **Per Endpoint** — "Each endpoint has its own independent rate limit counter. Hitting
  the limit on one endpoint does not affect others."

**Exceeded behaviour**: HTTP `429`, request rejected with no partial processing. And the
part that decides how this package rounds:

> "Repeatedly exceeding rate limits may result in temporary IP-level blocking."

A ceiling that answers 429 and then blocks the IP is not a latency trade. Guessing high
costs the connection, so this rounds toward the venue every time.

### The endpoints this package actually calls

| endpoint | path | Sandbox | Production |
|---|---|---|---|
| Crypto Snapshot | `/market-data/crypto/snapshots/list` | 30/60s | 60/60s |
| Crypto Historical Bars | `/market-data/crypto/bars/list` | 30/60s | 60/60s |
| Stock Snapshot | `/market-data/stocks/snapshots/list` | 30/60s | 60/60s |
| Stock Historical Bars | `/market-data/stocks/bars/list` | 30/60s | 60/60s |
| Stock Tick | `/market-data/stocks/ticks/list` | 30/60s | 60/60s |
| Stock Quotes Depth | `/market-data/stocks/depths/list` | 30/60s | 60/60s |
| Option Tick / Snapshot / Bars | `/market-data/options/{ticks,snapshots,bars}/list` | 30/60s | 60/60s |
| Future Tick / Snapshot / Bars / Depth | `/market-data/futures/...` | 30/60s | 60/60s |
| Streaming Subscribe | `/market-data/streaming/subscribe` | 30/60s | 60/60s |
| Streaming Unsubscribe | `/market-data/streaming/unsubscribe` | 30/60s | 60/60s |
| Create Token | `/auth/tokens/create` | 10/10s | 10/10s |
| Check Token | `/auth/tokens/check` | 10/10s | 10/10s |

Auth is looser than market data and is not the binding constraint; it is recorded so a
future per-endpoint limiter does not have to re-derive it.

### A second, wider cap: 600/minute across market data

The per-endpoint reference pages state two numbers together, and they are not the same
number:

> • 1 request per second per App Key
> • Market Data Global Limit: 600 requests per minute

`1 request per second per App Key` **is** `60/60s`, stated in different units — so two
independently maintained vendor pages agree on the per-endpoint figure. The `600 requests
per minute` is a *global* market-data budget across all endpoints, ten times the
per-endpoint one, and it binds only for a caller fanning out across ten or more distinct
endpoints at once. This package does not, and its single shared limiter at 60/60s sits an
order of magnitude under it regardless.

## What this package declares, and why it is conservative

`capabilities/0` declares `%{limit: 60, per_ms: 60_000}` on both ceilings. Every endpoint
here is signed (`credential_benefit: :required`), so there is no anonymous surface and no
public/authenticated split to make.

**The declaration is stricter than the venue requires, deliberately.** The venue meters
per endpoint; `Supervisor`'s limiter is one shared bucket for all of them. So this package
spends a single 60/60s budget where the venue would allow each endpoint its own. That is
the safe direction against a limit whose stated penalty is an IP block, and the shape of
`Core.Capabilities`'s `public_ceiling` — one figure, no per-endpoint dimension — cannot
express the real rule anyway. The same shape gap `historical_timeframes` already has for
per-asset-class widths.

**Sandbox is not declared here.** `capabilities/0` takes no arguments and so cannot state
a figure that differs per environment; production is what a consumer is entitled to read
as this venue's contract. `Supervisor.limits/1` halves it to `30/60s` when
`Environment.resolve/1` says `:uat`, which is the venue's own relationship between its two
columns rather than a margin invented here.

## What this file got wrong, and how it was found

The 2026-09-08 revision of this file declared **5 requests per second**, from the Market
Data FAQ:

> The Data API (HTTP) has a rate limit of 300 requests per 60 seconds.

That page is real, still says exactly that, and is **contradicted by the venue's own
per-endpoint table by a factor of five**. `300/60s` is five times `60/60s`. The FAQ figure
had in turn replaced an uncited `10 req/s` inherited from the prior adapter, so this one
number has now been wrong twice in a row, in the same direction — too permissive — and the
second time with a citation attached, which is the part worth keeping. **A citation makes a
number checkable; it does not make it right.**

The venue contradicts itself, so the choice was made by rule rather than preference. The
per-endpoint table is more specific, newer (announced in the vendor changelog 2026-08-14),
states its own units, is corroborated by a second page, and is the stricter of the two.
Fail closed.

Three earlier bullets in this file, under "What this does not cover", carried per-endpoint
numbers — *"40 requests per 2 seconds"* for orders, *"600 requests per minute"* for
futures, *"60 requests per minute for tick data"* for options — each cited to a reference
page. **Those pages contain no rate-limit text at all.** Every reference page on this
venue's site was fetched and searched; the only per-endpoint figures anywhere are the ones
recorded above. Those bullets are deleted rather than corrected: they were unsourced
numbers wearing a citation, which is worse than a missing one, and is exactly the defect
class this family keeps naming.

### How it surfaced

Not by anyone re-reading this file. The citation on the options bullet —
`.../docs/reference/option-market-data/` — **404s**; the page is `options-market-data`,
plural. That 404 was caught by `script/check_doc_sources.sh` on its first run, pulling the
thread that found everything above.

The vendor's `rate-limits` page has existed since 2026-08-14 and is listed in
`sitemap.xml`. It was never a hidden page and this was never a vendor change we failed to
notice in time — **an index diff would have surfaced it the week it appeared**, which is
the one detector mechanism `dp_exchange_core`'s vendor-change design doc scored as
actually firing. This is now the third instance supporting that conclusion, and the first
one found by the instrument rather than by a person.

## Corroborating evidence already in this repo

`Supervisor`'s own moduledoc records "the prior adapter measured 118 ms per call across 342
symbols" in production — about 8.5 req/s sustained. That is **eight times** the ceiling
documented here, and the gap is now large enough that it needs saying plainly rather than
being noted as a curiosity: either that measurement was taken across several distinct
endpoints (each with its own 60/60s counter, which would make ~8.5 req/s aggregate
legitimate and still under the 600/min global), or the prior adapter was over the
per-endpoint limit and relying on the venue not enforcing it. Nothing in this repository
distinguishes those two, and no probe available here can — it needs credentials this
repository must never hold. Recorded as an open question rather than resolved by picking
the comfortable reading.

## The MQTT streaming transport is not covered by this figure

The Data Streaming API (MQTT) has **no stated rate limit for subscribe/unsubscribe** over
the socket itself, and the server "pushes messages at a maximum rate of 3 times per second
per connection". That is a different transport with a different budget, already governed by
`@pairs_per_socket`/`@max_shards` in `Feed`, not by this figure. Note that the *HTTP*
`subscribe`/`unsubscribe` calls — which is how this package registers interest — are
ordinary market-data endpoints and do carry the 60/60s limit above.

## What is and is not machine-readable on this vendor's site

Worth recording precisely, because a wrong belief in either direction costs something: an
over-broad "it's all JS-rendered" stops verification that would have worked, and an
over-broad "it's all fetchable" produces claims nobody actually read.

**Fetchable anonymously, no browser needed:**

- `docs/rate-limits/`, `docs/market-data-api/*`, `docs/changelog/` and the other prose
  pages — fully server-rendered.
- Every `docs/reference/<endpoint>/` page's **title, HTTP method, path, prose description
  and its "Rate Limits" block**. These live in the page's `<meta>` description content,
  which is why they survive a plain `curl` even though the page around them does not.
- `sitemap.xml`, which lists all 299 pages.

**Not fetchable** — these need an authenticated browser session against the interactive
console, and no amount of `curl` will produce them:

- **Per-endpoint parameter tables**: names, types, required/optional, defaults, ranges.
  The served HTML stops at "Unauthorized: Authentication required".
- Response schemas and field-level types.

So `Rest.get_order_book/3`'s `depth` default remains uncaptured for the stock endpoint,
exactly as `negative-claims.md` records — that limitation is real and is not lifted by
anything here. What *was* wrongly believed uncapturable is the rate-limit data, which is
in the meta blocks and in `docs/rate-limits/` and was readable the whole time.

**Trailing slashes matter.** Every `docs/` URL without one answers `301` to the slashed
form. Fetching without `-L` returns a 189-byte redirect stub, which reads exactly like a
JS-rendered shell if you do not check the status code — one of the two ways the
"JS-rendered" belief above got established. The committed manifest
(`doc-sources.tsv`) records canonical slashed URLs for this reason.
