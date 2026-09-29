# Webull OpenAPI reference pages — 2026-09-29 order/market-data audit

These 28 pages are the vendor's own reference documentation, fetched verbatim, for the
endpoints this package's order-placement, order-reading, bars, options, fundamentals,
screener and news code paths were audited and corrected against on 2026-09-29 (see
`CHANGELOG.md` and the commit(s) touching `lib/dp_exchange/webull/rest.ex` and
`lib/dp_exchange/webull/subscription.ex` from that date).

## Source and fetch method

**URL pattern**: `https://developer.webull.com/apis/docs/reference/<page-name>/`, where
`<page-name>` is this file's own basename without `.md` (e.g. `order-batch-place.md` was
fetched from `https://developer.webull.com/apis/docs/reference/order-batch-place/`).
Confirmed against `docs/reference/webull/endpoint-pages.txt`'s own capture of the vendor's
sitemap, which lists the same slugs under `docs/reference/*`.

**Fetch date**: 2026-09-29, for every page in this directory.

**Method**: each page's `.md` form, with the endpoint's full OpenAPI definition (parameters,
request body schema and response schema) embedded as JSON in the page body. This is a
correction to a stale claim `negative-claims.md` made and `rest.ex`'s own `get_order_book/3`
moduledoc repeated: that the vendor's reference pages "build parameter and schema tables in
JavaScript" and a plain fetch returns only the method, path and a one-line description. That
was true of whatever capture method produced `endpoint-inventory.md`; it is not true of the
`.md` form used for this audit, which carries the complete schema without a browser. See
`rest.ex`'s `get_order_book/3` moduledoc for where this is corrected in the code itself.

## Pages, and what each backs

| page | backs |
|---|---|
| `common-order-place.md` | `place_order/3`, `place_orders/3` — `quantity`/`total_cash_amount` field names, `support_trading_session` |
| `common-order-replace.md` | `replace_order/4` — `account_id` + `modify_orders` array body shape, `order_type` amendable |
| `order-detail.md` | `get_order/3`, `get_orders/2`, `to_order/1` — the combo-group response envelope, leg field names, `status`/`side` enums |
| `order-open.md` | `get_orders/2` — `pagination_key`, no `page_size` |
| `order-history.md` | `get_orders/2` with `history: true` — `start_time`/`end_time`, `pagination_key`, 7-day default |
| `order-batch-place.md` | `place_orders/3` — the batch schema's own narrower matrix (`order_type`, `time_in_force`, `entrust_type`, `support_trading_session`) |
| `historical-bars.md` | `get_stock_bars/5` — the `{"result": [...]}` object envelope, required `volume` |
| `option-historical-bars.md` | `option_bars/5` — same object envelope, no `start_time`/`end_time` param, required `volume` |
| `futures-historical-bars.md` | futures bars via `get_historical_prices/5` — bare-array envelope, required `volume` |
| `event-bars.md` | event bars via `get_historical_prices/5` — bare-array envelope, required `volume` |
| `crypto-bars.md` | `crypto_bars/5` — bare-array envelope (already correct), the `real_time_required` contradiction |
| `option-contract-list.md` | `option_contracts/3`, `to_option_contract/2` — `underlying_symbols`, `start_date`, `strike_price_gte`/`_lte`, `pagination_key`, `expiration_date`, `settlement_method`, `expired_cycle` |
| `trade-cash-activity-by-type.md` | `get_transfers/2`, `get_transactions/2` — `pagination_key`, no `page_size`/`last_activity_id` |
| `filings.md` | `get_filings/2` — the `{symbol, category, filings: [...]}` envelope, `publish_date` |
| `dividend-calendar.md` | `get_corporate_events/2` (`:dividend`) — `ex_div_date`, `declare_date` |
| `earnings-calendar.md` | `get_corporate_events/2` (`:earnings`) — `expected_publish_date` |
| `news-summary.md` | `get_news/2` — the Server-Sent Events response shape |
| `get-top-active.md` | `get_screener/3` (`"top_actives"`) — documented `rank_type` default `VOLUME` |
| `get-week-52-high-low.md` | `get_screener/3` (`"week52_high_low"`) — no documented `rank_type` default |
| `get-market-sectors.md` | `get_screener/3` (`"market_sectors"`) — `agg_type`, `pagination_key` |
| `get-market-sectors-detail.md` | `get_screener/3` (`"market_sector"`) — `sort_by` (not `agg_type`), `pagination_key` |
| `fund-dividends.md` | `get_fundamental/4` (`:fund_dividends`) — `pagination_key`, no `count` |
| `fund-files.md` | `get_fundamental/4` (`:fund_files`) — no `count` |
| `fund-holdings.md` | `get_fundamental/4` (`:fund_holdings`) — no `count` |
| `fund-splits.md` | `get_fundamental/4` (`:fund_splits`) — no `count` |
| `instrument-list.md` | `get_symbols/2` — `category` enum is `US_STOCK` only; ETFs via `sub_category=ETF` |
| `event-snapshot.md` | `get_top_of_book/3` (`US_EVENT` refusal) — `yes_bid`/`yes_ask`/`no_bid`/`no_ask` shape |
| `subscribe.md` | `Subscription.subscribe/3` — `grab`, `category` enum vs. measured-live behaviour |

## Pages added 2026-09-29 for the spec-example conformance suite

The 55 pages below were fetched the same day as the audit above but for a different
purpose: `test/dp_exchange/webull/spec_examples_test.exs` drives every endpoint this
package calls through the vendor's own documented example (or, where none exists, a
value built strictly from the schema's documented properties) rather than a fixture
invented to agree with the code. Each fixture under `test/fixtures/spec_examples/`
cites its page and line in `test/fixtures/spec_examples/README.md`; this table only
says which function(s) each page backs.

