defmodule DpExchange.Webull.Rest do
  @moduledoc """
  Webull's OpenAPI REST surface — internal.

  ## Every call is signed, including the public-looking ones

  There is no anonymous path here. `/market-data/crypto/snapshots/list` needs the same
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
  alias DpExchange.Core.Types.{Order, Quote, TopOfBook}
  alias DpExchange.Webull.{Auth, Environment, SymbolFormat}

  # Canonical width => the venue's own timespan code.
  #
  # `1w` → `W` is served by the venue and deliberately omitted: a weekly bar's boundary
  # depends on which weekday the venue starts its week, `Core.Timeframe` models no
  # alignment rule for it, and a bar nobody can verify the boundary of is a bar nobody
  # should store.
  # Bounds the instrument pagination loop. 342 symbols were measured at a page size the
  # venue no longer documents; 50 pages is far above any plausible catalogue and far below
  # forever.
  @max_pages 50

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

    with {:ok, body} <- get("/market-data/crypto/snapshots/list", params, credentials, opts),
         {:ok, row} <- first_row(body),
         {:ok, price} <- required(row, ["price", "lastPrice", "last_trade_price"]),
         {:ok, timestamp} <- venue_time(row) do
      {:ok,
       %Quote{
         symbol: SymbolFormat.to_canonical_symbol(native),
         price: decimal(price),
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
      # `symbols`, not `symbol`. The replacement endpoint took a rename with the path, and
      # `real_time_required` is **required** where the old path had no such parameter.
      # `false` asks for completed bars only: an in-progress bar has a boundary that has
      # not happened yet, and this package will not store one (see the `@timespans` note).
      params =
        %{
          "symbols" => native,
          "category" => "US_CRYPTO",
          "timespan" => timespan,
          "real_time_required" => "false"
        }
        |> put_present("count", Keyword.get(opts, :limit))

      with {:ok, body} <- get("/market-data/crypto/bars/list", params, credentials, opts),
           {:ok, bars} <- decode_bars(body, symbol, timeframe) do
        {:ok, Enum.filter(bars, &within?(&1, range))}
      end
    end
  end

  @doc """
  Best bid and ask for `symbol` — the top of the book, not a traded price.

  Same snapshot payload as `get_price/3`; the venue returns the last trade and the top of
  the book together, and this splits them. The documented schema carries `bid`, `ask`,
  `bid_size` and `ask_size`, so unlike some venues in this family the sizes are real here
  rather than `nil`.
  """
  @spec get_top_of_book(String.t(), map(), keyword()) ::
          {:ok, TopOfBook.t()} | {:error, term()} | {:refused, term()}
  def get_top_of_book(symbol, credentials, opts) do
    native = SymbolFormat.to_exchange_symbol(symbol)
    params = %{"symbols" => native, "category" => "US_CRYPTO"}

    with {:ok, body} <- get("/market-data/crypto/snapshots/list", params, credentials, opts),
         {:ok, row} <- first_row(body) do
      {:ok,
       %TopOfBook{
         symbol: SymbolFormat.to_canonical_symbol(native),
         bid: decimal(value(row, ["bidPrice", "bid_price", "bid"])),
         ask: decimal(value(row, ["askPrice", "ask_price", "ask"])),
         bid_size: decimal(value(row, ["bidSize", "bid_size"])),
         ask_size: decimal(value(row, ["askSize", "ask_size"])),
         venue_time: top_of_book_time(row),
         observed_at: DateTime.utc_now(),
         provider: :webull
       }}
    end
  end

  # The book's own stamp where the row carries one. `nil` rather than the local clock —
  # `observed_at` already holds that, and says which it is.
  defp top_of_book_time(row) do
    case venue_time(row) do
      {:ok, at} -> at
      _no_venue_time -> nil
    end
  end

  @doc """
  Every crypto symbol the venue lists, canonical.

  Measured 2026-08-05 against the old `/openapi/instrument/crypto/list`: 342 symbols, every
  one quoted in USD. **That measurement predates the D6 migration** and has not been retaken
  against `/trading/instruments/crypto/profiles/list`, which needs a credential this
  repository does not hold.

  ## This endpoint paginates, and the old one did not

  The replacement returns a `pagination_key` and expects it back to get the next page. A
  single call therefore returns *a page*, not the catalogue — and a truncated symbol list
  is the worst shape of failure this family has: every symbol in it is real, so nothing
  looks wrong, and the ones missing are simply never traded.

  So this follows the key until the venue stops sending one. `@max_pages` bounds it: a
  server that always returns a key would otherwise loop forever, and an infinite loop
  inside a facade call is worse than an error.
  """
  @spec get_symbols(map(), keyword()) ::
          {:ok, [String.t()]} | {:error, term()} | {:refused, term()}
  def get_symbols(credentials, opts) do
    with {:ok, rows} <- all_instrument_rows(nil, credentials, opts, [], 0) do
      {:ok,
       rows
       |> Enum.map(&value(&1, ["symbol", "disSymbol", "name"]))
       |> Enum.reject(&is_nil/1)
       |> Enum.map(&SymbolFormat.to_canonical_symbol/1)
       |> Enum.sort()
       |> Enum.uniq()}
    end
  end

  defp all_instrument_rows(_key, _credentials, _opts, _acc, page) when page >= @max_pages,
    do: {:error, :too_many_instrument_pages}

  defp all_instrument_rows(key, credentials, opts, acc, page) do
    params = put_present(%{"category" => "US_CRYPTO"}, "pagination_key", key)

    with {:ok, body} <-
           get("/trading/instruments/crypto/profiles/list", params, credentials, opts) do
      collected = acc ++ rows(body)

      case next_pagination_key(body) do
        nil -> {:ok, collected}
        ^key -> {:error, :pagination_key_did_not_advance}
        next -> all_instrument_rows(next, credentials, opts, collected, page + 1)
      end
    end
  end

  # A key echoed back unchanged would page forever without this; see the clause above.
  defp next_pagination_key(body) when is_map(body) do
    case value(body, ["pagination_key", "paginationKey", "next_page_key"]) do
      "" -> nil
      found -> found
    end
  end

  defp next_pagination_key(_body), do: nil

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

  # A POST carrying a JSON body.
  #
  # **This venue signs the body**, unlike Coinbase's URI-scoped JWT, so the exact bytes sent
  # must be the exact bytes signed. The encoded string is built once and used for both —
  # encoding twice risks two different orderings of the same map and a signature that does
  # not match the payload, which the venue would reject as an authentication failure rather
  # than as the encoding bug it is.
  defp post(path, body, credentials, opts) do
    environment = Environment.resolve(opts)
    host = Environment.host(environment)
    encoded = Jason.encode!(body)

    request = %{
      path: path,
      query_params: %{},
      body: encoded,
      host: host,
      timestamp: Auth.timestamp(),
      nonce: Auth.nonce()
    }

    with {:ok, headers} <- Auth.headers(request, credentials) do
      url = Environment.rest_url(environment) <> path

      case HttpClient.request(:post, url, headers, encoded, request_opts(opts)) do
        {:ok, %{status: status, body: response}} when status in 200..299 ->
          {:ok, decode(response)}

        {:ok, %{status: status, body: response}} when status in [400, 401, 403] ->
          {:refused, refusal(response)}

        {:ok, %{status: status, body: response}} ->
          {:error, {:exchange_error, :webull, "HTTP #{status}: #{inspect(response)}"}}

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
    case value(row, [
           "time",
           "ts",
           "timestamp",
           "tradeTime",
           "trade_time",
           # Added with the D6 migration: the documented replacement endpoints stamp rows
           # with these instead, and the list above silently produced
           # `:missing_venue_timestamp` for every row until they were added.
           "last_trade_time",
           "quote_time"
         ]) do
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

  @doc """
  Places a crypto order.

  ## The venue documents which type/time-in-force pairs it accepts, and the list is short

  Webull states the crypto rules outright rather than encoding them in a key name the way
  Coinbase does, and the effect is the same — most pairs do not exist:

      MARKET            -> IOC only
      LIMIT             -> DAY or GTC only
      STOP_LOSS_LIMIT   -> DAY or GTC only

  There is no market GTC and no limit IOC. **A pair the venue does not accept is refused
  here, before the request is sent**, rather than being sent and rejected — the venue's
  rejection would arrive as a business error the caller has to interpret, and the local
  refusal names both halves of what was wrong.

  ## `account_id` is required and is never inferred

  The venue takes the account on every order. This package does **not** look one up and
  choose: an account is where the money is, and a package picking one for a caller who has
  several would place a real order against the wrong balance. It comes from `opts[:account_id]`
  or the call fails.

  ## Only `NORMAL` combo orders

  The venue supports MASTER, OTO, OCO and OTOCO groupings, and states that **crypto supports
  only `NORMAL`**. Multi-leg and bracket orders are a Phase 11 shape for the venues that
  have them; sending one here would be rejected upstream.
  """
  @spec place_order(map(), map(), keyword()) ::
          {:ok, Order.t()} | {:error, term()} | {:refused, term()}
  def place_order(credentials, request, opts) do
    with {:ok, account_id} <- account_id(opts),
         {:ok, {order_type, tif}} <- crypto_combination(request),
         {:ok, leaf} <- order_leaf(request, order_type, tif) do
      body = %{
        "account_id" => account_id,
        "new_orders" => [Map.put(leaf, "client_order_id", client_order_id(request))]
      }

      with {:ok, response} <- post("/trading/orders/place", body, credentials, opts) do
        to_placed_order(response, request, order_type, tif)
      end
    end
  end

  defp account_id(opts) do
    case Keyword.get(opts, :account_id) do
      nil -> {:error, :account_id_required}
      account_id -> {:ok, account_id}
    end
  end

  # The venue's documented crypto matrix, written out so a pair outside it cannot be sent.
  @crypto_combinations %{
    {:market, :ioc} => {"MARKET", "IOC"},
    {:limit, :day} => {"LIMIT", "DAY"},
    {:limit, :gtc} => {"LIMIT", "GTC"},
    {:stop_limit, :day} => {"STOP_LOSS_LIMIT", "DAY"},
    {:stop_limit, :gtc} => {"STOP_LOSS_LIMIT", "GTC"}
  }

  defp crypto_combination(request) do
    type = Map.get(request, :order_type, :limit)
    tif = Map.get(request, :time_in_force, :gtc)

    case Map.fetch(@crypto_combinations, {type, tif}) do
      {:ok, pair} -> {:ok, pair}
      :error -> {:error, {:unsupported_order_combination, type, tif}}
    end
  end

  defp order_leaf(request, order_type, tif) do
    with {:ok, entrust, sizing} <- entrust(request, order_type) do
      leaf =
        %{
          "combo_type" => "NORMAL",
          "instrument_type" => "CRYPTO",
          "market" => "US",
          "symbol" => SymbolFormat.to_exchange_symbol(Map.fetch!(request, :symbol)),
          "side" => request |> Map.fetch!(:side) |> to_string() |> String.upcase(),
          "order_type" => order_type,
          "time_in_force" => tif,
          "entrust_type" => entrust
        }
        |> Map.merge(sizing)

      {:ok, put_present(leaf, "limit_price", price_for(request, order_type))}
      |> then(fn {:ok, l} ->
        {:ok, put_present(l, "stop_price", stop_for(request, order_type))}
      end)
    end
  end

  # `QTY` sizes in units, `AMOUNT` in cash. They are different orders and the venue names
  # them separately; a caller that gave neither gets an error rather than a default, and a
  # caller that gave both is asking for two things at once.
  defp entrust(request, order_type) do
    quantity = Map.get(request, :quantity)
    amount = Map.get(request, :amount)

    case {quantity, amount} do
      {nil, nil} ->
        {:error, :missing_order_size}

      {quantity, nil} ->
        {:ok, "QTY", %{"qty" => to_string(quantity)}}

      {nil, amount} ->
        amount_entrust(order_type, amount)

      {_quantity, _amount} ->
        {:error, :ambiguous_order_size}
    end
  end

  # The venue restricts `AMOUNT` on a stop-limit sell to `QTY` only. Rather than encode the
  # side rule twice, cash sizing is refused for stop-limit outright: a caller sizing a stop
  # in cash is asking for something the venue will not do on one side of the book, and
  # accepting it on the other invites a surprise later.
  defp amount_entrust("STOP_LOSS_LIMIT", _amount),
    do: {:error, :cash_sizing_not_supported_for_stop}

  defp amount_entrust(_order_type, amount), do: {:ok, "AMOUNT", %{"amount" => to_string(amount)}}

  defp price_for(_request, "MARKET"), do: nil
  defp price_for(request, _order_type), do: Map.get(request, :price)

  defp stop_for(request, "STOP_LOSS_LIMIT"), do: Map.get(request, :stop_price)
  defp stop_for(_request, _order_type), do: nil

  # 32 characters maximum, unique per account, and the venue's own reference for the order.
  defp client_order_id(request) do
    case Map.get(request, :client_order_id) do
      nil ->
        16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower) |> binary_part(0, 32)

      given ->
        given
    end
  end

  defp to_placed_order(response, request, order_type, tif) do
    case first_row(response) do
      {:ok, row} ->
        {:ok,
         %Order{
           id: value(row, ["order_id", "orderId", "client_order_id"]),
           symbol: Map.fetch!(request, :symbol),
           side: Map.fetch!(request, :side),
           order_type: order_type_atom(order_type),
           time_in_force: tif_atom(tif),
           quantity: Map.get(request, :quantity),
           price: Map.get(request, :price),
           status: :pending,
           provider: :webull
         }}

      _no_row ->
        {:error, :unexpected_response_shape}
    end
  end

  defp order_type_atom("MARKET"), do: :market
  defp order_type_atom("LIMIT"), do: :limit
  defp order_type_atom("STOP_LOSS_LIMIT"), do: :stop_limit

  defp tif_atom("IOC"), do: :ioc
  defp tif_atom("DAY"), do: :day
  defp tif_atom("GTC"), do: :gtc
end
