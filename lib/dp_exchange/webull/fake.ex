defmodule DpExchange.Webull.Fake do
  @moduledoc """
  An in-process Webull, for a consumer's tier-1 tests and for the conformance suite.

  **It is not a mock.** Nothing is stubbed, no expectation is recorded, no call is
  verified. It is a real implementation of `DpExchange.Core.Venue` answering from memory,
  and it runs the *same* conformance suite as the real adapter.

  ## Two rules

  **Less capable is allowed. Differently capable is not.** Where this cannot answer it
  returns an error, never an empty success.

  **It never rewrites a value the caller supplied**, and never stamps the current clock —
  `@at` is fixed, because a fake that stamps `utc_now/0` cannot be used to test anything
  about freshness and is itself the substitution this family refuses.

  ## It models the three things that make this venue different

  - **Credentials are required for market data.** `get_price/2` without them is
    `{:refused, :missing_credentials}`, because the real venue signs every call and has no
    anonymous endpoint. A fake that answered anyway would let a consumer's test pass while
    the real call returns 401.
  - **No volume.** `volume` is `nil` on every quote and every bar, matching a venue that
    reports none. Returning `0` would look like a real measurement of no trading.
  - **UAT has no stream.** `subscribe/2` under `environment: :uat` refuses, exactly as the
    real feed does, rather than delivering fake production data.
  """

  @behaviour DpExchange.Core.Venue

  alias DpExchange.Core.{Notice, Types, Venue}
  alias DpExchange.Webull.{Environment, Rest}

  @symbols ~w(BTC-USD ETH-USD SOL-USD)

  @price %{"BTC-USD" => "77845.79", "ETH-USD" => "2951.40", "SOL-USD" => "121.66"}

  # Fixed, not `utc_now/0`.
  @at ~U[2026-08-28 12:00:00Z]

  @impl true
  def child_spec(opts),
    do: %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}

  @impl true
  def start_link(_opts), do: :ignore

  @impl true
  def provider_name, do: DpExchange.Webull.provider_name()

  @impl true
  def runtime_id, do: DpExchange.Webull.runtime_id()

  @impl true
  def asset_classes, do: DpExchange.Webull.asset_classes()

  @impl true
  def capabilities, do: DpExchange.Webull.capabilities()

  @impl true
  def get_price(symbol, opts \\ []) do
    with :ok <- authenticated(opts) do
      case Map.fetch(@price, symbol) do
        {:ok, price} ->
          {:ok,
           %Types.Quote{
             symbol: symbol,
             price: Decimal.new(price),
             # This venue reports no volume anywhere. `nil`, never zero.
             volume: nil,
             timestamp: @at,
             provider: :webull
           }}

        :error ->
          {:refused, :not_listed}
      end
    end
  end

  @impl true
  def get_top_of_book(symbol, opts \\ []) do
    with :ok <- authenticated(opts) do
      case Map.fetch(@price, symbol) do
        {:ok, price} ->
          {:ok,
           %Types.TopOfBook{
             symbol: symbol,
             # A spread around the fake's price, with the bid deliberately not equal to it:
             # a test that passes only when they coincide is not testing the split.
             bid: Decimal.sub(Decimal.new(price), Decimal.new("0.25")),
             ask: Decimal.add(Decimal.new(price), Decimal.new("0.50")),
             bid_size: nil,
             ask_size: nil,
             venue_time: @at,
             observed_at: @at,
             provider: :webull
           }}

        :error ->
          {:refused, :not_listed}
      end
    end
  end

  @impl true
  def get_historical_prices(symbol, timeframe, range \\ [], opts \\ []) do
    with :ok <- authenticated(opts) do
      cond do
        symbol not in @symbols ->
          {:refused, :not_listed}

        timeframe not in Rest.timeframes() ->
          # Includes `12h` and `1w`, which the shared vocabulary models and this venue
          # does not serve — `1w` deliberately, since its boundary is unverifiable.
          {:error, {:unsupported_timeframe, timeframe}}

        true ->
          {:ok, [candle(symbol, timeframe)] |> Enum.filter(&within?(&1, range))}
      end
    end
  end

  @impl true
  def get_symbols(opts \\ []) do
    with :ok <- authenticated(opts), do: {:ok, @symbols}
  end

  @impl true
  def get_order_book(_symbol, _opts), do: Venue.not_supported()
  @impl true
  def get_market_overview(_opts), do: Venue.not_supported()
  @impl true
  def list_instruments(_opts), do: Venue.not_supported()
  @impl true
  def get_balances(_credentials, _opts), do: Venue.not_supported()
  @impl true
  def get_accounts(_credentials, _opts), do: Venue.not_supported()
  @impl true
  def get_fees(_credentials, _opts), do: Venue.not_supported()
  @impl true
  def get_transfers(_credentials, _opts), do: Venue.not_supported()
  # Both refused, matching the real venue. A fake that answered where the real one
  # refuses lets a consumer's suite go green against behaviour that cannot happen.
  @impl true
  def preview_order(_credentials, _request, _opts \\ []), do: Venue.not_supported()

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
  @impl true
  def test_connection(_credentials, _opts), do: Venue.not_supported()
  @impl true
  def get_rate_limit_status(_credentials, _opts), do: Venue.not_supported()
  @impl true
  def quantization(_symbol), do: Venue.not_supported()

  @impl true
  def market_status(_opts), do: {:ok, :open}

  @impl true
  def subscribe(symbols, opts \\ []) do
    environment = Environment.resolve(opts)

    if Environment.streaming?(environment) do
      target = Keyword.get(opts, :to, self())

      for symbol <- symbols, symbol in @symbols do
        case get_price(symbol, credentials: %{app_key: "fake", app_secret: "fake"}) do
          {:ok, quote_struct} -> send(target, {:dp_exchange, :webull, quote_struct})
          _refused -> :ok
        end
      end

      Process.put(__MODULE__, MapSet.new(Enum.filter(symbols, &(&1 in @symbols))))
      :ok
    else
      {:error, {:streaming_unavailable, environment}}
    end
  end

  @impl true
  def unsubscribe(symbols, _opts \\ []) do
    Process.put(__MODULE__, MapSet.difference(subscribed(), MapSet.new(symbols)))
    :ok
  end

  @impl true
  def update_symbols(symbols, _opts \\ []) do
    Process.put(__MODULE__, MapSet.new(Enum.filter(symbols, &(&1 in @symbols))))
    :ok
  end

  @impl true
  def coverage(_opts \\ []), do: Map.new(subscribed(), &{&1, :stream})

  @impl true
  def subscribe_notices(opts \\ []) do
    send(Keyword.get(opts, :to, self()), {:dp_exchange, :webull, Notice.new(:link_up, :webull)})
    :ok
  end

  defp subscribed, do: Process.get(__MODULE__, MapSet.new())

  # The real venue signs every call and has no anonymous endpoint, so a fake that answered
  # without credentials would let a consumer's test pass while the real call returns 401.
  defp authenticated(opts) do
    case Keyword.get(opts, :credentials) do
      %{app_key: _key, app_secret: _secret} -> :ok
      _absent -> {:refused, :missing_credentials}
    end
  end

  defp candle(symbol, timeframe) do
    price = Decimal.new(@price[symbol])

    %{
      symbol: symbol,
      timeframe: timeframe,
      timestamp: @at,
      open: price,
      high: price,
      low: price,
      close: price,
      volume: nil,
      provider: :webull
    }
  end

  defp within?(candle, range) do
    after_start?(candle, Keyword.get(range, :start)) and
      before_end?(candle, Keyword.get(range, :end))
  end

  defp after_start?(_candle, nil), do: true
  defp after_start?(candle, start), do: DateTime.compare(candle.timestamp, start) != :lt

  defp before_end?(_candle, nil), do: true
  defp before_end?(candle, finish), do: DateTime.compare(candle.timestamp, finish) != :gt

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
  def get_positions(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_funding(_symbol, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_contract_stats(_symbol, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_staking_rates(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_staking_balances(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_staking_rewards(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_staking_history(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def stake(_asset, _amount, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def unstake(_asset, _amount, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def quote_conversion(_from, _to, _amount, _opts \\ []),
    do: DpExchange.Core.Venue.not_supported()

  @impl true
  def commit_conversion(_id, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_conversion(_id, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def list_portfolios(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_deposit_address(_asset, _network, _opts \\ []),
    do: DpExchange.Core.Venue.not_supported()

  @impl true
  def list_approved_addresses(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def estimate_withdrawal_fee(_asset, _network, _amount, _opts \\ []),
    do: DpExchange.Core.Venue.not_supported()

  @impl true
  def withdraw(_asset, _network, _amount, _address, _opts \\ []),
    do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_option_chain(_underlying, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_option_expirations(_underlying, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_option_greeks(_symbol, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def list_watchlists(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_watchlist(_id, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def create_watchlist(_name, _symbols, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def update_watchlist(_id, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def delete_watchlist(_id, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_financials(_symbol, _kind, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_corporate_events(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_filings(_symbol, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_news(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_screener(_name, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def create_account(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def rename_account(_id, _name, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_roles(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def place_order(_credentials, request, opts \\ []) do
    # The fake enforces the venue's crypto matrix and its account requirement, so a
    # consumer's suite cannot go green on an order this venue would reject.
    with :ok <- fake_account(opts),
         :ok <- fake_combination(request) do
      {:ok,
       %Types.Order{
         id: "fake-webull-order-1",
         symbol: Map.fetch!(request, :symbol),
         side: Map.fetch!(request, :side),
         order_type: Map.get(request, :order_type, :limit),
         time_in_force: Map.get(request, :time_in_force, :gtc),
         quantity: Map.get(request, :quantity),
         price: Map.get(request, :price),
         status: :pending,
         provider: :webull
       }}
    end
  end

  defp fake_account(opts) do
    if Keyword.get(opts, :account_id), do: :ok, else: {:error, :account_id_required}
  end

  defp fake_combination(request) do
    pair = {Map.get(request, :order_type, :limit), Map.get(request, :time_in_force, :gtc)}

    if pair in [
         {:market, :ioc},
         {:limit, :day},
         {:limit, :gtc},
         {:stop_limit, :day},
         {:stop_limit, :gtc}
       ] do
      :ok
    else
      {type, tif} = pair
      {:error, {:unsupported_order_combination, type, tif}}
    end
  end
end