| page | backs |
|---|---|
| `crypto-snapshot.md` | `get_price/3`, `get_top_of_book/3` (crypto snapshot) |
| `snapshot.md` | `get_price/3`, `get_top_of_book/3` (stock/ETF snapshot) |
| `option-snapshot.md` | `get_price/3` (option snapshot) |
| `futures-snapshot.md` | `get_price/3` (futures snapshot) |
| `crypto-instrument-list.md` | `get_symbols/2`, `quantization/3` (crypto) |
| `quotes.md` | `get_order_book/3` (stock depths — titled "List Stock Depths" despite the filename; confirmed by its embedded `path`) |
| `futures-depth-of-book.md` | `get_order_book/3` (futures) |
| `footprint.md` | `get_volume_profile/4` (stock) |
| `get-noii-snapshot.md` | `get_auction_imbalance/3` (snapshot) |
| `get-noii-bars.md` | `get_auction_imbalance/3` (`history: true`) |
| `tick.md` | `get_trades/3` (stock) |
| `option-tick.md` | `get_trades/3` (option) |
| `futures-tick.md` | `get_trades/3` (futures) |
| `account-list.md` | `get_accounts/2` |
| `account-balance.md` | `get_balances/2` |
| `account-position.md` | `get_positions/2` |
| `common-order-preview.md` | `preview_order/3` |
| `common-order-cancel.md` | `cancel_order/3` |
| `create-token.md` | `create_token/2` |
| `check-token.md` | `check_token/3` |
| `get-watchlist.md` | `list_watchlists/2` (titled "List Watchlists" despite the filename) |
| `get-watchlist-instruments.md` | `get_watchlist/3` (titled "List Watchlist Instruments" despite the filename) |
| `create-watchlist.md` | `create_watchlist/4` |
| `update-watchlist.md` | `update_watchlist/3` |
| `delete-watchlist.md` | `delete_watchlist/3` |
| `add-watchlist-instruments.md` | `add_watchlist_instruments/4` |
| `remove-watchlist-instruments.md` | `remove_watchlist_instruments/4` |
| `update-watchlist-instruments.md` | `sort_watchlist_instruments/3` |
| `get-analyst-rating.md` | `get_fundamental/4` (`:analyst_ratings`) |
| `get-analyst-target-price.md` | `get_fundamental/4` (`:analyst_target_prices`) |
| `financial-balancesheet.md` | `get_fundamental/4` (`:balance_sheet`), `get_financials/4` |
| `capital-flow.md` | `get_fundamental/4` (`:capital_flows`) |
| `financial-cashflow.md` | `get_fundamental/4` (`:cash_flow`), `get_financials/4` |
| `get-company-profile.md` | `get_fundamental/4` (`:company_profile`) |
| `financial-alert.md` | `get_fundamental/4` (`:financial_alerts`) |
| `forecast-eps.md` | `get_fundamental/4` (`:forecast_eps`) |
| `financial-income.md` | `get_fundamental/4` (`:income_statement`), `get_financials/4` |
| `financial-indicators.md` | `get_fundamental/4` (`:indicators`), `get_financials/4` |
| `industry-comparison.md` | `get_fundamental/4` (`:industry_comparisons`) — documents `sort_by`, added to `@fundamentals`'s allowed list this same day |
| `fund-allocation.md` | `get_fundamental/4` (`:fund_allocations`) |
| `fund-brief.md` | `get_fundamental/4` (`:fund_brief`) |
| `fund-net-value.md` | `get_fundamental/4` (`:fund_net_values`) — documents `last_date`, added to `@fundamentals`'s allowed list this same day |
| `fund-performance.md` | `get_fundamental/4` (`:fund_performances`) |
| `fund-rating.md` | `get_fundamental/4` (`:fund_ratings`) |
| `get-gainers-losers.md` | `get_screener/3` (`"gainers_losers"`) |
| `get-high-dividend.md` | `get_screener/3` (`"high_dividend_ranks"`) — documents `sort_by`, added to `@screeners`'s allowed list this same day |
| `futures-instrument-list.md` | `list_futures_contracts/2` |
| `futures-products-class.md` | `list_futures_product_classes/2` |
| `event-categories-list.md` | `list_event_categories/2` |
| `event-series-list.md` | `list_event_series/2` |
| `event-events-list.md` | `list_event_events/2` |
| `event-market-list.md` | `list_event_markets/2` |
| `event-tick.md` | `get_event_trades/3` |
| `event-depth.md` | `get_event_order_book/3` |
| `unsubscribe.md` | `Subscription.unsubscribe/3` |

`get-top-active.md` and `get-week-52-high-low.md` (already committed, above) also
document `sort_by`, added to `@screeners`'s allowed list this same day.

No vendor OpenAPI page was found for the OAuth code-exchange endpoint `oauth_token/3`
calls (`connect-api/create-and-refresh-token`): it is absent from the scratchpad capture
and a live fetch of `developer.webull.com`'s page for it returned only the description
and status-code list — the field-level schema renders client-side and was not
retrievable by this audit's fetch method. `test/fixtures/spec_examples/auth_oauth_token.json`
is built from `usage-rules/auth.md`'s own prior reading of this endpoint instead, and says
so in `test/fixtures/spec_examples/README.md`.

## Relationship to `docs/reference/webull/doc-sources.tsv`

That file is the redirect/status freshness check `script/check_doc_sources.sh` runs against
— see its own header for why. This directory is not wired into that script; it is the
verbatim evidence for the 2026-09-29 audit's citations, kept so a reader can check a claim
against the exact page text it was read from without re-fetching. Adding these URLs to
`doc-sources.tsv` as well, so the automated freshness check covers them too, is a natural
follow-up not done as part of this audit.
