defmodule DpExchange.Webull.Rest do
  @moduledoc """
  Webull's OpenAPI REST surface — internal.

  ## Every call is signed, including the public-looking ones

  There is no anonymous path here. `/openapi/market-data/crypto/snapshot` needs the same
  App Key and signature as an order. That is why this venue declares
  `credential_benefit: :required` — the first in the family to do so — and why
  `get_price/2` takes credentials that other venues' `get_price/2` does not need.

  A consumer branching on `capabilities/0` learns this before it calls; a consumer that
  assumed market data is free learns it from a 401.

  ## Bars nest one level down, and assuming otherwise returns nothing

  The crypto-bars response is a list of **groups**, each carrying its rows under
  `"result"`:

      [%{"instrument_id" => …, "symbol" => …, "result" => [%{"open" => …}, …]}]

  The adapter this came from once mapped its row decoder over the *group* objects. Groups
  have no `"open"`, `"close"` or `"time"`, so every field resolved to `nil` — the call
  returned a list of all-nil bars, and the backfill logged an empty result for every
  crypto pair. It looked like the venue had no data.

  Both shapes are handled: a group with `"result"` is flattened, and a flat bar decodes
  directly, in case the equities path or a future change sends one.

  ## No volume, anywhere

  Webull's crypto OpenAPI exposes **no trade volume** — not on the bars, not on the
  snapshot, not on the MQTT stream. `volume` is `nil` rather than `0`, because zero is a
  volume and this venue is not reporting one. `capabilities/0` declares
  `reports_trade_volume: false` so a consumer can route volume-dependent work elsewhere
  rather than discovering a column of zeroes.
  """

  alias DpExchange.Core.HttpClient
  alias DpExchange.Core.Types.Quote
  alias DpExchange.Webull.{Auth, Environment, SymbolFormat}

  # Canonical width => the venue's own timespan code.
  #
  # `1w` → `W` is served by the venue and deliberately omitted: a weekly bar's boundary
  # depends on which weekday the venue starts its week, `Core.Timeframe` models no
  # alignment rule for it, and a bar nobody can verify the boundary of is a bar nobody
  # should store.
  @timespans %{
    "1m" => "M1",
    "5m" => "M5",
    "15m" => "M15",
    "30m" => "M30",
    "1h" => "M60",
    "2h" => "M120",
    "4h" => "M240",
    "1d" => "D"
  }

  @doc "Canonical timeframes this venue serves, shortest first."
  @spec timeframes() :: [String.t()]
  def timeframes, do: ~w(1m 5m 15m 30m 1h 2h 4h 1d)

  @doc "Last price for one symbol, from the crypto snapshot endpoint."
  @spec get_price(String.t(), map(), keyword()) ::
          {:ok, Quote.t()} | {:error, term()} | {:refused, term()}
  def get_price(symbol, credentials, opts) do
    native = SymbolFormat.to_exchange_symbol(symbol)
    params = %{"symbols" => native, "category" => "US_CRYPTO"}

    with {:ok, body} <- get("/openapi/market-data/crypto/snapshot", params, credentials, opts),
         {:ok, row} <- first_row(body),
         {:ok, price} <- required(row, ["price", "lastPrice", "last_trade_price"]),
         {:ok, timestamp} <- venue_time(row) do
      {:ok,
       %Quote{
         symbol: SymbolFormat.to_canonical_symbol(native),
         price: decimal(price),
         bid: decimal(value(row, ["bidPrice", "bid_price", "bid"])),
         ask: decimal(value(row, ["askPrice", "ask_price", "ask"])),
         # Not an oversight and not a zero: this venue reports no crypto volume anywhere.
         volume: nil,
         timestamp: timestamp,
         provider: :webull
       }}
    end
  end

  @doc """
  OHLC bars for a symbol and canonical timeframe.

  Bars carry no volume — see the module doc. A bar without a venue timestamp is an
  **error**, not a bar stamped with the local clock.
  """
  @spec get_historical_prices(String.t(), String.t(), keyword(), map(), keyword()) ::
          {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def get_historical_prices(symbol, timeframe, range, credentials, opts) do
    native = SymbolFormat.to_exchange_symbol(symbol)

    with {:ok, timespan} <- timespan(timeframe) do
      params =
        %{"symbol" => native, "category" => "US_CRYPTO", "timespan" => timespan}
        |> put_present("count", Keyword.get(opts, :limit))

      with {:ok, body} <- get("/openapi/market-data/crypto/bars", params, credentials, opts),
           {:ok, bars} <- decode_bars(body, symbol, timeframe) do
        {:ok, Enum.filter(bars, &within?(&1, range))}
      end
    end
  end

  @doc """
  Every crypto symbol the venue lists, canonical.

  Measured 2026-08-05 against `/openapi/instrument/crypto/list`: 342 symbols, every one
  quoted in USD.
  """
  @spec get_symbols(map(), keyword()) ::
          {:ok, [String.t()]} | {:error, term()} | {:refused, term()}
  def get_symbols(credentials, opts) do
    with {:ok, body} <- get("/openapi/instrument/crypto/list", %{}, credentials, opts) do
      {:ok,
       body
       |> rows()
       |> Enum.map(&value(&1, ["symbol", "disSymbol"]))
       |> Enum.reject(&is_nil/1)
       |> Enum.map(&SymbolFormat.to_canonical_symbol/1)
       |> Enum.sort()
       |> Enum.uniq()}
    end
  end

  # --- request ------------------------------------------------------------

  defp get(path, params, credentials, opts) do
    environment = Environment.resolve(opts)
    host = Environment.host(environment)

    request = %{
      path: path,
      query_params: stringify(params),
      body: "",
      host: host,
      timestamp: Auth.timestamp(),
      nonce: Auth.nonce()
    }

    with {:ok, headers} <- Auth.headers(request, credentials) do
      url = Environment.rest_url(environment) <> path <> query(params)

      case HttpClient.request(:get, url, headers, nil, request_opts(opts)) do
        {:ok, %{status: status, body: body}} when status in 200..299 ->
          {:ok, decode(body)}

        # Permanent for the request as sent. A caller whose token expired refreshes and
        # calls again, which is a different request rather than a retry of this one.
        {:ok, %{status: status, body: body}} when status in [400, 401, 403] ->
          {:refused, refusal(body)}

        {:ok, %{status: status, body: body}} ->
          {:error, {:exchange_error, :webull, "HTTP #{status}: #{inspect(body)}"}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp request_opts(opts) do
    opts
    |> Keyword.take([:limiter, :timeout, :retry_attempts, :log_requests, :plug, :req_adapter])
    |> Keyword.merge(provider: :webull, raw_status: true)
  end

  defp query(params) when map_size(params) == 0, do: ""
  defp query(params), do: "?" <> URI.encode_query(stringify(params))

  # --- decoding -----------------------------------------------------------

  # Groups carry their rows under "result"; a flat bar decodes directly. Mapping a row
  # decoder over the groups yields all-nil bars, which reads as "the venue has no data".
  defp decode_bars(body, symbol, timeframe) do
    body
    |> rows()
    |> Enum.flat_map(fn
      %{"result" => rows} when is_list(rows) -> rows
      %{} = flat_bar -> [flat_bar]
      _other -> []
    end)
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
      case decode_bar(row, symbol, timeframe) do
        {:ok, bar} -> {:cont, {:ok, [bar | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, bars} -> {:ok, bars |> Enum.reverse() |> Enum.sort_by(& &1.timestamp, DateTime)}
      error -> error
    end
  end

  defp decode_bar(row, symbol, timeframe) do
    with {:ok, timestamp} <- venue_time(row) do
      {:ok,
       %{
         symbol: symbol,
         timeframe: timeframe,
         timestamp: timestamp,
         open: decimal(value(row, ["open"])),
         high: decimal(value(row, ["high"])),
         low: decimal(value(row, ["low"])),
         close: decimal(value(row, ["close"])),
         # No volume on this venue's crypto bars. `nil`, never `0`.
         volume: nil,
         provider: :webull
       }}
    end
  end

  # The venue's own time, or nothing. The adapter this came from ended its bar decoder
  # with `|| DateTime.utc_now()`, so a bar the venue did not date was stamped with the
  # client's clock and became indistinguishable from a real one — the same substitution
  # found on two other venues in this family.
  defp venue_time(row) do
    case value(row, ["time", "ts", "timestamp", "tradeTime", "trade_time"]) do
      nil -> {:error, :missing_venue_timestamp}
      raw -> parse_time(raw)
    end
  end

  defp parse_time(value) when is_integer(value), do: from_epoch(value)

  defp parse_time(value) when is_binary(value) do
    case Integer.parse(value) do
      {epoch, ""} ->
        from_epoch(epoch)

      _not_an_epoch ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} -> {:ok, datetime}
          _error -> {:error, {:unparseable_venue_timestamp, value}}
        end
    end
  end

  defp parse_time(other), do: {:error, {:unparseable_venue_timestamp, other}}

  # Webull sends milliseconds on some endpoints and seconds on others. Ten digits is
  # seconds until roughly the year 2286; thirteen is milliseconds. Guessing the wrong one
  # puts a 2026 bar in 1970 or in 58,000 — both loud, which is why this is a threshold
  # rather than a fallback.
  defp from_epoch(value) when value > 100_000_000_000, do: DateTime.from_unix(value, :millisecond)
  defp from_epoch(value), do: DateTime.from_unix(value)

  defp timespan(timeframe) do
    case Map.fetch(@timespans, timeframe) do
      {:ok, code} -> {:ok, code}
      :error -> {:error, {:unsupported_timeframe, timeframe}}
    end
  end

  defp within?(bar, range) do
    after_start?(bar, Keyword.get(range, :start)) and before_end?(bar, Keyword.get(range, :end))
  end

  defp after_start?(_bar, nil), do: true
  defp after_start?(bar, start), do: DateTime.compare(bar.timestamp, start) != :lt

  defp before_end?(_bar, nil), do: true
  defp before_end?(bar, finish), do: DateTime.compare(bar.timestamp, finish) != :gt

  defp rows(body) when is_list(body), do: body
  defp rows(%{"data" => rows}) when is_list(rows), do: rows
  defp rows(%{} = body), do: [body]
  defp rows(_other), do: []

  defp first_row(body) do
    case rows(body) do
      [row | _rest] when is_map(row) -> {:ok, row}
      _empty -> {:error, :unexpected_response_shape}
    end
  end

  defp required(row, keys) do
    case value(row, keys) do
      nil -> {:error, :unexpected_response_shape}
      found -> {:ok, found}
    end
  end

  # Webull spells the same field differently across endpoints — `price`, `lastPrice`,
  # `last_trade_price`. Trying each is not guessing: they are the venue's own names for
  # one value, and a missing one still yields nil rather than a substitute.
  defp value(row, keys) when is_map(row) do
    Enum.find_value(keys, fn key ->
      case Map.get(row, key) do
        nil -> nil
        "" -> nil
        found -> found
      end
    end)
  end

  defp value(_row, _keys), do: nil

  defp refusal(body) do
    case decode(body) do
      %{"msg" => message} when is_binary(message) -> {:venue_error, message}
      %{"code" => code} -> {:venue_error, code}
      _other -> :refused
    end
  end

  defp decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> %{}
    end
  end

  defp decode(body), do: body

  defp stringify(params), do: Map.new(params, fn {k, v} -> {to_string(k), to_string(v)} end)

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, to_string(value))

  defp decimal(nil), do: nil
  defp decimal(%Decimal{} = value), do: value
  defp decimal(value) when is_binary(value), do: Decimal.new(value)
  defp decimal(value) when is_integer(value), do: Decimal.new(value)
  defp decimal(value) when is_float(value), do: Decimal.from_float(value)
end
