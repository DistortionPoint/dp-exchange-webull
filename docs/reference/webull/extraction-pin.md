# Extraction pin — what was read, and in what state

**Host**: `dp_crypto_management`, branch `master`, `553fa787`. Read 2026-08-28.

**The working tree was DIRTY at extraction time** — the third venue running, and the third
time. Four of the eleven Webull source files carried uncommitted modifications, so the
commit SHA alone does not identify what was read. The SHA-256 of each file as actually read
is below.

| SHA-256 (first 16) | Lines | File | Tree state |
|---|---|---|---|
| `6db4b9499c5b41dc` | 190 | `webull/feed.ex` | **M — uncommitted** |
| `a69b10ab37285dd8` | 187 | `webull/mqtt_packet.ex` | clean |
| `3d1db548e047ed6c` | 495 | `webull/mqtt_ws.ex` | **M — uncommitted** |
| `41ea6262a424e28a` | 1710 | `webull/provider.ex` | **M — uncommitted** |
| `3b21f3657852294b` | 216 | `webull/quote_proto.ex` | clean |
| `ff77eddb2a39dcd0` | 165 | `webull/session_plan.ex` | clean |
| `b79b62920b04ffed` | 208 | `webull/signing.ex` | clean |
| `80a62c766ebf515a` | 38 | `webull/symbol_format.ex` | clean |
| `c0242e524fc88ad8` | 331 | `webull/websocket_provider.ex` | clean |
| `124722c16cb9de60` | 715 | `webull/feed/coordinator.ex` | **M — uncommitted** |
| `6881055a3a8e4439` | 251 | `webull/websocket_provider/message_handler.ex` | clean |

**4,506 lines of adapter** — the largest in the family, and 34% more than Gemini's 3,359.
The test corpus read alongside it is 1,018 lines (the plan estimated 879; it grew).

`provider.ex` alone is 1,710 lines, which is the single largest file any venue extraction
has faced.

## Why this venue's moduledocs matter more than most

Webull is the venue where the prior adapter's comments carry the most measured evidence,
because it is the venue where the most went wrong. Three of them record incidents that
would be expensive to rediscover:

- **`mqtt_packet.ex`** — why Tortoise311 could not be used: its transport behaviour models
  an active-mode byte stream in 16 callbacks, and this venue's reachable broker is
  MQTT-over-WebSocket. Also a 2026-08-10 measurement of the two documented endpoints.
- **`quote_proto.ex`** — the feed publishes **protobuf** while the handler called
  `Jason.decode/1`, so payloads would have been dropped as malformed even after the
  connection and subscription were repaired. Three bugs stacked, only the last of which
  was visible.
- **`provider.ex`** — a UAT host selected by a `sandbox_mode` credential flag, and
  `mqtt-uat.webullbroker.com → NXDOMAIN`: this venue has a REST sandbox but **no streaming
  sandbox**.

Carried forward per the family's rule on moduledocs that record incidents. Where a comment's
stated *evidence* turned out to be wrong — and one has, on the 1883 endpoint — the
correction is recorded in `streaming-api.md` rather than the comment being silently
rewritten.
