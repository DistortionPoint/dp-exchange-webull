# Spec-example fixtures

Every fixture here backs a test in `test/dp_exchange/webull/spec_examples_test.exs`. Each
one is either **the vendor's own documented worked example** (a `"jsonRequestBodyExample"`
or a full response example embedded in the page's OpenAPI JSON) or, where no such example
exists, **assembled strictly from the schema's own per-property `"example"` values**, using
the schema's own JSON type for each field — never a value invented to agree with the code.
Which of the two applies is stated for every fixture below.

Pages cited as `docs/reference/webull/openapi/<name>.md` are committed in this repository.
A small number of pages this suite relies on were fetched during this same audit but not
yet committed there; those are marked `(uncommitted — see openapi/README.md)` and their
citation is against the fetched copy, not a repository path. `openapi/README.md`'s own
"Pages added 2026-09-29 for the spec-example conformance suite" table lists which function
each backs.

## Quotes, top-of-book, symbols, quantization

| fixture | page:lines | note |
|---|---|---|
| `quote_crypto_snapshot.json` | `crypto-snapshot.md:27` (path), `:168-243` (field examples) | no single worked example; assembled from per-property examples |
| `quote_stock_snapshot.json` | `snapshot.md:27,194-391` | same |
| `quote_option_snapshot.json` | `option-snapshot.md:27,171-302` | same |
| `quote_futures_snapshot.json` | `futures-snapshot.md:27,171-267` | same |
| `quote_symbols_page1.json`, `quote_symbols_page2.json` | `crypto-instrument-list.md:27` (path), `:198-270` (row fields), `:276-280` (pagination_key) | page 1 is the documented row + `pagination_key` example; page 2 omits the key per the schema's own "if absent, last page" |
| `list_instruments_page1.json`, `list_instruments_page2.json` | `crypto-instrument-list.md:27` (path), `:198-270` (row fields), `:56` (`symbols` param example `"BTCUSD,ALTUSD"` — `ALTUSD` sourced from there, not invented), `:61-72` (status enum `OC`/`CO`/`NT`), `:276-280` (pagination_key) | backs `Rest.list_instruments/2`; only `status: "OC"` has a full worked-example row on this page, so the `CO` and `NT` rows are the same documented row with the schema's own other two enum members substituted in — never a status this page does not enumerate |
| `quote_quantization_crypto.json` | `crypto-instrument-list.md:27,236-265` | the six quantization fields |
| `quote_quantization_stock.json` | `instrument-list.md:27,217-350` (committed) | AAPL row |

## Historical bars

| fixture | page:lines | note |
|---|---|---|
| `bars_crypto.json` | `crypto-bars.md:210-262` | bare array of groups; `BarDetailVo` carries no `volume` |
| `bars_futures.json` | `futures-historical-bars.md:184-257` | bare array of groups |
| `bars_event.json` | `event-bars.md:207-277` | bare array of groups |
| `bars_option.json` | `option-historical-bars.md:208-292` | `{"result": [...]}` object envelope |
| `bars_stock_grouped.json` | `historical-bars.md:232-317`, `:387-399` (range body example) | `{"result": [...]}` envelope; the vendor page's own schema example reuses `SILZ5`/futures wording on this stock-bars page — quoted verbatim, not corrected, since `decode_bar/3` keys off the caller's own symbol argument rather than this field |

## Order book depth, volume profile, auction imbalance, trades

| fixture | page:lines | note |
|---|---|---|
| `depth_order_book_stock.json` | `quotes.md:27` (path — titled "List Stock Depths" despite the filename), `:198-274,296-349` | no worked example; assembled |
| `depth_order_book_futures.json` | `futures-depth-of-book.md:~185-235` | `quote_time` documented as an integer here, unlike the stock endpoint's string |
| `depth_footprint.json` | `footprint.md:~250-290` | `time` is an ISO-8601 string with a colonless `+0000` offset, not an epoch |
| `depth_auction_imbalance.json` | `get-noii-snapshot.md:190-230` | bare object, not an array |
| `depth_auction_imbalance_bars.json` | `get-noii-bars.md:190-225` | no `paired_shares`/`imbalance_shares`/`imbalance_side` on this endpoint's own schema |
| `depth_trades_stock.json` | `tick.md:194-240` | |
| `depth_trades_option.json` | `option-tick.md:~180-220` | no `trading_sessions` param documented |
| `depth_trades_futures.json` | `futures-tick.md:175-225` | no `trading_sessions` param documented |

