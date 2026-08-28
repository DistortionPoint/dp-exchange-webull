defmodule DpExchange.Webull.QuoteProto do
  @moduledoc """
  Minimal proto3 decoder for the three Webull streaming payloads this package consumes.

  Webull's MQTT feed publishes **protobuf**, not JSON. The prior adapter's message handler
  called `Jason.decode/1`, so even once its connection and subscription were repaired every
  payload would still have been discarded as malformed — three bugs stacked, only the last
  of which was visible.

  ## Why hand-rolled rather than the `protobuf` package

  The schema is **six messages of nothing but `string` and `repeated <message>`**, so
  exactly one wire type matters — length-delimited (2) — plus varints for lengths and
  field headers. No floats, no zigzag, no packed repeated fields. Taking a dependency and a
  codegen step to read that is more machinery than the thing it reads.

  The venue's own definitions, verbatim, are in
  `docs/reference/webull/streaming-api.md`.

  **Every field is a string**, which is the reason this venue's numbers are trustworthy: no
  float ever enters, so nothing is rounded on the way in. Values go straight to
  `Decimal.new/1` at the boundary that needs them.

  ## Unknown fields are skipped, not fatal

  Proto3's own compatibility rule, and the thing that keeps a venue adding a field from
  taking the socket down. Wire types this schema never uses — varint, 64-bit, 32-bit — are
  parsed only far enough to step over them.

  A truncated or unparseable tail ends the walk with whatever was read rather than raising.
  This runs in the socket process, and one malformed frame must not cost the connection.

  ## Repeated versus scalar, and a bug this decoder used to have

  A wire walk cannot tell a scalar field from a repeated one — only the schema knows. So
  every repeat accumulates into a list, and the *reader* decides which it wanted.

  The adapter this was ported from accumulated the same way but read fields directly, with
  a `is_binary(value)` guard. Its comment said scalar fields "keep the LAST occurrence,
  which is proto3's rule" — but the code produced a **list** for a scalar sent twice, the
  guard then failed, and the entire message was rejected. Legal-on-the-wire input, dropped
  silently.

  Here `scalar/1` takes the last occurrence, which *is* proto3's rule, and `repeated/1`
  keeps the whole list. The comment and the code now agree.
  """

  import Bitwise

  @typedoc "Field number to decoded value. Repeats accumulate in wire order."
  @type field_map :: %{non_neg_integer() => term()}

  @doc """
  Decodes a `Snapshot` — the payload carrying a usable last price and volume.

  `Quote` carries book levels and `Tick` carries individual trades; this is the one a
  price collector wants.
  """
  @spec decode_snapshot(binary()) :: {:ok, map()} | :error
  def decode_snapshot(payload) when is_binary(payload) do
    fields = decode_message(payload)
    basic = fields |> Map.get(1) |> decode_nested()

    with symbol when is_binary(symbol) <- present(basic, 1),
         price when is_binary(price) <- present(fields, 3) do
      {:ok,
       %{
         symbol: symbol,
         price: price,
         volume: present(fields, 8),
         # `trade_time` (2) is the venue's own time for the print. Preferred over
         # `Basic.timestamp` (3), which is when the message was assembled — they differ,
         # and only the first one describes the trade.
         timestamp: present(fields, 2) || present(basic, 3)
       }}
    else
      _missing_required -> :error
    end
  end

  def decode_snapshot(_other), do: :error

  @doc "Decodes a `Tick` — a single trade."
  @spec decode_tick(binary()) :: {:ok, map()} | :error
  def decode_tick(payload) when is_binary(payload) do
    fields = decode_message(payload)
    basic = fields |> Map.get(1) |> decode_nested()

    with symbol when is_binary(symbol) <- present(basic, 1),
         price when is_binary(price) <- present(fields, 3) do
      {:ok,
       %{
         symbol: symbol,
         price: price,
         volume: present(fields, 4),
         side: present(fields, 5),
         timestamp: present(fields, 2) || present(basic, 3)
       }}
    else
      _missing_required -> :error
    end
  end

  def decode_tick(_other), do: :error

  @doc """
  Decodes a `Quote` — book levels — into the venue's own best bid and ask.

  The repeated fields arrive in book order, so the first entry of each side is the best
  level. **No mid is computed here.** A mid is a decision about what a price means, and it
  belongs with the caller that also knows whether both sides are present.
  """
  @spec decode_quote(binary()) :: {:ok, map()} | :error
  def decode_quote(payload) when is_binary(payload) do
    fields = decode_message(payload)
    basic = fields |> Map.get(1) |> decode_nested()

    case present(basic, 1) do
      symbol when is_binary(symbol) ->
        {:ok,
         %{
           symbol: symbol,
           ask: fields |> first_repeated(2) |> level_price(),
           bid: fields |> first_repeated(3) |> level_price(),
           timestamp: present(basic, 3)
         }}

      _no_symbol ->
        :error
    end
  end

  def decode_quote(_other), do: :error

  # --- proto3 wire format -------------------------------------------------

  @doc "Field number to value, repeats in wire order. Exposed for tests and for `Socket`."
  @spec decode_message(binary()) :: field_map()
  def decode_message(binary), do: decode_message(binary, %{})

  defp decode_message(<<>>, acc), do: acc

  defp decode_message(binary, acc) do
    with {header, rest} <- decode_varint(binary),
         field_number = bsr(header, 3),
         wire_type = band(header, 0x07),
         {value, rest} <- decode_value(wire_type, rest) do
      decode_message(rest, accumulate(acc, field_number, value))
    else
      _undecodable -> acc
    end
  end

  # Length-delimited: strings and nested messages, which is every field in this schema.
  # Kept as a binary — whether it is text or a sub-message depends on the field, and only
  # the caller knows which.
  defp decode_value(2, binary) do
    with {length, rest} <- decode_varint(binary),
         <<value::binary-size(length), remainder::binary>> <- rest do
      {value, remainder}
    else
      _truncated -> :error
    end
  end

  # Wire types this schema never uses, stepped over so an added field cannot break the walk.
  defp decode_value(0, binary), do: decode_varint(binary)
  defp decode_value(1, <<_skip::binary-size(8), rest::binary>>), do: {nil, rest}
  defp decode_value(5, <<_skip::binary-size(4), rest::binary>>), do: {nil, rest}
  defp decode_value(_unknown, _binary), do: :error

  defp decode_varint(binary), do: decode_varint(binary, 0, 0)

  defp decode_varint(<<1::1, chunk::7, rest::binary>>, acc, shift),
    do: decode_varint(rest, bor(acc, bsl(chunk, shift)), shift + 7)

  defp decode_varint(<<0::1, chunk::7, rest::binary>>, acc, shift),
    do: {bor(acc, bsl(chunk, shift)), rest}

  defp decode_varint(_truncated, _acc, _shift), do: :error

  defp accumulate(acc, field_number, value) do
    case Map.get(acc, field_number) do
      nil -> Map.put(acc, field_number, value)
      existing when is_list(existing) -> Map.put(acc, field_number, existing ++ [value])
      existing -> Map.put(acc, field_number, [existing, value])
    end
  end

  # --- reading ------------------------------------------------------------

  @doc """
  The scalar value of a field: the **last** occurrence, per proto3.

  A wire walk cannot tell a scalar from a repeated field, so a scalar sent twice arrives
  as a list. Reading it with an `is_binary` guard — as the prior adapter did — rejects the
  whole message for input the specification calls legal.
  """
  @spec scalar(field_map(), non_neg_integer()) :: binary() | nil
  def scalar(fields, field_number) do
    case Map.get(fields, field_number) do
      value when is_binary(value) -> value
      list when is_list(list) -> list |> Enum.filter(&is_binary/1) |> List.last()
      _absent -> nil
    end
  end

  # An empty proto3 string is the field being ABSENT, not a value. Passing `""` on as a
  # price turns a missing field into an unparseable number one layer down.
  defp present(fields, field_number) do
    case scalar(fields, field_number) do
      "" -> nil
      value -> value
    end
  end

  defp decode_nested(binary) when is_binary(binary), do: decode_message(binary)
  defp decode_nested([first | _rest]) when is_binary(first), do: decode_message(first)
  defp decode_nested(_absent), do: %{}

  defp first_repeated(fields, field_number) do
    case Map.get(fields, field_number) do
      [first | _rest] -> first
      value when is_binary(value) -> value
      _absent -> nil
    end
  end

  defp level_price(nil), do: nil

  defp level_price(binary) when is_binary(binary) do
    binary |> decode_message() |> present(1)
  end
end
