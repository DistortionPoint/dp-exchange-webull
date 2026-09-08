# Batch order placement — reference

**Source**: `https://developer.webull.com/apis/docs/reference/order-batch-place/`.
**Read and measured 2026-09-08.**

Committed rather than linked, per D13 — the prior citation for `Rest.place_orders/3`'s
`@batch_limit` and its equities-only restriction pointed at this page without committing
it, unlike every other doc-derived claim in this package.

## What the page states

> A maximum of 50 orders can be submitted once.

> Currently only stocks are supported.

`Rest.place_orders/3`'s `@batch_limit 50` and its instrument-type refusal (any request
containing a non-equity instrument is rejected before it is sent) are both this figure,
unchanged from what the code already declared — this is a citation added, not a value
changed.
