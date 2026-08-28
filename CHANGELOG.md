# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Status: EXPERIMENTAL

Stated here rather than only per-release, because a reader arriving at a specific version
needs it as much as one reading the top.

This package has not run in production. While it is `0.x` the API may change without a
major version. Coverage is uneven by design: fakes and live public endpoints are well
covered, order placement and authenticated flows are not.

**Whenever an endpoint moves to `:proven`, the entry that does it states the evidence** —
what was run against the live venue, and when. "Marked proven" with no evidence is not an
acceptable changelog line.

## [Unreleased]

### Added
- Repo scaffold from the DpExchange standard; extraction pinned to the host's `553fa787`
  with per-file SHA-256, since the Webull subtree was dirty at extraction time — the third
  venue running.
- `docs/reference/webull/streaming-api.md`: the venue's MQTT-over-WebSocket streaming
  contract, committed verbatim, with its connection limits and protobuf schema.

### Added — the package
- Market data (snapshot, bars, catalogue), streaming, and the whole supervision
  tree. 214 tests including Core's 28 conformance assertions, passing first run.
- **Credentials are required for market data** — every OpenAPI call is signed and
  there is no anonymous endpoint, so this is the family's first
  `credential_benefit: :required`.
- **`environment: :uat`** points REST at the UAT host. Streaming there refuses with
  `{:streaming_unavailable, :uat}` rather than falling back to production: the venue
  has no UAT broker, and a consumer testing against UAT that received production
  prices would be reading real market data believing it was fake.
- **No trade volume anywhere** on this venue, so `volume` is `nil` rather than `0`.
  Zero would look like a real measurement of no trading.

### Measured against the live venue, 2026-08-28
- **The documented "TCP/IP" endpoint speaks TLS, not plaintext MQTT.** Sending a
  well-formed MQTT 3.1.1 CONNECT to `data-api.webull.com:1883` returns
  `15 03 01 00 02 01 00` — a TLS `close_notify` alert. The prior adapter reached the right
  conclusion (use WebSocket) from the wrong evidence ("never speaks MQTT", "no TLS
  handshake"); there is a TLS peer there, refusing a malformed ClientHello.
  `wss://data-api.webull.com:8883/mqtt` answers `101` immediately.
