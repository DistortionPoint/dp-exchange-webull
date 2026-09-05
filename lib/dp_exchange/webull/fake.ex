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

  ## Failure injection and anonymous mode

  Every function below that has a real success path (not an unconditional
  `Venue.not_supported()`) checks `DpExchange.Core.FakeInjection.next_outcome/1` or `/2`
  first — a queued or always-set outcome from `FakeInjection.queue_failures/2,3` or
  `fail_always/2,3` short-circuits the fake's normal logic and is returned as-is.
  `authenticated/1` also checks `FakeInjection.credentials_bypassed?/1` before its normal
  `{:refused, :missing_credentials}` path. Neither changes anything for a test that never
  calls `FakeInjection` — see that module for the full contract.

  `subscribe/2`, `unsubscribe/2` and `update_symbols/2` are NOT wired: each takes a list
  of symbols in one call, and "this one symbol in the batch fails, the rest succeed" is a
  case whole-call injection cannot express — see `FakeInjection`'s own moduledoc.
  `place_orders/3` is the same shape for the same reason: one call, many orders.
  """

  @behaviour DpExchange.Core.Venue

  alias DpExchange.Core.{FakeInjection, Notice, Types, Venue}
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
    with_injection(symbol, fn ->
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
    end)
  end

  @impl true
  def get_top_of_book(symbol, opts \\ []) do
    with_injection(symbol, fn ->
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
    end)
  end

  @impl true
  def get_historical_prices(symbol, timeframe, range \\ [], opts \\ []) do
    with_injection(symbol, fn ->
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
    end)
  end

  @impl true
  def get_symbols(opts \\ []) do
    with_injection(fn ->
      with :ok <- authenticated(opts), do: {:ok, @symbols}
    end)
  end

  @impl true
  def get_order_book(symbol, opts \\ []) do
    with_injection(symbol, fn ->
      category = Keyword.get(opts, :category, "US_STOCK")

      cond do
        category not in ["US_STOCK", "US_ETF"] ->
          {:error, {:unsupported_book_category, category}}

        # A crypto pair has no depth endpoint on this venue, and the fake refuses it the same
        # way the real package does rather than inventing a book.
        String.contains?(symbol, "-") ->
          {:error, {:unsupported_book_category, category}}

        true ->
          with :ok <- authenticated(opts) do
            {:ok,
             %Types.OrderBook{
               symbol: symbol,
               bids: [
                 {Decimal.new("13.90"), Decimal.new("5")},
                 {Decimal.new("13.89"), Decimal.new("12")}
               ],
               asks: [
                 {Decimal.new("13.91"), Decimal.new("3")},
                 {Decimal.new("13.92"), Decimal.new("20")}
               ],
               timestamp: @at,
               sequence: nil,
               provider: :webull
             }}
          end
      end
    end)
  end

  @impl true
  def get_trades(symbol, opts \\ []) do
    with_injection(symbol, fn ->
      # A crypto pair. This venue's tick endpoint is equities-only, and the fake refuses
      # rather than inventing a tape.
      if String.contains?(symbol, "-") do
        {:error, {:unsupported_book_category, "US_CRYPTO"}}
      else
        with :ok <- authenticated(opts), do: {:ok, fake_ticks(symbol)}
      end
    end)
  end

  defp fake_ticks(symbol) do
    [
      %Types.Trade{
        id: nil,
        symbol: symbol,
        side: :buy,
        price: Decimal.new("48.07"),
        quantity: Decimal.new("1"),
        timestamp: @at,
        broken: false,
        provider: :webull
      },
      # A tick whose side code the venue does not document. `nil` is the honest answer, and
      # a fake without one would never exercise a consumer's handling.
      %Types.Trade{
        id: nil,
        symbol: symbol,
        side: nil,
        price: Decimal.new("48.08"),
        quantity: Decimal.new("3"),
        timestamp: @at,
        broken: false,
        provider: :webull
      }
    ]
  end

  @impl true
  def get_volume_profile(symbol, timeframe, opts \\ []) do
    with_injection(symbol, fn ->
      cond do
        timeframe not in ~w(5s 15s 1m 5m 30m) ->
          # Five widths, narrower than the bars endpoint. A caller asking for one this
          # endpoint does not serve gets an error, not the nearest.
          {:error, {:unsupported_timeframe, timeframe}}

        Keyword.get(opts, :session) == "OVN" ->
          {:error, {:unsupported_session, "OVN"}}

        true ->
          with :ok <- authenticated(opts) do
            {:ok,
             [
               %Types.VolumeProfile{
                 symbol: symbol,
                 timeframe: timeframe,
                 opened_at: @at,
                 total_volume: Decimal.new("1000"),
                 # Deliberately NOT buy_volume - sell_volume. The venue's classifier leaves
                 # some prints unattributed, and a fake where the three always reconcile
                 # would teach a consumer they must.
                 delta: Decimal.new("150"),
                 buy_volume: Decimal.new("600"),
                 sell_volume: Decimal.new("400"),
                 buy_at_price: %{"24.20" => Decimal.new("100"), "24.21" => Decimal.new("500")},
                 sell_at_price: %{"24.20" => Decimal.new("350"), "24.21" => Decimal.new("50")},
                 session: :regular,
                 provider: :webull
               }
             ]}
          end
      end
    end)
  end

  @impl true
  def get_auction_imbalance(symbol, opts \\ []) do
    with_injection(symbol, fn ->
      case Keyword.get(opts, :auction) do
        auction when auction in [:opening, :closing] ->
          with :ok <- authenticated(opts) do
            {:ok, [fake_imbalance(symbol, auction, Keyword.get(opts, :history, false))]}
          end

        nil ->
          {:error, :auction_required}

        other ->
          {:error, {:unsupported_auction, other}}
      end
    end)
  end

  defp fake_imbalance(symbol, auction, history?) do
    %Types.AuctionImbalance{
      symbol: symbol,
      auction: auction,
      # **The bars endpoint publishes none of these**, and the fake says so rather than
      # filling them in — a consumer computing a ratio over the series must find `nil`
      # here, not a number that looks balanced.
      paired_quantity: unless(history?, do: Decimal.new("701859")),
      imbalance_quantity: unless(history?, do: Decimal.new("5715")),
      side: unless(history?, do: "2"),
      reference_price: Decimal.new("253.83"),
      near_price: Decimal.new("253.93"),
      far_price: Decimal.new("253.98"),
      # Deliberately earlier than observed_at: outside an auction window the venue returns
      # the last imbalance, and a fake where the two agree would never exercise a
      # consumer's staleness check.
      venue_time: @at,
      observed_at: DateTime.add(@at, 3600, :second),
      provider: :webull
    }
  end

  @impl true
  def get_market_overview(_opts), do: Venue.not_supported()
  @impl true
  def list_instruments(_opts), do: Venue.not_supported()
  @impl true
  def get_balances(_credentials, opts) do
    with_injection(fn ->
      with :ok <- fake_account(opts) do
        {:ok,
         [
           %Types.Balance{
             currency: "USD",
             balance: Decimal.new("485705.95"),
             # `nil`, as in the real package: this venue publishes several disagreeing
             # "available" figures and neither it nor this fake picks one.
             available_balance: nil,
             hold: Decimal.new("485705"),
             timestamp: DateTime.utc_now(),
             provider: :webull
           }
         ]}
      end
    end)
  end

  @impl true
  def get_accounts(_credentials, _opts) do
    with_injection(fn ->
      # Two accounts of different classes, because that is the fact about this venue a
      # consumer most needs to handle: one credential reaches crypto and cash alike.
      {:ok,
       [
         %{
           "account_id" => "93IUJ28O9VO2KBGHDHR4H9",
           "account_number" => "10010048",
           "account_type" => "CASH",
           "account_label" => "Crypto",
           "account_class" => "CRYPTO"
         },
         %{
           "account_id" => "LOJOQITOD49R6G9BPQM489CISA",
           "account_number" => "10010049",
           "account_type" => "MARGIN",
           "account_label" => "Individual Margin",
           "account_class" => "INDIVIDUAL_MARGIN"
         }
       ]}
    end)
  end

  @impl true
  def get_fees(_credentials, _opts) do
    with_injection(fn ->
      {:ok,
       %{
         crypto_spread_pct: Decimal.new("1.00"),
         charged_by: "Webull Pay/Bakkt",
         source: :published_rate,
         captured_at: ~D[2026-09-03]
       }}
    end)
  end

  @impl true
  def get_transfers(_credentials, opts) do
    with_injection(fn ->
      with :ok <- fake_account(opts) do
        # A dividend alongside a deposit, because that is the distinction a consumer must
        # handle: both credit cash and neither is the other. The fake filters the same way
        # the real package does.
        types = Keyword.get(opts, :activity_types, ~w(DEPOSIT WITHDRAW TRANSFER))

        rows = [
          %{
            "id" => "a1b2c3",
            "account_id" => "93IUJ28O9VO2KBGHDHR4H9",
            "activity_type" => "DEPOSIT",
            "activity_sub_type" => "ACH",
            "currency" => "USD",
            "trade_date" => "2026-08-31",
            "net_amount" => "1500.0",
            "biz_time" => "2026-08-31T10:15:30.691Z"
          },
          %{
            "id" => "d4e5f6",
            "account_id" => "93IUJ28O9VO2KBGHDHR4H9",
            "activity_type" => "DIVIDENDS",
            "activity_sub_type" => "INCOME",
            "currency" => "USD",
            "trade_date" => "2026-08-30",
            "net_amount" => "12.40",
            "biz_time" => "2026-08-30T10:15:30.691Z"
          }
        ]

        {:ok, Enum.filter(rows, &(&1["activity_type"] in types))}
      end
    end)
  end

  @impl true
  def get_transactions(_credentials, opts) do
    with_injection(fn ->
      with :ok <- fake_account(opts) do
        # Unfiltered by default: the dividend and the fee are here beside the deposit, which
        # is the whole difference from `get_transfers/2`. A fake that returned only the three
        # transfer kinds would make the two functions look interchangeable.
        {:ok,
         [
           %{
             "id" => "a1b2c3",
             "activity_type" => "DEPOSIT",
             "currency" => "USD",
             "net_amount" => "1500.0"
           },
           %{
             "id" => "d4e5f6",
             "activity_type" => "DIVIDENDS",
             "currency" => "USD",
             "net_amount" => "12.40"
           },
           %{
             "id" => "g7h8i9",
             "activity_type" => "FEES",
             "currency" => "USD",
             "net_amount" => "-0.35"
           }
         ]}
      end
    end)
  end

  @impl true
  def list_payment_methods(_credentials, _opts \\ []), do: Venue.not_supported()

  @impl true
  def get_payment_method(_credentials, _id, _opts \\ []), do: Venue.not_supported()

  @impl true
  def add_payment_method(_details, _opts \\ []), do: Venue.not_supported()

  @impl true
  def transfer_internal(_asset, _amount, _opts, _request_opts), do: Venue.not_supported()

  @impl true
  def request_approved_address(_asset, _network, _address, _opts \\ []),
    do: Venue.not_supported()

  @impl true
  def remove_approved_address(_network, _address, _opts \\ []), do: Venue.not_supported()

  @impl true
  def list_networks(_asset, _opts \\ []), do: Venue.not_supported()

  @impl true
  def list_fee_promos(_opts \\ []), do: Venue.not_supported()

  @impl true
  def get_fx_rate(_pair, _at, _opts \\ []), do: Venue.not_supported()

  @impl true
  def get_notional_balances(_credentials, _currency, _opts \\ []), do: Venue.not_supported()

  @impl true
  def list_custody_fees(_credentials, _opts \\ []), do: Venue.not_supported()

  # Both refused, matching the real venue. A fake that answered where the real one
  # refuses lets a consumer's suite go green against behaviour that cannot happen.
  @impl true
  def preview_order(_credentials, request, opts \\ []) do
    with_injection(fn ->
      # Crypto is refused here as it is in production. A fake that priced a crypto order
      # would let a consumer's suite go green on a call the venue rejects.
      instrument = Map.get(request, :instrument_type, :crypto)

      if instrument == :crypto do
        {:error, {:preview_not_supported, :crypto}}
      else
        with :ok <- fake_account(opts),
             :ok <- fake_combination(request) do
          {:ok,
           %{
             instrument_type: instrument,
             estimated_cost: Decimal.new("100"),
             estimated_fee: Decimal.new("1")
           }}
        end
      end
    end)
  end

  @impl true
  def replace_order(_credentials, client_order_id, changes, opts \\ []) do
    with_injection(fn -> do_replace_order(client_order_id, changes, opts) end)
  end

  defp do_replace_order(client_order_id, changes, opts) do
    instrument = Keyword.get(opts, :instrument_type, :equity)
    order_type = Keyword.get(opts, :order_type, :limit)

    cond do
      instrument == :crypto ->
        {:error, {:preview_not_supported, :crypto}}

      changes == %{} ->
        {:error, :no_order_changes}

      true ->
        # The same per-type edit surface the real package enforces: a LIMIT order takes
        # order_type, time_in_force, quantity and limit price and nothing else.
        allowed = [
          :order_type,
          :time_in_force,
          :quantity,
          :price,
          :stop_price,
          :trailing_stop_step
        ]

        case Map.keys(changes) -- allowed do
          [] ->
            with :ok <- fake_account(opts) do
              {:ok, %{fake_order() | id: client_order_id, price: Map.get(changes, :price)}}
            end

          rejected ->
            {:error, {:unsupported_order_edit, order_type, rejected}}
        end
    end
  end

  @impl true
  def preview_replace(_credentials, _id, _changes, _opts \\ []), do: Venue.not_supported()

  @impl true
  def close_position(_credentials, _symbol, _opts \\ []), do: Venue.not_supported()

  @impl true
  def cancel_all_orders(_credentials, _opts \\ []), do: Venue.not_supported()

  @impl true
  def get_trade_history(_credentials, _opts), do: Venue.not_supported()
  @impl true
  def test_connection(_credentials, _opts), do: Venue.not_supported()
  @impl true
  def get_rate_limit_status(_credentials, _opts), do: Venue.not_supported()
  @impl true
  def quantization(symbol, _opts \\ []) do
    with_injection(symbol, fn ->
      if String.contains?(symbol, "-") do
        {:ok,
         %{
           price_increment: Decimal.new("0.01"),
           quantity_increment: Decimal.new("0.00000001"),
           min_quantity: Decimal.new("0.0001"),
           max_quantity: Decimal.new("1000"),
           min_quote_size: Decimal.new("1.00"),
           max_quote_size: Decimal.new("100000"),
           status: "OC"
         }}
      else
        {:ok,
         %{
           price_increment: nil,
           quantity_increment: Decimal.new("1"),
           min_quantity: nil,
           max_quantity: nil,
           min_quote_size: nil,
           max_quote_size: nil,
           status: "OC"
         }}
      end
    end)
  end

  @impl true
  def market_status(_opts) do
    with_injection(fn -> {:ok, :open} end)
  end

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
    if FakeInjection.credentials_bypassed?(:webull) do
      :ok
    else
      case Keyword.get(opts, :credentials) do
        %{app_key: _key, app_secret: _secret} -> :ok
        _absent -> {:refused, :missing_credentials}
      end
    end
  end

  defp with_injection(symbol \\ nil, fun) do
    case FakeInjection.next_outcome(:webull, symbol) do
      {:override, outcome} -> outcome
      :none -> fun.()
    end
  end

  defp candle(symbol, timeframe) do
    price = Decimal.new(@price[symbol])

    %Types.Candle{
      symbol: symbol,
      timeframe: timeframe,
      opened_at: @at,
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
  defp after_start?(candle, start), do: DateTime.compare(candle.opened_at, start) != :lt

  defp before_end?(_candle, nil), do: true
  defp before_end?(candle, finish), do: DateTime.compare(candle.opened_at, finish) != :gt

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
  def get_positions(opts \\ []) do
    with_injection(fn ->
      with :ok <- fake_account(opts) do
        # A SHORT position, because that is the case a fake must carry: the venue states
        # direction only in the sign of the quantity, and a package that assumed :long would
        # be exactly backwards with every number still plausible.
        {:ok,
         [
           %Types.Position{
             symbol: "BTC-USD",
             side: :short,
             quantity: Decimal.new("0.4"),
             instrument_type: :crypto,
             average_cost: Decimal.new("41000"),
             mark_price: Decimal.new("40000"),
             unrealised_pnl: Decimal.new("400"),
             # Not published on this endpoint. `nil` means the venue did not say, never
             # "no liquidation risk".
             liquidation_price: nil,
             leverage: nil,
             provider: :webull
           }
         ]}
      end
    end)
  end

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
  def convert(_from, _to, _amount, _opts \\ []), do: Venue.not_supported()

  @impl true
  def get_trade_volume(_credentials, _opts \\ []), do: Venue.not_supported()

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
  def get_option_chain(underlying, _opts \\ []) do
    with_injection(underlying, fn ->
      # A strike with only a call on it, because that is the case a consumer iterating strikes
      # has to see. A fake whose grid was always complete would let one ship code that skips it.
      call = fake_contract(underlying, ~D[2026-03-20], Decimal.new("100"), :call)
      put = fake_contract(underlying, ~D[2026-03-20], Decimal.new("100"), :put)
      lone = fake_contract(underlying, ~D[2026-06-19], Decimal.new("120"), :call)

      {:ok,
       %Types.OptionChain{
         underlying: underlying,
         expiries: %{
           ~D[2026-03-20] => %{Decimal.new("100") => %{call: call, put: put}},
           ~D[2026-06-19] => %{Decimal.new("120") => %{call: lone, put: nil}}
         },
         # The contract list does not quote the underlying, and a fake that filled this in
         # would teach a consumer to rely on a field that is nil in production.
         underlying_price: nil,
         venue_time: nil,
         provider: :webull
       }}
    end)
  end

  @impl true
  def get_option_expirations(underlying, _opts \\ []) do
    with_injection(underlying, fn -> {:ok, [~D[2026-03-20], ~D[2026-06-19]]} end)
  end

  defp fake_contract(underlying, expiry, strike, right) do
    %Types.OptionContract{
      underlying: underlying,
      expiry: expiry,
      strike: strike,
      right: right,
      venue_symbol: "#{underlying}#{Date.to_iso8601(expiry)}#{right}",
      multiplier: Decimal.new("100"),
      settlement_type: nil,
      expiration_type: nil,
      last_trading_day: nil,
      index_option: nil,
      mini: nil,
      non_standard: nil,
      provider: :webull
    }
  end

  @impl true
  def get_option_greeks(_symbol, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def list_watchlists(_opts \\ []) do
    with_injection(fn ->
      # `symbols: nil`, as in the package: this endpoint names watchlists and does not list
      # membership, and a fake returning `[]` would teach a consumer that they are empty.
      {:ok,
       [
         %Types.Watchlist{
           id: "wl-1",
           name: "My Tech Stocks",
           symbols: nil,
           venue_time: nil,
           provider: :webull
         }
       ]}
    end)
  end

  @impl true
  def get_watchlist(id, _opts \\ []) do
    with_injection(fn ->
      # And `name: nil` here, because the membership endpoint does not return it.
      {:ok,
       %Types.Watchlist{
         id: id,
         name: nil,
         symbols: ["AAPL", "GOOG"],
         venue_time: nil,
         provider: :webull
       }}
    end)
  end

  @impl true
  def create_watchlist(name, symbols, _opts \\ []) do
    with_injection(fn ->
      {:ok,
       %Types.Watchlist{
         id: "wl-new",
         name: name,
         symbols: symbols,
         venue_time: nil,
         provider: :webull
       }}
    end)
  end

  @impl true
  def update_watchlist(id, opts \\ []) do
    with_injection(fn ->
      if Keyword.has_key?(opts, :symbols) do
        # Refused rather than silently skipped, as in the package: this venue's update
        # endpoint does not touch membership.
        {:error, :membership_not_updatable_here}
      else
        {:ok,
         %Types.Watchlist{
           id: id,
           name: Keyword.get(opts, :name),
           symbols: nil,
           venue_time: nil,
           provider: :webull
         }}
      end
    end)
  end

  @impl true
  def delete_watchlist(_id, _opts \\ []) do
    with_injection(fn -> {:ok, :ok} end)
  end

  @impl true
  def get_financials(symbol, kind, _opts \\ []) do
    with_injection(symbol, fn ->
      {:ok,
       [
         %Types.FinancialStatement{
           symbol: symbol,
           kind: kind,
           line_items: %{
             "total_assets" => "379297000000",
             "fiscal_year" => 2026,
             "fiscal_period" => 0
           },
           period_end: ~D[2025-12-27],
           # The venue's integer code, not a string. `0` is the full year.
           fiscal_period: "FY",
           currency: "USD",
           venue_time: nil,
           provider: :webull
         }
       ]}
    end)
  end

  @impl true
  def get_corporate_events(opts \\ []) do
    with_injection(fn ->
      case Keyword.get(opts, :symbol) do
        symbol when is_binary(symbol) ->
          {:ok,
           [
             %Types.CorporateEvent{
               symbol: symbol,
               kind: :dividend,
               ex_date: ~D[2026-08-10],
               record_date: ~D[2026-08-11],
               pay_date: ~D[2026-08-14],
               announced_date: nil,
               amount: Decimal.new("0.25"),
               currency: "USD",
               ratio: nil,
               # The venue publishes no confirmed flag. `true` would claim an earnings date is
               # final when one routinely is not.
               confirmed: nil,
               details: %{},
               provider: :webull
             }
           ]}

        _missing ->
          {:error, :symbol_required}
      end
    end)
  end

  @impl true
  def get_filings(symbol, _opts \\ []) do
    with_injection(symbol, fn ->
      {:ok,
       [
         %Types.Filing{
           symbol: symbol,
           id: "f-1",
           form_type: "10-Q",
           title: "Quarterly report",
           url: "https://example.invalid/f-1",
           filed_at: nil,
           period_end: ~D[2025-12-27],
           provider: :webull
         }
       ]}
    end)
  end

  @impl true
  def get_news(opts \\ []) do
    with_injection(fn ->
      case Keyword.get(opts, :symbols) do
        [_first | _rest] = symbols ->
          {:ok,
           [
             %Types.NewsItem{
               id: "n-1",
               headline: "Summary",
               summary: "A model's paraphrase, not the publisher's text.",
               url: nil,
               # The venue generated it; naming a publisher would attribute a paraphrase.
               source: "webull",
               symbols: symbols,
               published_at: nil,
               provider: :webull
             }
           ]}

        _missing ->
          {:error, :symbols_required}
      end
    end)
  end

  @impl true
  def get_screener(name, _opts \\ []) do
    with_injection(fn ->
      if name in Rest.screeners() do
        {:ok,
         [
           %Types.ScreenerResult{
             symbol: "AAPL",
             screener: name,
             # The venue's returned order, not a metric this package ranked on.
             rank: 1,
             metrics: %{"change_ratio" => "0.031"},
             venue_time: nil,
             provider: :webull
           }
         ]}
      else
        {:error, {:unknown_screener, name}}
      end
    end)
  end

  @impl true
  def create_account(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def rename_account(_id, _name, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_roles(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def place_order(_credentials, request, opts \\ []) do
    with_injection(fn ->
      # The fake enforces the venue's crypto matrix and its account requirement, so a
      # consumer's suite cannot go green on an order this venue would reject.
      with :ok <- fake_account(opts),
           :ok <- fake_combination(request) do
        # Round-tripped through the real module's own encode then decode — not the
        # caller's atom echoed back — so a fake-based suite exercises the same wire
        # names the real venue would see, and would catch a decoder gap the way the
        # real path does.
        order_type = Map.get(request, :order_type, :limit)
        tif = Map.get(request, :time_in_force, :gtc)

        {:ok,
         %Types.Order{
           id: "fake-webull-order-1",
           symbol: Map.fetch!(request, :symbol),
           side: Map.fetch!(request, :side),
           order_type: order_type |> Rest.order_type_name() |> Rest.order_type_atom(),
           time_in_force: tif |> Rest.tif_name() |> Rest.tif_atom(),
           quantity: Map.get(request, :quantity),
           price: Map.get(request, :price),
           status: :pending,
           provider: :webull
         }}
      end
    end)
  end

  @impl true
  def place_orders(_credentials, requests, opts) do
    # The venue's two limits, and a per-order result. A fake that answered ok-or-error would
    # let a consumer ship code that believes "the batch failed" when most of it was placed.
    cond do
      not is_binary(Keyword.get(opts, :account_id)) ->
        {:error, :account_id_required}

      requests == [] ->
        {:error, :empty_batch}

      length(requests) > 50 ->
        {:error, {:batch_too_large, length(requests), 50}}

      Enum.any?(requests, &(Map.get(&1, :instrument_type, :equity) != :equity)) ->
        index = Enum.find_index(requests, &(Map.get(&1, :instrument_type, :equity) != :equity))

        {:error,
         {:batch_instrument_not_supported, index,
          requests |> Enum.at(index) |> Map.get(:instrument_type)}}

      true ->
        {:ok,
         requests
         |> Enum.with_index()
         |> Enum.map(fn
           # The second one refused, because a partial batch is the normal shape.
           {_request, 1} -> %{"code" => "INSUFFICIENT_BUYING_POWER"}
           {request, index} -> %{"order_id" => "batch-#{index}", "symbol" => request[:symbol]}
         end)}
    end
  end

  defp fake_account(opts) do
    if Keyword.get(opts, :account_id), do: :ok, else: {:error, :account_id_required}
  end

  # The fake enforces the same per-instrument matrix the real package does, from the same
  # source of truth — `Rest.order_combinations/1`. A hand-copied list here would drift from
  # the builder it stands in for, one instrument type at a time.
  defp fake_combination(request) do
    instrument = Map.get(request, :instrument_type, :crypto)
    type = Map.get(request, :order_type, :limit)
    tif = Map.get(request, :time_in_force, :gtc)

    case Rest.order_combinations(instrument) do
      {:ok, allowed} ->
        if {type, tif} in allowed,
          do: :ok,
          else: {:error, {:unsupported_order_combination, instrument, type, tif}}

      error ->
        error
    end
  end

  @impl true
  def cancel_order(_credentials, client_order_id, opts \\ []) do
    with_injection(fn ->
      with :ok <- fake_account(opts) do
        case client_order_id do
          "fake-webull-order-1" -> {:ok, :cancelled}
          _unknown -> {:refused, :not_found}
        end
      end
    end)
  end

  @impl true
  def get_order(_credentials, client_order_id, opts \\ []) do
    with_injection(fn ->
      with :ok <- fake_account(opts) do
        case client_order_id do
          "fake-webull-order-1" -> {:ok, fake_order()}
          _unknown -> {:refused, :not_found}
        end
      end
    end)
  end

  @impl true
  def get_orders(_credentials, opts \\ []) do
    with_injection(fn ->
      with :ok <- fake_account(opts) do
        # Open by default, history when asked — the venue has two endpoints, not a filter.
        if Keyword.get(opts, :history, false) do
          {:ok, [%{fake_order() | status: :filled}]}
        else
          {:ok, [fake_order()]}
        end
      end
    end)
  end

  defp fake_order do
    %Types.Order{
      id: "fake-webull-order-1",
      symbol: "BTC-USD",
      side: :buy,
      order_type: :limit,
      time_in_force: :gtc,
      quantity: Decimal.new("0.5"),
      filled_quantity: Decimal.new("0"),
      price: Decimal.new("40000"),
      status: :open,
      provider: :webull
    }
  end
end
