# List Stock News

Captured 2026-10-18 from `https://developer.webull.com/apis/docs/reference/list-stock-news.md`.
This is the tables the fetch returned for the page's OpenAPI definition, not the raw
OpenAPI JSON the older captures in this directory hold. The rendered HTML page has no
parameter table at all; only the `.md` form carries them.

`GET https://api.sandbox.webull.com/market-data/news/stock-news/list`
Operation `listStockNews`, tag News. Section: Market Data API > Non-Display Solution (for
Retail/Buy-side Inst) > News.

Returns news related to a single stock. You can filter by sentiment, and results are
paginated with a cursor.

## Query parameters

| Name | Required | Type | Description | Allowed values / default | Example |
|---|---|---|---|---|---|
| `symbol` | Yes | string | Stock symbol. | | `TSLA` |
| `category` | No | string | Market category of the news data. | Enum `US_STOCK`, `HK_STOCK`. Default `US_STOCK` | `US_STOCK` |
| `sentiment` | No | string | Filters by sentiment. If omitted, all news is returned. | Enum `POSITIVE`, `NEGATIVE`, `NEUTRAL` | `POSITIVE` |
| `pagination_key` | No | string | Key from the previous response used to fetch the next page. Omit it for the first request. | | `eyJ2IjoxLCJsYXN0SWQiOiI5MTMyNDQ3NjkiLCJwYWdlSW====` |

Header parameters (all required): `x-app-key`, `x-app-secret`, `x-timestamp` (ISO 8601 UTC,
`YYYY-MM-DDThh:mm:ssZ`), `x-signature-version` (default `1.0`), `x-signature-algorithm`
(default `HMAC-SHA1`), `x-signature-nonce`, `x-access-token`, `x-version` (`v2` or `v3`,
default `v3`), `x-signature`.

## 200 response (`StockNewsResultVo`, `application/json`)

| Field | Type | Required | Description |
|---|---|---|---|
| `symbol` | string | No | Stock symbol. Example `TSLA` |
| `data` | array of `NewsItemVo` | Yes | List of news items. |
| `pagination_key` | string | No | Cursor for the next page. If absent, this is the last page. |

`data[]` (`NewsItemVo`):

| Field | Type | Description | Example / enum |
|---|---|---|---|
| `news_id` | string | Unique news identifier. | `20261008-001` |
| `title` | string | News headline. | `NVIDIA Announces New AI Chip` |
| `summary` | string | Short summary of the article. | `NVIDIA unveiled its next-generation AI chip at GTC.` |
| `source` | string | Name of the news source. | `Reuters` |
| `url` | string | URL of the original article. | `https://www.example.com/news/nvidia-ai-chip` |
| `publish_time` | string | Publish time, ISO 8601 with time zone offset. | `2026-10-08T09:30:00.000-04:00` |
| `sentiment` | string | Sentiment classification. | `POSITIVE`, `NEGATIVE`, `NEUTRAL` |
| `related_symbols` | array of string | Other stock symbols related to the article. | `["NVDA", "AMD"]` |

## Errors

All error bodies are `{error_code, message}`. `401` `UNAUTHORIZED` ("Insufficient
permission"), `417` `INVALID_PARAMETER` (a business-logic error; the page's example message
"Parameter error, phone" does not match this endpoint's parameters), `500` `SYSTEM_ERROR`.

## Notes the fetch recorded

- Pagination: first request without `pagination_key`; send the returned key for the next
  page; an absent key is the last page. No page size is documented.
- The page states no rate limit.
- The `related_symbols` item example is a JSON-formatted string rather than a single symbol,
  which is why this package refuses a `related_symbols` entry that is not ticker-shaped.
