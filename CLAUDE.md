# CLAUDE.md

Guidance for Claude Code working in this repository.

**ABSOLUTE RULES**:
***THIS IS ELIXIR. It is Functional, Parallel, and Concurrent. You CAN NOT treat this like Python, Ruby, or Javascript.
1. ALL operations MUST be concurrent/parallel in a single message
2. Prefer Agents over MCPs
3. **NEVER save working files, text/mds and tests to the root folder**
4. ALWAYS organize files in appropriate subdirectories
5. ALWAYS do CI Checks before COMMIT
6. NEVER COMMIT OR PUSH without confirmation
7. MANAGE YOUR CONTEXT
8. ALL TESTS MUST PASS — 0 failures allowed
9. ALL Credo issues must pass. Not just some, not just critical, ALL
10. NEVER USE PERL or PYTHON
11. NEVER USE the SYSTEM TMP. NEVER MEANS NEVER. DO NOT EVER DO THIS
12. NEVER USE GIT. NEVER MEANS NEVER. DO NOT EVER DO THIS
13. NEVER USE KILL/PKILL UNSCOPED, only scoped to your specific things. NEVER MEANS NEVER. DO NOT EVER DO THIS

**THIS REPO IS PUBLIC.** Every commit is a public commit, and git history is not
retractable. Verify `.gitignore` covers `.env*` (except `.env.sample`) and `.mcp.json`
before anything is staged. A leaked credential is not fixed by a later commit.

## Project Overview

`dp_exchange_webull` is the Webull venue package for the **DpExchange** family. It
implements `DpExchange.Core.Venue` — the same facade every venue in the family exposes —
and nothing else in this package is public API.

**Status: EXPERIMENTAL.** It has not run in production. Maturity is declared per endpoint
through `capabilities/0`, not per package.

## The one rule everything else follows from

**The facade is the boundary, and nothing crosses it.** This package's transport, rate
limiting, signing, session handling and supervision are internal. A consumer cannot tell
from the facade how data arrives here, and must not be able to.

When a change would let a consumer learn *how* this venue works, that change is wrong.

Concretely, none of these may appear in a return value or an argument: socket handles,
connection pools, WebSockex state, rate-limit buckets, signing keys, retry timers,
supervisor pids.

## What this package owns that Core does not

- **Its transport, and it is two of them at once.** Market data arrives over **MQTT 3.1.1
  carried on a WebSocket**; subscriptions are **HTTP** calls. The two are joined only by a
  `session_id` this package invents and sends to both. A consumer calls `subscribe/2` with
  symbols and learns none of that.
- **Its MQTT implementation.** Hand-rolled packet encode/decode rather than Tortoise311,
  because Tortoise ships TCP and SSL transports only and its transport behaviour models an
  active-mode byte stream in 16 callbacks — the wrong shape for MQTT over WebSocket. The
  moduledoc recording that is carried verbatim.
- **Its protobuf decoding.** Three of the five topics are protobuf, one is JSON, one is
  empty. The schema is six messages of nothing but strings, so it is decoded here rather
  than by taking a dependency and a codegen step. The prior adapter called `Jason.decode/1`
  on protobuf payloads, which would have dropped every quote even after the connection and
  subscription were fixed.
- **Its connection budget.** The venue allows **5 concurrent connections per App Key**,
  holds session state for about a minute after a disconnect, and pushes at most **3
  messages per second per connection**. Sharding, backoff and reconnect pacing are all
  decided here, against those numbers. A consumer cannot cause a sixth socket.
- **Re-subscribing after a reconnect.** The venue does not restore subscriptions when a
  connection drops. That bookkeeping is this package's, not the consumer's — noticing a
  reconnect and replaying subscriptions through a facade designed to hide reconnects would
  defeat the facade.
- **Its request signing.** Credentials arrive as function arguments; this package signs
  with them and keeps nothing. The host authenticates and chooses the scheme.

## Essential Commands

```bash
mix deps.get
mix compile
mix test                            # tier 1 — in-process fakes, every CI run
mix test --include tier2            # tier 2 — LIVE public endpoints, BY HAND ONLY
mix test --cover                    # threshold 90
mix quality                         # format + credo --strict + dialyzer + sobelow
```

**Never run tier-2 tests on a schedule.** They hit Webull's live public API, and a
venue that sees a package polling it on a timer will rate-limit or block.

## Documentation is the source, not the host adapter

Every claim this package makes about Webull comes from **Webull's own API
documentation**, committed to `docs/reference/webull/`. Not a GitHub SDK, not a
community write-up, not another client library.

The host's adapter is a *prior reading* of that documentation and is valuable for the
production behaviour it encodes, but on conflict the documentation wins and the
divergence gets recorded. `docs/reference/webull/extraction-pin.md` records exactly
which host state was read, including that the working tree was dirty.

## Testing Strategy

Four tiers; only the first two ever run unattended:

1. **In-process fakes** — every CI run. The default.
2. **Live public endpoints** — by hand, tagged `:tier2`, excluded from CI.
3. **Authenticated, read-only** — needs credentials this repo must never hold.
4. **Money-moving** — never a test. Answered in production, which is what moves an
   endpoint to `:proven`.

Tests must be `async: true` safe. Any seam a consumer's tests need to vary resolves
through `DpExchange.Core.Config`, per process — a node-wide switch makes this package
unusable in a consumer's async suite.

**The fake satisfies the same conformance suite as the real adapter.** It may be less
capable than the real venue; it must never be *differently* capable. Where it cannot
answer, it errors — it never returns an empty success for something unsupported, and it
never rewrites a value the caller supplied.

## Code Quality Requirements

- Coverage threshold 90
- `mix credo --strict` clean — ALL issues
- `mix dialyzer` clean
- `@moduledoc` and `@doc` on everything public; `@spec` on every public function
- Formatted at `line_length: 98`

### When a moduledoc records an incident

Some code here exists because something failed in production. Where a moduledoc explains
*why* a guard is there, that explanation is the most valuable thing in the file. Carry it
when the code moves or is copied. Do not compress it away.

## Critical Development Principles

### Fail closed; never substitute

The recurring failure in this family is **a nearby substitute where there should be an
error**: a missing granularity becoming the closest one, a missing endpoint becoming
synthetic data, an unknown source counting as evidence. Every value stays plausible and
only the meaning is wrong, which is why it does not surface as a failure.

Return `:error`. Raise. Refuse. Do not guess a value that looks right.

### Declare what you measured, not what you assume

A capability declaration is a claim about a real venue. If it was measured, say when and
against what — `measured_at` and `measured_against` exist for this. If it was read from
documentation and never probed, say that too. An unlabelled number is worse than a
missing one.

### Definition of "Done"

- Tests passing, 0 failures
- `mix quality` clean AND `mix test --cover` green — neither implies the other
- Public functions documented with `@doc` and `@spec`
- CHANGELOG entry where behaviour changed
- The design doc's checklist item marked, with what was found

## Documentation Standards

```
docs/design/            # Active design documents
docs/design/closed/     # Completed, with a retrospective appended
docs/design/ideas/      # Non-blocking discoveries; no date prefix
docs/reference/webull/# Webull's own API documentation, committed verbatim
```

Design docs are `YYYY-MM-DD_design-topic-name.md`. Status is one of
`Draft → In Review → Approved → Implementing → Implemented`.

Point at `docs/design/` as a directory. Do not reference individual design documents or
work items from this file.

### Consumer documentation

`usage-rules.md` ships inside the Hex tarball and is what a consuming agent reads. It is
not optional and it is not the README.
