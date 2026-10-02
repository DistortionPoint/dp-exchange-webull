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
  (`crypto-bars.md`) carries none. `decode_bar/3` previously hard-coded `nil` for every
  caller, which understated the four documented cases the same way the old
  `reports_trade_volume: false` understated the venue as a whole. `get_volume_profile/3`
  remains the separate equity endpoint that splits traded volume by price and side — this
  note is about the bars' own `volume` column, not that endpoint.

  This package previously declared `reports_trade_volume: false` unconditionally, which
  was true of crypto and a false claim about the venue as a whole — the same
  crypto-generalised-to-venue mistake `docs/reference/webull/negative-claims.md` records
  for three other refusals. Fixed alongside `historical_timeframes` below.
  """

  alias DpExchange.Core.{Config, HttpClient, Instrument}

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
  One exception: `1y`, which `Webull.capabilities/0` subtracts because
  `dp_exchange_core`'s `Timeframe.nameable/0` does not admit it (see
  `@core_unnameable_widths` in `webull.ex`). Read this function for what the venue
  serves; read `capabilities/0` for what this package can currently say about it. Which
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
    |> Map.put("extend_hour_required", to_string(Keyword.get(opts, :extended_hours, false)))
    |> Map.put("overnight_required", to_string(Keyword.get(opts, :overnight, false)))
  end

  defp snapshot_params(native, category, _opts),
    do: %{"symbols" => native, "category" => category}

  @doc """
  Last price for one symbol.

  **Crypto and stocks are different endpoints**, chosen by `opts[:category]` — `US_CRYPTO`
  (the default), `US_STOCK` or `US_ETF`. `US_OPTION` is refused: the vendor states the stock
  snapshot does not serve it.

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

    with {:ok, path} <- snapshot_path(category) do
      native = snapshot_symbol(symbol, category)
      params = snapshot_params(native, category, opts)

      with {:ok, body} <- get(path, params, credentials, opts),
           {:ok, row} <- first_row(body),
           {:ok, raw_price} <- required(row, ["price", "lastPrice", "last_trade_price"]),
           {:ok, price} <- required_decimal(raw_price, :price) do
        # A snapshot's `volume` is the day's aggregate, so a running total —
        # dp-exchange-core issue #42. `nil`, with no window, where the response has none.
        volume = snapshot_volume(row)

        {:ok,
         %Quote{
           symbol: snapshot_canonical(native, category),
           price: price,
           volume: volume,
           volume_window: volume && :running_total,
           # Read, not required — see `top_of_book_time/1`, which has always answered this
           # way for the sibling call on the same endpoint. `Core.Types.Quote` enforces
           # `[:symbol, :price, :observed_at, :provider]`; refusing a guarded traded price
           # over an optional field discards the fact the caller asked for.
           venue_time: top_of_book_time(row),
           observed_at: DateTime.utc_now(),
           provider: :webull
         }}
      end
    end
  end

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
  defp snapshot_volume(row), do: decimal(value(row, ["volume"]))

  @doc """
  OHLC bars for a symbol and canonical timeframe.

  Bars carry no volume — see the module doc. A bar without a venue timestamp is an
  **error**, not a bar stamped with the local clock.
  """
  @spec get_historical_prices(String.t(), String.t(), keyword(), map(), keyword()) ::
          {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def get_historical_prices(symbol, timeframe, range, credentials, opts) do
    # Crypto, stocks, options, futures and event contracts are five different endpoints —
    # and crypto is a different HTTP verb. `opts[:category]` picks, defaulting to crypto,
    # which is what this package served before its asset classes widened.
    case Config.opt(opts, :category, "US_CRYPTO") do
      "US_CRYPTO" -> crypto_bars(symbol, timeframe, range, credentials, opts)
      "US_OPTION" -> option_bars(symbol, timeframe, range, credentials, opts)
      "US_FUTURES" -> futures_bars(symbol, timeframe, credentials, opts)
      "US_EVENT" -> event_bars(symbol, timeframe, credentials, opts)
      _stock -> get_stock_bars(symbol, timeframe, range, credentials, opts)
    end
  end

  # **Futures bars take no range and no `real_time_required`.** The venue's page names
  # `symbols`, `category`, `timespan` and `count` and nothing else, so a caller's start and
  # end are not silently dropped into parameters this endpoint does not read — they simply
  # have nowhere to go, and `opts[:limit]` is how a caller bounds the read here.
  defp futures_bars(symbol, timeframe, credentials, opts) do
    with {:ok, timespan} <- stock_timespan(timeframe) do
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

      with {:ok, body} <- get("/market-data/futures/bars/list", params, credentials, opts) do
        decode_stock_bars(body, symbol, timeframe, [])
      end
    end
  end

  # **Event-contract bars do not say which side they are.** A binary market has a YES price
  # and a NO price that sum to one, and the venue's schema names `open`, `close`, `high`,
  # `low` without saying which. They are returned as the venue's own numbers under the
  # market's symbol; a caller reconciling against `get_event_trades/3`, which does name both
  # sides, is the way to find out. Labelling them here would be this package asserting a
  # side the venue did not state.
  defp event_bars(symbol, timeframe, credentials, opts) do
    with {:ok, timespan} <- event_timespan(timeframe) do
      params =
        %{
          "symbols" => symbol,
          "category" => "US_EVENT",
          "timespan" => timespan,
          # Required by the venue. `false` asks for completed bars only: an in-progress bar
          # has a boundary that has not happened yet.
          "real_time_required" => to_string(Keyword.get(opts, :real_time, false))
        }
        |> put_present("count", Keyword.get(opts, :limit))

      with {:ok, body} <-
             get("/market-data/event-contracts/bars/list", params, credentials, opts) do
        decode_stock_bars(body, symbol, timeframe, [])
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
  # letting `decode_stock_bars/4`'s client-side `within?/2` filter run against a caller's
  # range would, for any range outside that most-recent window, produce a real, complete-
  # looking response with every bar then discarded — a truncation that reads as "no data in
  # that range" rather than "count did not reach back far enough", the family's own named
  # failure shape.
  defp option_bars(symbol, timeframe, range, credentials, opts) do
    with :ok <- refuse_bar_range(range, :option),
         {:ok, timespan} <- stock_timespan(timeframe) do
      params =
        %{
          "symbols" => symbol,
          "category" => "US_OPTION",
          "timespan" => timespan
        }
        |> put_present("count", Keyword.get(opts, :limit))

      with {:ok, body} <- get("/market-data/options/bars/list", params, credentials, opts) do
        decode_stock_bars(body, symbol, timeframe, [])
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

  defp crypto_bars(symbol, timeframe, range, credentials, opts) do
    native = SymbolFormat.to_exchange_symbol(symbol)

    with {:ok, timespan} <- timespan(timeframe) do
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

  **`US_EVENT` is refused here on purpose, the same way `tick_path/1` refuses it for
  `get_trades/3`.** The event snapshot has no single `bid`/`ask` — it publishes
  `yes_bid`/`yes_ask`/`no_bid`/`no_ask` and their sizes (`event-snapshot.md:170-181,221-256`),
  because a binary market has two instruments' worth of quotes, not one. Picking the YES
  side to be "the" bid and ask would answer about only one of the two contracts and, per
  `get_event_order_book/3`'s own moduledoc, the numbers would still look right — a YES ask
  of 0.13 is real and is not "the" ask the way a stock's is. Use
  `get_event_order_book/3` instead, which returns both sides under their own names.
  """
  @spec get_top_of_book(String.t(), map(), keyword()) ::
          {:ok, TopOfBook.t()} | {:error, term()} | {:refused, term()}
  def get_top_of_book(symbol, credentials, opts) do
    category = Config.opt(opts, :category, "US_CRYPTO")

    with :ok <- refuse_event_top_of_book(category),
         {:ok, path} <- snapshot_path(category) do
      native = snapshot_symbol(symbol, category)
      params = snapshot_params(native, category, opts)

      with {:ok, body} <- get(path, params, credentials, opts),
           {:ok, row} <- first_row(body) do
        {:ok,
         %TopOfBook{
           symbol: snapshot_canonical(native, category),
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
  end

  defp refuse_event_top_of_book("US_EVENT"), do: {:error, {:use_get_event_order_book, "US_EVENT"}}
  defp refuse_event_top_of_book(_category), do: :ok

  # The book's own stamp where the row carries one. `nil` rather than the local clock —
  # `observed_at` already holds that, and says which it is.
  defp top_of_book_time(row) do
    case venue_time(row) do
      {:ok, at} -> at
      _no_venue_time -> nil
    end
  end

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
    with {:ok, rows} <- all_instrument_rows(nil, credentials, opts, [], 0) do
      {:ok,
       rows
       |> Enum.map(&value(&1, ["symbol", "disSymbol", "name"]))
       # Only a string names an instrument. `is_nil/1` let a map or a list through to
       # `to_canonical_symbol/1`, which raised (REST mutation fuzz, 2026-09-27).
       |> Enum.filter(&is_binary/1)
       |> Enum.map(&SymbolFormat.to_canonical_symbol/1)
       |> Enum.sort()
       |> Enum.uniq()}
    end
  end

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
      {:ok, Enum.flat_map(rows, &to_instrument/1)}
    end
  end

  defp ensure_crypto_category("US_CRYPTO"), do: :ok

  defp ensure_crypto_category(category),
    do: {:error, {:unsupported_instrument_category, category}}

  defp to_instrument(row) do
    symbol = value(row, ["symbol", "disSymbol", "name"])
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
    do: {:error, :too_many_instrument_pages}

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
  # `{:error, {:too_many_pages, n}}` on the bound and `{:error, :pagination_key_did_not_advance}`
  # on a repeated key — fail closed on both, rather than returning the pages collected so
  # far as though they were the whole list.
  defp paginate(fetch_page), do: paginate(fetch_page, nil, [], 0)

  defp paginate(_fetch_page, _key, _acc, page) when page >= @max_pages,
    do: {:error, {:too_many_pages, page}}

  defp paginate(fetch_page, key, acc, page) do
    with {:ok, {page_rows, next_key}} <- fetch_page.(key) do
      collected = [page_rows | acc]

      case next_key do
        nil -> {:ok, collected |> Enum.reverse() |> Enum.concat()}
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

  Reads the same `instruments/.../profiles/list` endpoint `get_symbols/1` already calls —
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
  """
  @spec quantization(String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def quantization(symbol, credentials, opts) do
    category = if String.contains?(symbol, "-"), do: "US_CRYPTO", else: "US_STOCK"
    native = if category == "US_CRYPTO", do: SymbolFormat.to_exchange_symbol(symbol), else: symbol

    with {:ok, path} <- instruments_path(category),
         params = %{"category" => category, "symbols" => native},
         {:ok, body} <- get(path, params, credentials, opts),
         {:ok, row} <- first_row(body) do
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

    request = %{path: path, query_params: stringify(params), body: "", host: host}
    url = Environment.rest_url(environment) <> path <> query(params)

    case HttpClient.request(:get, url, signer(request, credentials), nil, request_opts(opts)) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        decoded_body(body)

      # Permanent for the request as sent. A caller whose token expired refreshes and
      # calls again, which is a different request rather than a retry of this one.
      {:ok, %{status: status, body: body}} when status in [400, 401, 403] ->
        {:refused, refusal(status, body)}

      {:ok, %{status: status, body: body}} ->
        {:error, {:exchange_error, :webull, "HTTP #{status}: #{inspect(body)}"}}

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
  defp post(path, body, credentials, opts) do
    environment = Environment.resolve(opts)
    host = Environment.host(environment)
    encoded = Jason.encode!(body)

    request = %{path: path, query_params: %{}, body: encoded, host: host}
    url = Environment.rest_url(environment) <> path
    headers = signer(request, credentials)

    case HttpClient.request(:post, url, headers, encoded, request_opts(opts)) do
      {:ok, %{status: status, body: response}} when status in 200..299 ->
        decoded_body(response)

      {:ok, %{status: status, body: response}} when status in [400, 401, 403] ->
        {:refused, refusal(status, response)}

      {:ok, %{status: status, body: response}} ->
        {:error, {:exchange_error, :webull, "HTTP #{status}: #{inspect(response)}"}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A POST whose response is **not JSON** — the one shape `post/4` above cannot serve.
  # `post/4`'s `decoded_body/1` runs every 2xx body through `Jason.decode/1` and refuses
  # with `{:error, {:undecodable_response, :webull}}` on anything that fails to parse, so
  # calling it against an endpoint whose response is Server-Sent Events (`news-summary.md:195`
  # — `event:message\ndata:{...}` frames, `Content-Type: text/event-stream`) always refused,
  # not just sometimes: the body is never valid JSON on that endpoint. This is the same
  # signing and status handling `post/4` gives every other write, minus the JSON decode,
  # so `get_news/2` can read the frames itself.
  defp post_sse(path, body, credentials, opts) do
    environment = Environment.resolve(opts)
    host = Environment.host(environment)
    encoded = Jason.encode!(body)

    request = %{path: path, query_params: %{}, body: encoded, host: host}
    url = Environment.rest_url(environment) <> path
    headers = signer(request, credentials)

    case HttpClient.request(:post, url, headers, encoded, request_opts(opts)) do
      {:ok, %{status: status, body: response}} when status in 200..299 ->
        {:ok, response}

      {:ok, %{status: status, body: response}} when status in [400, 401, 403] ->
        {:refused, refusal(status, response)}

      {:ok, %{status: status, body: response}} ->
        {:error, {:exchange_error, :webull, "HTTP #{status}: #{inspect(response)}"}}

      {:error, reason} ->
        {:error, reason}
    end
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
  # would at best tell the caller a success failed and at worst act twice. `put_new`, so a
  # caller that has its own reason can still ask for retries.
  defp send_once(opts), do: Keyword.put_new(opts, :retry_attempts, 1)

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
      :req_adapter,
      :rate_limit_blocking
    ])
    |> Keyword.merge(provider: :webull, raw_status: true)
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
    with {:ok, body} <- get("/trading/accounts/list", %{}, credentials, opts) do
      rows(body)
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
    case value(body, ["account_currency_assets", "accountCurrencyAssets"]) do
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
         balance: decimal(value(row, ["cash_balance", "cashBalance"])),
         # Not derived. See the note on get_balances/2: this venue publishes several
         # different "available" figures and they disagree.
         available_balance: nil,
         hold: decimal(value(row, ["frozen_amount", "frozenAmount"])),
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
  direction is carried in the sign of `quantity` — so `Position.from_signed_quantity/1` does
  the conversion, which is exactly what it exists for. A package that assumed `:long`
  because equities are usually long would produce a short position that is exactly backwards
  with every number in it still plausible.

  `instrument_type` comes from the venue's own `EQUITY | OPTION | FUTURES | CRYPTO | EVENT`.
  An unknown one is `nil`, not the nearest.

  `liquidation_price` and `leverage` stay `nil`: **the venue publishes neither on this
  endpoint.** `nil` there means "not stated", never "no liquidation risk" — see
  `Core.Types.Position`.
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
  # **`side` and `quantity` are deliberately left alone.** `signed_quantity/1` answers
  # `{nil, nil}` for a quantity this package could not read, and the comment below it states
  # why: a position with no quantity has no direction either, and `:long` would be a guess.
  # That is a reasoned absence rather than an oversight, and unlike the symbol it still leaves
  # a caller knowing the position exists.
  defp to_position(row) do
    with {:ok, symbol} <-
           required_position_symbol(row |> value(["symbol"]) |> canonical_or_nil()) do
      {:ok, position_struct(row, symbol)}
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

  defp position_struct(row, symbol) do
    {side, quantity} =
      row
      |> value(["quantity"])
      |> decimal()
      |> signed_quantity()

    %Position{
      symbol: symbol,
      side: side,
      quantity: quantity,
      instrument_type: row |> value(["instrument_type", "instrumentType"]) |> instrument_atom(),
      average_cost: decimal(value(row, ["cost_price", "costPrice"])),
      mark_price: decimal(value(row, ["last_price", "lastPrice"])),
      # Marked, not booked. The venue reports only the open figure here.
      unrealised_pnl: decimal(value(row, ["unrealized_profit_loss", "unrealizedProfitLoss"])),
      provider: :webull
    }
  end

  # A position with no quantity has no direction either, and `:long` would be a guess about
  # a row the venue sent empty.
  defp signed_quantity(nil), do: {nil, nil}
  defp signed_quantity(%Decimal{} = quantity), do: Position.from_signed_quantity(quantity)

  defp instrument_atom("EQUITY"), do: :equity
  defp instrument_atom("OPTION"), do: :option
  defp instrument_atom("FUTURES"), do: :futures
  defp instrument_atom("CRYPTO"), do: :crypto
  defp instrument_atom("EVENT"), do: :event
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
  `CORPORATE_ACTION`, `OPTION_EA`, `JOURNAL`, `EC_SETTLEMENT` and `OTHER` alongside
  `DEPOSIT`, `WITHDRAW` and `TRANSFER`. The contract asks `get_transfers/2` for deposit and
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
         :ok <- same_year(Keyword.get(opts, :start), Keyword.get(opts, :end)) do
      base_params =
        %{"account_id" => account_id, "activity_types" => Enum.join(types, ",")}
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
  `INTERESTS`, `CORPORATE_ACTION`, `OPTION_EA`, `JOURNAL`, `EC_SETTLEMENT` and `OTHER`
  alongside the three.

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
         :ok <- same_year(Keyword.get(opts, :start), Keyword.get(opts, :end)) do
      base_params =
        %{"account_id" => account_id}
        |> put_present("activity_types", transaction_types(opts))
        |> put_present("start_time", iso_millis(Keyword.get(opts, :start)))
        |> put_present("end_time", iso_millis(Keyword.get(opts, :end)))

      paginate(cash_activities_page(base_params, credentials, opts))
    end
  end

  defp cash_activities_page(base_params, credentials, opts) do
    fn key ->
      params = put_present(base_params, "pagination_key", key)

      with {:ok, body} <-
             get("/trading/activities/cash-activities/list", params, credentials, opts),
           {:ok, page_rows} <- rows(body) do
        {:ok, {page_rows, next_pagination_key(body)}}
      end
    end
  end

  # Absent by default, which is what asks the venue for everything. A default list here
  # would be this package deciding what "every activity" means.
  defp transaction_types(opts) do
    case Keyword.get(opts, :activity_types) do
      nil -> nil
      types when is_list(types) -> Enum.join(types, ",")
      types -> to_string(types)
    end
  end

  # The venue's stated limit. Sending a cross-year range and reading the answer would give a
  # real list missing whichever half the venue dropped.
  defp same_year(%DateTime{year: year}, %DateTime{year: year}), do: :ok

  defp same_year(%DateTime{year: from}, %DateTime{year: to}),
    do: {:error, {:cross_year_range, from, to}}

  defp same_year(_start, _finish), do: :ok

  # The venue's documented format: yyyy-MM-dd'T'HH:mm:ss.SSS'Z'.
  defp iso_millis(nil), do: nil

  defp iso_millis(%DateTime{} = at),
    do: at |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()

  defp iso_millis(other), do: other

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
  """
  @spec preview_order(map(), map(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def preview_order(credentials, request, opts) do
    instrument = instrument_type(request)

    with :ok <- previewable(instrument),
         {:ok, account_id} <- account_id(opts),
         {:ok, order_type, tif} <- combination(request),
         {:ok, leaf} <- order_leaf(request, order_type, tif) do
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

  defp to_preview_result(row, instrument) do
    case value(row, ["estimated_cost", "estimatedCost"]) do
      nil ->
        {:error, :unexpected_response_shape}

      cost ->
        {:ok,
         %{
           instrument_type: instrument,
           # Total consideration on stocks and options; initial margin on futures. The
           # instrument above says which, because they are not the same quantity.
           estimated_cost: decimal(cost),
           estimated_fee:
             decimal(value(row, ["estimated_transaction_fee", "estimatedTransactionFee"]))
         }}
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
  """
  @spec replace_order(map(), String.t(), map(), keyword()) ::
          {:ok, Order.t()} | {:error, term()} | {:refused, term()}
  def replace_order(credentials, client_order_id, changes, opts) do
    instrument = Config.opt(opts, :instrument_type, :equity)
    order_type = Config.opt(opts, :order_type, :limit)

    with :ok <- previewable(instrument),
         :ok <- amendable(order_type, changes),
         {:ok, account_id} <- account_id(opts) do
      modification =
        %{"client_order_id" => client_order_id}
        |> put_present("order_type", changes |> Map.get(:order_type) |> order_type_name())
        |> put_present("quantity", Map.get(changes, :quantity))
        |> put_present("limit_price", Map.get(changes, :price))
        |> put_present("stop_price", Map.get(changes, :stop_price))
        |> put_present("trailing_stop_step", Map.get(changes, :trailing_stop_step))
        |> put_present("time_in_force", changes |> Map.get(:time_in_force) |> tif_name())

      body = %{"account_id" => account_id, "modify_orders" => [modification]}

      # Sent once (`put_new`, so a caller can still ask for retries), as `create_watchlist/4`
      # is. `Core.HttpClient` retries a timeout or a 5xx, and a replace that already took
      # effect, sent again, is at best refused, telling the caller a success failed. The
      # `client_order_id` names the order being changed, not this change, so the venue cannot
      # tell a repeat from a second replace.
      with {:ok, _response} <-
             post(
               "/trading/orders/replace",
               body,
               credentials,
               send_once(opts)
             ) do
        get_order(credentials, client_order_id, opts)
      end
    end
  end

  @amendable %{
    market: [:quantity],
    limit: [:order_type, :time_in_force, :quantity, :price],
    stop: [:order_type, :time_in_force, :quantity, :stop_price],
    stop_limit: [:order_type, :time_in_force, :quantity, :price, :stop_price],
    trailing_stop: [:trailing_stop_step]
  }

  defp amendable(order_type, changes) do
    case Map.fetch(@amendable, order_type) do
      :error ->
        {:error, {:unsupported_order_type, order_type}}

      {:ok, allowed} ->
        case Map.keys(changes) -- allowed do
          [] -> present?(changes)
          rejected -> {:error, {:unsupported_order_edit, order_type, rejected}}
        end
    end
  end

  # An amendment with nothing in it is not an amendment. Sending one would have the venue
  # re-accept the order unchanged, which looks like success and achieves nothing.
  defp present?(changes) when map_size(changes) == 0, do: {:error, :no_order_changes}
  defp present?(_changes), do: :ok

  @doc """
  The order book for an equity or ETF — `/market-data/stocks/depths/list`.

  **This venue's book is equities-only.** The crypto snapshot endpoint publishes a top of
  book and no depth, and the vendor states `US_OPTION` is not supported here. So a crypto
  symbol is refused before the request rather than sent and rejected.

  `opts[:category]` picks `US_STOCK` (the default) or `US_ETF`; `opts[:depth]` is the
  venue's own level count. `opts[:overnight]` includes overnight trading data, and the
  venue **requires the parameter**, so `false` is sent explicitly rather than omitted.

  ## `depth`'s default of `10` is this package's own choice, not a confirmed venue default

  Unlike `overnight_required`, this endpoint's own reference page has not been pulled into
  `docs/reference/webull/` — `endpoint-inventory.md` has its path and nothing else. **That
  is not because the vendor's pages need a browser.** `negative-claims.md`'s "pages had to
  be rendered" note is itself stale: it was written against a capture method that fetched
  only HTML, and every page pulled for the 2026-09-29 order/market-data audit
  (`docs/reference/webull/openapi/`) came back from a plain fetch of the page's `.md` form
  with the full OpenAPI parameter table embedded as JSON — no browser involved. The stock
  depths page simply was not among the pages that audit needed and so was not fetched;
  the gap is a page not yet pulled, not a page this package cannot read. `10` is inherited
  from a sibling endpoint that IS documented — `/market-data/event-contracts/depths/list`
  states "`depth` (default 10)" (`docs/reference/webull/futures-and-event-contracts.md`)
  — generalised here without confirmation that the stock endpoint shares it. On
  `US_FUTURES` specifically, the venue's own page states `depth` is **`1–10, required`**
  with no default at all (same file), so supplying `10` there is this package filling a
  required parameter with a value known to be in range, not a venue default being
  honoured.

  Settling the stock case needs this endpoint's own `.md` page pulled into
  `docs/reference/webull/openapi/` the same way the 2026-09-29 pages were, or a
  credentialed consumer's tier-3 probe of what an omitted `depth` actually returns.

  ## What is dropped, and why that is stated rather than silent

  Each level carries the venue's `order` array — market participant IDs and per-participant
  sizes — and `broker` names beneath that. `Core.Types.OrderBook` levels are
  `{price, size}`, so **the attribution is discarded here**. That is a real loss: on a
  lit book, who is quoting is information a caller may want, and this contract has no
  place for it. The sizes that survive are the venue's own level sizes, not a sum this
  package computed from the participants.

  `timestamp` is the venue's `quote_time`. **A book the venue did not stamp is refused** —
  a depth snapshot wearing the local clock cannot be told from a current one.
  """
  @spec get_order_book(String.t(), map(), keyword()) ::
          {:ok, OrderBook.t()} | {:error, term()} | {:refused, term()}
  def get_order_book(symbol, credentials, opts) do
    category = Config.opt(opts, :category, "US_STOCK")

    with {:ok, path} <- book_path(category) do
      params =
        %{
          "symbol" => symbol,
          "category" => category,
          # `10` is generalised from the event-contracts endpoint's documented default,
          # NOT confirmed for this endpoint — see this function's own @doc.
          "depth" => to_string(Config.opt(opts, :depth, 10))
        }
        |> put_present("overnight_required", book_overnight(category, opts))

      with {:ok, body} <- get(path, params, credentials, opts),
           {:ok, row} <- first_row(body) do
        to_order_book(row, symbol)
      end
    end
  end

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
  defp book_overnight(_category, opts), do: to_string(Keyword.get(opts, :overnight, false))

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
  defp to_order_book(row, symbol) do
    {:ok,
     %OrderBook{
       symbol: symbol,
       bids: book_levels(value(row, ["bids"]), :desc),
       asks: book_levels(value(row, ["asks"]), :asc),
       venue_time: top_of_book_time(row),
       observed_at: DateTime.utc_now(),
       # No sequence on this endpoint. `nil` means the venue did not say, so a caller
       # cannot use this book to detect a gap in a stream.
       sequence: nil,
       provider: :webull
     }}
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
  # The `not is_nil(price)` filter this already had is why a nil price cannot reach the sort.
  defp book_levels(rows, direction) when is_list(rows) do
    rows
    |> Enum.flat_map(fn row ->
      case decimal(value(row, ["price"])) do
        nil -> []
        price -> [{price, decimal(value(row, ["size"]))}]
      end
    end)
    |> Enum.sort_by(fn {price, _size} -> price end, {direction, Decimal})
  end

  defp book_levels(_absent, _direction), do: []

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

  Widths are `5s`, `15s`, `1m`, `5m` and `30m` — five, where `get_historical_prices/4`
  serves more. A width outside them is `{:unsupported_timeframe, width}` rather than the
  closest one this endpoint does have.

  `opts[:count]` is the venue's bar count (default 200, max 1200); `opts[:session]` picks
  `PRE`, `RTH` or `ATH` — **`OVN` is documented as not supported and is refused here**
  rather than sent.

  ## `real_time_required` is sent as `false`

  The vendor marks it required and says it controls whether an unfinished bar is included.
  `false` asks for completed intervals only: **an in-progress footprint has a boundary that
  has not happened yet**, and its buy/sell split will change before the interval closes. The
  same reasoning `get_historical_prices/4` uses for bars.

  The price maps come back **keyed on the venue's own price strings**. See
  `Core.Types.VolumeProfile` for why they are not re-keyed on `Decimal`.
  """
  @spec get_volume_profile(String.t(), String.t(), map(), keyword()) ::
          {:ok, [VolumeProfile.t()]} | {:error, term()} | {:refused, term()}
  def get_volume_profile(symbol, timeframe, credentials, opts) do
    category = Config.opt(opts, :category, "US_STOCK")

    with {:ok, path} <- footprint_path(category),
         {:ok, span} <- footprint_span(timeframe),
         {:ok, session} <- footprint_session(Keyword.get(opts, :session)) do
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

      with {:ok, body} <- get(path, params, credentials, opts),
           {:ok, row} <- first_row(body) do
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

  defp footprint_path(category) when category in ["US_STOCK", "US_ETF"],
    do: {:ok, "/market-data/stocks/footprints/list"}

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
    with {:ok, opened_at} <- venue_time(entry) do
      {:ok,
       %VolumeProfile{
         symbol: symbol,
         timeframe: timeframe,
         opened_at: opened_at,
         total_volume: decimal(value(entry, ["total"])),
         # The venue's own buy-minus-sell. Not recomputed from the totals — where they
         # disagree, the gap is the venue's classifier and not an error to correct.
         delta: decimal(value(entry, ["delta"])),
         buy_volume: decimal(value(entry, ["buy_total", "buyTotal"])),
         sell_volume: decimal(value(entry, ["sell_total", "sellTotal"])),
         buy_at_price: price_map(value(entry, ["buy_detail", "buyDetail"])),
         sell_at_price: price_map(value(entry, ["sell_detail", "sellDetail"])),
         session: session_atom(value(entry, ["trading_session", "tradingSession"])),
         provider: :webull
       }}
    end
  end

  defp price_map(%{} = detail),
    do: Map.new(detail, fn {price, size} -> {price, decimal(size)} end)

  defp price_map(_absent), do: nil

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
  """
  @spec get_auction_imbalance(String.t(), map(), keyword()) ::
          {:ok, [AuctionImbalance.t()]} | {:error, term()} | {:refused, term()}
  def get_auction_imbalance(symbol, credentials, opts) do
    observed_at = DateTime.utc_now()

    with {:ok, auction, action_type} <- auction_type(Keyword.get(opts, :auction)) do
      path =
        if Keyword.get(opts, :history, false),
          do: "/market-data/stocks/noii-bars/list",
          else: "/market-data/stocks/noii-snapshots/list"

      params = %{
        "symbol" => symbol,
        "category" => "US_STOCK",
        "imbalance_action_type" => action_type
      }

      with {:ok, body} <- get(path, params, credentials, opts),
           {:ok, imbalance_rows} <- rows(body) do
        {:ok, Enum.map(imbalance_rows, &to_imbalance(&1, symbol, auction, observed_at))}
      end
    end
  end

  defp auction_type(:opening), do: {:ok, :opening, "PRE_OPEN"}
  defp auction_type(:closing), do: {:ok, :closing, "PRE_CLOSE"}
  defp auction_type(nil), do: {:error, :auction_required}
  defp auction_type(other), do: {:error, {:unsupported_auction, other}}

  defp to_imbalance(row, symbol, auction, observed_at) do
    %AuctionImbalance{
      symbol: symbol,
      auction: auction,
      paired_quantity: decimal(value(row, ["paired_shares", "pairedShares"])),
      imbalance_quantity: decimal(value(row, ["imbalance_shares", "imbalanceShares"])),
      # The venue's code, carried as sent. Its meaning is not documented.
      side: to_string_or_nil(value(row, ["imbalance_side", "imbalanceSide"])),
      reference_price: decimal(value(row, ["imbalance_ref_price", "imbalanceRefPrice"])),
      near_price: decimal(value(row, ["imbalance_near_price", "imbalanceNearPrice"])),
      far_price: decimal(value(row, ["imbalance_far_price", "imbalanceFarPrice"])),
      # The venue's own time, or nil. Together with `observed_at` this is the only way to
      # tell a live imbalance from one returned outside the auction window.
      venue_time: imbalance_time(row),
      observed_at: observed_at,
      provider: :webull
    }
  end

  defp imbalance_time(row) do
    case value(row, ["imbalance_time", "imbalanceTime"]) do
      nil ->
        nil

      raw ->
        case parse_time(raw) do
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
  Tick-by-tick public trades — `/market-data/stocks/ticks/list`.

  **The tape, not `get_trade_history/2`.** That returns the credential's own fills; this
  returns everyone's executions, newest first as the venue sorts them.

  `opts[:limit]` is the venue's `count` (default 30, max 1000). `opts[:sessions]` takes the
  venue's own list — `PRE`, `RTH`, `ATH`, `OVN`, comma-joined — and defaults to `RTH`.
  **The venue marks `trading_sessions` required**, so one is always sent; asking for regular
  hours by default is a choice, and it is the one that matches what `get_price/3` returns.

  ## `side` has five codes and this package knows two of them

  The venue documents the field as *"Such as: B S G L N"* and defines none of them. `B` and
  `S` are unambiguous; **`G`, `L` and `N` are not documented anywhere the vendor publishes**,
  so they map to `nil` rather than being folded into the nearest of buy or sell.

  A tick whose side is `nil` is a real trade with an unknown aggressor. Guessing would put
  volume on the wrong side of a delta, which is the number a caller reads a tape for.

  `broken` is `false` on every tick: this venue publishes no bust flag here, and a venue
  with no concept of busts has nothing busted — which is the same answer.
  """
  @spec get_trades(String.t(), map(), keyword()) ::
          {:ok, [Trade.t()]} | {:error, term()} | {:refused, term()}
  def get_trades(symbol, credentials, opts) do
    category = Config.opt(opts, :category, "US_STOCK")

    with {:ok, path} <- tick_path(category) do
      params =
        %{
          "symbol" => symbol,
          "category" => category,
          "count" => to_string(Config.opt(opts, :limit, 30))
        }
        |> put_present("trading_sessions", tick_sessions(category, opts))

      with {:ok, body} <- get(path, params, credentials, opts),
           {:ok, row} <- first_row(body) do
        decode_ticks(row, symbol)
      end
    end
  end

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
      {:ok, trades} -> {:ok, trades |> Enum.reverse() |> Enum.sort_by(& &1.timestamp, DateTime)}
      error -> error
    end
  end

  defp to_trade(tick, symbol) do
    with {:ok, timestamp} <- venue_time(tick),
         {:ok, price} <- required_decimal(value(tick, ["price"]), :price),
         {:ok, quantity} <- required_decimal(value(tick, ["volume"]), :quantity) do
      {:ok,
       %Trade{
         # The venue publishes no per-tick id on this endpoint. `nil` says so.
         id: nil,
         symbol: symbol,
         side: tick_side(value(tick, ["side"])),
         price: price,
         quantity: quantity,
         timestamp: timestamp,
         # No bust flag on this endpoint; nothing was busted, which is the same answer.
         broken: false,
         provider: :webull
       }}
    end
  end

  # `B` and `S` are unambiguous. `G`, `L` and `N` appear in the venue's field description
  # and are defined nowhere it publishes, so they are `nil` — a real trade with an unknown
  # aggressor. Folding them into buy or sell would put volume on the wrong side of a delta.
  defp tick_side("B"), do: :buy
  defp tick_side("S"), do: :sell
  defp tick_side(_undocumented), do: nil

  # The stock bars endpoint serves **three widths the crypto one does not** — week, month
  # and year — on top of the eight they share.
  @stock_timespans Map.merge(@timespans, %{"1w" => "W", "1M" => "M", "1y" => "Y"})

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

  ## `real_time_required` defaults to **Y** here, unlike every other endpoint

  On the crypto bars and the footprints it defaults to false. Here the vendor's default is
  *"Y: The returned data includes the latest market data"* — an **in-progress bar whose
  boundary has not happened yet**. This sends `false` unless asked, matching what
  `get_historical_prices/5` does for crypto: a package that stored the venue's default would
  save a bar that changes after it is written.

  Widths: the eight the crypto endpoint serves plus `1w`, `1M` and `1y`.
  """
  @spec get_stock_bars(String.t(), String.t(), keyword(), map(), keyword()) ::
          {:ok, [Candle.t()]} | {:error, term()} | {:refused, term()}
  def get_stock_bars(symbol, timeframe, range, credentials, opts) do
    category = Config.opt(opts, :category, "US_STOCK")

    with :ok <- book_category(category),
         {:ok, timespan} <- stock_timespan(timeframe) do
      body =
        %{
          "symbols" => [symbol],
          "category" => category,
          "timespan" => timespan,
          # Completed bars only. The venue's own default is the opposite here.
          "real_time_required" => Keyword.get(opts, :real_time, false)
        }
        |> put_raw("count", Keyword.get(opts, :limit))
        |> put_raw("start_time", epoch_ms(Keyword.get(range, :start)))
        |> put_raw("end_time", epoch_ms(Keyword.get(range, :end)))
        |> put_present("trading_sessions", sessions_param(Keyword.get(opts, :sessions)))

      with {:ok, response} <- post("/market-data/stocks/bars/list", body, credentials, opts) do
        decode_stock_bars(response, symbol, timeframe, range)
      end
    end
  end

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
  defp epoch_ms(%DateTime{} = at), do: DateTime.to_unix(at, :millisecond)
  defp epoch_ms(other), do: other

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
  defp decode_stock_bars(response, symbol, timeframe, range) do
    with {:ok, groups} <- bar_groups(response),
         {:ok, raw_bars} <- nested_results(groups) do
      raw_bars
      |> Enum.reduce_while({:ok, []}, fn bar, {:ok, acc} ->
        case decode_bar(bar, symbol, timeframe) do
          {:ok, candle} -> {:cont, {:ok, [candle | acc]}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, bars} ->
          {:ok,
           bars
           |> Enum.reverse()
           |> Enum.filter(&within?(&1, range))
           |> Enum.sort_by(& &1.opened_at, DateTime)}

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
  are the venue's four, and only the second is a token that works.

  Tokens default to **15 days** and must be recreated, not renewed — there is no refresh on
  this endpoint. `expires_at` is milliseconds.
  """
  @spec create_token(map(), keyword()) :: {:ok, map()} | {:error, term()} | {:refused, term()}
  def create_token(credentials, opts) do
    with {:ok, response} <- post("/auth/tokens/create", %{}, credentials, send_once(opts)),
         {:ok, row} <- first_row(response) do
      {:ok, row}
    end
  end

  @doc """
  Checks a token's status — `POST /auth/tokens/check`.

  **This is the call that distinguishes the four states**, and the reason to make it before
  trusting a stored token: `PENDING` has never been verified, `EXPIRED` has run out, and
  `INVALID` was revoked or never existed. All three fail the same way at the next request,
  and only this endpoint says which.

  The status comes back as the venue's own string. Nothing is mapped to a boolean, because
  "not usable" covers three different problems with three different remedies.
  """
  @spec check_token(String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def check_token(token, credentials, opts) when is_binary(token) do
    with {:ok, response} <- post("/auth/tokens/check", %{"token" => token}, credentials, opts),
         {:ok, row} <- first_row(response) do
      {:ok, row}
    end
  end

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
  """
  @spec oauth_token(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def oauth_token(client_id, client_secret, opts)
      when is_binary(client_id) and is_binary(client_secret) do
    with {:ok, grant} <- oauth_grant(opts) do
      form =
        Map.merge(
          %{"client_id" => client_id, "client_secret" => client_secret},
          grant
        )

      url = Config.opt(opts, :oauth_url, oauth_url(opts)) <> "/oauth2/tokens/create"
      headers = [{"Content-Type", "application/x-www-form-urlencoded"}]

      case HttpClient.request(:post, url, headers, URI.encode_query(form), request_opts(opts)) do
        {:ok, %{status: status, body: body}} when status in 200..299 ->
          decoded_token(body)

        {:ok, %{status: status, body: body}} when status in [400, 401, 403] ->
          {:refused, refusal(status, body)}

        {:ok, %{status: status, body: body}} ->
          {:error, {:exchange_error, :webull, "HTTP #{status}: #{inspect(body)}"}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # `code` and `refresh_token` are the venue's two grants and it takes exactly one. Sending
  # both would leave the venue to choose, and which it chose is not something the caller
  # could read back from the response.
  defp oauth_grant(opts) do
    case {Keyword.get(opts, :code), Keyword.get(opts, :refresh_token)} do
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
  """
  @spec list_watchlists(map(), keyword()) ::
          {:ok, [Watchlist.t()]} | {:error, term()} | {:refused, term()}
  def list_watchlists(credentials, opts) do
    with {:ok, body} <- get("/market-data/watchlists/list", %{}, credentials, opts),
         {:ok, watchlist_rows} <- rows(body) do
      {:ok, watchlist_rows |> Enum.map(&to_watchlist(&1, nil)) |> Enum.reject(&is_nil/1)}
    end
  end

  @doc """
  One watchlist including its membership —
  `GET /market-data/watchlists/instruments/list`.

  The membership endpoint returns the instruments and **not the watchlist's name**, so
  `name` is `nil` here where `list_watchlists/2` has it. Reading the listing to fill it in
  would be a second request this function did not make, and a name from a moment ago beside
  a membership from now.
  """
  @spec get_watchlist(String.t(), map(), keyword()) ::
          {:ok, Watchlist.t()} | {:error, term()} | {:refused, term()}
  def get_watchlist(watchlist_id, credentials, opts) when is_binary(watchlist_id) do
    params = %{"watchlist_id" => watchlist_id}

    with {:ok, body} <-
           get("/market-data/watchlists/instruments/list", params, credentials, opts),
         {:ok, row} <- first_row(body),
         {:ok, instruments} <- list_value(row, ["instruments"]) do
      symbols =
        instruments
        |> Enum.map(&value(&1, ["symbol"]))
        |> Enum.reject(&is_nil/1)

      {:ok,
       %Watchlist{
         id: value(row, ["watchlist_id"]) || watchlist_id,
         name: nil,
         symbols: symbols,
         venue_time: nil,
         provider: :webull
       }}
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

  An empty `symbols` list makes one request and creates an empty watchlist, which is a real
  thing to want.

  **The venue does not accept event contracts, futures or options here**, by its own note on
  the add endpoint. Symbols default to `US_STOCK`; `opts[:category]` overrides.
  """
  @spec create_watchlist(String.t(), [String.t()], map(), keyword()) ::
          {:ok, Watchlist.t()} | {:error, term()} | {:refused, term()}
  def create_watchlist(name, symbols, credentials, opts) when is_binary(name) do
    body = put_present(%{"name" => name}, "sort", Keyword.get(opts, :sort))

    # Sent ONCE (`put_new`, so a caller can still ask for retries). `Core.HttpClient` retries
    # a timeout or a 5xx three times by default, and nothing in this body — a name and an
    # optional sort — lets the venue tell a second create from the first. The comment just
    # below names the outcome that produces: "the list now exists at the venue and the caller
    # has no handle to add to, read or delete it". A retried create makes precisely that
    # orphan, with a second one the caller does get an id for sitting beside it.
    with {:ok, response} <-
           post(
             "/market-data/watchlists/create",
             body,
             credentials,
             send_once(opts)
           ),
         {:ok, row} <- first_row(response),
         # `:id` is in `Types.Watchlist`'s `@enforce_keys`, so its `new/1` refuses a `nil`
         # there — and nothing here calls `new/1`, the struct being built literally as
         # everywhere in this family, so that check never ran. A created watchlist with no
         # id is the worst moment for one: the list now exists at the venue and the caller
         # has no handle to add to, read or delete it, and `nil` looks like a value.
         #
         # `to_watchlist/2` further down already refuses a row with no `watchlist_id`,
         # citing `dp_exchange_robinhood`'s rule — "a nil key there is worse than one fewer
         # row this cycle". This is the same rule on the create path.
         {:ok, id} <- created_watchlist_id(row) do
      add_created_members(id, name, symbols, credentials, opts)
    end
  end

  defp created_watchlist_id(row) do
    case value(row, ["watchlist_id"]) do
      nil -> {:error, {:missing_required_field, :id}}
      "" -> {:error, {:missing_required_field, :id}}
      id -> {:ok, id}
    end
  end

  defp add_created_members(id, name, [], _credentials, _opts) do
    {:ok, %Watchlist{id: id, name: name, symbols: [], venue_time: nil, provider: :webull}}
  end

  defp add_created_members(id, name, symbols, credentials, opts) do
    case add_watchlist_instruments(id, symbols, credentials, opts) do
      {:ok, _result} ->
        {:ok,
         %Watchlist{id: id, name: name, symbols: symbols, venue_time: nil, provider: :webull}}

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
  """
  @spec update_watchlist(String.t(), map(), keyword()) ::
          {:ok, Watchlist.t()} | {:error, term()} | {:refused, term()}
  def update_watchlist(watchlist_id, credentials, opts) when is_binary(watchlist_id) do
    if Keyword.has_key?(opts, :symbols) do
      {:error, :membership_not_updatable_here}
    else
      body =
        %{"watchlist_id" => watchlist_id}
        |> put_present("name", Keyword.get(opts, :name))
        |> put_present("sort", Keyword.get(opts, :sort))

      with {:ok, response} <-
             post("/market-data/watchlists/update", body, credentials, send_once(opts)),
           # `update-watchlist.md:168-186` documents the same `SuccessResponseVo`
           # `{"success": boolean}` shape every other watchlist write already guards with
           # `watchlist_success/1` (see its own comment: a `false` here is "a 200 that did
           # nothing"). This was the one watchlist write that discarded the response body
           # and reported `{:ok, watchlist}` for any 2xx, including a documented
           # `{"success": false}`.
           :ok <- watchlist_success(response) do
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
  call that deleted nothing.
  """
  @spec delete_watchlist(String.t(), map(), keyword()) ::
          {:ok, :ok} | {:error, term()} | {:refused, term()}
  def delete_watchlist(watchlist_id, credentials, opts) when is_binary(watchlist_id) do
    body = %{"watchlist_id" => watchlist_id}

    with {:ok, response} <-
           post("/market-data/watchlists/delete", body, credentials, send_once(opts)),
         :ok <- watchlist_success(response) do
      {:ok, :ok}
    end
  end

  @doc """
  Adds instruments to an existing watchlist — `POST /market-data/watchlists/instruments/add`.

  The venue caps an account at **1000 instruments across all watchlists** and rejects event
  contracts, futures and options here.
  """
  @spec add_watchlist_instruments(String.t(), [String.t()], map(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def add_watchlist_instruments(watchlist_id, symbols, credentials, opts),
    do: watchlist_membership("add", watchlist_id, symbols, credentials, opts)

  @doc """
  Removes instruments from a watchlist —
  `POST /market-data/watchlists/instruments/remove`.

  Removal is by symbol and category, not by the instrument id the listing returns — the
  venue's own asymmetry.
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
    case Keyword.get(opts, :sorts) do
      %{} = sorts when map_size(sorts) > 0 ->
        instruments =
          Enum.map(sorts, fn {symbol, position} ->
            %{
              "symbol" => symbol,
              "category" => fundamental_category(opts),
              "sort" => position
            }
          end)

        watchlist_write("update", watchlist_id, instruments, credentials, opts)

      _missing ->
        {:error, :sorts_required}
    end
  end

  defp watchlist_membership(action, watchlist_id, symbols, credentials, opts) do
    case List.wrap(symbols) do
      [] ->
        {:error, :symbols_required}

      list ->
        instruments =
          Enum.map(list, &%{"symbol" => &1, "category" => fundamental_category(opts)})

        watchlist_write(action, watchlist_id, instruments, credentials, opts)
    end
  end

  defp watchlist_write(action, watchlist_id, instruments, credentials, opts) do
    body = %{"watchlist_id" => watchlist_id, "instruments" => instruments}
    path = "/market-data/watchlists/instruments/#{action}"

    with {:ok, response} <- post(path, body, credentials, send_once(opts)),
         :ok <- watchlist_success(response) do
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

  # A row that cannot supply its own identity is dropped rather than published under an
  # empty one. `Core.Types.Watchlist`, `NewsItem` and `ScreenerResult` each enforce their
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
      nil -> nil
      id -> build_watchlist(id, row, symbols)
    end
  end

  defp build_watchlist(id, row, symbols) do
    %Watchlist{
      id: id,
      name: value(row, ["name"]),
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
  The fundamentals kinds this venue publishes, as atoms.

  Twenty-three endpoints under one shape. `get_fundamental/4` reaches any of them; the
  contract's own callbacks — `get_financials/3`, `get_corporate_events/1`, `get_filings/2` —
  reach the handful the contract has types for.
  """
  @spec fundamental_kinds() :: [atom()]
  def fundamental_kinds, do: @fundamentals |> Map.keys() |> Enum.sort()

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
        base_params =
          %{"symbol" => symbol, "category" => fundamental_category(opts)}
          |> put_allowed(allowed, opts)

        fundamental_rows(kind, path, base_params, credentials, opts)

      :error ->
        {:error, {:unknown_fundamental, kind}}
    end
  end

  defp fundamental_rows(:fund_dividends, path, base_params, credentials, opts) do
    fetch_page = fn key ->
      params = put_present(base_params, "pagination_key", key)

      with {:ok, body} <- get(path, params, credentials, opts),
           {:ok, page_rows} <- rows(body) do
        {:ok, {page_rows, next_pagination_key(body)}}
      end
    end

    paginate(fetch_page)
  end

  defp fundamental_rows(_kind, path, params, credentials, opts) do
    with {:ok, body} <- get(path, params, credentials, opts), do: rows(body)
  end

  defp fundamental_category(opts), do: Config.opt(opts, :category, "US_STOCK")

  defp put_allowed(params, allowed, opts) do
    Enum.reduce(allowed, params, fn key, acc ->
      put_present(acc, to_string(key), Keyword.get(opts, key))
    end)
  end

  @doc """
  Financial statements for an issuer — `Types.FinancialStatement`.

  `kind` is the contract's own vocabulary: `:balance_sheet`, `:income`, `:cash_flow` or
  `:indicators`. **Anything else is refused**, including a fundamentals kind this venue
  publishes that is not a statement: `:company_profile` is real and is not a financial
  statement, and answering with it would put a profile in a statement's shape.

  Line items are the venue's own names, unchanged — see `Core.Types.FinancialStatement`.

  **`fiscal_period` is the venue's integer code translated through the venue's own legend**,
  which its page states as `0=FY, 1=Q1, 2=Q2, 3=Q3, 4=Q4`. The contract wants a label and
  the venue publishes a code, so the code is mapped with the venue's own key and the raw
  integer stays in `line_items` — a code this legend does not cover leaves the label `nil`
  rather than inventing one, and the integer is still there to read.
  """
  @spec get_financials(String.t(), atom(), map(), keyword()) ::
          {:ok, [FinancialStatement.t()]} | {:error, term()} | {:refused, term()}
  def get_financials(symbol, kind, credentials, opts)
      when kind in [:balance_sheet, :income, :cash_flow, :indicators] do
    with {:ok, rows} <- get_fundamental(statement_endpoint(kind), symbol, credentials, opts) do
      {:ok, Enum.map(rows, &to_statement(&1, symbol, kind))}
    end
  end

  def get_financials(_symbol, kind, _credentials, _opts),
    do: {:error, {:unsupported_statement_kind, kind}}

  defp statement_endpoint(:income), do: :income_statement
  defp statement_endpoint(kind), do: kind

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
      currency: value(row, ["currency"]),
      venue_time: nil,
      provider: :webull
    }
  end

  # The venue's own legend, from its page: `0=FY, 1=Q1, 2=Q2, 3=Q3, 4=Q4`. A code outside it
  # is `nil` — the raw integer is still in `line_items`, and a label this package invented
  # would be indistinguishable from one the venue published.
  defp fiscal_period_label(0), do: "FY"
  defp fiscal_period_label(period) when period in 1..4, do: "Q#{period}"
  defp fiscal_period_label(period) when is_binary(period), do: period
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
  """
  @spec get_corporate_events(map(), keyword()) ::
          {:ok, [CorporateEvent.t()]} | {:error, term()} | {:refused, term()}
  def get_corporate_events(credentials, opts) do
    with {:ok, symbol} <- required_symbol(opts),
         {:ok, kinds} <- corporate_event_kinds(Keyword.get(opts, :kind)) do
      Enum.reduce_while(kinds, {:ok, []}, fn kind, {:ok, acc} ->
        case get_fundamental(calendar_endpoint(kind), symbol, credentials, opts) do
          {:ok, rows} ->
            {:cont, {:ok, acc ++ Enum.map(rows, &to_corporate_event(&1, symbol, kind))}}

          error ->
            {:halt, error}
        end
      end)
    end
  end

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
      pay_date: statement_date(value(row, ["pay_date", "payment_date"])),
      announced_date: statement_date(value(row, ["declare_date"])),
      amount: decimal(value(row, ["amount", "dividend"])),
      currency: value(row, ["currency"]),
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
      currency: value(row, ["currency"]),
      ratio: nil,
      confirmed: nil,
      details: row,
      provider: :webull
    }
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
         {:ok, filing_rows} <- filings_from_envelope(envelope_rows) do
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
      id: value(row, ["id", "filing_id"]),
      form_type: value(row, ["form_type", "type"]),
      title: value(row, ["title", "name"]),
      url: value(row, ["url", "link"]),
      filed_at: filing_time(row),
      period_end: statement_date(value(row, ["period_end", "end_date"])),
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

  @doc """
  News summaries — `POST /market-data/news/summaries/get`.

  **This one is generated, not reported.** The vendor's own description is "Invokes LLM to
  generate news summaries", so the `summary` on the item this returns is a model's
  paraphrase and not any publisher's text. That is recorded here because a caller quoting
  it is quoting a summary, and `source` names the venue rather than a wire.

  `opts[:symbols]` is required — the endpoint summarises a watchlist, not the market —
  and takes a list. `opts[:lang]` is the venue's own enum and is sent only when given.

  ## The response is Server-Sent Events, not JSON — and one generated reply, not a list

  `news-summary.md:195` documents `200` as `"Server-Sent Events stream. Each message
  contains JSON data"`, with example frames `event:message
  data:{"type":"meta","args":{"sessionId":"1","convId":451107711450219}}` followed by a
  run of `event:message data:{"type":"text","message":"..."}` chunks — Wally, the venue's
  own assistant, streaming one answer a token or a sentence at a time. That is not a JSON
  object with a `data` array of news items, which is what this read before: `post/4`'s
  `decoded_body/1` calls `Jason.decode/1` on every response and refuses anything that is
  not valid JSON, so every call this package made to this endpoint before returned
  `{:error, {:undecodable_response, :webull}}` — the endpoint never worked at all.

  There is also no itemised "news list" in this shape to normalise into several
  `NewsItem`s — there is one generated reply, addressed to the symbols asked for. This
  returns it as a single-element list holding that one item, concatenating every `"text"`
  chunk into `:summary` in the order the venue sent them, with `:id` taken from the
  stream's own `meta` event (`sessionId`/`convId`) — the venue's own identifier for that
  conversation, not one this package invented, and required because
  `Core.Types.NewsItem.id` is non-nil.
  """
  @spec get_news(map(), keyword()) ::
          {:ok, [NewsItem.t()]} | {:error, term()} | {:refused, term()}
  def get_news(credentials, opts) do
    with {:ok, symbols} <- required_symbols(opts) do
      body =
        %{
          "category_symbols" => [
            %{"category" => fundamental_category(opts), "symbols" => symbols}
          ]
        }
        |> put_present("lang", Keyword.get(opts, :lang))

      with {:ok, raw} <- post_sse("/market-data/news/summaries/get", body, credentials, opts),
           {:ok, events} <- decode_sse(raw) do
        news_item_from_sse(events, symbols)
      end
    end
  end

  defp required_symbols(opts) do
    case Keyword.get(opts, :symbols) do
      [_first | _rest] = symbols -> {:ok, symbols}
      symbol when is_binary(symbol) -> {:ok, [symbol]}
      _missing -> {:error, :symbols_required}
    end
  end

  defp required_symbol(opts) do
    case Keyword.get(opts, :symbol) do
      symbol when is_binary(symbol) -> {:ok, symbol}
      _missing -> {:error, :symbol_required}
    end
  end

  # Every `data:` line is one JSON event (`news-summary.md:195`'s own example frames); a
  # line the venue did not send as valid JSON is dropped rather than refusing the whole
  # stream, the same tolerance `HttpClient` gives a body that decoded but was not JSON —
  # this stream is a live LLM's output and a single malformed frame in the middle of it is
  # not evidence the rest is unreadable.
  defp decode_sse(body) when is_binary(body) do
    events =
      body
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.filter(&String.starts_with?(&1, "data:"))
      |> Enum.map(&(&1 |> String.trim_leading("data:") |> String.trim()))
      |> Enum.reject(&(&1 == ""))
      |> Enum.flat_map(fn line ->
        case Jason.decode(line) do
          {:ok, event} -> [event]
          {:error, _reason} -> []
        end
      end)

    case events do
      [] -> {:error, :unexpected_response_shape}
      _some -> {:ok, events}
    end
  end

  defp decode_sse(_other), do: {:error, :unexpected_response_shape}

  defp news_item_from_sse(events, asked_for) do
    case sse_conversation_id(events) do
      nil ->
        {:error, {:missing_required_field, :id}}

      id ->
        {:ok,
         [
           %NewsItem{
             id: id,
             headline: nil,
             summary: sse_summary_text(events),
             url: nil,
             # The venue generated this; naming a publisher would attribute a paraphrase
             # to them.
             source: "webull",
             symbols: asked_for,
             # The stream carries no timestamp of its own (`news-summary.md:195`'s frames
             # are `meta`/`text` only) — `nil` rather than the moment this package
             # happened to receive the last chunk, which would be this package's clock,
             # not the venue's.
             published_at: nil,
             provider: :webull
           }
         ]}
    end
  end

  defp sse_conversation_id(events) do
    Enum.find_value(events, fn
      %{"type" => "meta", "args" => %{"convId" => conv_id}} -> to_string(conv_id)
      %{"type" => "meta", "args" => %{"sessionId" => session_id}} -> to_string(session_id)
      _other -> nil
    end)
  end

  defp sse_summary_text(events) do
    events
    |> Enum.filter(&match?(%{"type" => "text"}, &1))
    |> Enum.map_join("", &Map.get(&1, "message", ""))
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
      {"/market-data/screeners/week52-high-low/list", [:rank_type, :sort_by, :direction]}
  }

  @paginated_screeners ["market_sectors", "market_sector"]

  @doc "The screeners this venue publishes, by the identifier `get_screener/4` takes."
  @spec screeners() :: [String.t()]
  def screeners, do: @screeners |> Map.keys() |> Enum.sort()

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

  An identifier this venue does not publish is `{:error, {:unknown_screener, name}}`.
  """
  @spec get_screener(String.t(), map(), keyword()) ::
          {:ok, [ScreenerResult.t()]} | {:error, term()} | {:refused, term()}
  def get_screener(name, credentials, opts) do
    case Map.fetch(@screeners, name) do
      {:ok, {path, allowed}} ->
        with :ok <- require_rank_type(name, opts) do
          base_params =
            %{"category" => fundamental_category(opts)}
            |> put_allowed(allowed, opts)
            |> screener_defaults(name)

          with {:ok, screener_rows} <-
                 screener_rows(name, path, base_params, credentials, opts) do
            {:ok,
             screener_rows
             |> Enum.with_index(1)
             |> Enum.map(&to_screener_result(&1, name))
             |> Enum.reject(&is_nil/1)}
          end
        end

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

  # Dropped AFTER `Enum.with_index/2`, so a survivor keeps the position the venue returned it
  # in. Closing the gap would re-rank the list, which is the same thing the `rank` comment
  # below rules out for a different reason.
  defp to_screener_result({row, rank}, name) do
    case value(row, ["symbol", "sector_name", "name"]) do
      nil -> nil
      symbol -> build_screener_result(symbol, row, rank, name)
    end
  end

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
    with :ok <- symbols_or_code(opts) do
      params =
        %{"category" => "US_FUTURES"}
        |> put_present("symbols", symbols_param(Keyword.get(opts, :symbols)))
        |> put_present("code", symbols_param(Keyword.get(opts, :code)))
        |> put_present("status", Keyword.get(opts, :status))

      with {:ok, body} <-
             get("/trading/instruments/futures/contracts/list", params, credentials, opts) do
        rows(body)
      end
    end
  end

  defp symbols_or_code(opts) do
    if Keyword.get(opts, :symbols) || Keyword.get(opts, :code) do
      :ok
    else
      {:error, :symbols_or_code_required}
    end
  end

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
           get("/trading/instruments/futures/product-classes/list", params, credentials, opts) do
      rows(body)
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
           get("/trading/instruments/event-contracts/categories/list", %{}, credentials, opts) do
      rows(body)
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
    params =
      %{}
      |> put_present("category", Keyword.get(opts, :category))
      |> put_present("symbols", symbols_param(Keyword.get(opts, :symbols)))
      |> put_present("pagination_key", Keyword.get(opts, :pagination_key))

    with {:ok, body} <-
           get("/trading/instruments/event-contracts/series/list", params, credentials, opts) do
      paged(body)
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
    case Keyword.get(opts, :series_symbol) do
      nil ->
        {:error, :series_symbol_required}

      series ->
        params =
          %{"series_symbol" => series}
          |> put_present("symbols", symbols_param(Keyword.get(opts, :symbols)))
          |> put_present("status", Keyword.get(opts, :status))

        with {:ok, body} <-
               get("/trading/instruments/event-contracts/events/list", params, credentials, opts) do
          rows(body)
        end
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
    params =
      %{}
      |> put_present("series_symbol", Keyword.get(opts, :series_symbol))
      |> put_present("event_symbol", Keyword.get(opts, :event_symbol))
      |> put_present("symbols", symbols_param(Keyword.get(opts, :symbols)))
      |> put_present("expiration_date_after", date_param(Keyword.get(opts, :expiring_after)))
      |> put_present("pagination_key", Keyword.get(opts, :pagination_key))

    with {:ok, body} <-
           get("/trading/instruments/event-contracts/markets/list", params, credentials, opts) do
      paged(body)
    end
  end

  defp date_param(%Date{} = date), do: Date.to_iso8601(date)
  defp date_param(other), do: other

  # `nil` where the venue sent no key, which is its way of saying this was the last page.
  # A missing key and an empty string are the same thing here and both mean the end.
  defp paged(%{"data" => data} = body) when is_list(data),
    do: {:ok, %{rows: data, pagination_key: presence(body["pagination_key"])}}

  defp paged(body) do
    case rows(body) do
      {:ok, page_rows} -> {:ok, %{rows: page_rows, pagination_key: nil}}
      {:error, _reason} = error -> error
    end
  end

  defp presence(""), do: nil
  defp presence(value), do: value

  @doc """
  The tape for one event-contract market —
  `GET /market-data/event-contracts/ticks/list`.

  **Not `get_trades/3`, and that is not an omission.** An event tick carries a `yes_price`
  *and* a `no_price` and a `side` of `yes`/`no`; `Types.Trade` carries one price and a side
  of `:buy`/`:sell`. Mapping `yes` to `:buy` would file the print against the other
  instrument of a two-instrument market, and the number would look right. So the venue's own
  rows are returned and nothing is normalised.

  The venue's default count here is **30**, not the 200 its other tapes use.
  """
  @spec get_event_trades(String.t(), map(), keyword()) ::
          {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def get_event_trades(symbol, credentials, opts) do
    params =
      %{"symbol" => symbol, "category" => "US_EVENT"}
      |> put_present("count", Keyword.get(opts, :limit))

    with {:ok, body} <-
           get("/market-data/event-contracts/ticks/list", params, credentials, opts),
         {:ok, row} <- first_row(body) do
      list_value(row, ["result"])
    end
  end

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
  level maps and its `quote_time` in milliseconds.
  """
  @spec get_event_order_book(String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def get_event_order_book(symbol, credentials, opts) do
    params =
      %{"symbol" => symbol, "category" => "US_EVENT"}
      |> put_present("depth", Keyword.get(opts, :depth))

    with {:ok, body} <-
           get("/market-data/event-contracts/depths/list", params, credentials, opts),
         {:ok, row} <- first_row(body) do
      {:ok,
       %{
         symbol: value(row, ["symbol"]) || symbol,
         yes_bids: List.wrap(value(row, ["yes_bids"])),
         yes_asks: List.wrap(value(row, ["yes_asks"])),
         no_bids: List.wrap(value(row, ["no_bids"])),
         no_asks: List.wrap(value(row, ["no_asks"])),
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
  """
  @spec get_option_chain(String.t(), map(), keyword()) ::
          {:ok, OptionChain.t()} | {:error, term()} | {:refused, term()}
  def get_option_chain(underlying, credentials, opts) do
    with {:ok, contracts} <- option_contracts(underlying, credentials, opts) do
      {:ok,
       %OptionChain{
         underlying: underlying,
         expiries: chain_grid(contracts),
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

    with {:ok, contract_rows} <- paginate(fetch_page) do
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
    with {:ok, expiry} <- option_expiry(value(row, ["expiration_date", "expirationDate"])),
         {:ok, strike} <- option_strike(value(row, ["strike_price", "strikePrice", "strike"])),
         {:ok, right} <- option_right(value(row, ["direction", "option_type", "optionType"])) do
      {:ok,
       %OptionContract{
         underlying: underlying,
         expiry: expiry,
         strike: strike,
         right: right,
         venue_symbol: value(row, ["symbol", "instrument_id", "instrumentId"]),
         multiplier: decimal(value(row, ["multiplier", "unit"])),
         settlement_type: value(row, ["settlement_method", "settlementMethod"]),
         expiration_type: value(row, ["expired_cycle", "expiredCycle"]),
         last_trading_day: option_last_trading_day(row),
         # The venue names none of these three on this endpoint. `nil` says "not published",
         # and `false` would say "the venue told us it is not one".
         index_option: nil,
         mini: nil,
         non_standard: nil,
         provider: :webull
       }}
    else
      :error -> {:error, {:unreadable_option_contract, Map.keys(row)}}
    end
  end

  defp to_option_contract(row, _underlying), do: {:error, {:unreadable_option_contract, row}}

  defp option_expiry(nil), do: :error

  defp option_expiry(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> :error
    end
  end

  defp option_expiry(_other), do: :error

  defp option_strike(nil), do: :error

  defp option_strike(value) do
    case decimal(value) do
      nil -> :error
      strike -> {:ok, strike}
    end
  end

  # The venue's own words for the two sides. Anything else is `:error` rather than a default
  # side — a put filed as a call is a position the opposite way round.
  defp option_right(value) when is_binary(value) do
    case String.upcase(value) do
      "CALL" -> {:ok, :call}
      "C" -> {:ok, :call}
      "PUT" -> {:ok, :put}
      "P" -> {:ok, :put}
      _other -> :error
    end
  end

  defp option_right(_other), do: :error

  defp option_last_trading_day(row) do
    case option_expiry(value(row, ["last_trade_date", "lastTradeDate", "last_trading_day"])) do
      {:ok, date} -> date
      :error -> nil
    end
  end

  # A strike listed with only one side keeps a `nil` on the other, rather than being absent:
  # a caller iterating strikes has to see that the put is missing.
  defp chain_grid(contracts) do
    Enum.reduce(contracts, %{}, fn contract, grid ->
      strikes = Map.get(grid, contract.expiry, %{})
      row = Map.get(strikes, contract.strike, %{call: nil, put: nil})

      Map.put(
        grid,
        contract.expiry,
        Map.put(strikes, contract.strike, Map.put(row, contract.right, contract))
      )
    end)
  end

  # --- decoding -----------------------------------------------------------

  # Groups carry their rows under "result"; a flat bar decodes directly. Mapping a row
  # decoder over the groups yields all-nil bars, which reads as "the venue has no data".
  defp decode_bars(body, symbol, timeframe) do
    with {:ok, body_rows} <- rows(body) do
      body_rows
      |> Enum.flat_map(fn
        %{"result" => group_rows} when is_list(group_rows) -> group_rows
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
  defp decode_bar(row, symbol, timeframe) do
    with {:ok, timestamp} <- venue_time(row),
         {:ok, open} <- required_decimal(value(row, ["open"]), :open),
         {:ok, high} <- required_decimal(value(row, ["high"]), :high),
         {:ok, low} <- required_decimal(value(row, ["low"]), :low),
         {:ok, close} <- required_decimal(value(row, ["close"]), :close) do
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
  defp before_end?(bar, finish), do: DateTime.compare(bar.opened_at, finish) != :gt

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
  defp refusal(status, body) do
    case refusal_body(body) do
      %{"msg" => message} when is_binary(message) -> {:venue_error, status, message}
      %{"message" => message} when is_binary(message) -> {:venue_error, status, message}
      %{"error_description" => detail} when is_binary(detail) -> {:venue_error, status, detail}
      %{"code" => code} -> {:venue_error, status, code}
      _other -> {:venue_error, status}
    end
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
  defp wire_number(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp wire_number(value), do: to_string(value)

  defp decimal(nil), do: nil
  defp decimal(%Decimal{} = value), do: value
  defp decimal(value) when is_integer(value), do: Decimal.new(value)
  defp decimal(value) when is_float(value), do: Decimal.from_float(value)

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
        if Decimal.nan?(parsed) or Decimal.inf?(parsed), do: nil, else: parsed

      _unparsable ->
        nil
    end
  end

  defp decimal(_other), do: nil

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
         {:ok, order_type, tif} <- combination(request),
         {:ok, leaf} <- order_leaf(request, order_type, tif) do
      body = %{
        "account_id" => account_id,
        "new_orders" => [Map.put(leaf, "client_order_id", client_order_id(request))]
      }

      with {:ok, response} <- post("/trading/orders/place", body, credentials, send_once(opts)) do
        to_placed_order(response, request, order_type, tif)
      end
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

  Each order takes the same shape `place_order/3` builds, and `client_order_id` is generated
  per order where the caller did not supply one — the venue requires one per order and
  requires them unique per account.

  Returns the venue's own rows, one per order, unnormalised: the venue validates per order
  and a batch where three of five were accepted is the normal shape, not the exception.
  """
  @spec place_orders(map(), [map()], keyword()) ::
          {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def place_orders(credentials, requests, opts) do
    with {:ok, account_id} <- account_id(opts),
         :ok <- batch_size(requests),
         {:ok, orders} <- batch_orders(requests) do
      body = %{"account_id" => account_id, "batch_orders" => orders}

      with {:ok, response} <-
             post("/trading/orders/batch-place", body, credentials, send_once(opts)) do
        batch_rows(response)
      end
    end
  end

  # `order-batch-place.md:266-328` documents this endpoint's OWN response envelope —
  # `{total, success, failed, batch_orders: [...]}` — not the generic `{"data": [...]}`
  # shape `rows/1` reads everywhere else. Calling `rows/1` directly on it fell through to
  # its bare-object clause, which wrapped the WHOLE envelope as a single one-element list:
  # a batch of N orders always answered with exactly one "row" — the envelope itself,
  # holding `total`/`success`/`failed` — never the N per-order results this function's own
  # moduledoc promises ("Returns the venue's own rows, one per order").
  defp batch_rows(%{"batch_orders" => rows}) when is_list(rows), do: {:ok, rows}
  defp batch_rows(other), do: rows(other)

  @batch_limit 50

  defp batch_size([]), do: {:error, :empty_batch}

  defp batch_size(requests) when length(requests) > @batch_limit,
    do: {:error, {:batch_too_large, length(requests), @batch_limit}}

  defp batch_size(_requests), do: :ok

  defp batch_orders(requests) do
    requests
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {request, index}, {:ok, acc} ->
      case batch_order(request, index) do
        {:ok, order} -> {:cont, {:ok, acc ++ [order]}}
        error -> {:halt, error}
      end
    end)
  end

  # Equities only, by the venue's own note. A crypto order in a batch is refused by index so
  # a caller knows which of fifty it was, rather than reading a venue message about a field.
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

  # **The batch endpoint's own schema, narrower than `place_order/3`'s.**
  # `order-batch-place.md:157-244` requires `order_type` MARKET or LIMIT — not `STOP_LOSS`,
  # `STOP_LOSS_LIMIT` or `TRAILING_STOP_LOSS`, all real for the single-order endpoint —
  # `time_in_force` DAY (its own enum has exactly one member), `entrust_type` QTY (no
  # `AMOUNT` here at all) and `support_trading_session`, which the single-order schema
  # leaves optional but this one lists as required. Checked against that schema rather
  # than discovered from a venue rejection: `order_leaf/3`, which `place_order/3` uses,
  # builds a wider order than this endpoint accepts, so a batch entry is built separately
  # here instead of reusing it.
  defp batch_leaf(request) do
    with {:ok, order_type} <- batch_order_type(request),
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
        |> put_present("limit_price", price_for(request, order_type))

      {:ok, leaf}
    end
  end

  # The batch schema's `time_in_force` enum has exactly one member, `DAY`
  # (order-batch-place.md:236-243). `DAY` is sent explicitly when the caller left it
  # unset — the same reasoning `get_order_book/3`'s `overnight_required` already states
  # for a required field with one legal value — but a caller who explicitly asked for
  # something else (`:gtc`, `:fok`, …) is refused rather than silently switched to `DAY`:
  # sending the one legal value regardless of what was asked for would be exactly the
  # substitution `entrust/3` above and `CLAUDE.md`'s fail-closed rule both refuse to make.
  defp batch_time_in_force(request) do
    case Map.get(request, :time_in_force, :day) do
      :day -> :ok
      other -> {:error, {:unsupported_batch_time_in_force, other}}
    end
  end

  defp batch_order_type(request) do
    case Map.get(request, :order_type, :limit) do
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
      {nil, nil} -> {:error, :missing_order_size}
      {quantity, nil} -> {:ok, %{"entrust_type" => "QTY", "quantity" => wire_number(quantity)}}
      {_quantity, _amount} -> {:error, :cash_sizing_not_supported_for_batch}
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
        {:error, :support_trading_session_required}

      session ->
        wire = session |> to_string() |> String.upcase()

        if wire in @support_trading_sessions do
          {:ok, wire}
        else
          {:error, {:unsupported_support_trading_session, session}}
        end
    end
  end

  defp account_id(opts) do
    case Keyword.get(opts, :account_id) do
      nil -> {:error, :account_id_required}
      account_id -> {:ok, account_id}
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

  @doc """
  The type/time-in-force pairs this venue accepts for `instrument`, or an error naming an
  instrument type this package cannot build an order for.

  Exposed so the fake enforces the same matrix rather than a hand-copied one that drifts.
  """
  @spec order_combinations(atom()) :: {:ok, [{atom(), atom()}]} | {:error, term()}
  def order_combinations(instrument), do: allowed_combinations(instrument)

  # A request that does not say is crypto, which is what this package served before the
  # instrument types widened. Changing that default would silently re-route existing
  # callers' orders onto a different market.
  defp instrument_type(request), do: Map.get(request, :instrument_type, :crypto)

  defp combination(request) do
    instrument = instrument_type(request)
    type = Map.get(request, :order_type, :limit)
    tif = Map.get(request, :time_in_force, default_tif(instrument))

    with {:ok, allowed} <- allowed_combinations(instrument) do
      if {type, tif} in allowed do
        {:ok, @order_type_names[type], @tif_names[tif]}
      else
        {:error, {:unsupported_order_combination, instrument, type, tif}}
      end
    end
  end

  # GTC on everything the venue lists it for; crypto keeps the default it always had.
  defp default_tif(:event), do: :gtc
  defp default_tif(_instrument), do: :gtc

  defp allowed_combinations(instrument) do
    case Map.fetch(@combinations, instrument) do
      {:ok, allowed} -> {:ok, allowed}
      :error -> {:error, {:unsupported_instrument_type, instrument}}
    end
  end

  defp order_leaf(request, order_type, tif) do
    instrument = instrument_type(request)

    with {:ok, entrust, sizing} <- entrust(request, order_type, instrument),
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
        |> put_present("limit_price", price_for(request, order_type))
        |> put_present("stop_price", stop_for(request, order_type))
        |> put_present("trailing_stop_step", trailing_stop_step_for(request, order_type))
        |> put_present("expire_date", expire_date(request, tif))
        |> put_present("event_outcome", Map.get(request, :event_outcome))
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
  defp expire_date(request, "GTD"), do: Map.get(request, :expire_date)
  defp expire_date(_request, _tif), do: nil

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
        {:error, :missing_order_size}

      {quantity, nil} ->
        {:ok, "QTY", %{"quantity" => wire_number(quantity)}}

      {nil, amount} ->
        amount_entrust(order_type, instrument, amount)

      {_quantity, _amount} ->
        {:error, :ambiguous_order_size}
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
    do: {:error, :cash_sizing_not_supported_for_stop}

  defp amount_entrust(_order_type, _instrument, amount),
    do: {:ok, "AMOUNT", %{"total_cash_amount" => wire_number(amount)}}

  # Only the two order types the venue documents `limit_price` for actually take it — see
  # the field table on `replace_order/4`'s own moduledoc, read from the same vendor
  # reference: `LIMIT` and `STOP_LOSS_LIMIT`. A plain `STOP_LOSS` has no limit leg at all,
  # only a trigger, and sending one anyway would assert a field the venue's schema for that
  # order type does not have — a caller building a stop request from a limit-order template
  # (leaving `:price` set) must not have it silently escape onto the wire on the wrong order
  # type.
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

  defp to_placed_order(response, request, order_type, tif) do
    case first_row(response) do
      {:ok, row} ->
        {:ok,
         %Order{
           # **The client_order_id, not the venue's order id.**
           #
           # Webull's whole order API is keyed on the client id: `/orders/cancel` takes it,
           # `/orders/get` takes it. Returning the venue's own `order_id` here would hand a
           # caller an identifier that round-trips nowhere — place, then cancel, and the
           # cancel fails on an id the venue does not accept.
           id: value(row, ["client_order_id", "clientOrderId"]),
           symbol: Map.fetch!(request, :symbol),
           side: Map.fetch!(request, :side),
           order_type: order_type_atom(order_type),
           time_in_force: tif_atom(tif),
           quantity: Map.get(request, :quantity),
           price: Map.get(request, :price),
           # Echoed from the caller's own request, the same as `price` and `quantity`
           # above — the venue's `/orders/place` response carries only the accepted
           # `client_order_id` and nothing else to build an `Order` from. Missing before
           # this fix, the same gap `stop_for/2` had on the request side: a caller placing
           # a STOP_LOSS or STOP_LOSS_LIMIT order got `stop_price: nil` back from the very
           # call that set it.
           stop_price: Map.get(request, :stop_price),
           status: :pending,
           provider: :webull
         }}

      _no_row ->
        {:error, :unexpected_response_shape}
    end
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
  @spec cancel_order(map(), String.t(), keyword()) ::
          {:ok, :cancelled} | {:error, term()} | {:refused, term()}
  def cancel_order(credentials, client_order_id, opts) do
    with {:ok, account_id} <- account_id(opts) do
      body = %{"account_id" => account_id, "client_order_id" => client_order_id}

      with {:ok, _response} <- post("/trading/orders/cancel", body, credentials, send_once(opts)) do
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
  @spec get_order(map(), String.t(), keyword()) ::
          {:ok, Order.t()} | {:error, term()} | {:refused, term()}
  def get_order(credentials, client_order_id, opts) do
    with {:ok, account_id} <- account_id(opts) do
      params = %{"account_id" => account_id, "client_order_id" => client_order_id}

      with {:ok, body} <- get("/trading/orders/get", params, credentials, opts),
           {:ok, group} <- first_row(body),
           # Refused rather than filled in from `client_order_id`: that would be publishing
           # the caller's own argument as though the venue had confirmed it.
           {:ok, %Order{id: id} = order} when is_binary(id) <- to_order(group) do
        {:ok, order}
      else
        {:ok, %Order{id: nil}} -> {:error, {:missing_required_field, :id}}
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
    with {:ok, account_id} <- account_id(opts) do
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
    {:ok,
     %Order{
       id: value(group, ["client_order_id", "clientOrderId"]) || leg_id(leg),
       symbol: leg |> value(["symbol"]) |> canonical_or_nil(),
       side: leg |> value(["side"]) |> side_atom(),
       order_type: leg |> value(["order_type", "orderType"]) |> order_type_atom(),
       time_in_force: leg |> value(["time_in_force", "timeInForce"]) |> tif_atom(),
       quantity: decimal(value(leg, ["total_quantity", "totalQuantity"])),
       filled_quantity: decimal(value(leg, ["filled_quantity", "filledQuantity"])),
       price: decimal(value(leg, ["limit_price", "limitPrice"])),
       stop_price: decimal(value(leg, ["stop_price", "stopPrice"])),
       # `filled_price` is documented as "Average transaction price of the filled
       # quantity" (`order-detail.md`) — `Core.Types.Order.average_price`'s own meaning,
       # not a separate field. The venue names no `avg_filled_price` anywhere this
       # package's own reference pages cover; that key was never proven, only assumed.
       average_price: decimal(value(leg, ["filled_price", "filledPrice"])),
       status: leg |> value(["status"]) |> status_atom(),
       provider: :webull
     }}
  end

  defp to_order(%{"orders" => [_first | _rest]} = group),
    do: {:error, {:unsupported_combo_type, Map.get(group, "combo_type")}}

  defp to_order(%{"orders" => []}), do: {:error, {:missing_required_field, :orders}}
  defp to_order(_other), do: {:error, :unexpected_response_shape}

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

  defp group_id(group) when is_map(group), do: value(group, ["client_order_id", "clientOrderId"])
  defp group_id(_group), do: nil

  defp leg_id(leg), do: value(leg, ["client_order_id", "clientOrderId"])

  defp canonical_or_nil(nil), do: nil
  # Only a string is a symbol. A map or a list used to reach
  # `SymbolFormat.to_canonical_symbol/1` and raise out of `get_order/3`, `get_orders/2` and
  # `get_positions/2` (REST mutation fuzz, 2026-09-27). It is now the same absent symbol as
  # `nil`: an order carries it as `nil` and a position refuses it.
  defp canonical_or_nil(native) when is_binary(native),
    do: SymbolFormat.to_canonical_symbol(native)

  defp canonical_or_nil(_absent), do: nil

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
  # own FAILED status as the rejected-order case. `SUBMITTED` gets no such statement
  # anywhere on the page ("submitted to the exchange or webull" says nothing about whether
  # the order is working), and `Core.Types.Order.status/0` has no slot for "submitted,
  # outcome unknown" — so it stays `nil` rather than being guessed as `:open`.
  defp status_atom("PENDING"), do: :pending
  defp status_atom("PARTIAL_FILLED"), do: :partially_filled
  defp status_atom("FILLED"), do: :filled
  defp status_atom("CANCELLED"), do: :cancelled
  defp status_atom("FAILED"), do: :rejected
  defp status_atom(_other), do: nil
end
