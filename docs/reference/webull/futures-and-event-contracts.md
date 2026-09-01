# Webull futures and event contracts — parameters and response fields

**Captured 2026-09-01** from `developer.webull.com/apis/docs/reference/…`, by rendering each
page in a browser and reading the parameter and schema tables.

**Why a browser was needed.** The tables are rendered by the page's own JavaScript. A plain
fetch of these URLs returns the endpoint's method, path and one-line description and
**nothing else** — which is exactly what the 2026-08-31 inventory captured, and why that
inventory has paths but no parameters. A capture that stops at the method and path looks
complete and cannot be implemented from.

Every endpoint below is `GET`, and the sandbox host is `https://api.sandbox.webull.com`.

## Futures

### `/market-data/futures/snapshots/list`

| parameter | required | notes |
|---|---|---|
| `symbols` | yes | comma-separated, **max 20** |
| `category` | yes | `US_FUTURES` only |

Response fields: `symbol`, `instrument_id`, `price`, `open`, `high`, `low`, `pre_close`,
`volume`, `change`, `change_ratio`, `last_trade_time` (**int64 ms**), `open_interest`,
`quote_time` (**int64 ms**), `bid`, `ask`, `bid_size`, `ask_size`, `settle_date`,
`settle_price`.

**`pre_close` is the previous *settlement*, not a close**, and `change` is measured against
it. A futures settlement price is set by the exchange and is not the last trade.

### `/market-data/futures/bars/list`

| parameter | required | notes |
|---|---|---|
| `symbols` | yes | comma-separated, max 20 |
| `category` | yes | `US_FUTURES` |
| `timespan` | yes | `M1 M5 M15 M30 M60 M120 M240 D W M Y` |
| `count` | yes | default 200, **max 1200** |

**No `real_time_required` on this endpoint**, unlike the stock and event bars. Rows:
`symbol`, `instrument_id`, `result[]` of `time` (ISO-8601 with offset), `open`, `close`,
`high`, `low`, `volume`.

### `/market-data/futures/ticks/list`

`symbol` (singular), `category`, `count` (default 200, max 1200). Rows: `symbol`,
`instrument_id`, `result[]` of `time` (**ms epoch as a string**), `price`, `volume`,
`side` — "Such as: B S G L N", the same five-code vocabulary the stock tape uses.

### `/market-data/futures/depths/list`

`symbol`, `category`, `depth` (**1–10**, required). Rows: `symbol`, `instrument_id`,
`quote_time` (int64 ms), `asks[]` and `bids[]` of `price` and `size`.

The page states level 1 must be requested from the snapshot instead.

### `/market-data/futures/footprints/list`

`symbols`, `category`, `timespan` (`S5 S15 M1 M5 M30`), `count` (default 200, max 1200),
`real_time_required` (required), `trading_sessions` (`PRE RTH ATH OVN`; the page says OVN
is not supported).

Rows carry `total`, `delta`, `buy_total`, `sell_total`, and `buy_detail` / `sell_detail` as
**price-keyed maps** — the same shape as the stock footprint.

*The page's `category` description reads "Only US_STOCK type queries are supported" while
its enum lists only `US_FUTURES`. The enum is what this package sends; the sentence appears
to be copied from the stock page.*

### `/trading/instruments/futures/contracts/list`

`category` (required, `US_FUTURES`), and **either `symbols` or `code`** — the page states
one of the two must be present. `status` filters `OC` (tradable) / `CO` (liquidate only) /
`NT` (non-tradable), default `OC`.

Response: `symbol`, `instrument_id`, `exchange_code`, `code`, `name`, `product_class_id`,
`product_class_name`, `status`, `currency`, `contract_month` (`yyyyMM`), `settlement_date`,
`size` (**contract multiplier**), `unit`, `min_tick`, `first_notice_date`,
`last_notice_date`, `first_trading_date`, `last_trading_date`.

**`instrument_id` on a continuous contract is the continuous contract's**, and the page says
placing an order needs the actual month contract's id instead.

### `/trading/instruments/futures/product-classes/list`

`category` (required). Returns `product_class_id` and `product_class_name`.

## Event contracts

Category is `US_EVENT`, and it is **optional** on all four market-data endpoints — the
venue defaults it.

### `/market-data/event-contracts/snapshots/list`

`symbols` (max 100), `category`. Response: `instrument_id`, `symbol`, `name`, `price`,
`volume`, `last_trade_time` (int64 ms), `open_interest`, and **four sides**: `yes_bid`,
`yes_bid_size`, `yes_ask`, `yes_ask_size`, `no_bid`, `no_bid_size`, `no_ask`, `no_ask_size`.

### `/market-data/event-contracts/bars/list`

`symbols` (max 100), `category`, `timespan` (`M1 M5 M15 M30 M60 M120 M240 D`), `count`,
`real_time_required` (**required**). Rows: `instrument_id`, `symbol`, `result[]` of `open`,
`close`, `high`, `low`, `volume`, `time`.

**The page does not say which side these prices are.** A binary market has a YES price and a
NO price and they sum to one; the schema names neither.

### `/market-data/event-contracts/ticks/list`

`symbol`, `category`, `count` (default **30**, max 1200). Rows: `instrument_id`, `symbol`,
`result[]` of `time`, **`yes_price`**, **`no_price`**, `volume`, `side` (`yes`/`no` — "side
for the taker"), `trade_id`.

**`side` is `yes`/`no`, not buy/sell.**

### `/market-data/event-contracts/depths/list`

`symbol`, `category`, `depth` (default 10). Rows: `instrument_id`, `symbol`, `quote_time`,
and **four arrays**: `yes_bids`, `yes_asks`, `no_bids`, `no_asks`.

The page notes that in a binary market a yes bid at X equals a no ask at 100−X, and still
returns all four.

### `/trading/instruments/event-contracts/categories/list`

**No parameters.** Returns `category_id`, `category_code`, `category_name`.

### `/trading/instruments/event-contracts/series/list`

`category` (`ECONOMICS FINANCIALS POLITICS ENTERTAINMENT SCIENCE_TECHNOLOGY CLIMATE_WEATHER
TRANSPORTATION CRYPTO SPORTS`), `symbols` (max 100), `pagination_key`. Returns
`data[]` of `category`, `series_id`, `symbol`, `name`, `frequency` (`HOURLY DAILY WEEKLY
MONTHLY ANNUAL ONE_OFF CUSTOM`), plus a top-level `pagination_key` — **absent means this was
the last page**.

### `/trading/instruments/event-contracts/events/list`

`series_symbol` (**required**), `symbols`, `status` (`ACTIVE`/`INACTIVE`). Returns
`series_id`, `symbol`, `name`, `status`, `short_name`, `strike_date`, `strike_period`,
`mutually_exclusive`.

### `/trading/instruments/event-contracts/markets/list`

`series_symbol`, `event_symbol`, `symbols` (max 100), `expiration_date_after`,
`pagination_key`. Returns `data[]` of `series_id`, `series_symbol`, `series_name`,
`event_symbol`, `event_name`, `instrument_id`, `symbol`, `name`, `yes_condition`,
`last_trading_date`, `status` (`NOT_SET LISTING DELISTING OTHER UNRECOGNIZED`),
`tradable_status` (`OC CO NT`), `can_close_early`, `expected_exp_date`, `latest_exp_date`,
`payout_date`, `fractionable`, and `price_ranges[]` of `start`, `end`, `step`.

**`status` and `tradable_status` are different fields with different vocabularies**, and a
market can be `LISTING` and `NT` at the same time.
