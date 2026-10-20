defmodule DpExchange.Webull.Rest do
  @moduledoc """
  Webull's OpenAPI REST surface — internal.

  ## Every call is signed, including the public-looking ones

  There is no anonymous path here. `/market-data/crypto/snapshots/list` needs the same
  App Key and signature as an order. That is why this venue declares
  `credential_benefit: :required` — the first in the family to do so — and why
  `get_price/3` takes credentials that other venues' `get_price` does not need.

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

  ## Volume is real on stocks, absent on crypto

  Webull's crypto OpenAPI documents **no trade volume** on the bars or the REST snapshot.
  `volume` is `nil` rather than `0` on a crypto quote from this module, because zero is a
  volume and this venue is not reporting one.

  **The MQTT stream is not covered by that sentence any more.** It used to be, but that
  was never measured. The stream's `Snapshot` schema carries `volume` (field 8) for every
  category, and `Socket` now passes it through as a `:running_total`, or `nil` when the
  frame leaves it empty (dp_exchange_webull issue #6). Whether crypto snapshots fill it in
  is for a live run to show, not for this doc to assume.

  The **stock** snapshot is different: `get_price/2` with `category: "US_STOCK"` or
  `"US_ETF"` carries a real `volume`, the day's aggregate. `capabilities/0` therefore
  declares `reports_trade_volume: true` — the venue does report one, on a real, active
  path — with `measured_against` carrying the crypto/equity split so a caller does not
  read the boolean as "every quote has a number."

  **Bars are the same split, not a blanket "no volume."** Stock, option, futures and event
  bars each document a required `volume` on their own `"result"` row
  (`historical-bars.md:269,298`, `option-historical-bars.md`,
  `futures-historical-bars.md:214`, `event-bars.md:236`); only the crypto bar schema
  (`crypto-bars.md`) carries none. `decode_bar/4` previously hard-coded `nil` for every
  caller, which understated the four documented cases the same way the old
  `reports_trade_volume: false` understated the venue as a whole. `get_volume_profile/4`
  remains the separate equity endpoint that splits traded volume by price and side — this
  note is about the bars' own `volume` column, not that endpoint.

  This package previously declared `reports_trade_volume: false` unconditionally, which
  was true of crypto and a false claim about the venue as a whole — the same
  crypto-generalised-to-venue mistake `docs/reference/webull/negative-claims.md` records
  for three other refusals. Fixed alongside `historical_timeframes` below.
  """

  alias DpExchange.Core.{Config, HttpClient, Instrument, Timeframe}

  alias DpExchange.Core.Types.{
    AuctionImbalance,
    Balance,
    Candle,
    CorporateEvent,
    Filing,
    FinancialStatement,
    NewsItem,
    OptionChain,
    OptionContract,
    Order,
    OrderBook,
    Position,
    Quote,
    ScreenerResult,
    TopOfBook,
    Trade,
    VolumeProfile,
    Watchlist
  }

  alias DpExchange.Webull.{Auth, Environment, SymbolFormat}

  # Canonical width => the venue's own timespan code, for the **crypto and event-contract**
  # bars — the two endpoints that stop at `1d`.
  #
  # `1w` → `W` is served by the venue's *equity, option and futures* bars (see
  # `@stock_timespans` below) and deliberately excluded from **this** map: a weekly bar's
  # boundary depends on which weekday the venue starts its week, `Core.Timeframe` models
  # no alignment rule for it, and a bar nobody can verify the boundary of is a bar nobody
  # should store here. That reasoning is about crypto's continuous, boundary-less week —
  # it does not carry over to equities, which trade on a fixed Monday-to-Friday calendar
  # the venue's own weekly bar aligns to, which is why `@stock_timespans` accepts it.
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

  # Bounds the instrument pagination loop. 342 symbols were measured at a page size the
  # venue no longer documents; 50 pages is far above any plausible catalogue and far below
  # forever.
  @max_pages 50

  @doc "Canonical timeframes the crypto and event-contract bars serve, shortest first."
  @spec timeframes() :: [String.t()]
  def timeframes, do: ~w(1m 5m 15m 30m 1h 2h 4h 1d)

  @doc """
  Every canonical timeframe served by *some* active endpoint on this venue —
  `timeframes/0`'s eight plus `1w`, `1M` and `1y`, which the equity, option and futures
  bars serve and the crypto and event-contract bars refuse (see `@timespans` above).

  This is a fact about the **venue**, not the finished `capabilities/0` declaration:
  `Core.Capabilities` has one flat `historical_timeframes` list for the whole package, with
  no per-asset-class shape, so a width reachable on *any* path belongs in that declaration
  too — **which is now the family's written rule rather than an inference made here**: see
  `DpExchange.Core.Capabilities`' "A list-valued capability is a UNION across asset classes"
  section, which cites this function as its worked example. This package chose that reading
  before it was written down, and the rule's second half is what makes it honest: the
  per-call path must fail closed, which is what the last paragraph below describes.
  `Webull.capabilities/0` declares exactly this list, `1y` included (Core's
  `Timeframe.nameable/0` has admitted it since `dp_exchange_core` 0.1.57). Which
  category a given call actually reaches a width on is enforced per-call either way:
  `get_historical_prices/5` with a crypto or event-contract category returns `{:error,
  {:unsupported_timeframe, _}}` for `1w`, `1M` and `1y` rather than silently degrading to
  the nearest width it does serve.
  """
  @spec wide_timeframes() :: [String.t()]
  def wide_timeframes, do: timeframes() ++ ~w(1w 1M 1y)

  # **Three snapshot endpoints, one per market**, and they are not interchangeable: the
  # crypto one takes `US_CRYPTO`, the stock one takes `US_STOCK` or `US_ETF` and refuses
  # `US_OPTION`, and options have **their own** endpoint. That last was previously recorded
  # here as "`US_OPTION` is refused: the vendor states the stock snapshot does not serve
  # it" — true of the stock snapshot, and a false negative about the venue, which publishes
  # `/market-data/options/snapshots/list` alongside it.
  #
  # Sending a stock symbol to the crypto endpoint returns nothing rather than an error,
  # which is why the category picks the path here rather than being passed through.
  #
  # `opts[:category]` selects; the default is `US_CRYPTO`, which is what this package served
  # before its asset classes widened. Changing that default would silently re-route existing
  # callers onto a different market.
  defp snapshot_path("US_CRYPTO"), do: {:ok, "/market-data/crypto/snapshots/list"}

  defp snapshot_path("US_OPTION"), do: {:ok, "/market-data/options/snapshots/list"}

  defp snapshot_path("US_FUTURES"), do: {:ok, "/market-data/futures/snapshots/list"}

  defp snapshot_path("US_EVENT"), do: {:ok, "/market-data/event-contracts/snapshots/list"}

  defp snapshot_path(category) when category in ["US_STOCK", "US_ETF"],
    do: {:ok, "/market-data/stocks/snapshots/list"}

  defp snapshot_path(category), do: {:error, {:unsupported_snapshot_category, category}}

  # The stock snapshot publishes extended-hours and overnight blocks only when asked. Both
  # are marked optional by the venue and default to false, and this sends them explicitly so
  # a caller reading `nil` knows it did not ask rather than that the venue had nothing.
  #
  # Crypto and options take neither: crypto trades continuously, so there are no hours to
  # extend, and the option snapshot is its own endpoint with its own parameters. Sending
  # them anyway would be this package asserting a session model the venue did not offer.
  defp snapshot_params(native, category, opts)
       when category not in ["US_CRYPTO", "US_OPTION", "US_FUTURES", "US_EVENT"] do
    %{"symbols" => native, "category" => category}
    |> Map.put("extend_hour_required", to_string(Config.opt(opts, :extended_hours, false)))
    |> Map.put("overnight_required", to_string(Config.opt(opts, :overnight, false)))
  end

  defp snapshot_params(native, category, _opts),
    do: %{"symbols" => native, "category" => category}

  @doc """
  Last price for one symbol.

  **Each asset class is its own endpoint**, chosen by `opts[:category]` — `US_CRYPTO` (the
  default), `US_STOCK`, `US_ETF`, `US_OPTION`, `US_FUTURES` or `US_EVENT`. Any other category
  is `{:error, {:unsupported_snapshot_category, category}}` before a request is made.

  **The row must be the symbol asked for.** The response is a list, and the first row used to
  be taken whatever it named. A row that names a different symbol than the one requested is
  `{:error, :not_in_response}`: a price for another instrument is the substitute this package
  refuses to hand back, and it would look entirely plausible. A response whose rows name no
  symbol at all is read as before.

  **An event contract's `price` is the venue's own unlabelled number** (`event-snapshot.md`
  says only "the current market price for buying or selling an event contract", beside
  separate `yes_*` and `no_*` quotes). It is returned as sent; which outcome it prices is not
  stated by the venue, and nothing here claims one.

  ## Volume is read wherever the response carries it

  The crypto snapshot documents no volume, and a response without one gives `nil`. One
  that carries a `volume` delivers it as a `:running_total`, because a documented field
  list is not a measurement. Where crypto gives none, its quote's volume is `nil` —
  never zero, which would claim a genuinely flat interval. The **stock** snapshot does
  publish `volume`, and it is the day's aggregate rather than the last trade's size; the
  venue names no per-trade size on this endpoint, so that is what a caller gets and the
  field carries the venue's own meaning.
  """
  @spec get_price(String.t(), map(), keyword()) ::
          {:ok, Quote.t()} | {:error, term()} | {:refused, term()}
  def get_price(symbol, credentials, opts) do
    category = Config.opt(opts, :category, "US_CRYPTO")

    with {:ok, path} <- snapshot_path(category),
         :ok <- validate_hours_flags(opts),
         :ok <- validate_symbol(symbol) do
      native = snapshot_symbol(symbol, category)
      params = snapshot_params(native, category, opts)

      with {:ok, body} <- get_symbol(path, params, credentials, opts),
           {:ok, row} <- symbol_row(body, native) do
        snapshot_quote(row, native, category)
      end
    end
  end

  @doc """
  Whether `symbol` is something a single-symbol read can ask the venue about: a string with
  something in it after trimming. Anything else - `nil`, an atom, a number, `""`, `"  "` - is
  `{:error, {:invalid_symbol, symbol}}`, decided locally before credentials and before any
  request.

  These used to raise `FunctionClauseError` in the symbol mapper (crypto) or go out as
  `symbols=` for the venue to refuse (everything else). Shared with
  `DpExchange.Webull.Fake`, so both answer a malformed symbol identically.
  """
  @spec validate_symbol(term()) :: :ok | {:error, {:invalid_symbol, term()}}
  def validate_symbol(symbol) when is_binary(symbol) do
    if String.trim(symbol) == "", do: {:error, {:invalid_symbol, symbol}}, else: :ok
  end

  def validate_symbol(symbol), do: {:error, {:invalid_symbol, symbol}}

  @doc """
  Whether `symbols` is a proper list: anything else (a bare string, `nil`, an improper list)
  is `{:error, {:invalid_symbols, symbols}}`. Its members are not judged here - `get_prices/3`
  answers a member that is not a usable symbol under its own key.

  The positional check `get_prices/3` makes first, for `DpExchange.Webull.Options` to run
  before it looks at the options.
  """
  @spec validate_symbols(term()) :: :ok | {:error, {:invalid_symbols, term()}}
  def validate_symbols(symbols) do
    with {:ok, _members} <- snapshot_members(symbols), do: :ok
  end

  @doc """
  Whether `range` is a keyword list whose `:start` and `:end`, where present, are
  `DateTime`s: the check `get_historical_prices/5` makes before anything is signed, for
  `DpExchange.Webull.Fake`. Anything else is `{:error, {:invalid_range, range}}`.

  A non-`DateTime` bound used to raise in `DateTime.compare/2` after the request had been
  made and charged against the endpoint's bucket.
  """
  @spec validate_range(term()) :: :ok | {:error, {:invalid_range, term()}}
  def validate_range(range) do
    if valid_range?(range), do: :ok, else: {:error, {:invalid_range, range}}
  end

  # A range whose `:start` is after its `:end` is a mistake, not an empty window: it filtered
  # every bar out and answered `{:ok, []}`, which reads as "no trading in that period".
  # `start == end` stays valid (`:end` is exclusive, so it is a genuinely empty window).
  defp valid_range?(range) when is_list(range) do
    Keyword.keyword?(range) and range_bound?(Keyword.get(range, :start)) and
      range_bound?(Keyword.get(range, :end)) and
      not inverted?(Keyword.get(range, :start), Keyword.get(range, :end))
  end

  defp valid_range?(_other), do: false

  defp inverted?(%DateTime{} = start, %DateTime{} = finish),
    do: DateTime.compare(start, finish) == :gt

  defp inverted?(_start, _finish), do: false

  defp range_bound?(nil), do: true
  defp range_bound?(%DateTime{}), do: true
  defp range_bound?(_other), do: false

  # One snapshot row as a `Quote`, shared by `get_price/3` and `get_prices/3`, so the batched
  # call cannot drift from the single one.
  defp snapshot_quote(row, native, category) do
    # `price` alone: every snapshot page defines it (`snapshot.md:220`, `crypto-snapshot.md:189`,
    # `option-snapshot.md:181`, `futures-snapshot.md:181`, `event-snapshot.md:200`); no page or
    # captured response shows `lastPrice` or `last_trade_price`.
    with {:ok, raw_price} <- required(row, ["price"]),
         :ok <- quoted(raw_price),
         {:ok, price} <- required_price(raw_price, :price) do
      # A snapshot's `volume` is the day's aggregate, so a running total —
      # dp-exchange-core issue #42. `nil`, with no window, where the response has none.
      volume = snapshot_volume(row)

      {:ok,
       %Quote{
         symbol: snapshot_canonical(native, category),
         price: price,
         volume: volume,
         volume_window: volume && :running_total,
         # Read, not required - `Core.Types.Quote` enforces
         # `[:symbol, :price, :observed_at, :provider]`; refusing a guarded traded price
         # over an optional field discards the fact the caller asked for. **The time of the
         # last trade and nothing else** (`trade_time/1`): a row that states only a
         # `quote_time` has no trade time, and that quote's time is a different event.
         venue_time: trade_time(row, category),
         observed_at: DateTime.utc_now(),
         provider: :webull
       }}
    end
  end

  @snapshot_batch 20

  @doc """
  Last prices for many crypto symbols, up to #{@snapshot_batch} per request.

  The crypto snapshot endpoint takes a list: "Supports querying up to 20 symbols per
  request" (`docs/reference/webull/openapi/crypto-snapshot.md`). `get_price/3` sends one, so
  a consumer filling a stale stream from REST got 60 symbols a minute from a per-endpoint
  limit of one request per second, where the venue serves 1,200 (dp_exchange_webull issue
  #9). Each chunk of #{@snapshot_batch} is one request through the same endpoint bucket.

  Answers `{:ok, %{symbol => result}}` with a result for **every** symbol asked for, in the
  shape `get_price/3` gives it: `{:ok, Quote.t()}`, `{:refused, :no_quote}` for the venue's
  `"null"` price, or `{:error, reason}`. A symbol the response carries no row for is
  `{:error, :not_in_response}`, never silently absent. A chunk the venue rejects for its
  content (a 4xx other than 401/403/429, such as one `INVALID_SYMBOL` member) is halved and
  retried down to single symbols, so only the rejected symbol keeps the rejection. A chunk
  whose request fails any other way gives
  each of its symbols that failure, so one chunk's trouble never costs another's quotes.
  A member that is not a usable symbol (`nil`, a number, blank text) is answered
  `{:error, {:invalid_symbol, member}}` under its own key, with no request, and does not cost
  the other members anything (so such a key is not always text); a `symbols` that is not a
  proper list is `{:error, {:invalid_symbols, symbols}}`. `US_CRYPTO` only. Other categories answer `{:error, {:unsupported_category, category}}`,
  because their snapshot limits are not read here.
  """
  @spec get_prices([String.t()], map(), keyword()) ::
          {:ok, %{String.t() => {:ok, Quote.t()} | {:error, term()} | {:refused, term()}}}
          | {:error, term()}
  def get_prices(symbols, credentials, opts) do
    case Config.opt(opts, :category, "US_CRYPTO") do
      "US_CRYPTO" ->
        with {:ok, members} <- snapshot_members(symbols),
             :ok <- validate_hours_flags(opts) do
          {:ok, path} = snapshot_path("US_CRYPTO")

          # An element that is not a usable symbol gets `{:error, {:invalid_symbol, v}}` of
          # its own, without a request: it would otherwise raise in the symbol mapper, or
          # reach the wire blank and cost the whole chunk its other members.
          {valid, invalid} = Enum.split_with(members, &(validate_symbol(&1) == :ok))

          results =
            valid
            |> Enum.chunk_every(@snapshot_batch)
            |> Enum.flat_map(&snapshot_chunk(&1, path, credentials, opts))
            |> Map.new()

          {:ok, Enum.reduce(invalid, results, &Map.put(&2, &1, validate_symbol(&1)))}
        end

      other ->
        {:error, {:unsupported_category, other}}
    end
  end

  # The unique members of a symbol list, or `{:error, {:invalid_symbols, value}}` for what is
  # not a proper list. By hand, so an improper list is refused rather than raised on.
  defp snapshot_members(symbols), do: snapshot_members(symbols, symbols, [])

  defp snapshot_members([member | rest], whole, acc),
    do: snapshot_members(rest, whole, [member | acc])

  defp snapshot_members([], _whole, acc), do: {:ok, acc |> Enum.reverse() |> Enum.uniq()}
  defp snapshot_members(_not_a_list, whole, _acc), do: {:error, {:invalid_symbols, whole}}

  defp snapshot_chunk(symbols, path, credentials, opts) do
    # Grouped, not mapped one-to-one: two spellings of one pair (`"BTC-USD"`, `"BTCUSD"`)
    # survive `Enum.uniq/1` and share a native symbol, and a plain map would keep only the
    # last of them — the other would get no result, breaking "a result for every symbol".
    natives = Enum.group_by(symbols, &SymbolFormat.to_exchange_symbol/1)
    params = snapshot_params(natives |> Map.keys() |> Enum.join(","), "US_CRYPTO", opts)

    with {:ok, body} <- get(path, params, credentials, opts),
         {:ok, rows} <- rows(body) do
      by_native =
        for row <- rows,
            is_map(row),
            is_binary(row["symbol"]),
            into: %{},
            do: {row["symbol"], row}

      for {native, spellings} <- natives,
          result = native_result(by_native, native),
          symbol <- spellings,
          do: {symbol, result}
    else
      failure -> split_or_fail(failure, symbols, path, credentials, opts)
    end
  end

  defp native_result(by_native, native) do
    case Map.fetch(by_native, native) do
      {:ok, row} -> snapshot_quote(row, native, "US_CRYPTO")
      :error -> {:error, :not_in_response}
    end
  end

  # **A chunk the venue rejects for its content is halved and retried, down to single
  # symbols.** The venue refuses a whole subscribe request for one symbol it calls
  # `INVALID_SYMBOL` (`Subscription`'s moduledoc, measured live), and a consumer that polls
  # its never-ticked pairs first, where those symbols collect, would have every chunk of 20
  # refused for one bad member and get nothing at all. That fits dp_crypto_management's log
  # from 0.4.104 onward: thousands of consecutive polls, `{:every_symbol_failed, 60}` every
  # time. Halving isolates each rejected symbol in about two extra requests per bad symbol,
  # whatever wording the venue uses. The rejected symbol keeps the venue's own answer, and
  # every other symbol gets its quote. The bound is the tree's size: a 400 that is about the
  # request itself rather than any member fails every half, and a chunk of 20 then spends
  # 39 requests before each symbol carries the rejection — bounded, and paced by the
  # endpoint bucket like any other request.
  #
  # Only a 4xx about the request's content is split. A 401/403 is the credential and a 429
  # is the budget; both would fail every half the same way, so splitting would only spend
  # more requests. A 5xx or a transport error is not about which symbols were asked for.
  defp split_or_fail(failure, [_one] = symbols, _path, _credentials, _opts),
    do: Enum.map(symbols, &{&1, failure})

  defp split_or_fail(failure, symbols, path, credentials, opts) do
    if content_rejection?(failure) do
      {left, right} = Enum.split(symbols, div(length(symbols), 2))

      snapshot_chunk(left, path, credentials, opts) ++
        snapshot_chunk(right, path, credentials, opts)
    else
      Enum.map(symbols, &{&1, failure})
    end
  end

  # Any refusal that is not about the credential: 400 and the documented 417 business response
  # (`INVALID_SYMBOL`), 409, 422, ... A 401/403 would fail every half the same way, and a 404
  # is `{:refused, :not_found}`, which does not match here.
  defp content_rejection?({:refused, {:venue_error, status, _detail}}),
    do: status not in [401, 403]

  defp content_rejection?({:refused, {:venue_error, status}}), do: status not in [401, 403]
  defp content_rejection?(_failure), do: false

  # Only crypto pairs go through the canonical mapper — an equity ticker is already the
  # venue's own identifier, and a splitter hunting for a quote currency would mangle one.
  defp snapshot_symbol(symbol, "US_CRYPTO"), do: SymbolFormat.to_exchange_symbol(symbol)
  defp snapshot_symbol(symbol, _category), do: symbol

  defp snapshot_canonical(native, "US_CRYPTO"), do: SymbolFormat.to_canonical_symbol(native)
  defp snapshot_canonical(native, _category), do: native

  # Read on every category, crypto included. Crypto used to answer `nil` without looking,
  # because `crypto-snapshot.md` documents no volume field — the same unmeasured assumption
  # dp_exchange_webull issue #6 found on the stream. A response that carries none still
  # gives `nil`, never zero, which would claim a flat interval.
  #
  # A negative volume is no volume: `size_or_nil/1`.
  defp snapshot_volume(row), do: size_or_nil(value(row, ["volume"]))

  # A size or volume the venue states, read as a number that can be one: `nil` where it is
  # absent, unreadable, or NEGATIVE. A negative quantity of anything traded or resting is no
  # quantity, and delivering `-5` as a running volume or a level's size stays plausible while
  # its meaning is wrong. `nil` is "not published", the answer this package gives for an
  # unreadable figure everywhere a size is optional (`Core.Types.TopOfBook`, `Quote`).
  defp size_or_nil(raw) do
    case decimal(raw) do
      nil -> nil
      size -> if Decimal.negative?(size), do: nil, else: size
    end
  end

  # **The string `"null"` is the venue saying it has no price, so it is refused, not an
  # error** (dp_exchange_webull issue #8). Measured by a consumer on 2026-10-02 against
  # 0.4.101: 51 of the ~325 USD pairs the catalogue lists as tradable answered every quote
  # this way (MATIC-USD, FTM-USD, FTT-USD, KLAY-USD, … several delisted or renamed upstream),
  # and they never tick on the stream either. `Socket` already recorded the same shape from a
  # delisted pair. Reported as `{:invalid_decimal, :price, "null"}` it read as a broken
  # parser, and since `{:error, _}` is possibly transient by contract, the consumer retried
  # it forever. `{:refused, :no_quote}` is the venue's definite answer, and permanent.
  # Anything else unreadable stays an error: only this exact venue spelling means "no quote".
  defp quoted("null"), do: {:refused, :no_quote}
  defp quoted(_raw_price), do: :ok

  @doc """
  OHLC bars for a symbol and canonical timeframe.

  Bars carry no volume on crypto — see the module doc. A bar without a venue timestamp is an
  **error**, not a bar stamped with the local clock.

  ## Family conventions (all categories)

    * **The bar still forming is dropped** (`opened_at` plus the width is after now,
      this machine's clock) unless `include_partial: true`. Core's `Candle` has no flag, so
      with `include_partial: true` the last bar may still change. `real_time:` is gone
      (BREAKING) and is `{:error, {:unsupported_option, :real_time}}`; a non-boolean
      `:include_partial` is `{:error, {:invalid_option, :include_partial, v}}`.
    * **`:start` inclusive, `:end` exclusive**, on `opened_at`. A crypto or stock read whose
      page is full while its oldest bar is still after `:start` is
      `{:error, {:range_too_wide, count}}` (was `{:range_exceeds_count, count}`), never a
      short answer. Stock bars send `count` (the `:limit`, else the maximum when a `:start`
      is given) so the venue's default of 200 does not cut a range short.
    * **A bar must sit on its width's grid**, else the reply is
      `{:error, {:unaligned_candle, time}}`. Crypto uses the strict UTC grid
      (`DpExchange.Core.Timeframe.aligned?/2`). Stock, option, futures and event bars are
      session-anchored: widths of 30 minutes and under keep the UTC grid, `1h` and wider
      intraday widths need only a 30-minute alignment (a 09:30 New York open is 13:30Z or
      14:30Z), and a daily, weekly, monthly or yearly bar stamped at 00:00Z or at New York
      midnight (04:00Z EDT, 05:00Z EST) is mapped to 00:00 UTC of that date. **Unmeasured**:
      the pages call `time` "Bar UTC time" without saying it is the open.
    * An open, high, low or close of zero or less is `{:error, {:non_positive_price, field,
      raw}}`.
  """
  @spec get_historical_prices(String.t(), String.t(), keyword(), map(), keyword()) ::
          {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def get_historical_prices(symbol, timeframe, range, credentials, opts) do
    # Crypto, stocks, options, futures and event contracts are five different endpoints —
    # and crypto is a different HTTP verb. `opts[:category]` picks, defaulting to crypto,
    # which is what this package served before its asset classes widened.
    #
    # The range, the category's own checks and the symbol are all decided locally first
    # (`validate_bars_request/3`, `validate_symbol/1`), so a malformed argument answers the
    # same way whatever the credentials and never after a charged request.
    with :ok <- validate_bars_request(timeframe, range, opts),
         :ok <- validate_symbol(symbol) do
      case Config.opt(opts, :category, "US_CRYPTO") do
        "US_CRYPTO" -> crypto_bars(symbol, timeframe, range, credentials, opts)
        "US_OPTION" -> option_bars(symbol, timeframe, range, credentials, opts)
        "US_FUTURES" -> futures_bars(symbol, timeframe, range, credentials, opts)
        "US_EVENT" -> event_bars(symbol, timeframe, range, credentials, opts)
        _stock -> get_stock_bars(symbol, timeframe, range, credentials, opts)
      end
    end
  end

  # **Futures bars take no range and no `real_time_required`.** The venue's page names
  # `symbols`, `category`, `timespan` and `count` and nothing else, so a caller's start and
  # end have nowhere to go, and `opts[:limit]` is how a caller bounds the read here. **So a
  # range is refused**, as `option_bars/5` refuses one: it was ignored, and the latest bars
  # came back as though they answered a window in the past.
  defp futures_bars(symbol, timeframe, range, credentials, opts) do
    with :ok <- refuse_bar_range(range, :future),
         {:ok, timespan} <- stock_timespan(timeframe),
         :ok <- limit_within_max(Keyword.get(opts, :limit), 1_200) do
      params =
        %{
          "symbols" => symbol,
          "category" => "US_FUTURES",
          # The venue marks `count` REQUIRED and documents 200 as its default; sending it
          # explicitly keeps the page size this package asked for rather than one that can
          # change under it.
          "count" => to_string(Config.opt(opts, :limit, 200)),
          "timespan" => timespan
        }

      with {:ok, body} <-
             get_symbol("/market-data/futures/bars/list", params, credentials, opts),
           {:ok, bars} <- decode_stock_bars(body, symbol, timeframe) do
        {:ok, finish_bars(bars, timeframe, opts)}
      end
    end
  end

  # **Event-contract bars do not say which side they are.** A binary market has a YES price
  # and a NO price that sum to one, and the venue's schema names `open`, `close`, `high`,
  # `low` without saying which. They are returned as the venue's own numbers under the
  # market's symbol; a caller reconciling against `get_event_trades/3`, which does name both
  # sides, is the way to find out. Labelling them here would be this package asserting a
  # side the venue did not state.
  # Takes no range either, and refuses one for the reason `futures_bars/5` does.
  defp event_bars(symbol, timeframe, range, credentials, opts) do
    with :ok <- refuse_bar_range(range, :event),
         {:ok, timespan} <- event_timespan(timeframe),
         :ok <- limit_within_max(Keyword.get(opts, :limit), 1_200) do
      params =
        %{
          "symbols" => symbol,
          "category" => "US_EVENT",
          "timespan" => timespan,
          # Required by the venue. `false` is its default and, per `event-bars.md:93`, does
          # not include a candle that is not yet finalised; `true` only when the caller
          # asked for the forming bar (`include_partial: true`). Whatever the venue does,
          # the forming bar is also removed client-side (`finish_bars/3`).
          "real_time_required" => to_string(Keyword.get(opts, :include_partial) == true)
        }
        |> put_present("count", Keyword.get(opts, :limit))

      with {:ok, body} <-
             get_symbol("/market-data/event-contracts/bars/list", params, credentials, opts),
           {:ok, bars} <- decode_stock_bars(body, symbol, timeframe) do
        {:ok, finish_bars(bars, timeframe, opts)}
      end
    end
  end

  # The event endpoint's enum stops at `D` — no weekly, monthly or yearly, which the stock
  # and futures ones carry. A width the venue does not serve is an error rather than the
  # nearest one it does.
  defp event_timespan(timeframe) do
    case Map.fetch(@timespans, timeframe) do
      {:ok, timespan} -> {:ok, timespan}
      :error -> {:error, {:unsupported_timeframe, timeframe}}
    end
  end

  # Options have their own bars endpoint and take the same `timespan` vocabulary the stock
  # one does. It is a GET where the stock bars are a POST — the venue's own split, not a
  # simplification here.
  #
  # **No `start_time`/`end_time` on this endpoint.** `option-historical-bars.md:34-93`
  # names exactly five parameters — `symbols`, `category`, `timespan`, `count`,
  # `real_time_required` — and no range. This package's own `get_historical_prices/5`
  # accepts a `range`, and sending it as `start_time`/`end_time` before this asked a
  # parameter the venue does not read; the venue would either ignore it silently or
  # (undocumented either way) reject the call for an unrecognised field. `refuse_bar_range/1`
  # below refuses instead: the venue serves only its most recent `count` bars here, and
  # letting a client-side `within?/2` filter run against a caller's
  # range would, for any range outside that most-recent window, produce a real, complete-
  # looking response with every bar then discarded — a truncation that reads as "no data in
  # that range" rather than "count did not reach back far enough", the family's own named
  # failure shape.
  defp option_bars(symbol, timeframe, range, credentials, opts) do
    with :ok <- refuse_bar_range(range, :option),
         {:ok, timespan} <- stock_timespan(timeframe),
         :ok <- limit_within_max(Keyword.get(opts, :limit), 1_200) do
      params =
        %{
          "symbols" => symbol,
          "category" => "US_OPTION",
          "timespan" => timespan
        }
        |> put_present("count", Keyword.get(opts, :limit))
        # `real_time_required` is optional here (default false, "Include the latest data"),
        # so only a caller who asked for the forming bar sends it; otherwise
        # `include_partial: true` would be answered by a venue that never sent that bar.
        |> put_present(
          "real_time_required",
          if(Keyword.get(opts, :include_partial) == true, do: "true")
        )

      with {:ok, body} <-
             get_symbol("/market-data/options/bars/list", params, credentials, opts),
           {:ok, bars} <- decode_stock_bars(body, symbol, timeframe) do
        {:ok, finish_bars(bars, timeframe, opts)}
      end
    end
  end

  defp refuse_bar_range([], _kind), do: :ok

  defp refuse_bar_range(range, kind) do
    case {Keyword.get(range, :start), Keyword.get(range, :end)} do
      {nil, nil} -> :ok
      _bounded -> {:error, {:unsupported_bar_range, kind}}
    end
  end

  # crypto-bars.md: `count` defaults to 200 and is at most 1200, and the endpoint takes no
  # start or end. A range is therefore a filter over the most recent `count` bars.
  @crypto_bar_default 200
  @crypto_bar_max 1_200

  defp crypto_bars(symbol, timeframe, range, credentials, opts) do
    native = SymbolFormat.to_exchange_symbol(symbol)

    with {:ok, timespan} <- timespan(timeframe) do
      # The caller's `:limit`; else, when a `:start` is given, the page maximum (1200) so the
      # range can be reached past the venue's default of 200 (as the stock path does); else
      # nothing (the venue's default, the latest bars).
      count =
        case {Keyword.get(opts, :limit), Keyword.get(range, :start)} do
          {nil, %DateTime{}} -> @crypto_bar_max
          {limit, _start} -> limit
        end

      # `symbols`, not `symbol`. The replacement endpoint took a rename with the path, and
      # `real_time_required` is **required** where the old path had no such parameter.
      # `false` asks for completed bars only: an in-progress bar has a boundary that has
      # not happened yet, and this package will not store one (see the `@timespans` note).
      #
      # **The vendor's own description of this parameter contradicts itself, and the wire
      # value below is not changed to match either half on its own.** `crypto-bars.md:95`
      # reads: "Whether to include the most recent in-progress bar.<br/>• true: Only
      # completed historical bars are returned<br/>• false: Includes the latest
      # in-progress bar" — the bullets say `true` means completed-only and `false` means
      # include-in-progress, which is the OPPOSITE of what the parameter's own name and
      # default (`"default": "true"`, same page) suggest, and the opposite of what every
      # comment in this codebase about this field has said. Sending `"false"`, as this does,
      # is the choice this package makes under that contradiction: a candle whose boundary
      # has not happened yet is not a bar this package will store (`@timespans`'s own
      # note), so "completed bars only" is the safer of the two readings regardless of
      # which bullet is the typo — and if the bullets are the accurate half rather than the
      # name/default, this sends the WRONG value and gets in-progress bars back, which is
      # recorded here rather than silently assumed correct. Settling it needs a
      # credentialed tier-3 probe comparing `"true"` and `"false"` against a bar still
      # forming; this repository holds no credentials to run one.
      params =
        %{
          "symbols" => native,
          "category" => "US_CRYPTO",
          "timespan" => timespan,
          "real_time_required" => "false"
        }
        |> put_present("count", count)

      with :ok <- crypto_count_within_limit(Keyword.get(opts, :limit)),
           {:ok, body} <- get_symbol("/market-data/crypto/bars/list", params, credentials, opts),
           {:ok, bars} <- decode_bars(body, symbol, timeframe),
           :ok <- range_reached(bars, range, count || @crypto_bar_default) do
        {:ok, bars |> Enum.filter(&within?(&1, range)) |> finish_bars(timeframe, opts)}
      end
    end
  end

  @doc """
  Whether a crypto bars request names a width and a `:limit` the endpoint serves: the two
  checks `get_historical_prices/5` makes on the crypto path before anything is signed, in
  the same order, for `DpExchange.Webull.Fake` to refuse exactly what the real path refuses.
  """
  @spec validate_crypto_bars_request(String.t(), keyword()) :: :ok | {:error, term()}
  def validate_crypto_bars_request(timeframe, opts) do
    with {:ok, _timespan} <- timespan(timeframe),
         do: crypto_count_within_limit(Keyword.get(opts, :limit))
  end

  @doc """
  Whether a bars request names a category, width, range and `:limit` that the endpoint for
  that category serves: the checks `get_historical_prices/5` makes on every one of its five
  paths before anything is signed, in the same order, for `DpExchange.Webull.Fake` to refuse
  exactly what the real path refuses.

  `opts[:category]` defaults to `US_CRYPTO`, as it does there. Crypto checks the width and
  `:limit`; options, futures and event contracts refuse a range and check the width and
  `:limit`; any other category is the equity path, which checks the category, the width (the
  three it adds to the crypto eight) and the `:limit` for that width.
  """
  @spec validate_bars_request(String.t(), keyword(), keyword()) :: :ok | {:error, term()}
  def validate_bars_request(timeframe, range, opts) do
    with :ok <- validate_bar_options(opts),
         :ok <- validate_range(range),
         do: validate_category_bars(timeframe, range, opts)
  end

  @doc """
  The bar options every bars path checks first: `:real_time` was renamed `:include_partial`
  (the family's name for "give me the bar that is still forming") and is refused
  `{:error, {:unsupported_option, :real_time}}` rather than ignored - silently ignoring it
  would hand a caller who asked for the forming bar a series without it. `:include_partial`
  must be a boolean (`{:error, {:invalid_option, :include_partial, value}}`).

  Shared by `get_historical_prices/5`, `get_stock_bars/5` and `DpExchange.Webull.Fake`.
  """
  @spec validate_bar_options(keyword()) :: :ok | {:error, term()}
  def validate_bar_options(opts) do
    cond do
      Keyword.has_key?(opts, :real_time) ->
        {:error, {:unsupported_option, :real_time}}

      Keyword.get(opts, :include_partial) not in [nil, true, false] ->
        {:error, {:invalid_option, :include_partial, Keyword.get(opts, :include_partial)}}

      true ->
        :ok
    end
  end

  defp validate_category_bars(timeframe, range, opts) do
    limit = Keyword.get(opts, :limit)

    case Config.opt(opts, :category, "US_CRYPTO") do
      "US_CRYPTO" ->
        validate_crypto_bars_request(timeframe, opts)

      "US_OPTION" ->
        with :ok <- refuse_bar_range(range, :option),
             {:ok, _timespan} <- stock_timespan(timeframe),
             do: limit_within_max(limit, 1_200)

      "US_FUTURES" ->
        with :ok <- refuse_bar_range(range, :future),
             {:ok, _timespan} <- stock_timespan(timeframe),
             do: limit_within_max(limit, 1_200)

      "US_EVENT" ->
        with :ok <- refuse_bar_range(range, :event),
             {:ok, _timespan} <- event_timespan(timeframe),
             do: limit_within_max(limit, 1_200)

      category ->
        with :ok <- book_category(category),
             {:ok, timespan} <- stock_timespan(timeframe),
             :ok <- limit_within_max(limit, stock_bar_max(timespan)),
             do: validate_sessions(opts)
    end
  end

  @doc """
  Whether `category` is one `get_price/3` can ask a snapshot endpoint about: the check it
  makes before a request, for `DpExchange.Webull.Fake`. Anything else is
  `{:error, {:unsupported_snapshot_category, category}}`.
  """
  @spec validate_snapshot_category(term()) :: :ok | {:error, term()}
  def validate_snapshot_category(category) do
    with {:ok, _path} <- snapshot_path(category), do: :ok
  end

  @doc """
  The category checks `get_top_of_book/3` makes before a request: a snapshot category, and
  not `US_EVENT`, which answers `{:error, {:use_get_event_order_book, "US_EVENT"}}`. For
  `DpExchange.Webull.Fake`, in the real order.
  """
  @spec validate_top_of_book_category(term()) :: :ok | {:error, term()}
  def validate_top_of_book_category(category) do
    with :ok <- refuse_event_top_of_book(category), do: validate_snapshot_category(category)
  end

  @doc """
  Whether `category` and `opts[:depth]` are an order-book request `get_order_book/3` sends:
  the category (`US_STOCK`, `US_ETF` or `US_FUTURES`) and a depth in the range its page
  states. The checks it makes before anything is signed, for `DpExchange.Webull.Fake`.
  """
  @spec validate_book_request(term(), keyword()) :: :ok | {:error, term()}
  def validate_book_request(category, opts) do
    with :ok <- refuse_option(opts, :limit),
         {:ok, _path} <- book_path(category),
         :ok <- book_depth(category, Keyword.get(opts, :depth)),
         do: validate_hours_flags(opts)
  end

  @doc """
  Whether `opts[:extended_hours]` and `opts[:overnight]` are each absent or a boolean: the
  check the snapshot, top-of-book and order-book reads make before the request is built, for
  `DpExchange.Webull.Fake`. Anything else is `{:error, {:invalid_option, key, value}}`.

  The two are sent to the venue as `"true"` / `"false"` through `to_string/1`, which raised
  `Protocol.UndefinedError` in the caller for a map or tuple and sent `"yes"` or `"1"` as
  typed for text and numbers: values the venue's boolean parameters do not define.
  """
  @spec validate_hours_flags(keyword()) :: :ok | {:error, {:invalid_option, atom(), term()}}
  def validate_hours_flags(opts) do
    Enum.find_value([:extended_hours, :overnight], :ok, fn key ->
      case Keyword.get(opts, key) do
        flag when flag in [nil, true, false] -> nil
        other -> {:error, {:invalid_option, key, other}}
      end
    end)
  end

  @doc """
  Whether `opts[:category]` (default `US_STOCK`) and `opts[:limit]` are a tape request
  `get_trades/3` sends: a category with a tape endpoint, and a count within that endpoint's
  stated maximum. The checks it makes before anything is signed, for
  `DpExchange.Webull.Fake`.
  """
  @spec validate_trades_request(keyword()) :: :ok | {:error, term()}
  def validate_trades_request(opts) do
    category = Config.opt(opts, :category, "US_STOCK")

    # `:sessions` is a session name or a list of them, as `get_trades/3` checks it: a map or a
    # list of maps there raised `Protocol.UndefinedError` in `Enum.join/2` / `to_string/1`.
    with :ok <- refuse_option(opts, :since),
         {:ok, _path} <- tick_path(category),
         :ok <- limit_within_max(Keyword.get(opts, :limit), tick_max(category)),
         do: validate_sessions(opts)
  end

  # A FAMILY option this endpoint has no parameter for is refused, never ignored (family
  # convention MD4): `get_order_book`'s `limit:` is not a depth option (`depth:` is), and the
  # tick endpoints take a `count` and no start time, so `since:` has nowhere to go. A `nil` is
  # an absent option.
  defp refuse_option(opts, key) do
    if Keyword.get(opts, key) == nil, do: :ok, else: {:error, {:unsupported_option, key}}
  end

  @doc """
  Whether `opts[:count]` is within the 20 the statement endpoints state as their maximum,
  for a statement `kind` (`get_financials/4`'s own vocabulary). The check
  `get_financials/4` makes after the kind and before anything is signed, for
  `DpExchange.Webull.Fake`. A query option (`:category`, `:type`, `:count`, ...) that is a map,
  a tuple or a list is `{:error, {:invalid_option, key, value}}`, checked first.
  """
  @spec validate_statement_count(atom(), keyword()) :: :ok | {:error, term()}
  def validate_statement_count(kind, opts) do
    endpoint = statement_endpoint(kind)

    allowed =
      case fundamental(endpoint) do
        {:ok, {_path, allowed}} -> allowed
        :error -> []
      end

    # The same two checks, in the same order, as `get_fundamental/4` makes before it builds the
    # query: a query option a query string cannot hold, then the count.
    with :ok <- scalar_opts(opts, [:category | allowed]), do: statement_count(endpoint, opts)
  end

  defp crypto_count_within_limit(n), do: limit_within_max(n, @crypto_bar_max)

  # A candle or trade `:limit` above the page's documented maximum (or not a positive whole
  # number) is `{:invalid_option, :limit, value}` (family convention MD4). It was
  # `{:limit_out_of_range, n, max: max}`; the `:count` options of the footprint and statement
  # endpoints keep that shape through `count_within_max/2`.
  defp limit_within_max(nil, _max), do: :ok
  defp limit_within_max(n, max) when is_integer(n) and n >= 1 and n <= max, do: :ok
  defp limit_within_max(n, _max), do: {:error, {:invalid_option, :limit, n}}

  # A bar or tick count over a maximum the endpoint's own page states is refused before the
  # request, in the shape the crypto check above has always used. Only endpoints whose page
  # STATES a maximum are checked (1200 for the bars and futures/option/event ticks, 1000
  # for the stock tape, 20 for the statement endpoints, 5 for `capital-flows`); the depth
  # endpoints state none and are left to the venue.
  defp count_within_max(nil, _max), do: :ok

  defp count_within_max(n, max) when is_integer(n) and n >= 1 and n <= max, do: :ok

  defp count_within_max(n, max), do: {:error, {:limit_out_of_range, n, max: max}}

  # **A range older than the read reaches is refused, not answered short.** A full page
  # whose oldest bar is still after `:start` means older bars exist that this read did not
  # fetch, and filtering it to the range returned a truncated window as complete, or `[]`
  # for a window wholly in the past, which reads as "no trading". A page shorter than
  # `count` is the venue's whole history, and is answered. The refusal is the family's
  # `{:range_too_wide, count}` (this was `{:range_exceeds_count, count}`).
  #
  # **Run on the bars as the venue sent them, before the range filter** - a filtered page is
  # shorter than `count` by construction and would never look full. Shared by the crypto
  # and stock paths.
  defp range_reached(bars, range, count) do
    with %DateTime{} = start <- Keyword.get(range, :start),
         true <- length(bars) >= count,
         %{opened_at: oldest} <- Enum.min_by(bars, & &1.opened_at, DateTime, fn -> nil end),
         :gt <- DateTime.compare(oldest, start) do
      {:error, {:range_too_wide, count}}
    else
      _reached_or_unbounded -> :ok
    end
  end

  @doc """
  Best bid and ask for `symbol` — the top of the book, not a traded price.

  Same snapshot payload as `get_price/3`; the venue returns the last trade and the top of
  the book together, and this splits them. The documented schema carries `bid`, `ask`,
  `bid_size` and `ask_size`, so unlike some venues in this family the sizes are real here
  rather than `nil`.

  **`US_EVENT` is refused here on purpose, the same way `tick_path/1` refuses it for
  `get_trades/3`.** The event snapshot has no single `bid`/`ask` — it publishes
  `yes_bid`/`yes_ask`/`no_bid`/`no_ask` and their sizes (`event-snapshot.md:170-181,221-256`),
  because a binary market has two instruments' worth of quotes, not one. Picking the YES
  side to be "the" bid and ask would answer about only one of the two contracts and, per
  `get_event_order_book/3`'s own moduledoc, the numbers would still look right — a YES ask
  of 0.13 is real and is not "the" ask the way a stock's is. Use
  `get_event_order_book/3` instead, which returns both sides under their own names.

  As in `get_price/3`, a row naming a different symbol than the one asked for is
  `{:error, :not_in_response}`. `bid`, `ask` and the sizes are `nil` where the row does not
  carry a number for them: a price of `0` (or the literal `"null"`; an empty string is an
  absent field) is no resting order on that side, so that side and its size are `nil`,
  while a negative price or text that is not a number is
  `{:error, {:non_positive_price, side, raw}}` / `{:error, {:invalid_decimal, side, raw}}`.
  `venue_time` is the quote's own time (`quote_time`) and **`nil` when the row
  has none** - the stock snapshot states only `last_trade_time`, a different event, and it is
  not used (family convention MD7).
  """
  @spec get_top_of_book(String.t(), map(), keyword()) ::
          {:ok, TopOfBook.t()} | {:error, term()} | {:refused, term()}
  def get_top_of_book(symbol, credentials, opts) do
    category = Config.opt(opts, :category, "US_CRYPTO")

    with :ok <- refuse_event_top_of_book(category),
         {:ok, path} <- snapshot_path(category),
         :ok <- validate_hours_flags(opts),
         :ok <- validate_symbol(symbol) do
      native = snapshot_symbol(symbol, category)
      params = snapshot_params(native, category, opts)

      with {:ok, body} <- get_symbol(path, params, credentials, opts),
           {:ok, row} <- symbol_row(body, native),
           # `bid` / `ask` and `bid_size` / `ask_size`, the names the snapshot pages define
           # (`snapshot.md:255-270`, `crypto-snapshot.md:224-243`, `option-snapshot.md:278-293`,
           # `futures-snapshot.md:238-253`). Nothing shows `bidPrice` / `bid_price` or the
           # camel-case sizes.
           {:ok, bid} <- quote_side_price(row, ["bid"], :bid),
           {:ok, ask} <- quote_side_price(row, ["ask"], :ask) do
        {:ok, top_of_book_row(row, native, category, bid, ask)}
      end
    end
  end

  # **A bid or ask of zero is "no resting order on that side" (`nil`, size `nil`); a negative
  # one, or text that is not a number, refuses the reply** (family convention MD6).
  # The literal `"null"` is the venue's own documented spelling of "no price" (a delisted
  # pair answers it) and is read as no price on that side, as is an absent field.
  defp quote_side_price(row, keys, field) do
    case value(row, keys) do
      # `""` is an empty field, the same "nothing there" `QuoteProto` reads it as.
      absent when absent in [nil, "null", ""] -> {:ok, nil}
      raw -> raw |> required_decimal(field) |> side_price(field, raw)
    end
  end

  defp side_price({:ok, price}, field, raw) do
    cond do
      Decimal.eq?(price, 0) -> {:ok, nil}
      Decimal.negative?(price) -> {:error, {:non_positive_price, field, raw}}
      true -> {:ok, price}
    end
  end

  defp side_price({:error, _reason} = error, _field, _raw), do: error

  defp top_of_book_row(row, native, category, bid, ask) do
    %TopOfBook{
      symbol: snapshot_canonical(native, category),
      bid: bid,
      ask: ask,
      # **A size is the size of a level, and a side with no readable price has no level.**
      # `bid: nil` beside a `bid_size` read as a one-sided book with depth on the empty
      # side. `Socket` already keeps each size only with the price it belongs to; this is
      # the same rule for the same type on the other transport.
      bid_size: bid && size_or_nil(value(row, ["bid_size"])),
      ask_size: ask && size_or_nil(value(row, ["ask_size"])),
      venue_time: quote_time(row, category),
      observed_at: DateTime.utc_now(),
      provider: :webull
    }
  end

  defp refuse_event_top_of_book("US_EVENT"), do: {:error, {:use_get_event_order_book, "US_EVENT"}}
  defp refuse_event_top_of_book(_category), do: :ok

  # **A bid and an ask are stamped with the quote's time, and only the quote's.** The crypto,
  # option and futures snapshots carry both `last_trade_time` and `quote_time`
  # (`crypto-snapshot.md:183,219`, `option-snapshot.md:221,272`, `futures-snapshot.md:221,232`),
  # and a `TopOfBook` dated by the last print judged the trade, not the quote.
  #
  # **A row with no `quote_time` is `nil`, not its `last_trade_time`.** The stock snapshot
  # has only `last_trade_time` (`snapshot.md:214`); this used to fall back to it "rather than
  # lose the only time it has", which dated a quote with a different event's time - on a
  # thinly traded name, hours before the quote. `TopOfBook.venue_time` is the venue's stated
  # time of THAT quote and nil when it states none (family convention MD7); `observed_at`
  # says when this package read it.
  defp quote_time(row, category) do
    # `parse_time(nil)` is an error, so an absent field is nil with the unparseable.
    case snapshot_time(value(row, ["quote_time"]), category) do
      {:ok, at} -> at
      _absent_or_unparseable -> nil
    end
  end

  # `Quote.venue_time`: the venue's stated time of the last trade; `nil` when the row states
  # none or states one this package cannot read.
  defp trade_time(row, category) do
    # `last_trade_time` alone (`snapshot.md:214`, `crypto-snapshot.md:183`,
    # `option-snapshot.md:221`, `futures-snapshot.md:221`, `event-snapshot.md:210`); no page
    # shows a `time`, `ts`, `timestamp` or `tradeTime` on a snapshot row.
    case snapshot_time(value(row, ["last_trade_time"]), category) do
      {:ok, at} -> at
      _absent_or_unparseable -> nil
    end
  end

  # **The unit follows what the page states.** The crypto, option and futures snapshots and the
  # futures depth state their `last_trade_time` / `quote_time` as "Unix epoch ... in milliseconds"
  # (`crypto-snapshot.md:185,221`, `option-snapshot.md:223,274`, `futures-snapshot.md:223,234`,
  # `futures-depth-of-book.md:195`), so those are read as milliseconds only
  # (`parse_time_ms/1`): a seconds-sized number is no time of this venue and is `nil`, not a
  # 2026 instant reached by guessing the unit from the digits. The stock snapshot
  # (`snapshot.md:216`, "Last trade time"), the stock depth (`quotes.md:207`, "Quote time") and
  # the event pages state no unit, so there the seconds-or-milliseconds reading stays.
  @ms_stated_categories ["US_CRYPTO", "US_OPTION", "US_FUTURES"]

  defp snapshot_time(raw, category) when category in @ms_stated_categories,
    do: parse_time_ms(raw)

  defp snapshot_time(raw, _unstated_unit), do: parse_time(raw)

  # The book's own stamp where the row carries one. `nil` rather than the local clock —
  # `observed_at` already holds that, and says which it is.
  defp top_of_book_time(row, category), do: quote_time(row, category)

  # A flat rate, published, not queried — see the moduledoc note on `get_fees/3`.
  @crypto_spread_pct Decimal.new("1.00")
  @crypto_spread_captured_at ~D[2026-09-03]

  @doc """
  Webull's crypto fee — captured from the venue's own published pricing, not from a live
  per-account query.

  **The Trading API this package speaks has no fee-schedule endpoint anywhere in its
  surface** — checked across `Instruments`, `Accounts`, `Assets` and `Activities`, the
  whole of the API's own navigation. What exists under that name lives in a different
  product entirely: **Broker API**'s "Fees and Credits" is an *administrative* interface
  — creating and reading fee deductions/credits a broker applies to a sub-account, not a
  schedule a caller queries. This package does not operate a brokerage (D8), so that
  surface is out of reach on principle as well as on credentials.

  What Webull does publish, on `webull.com/pricing`, is a single flat crypto spread:
  **1.00% per trade, charged by Webull Pay/Bakkt**, the same rate for every account —
  not a tier a credential selects among, so `credentials` plays no part in *which* rate
  comes back, and there is nothing here for a credential to gate.

  ## No credential gate, and that is deliberate (incident, 2026-09-07)

  This is the one endpoint on this venue that answers without a credential.
  `credentials` is accepted, for shape parity with every other callback in this
  module, and never inspected. A 2026-09-06 sweep gated this behind `Auth.present?/1`
  on the reasoning that the real path "had never run through `Auth.headers/2`" —
  true, and beside the point: there is nothing here to sign, because this function
  never builds a request. Gating it broke a real consumer, who resolves venue fees to
  score *candidate* strategy genomes before any account is attached — no credential
  exists at that point by design, so `get_fees/2` became unanswerable and their
  fee-overcome admission gate lost its input. `source: :published_rate` already says
  this answers from a captured constant, not a venue call; a callback that says that
  about itself must not also demand a credential it makes no use of. Captured
  #{@crypto_spread_captured_at}; re-check the page before trusting this figure if it is
  old by the time you read this.
  """
  @spec get_fees(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def get_fees(_credentials, _opts) do
    {:ok,
     %{
       crypto_spread_pct: @crypto_spread_pct,
       charged_by: "Webull Pay/Bakkt",
       source: :published_rate,
       captured_at: @crypto_spread_captured_at
     }}
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
    category = Config.opt(opts, :category, "US_CRYPTO")

    with {:ok, rows} <- all_instrument_rows(nil, credentials, opts, [], 0) do
      # `symbol` alone (`crypto-instrument-list.md:221`): a row's `name` is a display name, not
      # the symbol, and no page shows `disSymbol`.
      names = Enum.map(rows, &value(&1, ["symbol"]))

      # Only a string names an instrument (a map or a list raised in `to_canonical_symbol/1`,
      # REST mutation fuzz, 2026-09-27). A row that names none REFUSES the listing: skipping
      # it left a hole in the catalogue, so a symbol the venue lists read as unlisted.
      if Enum.all?(names, &is_binary/1) do
        {:ok, names |> Enum.map(&listed_symbol(&1, category)) |> Enum.sort() |> Enum.uniq()}
      else
        {:error, :unexpected_response_shape}
      end
    end
  end

  # **Only a crypto pair is split into `BASE-QUOTE`.** `SymbolFormat` cuts a symbol at a
  # trailing `USDT`/`USDC`/`USD`/`BTC`/`ETH`, which is right for `BTCUSD` and wrong for an
  # equity ticker that happens to end in one: `GBTC` and `FBTC` came back from
  # `get_symbols(category: "US_STOCK")` as `G-BTC` and `F-BTC`, names no stock endpoint takes
  # (`snapshot_symbol/2` sends a stock ticker as it is). A ticker is the venue's own identifier.
  defp listed_symbol(native, "US_CRYPTO"), do: SymbolFormat.to_canonical_symbol(native)
  defp listed_symbol(native, _category), do: native

  @doc """
  Every `US_CRYPTO` listing as a `Core.Instrument` — base, quote, instrument type and
  trading status — from the same paginated `/trading/instruments/crypto/profiles/list`
  endpoint `get_symbols/2` already walks.

  ## Category is fixed to `US_CRYPTO`, not read from `opts[:category]` the way
  `get_symbols/2`'s pagination helper does

  `Core.Instrument.instrument_type/0` is `:spot | :perp | :unknown` — no `:equity`
  member — and `instrument-list.md`'s stock row documents a `currency` field that names
  the LISTING currency, not one half of a traded pair the way crypto's `currency` does. A
  `US_STOCK`/`US_ETF` row has no honest quote to put there and no honest instrument type
  to claim, so this callback refuses both by name rather than reaching for the stock
  endpoint and inventing either: `{:error, {:unsupported_instrument_category, category}}`.

  ## `base`/`quote` come from the row's own `currency` field, never a parsed suffix list

  `Core.Instrument`'s own moduledoc names the hazard directly: splitting a symbol by
  scanning a list of known quote codes got Gemini's quote distribution wrong, because
  `BTCUSDCPERP` cannot be split without the venue's own fields. This does not scan
  `SymbolFormat`'s quote list for the `base:`/`quote:` fields — it reads `currency` off
  the SAME row (`crypto-instrument-list.md:266-270`) and strips it from `symbol`
  (`:221-225`) only when that strip is exact and leaves a non-empty remainder (`"BTCUSD"`
  minus `"USD"` is `"BTC"`). `symbol:` itself still goes through
  `SymbolFormat.to_canonical_symbol/1`, same as `get_symbols/2` — the two only need to
  agree for `currency` values `SymbolFormat.quotes/0` also lists, which is every
  `currency` this venue has been seen to publish.

  A row whose `symbol` does not literally end in its own `currency` is DROPPED, not
  guessed at and not made to fail the whole reply — `dp_exchange_robinhood`'s
  `Rest.list_instruments/2` (`row_symbol/1`/`has_symbol?/1`) is the precedent for
  dropping one unreadable row from an otherwise-honest catalogue rather than refusing
  the lot for it.

  ## status: `OC` is `:tradable`; `CO` and `NT` are both `:unknown`

  `Core.Instrument.status_from/1`'s own doc calls `limit_only` tradable "because the
  venue still matches orders". Webull's `CO` ("Liquidate only") is not that — only a
  CLOSING order matches; an order that would open or grow a position is refused — so
  `:tradable` would tell a consumer it can open a position here when the venue will
  refuse it. `NT` ("Non-Tradable") is not `:delisted` either: the row is still LISTED,
  only not currently tradable, and `:delisted` claims the venue removed it, which `NT`
  does not say. `Core.Instrument.status/0` offers exactly `:tradable | :delisted |
  :unknown`, so both land on `:unknown` — a consumer filtering on `status == :tradable`
  sees only `OC` rows; neither `CO` nor `NT` is mistaken for a listing the venue dropped.
  An absent or unrecognised status string is `:unknown` for the same reason: an unseen
  word must not manufacture a delisting nothing said.

  This is how a consumer tells the symbols `get_symbols/2` must still list (Core's
  contract: "every symbol the venue lists", not filtered here either) apart from ones
  the venue will reject at subscribe time — `RENDER-USD`, `SYN-USD`, `XDC-USD`,
  `TOSHI-USD` and the rest of dp_crypto_management's `INVALID_SYMBOL` rejections are
  exactly this: listed, but not `OC`.
  """
  @spec list_instruments(map(), keyword()) ::
          {:ok, [Instrument.t()]} | {:error, term()} | {:refused, term()}
  def list_instruments(credentials, opts) do
    category = Config.opt(opts, :category, "US_CRYPTO")

    with :ok <- ensure_crypto_category(category),
         {:ok, rows} <- all_instrument_rows(nil, credentials, opts, [], 0) do
      collect_instruments(rows)
    end
  end

  # **A row that cannot be read refuses the listing; it is never skipped.** A row whose symbol
  # does not end in its own `currency`, has no `currency`, or is not an object used to be
  # dropped, which left a hole in the catalogue: an instrument the venue lists read as unlisted.
  defp collect_instruments(rows) do
    rows
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
      case to_instrument(row) do
        [instrument] -> {:cont, {:ok, [instrument | acc]}}
        [] -> {:halt, {:error, :unexpected_response_shape}}
      end
    end)
    |> case do
      {:ok, instruments} -> {:ok, Enum.reverse(instruments)}
      {:error, _reason} = error -> error
    end
  end

  defp ensure_crypto_category("US_CRYPTO"), do: :ok

  defp ensure_crypto_category(category),
    do: {:error, {:unsupported_instrument_category, category}}

  defp to_instrument(row) do
    symbol = value(row, ["symbol"])
    currency = value(row, ["currency"])

    case instrument_base(symbol, currency) do
      {:ok, base} ->
        [
          Instrument.new(
            symbol: SymbolFormat.to_canonical_symbol(symbol),
            base: base,
            quote: currency,
            instrument: :spot,
            status: instrument_status(value(row, ["status"]))
          )
        ]

      :error ->
        []
    end
  end

  # `symbol` and `currency` both come from `value/2`, which already refuses anything but a
  # present, non-empty string — the same guard `row_symbol/1` needed in
  # `dp_exchange_robinhood`, here reached through this module's own `value/2` instead of a
  # second implementation of it.
  defp instrument_base(symbol, currency) when is_binary(symbol) and is_binary(currency) do
    if String.ends_with?(symbol, currency) do
      case String.replace_suffix(symbol, currency, "") do
        "" -> :error
        base -> {:ok, base}
      end
    else
      :error
    end
  end

  defp instrument_base(_symbol, _currency), do: :error

  # This venue's own vocabulary (`crypto-instrument-list.md:59-72`), not
  # `Core.Instrument.status_from/1`'s — Webull never sends `online`/`closed`/`delisted`
  # here, so reading it directly is honest where routing through `status_from/1` would
  # only ever land on `:unknown` anyway (Webull's OC/CO/NT are not that function's
  # vocabulary) while implying an equivalence that does not hold. See this function's own
  # moduledoc for why `CO` and `NT` both read `:unknown` rather than `:tradable` or
  # `:delisted`.
  defp instrument_status("OC"), do: :tradable
  defp instrument_status(_co_nt_or_unrecognised), do: :unknown

  defp all_instrument_rows(_key, _credentials, _opts, _acc, page) when page >= @max_pages,
    do: {:error, :history_truncated}

  defp all_instrument_rows(key, credentials, opts, acc, page) do
    category = Config.opt(opts, :category, "US_CRYPTO")
    params = instrument_params(category, key)

    with {:ok, path} <- instruments_path(category),
         {:ok, body} <- get(path, params, credentials, opts),
         {:ok, page_rows} <- rows(body) do
      # Pages are collected AS PAGES and concatenated once, not folded with `acc ++ page`.
      # `++` copies its left operand, so appending each page to a growing accumulator is
      # quadratic in the number of rows — the one thing a pagination walk is guaranteed to
      # do a lot of. Measured: 50 pages of 250 rows went from 2.75 ms to 0.55 ms, and 50 of
      # 49 rows from 0.20 ms to 0.01 ms.
      #
      # `dp_exchange_robinhood`'s `walk/6` already did it this way and says why.
      collected = [page_rows | acc]

      case next_pagination_key(body) do
        nil -> {:ok, collected |> Enum.reverse() |> Enum.concat()}
        {:invalid_key, _other} -> {:error, :unexpected_pagination_key}
        ^key -> {:error, :pagination_key_did_not_advance}
        next -> all_instrument_rows(next, credentials, opts, collected, page + 1)
      end
    end
  end

  defp instrument_params(category, key) do
    {wire_category, sub_category} = instrument_category_params(category)

    %{"category" => wire_category}
    |> put_present("sub_category", sub_category)
    |> put_present("pagination_key", key)
  end

  # `/trading/instruments/stocks/profiles/list`'s own `category` parameter has exactly one
  # enum member, `US_STOCK` (instrument-list.md:36-43) — `US_ETF` was never a value it
  # accepts, so every ETF-category call this package made was sent an undefined category
  # rather than filtered to ETFs. The venue reaches ETFs on this same endpoint through
  # `sub_category=ETF` (instrument-list.md:75-89, one of six sub-categories of `US_STOCK`),
  # so a caller asking this package for `"US_ETF"` is translated to that pair rather than
  # passed through unchanged.
  defp instrument_category_params("US_ETF"), do: {"US_STOCK", "ETF"}
  defp instrument_category_params(category), do: {category, nil}

  # A cursor follow shared by every endpoint that documents `pagination_key`, bounded by
  # `@max_pages` for the same reason `all_instrument_rows/5` is — a server that always
  # returns a key must not loop this call forever. `fetch_page` takes the current key
  # (`nil` for the first page) and returns `{:ok, {page_rows, next_key}}`, `next_key` being
  # `nil` on the last page; pages are collected and concatenated once at the end, for the
  # same reason `all_instrument_rows/5`'s own comment gives.
  #
  # `{:error, :history_truncated}` on the bound (family convention DV7; this was
  # `{:too_many_pages, n}`) and `{:error, :pagination_key_did_not_advance}` on a repeated
  # key — fail closed on both, rather than returning the pages collected so far as though
  # they were the whole list.
  defp paginate(fetch_page), do: paginate(fetch_page, nil, [], 0)

  defp paginate(_fetch_page, _key, _acc, page) when page >= @max_pages,
    do: {:error, :history_truncated}

  defp paginate(fetch_page, key, acc, page) do
    with {:ok, {page_rows, next_key}} <- fetch_page.(key) do
      collected = [page_rows | acc]

      case next_key do
        nil -> {:ok, collected |> Enum.reverse() |> Enum.concat()}
        {:invalid_key, _other} -> {:error, :unexpected_pagination_key}
        ^key -> {:error, :pagination_key_did_not_advance}
        next -> paginate(fetch_page, next, collected, page + 1)
      end
    end
  end

  # **Crypto and stock instruments are different endpoints**, and both paginate the same
  # way. The category picks; the default is crypto, which is what this package listed before
  # its asset classes widened.
  @doc """
  Rounds a price and quantity to what the venue will actually accept.

  Reads the same `instruments/.../profiles/list` endpoint `get_symbols/2` already calls —
  filtered to one symbol — rather than a separate lookup. **Crypto and stock instruments
  publish disjoint fields**, verified against the vendor's own live schema, 2026-09-03:

    * **crypto** (`V2CryptoInstrument`-shaped rows): `price_step`, `lot_size`,
      `min_trade_qty`, `max_trade_qty`, `min_trade_amt`, `max_trade_amt` — all six present
    * **stock/ETF**: only `lot_size`. No price step, no per-unit or per-cash min or max
      anywhere on the row — margin ratios and share-class flags instead, none of them
      quantization

  A stock/ETF symbol therefore answers with `quantity_increment` alone and every other
  field `nil` — not a guess at what the venue does not name, and not the crypto shape
  reused because it was already written.

  Category is read from the symbol's own shape (a canonical pair has a dash; a ticker does
  not) rather than asked for, because `quantization/1`'s contract takes only a symbol.

  The row must be the symbol's own: a response whose rows all name other symbols is
  `{:error, :not_in_response}`, never another instrument's increments.
  """
  @spec quantization(String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def quantization(symbol, credentials, opts) do
    with :ok <- validate_symbol(symbol), do: quantization_checked(symbol, credentials, opts)
  end

  defp quantization_checked(symbol, credentials, opts) do
    category = if String.contains?(symbol, "-"), do: "US_CRYPTO", else: "US_STOCK"
    native = if category == "US_CRYPTO", do: SymbolFormat.to_exchange_symbol(symbol), else: symbol

    with {:ok, path} <- instruments_path(category),
         params = %{"category" => category, "symbols" => native},
         {:ok, body} <- get_symbol(path, params, credentials, opts),
         {:ok, row} <- symbol_row(body, native) do
      {:ok, quantum_from_row(row, category)}
    end
  end

  defp quantum_from_row(row, "US_CRYPTO") do
    %{
      price_increment: decimal(value(row, ["price_step"])),
      quantity_increment: decimal(value(row, ["lot_size"])),
      min_quantity: decimal(value(row, ["min_trade_qty"])),
      max_quantity: decimal(value(row, ["max_trade_qty"])),
      min_quote_size: decimal(value(row, ["min_trade_amt"])),
      max_quote_size: decimal(value(row, ["max_trade_amt"])),
      status: value(row, ["status"])
    }
  end

  defp quantum_from_row(row, _stock_or_etf) do
    %{
      price_increment: nil,
      quantity_increment: decimal(value(row, ["lot_size"])),
      min_quantity: nil,
      max_quantity: nil,
      min_quote_size: nil,
      max_quote_size: nil,
      status: value(row, ["status"])
    }
  end

  defp instruments_path("US_CRYPTO"), do: {:ok, "/trading/instruments/crypto/profiles/list"}

  defp instruments_path(category) when category in ["US_STOCK", "US_ETF"],
    do: {:ok, "/trading/instruments/stocks/profiles/list"}

  defp instruments_path(category), do: {:error, {:unsupported_instrument_category, category}}

  # A key echoed back unchanged would page forever without this; see the clause above.
  #
  # A cursor is text. A number, list or object in its place used to be sent back as the next
  # request's `pagination_key`, and `stringify/1` raises on a map or a list - in the caller.
  # It is `{:invalid_key, term}` and the walk refuses it: ending the walk there would hand back
  # the pages collected so far as though they were the whole list.
  defp next_pagination_key(body) when is_map(body) do
    # `pagination_key` (`crypto-instrument-list.md:276` and every paged page); nothing shows
    # `paginationKey` or `next_page_key`.
    case value(body, ["pagination_key"]) do
      "" -> nil
      nil -> nil
      found when is_binary(found) -> found
      other -> {:invalid_key, other}
    end
  end

  defp next_pagination_key(_body), do: nil

  # --- request ------------------------------------------------------------

  defp get(path, params, credentials, opts), do: get(path, params, credentials, opts, :resource)

  # A single-symbol read (`:symbol`): the venue's "no such symbol" answers are
  # `{:refused, :not_listed}` and nothing else - see `not_listed_response?/1`.
  defp get_symbol(path, params, credentials, opts),
    do: get(path, params, credentials, opts, :symbol)

  defp get(path, params, credentials, opts, kind) do
    environment = Environment.resolve(opts)
    host = Environment.host(environment)

    request = %{path: path, query_params: stringify(params), body: "", host: host}
    url = Environment.rest_url(environment) <> path <> query(params)

    :get
    |> HttpClient.request(url, signer(request, credentials), nil, request_opts(opts))
    |> symbol_verdict(kind)
    |> get_result()
  end

  # **A symbol the venue does not list is a refusal, not a retryable error.** The venue
  # answers an unlisted symbol on a single-symbol read with a 4xx `INVALID_SYMBOL` (a 417 in
  # practice) or a 404, and the 4xx used to surface as the generic
  # `{:error, {:exchange_error, :webull, "HTTP 417: ..."}}`, which Core calls retryable: a
  # consumer retried a symbol that will never exist. Both are `{:refused, :not_listed}` now,
  # the one word every venue in the family uses; the venue's text is not carried (it is not
  # stable across venues). Only on single-symbol reads: a 404 on an order or a watchlist is
  # still `:not_found`, which is a different thing that is missing.
  defp symbol_verdict(response, :symbol) do
    if not_listed_response?(response), do: {:refused, :not_listed}, else: response
  end

  defp symbol_verdict(response, :resource), do: response
  defp symbol_verdict(response, :write), do: response

  defp not_listed_response?({:ok, %{status: 404}}), do: true

  defp not_listed_response?({:ok, %{status: status, body: body}})
       when status in 400..499 and status not in [401, 403, 429],
       do: invalid_symbol_body?(body)

  defp not_listed_response?(_other), do: false

  defp invalid_symbol_body?(body) when is_binary(body),
    do: String.contains?(body, "INVALID_SYMBOL")

  defp invalid_symbol_body?(body) when is_map(body) do
    body
    |> Map.take(["error_code", "message"])
    |> Map.values()
    |> Enum.any?(&(is_binary(&1) and String.contains?(&1, "INVALID_SYMBOL")))
  end

  defp invalid_symbol_body?(_other), do: false

  # **A 4xx is a refusal - any 4xx but 408 and 429, reads and writes alike.** The venue read
  # the request and declined it, so nothing was placed, changed or created and a retry of the
  # same request gets the same answer. Core's DV6 says so for every venue ("including 409,
  # 415, 422 and any other 4xx the venue does not document"), and this venue DOCUMENTS one:
  # `417`, its business response, `{"error_code": ..., "message": ...}` (every endpoint page).
  # That 417 used to fall into the generic `{:error, {:exchange_error, ...}}`, which Core calls
  # retryable and which `place_order/3` wrapped as `{:order_unconfirmed, id, ...}`: an order
  # the venue had refused, reported as possibly live. `408` stays an error (a request timeout
  # does not say whether the server acted) and `429` never arrives as a response:
  # `Core.HttpClient` answers it as its own error, which `unsent?/1` knows. 404 is
  # `{:refused, :not_found}`, matched before this guard.
  defguardp declined?(status) when status in 400..499 and status not in [408, 429]

  defp get_result(result) do
    case result do
      {:refused, _reason} = verdict ->
        verdict

      {:ok, %{status: status, body: body}} when status in 200..299 ->
        decoded_body(body)

      # Nothing at that id: permanent for the request as sent, and the answer the Fake gives
      # for an order it never issued. It was `{:exchange_error, :webull, "HTTP 404 ..."}`,
      # which Core calls retryable.
      {:ok, %{status: 404}} ->
        {:refused, :not_found}

      # Permanent for the request as sent: the venue read it and declined it (400, 401, 403,
      # the documented 417 business response, 409, 422, ...). A caller whose token expired
      # refreshes and calls again, which is a different request rather than a retry of this
      # one. 408 and 429 are not a considered answer and stay errors (`declined?/1`).
      {:ok, %{status: status, body: body}} when declined?(status) ->
        {:refused, refusal(status, body)}

      {:ok, %{status: status, body: body}} ->
        unexpected_status(status, body)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A POST carrying a JSON body.
  #
  # **This venue signs the body**, unlike Coinbase's URI-scoped JWT, so the exact bytes sent
  # must be the exact bytes signed. The encoded string is built once and used for both —
  # encoding twice risks two different orderings of the same map and a signature that does
  # not match the payload, which the venue would reject as an authentication failure rather
  # than as the encoding bug it is.
  defp post(path, body, credentials, opts), do: post(path, body, credentials, opts, :resource)

  # A single-symbol read made by POST (stock bars); see `symbol_verdict/2`.
  defp post_symbol(path, body, credentials, opts),
    do: post(path, body, credentials, opts, :symbol)

  defp post(path, body, credentials, opts, kind) do
    environment = Environment.resolve(opts)
    host = Environment.host(environment)
    encoded = Jason.encode!(body)

    request = %{path: path, query_params: %{}, body: encoded, host: host}
    url = Environment.rest_url(environment) <> path
    headers = signer(request, credentials)

    :post
    |> HttpClient.request(url, headers, encoded, request_opts(opts))
    |> symbol_verdict(kind)
    |> post_result()
  end

  # A write sent exactly once (`send_once/1`): an order, a token, a watchlist.
  defp post_write(path, body, credentials, opts),
    do: post(path, body, credentials, send_once(opts), :write)

  defp post_result(result) do
    case result do
      {:refused, _reason} = verdict ->
        verdict

      {:ok, %{status: status, body: response}} when status in 200..299 ->
        decoded_body(response)

      {:ok, %{status: 404}} ->
        {:refused, :not_found}

      {:ok, %{status: status, body: response}} when declined?(status) ->
        {:refused, refusal(status, response)}

      {:ok, %{status: status, body: response}} ->
        unexpected_status(status, response)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp unexpected_status(status, response) do
    {:error,
     {:exchange_error, :webull,
      "HTTP #{status}: #{inspect(response, limit: 50, printable_limit: 2_048)}"}}
  end

  # Signed per attempt, not once per call. `Core.HttpClient` retries a timeout or a 5xx,
  # and a retry carrying the first attempt's `x-signature-nonce` is a replay the venue is
  # built to refuse — so before this, every retry of a signed request was a wasted call
  # that failed with a misleading authentication error. `Core.HttpClient` calls this
  # function again for each attempt, so each carries its own timestamp and nonce.
  #
  # The consequence is that a retried write can now take effect twice. Every write whose
  # repeat is not harmless is therefore sent once — see `send_once/1`.
  defp signer(request, credentials) do
    fn ->
      request
      |> Map.merge(%{timestamp: Auth.timestamp(), nonce: Auth.nonce()})
      |> Auth.headers(credentials)
    end
  end

  # A write that must not be repeated on a retry: an order placed, cancelled, or a
  # watchlist or token changed. The venue documents no idempotency key — `client_order_id`
  # names the order, and nothing in the reference says a repeated place is deduplicated
  # rather than refused or placed again — so a 5xx whose request in fact landed, retried,
  # would at best tell the caller a success failed and at worst act twice. `put`, not
  # `put_new`: "sent once" is a guarantee, so a `retry_attempts: 3` reaching this module
  # does not turn a cancel or a placement into three requests. The facade and the Fake
  # never let one reach it: these calls are absent from `Options`' retry-key set, so
  # `:retry_attempts` and `:retry_delay` are `{:unknown_option, key}` at the boundary.
  defp send_once(opts), do: Keyword.put(opts, :retry_attempts, 1)

  # `:rate_limit_blocking` was absent from this allowlist entirely — the same
  # family-wide gap traced and fixed on `Subscription`'s copy of this function while
  # investigating DpCryptoManagement's issue #23 (see `Feed`'s moduledoc). Forwarded,
  # not defaulted: a direct call through this module is a one-off, and fail-fast may be
  # exactly what that caller wants — matching `dp_exchange_robinhood`'s `Rest`.
  defp request_opts(opts) do
    opts
    |> Keyword.take([
      :limiter,
      :timeout,
      :retry_attempts,
      :log_requests,
      :plug,
      :adapter,
      :req_adapter,
      :rate_limit_blocking,
      # Forwarded since tick AK: the table accepted these and this list dropped them, so
      # `max_body_bytes: 1_024` bounded nothing. A forwarded `nil` is the default.
      :weight,
      :retry_delay,
      :max_retry_after_s,
      :max_body_bytes
    ])
    # Core's default is one attempt for a non-GET. The POSTs that reach here without
    # `send_once/1` are reads (bars, order preview, token check): each attempt is
    # re-signed and repeating one changes nothing, so they keep three attempts, explicit
    # and lowerable by the caller. Every write passed `send_once/1`, so its 1 wins. A
    # forwarded `nil` counts as absent, or it would fall through to Core's 1.
    |> Keyword.update(:retry_attempts, 3, &(&1 || 3))
    # Per endpoint as well as per venue — see `Supervisor.limits/1`.
    |> Keyword.merge(provider: :webull, raw_status: true, rate_limit_per_endpoint: true)
  end

  defp query(params) when map_size(params) == 0, do: ""
  defp query(params), do: "?" <> URI.encode_query(stringify(params))

  @doc """
  Every account this credential can reach — `/trading/accounts/list`.

  Takes no parameters: the credential decides what it sees.

  **`account_class` is where this venue's breadth shows.** The documented values are
  `INDIVIDUAL_CASH`, `INDIVIDUAL_MARGIN`, `ROTH_IRA`, `TRADITIONAL_IRA`, `ROLLOVER_IRA`,
  `MANAGED_ROTH_IRA`, `MANAGED_TRADITIONAL_IRA`, `CRYPTO`, `FUTURES` and `EVENTS_CASH` — so
  a single credential can hold crypto, futures and event-contract accounts alongside cash
  and margin ones. This package serves crypto today; the accounts endpoint sees all of them
  and says so, which is why the rows come back whole rather than filtered.

  Rows are the venue's own maps. An account is not a value type in this contract, and
  normalising `account_label` into something else would lose exactly the field a caller
  picking an account needs.
  """
  @spec get_accounts(map(), keyword()) ::
          {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def get_accounts(credentials, opts) do
    # `{:ok, [map()]}`: a row that is not an object is not an account (`object_rows/1`).
    with {:ok, body} <- get("/trading/accounts/list", %{}, credentials, opts),
         {:ok, account_rows} <- rows(body) do
      object_rows(account_rows)
    end
  end

  @doc """
  Balances for one account — `/trading/assets/balances/get`.

  Requires `opts[:account_id]`, as every account call on this venue does. There is no
  all-accounts variant; a caller holding several asks per account, and which one is theirs
  to choose.

  ## What this deliberately does not fill in

  The venue publishes several *different* restrictions on a currency balance —
  `frozen_amount`, `held_amount` (in transit), `unsettled_cash`, and the derived
  `buying_power`, `option_buying_power`, `day_buying_power` and `available_withdrawal`. They
  are not the same number and they do not agree.

  `Core.Types.Balance` has one `available_balance`, and **there is no honest way to pick
  which of those it is.** `available_withdrawal` is what can leave the account;
  `buying_power` is what can be traded and on a margin account exceeds the cash; settled and
  unsettled cash differ again. So `available_balance` is `nil` — the venue said several
  things and this package will not choose one and label it "available".

  `balance` is `cash_balance` and `hold` is `frozen_amount`, both of which are the venue's
  own single-meaning fields. The rest is reachable through `get_accounts/2` on a package
  that carries it, and is a known gap in this contract rather than in this venue.
  """
  @spec get_balances(map(), keyword()) ::
          {:ok, [Balance.t()]} | {:error, term()} | {:refused, term()}
  def get_balances(credentials, opts) do
    asked_at = DateTime.utc_now()

    with {:ok, account_id} <- account_id(opts),
         {:ok, body} <-
           get("/trading/assets/balances/get", %{"account_id" => account_id}, credentials, opts),
         {:ok, rows} <- currency_assets(body) do
      to_balances(rows, asked_at)
    end
  end

  # **An absent asset list stays `[]` — a decision this file already made and tests already
  # pin ("a body with no currency assets key is an empty list too").** The venue answered
  # about an account and named no currencies under either spelling; that reads as "you hold
  # nothing" and is different from a balance of zero and different from an error. This is
  # the same shape `rows/1` gives `"data" => nil`: a key whose absence the venue's own
  # envelope treats as "none" rather than "unreadable", and `value/2` cannot tell an absent
  # key apart from one explicitly sent as `null` — both read back as `nil` — so both stay
  # `[]` here for the same reason.
  #
  # **A present value that is not a list is a different case and is NOT this one.** A string,
  # number, boolean or object under `account_currency_assets` is the venue answering with
  # something this package cannot read as an asset list, not the venue saying there are none
  # — the same distinction `rows/1` draws between `"data" => nil` and `"data" => "x"`.
  # Collapsing that into `[]` reported "you hold nothing" for a reply that never said so.
  defp currency_assets(body) when is_map(body) do
    case value(body, ["account_currency_assets"]) do
      rows when is_list(rows) -> {:ok, rows}
      nil -> {:ok, []}
      _unreadable -> {:error, :unexpected_response_shape}
    end
  end

  defp currency_assets(_body), do: {:error, :unexpected_response_shape}

  # Refuses a currency-asset row this package cannot attribute, rather than emitting an
  # unusable `Balance` and reporting it as success.
  #
  # `Core.Types.Balance`'s `new/1` refuses a `nil` in `:currency`. Nothing here called
  # `new/1` — this built the struct literally, the way all five venues do — so the check
  # never ran, and `currency` came straight out of the venue's JSON by key. A renamed or
  # absent `"currency"` produced `%Balance{currency: nil}`: an amount attributable to no
  # asset, returned inside `{:ok, balances}`, which a consumer cannot size, book or
  # reconcile against. It is the renamed-field scenario `Core.Types.Validate`'s moduledoc
  # exists for, arriving through the one path that bypassed the constructor written to catch
  # it — and this venue is the likeliest of the five to hit it, since `value/2` already
  # exists here because Webull sends the same field under two spellings.
  #
  # `cash_balance` is deliberately NOT guarded the same way. `Core.Types.Balance` states
  # that `:balance` may honestly be `nil` while `:currency` may not, and the two are not the
  # same kind of required: an unknown quantity is still a balance, an unattributable one is
  # not.
  defp to_balance(row, asked_at) do
    with {:ok, currency} <- required_currency(value(row, ["currency"])) do
      {:ok,
       %Balance{
         currency: currency,
         balance: decimal(value(row, ["cash_balance"])),
         # Not derived. See the note on get_balances/2: this venue publishes several
         # different "available" figures and they disagree.
         available_balance: nil,
         hold: decimal(value(row, ["frozen_amount"])),
         # When we asked. A balance has no venue event time.
         timestamp: asked_at,
         provider: :webull
       }}
    end
  end

  # One unattributable row refuses the whole reply rather than leaving a gap in it. A balance
  # list with an entry silently missing reads as "you hold none of that currency", which is a
  # different and more dangerous statement than "this response could not be read".
  defp to_balances(rows, asked_at) do
    rows
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
      case to_balance(row, asked_at) do
        {:ok, balance} -> {:cont, {:ok, [balance | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, balances} -> {:ok, Enum.reverse(balances)}
      error -> error
    end
  end

  defp required_currency(code) when is_binary(code) and code != "", do: {:ok, code}
  defp required_currency(_absent), do: {:error, :unexpected_response_shape}

  @doc """
  Open positions on one account — `/trading/assets/positions/list`.

  Requires `opts[:account_id]`.

  **This venue states no side.** Every documented field is a quantity, a price or a P&L, and
  `account-position.md` describes `quantity` only as "Quantity of the position" - it
  documents no sign convention. Direction is therefore read from the sign of `quantity`
  through `Position.from_signed_quantity/1` (a negative is `:short`), **an assumption
  that has not been measured against a live short position** and needs a credential this
  repository never holds. A package that assumed `:long`
  because equities are usually long would produce a short position that is exactly backwards
  with every number in it still plausible.

  `instrument_type` comes from the venue's own `EQUITY | OPTION | FUTURES | CRYPTO | EVENT`.
  An unknown one is `nil`, not the nearest.

  **Two documented row shapes cannot be a `Position` and are refused, with the whole list:**
  an options strategy other than `SINGLE` (one row for several contracts, which sit under
  `legs`) and any `EVENT` row (its `event_outcome`, `yes` or `no`, is the opposite exposure
  to the same symbol and `Position` has nowhere to say which). Both answer
  `{:error, {:unsupported_position, symbol, reason}}`; the alternative was a position that
  read as a plain holding in the underlying, or a `no` holding reported as a `yes` one.
  A `SINGLE` option row's `symbol` is passed on as the venue sent it. The page's own example
  shows the underlying (`AAPL`) there while describing the field as the "option symbol code
  for derivatives", and this was not probed live, so it is not asserted to be the contract
  symbol.

  `liquidation_price` and `leverage` stay `nil`: **the venue publishes neither on this
  endpoint.** `nil` there means "not stated", never "no liquidation risk" — see
  `Core.Types.Position`.

  **A row with no readable `quantity` refuses the whole list**
  (`{:error, {:missing_required_field, :quantity}}`, or `{:invalid_decimal, :quantity,
  value}` for text that is not a number): the page lists it as required, and
  `Core.Types.Position` has no `nil` quantity or side to put in its place.
  """
  @spec get_positions(map(), keyword()) ::
          {:ok, [Position.t()]} | {:error, term()} | {:refused, term()}
  def get_positions(credentials, opts) do
    with {:ok, account_id} <- account_id(opts),
         {:ok, body} <-
           get("/trading/assets/positions/list", %{"account_id" => account_id}, credentials, opts),
         {:ok, position_rows} <- rows(body) do
      to_positions(position_rows)
    end
  end

  # Refuses a position row this venue did not attribute to an instrument.
  #
  # `Core.Types.Position` enforces `:symbol` and its `new/1` refuses a `nil` there, but this
  # decoder builds the struct literally — as everywhere in this family — so that check never
  # ran, and `canonical_or_nil/1` passes an absent symbol straight through. A position naming
  # no instrument cannot be sized, closed or reconciled by anyone: it is not a weaker claim
  # about what is held, it is not a claim at all, and it sits in a list of real positions
  # looking like one.
  #
  # **A quantity this package cannot read refuses the list too.** `Core.Types.Position`
  # enforces `:quantity` and `:side` and states that the quantity is "always positive" and the
  # side "explicit"; a position with neither was built (`signed_quantity/1` answered
  # `{nil, nil}`) and handed to a consumer whose `Position.quantity` arithmetic then raised on
  # `nil`. `account-position.md` lists `quantity` among the row's REQUIRED fields, so a row
  # without a readable one is not the documented shape, and a `:long` would be a guess about
  # direction. The refusal is `{:error, {:missing_required_field, :quantity}}` for an absent
  # one and `{:error, {:invalid_decimal, :quantity, value}}` for text that is not a number.
  defp to_position(row) do
    with {:ok, symbol} <-
           required_position_symbol(
             row
             |> value(["symbol"])
             |> canonical_or_nil(row_instrument_type(row))
           ),
         :ok <- representable_position(row, symbol),
         {:ok, quantity} <- required_decimal(value(row, ["quantity"]), :quantity) do
      {:ok, position_struct(row, symbol, quantity)}
    end
  end

  # **A position `Core.Types.Position` cannot say is refused, not flattened into one it can.**
  # `account-position.md` documents two row shapes this struct has no field for:
  #
  #   * an `option_strategy` other than `SINGLE` (a vertical, straddle, condor, ...) is ONE
  #     row for a whole strategy, with the contracts under `legs` and a `quantity`, `cost_price`
  #     and `last_price` that describe the strategy and not any one contract. Returned as a
  #     `Position`, it read as a plain holding in the underlying's symbol.
  #   * an `EVENT` row carries an `event_outcome` (`yes` or `no`). The two outcomes are
  #     opposite exposures to the same symbol, and a `Position` that drops the field reports
  #     a `no` holding as a `yes` one.
  #
  # The refusal covers the whole list, as an unreadable order does in `collect_orders/1`: a
  # position list quietly missing a spread reads as "nothing is held there".
  defp representable_position(row, symbol) do
    strategy = value(row, ["option_strategy"])

    cond do
      is_binary(strategy) and strategy != "SINGLE" ->
        {:error, {:unsupported_position, symbol, {:option_strategy, strategy}}}

      value(row, ["instrument_type"]) == "EVENT" ->
        {:error, {:unsupported_position, symbol, :event_outcome}}

      true ->
        :ok
    end
  end

  # One unattributable row refuses the whole reply rather than leaving a gap in it. A position
  # list with an entry silently missing reads as "you hold none of that instrument", which is
  # a different and more dangerous claim than "this response could not be read".
  defp to_positions(rows) do
    rows
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
      case to_position(row) do
        {:ok, position} -> {:cont, {:ok, [position | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, positions} -> {:ok, Enum.reverse(positions)}
      error -> error
    end
  end

  defp required_position_symbol(nil), do: {:error, {:missing_required_field, :symbol}}
  defp required_position_symbol(symbol), do: {:ok, symbol}

  defp position_struct(row, symbol, signed_quantity) do
    {side, quantity} = Position.from_signed_quantity(signed_quantity)

    %Position{
      symbol: symbol,
      side: side,
      quantity: quantity,
      instrument_type: row |> value(["instrument_type"]) |> instrument_atom(),
      average_cost: decimal(value(row, ["cost_price"])),
      mark_price: decimal(value(row, ["last_price"])),
      # Marked, not booked. The venue reports only the open figure here.
      unrealised_pnl: decimal(value(row, ["unrealized_profit_loss"])),
      provider: :webull
    }
  end

  defp instrument_atom("EQUITY"), do: :equity
  defp instrument_atom("OPTION"), do: :option
  defp instrument_atom("FUTURES"), do: :futures
  defp instrument_atom("CRYPTO"), do: :crypto
  # No `"EVENT"` clause: an event row never reaches here (`representable_position/2`).
  defp instrument_atom(_other), do: nil

  # The venue's own activity types. `get_transfers/2` is documented in the contract as
  # "deposit and withdrawal history", so these three are what it asks for — the endpoint
  # itself carries far more.
  @transfer_activity_types ~w(DEPOSIT WITHDRAW TRANSFER)

  @doc """
  Money into and out of one account — `/trading/activities/cash-activities/list`.

  Requires `opts[:account_id]`.

  ## This endpoint is much wider than transfers, and that matters

  It lists **every** cash activity: `TRADE`, `FEES`, `DIVIDENDS`, `TAX`, `INTERESTS`,
  `CORPORATE_ACTION`, `OPTION_EA`, `JOURNAL` and `EC_SETTLEMENT` (the page's twelve-value
  enum; `OTHER` is not one) alongside `DEPOSIT`, `WITHDRAW` and `TRANSFER`. The contract asks `get_transfers/2` for deposit and
  withdrawal history, because that is what a cost basis for transferred-in assets needs.

  **Returning all of it under that name would be wrong in a way that costs money.** A
  dividend and a deposit both credit cash and neither is the other; a caller computing what
  it put in would count income as contribution. So this asks the venue for
  `DEPOSIT,WITHDRAW,TRANSFER` and `opts[:activity_types]` widens it, taking the venue's own
  strings.

  **The filter goes to the venue, not to the page.** Filtering here would silently drop
  matching rows that were on the next page.

  ## The venue's two constraints, enforced rather than discovered

  Without a time range the venue answers **the last 7 days** — its default, not this
  package's, and stated here so a caller does not read an empty list as "no deposits ever".

  `start_time` and `end_time` must fall in the **same calendar year**; the venue says
  cross-year queries are not supported. This refuses such a range up front rather than
  sending it and reading whatever comes back, because a venue that silently truncates to
  one year returns a real list that is missing the other half.

  Rows come back as the venue sends them. `activity_sub_type` alone has 60-odd values
  carrying the distinction between an ACH deposit and a wire, a reversal and a payment —
  and no struct in this contract has anywhere to put them.

  ## Pagination follows `pagination_key`, bounded — not `page_size`/`last_activity_id`

  `trade-cash-activity-by-type.md:90` names `account_id`, `activity_types`, `start_time`,
  `end_time` and `pagination_key`; there is no `page_size` and no `last_activity_id`. Both
  were sent before this fix and neither is a parameter the venue reads, so `opts[:limit]`
  and `opts[:after]` did nothing — the whole first page always came back, cursor or not.
  This now walks `pagination_key` to the end (or `@max_pages`, fail closed) instead.
  """
  @spec get_transfers(map(), keyword()) ::
          {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def get_transfers(credentials, opts) do
    types = Config.opt(opts, :activity_types, @transfer_activity_types)

    with {:ok, account_id} <- account_id(opts),
         :ok <- validate_activity_range(opts) do
      base_params =
        %{"account_id" => account_id, "activity_types" => activity_types_param(types)}
        |> put_present("start_time", iso_millis(Keyword.get(opts, :start)))
        |> put_present("end_time", iso_millis(Keyword.get(opts, :end)))

      paginate(cash_activities_page(base_params, credentials, opts))
    end
  end

  @doc """
  **Every** cash activity on one account — the same endpoint `get_transfers/2` narrows.

  Requires `opts[:account_id]`.

  `get_transfers/2` asks the venue for `DEPOSIT,WITHDRAW,TRANSFER` because the contract
  documents it as deposit and withdrawal history. This asks for none of that filtering and
  returns what the endpoint actually carries: `TRADE`, `FEES`, `DIVIDENDS`, `TAX`,
  `INTERESTS`, `CORPORATE_ACTION`, `OPTION_EA`, `JOURNAL` and `EC_SETTLEMENT` alongside the
  three.

  **The two are not interchangeable in either direction.** A dividend and a deposit both
  credit cash and neither is the other: a caller computing what it put in must use
  `get_transfers/2`, and a caller reconciling a balance against everything that moved must
  use this — summing `get_transfers/2` leaves out the fees.

  **Summing this is not a balance either.** `get_balances/2` is the authority; this is the
  explanation for the difference between two of them.

  The venue's two constraints hold here as they do there: without a time range it answers
  the last **7 days**, and a range spanning two calendar years is refused up front rather
  than silently truncated. Pagination follows `pagination_key`, bounded — see
  `get_transfers/2`'s own note; this endpoint is the same one.
  """
  @spec get_transactions(map(), keyword()) ::
          {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def get_transactions(credentials, opts) do
    with {:ok, account_id} <- account_id(opts),
         :ok <- validate_activity_range(opts) do
      base_params =
        %{"account_id" => account_id}
        |> put_present("activity_types", transaction_types(opts))
        |> put_present("start_time", iso_millis(Keyword.get(opts, :start)))
        |> put_present("end_time", iso_millis(Keyword.get(opts, :end)))

      paginate(cash_activities_page(base_params, credentials, opts))
    end
  end

  # Each page's rows are objects or the read is refused: `get_transfers/2` and
  # `get_transactions/2` promise `[map()]` and hand the venue's rows back unnormalised, so a
  # string or a number among them was returned as a "transfer".
  defp cash_activities_page(base_params, credentials, opts) do
    fn key ->
      params = put_present(base_params, "pagination_key", key)

      with {:ok, body} <-
             get("/trading/activities/cash-activities/list", params, credentials, opts),
           {:ok, page_rows} <- rows(body),
           {:ok, objects} <- object_rows(page_rows) do
        {:ok, {objects, next_pagination_key(body)}}
      end
    end
  end

  # Absent by default, which is what asks the venue for everything. A default list here
  # would be this package deciding what "every activity" means.
  defp transaction_types(opts) do
    case Keyword.get(opts, :activity_types) do
      nil -> nil
      types -> activity_types_param(types)
    end
  end

  # The venue takes the types comma-joined. `validate_activity_range/1` has already refused
  # anything but a list of text or the venue's own string, so neither `Enum.join/2` nor
  # `to_string/1` can raise here.
  defp activity_types_param(types) when is_list(types), do: Enum.join(types, ",")
  defp activity_types_param(types), do: to_string(types)

  defp valid_activity_types(nil), do: :ok

  defp valid_activity_types(types) when is_binary(types) and types != "", do: :ok

  defp valid_activity_types([_first | _rest] = types) do
    if Enum.all?(types, &(is_binary(&1) and &1 != "")),
      do: :ok,
      else: {:error, {:invalid_activity_types, types}}
  end

  defp valid_activity_types(types), do: {:error, {:invalid_activity_types, types}}

  # The venue's stated limit. Sending a cross-year range and reading the answer would give a
  # real list missing whichever half the venue dropped.
  #
  # Compared in UTC, the zone `iso_millis/1` puts on the wire. A `DateTime` in another zone
  # carries its local `year`, so `2025-12-31T22:00-05:00` (already 2026 in UTC) read as 2025
  # and let a range the venue sees as cross-year through to be silently truncated.
  defp same_year(%DateTime{} = start, %DateTime{} = finish) do
    from = utc_millis(start).year
    to = utc_millis(finish).year
    if from == to, do: :ok, else: {:error, {:cross_year_range, from, to}}
  end

  defp same_year(_start, _finish), do: :ok

  @doc """
  Whether `opts[:start]`/`opts[:end]` is a range the cash-activity endpoint accepts (both in
  one calendar year, compared in UTC) and `opts[:activity_types]` is something it can send
  (a non-empty list of text, or the venue's own comma-joined string; absent is fine). The
  checks `get_transfers/2` and `get_transactions/2` make after the account and before
  anything is signed, for `DpExchange.Webull.Fake` to refuse exactly as the real path does.
  A list with a non-text member, or a number, is
  `{:error, {:invalid_activity_types, value}}`: it raised out of `Enum.join/2` or went to
  the wire as whatever `to_string/1` made of it.
  """
  @spec validate_activity_range(keyword()) :: :ok | {:error, term()}
  def validate_activity_range(opts) do
    with :ok <- window_times(opts, [:start, :end]),
         :ok <- ordered_window(opts, :start, :end),
         :ok <- same_year(Keyword.get(opts, :start), Keyword.get(opts, :end)),
         do: valid_activity_types(Keyword.get(opts, :activity_types))
  end

  @doc """
  Whether `opts[:since]`/`opts[:until]` are times `get_orders/2` can send: absent, or a
  `DateTime`. For `DpExchange.Webull.Fake`, which refuses exactly as the real path does.

  Only the history listing reads them (the open-orders page names no time parameters), so a
  window asked of an open listing is `{:error, {:unsupported_option, key}}` rather than
  ignored. On a history read a bound that is not a `DateTime` is
  `{:error, {:invalid_time, key, value}}`, and `:since` after `:until` is
  `{:error, {:invalid_option, :since, value}}`.
  """
  @spec validate_orders_window(keyword()) :: :ok | {:error, term()}
  def validate_orders_window(opts) do
    with :ok <- validate_history_flag(opts), do: orders_window(opts, Keyword.get(opts, :history))
  end

  defp orders_window(opts, true) do
    with :ok <- window_times(opts, [:since, :until]), do: ordered_window(opts, :since, :until)
  end

  # The open-orders endpoint names no time parameters (`order-open.md`), so a window asked of
  # it has nowhere to go: refused, not answered with every open order as though the window
  # had been applied.
  defp orders_window(opts, _open) do
    Enum.find_value([:since, :until], :ok, fn key ->
      if Keyword.get(opts, key) == nil, do: nil, else: {:error, {:unsupported_option, key}}
    end)
  end

  # A window whose lower bound is after its upper one is a caller's mistake; sent, it is
  # answered with nothing, which reads as "no orders / no activity in that period".
  defp ordered_window(opts, from_key, to_key) do
    case {Keyword.get(opts, from_key), Keyword.get(opts, to_key)} do
      {%DateTime{} = from, %DateTime{} = to} ->
        if DateTime.compare(from, to) == :gt,
          do: {:error, {:invalid_option, from_key, from}},
          else: :ok

      _open_ended ->
        :ok
    end
  end

  @doc """
  Whether `opts[:history]` is absent or a boolean: the check `get_orders/2` and
  `get_auction_imbalance/3` make before choosing between their open/snapshot and
  history/bars endpoints, for `DpExchange.Webull.Fake`.

  Any other value (`"false"`, `0`, `:no`) used to be truthy to `if`, so a caller who wrote
  `history: "false"` was silently answered from the history endpoint. Refused
  `{:error, {:invalid_option, :history, value}}`.
  """
  @spec validate_history_flag(keyword()) :: :ok | {:error, {:invalid_option, :history, term()}}
  def validate_history_flag(opts) do
    case Keyword.get(opts, :history) do
      flag when flag in [nil, true, false] -> :ok
      other -> {:error, {:invalid_option, :history, other}}
    end
  end

  # **A time bound is a `DateTime`, or the call is refused.** `iso_millis/1` wrote any other
  # term to the wire as it was (an epoch integer as a number, a `NaiveDateTime` as
  # `"2026-01-01 00:00:00"`, a `Date` as a bare date), none of them the page's
  # `yyyy-MM-dd'T'HH:mm:ss.SSS'Z'`, and `same_year/2` waved such a range through, so the
  # cross-year guard was off for exactly the values it could not read. The venue answers an
  # unreadable bound with a refusal about nothing the caller can see, or reads it as another
  # instant; neither is a substitute worth sending.
  defp window_times(opts, keys) do
    Enum.find_value(keys, :ok, fn key ->
      case Keyword.get(opts, key) do
        nil -> nil
        %DateTime{} -> nil
        other -> {:error, {:invalid_time, key, other}}
      end
    end)
  end

  # The venue's documented format: yyyy-MM-dd'T'HH:mm:ss.SSS'Z'. Always UTC and always three
  # fractional digits: `DateTime.to_iso8601/1` keeps a non-UTC offset (`+05:00`) and omits
  # the fraction on a second-precision value, and neither is the documented format.
  defp iso_millis(nil), do: nil

  # No clause for any other term: every caller runs `window_times/2` first (through
  # `validate_activity_range/1` or `validate_orders_window/1`), which refuses a bound that is
  # neither `nil` nor a `DateTime` as `{:invalid_time, key, value}`, so nothing else arrives.
  defp iso_millis(%DateTime{} = at), do: at |> utc_millis() |> DateTime.to_iso8601()

  defp utc_millis(%DateTime{} = at),
    do: at |> DateTime.to_unix(:millisecond) |> DateTime.from_unix!(:millisecond)

  @doc """
  Prices an order **without placing it** — `/trading/orders/preview`.

  Takes the same request `place_order/3` does and builds the same order body, so a preview
  and the order it previews cannot diverge.

  **Crypto is refused before the request.** The vendor states it plainly: *"For crypto
  trading, this feature is currently not supported."* Sending one anyway would return a
  business error a caller cannot distinguish from a rejected order, so this refuses with
  `{:preview_not_supported, :crypto}` and names the reason.

  Returns the venue's own two figures: `estimated_cost` and `estimated_transaction_fee`.
  **What `estimated_cost` means depends on the instrument** — for stocks and options it is
  the total consideration including premium and charges; for futures it is the initial
  margin required to open the position. Those are different quantities, and the key carries
  the instrument so a caller cannot read one as the other.

  A figure the venue sent that cannot be read as a number is
  `{:error, {:invalid_decimal, :estimated_cost | :estimated_fee, value}}`, not a `nil`; an
  absent `estimated_cost` is `{:error, :unexpected_response_shape}`, and an absent fee is
  `nil`.
  """
  @spec preview_order(map(), term(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def preview_order(credentials, request, opts) do
    # The request is judged exactly as `place_order/3` judges it, and FIRST: a request place
    # refuses is refused with place's tuple, whatever its instrument. Only a valid order is
    # then asked whether this venue can price it (crypto cannot).
    with {:ok, _order_type, _tif, leaf} <- checked_order(request),
         :ok <- previewable(instrument_type(request)),
         {:ok, account_id} <- account_id(opts) do
      instrument = instrument_type(request)

      body = %{
        "account_id" => account_id,
        "new_orders" => [Map.put(leaf, "client_order_id", client_order_id(request))]
      }

      with {:ok, response} <- post("/trading/orders/preview", body, credentials, opts) do
        to_preview(response, instrument)
      end
    end
  end

  defp previewable(:crypto), do: {:error, {:preview_not_supported, :crypto}}
  defp previewable(_instrument), do: :ok

  defp to_preview(response, instrument) do
    case rows(response) do
      {:ok, preview_rows} -> to_preview_result(List.first(preview_rows) || response, instrument)
      {:error, _reason} = error -> error
    end
  end

  # **A figure the venue sent and this package cannot read is an error, not a `nil`.**
  # `estimated_cost` and `estimated_transaction_fee` are both REQUIRED by
  # `common-order-preview.md`'s response schema (and the response is one object, not a list).
  # A present-but-unparseable value used to come back as `estimated_cost: nil` inside
  # `{:ok, preview}`, which a caller reads as "the venue priced this order at nothing
  # known" rather than "the venue's answer could not be read". An ABSENT fee stays `nil`:
  # it was never sent, and `nil` says so.
  defp to_preview_result(row, instrument) do
    with {:ok, cost} <-
           required_decimal(value(row, ["estimated_cost"]), :estimated_cost),
         {:ok, fee} <-
           optional_decimal(value(row, ["estimated_transaction_fee"]), :estimated_fee) do
      {:ok,
       %{
         instrument_type: instrument,
         # Total consideration on stocks and options; initial margin on futures. The
         # instrument above says which, because they are not the same quantity.
         estimated_cost: cost,
         estimated_fee: fee
       }}
    else
      {:error, {:missing_required_field, :estimated_cost}} ->
        {:error, :unexpected_response_shape}

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Amends a working order in place — `/trading/orders/replace`.

  **Crypto is refused before the request**, for the same documented reason as
  `preview_order/3`: the vendor's own page says the endpoint modifies equity, options and
  futures orders and that crypto is not supported. A crypto caller wanting a different
  order cancels and re-places, and that window is the venue's rather than this package's.

  **The venue restricts what may change, per order type**, and this refuses the rest rather
  than sending it:

      MARKET               quantity only
      LIMIT                order_type, time_in_force, quantity, limit_price
      STOP_LOSS            order_type, time_in_force, quantity, stop_price
      STOP_LOSS_LIMIT      order_type, time_in_force, quantity, limit_price, stop_price
      TRAILING_STOP_LOSS   trailing_stop_step only

  Keyed on `client_order_id`, like every other order call on this venue.

  ## The body is `account_id` plus a `modify_orders` array, not a flat object

  `common-order-replace.md:141,150` marks both `account_id` and `modify_orders` required
  on the outer body, and `client_order_id` required on each entry of that array — there is
  no top-level `client_order_id`. A flat body with `client_order_id` beside `account_id`,
  which is what this sent before, is not this endpoint's shape at all; the venue's schema
  has no field there to receive it.

  `order_type` is sent too, when the caller's `changes` include it: the `@amendable` table
  below already let `:order_type` through its check for `limit`, `stop` and `stop_limit`
  — a caller changing a limit order to a market one, which the venue's own futures rules
  describe as the one destination each amendable type may switch to — but the field never
  reached the wire, so that change was silently dropped from every replace this package
  sent while the check that was supposed to gate it kept passing.

  The venue's response carries no order, so **the order is read back**: reporting the change
  a caller asked for as though the venue had confirmed it is a different claim from
  reporting what the venue did.

  **A failed read-back is not a failed replace.** The venue has accepted the amendment by the
  time the order is read, so a read that fails (a timeout, a refusal, another order's
  answer) is `{:error, {:replace_accepted_unread, client_order_id, reason}}` - the id goes
  back as `place_order/3` returns `{:order_unconfirmed, id, reason}` - and `get_order/3`
  says what the order is now. Retrying the replace is not the remedy.

  ## Which order is being edited is not guessed

  `opts[:instrument_type]` and `opts[:order_type]` (the type of the order being amended -
  its edit table is chosen from it) are **required**: absent, each is
  `{:error, {:missing_option, key}}`. They used to default to an equity limit order, where
  `place_order/3` defaults to crypto. `changes` that is empty or not a map (`%{}`, `nil`, text,
  a keyword list) is `{:error, {:invalid_order_request, changes}}`, checked before those two
  options, and an order id that is `nil`, not text or
  blank is `{:error, {:invalid_order_id, id}}`, checked first.

  A transport error or 5xx on the replace itself (it may have landed) is
  `{:error, {:order_unconfirmed, client_order_id, reason}}`; no credentials or our own
  limiter refusing, decided before anything is sent, stay the plain `{:error, reason}`.
  """
  @spec replace_order(map(), term(), term(), keyword()) ::
          {:ok, Order.t()} | {:error, term()} | {:refused, term()}
  def replace_order(credentials, client_order_id, changes, opts) do
    with :ok <- validate_replace(client_order_id, changes, opts),
         {:ok, account_id} <- account_id(opts) do
      # Money fields as the venue's strings (`common-order-replace.md` types all four as
      # `"type": "string"`); an integer `quantity` went out as a JSON number.
      modification =
        %{"client_order_id" => client_order_id}
        |> put_present("order_type", changes |> Map.get(:order_type) |> order_type_name())
        |> put_number("quantity", Map.get(changes, :quantity))
        |> put_number("limit_price", Map.get(changes, :price))
        |> put_number("stop_price", Map.get(changes, :stop_price))
        |> put_number("trailing_stop_step", Map.get(changes, :trailing_stop_step))
        |> put_present("time_in_force", changes |> Map.get(:time_in_force) |> tif_name())

      body = %{"account_id" => account_id, "modify_orders" => [modification]}

      # Sent exactly once (`post_write/4`), as `create_watchlist/4` is, and the facade refuses
      # `:retry_attempts`. `Core.HttpClient` retries a timeout or a 5xx, and a replace that
      # already took effect, sent again, is at best refused, telling the caller a success
      # failed. The `client_order_id` names the order being changed, not this change, so the
      # venue cannot tell a repeat from a second replace.
      case post_write("/trading/orders/replace", body, credentials, opts) do
        {:ok, _response} ->
          read_back_replaced(get_order(credentials, client_order_id, opts), client_order_id)

        # A transport error or 5xx does not say whether the amendment landed: the id goes
        # back so the caller reads the order instead of resending. Decided-before-sending
        # outcomes (no credentials, our own limiter) are plain, as for `place_order/3`.
        {:error, reason} ->
          if unsent?(reason, send_once(opts)),
            do: {:error, reason},
            else: {:error, {:order_unconfirmed, client_order_id, reason}}

        refused ->
          refused
      end
    end
  end

  # **The venue accepted the replace; only the read-back failed.** Answering the read-back's
  # own `{:error, _}` / `{:refused, _}` made a replace that took effect look exactly like one
  # that did not, and a caller that retries a failed replace would send it twice. The id goes
  # back with the failure, as `place_order/3`'s `{:order_unconfirmed, id, reason}` does, and
  # `get_order/3` with it is how to find out what the order is now.
  defp read_back_replaced({:ok, %Order{}} = order, _client_order_id), do: order

  defp read_back_replaced({failure, reason}, client_order_id) when failure in [:error, :refused],
    do: {:error, {:replace_accepted_unread, client_order_id, reason}}

  @amendable %{
    market: [:quantity],
    limit: [:order_type, :time_in_force, :quantity, :price],
    stop: [:order_type, :time_in_force, :quantity, :stop_price],
    stop_limit: [:order_type, :time_in_force, :quantity, :price, :stop_price],
    trailing_stop: [:trailing_stop_step]
  }

  @doc """
  Every check `replace_order/4` makes before the account option and the credentials, in its
  order: the order id (`{:invalid_order_id, v}`), `changes` being a map
  (`{:invalid_order_request, changes}`), the two options that say WHICH order is being
  edited (`opts[:instrument_type]` and `opts[:order_type]`, each `{:missing_option, key}`
  when absent), crypto (`{:preview_not_supported, :crypto}`), and the per-type edit table.

  **Neither option is defaulted.** `replace_order/4` used to assume an equity limit order
  where `place_order/3` assumes crypto, so a caller who forgot to say was checked against,
  and edited under, the table of an order it never placed.
  """
  @spec validate_replace(term(), term(), keyword()) :: :ok | {:error, term()}
  def validate_replace(client_order_id, changes, opts) do
    with :ok <- validate_replace_arguments(client_order_id, changes),
         {:ok, instrument} <- replace_option(opts, :instrument_type),
         {:ok, order_type} <- replace_option(opts, :order_type),
         :ok <- previewable(instrument),
         {:ok, _allowed} <- allowed_combinations(instrument),
         :ok <- amendable(order_type, changes) do
      futures_type_change(instrument, order_type, changes)
    end
  end

  # **A futures order changes type in one direction only** (`common-order-replace.md`, "Futures
  # order modification rules"): a limit or stop order "can only be changed to `market`", a
  # stop-limit order "can only be changed to `limit`". Anything else was sent for the venue to
  # refuse; it is `{:unsupported_order_type_change, from, to}` before the request, in the Fake
  # too. The page states no such rule for equities or options, so none is made up for them.
  @futures_type_changes %{limit: :market, stop: :market, stop_limit: :limit}

  defp futures_type_change(:futures, order_type, changes) do
    case Map.get(changes, :order_type) do
      nil -> :ok
      target -> check_futures_target(order_type, target)
    end
  end

  defp futures_type_change(_instrument, _order_type, _changes), do: :ok

  defp check_futures_target(order_type, target) do
    if Map.get(@futures_type_changes, order_type) == target,
      do: :ok,
      else: {:error, {:unsupported_order_type_change, order_type, target}}
  end

  @doc """
  The two positional checks `replace_order/4` makes first: the order id
  (`{:error, {:invalid_order_id, id}}`), then `changes` being a map
  (`{:error, {:invalid_order_request, changes}}`). For `DpExchange.Webull.Options`, which runs
  them before it looks at the options.
  """
  @spec validate_replace_arguments(term(), term()) :: :ok | {:error, term()}
  def validate_replace_arguments(client_order_id, changes) do
    with :ok <- validate_order_id(client_order_id), do: replace_changes(changes)
  end

  # An empty map changes nothing, so it is not a replace: refused with the non-map's tuple,
  # before the instrument and order-type options are asked for.
  defp replace_changes(changes) when is_map(changes) and map_size(changes) > 0, do: :ok
  defp replace_changes(changes), do: {:error, {:invalid_order_request, changes}}

  defp replace_option(opts, key) do
    case Config.opt(opts, key, nil) do
      nil -> {:error, {:missing_option, key}}
      found -> {:ok, found}
    end
  end

  defp amendable(order_type, changes) do
    case Map.fetch(@amendable, order_type) do
      :error ->
        {:error, {:unsupported_order_type, order_type}}

      {:ok, allowed} ->
        case Map.keys(changes) -- allowed do
          [] -> amendment_values(changes)
          rejected -> {:error, {:unsupported_order_edit, order_type, rejected}}
        end
    end
  end

  # **What an amendment carries must be sendable, or the call is refused.** Every field the map
  # names is judged as `place_order/3` judges it, **a present `nil` included**
  # (`DpExchange.Core.Venue.replace_order/4`: "each field that is present is judged as
  # `place_order/3` judges it ..., a present `nil` included, so `%{price: nil}` is
  # `{:invalid_price, nil}`, not 'no change'"). A `nil` used to be dropped as "no change",
  # which left `%{quantity: nil}` answering a bare `:no_order_changes`. An `:order_type` or
  # `:time_in_force` this package has no wire name for was dropped from the body, so the
  # caller was told an amendment happened that never reached the venue; and a quantity or
  # price that is not a number above zero was sent as typed.
  defp amendment_values(changes) do
    with :ok <- present_fields(changes),
         :ok <- positive_numbers(changes, [:quantity, :price, :stop_price, :trailing_stop_step]),
         :ok <- known_name(changes, :order_type, &order_type_name/1, :unsupported_order_type) do
      known_name(changes, :time_in_force, &tif_name/1, :unsupported_time_in_force)
    end
  end

  # The first present-but-`nil` field, in `place_order/3`'s check order, answered with the
  # tag `place_order/3` gives that field when it is `nil`.
  defp present_fields(changes) do
    Enum.find_value(
      [:order_type, :time_in_force, :quantity, :price, :stop_price, :trailing_stop_step],
      :ok,
      fn field ->
        if Map.has_key?(changes, field) and is_nil(Map.fetch!(changes, field)),
          do: {:error, nil_field_tag(field)}
      end
    )
  end

  defp nil_field_tag(:order_type), do: {:missing_field, :order_type}
  defp nil_field_tag(:time_in_force), do: {:missing_field, :time_in_force}
  defp nil_field_tag(field), do: {invalid_number_tag(field), nil}

  defp known_name(set, field, wire_name, error) do
    case Map.fetch(set, field) do
      {:ok, value} -> if wire_name.(value), do: :ok, else: {:error, {error, value}}
      :error -> :ok
    end
  end

  @doc """
  Whether `client_order_id` names an order a call can address: text, and not empty.

  The check `cancel_order/3`, `get_order/3` and `replace_order/4` make FIRST - before the
  account option and before anything is signed - for `DpExchange.Webull.Fake` to refuse what
  the real path refuses. A `nil`, an empty or a whitespace-only id (`"  "` was sent as it
  stood) is `{:error, {:invalid_order_id, id}}`. Length is not checked here: the
  32-character cap is the venue's for an id the CALLER chose (`place_order/3` enforces it,
  as `{:invalid_client_order_id, id}`), and an id the venue issued is not this package's to
  refuse.
  """
  @spec validate_order_id(term()) :: :ok | {:error, {:invalid_order_id, term()}}
  def validate_order_id(id) when is_binary(id) do
    if String.trim(id) == "", do: {:error, {:invalid_order_id, id}}, else: :ok
  end

  def validate_order_id(id), do: {:error, {:invalid_order_id, id}}

  @doc """
  The order book for an equity, ETF or future — `/market-data/stocks/depths/list`, or
  `/market-data/futures/depths/list` for `US_FUTURES`.

  **The crypto and option books are refused.** The crypto snapshot endpoint publishes a top
  of book and no depth, and the vendor states `US_OPTION` is not supported here. So a
  crypto or option category is refused before the request
  (`{:error, {:unsupported_book_category, category}}`) rather than sent and rejected.

  `opts[:category]` picks `US_STOCK` (the default), `US_ETF` or `US_FUTURES`;
  `opts[:depth]` is the venue's own level count. `opts[:overnight]` includes overnight
  trading data on the stock endpoint, which **requires the parameter**, so `false` is sent
  explicitly rather than omitted; the futures endpoint does not take it.

  ## `depth` defaults to `10`

  The stock depths page (`docs/reference/webull/openapi/quotes.md`) marks `depth` required
  and describes it as "L1-1 level, L2-default 10 levels", so `10` is the page's own L2
  figure. On `US_FUTURES` the venue's page states `depth` is **`1–10, required`** with no
  default (`docs/reference/webull/futures-and-event-contracts.md`), so `10` there is this
  package filling a required parameter with a value known to be in range, not a venue
  default being honoured.

  ## What is dropped, and why that is stated rather than silent

  Each level carries the venue's `order` array — market participant IDs and per-participant
  sizes — and `broker` names beneath that. `Core.Types.OrderBook` levels are
  `{price, size}`, so **the attribution is discarded here**. That is a real loss: on a
  lit book, who is quoting is information a caller may want, and this contract has no
  place for it. The sizes that survive are the venue's own level sizes, not a sum this
  package computed from the participants.

  **The row is the requested symbol's.** A row naming another symbol is
  `{:error, :not_in_response}`, never that instrument's book under this one's name; a
  response whose rows name no symbol is read as its first row.

  `venue_time` is the venue's `quote_time`. **A book the venue did not stamp is delivered
  with `venue_time: nil`**, never the local clock: `observed_at` states when this package
  read it, and refusing would discard real levels over an optional field.
  """
  @spec get_order_book(String.t(), map(), keyword()) ::
          {:ok, OrderBook.t()} | {:error, term()} | {:refused, term()}
  def get_order_book(symbol, credentials, opts) do
    category = Config.opt(opts, :category, "US_STOCK")

    with :ok <- refuse_option(opts, :limit),
         {:ok, path} <- book_path(category),
         :ok <- book_depth(category, Keyword.get(opts, :depth)),
         :ok <- validate_hours_flags(opts),
         :ok <- validate_symbol(symbol) do
      params =
        %{
          "symbol" => symbol,
          "category" => category,
          # `10`: the stock page's "L2-default 10 levels"; see this function's own @doc.
          "depth" => to_string(Config.opt(opts, :depth, 10))
        }
        |> put_present("overnight_required", book_overnight(category, opts))

      with {:ok, body} <- get_symbol(path, params, credentials, opts),
           {:ok, row} <- symbol_row(body, symbol) do
        to_order_book(row, symbol, category)
      end
    end
  end

  # **A depth the venue states a range for is checked before the request.** The futures page
  # (`futures-depth-of-book.md`) says "Valid range: 1 – 10"; the stock page states none beyond
  # "L1-1 level, L2-default 10 levels", so there only a positive whole number is required. A
  # string, `0` or a negative went out as `depth=...` for the venue to refuse, or to read as it
  # liked. Absent is the documented `10` sent by `get_order_book/3`.
  defp book_depth(_category, nil), do: :ok
  defp book_depth("US_FUTURES", depth) when is_integer(depth) and depth in 1..10, do: :ok
  defp book_depth("US_FUTURES", depth), do: {:error, {:invalid_option, :depth, depth}}
  defp book_depth(_category, depth) when is_integer(depth) and depth >= 1, do: :ok
  defp book_depth(_category, depth), do: {:error, {:invalid_option, :depth, depth}}

  # Futures have their own depth endpoint, at the same two-sided shape. `US_EVENT` does not
  # belong here at all — see `get_event_order_book/3`.
  defp book_path("US_FUTURES"), do: {:ok, "/market-data/futures/depths/list"}

  defp book_path(category) do
    with :ok <- book_category(category), do: {:ok, "/market-data/stocks/depths/list"}
  end

  # The venue marks `overnight_required` REQUIRED on the **stock** depth endpoint, so it is
  # always sent there — an omitted required parameter is a refusal the caller cannot read.
  # The futures endpoint does not take it, and sending it would assert a session model that
  # endpoint did not offer.
  defp book_overnight("US_FUTURES", _opts), do: nil
  defp book_overnight(_category, opts), do: to_string(Config.opt(opts, :overnight, false))

  # The vendor's own enum. `US_OPTION` is listed as not supported here, and crypto has no
  # depth endpoint at all — its snapshot publishes a top of book and nothing beneath it.
  defp book_category(category) when category in ["US_STOCK", "US_ETF"], do: :ok
  defp book_category(category), do: {:error, {:unsupported_book_category, category}}

  # `venue_time/1` already reads `quote_time`, which is what this endpoint stamps — read,
  # not required. `Core.Types.OrderBook` enforces `[:symbol, :bids, :asks, :observed_at,
  # :provider]` and types `venue_time` as `DateTime.t() | nil`, so an undated book is a
  # shape the contract has a way to say. Refusing threw away the levels themselves, which
  # are the whole of what the caller asked for.
  #
  # The guarantee that mattered is kept and is what the test now asserts directly: an
  # undated book is `nil` here, never this package's clock.
  defp to_order_book(row, symbol, category) do
    with {:ok, bids} <- book_levels(value(row, ["bids"]), :desc),
         {:ok, asks} <- book_levels(value(row, ["asks"]), :asc) do
      {:ok,
       %OrderBook{
         symbol: symbol,
         bids: bids,
         asks: asks,
         venue_time: top_of_book_time(row, category),
         observed_at: DateTime.utc_now(),
         # No sequence on this endpoint. `nil` means the venue did not say, so a caller
         # cannot use this book to detect a gap in a stream.
         sequence: nil,
         provider: :webull
       }}
    end
  end

  # The level's own size, not a sum over its `order` array. Those are different numbers when
  # the venue reports partial attribution, and the level size is the one it stands behind.
  # Sorted here, not passed through in the venue's row order. `Core.Types.OrderBook` makes
  # the ordering part of the contract in as many words — "a caller reading `hd(bids)` as the
  # best bid is reading it correctly, and a venue package that returns venue-order without
  # re-sorting has broken the contract even though every value in it is true" — and this
  # returned whatever row the venue sent first.
  #
  # `{direction, Decimal}` rather than term order, matching `dp_exchange_coinbase`'s
  # `Socket.sorted/2`, because `Decimal` structs do not compare correctly as plain terms.
  #
  # This used to call coinbase "the only package in the family that was already doing
  # this", and that credited a package for half a job. Coinbase builds a book on two
  # paths — `Socket`'s snapshot, which sorted, and `Rest.get_order_book/2`, which did not
  # until 2026-09-14. The attribution was taken from the sorting one and the other went
  # unexamined for a day. "Does this package sort?" is the wrong question: a package has
  # one book path per transport and each needs checking.
  #
  # A level cannot reach the sort without a price: `book_level/1` refuses one that has none.
  #
  # **A level that names a price must state a readable size, or the book is refused.**
  # `Core.Types.OrderBook` types a level `{Decimal.t(), Decimal.t()}` and `OrderBook.new/1`
  # raises on anything else; this built the struct as a literal and let `{price, nil}` through
  # for a level with no `size` (or `"null"`, or `"NaN"`). Dropping the level instead would
  # publish a book with a hole in it as though the venue had shown no liquidity at that price,
  # which is a meaning the venue never stated; so the whole answer is
  # `{:missing_required_field, :size}` / `{:invalid_decimal, :size, value}`.
  #
  # **A level with no readable price refuses the book too** (family convention MD5). The
  # filter above ("the `not is_nil(price)` filter") used to drop it, which published a book
  # with a hole in it as though the venue had shown nothing at that price - the same
  # substitution, one field earlier. A price of zero or less refuses
  # (`{:non_positive_price, :price, raw}`); **a level whose size is zero is dropped**
  # (no liquidity there, nothing was hidden), and a negative size refuses.
  defp book_levels(rows, direction) when is_list(rows) do
    rows
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, levels} ->
      case book_level(row) do
        {:ok, level} -> {:cont, {:ok, [level | levels]}}
        :empty -> {:cont, {:ok, levels}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, levels} ->
        sorted =
          levels
          |> Enum.reverse()
          |> Enum.sort_by(fn {price, _size} -> price end, {direction, Decimal})

        {:ok, sorted}

      {:error, _reason} = error ->
        error
    end
  end

  # Absent or `null` is an empty side; a side that is present and is not a list (a string, a
  # number, an object) is a book this package could not read, which must not be delivered as
  # a side with no liquidity.
  defp book_levels(nil, _direction), do: {:ok, []}
  defp book_levels(_unreadable, _direction), do: {:error, :unexpected_response_shape}

  defp book_level(row) do
    with {:ok, price} <- required_price(value(row, ["price"]), :price),
         {:ok, size} <- required_decimal(value(row, ["size"]), :size) do
      cond do
        Decimal.positive?(size) -> {:ok, {price, size}}
        Decimal.eq?(size, 0) -> :empty
        true -> {:error, {:non_positive_size, :size, value(row, ["size"])}}
      end
    end
  end

  # The venue's footprint granularities. **Deliberately narrower than `timeframes/0`** —
  # the footprint endpoint serves five widths and the bars endpoint serves more, and a
  # caller asking for a width this endpoint does not have gets an error rather than the
  # nearest one.
  @footprint_spans %{"5s" => "S5", "15s" => "S15", "1m" => "M1", "5m" => "M5", "30m" => "M30"}

  @doc """
  Traded volume split by price and by side — `/market-data/stocks/footprints/list`.

  **Requires a separate Webull subscription**, which the vendor states on the endpoint. A
  credential without it gets the venue's own refusal; this package does not pretend to know
  in advance which credentials carry it.

  Widths are `5s`, `15s`, `1m`, `5m` and `30m` — five, where `get_historical_prices/5`
  serves more. A width outside them is `{:unsupported_timeframe, width}` rather than the
  closest one this endpoint does have.

  `opts[:count]` is the venue's bar count (default 200, max 1200); `opts[:session]` picks
  `PRE`, `RTH` or `ATH` — **`OVN` is documented as not supported and is refused here**
  rather than sent.

  ## `real_time_required` is sent as `false`

  The vendor marks it required and says it controls whether an unfinished bar is included.
  `false` asks for completed intervals only: **an in-progress footprint has a boundary that
  has not happened yet**, and its buy/sell split will change before the interval closes. The
  same reasoning `get_historical_prices/5` uses for bars.

  The price maps come back **keyed on the venue's own price strings**. See
  `Core.Types.VolumeProfile` for why they are not re-keyed on `Decimal`.
  """
  @spec get_volume_profile(String.t(), String.t(), map(), keyword()) ::
          {:ok, [VolumeProfile.t()]} | {:error, term()} | {:refused, term()}
  def get_volume_profile(symbol, timeframe, credentials, opts) do
    category = Config.opt(opts, :category, "US_STOCK")

    with {:ok, path} <- footprint_path(category),
         {:ok, span} <- footprint_span(timeframe),
         {:ok, session} <- footprint_session(Keyword.get(opts, :session)),
         :ok <- count_within_max(Keyword.get(opts, :count), 1_200),
         :ok <- validate_symbol(symbol) do
      params =
        %{
          "symbols" => symbol,
          "category" => category,
          "timespan" => span,
          # Completed intervals only; an unfinished footprint's split still moves.
          "real_time_required" => "false"
        }
        |> put_present("count", Keyword.get(opts, :count))
        |> put_present("trading_sessions", session)

      with {:ok, body} <- get_symbol(path, params, credentials, opts),
           {:ok, row} <- symbol_row(body, symbol) do
        decode_profiles(row, symbol, timeframe)
      end
    end
  end

  # Futures publish a footprint at the same shape and their own path.
  #
  # **The futures page's `category` prose says "Only US_STOCK type queries are supported"
  # while its enum lists only `US_FUTURES`.** The enum is what this package sends: the
  # sentence reads as copied from the stock page, and a category the endpoint's own enum
  # does not list cannot be the one it wants. Recorded rather than quietly resolved, because
  # if the prose turns out to be right this is where a reader will look.
  defp footprint_path("US_FUTURES"), do: {:ok, "/market-data/futures/footprints/list"}

  # `footprint.md`'s `category` enum is `US_STOCK` alone ("Only US_STOCK type queries are
  # supported"); `US_ETF` was sent anyway, a value the endpoint does not list.
  defp footprint_path("US_STOCK"), do: {:ok, "/market-data/stocks/footprints/list"}

  defp footprint_path(category), do: {:error, {:unsupported_footprint_category, category}}

  defp footprint_span(timeframe) do
    case Map.fetch(@footprint_spans, timeframe) do
      {:ok, span} -> {:ok, span}
      :error -> {:error, {:unsupported_timeframe, timeframe}}
    end
  end

  # `OVN` is in the venue's enum and its own note says it is not supported. Sending it
  # returns a business error the caller cannot distinguish from an empty session.
  defp footprint_session(nil), do: {:ok, nil}
  defp footprint_session("OVN"), do: {:error, {:unsupported_session, "OVN"}}
  defp footprint_session(session) when session in ["PRE", "RTH", "ATH"], do: {:ok, session}
  defp footprint_session(session), do: {:error, {:unsupported_session, session}}

  @doc """
  Whether a footprint request names a category, width and session the endpoint serves: the
  three checks `get_volume_profile/4` makes before anything is signed, in the same order,
  for `DpExchange.Webull.Fake` to refuse exactly what the real path refuses.
  """
  @spec validate_footprint_request(String.t(), keyword()) :: :ok | {:error, term()}
  def validate_footprint_request(timeframe, opts) do
    with {:ok, _path} <- footprint_path(Config.opt(opts, :category, "US_STOCK")),
         {:ok, _span} <- footprint_span(timeframe),
         {:ok, _session} <- footprint_session(Keyword.get(opts, :session)),
         do: count_within_max(Keyword.get(opts, :count), 1_200)
  end

  defp decode_profiles(row, symbol, timeframe) do
    with {:ok, entries} <- list_value(row, ["result"]),
         do: decode_profile_entries(entries, symbol, timeframe)
  end

  defp decode_profile_entries(entries, symbol, timeframe) do
    entries
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case to_profile(entry, symbol, timeframe) do
        {:ok, profile} -> {:cont, {:ok, [profile | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, profiles} -> {:ok, Enum.reverse(profiles)}
      error -> error
    end
  end

  defp to_profile(entry, symbol, timeframe) do
    with {:ok, opened_at} <- venue_time(entry),
         {:ok, buys} <- price_map(value(entry, ["buy_detail"]), :buy_detail),
         {:ok, sells} <- price_map(value(entry, ["sell_detail"]), :sell_detail) do
      {:ok,
       %VolumeProfile{
         symbol: symbol,
         timeframe: timeframe,
         opened_at: opened_at,
         total_volume: decimal(value(entry, ["total"])),
         # The venue's own buy-minus-sell. Not recomputed from the totals — where they
         # disagree, the gap is the venue's classifier and not an error to correct.
         delta: decimal(value(entry, ["delta"])),
         buy_volume: decimal(value(entry, ["buy_total"])),
         sell_volume: decimal(value(entry, ["sell_total"])),
         buy_at_price: buys,
         sell_at_price: sells,
         session: session_atom(value(entry, ["trading_session"])),
         provider: :webull
       }}
    end
  end

  # **A price level whose size cannot be read refuses the profile.** `VolumeProfile`'s maps
  # are `%{String.t() => Decimal.t()}` and `point_of_control/1` adds the two sides' sizes, so
  # a `nil` size stored under a price (`"null"`, `"NaN"`, text) was a map that type-checks as
  # present and raises `Decimal.add/2` on `nil` in the consumer. Dropping the level instead
  # would publish a footprint with a hole in it that reads as "nothing traded at that price".
  # An absent map is `nil` ("not published"); a present one that is not an object is not
  # the documented shape.
  defp price_map(nil, _field), do: {:ok, nil}

  defp price_map(%{} = detail, field) do
    Enum.reduce_while(detail, {:ok, %{}}, fn {price, size}, {:ok, acc} ->
      case required_size(size, field) do
        {:ok, parsed} ->
          {:cont, {:ok, Map.put(acc, price, parsed)}}

        {:error, {:missing_required_field, _field}} ->
          {:halt, {:error, {:invalid_decimal, field, size}}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp price_map(_unreadable, _field), do: {:error, :unexpected_response_shape}

  defp session_atom("PRE"), do: :pre_market
  defp session_atom("RTH"), do: :regular
  defp session_atom("ATH"), do: :after_hours
  defp session_atom("OVN"), do: :overnight
  defp session_atom(_other), do: nil

  @doc """
  The auction order imbalance — snapshot or published series.

  **Requires a Nasdaq TotalView non-display subscription**, which the vendor states on both
  endpoints.

  `opts[:auction]` is required and is `:opening` or `:closing`; the venue names them
  `PRE_OPEN` and `PRE_CLOSE`. They are different auctions with different windows, and
  choosing one for a caller who did not say would answer a question nobody asked.

  ## Two endpoints, and the series carries less than the snapshot

      snapshot          /market-data/stocks/noii-snapshots/list
      history: true     /market-data/stocks/noii-bars/list

  **The bars publish the three auction prices and the time and nothing else** — no
  `paired_shares`, no `imbalance_shares`, no `imbalance_side`. Those come back `nil`, which
  says the venue did not publish them on that endpoint. `nil` there is not an imbalance of
  zero, and a caller computing a ratio from the series gets `nil` rather than a number that
  looks balanced.

  ## Outside the auction window the snapshot returns the last one, not nothing

  The vendor is explicit: published during ET 9:28–9:30 and 15:50–16:00, updating every 5
  seconds, and **"outside these periods, historical data is returned"**. So the venue's own
  `imbalance_time` is carried alongside `observed_at`, and the two together are the only way
  a caller can tell a live imbalance from this morning's.

  `side` is the venue's own value, unmapped — see `Core.Types.AuctionImbalance` for why.

  `auction` on each result is the one the **row** names in its own `imbalance_action_type`
  (`PRE_OPEN` is `:opening`, `PRE_CLOSE` is `:closing`), not the one requested: outside the
  publication windows the venue returns history, and a row for the other auction must not be
  labelled with the requested one. A row that names none takes the requested auction; one
  that names any other value is `{:error, {:unsupported_auction, value}}`.
  """
  @spec get_auction_imbalance(String.t(), map(), keyword()) ::
          {:ok, [AuctionImbalance.t()]} | {:error, term()} | {:refused, term()}
  def get_auction_imbalance(symbol, credentials, opts) do
    observed_at = DateTime.utc_now()

    with {:ok, auction, action_type} <- auction_type(Keyword.get(opts, :auction)),
         :ok <- validate_history_flag(opts),
         :ok <- validate_symbol(symbol) do
      path =
        if Keyword.get(opts, :history, false),
          do: "/market-data/stocks/noii-bars/list",
          else: "/market-data/stocks/noii-snapshots/list"

      params = %{
        "symbol" => symbol,
        "category" => "US_STOCK",
        "imbalance_action_type" => action_type
      }

      with {:ok, body} <- get_symbol(path, params, credentials, opts),
           {:ok, imbalance_rows} <- rows(body) do
        to_imbalances(imbalance_rows, symbol, auction, observed_at)
      end
    end
  end

  defp to_imbalances(imbalance_rows, symbol, auction, observed_at) do
    imbalance_rows
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
      case to_imbalance(row, symbol, auction, observed_at) do
        {:ok, imbalance} -> {:cont, {:ok, [imbalance | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, imbalances} -> {:ok, Enum.reverse(imbalances)}
      error -> error
    end
  end

  defp auction_type(:opening), do: {:ok, :opening, "PRE_OPEN"}
  defp auction_type(:closing), do: {:ok, :closing, "PRE_CLOSE"}
  defp auction_type(nil), do: {:error, :auction_required}
  defp auction_type(other), do: {:error, {:unsupported_auction, other}}

  defp to_imbalance(row, symbol, requested, observed_at) do
    with :ok <- imbalance_symbol(row, symbol),
         {:ok, auction} <- row_auction(row, requested) do
      {:ok,
       %AuctionImbalance{
         symbol: symbol,
         auction: auction,
         paired_quantity: decimal(value(row, ["paired_shares"])),
         imbalance_quantity: decimal(value(row, ["imbalance_shares"])),
         # The venue's code, carried as sent. Its meaning is not documented.
         side: to_string_or_nil(value(row, ["imbalance_side"])),
         reference_price: decimal(value(row, ["imbalance_ref_price"])),
         near_price: decimal(value(row, ["imbalance_near_price"])),
         far_price: decimal(value(row, ["imbalance_far_price"])),
         # The venue's own time, or nil. Together with `observed_at` this is the only way to
         # tell a live imbalance from one returned outside the auction window.
         venue_time: imbalance_time(row),
         observed_at: observed_at,
         provider: :webull
       }}
    end
  end

  # **A row is the requested symbol's, or the read is refused.** Both NOII pages document
  # `symbol` on each row, and the rows were stamped with the symbol ASKED for whatever they
  # named, so another instrument's imbalance came back filed under this one with every number
  # in it plausible. A row that names no symbol is read as the requested one, as ever.
  defp imbalance_symbol(row, symbol) do
    case value(row, ["symbol"]) do
      nil -> :ok
      named -> if same_symbol?(named, symbol), do: :ok, else: {:error, :not_in_response}
    end
  end

  # **The auction is the one the ROW says it belongs to.** Every row carries its own
  # `imbalance_action_type` (`PRE_OPEN` or `PRE_CLOSE`, `get-noii-snapshot.md`,
  # `get-noii-bars.md`), and the label used to be the auction the caller ASKED for. Outside
  # the venue's publication windows it "returns historical data", so a row for the other
  # auction answered under the requested one's name was a closing imbalance filed as an
  # opening one, with every number in it still plausible. A row that names no auction takes
  # the requested one; one that names a value outside the two is refused.
  defp row_auction(row, requested) do
    case value(row, ["imbalance_action_type"]) do
      nil -> {:ok, requested}
      "PRE_OPEN" -> {:ok, :opening}
      "PRE_CLOSE" -> {:ok, :closing}
      other -> {:error, {:unsupported_auction, other}}
    end
  end

  defp imbalance_time(row) do
    case value(row, ["imbalance_time"]) do
      nil ->
        nil

      raw ->
        # `get-noii-snapshot.md` and `get-noii-bars.md`: "Timestamp in milliseconds".
        case parse_time_ms(raw) do
          {:ok, at} -> at
          _unparsable -> nil
        end
    end
  end

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(value) when is_binary(value), do: value
  defp to_string_or_nil(value) when is_integer(value), do: Integer.to_string(value)

  # A map or a list is not a side code, and `to_string/1` raised on it out of
  # `get_auction_imbalance/3` (REST mutation fuzz, 2026-09-27). `nil` is what an absent
  # side already answers.
  defp to_string_or_nil(_not_a_code), do: nil

  @doc """
  Tick-by-tick public trades — `/market-data/stocks/ticks/list` for `US_STOCK` (the
  default) and `US_ETF`, `/market-data/options/ticks/list` for `US_OPTION` and
  `/market-data/futures/ticks/list` for `US_FUTURES`. Crypto is refused
  (`{:unsupported_book_category, category}`) and `US_EVENT` answers
  `{:use_get_event_trades, "US_EVENT"}`. `opts[:sessions]` reaches the stock tape only.

  **The tape, not `get_trade_history/2`.** That returns the credential's own fills; this
  returns everyone's executions. The venue sends them newest first; they are returned
  **oldest first** by the venue's own time, as `Core.Venue` asks.

  `opts[:limit]` is the venue's `count` (default 30; max 1000 on the stock tape, 1200 on the
  option and futures tapes). `opts[:sessions]` reaches the stock tape only and takes the
  venue's own list — `PRE`, `RTH`, `ATH`, `OVN`, comma-joined — defaulting to `RTH`.
  **The venue marks `trading_sessions` required on the stock tape**, so one is always sent
  there; asking for regular hours by default is a choice, and it is the one that matches what
  `get_price/3` returns. The option and futures tapes take no such parameter and none is sent.

  ## `side` is always `nil`: the venue's five codes are defined nowhere

  The venue documents the field as *"Such as: B S G L N"* and defines none of them -
  **not whose side `B` is** (the taker's, the buyer's, the resting order's). `Core.Types.Trade`
  says an undocumented code is `nil`, not a mapping nobody has checked, so every tick's
  `side` is `nil` (**BREAKING**: `B` was `:buy` and `S` was `:sell`). **Unmeasured**: a live
  read against a known aggressor would settle the meaning; until then the mapping is not
  claimed. Guessing would put volume on the wrong side of a delta, which is the number a
  caller reads a tape for. A price of zero or less refuses the reply
  (`{:non_positive_price, :price, raw}`).

  `broken` is `false` on every tick: this venue publishes no bust flag here, and a venue
  with no concept of busts has nothing busted — which is the same answer.
  """
  @spec get_trades(String.t(), map(), keyword()) ::
          {:ok, [Trade.t()]} | {:error, term()} | {:refused, term()}
  def get_trades(symbol, credentials, opts) do
    category = Config.opt(opts, :category, "US_STOCK")

    with :ok <- refuse_option(opts, :since),
         {:ok, path} <- tick_path(category),
         :ok <- limit_within_max(Keyword.get(opts, :limit), tick_max(category)),
         :ok <- validate_sessions(opts),
         :ok <- validate_symbol(symbol) do
      params =
        %{
          "symbol" => symbol,
          "category" => category,
          "count" => to_string(Config.opt(opts, :limit, 30))
        }
        |> put_present("trading_sessions", tick_sessions(category, opts))

      with {:ok, body} <- get_symbol(path, params, credentials, opts),
           {:ok, row} <- symbol_row(body, symbol) do
        decode_ticks(row, symbol)
      end
    end
  end

  # `tick.md`: "maximum limit 1000"; `option-tick.md` and `futures-tick.md`: 1200.
  defp tick_max(category) when category in ["US_OPTION", "US_FUTURES"], do: 1_200
  defp tick_max(_category), do: 1_000

  # Options and futures each have their own tape endpoint. The stock one refuses both,
  # which is the venue's split rather than an absence.
  defp tick_path("US_OPTION"), do: {:ok, "/market-data/options/ticks/list"}

  defp tick_path("US_FUTURES"), do: {:ok, "/market-data/futures/ticks/list"}

  # **`US_EVENT` is refused here on purpose.** An event tick carries a `yes_price` and a
  # `no_price` and a `side` of `yes`/`no`; `Types.Trade` carries one price and a side of
  # `:buy`/`:sell`. Mapping yes to buy would file a trade in the other instrument of a
  # two-instrument market. `get_event_trades/3` returns the venue's own rows instead.
  defp tick_path("US_EVENT"), do: {:error, {:use_get_event_trades, "US_EVENT"}}

  defp tick_path(category) do
    with :ok <- book_category(category), do: {:ok, "/market-data/stocks/ticks/list"}
  end

  # Required on the stock tape, where `RTH` is the default because it is the session the
  # rest of this package's price data comes from. Neither the option nor the futures tape
  # takes it, and sending it would assert a session model they did not offer.
  defp tick_sessions(category, _opts) when category in ["US_OPTION", "US_FUTURES"], do: nil
  defp tick_sessions(_category, opts), do: sessions_param(Config.opt(opts, :sessions, ["RTH"]))

  defp sessions_param(sessions) when is_list(sessions), do: Enum.join(sessions, ",")
  # Absent is absent, not `""`: `to_string(nil)` sent `"trading_sessions": ""`, a value outside
  # the PRE/RTH/ATH/OVN enum, on every stock bar request that named no session.
  defp sessions_param(nil), do: nil
  defp sessions_param(session), do: to_string(session)

  defp decode_ticks(row, symbol) do
    row
    |> list_value(["result"])
    |> case do
      {:ok, ticks} -> decode_tick_entries(ticks, symbol)
      error -> error
    end
  end

  defp decode_tick_entries(ticks, symbol) do
    ticks
    |> Enum.reduce_while({:ok, []}, fn tick, {:ok, acc} ->
      case to_trade(tick, symbol) do
        {:ok, trade} -> {:cont, {:ok, [trade | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      # Oldest first, by the venue's own time — see `Core.Venue`'s callback doc.
      # The accumulator already holds the venue's newest-first rows reversed, so the stable sort
      # leaves ticks sharing one instant oldest first too.
      {:ok, trades} -> {:ok, Enum.sort_by(trades, & &1.timestamp, DateTime)}
      error -> error
    end
  end

  # **A tick's `time` is documented in milliseconds, so it is read as milliseconds.**
  # `tick.md:223`, `option-tick.md` and `futures-tick.md` all say "Unix epoch timestamp in
  # milliseconds". `venue_time/1` tells seconds from milliseconds by magnitude, which is right
  # for the bar pages that state no unit and wrong here: a seconds-valued `time`
  # (`1787936147`) was accepted as a real second and dated a trade correctly by accident of
  # its magnitude, where the documented contract makes it a unit the venue does not use. A
  # value at or below 100_000_000_000 ms (1973) cannot be a tick of this venue, so it is
  # refused `:invalid_unix_time` rather than reinterpreted. An ISO string is still read as
  # written.
  defp tick_time(tick) do
    case value(tick, ["time"]) do
      nil -> {:error, :missing_venue_timestamp}
      raw -> parse_time_ms(raw)
    end
  end

  defp to_trade(tick, symbol) do
    with {:ok, timestamp} <- tick_time(tick),
         {:ok, price} <- required_price(value(tick, ["price"]), :price),
         {:ok, quantity} <- required_size(value(tick, ["volume"]), :quantity) do
      {:ok,
       %Trade{
         # The venue publishes no per-tick id on this endpoint. `nil` says so.
         id: nil,
         symbol: symbol,
         # **Always `nil`: the venue's `side` code is not defined anywhere it publishes.**
         # `tick.md` / `futures-tick.md` say only "Such as: B S G L N". `Core.Types.Trade`
         # types the taker's side as `:buy | :sell | nil` and says a code the venue does not
         # document is `nil`, rather than a mapping nobody has checked: `B` could be the
         # buyer's side, the taker's, or the resting order's, and a wrong guess inverts
         # every delta while every number stays real. It was `B -> :buy`, `S -> :sell`
         # (BREAKING: those trades now carry `side: nil`). Unmeasured: a live read
         # comparing a tick against a known aggressor would settle the meaning.
         side: nil,
         price: price,
         quantity: quantity,
         timestamp: timestamp,
         # No bust flag on this endpoint; nothing was busted, which is the same answer.
         broken: false,
         provider: :webull
       }}
    end
  end

  # The stock bars endpoint serves **three widths the crypto one does not** — week, month
  # and year — on top of the eight they share.
  @stock_timespans Map.merge(@timespans, %{"1w" => "W", "1M" => "M", "1y" => "Y"})

  # `historical-bars.md`: "Number of bars, default 200" - what the venue returns when no
  # `count` is sent.
  @stock_bar_default 200

  @doc """
  Historical bars for an equity or ETF — `POST /market-data/stocks/bars/list`.

  **A POST, where the crypto bars are a GET**, and its parameters go in a JSON body rather
  than a query string. Same endpoint family, different verb; the vendor documents it so.

  ## Daily and above are adjusted; minute bars are not

  The vendor states it plainly: *"Daily and above are forward-adjusted; minute bars are
  unadjusted."* **These are not the same series at different resolutions.** A caller
  stitching 1m bars onto a daily series across a split gets a discontinuity that is entirely
  real in each half and wrong where they meet, and nothing in the data says which side was
  adjusted.

  This package cannot fix that — the venue publishes what it publishes — so it reports it:
  every bar from this endpoint carries the width it was asked for, and the adjustment
  follows from that width by the venue's rule. `adjusted?/1` answers it for a width without
  a request.

  ## The bar that is still forming is dropped unless `include_partial: true`

  Every bars path in this package (crypto, stock, option, futures, event) removes a bar
  whose `opened_at` plus its width is after now (this machine's clock - the venue sends no
  clock on this endpoint) unless the caller passes `include_partial: true`. The request asks
  the venue for `real_time_required: true` (its default, *"Y: The returned data includes the
  latest market data"*) so that finished bars are not cut off at "the nearest whole hour",
  and the one still forming is removed here. **The option was `real_time:` and is now
  `include_partial:`** (BREAKING); `real_time:` is refused
  `{:error, {:unsupported_option, :real_time}}`. `Core.Types.Candle` has no partial flag, so
  with `include_partial: true` the last bar may still change after it is returned.

  ## The range

  `:start` is inclusive and `:end` **exclusive**, on `opened_at`. The venue returns the latest
  `count` bars (default 200 on its side) up to `end_time`, so a range is walked the one way
  there is: `count` is sent as the caller's `:limit`, or as the endpoint's maximum (1200; 1650
  for `1m`) when a `:start` is given without one, and a full page whose oldest bar is still
  after `:start` is `{:error, {:range_too_wide, count}}` - older bars exist that this read did
  not fetch, and returning the page would present a truncated window as the whole range.
  Whether the venue returns the latest or the oldest `count` bars of a range is **unmeasured**
  (the page does not say); only the oldest-bar check above is made.

  ## A bar's `time` must sit on its width

  The page says only "Bar UTC time" (`historical-bars.md`), not that it is the open. A bar
  whose time is off its grid refuses the whole reply `{:error, {:unaligned_candle, time}}`.
  The grid is the session's, not the UTC epoch's: widths of 30 minutes and under keep the
  strict UTC grid (they divide the 09:30 New York open); `1h` and wider intraday widths need
  only minute 0 or 30 with no seconds (13:30Z is accepted, 13:45Z refused); a `1d`, `1w`,
  `1M` or `1y` bar stamped at 00:00Z or at New York midnight (04:00Z in EDT, 05:00Z in EST)
  is mapped to 00:00 UTC of that date, as `DpExchange.Schwab` does, and a `1d` bar at any
  other time of day is refused (weeks, months and years have no rule in Core, so another
  time is left as sent). **Unmeasured** against a live venue: this is where a session bar
  can open, not an observed stamp.

  Widths: the eight the crypto endpoint serves plus `1w`, `1M` and `1y`.
  """
  @spec get_stock_bars(String.t(), String.t(), keyword(), map(), keyword()) ::
          {:ok, [Candle.t()]} | {:error, term()} | {:refused, term()}
  def get_stock_bars(symbol, timeframe, range, credentials, opts) do
    category = Config.opt(opts, :category, "US_STOCK")

    with :ok <- validate_bar_options(opts),
         :ok <- book_category(category),
         {:ok, timespan} <- stock_timespan(timeframe),
         # `historical-bars.md`: "maximum limit 1200 (M1 supports up to 1650)".
         :ok <- limit_within_max(Keyword.get(opts, :limit), stock_bar_max(timespan)),
         :ok <- validate_sessions(opts),
         :ok <- validate_range(range),
         :ok <- validate_symbol(symbol) do
      count = stock_count(range, opts, timespan)

      body =
        %{
          "symbols" => [symbol],
          "category" => category,
          "timespan" => timespan,
          # **`true`, and the in-progress bar dropped here.** This sent `false` for
          # "completed bars only", but historical-bars.md defines N as "Pulls only the
          # completed bars from the previous period at the nearest whole hour at the time of
          # request": an intraday read at 10:59 stopped at 10:00, up to an hour of finished
          # bars missing. `true` (the venue's default) returns them all, and the one bar
          # still forming is removed below unless `include_partial: true`.
          "real_time_required" => true
        }
        |> put_raw("count", count)
        |> put_raw("start_time", epoch_ms(Keyword.get(range, :start)))
        |> put_raw("end_time", epoch_ms(Keyword.get(range, :end)))
        |> put_present("trading_sessions", sessions_param(Keyword.get(opts, :sessions)))

      with {:ok, response} <-
             post_symbol("/market-data/stocks/bars/list", body, credentials, opts),
           {:ok, bars} <- decode_stock_bars(response, symbol, timeframe),
           :ok <- range_reached(bars, range, count || @stock_bar_default) do
        {:ok, bars |> Enum.filter(&within?(&1, range)) |> finish_bars(timeframe, opts)}
      end
    end
  end

  # The venue's own default is 200 and it is applied when no `count` is sent, which is how a
  # range came back short. A caller's `:limit` is sent; a range with a `:start` and no limit
  # sends the endpoint's maximum so the read reaches as far back as one request can; no
  # range and no limit leaves the venue's default (the latest bars, which is what was asked).
  defp stock_count(range, opts, timespan) do
    case {Keyword.get(opts, :limit), Keyword.get(range, :start)} do
      {nil, nil} -> nil
      {nil, %DateTime{}} -> stock_bar_max(timespan)
      {limit, _start} -> limit
    end
  end

  defp stock_bar_max("M1"), do: 1_650
  defp stock_bar_max(_timespan), do: 1_200

  # Every bars path: a caller who asked for the forming bar (`include_partial: true`) keeps
  # it. Otherwise a bar whose end has not happened yet is not a bar this package returns.
  defp finish_bars(bars, timeframe, opts) do
    if Keyword.get(opts, :include_partial) == true,
      do: bars,
      else: drop_in_progress(bars, timeframe)
  end

  defp drop_in_progress(bars, timeframe) do
    now = DateTime.utc_now()

    Enum.reject(bars, fn bar ->
      case bar_end(bar.opened_at, timeframe) do
        {:ok, finish} -> DateTime.compare(finish, now) == :gt
        :error -> false
      end
    end)
  end

  # **A week, a month and a year have an end too.** `Timeframe.seconds/1` is `:error` for
  # `1w`, `1M` and `1y` (Core will not encode a boundary rule for a width that is not a fixed
  # number of seconds), and this used to read that `:error` as "keep every bar" - while the
  # request had asked the venue for `real_time_required: true`, so the weekly, monthly or
  # yearly bar still forming came back stored as though complete, which is exactly what this
  # function exists to stop. The end is `opened_at` plus the calendar width: a bar that has
  # not reached it is the forming one. Any other width Core cannot size still keeps its bars.
  defp bar_end(opened_at, timeframe) do
    case Timeframe.seconds(timeframe) do
      {:ok, width} -> {:ok, DateTime.add(opened_at, width)}
      :error -> calendar_bar_end(opened_at, timeframe)
    end
  end

  defp calendar_bar_end(opened_at, "1w"), do: {:ok, DateTime.add(opened_at, 7 * 86_400)}
  defp calendar_bar_end(opened_at, "1M"), do: {:ok, DateTime.shift(opened_at, month: 1)}
  defp calendar_bar_end(opened_at, "1y"), do: {:ok, DateTime.shift(opened_at, year: 1)}
  # Deliberately defensive, and unreachable today: every bars path has already refused a width
  # outside `@timespans` / `@stock_timespans`, and each of those is either a width Core can
  # size or one of the three above. It stays so that a width added to a map later keeps its
  # bars (as documented above) rather than raising a `FunctionClauseError` mid-read.
  defp calendar_bar_end(_opened_at, _timeframe), do: :error

  defp stock_timespan(timeframe) do
    case Map.fetch(@stock_timespans, timeframe) do
      {:ok, timespan} -> {:ok, timespan}
      :error -> {:error, {:unsupported_timeframe, timeframe}}
    end
  end

  @doc """
  Whether bars of `timeframe` are forward-adjusted, per the venue's rule.

  Daily and above are; minute bars are not. **`nil` for a width this package does not
  serve** — an unknown width has no answer, and `false` would be a claim.

  Exposed because a caller stitching two widths together needs to know they are not the same
  series, and nothing in the bar data itself says so.
  """
  @spec adjusted?(String.t()) :: boolean() | nil
  def adjusted?(timeframe) do
    case Map.fetch(@stock_timespans, timeframe) do
      {:ok, timespan} -> timespan in ~w(D W M Y)
      :error -> nil
    end
  end

  # **A JSON body, not a query string.** `put_present/3` stringifies, which is right for a
  # query and wrong here: the venue documents `count`, `start_time` and `end_time` as
  # `int32`/`int64`, and a quoted number in a typed JSON field is a different value.
  defp put_raw(map, _key, nil), do: map
  defp put_raw(map, key, value), do: Map.put(map, key, value)

  defp epoch_ms(nil), do: nil
  # No clause for any other term: `get_stock_bars/5` runs `validate_range/1` first, which
  # admits only `nil` and a `DateTime` for either bound, so nothing else can arrive here.
  defp epoch_ms(%DateTime{} = at), do: DateTime.to_unix(at, :millisecond)

  # **Two envelope shapes across this decoder's four callers, and neither is "one level of
  # `result`" the way the old code (and this package's own moduledoc) assumed.**
  # `historical-bars.md:234-238` (stock) and `option-historical-bars.md:210-214` wrap their
  # per-symbol groups in an object — `{"result": [...]}`, `"required": ["result"]` — while
  # `futures-historical-bars.md:180-188` and `event-bars.md:203-209` return the bare array
  # of groups directly (`"type": "array"` at the response root), the same top-level shape
  # `crypto-bars.md:209` documents and `decode_bars/3` already handles correctly for
  # crypto. `rows/1` reads a bare array correctly on its own; it is the object-wrapped
  # stock/option shape it cannot see, because it only unwraps a `"data"` key. Before this,
  # a stock or option response fell into `rows/1`'s bare-object fallback clause — the
  # WHOLE body became one "row" — and `nested_results/1` then read that row's `"result"`
  # key, getting back the array of per-symbol GROUPS (`%{"symbol" => …, "result" => [...]}`)
  # with no `"open"`/`"close"`/`"time"` of their own. `decode_bar/3` was asked to decode
  # each group as though it were a bar and failed (or, before `required_decimal` existed,
  # produced an all-nil candle) for every stock and option request this package made.
  #
  # The range is NOT applied here: `get_stock_bars/5` checks `range_reached/3` on the bars as
  # the venue sent them, then filters.
  defp decode_stock_bars(response, symbol, timeframe) do
    with {:ok, groups} <- bar_groups(response),
         {:ok, raw_bars} <- nested_results(groups) do
      raw_bars
      |> Enum.reduce_while({:ok, []}, fn bar, {:ok, acc} ->
        case decode_bar(bar, symbol, timeframe, :session) do
          {:ok, candle} -> {:cont, {:ok, [candle | acc]}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, bars} ->
          {:ok, bars |> Enum.reverse() |> Enum.sort_by(& &1.opened_at, DateTime)}

        error ->
          error
      end
    end
  end

  defp bar_groups(%{"result" => groups}) when is_list(groups), do: {:ok, groups}
  defp bar_groups(groups) when is_list(groups), do: {:ok, groups}
  defp bar_groups(_other), do: {:error, :unexpected_response_shape}

  # Every group's `result` list, in order; one group whose `result` cannot be read refuses
  # the lot, rather than leaving that symbol's bars out of a reply that reads as complete.
  defp nested_results(groups) do
    groups
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
      case list_value(row, ["result"]) do
        {:ok, entries} -> {:cont, {:ok, [entries | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, pages} -> {:ok, pages |> Enum.reverse() |> Enum.concat()}
      error -> error
    end
  end

  # --- token lifecycle ----------------------------------------------------

  @doc """
  Creates a server-to-server token — `POST /auth/tokens/create`.

  **The token this returns is not usable yet.** It comes back `PENDING`, and the venue's own
  note says verification happens through an SMS code in the Webull app — which needs a
  person, and is not something this package can do. A caller that treats a successful
  response as an authenticated session will find every subsequent call refused.

  `status` travels unmapped for that reason: `PENDING`, `NORMAL`, `INVALID` and `EXPIRED`
  are the venue's four, and only the second is a token that works. A response with no
  `token`, or a `status` outside the four, is refused rather than handed back as a token -
  as the `reason` of the `:write_unconfirmed` below (`{:missing_required_field, field}` /
  `{:unknown_token_status, status}`).

  Tokens default to **15 days** and must be recreated, not renewed — there is no refresh on
  this endpoint. `expires_at` is milliseconds.

  **A create that may have reached the venue and is not proven** (a transport error or
  timeout, a 5xx, a 2xx whose body is unreadable, names no token or states a status outside
  the four) is `{:error, {:write_unconfirmed, nil, reason}}`: a token may now exist (`nil`:
  the request carries no idempotency key), and the venue's SMS verification may be waiting.
  Failures decided before sending (missing credentials, our own limiter refusing a single
  attempt) stay plain, and a 4xx is `{:refused, reason}`. Sent once.
  """
  @spec create_token(map(), keyword()) :: {:ok, map()} | {:error, term()} | {:refused, term()}
  def create_token(credentials, opts) do
    with {:ok, response} <-
           write_outcome(
             post_write("/auth/tokens/create", %{}, credentials, opts),
             send_once(opts)
           ),
         {:ok, row} <- write_outcome(first_row(response)),
         :ok <- write_outcome(token_row(row, :token)) do
      {:ok, row}
    end
  end

  @token_statuses ~w(PENDING NORMAL INVALID EXPIRED)

  # **A token response that names no token, or a status outside the venue's four, is not a
  # token.** `first_row/1` accepts any object, so `%{}` - or an error envelope that arrived
  # with a 2xx - came back as `{:ok, %{}}`: a created token that does not exist, or a checked
  # one with no verdict, which a caller reads as "usable". `create-token.md` and
  # `check-token.md` both document `status` as `PENDING | NORMAL | INVALID | EXPIRED`; a fifth
  # word is the venue saying something this package has no remedy for, and `NORMAL` must
  # never be inferred. `create_token/2` additionally needs the `token` itself.
  defp token_row(row, :token) do
    with {:ok, _token} <- required_string(row, "token", :token), do: token_row(row, :status)
  end

  defp token_row(row, :status) do
    case required_string(row, "status", :status) do
      {:ok, status} when status in @token_statuses -> :ok
      {:ok, status} -> {:error, {:unknown_token_status, status}}
      {:error, _reason} = error -> error
    end
  end

  defp required_string(row, key, field) do
    case value(row, [key]) do
      found when is_binary(found) -> {:ok, found}
      _absent -> {:error, {:missing_required_field, field}}
    end
  end

  @doc """
  Checks a token's status — `POST /auth/tokens/check`.

  **This is the call that distinguishes the four states**, and the reason to make it before
  trusting a stored token: `PENDING` has never been verified, `EXPIRED` has run out, and
  `INVALID` was revoked or never existed. All three fail the same way at the next request,
  and only this endpoint says which.

  The status comes back as the venue's own string. Nothing is mapped to a boolean, because
  "not usable" covers three different problems with three different remedies. A response
  with no `status`, or one outside the venue's four, is refused rather than returned as a
  verdict (`{:error, {:missing_required_field, :status}}` /
  `{:error, {:unknown_token_status, status}}`).
  """
  @spec check_token(String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def check_token(token, credentials, opts) when is_binary(token) do
    with {:ok, response} <- post("/auth/tokens/check", %{"token" => token}, credentials, opts),
         {:ok, row} <- first_row(response),
         :ok <- token_row(row, :status) do
      {:ok, row}
    end
  end

  # A token that is not text is refused here rather than raising `FunctionClauseError` in the
  # caller. The value is a credential, so the error names the field and never echoes it.
  def check_token(_token, _credentials, _opts), do: {:error, {:invalid_field, :token}}

  @doc """
  The OAuth token exchange and refresh — `POST /oauth2/tokens/create` on the Connect host.

  **One endpoint, two operations, and `grant_type` picks.** With `opts[:code]` it exchanges
  the authorization code the host obtained — the second leg of the consent flow. With
  `opts[:refresh_token]` it refreshes. Neither is `{:error, :code_or_refresh_token_required}`
  rather than a call the venue would reject.

  **A different host from every other endpoint** — `oauth-open-api…` — and a form body
  rather than the signed JSON the rest of this package sends. That is why the package/host
  split cannot be read off a path: the same URL serves the host's code exchange and the
  package's refresh.

  **Two expiries come back, and they are not the same clock.** `expires_in` is the access
  token's, in seconds; `rt_expires_in` is the refresh token's, and it is the one that ends
  the session when it runs out. A caller tracking only the first will be surprised.

  A 2xx answer with no `access_token` is `{:error, {:missing_required_field, :access_token}}`,
  not a token response: this package has no vendor schema for this body (the page is not
  retrievable), but a grant that returned no token has not succeeded whatever else it said.

  **A grant that may have been honoured and is not proven is `{:error, {:write_unconfirmed,
  nil, reason}}`**, never a bare error: a transport error or timeout, a 5xx or 408, and a 2xx
  that is undecodable, is not an object or carries no `access_token`. The code may be spent or
  the refresh token rotated with the answer lost, so retrying the same credential is not the
  remedy; start the consent flow again. A 4xx but 408 and 429 is `{:refused, reason}`, and a
  failure decided before sending (our own limiter refusing) stays plain. Sent once.
  """
  @spec oauth_token(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def oauth_token(client_id, client_secret, opts)
      when is_binary(client_id) and is_binary(client_secret) do
    with {:ok, grant} <- oauth_grant(opts),
         {:ok, base_url} <- secure_oauth_url(opts) do
      form =
        Map.merge(
          %{"client_id" => client_id, "client_secret" => client_secret},
          grant
        )

      url = base_url <> "/oauth2/tokens/create"
      headers = [{"Content-Type", "application/x-www-form-urlencoded"}]

      # Sent once: an authorization code is single-use and a refresh token may rotate, so a
      # retry after a lost answer to a request that succeeded fails, and the token it issued
      # is gone.
      #
      # **And for the same reason an answer that was lost is not a plain error.** A transport
      # error or timeout, a 5xx or 408, and a 2xx that is no token (undecodable, not an object,
      # no `access_token`) may all follow a grant the venue honoured: the code is spent or the
      # refresh token rotated, and the new token is gone with the answer. A caller reading a
      # bare `{:error, _}` as "worth retrying" retries with a credential that no longer works.
      # `write_outcome/2` (Core's W1) tags them `{:write_unconfirmed, nil, reason}`, as
      # `create_token/2` does; what was decided before sending stays plain.
      sent_opts = send_once(request_opts(opts))

      :post
      |> HttpClient.request(url, headers, URI.encode_query(form), sent_opts)
      |> oauth_result()
      |> write_outcome(sent_opts)
    end
  end

  # Refused rather than a `FunctionClauseError` in the caller; the client secret is never
  # echoed, so the error names the field.
  def oauth_token(client_id, _client_secret, _opts) when not is_binary(client_id),
    do: {:error, {:invalid_field, :client_id}}

  def oauth_token(_client_id, _client_secret, _opts),
    do: {:error, {:invalid_field, :client_secret}}

  defp oauth_result({:ok, %{status: status, body: body}}) when status in 200..299 do
    with {:ok, tokens} <- decoded_token(body),
         {:ok, _access_token} <- required_string(tokens, "access_token", :access_token),
         do: {:ok, tokens}
  end

  # Any 4xx but 408 and 429 is the venue declining the grant (`declined?/1`): the code or
  # refresh token was read and refused, not lost in transit.
  defp oauth_result({:ok, %{status: status, body: body}}) when declined?(status),
    do: {:refused, refusal(status, body)}

  defp oauth_result({:ok, %{status: status, body: body}}), do: unexpected_status(status, body)
  defp oauth_result({:error, reason}), do: {:error, reason}

  @doc """
  The checks `oauth_token/3` makes before it sends anything, in its order: `client_id` is
  text, `client_secret` is text, exactly one of `opts[:code]` / `opts[:refresh_token]` is
  given, and the OAuth host is `https` (or loopback `http`). For `DpExchange.Webull.Fake`.
  """
  @spec validate_oauth_request(term(), term(), keyword()) :: :ok | {:error, term()}
  def validate_oauth_request(client_id, _client_secret, _opts) when not is_binary(client_id),
    do: {:error, {:invalid_field, :client_id}}

  def validate_oauth_request(_client_id, client_secret, _opts) when not is_binary(client_secret),
    do: {:error, {:invalid_field, :client_secret}}

  def validate_oauth_request(_client_id, _client_secret, opts) do
    with {:ok, _grant} <- oauth_grant(opts),
         {:ok, _url} <- secure_oauth_url(opts),
         do: :ok
  end

  # `code` and `refresh_token` are the venue's two grants and it takes exactly one. Sending
  # both would leave the venue to choose, and which it chose is not something the caller
  # could read back from the response.
  defp oauth_grant(opts) do
    # An empty (or blank) grant is no grant: it used to be sent, and the venue's refusal of an
    # empty `code` says nothing a caller could act on. It is "neither", refused by name.
    case {nonblank(Keyword.get(opts, :code)), nonblank(Keyword.get(opts, :refresh_token))} do
      {code, nil} when is_binary(code) ->
        {:ok, %{"grant_type" => "authorization_code", "code" => code}}

      {nil, refresh} when is_binary(refresh) ->
        {:ok, %{"grant_type" => "refresh_token", "refresh_token" => refresh}}

      {code, refresh} when is_binary(code) and is_binary(refresh) ->
        {:error, :code_and_refresh_token_are_exclusive}

      _neither ->
        {:error, :code_or_refresh_token_required}
    end
  end

  defp nonblank(text) when is_binary(text), do: if(String.trim(text) == "", do: nil, else: text)
  defp nonblank(other), do: other

  # `:oauth_url` is a consumer-overridable base URL, and the form it receives carries the
  # `client_secret` plus the authorization code or refresh token in the body. An `http://`
  # override sent all three in cleartext, silently. Refused instead: https only, with plain
  # http allowed to a loopback host alone (the test seam). The error names no URL, which may
  # itself carry userinfo.
  @loopback_hosts ["127.0.0.1", "localhost", "::1"]

  defp secure_oauth_url(opts) do
    url = Config.opt(opts, :oauth_url, oauth_url(opts))

    case is_binary(url) and URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" ->
        {:ok, url}

      %URI{scheme: "http", host: host} when host in @loopback_hosts ->
        {:ok, url}

      _insecure_or_malformed ->
        {:error, {:insecure_url, :webull}}
    end
  end

  defp oauth_url(opts) do
    case Environment.resolve(opts) do
      :production -> "https://oauth-open-api.webull.com"
      _sandbox -> "https://oauth-open-api.sandbox.webull.com"
    end
  end

  # --- watchlists ---------------------------------------------------------

  @doc """
  The watchlists held at the venue — `GET /market-data/watchlists/list`.

  **`symbols` is `nil` on every row, and that is not an empty watchlist.** This endpoint
  names watchlists and does not list their membership; `get_watchlist/3` reads that with a
  second request. `nil` says "not asked"; `[]` would say "this watchlist is empty", and the
  two are not the same answer.

  The venue caps an account at 20 watchlists.

  A row with no text `watchlist_id` refuses the whole reply as `{:error,
  {:missing_required_field, :id}}`; it is never dropped.
  """
  @spec list_watchlists(map(), keyword()) ::
          {:ok, [Watchlist.t()]} | {:error, term()} | {:refused, term()}
  def list_watchlists(credentials, opts) do
    with {:ok, body} <- get("/market-data/watchlists/list", %{}, credentials, opts),
         {:ok, watchlist_rows} <- rows(body) do
      collect_watchlists(watchlist_rows)
    end
  end

  # **A listing is every watchlist or a refusal - never the ones this package could read.** A
  # row with no text `watchlist_id` used to be dropped, and a caller reading the list then
  # believed the watchlist did not exist (and might create a second one). One row that cannot
  # name itself refuses the whole reply as `{:error, {:missing_required_field, :id}}`, the
  # answer `get_watchlist/3` and `create_watchlist/4` already give for the same shape.
  defp collect_watchlists(watchlist_rows) do
    watchlist_rows
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
      case to_watchlist(row, nil) do
        nil -> {:halt, {:error, {:missing_required_field, :id}}}
        watchlist -> {:cont, {:ok, [watchlist | acc]}}
      end
    end)
    |> case do
      {:ok, watchlists} -> {:ok, Enum.reverse(watchlists)}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  One watchlist including its membership —
  `GET /market-data/watchlists/instruments/list`.

  The membership endpoint returns the instruments and **not the watchlist's name**, so
  `name` is `nil` here where `list_watchlists/2` has it. Reading the listing to fill it in
  would be a second request this function did not make, and a name from a moment ago beside
  a membership from now.

  The `id` is the one the venue's reply names. A reply that names none is
  `{:error, {:missing_required_field, :id}}`; it is not filled in from the id asked for.
  """
  @spec get_watchlist(String.t(), map(), keyword()) ::
          {:ok, Watchlist.t()} | {:error, term()} | {:refused, term()}
  def get_watchlist(watchlist_id, _credentials, _opts)
      when not (is_binary(watchlist_id) and watchlist_id != ""),
      do: {:error, {:invalid_watchlist_id, watchlist_id}}

  def get_watchlist(watchlist_id, credentials, opts) do
    params = %{"watchlist_id" => watchlist_id}

    with {:ok, body} <-
           get("/market-data/watchlists/instruments/list", params, credentials, opts),
         {:ok, row} <- first_row(body),
         # **The id is the venue's, or the read is refused.** This fell back to the id the
         # caller asked for, publishing the caller's own argument as though the venue had
         # confirmed it (`get_order/3` refuses the same shape for the same reason).
         {:ok, id} <- venue_watchlist_id(row),
         # A different watchlist than the one asked for is not this one's membership.
         :ok <- if(id == watchlist_id, do: :ok, else: {:error, :not_in_response}),
         {:ok, instruments} <- list_value(row, ["instruments"]) do
      symbols = Enum.map(instruments, &value(&1, ["symbol"]))

      # `Core.Types.Watchlist.symbols` is `[String.t()]`: only text names an instrument. A
      # member that names none refuses the read; dropping it published a membership with a
      # hole in it as though it were the whole list.
      if Enum.all?(symbols, &is_binary/1) do
        {:ok,
         %Watchlist{
           id: id,
           name: nil,
           symbols: symbols,
           venue_time: nil,
           provider: :webull
         }}
      else
        {:error, :unexpected_response_shape}
      end
    end
  end

  @doc """
  Creates a watchlist and adds `symbols` to it —
  `POST /market-data/watchlists/create`, then `.../instruments/add`.

  **Two requests, and the second can fail after the first succeeded.** The venue creates an
  empty watchlist and adds members separately; where the add fails, the watchlist exists and
  is empty, and this returns the error rather than the id — a caller that saw
  `{:ok, watchlist}` would believe the membership took. The id is in the error term so the
  watchlist can be found and dealt with.

  **If the add itself is unproven** (a timeout or 5xx: it may have landed) the answer is
  `{:error, {:watchlist_created_members_unconfirmed, id, reason}}` - the watchlist exists and
  its membership is UNKNOWN, so read it with `get_watchlist/3` before adding again. Only a
  definite failure is `{:watchlist_created_without_members, id, reason}`.

  An empty `symbols` list makes one request and creates an empty watchlist, which is a real
  thing to want.

  **The venue does not accept event contracts, futures or options here**, by its own note on
  the add endpoint. Symbols default to `US_STOCK`; `opts[:category]` overrides.

  `symbols` is checked before the watchlist is created: a member that is not non-empty text
  is `{:error, {:invalid_symbols, symbols}}`, and `opts[:sort]` must be a whole number
  (`{:error, {:invalid_sort, sort}}`), so a mistake knowable from the arguments does not
  leave an empty watchlist behind.

  **A create that may have reached the venue and is not proven** (a transport error or
  timeout, a 5xx, a 2xx whose body is unreadable or names no id) is `{:error,
  {:write_unconfirmed, nil, reason}}`: the watchlist may exist, so list before retrying.
  Failures decided before sending stay plain.
  """
  @spec create_watchlist(String.t(), [String.t()], map(), keyword()) ::
          {:ok, Watchlist.t()} | {:error, term()} | {:refused, term()}
  def create_watchlist(name, _symbols, _credentials, _opts) when not is_binary(name),
    do: {:error, {:invalid_watchlist_name, name}}

  def create_watchlist(name, symbols, credentials, opts) do
    body = put_present(%{"name" => name}, "sort", Keyword.get(opts, :sort))

    # Sent ONCE (`post_write/4`; the facade refuses `:retry_attempts`). `Core.HttpClient`
    # retries a timeout or a 5xx three times by default, and nothing in this body — a name and an
    # optional sort — lets the venue tell a second create from the first. The comment just
    # below names the outcome that produces: "the list now exists at the venue and the caller
    # has no handle to add to, read or delete it". A retried create makes precisely that
    # orphan, with a second one the caller does get an id for sitting beside it.
    #
    # **The members and the sort are checked BEFORE the watchlist is created.** They were
    # checked by the add that follows the create, so a member that was not text left the
    # watchlist created and empty for a mistake that was knowable from the arguments, and a
    # `sort` of text went out as a JSON string where the page types an integer.
    with {:ok, members} <- validate_watchlist_symbols(symbols),
         :ok <- validate_watchlist_sort(Keyword.get(opts, :sort)),
         :ok <- validate_watchlist_category(opts),
         {:ok, response} <-
           write_outcome(
             post_write("/market-data/watchlists/create", body, credentials, opts),
             send_once(opts)
           ),
         {:ok, row} <- write_outcome(first_row(response)),
         # `:id` is in `Types.Watchlist`'s `@enforce_keys`, so its `new/1` refuses a `nil`
         # there — and nothing here calls `new/1`, the struct being built literally as
         # everywhere in this family, so that check never ran. A created watchlist with no
         # id is the worst moment for one: the list now exists at the venue and the caller
         # has no handle to add to, read or delete it, and `nil` looks like a value.
         #
         # `to_watchlist/2` further down already refuses a row with no `watchlist_id`,
         # citing `dp_exchange_robinhood`'s rule — "a nil key there is worse than one fewer
         # row this cycle". This is the same rule on the create path.
         {:ok, id} <- write_outcome(created_watchlist_id(row)) do
      add_created_members(id, name, members, credentials, opts)
    end
  end

  @doc """
  The members a watchlist write names, as a list: a list of non-empty text, one text, or
  `nil`/`[]` for none. Anything else is `{:error, {:invalid_symbols, value}}`.

  The check `create_watchlist/4` makes before it creates anything, and
  `add_watchlist_instruments/4` / `remove_watchlist_instruments/4` before they write, for
  `DpExchange.Webull.Fake` to refuse exactly what the real path refuses.
  """
  @spec validate_watchlist_symbols(term()) :: {:ok, [String.t()]} | {:error, term()}
  def validate_watchlist_symbols(symbols) do
    members = List.wrap(symbols)

    if Enum.all?(members, &(is_binary(&1) and &1 != "")),
      do: {:ok, members},
      else: {:error, {:invalid_symbols, symbols}}
  end

  @doc """
  Whether `id` and `name` are something a watchlist call can address: an id is non-empty
  text, a name is text. Anything else is `{:error, {:invalid_watchlist_id, id}}` /
  `{:error, {:invalid_watchlist_name, name}}`; these were `FunctionClauseError`s in the
  caller's process. The check `get_watchlist/3`, `update_watchlist/3`, `delete_watchlist/3`
  and `create_watchlist/4` make before anything else, for `DpExchange.Webull.Fake`.
  """
  @spec validate_watchlist_target(:id | :name, term()) :: :ok | {:error, term()}
  def validate_watchlist_target(:id, id) when is_binary(id) and id != "", do: :ok
  def validate_watchlist_target(:id, id), do: {:error, {:invalid_watchlist_id, id}}
  def validate_watchlist_target(:name, name) when is_binary(name), do: :ok
  def validate_watchlist_target(:name, name), do: {:error, {:invalid_watchlist_name, name}}

  @doc """
  Whether `sort` is something a watchlist create or update can send: absent, or a whole
  number. `sort` is a JSON integer on the watchlist pages (`create-watchlist.md:149-154`);
  text or a float there was sent as text, and a value the venue would read some other way.
  Anything else is `{:error, {:invalid_sort, sort}}`. For `DpExchange.Webull.Fake`.
  """
  @spec validate_watchlist_sort(term()) :: :ok | {:error, {:invalid_sort, term()}}
  def validate_watchlist_sort(nil), do: :ok
  def validate_watchlist_sort(sort) when is_integer(sort), do: :ok
  def validate_watchlist_sort(sort), do: {:error, {:invalid_sort, sort}}

  @doc """
  Whether `opts[:category]` (absent means `US_STOCK`) is the one value the watchlist
  instrument endpoints document: their `category` enum is `US_STOCK` alone
  (`add-watchlist-instruments.md` and the remove and update pages). Anything else is
  `{:error, {:invalid_category, category}}` before a request, rather than a 417 from the venue
  that `DpExchange.Webull.Fake` could not model. The check `create_watchlist/4` and the three
  instrument writes make after their members, for `Fake`.
  """
  @spec validate_watchlist_category(keyword()) :: :ok | {:error, {:invalid_category, term()}}
  def validate_watchlist_category(opts) do
    case Keyword.get(opts, :category) do
      category when category in [nil, "US_STOCK"] -> :ok
      other -> {:error, {:invalid_category, other}}
    end
  end

  defp venue_watchlist_id(row) do
    case value(row, ["watchlist_id"]) do
      id when is_binary(id) -> {:ok, id}
      _absent -> {:error, {:missing_required_field, :id}}
    end
  end

  # Text, as `Core.Types.Watchlist.id` is and as the page types it: a number or an object in
  # that field was handed back as the new watchlist's id, and no later call could take it.
  defp created_watchlist_id(row), do: venue_watchlist_id(row)

  defp add_created_members(id, name, [], _credentials, _opts) do
    {:ok, %Watchlist{id: id, name: name, symbols: [], venue_time: nil, provider: :webull}}
  end

  defp add_created_members(id, name, symbols, credentials, opts) do
    case add_watchlist_instruments(id, symbols, credentials, opts) do
      {:ok, _result} ->
        {:ok,
         %Watchlist{id: id, name: name, symbols: symbols, venue_time: nil, provider: :webull}}

      # The add may have landed: the watchlist exists, its membership is UNKNOWN. Not
      # "without members", which would send the caller to add them a second time.
      {:error, {:write_unconfirmed, nil, reason}} ->
        {:error, {:watchlist_created_members_unconfirmed, id, reason}}

      {:error, reason} ->
        {:error, {:watchlist_created_without_members, id, reason}}

      {:refused, reason} ->
        {:error, {:watchlist_created_without_members, id, reason}}
    end
  end

  @doc """
  Renames a watchlist or changes its sort order — `POST /market-data/watchlists/update`.

  **This does not change membership.** The venue's update endpoint touches the watchlist's
  own properties and nothing else; `add_watchlist_instruments/4` and
  `remove_watchlist_instruments/4` are the membership writes. A contract caller reading
  "replaces a watchlist's name or membership" gets the first half here, and the second is
  refused rather than silently skipped — `opts[:symbols]` is
  `{:error, :membership_not_updatable_here}`.

  Only what is given is changed: the venue leaves unprovided fields alone.

  A write that may have reached the venue and is not proven is `{:error,
  {:write_unconfirmed, nil, reason}}`; failures decided before sending stay plain.
  """
  @spec update_watchlist(String.t(), map(), keyword()) ::
          {:ok, Watchlist.t()} | {:error, term()} | {:refused, term()}
  def update_watchlist(watchlist_id, _credentials, _opts)
      when not (is_binary(watchlist_id) and watchlist_id != ""),
      do: {:error, {:invalid_watchlist_id, watchlist_id}}

  def update_watchlist(watchlist_id, credentials, opts) do
    if Keyword.has_key?(opts, :symbols) do
      {:error, :membership_not_updatable_here}
    else
      body =
        %{"watchlist_id" => watchlist_id}
        |> put_present("name", Keyword.get(opts, :name))
        |> put_present("sort", Keyword.get(opts, :sort))

      with :ok <- validate_watchlist_sort(Keyword.get(opts, :sort)),
           {:ok, response} <-
             write_outcome(
               post_write("/market-data/watchlists/update", body, credentials, opts),
               send_once(opts)
             ),
           # `update-watchlist.md:168-186` documents the same `SuccessResponseVo`
           # `{"success": boolean}` shape every other watchlist write already guards with
           # `watchlist_success/1` (see its own comment: a `false` here is "a 200 that did
           # nothing"). This was the one watchlist write that discarded the response body
           # and reported `{:ok, watchlist}` for any 2xx, including a documented
           # `{"success": false}`.
           :ok <- write_outcome(watchlist_success(response)) do
        {:ok,
         %Watchlist{
           id: watchlist_id,
           name: Keyword.get(opts, :name),
           # Membership was not touched and was not read. `nil` says so.
           symbols: nil,
           venue_time: nil,
           provider: :webull
         }}
      end
    end
  end

  @doc """
  Deletes a watchlist and everything in it — `POST /market-data/watchlists/delete`.

  **Irreversible, in the venue's own words.** Returns `:ok` rather than the venue's
  `%{"success" => true}`, because the contract's `delete_watchlist/2` is documented as
  returning `:ok` — and a `false` in that field is an error here rather than a successful
  call that deleted nothing. A delete that may have reached the venue and is not proven is
  `{:error, {:write_unconfirmed, nil, reason}}` (re-listing shows whether it took); an unknown
  id is `{:refused, :not_found}`.
  """
  @spec delete_watchlist(String.t(), map(), keyword()) ::
          {:ok, :ok} | {:error, term()} | {:refused, term()}
  def delete_watchlist(watchlist_id, _credentials, _opts)
      when not (is_binary(watchlist_id) and watchlist_id != ""),
      do: {:error, {:invalid_watchlist_id, watchlist_id}}

  def delete_watchlist(watchlist_id, credentials, opts) do
    body = %{"watchlist_id" => watchlist_id}

    with {:ok, response} <-
           write_outcome(
             post_write("/market-data/watchlists/delete", body, credentials, opts),
             send_once(opts)
           ),
         :ok <- write_outcome(watchlist_success(response)) do
      {:ok, :ok}
    end
  end

  @doc """
  Re-tags the outcome of a watchlist write that may have reached the venue.

  An `{:error, reason}` that was NOT decided before sending (`unsent?/1`: missing credentials,
  our own limiter refusing) - a transport error or timeout, a 5xx, a 2xx whose body cannot be
  read or that lacks the id or `success` the write needs - does not say whether the write
  happened, so it is `{:error, {:write_unconfirmed, nil, reason}}` (`nil`: this venue takes no
  idempotency key for a watchlist write; `reason` bounded). A caller that read a bare
  `{:error, _}` as "worth retrying" would repeat a create or a delete. Pre-send failures,
  `{:refused, _}` and `:ok`/`{:ok, _}` pass through unchanged. `opts` are the options the
  request was sent under (`unsent?/2`): a limiter refusal on a RETRY of a write that was
  already sent is not proof that nothing was sent. For `DpExchange.Webull.Fake`.
  """
  @spec write_outcome(term(), keyword()) :: term()
  def write_outcome(result, opts \\ [])

  def write_outcome({:error, reason} = error, opts) do
    if unsent?(reason, opts),
      do: error,
      else: {:error, {:write_unconfirmed, nil, bound_write_reason(reason)}}
  end

  def write_outcome(other, _opts), do: other

  defp bound_write_reason(reason) when is_atom(reason), do: reason

  defp bound_write_reason({tag, detail}) when is_atom(tag) and is_atom(detail),
    do: {tag, detail}

  defp bound_write_reason({tag, detail}) when is_atom(tag) and is_binary(detail),
    do: {tag, String.slice(detail, 0, 2_048)}

  defp bound_write_reason({:exchange_error, venue, message})
       when is_atom(venue) and is_binary(message),
       do: {:exchange_error, venue, String.slice(message, 0, 2_048)}

  defp bound_write_reason(reason) when is_binary(reason), do: String.slice(reason, 0, 2_048)
  defp bound_write_reason(reason), do: inspect(reason, limit: 50, printable_limit: 2_048)

  @doc """
  Adds instruments to an existing watchlist — `POST /market-data/watchlists/instruments/add`.

  The venue caps an account at **1000 instruments across all watchlists** and rejects event
  contracts, futures and options here.

  A write that may have reached the venue and is not proven is `{:error,
  {:write_unconfirmed, nil, reason}}` (`write_outcome/1`); read the watchlist before retrying.
  """
  @spec add_watchlist_instruments(String.t(), [String.t()], map(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def add_watchlist_instruments(watchlist_id, symbols, credentials, opts),
    do: watchlist_membership("add", watchlist_id, symbols, credentials, opts)

  @doc """
  Removes instruments from a watchlist —
  `POST /market-data/watchlists/instruments/remove`.

  Removal is by symbol and category, not by the instrument id the listing returns — the
  venue's own asymmetry. An unproven write is `{:error, {:write_unconfirmed, nil, reason}}`,
  as for `add_watchlist_instruments/4`.
  """
  @spec remove_watchlist_instruments(String.t(), [String.t()], map(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def remove_watchlist_instruments(watchlist_id, symbols, credentials, opts),
    do: watchlist_membership("remove", watchlist_id, symbols, credentials, opts)

  @doc """
  Reorders instruments within a watchlist —
  `POST /market-data/watchlists/instruments/update`.

  **`opts[:sorts]` is required and is a map of symbol to position.** The endpoint updates
  sort order and nothing else, and a call without positions would send the venue a list of
  symbols with no change in it.
  """
  @spec sort_watchlist_instruments(String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def sort_watchlist_instruments(watchlist_id, credentials, opts) do
    with {:ok, sorts} <- validate_watchlist_sorts(opts),
         :ok <- validate_watchlist_category(opts) do
      instruments =
        Enum.map(sorts, fn {symbol, position} ->
          %{
            "symbol" => symbol,
            "category" => fundamental_category(opts),
            "sort" => position
          }
        end)

      watchlist_write("update", watchlist_id, instruments, credentials, opts)
    end
  end

  @doc """
  The `opts[:sorts]` check `sort_watchlist_instruments/3` makes first: a non-empty map of
  symbol (non-empty text) to position (a whole number). Missing or empty is
  `{:error, :sorts_required}`; anything else wrong is `{:error, {:invalid_sorts, sorts}}`.
  For `DpExchange.Webull.Fake`.
  """
  @spec validate_watchlist_sorts(keyword()) :: {:ok, map()} | {:error, term()}
  def validate_watchlist_sorts(opts) do
    case Keyword.get(opts, :sorts) do
      %{} = sorts when map_size(sorts) > 0 ->
        # A symbol is text and a position is a whole number (`update-watchlist-instruments.md`
        # types `sort` as an integer): anything else was sent as it stood.
        if Enum.all?(sorts, fn {symbol, position} ->
             is_binary(symbol) and symbol != "" and is_integer(position)
           end),
           do: {:ok, sorts},
           else: {:error, {:invalid_sorts, sorts}}

      _missing ->
        {:error, :sorts_required}
    end
  end

  defp watchlist_membership(action, watchlist_id, symbols, credentials, opts) do
    with {:ok, members} <- validate_watchlist_membership(symbols),
         :ok <- validate_watchlist_category(opts) do
      instruments =
        Enum.map(members, &%{"symbol" => &1, "category" => fundamental_category(opts)})

      watchlist_write(action, watchlist_id, instruments, credentials, opts)
    end
  end

  @doc """
  The symbols check `add_watchlist_instruments/4` and `remove_watchlist_instruments/4` make
  first: `validate_watchlist_symbols/1`, and then at least one symbol
  (`{:error, :symbols_required}`). For `DpExchange.Webull.Fake`.
  """
  @spec validate_watchlist_membership(term()) :: {:ok, [String.t()]} | {:error, term()}
  def validate_watchlist_membership(symbols) do
    case validate_watchlist_symbols(symbols) do
      {:ok, []} -> {:error, :symbols_required}
      other -> other
    end
  end

  defp watchlist_write(action, watchlist_id, instruments, credentials, opts) do
    body = %{"watchlist_id" => watchlist_id, "instruments" => instruments}
    path = "/market-data/watchlists/instruments/#{action}"

    with :ok <- validate_watchlist_target(:id, watchlist_id),
         {:ok, response} <-
           write_outcome(post_write(path, body, credentials, opts), send_once(opts)),
         :ok <- write_outcome(watchlist_success(response)) do
      {:ok, %{"success" => true}}
    end
  end

  # `{"success": false}` is a 200 that did nothing. Reporting it as `{:ok, _}` is the
  # failure this venue's watchlist endpoints invite: every one of them answers with a
  # boolean rather than an error status.
  defp watchlist_success(response) do
    case rows(response) do
      {:ok, success_rows} ->
        case List.first(success_rows) do
          %{"success" => true} -> :ok
          %{"success" => false} -> {:refused, :watchlist_write_rejected}
          nil -> {:error, :unexpected_response_shape}
          # A row that names no `success` is not a success. Every watchlist endpoint answers
          # with that boolean; a reply without it did not say the write happened, and
          # reporting `:ok` for it asserted one this package cannot know about.
          _no_verdict -> {:error, :unexpected_response_shape}
        end

      {:error, _reason} = error ->
        error
    end
  end

  # A row that cannot supply its own identity is never published under an empty one (`nil`
  # here; `list_watchlists/2` refuses the whole listing for it, see `collect_watchlists/1`).
  # `Core.Types.Watchlist`, `NewsItem` and `ScreenerResult` each enforce their
  # identifying field, and `new/1` refuses a `nil` there — but these build the struct
  # literally, as everywhere in this family, so `|| ""` satisfied the requirement while
  # saying nothing.
  #
  # An empty string is worse than the `nil` it replaced. A `nil` is detectable; `""` is a
  # value, so a consumer keying coverage by symbol gets a live entry named "" and a
  # consumer deduplicating by id collapses every unidentified row into one.
  #
  # `dp_exchange_robinhood` states the rule this follows, for the same reason:
  # "a row missing `symbol` entirely is dropped rather than published under a fabricated
  # one ... a nil key there is worse than one fewer row this cycle".
  defp to_watchlist(row, symbols) do
    case value(row, ["watchlist_id"]) do
      id when is_binary(id) -> build_watchlist(id, row, symbols)
      _no_text_id -> nil
    end
  end

  defp build_watchlist(id, row, symbols) do
    %Watchlist{
      id: id,
      name: text_or_nil(value(row, ["name"])),
      # `nil`, not `[]`: this endpoint does not list membership, and an empty list would say
      # the watchlist is empty.
      symbols: symbols,
      venue_time: nil,
      provider: :webull
    }
  end

  # --- fundamentals, screeners and news -----------------------------------

  # Every fundamentals endpoint takes `symbol` and `category` and differs only in what it
  # adds. The table is the endpoint list; the extras each one accepts are named beside it,
  # so a parameter that belongs to one cannot leak into another.
  #
  # `US_STOCK` is the only category any of them documents. It is sent explicitly rather than
  # omitted: a required parameter left out is a refusal the caller cannot read.
  @fundamentals %{
    analyst_ratings: {"/market-data/fundamentals/analysis/ratings/get", []},
    analyst_target_prices: {"/market-data/fundamentals/analysis/target-prices/get", []},
    balance_sheet: {"/market-data/fundamentals/balance-sheets/get", [:type, :count]},
    capital_flows: {"/market-data/fundamentals/capital-flows/get", [:count]},
    cash_flow: {"/market-data/fundamentals/cash-flows/get", [:type, :count]},
    company_profile: {"/market-data/fundamentals/company-profiles/get", []},
    dividend_calendar: {"/market-data/fundamentals/dividend-calendars/list", []},
    earnings_calendar: {"/market-data/fundamentals/earnings-calendars/list", []},
    filings: {"/market-data/fundamentals/filings/list", []},
    financial_alerts: {"/market-data/fundamentals/financial-alerts/get", []},
    forecast_eps: {"/market-data/fundamentals/forecast-eps/get", []},
    fund_allocations: {"/market-data/fundamentals/fund-allocations/get", []},
    fund_brief: {"/market-data/fundamentals/fund-brief/get", []},
    # `fund-dividends.md:36-73` documents `symbol`, `category` and `pagination_key` —
    # no `count` — and this is the one fundamentals endpoint (besides `filings`, which has
    # its own envelope handling) that paginates; `get_fundamental/4` follows `pagination_key`
    # bounded, internally, so it is not in the caller-suppliable list below.
    fund_dividends: {"/market-data/fundamentals/fund-dividends/get", []},
    # `fund-files.md`, `fund-holdings.md` and `fund-splits.md` each document only `symbol`
    # and `category` — no `count`, on any of the three, unlike `capital_flows` and the
    # statement endpoints above, which do define it.
    fund_files: {"/market-data/fundamentals/fund-files/get", []},
    fund_holdings: {"/market-data/fundamentals/fund-holdings/get", []},
    # `fund-net-value.md:58-66` also documents `last_date` ("Last Query Date") alongside
    # `count` — both optional, paging a fund's net-value history further back than the
    # default 5-row window. Omitted here, `last_date` was silently dropped rather than
    # forwarded.
    fund_net_values: {"/market-data/fundamentals/fund-net-values/get", [:count, :last_date]},
    fund_performances: {"/market-data/fundamentals/fund-performances/get", []},
    fund_ratings: {"/market-data/fundamentals/fund-ratings/get", []},
    fund_splits: {"/market-data/fundamentals/fund-splits/get", []},
    income_statement: {"/market-data/fundamentals/income-statements/get", [:type, :count]},
    indicators: {"/market-data/fundamentals/indicators/get", [:type, :count]},
    # `industry-comparison.md:58-67` documents an optional `sort_by` (default `EPS_TTM`) —
    # omitted here, a caller's `sort_by:` opt was silently dropped rather than forwarded.
    industry_comparisons: {"/market-data/fundamentals/industry-comparisons/get", [:sort_by]}
  }

  @doc """
  The fundamentals kinds this package reaches, as atoms. Not every fundamentals endpoint the
  venue publishes: as of 2026-10-18 its index also lists insider holdings and transactions,
  institutions and their 13F holdings and changes, and the economic calendar, none of which
  is reached here (`docs/reference/webull/endpoint-pages.txt`).

  Twenty-three endpoints under one shape. `get_fundamental/4` reaches any of them; the
  contract's own callbacks — `get_financials/3`, `get_corporate_events/1`, `get_filings/2` —
  reach the handful the contract has types for.
  """
  @spec fundamental_kinds() :: [atom()]
  def fundamental_kinds, do: @fundamentals |> Map.keys() |> Enum.sort()

  # Read through a function so code above `@fundamentals` (`validate_statement_count/2`) can
  # reach it.
  defp fundamental(kind), do: Map.fetch(@fundamentals, kind)

  @doc """
  One fundamentals endpoint, by kind — the venue's own rows, unnormalised.

  **A kind this venue does not publish is `{:error, {:unknown_fundamental, kind}}` before a
  request is made.** Guessing a path from an atom would produce a 404 that reads like a
  venue outage.

  `opts[:type]` (`ANNUAL` or `QUARTERLY`) and `opts[:count]` are accepted **only on the
  endpoints that document them**, and are dropped elsewhere rather than sent — a parameter
  an endpoint does not know is at best ignored and at worst a refusal, and neither tells the
  caller which happened. `fund_files`, `fund_holdings` and `fund_splits` are three such
  endpoints for `:count` specifically — none of their own pages define it.

  `:fund_dividends` is the one kind (besides `:filings`, which `get_filings/2` reaches
  through its own envelope) whose page documents `pagination_key`
  (`fund-dividends.md:60-73`), and this follows it bounded rather than returning one page.

  Rows come back as the venue sends them. A balance sheet has ninety-odd line items under
  the venue's own names, and a normalised schema would either drop most of them or invent a
  common shape three statement types do not share.
  """
  @spec get_fundamental(atom(), String.t(), map(), keyword()) ::
          {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def get_fundamental(kind, symbol, credentials, opts) do
    case Map.fetch(@fundamentals, kind) do
      {:ok, {path, allowed}} ->
        # The statement endpoints state "maximum value is 20" for `count`
        # (`financial-balancesheet.md` and kin, `fund-net-value.md`); `capital-flows` states
        # "range 1~5" (`capital-flow.md`).
        #
        # The options are checked BEFORE the query is built (`scalar_opts/2`): a map or a list
        # of maps for `:type` raised `Protocol.UndefinedError` out of `put_present/3`'s
        # `to_string/1`, in the caller's process.
        with :ok <- validate_fundamental_request(kind, symbol, opts) do
          base_params =
            %{"symbol" => symbol, "category" => fundamental_category(opts)}
            |> put_allowed(allowed, opts)

          fundamental_rows(kind, path, base_params, credentials, opts)
        end

      :error ->
        {:error, {:unknown_fundamental, kind}}
    end
  end

  @doc """
  The checks `get_fundamental/4` makes before it builds a request, in its order: the kind
  (`{:error, {:unknown_fundamental, kind}}`), the option types, the statement count, the
  symbol. For `DpExchange.Webull.Fake`, which refuses exactly what the real path refuses.
  """
  @spec validate_fundamental_request(term(), term(), keyword()) :: :ok | {:error, term()}
  def validate_fundamental_request(kind, symbol, opts) do
    case Map.fetch(@fundamentals, kind) do
      {:ok, {_path, allowed}} ->
        with :ok <- scalar_opts(opts, [:category | allowed]),
             :ok <- statement_count(kind, opts),
             do: validate_symbol(symbol)

      :error ->
        {:error, {:unknown_fundamental, kind}}
    end
  end

  @doc """
  The options a `get_fundamental/4` of `kind` reads: `:category`, and the query keys that
  kind's own page documents. An endpoint's page names no `count` or `type` unless it does, so
  those are not options of a kind that does not take them.

  A kind this venue does not publish is `{:error, {:unknown_fundamental, kind}}`, the same
  answer `get_fundamental/4` gives. For `DpExchange.Webull.Options`.
  """
  @spec fundamental_option_keys(term()) ::
          {:ok, [atom()]} | {:error, {:unknown_fundamental, term()}}
  def fundamental_option_keys(kind) do
    case Map.fetch(@fundamentals, kind) do
      {:ok, {_path, allowed}} -> {:ok, [:category | allowed]}
      :error -> {:error, {:unknown_fundamental, kind}}
    end
  end

  @counted_to_20 [:balance_sheet, :cash_flow, :income_statement, :indicators, :fund_net_values]

  defp statement_count(kind, opts) when kind in @counted_to_20,
    do: count_within_max(Keyword.get(opts, :count), 20)

  # `capital-flow.md`: "Number of records to return, range 1~5, default 5". This used to be
  # left to the venue on the strength of the page stating no maximum; it states one.
  defp statement_count(:capital_flows, opts), do: count_within_max(Keyword.get(opts, :count), 5)

  defp statement_count(_kind, _opts), do: :ok

  defp fundamental_rows(:fund_dividends, path, base_params, credentials, opts) do
    fetch_page = fn key ->
      params = put_present(base_params, "pagination_key", key)

      with {:ok, body} <- get_symbol(path, params, credentials, opts),
           {:ok, page_rows} <- rows(body),
           {:ok, objects} <- object_rows(page_rows) do
        {:ok, {objects, next_pagination_key(body)}}
      end
    end

    paginate(fetch_page)
  end

  # `[map()]`, as `get_fundamental/4` promises: a row that is not an object is refused rather
  # than handed back as one.
  defp fundamental_rows(_kind, path, params, credentials, opts) do
    with {:ok, body} <- get_symbol(path, params, credentials, opts),
         {:ok, listed} <- rows(body) do
      object_rows(listed)
    end
  end

  defp fundamental_category(opts), do: Config.opt(opts, :category, "US_STOCK")

  # **An option that goes into a query string must be something a query string can hold**:
  # text, a number, an atom, a `Decimal` or a `Date` (`scalar_opts/2`), or for the options that
  # name several things (`list_opts/2`) also a list of text, which is comma-joined. Anything
  # else - a map, a tuple, a list with a non-text member - reached `put_present/3`'s
  # `to_string/1` and raised `Protocol.UndefinedError` out of the facade call, in the caller's
  # process, after the rate limiter had been asked; and a list given where ONE value belongs
  # (`type: ["ANNUAL", "QUARTERLY"]`) was written to the wire as the concatenation
  # `"ANNUALQUARTERLY"`. Refused `{:invalid_option, key, value}` before anything is built.
  # `nil` is absent. Shared with `DpExchange.Webull.Fake` through the `validate_*` functions
  # that call it, so both answer alike.
  defp scalar_opts(opts, keys), do: checked_opts(opts, keys, &scalar_value?/1)
  defp list_opts(opts, keys), do: checked_opts(opts, keys, &list_value?/1)

  # **`:sessions` names sessions the venue's enum lists, or the read is refused.** The tape
  # and stock-bar pages give `trading_sessions` the enum `PRE`, `RTH`, `ATH`, `OVN`
  # (comma-separated for several). It was only type-checked, so `"rth"`, `"ALL"`, `[]` (sent
  # as an empty string) or a list repeating a session went to the venue as typed, while the
  # footprint read (`footprint_session/1`) has always refused an unlisted one. Absent stays
  # absent. `{:error, {:invalid_option, :sessions, value}}`.
  @session_names ["PRE", "RTH", "ATH", "OVN"]

  defp validate_sessions(opts) do
    with :ok <- list_opts(opts, [:sessions]) do
      case Keyword.get(opts, :sessions) do
        nil -> :ok
        value -> if sessions_named?(value), do: :ok, else: invalid_sessions(value)
      end
    end
  end

  defp invalid_sessions(value), do: {:error, {:invalid_option, :sessions, value}}

  defp sessions_named?([_first | _rest] = sessions),
    do: Enum.all?(sessions, &(&1 in @session_names)) and sessions == Enum.uniq(sessions)

  defp sessions_named?([]), do: false
  defp sessions_named?(session) when is_binary(session), do: session in @session_names
  defp sessions_named?(session) when is_atom(session), do: to_string(session) in @session_names
  defp sessions_named?(_other), do: false

  defp checked_opts(opts, keys, valid?) do
    Enum.find_value(keys, :ok, fn key ->
      value = Keyword.get(opts, key)
      if valid?.(value), do: nil, else: {:error, {:invalid_option, key, value}}
    end)
  end

  defp scalar_value?(value)
       when is_nil(value) or is_binary(value) or is_number(value) or is_atom(value),
       do: true

  defp scalar_value?(%Date{}), do: true
  defp scalar_value?(%Decimal{}), do: true
  defp scalar_value?(_other), do: false

  defp list_value?(list) when is_list(list), do: text_list?(list)
  defp list_value?(value), do: scalar_value?(value)

  # By hand: an improper list is refused rather than raised on by `Enum.all?/2`.
  defp text_list?([text | rest]), do: is_binary(text) and text_list?(rest)
  defp text_list?([]), do: true
  defp text_list?(_improper), do: false

  defp put_allowed(params, allowed, opts) do
    Enum.reduce(allowed, params, fn key, acc ->
      put_present(acc, to_string(key), Keyword.get(opts, key))
    end)
  end

  @statement_kinds [:balance_sheet, :income, :cash_flow, :indicators]

  @doc """
  Whether `kind` is a statement kind `get_financials/4` serves. The check it makes before a
  request is built, for `DpExchange.Webull.Fake` to refuse a `kind` (`:company_profile`, a
  typo) exactly as the real path does rather than answer with a statement of it.
  """
  @spec validate_statement_kind(term()) :: :ok | {:error, term()}
  def validate_statement_kind(kind) when kind in @statement_kinds, do: :ok
  def validate_statement_kind(kind), do: {:error, {:unsupported_statement_kind, kind}}

  @doc """
  Financial statements for an issuer — `Types.FinancialStatement`.

  `kind` is the contract's own vocabulary: `:balance_sheet`, `:income`, `:cash_flow` or
  `:indicators`. **Anything else is refused**, including a fundamentals kind this venue
  publishes that is not a statement: `:company_profile` is real and is not a financial
  statement, and answering with it would put a profile in a statement's shape.

  Line items are the venue's own names, unchanged — see `Core.Types.FinancialStatement`.

  **`:indicators` answers one statement per fiscal period, not one per call.** The venue
  returns a single object whose metrics each list their own `{fiscal_year, fiscal_period,
  value}` readings; those are regrouped by period, oldest first, with `line_items` holding
  that period's metrics beside `fiscal_year`, the raw `fiscal_period` code and `currency`.
  `period_end` is `nil` for them (the page publishes no end date). A response not in that
  shape is `{:error, :unexpected_response_shape}`.

  **`fiscal_period` is the venue's integer code translated through the venue's own legend**,
  which its page states as `0=FY, 1=Q1, 2=Q2, 3=Q3, 4=Q4`. The contract wants a label and
  the venue publishes a code, so the code is mapped with the venue's own key and the raw
  integer stays in `line_items` — a code this legend does not cover leaves the label `nil`
  rather than inventing one, and the integer is still there to read.
  """
  @spec get_financials(String.t(), atom(), map(), keyword()) ::
          {:ok, [FinancialStatement.t()]} | {:error, term()} | {:refused, term()}
  def get_financials(symbol, kind, credentials, opts)
      when kind in @statement_kinds do
    with {:ok, rows} <- get_fundamental(statement_endpoint(kind), symbol, credentials, opts),
         {:ok, rows} <- object_rows(rows) do
      to_statements(rows, symbol, kind)
    end
  end

  def get_financials(_symbol, kind, _credentials, _opts),
    do: {:error, {:unsupported_statement_kind, kind}}

  # A row that is not an object (a string or a number in the list) is not a statement, a
  # calendar entry or a filing. It used to become one with every field `nil` and the stray
  # value as its `line_items` or `details`; the whole read is refused instead.
  defp object_rows(rows) do
    if Enum.all?(rows, &is_map/1), do: {:ok, rows}, else: {:error, :unexpected_response_shape}
  end

  defp statement_endpoint(:income), do: :income_statement
  defp statement_endpoint(kind), do: kind

  defp to_statements(rows, symbol, :indicators), do: indicator_statements(rows, symbol)

  defp to_statements(rows, symbol, kind),
    do: {:ok, Enum.map(rows, &to_statement(&1, symbol, kind))}

  # **`indicators` is not shaped like the other statements, and reading it as one lost every
  # period.** `financial-indicators.md:186-228` documents ONE object per call,
  # `{currency, values: {<metric>: [{fiscal_year, fiscal_period, value}, ...]}}` - the periods
  # sit INSIDE each metric's list, so there is no top-level `end_date` or `fiscal_period` for
  # `to_statement/3` to read. It returned one statement whose `period_end` and
  # `fiscal_period` were both `nil` and whose period-by-period values were buried in
  # `line_items`, and a caller could not tell which year a ratio belonged to.
  #
  # Regrouped here: one `FinancialStatement` per `{fiscal_year, fiscal_period}` the venue
  # listed, oldest first, `line_items` holding that period's metrics by the venue's own names
  # (values as the strings it sent) beside the `fiscal_year`, raw `fiscal_period` code and
  # `currency`. `period_end` is `nil`: the page publishes no end date for an indicator, and
  # none is derived from a fiscal year, which is not a calendar year. A row without a `values`
  # object, or a period entry that is not an object carrying an integer `fiscal_year`, is not
  # the documented shape and refuses the whole read.
  defp indicator_statements(rows, symbol) do
    rows
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
      case indicator_periods(row) do
        {:ok, periods} ->
          {:cont, {:ok, [indicator_statement_list(periods, row, symbol) | acc]}}

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, groups} -> {:ok, groups |> Enum.reverse() |> Enum.concat()}
      error -> error
    end
  end

  defp indicator_statement_list(periods, row, symbol) do
    currency = text_or_nil(value(row, ["currency"]))

    periods
    |> Enum.sort_by(fn {{year, period}, _metrics} -> {year, period} end)
    |> Enum.map(fn {{year, period}, metrics} ->
      %FinancialStatement{
        symbol: symbol,
        kind: :indicators,
        line_items:
          Map.merge(metrics, %{
            "fiscal_year" => year,
            "fiscal_period" => period,
            "currency" => currency
          }),
        period_end: nil,
        fiscal_period: fiscal_period_label(period),
        currency: currency,
        venue_time: nil,
        provider: :webull
      }
    end)
  end

  defp indicator_periods(%{"values" => %{} = values}) do
    Enum.reduce_while(values, {:ok, %{}}, fn {metric, entries}, {:ok, acc} ->
      case add_indicator_entries(acc, metric, entries) do
        {:ok, grouped} -> {:cont, {:ok, grouped}}
        error -> {:halt, error}
      end
    end)
  end

  defp indicator_periods(_not_the_documented_shape), do: {:error, :unexpected_response_shape}

  defp add_indicator_entries(acc, metric, entries) when is_list(entries) do
    Enum.reduce_while(entries, {:ok, acc}, fn entry, {:ok, grouped} ->
      case indicator_entry(entry) do
        {:ok, key, reading} ->
          {:cont, {:ok, put_reading(grouped, key, metric, reading)}}

        :error ->
          {:halt, {:error, :unexpected_response_shape}}
      end
    end)
  end

  defp add_indicator_entries(_acc, _metric, _entries), do: {:error, :unexpected_response_shape}

  defp put_reading(grouped, key, metric, reading),
    do: Map.update(grouped, key, %{metric => reading}, &Map.put(&1, metric, reading))

  defp indicator_entry(%{"fiscal_year" => year, "fiscal_period" => period} = entry)
       when is_integer(year),
       do: {:ok, {year, period}, Map.get(entry, "value")}

  defp indicator_entry(_other), do: :error

  defp to_statement(row, symbol, kind) do
    %FinancialStatement{
      symbol: symbol,
      kind: kind,
      # The whole row, the venue's names intact. The identifying fields are copied out
      # rather than removed: a line item map that lost its own period would be unreadable
      # beside a second one.
      line_items: row,
      period_end: statement_date(value(row, ["end_date"])),
      fiscal_period: fiscal_period_label(value(row, ["fiscal_period"])),
      currency: text_or_nil(value(row, ["currency"])),
      venue_time: nil,
      provider: :webull
    }
  end

  # The venue's own legend, from its page: `0=FY, 1=Q1, 2=Q2, 3=Q3, 4=Q4`. A code outside it
  # is `nil` — the raw integer is still in `line_items`, and a label this package invented
  # would be indistinguishable from one the venue published.
  defp fiscal_period_label(0), do: "FY"
  defp fiscal_period_label(period) when period in 1..4, do: "Q#{period}"
  # A venue that has already worded the period ("FY2026") sent a label, and a label is what
  # this field wants. A numeric string is the legend's code in another type and goes through
  # the legend: passed on as it was, "0" would have been published as a period label.
  defp fiscal_period_label(period) when is_binary(period) do
    case Integer.parse(period) do
      {code, ""} -> fiscal_period_label(code)
      _worded -> period
    end
  end

  defp fiscal_period_label(_other), do: nil

  defp statement_date(nil), do: nil

  defp statement_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      {:error, _reason} -> nil
    end
  end

  defp statement_date(_other), do: nil

  @doc """
  Dividends and earnings dates — `Types.CorporateEvent`.

  **Two endpoints, and `opts[:kind]` chooses.** `:dividend` reads the dividend calendar and
  `:earnings` the earnings one; without it both are read and the results concatenated, which
  is two requests and is stated here so a caller counting requests is not surprised.

  `opts[:symbol]` is **required**: this venue's calendars are per issuer, not market-wide.
  A market-wide calendar and one issuer's are different questions, and this endpoint answers
  only the second.

  **Splits are not here.** Webull publishes `fund-splits` for funds and nothing for equities,
  so a `:split` kind would be answerable for some symbols and silently empty for the rest.
  `get_fundamental(:fund_splits, …)` reaches the one that exists.

  **A dividend's `amount` is set only for a `CASH_DIVIDEND`** (or a row that names no
  `div_type`). The venue's other types - stock, scrip, return of capital, and so on - leave it
  `nil`, because a cash amount in `currency` is a claim the page does not make for them; the
  venue's whole row, `div_type` included, is in `details`.
  """
  @spec get_corporate_events(map(), keyword()) ::
          {:ok, [CorporateEvent.t()]} | {:error, term()} | {:refused, term()}
  def get_corporate_events(credentials, opts) do
    with {:ok, symbol} <- required_symbol(opts),
         {:ok, kinds} <- corporate_event_kinds(Keyword.get(opts, :kind)) do
      Enum.reduce_while(kinds, {:ok, []}, fn kind, {:ok, acc} ->
        with {:ok, rows} <- get_fundamental(calendar_endpoint(kind), symbol, credentials, opts),
             {:ok, rows} <- object_rows(rows) do
          {:cont, {:ok, acc ++ Enum.map(rows, &to_corporate_event(&1, symbol, kind))}}
        else
          error -> {:halt, error}
        end
      end)
    end
  end

  @doc """
  The calendars `get_corporate_events/2` reads for `opts[:kind]`: both when it is absent,
  one when it is `:dividend` or `:earnings`, and `{:error, {:unsupported_event_kind, kind}}`
  for anything else. For `DpExchange.Webull.Fake`, which answers one event per calendar read.
  """
  @spec corporate_event_kinds_for(term()) :: {:ok, [atom()]} | {:error, term()}
  def corporate_event_kinds_for(kind), do: corporate_event_kinds(kind)

  defp corporate_event_kinds(nil), do: {:ok, [:dividend, :earnings]}
  defp corporate_event_kinds(kind) when kind in [:dividend, :earnings], do: {:ok, [kind]}
  defp corporate_event_kinds(kind), do: {:error, {:unsupported_event_kind, kind}}

  defp calendar_endpoint(:dividend), do: :dividend_calendar
  defp calendar_endpoint(:earnings), do: :earnings_calendar

  # Dividend and earnings calendars name their dates differently, so this branches on
  # `kind` rather than trying one shared set of keys against both.
  #
  # **Dividend**: `ex_div_date` and `declare_date` (`dividend-calendar.md:202,207`), not
  # `ex_dividend_date`/`announce_date` — neither of those two is a field either page
  # defines, so `ex_date` and `announced_date` were `nil` on every dividend row before this.
  #
  # **Earnings**: `expected_publish_date` (`earnings-calendar.md:185`) is the one date this
  # calendar publishes, and it is carried under `:announced_date` — `Core.Types.CorporateEvent`
  # has no earnings-specific date field, `:ex_date`/`:record_date`/`:pay_date` are dividend
  # vocabulary an earnings row has no business populating, and the type's own moduledoc
  # discusses an earnings date's uncertainty in the same breath as introducing
  # `:announced_date`, right before `:confirmed`. Before this, an earnings row's only
  # chance at a date was `announce_date`/`announcement_date`, which this calendar does not
  # publish either, so every earnings event came back dateless.
  defp to_corporate_event(row, symbol, :dividend) do
    %CorporateEvent{
      symbol: symbol,
      kind: :dividend,
      ex_date: statement_date(value(row, ["ex_div_date"])),
      record_date: statement_date(value(row, ["record_date"])),
      pay_date: statement_date(value(row, ["pay_date"])),
      announced_date: statement_date(value(row, ["declare_date"])),
      amount: dividend_amount(row),
      currency: text_or_nil(value(row, ["currency"])),
      ratio: nil,
      # The venue publishes no confirmed/estimated flag on either calendar. `nil` says so;
      # `true` would claim a date is final when an earnings date routinely is not.
      confirmed: nil,
      details: row,
      provider: :webull
    }
  end

  defp to_corporate_event(row, symbol, :earnings) do
    %CorporateEvent{
      symbol: symbol,
      kind: :earnings,
      ex_date: nil,
      record_date: nil,
      pay_date: nil,
      announced_date: statement_date(value(row, ["expected_publish_date"])),
      amount: nil,
      currency: text_or_nil(value(row, ["currency"])),
      ratio: nil,
      confirmed: nil,
      details: row,
      provider: :webull
    }
  end

  # **`amount` is a cash amount only for a cash dividend.** `dividend-calendar.md` types each
  # row with a `div_type` - `CASH_DIVIDEND`, `STOCK_DIVIDEND`, `SCRIP_DIVIDEND`,
  # `RETURN_OF_CAPITAL`, `INTEREST_PRINCIPAL_PAYMENT`, `DIVIDEND_REINVESTMENT`,
  # `TRUST_INCOME_DISTRIBUTION` - and describes `amount` as "per share" without saying of what
  # for the others. A stock dividend's figure copied into `Core.Types.CorporateEvent.amount`
  # (a cash amount in `currency`) is a number that looks like money and is not. Any other
  # type leaves `amount` `nil`; `details` still holds the venue's row, `div_type` included. A
  # row naming no type is read as before.
  defp dividend_amount(row) do
    case value(row, ["div_type"]) do
      type when type in [nil, "CASH_DIVIDEND"] -> decimal(value(row, ["amount"]))
      _other_type -> nil
    end
  end

  @doc """
  Regulatory filings this venue indexes — `Types.Filing`.

  **This points at filings; it does not fetch them.** The `url` on each row is the venue's
  own link and nothing here follows it.

  ## The list is under `filings`, not `data`

  `filings.md:176` documents `GET /market-data/fundamentals/filings/list` as returning a
  single object — `{symbol, category, filings: [{title, url, publish_date}]}` — with the
  array under its own key, `filings`, not the `data` key `get_fundamental/4`'s generic
  `rows/1` unwraps. Before this, `rows/1` saw no `data` key and fell back to its
  bare-object clause, treating the WHOLE envelope as one row; every field this decoder
  reads off an individual filing (`title`, `url`, `publish_date`) is absent on that
  envelope, so `get_filings/2` returned a single all-`nil` filing rather than the venue's
  actual list. `filings_from_envelope/1` below reaches into the right key instead.
  """
  @spec get_filings(String.t(), map(), keyword()) ::
          {:ok, [Filing.t()]} | {:error, term()} | {:refused, term()}
  def get_filings(symbol, credentials, opts) do
    with {:ok, envelope_rows} <- get_fundamental(:filings, symbol, credentials, opts),
         {:ok, filing_rows} <- filings_from_envelope(envelope_rows),
         {:ok, filing_rows} <- object_rows(filing_rows) do
      {:ok, Enum.map(filing_rows, &to_filing(&1, symbol))}
    end
  end

  defp filings_from_envelope([envelope]) when is_map(envelope),
    do: list_value(envelope, ["filings"])

  defp filings_from_envelope([]), do: {:ok, []}
  defp filings_from_envelope(_other), do: {:error, :unexpected_response_shape}

  defp to_filing(row, symbol) do
    %Filing{
      symbol: symbol,
      # **A filing row carries `title`, `url` and `publish_date` and nothing else**
      # (`filings.md:182-192`; the captured example, `fund_report_filings.json`, agrees). The
      # venue names no filing id, no form type and no period end, and the aliases that were
      # read here (`id`, `filing_id`, `form_type`, `type`, `name`, `link`, `period_end`,
      # `end_date`) appear in no page or capture: a different field of the same name would
      # have been filed as the filing's own. They are `nil`, "not published".
      id: nil,
      form_type: nil,
      title: text_or_nil(value(row, ["title"])),
      url: text_or_nil(value(row, ["url"])),
      filed_at: filing_time(row),
      period_end: nil,
      provider: :webull
    }
  end

  # `publish_date` is a bare `YYYY-MM-DD` (`filings.md:192`) with no time of day — the
  # venue never states one. `Core.Types.Filing.filed_at` is a `DateTime`, so midnight UTC
  # on the venue's own date is used to satisfy the type: the DATE is the venue's, the TIME
  # is not, and that split is recorded here rather than presented as a moment the venue
  # gave.
  defp filing_time(row) do
    case statement_date(value(row, ["publish_date"])) do
      nil -> nil
      date -> DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
    end
  end

  @news_path "/market-data/news/stock-news/list"
  @news_categories ["US_STOCK", "HK_STOCK"]
  @news_sentiments ["POSITIVE", "NEGATIVE", "NEUTRAL"]

  @doc """
  News about the symbols asked for — `GET /market-data/news/stock-news/list`, one request
  per symbol.

  **These are the venue's own news items, not a generated summary.** Until 2026-10-18 this
  read `POST /market-data/news/summaries/get`, whose vendor description is "Invokes LLM to
  generate news summaries": one Server-Sent-Events reply, a model's paraphrase with no
  headline, no link, no publisher and no time. The vendor's reference now publishes
  `list-stock-news` (`openapi/list-stock-news.md`), which returns itemised articles with
  `news_id`, `title`, `summary`, `source`, `url`, `publish_time`, `sentiment` and
  `related_symbols`, so the summaries endpoint is no longer called. The two are different
  products: a caller who relied on the old single paraphrase gets articles now.

  `opts[:symbols]` is required, a list or one symbol as a string. `opts[:category]` is
  `US_STOCK` (the default) or `HK_STOCK`, the page's enum; `opts[:sentiment]` is
  `POSITIVE`, `NEGATIVE` or `NEUTRAL` and filters on the venue's classification. A value
  outside those is `{:error, {:invalid_option, key, value}}` before anything is sent.
  `sentiment` is a filter only: `Core.Types.NewsItem` has no field for the venue's label.

  **The cursor is followed, never dropped.** `Core.Venue.get_news/1` names no count or
  window, and the page documents a `pagination_key` and no page size. `opts[:limit]` (a
  positive integer, this package's option) is how many items **per symbol** the caller
  wants: pages are read until that many have arrived and the list is cut to exactly that
  number. Without `:limit` the feed is read to its end (an absent or empty cursor). A cursor
  that repeats the one just sent is `{:error, :pagination_key_did_not_advance}`, one that is
  not text is `{:error, :unexpected_pagination_key}`, and `@max_pages` pages without either
  the limit or the end is `{:error, :history_truncated}` (family convention) rather than the
  items so far, so a busy symbol read without `:limit` may be refused: pass one. An item the
  venue returned for two of the symbols appears once, with both symbols in `:symbols`.

  `:symbols` is the symbol the item was returned for plus the venue's own
  `related_symbols`: the venue's tagging, not a judgement made here. `:published_at` is the
  venue's `publish_time`, converted to UTC. An item with no `news_id`, an unreadable
  `publish_time` or an unreadable `related_symbols` refuses the whole read, as every
  unreadable row in this package does, rather than being dropped from the list.

  The page states no rate limit of its own; the per-endpoint and global buckets that govern
  every market-data read apply.
  """
  @spec get_news(map(), keyword()) ::
          {:ok, [NewsItem.t()]} | {:error, term()} | {:refused, term()}
  def get_news(credentials, opts) do
    with {:ok, symbols} <- required_symbols(opts),
         {:ok, {filters, limit}} <- news_filters(opts) do
      news_for_symbols(Enum.uniq(symbols), filters, limit, credentials, opts)
    end
  end

  @doc """
  What `get_news/2` asks for beside `symbol`: `{filters, limit}`. `filters` is the query
  `category` (default `US_STOCK`) and `sentiment` when given, each checked against the
  page's enum; `limit` is `opts[:limit]`, a positive integer, or `nil`. The second check
  `get_news/2` makes, after the symbols, for `DpExchange.Webull.Fake` to refuse exactly what
  the real path refuses.
  """
  @spec news_filters(keyword()) ::
          {:ok, {%{String.t() => String.t()}, pos_integer() | nil}} | {:error, term()}
  def news_filters(opts) do
    with {:ok, category} <- news_enum(opts, :category, @news_categories, "US_STOCK"),
         {:ok, sentiment} <- news_enum(opts, :sentiment, @news_sentiments, nil),
         {:ok, limit} <- news_limit(Keyword.get(opts, :limit)) do
      {:ok, {put_present(%{"category" => category}, "sentiment", sentiment), limit}}
    end
  end

  defp news_limit(nil), do: {:ok, nil}
  defp news_limit(limit) when is_integer(limit) and limit >= 1, do: {:ok, limit}
  defp news_limit(other), do: {:error, {:invalid_option, :limit, other}}

  defp news_enum(opts, key, allowed, default) do
    case Keyword.get(opts, key) do
      nil -> {:ok, default}
      value when is_binary(value) or is_atom(value) -> news_enum_value(key, value, allowed)
      value -> {:error, {:invalid_option, key, value}}
    end
  end

  defp news_enum_value(key, value, allowed) do
    if to_string(value) in allowed,
      do: {:ok, to_string(value)},
      else: {:error, {:invalid_option, key, value}}
  end

  defp news_for_symbols(symbols, filters, limit, credentials, opts) do
    symbols
    |> Enum.reduce_while({:ok, []}, fn symbol, {:ok, acc} ->
      fetch_page = fn key -> news_page(symbol, filters, key, credentials, opts) end

      case news_walk(fetch_page, limit, nil, [], 0, 0) do
        {:ok, items} -> {:cont, {:ok, [items | acc]}}
        failure -> {:halt, failure}
      end
    end)
    |> case do
      {:ok, pages} -> {:ok, pages |> Enum.reverse() |> Enum.concat() |> merge_news()}
      failure -> failure
    end
  end

  # Reads pages until `limit` items have arrived (cut to exactly `limit`) or the venue sends
  # no cursor. See `get_news/2` for the refusals; `paginate/4` is the same walk without a
  # count.
  #
  # Pages are collected AS PAGES with a running count and flattened once: `acc ++ items` per
  # page copied the whole accumulator each time, and `length/1` of it walked it again.
  defp news_walk(_fetch_page, _limit, _key, _pages, _count, page) when page >= @max_pages,
    do: {:error, :history_truncated}

  defp news_walk(fetch_page, limit, key, pages, count, page) do
    with {:ok, {items, next_key}} <- fetch_page.(key) do
      collected = [items | pages]
      total = count + length(items)

      cond do
        limit != nil and total >= limit ->
          {:ok, collected |> flatten_pages() |> Enum.take(limit)}

        next_key == nil ->
          {:ok, flatten_pages(collected)}

        match?({:invalid_key, _other}, next_key) ->
          {:error, :unexpected_pagination_key}

        next_key == key ->
          {:error, :pagination_key_did_not_advance}

        true ->
          news_walk(fetch_page, limit, next_key, collected, total, page + 1)
      end
    end
  end

  defp flatten_pages(pages), do: pages |> Enum.reverse() |> Enum.concat()

  defp news_page(symbol, filters, key, credentials, opts) do
    params =
      filters
      |> Map.put("symbol", symbol)
      |> put_present("pagination_key", key)

    with {:ok, body} <- get_symbol(@news_path, params, credentials, opts),
         {:ok, rows} <- news_rows(body),
         {:ok, items} <- news_items(rows, symbol) do
      {:ok, {items, next_pagination_key(body)}}
    end
  end

  # `data` is the page's required array (`StockNewsResultVo`); a body without it is not a
  # news page, and `rows/1`'s fall-back of treating a bare object as one row would read the
  # envelope as an article.
  defp news_rows(%{"data" => rows}) when is_list(rows), do: object_rows(rows)
  defp news_rows(_other), do: {:error, :unexpected_response_shape}

  defp news_items(rows, symbol) do
    rows
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
      case to_news_item(row, symbol) do
        {:ok, item} -> {:cont, {:ok, [item | acc]}}
        failure -> {:halt, failure}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      failure -> failure
    end
  end

  defp to_news_item(row, symbol) do
    with {:ok, id} <- news_id(value(row, ["news_id"])),
         {:ok, published_at} <- news_time(value(row, ["publish_time"])),
         {:ok, related} <- news_related(value(row, ["related_symbols"])) do
      {:ok,
       %NewsItem{
         id: id,
         headline: text_or_nil(value(row, ["title"])),
         summary: text_or_nil(value(row, ["summary"])),
         url: text_or_nil(value(row, ["url"])),
         source: text_or_nil(value(row, ["source"])),
         symbols: Enum.uniq([symbol | related]),
         published_at: published_at,
         provider: :webull
       }}
    end
  end

  defp news_id(id) when is_binary(id), do: {:ok, id}
  defp news_id(_absent_or_unreadable), do: {:error, {:missing_required_field, :id}}

  # `publish_time` is ISO 8601 with an offset (`2026-10-08T09:30:00.000-04:00`); absent is
  # `nil`, not this package's clock.
  defp news_time(nil), do: {:ok, nil}

  defp news_time(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, _reason} -> {:error, {:unparseable_venue_timestamp, text}}
    end
  end

  defp news_time(other), do: {:error, {:unparseable_venue_timestamp, other}}

  # The page's own example for an item is a JSON-encoded array in a string (`"[\"NVDA\"]"`),
  # which is not a symbol; anything that is not ticker-shaped text refuses the read.
  defp news_related(nil), do: {:ok, []}

  defp news_related(list) when is_list(list) do
    if Enum.all?(list, &ticker_text?/1),
      do: {:ok, list},
      else: {:error, :unexpected_response_shape}
  end

  defp news_related(_not_a_list), do: {:error, :unexpected_response_shape}

  defp ticker_text?(text), do: is_binary(text) and text =~ ~r/\A[A-Za-z0-9._\/-]+\z/

  # An article returned for two of the symbols asked about is one article.
  defp merge_news(items) do
    groups = Enum.group_by(items, & &1.id)

    items
    |> Enum.map(& &1.id)
    |> Enum.uniq()
    |> Enum.map(fn id ->
      [first | rest] = Map.fetch!(groups, id)
      %{first | symbols: Enum.uniq(first.symbols ++ Enum.flat_map(rest, & &1.symbols))}
    end)
  end

  @doc """
  The symbols `get_news/2` asks about: `opts[:symbols]` as a list, or one symbol as a
  string; `{:error, :symbols_required}` otherwise. The first check `get_news/2` makes, for
  `DpExchange.Webull.Fake` to accept and refuse exactly what the real path does.
  """
  @spec news_symbols(keyword()) :: {:ok, [String.t()]} | {:error, :symbols_required}
  def news_symbols(opts), do: required_symbols(opts)

  defp required_symbols(opts) do
    case Keyword.get(opts, :symbols) do
      [_first | _rest] = symbols -> all_symbols(symbols)
      symbol when is_binary(symbol) and symbol != "" -> {:ok, [symbol]}
      _missing -> {:error, :symbols_required}
    end
  end

  # Every entry is text. A tuple, a map or a pid in the list reached `Jason.encode!/1` in
  # `post_sse/4` and raised in the caller's process; an empty string names nothing.
  defp all_symbols(symbols) do
    if Enum.all?(symbols, &(is_binary(&1) and &1 != "")),
      do: {:ok, symbols},
      else: {:error, :symbols_required}
  end

  defp required_symbol(opts) do
    case Keyword.get(opts, :symbol) do
      symbol when is_binary(symbol) -> {:ok, symbol}
      _missing -> {:error, :symbol_required}
    end
  end

  # The five screeners, each with its own required parameters. `gainers_losers` needs a
  # ranking window and a sort field; the sector ones need an aggregation and a period; the
  # rest need only the category. A shared parameter set would send every screener the union.
  # `market_sector` (singular, `/get`) takes `sort_by`, not `agg_type` —
  # `get-market-sectors-detail.md:73-90` documents `sort_by` (default `CHANGE_RATIO`) and
  # no `agg_type` at all on this endpoint; `agg_type` (default `MARKET_VALUE`) is
  # `market_sectors` (plural, `/list`)'s own parameter (`get-market-sectors.md:47-60`) and
  # was sent on the wrong one of the two before this. `pagination_key` is on neither list
  # any more: both endpoints document it (`get-market-sectors.md:96`,
  # `get-market-sectors-detail.md`) and `get_screener/3` now follows it bounded instead of
  # taking a caller-supplied cursor for a single page.
  @screeners %{
    "gainers_losers" =>
      {"/market-data/screeners/gainers-losers/list", [:rank_type, :sort_by, :direction]},
    # `get-high-dividend.md` documents `sort_by` (default `YIELD`) alongside `category` and
    # `direction` — omitted here, a caller's `sort_by:` opt was silently dropped.
    "high_dividend_ranks" =>
      {"/market-data/screeners/high-dividend-ranks/list", [:sort_by, :direction]},
    "market_sectors" =>
      {"/market-data/screeners/market-sectors/list", [:agg_type, :period, :direction]},
    "market_sector" =>
      {"/market-data/screeners/market-sectors/get", [:sector_id, :sort_by, :period, :direction]},
    # `get-top-active.md:66-89` documents `sort_by` (default `VOLUME`) as a fourth query
    # parameter alongside `rank_type`, `category` and `direction` — omitted here, a
    # caller's `sort_by:` opt was silently dropped.
    "top_actives" =>
      {"/market-data/screeners/top-actives/list", [:rank_type, :sort_by, :direction]},
    # `get-week-52-high-low.md:70-88` documents `sort_by` (default `CHANGE_RATIO_52W`)
    # alongside `rank_type`, `category` and `direction` — omitted here, a caller's
    # `sort_by:` opt was silently dropped.
    "week52_high_low" =>
      {"/market-data/screeners/week52-high-low/list", [:rank_type, :sort_by, :direction]},
    # `list-hot-tickers.md` (fetched 2026-10-12, when the vendor's sitemap first listed it):
    # stocks ranked by community activity, a bare array of `{rank, symbol, category}`. The
    # page documents NO query parameter at all, so nothing is sent — not even `category`.
    "hot_stocks" => {"/market-data/communities/stock-rankings/list", []}
  }

  @paginated_screeners ["market_sectors", "market_sector"]

  # Screeners whose page documents no `category` parameter.
  @uncategorised_screeners ["hot_stocks"]

  @doc """
  The screeners this package reaches, by the identifier `get_screener/3` takes. The venue
  also lists a fear-and-greed index and a per-stock unusual-activity feed, which are not
  rankings and are not reached here (`docs/reference/webull/endpoint-pages.txt`, 2026-10-18).
  """
  @spec screeners() :: [String.t()]
  def screeners, do: @screeners |> Map.keys() |> Enum.sort()

  @doc """
  The options a `get_screener/3` of `name` reads: the query keys that screener's own page
  documents, and `:category` unless the page documents none (`hot_stocks`).

  An identifier this venue does not publish is `{:error, {:unknown_screener, name}}`, the same
  answer `get_screener/3` gives. For `DpExchange.Webull.Options`.
  """
  @spec screener_option_keys(term()) :: {:ok, [atom()]} | {:error, {:unknown_screener, term()}}
  def screener_option_keys(name) do
    case Map.fetch(@screeners, name) do
      {:ok, {_path, allowed}} when name in @uncategorised_screeners -> {:ok, allowed}
      {:ok, {_path, allowed}} -> {:ok, [:category | allowed]}
      :error -> {:error, {:unknown_screener, name}}
    end
  end

  @doc """
  A venue screener, by the venue's own identifier for it — `Types.ScreenerResult`.

  **Two venues' "top movers" answer different questions**, and nothing here merges or
  re-ranks them: the rank is the position the venue returned the row in, and the metrics are
  its own fields under its own names.

  Each screener takes different parameters and this sends **only** the ones its own page
  documents. `gainers_losers` requires `rank_type` and `sort_by`; both default to the
  venue's own documented defaults rather than being omitted, because the venue marks them
  required and an omitted required parameter is a refusal a caller cannot read. `top_actives`
  defaults `rank_type` to the venue's own documented `VOLUME`
  (`get-top-active.md:51-57`). `week52_high_low`'s own page documents four `rank_type`
  values and no default (`get-week-52-high-low.md:44`) — `opts[:rank_type]` is **required**
  here for that reason, `{:error, :rank_type_required}` when it is missing, rather than a
  guess at one of the four.

  `market_sectors` and `market_sector` both document `pagination_key`
  (`get-market-sectors.md:96`) and this follows it to the end, bounded — see `paginate/1`.

  `hot_stocks` ranks stocks by **community activity**, not by price or volume
  (`list-hot-tickers.md`). Its page documents no query parameter, so none is sent; each row's
  `metrics` carries the venue's own `rank` and `category`.

  An identifier this venue does not publish is `{:error, {:unknown_screener, name}}`.
  """
  @spec get_screener(String.t(), map(), keyword()) ::
          {:ok, [ScreenerResult.t()]} | {:error, term()} | {:refused, term()}
  def get_screener(name, credentials, opts) do
    case Map.fetch(@screeners, name) do
      {:ok, {path, allowed}} ->
        with :ok <- require_rank_type(name, opts),
             :ok <- scalar_opts(opts, [:category | allowed]) do
          base_params =
            name
            |> screener_base_params(opts)
            |> put_allowed(allowed, opts)
            |> screener_defaults(name)

          with {:ok, screener_rows} <-
                 screener_rows(name, path, base_params, credentials, opts) do
            screener_results(screener_rows, name)
          end
        end

      :error ->
        {:error, {:unknown_screener, name}}
    end
  end

  # A row that names nothing refuses the read: dropping it published a ranking with a hole
  # in it (and, positions being the rank, the hole is a rank).
  defp screener_results(screener_rows, name) do
    results =
      screener_rows
      |> Enum.with_index(1)
      |> Enum.map(&to_screener_result(&1, name))

    if Enum.any?(results, &is_nil/1),
      do: {:error, :unexpected_response_shape},
      else: {:ok, results}
  end

  @doc """
  Whether `name` and `opts` are a screener request `get_screener/3` would send: a known
  identifier, and the `rank_type` `week52_high_low` requires. The checks it makes before
  anything is signed, for `DpExchange.Webull.Fake` to refuse exactly what the real path does.
  """
  @spec validate_screener(term(), keyword()) :: :ok | {:error, term()}
  def validate_screener(name, opts) do
    case Map.fetch(@screeners, name) do
      {:ok, {_path, allowed}} ->
        # A query option that is a map, tuple or list is `{:invalid_option, key, value}`: it
        # raised `Protocol.UndefinedError` in `put_present/3` once the request was built.
        with :ok <- require_rank_type(name, opts), do: scalar_opts(opts, [:category | allowed])

      :error ->
        {:error, {:unknown_screener, name}}
    end
  end

  defp require_rank_type("week52_high_low", opts) do
    case Keyword.get(opts, :rank_type) do
      nil -> {:error, :rank_type_required}
      _present -> :ok
    end
  end

  defp require_rank_type(_name, _opts), do: :ok

  defp screener_base_params(name, _opts) when name in @uncategorised_screeners, do: %{}
  defp screener_base_params(_name, opts), do: %{"category" => fundamental_category(opts)}

  defp screener_rows(name, path, base_params, credentials, opts)
       when name in @paginated_screeners do
    fetch_page = fn key ->
      params = put_present(base_params, "pagination_key", key)

      with {:ok, body} <- get(path, params, credentials, opts),
           {:ok, page_rows} <- rows(body) do
        {:ok, {page_rows, next_pagination_key(body)}}
      end
    end

    paginate(fetch_page)
  end

  defp screener_rows(_name, path, params, credentials, opts) do
    with {:ok, body} <- get(path, params, credentials, opts), do: rows(body)
  end

  # The venue's own documented defaults, sent explicitly. `gainers_losers` marks `rank_type`
  # and `sort_by` REQUIRED; `top_actives` names `VOLUME` as its own default
  # (`get-top-active.md:51-57`) — not `DAY_1`, which is `gainers_losers`'s ranking window
  # and was never a member of `top_actives`'s `rank_type` enum at all.
  # `week52_high_low` gets no clause here: `require_rank_type/2` above refuses it instead,
  # because its page names no default to fall back to.
  defp screener_defaults(params, "gainers_losers") do
    params
    |> Map.put_new("rank_type", "DAY_1")
    |> Map.put_new("sort_by", "CHANGE_RATIO")
  end

  defp screener_defaults(params, "top_actives"), do: Map.put_new(params, "rank_type", "VOLUME")

  defp screener_defaults(params, _name), do: params

  # `nil` for a row that names nothing, which the caller turns into a refusal of the read.
  defp to_screener_result({row, rank}, name) do
    # Only text names a row. `ScreenerResult.symbol` is `String.t()`, and a number or an object
    # under `symbol` was published as one; it is the same unnamed row as a missing key.
    #
    # A row is named by its `symbol` (`get-gainers-losers.md`, `get-top-active.md`,
    # `list-hot-tickers.md:151`, and the stocks under a sector, `get-market-sectors-detail.md`);
    # only the `market_sectors` listing names a row by its sector's `name`
    # (`get-market-sectors.md:224`). No page shows `sector_name`, and a stock row's `name` is
    # the company's, not its symbol.
    named =
      case value(row, [screener_name_key(name)]) do
        text when is_binary(text) -> text
        _unnamed -> nil
      end

    case named do
      symbol when is_binary(symbol) -> build_screener_result(symbol, row, rank, name)
      _unnamed -> nil
    end
  end

  defp screener_name_key("market_sectors"), do: "name"
  defp screener_name_key(_screener), do: "symbol"

  defp build_screener_result(symbol, row, rank, name) do
    %ScreenerResult{
      symbol: symbol,
      screener: name,
      # The venue's returned order. It publishes no rank field, and the position it chose to
      # return a row in is the ranking — inventing one from a metric would re-rank the list.
      rank: rank,
      metrics: row,
      venue_time: nil,
      provider: :webull
    }
  end

  # --- futures and event contracts ---------------------------------------

  @doc """
  Futures contracts by symbol or by product code —
  `GET /trading/instruments/futures/contracts/list`.

  **Either `opts[:symbols]` or `opts[:code]`, and the venue requires one of them.** Missing
  both is `{:error, :symbols_or_code_required}` before a request is made, because the venue
  answers a request with neither in a way a caller cannot tell from "no contracts listed".

  `opts[:status]` filters `OC` (tradable), `CO` (liquidate only) or `NT` (non-tradable). The
  venue's own default is `OC`, and this package does not send one — a filter this package
  chose would hide contracts the caller did not ask to hide.

  Rows come back as the venue sends them. **`instrument_id` on a continuous contract is the
  continuous contract's id**, and the venue states an order needs the actual month
  contract's; nothing here resolves one to the other.
  """
  @spec list_futures_contracts(map(), keyword()) ::
          {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def list_futures_contracts(credentials, opts) do
    with :ok <- validate_futures_contracts_request(opts) do
      params =
        %{"category" => "US_FUTURES"}
        |> put_present("symbols", symbols_param(Keyword.get(opts, :symbols)))
        |> put_present("code", symbols_param(Keyword.get(opts, :code)))
        |> put_present("status", Keyword.get(opts, :status))

      with {:ok, body} <-
             get("/trading/instruments/futures/contracts/list", params, credentials, opts),
           {:ok, contracts} <- rows(body) do
        object_rows(contracts)
      end
    end
  end

  @doc """
  The checks `list_futures_contracts/2` makes before it builds a request, in its order:
  the option types, then that `:symbols` or `:code` names something. For
  `DpExchange.Webull.Fake`, which refuses exactly what the real path refuses.
  """
  @spec validate_futures_contracts_request(keyword()) :: :ok | {:error, term()}
  def validate_futures_contracts_request(opts) do
    with :ok <- list_opts(opts, [:symbols, :code]),
         :ok <- scalar_opts(opts, [:status]),
         do: symbols_or_code(opts)
  end

  defp symbols_or_code(opts) do
    # `[]` and `""` name nothing: they used to count as given, and went out as an empty
    # `symbols=` the venue answers in a way a caller cannot tell from "no contracts listed".
    if Enum.any?([:symbols, :code], &(opts |> Keyword.get(&1) |> symbols_param() |> named?())) do
      :ok
    else
      {:error, :symbols_or_code_required}
    end
  end

  defp named?(param), do: is_binary(param) and String.trim(param) != ""

  defp symbols_param(nil), do: nil
  defp symbols_param(list) when is_list(list), do: Enum.join(list, ",")
  defp symbols_param(value), do: to_string(value)

  @doc """
  The futures product classification groups —
  `GET /trading/instruments/futures/product-classes/list`.

  Two fields, `product_class_id` and `product_class_name`, and the ids are what
  `list_futures_contracts/2` rows carry. Returned as the venue's own maps because there is
  nothing to normalise.
  """
  @spec list_futures_product_classes(map(), keyword()) ::
          {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def list_futures_product_classes(credentials, opts) do
    params = %{"category" => "US_FUTURES"}

    with {:ok, body} <-
           get("/trading/instruments/futures/product-classes/list", params, credentials, opts),
         {:ok, classes} <- rows(body) do
      object_rows(classes)
    end
  end

  @doc """
  Every event-contract category — `GET /trading/instruments/event-contracts/categories/list`.

  **Takes no parameters at all.** It is the root of this venue's event hierarchy:
  category → series → event → market, and each level's symbol addresses the next.
  """
  @spec list_event_categories(map(), keyword()) ::
          {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def list_event_categories(credentials, opts) do
    with {:ok, body} <-
           get("/trading/instruments/event-contracts/categories/list", %{}, credentials, opts),
         {:ok, categories} <- rows(body) do
      object_rows(categories)
    end
  end

  @doc """
  Event-contract series — `GET /trading/instruments/event-contracts/series/list`.

  A series is the venue's template for a recurring event ("Monthly Jobs Report"), not a
  tradable thing.

  **Paged, and the absence of a key is the end.** `opts[:pagination_key]` continues, and the
  page's own `pagination_key` is returned alongside the rows as
  `{:ok, %{rows: [...], pagination_key: key_or_nil}}` — `nil` means this was the last page.
  Returning a bare list would make the last page and a truncated one look identical.
  """
  @spec list_event_series(map(), keyword()) ::
          {:ok, %{rows: [map()], pagination_key: String.t() | nil}}
          | {:error, term()}
          | {:refused, term()}
  def list_event_series(credentials, opts) do
    with :ok <- validate_event_series_request(opts) do
      params =
        %{}
        |> put_present("category", Keyword.get(opts, :category))
        |> put_present("symbols", symbols_param(Keyword.get(opts, :symbols)))
        |> put_present("pagination_key", Keyword.get(opts, :pagination_key))

      path = "/trading/instruments/event-contracts/series/list"

      with {:ok, body} <- get(path, params, credentials, opts), do: paged(body)
    end
  end

  @doc """
  The events under one series — `GET /trading/instruments/event-contracts/events/list`.

  `opts[:series_symbol]` is **required** by the venue; missing it is
  `{:error, :series_symbol_required}` before a request is made.

  `opts[:status]` takes the venue's `ACTIVE` or `INACTIVE` and is not defaulted: an event
  that has settled is still a real event, and filtering it out for a caller who did not ask
  would hide history.
  """
  @spec list_event_events(map(), keyword()) ::
          {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def list_event_events(credentials, opts) do
    with :ok <- validate_event_events_request(opts),
         do: events_for(Keyword.fetch!(opts, :series_symbol), credentials, opts)
  end

  @doc """
  The checks `list_event_series/2` makes before it builds a request: the scalar options,
  then `:symbols`. For `DpExchange.Webull.Fake`.
  """
  @spec validate_event_series_request(keyword()) :: :ok | {:error, term()}
  def validate_event_series_request(opts) do
    with :ok <- scalar_opts(opts, [:category, :pagination_key]),
         do: list_opts(opts, [:symbols])
  end

  @doc """
  The checks `list_event_events/2` makes before it builds a request: `:series_symbol` is
  present (`{:error, :series_symbol_required}`), then the option types. For
  `DpExchange.Webull.Fake`.
  """
  @spec validate_event_events_request(keyword()) :: :ok | {:error, term()}
  def validate_event_events_request(opts) do
    case Keyword.get(opts, :series_symbol) do
      nil ->
        {:error, :series_symbol_required}

      _series ->
        with :ok <- scalar_opts(opts, [:series_symbol, :status]),
             do: list_opts(opts, [:symbols])
    end
  end

  @doc """
  The checks `list_event_markets/2` makes before it builds a request: the scalar options,
  then `:symbols`. For `DpExchange.Webull.Fake`.
  """
  @spec validate_event_markets_request(keyword()) :: :ok | {:error, term()}
  def validate_event_markets_request(opts) do
    scalars = [:series_symbol, :event_symbol, :expiring_after, :pagination_key]

    with :ok <- scalar_opts(opts, scalars), do: list_opts(opts, [:symbols])
  end

  @doc """
  The checks `get_event_trades/3` makes before it builds a request: the `:limit` (at most
  1200), then the symbol. For `DpExchange.Webull.Fake`.
  """
  @spec validate_event_trades_request(term(), keyword()) :: :ok | {:error, term()}
  def validate_event_trades_request(symbol, opts) do
    with :ok <- limit_within_max(Keyword.get(opts, :limit), 1_200),
         do: validate_symbol(symbol)
  end

  @doc """
  The checks `get_event_order_book/3` makes before it builds a request: the `:depth`, then
  the symbol. For `DpExchange.Webull.Fake`.
  """
  @spec validate_event_book_request(term(), keyword()) :: :ok | {:error, term()}
  def validate_event_book_request(symbol, opts) do
    with :ok <- book_depth("US_EVENT", Keyword.get(opts, :depth)),
         do: validate_symbol(symbol)
  end

  defp events_for(series, credentials, opts) do
    params =
      %{"series_symbol" => series}
      |> put_present("symbols", symbols_param(Keyword.get(opts, :symbols)))
      |> put_present("status", Keyword.get(opts, :status))

    path = "/trading/instruments/event-contracts/events/list"

    with {:ok, body} <- get(path, params, credentials, opts),
         {:ok, events} <- rows(body) do
      object_rows(events)
    end
  end

  @doc """
  The tradable markets under a series or an event —
  `GET /trading/instruments/event-contracts/markets/list`.

  This is the level that is actually tradable; the three above it are addressing.

  **`status` and `tradable_status` are two different fields with two different
  vocabularies**, and a market can be `LISTING` and `NT` at the same time. Both survive on
  the row, because collapsing them into one "is it tradable" boolean is how a caller ends up
  routing an order at a market that is listed and not accepting one.

  Paged like `list_event_series/2`, and returned the same way.
  """
  @spec list_event_markets(map(), keyword()) ::
          {:ok, %{rows: [map()], pagination_key: String.t() | nil}}
          | {:error, term()}
          | {:refused, term()}
  def list_event_markets(credentials, opts) do
    with :ok <- validate_event_markets_request(opts) do
      params =
        %{}
        |> put_present("series_symbol", Keyword.get(opts, :series_symbol))
        |> put_present("event_symbol", Keyword.get(opts, :event_symbol))
        |> put_present("symbols", symbols_param(Keyword.get(opts, :symbols)))
        |> put_present("expiration_date_after", date_param(Keyword.get(opts, :expiring_after)))
        |> put_present("pagination_key", Keyword.get(opts, :pagination_key))

      path = "/trading/instruments/event-contracts/markets/list"

      with {:ok, body} <- get(path, params, credentials, opts), do: paged(body)
    end
  end

  defp date_param(%Date{} = date), do: Date.to_iso8601(date)
  defp date_param(other), do: other

  # `nil` where the venue sent no key, which is its way of saying this was the last page.
  # A missing key and an empty string are the same thing here and both mean the end.
  #
  # **The key is text or the page is refused, and every row is an object.** A number, list or
  # object under `pagination_key` was handed back inside `{:ok, %{pagination_key: key}}` typed
  # `String.t() | nil`, and a caller passing it on as `opts[:pagination_key]` raised
  # `Protocol.UndefinedError` in `to_string/1` on the NEXT call. The walks that follow a key
  # themselves (`next_pagination_key/1`) already refuse it as `:unexpected_pagination_key`;
  # this is the one reader that returned it. A row that is not an object breaks the `[map()]`
  # the spec promises, as `object_rows/1` refuses it everywhere else.
  defp paged(%{"data" => data} = body) when is_list(data) do
    with {:ok, key} <- page_key(body["pagination_key"]),
         {:ok, objects} <- object_rows(data) do
      {:ok, %{rows: objects, pagination_key: key}}
    end
  end

  defp paged(body) do
    with {:ok, page_rows} <- rows(body),
         {:ok, objects} <- object_rows(page_rows) do
      {:ok, %{rows: objects, pagination_key: nil}}
    end
  end

  defp page_key(nil), do: {:ok, nil}
  defp page_key(""), do: {:ok, nil}
  defp page_key(key) when is_binary(key), do: {:ok, key}
  defp page_key(_not_text), do: {:error, :unexpected_pagination_key}

  @doc """
  The tape for one event-contract market —
  `GET /market-data/event-contracts/ticks/list`.

  **Not `get_trades/3`, and that is not an omission.** An event tick carries a `yes_price`
  *and* a `no_price` and a `side` of `yes`/`no`; `Types.Trade` carries one price and a side
  of `:buy`/`:sell`. Mapping `yes` to `:buy` would file the print against the other
  instrument of a two-instrument market, and the number would look right. So the venue's own
  rows are returned and nothing is normalised.

  The venue's default count here is **30**, the same as its other tapes (`event-tick.md`,
  `tick.md`); the maximum is 1200.
  """
  @spec get_event_trades(String.t(), map(), keyword()) ::
          {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def get_event_trades(symbol, credentials, opts) do
    # `event-tick.md`: "maximum limit 1200". The query is built AFTER the limit is checked: a
    # map for `:limit` raised `Protocol.UndefinedError` out of `put_present/3` before the
    # check that refuses it as `{:invalid_option, :limit, value}` could run.
    with :ok <- validate_event_trades_request(symbol, opts),
         params = event_params(symbol, "count", Keyword.get(opts, :limit)),
         {:ok, body} <-
           get_symbol("/market-data/event-contracts/ticks/list", params, credentials, opts),
         {:ok, row} <- symbol_row(body, symbol),
         {:ok, ticks} <- list_value(row, ["result"]) do
      object_rows(ticks)
    end
  end

  # The query both event-contract market reads start from: the market's symbol, the category,
  # and one optional count or depth.
  defp event_params(symbol, key, value),
    do: put_present(%{"symbol" => symbol, "category" => "US_EVENT"}, key, value)

  @doc """
  The order book for one event-contract market —
  `GET /market-data/event-contracts/depths/list`.

  **Four books, not two**, and that is why this is not `get_order_book/3`. The venue returns
  `yes_bids`, `yes_asks`, `no_bids` and `no_asks`; `Types.OrderBook` has one bid side and one
  ask side. Picking the YES pair to be "the book" would answer about an instrument the caller
  never named, and the prices would be plausible — a YES ask of 0.13 and a NO ask of 0.92 are
  both real and neither is the other.

  The venue notes that in a binary market a yes bid at X equals a no ask at 1−X. That
  identity is the venue's; this package does not derive one side from the other, because a
  derived level cannot be told from a quoted one.

  Returned as `%{yes_bids:, yes_asks:, no_bids:, no_asks:, quote_time:}` with the venue's own
  level maps and its `quote_time` in milliseconds. A side that is present and not a list is
  `{:error, :unexpected_response_shape}` (an absent one is `[]`), and a row naming another
  market than the one asked for is `{:error, :not_in_response}`. `opts[:depth]` must be a
  whole number of levels, one or more, or `{:error, {:invalid_option, :depth, depth}}`
  before any request.
  """
  @spec get_event_order_book(String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def get_event_order_book(symbol, credentials, opts) do
    # **Each side is a list or it is refused.** `List.wrap/1` turned a string into a
    # one-level "book" and an object into a one-row list of the wrong thing, and an unreadable
    # side read as an empty one - the shape `list_value/2` exists to refuse. An absent side is
    # still none, and a row that names another market is `:not_in_response` (`symbol_row/2`).
    #
    # A `:depth` that is not a whole number of levels is refused before the request, as the
    # stock and futures books refuse theirs: the page states none beyond "default 10 levels".
    #
    # The query is built AFTER that check: a map for `:depth` raised out of `put_present/3`
    # first.
    with :ok <- validate_event_book_request(symbol, opts),
         params = event_params(symbol, "depth", Keyword.get(opts, :depth)),
         {:ok, body} <-
           get_symbol("/market-data/event-contracts/depths/list", params, credentials, opts),
         {:ok, row} <- symbol_row(body, symbol),
         {:ok, yes_bids} <- list_value(row, ["yes_bids"]),
         {:ok, yes_asks} <- list_value(row, ["yes_asks"]),
         {:ok, no_bids} <- list_value(row, ["no_bids"]),
         {:ok, no_asks} <- list_value(row, ["no_asks"]) do
      {:ok,
       %{
         symbol: value(row, ["symbol"]) || symbol,
         yes_bids: yes_bids,
         yes_asks: yes_asks,
         no_bids: no_bids,
         no_asks: no_asks,
         quote_time: value(row, ["quote_time"])
       }}
    end
  end

  # --- options -----------------------------------------------------------

  @doc """
  The option chain for an underlying — `GET /trading/instruments/options/contracts/list`.

  Returns `Types.OptionChain`: **expiry × strike, both sides**. The venue publishes a flat
  list of contracts; a flat list is lossless in data and answers none of the questions a
  chain is asked, so the grid is rebuilt here.

  **A contract this package cannot read is refused, not skipped.** An expiry, a strike and a
  right are what address a contract; a row missing any of them yields
  `{:error, {:unreadable_option_contract, keys}}` naming the keys the venue actually sent.
  Dropping the row would return a chain with a hole in it that looks complete, and a caller
  walking strikes would never learn the strike was there.

  **`:underlying_price` is `nil`.** This endpoint lists contracts and does not quote the
  underlying. Fetching it separately and stamping it on would be two observations at two
  times presented as one, which is how a "delta-neutral" position turns out not to be.

  `opts[:expiry]` and `opts[:strike]` are passed to the venue where given — a full chain is
  large, and narrowing it at the venue is not the same as narrowing it here.

  **Two different contracts at one expiry, strike and right are refused, not overwritten.**
  The grid holds one contract per cell, and an index whose standard and weekly roots share a
  date (SPX and SPXW on the third Friday) can list two. The second used to replace the
  first silently, so a caller trading the cell got whichever row the venue sent last. That
  is now `{:error, {:ambiguous_option_contract, expiry, strike, right, [venue_symbol]}}`;
  narrow the request with `opts[:expiry]` / `opts[:strike]` or read the flat contract list.
  The same contract listed twice is one contract, and is kept once.

  **The grid is keyed on the strike's value, not the venue's spelling of it**: a call listed
  at `"150.0"` and a put at `"150"` share the cell at `Decimal.new("150")`. The contract's own
  `:strike` keeps the spelling it was sent with.
  """
  @spec get_option_chain(String.t(), map(), keyword()) ::
          {:ok, OptionChain.t()} | {:error, term()} | {:refused, term()}
  def get_option_chain(underlying, credentials, opts) do
    with {:ok, contracts} <- option_contracts(underlying, credentials, opts),
         {:ok, grid} <- chain_grid(contracts) do
      {:ok,
       %OptionChain{
         underlying: underlying,
         expiries: grid,
         underlying_price: nil,
         venue_time: nil,
         provider: :webull
       }}
    end
  end

  @doc """
  The expiries listed on an underlying, without the strikes.

  Webull publishes no expiry-only endpoint, so this reads the contract list and returns its
  distinct expiries, earliest first. **That is a narrowing of a real response, not a
  substitute for a missing one** — the dates are the venue's own, and no date appears here
  that was not on a contract the venue listed.

  A caller that needs the strikes as well should call `get_option_chain/3` once rather than
  this and then that: the two would be two reads of a list that moves.
  """
  @spec get_option_expirations(String.t(), map(), keyword()) ::
          {:ok, [Date.t()]} | {:error, term()} | {:refused, term()}
  def get_option_expirations(underlying, credentials, opts) do
    with {:ok, contracts} <- option_contracts(underlying, credentials, opts) do
      {:ok,
       contracts
       |> Enum.map(& &1.expiry)
       |> Enum.uniq()
       |> Enum.sort(Date)}
    end
  end

  # **Four request-side corrections against `option-contract-list.md`.**
  #
  #   * `underlying_symbols` (plural, `:60`), not `underlying_symbol` — the singular name
  #     is not a parameter this endpoint defines at all, so every call before this sent an
  #     underlying the venue did not read and got back whatever `underlying_symbols`
  #     omitted returns (everything, or a business error — either way not "this symbol's
  #     contracts").
  #   * `start_date` (`:78`, "Exact expiration date"), not `expire_date` — again not a
  #     parameter this endpoint defines.
  #   * `strike_price_gte`/`strike_price_lte` (`:127,136`), not `strike_price` — the venue
  #     takes a strike RANGE and has no exact-match field; an exact strike is expressed
  #     honestly as `gte == lte == strike`, which is the literal way to say "strike equals
  #     this" with a range-only pair, not a synthesized bound.
  #   * `page_size` is undefined here — the venue paginates this endpoint on
  #     `pagination_key` (`:167`) instead, which `option_contracts/3` now follows bounded.
  defp option_contracts(underlying, credentials, opts) do
    base_params =
      %{"underlying_symbols" => underlying, "category" => "US_OPTION"}
      |> put_present("start_date", option_date_param(Keyword.get(opts, :expiry)))
      |> option_strike_params(Keyword.get(opts, :strike))

    fetch_page = fn key ->
      params = put_present(base_params, "pagination_key", key)

      with {:ok, body} <-
             get("/trading/instruments/options/contracts/list", params, credentials, opts),
           {:ok, contract_rows} <- rows(body) do
        {:ok, {contract_rows, next_pagination_key(body)}}
      end
    end

    with :ok <- validate_symbol(underlying),
         {:ok, contract_rows} <- paginate(fetch_page) do
      decode_option_contracts(contract_rows, underlying)
    end
  end

  defp option_strike_params(params, nil), do: params

  defp option_strike_params(params, strike) do
    wire = option_decimal_param(strike)

    params
    |> Map.put("strike_price_gte", wire)
    |> Map.put("strike_price_lte", wire)
  end

  defp option_date_param(%Date{} = date), do: Date.to_iso8601(date)
  defp option_date_param(other), do: other

  defp option_decimal_param(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp option_decimal_param(other), do: other

  defp decode_option_contracts(rows, underlying) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, acc} ->
      case to_option_contract(row, underlying) do
        {:ok, contract} -> {:cont, {:ok, [contract | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, contracts} -> {:ok, Enum.reverse(contracts)}
      error -> error
    end
  end

  # The three addressing fields are required together. A row that yields two of them is a
  # row this package misread, and naming the keys the venue sent is what lets a reader fix
  # it — a `nil` strike would sit in the grid looking like a contract.
  #
  # `expiration_date` (`option-contract-list.md:312`), not `expire_date` — the request
  # parameter and the response field are spelled differently on this endpoint, and reading
  # the request's own name off the response found nothing on every row: every contract this
  # package listed had `expiry: nil` and failed the addressing check below. `settlement_type`
  # and `expiration_type` are `Core.Types.OptionContract`'s own field names — freeform
  # per-venue strings, not a cross-venue enum — populated here from the venue's
  # `settlement_method` and `expired_cycle` (`:357,362`), not `settlement_type`/
  # `expiration_type`, which this endpoint does not define.
  defp to_option_contract(row, underlying) when is_map(row) do
    # Every name below is the one `option-contract-list.md:312-362` defines; no page or
    # capture shows `expirationDate`, `strikePrice`, `strike`, `direction` or `optionType`.
    with {:ok, expiry} <- option_expiry(value(row, ["expiration_date"])),
         {:ok, strike} <- option_strike(value(row, ["strike_price"])),
         {:ok, right} <- option_right(value(row, ["option_type"])),
         :ok <- contract_underlying(row, underlying) do
      {:ok,
       %OptionContract{
         underlying: underlying,
         expiry: expiry,
         strike: strike,
         right: right,
         # The OCC contract symbol (`:297`). `instrument_id` is the venue's internal id, not a
         # symbol any endpoint takes, and `unit` is a futures field (`futures-instrument-list.md`).
         venue_symbol: text_or_nil(value(row, ["symbol"])),
         multiplier: decimal(value(row, ["multiplier"])),
         settlement_type: text_or_nil(value(row, ["settlement_method"])),
         expiration_type: text_or_nil(value(row, ["expired_cycle"])),
         # The page defines no last-trading-day field (`last_trade_date`, `lastTradeDate` and
         # `last_trading_day` appear nowhere): `nil`, "not published".
         last_trading_day: nil,
         # The venue names none of these three flags on this endpoint. It publishes
         # neighbours - `underlying_type` (`INDEX_CALL_OPTION`...), `def_type` (`STANDARD |
         # BINARY | FLEX`) and `settlement_method` - but none says what `Core`'s flags mean
         # (a deliverable altered by a corporate action; cash settlement of an index), and
         # mapping a neighbour onto them would be this package's reading, not the venue's
         # word. `nil` says "not published", and `false` would say "the venue told us it
         # is not one". `settlement_method` is carried as `settlement_type` above.
         index_option: nil,
         mini: nil,
         non_standard: nil,
         provider: :webull
       }}
    else
      :error -> {:error, {:unreadable_option_contract, Map.keys(row)}}
      {:error, _reason} = refused -> refused
    end
  end

  defp to_option_contract(row, _underlying), do: {:error, {:unreadable_option_contract, row}}

  # **A contract is the requested underlying's, or the read is refused.** The page documents
  # `underlying_symbol` on every row (`option-contract-list.md`), and a row naming another
  # underlying was filed under the one asked for with its expiry, strike and right all
  # plausible - the substitution `symbol_row/2` refuses for the snapshot rows. A row that names
  # no underlying is read as the requested one, as ever.
  defp contract_underlying(row, underlying) do
    case value(row, ["underlying_symbol"]) do
      nil -> :ok
      named -> if same_symbol?(named, underlying), do: :ok, else: {:error, :not_in_response}
    end
  end

  defp option_expiry(nil), do: :error

  defp option_expiry(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> :error
    end
  end

  defp option_expiry(_other), do: :error

  defp option_strike(nil), do: :error

  # **A strike is a price above zero.** `"0"` and `"-5"` read as numbers and filed a contract
  # at a strike no option has, in a grid cell a caller walking strikes would treat as real.
  # Refused as an unreadable contract, like a strike that is not a number at all.
  defp option_strike(value) do
    case decimal(value) do
      %Decimal{} = strike -> if Decimal.positive?(strike), do: {:ok, strike}, else: :error
      nil -> :error
    end
  end

  # The venue's own words for the two sides. Anything else is `:error` rather than a default
  # side — a put filed as a call is a position the opposite way round.
  defp option_right(value) when is_binary(value) do
    case String.upcase(value) do
      # `CALL` / `PUT` only (`option-contract-list.md:338`): no page shows `C` or `P`.
      "CALL" -> {:ok, :call}
      "PUT" -> {:ok, :put}
      _other -> :error
    end
  end

  defp option_right(_other), do: :error

  # **The grid is keyed on the strike's VALUE, not on how the venue spelled it.** A `Decimal`
  # is a coefficient and an exponent, and `Decimal.new("150.0")` and `Decimal.new("150")`
  # are different map keys for the same strike: a call listed at `"150.0"` and a put at
  # `"150"` landed in two cells, each with a `nil` on the side the other held, and a caller
  # looking up the strike found half a row. The key is the plain, trailing-zero-free form
  # (`Decimal.new("150")`, the form `Core.Types.OptionChain` shows), and the contract's own
  # `:strike` keeps the venue's spelling.
  defp strike_key(%Decimal{} = strike) do
    strike |> Decimal.normalize() |> Decimal.to_string(:normal) |> Decimal.new()
  end

  # A strike listed with only one side keeps a `nil` on the other, rather than being absent:
  # a caller iterating strikes has to see that the put is missing.
  #
  # A cell already holding a DIFFERENT contract is refused — see `get_option_chain/3`'s
  # "Two different contracts" paragraph. Found 2026-10-10 by reading this function.
  defp chain_grid(contracts) do
    Enum.reduce_while(contracts, {:ok, %{}}, fn contract, {:ok, grid} ->
      strikes = Map.get(grid, contract.expiry, %{})
      key = strike_key(contract.strike)
      row = Map.get(strikes, key, %{call: nil, put: nil})

      case Map.get(row, contract.right) do
        held when is_nil(held) or held == contract ->
          row = Map.put(row, contract.right, contract)
          {:cont, {:ok, Map.put(grid, contract.expiry, Map.put(strikes, key, row))}}

        held ->
          {:halt,
           {:error,
            {:ambiguous_option_contract, contract.expiry, contract.strike, contract.right,
             [held.venue_symbol, contract.venue_symbol]}}}
      end
    end)
  end

  # --- decoding -----------------------------------------------------------

  # Groups carry their rows under "result"; a flat bar decodes directly. Mapping a row
  # decoder over the groups yields all-nil bars, which reads as "the venue has no data".
  defp decode_bars(body, symbol, timeframe) do
    # A group that is not an object (a string or a number among the groups) refuses the reply,
    # as `nested_results/1` does for the stock, option, futures and event bars: it used to be
    # skipped, so a crypto series with a group missing read as a complete one.
    with {:ok, listed} <- rows(body),
         {:ok, body_rows} <- object_rows(listed) do
      body_rows
      |> Enum.flat_map(fn
        %{"result" => group_rows} when is_list(group_rows) -> group_rows
        flat_bar -> [flat_bar]
      end)
      |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
        case decode_bar(row, symbol, timeframe, :crypto) do
          {:ok, bar} -> {:cont, {:ok, [bar | acc]}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, bars} -> {:ok, bars |> Enum.reverse() |> Enum.sort_by(& &1.opened_at, DateTime)}
        error -> error
      end
    end
  end

  # **Volume is documented on four of this decoder's five callers.** Stock, option, futures
  # and event bars all list `volume` as a REQUIRED field of their own `"result"` row
  # (`historical-bars.md:269,298`, `option-historical-bars.md`, `futures-historical-bars.md:214`,
  # `event-bars.md:236`) — only `crypto-bars.md`'s own bar schema carries no such field.
  # Hard-coding `nil` here for every caller, which is what this did before, was correct for
  # crypto and a false claim about the other four: reading `value(row, ["volume"])` costs
  # nothing when the field is absent (`decimal(nil)` is already `nil`) and is the honest
  # value when the venue sent one.
  #
  # **`time` is not provably the open, so it must sit on the width's grid.** The pages say
  # "Bar UTC time" / "Bar timestamp in ISO-8601 or Unix time format" and never "open time",
  # and a bar whose time is off the grid (the pages' own example is `09:00:09.945`) is either
  # a different instant (a close, a last-trade) or a fabricated one - stored as `opened_at`
  # it would be a plausible candle in the wrong bucket. The whole reply is refused
  # `{:unaligned_candle, time}`. **Unmeasured** against a live venue. The crypto endpoint
  # serves no width Core lacks a rule for; on the session endpoints `1w`, `1M` and `1y` have
  # none in Core and pass wherever `session_bar_time/2` leaves them as sent. OHLC are prices:
  # zero or negative refuses (`required_price/2`).
  #
  # `kind` is `:crypto` (a 24h market: the strict UTC grid) or `:session` (stock, option,
  # futures, event: see `session_bar_time/2`).
  defp decode_bar(row, symbol, timeframe, kind) do
    with {:ok, raw_timestamp} <- venue_time(row),
         {:ok, timestamp} <- bar_time(raw_timestamp, timeframe, kind),
         {:ok, open} <- required_price(value(row, ["open"]), :open),
         {:ok, high} <- required_price(value(row, ["high"]), :high),
         {:ok, low} <- required_price(value(row, ["low"]), :low),
         {:ok, close} <- required_price(value(row, ["close"]), :close) do
      {:ok,
       %Candle{
         symbol: symbol,
         timeframe: timeframe,
         opened_at: timestamp,
         open: open,
         high: high,
         low: low,
         close: close,
         volume: decimal(value(row, ["volume"])),
         provider: :webull
       }}
    end
  end

  # The venue's own time, or nothing. The adapter this came from ended its bar decoder
  # with `|| DateTime.utc_now()`, so a bar the venue did not date was stamped with the
  # client's clock and became indistinguishable from a real one — the same substitution
  # found on two other venues in this family.
  defp venue_time(row) do
    # `time` alone: the bar, tick and footprint rows all define it (`crypto-bars.md:229`,
    # `historical-bars.md:273`, `option-historical-bars.md:249`, `futures-historical-bars.md:218`,
    # `event-bars.md:265`, `tick.md:221`, `futures-tick.md:204`, `option-tick.md:204`,
    # `footprint.md:240`). `ts`, `timestamp`, `tradeTime` and `trade_time` appear in no REST
    # page, and `last_trade_time` / `quote_time` belong to snapshots, which have their own
    # readers (`trade_time/1`, `quote_time/1`): a bar dated by a quote's time is another event.
    case value(row, ["time"]) do
      nil -> {:error, :missing_venue_timestamp}
      raw -> parse_time(raw)
    end
  end

  # A time the page states in milliseconds, read as milliseconds and nothing else: a number at
  # or below 100_000_000_000 (1973 as milliseconds, so a seconds-sized value) or past thirteen
  # digits is `:invalid_unix_time`, never reinterpreted in another unit. A number written as
  # text is read the same way; anything that is not a number (an ISO 8601 string) is read as
  # written by `parse_time/1`.
  defp parse_time_ms(value) when is_integer(value), do: strict_epoch_ms(value)

  defp parse_time_ms(value) when is_binary(value) do
    case Integer.parse(value) do
      {epoch, ""} -> strict_epoch_ms(epoch)
      _not_an_epoch -> parse_time(value)
    end
  end

  defp parse_time_ms(other), do: parse_time(other)

  defp strict_epoch_ms(ms) when ms > 100_000_000_000 and ms <= 9_999_999_999_999,
    do: DateTime.from_unix(ms, :millisecond)

  defp strict_epoch_ms(_not_a_millisecond_time), do: {:error, :invalid_unix_time}

  defp parse_time(value) when is_integer(value), do: from_epoch(value)

  defp parse_time(value) when is_binary(value) do
    case Integer.parse(value) do
      {epoch, ""} ->
        from_epoch(epoch)

      _not_an_epoch ->
        case DateTime.from_iso8601(value) do
          # The epoch rule applies to the written form too: `0001-01-01T00:00:00Z` and
          # `1970-01-01T00:00:00Z` are the same "unknown" sentinel as an epoch of 0 and were
          # accepted as real times.
          {:ok, datetime, _offset} -> iso_time(datetime)
          _error -> {:error, {:unparseable_venue_timestamp, value}}
        end
    end
  end

  defp parse_time(other), do: {:error, {:unparseable_venue_timestamp, other}}

  defp iso_time(datetime) do
    if DateTime.to_unix(datetime) > 0, do: {:ok, datetime}, else: {:error, :invalid_unix_time}
  end

  # Webull sends milliseconds on some endpoints and seconds on others. Ten digits is
  # seconds until roughly the year 2286; thirteen is milliseconds. Guessing the wrong one
  # puts a 2026 bar in 1970 or in 58,000 — both loud, which is why this is a threshold
  # rather than a fallback.
  # Non-positive is refused before the unit question is even asked.
  #
  # `DateTime.from_unix/2` answers `{:ok, ~U[1970-01-01 00:00:00Z]}` for 0 and a 1969 instant
  # for negatives — valid `DateTime`s, which is exactly why they are the dangerous case.
  # `0` is a common venue sentinel for "unknown", and the comment below calls 1970 "loud"
  # while it is not: a consumer computing an age gets fifty-six years and may well skip the
  # row, but one that logs or charts the timestamp shows 1970 and calls it data. The family
  # settled this for level timestamps — "an unreadable level timestamp does not become the
  # epoch" — and the same answer applies wherever an epoch is converted.
  #
  # `{:error, :invalid_unix_time}` is the shape an out-of-range value already produces here,
  # so every caller handles it unchanged.
  defp from_epoch(value) when value <= 0, do: {:error, :invalid_unix_time}

  # **Past thirteen digits is neither seconds nor milliseconds.** Microseconds (16 digits) or
  # nanoseconds (19) read as milliseconds is a `DateTime` in the year 50,000 or later - valid,
  # so it would go out as a bar's open time or a quote's time with no failure anywhere. The
  # venue documents only seconds and milliseconds, so a longer value is refused as the unit
  # it cannot be read as.
  defp from_epoch(value) when value > 9_999_999_999_999, do: {:error, :invalid_unix_time}

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
  defp after_start?(bar, start), do: DateTime.compare(bar.opened_at, start) != :lt

  defp before_end?(_bar, nil), do: true
  # `:end` is exclusive: a bar opening exactly at `:end` belongs to the next window.
  defp before_end?(bar, finish), do: DateTime.compare(bar.opened_at, finish) == :lt

  defp bar_time(timestamp, timeframe, :crypto), do: strict_bar_time(timestamp, timeframe)
  defp bar_time(timestamp, timeframe, :session), do: session_bar_time(timestamp, timeframe)

  defp strict_bar_time(timestamp, timeframe) do
    if Timeframe.aligned?(timestamp, timeframe),
      do: {:ok, timestamp},
      else: {:error, {:unaligned_candle, timestamp}}
  end

  # **Session-traded bars are anchored to the session, not to the UTC epoch.** US cash
  # sessions open at 09:30 America/New_York, so:
  #
  #   * widths of 30 minutes and under divide 09:30 and keep the strict UTC grid;
  #   * wider intraday widths (1h, 2h, 4h, ...) open at 09:30, 10:30 ...: only a
  #     30-minute alignment (minute 0 or 30, no seconds) is required;
  #   * a daily, weekly, monthly or yearly bar stamped at exchange-local midnight (04:00Z in
  #     EDT, 05:00Z in EST) or at 00:00Z states the session DATE; it is mapped to 00:00 UTC of
  #     that date, as `DpExchange.Schwab` does. A `1d` bar at any other time of day is
  #     refused; `1w`/`1M`/`1y` have no rule in Core and any other time is left as sent.
  #
  # Anything off those grids is `{:unaligned_candle, time}`. **Unmeasured** against a live
  # venue: this is the architect's reading of where a session bar can open.
  defp session_bar_time(timestamp, timeframe) do
    cond do
      timeframe in ["1h", "2h", "4h", "6h", "12h"] ->
        half_hour_bar_time(timestamp)

      timeframe in ["1d", "1w", "1M", "1y"] ->
        session_date_time(timestamp, timeframe)

      true ->
        strict_bar_time(timestamp, timeframe)
    end
  end

  defp half_hour_bar_time(%DateTime{minute: minute, second: 0, microsecond: {0, _p}} = at)
       when minute in [0, 30],
       do: {:ok, at}

  defp half_hour_bar_time(at), do: {:error, {:unaligned_candle, at}}

  defp session_date_time(
         %DateTime{hour: hour, minute: 0, second: 0, microsecond: {0, _p}} = at,
         _timeframe
       )
       when hour in [0, 4, 5],
       do: {:ok, DateTime.new!(DateTime.to_date(at), ~T[00:00:00], "Etc/UTC")}

  defp session_date_time(at, "1d"), do: {:error, {:unaligned_candle, at}}
  defp session_date_time(at, _calendar_width), do: {:ok, at}

  # **An envelope is never a row.** The third clause exists for endpoints that answer with a
  # bare object, and it used to catch envelopes too: `%{"code" => "200", "msg" => "ok",
  # "data" => nil}` failed the `is_list/1` guard above, landed on `%{} = body`, and came back
  # as a one-row list whose row was the envelope itself. Measured against that body:
  # `get_orders/2` answered `{:ok, [%Order{id: nil, symbol: nil, side: nil, …}]}` — a phantom
  # order — and `get_transfers/2`, which returns rows as the venue sends them, handed the
  # envelope back as a transfer. `get_positions/2` refused the envelope as a malformed
  # position, which fails closed but reports "no positions" as corrupt data.
  #
  # So a `"data"` key decides the shape whatever it holds: a list is the rows, an object is
  # one row (the object, not its wrapper), and `null` is none.
  #
  # **A `"data"` that is present and is neither a list, an object nor `null` is unreadable,
  # not empty.** This used to fall through the same `_nothing -> []` clause `null` takes —
  # `%{"data" => "x"}`, or a `42` or a `true` the venue sent where a list belongs, came back
  # as `{:ok, []}`, indistinguishable from a genuinely empty page. `get_orders/2`,
  # `get_positions/2` and every other list endpoint built on this function answered "no
  # orders" / "no positions" from a response this package could not read at all — the exact
  # substitution the family rule against is written for: a value that stays plausible while
  # its meaning silently changes from "none" to "the venue said something this package does
  # not understand". `null` keeps its own clause and stays `[]`, because it is the one shape
  # in this set that is a documented, deliberate "nothing here" rather than a shape this
  # package failed to parse.
  #
  # Same reasoning for the body itself: a `2xx` payload that decoded to neither a list nor a
  # map — a bare string, number or boolean where JSON allows one but this contract never
  # expects one — used to fall through `_other -> []` below the bare-object clause. That is
  # the same "no rows" answer a caller cannot tell apart from an endpoint with nothing to
  # report.
  defp rows(body) when is_list(body), do: {:ok, body}
  defp rows(%{"data" => rows}) when is_list(rows), do: {:ok, rows}
  defp rows(%{"data" => %{} = row}), do: {:ok, [row]}
  defp rows(%{"data" => nil}), do: {:ok, []}
  defp rows(%{"data" => _unreadable}), do: {:error, :unexpected_response_shape}
  defp rows(%{} = body), do: {:ok, [body]}
  defp rows(_other), do: {:error, :unexpected_response_shape}

  defp first_row(body) do
    case rows(body) do
      {:ok, [row | _rest]} when is_map(row) -> {:ok, row}
      {:ok, _empty} -> {:error, :unexpected_response_shape}
      {:error, _reason} = error -> error
    end
  end

  # The row for the symbol that was asked for. A list endpoint answers every symbol in the
  # request, and the first row used to be taken whichever instrument it named, so a response
  # leading with another symbol delivered that symbol's price, book or increments under the
  # requested symbol's name. A row naming a different symbol is `:not_in_response`; a
  # response none of whose rows names a symbol is read as the first row, as it always was.
  defp symbol_row(body, native) do
    with {:ok, body_rows} <- rows(body) do
      case Enum.filter(body_rows, &is_map/1) do
        [] -> {:error, :unexpected_response_shape}
        maps -> pick_symbol_row(maps, native)
      end
    end
  end

  defp pick_symbol_row([first | _rest] = maps, native) do
    named? = Enum.any?(maps, &is_binary(value(&1, ["symbol"])))

    case Enum.find(maps, &same_symbol?(value(&1, ["symbol"]), native)) do
      nil when named? -> {:error, :not_in_response}
      nil -> {:ok, first}
      row -> {:ok, row}
    end
  end

  defp same_symbol?(named, native) when is_binary(named),
    do: String.upcase(named) == String.upcase(native)

  defp same_symbol?(_named, _native), do: false

  defp required(row, keys) do
    case value(row, keys) do
      nil -> {:error, :unexpected_response_shape}
      found -> {:ok, found}
    end
  end

  # The first of `keys` the row carries. **Every key a caller lists must be a name a vendor
  # page or a captured response shows, and the caller says which in a comment.** An alias
  # that is only a guess at how the venue might spell a field is a substitute source: a
  # different field of that name would be read as this one.
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

  # A field the Core type says is `String.t() | nil`: text, or nothing. A number or an object
  # the venue sent there is not the text the type promises, and is not guessed at.
  defp text_or_nil(text) when is_binary(text), do: text
  defp text_or_nil(_not_text), do: nil

  # **A nested list, or a refusal.** `value(row, ["result"]) |> List.wrap()` stood at each of
  # this function's callers, and `List.wrap/1` turns a string into a one-element list and an
  # object into a one-row list of the wrong thing, while a row that was not an object read
  # as `nil` and so as nothing. A reply the tick, profile, bar or watchlist decoder could not
  # read therefore came back as no ticks, no bars, an empty watchlist, or a single entry
  # built from a wrapper. Absent or `null` is still none: the venue omits an empty list.
  defp list_value(row, keys) when is_map(row) do
    case value(row, keys) do
      list when is_list(list) -> {:ok, list}
      nil -> {:ok, []}
      _unreadable -> {:error, :unexpected_response_shape}
    end
  end

  defp list_value(_row, _keys), do: {:error, :unexpected_response_shape}

  # A refusal carries the venue's status AND its words. This used to take only the body, so
  # every `4xx` this package refuses on — 400, 401 and 403 — arrived at the caller looking
  # identical, and their remedies are not: a 400 means fix the request, a 401 means refresh
  # the token and call again, a 403 means a person has to change what the credential is
  # entitled to. The clause above `refusal/2`'s callers even says so ("a caller whose token
  # expired refreshes and calls again") — the code knew which status it had matched and then
  # discarded the only thing that could tell a caller.
  #
  # Same shape as `dp_exchange_coinbase`, `dp_exchange_robinhood` and `dp_exchange_schwab`
  # already use. This venue was the one outlier, found by sweeping the family for the
  # principle a consumer named on dp-exchange-gemini#1: **a caller must never be handed less
  # than this package already had.**
  #
  # An unrecognised body keeps the status rather than collapsing to a bare `:refused`. A
  # status alone is thin, but it is the difference between "the venue rejected this and here
  # is which kind" and "something went wrong".
  defp refusal(status, body), do: refusal_reason(status, refusal_body(body))

  # The venue's documented error shape (`{"error_code": "UNAUTHORIZED", "message": ...}` on its
  # 401 and 417 responses): the code is the part a caller matches on, and the message alone
  # dropped it.
  defp refusal_reason(status, %{"error_code" => code, "message" => message})
       when is_binary(code) and is_binary(message),
       do: {:venue_error, status, bound_reason(code <> ": " <> message)}

  # Only the two fields the pages' error bodies define (`subscribe.md:226-232` and every other
  # page's 401, 417 and 500 body). `msg`, `code` and `error_description` appear in no page.
  defp refusal_reason(status, %{"message" => message}) when is_binary(message),
    do: {:venue_error, status, bound_reason(message)}

  defp refusal_reason(status, %{"error_code" => code}) when is_binary(code),
    do: {:venue_error, status, bound_reason(code)}

  defp refusal_reason(status, _other), do: {:venue_error, status}

  # A refusal's words come from the venue, or from a gateway in front of it, and ride in an
  # error tuple a caller logs and keeps. Text over 2 KiB is cut and copied (a view would pin
  # the whole response, up to Core's body limit); the cut is marked, never silent. A `code`
  # that is an object or a list used to ride along whole and is now the bare status.
  @max_reason_bytes 2_048

  defp bound_reason(text) when byte_size(text) <= @max_reason_bytes, do: :binary.copy(text)

  defp bound_reason(text) do
    # DELIBERATE DEFENSIVE ARM (no test reaches the invalid-UTF-8 side): every caller passes
    # text `Jason` decoded, valid UTF-8 by construction. Kept so a more lenient body decoder
    # cannot make `String.slice/3` misread bytes that are not text.
    cut =
      if String.valid?(text),
        do: String.slice(text, 0, div(@max_reason_bytes, 4)),
        else: binary_part(text, 0, @max_reason_bytes)

    :binary.copy(cut) <> "... [truncated, #{byte_size(text)} bytes in all]"
  end

  # A 2xx body this package cannot decode is NOT an empty object.
  #
  # This used to collapse any unparseable body to `%{}` and hand it on as success. Nothing
  # downstream could tell that apart from a real but sparse response: `%{}` flows into every
  # reader in this module and comes out as a well-formed struct with each field `nil`,
  # returned as `{:ok, value}`. The realistic way to get there is not malformed JSON from
  # the venue but a `200` that is not the venue at all — an interstitial, a captive portal,
  # or a CDN maintenance page, all of which answer `200 text/html`. A caller polling
  # balances through one of those was told, truthfully-looking, that it held nothing.
  #
  # Refuse instead. `refusal_body/1` below stays lenient on purpose, for a body read for a
  # different reason.
  defp decoded_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> {:error, {:undecodable_response, :webull}}
    end
  end

  defp decoded_body(body), do: {:ok, body}

  # The OAuth token response, which must be an object because the caller reads
  # `access_token`, `refresh_token` and two separate expiries out of it.
  #
  # This was the sharpest instance of the `%{}` collapse: an unparseable or non-object token
  # response became `{:ok, %{}}`, so a refresh that had not actually returned a token
  # reported success and the session ended at the next signed call with an authentication
  # failure nothing connected back to the refresh.
  defp decoded_token(body) do
    case decoded_body(body) do
      {:ok, %{} = decoded} -> {:ok, decoded}
      {:ok, _other} -> {:error, :unexpected_response_shape}
      {:error, _reason} = error -> error
    end
  end

  # Deliberately lenient, unlike `decoded_body/1`. A refusal's body is read for a
  # human-readable reason and "there wasn't one in it" is an honest answer — the refusal
  # itself is already established by the status code, so collapsing an unparseable body to
  # `%{}` here loses nothing and `{:venue_error, status}` remains true. On a 2xx body the
  # identical collapse invents a success, which is the whole difference.
  defp refusal_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> %{}
    end
  end

  defp refusal_body(body), do: body

  defp stringify(params), do: Map.new(params, fn {k, v} -> {to_string(k), to_string(v)} end)

  defp put_present(map, _key, nil), do: map

  defp put_present(map, key, %Decimal{} = value),
    do: Map.put(map, key, wire_number(value))

  # `sort` on watchlist create/update is documented as a JSON integer
  # (`create-watchlist.md:150-155`, `update-watchlist.md`), not a string. The generic
  # clause below stringifies every other value — appropriate for a GET query, where
  # `stringify/1` does the same thing again downstream, but wrong for a POST body
  # `Jason.encode!/1`s directly: it sent `"sort":"1"` where the vendor documents `"sort":1`.
  # An integer is kept as one here so a JSON body carries the venue's own type; `get/4`'s
  # own `stringify/1` pass still turns it into a query string value where one is built.
  defp put_present(map, key, value) when is_integer(value), do: Map.put(map, key, value)

  defp put_present(map, key, value) when is_float(value),
    do: Map.put(map, key, wire_number(value))

  defp put_present(map, key, value), do: Map.put(map, key, to_string(value))

  # **`Decimal.to_string/1` defaults to SCIENTIFIC notation**, and `to_string/1` on a
  # `%Decimal{}` reaches the same default through `String.Chars`. So a quantity or price
  # carrying an exponent went onto the wire as `"1.5E+2"` or `"1E-8"` — not a number this
  # venue reads, and a different order if it read one at all.
  #
  # An exponent is not exotic. `Decimal.normalize/1` — the ordinary way to strip trailing
  # zeros — turns `150.00` into `1.5E+2`, and anything below a millionth carries one by
  # construction: `Decimal.new("0.00000001")` is `1E-8`.
  #
  # `option_decimal_param/1` in this same module already said `:normal` and the ORDER path
  # did not. Guarding `put_present/3` as well as the two size fields means a money field
  # added to a map later cannot reintroduce it.
  #
  # A float and a numeric string get the same treatment. `to_string(1.0e-8)` is `"1.0e-8"` and a
  # caller's `"1e-8"` went out as typed: neither is a number the venue reads as one.
  defp wire_number(%Decimal{} = value), do: Decimal.to_string(value, :normal)

  defp wire_number(value) when is_float(value),
    do: value |> Decimal.from_float() |> wire_number()

  defp wire_number(value) when is_binary(value) do
    case decimal(value) do
      # DELIBERATE DEFENSIVE ARM: every money caller runs `positive_numbers/2` first, which
      # refuses text that is not a number, so this is unreachable today. Kept so a field
      # added later without that check sends the text as typed (the venue refuses it by
      # name) rather than raising out of the caller's process on a money write.
      nil -> value
      parsed -> wire_number(parsed)
    end
  end

  defp wire_number(value), do: to_string(value)

  # A money field of a JSON body: always the venue's string form (`order-*.md` and
  # `common-order-replace.md` type `quantity`, `limit_price`, `stop_price` and
  # `trailing_stop_step` as `"type": "string"`). `put_present/3` keeps an integer an integer,
  # which is right for `sort` and `count` and sent `"limit_price": 10` for a price of `10`.
  defp put_number(map, _key, nil), do: map
  defp put_number(map, key, value), do: Map.put(map, key, wire_number(value))

  # **A number the order will carry must be a finite number above zero.** `0`, a negative, a
  # `NaN`, an `Infinity`, a boolean or text that is not a number all used to be sent as typed
  # (or, for a map or a list, raised out of `to_string/1` in the caller's process) on a
  # money-moving write; the venue's refusal then arrived after the request and named a field
  # the caller never wrote. `:error` is `{:invalid_<field>, value}` (`:invalid_quantity`,
  # `:invalid_amount`, `:invalid_price`, `:invalid_stop_price`,
  # `:invalid_trailing_stop_step`) for the first offending field, in the order given.
  #
  # **A float is refused**: it has already lost digits (`0.1 + 0.2`), and what reached the
  # wire was the digits of the float, not the number the caller meant. A `Decimal`, an
  # integer or a numeric string is exact.
  defp positive_numbers(request, fields) do
    Enum.find_value(fields, :ok, fn field ->
      value = Map.get(request, field)

      if is_nil(value) or positive_number?(value),
        do: nil,
        else: {:error, {invalid_number_tag(field), value}}
    end)
  end

  defp invalid_number_tag(:quantity), do: :invalid_quantity
  defp invalid_number_tag(:amount), do: :invalid_amount
  defp invalid_number_tag(:price), do: :invalid_price
  defp invalid_number_tag(:stop_price), do: :invalid_stop_price
  defp invalid_number_tag(:trailing_stop_step), do: :invalid_trailing_stop_step

  defp positive_number?(%Decimal{} = value) do
    not (Decimal.nan?(value) or Decimal.inf?(value) or absurd_exponent?(value)) and
      Decimal.gt?(value, 0)
  end

  defp positive_number?(value) when is_integer(value), do: value > 0

  defp positive_number?(value) when is_binary(value) do
    case decimal(value) do
      nil -> false
      parsed -> Decimal.gt?(parsed, 0)
    end
  end

  defp positive_number?(_not_a_number), do: false

  defp decimal(nil), do: nil
  defp decimal(%Decimal{} = value), do: value
  defp decimal(value) when is_integer(value), do: Decimal.new(value)
  defp decimal(value) when is_float(value), do: Decimal.from_float(value)

  # **A number written in more than 1,024 characters is no price, size or rate on this venue.**
  # `absurd_exponent?/1` bounds the EXPONENT but not the coefficient: `"1"` followed by two
  # thousand zeros is a finite `Decimal` with exponent 0, which used to be accepted as a price
  # and parsed by an integer conversion that grows with the string, from a body of any size
  # the HTTP client allows. Refused before the parse. **Chosen, not measured**: the venue
  # documents no numeric range, and the longest figure it has been seen to send is a few
  # dozen characters.
  @max_decimal_chars 1_024

  defp decimal(value) when is_binary(value) and byte_size(value) > @max_decimal_chars, do: nil

  # `Decimal.new/1` raises on a string that is not a number — a real, previously observed
  # response shape from a delisted Webull crypto pair, which returns the literal string
  # "null" for a price field. `Decimal.parse/1`, requiring the whole string be consumed
  # (`{d, ""}`), does not.
  #
  # `Decimal.parse/1` alone is not a sufficient guard, though: "NaN", "Inf" and "-Inf" all
  # fully parse, and a NaN or Infinity flowing into downstream arithmetic as a real price
  # is worse than the crash this replaced — it poisons a calculation silently instead of
  # failing where it happened.
  defp decimal(value) when is_binary(value) do
    case Decimal.parse(value) do
      {parsed, ""} ->
        if Decimal.nan?(parsed) or Decimal.inf?(parsed) or absurd_exponent?(parsed),
          do: nil,
          else: parsed

      _unparsable ->
        nil
    end
  end

  defp decimal(_other), do: nil

  # `"1E999999999"` parses, and is a finite `Decimal` whose exponent is a nine-digit number.
  # The first `Decimal.add/2`, `compare/2` or `to_string(:normal)` over it aligns coefficients
  # by `10^exponent`: a gigabyte of integer, in the caller's process, from one field. No
  # price, size or rate on this venue is near 1E+-1000, so an exponent past that is refused
  # as unreadable. **Chosen, not measured**: the venue documents no numeric range.
  defp absurd_exponent?(%Decimal{exp: exp}), do: abs(exp) > 1_000

  # A garbage or missing value in a field this contract requires must not become a `nil`
  # carried into `@enforce_keys` — a struct's field list does not check that a value is
  # non-nil, only that the key was given, so `decimal/1`'s lenient `nil` would sail
  # straight through to a subscriber as a `Quote` with no price. Refuse the record instead.
  defp required_decimal(nil, field), do: {:error, {:missing_required_field, field}}

  defp required_decimal(value, field) do
    case decimal(value) do
      nil -> {:error, {:invalid_decimal, field, value}}
      parsed -> {:ok, parsed}
    end
  end

  # **A traded price is positive.** `required_decimal/2` reads `"0"` and `"-5"` as numbers,
  # and a candle, a trade or a last price of zero (or less) is the venue's placeholder for
  # "no value", not a price - it stays plausible downstream and only the meaning is wrong.
  # Refused `{:non_positive_price, field, raw}`. (Sizes and quantities keep
  # `required_decimal/2`: a zero position or fill is real.)
  defp required_price(raw, field) do
    with {:ok, price} <- required_decimal(raw, field) do
      if Decimal.positive?(price),
        do: {:ok, price},
        else: {:error, {:non_positive_price, field, raw}}
    end
  end

  # **A print's size is not negative.** `required_decimal/2` reads `"-5"` as a number, and a
  # tape row of minus five lots is the venue's garbage, not a trade: it would be delivered as a
  # `Trade.quantity` that every consumer sums. Refused `{:non_positive_size, field, raw}` (the
  # tag the order book uses for the same figure). Zero is kept: whether a zero-size print is a
  # real correction is the venue's to say, and this package has no measurement either way.
  defp required_size(raw, field) do
    with {:ok, size} <- required_decimal(raw, field) do
      if Decimal.negative?(size),
        do: {:error, {:non_positive_size, field, raw}},
        else: {:ok, size}
    end
  end

  # Absent is `nil`; present and unreadable is an error. `decimal/1` alone answers `nil` for
  # both, which is how a figure the venue DID send, in a shape this package could not read,
  # became indistinguishable from one it never sent.
  defp optional_decimal(nil, _field), do: {:ok, nil}
  defp optional_decimal(value, field), do: required_decimal(value, field)

  @doc """
  Places an order. `request[:instrument_type]` picks the instrument (`:crypto` when absent,
  which is what this package served first; see `order_instrument_types/0`), and each
  instrument has its own type and time-in-force matrix. The crypto matrix is the short one,
  described first.

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

  ## An accepted response that names no order is `:order_unconfirmed`

  A 2xx whose row carries no `client_order_id`, **or no row at all** (`{}` with an empty or
  unreadable `data`), is
  `{:error, {:order_unconfirmed, client_order_id, :unexpected_response_shape}}` - the same
  shape a timeout gets, with the id this package sent, because the order may be live. Use
  `get_order/3` with that id to find out.

  **Only an outcome that may have reached the venue is wrapped.** Missing credentials, our
  own rate limiter refusing and a signing failure are decided before anything is sent and
  are the plain `{:error, reason}` (`{:missing_credentials, :webull}`, ...): there is no
  order to reconcile.

  ## The request is checked, in this order, before anything is signed

  A map (`{:invalid_order_request, r}`); no key the builder does not read
  (`{:unsupported_order_field, key}`); `:symbol` (`{:invalid_symbol, v}`); `:side`, `:buy`
  or `:sell` as an atom or text in any case (`{:missing_field, :side}` when absent,
  `{:invalid_side, v}` otherwise - **`:short` is refused**,
  `capabilities/0` says `supports_short_selling: false`); `:order_type` and
  `:time_in_force`, **both required and never defaulted** (`{:missing_field, key}`; a type
  the instrument does not use is `{:unsupported_order_type, type}`, a duration it does not
  serve for the type `{:unsupported_order_combination, type, tif}`); **with the duration, a
  GTD order's `:expire_date`** (`{:missing_field, :expire_date}`; on any other duration
  `{:unexpected_field, :expire_date}`); the size (`{:missing_field, :quantity}` when
  neither `:quantity` nor `:amount` is given, `{:unexpected_field, :amount}` when both are
  or when a stop-limit order is sized in cash, `{:invalid_quantity, v}`,
  `{:invalid_amount, v}` - a float is refused, it has lost digits); the price fields
  (`{:unexpected_field, key}` for one the type does not use, `{:missing_field, key}` for one
  it needs, `{:invalid_price, v}`, `{:invalid_stop_price, v}`,
  `{:invalid_trailing_stop_step, v}`); `:client_order_id`
  (`{:invalid_client_order_id, v}`, 32 characters at most); then the account option
  (`{:missing_option, :account_id}`) and the credentials.
  """
  @spec place_order(map(), term(), keyword()) ::
          {:ok, Order.t()} | {:error, term()} | {:refused, term()}
  def place_order(credentials, request, opts) do
    with {:ok, order_type, tif, leaf} <- checked_order(request),
         {:ok, account_id} <- account_id(opts) do
      client_order_id = client_order_id(request)

      body = %{
        "account_id" => account_id,
        "new_orders" => [Map.put(leaf, "client_order_id", client_order_id)]
      }

      case post_write("/trading/orders/place", body, credentials, opts) do
        {:ok, response} ->
          to_placed_order(response, request, order_type, tif, client_order_id)

        # **The id goes back with the failure - when the request may have been sent.** An
        # `{:error, _}` (a timeout, a 5xx) does not say whether the order landed, and a
        # generated id was returned only on success, so a caller left holding a possibly
        # live order had no way to look it up or cancel it. `get_order/3` with this id is
        # how to find out. An error decided BEFORE anything left (no credentials, our own
        # limiter refusing, a signing failure) sent nothing, so there is nothing to
        # reconcile and wrapping it would send the caller looking for an order that was
        # never placed: it stays a plain `{:error, reason}`.
        {:error, reason} ->
          if unsent?(reason, send_once(opts)),
            do: {:error, reason},
            else: {:error, {:order_unconfirmed, client_order_id, reason}}

        refused ->
          refused
      end
    end
  end

  @doc """
  Whether an `{:error, reason}` from a signed request was decided before anything was sent:
  missing or unusable credentials (`Auth.headers/2`), `Core.HttpClient`'s own limiter
  refusing (`"Throttled by our own rate limiter ..."` / `"Rate limiter unavailable"` /
  `:rate_limit_timeout` from a blocking limiter, bare or inside
  `{:exchange_error, provider, message}`), or the venue's own 429
  (`"Rate limited by the venue - retry after Ns"`): the venue documents it as "request
  rejected with no partial processing" (`rest-rate-limits.md`), and Core's `place_order/3`
  contract makes it the one 4xx that is a plain `{:error, reason}`.

  Such an outcome cannot have placed or changed anything, so `place_order/3` does not wrap
  it as `:order_unconfirmed`. Anything else (a transport error, a timeout, a 5xx, an
  undecodable body) may have reached the venue.
  """
  @spec unsent?(term()) :: boolean()
  def unsent?({:missing_credentials, _venue}), do: true
  def unsent?({:invalid_credentials, _venue}), do: true
  def unsent?({:exchange_error, _venue, message}), do: unsent?(message)
  def unsent?(:rate_limit_timeout), do: true
  def unsent?("Throttled by our own rate limiter" <> _rest), do: true
  def unsent?("Rate limiter unavailable" <> _rest), do: true
  def unsent?("Rate limited by the venue" <> _rest), do: true
  def unsent?(_possibly_sent), do: false

  @doc """
  `unsent?/1` for a request sent under `opts`: a refusal by our own limiter proves nothing
  was sent only when the request had a single attempt.

  `Core.HttpClient` asks the limiter again before every retry. With `retry_attempts: 3` a
  limiter refusal on the second attempt follows a first attempt that was sent and may have
  landed, so reporting it as the plain `{:error, reason}` would send the caller to place the
  order again. `Rest` sends every write once (`retry_attempts: 1`, always), so a limiter
  refusal is always a refusal before the first attempt. Missing or unusable credentials are
  decided before the first attempt whatever `retry_attempts` is. A `:retry_attempts` that is not an
  integer is treated as retrying (the conservative answer).
  """
  @spec unsent?(term(), keyword()) :: boolean()
  def unsent?(reason, opts) do
    unsent?(reason) and (not limiter_refusal?(reason) or single_attempt?(opts))
  end

  defp limiter_refusal?({:exchange_error, _venue, message}), do: limiter_refusal?(message)
  defp limiter_refusal?(:rate_limit_timeout), do: true
  defp limiter_refusal?("Throttled by our own rate limiter" <> _rest), do: true
  defp limiter_refusal?("Rate limiter unavailable" <> _rest), do: true
  defp limiter_refusal?("Rate limited by the venue" <> _rest), do: true
  defp limiter_refusal?(_other), do: false

  defp single_attempt?(opts) do
    case Keyword.get(opts, :retry_attempts, 1) do
      attempts when is_integer(attempts) -> attempts <= 1
      _other -> false
    end
  end

  @doc """
  Places several orders in one request — `POST /trading/orders/batch-place`.

  **Not `place_order/3` in a loop.** The venue accepts the batch as one request, and a
  caller that looped would be reconciling N outcomes instead of reading one response.

  **The venue's limits, enforced here rather than discovered.** A maximum of **50** orders
  per request, and **equities only** — `docs/reference/webull/batch-orders.md` quotes the
  page verbatim for both. A batch over the cap is refused before it is sent rather than
  split, because splitting turns one request into several and undoes the only reason to
  call this. An order whose instrument type is not equity is refused by index, so a caller
  knows which one.

  **The vendor also says this is not available to every client.** A refusal here can mean
  the account is not entitled rather than that the batch was wrong, and the venue's own
  message is carried through unchanged for that reason.

  A missing `:symbol` or `:side`, or a `LIMIT` order with no `:price`, is refused by index as
  `{:batch_order_rejected, index, {:missing_field, field}}` (an absent `:symbol` is
  `{:invalid_symbol, nil}`, a bad one `{:invalid_symbol, v}`; an absent `:side` is
  `{:missing_field, :side}`, a bad one `{:invalid_side, v}`) before anything is sent. Neither
  `:quantity` nor `:amount` is `{:missing_field, :quantity}`, and `:amount` at all is
  `{:unexpected_field, :amount}` (the batch endpoint takes `QTY` only). A key the batch
  builder does not read is `{:unsupported_order_field, key}`, and a `:price` on a market entry is
  `{:unexpected_field, :price}`, each by index.

  A batch that may have been placed - a timeout, a 5xx, or a 2xx with no readable rows - is
  `{:error, {:order_unconfirmed, ids, reason}}`, `ids` being every `client_order_id` sent, in
  order (generated ones included). Decided-before-sending failures (`unsent?/2`) stay plain.

  Each order takes the same shape `place_order/3` builds, and `client_order_id` is generated
  per order where the caller did not supply one — the venue requires one per order and
  requires them unique per account.

  Returns the venue's own rows, one per order, unnormalised: the venue validates per order
  and a batch where three of five were accepted is the normal shape, not the exception.
  """
  @spec place_orders(map(), [map()] | term(), keyword()) ::
          {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def place_orders(credentials, requests, opts) do
    with {:ok, account_id} <- account_id(opts),
         :ok <- batch_size(requests),
         {:ok, orders} <- batch_orders(requests) do
      body = %{"account_id" => account_id, "batch_orders" => orders}

      ids = Enum.map(orders, &Map.fetch!(&1, "client_order_id"))

      case post_write("/trading/orders/batch-place", body, credentials, opts) do
        {:ok, response} ->
          batch_result(batch_rows(response), ids)

        {:error, reason} ->
          if unsent?(reason, send_once(opts)),
            do: {:error, reason},
            else: {:error, {:order_unconfirmed, ids, reason}}

        refused ->
          refused
      end
    end
  end

  # **A batch that may have been placed is never a bare error.** A timeout, a 5xx, or a 2xx
  # whose envelope holds no readable rows does not say that none of the orders landed, and the
  # ids this package generated per order were otherwise lost with the failure, so a caller
  # retrying the batch would place every order again under new ids. The ids go back as a list
  # in `{:order_unconfirmed, ids, reason}` (`place_order/3`'s tag, with the ids of the whole
  # batch in order); `get_order/3` per id settles each.
  defp batch_result({:ok, [_row | _rest]} = result, _ids), do: result

  defp batch_result({:ok, []}, ids),
    do: {:error, {:order_unconfirmed, ids, :unexpected_response_shape}}

  defp batch_result({:error, reason}, ids), do: {:error, {:order_unconfirmed, ids, reason}}

  # `order-batch-place.md:266-328` documents this endpoint's OWN response envelope —
  # `{total, success, failed, batch_orders: [...]}` — not the generic `{"data": [...]}`
  # shape `rows/1` reads everywhere else. Calling `rows/1` directly on it fell through to
  # its bare-object clause, which wrapped the WHOLE envelope as a single one-element list:
  # a batch of N orders always answered with exactly one "row" — the envelope itself,
  # holding `total`/`success`/`failed` — never the N per-order results this function's own
  # moduledoc promises ("Returns the venue's own rows, one per order").
  #
  # `{:ok, [map()]}`: a row that is not an object cannot be a per-order result. It is an
  # unreadable reply, which `batch_result/2` answers `:order_unconfirmed` (the batch may be live).
  defp batch_rows(%{"batch_orders" => rows}) when is_list(rows), do: object_rows(rows)

  defp batch_rows(other) do
    with {:ok, listed} <- rows(other), do: object_rows(listed)
  end

  @batch_limit 50

  defp batch_size([]), do: {:error, :empty_batch}

  defp batch_size(requests) when length(requests) > @batch_limit,
    do: {:error, {:batch_too_large, length(requests), @batch_limit}}

  # Not a list (`nil`, a map): `length/1` in the guard above is false for it, and the
  # `Enum.with_index/1` that follows raised out of the caller's process on a money write.
  defp batch_size(requests) when not is_list(requests), do: {:error, :invalid_batch}

  # An improper list (`[order | :tail]`) is a list to `is_list/1` but `length/1` raises on it,
  # and in the guard above that only made the clause not match, so the batch was waved through
  # to `Enum.with_index/1`, which raised in the caller's process on a money write. Refused as
  # the non-list it is, by the same walk `invalid_symbols/2` uses for symbol lists.
  defp batch_size(requests) do
    if proper_list?(requests), do: :ok, else: {:error, :invalid_batch}
  end

  defp proper_list?([]), do: true
  defp proper_list?([_head | tail]), do: proper_list?(tail)
  defp proper_list?(_improper_tail), do: false

  @doc """
  Whether `requests` is a batch `place_orders/3` would send: its size and every entry
  against the batch endpoint's own schema, refused by index. The same checks
  `place_orders/3` makes before it signs anything, for `DpExchange.Webull.Fake` to answer
  exactly as the real path does — a fake that accepted a `STOP_LOSS` or price-less `LIMIT`
  entry would let a consumer ship a batch the venue path refuses.
  """
  @spec validate_batch_orders([map()] | term()) :: :ok | {:error, term()}
  def validate_batch_orders(requests) do
    with :ok <- batch_size(requests),
         {:ok, _orders} <- batch_orders(requests),
         do: :ok
  end

  defp batch_orders(requests) do
    requests
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {request, index}, {:ok, acc} ->
      case batch_order(request, index) do
        {:ok, order} -> {:cont, {:ok, [order | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, orders} -> orders |> Enum.reverse() |> unique_batch_ids()
      error -> error
    end
  end

  # **A `client_order_id` is unique per account, so two entries of one batch cannot share
  # one.** The second used to go to the venue as sent (and, in the fake, overwrite the first
  # order's remembered copy); it is refused here by the index of the repeat, before anything
  # is signed. Ids the package generated are unique by construction.
  defp unique_batch_ids(orders) do
    orders
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, MapSet.new()}, fn {order, index}, {:ok, seen} ->
      id = Map.fetch!(order, "client_order_id")

      if MapSet.member?(seen, id),
        do: {:halt, {:error, {:batch_order_rejected, index, {:duplicate_client_order_id, id}}}},
        else: {:cont, {:ok, MapSet.put(seen, id)}}
    end)
    |> case do
      {:ok, _seen} -> {:ok, orders}
      error -> error
    end
  end

  # Equities only, by the venue's own note. A crypto order in a batch is refused by index so
  # a caller knows which of fifty it was, rather than reading a venue message about a field.
  defp batch_order(request, index) when not is_map(request),
    do: {:error, {:batch_order_rejected, index, :not_an_order}}

  defp batch_order(request, index) do
    case Map.get(request, :instrument_type, :equity) do
      :equity ->
        case batch_leaf(request) do
          {:ok, leaf} -> {:ok, Map.put(leaf, "client_order_id", client_order_id(request))}
          {:error, reason} -> {:error, {:batch_order_rejected, index, reason}}
        end

      other ->
        {:error, {:batch_instrument_not_supported, index, other}}
    end
  end

  @batch_order_types [:market, :limit]

  # Every key `checked_order/1` and `order_leaf/3` read. Any other key is refused by name
  # rather than ignored: `post_only: true` or `reduce_only: true` is a promise the venue
  # would never be told about.
  @order_request_keys [
    :symbol,
    :side,
    :order_type,
    :time_in_force,
    :quantity,
    :amount,
    :price,
    :stop_price,
    :trailing_stop_step,
    :trailing_type,
    :client_order_id,
    :instrument_type,
    :expire_date,
    :event_outcome,
    :support_trading_session
  ]

  # The batch builder reads fewer: no stop, trail, expiry or event outcome.
  @batch_request_keys [
    :symbol,
    :side,
    :order_type,
    :time_in_force,
    :quantity,
    :amount,
    :price,
    :client_order_id,
    :instrument_type,
    :support_trading_session
  ]

  # **The batch endpoint's own schema, narrower than `place_order/3`'s.**
  # `order-batch-place.md:157-244` requires `order_type` MARKET or LIMIT — not `STOP_LOSS`,
  # `STOP_LOSS_LIMIT` or `TRAILING_STOP_LOSS`, all real for the single-order endpoint —
  # `time_in_force` DAY (its own enum has exactly one member), `entrust_type` QTY (no
  # `AMOUNT` here at all) and `support_trading_session`, which the single-order schema
  # leaves optional but this one lists as required. Checked against that schema rather
  # than discovered from a venue rejection: `order_leaf/3`, which `place_order/3` uses,
  # builds a wider order than this endpoint accepts, so a batch entry is built separately
  # here instead of reusing it.
  #
  # The identity and price checks are the same ones `order_leaf/3` makes. Without them a
  # batch entry with no `:side` or `:symbol` raised `KeyError` in the caller's process on a
  # money-moving write, and a `LIMIT` entry with no `:price` was sent with no `limit_price`
  # at all, one entry of up to fifty failing at the venue instead of by index here.
  defp batch_leaf(request) do
    with :ok <- known_order_keys(request, @batch_request_keys),
         :ok <- required_order_identity(request),
         {:ok, order_type} <- batch_order_type(request),
         :ok <- unexpected_price_fields(request, order_type),
         :ok <- required_order_prices(request, order_type),
         :ok <- positive_numbers(request, [:quantity, :amount]),
         :ok <- positive_numbers(request, sent_price_fields(order_type)),
         :ok <- batch_time_in_force(request),
         {:ok, sizing} <- batch_entrust(request),
         {:ok, support_trading_session} <- batch_support_trading_session(request) do
      leaf =
        %{
          "combo_type" => "NORMAL",
          "instrument_type" => "EQUITY",
          "market" => "US",
          "symbol" => order_symbol(request, :equity),
          "side" => request |> Map.fetch!(:side) |> to_string() |> String.upcase(),
          "order_type" => order_type,
          "time_in_force" => "DAY",
          "support_trading_session" => support_trading_session
        }
        |> Map.merge(sizing)
        |> put_number("limit_price", price_for(request, order_type))

      {:ok, leaf}
    end
  end

  # The batch schema's `time_in_force` enum has exactly one member, `DAY`
  # (order-batch-place.md:236-243). **It is still required per row** (`{:missing_field,
  # :time_in_force}`): a duration the caller never named is not defaulted, even to the one
  # legal value, the same as on `place_order/3`. A caller who asked for something else
  # (`:gtc`, `:fok`, …) is refused rather than silently switched to `DAY`: sending the one
  # legal value regardless of what was asked for would be exactly the substitution
  # `entrust/3` above and `CLAUDE.md`'s fail-closed rule both refuse to make.
  defp batch_time_in_force(request) do
    case Map.get(request, :time_in_force) do
      :day -> :ok
      nil -> {:error, {:missing_field, :time_in_force}}
      other -> {:error, {:unsupported_batch_time_in_force, other}}
    end
  end

  # Required per row, never defaulted: an absent type used to become a limit order.
  defp batch_order_type(request) do
    case Map.get(request, :order_type) do
      nil -> {:error, {:missing_field, :order_type}}
      type when type in @batch_order_types -> {:ok, order_type_name(type)}
      other -> {:error, {:unsupported_batch_order_type, other}}
    end
  end

  # **`QTY` only.** The batch schema's `entrust_type` enum has one member
  # (order-batch-place.md:187-194); `AMOUNT` sizing, real for `place_order/3`, is not
  # offered on this endpoint at all. A caller who supplied `:amount` is refused rather
  # than silently sized by quantity instead.
  defp batch_entrust(request) do
    case {Map.get(request, :quantity), Map.get(request, :amount)} do
      {nil, nil} -> {:error, {:missing_field, :quantity}}
      {quantity, nil} -> {:ok, %{"entrust_type" => "QTY", "quantity" => wire_number(quantity)}}
      {_quantity, _amount} -> {:error, {:unexpected_field, :amount}}
    end
  end

  @support_trading_sessions ~w(ALL CORE NIGHT)

  # **No documented default.** `order-batch-place.md:195-199` lists `support_trading_session`
  # required, with three enum members, and states none of them as what the venue applies
  # when it is absent — unlike `time_in_force` above, whose enum has only the one legal
  # value `DAY`. A caller who does not say which session is refused rather than a guess at
  # `CORE`.
  defp batch_support_trading_session(request) do
    case Map.get(request, :support_trading_session) do
      nil ->
        {:error, {:missing_field, :support_trading_session}}

      session ->
        wire = session |> to_string() |> String.upcase()

        if wire in @support_trading_sessions do
          {:ok, wire}
        else
          {:error, {:unsupported_support_trading_session, session}}
        end
    end
  end

  defp account_id(opts), do: validate_account(opts)

  @doc """
  The account every account and order call is made against: `opts[:account_id]`, which must
  be non-empty text.

  Anything else (absent, `nil`, `false`, a number, `""`, whitespace only) is
  `{:error, {:missing_option, :account_id}}` - the family's answer for a missing account
  option, replacing the bare atom `:account_id_required`. A number went into a JSON body as
  a number and a query as its `to_string/1`, where the venue types the account id as a
  string. The check each account call makes, for `DpExchange.Webull.Fake` to refuse exactly
  what the real path refuses.
  """
  @spec validate_account(keyword()) ::
          {:ok, String.t()} | {:error, {:missing_option, :account_id}}
  def validate_account(opts) do
    case Keyword.get(opts, :account_id) do
      account_id when is_binary(account_id) ->
        if String.trim(account_id) == "",
          do: {:error, {:missing_option, :account_id}},
          else: {:ok, account_id}

      _missing ->
        {:error, {:missing_option, :account_id}}
    end
  end

  # **The venue's matrix is per instrument type, and the differences are not cosmetic.**
  # Written out so a pair outside a type's list cannot be sent, and so the reason a caller
  # gets names both halves.
  #
  # Read from the vendor's order reference, 2026-09-01:
  #
  #   CRYPTO   MARKET/IOC, LIMIT/DAY|GTC, STOP_LOSS_LIMIT/DAY|GTC
  #   EQUITY   MARKET, LIMIT, STOP_LOSS, STOP_LOSS_LIMIT, TRAILING_STOP_LOSS × DAY|GTC
  #   OPTION   as EQUITY minus TRAILING_STOP_LOSS ("Options not supported")
  #   FUTURES  as OPTION; BUY and SELL only
  #   EVENT    LIMIT only, and DAY|GTC|IOC|GTD|FOK
  #
  # The institutional-only types (MARKET_ON_OPEN, MARKET_ON_CLOSE, LIMIT_ON_OPEN) are
  # absent deliberately: the vendor restricts them to institutional stock orders, and a
  # package that sent one for an ordinary account would get a refusal it could not explain.
  @order_type_names %{
    market: "MARKET",
    limit: "LIMIT",
    stop: "STOP_LOSS",
    stop_limit: "STOP_LOSS_LIMIT",
    trailing_stop: "TRAILING_STOP_LOSS"
  }

  @tif_names %{day: "DAY", gtc: "GTC", ioc: "IOC", gtd: "GTD", fok: "FOK"}

  @doc """
  The venue's wire name for an `order_type` atom this package encodes, or `nil` for an
  atom this package does not send.

  Exposed so the fake can round-trip a placed order through the same encode/decode this
  package uses on a real order, rather than echoing the caller's atom back unchanged.
  """
  @spec order_type_name(atom() | nil) :: String.t() | nil
  def order_type_name(nil), do: nil
  def order_type_name(order_type), do: Map.get(@order_type_names, order_type)

  @doc """
  The venue's wire name for a `time_in_force` atom this package encodes, or `nil` for an
  atom this package does not send.

  Exposed for the same reason as `order_type_name/1`.
  """
  @spec tif_name(atom() | nil) :: String.t() | nil
  def tif_name(nil), do: nil
  def tif_name(tif), do: Map.get(@tif_names, tif)

  @equity_types [:market, :limit, :stop, :stop_limit, :trailing_stop]
  @option_types [:market, :limit, :stop, :stop_limit]
  @stock_tifs [:day, :gtc]
  @event_tifs [:day, :gtc, :ioc, :gtd, :fok]

  @combinations %{
    crypto: [
      {:market, :ioc},
      {:limit, :day},
      {:limit, :gtc},
      {:stop_limit, :day},
      {:stop_limit, :gtc}
    ],
    equity: for(type <- @equity_types, tif <- @stock_tifs, do: {type, tif}),
    option: for(type <- @option_types, tif <- @stock_tifs, do: {type, tif}),
    futures: for(type <- @option_types, tif <- @stock_tifs, do: {type, tif}),
    event: for(tif <- @event_tifs, do: {:limit, tif})
  }

  @instrument_names %{
    crypto: "CRYPTO",
    equity: "EQUITY",
    option: "OPTION",
    futures: "FUTURES",
    event: "EVENT"
  }

  @doc """
  Every instrument type this package can build an order for, as the venue names them.

  Exposed because `capabilities/0` declares from it, and a declaration that can disagree
  with the builder it describes is a declaration worth nothing.
  """
  @spec order_instrument_types() :: [atom()]
  def order_instrument_types, do: @combinations |> Map.keys() |> Enum.sort()

  # A request that does not say is crypto, which is what this package served before the
  # instrument types widened. Changing that default would silently re-route existing
  # callers' orders onto a different market.
  defp instrument_type(request), do: Map.get(request, :instrument_type, :crypto)

  # **Nothing about the order type or its duration is defaulted.** An absent `:order_type`
  # used to become a limit order and an absent `:time_in_force` a GTC one, so a request that
  # forgot to say it wanted a market order was sent as a limit order, and one that forgot
  # its duration rested on the book until cancelled. Every value stays plausible and only
  # the meaning is wrong; the caller is told which field is missing instead.
  #
  # Order of the answers: a type no combination of the instrument uses is
  # `{:unsupported_order_type, type}`; a duration the instrument does not serve for that
  # type is `{:unsupported_order_combination, type, tif}`.
  defp combination(request) do
    with {:ok, allowed} <- allowed_combinations(instrument_type(request)),
         {:ok, type} <- required_field(request, :order_type),
         :ok <- served_order_type(allowed, type),
         {:ok, tif} <- required_field(request, :time_in_force) do
      if {type, tif} in allowed do
        {:ok, @order_type_names[type], @tif_names[tif]}
      else
        {:error, {:unsupported_order_combination, type, tif}}
      end
    end
  end

  defp required_field(request, field) do
    case Map.get(request, field) do
      nil -> {:error, {:missing_field, field}}
      found -> {:ok, found}
    end
  end

  defp served_order_type(allowed, type) do
    if Enum.any?(allowed, fn {served, _tif} -> served == type end),
      do: :ok,
      else: {:error, {:unsupported_order_type, type}}
  end

  defp known_order_keys(request, allowed) do
    case request |> Map.keys() |> Enum.sort() |> Enum.find(&(&1 not in allowed)) do
      nil -> :ok
      key -> {:error, {:unsupported_order_field, key}}
    end
  end

  # The order of the checks is the family's: request is a map, unknown keys, symbol, side,
  # order type, duration and combination, quantity, price fields, client order id (all inside
  # `order_leaf/3`). The account option and the credentials come after, in the callers.
  defp checked_order(request) when is_map(request) do
    with :ok <- known_order_keys(request, @order_request_keys),
         :ok <- valid_order_symbol(Map.get(request, :symbol)),
         :ok <- valid_order_side(Map.get(request, :side)),
         {:ok, order_type, tif} <- combination(request),
         # The expiry belongs to the time-in-force step (DV10): a GTD order without its date
         # is refused here, before the size and every price field.
         {:ok, expire} <- expire_date(request, tif),
         {:ok, leaf} <- order_leaf(request, order_type, tif, expire) do
      {:ok, order_type, tif, leaf}
    end
  end

  defp checked_order(request), do: {:error, {:invalid_order_request, request}}

  defp allowed_combinations(instrument) do
    case Map.fetch(@combinations, instrument) do
      {:ok, allowed} -> {:ok, allowed}
      :error -> {:error, {:unsupported_instrument_type, instrument}}
    end
  end

  # `common-order-place.md` (`entrust_type`): "When placing Event Contract orders using
  # AMOUNT, only BUY orders are supported (side=BUY), and time_in_force must be FOK." A rule
  # the page states is enforced before the request, not left to the venue: a SELL is
  # `{:invalid_side, side}`, any other duration is
  # `{:unsupported_order_combination, :amount, time_in_force}`.
  defp event_amount_rules("AMOUNT", :event, request) do
    side = Map.get(request, :side)
    tif = Map.get(request, :time_in_force)

    cond do
      side |> to_string() |> String.downcase() != "buy" -> {:error, {:invalid_side, side}}
      tif != :fok -> {:error, {:unsupported_order_combination, :amount, tif}}
      true -> :ok
    end
  end

  defp event_amount_rules(_entrust, _instrument, _request), do: :ok

  defp order_leaf(request, order_type, tif, expire) do
    instrument = instrument_type(request)

    with :ok <- positive_numbers(request, [:quantity, :amount]),
         {:ok, entrust, sizing} <- entrust(request, order_type, instrument),
         :ok <- event_amount_rules(entrust, instrument, request),
         :ok <- unexpected_price_fields(request, order_type),
         :ok <- required_order_prices(request, order_type),
         {:ok, trailing} <- checked_prices(request, order_type),
         :ok <- valid_client_order_id(Map.get(request, :client_order_id)),
         {:ok, outcome} <- event_outcome(request),
         {:ok, session} <- support_trading_session(request) do
      leaf =
        %{
          "combo_type" => "NORMAL",
          "instrument_type" => Map.fetch!(@instrument_names, instrument),
          "market" => "US",
          "symbol" => order_symbol(request, instrument),
          "side" => request |> Map.fetch!(:side) |> to_string() |> String.upcase(),
          "order_type" => order_type,
          "time_in_force" => tif,
          "entrust_type" => entrust
        }
        |> Map.merge(sizing)
        |> put_number("limit_price", price_for(request, order_type))
        |> put_number("stop_price", stop_for(request, order_type))
        |> put_number("trailing_stop_step", trailing_stop_step_for(request, order_type))
        |> put_present("trailing_type", trailing)
        |> put_present("expire_date", expire)
        |> put_present("event_outcome", outcome)
        |> put_present("support_trading_session", session)

      {:ok, leaf}
    end
  end

  # `common-order-place.md`'s own "Equity" example (identically `common-order-preview.md`'s)
  # carries `support_trading_session` as an ordinary field on an ordinary order — a real,
  # documented, OPTIONAL field `order_leaf/3` (shared by `preview_order/3` and
  # `place_order/3`) never read at all, so a caller asking for an extended-hours session
  # had it silently dropped rather than sent. Unlike `batch_support_trading_session/1`
  # (`order-batch-place.md`'s own schema marks it required, no default), an absent value
  # here is left off the wire rather than refused; a value that does not match the venue's
  # three-member enum is refused rather than sent unchecked.
  defp support_trading_session(request) do
    case Map.get(request, :support_trading_session) do
      nil ->
        {:ok, nil}

      session ->
        wire = session |> to_string() |> String.upcase()

        if wire in @support_trading_sessions do
          {:ok, wire}
        else
          {:error, {:unsupported_support_trading_session, session}}
        end
    end
  end

  # **Only crypto symbols go through the canonical mapper.** An equity ticker is already the
  # venue's own identifier — `AAPL` is `AAPL` — and pushing it through a pair splitter that
  # looks for a quote currency would mangle any ticker ending in one of them.
  defp order_symbol(request, :crypto),
    do: SymbolFormat.to_exchange_symbol(Map.fetch!(request, :symbol))

  defp order_symbol(request, _instrument), do: Map.fetch!(request, :symbol)

  # GTD is the only time-in-force with a date, and the venue requires one with it. Missing
  # is left missing rather than defaulted: a date chosen here would be an expiry the caller
  # never asked for.
  #
  # **What is sent is a `yyyy-MM-dd` date, or the order is refused.** The page types the field
  # `string`, "format (UTC). The value must be in yyyy-MM-dd format"
  # (`common-order-place.md`). It used to go to the wire as whatever the caller held, so a
  # `DateTime` (JSON-encoded as a full timestamp), `"20261201"`, `"2026-12-01T00:00:00Z"` or a
  # number reached the venue as a refusal about nothing the caller wrote. A `Date` is written
  # in that form; a string must already be one real date in it.
  #
  # **A GTD order with no expiry is refused**, `{:missing_field, :expire_date}`: it used to
  # be sent without one and left to the venue. The converse is refused too - an
  # `:expire_date` on any other duration was read only for GTD and silently dropped, so a
  # caller who set one believed the order would lapse on that day.
  defp expire_date(request, "GTD") do
    case Map.get(request, :expire_date) do
      nil -> {:error, {:missing_field, :expire_date}}
      %Date{} = date -> {:ok, Date.to_iso8601(date)}
      text when is_binary(text) -> expire_date_text(text)
      other -> {:error, {:invalid_expire_date, other}}
    end
  end

  defp expire_date(request, _tif) do
    case Map.get(request, :expire_date) do
      nil -> {:ok, nil}
      _given -> {:error, {:unexpected_field, :expire_date}}
    end
  end

  defp expire_date_text(text) do
    with {:ok, date} <- Date.from_iso8601(text),
         true <- Date.to_iso8601(date) == text do
      {:ok, text}
    else
      _not_a_date -> {:error, {:invalid_expire_date, text}}
    end
  end

  # `event_outcome` is `yes` or `no` on the page (`common-order-place.md`: "only applicable to
  # event orders"), the two opposite exposures to one market. It went to the wire as whatever
  # the caller held (`to_string/1` of an atom, a map raising), so `:maybe` or `"YES "` was a
  # refusal the caller could not trace, on an order that moves money. Written lower-case, the
  # form the page gives; anything but those two is refused before a request. Absent stays
  # absent: the page does not mark the field required.
  defp event_outcome(request) do
    case Map.get(request, :event_outcome) do
      nil -> {:ok, nil}
      outcome when outcome in [:yes, :no] -> {:ok, Atom.to_string(outcome)}
      outcome when outcome in ["yes", "no"] -> {:ok, outcome}
      other -> {:error, {:invalid_event_outcome, other}}
    end
  end

  # `QTY` sizes in units, `AMOUNT` in cash. They are different orders and the venue names
  # them separately; a caller that gave neither gets an error rather than a default, and a
  # caller that gave both is asking for two things at once.
  #
  # **The size fields are `quantity` and `total_cash_amount`, never `qty`/`amount`.**
  # `common-order-place.md:287,292` names both: `quantity` ("Transaction quantity...") is
  # the field for QTY-entrust orders and `total_cash_amount` ("The total order amount...")
  # is the field for AMOUNT-entrust ones. No page in `docs/reference/webull/` defines a
  # `qty` or an `amount` field — those were this package's own invented names, and the
  # venue does not read them: every order this package placed, previewed or batched
  # carried an `entrust_type` but no size the venue could act on, which is the "every value
  # stays plausible and only the meaning is wrong" failure shape this family's own
  # `CLAUDE.md` names, since `entrust_type` alone is a well-formed field the venue accepts.
  defp entrust(request, order_type, instrument) do
    quantity = Map.get(request, :quantity)
    amount = Map.get(request, :amount)

    case {quantity, amount} do
      {nil, nil} ->
        {:error, {:missing_field, :quantity}}

      {quantity, nil} ->
        {:ok, "QTY", %{"quantity" => wire_number(quantity)}}

      {nil, amount} ->
        amount_entrust(order_type, instrument, amount)

      # Both sizings: the cash one is the unexpected one (DV4), as Core's `place_order/3`
      # doc has it for `:quote_size` - this venue's key for it is `:amount`.
      {_quantity, _amount} ->
        {:error, {:unexpected_field, :amount}}
    end
  end

  # **`AMOUNT` is not available everywhere.** The vendor states it for U.S. stock and event
  # contract trading; futures and options take `QTY` only. Refusing here names the reason,
  # where sending it would return a business error about a field the caller thought was
  # supported.
  defp amount_entrust(_order_type, instrument, _amount) when instrument in [:futures, :option],
    do: {:error, {:cash_sizing_not_supported, instrument}}

  # The venue restricts `AMOUNT` on a stop-limit sell to `QTY` only. Rather than encode the
  # side rule twice, cash sizing is refused for stop-limit outright: a caller sizing a stop
  # in cash is asking for something the venue will not do on one side of the book, and
  # accepting it on the other invites a surprise later.
  defp amount_entrust("STOP_LOSS_LIMIT", _instrument, _amount),
    do: {:error, {:unexpected_field, :amount}}

  defp amount_entrust(_order_type, _instrument, amount),
    do: {:ok, "AMOUNT", %{"total_cash_amount" => wire_number(amount)}}

  # Only the two order types the venue documents `limit_price` for actually take it — see
  # the field table on `replace_order/4`'s own moduledoc, read from the same vendor
  # reference: `LIMIT` and `STOP_LOSS_LIMIT`. A plain `STOP_LOSS` has no limit leg at all,
  # only a trigger, and sending one anyway would assert a field the venue's schema for that
  # order type does not have — a caller building a stop request from a limit-order template
  # (leaving `:price` set) must not have it silently escape onto the wire on the wrong order
  # type.
  # A limit with no limit price, or a stop with no trigger, was sent with the field simply
  # absent, because `put_present/3` skips `nil`. The venue refuses it, but only after the
  # request; refused here it names the field, and spends no write.
  # `Map.fetch!/2` on `:side` raised `KeyError` in the caller's process, on an order write.
  # (The batch endpoint's identity check; `checked_order/1` makes the same three for a
  # single order, in the same order.)
  defp required_order_identity(request) do
    with :ok <- valid_order_symbol(Map.get(request, :symbol)),
         :ok <- valid_order_side(Map.get(request, :side)),
         do: valid_client_order_id(Map.get(request, :client_order_id))
  end

  # A symbol that is not text raised `FunctionClauseError` in `SymbolFormat` (crypto) or went
  # to the wire as `to_string/1` of whatever it was; an empty or whitespace-only one is no
  # product. A missing symbol is the same `{:invalid_symbol, nil}`.
  defp valid_order_symbol(symbol) when is_binary(symbol) do
    if String.trim(symbol) == "", do: {:error, {:invalid_symbol, symbol}}, else: :ok
  end

  defp valid_order_symbol(symbol), do: {:error, {:invalid_symbol, symbol}}

  # `common-order-place.md`'s `side` is BUY, SELL, or SHORT (options only, by its note), and
  # this package's own `capabilities/0` says `supports_short_selling: false`. **`:short` is
  # refused here** - `{:invalid_side, :short}` - so the declaration and the builder agree: it
  # used to be sent on every instrument and come back as an `Order` with `side: nil`.
  # `:buy` and `:sell`, or `"buy"` and `"sell"` in any case, are accepted; any other value
  # (`:bid`, `:long`, `nil`) would have been upper-cased and sent, failing at the venue after
  # the request and naming nothing the caller wrote.
  #
  # **An absent side is `{:missing_field, :side}`, not `{:invalid_side, nil}`** (DV2): the
  # caller did not write a wrong side, they wrote none. Every other bad value stays
  # `{:invalid_side, value}`.
  defp valid_order_side(nil), do: {:error, {:missing_field, :side}}
  defp valid_order_side(side) when side in [:buy, :sell], do: :ok

  defp valid_order_side(side) when is_binary(side) do
    if String.downcase(side) in ["buy", "sell"], do: :ok, else: {:error, {:invalid_side, side}}
  end

  defp valid_order_side(side), do: {:error, {:invalid_side, side}}

  # `common-order-place.md:175`: the caller's own id is "Maximum length is 32 characters".
  # One longer (or empty, or not text) was sent as it stood and failed at the venue after the
  # request; refused here it names the id and spends no write. Absent is fine: one is
  # generated.
  defp valid_client_order_id(nil), do: :ok

  defp valid_client_order_id(id) when is_binary(id) do
    if String.trim(id) != "" and String.length(id) <= 32,
      do: :ok,
      else: {:error, {:invalid_client_order_id, id}}
  end

  defp valid_client_order_id(id), do: {:error, {:invalid_client_order_id, id}}

  @doc """
  Whether `request` is an order this package would send: the venue's combination matrix,
  sizing, and the prices its type requires. The same checks `place_order/3` makes before
  it signs anything, for `DpExchange.Webull.Fake` to answer exactly as the real path does.
  """
  @spec validate_order_request(term()) :: :ok | {:error, term()}
  def validate_order_request(request) do
    with {:ok, _order_type, _tif, _leaf} <- checked_order(request), do: :ok
  end

  @doc """
  Whether `request` is an order `preview_order/3` would price: every check
  `validate_order_request/1` makes FIRST, so a request `place_order/3` refuses is refused with
  the identical tuple (a non-map is `{:invalid_order_request, r}`, never a raise), and then an
  instrument the venue can preview (crypto is `{:preview_not_supported, :crypto}`). The same
  steps `preview_order/3` takes, for `DpExchange.Webull.Fake`.
  """
  @spec validate_preview_request(term()) :: :ok | {:error, term()}
  def validate_preview_request(request) do
    with :ok <- validate_order_request(request), do: previewable(instrument_type(request))
  end

  defp required_order_prices(request, order_type) do
    case Enum.find(sent_price_fields(order_type), &is_nil(Map.get(request, &1))) do
      nil -> :ok
      field -> {:error, {:missing_field, field}}
    end
  end

  # **A price the order type does not use is refused, not dropped.** `:price` on a market or
  # stop order, `:stop_price` on a limit or market one, `:trailing_stop_step` on anything but
  # a trailing stop were skipped by the builder, so the caller believed a protective stop or
  # a limit was in force on an order that went out without it.
  defp unexpected_price_fields(request, order_type) do
    unused = [:price, :stop_price, :trailing_stop_step] -- sent_price_fields(order_type)

    case Enum.find(unused, &(not is_nil(Map.get(request, &1)))) do
      nil -> :ok
      key -> {:error, {:unexpected_field, key}}
    end
  end

  # The request fields an order type puts on the wire as a price, which are the ones it
  # requires and the only ones checked (a `:price` left on a market order is never sent).
  defp sent_price_fields("LIMIT"), do: [:price]
  defp sent_price_fields("STOP_LOSS"), do: [:stop_price]
  defp sent_price_fields("STOP_LOSS_LIMIT"), do: [:price, :stop_price]
  defp sent_price_fields("TRAILING_STOP_LOSS"), do: [:trailing_stop_step]
  defp sent_price_fields(_other), do: []

  # The numbers an order carries must be positive, and a trailing stop must say what its step
  # is a step OF (`checked_trailing_type/2`). `{:ok, wire_trailing_type | nil}`.
  defp checked_prices(request, order_type) do
    with :ok <- positive_numbers(request, sent_price_fields(order_type)),
         {:ok, trailing} <- trailing_type(request, order_type),
         do: percentage_cap(request, trailing)
  end

  # **A trailing stop names what its step measures.** `common-order-place.md` documents
  # `trailing_type` (`AMOUNT` or `PERCENTAGE`) beside `trailing_stop_step`, and its trailing
  # example sends both: `"trailing_type": "AMOUNT", "trailing_stop_step": "1"`. The step alone
  # is `1` dollar or `100%`, and this package used to send the step alone, leaving the venue
  # to choose, with the same number meaning two very different protective stops. It is
  # required here, never defaulted, and refused on any other order type rather than dropped.
  @trailing_types %{
    :amount => "AMOUNT",
    :percentage => "PERCENTAGE",
    "AMOUNT" => "AMOUNT",
    "PERCENTAGE" => "PERCENTAGE"
  }

  defp trailing_type(request, "TRAILING_STOP_LOSS") do
    case Map.get(request, :trailing_type) do
      nil -> {:error, {:missing_field, :trailing_type}}
      type -> named_trailing_type(type)
    end
  end

  defp trailing_type(request, _order_type) do
    case Map.get(request, :trailing_type) do
      nil -> {:ok, nil}
      _given -> {:error, {:unexpected_field, :trailing_type}}
    end
  end

  defp named_trailing_type(type) do
    case Map.fetch(@trailing_types, type) do
      {:ok, wire} -> {:ok, wire}
      :error -> {:error, {:invalid_trailing_type, type}}
    end
  end

  # "If the tracking type is percentage, the tracking spread can not exceed 1, 0.01 means 1%."
  defp percentage_cap(request, "PERCENTAGE") do
    step = Map.get(request, :trailing_stop_step)

    case decimal(step) do
      %Decimal{} = parsed ->
        if Decimal.compare(parsed, 1) == :gt,
          do: {:error, {:invalid_trailing_stop_step, step}},
          else: {:ok, "PERCENTAGE"}

      nil ->
        {:ok, "PERCENTAGE"}
    end
  end

  defp percentage_cap(_request, trailing), do: {:ok, trailing}

  defp price_for(request, "LIMIT"), do: Map.get(request, :price)
  defp price_for(request, "STOP_LOSS_LIMIT"), do: Map.get(request, :price)
  defp price_for(_request, _order_type), do: nil

  # **`STOP_LOSS` needs its trigger exactly as much as `STOP_LOSS_LIMIT` does** — the field
  # table on `replace_order/4`'s own moduledoc names `stop_price` for both. Sending only the
  # limit-leg variant meant every plain stop-loss order this package built — a real,
  # `@combinations`-listed pair for equity, option and futures instruments — went out with
  # no trigger price at all: the single field that makes it a stop order.
  defp stop_for(request, "STOP_LOSS"), do: Map.get(request, :stop_price)
  defp stop_for(request, "STOP_LOSS_LIMIT"), do: Map.get(request, :stop_price)
  defp stop_for(_request, _order_type), do: nil

  # **Never sent at all before this fix.** `TRAILING_STOP_LOSS` is a real, `@combinations`-
  # listed order type for **equity** instruments — the venue's own matrix excludes it from
  # option and futures orders ("Options not supported"), which is why `@option_types` above
  # stops at `STOP_LOSS_LIMIT` — and the venue's own
  # `replace_order/4` field table (and `@amendable` below) names `trailing_stop_step` as the
  # one field that type takes. `order_leaf/3` built every other field for it — instrument,
  # side, sizing, time in force — and never this one, so every trailing-stop order this
  # package placed reached the venue with no trail distance configured at all. A caller who
  # supplied `:trailing_stop_step` had it silently discarded rather than reaching the wire.
  defp trailing_stop_step_for(request, "TRAILING_STOP_LOSS"),
    do: Map.get(request, :trailing_stop_step)

  defp trailing_stop_step_for(_request, _order_type), do: nil

  # 32 characters maximum, unique per account, and the venue's own reference for the order.
  defp client_order_id(request) do
    case Map.get(request, :client_order_id) do
      nil ->
        16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower) |> binary_part(0, 32)

      given ->
        given
    end
  end

  defp to_placed_order(response, request, order_type, tif, sent_id) do
    case first_row(response) do
      # A 2xx whose row names no order is not a placed order the caller can use: `id: nil`
      # cannot be cancelled or looked up, `get_order/3` already refuses the same shape, and
      # the order may well be live. The id this package sent goes back with the failure, as
      # it does for a timeout, so the caller can find out with `get_order/3`.
      {:ok, row} when is_map(row) ->
        # Text only: `Order.id` is a string, and a number or object the venue sent there is
        # not an id the cancel and read-back calls could take.
        #
        # **And it is the id this package SENT.** The venue echoes the `client_order_id` it was
        # given (`common-order-place.md`'s `OrderCommonWriteResult`), and `Order.id` is what
        # `cancel_order/3` and `get_order/3` take. A 2xx row naming a DIFFERENT id is not an
        # answer about our order, which may be live under the id we sent; it was returned as
        # the placed order, so a caller would cancel or read another one. It is unconfirmed,
        # with the id sent, like any acceptance that names nothing.
        case value(row, ["client_order_id"]) do
          ^sent_id ->
            {:ok, placed_order(sent_id, request, order_type, tif)}

          _absent_unreadable_or_other ->
            {:error, {:order_unconfirmed, sent_id, :unexpected_response_shape}}
        end

      # No row at all (`{}`, `{"data": []}`, an unreadable `data`): the request was sent and
      # the venue answered 2xx, so the order may be live. Not a bare shape error, which a
      # caller would retry into a duplicate.
      _no_row ->
        {:error, {:order_unconfirmed, sent_id, :unexpected_response_shape}}
    end
  end

  defp placed_order(id, request, order_type, tif) do
    %Order{
      # **The client_order_id, not the venue's order id.**
      #
      # Webull's whole order API is keyed on the client id: `/orders/cancel` takes it,
      # `/orders/get` takes it. Returning the venue's own `order_id` here would hand a
      # caller an identifier that round-trips nowhere — place, then cancel, and the
      # cancel fails on an id the venue does not accept.
      id: id,
      symbol: Map.fetch!(request, :symbol),
      # **The contract's own vocabulary and number type, not the caller's spelling.**
      # `Core.Types.Order.side` is `:buy | :sell` and its numbers are `Decimal`; the request
      # is validated for what the venue accepts (`"BUY"`, `:sell`, an integer or a numeric
      # string for a size), and this echoed it as typed, so a `"buy"` side or a `5`
      # quantity came back inside an `%Order{}` that `Order.new/1` would refuse. `:short` is
      # refused before this point, so the side is always `:buy` or `:sell`.
      side: request |> Map.fetch!(:side) |> to_string() |> String.upcase() |> side_atom(),
      order_type: order_type_atom(order_type),
      time_in_force: tif_atom(tif),
      quantity: decimal(Map.get(request, :quantity)),
      price: decimal(Map.get(request, :price)),
      # Echoed from the caller's own request, the same as `price` and `quantity`
      # above — the venue's `/orders/place` response carries only the accepted
      # `client_order_id` and nothing else to build an `Order` from. Missing before
      # this fix, the same gap `stop_for/2` had on the request side: a caller placing
      # a STOP_LOSS or STOP_LOSS_LIMIT order got `stop_price: nil` back from the very
      # call that set it.
      stop_price: decimal(Map.get(request, :stop_price)),
      status: :pending,
      provider: :webull
    }
  end

  @doc """
  A number a request carries as the `Decimal` an `Order` holds: a `Decimal`, an integer, a
  float or a numeric string; `nil` for anything else (and for `NaN`, `Infinity` and an
  absurd exponent). The decoder `place_order/3` and the venue's read-backs use, for
  `DpExchange.Webull.Fake` to amend an order exactly as the real read-back reads it.
  """
  @spec number_to_decimal(term()) :: Decimal.t() | nil
  def number_to_decimal(value), do: decimal(value)

  @doc """
  The `Order` `place_order/3` answers for `request` under `id`, built by the same code.

  For `DpExchange.Webull.Fake`, which used to echo the request as typed. The request must
  already have passed `validate_order_request/1`, which requires the type and the time in
  force: neither is defaulted.
  """
  @spec order_from_request(String.t(), map()) :: Order.t()
  def order_from_request(id, request) do
    placed_order(
      id,
      request,
      request |> Map.get(:order_type) |> order_type_name(),
      request |> Map.get(:time_in_force) |> tif_name()
    )
  end

  # Reverse of @order_type_names, derived from it rather than hand-duplicated so the two
  # can never drift apart again. Every value this package itself encodes (all five
  # declared order types) now decodes back; a value outside that set — genuinely unknown
  # to this package — still falls through to `nil` rather than a guessed atom.
  @order_type_atoms Map.new(@order_type_names, fn {atom, name} -> {name, atom} end)

  @doc """
  The `order_type` atom for a venue wire name this package decodes, or `nil` for a value
  this package does not recognise.

  Built from `@order_type_names` so every type this package's own `order_type_name/1` can
  produce decodes back to the same atom — a caller placing a stop or trailing-stop order,
  or reading one back, must not silently lose it to `nil`. A genuinely unknown venue value
  still yields `nil`; that is a table lookup missing, not a guess.
  """
  @spec order_type_atom(String.t() | nil) :: atom() | nil
  def order_type_atom(nil), do: nil
  def order_type_atom(name), do: Map.get(@order_type_atoms, name)

  # Reverse of @tif_names, same reasoning as @order_type_atoms above.
  @tif_atoms Map.new(@tif_names, fn {atom, name} -> {name, atom} end)

  @doc """
  The `time_in_force` atom for a venue wire name this package decodes, or `nil` for a
  value this package does not recognise. Same reasoning as `order_type_atom/1`.
  """
  @spec tif_atom(String.t() | nil) :: atom() | nil
  def tif_atom(nil), do: nil
  def tif_atom(name), do: Map.get(@tif_atoms, name)

  @doc """
  Cancels an order by its **client order id**.

  Webull's order API is keyed on the id the caller supplied, not the one the venue returned
  — `/orders/cancel` and `/orders/get` both take `client_order_id`. `Order.id` carries it
  for exactly that reason, so `place_order/3` then `cancel_order/3` round-trips.

  Requires `opts[:account_id]`, as every order call on this venue does.
  """
  @spec cancel_order(map(), term(), keyword()) ::
          {:ok, :cancelled} | {:error, term()} | {:refused, term()}
  def cancel_order(credentials, client_order_id, opts) do
    with :ok <- validate_order_id(client_order_id),
         {:ok, account_id} <- account_id(opts) do
      body = %{"account_id" => account_id, "client_order_id" => client_order_id}

      with {:ok, _response} <- post_write("/trading/orders/cancel", body, credentials, opts) do
        {:ok, :cancelled}
      end
    end
  end

  @doc """
  One order by its client order id.

  Requires `opts[:account_id]`.

  ## The response is a combo GROUP, not a flat order row

  `/trading/orders/get` returns `{client_order_id, combo_order_id, combo_type, orders:
  [...]}` (`order-detail.md:163,182`) — the group's OWN fields (side, status, quantity,
  price, …) live on each entry of `orders`, not on the envelope. Reading them off the
  group itself, which is what this did before, finds nothing at every key and returns an
  `Order` every field of which is `nil` except `provider` — a response that looks like an
  order and answers no question about one. See `to_order/1`.
  """
  @spec get_order(map(), term(), keyword()) ::
          {:ok, Order.t()} | {:error, term()} | {:refused, term()}
  def get_order(credentials, client_order_id, opts) do
    with :ok <- validate_order_id(client_order_id),
         {:ok, account_id} <- account_id(opts) do
      params = %{"account_id" => account_id, "client_order_id" => client_order_id}

      with {:ok, body} <- get("/trading/orders/get", params, credentials, opts),
           {:ok, group} <- first_row(body),
           # Refused rather than filled in from `client_order_id`: that would be publishing
           # the caller's own argument as though the venue had confirmed it.
           {:ok, %Order{id: id} = order} when is_binary(id) <- to_order(group) do
        # An order the venue names differently is another order, not this one.
        if id == client_order_id, do: {:ok, order}, else: {:error, :not_in_response}
      else
        # Any order whose id is not text: absent, or a number or object the venue sent where
        # `Order.id` (a string) belongs. Returning it would hand back a struct `Order.new/1`
        # refuses.
        {:ok, %Order{}} -> {:error, {:missing_required_field, :id}}
        {:error, _reason} = error -> error
        other -> other
      end
    end
  end

  @doc """
  Open orders, or historical ones with `history: true`.

  **These are two endpoints, not one with a filter.** `/orders/open-orders/list` and
  `/orders/historical-orders/list` answer different questions, and a caller asking for
  "orders" without saying which gets the open ones — the set that can still change.

  Requires `opts[:account_id]`. **Follows `pagination_key`, bounded** —
  `order-open.md:46,554` and `order-history.md:66` both document it on the request and the
  response, which the venue's own `page_size` never was: nothing in either page names a
  `page_size` parameter, so the `page_size` this sent before was undefined on both
  endpoints. `opts[:limit]` is no longer sent for that reason.

  `history: true` also accepts `opts[:since]`/`opts[:until]` (`DateTime`s), sent as the
  documented `start_time`/`end_time` in the venue's own `yyyy-MM-dd'T'HH:mm:ss.SSS'Z'`
  format (`order-history.md:47,58`). **Omitted, the venue defaults to the last 7 days** —
  its own words, not a default this package invented — so a caller reconciling a longer
  history must pass both.
  """
  @spec get_orders(map(), keyword()) ::
          {:ok, [Order.t()]} | {:error, term()} | {:refused, term()}
  def get_orders(credentials, opts) do
    with {:ok, account_id} <- account_id(opts),
         :ok <- validate_orders_window(opts) do
      history? = Keyword.get(opts, :history, false)

      path =
        if history?,
          do: "/trading/orders/historical-orders/list",
          else: "/trading/orders/open-orders/list"

      # `start_time`/`end_time` are documented on `/orders/historical-orders/list` only
      # (`order-history.md:47,58`) — `/orders/open-orders/list` names just `account_id`
      # and `pagination_key` (`order-open.md:36,46`). Sending them unconditionally, on
      # the open path too, would ask that endpoint a parameter it does not define.
      base_params =
        if history? do
          %{"account_id" => account_id}
          |> put_present("start_time", iso_millis(Keyword.get(opts, :since)))
          |> put_present("end_time", iso_millis(Keyword.get(opts, :until)))
        else
          %{"account_id" => account_id}
        end

      fetch_page = fn key ->
        params = put_present(base_params, "pagination_key", key)

        with {:ok, body} <- get(path, params, credentials, opts),
             {:ok, page_rows} <- rows(body) do
          {:ok, {page_rows, next_pagination_key(body)}}
        end
      end

      with {:ok, order_rows} <- paginate(fetch_page) do
        collect_orders(order_rows)
      end
    end
  end

  # The venue's own order GROUP — `{client_order_id, combo_order_id, combo_type, orders:
  # [leg, ...]}` (`order-detail.md:163,182`), the same envelope `/orders/get`,
  # `/orders/open-orders/list` and `/orders/historical-orders/list` all return one or more
  # of. A single-leg group (`combo_type: "NORMAL"`, one entry in `orders`) decodes onto
  # `Core.Types.Order` directly, from that one leg.
  #
  # **A multi-leg group is refused, not decomposed.** `Types.OrderLeg`'s own moduledoc says
  # what a leg means here: "the exchange accepts each as a single order and fills it as a
  # unit or not at all". Webull's own combo types are not that — `MASTER`/`STOP_PROFIT`/
  # `STOP_LOSS` is a parent order plus contingent orders that may never fire, and
  # `OCO`/`OTO`/`OTOCO` are alternative or triggered orders, not a spread filled as one
  # (`order-detail.md:182`'s own combo_type table). Representing them with `OrderLeg.ratio`
  # would assert a fill guarantee the venue does not make. Unlike Schwab's spread legs
  # (`dp-exchange-schwab`'s `Orders.leg_fields/1`), where the venue's `orderLegCollection`
  # genuinely is one strategy filled together, nothing here is misdescribed by refusing.
  defp to_order(%{"orders" => [leg]} = group) when is_map(leg) do
    status = leg |> value(["status"]) |> status_atom()

    {:ok,
     %Order{
       # The names `order-detail.md:167-331` defines (`client_order_id`, `order_type`,
       # `time_in_force`, `total_quantity`, `filled_quantity`, `limit_price`, `stop_price`,
       # `filled_price`); no page or capture shows their camel-case spellings.
       id: value(group, ["client_order_id"]) || leg_id(leg),
       symbol: leg |> value(["symbol"]) |> canonical_or_nil(row_instrument_type(leg)),
       side: leg |> value(["side"]) |> side_atom(),
       order_type: leg |> value(["order_type"]) |> order_type_atom(),
       time_in_force: leg |> value(["time_in_force"]) |> tif_atom(),
       quantity: decimal(value(leg, ["total_quantity"])),
       filled_quantity: decimal(value(leg, ["filled_quantity"])),
       price: decimal(value(leg, ["limit_price"])),
       stop_price: decimal(value(leg, ["stop_price"])),
       # `filled_price` is documented as "Average transaction price of the filled
       # quantity" (`order-detail.md`) — `Core.Types.Order.average_price`'s own meaning,
       # not a separate field. The venue names no `avg_filled_price` anywhere this
       # package's own reference pages cover; that key was never proven, only assumed.
       average_price: decimal(value(leg, ["filled_price"])),
       status: status,
       created_at: iso_order_time(value(leg, ["place_time_at"])),
       updated_at: updated_at(leg, status),
       provider: :webull
     }}
  end

  defp to_order(%{"orders" => [_first | _rest]} = group),
    do: {:error, {:unsupported_combo_type, Map.get(group, "combo_type")}}

  defp to_order(%{"orders" => []}), do: {:error, {:missing_required_field, :orders}}
  defp to_order(_other), do: {:error, :unexpected_response_shape}

  # `place_time_at` is "Order placement time in ISO8601 format (UTC). Format:
  # yyyy-MM-dd'T'HH:mm:ss.SSSZ", example `2025-11-11T05:44:35.385Z` (`order-detail.md:342`,
  # and the same field on the open and history pages). That is the venue's own placement
  # time, so it is `created_at`. The deprecated millisecond `place_time` beside it is not
  # read: one stated format is enough, and a second reading of the same instant could only
  # disagree. Anything not ISO8601 with an offset is `nil` - the venue's word or nothing,
  # never an epoch guessed at or the local clock.
  defp iso_order_time(raw) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, at, _offset} -> at
      {:error, _reason} -> nil
    end
  end

  defp iso_order_time(_not_text), do: nil

  # `filled_time_at` is "Time of the last executed trade" (`order-detail.md:353`), which is
  # the order's last change only while a fill IS the last thing that happened to it. For a
  # `:filled` order it is, and for a `:partially_filled` one it is the latest change this
  # read knows of. For any other status (cancelled after a partial fill, say) the order
  # changed later than its last fill and the venue states no time for that, so `updated_at`
  # stays `nil` rather than carry a time that is earlier than the truth. **Unmeasured against
  # a live order**: the page's example gives `filled_time_at` the same instant as
  # `place_time_at`.
  defp updated_at(leg, status) when status in [:filled, :partially_filled],
    do: iso_order_time(value(leg, ["filled_time_at"]))

  defp updated_at(_leg, _status), do: nil

  # **An order list is all of the orders or a refusal — never the ones this package could
  # read.** A group it cannot decode into one `Order` (a multi-leg combo `to_order/1`
  # refuses, a group with no `orders`, no id) used to be DROPPED, on the precedent of
  # `to_watchlist/2`. That precedent does not carry over: one fewer watchlist row this cycle
  # is a cosmetic gap, while an open-orders list missing a working OCO or bracket reads as
  # "nothing is working there", and a caller reconciling from it may place the order again.
  # `dp_exchange_robinhood` and `dp_exchange_gemini` already refuse the whole list on one
  # unreadable row. The refusal names the groups, by `client_order_id` where the venue gave
  # one, so a caller can see what it holds that this package cannot represent.
  defp collect_orders(order_rows) do
    {orders, unreadable} =
      Enum.reduce(order_rows, {[], []}, fn group, {orders, unreadable} ->
        case to_order(group) do
          {:ok, %Order{id: id} = order} when is_binary(id) -> {[order | orders], unreadable}
          _refused -> {orders, [group_id(group) | unreadable]}
        end
      end)

    case unreadable do
      [] -> {:ok, Enum.reverse(orders)}
      ids -> {:error, {:unreadable_orders, Enum.reverse(ids)}}
    end
  end

  defp group_id(group) when is_map(group), do: value(group, ["client_order_id"])
  defp group_id(_group), do: nil

  defp leg_id(leg), do: value(leg, ["client_order_id"])

  defp row_instrument_type(row), do: value(row, ["instrument_type"])

  defp canonical_or_nil(nil, _instrument_type), do: nil

  # Only a string is a symbol. A map or a list used to reach
  # `SymbolFormat.to_canonical_symbol/1` and raise out of `get_order/3`, `get_orders/2` and
  # `get_positions/2` (REST mutation fuzz, 2026-09-27). It is now the same absent symbol as
  # `nil`: an order carries it as `nil` and a position refuses it.
  #
  # **Only a crypto pair is split into `BASE-QUOTE`**, as `listed_symbol/2` does for the
  # catalogue. A row that states it is an equity, option, future or event holds a ticker or
  # contract code the venue named, and `GBTC` is not `G-BTC`. A row that states no type is
  # read as before (`account-position.md` lists `instrument_type` as required, so that is the
  # undocumented shape, and the split it always had is kept for it).
  defp canonical_or_nil(native, instrument_type)
       when is_binary(native) and instrument_type in [nil, "CRYPTO"],
       do: SymbolFormat.to_canonical_symbol(native)

  defp canonical_or_nil(native, _other_instrument) when is_binary(native), do: native

  defp canonical_or_nil(_absent, _instrument_type), do: nil

  # `order-detail.md:182`'s own `side` enum names `SHORT` beside `BUY`/`SELL`, and
  # `Core.Types.Order.side/0` is `:buy | :sell` — Core has no third slot for it. `nil` is
  # the honest answer for `SHORT` here, the same rule `Types.Order`'s own moduledoc states
  # for Coinbase's `close_position/3`: the venue's word, or nothing, never the nearest atom.
  defp side_atom("BUY"), do: :buy
  defp side_atom("SELL"), do: :sell
  defp side_atom(_other), do: nil

  # `order-detail.md:215`'s documented `status` enum is exactly six values: `PENDING`,
  # `SUBMITTED`, `CANCELLED`, `FILLED`, `FAILED`, `PARTIAL_FILLED`. `WORKING`, the
  # single-`L` `CANCELED`, `REJECTED` and `EXPIRED` are not among them and are removed here
  # rather than kept on the strength of an earlier, unrecorded measurement — nothing in
  # `docs/reference/webull/` attests any of the four live, so keeping them would be
  # presenting a guess as a documented mapping.
  #
  # `PARTIAL_FILLED` is `Core.Types.Order.status/0`'s own `:partially_filled`, not `:open`
  # — the two are different claims (some of the order filled, vs. none of it), and this
  # sent the wrong one for every partially filled order read back.
  #
  # `FAILED` maps to `:rejected` on the vendor's OWN equivalence, not this package's: its
  # description reads "Indicates a failed order, such as REJECTED" — the venue naming its
  # own FAILED status as the rejected-order case.
  #
  # `SUBMITTED` is `:pending`. It was `nil`, on the reading that `Core.Types.Order.status/0`
  # has no slot for "submitted, outcome unknown". `:pending` is that slot: accepted, not
  # yet known to be working, and not terminal, which is what "submitted to the exchange or
  # webull" says. It is also the example status on the open-orders page (order-open.md:234),
  # so a `nil` made every working order look unknown. It is still not `:open`, which would
  # claim the order is resting on the book.
  defp status_atom("SUBMITTED"), do: :pending
  defp status_atom("PENDING"), do: :pending
  defp status_atom("PARTIAL_FILLED"), do: :partially_filled
  defp status_atom("FILLED"), do: :filled
  defp status_atom("CANCELLED"), do: :cancelled
  defp status_atom("FAILED"), do: :rejected
  defp status_atom(_other), do: nil
end
