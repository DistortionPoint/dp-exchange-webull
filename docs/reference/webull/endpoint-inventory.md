# Webull OpenAPI — endpoint inventory

**Source**: `developer.webull.com/apis/sitemap.xml`, enumerated 2026-08-31, then each
reference page fetched and its method and path read from the rendered documentation.
**Primary vendor documentation only** — not the SDK, not a wrapper, not the prior host
adapter. Each of those shows what *its author* implemented; only this shows what the venue
offers.

## Counts

**Re-checked 2026-09-03.** The table below read "5 of 85" until this release, from the
2026-08-31 capture. The vendor count has not moved; this package's coverage of it has —
this release added options, futures, event contracts, fundamentals, screeners, watchlists,
batch orders and the token lifecycle.

**Re-checked 2026-09-05.** The 2026-09-03 count read "44 of 87 `:experimental`, 43
`:unsupported`, ... 13 remain not yet ported" — accurate the morning it was written, and
stale by that same afternoon, when `get_fees/2` and `quantization/1` shipped out of
`@not_ported` without this file being told.

**Current, from `capabilities/0`, checked 2026-09-05**: 46 of 87 contract callbacks
`:experimental`, 41 `:unsupported`, of which 30 are the venue's own absence — see
`negative-claims.md` — and 11 remain not yet ported.

**Re-checked 2026-09-05, later the same day.** `dp_exchange_core` 0.1.48 added one new
optional contract callback, `coverage_by_kind/1`, and this package implemented it in the
same release — moving the total from 87 to 88 contract callbacks (47 `:experimental`, 41
`:unsupported`, unchanged) with nothing about the venue's own endpoint surface having
moved at all. Recorded as its own note rather than silently editing the count above, for
the same reason the 2026-09-03 correction got its own paragraph: the change was in this
package's contract, not in what was re-checked against the venue.

**Re-checked 2026-09-13.** The weekly index diff fired for the first time, reporting one new
vendor page: `broker-fd-api/order-executions`, taking that surface from 79 to 80 published
pages. **No claim in this package changed**, and the reasoning is in
`endpoint-pages.txt`'s own header: the Broker API is a different product tier from the
Trading + Market Data API every callback here is built on, and this package implements none
of it. The nearest-sounding claim — `{:get_trade_volume, 2}` `:unsupported` — rests on the
venue publishing no account volume *report*, not on the absence of an executions endpoint,
so a broker-tier page does not touch it. The count in the table below is left at its capture
date, as the 2026-09-03 correction established.

**Re-checked 2026-10-18.** Eleven pages appeared on the Trading + Market Data API (all
`GET`, Non-Display Solution): three news (`list-stock-news`, `list-news`, `get-news-detail`),
six fundamentals (`get-insider-holdings`, `list-insider-transactions`, `list-institutions`,
`list-institution-holdings`, `list-institution-holding-changes`, `list-economic-calendars`)
and two screeners (`get-fear-and-greed-index`, `list-stock-unusual-activities`). That takes
the surface from 85 to 96 (the 2026-10-12 `list-hot-tickers` page, served as the `hot_stocks`
screener, was also not counted in the 85). **One claim changed**: `get_news/1` now reads
`list-stock-news` instead of the LLM-generated `news/summaries/get`, and says so. The other
ten falsify no `capabilities/0` declaration; the reasoning per page is in
`endpoint-pages.txt`'s header. The table below stays at its capture date.

**Re-checked 2026-10-26.** The vendor renamed `list-hot-tickers` to `list-hot-stocks`. The
path, the response and the absent query parameters are unchanged; only the `operationId`
and one row description differ. The capture moved to `openapi/list-hot-stocks.md` and
every citation followed it. Three pages appeared, all on tiers this package implements none
of:

- `broker-market-data-api/event-forecast-using-get` and
  `broker-market-data-api/structured-target-using-get`, on Broker Market Data.
- `broker-fd-api/structured-targets-list`, on the Broker API.

`fd-events/sod-events` vanished from FD Events. **No claim changed**; the reasoning is in
`endpoint-pages.txt`'s header.

