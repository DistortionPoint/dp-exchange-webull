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
    {:get_positions, 1},
    {:get_funding, 2},
    {:get_contract_stats, 2},
    {:get_staking_rates, 1},
    {:get_staking_balances, 1},
    {:get_staking_rewards, 1},
    {:get_staking_history, 1},
    {:stake, 3},
    {:unstake, 3},
    {:quote_conversion, 4},
    {:commit_conversion, 2},
    {:get_conversion, 2},
    {:list_portfolios, 1},
    {:get_deposit_address, 3},
    {:list_approved_addresses, 1},
    {:estimate_withdrawal_fee, 4},
    {:withdraw, 5},
    {:get_option_chain, 2},
    {:get_option_expirations, 2},
    {:get_option_greeks, 2},
    {:list_watchlists, 1},
    {:get_watchlist, 2},
    {:create_watchlist, 3},
    {:update_watchlist, 2},
    {:delete_watchlist, 2},
    {:get_financials, 3},
    {:get_corporate_events, 1},
    {:get_filings, 2},
    {:get_news, 1},
    {:get_screener, 2},
    {:create_account, 1},
    {:rename_account, 3},
    {:get_roles, 1},
    # **Both endpoints exist. The venue excludes crypto from them, which this package only
    # serves.** Read from the vendor's own reference pages on 2026-09-01:
    #
    #   /trading/orders/preview  — "For crypto trading, this feature is currently not
    #                              supported."
    #   /trading/orders/replace  — "Modifies equity, options and futures orders […] For
    #                              crypto trading, this feature is currently not supported."
    #
    # The previous note here said preview "has no endpoint at all", which was false — a
    # claim about the venue that the venue contradicts. What is true is narrower and worth
    # stating exactly: the endpoints are documented, and they are documented as excluding
    # the one asset class this package declares.
    #
    # So `replace_order/4` is not merely unimplemented; on crypto there is nothing to
    # implement. A caller wanting a different order cancels and re-places, which is NOT
    # equivalent — it opens a window in which no order is live — and that window is the
    # venue's, not this package's.
    {:preview_order, 3},
    {:replace_order, 4},
    {:get_order_book, 2},
    {:get_market_overview, 1},
    {:list_instruments, 1},
    {:get_accounts, 2},
    {:get_fees, 2},
    {:get_transfers, 2},
    {:get_trade_history, 2},
    {:get_balances, 2},
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

  @impl true
  def asset_classes, do: [:crypto]

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
      supported_instrument_types: [:spot],

      # The venue's documented crypto matrix: MARKET takes IOC only; LIMIT and
      # STOP_LOSS_LIMIT take DAY or GTC. There is no market GTC and no limit IOC, and
      # `place_order/3` refuses a pair outside it rather than letting the venue reject it.
      supported_order_types: [:market, :limit, :stop_limit],
      supported_time_in_force: [:ioc, :day, :gtc],
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
  def get_order_book(_symbol, _opts), do: Venue.not_supported()

  @impl true
  def get_market_overview(_opts), do: Venue.not_supported()

  @impl true
  def list_instruments(_opts), do: Venue.not_supported()

  # --- account and trading -----------------------------------------------

  @impl true
  def get_balances(_credentials, _opts), do: Venue.not_supported()
  @impl true
  def get_accounts(_credentials, _opts), do: Venue.not_supported()
  @impl true
  def get_fees(_credentials, _opts), do: Venue.not_supported()
  @impl true
  def get_transfers(_credentials, _opts), do: Venue.not_supported()
  @impl true
  def place_order(credentials, request, opts \\ []),
    do: Rest.place_order(credentials, request, with_limiter(opts))

  @doc """
  **Not supported.** This venue publishes no order-preview endpoint.

  Declared through `supports_order_preview: false`, so a consumer routes around it rather
  than discovering the refusal at call time.
  """
  @impl true
  def preview_order(_credentials, _request, _opts \\ []), do: Venue.not_supported()

  @doc """
  **Not supported.** This venue has no atomic replace; a caller cancels and re-places.

  That is not equivalent — it opens a window in which no order is live — which is why
  `supports_order_replace: false` is a claim about **risk** rather than convenience.
  """
  @impl true
  def replace_order(_credentials, _id, _request, _opts \\ []), do: Venue.not_supported()

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
  def get_positions(_opts), do: Venue.not_supported()

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
  def list_portfolios(_opts), do: Venue.not_supported()

  @impl true
  def get_deposit_address(_asset, _network, _opts), do: Venue.not_supported()

  @impl true
  def list_approved_addresses(_opts), do: Venue.not_supported()

  @impl true
  def estimate_withdrawal_fee(_asset, _network, _amount, _opts), do: Venue.not_supported()

  @impl true
  def withdraw(_asset, _network, _amount, _address, _opts), do: Venue.not_supported()

  @impl true
  def get_option_chain(_underlying, _opts), do: Venue.not_supported()

  @impl true
  def get_option_expirations(_underlying, _opts), do: Venue.not_supported()

  @impl true
  def get_option_greeks(_symbol, _opts), do: Venue.not_supported()

  @impl true
  def list_watchlists(_opts), do: Venue.not_supported()

  @impl true
  def get_watchlist(_id, _opts), do: Venue.not_supported()

  @impl true
  def create_watchlist(_name, _symbols, _opts), do: Venue.not_supported()

  @impl true
  def update_watchlist(_id, _opts), do: Venue.not_supported()

  @impl true
  def delete_watchlist(_id, _opts), do: Venue.not_supported()

  @impl true
  def get_financials(_symbol, _kind, _opts), do: Venue.not_supported()

  @impl true
  def get_corporate_events(_opts), do: Venue.not_supported()

  @impl true
  def get_filings(_symbol, _opts), do: Venue.not_supported()

  @impl true
  def get_news(_opts), do: Venue.not_supported()

  @impl true
  def get_screener(_name, _opts), do: Venue.not_supported()

  @impl true
  def create_account(_opts), do: Venue.not_supported()

  @impl true
  def rename_account(_id, _name, _opts), do: Venue.not_supported()

  @impl true
  def get_roles(_opts), do: Venue.not_supported()
end
