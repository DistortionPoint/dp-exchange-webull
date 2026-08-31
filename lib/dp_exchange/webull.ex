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
    # Neither exists on this venue. `preview_order/3` has no endpoint at all;
    # `replace_order/4` means a caller cancels and re-places, which is NOT equivalent —
    # it opens a window in which no order is live.
    {:preview_order, 3},
    {:replace_order, 4},
    {:get_order_book, 2},
    {:get_market_overview, 1},
    {:list_instruments, 1},
    {:get_accounts, 2},
    {:get_fees, 2},
    {:get_transfers, 2},
    {:place_order, 3},
    {:cancel_order, 3},
    {:get_order, 3},
    {:get_orders, 2},
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

      # Measured 2026-08-05 against `/openapi/instrument/crypto/list`: 342 symbols, every
      # one quoted in USD.
      supported_quotes: ["USD"],
      supported_instrument_types: [:spot],
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
  def place_order(_credentials, _request, _opts), do: Venue.not_supported()

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
  def cancel_order(_credentials, _id, _opts), do: Venue.not_supported()
  @impl true
  def get_order(_credentials, _id, _opts), do: Venue.not_supported()
  @impl true
  def get_orders(_credentials, _opts), do: Venue.not_supported()
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
end
