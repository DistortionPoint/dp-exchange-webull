# Get News Detail

Captured 2026-10-18 from `https://developer.webull.com/apis/docs/reference/get-news-detail.md`
(the tables the fetch returned for the page's OpenAPI definition, not the raw JSON). **Not
used by this package**: `Core.Types.NewsItem` carries a summary, not an article body, and
the contract has no callback for fetching one. Recorded as the page `list-stock-news`'s
`news_id` is meant to feed.

`GET https://api.sandbox.webull.com/market-data/news/detail/get`
Operation `getNewsDetail`, tag News. Retrieves the complete content of a US market news
article by its ID.

## Query parameters

| Name | Required | Description | Example |
|---|---|---|---|
| `news_id` | Yes | Unique identifier of the news item; obtain it from the news list or search APIs. | `20261008-001` |

Header parameters: the same nine signing headers as `list-stock-news.md`.

## 200 response (`NewsDetailVo`)

`news_id`, `title`, `content` (the full article body), `source`, `url`, `publish_time` (ISO
8601 with offset), `sentiment` (`POSITIVE` | `NEGATIVE` | `NEUTRAL`), `related_symbols`
(array of strings).

Errors: `401`, `417`, `500`, each `{error_code, message}`. The page states no rate limit.
