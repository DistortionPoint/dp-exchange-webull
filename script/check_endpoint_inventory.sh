#!/usr/bin/env bash
# Diffs the vendor's published endpoint reference pages against the committed capture in
# `docs/reference/webull/endpoint-pages.txt`, and reports anything that appeared or vanished.
#
# Why an index diff:
#
# `dp_exchange_core`'s vendor-change design doc audited what would have caught each way
# five vendors' documentation turned out to be wrong. A CHANGELOG diff caught nothing
# across the whole sample. An INDEX diff was the only mechanism that ever fired — and this
# venue is where that lesson cost the most. The identical sitemap search found
# `docs/rate-limits`, a per-endpoint rate-limit table that had existed since 2026-08-14,
# while this package declared a REST ceiling FIVE TIMES too permissive against a venue
# whose documented penalty is a temporary IP block. Nobody found it for weeks because
# nobody was comparing indexes.
#
# This venue publishes no machine-readable specification — `dp_exchange_gemini` does, and
# its checker diffs the OpenAPI/AsyncAPI documents directly. The sitemap is the only index
# this vendor offers, and its `docs/reference/*` pages are one per endpoint, so their set
# is the closest thing to an operation list available here. One HTTP request.
#
# A difference is a NOTICE, not a build failure. A page appearing may mean an
# `:unsupported` declaration in `capabilities/0` is now false; one vanishing may mean a
# claim this package makes has gone stale. Both need a person, and neither should block a
# merge — the result depends entirely on a third party's web server.
#
# Documentation index only. Never a venue API: tier-2 tests hit live endpoints and must
# never run on a schedule.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMITTED="$ROOT/docs/reference/webull/endpoint-pages.txt"
WORK="$ROOT/tmp/inventory_check"
SITEMAP="https://developer.webull.com/apis/sitemap.xml"

rm -rf "$WORK"
mkdir -p "$WORK"

# `tr -d '\r'` guards the CRLF trap that made a sibling checker report every entry as both
# added and removed at once.
curl -sL --max-time 60 "$SITEMAP" | tr -d '\r' \
  | grep -oE "apis/docs/reference/[^<[:space:]]*" \
  | sed 's|apis/docs/reference/||' \
  | sort -u > "$WORK/now.txt"

if [ ! -s "$WORK/now.txt" ]; then
  echo "  UNREACHABLE  the sitemap returned no reference pages — not treating that as a"
  echo "               change. A vendor being down is not a vendor changing something."
  exit 0
fi

grep -vE '^#|^$' "$COMMITTED" | sort -u > "$WORK/committed.txt"

added=$(comm -13 "$WORK/committed.txt" "$WORK/now.txt")
removed=$(comm -23 "$WORK/committed.txt" "$WORK/now.txt")

echo "== webull endpoint reference pages vs. the committed capture"

if [ -z "$added" ] && [ -z "$removed" ]; then
  echo "  OK       $(wc -l < "$WORK/now.txt" | tr -d ' ') reference pages, unchanged"
  echo
  echo "The committed capture matches the vendor's current documentation index."
  exit 0
fi

echo "  CHANGED"
if [ -n "$added" ]; then
  echo "    APPEARED since the committed capture was taken:"
  printf '      %s\n' $added
  echo "      -> a capabilities/0 :unsupported declaration may now be FALSE, and a new page"
  echo "         may carry limits or field tables this package's claims should rest on."
fi
if [ -n "$removed" ]; then
  echo "    VANISHED since the committed capture was taken:"
  printf '      %s\n' $removed
  echo "      -> a claim this package makes may now rest on nothing."
fi

echo
echo "This is a NOTICE, not a build failure. Read the vendor's page, decide what the change"
echo "means for what this package CLAIMS, fix the claim if it is now wrong, and only then"
echo "update docs/reference/webull/endpoint-pages.txt with today's date. Updating the"
echo "capture first turns this check into a rubber stamp."
exit 1
