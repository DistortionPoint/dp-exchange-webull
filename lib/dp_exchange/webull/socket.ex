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

  A `:malformed_length` means the stream can no longer be resynchronised. The buffer is
  dropped and a notice raised rather than retaining bytes that can never parse: keeping
  them would leave a live socket delivering nothing, which is the failure mode this family
  ranks worst.

  ## Keep-alive

  The venue's CONNECT carries a keep-alive interval, and MQTT requires the client to send
  something within it. `PINGREQ` goes out at half that interval — early enough that one
  lost ping is not a disconnect.

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

  alias DpExchange.Core.Notice
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
  @socket_connect_timeout_ms 3_000
  @socket_recv_timeout_ms 2_000

  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    url = Keyword.fetch!(opts, :url)

    state = %{
      subscriber: Keyword.fetch!(opts, :subscriber),
      session_id: Keyword.fetch!(opts, :session_id),
      app_key: Keyword.fetch!(opts, :app_key),
      buffer: <<>>,
      connected?: false
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
    |> Keyword.take([:socket_connect_timeout, :socket_recv_timeout])
    |> Keyword.put_new(:socket_connect_timeout, @socket_connect_timeout_ms)
    |> Keyword.put_new(:socket_recv_timeout, @socket_recv_timeout_ms)
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
  def handle_disconnect(%{reason: reason}, state) do
    # session_id rides along so a Feed managing several shards' sockets can tell which
    # one just dropped — the message alone carries no sender identity otherwise.
    notify(
      state,
      Notice.new(:link_down, :webull,
        details: %{reason: inspect(reason), session_id: state.session_id}
      )
    )

    {:reconnect, %{state | buffer: <<>>, connected?: false}}
  end

  @impl true
  def handle_info(:send_connect, state) do
    # The password is documented as "any value" — authorisation happens on the signed HTTP
    # subscribe, so this is sent to satisfy the protocol flag rather than to authenticate.
    packet = MqttPacket.connect(state.session_id, state.app_key, "x", @keep_alive_s)
    Process.send_after(self(), :ping, div(@keep_alive_s, 2) * 1_000)
    {:reply, {:binary, packet}, state}
  end

  def handle_info(:ping, state) do
    Process.send_after(self(), :ping, div(@keep_alive_s, 2) * 1_000)
    {:reply, {:binary, MqttPacket.pingreq()}, state}
  end

  def handle_info(_other, state), do: {:ok, state}

  @impl true
  def handle_frame({:binary, data}, state) do
    drain(%{state | buffer: state.buffer <> data})
  end

  def handle_frame(_other, state), do: {:ok, state}

  # --- packet handling ----------------------------------------------------

  defp drain(state) do
    case MqttPacket.decode(state.buffer) do
      {:ok, packet, rest} ->
        state |> handle_packet(packet) |> Map.put(:buffer, rest) |> drain()

      {:error, :incomplete} ->
        {:ok, state}

      {:error, :malformed_length} ->
        # Unrecoverable: no future byte repairs an invalid length. Dropping the buffer and
        # saying so beats a live socket that silently delivers nothing.
        notify(state, Notice.new(:data_quality, :webull, details: %{dropped: :malformed_frame}))
        {:ok, %{state | buffer: <<>>}}
    end
  end

  defp handle_packet(state, {:connack, 0}) do
    # session_id rides along so a Feed managing several shards' sockets can tell which
    # one just came up — see the matching comment on handle_disconnect/2.
    notify(state, Notice.new(:link_up, :webull, details: %{session_id: state.session_id}))
    %{state | connected?: true}
  end

  # The venue's connection error codes mean genuinely different things, and two of them
  # are one integer apart: 103/104 are credential answers, 105 is our own behaviour.
  # Reporting a connection-limit breach as rejected credentials sends an operator to
  # rotate a key that is fine.
  defp handle_packet(state, {:connack, code}) when code in [3, 103, 104] do
    notify(state, Notice.new(:credentials_rejected, :webull, details: %{connack: code}))
    state
  end

  defp handle_packet(state, {:connack, 105}) do
    notify(
      state,
      Notice.new(:degraded, :webull,
        details: %{connack: 105, reason: :connection_limit},
        message: "five concurrent connections per App Key; the venue holds state ~1 minute"
      )
    )

    state
  end

  defp handle_packet(state, {:connack, code}) do
    notify(state, Notice.new(:link_down, :webull, details: %{connack: code}))
    state
  end

  defp handle_packet(state, {:publish, topic, payload}) do
    emit(state, topic, payload)
    state
  end

  defp handle_packet(state, _other), do: state

  # Three topics are protobuf, one is JSON, one is empty. A handler assuming a single
  # encoding drops four fifths of the traffic — which is what the prior adapter did by
  # calling `Jason.decode/1` on every payload.
  defp emit(state, "snapshot", payload),
    do: emit_decoded(state, QuoteProto.decode_snapshot(payload))

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
  defp emit(state, "quote", payload) do
    case QuoteProto.decode_quote(payload) do
      {:ok, %{bid: bid, ask: ask} = decoded} when is_binary(bid) or is_binary(ask) ->
        emit_top_of_book(state, decoded)

      _no_levels ->
        :ok
    end
  end

  # A `tick` message is one print — the tape. Unlike `snapshot` and `quote`, this topic is
  # not requested by default everywhere in the family; on this venue it is, though (see
  # `Subscription`'s default `sub_types`), so a subscriber gets `Core.Types.Trade` on this
  # topic the same way it gets `Quote` and `TopOfBook` on the other two, with no extra
  # option to ask for it — the facade hides the venue's `sub_types` vocabulary the same way
  # it hides everything else about how this venue is reached.
  defp emit(state, "tick", payload), do: emit_trade(state, QuoteProto.decode_tick(payload))

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
    case Jason.decode(payload) do
      {:ok, %{} = body} ->
        notify(
          state,
          Notice.new(:degraded, :webull,
            message: venue_notice_text(body),
            details: %{venue_notice: body}
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

  # No non-binary clause: dialyzer proves this call site always passes a binary, and a dead
  # fallback is the unreachable code assertion 16 exists to find. A non-binary would raise
  # here, which is the fail-closed answer rather than a silent `:ok`.
  defp emit_unparsed_notice(state, payload) when is_binary(payload) do
    if String.valid?(payload) and String.trim(payload) != "" do
      notify(
        state,
        Notice.new(:degraded, :webull,
          message: String.trim(payload),
          details: %{venue_notice_unparsed: payload}
        )
      )
    end

    :ok
  end

  defp venue_notice_text(%{"content" => content}) when is_binary(content) do
    case String.trim(content) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp venue_notice_text(_no_content), do: nil

  defp emit_top_of_book(state, decoded) do
    with {:ok, timestamp} <- venue_time(decoded) do
      send(
        state.subscriber,
        {:dp_exchange, :webull,
         %TopOfBook{
           symbol: SymbolFormat.to_canonical_symbol(decoded.symbol),
           bid: decimal(decoded[:bid]),
           ask: decimal(decoded[:ask]),
           # The venue's book message carries prices and no sizes, so these stay nil —
           # not published, and specifically not zero.
           bid_size: nil,
           ask_size: nil,
           venue_time: timestamp,
           observed_at: DateTime.utc_now(),
           provider: :webull
         }}
      )
    end

    :ok
  end

  defp emit_decoded(state, {:ok, decoded}) do
    with {:ok, timestamp} <- venue_time(decoded),
         {:ok, price} <- required_decimal(decoded[:price], :price) do
      send(
        state.subscriber,
        {:dp_exchange, :webull,
         %Quote{
           symbol: SymbolFormat.to_canonical_symbol(decoded.symbol),
           price: price,
           volume: nil,
           venue_time: timestamp,
           observed_at: DateTime.utc_now(),
           provider: :webull
         }}
      )
    end

    :ok
  end

  defp emit_decoded(_state, :error), do: :ok

  # `id: nil` — see the moduledoc's "`tick` carries no trade id". `Trade.new/1` is
  # deliberately not used here: it would raise on the very absence this comment and the
  # moduledoc both document as real rather than accidental.
  defp emit_trade(state, {:ok, decoded}) do
    with {:ok, timestamp} <- venue_time(decoded),
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
    end

    :ok
  end

  defp emit_trade(_state, :error), do: :ok

  # Undocumented on the streaming schema (`docs/reference/webull/streaming-api.md` gives
  # the field no value list) — matched against the same `"B"`/`"S"` the venue's REST tape
  # documents and this package already relies on in `Rest`'s own `tick_side/1`. Anything
  # else is `nil`, a real trade with an unknown aggressor, rather than a guess that would
  # put volume on the wrong side of a delta.
  defp tick_side("B"), do: :buy
  defp tick_side("S"), do: :sell
  defp tick_side(_undocumented), do: nil

  # Absent, and nothing is emitted. On a stream, refusing to substitute means dropping the
  # frame rather than stamping it with our own clock.
  defp venue_time(%{timestamp: raw}) when is_binary(raw) do
    case Integer.parse(raw) do
      {epoch, ""} when epoch > 100_000_000_000 -> DateTime.from_unix(epoch, :millisecond)
      {epoch, ""} -> DateTime.from_unix(epoch)
      _not_an_epoch -> {:error, :missing_venue_timestamp}
    end
  end

  defp venue_time(_absent), do: {:error, :missing_venue_timestamp}

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
        if Decimal.nan?(parsed) or Decimal.inf?(parsed), do: nil, else: parsed

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
