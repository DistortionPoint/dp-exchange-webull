defmodule DpExchange.Webull.MqttPacket do
  @moduledoc """
  MQTT 3.1.1 packet encode/decode — only the packets this venue needs.

  ## Why not a full MQTT client library

  The reachable broker is `wss://data-api.webull.com:8883/mqtt` — MQTT **over WebSocket**.
  Tortoise311 ships `Transport.Tcp` and `Transport.SSL` only, and its transport behaviour
  is sixteen callbacks modelling an **active-mode byte stream**: `setopts`,
  `controlling_process`, `{:tcp, socket, data}` messages to an owner process. Shimming a
  frame-oriented WebSocket into that faithfully is more moving parts, and more ways to be
  subtly wrong, than encoding the eight packet types actually used here.

  The connection lifecycle is already solved by `websockex`, which this family runs for
  several venues. Only the framing was missing.

  ## Packets implemented

  Outbound: `CONNECT` (1), `SUBSCRIBE` (8), `PINGREQ` (12), `DISCONNECT` (14).
  Inbound: `CONNACK` (2), `SUBACK` (9), `PUBLISH` (3), `PINGRESP` (13).

  **QoS 0 throughout**, which is why `PUBACK`/`PUBREC`/`PUBREL`/`PUBCOMP` are absent: a
  dropped price tick is replaced by the next one. Higher QoS would buy redelivery of stale
  prices at the cost of broker-side queueing — the wrong trade for a feed where only the
  newest value matters.

  ## Frame boundaries are not packet boundaries

  `decode/1` returns `{:ok, packet, rest}` so a caller holding a byte buffer can loop. A
  WebSocket frame may carry several MQTT packets or half of one, and assuming otherwise is
  a classic way to lose every packet after the first coalesced frame.

  `{:error, :incomplete}` means "need more bytes" and is an ordinary state, not a failure.

  ## Remaining length

  MQTT encodes variable-header-plus-payload size as a base-128 varint of **at most four
  bytes**. The encoder handles the full range because a truncated length silently corrupts
  every subsequent packet in the stream rather than failing where the mistake was made.
  """

  import Bitwise

  @connect 1
  @connack 2
  @publish 3
  @subscribe 8
  @suback 9
  @pingreq 12
  @pingresp 13
  @disconnect 14

  @protocol_name "MQTT"
  @protocol_level 4

  @doc """
  `CONNECT` with a clean session.

  `client_id` is Webull's `session_id` — **the same value the HTTP subscribe call names**,
  which is the only thing joining the two transports. `username` is the App Key. The
  password is documented as "any value" and is not validated by this broker, so it is sent
  to satisfy the flag rather than to authenticate; authorisation happens on the signed
  HTTP subscribe.

  `clean_session` is set: there is no durable subscription state worth resuming, and a
  resumed session would replay stale queued prices on reconnect. The venue does not restore
  subscriptions across a reconnect anyway.
  """
  @spec connect(String.t(), String.t(), String.t(), pos_integer()) :: binary()
  def connect(client_id, username, password, keep_alive_s \\ 60) do
    # bit 7 username, bit 6 password, bit 1 clean session
    flags = 0b1100_0010
    payload = encode_string(client_id) <> encode_string(username) <> encode_string(password)

    variable_header =
      encode_string(@protocol_name) <> <<@protocol_level, flags, keep_alive_s::16>>

    fixed_header(@connect, 0) <>
      encode_remaining_length(byte_size(variable_header <> payload)) <>
      variable_header <> payload
  end

  @doc """
  `SUBSCRIBE` to `topics` at QoS 0.

  `packet_id` must be non-zero — MQTT reserves 0 — and is echoed in the `SUBACK` so a
  caller can match them.
  """
  @spec subscribe([String.t()], 1..65_535) :: binary()
  def subscribe(topics, packet_id) when is_list(topics) and packet_id > 0 do
    payload = Enum.map_join(topics, fn topic -> encode_string(topic) <> <<0>> end)
    variable_header = <<packet_id::16>>

    # SUBSCRIBE requires the reserved flags 0b0010; a broker is entitled to close the
    # connection outright if they are anything else.
    fixed_header(@subscribe, 0b0010) <>
      encode_remaining_length(byte_size(variable_header <> payload)) <>
      variable_header <> payload
  end

  @spec pingreq() :: binary()
  def pingreq, do: fixed_header(@pingreq, 0) <> <<0>>

  @spec disconnect() :: binary()
  def disconnect, do: fixed_header(@disconnect, 0) <> <<0>>

  @doc """
  Decodes one inbound packet from the front of a buffer.

  Returns `{:ok, packet, rest}`, `{:error, :incomplete}` when more bytes are needed, or
  `{:error, :malformed_length}` when the stream cannot be resynchronised.
  """
  @spec decode(binary()) ::
          {:ok, term(), binary()} | {:error, :incomplete} | {:error, :malformed_length}
  def decode(<<type::4, flags::4, rest::binary>>) do
    case decode_remaining_length(rest) do
      {:ok, length, after_length} when byte_size(after_length) >= length ->
        <<body::binary-size(length), remainder::binary>> = after_length
        {:ok, decode_body(type, flags, body), remainder}

      # The length decoded but the body has not all arrived yet.
      {:ok, _length, _partial_body} ->
        {:error, :incomplete}

      :incomplete ->
        {:error, :incomplete}

      # A fifth continuation byte. MQTT caps the remaining-length varint at four bytes, so
      # this is a corrupt stream, not a short read.
      #
      # **The adapter this was ported from returned `:incomplete` here**, which tells the
      # caller to wait for more bytes — and no future byte can fix a length that is already
      # invalid. A corrupt frame would have parked the read buffer forever, with the socket
      # up, the subscription live, and nothing arriving. Silence is the worst failure this
      # family has, so a stream that cannot be resynchronised must say so and be reset.
      :malformed ->
        {:error, :malformed_length}
    end
  end

  def decode(_too_short), do: {:error, :incomplete}

  # CONNACK: a session-present flag then a return code. 0 is accepted; the rest are the
  # spec's refusal reasons, surfaced verbatim because "unauthorized" and "bad protocol
  # version" demand completely different fixes.
  defp decode_body(@connack, _flags, <<_session_present, return_code, _rest::binary>>) do
    {:connack, return_code}
  end

  defp decode_body(@suback, _flags, <<packet_id::16, codes::binary>>) do
    {:suback, packet_id, :binary.bin_to_list(codes)}
  end

  # PUBLISH carries a packet identifier after the topic **only at QoS 1 or 2**, and the QoS
  # lives in bits 2-1 of the fixed-header flags.
  #
  # This package subscribes at QoS 0 and so should never see a higher one — but "should
  # never" is not a decoder's business. Reading the flags costs nothing, and ignoring them
  # means that if the broker ever publishes at QoS 1, two bytes of packet identifier are
  # read as the head of the protobuf payload. That does not fail: it decodes into a
  # slightly wrong message, which is this family's named failure mode arriving through the
  # wire format.
  defp decode_body(@publish, flags, body) do
    qos = flags |> bsr(1) |> band(0x03)

    case body do
      <<topic_length::16, topic::binary-size(topic_length), rest::binary>> ->
        publish(topic, qos, rest)

      _truncated ->
        {:unhandled, @publish, body}
    end
  end

  defp decode_body(@pingresp, _flags, _body), do: :pingresp
  defp decode_body(type, _flags, body), do: {:unhandled, type, body}

  defp publish(topic, 0, payload), do: {:publish, topic, payload}

  defp publish(topic, _qos, <<_packet_id::16, payload::binary>>),
    do: {:publish, topic, payload}

  defp publish(topic, _qos, payload), do: {:publish, topic, payload}

  # --- primitives ---------------------------------------------------------

  defp fixed_header(type, flags), do: <<type::4, flags::4>>

  defp encode_string(value) when is_binary(value), do: <<byte_size(value)::16>> <> value

  # Base-128 varint, seven bits per byte, high bit continues. At most four bytes.
  defp encode_remaining_length(length) when length < 128, do: <<length>>

  defp encode_remaining_length(length) do
    <<1::1, band(length, 0x7F)::7>> <> encode_remaining_length(bsr(length, 7))
  end

  defp decode_remaining_length(binary), do: decode_remaining_length(binary, 0, 0, 0)

  defp decode_remaining_length(_binary, _acc, _shift, count) when count >= 4, do: :malformed

  defp decode_remaining_length(<<1::1, chunk::7, rest::binary>>, acc, shift, count),
    do: decode_remaining_length(rest, acc + bsl(chunk, shift), shift + 7, count + 1)

  defp decode_remaining_length(<<0::1, chunk::7, rest::binary>>, acc, shift, _count),
    do: {:ok, acc + bsl(chunk, shift), rest}

  defp decode_remaining_length(_truncated, _acc, _shift, _count), do: :incomplete
end
