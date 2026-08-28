# Data Streaming API — reference

**Source**: `https://developer.webull.com/apis/docs/market-data-api/data-streaming-api`.
**Read and measured 2026-08-28.**

Committed rather than linked, per D13. This venue's streaming design is the one the plan
expected to strain the facade hardest, and it does — for a reason the documentation states
plainly and a reader might skim past.

## The shape of it

> The Data Streaming API pushes real-time market data using the **MQTT protocol (v3.1.1)**
> over TCP/IP or WebSocket.

**Subscriptions are not managed over MQTT.** They are HTTP calls:

> After establishing the MQTT connection, use the **HTTP API** to manage subscriptions:
> Subscribe … Unsubscribe …

So a working stream is two transports at once — an MQTT session that receives, and REST
calls that steer it, joined only by a `session_id` the caller invents and must send to
both. **Nothing about that crosses the facade**: a consumer calls `subscribe/2` with
symbols. This is the sharpest illustration in the family of why D12 is worth its cost.

## Connection endpoints, and the one that does not work as labelled

| Environment | Protocol | Endpoint |
|---|---|---|
| Production | TCP/IP | `data-api.webull.com:1883` |
| Production | WebSocket | `wss://data-api.webull.com:8883/mqtt` |

**Measured 2026-08-28.** Sending a well-formed plaintext MQTT 3.1.1 `CONNECT` packet to
port 1883:

```
→ 10 11 00 04 4D 51 54 54 04 02 00 3C 00 05 70 72 6F 62 65   (CONNECT, client "probe")
← 15 03 01 00 02 01 00
```

That reply is a **TLS alert record** — `0x15` alert, version `0x0301`, length 2, level 1
(warning), description 0 (`close_notify`). The port is speaking **TLS**, not plaintext
MQTT. It read our CONNECT, failed to parse it as a TLS `ClientHello`, and closed.

The documentation labels that endpoint "TCP/IP", which reads as plain MQTT — the
conventional plaintext port, as opposed to 8883 for TLS. Here the numbers are the other
way round: 1883 wants TLS and 8883 carries WebSocket.

The WebSocket endpoint answers immediately:

```
GET wss://data-api.webull.com:8883/mqtt  →  HTTP/1.1 101 Switching Protocols
```

### The prior adapter reached the right conclusion by the wrong evidence

`webull/mqtt_packet.ex` records, measured 2026-08-10, that 1883 "accepts a TCP connection
and then never speaks MQTT — no CONNACK, no TLS handshake, just `:connection_timeout`."

The conclusion — use WebSocket — is correct and is carried forward. **The stated evidence
is not**: there *is* a TLS handshake being attempted, and the silence a plain client sees
is a TLS peer refusing a malformed `ClientHello`, not a dead broker. A reader trusting the
comment would conclude the port is broken and stop; the truth is it works and wants a
different protocol, which is a thing someone might one day want to use.

Same shape as the Coinbase finding in Phase 5: **the code was right and its recorded
reason was wrong, so nothing failed and nothing would have.**

## Connection rules, which are the venue's real constraints

Quoted:

> - Do not reuse the same `session_id` across multiple connections under one App Key. A
>   new connection with the same `session_id` will disconnect the previous one.
> - Each App Key supports a maximum of **5 concurrent connections**. Exceeding this returns
>   error code 105.
> - After disconnecting, the server retains connection state for **about 1 minute**. If
>   you've reached 5 connections, wait 1 minute before reconnecting.
> - The server pushes messages at a maximum rate of **3 times per second per connection**.

Four constraints, each of which shapes the package rather than the consumer:

- **5 connections per App Key** is a hard ceiling on sharding. Whatever the pair count, the
  package cannot open a sixth socket, and a consumer must never be able to cause one.
- **The 1-minute retention window turns a reconnect storm into an outage.** Reconnecting
  immediately after hitting the limit fails until the server ages the old sessions out, so
  backoff here is not politeness, it is the only way back.
- **3 messages/second per connection** is a delivery ceiling, not a request ceiling — it
  limits what a socket can carry, which is a sharding input rather than a rate-limiter one.
- **A duplicate `session_id` silently kills the older connection.** Two package instances
  that generated the same id would take turns disconnecting each other, each looking
  healthy in isolation.

> **CAUTION** — If the connection is dropped due to network issues, previous subscriptions
> are **not** automatically restored. You must re-subscribe after reconnecting.

The package owns that re-subscribe. A consumer that had to notice a reconnect and replay
its own subscriptions would be doing the venue's bookkeeping through a facade designed to
hide exactly this.

## Connection error codes

| Code | Meaning |
|---|---|
| 0 | Connection accepted |
| 1 | Unacceptable protocol version |
| 2 | Invalid ClientId |
| 3 | App Key is empty |
| 7 | Connection lost |
| 16 | Heartbeat timeout |
| 100 | Unknown error |
| 101 | Internal error |
| 102 | Connection already authenticated |
| 103 | Authentication failed |
| 104 | Invalid App Key |
| 105 | Exceeds connection limit |

`103` and `104` are credential answers and belong on the notices channel as
`credentials_rejected`. `105` is a capacity answer about our own behaviour and must not be
reported as a credential problem — they are one HTTP-status-like integer apart and mean
entirely different things to an operator.

## CONNECT packet fields

| Field | Value |
|---|---|
| ClientId | a unique `session_id` you create, **also used for subscribe/unsubscribe** |
| User Name | your App Key |
| Password | any value |

The password being ignored is worth stating: authentication is the App Key in the username
field, so a package must not treat an empty password as a misconfiguration.

## Topics and payloads

| Data type | Topic | Payload |
|---|---|---|
| QUOTE | `quote` | Protobuf |
| SNAPSHOT | `snapshot` | Protobuf |
| TICK | `tick` | Protobuf |
| NOTICE | `notice` | **JSON** |
| ECHO | `echo` | null (heartbeat) |

Event contracts use `event-quote` / `event-snapshot` / `event-tick`, which this package
does not consume — it declares `supported_instrument_types: [:spot]`.

**Mixed encodings on one connection.** Three topics are protobuf, one is JSON, one is
empty. A handler that assumes a single encoding drops four fifths of the traffic — which is
precisely what happened in the prior adapter, whose `MessageHandler` called `Jason.decode/1`
on protobuf payloads. Its own moduledoc records that even after the connection and
subscription were fixed, "the payloads would have been dropped as malformed."

## Protobuf schema, verbatim

Every field is a `string`. That is what makes a hand-rolled decoder reasonable here.

```protobuf
message Basic {
    string symbol = 1;
    string instrument_id = 2;
    string timestamp = 3;
}

message Quote {
    Basic basic = 1;
    repeated AskBid asks = 2;
    repeated AskBid bids = 3;
}

message AskBid {
    string price = 1;
    string size = 2;
    repeated Order order = 3;
    repeated Broker broker = 4;
}

message Order  { string mpid = 1; string size = 2; }
message Broker { string bid = 1;  string name = 2; }

message Snapshot {
    Basic basic = 1;
    string trade_time = 2;
    string price = 3;
    string open = 4;
    string high = 5;
    string low = 6;
    string pre_close = 7;
    string volume = 8;
    string change = 9;
    string change_ratio = 10;
    // … ext_* 11–17 and ovn_* 18–24, extended and overnight sessions
}

message Tick {
    Basic basic = 1;
    string time = 2;
    string price = 3;
    string volume = 4;
    string side = 5;
}
```

**Numbers arrive as strings**, which is a gift: no float ever enters, and every value goes
straight to `Decimal.new/1` without passing through a representation that could round it.