## Accounts, balances, positions, transfers, transactions

| fixture | page:lines | note |
|---|---|---|
| `account_list.json` | `account-list.md:145-202` | assembled from per-field examples |
| `account_balance.json` | `account-balance.md:162-386` | assembled |
| `account_position.json` | `account-position.md:166-298` | the OPTION row the schema's own examples cohere into |
| `account_transfers.json` | `docs/reference/webull/openapi/trade-cash-activity-by-type.md:222-366` | `activity_type`/`activity_sub_type` use the page's own documented DEPOSIT/ACH pairing (from the field's description table, not its standalone example, which is TRADE/BUY) |
| `account_transactions.json` | same page/lines | uses the field's own literal `TRADE`/`BUY` example |

## Orders (preview, place, batch, replace, cancel, detail, open, history)

| fixture | page:lines | note |
|---|---|---|
| `order_preview.json` | `common-order-preview.md:437-459` (request, "Equity" example, placeholders replaced with the same schema's field examples at `:145,172`), `:976,981` (response fields, no full example) | |
| `order_place.json` | `docs/reference/webull/openapi/common-order-place.md:481-499` (request), `:1031-1050` (response fields, no full example) | |
| `order_place_batch.json` | `docs/reference/webull/openapi/order-batch-place.md:421-439` (request, verbatim `jsonRequestBodyExample`), `:329-348` (response, verbatim documented example) | |
| `order_replace.json` | `docs/reference/webull/openapi/common-order-replace.md:375-399` (request, narrowed to the 4 fields a LIMIT amendment uses), `:281-299` (ack response fields) | `replace_order/4` never parses the ack body — it reads the order back via `get_order/3` |
| `order_cancel.json` | `docs/reference/webull/openapi/common-order-cancel.md:264-267` (request, verbatim), `:170-189` (response fields, unused by `cancel_order/3`) | |
| `order_detail.json` | `docs/reference/webull/openapi/order-detail.md:203-356` (field examples), `:228-236` (status enum — both `SUBMITTED` and `FILLED` variants kept, since `status_atom/1` maps `SUBMITTED` to `nil`), `:36-53` (request query) | two response variants: `response_filled`, `response_submitted` |
| `order_open_list.json` | `docs/reference/webull/openapi/order-open.md:163,234,554-561` | `status: "SUBMITTED"` (the field's own literal example) chosen for the nil-mapping case |
| `order_history_list.json` | `docs/reference/webull/openapi/order-history.md:183,255-264,574-581`, `:53,63` (start/end format) | `status: "FILLED"` for the closed-order path |

## Watchlists and auth/token

| fixture | page:lines | note |
|---|---|---|
| `auth_create_token.json` | `create-token.md:139-160` | |
| `auth_check_token.json` | `check-token.md:161-182,257-259` | |
| `auth_oauth_token.json` | no vendor OpenAPI page found (see `openapi/README.md`) | built from `usage-rules/auth.md`'s own prior reading, not a vendor schema |
| `watchlist_list.json` | `get-watchlist.md:145-171` (titled "List Watchlists" despite the filename) | |
| `watchlist_get.json` | `get-watchlist-instruments.md:153-198` (titled "List Watchlist Instruments" despite the filename) | |
| `watchlist_create.json` | `create-watchlist.md:169-179,250-253` | response is a bare `{"watchlist_id": ...}`, not a list |
| `watchlist_update.json` | `update-watchlist.md:168-186` | shared `SuccessResponseVo` |
| `watchlist_delete.json` | `delete-watchlist.md:145-159,244-246` | |
| `watchlist_add_instruments.json` | `add-watchlist-instruments.md:279-289` | |
| `watchlist_remove_instruments.json` | `remove-watchlist-instruments.md` (same shape as add) | |
| `watchlist_sort_instruments.json` | `update-watchlist-instruments.md:279-289` | |

## Fundamentals — statement-shaped kinds

| fixture | page:lines | note |
|---|---|---|
| `fund_stmt_analyst_ratings.json` | `get-analyst-rating.md:166-210` | |
| `fund_stmt_analyst_target_prices.json` | `get-analyst-target-price.md:166-205` | |
| `fund_stmt_balance_sheet.json` | `financial-balancesheet.md:186-435` | |
| `fund_stmt_capital_flows.json` | `capital-flow.md:174-218` | |
| `fund_stmt_cash_flow.json` | `financial-cashflow.md:186-306` | |
| `fund_stmt_company_profile.json` | `get-company-profile.md:166-223` | |
| `fund_stmt_financial_alerts.json` | `financial-alert.md:166-212` | |
| `fund_stmt_forecast_eps.json` | `forecast-eps.md:164-199` | bare array response |
| `fund_stmt_income_statement.json` | `financial-income.md:186-370` | |
| `fund_stmt_indicators.json` | `financial-indicators.md:186-228` | nested `{currency, values: {<metric>: [{fiscal_year, fiscal_period, value}]}}` shape |
| `fund_stmt_industry_comparisons.json` | `industry-comparison.md:174-234` | `data` array of comparison items |

All eleven above are assembled from each page's own per-property `example` values — none of
these pages carries a single full worked response.

## Fund reports, calendars, filings, news

| fixture | page:lines | note |
|---|---|---|
| `fund_report_allocations.json` | `fund-allocation.md:168-215` | assembled |
| `fund_report_brief.json` | `fund-brief.md:168-215` | assembled; bare object |
| `fund_report_dividends.json` | `docs/reference/webull/openapi/fund-dividends.md:182-216` | assembled; `page_1`/`page_2` pair drives the `pagination_key` walk, page 1's key is the page's own documented example |
| `fund_report_files.json` | `docs/reference/webull/openapi/fund-files.md:167-193` | assembled |
| `fund_report_holdings.json` | `docs/reference/webull/openapi/fund-holdings.md:167-202` | assembled |
| `fund_report_net_values.json` | `fund-net-value.md:191-205,58-66` | assembled |
| `fund_report_performances.json` | `fund-performance.md:167-201` | assembled; bare object |
| `fund_report_ratings.json` | `fund-rating.md:169-190` | assembled |
| `fund_report_splits.json` | `docs/reference/webull/openapi/fund-splits.md:167-199` | assembled |
| `fund_report_dividend_calendar.json` | `docs/reference/webull/openapi/dividend-calendar.md:168-225` | assembled |
| `fund_report_earnings_calendar.json` | `docs/reference/webull/openapi/earnings-calendar.md:168-212` | assembled |
| `fund_report_filings.json` | `docs/reference/webull/openapi/filings.md:164-205` | real worked example — Apple 8-K, `{symbol, category, filings: [...]}` envelope |
| `fund_report_news_sse.json` | `docs/reference/webull/openapi/news-summary.md:195` | the vendor's own worked SSE stream, verbatim: a `meta` event then three `text` chunks |

## Screeners and futures reference data

| fixture | page:lines | note |
|---|---|---|
| `screener_gainers_losers.json` | `get-gainers-losers.md` (`ScreenerStockVo`, 17 fields) | assembled |
| `screener_top_actives.json` | `docs/reference/webull/openapi/get-top-active.md` (`MostActiveStockVo`) | assembled |
| `screener_high_dividend.json` | `get-high-dividend.md` (`HighDividendStockVo`, 20 fields) | assembled |
| `screener_week52.json` | `docs/reference/webull/openapi/get-week-52-high-low.md` (`Week52StockVo`) | assembled |
| `screener_market_sectors.json` | `docs/reference/webull/openapi/get-market-sectors.md` | assembled; nested `data: [MarketSectorsVo]` envelope with `pagination_key` |
| `screener_market_sector_detail.json` | `docs/reference/webull/openapi/get-market-sectors-detail.md` | assembled; `data: [SectorDetailStockVo]` envelope with `pagination_key` |
| `futures_contracts.json` | `futures-instrument-list.md` (`FuturesInstrumentVo`, 19 fields) | assembled; `product_class_id` is a JSON integer per the schema |
| `futures_product_classes.json` | `futures-products-class.md` (`FuturesProductClass`) | assembled |

## Event-contract reference data and options

| fixture | page:lines | note |
|---|---|---|
| `event_categories.json` | `event-categories-list.md:150-165` | assembled |
| `event_series.json` | `event-series-list.md:197-244` | assembled |
| `event_events.json` | `event-events-list.md:187-233` | assembled; `status: "inactive"` is the field's own literal (lowercase) example |
| `event_markets.json` | `event-market-list.md:218-360` | assembled |
| `event_trades.json` | `event-tick.md:184-246` | assembled |
| `event_order_book.json` | `event-depth.md:187-306` | assembled; the vendor's own `AskBid` example is reused identically across all four sides (yes/no × bid/ask) — that is what the schema documents, not a fixture-authoring shortcut |
| `option_contract_list.json` | `docs/reference/webull/openapi/option-contract-list.md:293-382,449` | the one documented contract (a call); used for both `get_option_chain/3` and `get_option_expirations/3` since they hit the same endpoint |

## Streaming — HTTP subscribe/unsubscribe and protobuf

| fixture | page:lines | note |
|---|---|---|
| `stream_subscribe_request.json` | `docs/reference/webull/openapi/subscribe.md:286-298` | literal `jsonRequestBodyExample` |
| `stream_subscribe_response.json` | `docs/reference/webull/openapi/subscribe.md:216-218` | `{}` — the page documents `200: OK` with no body schema |
| `stream_unsubscribe_request.json` | `unsubscribe.md` | literal `jsonRequestBodyExample` |
| `stream_unsubscribe_response.json` | `unsubscribe.md` | `{}`, same reasoning as the subscribe response |
| `stream_invalid_symbol_rejection.json` | `docs/reference/webull/openapi/subscribe.md:241-262` (generic 417 envelope shape) + `lib/dp_exchange/webull/subscription.ex`'s own moduledoc (measured `INVALID_SYMBOL` text, DpCryptoManagement issue #24) | `subscribe.md`'s own 417 example uses a different code and is not representative of this specific rejection |
| `stream_invalid_session_rejection.json` | `lib/dp_exchange/webull/subscription.ex` (quoted verbatim, dp-exchange-core issue #30) | not on any vendor page — measured live |
| `stream_oversubscribed_rejection.json` | `lib/dp_exchange/webull/subscription.ex` (`TOO_MANY_SYMBOLS_SUBSCRIPTION` — code only pattern-matches the `error_code`) | the `message` text is illustrative only, not a literal vendor string |
| `stream_snapshot_fields.json` | `docs/reference/webull/streaming-api.md:161-165,183-195` | schema-derived — protobuf has no literal wire example |
| `stream_tick_fields.json` | `docs/reference/webull/streaming-api.md:161-165,197-203` | schema-derived |
| `stream_quote_fields.json` | `docs/reference/webull/streaming-api.md:167-181` | schema-derived; includes `order`/`broker` sub-fields on the first ask, not just the simplified two-field `AskBid` |

## Pages relied on but not yet committed under `docs/reference/webull/openapi/`

`crypto-snapshot.md`, `snapshot.md`, `option-snapshot.md`, `futures-snapshot.md`,
`crypto-instrument-list.md`, `quotes.md`, `futures-depth-of-book.md`, `footprint.md`,
`get-noii-snapshot.md`, `get-noii-bars.md`, `tick.md`, `option-tick.md`, `futures-tick.md`,
`account-list.md`, `account-balance.md`, `account-position.md`, `common-order-preview.md`,
`common-order-cancel.md`, `create-token.md`, `check-token.md`, `get-watchlist.md`,
`get-watchlist-instruments.md`, `create-watchlist.md`, `update-watchlist.md`,
`delete-watchlist.md`, `add-watchlist-instruments.md`, `remove-watchlist-instruments.md`,
`update-watchlist-instruments.md`, `get-analyst-rating.md`, `get-analyst-target-price.md`,
`financial-balancesheet.md`, `capital-flow.md`, `financial-cashflow.md`,
`get-company-profile.md`, `financial-alert.md`, `forecast-eps.md`, `financial-income.md`,
`financial-indicators.md`, `industry-comparison.md`, `fund-allocation.md`, `fund-brief.md`,
`fund-net-value.md`, `fund-performance.md`, `fund-rating.md`, `get-gainers-losers.md`,
`get-high-dividend.md`, `futures-instrument-list.md`, `futures-products-class.md`,
`event-categories-list.md`, `event-series-list.md`, `event-events-list.md`,
`event-market-list.md`, `event-tick.md`, `event-depth.md` and `unsubscribe.md` **were
committed as part of this same audit** — see `docs/reference/webull/openapi/README.md`'s
"Pages added 2026-09-29 for the spec-example conformance suite" section. This file cites
them by bare filename either way; all now resolve under that directory.
