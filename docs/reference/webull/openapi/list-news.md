# List News

Captured 2026-10-18 from `https://developer.webull.com/apis/docs/reference/list-news.md`
(the tables the fetch returned for the page's OpenAPI definition, not the raw JSON). **Not
used by this package**: it is a keyword search over US market news, and the contract's
`get_news` takes symbols. Recorded because its arrival, with `list-stock-news`, is what
showed the old `news/summaries/get` source was no longer the venue's only news endpoint.

`GET https://api.sandbox.webull.com/market-data/news/search/list`
Operation `listNews`, tag News. Searches US market news by keyword, with an optional date
range and cursor pagination.

## Query parameters

| Name | Required | Description |
|---|---|---|
| `keyword` | Yes | Search term, up to 100 characters. |
| `start_date` | No | Start of the range, `yyyy-MM-dd`. Defaults to 7 days ago. |
| `end_date` | No | End of the range, `yyyy-MM-dd`. Defaults to today. |
| `pagination_key` | No | Cursor from the previous response. Omit on the first request. |

Header parameters: the same nine signing headers as `list-stock-news.md`.

## 200 response (`NewsSearchResultVo`)

`keyword` (string, the keyword used), `data` (required array of items), `pagination_key`
(absent on the last page). Each item: `news_id`, `title`, `summary`, `source`, `url`,
`publish_time` (ISO 8601 with offset), `sentiment` (`POSITIVE` | `NEGATIVE` | `NEUTRAL`),
`related_symbols` (array of strings).

Errors: `401`, `417`, `500`, each `{error_code, message}`. The page states no rate limit.
