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
        # Each side's best level is decoded ONCE and read twice, rather than decoded twice
        # and read once. `level_price/1` and `level_size/1` each ran `decode_message/1` over
        # the whole level binary — and an `AskBid` is not a two-field message: the venue's
        # schema gives it `repeated Order order = 3` and `repeated Broker broker = 4`, so on
        # an MPID-level book that binary carries every market maker at the price, and all of
        # it was walked twice to read two strings out of it.
        {ask_price, ask_size} = fields |> first_repeated(2) |> level()
        {bid_price, bid_size} = fields |> first_repeated(3) |> level()

        {:ok,
         %{
           symbol: symbol,
           ask: ask_price,
           ask_size: ask_size,
           bid: bid_price,
           bid_size: bid_size,
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
  def decode_message(binary), do: binary |> decode_message(%{}) |> reverse_repeats()

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

  # `Map.fetch/2`, not `Map.get/2`. `decode_value/2` returns `nil` as the VALUE of a 64-bit
  # or 32-bit field it stepped over, and `Map.get/2` cannot tell that stored `nil` from an
  # absent key — so the next occurrence of the same field number REPLACED the placeholder
  # instead of accumulating beside it.
  #
  # **No decoded field changes value because of this, and that was checked rather than
  # assumed.** Every reader in this module — `scalar/1`, `decode_nested/1`,
  # `first_repeated/2` — filters for `is_binary/1`, so a lost `nil` is a lost nothing; the
  # difference is visible only through `decode_message/1` itself, which is public. It is
  # fixed as a latent trap, not as a live defect: the conflation holds only while every
  # stepped-over wire type decodes to `nil`, and the first `decode_value/2` clause to return
  # a meaningful value for a field number the schema also uses would turn it into a silent
  # drop with nothing in the tests pointing at it.
  defp accumulate(acc, field_number, value) do
    case Map.fetch(acc, field_number) do
      :error -> Map.put(acc, field_number, value)
      {:ok, existing} when is_list(existing) -> Map.put(acc, field_number, [value | existing])
      {:ok, existing} -> Map.put(acc, field_number, [value, existing])
    end
  end

  # Repeats accumulate by PREPENDING and the whole map is reversed once, rather than
  # appending with `existing ++ [value]` — which is O(n) per level and so O(n²) per message.
  # Measured on a synthetic book before the change: 5 levels a side 2.8us, 50 levels 12.7us,
  # 100 levels 33.6us, 200 levels 120.1us — the shape of a quadratic, and `AskBid`'s own
  # `repeated Order` and `repeated Broker` mean the level binaries walk the same accumulator
  # again for every market maker quoted at the price.
  #
  # Wire order is what `scalar/1` (last occurrence) and `first_repeated/2` (first entry)
  # both read by, so the reversal is not optional bookkeeping — it is the thing that keeps
  # those two reading what they say they read.
  defp reverse_repeats(fields) do
    Map.new(fields, fn
      {field_number, value} when is_list(value) -> {field_number, Enum.reverse(value)}
      {field_number, value} -> {field_number, value}
    end)
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

  # `Basic basic = 1` is singular in the schema, so a wire walk seeing it more than once
  # is the same legal-but-unusual case `scalar/1` documents for a scalar field: the LAST
  # occurrence is proto3's rule, not the first. Matching `scalar/1`'s own rule here rather
  # than picking the first keeps the two consistent — the bug this module's moduledoc
  # records ("keep the LAST occurrence... but the code produced a list... rejected") was
  # about a top-level scalar; this is the same rule applied to the one nested field this
  # schema has.
  defp decode_nested(list) when is_list(list) do
    case Enum.filter(list, &is_binary/1) do
      [] -> %{}
      binaries -> binaries |> List.last() |> decode_message()
    end
  end

  defp decode_nested(_absent), do: %{}

  # The first binary, not simply the first element — filtered exactly as `scalar/1` and
  # `decode_nested/1` already filter, and for the reason this module's own moduledoc gives:
  # "A truncated or unparseable tail ends the walk with whatever was read rather than
  # raising. This runs in the socket process, and one malformed frame must not cost the
  # connection."
  #
  # It took `[first | _rest]` unfiltered, so a field number arriving once with a wire type
  # this schema never uses and once as the real level accumulated as `[7, <<level>>]`, and
  # the `7` went to `level_price/1`, which has clauses for a binary and for `nil` and none
  # for an integer. `FunctionClauseError` — raised inside the socket process, with no
  # `rescue` anywhere between here and `handle_frame/2`, so the connection went down and
  # came back to be handed the same frame again. The two sibling readers in this module were
  # already defensive; this one was not, which is the whole of the difference.
  #
  # Skipping a non-binary rather than stopping at it is also what keeps the *good* level:
  # `Enum.find/2` walks past the junk to the entry that really is an `AskBid`.
  defp first_repeated(fields, field_number) do
    case Map.get(fields, field_number) do
      list when is_list(list) -> Enum.find(list, &is_binary/1)
      value when is_binary(value) -> value
      _absent -> nil
    end
  end

  # `AskBid { string price = 1; string size = 2; }` — the venue's own schema, verbatim in
  # `docs/reference/webull/streaming-api.md`. Field 2 was walked off the wire by
  # `decode_message/1` and then discarded, while `Socket` published `bid_size: nil` under a
  # comment stating as fact that "the venue's book message carries prices and no sizes". It
  # carries both. A consumer sizing an order against that `nil` was being told the depth was
  # unpublished when it had been published and thrown away.
  #
  # `present/2` maps an empty string to `nil`, which is what keeps the distinction
  # `Core.Types.TopOfBook` insists on: `nil` is "not published", and is not a zero. A level
  # that really does state `"0"` reaches a caller as a zero, because that is what the venue
  # said.
  #
  # Both are read from ONE decode of the level. They used to be `level_price/1` and
  # `level_size/1`, each walking the same binary separately.
  defp level(nil), do: {nil, nil}

  defp level(binary) when is_binary(binary) do
    decoded = decode_message(binary)
    {present(decoded, 1), present(decoded, 2)}
  end
end
