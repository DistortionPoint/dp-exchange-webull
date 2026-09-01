# Every negative this package makes, and what was checked

**Audited 2026-09-01.** A negative is any statement that the venue *lacks* something: a
`:unsupported` declaration, a "there is no…", a "does not support…". §0's rule says a value
must never be substituted for a missing one; this is the same rule pointed at documentation.
**An unverified negative is a substitution exactly like an invented value.**

This package produced the family's clearest example of the failure mode, and it is worth
stating up front: **three separate refusals were true statements about the *stock* endpoint,
restated as claims about the venue.** Webull publishes a separate options endpoint beside
each one.

## Sources

| source | what it is | read |
|---|---|---|
| **inventory** | `docs/reference/webull/endpoint-inventory.md` — 229 documented endpoints from `developer.webull.com/apis/sitemap.xml` | 2026-08-31 |
| **pages** | the vendor's reference pages, **rendered in a browser** — see below | 2026-09-01 |
| **futures/events** | `docs/reference/webull/futures-and-event-contracts.md` | 2026-09-01 |

**The pages had to be rendered.** Webull's reference pages build their parameter and schema
tables in JavaScript: a plain fetch returns the method, the path and a one-line description
and nothing else — which is exactly what the 2026-08-31 inventory captured, and why it has
paths but no parameters. **A capture that stops at the method and path looks complete and
cannot be implemented from.**

## The negatives

| claim | verified against | verdict |
|---|---|---|
| **"`US_OPTION` is refused: the vendor states the stock snapshot does not serve it"** | pages, 2026-09-01 | **WAS WRONG, corrected.** True of the *stock* snapshot. The venue publishes `/market-data/options/snapshots/list` |
| **The same claim on bars** | pages, 2026-09-01 | **WAS WRONG, corrected.** `/market-data/options/bars/list` exists |
| **The same claim on the tape** | pages, 2026-09-01 | **WAS WRONG, corrected.** `/market-data/options/ticks/list` exists |
| No greeks | pages, 2026-09-01 | **holds, and this one is real.** No Webull endpoint publishes a delta, gamma or implied volatility. Computing them needs a rate and a volatility surface the venue does not publish either — every number would be this package's model presented as the venue's |
| No crypto depth | pages | **holds.** The crypto snapshot publishes a top of book and nothing beneath it |
| No crypto volume anywhere | pages | **holds.** Which is why a crypto quote's volume is `nil` and never `0` — zero would claim a genuinely flat interval |
| No event-contract order book in `Types.OrderBook`'s shape | pages, 2026-09-01 | **holds, and it is a shape mismatch rather than an absence.** The venue returns four arrays — `yes_bids`, `yes_asks`, `no_bids`, `no_asks` — and the contract's type has two sides. `get_event_order_book/2` returns the venue's own |
| No event-contract tape in `Types.Trade`'s shape | pages, 2026-09-01 | **holds, same reason.** An event tick has a `yes_price` *and* a `no_price` and a side of `yes`/`no` |
| No split calendar for equities | pages, 2026-09-01 | **holds.** `fund-splits` covers funds and nothing covers equities, which is why `get_corporate_events/1` has no `:split` kind — it would be answerable for some symbols and silently empty for the rest |
| No payment methods, transfers, allowlist, networks | inventory, 2026-09-01 | **holds.** Funding happens in Webull's own applications, which need a person. `/trading/activities/cash-activities/list` *reports* money that moved |
| No FX, no notional valuation, no custody, no fee promos | inventory, 2026-09-01 | **holds** |
| No streaming for crypto beyond the documented MQTT surface | prior measurement, 2026-08-10 | **holds as measured.** Recorded in `mqtt_packet.ex`'s moduledoc |
| Batch place is equities-only and caps at 50 | pages, 2026-09-01 | **holds — and it is the venue's own limit, enforced here.** Its page also says the endpoint is not available to every client |
| **The `/openapi/…` path prefix** | inventory | **the inverse case.** Five endpoints used a prefix that appears nowhere in current documentation, inherited from an older site, and **the whole suite passed the entire time** because no test asserted a path. `documented_paths_test.exs` exists so that cannot recur |

## Two lessons, both learned here

**A refusal about one endpoint is not a claim about the venue.** Three of these were the
stock endpoint's real limitation, restated one level too broadly. The tell is the wording:
"the vendor states the stock snapshot does not serve it" is *correct* and was still used to
justify a refusal that was not.

**Render the page.** The parameter tables that this package needed did not exist in the
fetched HTML. An inventory built from method and path alone is a real document that cannot
be implemented from, and looks finished.