| surface | endpoints | in this package |
|---|---|---|
| **Trading + Market Data API** | **85** | most of the crypto, stock, option, futures and event-contract surface; see `capabilities/0` for the current, per-callback answer rather than a count frozen at capture time |
| Broker API (`broker-fd-api`) | 78 | 0 |
| Broker Market Data | 37 | 0 |
| FD Events | 13 | 0 |
| Custom | 12 | 0 |
| Connect | 4 | 3 — see below; only the consent redirect stays with the host |
| **total documented** | **229** | **48 of 89 contract callbacks `:experimental`, 41 `:unsupported` (31 of them the venue's own absence), per `capabilities/0` as checked 2026-10-21** |

### Connect is not all "auth", and only half of it is the host's

The pre-approved skip is the **consent leg**, not the token lifecycle — the same rule
`dp_exchange_schwab` already ships, where `Auth.refresh/2` performs the refresh in-package
and only the browser grant stays with the host.

| endpoint | side | why |
|---|---|---|
| `connect-api/get-authorization-code` | **host** | consent redirect; needs a browser and a person |
| `connect-api/connect` | **host** | same flow |
| **`connect-api/create-and-refresh-token`** | **package** | credential *use* — §6.0 places "session refresh, token rotation" here |
| **`/auth/tokens/create`**, **`/auth/tokens/check`** | **package** | same; both are implemented — see `dp_exchange_core`'s `usage-rules/auth.md` |

Sweeping all of it into "OAuth, skipped" would leave this venue unable to keep a session
alive while another venue in the same family does exactly that in-package.

The sitemap lists 247 reference pages; 18 of them are category index pages rather than
endpoints, which is why the Trading + Market Data count is 85 and not 103.

## This package once called paths the vendor no longer documents — resolved

**Historical, and settled — read the two paragraphs below before the table.** Before the
D6 migration, every endpoint this package implemented used a path that did not appear in
the vendor's current documentation:

| this package used to call | migrated to |
|---|---|
| `/openapi/instrument/crypto/list` | `/trading/instruments/crypto/profiles/list` |
| `/openapi/market-data/crypto/bars` | `/market-data/crypto/bars/list` |
| `/openapi/market-data/crypto/snapshot` | `/market-data/crypto/snapshots/list` |
| `/openapi/market-data/streaming/subscribe` | `/market-data/streaming/subscribe` |
| `/openapi/market-data/streaming/unsubscribe` | `/market-data/streaming/unsubscribe` |

Only the two streaming paths survived unchanged, and even those lost the `/openapi`
prefix. **This package no longer calls any left-hand path above.** The D6 migration moved
every call onto the right-hand, currently-documented path, and
`test/dp_exchange/webull/documented_paths_test.exs` fails the build if a source file
(outside a comment or heredoc) names an old one again. The left-hand column is historical
record now, not a live route this package depends on.

These paths were inherited from the host adapter, which read Webull's documentation at
some earlier date. This file used to say "whether the old paths still resolve is not
established here — it needs a live probe, and this repository holds no credential." That
question has since been answered.

**Live-probed unauthenticated against `api.webull.com`, 2026-09-05** (the sweep recorded
in `dp_exchange_core`'s `docs/design/2026-09-05_family-wide-defect-sweep.md` §2, W5) —
subscribe shown, and
unsubscribe probed identically with the same result on both sides:

| path | response |
|---|---|
| `POST /market-data/streaming/subscribe` (current) | `server: WEBULL OPENAPI`; `400 {"error_code":"ILLEAGAL_PARAMETER","message":"property \"x-signature-algorithm\" is required"}` — reaches the real trading backend, which validates this package's signing headers before anything else |
| `POST /openapi/market-data/streaming/subscribe` (old) | `server: APISIX`; `404 {"error_msg":"404 Route Not Found"}` — the API gateway in front of the backend has no route registered for this path at all |

The `server` header alone tells the two apart: the current paths are answered by the
backend itself (`WEBULL OPENAPI`); the old ones never get past the gateway (`APISIX`) that
sits in front of it. **The old paths do not still resolve** — the vendor retired the
routes, not just the documentation for them. Had this package still been calling them (it
is not, as of the D6 migration above), every request would have failed at the gateway
before reaching Webull's own validation — a meaningfully worse failure than "the venue
refused a malformed request": it means there was never a request to refuse.

This is the same shape as Gemini's replaced WebSocket API: an adapter built from a reading
of documentation that has since moved, with nothing watching the documentation. The
difference here is that the move has now been confirmed live rather than left open.

## Endpoints

`GET`/`POST` and path as the vendor documents them. Paths are relative to the API host.

### Trading + Market Data API — 85 endpoints

```
GET    /market-data/crypto/bars/list                crypto-bars
GET    /market-data/crypto/snapshots/list           crypto-snapshot
GET    /market-data/event-contracts/bars/list       event-bars
GET    /market-data/event-contracts/depths/list     event-depth
GET    /market-data/event-contracts/snapshots/list  event-snapshot
GET    /market-data/event-contracts/ticks/list      event-tick
GET    /market-data/fundamentals/analysis/ratings/get get-analyst-rating
GET    /market-data/fundamentals/analysis/target-prices/get get-analyst-target-price
GET    /market-data/fundamentals/balance-sheets/get financial-balancesheet
GET    /market-data/fundamentals/capital-flows/get  capital-flow
GET    /market-data/fundamentals/cash-flows/get     financial-cashflow
GET    /market-data/fundamentals/company-profiles/get get-company-profile
GET    /market-data/fundamentals/dividend-calendars/list dividend-calendar
GET    /market-data/fundamentals/earnings-calendars/list earnings-calendar
GET    /market-data/fundamentals/filings/list       filings
GET    /market-data/fundamentals/financial-alerts/get financial-alert
GET    /market-data/fundamentals/forecast-eps/get   forecast-eps
GET    /market-data/fundamentals/fund-allocations/get fund-allocation
GET    /market-data/fundamentals/fund-brief/get     fund-brief
GET    /market-data/fundamentals/fund-dividends/get fund-dividends
GET    /market-data/fundamentals/fund-files/get     fund-files
GET    /market-data/fundamentals/fund-holdings/get  fund-holdings
GET    /market-data/fundamentals/fund-net-values/get fund-net-value
GET    /market-data/fundamentals/fund-performances/get fund-performance
GET    /market-data/fundamentals/fund-ratings/get   fund-rating
GET    /market-data/fundamentals/fund-splits/get    fund-splits
GET    /market-data/fundamentals/income-statements/get financial-income
GET    /market-data/fundamentals/indicators/get     financial-indicators
GET    /market-data/fundamentals/industry-comparisons/get industry-comparison
GET    /market-data/futures/bars/list               futures-historical-bars
GET    /market-data/futures/depths/list             futures-depth-of-book
GET    /market-data/futures/footprints/list         futures-footprint
GET    /market-data/futures/snapshots/list          futures-snapshot
GET    /market-data/futures/ticks/list              futures-tick
GET    /market-data/options/bars/list               option-historical-bars
GET    /market-data/options/snapshots/list          option-snapshot
GET    /market-data/options/ticks/list              option-tick
GET    /market-data/screeners/gainers-losers/list   get-gainers-losers
GET    /market-data/screeners/high-dividend-ranks/list get-high-dividend
GET    /market-data/screeners/market-sectors/get    get-market-sectors-detail
GET    /market-data/screeners/market-sectors/list   get-market-sectors
GET    /market-data/screeners/top-actives/list      get-top-active
GET    /market-data/screeners/week52-high-low/list  get-week-52-high-low
GET    /market-data/stocks/depths/list              quotes
GET    /market-data/stocks/footprints/list          footprint
GET    /market-data/stocks/noii-bars/list           get-noii-bars
GET    /market-data/stocks/noii-snapshots/list      get-noii-snapshot
GET    /market-data/stocks/snapshots/list           snapshot
GET    /market-data/stocks/ticks/list               tick
GET    /market-data/watchlists/instruments/list     get-watchlist-instruments
GET    /market-data/watchlists/list                 get-watchlist
GET    /trading/accounts/list                       account-list
GET    /trading/activities/cash-activities/list     trade-cash-activity-by-type
GET    /trading/assets/balances/get                 account-balance
GET    /trading/assets/positions/list               account-position
GET    /trading/instruments/crypto/profiles/list    crypto-instrument-list
GET    /trading/instruments/event-contracts/categories/list event-categories-list
GET    /trading/instruments/event-contracts/events/list event-events-list
GET    /trading/instruments/event-contracts/markets/list event-market-list
GET    /trading/instruments/event-contracts/series/list event-series-list
GET    /trading/instruments/futures/contracts/list  futures-instrument-list
GET    /trading/instruments/futures/product-classes/list futures-products-class
GET    /trading/instruments/futures/product-codes/list futures-products
GET    /trading/instruments/options/contracts/list  option-contract-list
GET    /trading/instruments/stocks/profiles/list    instrument-list
GET    /trading/orders/get                          order-detail
GET    /trading/orders/historical-orders/list       order-history
GET    /trading/orders/open-orders/list             order-open
POST   /auth/tokens/check                           check-token
POST   /auth/tokens/create                          create-token
POST   /market-data/news/summaries/get              news-summary (not called since 2026-10-18)
POST   /market-data/stocks/bars/list                historical-bars
POST   /market-data/streaming/subscribe             subscribe
POST   /market-data/streaming/unsubscribe           unsubscribe
POST   /market-data/watchlists/create               create-watchlist
POST   /market-data/watchlists/delete               delete-watchlist
POST   /market-data/watchlists/instruments/add      add-watchlist-instruments
POST   /market-data/watchlists/instruments/remove   remove-watchlist-instruments
POST   /market-data/watchlists/instruments/update   update-watchlist-instruments
POST   /market-data/watchlists/update               update-watchlist
POST   /trading/orders/batch-place                  order-batch-place
POST   /trading/orders/cancel                       common-order-cancel
POST   /trading/orders/place                        common-order-place
POST   /trading/orders/preview                      common-order-preview
POST   /trading/orders/replace                      common-order-replace
```

### Added since the capture above — 2026-10-18

Not part of the 85 counted above. `GET`, Non-Display Solution. Only the first, and the
`list-hot-stocks` line at the end (added 2026-10-12 as `list-hot-tickers`, not in the 11
below), are called.

```
GET    /market-data/news/stock-news/list            list-stock-news   (get_news/1)
GET    /market-data/news/search/list                list-news
GET    /market-data/news/detail/get                 get-news-detail
GET    /market-data/fundamentals/insider-holdings/get get-insider-holdings
GET    /market-data/fundamentals/insider-transactions/list list-insider-transactions
GET    /market-data/fundamentals/institutions/list  list-institutions
GET    /market-data/fundamentals/institutions/holdings/list list-institution-holdings
GET    /market-data/fundamentals/institutions/holding-changes/list list-institution-holding-changes
GET    /market-data/fundamentals/economic-calendars/list list-economic-calendars
GET    /market-data/screeners/fear-greed-indexes/get get-fear-and-greed-index
GET    /market-data/screeners/unusual-activities/list list-stock-unusual-activities
GET    /market-data/communities/stock-rankings/list list-hot-stocks (get_screener("hot_stocks"))
```

### Category index pages (not endpoints)

`accounts`, `activities`, `assets`, `authentication`, `crypto-market-data`,
`event-market-data`, `fundamentals`, `futures-market-data`, `instruments`,
`market-data-streaming`, `news`, `options-market-data`, `order-query`, `screeners`,
`stocks-market-data`, `trading`, `watchlist`, `webull-openapi-documentation`.

Listed so the 103-versus-85 difference is checkable rather than asserted.

## Re-capturing

```
curl -s https://developer.webull.com/apis/sitemap.xml \
  | grep -oE '<loc>[^<]+' | sed 's|<loc>||' | grep '/docs/reference/'
```

Then fetch each page **with a trailing slash** (`curl -L`; the site 301s otherwise) and
read the method and path from the rendered text — the documentation is Docusaurus and
server-renders them, so no browser is needed.
