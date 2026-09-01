defmodule DpExchange.Webull do
  @moduledoc """
  Webull, behind the DpExchange facade.

  > #### ⚠️ EXPERIMENTAL {: .warning}
  >
  > This package has not run in production. While it is `0.x` the API may change without a
  > major version — pin all three segments. **Maturity is declared per endpoint** through
  > `capabilities/0`; do not read this banner as your check.

  **This module is the entire public API of this package.** Transport, signing, session
  handling and supervision are internal, and nothing here returns them.

  ## Credentials are required for market data, which is unusual

  Every Webull OpenAPI call is signed — including the ones that look public. There is no
  anonymous quote endpoint. `capabilities/0` declares `credential_benefit: :required`, the
  first venue in this family to do so, and `get_price/2` takes credentials that the same
  call on other venues does not need.

  The host still owns authentication: it holds the App Key and secret and passes them in.
  This package signs one request with them and keeps nothing.

  ## Two transports, and you see neither

  Market data arrives over **MQTT 3.1.1 carried on a WebSocket**; subscriptions are
  **HTTP** calls; the two are joined by a session identifier this package generates. You
  call `subscribe/2` with symbols.

  That matters beyond tidiness. The venue does **not** restore subscriptions after a
  reconnect — this package replays them. A consumer doing that itself would have to notice
  reconnects, which is exactly what the facade exists to hide.

  ## The UAT environment has REST but no stream

  `environment: :uat` gives authenticated REST against test data. It has **no broker** —
  `mqtt-uat.webullbroker.com` does not resolve — so `subscribe/2` there returns
  `{:error, {:streaming_unavailable, :uat}}` rather than quietly falling back to
  production. A consumer testing against UAT that received production prices would be
  reading real market data believing it was fake.

  ## No trade volume, anywhere

  Webull's crypto OpenAPI reports no volume: not on bars, not on the snapshot, not on the
  stream. `volume` is `nil`, never `0`, and `capabilities/0` says
  `reports_trade_volume: false` so volume-dependent work can be routed elsewhere rather
  than reading a column of zeroes.

  ## Supervision

      children = [{DpExchange.Webull, []}]

      {:ok, quote} = DpExchange.Webull.get_price("BTC-USD", credentials: my_credentials())
  """

  @behaviour DpExchange.Core.Venue

  alias DpExchange.Core.{Capabilities, Venue}
  alias DpExchange.Webull.{Environment, Feed, Rest, SymbolFormat}

  # Not implemented in this release. None of them is about authentication — the host
  # supplies credentials and these simply have not been ported yet, which is a different
  # claim from "the venue does not serve them" and is stated as such.
  @unsupported [
    # Core 0.1.16's wider facade — declared, not yet implemented. Each is a Phase 3–13
    # item. `:unsupported` is about this package unless the note says otherwise.
    {:get_funding, 2},
    {:get_contract_stats, 2},
    {:get_staking_rates, 1},
    {:get_staking_balances, 1},
    {:get_staking_rewards, 1},
    {:get_staking_history, 1},
    {:stake, 3},
    {:unstake, 3},
    # **No one-step convert and no account volume report.** `convert/4` is the form where
    # the venue executes without holding a rate; this venue publishes neither that nor the
    # two-step quote/commit pair. `get_trade_volume/2` likewise — the venue reports fills,
    # and summing them here would be this package's arithmetic rather than the venue's
    # ledger, which is the number its fee tiers actually come from.
    {:convert, 4},
    {:get_trade_volume, 2},
    {:quote_conversion, 4},
    {:commit_conversion, 2},
    {:get_conversion, 2},
    {:list_portfolios, 1},
    {:get_deposit_address, 3},
    {:list_approved_addresses, 1},
    {:estimate_withdrawal_fee, 4},
    {:withdraw, 5},
    # **Webull's published API moves no money and holds no funding rails.** Checked against
    # the venue's own endpoint list on 2026-09-01: there is no payment-method endpoint at
    # either scope, no bank registration, no crypto network list, no allowlist, and no
    # transfer between accounts. Funding is done in Webull's own applications, which need a
    # person. `/trading/activities/cash-activities/list` **reports** money that moved; it
    # does not move any.
    {:list_payment_methods, 2},
    {:get_payment_method, 3},
    {:add_payment_method, 2},
    {:transfer_internal, 4},
    {:request_approved_address, 4},
    {:remove_approved_address, 3},
    {:list_networks, 2},
    # No promotional fee list, no FX publication, no notional valuation and no custody
    # product on this venue's API either.
    {:list_fee_promos, 1},
    {:get_fx_rate, 3},
    {:get_notional_balances, 3},
    {:list_custody_fees, 2},
    # **Webull publishes no greeks anywhere.** The option snapshot quotes the contract; it
    # does not publish delta, gamma or an implied volatility, and neither does any other
    # endpoint on this venue. Computing them here would be the most tempting substitution in
    # this package — Black-Scholes needs a rate and a volatility surface this venue does not
    # publish either, so every number would be this package's model presented as the
    # venue's. `get_option_chain/2` and `get_option_expirations/2` are live.
    {:get_option_greeks, 2},
    {:create_account, 1},
    {:rename_account, 3},
    {:get_roles, 1},
    # **`preview_replace/4` has no endpoint here.** The venue previews an order that does
    # not exist yet (`/trading/orders/preview`) and amends one that does
    # (`/trading/orders/replace`); it does not price an amendment in advance. Read from the
    # vendor's reference, 2026-09-01.
    #
    # `preview_order/3` and `replace_order/4` are implemented — both exclude crypto, which
    # they say for themselves, and this package now serves more than crypto.
    {:preview_replace, 4},
    # **No bulk cancel on this venue — read from its reference, 2026-09-01.**
    # `/trading/orders/cancel` takes one `client_order_id`. There is no cancel-all and no
    # cancel-session; a loop over `get_orders/2` would be N partial outcomes that cannot
    # reach an order placed between the listing and the cancels.
    {:cancel_all_orders, 2},
    # `/trading/assets/positions/list` exists and there is no endpoint that *closes* one.
    # Reading a position and placing the opposite order sizes against the last read, and a
    # position that moved leaves a residue — which is exactly what a venue-side close
    # avoids, and this venue does not offer.
    {:close_position, 3},
    {:get_market_overview, 1},
    {:list_instruments, 1},
    {:get_fees, 2},
    {:get_trade_history, 2},
    {:get_rate_limit_status, 2},
    {:test_connection, 2},
    {:quantization, 1}
  ]

  # --- lifecycle ---------------------------------------------------------

  @impl true
  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @impl true
  def start_link(opts), do: DpExchange.Webull.Supervisor.start_link(opts)

  # --- declaration -------------------------------------------------------

  @impl true
  def provider_name, do: "Webull"

  @impl true
  def runtime_id, do: :webull

  @doc """
  The asset classes this package serves.

  **`:equity` is here because the order builder serves it, not because the venue does.**
  Webull publishes stocks, options, futures and event contracts alongside crypto; this
  package's order path now builds all five instrument types, its preview and replace
  endpoints work on the four non-crypto ones, and `get_accounts/2` already returns the
  `CRYPTO`, `FUTURES` and `EVENTS_CASH` account classes the credential reaches.

  The coarse vocabulary is `:crypto | :equity | :option | :future | :event_contract`; the
  finer statement is `supported_instrument_types` below. A declaration that outran the code
  would be the worse error — a consumer routes on this.

  **Options joined on 2026-09-01**: the contract list, snapshot, bars and tape are live, and
  `US_OPTION` reaches its own endpoints rather than being refused on the stock ones — which
  is what this package claimed until that date, and was a false negative about the venue.

  **Futures and event contracts joined on the same day**: futures snapshots, bars, ticks,
  depths and footprints route by `US_FUTURES`, and the event-contract hierarchy — category,
  series, event, market — plus its snapshots, bars, ticks and depths are reachable. Each
  class is declared per endpoint through `capabilities/0`'s `endpoints` map, which is why
  that map exists rather than one flag per package.

  **Two event-contract endpoints are deliberately not behind the contract's callbacks.** An
  event tick has a yes price, a no price and a side of `yes`/`no`; an event book has four
  sides. `Types.Trade` and `Types.OrderBook` have room for neither, so `get_event_trades/2`
  and `get_event_order_book/2` return the venue's own rows and `get_trades/2` and
  `get_order_book/2` refuse `US_EVENT` rather than filing a print against the other
  instrument of a two-instrument market.
  """
  @impl true
  def asset_classes, do: [:crypto, :equity, :option, :future, :event_contract]

  @impl true
  def capabilities do
    Capabilities.new(
      endpoints: endpoint_maturities(),

      # Measured 2026-08-05 against the pre-D6 `/openapi/instrument/crypto/list`: 342
      # symbols, every one quoted in USD. The endpoint has since moved to
      # `/trading/instruments/crypto/profiles/list` and the measurement has not been
      # retaken — it needs a credential this repository does not hold. Treat 342 as the
      # last observed figure, not a current one.
      supported_quotes: ["USD"],
      # Five, because the order builder builds five. `Rest.order_instrument_types/0` is the
      # same list, so this cannot drift from what can actually be sent.
      # A share bought outright is `:spot` — the vocabulary has no separate `:equity`, and
      # does not need one: the distinction that matters is settled vs derivative.
      supported_instrument_types: [:spot, :option, :future, :event_contract],

      # The venue's documented crypto matrix: MARKET takes IOC only; LIMIT and
      # STOP_LOSS_LIMIT take DAY or GTC. There is no market GTC and no limit IOC, and
      # `place_order/3` refuses a pair outside it rather than letting the venue reject it.
      # The union across instrument types. Which pairs a given type accepts is narrower and
      # is enforced per instrument by `Rest.order_combinations/1` — crypto has five pairs,
      # an event contract has LIMIT only.
      supported_order_types: [:market, :limit, :stop, :stop_limit, :trailing_stop],
      supported_time_in_force: [:ioc, :day, :gtc, :gtd, :fok],

      # **Both true, and both scoped to the four non-crypto instrument types.** The venue
      # excludes crypto from its preview and replace endpoints and says so; the endpoints
      # themselves refuse a crypto request before it is sent, naming the reason.
      supports_order_preview: true,
      supports_order_replace: true,
      supports_short_selling: false,
      streamable: [:quotes],
      historical_timeframes: Rest.timeframes(),

      # Bounded by request parameters rather than a stated page size. `nil` until it is
      # measured, rather than a number that looks measured.
      max_candles_per_request: nil,

      # Webull's crypto OpenAPI exposes no trade volume anywhere. Declared so a consumer
      # routes volume-dependent work elsewhere instead of reading zeroes.
      reports_trade_volume: false,
      catalog_size: :small,

      # **The family's first `:required`.** Every call is signed, including the ones that
      # look public — there is no anonymous quote endpoint on this venue.
      credential_benefit: :required,
      public_ceiling: %{limit: 10, per_ms: 1_000},
      authenticated_ceiling: %{limit: 10, per_ms: 1_000},
      measured_at: ~D[2026-08-28],
      measured_against:
        "streaming contract, MQTT endpoints and protobuf schema read from " <>
          "developer.webull.com and verified live (1883 answers a TLS close_notify to a " <>
          "plaintext CONNECT; 8883/mqtt answers 101); symbol count and USD-only quoting " <>
          "inherited from the prior adapter's 2026-08-05 measurement and NOT re-measured " <>
          "here, since the catalogue endpoint requires credentials this repo does not hold"
    )
  end

  defp endpoint_maturities do
    active =
      for {name, arity} <- Venue.behaviour_info(:callbacks),
          {name, arity} not in @unsupported,
          into: %{},
          do: {{name, arity}, :experimental}

    Enum.reduce(@unsupported, active, &Map.put(&2, &1, :unsupported))
  end

  # --- market data -------------------------------------------------------

  @impl true
  def get_price(symbol, opts \\ []),
    do: Rest.get_price(symbol, credentials(opts), with_limiter(opts))

  @impl true
  def get_top_of_book(symbol, opts \\ []),
    do: Rest.get_top_of_book(symbol, credentials(opts), with_limiter(opts))

  @impl true
  def get_historical_prices(symbol, timeframe, range \\ [], opts \\ []),
    do:
      Rest.get_historical_prices(symbol, timeframe, range, credentials(opts), with_limiter(opts))

  @impl true
  def get_symbols(opts \\ []), do: Rest.get_symbols(credentials(opts), with_limiter(opts))

  @impl true
  @doc """
  The order book for an equity or ETF.

  See `DpExchange.Webull.Rest.get_order_book/3` — including why a crypto symbol is refused
  here, and what per-participant attribution this contract has no place for.
  """
  def get_order_book(symbol, opts \\ []),
    do: Rest.get_order_book(symbol, credentials(opts), with_limiter(opts))

  @doc """
  Tick-by-tick public trades for an equity or ETF — the tape.

  See `DpExchange.Webull.Rest.get_trades/3`, including why three of the venue's five side
  codes map to `nil`.
  """
  @impl true
  def get_trades(symbol, opts \\ []),
    do: Rest.get_trades(symbol, credentials(opts), with_limiter(opts))

  @doc """
  Traded volume split by price and by side, for an equity.

  See `DpExchange.Webull.Rest.get_volume_profile/4` — including the five widths this
  endpoint serves and why `real_time_required` is sent as `false`.
  """
  @impl true
  def get_volume_profile(symbol, timeframe, opts \\ []),
    do: Rest.get_volume_profile(symbol, timeframe, credentials(opts), with_limiter(opts))

  @doc """
  The auction order imbalance. `opts[:auction]` is required — `:opening` or `:closing`.

  See `DpExchange.Webull.Rest.get_auction_imbalance/3`, including why the venue's own time
  matters as much as the numbers outside an auction window.
  """
  @impl true
  def get_auction_imbalance(symbol, opts \\ []),
    do: Rest.get_auction_imbalance(symbol, credentials(opts), with_limiter(opts))

  @impl true
  def get_market_overview(_opts), do: Venue.not_supported()

  @impl true
  def list_instruments(_opts), do: Venue.not_supported()

  # --- account and trading -----------------------------------------------

  @impl true
  @doc """
  Balances for one account. Requires `opts[:account_id]`.

  See `DpExchange.Webull.Rest.get_balances/2` — in particular why `available_balance` is
  `nil` on this venue.
  """
  def get_balances(credentials, opts), do: Rest.get_balances(credentials, with_limiter(opts))
  @impl true
  @doc """
  Every account this credential can reach, as the venue records them.

  See `DpExchange.Webull.Rest.get_accounts/2`, including what `account_class` reveals about
  this venue's breadth.
  """
  def get_accounts(credentials, opts), do: Rest.get_accounts(credentials, with_limiter(opts))
  @impl true
  def get_fees(_credentials, _opts), do: Venue.not_supported()
  @impl true
  @doc """
  Money into and out of one account. Requires `opts[:account_id]`.

  See `DpExchange.Webull.Rest.get_transfers/2` — in particular why the endpoint's wider
  activity types are excluded unless asked for, and what the venue's 7-day default means
  for an empty answer.
  """
  def get_transfers(credentials, opts), do: Rest.get_transfers(credentials, with_limiter(opts))
  @impl true
  def place_order(credentials, request, opts \\ []),
    do: Rest.place_order(credentials, request, with_limiter(opts))

  @doc """
  Places several orders in one request. **This moves funds.**

  See `DpExchange.Webull.Rest.place_orders/3`. **Fifty at most and equities only**, both the
  venue's own limits and both enforced before the request; the vendor also notes the endpoint
  is not available to every client.
  """
  @impl true
  def place_orders(credentials, requests, opts),
    do: Rest.place_orders(credentials, requests, with_limiter(opts))

  @impl true
  @doc """
  Prices an order without placing it. Requires `opts[:account_id]`.

  See `DpExchange.Webull.Rest.preview_order/3` — including why crypto is refused, and what
  `estimated_cost` means on a futures order.
  """
  def preview_order(credentials, request, opts \\ []),
    do: Rest.preview_order(credentials, request, with_limiter(opts))

  @impl true
  @doc """
  Amends a working order in place, keyed on its client order id.

  See `DpExchange.Webull.Rest.replace_order/4` — including which fields each order type
  allows, and why the order is read back rather than reported from the request.
  """
  def replace_order(credentials, client_order_id, changes, opts \\ []),
    do: Rest.replace_order(credentials, client_order_id, changes, with_limiter(opts))

  @impl true
  def preview_replace(_credentials, _id, _changes, _opts \\ []), do: Venue.not_supported()

  @impl true
  def close_position(_credentials, _symbol, _opts \\ []), do: Venue.not_supported()

  @impl true
  def cancel_all_orders(_credentials, _opts \\ []), do: Venue.not_supported()

  @impl true
  def cancel_order(credentials, client_order_id, opts \\ []),
    do: Rest.cancel_order(credentials, client_order_id, with_limiter(opts))

  @impl true
  def get_order(credentials, client_order_id, opts \\ []),
    do: Rest.get_order(credentials, client_order_id, with_limiter(opts))

  @impl true
  def get_orders(credentials, opts \\ []), do: Rest.get_orders(credentials, with_limiter(opts))
  @impl true
  def get_trade_history(_credentials, _opts), do: Venue.not_supported()

  # --- streaming ---------------------------------------------------------

  @impl true
  def subscribe(symbols, opts), do: Feed.subscribe(feed(opts), symbols, opts)

  @impl true
  def unsubscribe(symbols, opts), do: Feed.unsubscribe(feed(opts), symbols, opts)

  @impl true
  def update_symbols(symbols, opts), do: Feed.update_symbols(feed(opts), symbols, opts)

  @impl true
  def coverage(opts \\ []) do
    feed = feed(opts)
    if alive?(feed), do: Feed.coverage(feed), else: %{}
  end

  @impl true
  def subscribe_notices(opts), do: Feed.subscribe_notices(feed(opts), opts)

  # --- health ------------------------------------------------------------

  @impl true
  def test_connection(_credentials, _opts), do: Venue.not_supported()

  @impl true
  def get_rate_limit_status(_credentials, _opts), do: Venue.not_supported()

  @impl true
  def market_status(_opts), do: {:ok, :open}

  @impl true
  def quantization(_symbol), do: Venue.not_supported()

  # --- internals ---------------------------------------------------------

  defp feed(opts), do: Keyword.get(opts, :feed, DpExchange.Webull.Supervisor.feed_name(opts))

  defp alive?(name) when is_atom(name), do: is_pid(GenServer.whereis(name))
  defp alive?(pid) when is_pid(pid), do: Process.alive?(pid)

  # Credentials are an argument on this venue's market data too, because it has no
  # anonymous endpoints. An absent map reaches `Auth` and is refused there with
  # `{:missing_credentials, :webull}` rather than producing an unsigned request.
  defp credentials(opts), do: Keyword.get(opts, :credentials, %{})

  defp with_limiter(opts) do
    Keyword.put_new(opts, :limiter, DpExchange.Webull.Supervisor.limiter_name(opts))
  end

  @doc """
  Whether this environment carries a live stream.

  Exposed because the answer differs by environment on this venue and a consumer should be
  able to ask before it commits, rather than learning from a subscription that never
  delivers.
  """
  @spec streaming?(keyword()) :: boolean()
  def streaming?(opts \\ []), do: opts |> Environment.resolve() |> Environment.streaming?()

  @doc "The quote currencies this venue settles in."
  @spec quotes() :: [String.t()]
  def quotes, do: SymbolFormat.quotes()

  # --- Declared but not yet implemented -----------------------------------
  #
  # Core 0.1.16 widened the facade to the surface the venues actually publish. These answer
  # `{:error, :not_supported}` and are declared `:unsupported` in `capabilities/0`, so a
  # consumer routing on the declaration is told the truth.
  #
  # **`:unsupported` here is a statement about this package, not about the venue.** That
  # distinction is the one Phase 1 had to correct after a package spent a year asserting a
  # venue had no streaming API when it had fifteen services. Where the venue genuinely does
  # not offer something, the comment beside it says so.

  @impl true
  @doc """
  Open positions on one account. Requires `opts[:account_id]`.

  See `DpExchange.Webull.Rest.get_positions/2`, including why the side comes from the sign
  of the quantity rather than an assumption.
  """
  def get_positions(opts), do: Rest.get_positions(credentials(opts), with_limiter(opts))

  @impl true
  def get_funding(_symbol, _opts), do: Venue.not_supported()

  @impl true
  def get_contract_stats(_symbol, _opts), do: Venue.not_supported()

  @impl true
  def get_staking_rates(_opts), do: Venue.not_supported()

  @impl true
  def get_staking_balances(_opts), do: Venue.not_supported()

  @impl true
  def get_staking_rewards(_opts), do: Venue.not_supported()

  @impl true
  def get_staking_history(_opts), do: Venue.not_supported()

  @impl true
  def stake(_asset, _amount, _opts), do: Venue.not_supported()

  @impl true
  def unstake(_asset, _amount, _opts), do: Venue.not_supported()

  @impl true
  def quote_conversion(_from, _to, _amount, _opts), do: Venue.not_supported()

  @impl true
  def commit_conversion(_id, _opts), do: Venue.not_supported()

  @impl true
  def get_conversion(_id, _opts), do: Venue.not_supported()

  @impl true
  def convert(_from, _to, _amount, _opts \\ []), do: Venue.not_supported()

  @impl true
  def get_trade_volume(_credentials, _opts \\ []), do: Venue.not_supported()

  @impl true
  def list_portfolios(_opts), do: Venue.not_supported()

  @impl true
  def get_deposit_address(_asset, _network, _opts), do: Venue.not_supported()

  @impl true
  def list_approved_addresses(_opts), do: Venue.not_supported()

  @impl true
  def estimate_withdrawal_fee(_asset, _network, _amount, _opts), do: Venue.not_supported()

  @impl true
  def withdraw(_asset, _network, _amount, _address, _opts), do: Venue.not_supported()

  @doc """
  Every cash activity on one account — wider than `get_transfers/2` and wider than fills.

  See `DpExchange.Webull.Rest.get_transactions/2`. The two are not interchangeable: a
  dividend and a deposit both credit cash and neither is the other, so a caller computing
  contributions uses `get_transfers/2` and one reconciling a balance uses this.
  """
  @impl true
  def get_transactions(credentials, opts),
    do: Rest.get_transactions(credentials, with_limiter(opts))

  @impl true
  def list_payment_methods(_credentials, _opts), do: Venue.not_supported()

  @impl true
  def get_payment_method(_credentials, _id, _opts), do: Venue.not_supported()

  @impl true
  def add_payment_method(_details, _opts), do: Venue.not_supported()

  @impl true
  def transfer_internal(_asset, _amount, _opts, _request_opts), do: Venue.not_supported()

  @impl true
  def request_approved_address(_asset, _network, _address, _opts), do: Venue.not_supported()

  @impl true
  def remove_approved_address(_network, _address, _opts), do: Venue.not_supported()

  @impl true
  def list_networks(_asset, _opts), do: Venue.not_supported()

  @impl true
  def list_fee_promos(_opts), do: Venue.not_supported()

  @impl true
  def get_fx_rate(_pair, _at, _opts), do: Venue.not_supported()

  @impl true
  def get_notional_balances(_credentials, _currency, _opts), do: Venue.not_supported()

  @impl true
  def list_custody_fees(_credentials, _opts), do: Venue.not_supported()

  @doc """
  The option chain for an underlying — expiry × strike, both sides.

  See `DpExchange.Webull.Rest.get_option_chain/3`. The venue publishes a flat contract list
  and the grid is rebuilt here; a contract this package cannot address is refused rather
  than dropped, so a chain never comes back with a hole in it that looks complete.
  """
  @impl true
  def get_option_chain(underlying, opts \\ []),
    do: Rest.get_option_chain(underlying, credentials(opts), with_limiter(opts))

  @doc """
  The expiries listed on an underlying.

  See `DpExchange.Webull.Rest.get_option_expirations/3`. Webull publishes no expiry-only
  endpoint, so these are the distinct expiries of a real contract list — a narrowing of a
  response the venue sent, not a substitute for one it did not.
  """
  @impl true
  def get_option_expirations(underlying, opts \\ []),
    do: Rest.get_option_expirations(underlying, credentials(opts), with_limiter(opts))

  @doc """
  Futures contracts by symbol or by product code.

  Venue-specific: the contract has no callback for a futures chain. See
  `DpExchange.Webull.Rest.list_futures_contracts/2` — one of `opts[:symbols]` or
  `opts[:code]` is required.
  """
  @spec list_futures_contracts(keyword()) ::
          {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def list_futures_contracts(opts \\ []),
    do: Rest.list_futures_contracts(credentials(opts), with_limiter(opts))

  @doc """
  The futures product classification groups.

  See `DpExchange.Webull.Rest.list_futures_product_classes/2`.
  """
  @spec list_futures_product_classes(keyword()) ::
          {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def list_futures_product_classes(opts \\ []),
    do: Rest.list_futures_product_classes(credentials(opts), with_limiter(opts))

  @doc """
  Every event-contract category — the root of category → series → event → market.

  See `DpExchange.Webull.Rest.list_event_categories/2`.
  """
  @spec list_event_categories(keyword()) :: {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def list_event_categories(opts \\ []),
    do: Rest.list_event_categories(credentials(opts), with_limiter(opts))

  @doc """
  Event-contract series, paged.

  See `DpExchange.Webull.Rest.list_event_series/2`. The returned `:pagination_key` is `nil`
  on the last page, which is how the end is told from a truncation.
  """
  @spec list_event_series(keyword()) ::
          {:ok, %{rows: [map()], pagination_key: String.t() | nil}}
          | {:error, term()}
          | {:refused, term()}
  def list_event_series(opts \\ []),
    do: Rest.list_event_series(credentials(opts), with_limiter(opts))

  @doc """
  The events under one series. `opts[:series_symbol]` is required.

  See `DpExchange.Webull.Rest.list_event_events/2`.
  """
  @spec list_event_events(keyword()) :: {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def list_event_events(opts \\ []),
    do: Rest.list_event_events(credentials(opts), with_limiter(opts))

  @doc """
  The tradable markets under a series or an event, paged.

  See `DpExchange.Webull.Rest.list_event_markets/2`. `status` and `tradable_status` are two
  different fields and both survive.
  """
  @spec list_event_markets(keyword()) ::
          {:ok, %{rows: [map()], pagination_key: String.t() | nil}}
          | {:error, term()}
          | {:refused, term()}
  def list_event_markets(opts \\ []),
    do: Rest.list_event_markets(credentials(opts), with_limiter(opts))

  @doc """
  The tape for one event-contract market.

  **Not `get_trades/2`.** See `DpExchange.Webull.Rest.get_event_trades/3`: an event tick has
  a yes price, a no price and a side of `yes`/`no`, and `Types.Trade` has room for one price
  and a side of `:buy`/`:sell`.
  """
  @spec get_event_trades(String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def get_event_trades(symbol, opts \\ []),
    do: Rest.get_event_trades(symbol, credentials(opts), with_limiter(opts))

  @doc """
  The order book for one event-contract market — **four books, not two**.

  See `DpExchange.Webull.Rest.get_event_order_book/3`. `Types.OrderBook` has one bid side and
  one ask side; a binary market quotes YES and NO separately and neither is the other.
  """
  @spec get_event_order_book(String.t(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def get_event_order_book(symbol, opts \\ []),
    do: Rest.get_event_order_book(symbol, credentials(opts), with_limiter(opts))

  @impl true
  def get_option_greeks(_symbol, _opts), do: Venue.not_supported()

  @doc """
  The watchlists held at the venue.

  See `DpExchange.Webull.Rest.list_watchlists/2`. `symbols` is `nil` on every row — this
  endpoint names watchlists and does not list membership, and `nil` is "not asked" where
  `[]` would be "empty".
  """
  @impl true
  def list_watchlists(opts \\ []),
    do: Rest.list_watchlists(credentials(opts), with_limiter(opts))

  @doc """
  One watchlist including its membership.

  See `DpExchange.Webull.Rest.get_watchlist/3`. `name` is `nil` here: the membership
  endpoint does not return it.
  """
  @impl true
  def get_watchlist(id, opts \\ []),
    do: Rest.get_watchlist(id, credentials(opts), with_limiter(opts))

  @doc """
  Creates a watchlist and adds `symbols` to it.

  See `DpExchange.Webull.Rest.create_watchlist/4`. **Two requests**, and where the second
  fails the watchlist exists and is empty — the error carries its id.
  """
  @impl true
  def create_watchlist(name, symbols, opts \\ []),
    do: Rest.create_watchlist(name, symbols, credentials(opts), with_limiter(opts))

  @doc """
  Renames a watchlist or changes its sort order. **Does not change membership.**

  See `DpExchange.Webull.Rest.update_watchlist/3` — `opts[:symbols]` is refused rather than
  silently skipped, and `add_watchlist_instruments/3` is the membership write.
  """
  @impl true
  def update_watchlist(id, opts \\ []),
    do: Rest.update_watchlist(id, credentials(opts), with_limiter(opts))

  @doc """
  Deletes a watchlist and everything in it. **Irreversible.**

  See `DpExchange.Webull.Rest.delete_watchlist/3`.
  """
  @impl true
  def delete_watchlist(id, opts \\ []),
    do: Rest.delete_watchlist(id, credentials(opts), with_limiter(opts))

  @doc """
  Adds instruments to a watchlist.

  Venue-specific: the contract's `update_watchlist/2` does not reach membership on this
  venue. See `DpExchange.Webull.Rest.add_watchlist_instruments/4`.
  """
  @spec add_watchlist_instruments(String.t(), [String.t()], keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def add_watchlist_instruments(id, symbols, opts \\ []),
    do: Rest.add_watchlist_instruments(id, symbols, credentials(opts), with_limiter(opts))

  @doc """
  Removes instruments from a watchlist, by symbol and category.

  See `DpExchange.Webull.Rest.remove_watchlist_instruments/4`.
  """
  @spec remove_watchlist_instruments(String.t(), [String.t()], keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def remove_watchlist_instruments(id, symbols, opts \\ []),
    do: Rest.remove_watchlist_instruments(id, symbols, credentials(opts), with_limiter(opts))

  @doc """
  Reorders instruments within a watchlist. `opts[:sorts]` maps symbol to position.

  See `DpExchange.Webull.Rest.sort_watchlist_instruments/3`.
  """
  @spec sort_watchlist_instruments(String.t(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def sort_watchlist_instruments(id, opts \\ []),
    do: Rest.sort_watchlist_instruments(id, credentials(opts), with_limiter(opts))

  @doc """
  Financial statements for an issuer.

  See `DpExchange.Webull.Rest.get_financials/4`. Line items keep the venue's own names, and
  `fiscal_period` keeps its integer code — `0` for the full year, `1`–`4` for quarters.
  """
  @impl true
  def get_financials(symbol, kind, opts \\ []),
    do: Rest.get_financials(symbol, kind, credentials(opts), with_limiter(opts))

  @doc """
  Dividends and earnings dates for one issuer. `opts[:symbol]` is required.

  See `DpExchange.Webull.Rest.get_corporate_events/2`. Without `opts[:kind]` both calendars
  are read, which is two requests.
  """
  @impl true
  def get_corporate_events(opts \\ []),
    do: Rest.get_corporate_events(credentials(opts), with_limiter(opts))

  @doc """
  Regulatory filings this venue indexes. **Points at them; never fetches them.**

  See `DpExchange.Webull.Rest.get_filings/3`.
  """
  @impl true
  def get_filings(symbol, opts \\ []),
    do: Rest.get_filings(symbol, credentials(opts), with_limiter(opts))

  @doc """
  News summaries. **Generated, not reported** — the venue's own description is "invokes LLM
  to generate news summaries", so each `summary` is a model's paraphrase.

  See `DpExchange.Webull.Rest.get_news/2`. `opts[:symbols]` is required.
  """
  @impl true
  def get_news(opts \\ []), do: Rest.get_news(credentials(opts), with_limiter(opts))

  @doc """
  A venue screener by the venue's own identifier — `screeners/0` lists them.

  See `DpExchange.Webull.Rest.get_screener/3`. Nothing is merged or re-ranked: the rank is
  the position the venue returned the row in.
  """
  @impl true
  def get_screener(name, opts \\ []),
    do: Rest.get_screener(name, credentials(opts), with_limiter(opts))

  @doc """
  One fundamentals endpoint by kind — the venue's own rows, unnormalised.

  Venue-specific: twenty-three endpoints under one shape, of which the contract has types
  for four. `fundamental_kinds/0` lists them; see
  `DpExchange.Webull.Rest.get_fundamental/4`.
  """
  @spec get_fundamental(atom(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def get_fundamental(kind, symbol, opts \\ []),
    do: Rest.get_fundamental(kind, symbol, credentials(opts), with_limiter(opts))

  @doc "The fundamentals kinds `get_fundamental/3` reaches."
  @spec fundamental_kinds() :: [atom()]
  defdelegate fundamental_kinds(), to: Rest

  @doc "The screener identifiers `get_screener/2` takes."
  @spec screeners() :: [String.t()]
  defdelegate screeners(), to: Rest

  @doc """
  Creates a server-to-server token. **The token comes back `PENDING` and is not usable yet.**

  Venue-specific. See `DpExchange.Webull.Rest.create_token/2` — verification happens through
  an SMS code in the Webull app, which needs a person.
  """
  @spec create_token(keyword()) :: {:ok, map()} | {:error, term()} | {:refused, term()}
  def create_token(opts \\ []),
    do: Rest.create_token(credentials(opts), with_limiter(opts))

  @doc """
  Checks a token's status — the call that tells `PENDING` from `EXPIRED` from `INVALID`.

  See `DpExchange.Webull.Rest.check_token/3`. All three fail the same way at the next
  request, and only this endpoint says which.
  """
  @spec check_token(String.t(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def check_token(token, opts \\ []),
    do: Rest.check_token(token, credentials(opts), with_limiter(opts))

  @doc """
  The OAuth code exchange and refresh — one endpoint, two operations.

  See `DpExchange.Webull.Rest.oauth_token/3`. `opts[:code]` exchanges, `opts[:refresh_token]`
  refreshes, and exactly one of them is required. **Two expiries come back and they are not
  the same clock**: `rt_expires_in` is the one that ends the session.
  """
  @spec oauth_token(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def oauth_token(client_id, client_secret, opts \\ []),
    do: Rest.oauth_token(client_id, client_secret, with_limiter(opts))

  @impl true
  def create_account(_opts), do: Venue.not_supported()

  @impl true
  def rename_account(_id, _name, _opts), do: Venue.not_supported()

  @impl true
  def get_roles(_opts), do: Venue.not_supported()
end
