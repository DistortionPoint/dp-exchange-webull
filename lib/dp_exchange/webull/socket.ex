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
  only job is to connect, stay connected, and turn payloads into `Core.Types.Quote`.
  """

  use WebSockex

  alias DpExchange.Core.Notice
  alias DpExchange.Core.Types.{Quote, TopOfBook}
  alias DpExchange.Webull.{MqttPacket, QuoteProto, SymbolFormat}

  require Logger

  @keep_alive_s 60

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

    WebSockex.start_link(url, __MODULE__, state)
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

  defp emit(state, "notice", payload) do
    case Jason.decode(payload) do
      {:ok, %{} = body} ->
        notify(state, Notice.new(:degraded, :webull, details: %{venue_notice: body}))

      _undecodable ->
        :ok
    end
  end

  defp emit(_state, _topic, _payload), do: :ok

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
         {:ok, price} <- required_decimal(decoded[:price]) do
      send(
        state.subscriber,
        {:dp_exchange, :webull,
         %Quote{
           symbol: SymbolFormat.to_canonical_symbol(decoded.symbol),
           price: price,
           volume: nil,
           timestamp: timestamp,
           provider: :webull
         }}
      )
    end

    :ok
  end

  defp emit_decoded(_state, :error), do: :ok

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

  # `Quote.price` is required and a `nil` there is the same substitution a raise would
  # have been, wearing a quieter shape — a struct's own field list does not check that a
  # required value is non-nil, only that the key was given. Refuse the frame instead of
  # delivering a Quote with no price.
  defp required_decimal(value) do
    case decimal(value) do
      nil -> {:error, {:invalid_decimal, :price, value}}
      parsed -> {:ok, parsed}
    end
  end
end
