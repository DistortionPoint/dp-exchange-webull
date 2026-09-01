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

  alias DpExchange.Core.Types.{
    AuctionImbalance,
    Balance,
    Candle,
    Order,
    OrderBook,
    Position,
    Quote,
    TopOfBook,
    Trade,
    VolumeProfile
  }

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

  # **Two snapshot endpoints, one per market**, and they are not interchangeable: the crypto
  # one takes `US_CRYPTO` and the stock one takes `US_STOCK` or `US_ETF` and refuses
  # `US_OPTION`. Sending a stock symbol to the crypto endpoint returns nothing rather than
  # an error, which is why the category picks the path here rather than being passed through.
  #
  # `opts[:category]` selects; the default is `US_CRYPTO`, which is what this package served
  # before its asset classes widened. Changing that default would silently re-route existing
  # callers onto a different market.
  defp snapshot_path("US_CRYPTO"), do: {:ok, "/market-data/crypto/snapshots/list"}

  defp snapshot_path(category) when category in ["US_STOCK", "US_ETF"],
    do: {:ok, "/market-data/stocks/snapshots/list"}

  defp snapshot_path(category), do: {:error, {:unsupported_snapshot_category, category}}

  # The stock snapshot publishes extended-hours and overnight blocks only when asked. Both
  # are marked optional by the venue and default to false, and this sends them explicitly so
  # a caller reading `nil` knows it did not ask rather than that the venue had nothing.
  defp snapshot_params(native, category, opts) do
    base = %{"symbols" => native, "category" => category}

    if category == "US_CRYPTO" do
      base
    else
      base
      |> Map.put("extend_hour_required", to_string(Keyword.get(opts, :extended_hours, false)))
      |> Map.put("overnight_required", to_string(Keyword.get(opts, :overnight, false)))
    end
  end

  @doc """
  Last price for one symbol.

  **Crypto and stocks are different endpoints**, chosen by `opts[:category]` — `US_CRYPTO`
  (the default), `US_STOCK` or `US_ETF`. `US_OPTION` is refused: the vendor states the stock
  snapshot does not serve it.

  ## Volume is `nil` on crypto and real on stocks

  This venue publishes no crypto volume anywhere, so a crypto quote's volume is `nil` —
  never zero, which would claim a genuinely flat interval. The **stock** snapshot does
  publish `volume`, and it is the day's aggregate rather than the last trade's size; the
  venue names no per-trade size on this endpoint, so that is what a caller gets and the
  field carries the venue's own meaning.
  """
  @spec get_price(String.t(), map(), keyword()) ::
          {:ok, Quote.t()} | {:error, term()} | {:refused, term()}
  def get_price(symbol, credentials, opts) do
    category = Keyword.get(opts, :category, "US_CRYPTO")

    with {:ok, path} <- snapshot_path(category) do
      native = snapshot_symbol(symbol, category)
      params = snapshot_params(native, category, opts)

      with {:ok, body} <- get(path, params, credentials, opts),
           {:ok, row} <- first_row(body),
           {:ok, price} <- required(row, ["price", "lastPrice", "last_trade_price"]),
           {:ok, timestamp} <- venue_time(row) do
        {:ok,
         %Quote{
           symbol: snapshot_canonical(native, category),
           price: decimal(price),
           volume: snapshot_volume(row, category),
           timestamp: timestamp,
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

  # `nil` on crypto because the venue reports none — not zero, which claims a flat interval.
  defp snapshot_volume(_row, "US_CRYPTO"), do: nil
  defp snapshot_volume(row, _category), do: decimal(value(row, ["volume"]))

  @doc """
  OHLC bars for a symbol and canonical timeframe.

  Bars carry no volume — see the module doc. A bar without a venue timestamp is an
  **error**, not a bar stamped with the local clock.
  """
  @spec get_historical_prices(String.t(), String.t(), keyword(), map(), keyword()) ::
          {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def get_historical_prices(symbol, timeframe, range, credentials, opts) do
    # Crypto and stocks are different endpoints — and different HTTP verbs. `opts[:category]`
    # picks, defaulting to crypto, which is what this package served before its asset
    # classes widened.
    case Keyword.get(opts, :category, "US_CRYPTO") do
      "US_CRYPTO" -> crypto_bars(symbol, timeframe, range, credentials, opts)
      _stock -> get_stock_bars(symbol, timeframe, range, credentials, opts)
    end
  end

  defp crypto_bars(symbol, timeframe, range, credentials, opts) do
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
    category = Keyword.get(opts, :category, "US_CRYPTO")

    with {:ok, path} <- snapshot_path(category) do
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
    category = Keyword.get(opts, :category, "US_CRYPTO")
    params = put_present(%{"category" => category}, "pagination_key", key)

    with {:ok, path} <- instruments_path(category),
         {:ok, body} <- get(path, params, credentials, opts) do
      collected = acc ++ rows(body)

      case next_pagination_key(body) do
        nil -> {:ok, collected}
        ^key -> {:error, :pagination_key_did_not_advance}
        next -> all_instrument_rows(next, credentials, opts, collected, page + 1)
      end
    end
  end

  # **Crypto and stock instruments are different endpoints**, and both paginate the same
  # way. The category picks; the default is crypto, which is what this package listed before
  # its asset classes widened.
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
      {:ok, rows(body)}
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
           get("/trading/assets/balances/get", %{"account_id" => account_id}, credentials, opts) do
      {:ok,
       body
       |> currency_assets()
       |> Enum.map(&to_balance(&1, asked_at))}
    end
  end

  defp currency_assets(body) when is_map(body) do
    case value(body, ["account_currency_assets", "accountCurrencyAssets"]) do
      rows when is_list(rows) -> rows
      _absent -> []
    end
  end

  defp currency_assets(_body), do: []

  defp to_balance(row, asked_at) do
    %Balance{
      currency: value(row, ["currency"]),
      balance: decimal(value(row, ["cash_balance", "cashBalance"])),
      # Not derived. See the note on get_balances/2: this venue publishes several
      # different "available" figures and they disagree.
      available_balance: nil,
      hold: decimal(value(row, ["frozen_amount", "frozenAmount"])),
      # When we asked. A balance has no venue event time.
      timestamp: asked_at,
      provider: :webull
    }
  end

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
           get("/trading/assets/positions/list", %{"account_id" => account_id}, credentials, opts) do
      {:ok, body |> rows() |> Enum.map(&to_position/1)}
    end
  end

  defp to_position(row) do
    {side, quantity} =
      row
      |> value(["quantity"])
      |> decimal()
      |> signed_quantity()

    %Position{
      symbol: row |> value(["symbol"]) |> canonical_or_nil(),
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
  """
  @spec get_transfers(map(), keyword()) ::
          {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def get_transfers(credentials, opts) do
    types = Keyword.get(opts, :activity_types, @transfer_activity_types)

    with {:ok, account_id} <- account_id(opts),
         :ok <- same_year(Keyword.get(opts, :start), Keyword.get(opts, :end)) do
      params =
        %{"account_id" => account_id, "activity_types" => Enum.join(types, ",")}
        |> put_present("start_time", iso_millis(Keyword.get(opts, :start)))
        |> put_present("end_time", iso_millis(Keyword.get(opts, :end)))
        |> put_present("page_size", Keyword.get(opts, :limit))
        |> put_present("last_activity_id", Keyword.get(opts, :after))

      with {:ok, body} <-
             get("/trading/activities/cash-activities/list", params, credentials, opts) do
        {:ok, rows(body)}
      end
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
    row = response |> rows() |> List.first() || response

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

  The venue's response carries no order, so **the order is read back**: reporting the change
  a caller asked for as though the venue had confirmed it is a different claim from
  reporting what the venue did.
  """
  @spec replace_order(map(), String.t(), map(), keyword()) ::
          {:ok, Order.t()} | {:error, term()} | {:refused, term()}
  def replace_order(credentials, client_order_id, changes, opts) do
    instrument = Keyword.get(opts, :instrument_type, :equity)
    order_type = Keyword.get(opts, :order_type, :limit)

    with :ok <- previewable(instrument),
         :ok <- amendable(order_type, changes),
         {:ok, account_id} <- account_id(opts) do
      body =
        %{"account_id" => account_id, "client_order_id" => client_order_id}
        |> put_present("quantity", Map.get(changes, :quantity))
        |> put_present("limit_price", Map.get(changes, :price))
        |> put_present("stop_price", Map.get(changes, :stop_price))
        |> put_present("trailing_stop_step", Map.get(changes, :trailing_stop_step))
        |> put_present("time_in_force", changes |> Map.get(:time_in_force) |> tif_name())

      with {:ok, _response} <- post("/trading/orders/replace", body, credentials, opts) do
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
  venue's own level count — L1 is 1, L2 defaults to 10. `opts[:overnight]` includes
  overnight trading data, and the venue **requires the parameter**, so `false` is sent
  explicitly rather than omitted.

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
    category = Keyword.get(opts, :category, "US_STOCK")

    with :ok <- book_category(category) do
      params = %{
        "symbol" => symbol,
        "category" => category,
        "depth" => to_string(Keyword.get(opts, :depth, 10)),
        # The venue marks this REQUIRED, so it is always sent — an omitted required
        # parameter is a refusal the caller cannot read.
        "overnight_required" => to_string(Keyword.get(opts, :overnight, false))
      }

      with {:ok, body} <- get("/market-data/stocks/depths/list", params, credentials, opts),
           {:ok, row} <- first_row(body) do
        to_order_book(row, symbol)
      end
    end
  end

  # The vendor's own enum. `US_OPTION` is listed as not supported here, and crypto has no
  # depth endpoint at all — its snapshot publishes a top of book and nothing beneath it.
  defp book_category(category) when category in ["US_STOCK", "US_ETF"], do: :ok
  defp book_category(category), do: {:error, {:unsupported_book_category, category}}

  defp to_order_book(row, symbol) do
    # `venue_time/1` already reads `quote_time`, which is what this endpoint stamps.
    with {:ok, timestamp} <- venue_time(row) do
      {:ok,
       %OrderBook{
         symbol: symbol,
         bids: book_levels(value(row, ["bids"])),
         asks: book_levels(value(row, ["asks"])),
         timestamp: timestamp,
         # No sequence on this endpoint. `nil` means the venue did not say, so a caller
         # cannot use this book to detect a gap in a stream.
         sequence: nil,
         provider: :webull
       }}
    end
  end

  # The level's own size, not a sum over its `order` array. Those are different numbers when
  # the venue reports partial attribution, and the level size is the one it stands behind.
  defp book_levels(rows) when is_list(rows) do
    for row <- rows,
        price = decimal(value(row, ["price"])),
        size = decimal(value(row, ["size"])),
        not is_nil(price),
        do: {price, size}
  end

  defp book_levels(_absent), do: []

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
    with {:ok, span} <- footprint_span(timeframe),
         {:ok, session} <- footprint_session(Keyword.get(opts, :session)) do
      params =
        %{
          "symbols" => symbol,
          "category" => "US_STOCK",
          "timespan" => span,
          # Completed intervals only; an unfinished footprint's split still moves.
          "real_time_required" => "false"
        }
        |> put_present("count", Keyword.get(opts, :count))
        |> put_present("trading_sessions", session)

      with {:ok, body} <- get("/market-data/stocks/footprints/list", params, credentials, opts),
           {:ok, row} <- first_row(body) do
        decode_profiles(row, symbol, timeframe)
      end
    end
  end

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
    row
    |> value(["result"])
    |> List.wrap()
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

      with {:ok, body} <- get(path, params, credentials, opts) do
        {:ok,
         body
         |> rows()
         |> Enum.map(&to_imbalance(&1, symbol, auction, observed_at))}
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
  defp to_string_or_nil(value), do: to_string(value)

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
    category = Keyword.get(opts, :category, "US_STOCK")

    with :ok <- book_category(category) do
      params = %{
        "symbol" => symbol,
        "category" => category,
        "count" => to_string(Keyword.get(opts, :limit, 30)),
        # Required by the venue. `RTH` is the default because it is the session the rest of
        # this package's price data comes from.
        "trading_sessions" => sessions_param(Keyword.get(opts, :sessions, ["RTH"]))
      }

      with {:ok, body} <- get("/market-data/stocks/ticks/list", params, credentials, opts),
           {:ok, row} <- first_row(body) do
        decode_ticks(row, symbol)
      end
    end
  end

  defp sessions_param(sessions) when is_list(sessions), do: Enum.join(sessions, ",")
  defp sessions_param(session), do: to_string(session)

  defp decode_ticks(row, symbol) do
    row
    |> value(["result"])
    |> List.wrap()
    |> Enum.reduce_while({:ok, []}, fn tick, {:ok, acc} ->
      case to_trade(tick, symbol) do
        {:ok, trade} -> {:cont, {:ok, [trade | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, trades} -> {:ok, Enum.reverse(trades)}
      error -> error
    end
  end

  defp to_trade(tick, symbol) do
    with {:ok, timestamp} <- venue_time(tick) do
      {:ok,
       %Trade{
         # The venue publishes no per-tick id on this endpoint. `nil` says so.
         id: nil,
         symbol: symbol,
         side: tick_side(value(tick, ["side"])),
         price: decimal(value(tick, ["price"])),
         quantity: decimal(value(tick, ["volume"])),
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
    category = Keyword.get(opts, :category, "US_STOCK")

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

  defp decode_stock_bars(response, symbol, timeframe, range) do
    response
    |> rows()
    |> Enum.flat_map(fn row -> row |> value(["result"]) |> List.wrap() end)
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
      {:ok, bars} -> {:ok, bars |> Enum.reverse() |> Enum.sort_by(& &1.opened_at, DateTime)}
      error -> error
    end
  end

  defp decode_bar(row, symbol, timeframe) do
    with {:ok, timestamp} <- venue_time(row) do
      {:ok,
       %Candle{
         symbol: symbol,
         timeframe: timeframe,
         opened_at: timestamp,
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
  defp after_start?(bar, start), do: DateTime.compare(bar.opened_at, start) != :lt

  defp before_end?(_bar, nil), do: true
  defp before_end?(bar, finish), do: DateTime.compare(bar.opened_at, finish) != :gt

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
         {:ok, order_type, tif} <- combination(request),
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

  defp tif_name(nil), do: nil
  defp tif_name(tif), do: Map.get(@tif_names, tif)

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

    with {:ok, entrust, sizing} <- entrust(request, order_type, instrument) do
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
        |> put_present("expire_date", expire_date(request, tif))
        |> put_present("event_outcome", Map.get(request, :event_outcome))

      {:ok, leaf}
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
  defp entrust(request, order_type, instrument) do
    quantity = Map.get(request, :quantity)
    amount = Map.get(request, :amount)

    case {quantity, amount} do
      {nil, nil} ->
        {:error, :missing_order_size}

      {quantity, nil} ->
        {:ok, "QTY", %{"qty" => to_string(quantity)}}

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
    do: {:ok, "AMOUNT", %{"amount" => to_string(amount)}}

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
           status: :pending,
           provider: :webull
         }}

      _no_row ->
        {:error, :unexpected_response_shape}
    end
  end

  defp order_type_atom("MARKET"), do: :market
  defp order_type_atom(nil), do: nil
  defp order_type_atom("LIMIT"), do: :limit
  defp order_type_atom("STOP_LOSS_LIMIT"), do: :stop_limit
  defp order_type_atom(_other), do: nil

  defp tif_atom("IOC"), do: :ioc
  defp tif_atom("DAY"), do: :day
  defp tif_atom("GTC"), do: :gtc
  defp tif_atom(_other), do: nil

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

      with {:ok, _response} <- post("/trading/orders/cancel", body, credentials, opts) do
        {:ok, :cancelled}
      end
    end
  end

  @doc """
  One order by its client order id.

  Requires `opts[:account_id]`.
  """
  @spec get_order(map(), String.t(), keyword()) ::
          {:ok, Order.t()} | {:error, term()} | {:refused, term()}
  def get_order(credentials, client_order_id, opts) do
    with {:ok, account_id} <- account_id(opts) do
      params = %{"account_id" => account_id, "client_order_id" => client_order_id}

      with {:ok, body} <- get("/trading/orders/get", params, credentials, opts),
           {:ok, row} <- first_row(body) do
        {:ok, to_order(row)}
      end
    end
  end

  @doc """
  Open orders, or historical ones with `history: true`.

  **These are two endpoints, not one with a filter.** `/orders/open-orders/list` and
  `/orders/historical-orders/list` answer different questions, and a caller asking for
  "orders" without saying which gets the open ones — the set that can still change.

  Requires `opts[:account_id]`. Returns one page; the venue paginates on `client_order_id`
  as a cursor and this does not follow it.
  """
  @spec get_orders(map(), keyword()) ::
          {:ok, [Order.t()]} | {:error, term()} | {:refused, term()}
  def get_orders(credentials, opts) do
    with {:ok, account_id} <- account_id(opts) do
      path =
        if Keyword.get(opts, :history, false),
          do: "/trading/orders/historical-orders/list",
          else: "/trading/orders/open-orders/list"

      params = put_present(%{"account_id" => account_id}, "page_size", Keyword.get(opts, :limit))

      with {:ok, body} <- get(path, params, credentials, opts) do
        {:ok, body |> rows() |> Enum.map(&to_order/1)}
      end
    end
  end

  # The venue's own order row. Anything it names that this package does not recognise
  # becomes `nil` rather than the nearest atom.
  defp to_order(row) do
    %Order{
      id: value(row, ["client_order_id", "clientOrderId"]),
      symbol: row |> value(["symbol"]) |> canonical_or_nil(),
      side: row |> value(["side"]) |> side_atom(),
      order_type: row |> value(["order_type", "orderType"]) |> order_type_atom(),
      time_in_force: row |> value(["time_in_force", "timeInForce"]) |> tif_atom(),
      quantity: decimal(value(row, ["qty", "quantity"])),
      filled_quantity: decimal(value(row, ["filled_qty", "filledQty"])),
      price: decimal(value(row, ["limit_price", "limitPrice"])),
      average_price: decimal(value(row, ["avg_filled_price", "avgFilledPrice"])),
      status: row |> value(["order_status", "status"]) |> status_atom(),
      provider: :webull
    }
  end

  defp canonical_or_nil(nil), do: nil
  defp canonical_or_nil(native), do: SymbolFormat.to_canonical_symbol(native)

  defp side_atom("BUY"), do: :buy
  defp side_atom("SELL"), do: :sell
  defp side_atom(_other), do: nil

  defp status_atom("PENDING"), do: :pending
  defp status_atom("WORKING"), do: :open
  defp status_atom("PARTIAL_FILLED"), do: :open
  defp status_atom("FILLED"), do: :filled
  defp status_atom("CANCELLED"), do: :cancelled
  defp status_atom("CANCELED"), do: :cancelled
  defp status_atom("REJECTED"), do: :rejected
  defp status_atom("EXPIRED"), do: :expired
  defp status_atom(_other), do: nil
end
