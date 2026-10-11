defmodule DpExchange.Webull.Socket do
  @moduledoc """
  The MQTT-over-WebSocket connection — internal, never named above the facade.

  `websockex` carries the frames; `MqttPacket` provides the framing; `QuoteProto` decodes
  the payloads. None of those three names can appear in anything a consumer receives.

  ## The buffer is the point

  A WebSocket frame is **not** an MQTT packet. One frame may carry several packets, or
  half of one, and the broker is under no obligation to align them. So every inbound frame
  is appended to a buffer and the buffer is drained packet by packet until it returns
  `:incomplete`.

  Assuming frame boundaries are packet boundaries loses every packet after the first
  coalesced frame — quietly, because the socket stays up and the first message parses fine.

  A `:malformed_length` or `:malformed_header` means the stream can no longer be
  resynchronised. A `:data_quality` notice is raised and the connection is closed, as MQTT
  3.1.1 section 2.2 requires of a receiver; the ordinary disconnect path then reconnects with
  backoff and resubscribes. Retaining the bytes would leave a live socket delivering nothing,
  and merely emptying the buffer would read the next frame from an unknown offset - both
  silent, which is the failure mode this family ranks worst.

  ## Keep-alive

  The venue's CONNECT carries a keep-alive interval, and MQTT requires the client to send
  something within it. `PINGREQ` goes out at half that interval — early enough that one
  lost ping is not a disconnect.

  **Exactly one ping chain per connection.** `WebSockex` reconnects inside the SAME
  process, and `handle_connect/2` runs on every reconnect. The chain used to be a bare
  `:ping` timer started by each `CONNECT` and re-armed by every `:ping` forever, so each
  reconnect started another chain beside the old one, and nothing ever stopped either. This
  venue drops this socket in bursts (the "issue #27" section below measured 117 crashes in
  seven minutes), which leaves about 118 chains running: a `PINGREQ` every quarter-second
  where the protocol asks for one every thirty. Worse, a surviving chain's `:ping`, queued
  while the socket reconnected, could reach the NEW connection ahead of its `CONNECT`.
  MQTT 3.1.1 requires `CONNECT` to be the first packet a client sends (§3.1), and a server
  closes a connection that sends anything else first — so a stale ping could cause the next
  drop itself.

  Each `CONNECT` now arms a timer carrying a fresh reference, kept in `state.ping`. A
  `{:ping, ref}` that does not match it belongs to a dead connection: it is dropped and NOT
  re-armed, so its chain ends there. `handle_disconnect/2` clears the reference, so no ping
  from the old connection can reach the new one before its `CONNECT`.

  ## A PINGREQ nobody answers ends the connection

  MQTT 3.1.1 requires the server to answer every PINGREQ with a PINGRESP (§3.12). This
  socket sent the PINGREQs and never looked for the answers. A network path that died
  without either end being told therefore left a "connected" socket delivering nothing
  for as long as the operating system's own timeouts allowed, since TCP notices a dead peer
  only after its retransmissions give up. Every frame, a PINGRESP included, now counts as
  being heard from. When a ping falls due after `@silence_ms` (three PINGREQ intervals,
  90s) with nothing heard, the socket raises a `:degraded` notice
  (`details.reason: :silent_connection`, with the `session_id`) and closes. That takes the
  ordinary `handle_disconnect/2` path: `:link_down`, reconnect, CONNECT, resubscribe.

  ## Acknowledgements are owed whatever QoS the venue picks

  The socket never sends a `SUBSCRIBE`, so the QoS a session is delivered at is the venue's
  choice. A `PUBLISH` at QoS 1 or 2 is acknowledged (`PUBACK`, `PUBREC`, and `PUBCOMP` for
  the `PUBREL` that follows), all of a frame's acknowledgements in one reply frame. A
  broker's in-flight window fills with unacknowledged messages and delivery stops while the
  connection, the keep-alive and the subscription all look healthy. See `MqttPacket`.

  ## QoS 2 is delivered once; QoS 1 may be delivered again, and that is the spec

  Acknowledging a QoS 2 `PUBLISH` is not enough to make it exactly-once. A broker that does
  not see the `PUBREC` in time retransmits the `PUBLISH` with `DUP` set, and one that
  reuses a packet id before the `PUBREL` produces a second `PUBLISH` the same way. Handled
  naively, each is a second delivery of a price the consumer already has. MQTT 3.1.1 §4.3.3
  says what a receiver does instead: until it has the `PUBREL`, it acknowledges every
  further `PUBLISH` of that packet id with a `PUBREC` and "MUST NOT cause duplicate
  messages to be delivered to any onward recipients".

  So `state.qos2_pending` holds the packet ids that were delivered and answered with a
  `PUBREC` and have not yet been released. A QoS 2 `PUBLISH` whose id is in the set is
  re-acknowledged and NOT delivered. A `PUBREL` removes its id and is answered with
  `PUBCOMP` whether or not the id was held, because §4.3.3 requires the `PUBCOMP`
  regardless, and after it the same id is a new publication. The `DUP` flag is not consulted
  and `MqttPacket` does not expose it: the set is the authority, and a `DUP` publish whose
  id is not in it (the first attempt never arrived) is exactly the first delivery.

  The set is bounded by the id space: a packet id is 16 bits, so at most 65,535 can be
  outstanding (id 0 is not a valid identifier, §2.3.1). A `PUBLISH` that would need a
  65,536th entry cannot come from a conforming broker; it is neither delivered nor
  acknowledged, and a `:data_quality` notice says so. Delivering it would lose the
  exactly-once guarantee silently; acknowledging it would tell the broker it is safe to
  forget a message this socket cannot track. The set is cleared on disconnect, because the
  CONNECT sets clean session and the broker discards its half of the exchange too.

  **QoS 1 is deliberately NOT deduplicated.** §4.3.2: after sending the `PUBACK`, the
  receiver "MUST treat any incoming PUBLISH packet that contains the same Packet Identifier
  as being a new publication, irrespective of the setting of its DUP flag". At-least-once
  is the contract at that QoS, and a retransmission is indistinguishable from a legitimate
  reuse of the id. It is acknowledged again and delivered again, which for a feed where the
  newest value wins costs nothing; a consumer that needs the difference has the venue's
  own timestamp on every `Quote`, `TopOfBook` and `Trade`.

  ## Data this socket cannot read is reported

  A `snapshot`, `quote` or `tick` that cannot be turned into a `Quote`, `TopOfBook` or
  `Trade`, a topic it does not decode, and a packet type it does not handle each raise a
  `:data_quality` notice, once per reason per connection and for at most 64 distinct
  reasons. The reason never carries the venue's offending value (that is in `details`), so
  the set of reasons already reported cannot grow with what the venue sends.

  ## What it does not do

  It does not subscribe. Subscriptions on this venue are **HTTP calls**, made by `Feed`
  with the same `session_id` this connection registered as its MQTT client id. The socket's
  only job is to connect, stay connected, and turn payloads into `Core.Types.Quote` (the
  `snapshot` topic), `Core.Types.TopOfBook` (the `quote` topic) or `Core.Types.Trade` (the
  `tick` topic) — see `emit/3` below.

  ## `tick` carries no trade id, and `Trade.id` is `nil` rather than invented

  The venue's `Tick` message (`docs/reference/webull/streaming-api.md`) is `Basic`, `time`,
  `price`, `volume`, `side` — nothing identifies one print from the next. `Core.Types.Trade`
  requires `:id`, so this builds the struct literally (`%Trade{id: nil, ...}`) rather than
  through `Trade.new/1`, the same way `Rest.get_trades/3`'s `to_trade/2` already does for
  this venue's REST tape, which has the identical gap and says so in its own comment.
  `Trade.new/1`'s validation exists to catch an accidentally-absent required field; this
  absence is not accidental, so going around it here is not going around the check — it is
  the one place a real, checked absence is allowed to be `nil` instead of failing closed.

  ## Ending a session cleanly

  It does not close itself, either — `Feed` decides when a shard's session ends, and
  `disconnect/2` is how it says so on the wire before that shard's process goes down. See
  `MqttPacket.disconnect/0` for why a clean `DISCONNECT` matters and `Feed`'s own
  `terminate/2` for where this is actually called.

  ## The transport underneath is a private fork — dp-exchange-core issue #27

  Webull sometimes closes this socket with a WebSocket close frame that carries **prose**
  instead of a 2-byte RFC 6455 status code (measured: `"bye-bye!!!"`, no valid close code
  in the first two bytes). Hex's latest `websockex` (0.5.1, and its unreleased upstream)
  raises and kills the process on that frame *before* `handle_disconnect/2` below ever
  runs — turning a peer's protocol violation into 117 crashes in 7 minutes, live. See
  `DpExchange.Webull.Vendor.WebSockex`'s own moduledoc for the full incident, the exact
  two-line fix, and why vendoring (not switching transports, not waiting on upstream) was
  the right call. `use WebSockex` two lines below resolves to that vendored module, not
  the real dependency, via the `alias` immediately above it — every callback in this
  module is otherwise unchanged.
  """

  alias DpExchange.Core.{Notice, Telemetry}
  alias DpExchange.Core.Types.{Quote, TopOfBook, Trade}
  alias DpExchange.Webull.{MqttPacket, QuoteProto, SymbolFormat}

  # `DpExchange.Webull.Vendor.WebSockex`, not the real `websockex` hex package's
  # `WebSockex` — see that module's own moduledoc for why. This alias, and its position
  # before `use WebSockex` immediately below (aliasing is lexical, so the alias must be
  # declared first), is the only change in this module that switches it over; every
  # callback below is unchanged.
  alias DpExchange.Webull.Vendor.WebSockex

  use WebSockex

  require Logger

  # This package's own choice, not a venue-mandated value — MQTT 3.1.1's keep-alive is a
  # client-selected 16-bit second count (0-65535), and nothing in
  # docs/reference/webull/streaming-api.md states a required or recommended figure.
  # Already investigated once as a possible cause of a ~10s close cadence and ruled out
  # on the arithmetic alone (this schedule cannot explain a period shorter than the
  # 30s PINGREQ half-interval below it) — see the CHANGELOG's "Why the venue closes the
  # connection at all" entry.
  @keep_alive_s 60

  # The topics `emit/3` handles: `notice`, and `echo` (the empty heartbeat, deliberately
  # ignored). `tick`, `snapshot` and `quote` have clauses of their own. Anything else is
  # reported, not dropped: see `handle_packet/2`.
  @known_topics ["notice", "echo"]

  # How many distinct dropped-data reasons one connection reports before going quiet. Ours,
  # not the venue's: far more than the handful of real reasons, small enough that a venue
  # inventing a new one per message cannot grow the socket's state without bound.
  @max_reported_drops 64

  # A QoS 2 packet id is 16 bits and 0 is not a valid identifier (MQTT 3.1.1 §2.3.1), so a
  # conforming broker can have at most this many QoS 2 deliveries awaiting their PUBREL. It
  # is the protocol's bound, not ours: see the moduledoc's "QoS 2 is delivered once".
  @max_qos2_pending 65_535

  # Three missed PINGRESPs at the half-keep-alive cadence. See the moduledoc's "A PINGREQ
  # nobody answers ends the connection".
  @silence_ms div(@keep_alive_s, 2) * 3 * 1_000

  # How long a session must have stayed up after CONNACK 0 before its drop counts as a
  # healthy blip (reconnect at once) rather than another failure in a run. Long enough that
  # a connect-then-drop flapper cannot reach it, and far shorter than any real session.
  # This package's own choice, not a venue figure; see `handle_disconnect/2`.
  @stable_session_ms 30_000

  # Chosen against `Feed`'s own `@call_timeout` (15s), not inherited.
  #
  # `WebSockex.Conn` defaults to `socket_connect_timeout: 6_000` and
  # `socket_recv_timeout: 5_000` (measured in `deps/websockex/lib/websockex/conn.ex:10-11`),
  # and passing no opts silently accepts them. That is 11s of a 15s budget spent on TCP and
  # the HTTP upgrade alone, before this venue's own CONNACK wait — which `Feed` must also
  # fit in the same call, since a shard is not usable until the broker has accepted its
  # session id. `Feed` is a named, shared process and opens sockets from inside its own
  # callbacks, so that window is borne by every other consumer's queued call, not just the
  # one that triggered the connect.
  #
  # 3s + 2s leaves real room for the CONNACK and the HTTP subscribe that follow. Both stay
  # overridable, and setting them changes no failure semantics: `start_link/1` still returns
  # `{:error, reason}` synchronously exactly as before.
  #
  # Their sum is also the whole handshake's deadline. `socket_recv_timeout` alone bounds
  # each `recv` of the upgrade response, not the response, so a peer that trickled it kept
  # a start or a reconnect open indefinitely. The vendored `WebSockex` now ends the
  # handshake at connect plus recv. See its moduledoc, item 3.
  @socket_connect_timeout_ms 3_000
  @socket_recv_timeout_ms 2_000

  @base_reconnect_delay_ms 1_000
  @max_reconnect_delay_ms 30_000

  @doc """
  How long to wait before the reconnect that `attempt` is about to make.

  **`websockex` reconnects with no delay of its own.** `on_disconnect/5` in
  `deps/websockex/lib/websockex.ex` calls `open_connection/3` and, on failure, calls itself
  with `attempt + 1` — a synchronous loop with nothing between the turns. So a socket the
  venue will not accept back reconnects at full connect speed, forever, and the things that
  cause it are exactly the things that do not fix themselves by being retried sooner:
  credentials the venue has stopped honouring, an IP it has started refusing, a maintenance
  window, a 503. CLAUDE.md's own testing tiers say what a venue does about traffic like
  that — "a venue that sees a package polling it on a timer will rate-limit or block" — and
  a reconnect storm is that, without the timer.

  **Attempt 1 waits nothing.** It is a live session that just dropped, and nothing about an
  ordinary network blip suggests waiting helps. Every attempt after it is a reconnect that
  has already failed at least once, so the wait doubles from #{@base_reconnect_delay_ms}ms,
  capped at #{@max_reconnect_delay_ms}ms.

  The same shape, and the same two constants, as `DpExchange.Schwab.Socket`'s
  `reconnect_delay_ms/1`, which had this venue family's only reconnect backoff until now.
  Its counter is `LOGIN_DENIED`s specifically because that venue can name its own auth
  rejection; here the counter is `websockex`'s consecutive-failure count, which needs no
  venue-specific signal and is already correct for every reason a reconnect can fail.
  """
  # Integer shifting, not `:math.pow/2`, and the exponent is clamped BEFORE the shift.
  #
  # `:math.pow(2, n)` is float arithmetic and raises `ArithmeticError` once `n` passes 1023,
  # because the float range ends at ~1.8e308. Clamping the RESULT — `min(base * pow, max)` —
  # does not help: the raise happens while computing the argument to `min/2`. So the
  # function written to survive a reconnect storm crashed during a long one, at roughly
  # attempt 1025, which at the 30-second cap is about 8.5 hours of continuous failure. That
  # is an ordinary overnight outage or an access token nobody has refreshed yet, and the
  # crash lands inside `handle_disconnect/2` where it reads as this socket's fault rather
  # than the venue's.
  #
  # `Bitwise.bsl/2` has no such ceiling and is exact. The clamp exists only so the
  # intermediate cannot grow without bound — the cap is already reached at exponent 5
  # (`2^5 * @base_reconnect_delay_ms` exceeds `@max_reconnect_delay_ms`), so every clamped
  # value produces the identical answer the unclamped one would have.
  @max_backoff_exponent 30

  @spec reconnect_delay_ms(pos_integer()) :: non_neg_integer()
  def reconnect_delay_ms(attempt) when is_integer(attempt) and attempt <= 1, do: 0

  def reconnect_delay_ms(attempt) when is_integer(attempt) do
    exponent = min(attempt - 2, @max_backoff_exponent)

    min(@base_reconnect_delay_ms * Bitwise.bsl(1, exponent), @max_reconnect_delay_ms)
  end

  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    url = Keyword.fetch!(opts, :url)

    state = %{
      subscriber: Keyword.fetch!(opts, :subscriber),
      session_id: Keyword.fetch!(opts, :session_id),
      app_key: Keyword.fetch!(opts, :app_key),
      buffer: <<>>,
      # QoS 2 packet ids delivered and PUBREC'd but not yet released by a PUBREL. See the
      # moduledoc's "QoS 2 is delivered once".
      qos2_pending: MapSet.new(),
      connected?: false,
      # Monotonic ms of the last CONNACK 0, for `stable_session?/1`.
      connected_at: nil,
      ping: nil,
      # When the last frame of any kind, a PINGRESP included, arrived. See the moduledoc's
      # "A PINGREQ nobody answers ends the connection".
      last_heard_at: nil
    }

    WebSockex.start_link(url, __MODULE__, state, connection_opts(opts))
  end

  @doc """
  The connection options handed to `WebSockex.start_link/4`.

  Exposed so the deliberate timeouts can be asserted without opening a real socket — a
  later refactor must not be able to drop them back to the dependency's defaults unnoticed.
  """
  @spec connection_opts(keyword()) :: keyword()
  def connection_opts(opts) do
    opts
    |> Keyword.take([:socket_connect_timeout, :socket_recv_timeout, :ssl_options])
    |> Keyword.put_new(:socket_connect_timeout, @socket_connect_timeout_ms)
    |> Keyword.put_new(:socket_recv_timeout, @socket_recv_timeout_ms)
    |> Keyword.put_new_lazy(:ssl_options, &verified_tls/0)
  end

  # **Certificate verification, which `websockex` does not do unless told to.** Its
  # `WebSockex.Conn` starts with `insecure: true`, which is `verify: :verify_none`
  # (`deps/websockex/lib/websockex/conn.ex:24`). No socket in this family passed TLS options,
  # so every `wss://` connection accepted any certificate from anyone. Measured 2026-09-27:
  # against a local TLS server presenting a certificate from a CA nothing trusts, the TLS
  # handshake completed and the client went on to send its upgrade request. Anyone able to
  # sit on the path could have impersonated the venue and read everything sent after the
  # upgrade, credentials included. HTTP was never affected, because Mint verifies by default.
  #
  # The operating system's trust store (`:public_key.cacerts_get/0`, which OTP caches after
  # the first read) and the HTTPS hostname rules, so a venue's wildcard certificate matches.
  # A caller can still pass its own `:ssl_options`, which replace these entirely.
  defp verified_tls do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end

  # Bounded well under `Feed`'s default `GenServer` shutdown timeout (5s, unset by
  # `Supervisor`) — `terminate/2` calls this once per connected shard and a slow or wedged
  # socket must not eat another shard's share of that budget.
  @disconnect_timeout_ms 500

  @doc """
  Sends a clean MQTT `DISCONNECT` on an already-open socket, synchronously.

  `WebSockex.send_frame/3` is a `:gen.call` against the socket process itself — the only
  way to put a frame on an already-running `Socket` from outside its own callbacks, since
  `MqttPacket`'s framing stays private to this module (`Feed` must not learn it — see the
  moduledoc's boundary). Called by `Feed`'s own `terminate/2`, once per shard still
  connected when this package is shutting down cleanly.

  Best-effort and never raises: a shard whose socket has already gone — crashed, already
  reconnecting, already torn down by the time shutdown reaches it — must not block or
  crash the shutdown asking for this. `{:error, reason}` says so; there is nothing a
  caller mid-shutdown can usefully do with it beyond logging, which `Feed` does.

  The `pid == self()` guard exists because this runs from inside `Feed`'s own
  `terminate/2`: a call this deep can legitimately end up with `pid` being the calling
  process itself only through a test fixture, never in production (a shard's socket is
  always a distinct `Socket.start_link/1` process) — but `WebSockex.send_frame/3` answers
  that specific case by *raising* `WebSockex.CallingSelfError` rather than returning an
  error, which the `catch` below alone would not stop. Checked first so this function's
  own "never raises" holds regardless.
  """
  @spec disconnect(pid(), timeout()) :: :ok | {:error, term()}
  def disconnect(pid, timeout \\ @disconnect_timeout_ms)

  def disconnect(pid, _timeout) when pid == self(), do: {:error, :calling_self}

  def disconnect(pid, timeout) do
    if Process.alive?(pid) do
      WebSockex.send_frame(pid, {:binary, MqttPacket.disconnect()}, timeout)
    else
      {:error, :not_alive}
    end
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  # --- callbacks ----------------------------------------------------------

  @impl true
  def handle_connect(_conn, state) do
    # The WebSocket is up; MQTT is not. CONNECT goes out immediately and `link_up` waits
    # for the CONNACK — reporting a live link on a socket that has not authenticated
    # would be reporting the transport, not the venue.
    send(self(), :send_connect)
    {:ok, state}
  end

  @impl true
  def handle_disconnect(%{reason: reason} = status, state) do
    # session_id rides along so a Feed managing several shards' sockets can tell which
    # one just dropped — the message alone carries no sender identity otherwise.
    notify(
      state,
      Notice.new(:link_down, :webull,
        details: %{reason: inspect(reason), session_id: state.session_id}
      )
    )

    Telemetry.link_down(:webull, inspect(reason))

    # `attempt_number` comes from the transport itself. It is a documented key of the
    # `connection_status_map` this function already pattern-matches on
    # (`WebSockex.connection_status_map/0`), and `on_disconnect/5` increments it for each
    # CONSECUTIVE failed reconnect, starting fresh at 1 each time a live session drops.
    #
    # This module used to state that it "keeps no attempt counter", and declined to emit
    # `link_reconnect_attempt` rather than invent one. Refusing to invent was right; the
    # premise was wrong — the real counter was in the argument all along. Both the backoff
    # below and the event now run on the transport's own number rather than a local guess.
    #
    # It matters most on this venue. The vendored fork exists because Webull severs the
    # connection with a malformed close frame (the moduledoc's dp-exchange-core issue #27
    # section) — measured at 117 crashes in 7 minutes, which is a venue dropping this socket
    # repeatedly and in bursts, which is exactly what a delay-free reconnect turns into a
    # connect storm.
    #
    # `Map.get/3` rather than a pattern, so the unit tests that call this callback directly
    # with a bare `%{reason: ...}` keep describing what they mean: one healthy session
    # dropping, which still reconnects at once.
    #
    # **A session the broker refused counts too.** `attempt_number` counts failed TRANSPORT
    # reconnects, and restarts at 1 after every upgrade that succeeded. A broker answering
    # CONNACK 103/104/105 leaves the WebSocket up, so the next drop was attempt 1 again: delay
    # 0, forever. On 105 (connection limit) that is self-sustaining, because the broker holds
    # state for about a minute and "backoff is the only way back" (streaming-api.md).
    # Consecutive sessions that never reached CONNACK 0 now feed the same backoff.
    #
    # **Reaching CONNACK 0 is not, by itself, a healthy session.** Found 2026-10-10 by
    # reading this function: any session that got that far reset the counter, so a venue
    # that accepted the CONNECT and dropped the socket seconds later (the malformed-close
    # bursts this module's vendored fork exists for) was reconnected at delay 0 every time,
    # the connect storm this backoff is here to prevent. The counter now resets only when the
    # session LIVED `@stable_session_ms`; a shorter one counts as another failed attempt.
    unconnected =
      if stable_session?(state), do: 0, else: Map.get(state, :unconnected_sessions, 0) + 1

    attempt = max(Map.get(status, :attempt_number, 1), unconnected + 1)
    delay = reconnect_delay_ms(attempt)

    Telemetry.link_reconnect_attempt(:webull, attempt, delay)

    # Blocks THIS socket process only, and only while it has no connection to serve anyway —
    # the same trade `dp_exchange_schwab.Socket` already makes.
    if delay > 0, do: Process.sleep(delay)

    {:reconnect,
     Map.merge(state, %{
       buffer: <<>>,
       # Acknowledgements owed to a connection that no longer exists are owed to nobody.
       acks: [],
       # The CONNECT sets clean session, so the broker has forgotten its half of every QoS 2
       # exchange that was open on the dead connection. Keeping ours would suppress the first
       # delivery of a reused packet id on the next one.
       qos2_pending: MapSet.new(),
       connected?: false,
       connected_at: nil,
       ping: nil,
       unconnected_sessions: unconnected
     })}
  end

  # Connected, and for at least `@stable_session_ms`. A state with no `:connected_at` (a
  # session that never reached CONNACK 0, or one a test built by hand) is not stable: with
  # nothing to measure the age from, the answer that cannot cause a storm is "no".
  defp stable_session?(%{connected?: true, connected_at: connected_at})
       when is_integer(connected_at),
       do: now_ms() - connected_at >= @stable_session_ms

  defp stable_session?(_state), do: false

  @impl true
  def handle_info(:send_connect, state) do
    # The password is documented as "any value" — authorisation happens on the signed HTTP
    # subscribe, so this is sent to satisfy the protocol flag rather than to authenticate.
    packet = MqttPacket.connect(state.session_id, state.app_key, "x", @keep_alive_s)
    ping = make_ref()
    schedule_ping(ping)
    {:reply, {:binary, packet}, %{state | ping: ping, last_heard_at: now_ms()}}
  end

  def handle_info({:ping, ping}, %{ping: ping} = state) when is_reference(ping) do
    silent_for = now_ms() - state.last_heard_at

    if silent_for >= @silence_ms do
      notify(
        state,
        Notice.new(:degraded, :webull,
          message:
            "nothing heard, not even a PINGRESP, for #{silent_for}ms — closing the " <>
              "connection and reconnecting",
          details: %{
            reason: :silent_connection,
            silent_for_ms: silent_for,
            session_id: state.session_id
          }
        )
      )

      {:close, %{state | ping: nil}}
    else
      schedule_ping(ping)
      {:reply, {:binary, MqttPacket.pingreq()}, state}
    end
  end

  # A ping from a connection that has since dropped. It is not re-armed, so its chain ends
  # here — see the moduledoc's "Keep-alive" section.
  def handle_info({:ping, _stale}, state), do: {:ok, state}

  def handle_info(_other, state), do: {:ok, state}

  defp schedule_ping(ping),
    do: Process.send_after(self(), {:ping, ping}, div(@keep_alive_s, 2) * 1_000)

  defp now_ms, do: System.monotonic_time(:millisecond)

  @impl true
  def handle_frame({:binary, data}, state) do
    state = %{state | last_heard_at: now_ms()}
    # Counted per WEBSOCKET frame, which on this venue is not the same as per MQTT packet:
    # `drain/1` reassembles packets out of a buffer, so one frame can carry several and a
    # packet can span two. The frame is the honest unit for a link event — it is what the
    # venue actually put on the wire, and `byte_size(data)` is exactly what arrived. Counting
    # reassembled packets instead would report a number this socket computed rather than one
    # the venue sent.
    Telemetry.link_event(:webull, :frame, byte_size(data))
    drain(%{state | buffer: state.buffer <> data})
  end

  def handle_frame(_other, state), do: {:ok, state}

  # --- packet handling ----------------------------------------------------

  defp drain(state) do
    case MqttPacket.decode(state.buffer) do
      {:ok, packet, rest} ->
        state |> handle_packet(packet) |> Map.put(:buffer, rest) |> drain()

      {:error, :incomplete} ->
        finish(state)

      {:error, reason} when reason in [:malformed_length, :malformed_header] ->
        # Unrecoverable: no future byte repairs an invalid length, and MQTT 3.1.1 section 2.2
        # says a receiver that gets an invalid header MUST close the connection. Carrying on
        # with an emptied buffer read the next frame from an unknown offset, which could
        # swallow real packets as the body of a bogus one. Say so once, then take the ordinary
        # disconnect path (`:link_down`, backoff, reconnect, CONNECT, resubscribe). Acks owed
        # on this connection are owed to nobody.
        notify(
          state,
          Notice.new(:data_quality, :webull,
            message: "MQTT stream lost framing (#{reason}) - closing the connection",
            details: %{dropped: :malformed_frame, reason: reason, session_id: state.session_id}
          )
        )

        {:close, state |> Map.put(:buffer, <<>>) |> Map.put(:acks, [])}
    end
  end

  # Ends a frame's drain. Acknowledgements owed for the packets it carried go out as ONE
  # binary frame: MQTT over WebSocket allows several packets in a frame, and `WebSockex`
  # takes one reply per callback. See `MqttPacket`'s moduledoc for why anything is owed.
  defp finish(state) do
    case Map.get(state, :acks, []) do
      [] ->
        {:ok, state}

      owed ->
        {:reply, {:binary, owed |> Enum.reverse() |> IO.iodata_to_binary()},
         Map.put(state, :acks, [])}
    end
  end

  defp owe_ack(state, kind, packet_id) do
    ack = MqttPacket.ack(kind, packet_id)
    Map.update(state, :acks, [ack], &[ack | &1])
  end

  defp handle_packet(state, {:connack, 0}) do
    # session_id rides along so a Feed managing several shards' sockets can tell which
    # one just came up — see the matching comment on handle_disconnect/2.
    notify(state, Notice.new(:link_up, :webull, details: %{session_id: state.session_id}))

    # Here and not in `handle_connect/2`, for the reason that callback already gives: the
    # WebSocket being up is the transport, and the LINK is the venue accepting the MQTT
    # CONNECT. Emitting on `handle_connect/2` would report a live venue for a socket that
    # has not authenticated — the transport-vs-link confusion `Core.Telemetry`'s "Why the
    # category is `:link` and not `:ws`" section exists to prevent, and this venue is the
    # one where the two genuinely come apart.
    #
    # The metrics channel alongside the notice channel, never instead of it: a `Core.Notice`
    # is a condition a consumer must ACT on, telemetry is aggregate and lossy by design.
    Telemetry.link_up(:webull)
    # A new connection gets its own drop reports: see `report_drop/3`.
    Map.merge(state, %{connected?: true, connected_at: now_ms(), drops_reported: MapSet.new()})
  end

  # The venue's connection error codes mean genuinely different things, and two of them
  # are one integer apart: 103/104 are credential answers, 105 is our own behaviour.
  # Reporting a connection-limit breach as rejected credentials sends an operator to
  # rotate a key that is fine.
  #
  # `session_id` rides along on every one of these, exactly as it does on `:link_up` and
  # `:link_down`, and for the same reason: a `Feed` managing several shards' sockets cannot
  # otherwise tell WHICH shard the venue refused. It could not, and the cost was a caller
  # parked on that shard's `reply_to` with nothing able to answer it — see `Feed`'s own
  # refusal clause. The two notices that carry a session id and the three that did not were
  # the same event class all along; only the successful one had been wired up.
  # 4 (bad user name or password) and 5 (not authorised) are MQTT 3.1.1 §3.2.2.3's own
  # credential refusals. The venue's table (`streaming-api.md`) lists neither, only its 3,
  # 103 and 104, but a broker answering a standard code means the standard thing, and it
  # was being reported as a transport `:link_down` that tells an operator nothing about the key.
  defp handle_packet(state, {:connack, code}) when code in [3, 4, 5, 103, 104] do
    notify(
      state,
      Notice.new(:credentials_rejected, :webull,
        details: %{connack: code, session_id: state.session_id}
      )
    )

    state
  end

  defp handle_packet(state, {:connack, 105}) do
    notify(
      state,
      Notice.new(:degraded, :webull,
        details: %{connack: 105, reason: :connection_limit, session_id: state.session_id},
        message: "five concurrent connections per App Key; the venue holds state ~1 minute"
      )
    )

    state
  end

  defp handle_packet(state, {:connack, code}) do
    notify(
      state,
      Notice.new(:link_down, :webull, details: %{connack: code, session_id: state.session_id})
    )

    state
  end

  # `tick`, `snapshot`, `quote` and anything unrecognised thread the state through, for
  # `report_drop/3`; `notice` and `echo` never drop silently and keep their `:ok`-returning
  # `emit/3`.
  defp handle_packet(state, {:publish, "tick", payload}),
    do: emit_trade(state, QuoteProto.decode_tick(payload))

  # Three topics are protobuf, one is JSON, one is empty. A handler assuming a single
  # encoding drops four fifths of the traffic — which is what the prior adapter did by
  # calling `Jason.decode/1` on every payload.
  #
  # **A snapshot or book this package cannot read is reported, as an unreadable tick
  # always was.** Both returned `:ok` in silence, so a venue that changed a field number
  # left a consumer with a connected, subscribed, mute feed and nothing saying it was this
  # decoder rather than the venue. These are the main data path; the tape was the only one
  # that could explain itself (dp-exchange-core issue #40).
  defp handle_packet(state, {:publish, "snapshot", payload}),
    do: emit_snapshot(state, QuoteProto.decode_snapshot(payload))

  defp handle_packet(state, {:publish, "quote", payload}),
    do: emit_book(state, QuoteProto.decode_quote(payload))

  defp handle_packet(state, {:publish, topic, payload}) when topic in @known_topics do
    emit(state, topic, payload)
    state
  end

  # dp-exchange-core issue #40. A topic this package does not decode was dropped with no
  # trace. If the venue ever published a data type under a name the streaming page does not
  # list, the subscriber saw nothing and was told nothing. It is reported once per topic per
  # connection, with the payload's size rather than its bytes.
  defp handle_packet(state, {:publish, topic, payload}) do
    # Copied: the topic is a view into the frame and it becomes part of a key that
    # `state.drops_reported` holds for the life of the connection, which would pin every
    # such frame (up to 1 MiB each, 64 keys) for as long.
    topic = :binary.copy(topic)

    report_drop(state, {:unrecognised_topic, topic}, %{topic: topic, bytes: byte_size(payload)})
  end

  # A QoS 1 PUBLISH: acknowledged, then handled exactly as a QoS 0 one is. Always delivered,
  # DUP or not: MQTT 3.1.1 §4.3.2 makes a repeat of the id after the PUBACK a new publication.
  defp handle_packet(state, {:publish, topic, payload, {:puback, packet_id}}) do
    state |> owe_ack(:puback, packet_id) |> handle_packet({:publish, topic, payload})
  end

  # A QoS 2 PUBLISH. MQTT 3.1.1 §4.3.3: an id still awaiting its PUBREL is acknowledged again
  # and not delivered again. The window-full branch is unreachable from a conforming broker;
  # see the moduledoc.
  defp handle_packet(state, {:publish, topic, payload, {:pubrec, packet_id}}) do
    pending = Map.get(state, :qos2_pending, MapSet.new())

    cond do
      MapSet.member?(pending, packet_id) ->
        owe_ack(state, :pubrec, packet_id)

      MapSet.size(pending) >= @max_qos2_pending ->
        report_drop(state, {:qos2, :window_full}, %{packet_id: packet_id, topic: topic})

      true ->
        state
        |> Map.put(:qos2_pending, MapSet.put(pending, packet_id))
        |> owe_ack(:pubrec, packet_id)
        |> handle_packet({:publish, topic, payload})
    end
  end

  # The PUBREL that completes a QoS 2 delivery. The id is released, and answered with a
  # PUBCOMP whether or not it was held: §4.3.3 requires the PUBCOMP regardless, and a PUBREL
  # for an id this connection never saw (a retransmission after our PUBCOMP was lost) must
  # still be answered or the broker retries it forever.
  defp handle_packet(state, {:pubrel, packet_id}) do
    pending = state |> Map.get(:qos2_pending, MapSet.new()) |> MapSet.delete(packet_id)

    state |> Map.put(:qos2_pending, pending) |> owe_ack(:pubcomp, packet_id)
  end

  # A packet type this package neither sends a request for nor decodes (SUBACK, PUBACK,
  # a PUBLISH too short for its own identifier). It used to be dropped here without a trace,
  # though `MqttPacket` decodes it precisely so that someone is told. Reported once per type
  # per connection, with the size and not the bytes.
  defp handle_packet(state, {:unhandled, type, body}) do
    report_drop(state, {:unhandled_packet, type}, %{packet_type: type, bytes: byte_size(body)})
  end

  defp handle_packet(state, _other), do: state

  # A `quote` message is the book: bid and ask, and no last price — the venue does not send
  # one on this topic.
  #
  # This used to build a `Core.Types.Quote` with `price: bid || ask`, defended in a comment
  # as "a real quoted number, labelled as the bid too". It is real, and it is not a price.
  # A bid is a resting order; a price is an execution. The same substitution was found on
  # two other venues in this family, one of which had shipped it.
  #
  # A book message is top-of-book data and now delivers `Core.Types.TopOfBook`, which has
  # no `price` field to misuse.
  #
  # **The guard tests the DECODED levels, not the raw strings.** It used to ask
  # `is_binary(bid) or is_binary(ask)` of the wire strings and only then ran `decimal/1`, so a
  # delisted pair's `"null"` (a documented shape — see `decimal/1`) passed the guard, decoded
  # to `nil`, and went out as `%TopOfBook{bid: nil, ask: nil}`: delivered, and counted by
  # `Feed` as coverage for a symbol with no book at all. Found 2026-10-10. A quote that states
  # no readable level is no quote.
  defp emit_book(state, {:ok, decoded}) do
    case readable_levels(decoded) do
      {:ok, bid, ask} ->
        emit_top_of_book(state, decoded, bid, ask)
        state

      :error ->
        report_drop(state, {:quote, :no_readable_level}, %{
          symbol: decoded.symbol,
          bid: decoded.bid,
          ask: decoded.ask
        })
    end
  end

  defp emit_book(state, :error), do: report_drop(state, {:quote, :undecodable}, %{})

  # A `tick` message is one print — the tape. Unlike `snapshot` and `quote`, this topic is
  # not requested by default everywhere in the family; on this venue it is, though (see
  # `Subscription`'s default `sub_types`), so a subscriber gets `Core.Types.Trade` on this
  # topic the same way it gets `Quote` and `TopOfBook` on the other two, with no extra
  # option to ask for it — the facade hides the venue's `sub_types` vocabulary the same way
  # it hides everything else about how this venue is reached.

  # The venue's own words go in `:message`, which is the field a consumer renders.
  #
  # dp-exchange-core issue #33: this used to pass only `details: %{venue_notice: body}`, so
  # a consumer printing `notice.message` printed nothing **while holding the text**. The
  # reporter's node logged `webull degraded: (no message)` 230 times in 66 minutes over
  # "Permission grabbed by other session, category : us-crypto" — a line that is not noise
  # and was made to look like noise. `handle_packet(state, {:connack, 105})` above already
  # set `:message`; this path simply never did.
  #
  # **`"content"` is OBSERVED, not documented.** The vendor's streaming page documents that
  # the `notice` topic carries JSON and does not publish its field schema
  # (`docs/reference/webull/streaming-api.md`'s topic table is as far as it goes). The key
  # comes from a consumer's production frames. Reading it is still safe rather than a guess:
  # an absent or non-string `content` yields `nil`, the raw body stays in `details`
  # untouched, and nothing is substituted — `nil` keeps meaning "the venue sent no text",
  # which is a real answer for the code-only shape the same reporter saw alongside it
  # (four numeric-keyed fields, no `content`).
  defp emit(state, "notice", payload) do
    # `strings: :copy`: by default Jason returns views into `payload`, and `body` rides in the
    # notice's `details` - see `bound_text/1` for what that would pin.
    case Jason.decode(payload, strings: :copy) do
      {:ok, %{} = body} ->
        notify(
          state,
          Notice.new(:degraded, :webull,
            message: venue_notice_text(body),
            # `session_id` names the shard the venue said this to. Issue #10 asked for it,
            # and `Feed` needs it (issue #11): a "Permission grabbed" notice on THIS
            # session is the evidence that its silence is a sibling's grab rather than a
            # lost subscription.
            details: %{
              venue_notice: bound_notice_body(body),
              session_id: Map.get(state, :session_id)
            },
            severity: venue_notice_severity(body)
          )
        )

      _undecodable ->
        # The venue said something this package could not parse as JSON. Dropping it
        # silently is the same defect as the one above, one level down — so the text is
        # carried as-is when it is text at all. A payload that is not valid UTF-8 has no
        # words to keep and stays dropped rather than becoming mojibake in a log line.
        emit_unparsed_notice(state, payload)
    end
  end

  defp emit(_state, _topic, _payload), do: :ok

  # The decoded body rides in the notice's `details`, and `bound_text/1` only bounds the
  # words. The venue documents no notice size and a frame may be up to the 1 MiB `MqttPacket`
  # allows, so one frame could still put a megabyte-sized term into a notice that a consumer
  # keeps. Past 64 KiB (in `:erlang.external_size/1`, the term's own size, not the wire's) the
  # body is replaced by a statement that it was too large, with its size: the message text,
  # which is bounded separately, still carries the venue's words, and nothing is invented.
  # Every notice the venue has been seen to send is far below this.
  @max_notice_body_bytes 65_536

  defp bound_notice_body(body) do
    case :erlang.external_size(body) do
      size when size <= @max_notice_body_bytes -> body
      size -> %{"truncated" => true, "approx_bytes" => size}
    end
  end

  # No non-binary clause: dialyzer proves this call site always passes a binary, and a dead
  # fallback is the unreachable code assertion 16 exists to find. A non-binary would raise
  # here, which is the fail-closed answer rather than a silent `:ok`.
  defp emit_unparsed_notice(state, payload) when is_binary(payload) do
    if String.valid?(payload) and String.trim(payload) != "" do
      notify(
        state,
        Notice.new(:degraded, :webull,
          message: payload |> String.trim() |> bound_text(),
          details: %{venue_notice_unparsed: bound_text(payload)}
        )
      )
    end

    :ok
  end

  # How much of the venue's own words one notice carries. Ours, not the venue's: the venue
  # documents no notice size, a frame may be up to the 1 MiB `MqttPacket` allows, and one
  # notice is raised per frame, so an unbounded text was a megabyte per notice.
  @max_notice_text_bytes 1_024

  # Cut on a UTF-8 boundary (the input is valid UTF-8), with a marker saying it was cut.
  #
  # Always a fresh binary. `String.trim/1` and `binary_part/3` hand back a view into the frame
  # they came from, and a notice is the one thing here a consumer may keep for a long time
  # (a "last notice" field, an ETS row): a 40-byte message would pin the whole frame - up to
  # the 1 MiB `MqttPacket` allows - for as long as it was held.
  defp bound_text(text) when byte_size(text) <= @max_notice_text_bytes, do: :binary.copy(text)

  defp bound_text(text) do
    cut = utf8_boundary(text, @max_notice_text_bytes)

    binary_part(text, 0, cut) <> "... [truncated, #{byte_size(text)} bytes in all]"
  end

  # The largest `n <= limit` at which a character starts, so `text[0, n)` ends whole.
  defp utf8_boundary(text, n) when n > 0 do
    if Bitwise.band(:binary.at(text, n), 0xC0) == 0x80,
      do: utf8_boundary(text, n - 1),
      else: n
  end

  defp utf8_boundary(_text, 0), do: 0

  # **Severity is read from the frame; it used to be a constant.** Every frame on the
  # `notice` topic was `Notice.new(:degraded, :webull, ...)`, and `:degraded` defaults to
  # `:warning`, so a consumer mapping severity to a log level — the mapping `Core.Notice`
  # itself documents — logged a WARN per frame whatever the frame said.
  #
  # dp-exchange-webull issue #5, measured over eight hours on a live host: **336 WARN/hour,
  # of which 184/hour were `%{"drop" => 0, "rtt" => 0, "sent" => 1878, "type" => "1001"}`** —
  # a keepalive reporting ZERO drops, rendered as `webull degraded: (no message)` because it
  # carries no `content`. The feed was healthy throughout: 4,400-4,600 rows/60s, zero
  # reconnects. Those two notices were the #1 and #2 entries in that host's warning log by
  # volume and buried 1,331 genuinely serious warnings underneath them.
  #
  # `Core.Notice` calls severity "not a log level — a call to action", and its
  # `default_severity/1` is explicitly "a default, not a rule: a caller with better
  # information overrides it". The frame IS better information, so it is read rather than
  # assumed.
  #
  # **Keyed on evidence, not on the `type` code the reporter suggested.** The vendor
  # publishes no field schema for this topic at all — `venue_notice_text/1` below already
  # records that `"content"` is observed rather than documented — so a `"1001" => :info`
  # table would be one consumer's observation hardcoded as a venue fact, and a venue that
  # renumbered or added a code would silently get the wrong answer. `content` and `drop` are
  # the fields that actually carry the claim, and they are what the reporter's own evidence
  # discriminates on.
  #
  # Two things count as adverse, and nothing else does:
  #
  #   * the venue sent WORDS — it only writes `content` when it has something to say, and
  #     the frame that prompted issue #33 ("Permission grabbed by other session") is exactly
  #     that shape. Still `:warning`.
  #   * a non-zero `drop`. Frames lost is the venue answering from a worse path than usual,
  #     which is what `:degraded` means.
  #
  # Absence of an adverse indicator is not evidence of degradation, so everything else is
  # `:info`. That is the whole fix: `drop: 0` no longer claims a human should look.
  #
  # The KIND stays `:degraded`, and that is a known imperfection rather than an oversight.
  # `Core.Notice`'s kinds are "deliberately a closed set. An open one would let each venue
  # package invent its own vocabulary" — and the set has no slot for "the venue reported on
  # itself and nothing is wrong". Widening it is a change to the shared contract and not
  # this package's to make unilaterally. Severity is the field the reported harm actually
  # runs through, and it is now correct.
  defp venue_notice_severity(body) do
    if venue_notice_text(body) || dropped_frames?(body), do: :warning, else: :info
  end

  # A count the venue states. Accepted as an integer or as a numeric string, because the
  # vendor documents neither; anything else is no statement at all, and an absent or
  # unreadable count is not evidence that frames were dropped.
  defp dropped_frames?(%{"drop" => drop}) when is_integer(drop), do: drop > 0

  defp dropped_frames?(%{"drop" => drop}) when is_binary(drop) do
    case Integer.parse(String.trim(drop)) do
      {count, ""} -> count > 0
      _unreadable -> false
    end
  end

  defp dropped_frames?(_no_count), do: false

  defp venue_notice_text(%{"content" => content}) when is_binary(content) do
    case String.trim(content) do
      "" -> nil
      trimmed -> bound_text(trimmed)
    end
  end

  defp venue_notice_text(_no_content), do: nil

  # Both levels decoded once, here, so the caller can refuse a book that states neither.
  defp readable_levels(decoded) do
    case {decimal(decoded[:bid]), decimal(decoded[:ask])} do
      {nil, nil} -> :error
      {bid, ask} -> {:ok, bid, ask}
    end
  end

  defp emit_top_of_book(state, decoded, bid, ask) do
    send(
      state.subscriber,
      {:dp_exchange, :webull,
       %TopOfBook{
         symbol: SymbolFormat.to_canonical_symbol(decoded.symbol),
         bid: bid,
         ask: ask,
         # The venue's `AskBid` carries `price = 1` AND `size = 2` — its own schema, kept
         # verbatim in `docs/reference/webull/streaming-api.md`. These were hardcoded to
         # `nil` under a comment saying the venue sent no sizes; it sends them, and
         # `QuoteProto` was decoding them off the wire and discarding them.
         #
         # `nil` still reaches a caller for a level that states no size, which is what
         # `Core.Types.TopOfBook` requires: "not published", never "none available".
         #
         # **A size is the size of a level, and a side with no readable price has no level.**
         # `bid: nil` with a `bid_size` beside it says "no resting bid, and 5 of it": a level
         # that is absent and sized at once. The price was `"null"` or unparseable and the
         # size was a real number, so the pair read as a one-sided book with depth on the
         # empty side. Each size is kept only with the price it belongs to.
         bid_size: bid && decimal(decoded[:bid_size]),
         ask_size: ask && decimal(decoded[:ask_size]),
         venue_time: venue_time_or_nil(decoded),
         observed_at: DateTime.utc_now(),
         provider: :webull
       }}
    )

    :ok
  end

  # **`Snapshot.volume` (field 8) is passed through, labelled a running total.** It was
  # decoded off the wire by `QuoteProto` and then hard-coded to `nil` here, from this
  # package's first commit, under the belief that crypto publishes no volume — never
  # measured (dp_exchange_webull issue #6). The schema's `Snapshot` carries `volume` beside
  # `open`, `high`, `low` and `pre_close`, which makes it the session's cumulative total, not
  # one print: `:running_total` (dp-exchange-core issue #42), to be differenced, never
  # summed. A snapshot that states no volume (`QuoteProto` reads `""` as absent) or an
  # unreadable one stays `nil`, with no window, so nothing is invented either way.
  defp emit_snapshot(state, {:ok, decoded}) do
    case required_decimal(decoded[:price], :price) do
      {:ok, price} ->
        volume = decimal(decoded[:volume])

        send(
          state.subscriber,
          {:dp_exchange, :webull,
           %Quote{
             symbol: SymbolFormat.to_canonical_symbol(decoded.symbol),
             price: price,
             volume: volume,
             volume_window: volume && :running_total,
             venue_time: venue_time_or_nil(decoded),
             observed_at: DateTime.utc_now(),
             provider: :webull
           }}
        )

        state

      {:error, reason} ->
        report_drop(state, {:snapshot, drop_reason(reason)}, %{
          symbol: decoded.symbol,
          price: decoded.price
        })
    end
  end

  defp emit_snapshot(state, :error), do: report_drop(state, {:snapshot, :undecodable}, %{})

  # `id: nil` — see the moduledoc's "`tick` carries no trade id". `Trade.new/1` is
  # deliberately not used here: it would raise on the very absence this comment and the
  # moduledoc both document as real rather than accidental.
  defp emit_trade(state, {:ok, decoded}) do
    with {:ok, timestamp} <- tick_time(decoded),
         {:ok, price} <- required_decimal(decoded[:price], :price),
         {:ok, quantity} <- required_decimal(decoded[:volume], :quantity) do
      send(
        state.subscriber,
        {:dp_exchange, :webull,
         %Trade{
           id: nil,
           symbol: SymbolFormat.to_canonical_symbol(decoded.symbol),
           side: tick_side(decoded[:side]),
           price: price,
           quantity: quantity,
           timestamp: timestamp,
           broken: false,
           provider: :webull
         }}
      )

      state
    else
      {:error, reason} ->
        report_drop(state, {:tick, drop_reason(reason)}, %{
          symbol: decoded[:symbol],
          time: decoded[:timestamp],
          basic_timestamp: decoded[:basic_timestamp],
          price: decoded[:price],
          volume: decoded[:volume]
        })
    end
  end

  defp emit_trade(state, :error),
    do: report_drop(state, {:tick, :undecodable}, %{})

  # The print's own `time` (field 2) first, then the `Basic` message's `timestamp` (field 3).
  # It used to take whichever was PRESENT, so a `time` in a form this package cannot read
  # (the streaming page gives the field no format) dropped the print even when the frame
  # carried a readable `timestamp` beside it.
  defp tick_time(decoded) do
    case venue_time(decoded) do
      {:ok, at} -> {:ok, at}
      {:error, _unreadable} -> venue_time(%{timestamp: decoded[:basic_timestamp]})
    end
  end

  # **A dropped print is reported, once per reason per connection.** dp-exchange-core issue
  # #40: a consumer subscribed to `:trades` saw no `Trade` in six hours, and this package
  # could not say whether the venue sent none or this module discarded them, because both
  # answered `:ok` in silence. A `:data_quality` notice names the reason and carries the raw
  # fields (strings from the frame, never credentials), which is what a consumer needs to
  # tell "the venue publishes no crypto ticks" from "this decoder cannot read them". Once per
  # reason per connection, so a steady stream of unreadable prints is one line, not thousands.
  #
  # **The set of keys already reported is bounded.** A key can carry something the venue
  # chose (a topic name), and one that carried the offending value itself
  # (`{:invalid_decimal, :price, "<whatever arrived>"}`): a stream of distinct values made a
  # distinct key each, so a notice per message and a set growing for as long as the
  # connection lived. `drop_reason/1` takes the value out of the key (it stays in `details`),
  # and past `@max_reported_drops` distinct reasons nothing more is added or sent.
  defp report_drop(state, key, details) do
    reported = Map.get(state, :drops_reported, MapSet.new())

    if MapSet.member?(reported, key) or MapSet.size(reported) >= @max_reported_drops do
      state
    else
      notify(
        state,
        Notice.new(:data_quality, :webull,
          message: "dropped #{inspect(key)} (first on this connection)",
          details: Map.put(details, :dropped, key)
        )
      )

      Map.put(state, :drops_reported, MapSet.put(reported, key))
    end
  end

  # The reason a frame was dropped, without the venue's value in it. See `report_drop/3`.
  defp drop_reason({:invalid_decimal, field, _value}), do: {:invalid_decimal, field}
  defp drop_reason(reason), do: reason

  # Undocumented on the streaming schema (`docs/reference/webull/streaming-api.md` gives
  # the field no value list) — matched against the same `"B"`/`"S"` the venue's REST tape
  # documents and this package already relies on in `Rest`'s own `tick_side/1`. Anything
  # else is `nil`, a real trade with an unknown aggressor, rather than a guess that would
  # put volume on the wrong side of a delta.
  defp tick_side("B"), do: :buy
  defp tick_side("S"), do: :sell
  defp tick_side(_undocumented), do: nil

  # `{:error, :missing_venue_timestamp}` for a frame the venue did not date, or dated with
  # something this package cannot read. What a caller does with that depends entirely on the
  # TYPE being built, and `venue_time_or_nil/1` below is the other answer.
  defp venue_time(%{timestamp: raw}) when is_binary(raw) do
    case Integer.parse(raw) do
      # Non-positive is refused before the unit question is asked. `DateTime.from_unix/2`
      # answers `{:ok, ~U[1970-01-01 00:00:00Z]}` for 0 and a 1969 instant for negatives —
      # valid `DateTime`s, which is why they are the dangerous case rather than the obvious
      # one. `0` is a common venue sentinel for "unknown", and a frame dated 1970 is a real
      # timestamp to everything downstream. Same rule as `Rest.from_epoch/1`.
      {epoch, ""} when epoch <= 0 -> {:error, :missing_venue_timestamp}
      # **The streaming schema gives `timestamp` and `time` no unit and no format** (a bare
      # `string`, `docs/reference/webull/streaming-api.md`). Seconds versus milliseconds is
      # the same ten-or-thirteen-digit reading `Rest.from_epoch/1` makes of REST pages that DO
      # state theirs: UNMEASURED on this stream. A frame in any other form (an ISO string, say)
      # is `:missing_venue_timestamp`, not a guess. More than thirteen digits is neither unit -
      # read as milliseconds, a microsecond or nanosecond value became a valid `DateTime` tens
      # of thousands of years out.
      {epoch, ""} when epoch > 9_999_999_999_999 -> {:error, :missing_venue_timestamp}
      {epoch, ""} when epoch > 100_000_000_000 -> DateTime.from_unix(epoch, :millisecond)
      {epoch, ""} -> DateTime.from_unix(epoch)
      _not_an_epoch -> {:error, :missing_venue_timestamp}
    end
  end

  defp venue_time(_absent), do: {:error, :missing_venue_timestamp}

  # For the types whose contract makes the venue's time OPTIONAL.
  #
  # `emit_top_of_book/2` and `emit_decoded/2` used to gate on `venue_time/1` and emit nothing
  # when it failed, under "on a stream, refusing to substitute means dropping the frame
  # rather than stamping it with our own clock". Refusing to substitute is right, and that
  # was not it: writing our own clock into `venue_time` would be the substitution, and
  # emitting `nil` there is its opposite.
  #
  # `Core.Types.TopOfBook` enforces `[:symbol, :observed_at, :provider]` and `Core.Types.Quote`
  # `[:symbol, :price, :observed_at, :provider]`. Neither enforces the venue's time, and
  # `observed_at` — always present, and documented as "a different, honest fact" rather than a
  # stand-in — is what states freshness. A real bid, ask or traded price was being discarded
  # over a field the contract marks optional.
  #
  # `Rest.top_of_book_time/1` has always given exactly this answer on the other transport, so
  # the same venue and the same type disagreed depending on how the value arrived.
  #
  # **`emit_trade/2` still gates on `venue_time/1`, and that is not an inconsistency**:
  # `Core.Types.Trade` lists `:timestamp` in `@enforce_keys` and types it non-nullable, so a
  # print this package cannot place in time is genuinely not one it can report. The answers
  # differ because the contracts differ, which is the only thing that licenses them to.
  defp venue_time_or_nil(decoded) do
    case venue_time(decoded) do
      {:ok, at} -> at
      {:error, _unstated} -> nil
    end
  end

  defp notify(state, notice), do: send(state.subscriber, {:dp_exchange, :webull, notice})

  defp decimal(nil), do: nil

  # `Decimal.new/1` raises on a string that is not a number — a real, previously observed
  # response shape from a delisted Webull crypto pair, which returns "null" for a price
  # field. `Decimal.parse/1`, requiring the whole string be consumed, does not.
  #
  # `Decimal.parse/1` alone is not a sufficient guard, though: "NaN", "Inf" and "-Inf" all
  # fully parse, and a NaN or Infinity flowing downstream as a real price is worse than the
  # crash this replaced — it poisons a calculation silently instead of failing visibly.
  defp decimal(value) when is_binary(value) do
    case Decimal.parse(value) do
      {parsed, ""} ->
        # An exponent past +-1000 is no price on this venue; arithmetic over `1E999999999`
        # allocates a gigabyte integer. Chosen, not measured. See `Rest`'s `decimal/1`.
        if Decimal.nan?(parsed) or Decimal.inf?(parsed) or abs(parsed.exp) > 1_000,
          do: nil,
          else: parsed

      _unparsable ->
        nil
    end
  end

  defp decimal(_other), do: nil

  # `Quote.price`, `Trade.price` and `Trade.quantity` are all required, and a `nil` there
  # is the same substitution a raise would have been, wearing a quieter shape — a struct's
  # own field list does not check that a required value is non-nil, only that the key was
  # given. `field` names which one failed, since `emit_trade/2` checks two.
  defp required_decimal(value, field) do
    case decimal(value) do
      nil -> {:error, {:invalid_decimal, field, value}}
      parsed -> {:ok, parsed}
    end
  end
end
