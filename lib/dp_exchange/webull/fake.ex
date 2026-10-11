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
  about freshness and is itself the substitution this family refuses. **The one exception is
  `get_balances/2`'s `timestamp`**, which is `DateTime.utc_now/0` because the real package
  stamps it with when it asked (`Rest.get_balances/2`'s `asked_at`: a balance has no venue
  event time), so a fixed past instant there would be the fake being differently capable.

  ## It models the three things that make this venue different

  - **Credentials are required everywhere a real call reaches the venue — not for
    market data alone, and not for a callback that never builds a request.**
    `get_price/2` without them is `{:error, {:missing_credentials, :webull}}`, because
    the real venue signs every call and has no anonymous endpoint — and so is every
    credentialed account and order call (`get_balances/2`, `get_accounts/2`,
    `place_order/3`, and the rest). `{:error, {:missing_credentials, :webull}}`, not
    `{:refused, _}`: a missing *local* credential never reaches the venue at all, and
    `DpExchange.Core.Venue`'s own moduledoc reserves `:refused` for the venue's own
    permanent word about a request it received. It is `Auth.headers/2`'s own return
    value for a credential that does not match its shape, echoed here rather than
    invented — this used to answer `{:refused, :missing_credentials}` here and
    `{:ok, _}` on several of the account and order callbacks, both wrong for the
    reasons above; found by `dp_exchange_core` 0.1.57's assertion 17. A fake that
    answered anyway would let a consumer's test pass while the real call returns 401.

    **`get_fees/2` is the one deliberate exception.** It answers a captured published
    rate and never builds a request, so there is nothing for a credential to gate — see
    its own moduledoc. A 2026-09-06 sweep gated it anyway, on the reasoning that the
    real path "had never run through `Auth.headers/2`"; that broke a real consumer who
    resolves fees before any account is attached, and was reverted 2026-09-07.

    **The gate covers the widened surface too, and that part assertion 17 cannot check.**
    Options, watchlists, financials, corporate events, filings, news and the screener all
    reach the venue through the same signed `Rest` request path as everything else, so
    they refuse without credentials exactly as `get_price/2` does. They were missed
    originally because assertion 17 gates on `Core.AdapterContract`'s hardcoded
    `@credentialed` list — `get_balances`, `get_accounts`, `get_fees`, `get_transfers`,
    `place_order`, `cancel_order`, `get_order`, `get_orders`, `get_trade_history` — which
    names none of them, so twelve callbacks answered `{:ok, _}` with no credentials while
    the real venue returned 401. A cross-package audit found the identical gap in
    `dp_exchange_schwab`'s fake on the same widened surface; it is a property of the
    assertion's fixed list, not of either venue.
  - **No volume.** `volume` is `nil` on every quote and every bar, matching a venue that
    reports none. Returning `0` would look like a real measurement of no trading.
  - **UAT has no stream.** `subscribe/2` under `environment: :uat` refuses, exactly as the
    real feed does, rather than delivering fake production data.

  ## Remembered per process, and what is unmeasured

  Orders from `place_order/3`, `place_orders/3` and `replace_order/4` are remembered, so
  every id they return is accepted by this fake's `get_order/3` and `cancel_order/3`
  (`close_position/3` is unsupported here, so it issues none). Watchlists from
  `create_watchlist/3` read back their members; only the fixture's own `wl-1` returns canned
  ones. `get_watchlist/2` for any other id is `{:refused, :not_found}` - **the real venue's
  answer for an unknown watchlist id is unmeasured** (`get-watchlist-instruments.md` states
  only the generic error bodies), so the fake fails closed rather than guess one.

  ## Failure injection and anonymous mode

  Every function below that has a real success path (not an unconditional
  `Venue.not_supported()`) checks `DpExchange.Core.FakeInjection.next_outcome/1` or `/2`
  first — a queued or always-set outcome from `FakeInjection.queue_failures/2,3` or
  `fail_always/2,3` short-circuits the fake's normal logic and is returned as-is.
  `authenticated/1` also checks `FakeInjection.credentials_bypassed?/1` before its normal
  `{:error, {:missing_credentials, :webull}}` path. Neither changes anything for a test
  that never calls `FakeInjection` — see that module for the full contract.

  `subscribe/2`, `unsubscribe/2` and `update_symbols/2` are NOT wired: each takes a list
  of symbols in one call, and "this one symbol in the batch fails, the rest succeed" is a
  case whole-call injection cannot express — see `FakeInjection`'s own moduledoc.
  `place_orders/3` is the same shape for the same reason: one call, many orders.
  """

  @behaviour DpExchange.Core.Venue

  alias DpExchange.Core.{Config, FakeInjection, Instrument, Notice, Types, Venue}
  alias DpExchange.Webull.{Auth, Environment, Rest}

  # `XRP-USD` is a real member of `@symbols` (so `get_symbols/1` lists it — this fake
  # would be lying about the venue if it silently dropped a non-tradable row, and the
  # real bug this fixes is exactly a consumer unable to tell it apart from the other
  # three) but its `list_instruments/1` row carries `status: :unknown` rather than
  # `:tradable` — this fake's one modeled `NT` ("Non-Tradable") listing.
  @symbols ~w(BTC-USD ETH-USD SOL-USD XRP-USD)

  @price %{
    "BTC-USD" => "77845.79",
    "ETH-USD" => "2951.40",
    "SOL-USD" => "121.66",
    "XRP-USD" => "0.58"
  }

  # Fixed, not `utc_now/0`.
  @at ~U[2026-08-28 12:00:00Z]

  # The id of the one order `get_orders/2` always lists, in the venue's own `client_order_id`
  # format: the 32 lower-case hex characters `Rest` generates for an order that names none
  # (a 32-character maximum, unique per account). This was `fake-webull-order-1`, which is
  # neither, and it was also what `place_order/3` issued for EVERY order that named no id, so
  # two placements in a test shared it and the second overwrote the first.
  @default_order_id "5f1e9c0a7b2d4e68a3c4d5e6f7081920"

  # `place_order/3` and `place_orders/3` issue ids from this prefix plus a per-process count:
  # 20 hex characters and a 12-character counter, 32 in all, a new one per order, and
  # deterministic so a consumer's test can be reproduced. The system `order_id` the batch
  # endpoint also returns is 26 upper-case alphanumerics (`order-batch-place.md`'s example,
  # `80HG7CPSFDPCAL3TP66LKBAS69`).
  @issued_prefix "3a9f5c2e8b1d47a6905c"
  @issued_key {__MODULE__, :issued}
  @system_order_prefix "80HG7CPSFDPCAL3TP66LKB"

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
      category = Config.opt(opts, :category, "US_CRYPTO")

      # The category before credentials, from `Rest`'s own list: a category the real path has
      # no snapshot endpoint for is refused by name, not answered with a crypto price. One it
      # does serve, other than crypto, is an endpoint this fake models no symbol on.
      with :ok <- Rest.validate_snapshot_category(category),
           :ok <- authenticated(opts) do
        case category == "US_CRYPTO" && Map.fetch(@price, symbol) do
          {:ok, price} ->
            {:ok,
             %Types.Quote{
               symbol: symbol,
               price: Decimal.new(price),
               # `@symbols` is crypto-only, and the venue's crypto OpenAPI reports no
               # volume anywhere — `nil`, never zero. The venue's stock snapshot DOES
               # report a real day-aggregate volume (`Rest.get_price/3`,
               # `capabilities/0`'s `reports_trade_volume: true`), but this fake models
               # no stock symbol, so it never has to choose between the two: an equity
               # ticker here is simply `{:refused, :not_listed}`, "less capable" rather
               # than "differently capable."
               volume: nil,
               venue_time: @at,
               observed_at: @at,
               provider: :webull
             }}

          _not_listed ->
            {:refused, :not_listed}
        end
      end
    end)
  end

  @doc """
  `DpExchange.Webull.get_prices/2`'s shape: a result for every symbol asked for, each
  exactly what `get_price/2` gives that symbol here.
  """
  @spec get_prices([String.t()], keyword()) :: {:ok, map()} | {:error, term()}
  def get_prices(symbols, opts \\ []) do
    case Config.opt(opts, :category, "US_CRYPTO") do
      "US_CRYPTO" -> {:ok, Map.new(Enum.uniq(symbols), &{&1, get_price(&1, opts)})}
      other -> {:error, {:unsupported_category, other}}
    end
  end

  @impl true
  def get_top_of_book(symbol, opts \\ []) do
    with_injection(symbol, fn ->
      category = Config.opt(opts, :category, "US_CRYPTO")

      # `US_EVENT` is refused as `Rest.get_top_of_book/3` refuses it (it has two books, not a
      # top of one), then the snapshot category, both before credentials.
      with :ok <- Rest.validate_top_of_book_category(category),
           :ok <- authenticated(opts) do
        case category == "US_CRYPTO" && Map.fetch(@price, symbol) do
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

          _not_listed ->
            {:refused, :not_listed}
        end
      end
    end)
  end

  @impl true
  def get_historical_prices(symbol, timeframe, range \\ [], opts \\ []) do
    with_injection(symbol, fn ->
      # The category, width, range and `:limit` are checked BEFORE credentials, as `Rest`'s
      # paths do (the width and count checks run before `get/4` reaches `Auth.headers/2`),
      # through the real validator rather than a copy. For the default crypto category that
      # is the crypto set (`Rest.timeframes/0`) — not `Rest.wide_timeframes/0`: `12h` is
      # unserved anywhere, and `1w`/`1M`/`1y`, which the venue's *equity, option and futures*
      # bars serve, its crypto bars refuse deliberately. A `:limit` over 1200 is refused as
      # `{:limit_out_of_range, n, max: 1200}`, and an option, futures or event request that
      # names a range is refused as it is there. This fake models no non-crypto symbol, so a
      # request those endpoints would accept is `{:refused, :not_listed}`, never a crypto bar.
      with :ok <- Rest.validate_bars_request(timeframe, range, opts),
           :ok <- authenticated(opts) do
        if symbol in @symbols and Config.opt(opts, :category, "US_CRYPTO") == "US_CRYPTO" do
          {:ok, [candle(symbol, timeframe)] |> Enum.filter(&within?(&1, range))}
        else
          {:refused, :not_listed}
        end
      end
    end)
  end

  @impl true
  def get_symbols(opts \\ []) do
    with_injection(fn ->
      # The category first, credentials second — `Rest.get_symbols/2` builds its request
      # path from the category before `get/4` signs anything. This fake lists only the
      # crypto catalogue, so any other category (including `US_STOCK`, which the real path
      # does serve) is refused by name rather than answered with the crypto list.
      with :ok <- fake_instrument_category(Config.opt(opts, :category, "US_CRYPTO")),
           :ok <- authenticated(opts),
           do: {:ok, @symbols}
    end)
  end

  @impl true
  def get_order_book(symbol, opts \\ []) do
    with_injection(symbol, fn ->
      category = Config.opt(opts, :category, "US_STOCK")

      # The category and `:depth` from `Rest`'s own validator, before credentials: a depth the
      # venue's page gives a range for (futures: 1 to 10) or a non-number was accepted here,
      # and `US_FUTURES`, which `Rest` serves, was refused as an unknown category.
      with :ok <- Rest.validate_book_request(category, opts),
           :ok <- fake_book_symbol(symbol, category),
           :ok <- authenticated(opts) do
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
           venue_time: @at,
           observed_at: @at,
           sequence: nil,
           provider: :webull
         }}
      end
    end)
  end

  # A crypto pair has no depth endpoint on this venue, and the fake refuses it the same way
  # the real package does rather than inventing a book.
  defp fake_book_symbol(symbol, category) do
    if String.contains?(symbol, "-"),
      do: {:error, {:unsupported_book_category, category}},
      else: :ok
  end

  @impl true
  def get_trades(symbol, opts \\ []) do
    with_injection(symbol, fn ->
      # The category (a tape endpoint exists for stocks, ETFs, options and futures) and the
      # `:limit` against that endpoint's stated maximum, from `Rest`'s validator, before
      # credentials. Then a crypto pair: this venue's tick endpoint is equities-only, and the
      # fake refuses rather than inventing a tape.
      with :ok <- Rest.validate_trades_request(opts),
           :ok <- fake_tape_symbol(symbol),
           :ok <- authenticated(opts),
           do: {:ok, fake_ticks(symbol)}
    end)
  end

  defp fake_tape_symbol(symbol) do
    if String.contains?(symbol, "-"),
      do: {:error, {:unsupported_book_category, "US_CRYPTO"}},
      else: :ok
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
      # Category, width (five, narrower than the bars endpoint - an unserved one is an error,
      # not the nearest) and session, in `Rest.get_volume_profile/4`'s own order and from its
      # own validator, all before credentials. A session outside PRE/RTH/ATH used to pass
      # here; only `OVN` was refused.
      with :ok <- Rest.validate_footprint_request(timeframe, opts),
           :ok <- authenticated(opts) do
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
  def list_instruments(opts \\ []) do
    with_injection(fn ->
      category = Config.opt(opts, :category, "US_CRYPTO")

      with :ok <- fake_instrument_category(category),
           :ok <- authenticated(opts) do
        {:ok,
         [
           fake_instrument("BTC-USD", "BTC", "USD", :tradable),
           fake_instrument("ETH-USD", "ETH", "USD", :tradable),
           fake_instrument("SOL-USD", "SOL", "USD", :tradable),
           # `status: "NT"` on the real venue — still returned by `get_symbols/1` (see
           # `@symbols`'s own comment) but `:unknown` here, never `:tradable`. This is the
           # one row a consumer's test can use to prove it checks `status` before trading
           # a symbol `get_symbols/1` handed it.
           fake_instrument("XRP-USD", "XRP", "USD", :unknown)
         ]}
      end
    end)
  end

  # Matches `Rest.list_instruments/2`'s own refusal — see that function's moduledoc for
  # why `US_STOCK`/`US_ETF` are refused by name rather than served with an invented
  # instrument type and quote.
  defp fake_instrument_category("US_CRYPTO"), do: :ok

  defp fake_instrument_category(category),
    do: {:error, {:unsupported_instrument_category, category}}

  defp fake_instrument(symbol, base, quote_asset, status) do
    Instrument.new(
      symbol: symbol,
      base: base,
      quote: quote_asset,
      instrument: :spot,
      status: status
    )
  end

  @impl true
  def get_balances(credentials, opts) do
    with_injection(fn ->
      # Account first, credentials second — the same order `Rest.get_balances/2` checks
      # them in (`account_id(opts)` then `Auth.headers/2`), so a caller missing both sees
      # the same error here as it would there.
      with :ok <- fake_account(opts),
           :ok <- credentialed(credentials) do
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
  def get_accounts(credentials, _opts) do
    with_injection(fn ->
      with :ok <- credentialed(credentials) do
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
      end
    end)
  end

  @impl true
  def get_fees(_credentials, _opts) do
    with_injection(fn ->
      # `Rest.get_fees/2` answers from a captured published rate and builds no request
      # at all, so unlike every other credentialed callback there is nothing here for a
      # credential to gate — see its own moduledoc for the 2026-09-07 incident where
      # gating this anyway broke a consumer who resolves fees before any account is
      # attached. No `credentialed/1` check, deliberately, and this must keep matching
      # `Rest.get_fees/2` exactly.
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
  def get_transfers(credentials, opts) do
    with_injection(fn ->
      # Account, then the date range, credentials last — matching `Rest.get_transfers/2`'s
      # own order. A range across two calendar years is refused as it is there; it used to
      # be answered.
      with :ok <- fake_account(opts),
           :ok <- Rest.validate_activity_range(opts),
           :ok <- credentialed(credentials) do
        # A dividend alongside a deposit, because that is the distinction a consumer must
        # handle: both credit cash and neither is the other. The fake filters the same way
        # the real package does.
        types = Config.opt(opts, :activity_types, ~w(DEPOSIT WITHDRAW TRANSFER))

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

        {:ok, filter_activity_types(rows, types)}
      end
    end)
  end

  @impl true
  def get_transactions(credentials, opts) do
    with_injection(fn ->
      # Account, then the date range, credentials last — matching
      # `Rest.get_transactions/2`'s own order.
      with :ok <- fake_account(opts),
           :ok <- Rest.validate_activity_range(opts),
           :ok <- credentialed(credentials) do
        # Unfiltered by default: the dividend and the fee are here beside the deposit, which
        # is the whole difference from `get_transfers/2`. A fake that returned only the three
        # transfer kinds would make the two functions look interchangeable. `activity_types`
        # narrows it, as it does at the venue (a list, or the venue's comma-joined string);
        # it used to be ignored.
        rows = [
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
        ]

        {:ok, filter_activity_types(rows, Keyword.get(opts, :activity_types))}
      end
    end)
  end

  defp filter_activity_types(rows, nil), do: rows

  defp filter_activity_types(rows, types) when is_list(types),
    do: Enum.filter(rows, &(&1["activity_type"] in types))

  defp filter_activity_types(rows, types),
    do: filter_activity_types(rows, types |> to_string() |> String.split(",", trim: true))

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
  def preview_order(credentials, request, opts \\ []) do
    with_injection(fn ->
      # Crypto is refused here as it is in production. A fake that priced a crypto order
      # would let a consumer's suite go green on a call the venue rejects.
      instrument = Map.get(request, :instrument_type, :crypto)

      if instrument == :crypto do
        {:error, {:preview_not_supported, :crypto}}
      else
        # Account, then the order itself, credentials last — matching
        # `Rest.preview_order/3`'s own order (account, combination, order body, THEN
        # `post/4` -> `Auth.headers/2`). The order body is checked through
        # `Rest.validate_order_request/1`, which includes the combination: a preview with
        # no size, or a limit with no price, is refused here as it is there. It used to
        # check the combination alone and price anything.
        with :ok <- fake_account(opts),
             :ok <- Rest.validate_order_request(request),
             :ok <- credentialed(credentials) do
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
  def replace_order(credentials, client_order_id, changes, opts \\ []) do
    with_injection(fn -> do_replace_order(credentials, client_order_id, changes, opts) end)
  end

  defp do_replace_order(credentials, client_order_id, changes, opts) do
    instrument = Config.opt(opts, :instrument_type, :equity)
    order_type = Config.opt(opts, :order_type, :limit)

    # The real package's own order: crypto, then the per-type edit table (which also refuses
    # an empty amendment, AFTER an unknown order type - an empty `changes` used to be
    # `:no_order_changes` ahead of `{:unsupported_order_type, _}`), then the account, then
    # `post/4` -> `Auth.headers/2`. The edit table is the real one, not a union of every
    # type's fields.
    with :ok <- fake_replaceable(instrument),
         :ok <- Rest.validate_amendment(order_type, changes),
         :ok <- fake_account(opts),
         :ok <- Rest.validate_order_id(client_order_id),
         :ok <- credentialed(credentials),
         {:ok, base} <- replaceable_order(client_order_id) do
      # Remembered (per process) under the same id, as the venue amends in place and
      # `Rest.replace_order/4` reads that order back: an id this returns is then accepted by
      # `get_order/3` and `cancel_order/3`. The order keeps its own fields except the ones
      # changed.
      {:ok, base |> amended_order(changes) |> remember_order()}
    end
  end

  # Only an order this process placed (or the fixed order) can be replaced. An id the fake
  # never issued is refused as `get_order/3` and `cancel_order/3` refuse it, never invented.
  defp replaceable_order(client_order_id) do
    case lookup_order(client_order_id) do
      {:ok, _order} = found -> found
      :error -> {:refused, :not_found}
    end
  end

  defp fake_replaceable(:crypto), do: {:error, {:preview_not_supported, :crypto}}
  defp fake_replaceable(_instrument), do: :ok

  # The order as the venue reads it back after the amendment (`Rest.replace_order/4` reads
  # the order back rather than echoing the request): the fields that changed are the new
  # values, and the rest are the order's own. A quantity-only edit used to blank the price,
  # and the quantity edit itself was dropped.
  defp amended_order(%Types.Order{} = base, changes) do
    Enum.reduce(
      [:quantity, :price, :stop_price, :order_type, :time_in_force],
      base,
      fn field, order ->
        case Map.get(changes, field) do
          nil -> order
          new -> Map.put(order, field, amended_value(field, new))
        end
      end
    )
  end

  # The read-back holds `Decimal`s, whatever the amendment spelled them as (an integer, a
  # numeric string): the real path sends the venue's string and reads the order back.
  defp amended_value(field, new) when field in [:quantity, :price, :stop_price],
    do: Rest.number_to_decimal(new)

  defp amended_value(_field, new), do: new

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
  def quantization(symbol, opts \\ []) do
    with_injection(symbol, fn ->
      # `Rest.quantization/3` reads the same `instruments/.../profiles/list` endpoint
      # every other market-data call does, so it needs the same `authenticated(opts)`
      # gate they already carry.
      with :ok <- authenticated(opts) do
        cond do
          # A crypto pair the fake does not list is one the venue's catalogue would answer
          # with no row (`Rest.quantization/3`: no row to read). Increments for it would be a
          # price step and lot size this fake invented for an instrument it has never heard of.
          # An equity ticker is modelled by one fixed row, as `get_price/2`'s docs say, so it is
          # not held to the crypto list.
          String.contains?(symbol, "-") and symbol not in @symbols ->
            {:refused, :not_listed}

          String.contains?(symbol, "-") ->
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

          true ->
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
      end
    end)
  end

  # Matches the real facade: this venue is not crypto-only, `market_status/1` carries no
  # symbol or asset-class argument to answer per-class with, and the venue publishes no
  # market-status or trading-calendar endpoint this package can reach. See
  # `DpExchange.Webull.market_status/1`'s own doc for the full reasoning. The real facade
  # never dials out for this either, so there is nothing for `with_injection/2` to wrap.
  @impl true
  def market_status(_opts), do: Venue.not_supported()

  @impl true
  def subscribe(symbols, opts \\ []) do
    case check_symbols(symbols) do
      :ok -> symbols |> canonical_case() |> subscribe_checked(opts)
      {:error, _reason} = refused -> refused
    end
  end

  defp subscribe_checked(symbols, opts) do
    environment = Environment.resolve(opts)

    if Environment.streaming?(environment) do
      target = Config.opt(opts, :to, self())

      for symbol <- symbols, symbol in @symbols do
        case get_price(symbol, credentials: %{app_key: "fake", app_secret: "fake"}) do
          {:ok, quote_struct} -> send(target, {:dp_exchange, :webull, quote_struct})
          _refused -> :ok
        end
      end

      # **Added to, never replacing.** This was the identical line `update_symbols/2`
      # carries below — the two callbacks were byte-for-byte the same function — so a
      # second `subscribe/2` dropped whatever the first had subscribed. The real
      # facade unions (`wanted: MapSet.union(state.wanted, MapSet.new(symbols))` in
      # `Feed`), so a consumer's tier-1 tests against this fake certified the opposite
      # of what the venue does: subscribe twice, keep one symbol here, keep both there.
      #
      # The contract settles which is right without needing a new sentence in it.
      # `c:DpExchange.Core.Venue.update_symbols/2` exists to "change a live
      # subscription's symbol set", and `c:unsubscribe/2` to stop delivery for named
      # symbols. Neither has any purpose if `subscribe/2` already replaces — you would
      # just subscribe the new list. Two callbacks the contract distinguishes,
      # implemented as one function, is the tell.
      Process.put(
        __MODULE__,
        MapSet.union(subscribed(), MapSet.new(Enum.filter(symbols, &(&1 in @symbols))))
      )

      :ok
    else
      {:error, {:streaming_unavailable, environment}}
    end
  end

  @impl true
  def unsubscribe(symbols, _opts \\ []) do
    with :ok <- check_symbols(symbols) do
      symbols = canonical_case(symbols)
      Process.put(__MODULE__, MapSet.difference(subscribed(), MapSet.new(symbols)))
      :ok
    end
  end

  @impl true
  def update_symbols(symbols, _opts \\ []) do
    with :ok <- check_symbols(symbols) do
      symbols = canonical_case(symbols)
      Process.put(__MODULE__, MapSet.new(Enum.filter(symbols, &(&1 in @symbols))))
      :ok
    end
  end

  @impl true
  def coverage(_opts \\ []), do: Map.new(subscribed(), &{&1, :stream})

  # This fake's `subscribe/2` only ever sends `Types.Quote` (built from `get_price/2`,
  # above) — never a `Types.TopOfBook` — so, unlike the real venue, it has exactly one
  # kind to report here. That is honest for what the fake actually delivers, not a
  # simplification: "less capable is allowed, differently capable is not" means the fake
  # must never *claim* a second kind it cannot produce.
  @impl true
  def coverage_by_kind(opts \\ []), do: %{quotes: coverage(opts)}

  @impl true
  def subscribe_notices(opts \\ []) do
    send(Config.opt(opts, :to, self()), {:dp_exchange, :webull, Notice.new(:link_up, :webull)})
    :ok
  end

  defp subscribed, do: Process.get(__MODULE__, MapSet.new())

  # The real venue signs every call and has no anonymous endpoint, so a fake that answered
  # without credentials would let a consumer's test pass while the real call returns 401.
  # For the market-data callbacks, which carry credentials in `opts[:credentials]` the same
  # way the real facade's `credentials(opts)` helper reads them.
  defp authenticated(opts), do: credentialed(Keyword.get(opts, :credentials, %{}))

  # The same gate for the callbacks that receive credentials as their own first
  # argument instead — `get_balances/2`, `get_accounts/2`, `place_order/3` and the rest
  # of this venue's account and order surface. `Auth.headers/2` is the real gate every
  # one of those calls passes through, and `Auth.present?/1` is its exact shape check,
  # reused rather than re-implemented so this fake's gate cannot drift out of step with
  # the real one. `get_fees/2` does NOT call this: it builds no request and answers a
  # captured published rate, so there is nothing here for a credential to gate — see
  # its own moduledoc for the incident where gating it anyway broke a consumer.
  defp credentialed(credentials) do
    if FakeInjection.credentials_bypassed?(:webull) do
      :ok
    else
      Auth.present?(credentials)
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
      # Account first, credentials second — matching `Rest.get_positions/2`'s own order
      # (`account_id(opts)` then `Auth.headers/2`). Credentials arrive in
      # `opts[:credentials]` here, as `DpExchange.Webull.get_positions/1` reads them via
      # its own `credentials(opts)` helper rather than as a bare argument.
      with :ok <- fake_account(opts),
           :ok <- authenticated(opts) do
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
  def get_option_chain(underlying, opts \\ []) do
    with_injection(underlying, fn ->
      with :ok <- authenticated(opts) do
        {:ok,
         %Types.OptionChain{
           underlying: underlying,
           expiries: fake_option_grid(underlying, opts),
           # The contract list does not quote the underlying, and a fake that filled this in
           # would teach a consumer to rely on a field that is nil in production.
           underlying_price: nil,
           venue_time: nil,
           provider: :webull
         }}
      end
    end)
  end

  @impl true
  def get_option_expirations(underlying, opts \\ []) do
    with_injection(underlying, fn ->
      with :ok <- authenticated(opts) do
        {:ok, underlying |> fake_option_grid(opts) |> Map.keys() |> Enum.sort(Date)}
      end
    end)
  end

  # The fake's two expiries, narrowed by `opts[:expiry]` and `opts[:strike]` as the venue narrows
  # the contract list (`Rest.get_option_chain/3` sends both to it): a request for one expiry
  # got both here. A request nothing matches is an empty grid, as an empty list is there.
  #
  # A strike with only a call on it stays in, because that is the case a consumer iterating
  # strikes has to see. A fake whose grid was always complete would let one ship code that
  # skips it.
  defp fake_option_grid(underlying, opts) do
    call = fake_contract(underlying, ~D[2026-03-20], Decimal.new("100"), :call)
    put = fake_contract(underlying, ~D[2026-03-20], Decimal.new("100"), :put)
    lone = fake_contract(underlying, ~D[2026-06-19], Decimal.new("120"), :call)

    grid = %{
      ~D[2026-03-20] => %{Decimal.new("100") => %{call: call, put: put}},
      ~D[2026-06-19] => %{Decimal.new("120") => %{call: lone, put: nil}}
    }

    grid
    |> narrow_expiry(Keyword.get(opts, :expiry))
    |> narrow_strike(Keyword.get(opts, :strike))
  end

  defp narrow_expiry(grid, nil), do: grid

  defp narrow_expiry(grid, expiry),
    do: Map.filter(grid, fn {date, _strikes} -> expiry_matches?(date, expiry) end)

  defp expiry_matches?(date, %Date{} = expiry), do: date == expiry
  defp expiry_matches?(date, expiry) when is_binary(expiry), do: Date.to_iso8601(date) == expiry
  defp expiry_matches?(_date, _unreadable), do: false

  defp narrow_strike(grid, nil), do: grid

  defp narrow_strike(grid, strike) do
    wanted = Rest.number_to_decimal(strike)

    grid
    |> Map.new(fn {date, strikes} ->
      {date, Map.filter(strikes, fn {key, _row} -> strike_matches?(key, wanted) end)}
    end)
    |> Map.reject(fn {_date, strikes} -> map_size(strikes) == 0 end)
  end

  defp strike_matches?(_key, nil), do: false
  defp strike_matches?(key, wanted), do: Decimal.equal?(key, wanted)

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
  def list_watchlists(opts \\ []) do
    with_injection(fn ->
      with :ok <- authenticated(opts) do
        # `symbols: nil`, as in the package: this endpoint names watchlists and does not list
        # membership, and a fake returning `[]` would teach a consumer that they are empty.
        #
        # The canned `wl-1` (unless it was deleted here), then the watchlists this process
        # created, so a create is visible in the listing as it is at the venue.
        canned =
          if Map.get(watchlists(), "wl-1") == :deleted,
            do: [],
            else: [watchlist_struct("wl-1", "My Tech Stocks", nil)]

        created =
          for {id, %{name: name}} <- Enum.sort(watchlists()),
              do: watchlist_struct(id, name, nil)

        {:ok, canned ++ created}
      end
    end)
  end

  defp watchlist_struct(id, name, symbols) do
    %Types.Watchlist{id: id, name: name, symbols: symbols, venue_time: nil, provider: :webull}
  end

  # Watchlists this process created (`id => %{name, symbols}`) or deleted (`id => :deleted`).
  # The fake created one and then read back the canned `AAPL`/`GOOG` membership for it.
  @watchlists_key {__MODULE__, :watchlists}

  # The one watchlist the fixture ships with, before anything is created or deleted.
  @canned_watchlist_id "wl-1"

  defp watchlists, do: Process.get(@watchlists_key, %{})

  defp put_watchlist(id, value),
    do: Process.put(@watchlists_key, Map.put(watchlists(), id, value))

  @impl true
  def get_watchlist(id, opts \\ []) do
    with_injection(fn ->
      with :ok <- authenticated(opts) do
        # And `name: nil` here, because the membership endpoint does not return it.
        case Map.fetch(watchlists(), id) do
          {:ok, %{symbols: symbols}} ->
            {:ok, watchlist_struct(id, nil, symbols)}

          # No rows: what `Rest.get_watchlist/3` reads as `:unexpected_response_shape`.
          {:ok, :deleted} ->
            {:error, :unexpected_response_shape}

          # The fixture's own canned watchlist, and only that one.
          :error when id == @canned_watchlist_id ->
            {:ok, watchlist_struct(id, nil, ["AAPL", "GOOG"])}

          # An id this process never created. `get-watchlist-instruments.md` states no
          # answer for an unknown id (only the generic error bodies), so the real shape is
          # UNMEASURED; the fake fails closed with the refusal it already uses for an
          # unknown order id rather than invent members for a watchlist that does not exist.
          :error ->
            {:refused, :not_found}
        end
      end
    end)
  end

  @impl true
  def create_watchlist(name, symbols, opts \\ []) do
    with_injection(fn ->
      # The members and the sort first, from `Rest`'s own validators and before credentials, as
      # `Rest.create_watchlist/4` checks them before it creates anything: a member that is
      # not text, or a `sort` that is not a whole number, was accepted here.
      with {:ok, members} <- Rest.validate_watchlist_symbols(symbols),
           :ok <- Rest.validate_watchlist_sort(Keyword.get(opts, :sort)),
           :ok <- authenticated(opts) do
        # A new id per create, and the members it was created with, which `get_watchlist/2`
        # reads back.
        id = new_watchlist_id()
        put_watchlist(id, %{name: name, symbols: members})
        {:ok, watchlist_struct(id, name, members)}
      end
    end)
  end

  # Minted from a VM-wide monotonic counter, never from the size of the map: that size
  # repeats a number once an id was deleted or touched without being created, and reissued
  # an id the process had already used. An id the process already holds a record for
  # (created, or deleted, or renamed by a caller who guessed it) is skipped, so a
  # never-created or deleted id is never handed out again.
  defp new_watchlist_id do
    id = "wl-new-#{System.unique_integer([:positive, :monotonic])}"
    if Map.has_key?(watchlists(), id), do: new_watchlist_id(), else: id
  end

  @impl true
  def update_watchlist(id, opts \\ []) do
    with_injection(fn ->
      if Keyword.has_key?(opts, :symbols) do
        # Refused rather than silently skipped, as in the package: this venue's update
        # endpoint does not touch membership. Checked BEFORE credentials, as
        # `Rest.update_watchlist/3` checks it before it builds a request.
        {:error, :membership_not_updatable_here}
      else
        with :ok <- Rest.validate_watchlist_sort(Keyword.get(opts, :sort)),
             :ok <- authenticated(opts) do
          rename_watchlist(id, Keyword.get(opts, :name))
          {:ok, watchlist_struct(id, Keyword.get(opts, :name), nil)}
        end
      end
    end)
  end

  # A rename of a watchlist this process created shows in the next listing.
  defp rename_watchlist(id, name) do
    case Map.fetch(watchlists(), id) do
      {:ok, %{} = created} when is_binary(name) -> put_watchlist(id, %{created | name: name})
      _other -> :ok
    end
  end

  @impl true
  def delete_watchlist(id, opts \\ []) do
    with_injection(fn ->
      with :ok <- authenticated(opts) do
        put_watchlist(id, :deleted)
        {:ok, :ok}
      end
    end)
  end

  @impl true
  def get_financials(symbol, kind, opts \\ []) do
    with_injection(symbol, fn ->
      # The kind first, credentials second — `Rest.get_financials/4` refuses a kind that is
      # not a statement (`:company_profile`, a typo) before it builds a request. This
      # answered a statement of whatever `kind` it was given.
      with :ok <- Rest.validate_statement_kind(kind),
           # A `:count` over the 20 the statement pages state is refused before credentials.
           :ok <- Rest.validate_statement_count(kind, opts),
           :ok <- authenticated(opts) do
        {:ok, [statement(symbol, kind)]}
      end
    end)
  end

  # `:indicators` is shaped like the real path's: one statement per fiscal period with the
  # metrics under the venue's names and NO `period_end`, because `financial-indicators.md`
  # publishes none. The other kinds carry a report end date and are unchanged.
  defp statement(symbol, :indicators) do
    %Types.FinancialStatement{
      symbol: symbol,
      kind: :indicators,
      line_items: %{
        "roa" => "0.2133",
        "fiscal_year" => 2025,
        "fiscal_period" => 4,
        "currency" => "USD"
      },
      period_end: nil,
      fiscal_period: "Q4",
      currency: "USD",
      venue_time: nil,
      provider: :webull
    }
  end

  defp statement(symbol, kind) do
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
  end

  @impl true
  def get_corporate_events(opts \\ []) do
    with_injection(fn ->
      # Symbol first, credentials second — `Rest.get_corporate_events/2`'s own
      # `required_symbol/1` runs before anything reaches `Auth.headers/2`, so a caller
      # supplying neither sees `:symbol_required` here too, not
      # `{:missing_credentials, :webull}` — found by a cross-package audit: the two
      # checks were the right side of `with`, but in the wrong order.
      case Keyword.get(opts, :symbol) do
        symbol when is_binary(symbol) ->
          # Symbol, then `opts[:kind]`, credentials last — `Rest.get_corporate_events/2`'s
          # own order. One event per calendar it reads: both without a `:kind`, the one named
          # with it. This answered a dividend whatever `:kind` was asked, and accepted a
          # `:kind` the real path refuses.
          with {:ok, kinds} <- Rest.corporate_event_kinds_for(Keyword.get(opts, :kind)),
               :ok <- authenticated(opts) do
            {:ok, Enum.map(kinds, &fake_event(symbol, &1))}
          end

        _missing ->
          {:error, :symbol_required}
      end
    end)
  end

  defp fake_event(symbol, :dividend) do
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
      # The venue publishes no confirmed flag. `true` would claim an earnings date
      # is final when one routinely is not.
      confirmed: nil,
      details: %{},
      provider: :webull
    }
  end

  # The earnings calendar's one date is carried as `announced_date`, as the real decoder does
  # (`Core.Types.CorporateEvent` has no earnings-specific date field), and the dividend-only
  # fields stay `nil`.
  defp fake_event(symbol, :earnings) do
    %Types.CorporateEvent{
      symbol: symbol,
      kind: :earnings,
      ex_date: nil,
      record_date: nil,
      pay_date: nil,
      announced_date: ~D[2026-08-20],
      amount: nil,
      currency: nil,
      ratio: nil,
      confirmed: nil,
      details: %{},
      provider: :webull
    }
  end

  @impl true
  def get_filings(symbol, opts \\ []) do
    with_injection(symbol, fn ->
      with :ok <- authenticated(opts) do
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
      end
    end)
  end

  @impl true
  def get_news(opts \\ []) do
    with_injection(fn ->
      # Symbols first, credentials second — see `get_corporate_events/1`'s own comment;
      # `Rest.get_news/2`'s `required_symbols/1` runs before anything reaches
      # `Auth.headers/2`.
      # Through `Rest.news_symbols/1`, which also takes one symbol as a bare string - the
      # real path accepts `symbols: "AAPL"`, and the fake refused it as `:symbols_required`.
      case Rest.news_symbols(opts) do
        {:ok, symbols} ->
          with :ok <- authenticated(opts) do
            {:ok,
             [
               %Types.NewsItem{
                 id: "n-1",
                 # `nil`, as `Rest.get_news/2` has it: the venue's stream names no headline,
                 # and a fake that supplied one would teach a consumer to read a field that
                 # is empty in production.
                 headline: nil,
                 summary: "A model's paraphrase, not the publisher's text.",
                 url: nil,
                 # The venue generated it; naming a publisher would attribute a paraphrase.
                 source: "webull",
                 symbols: symbols,
                 published_at: nil,
                 provider: :webull
               }
             ]}
          end

        {:error, _reason} = missing ->
          missing
      end
    end)
  end

  @impl true
  def get_screener(name, opts \\ []) do
    with_injection(fn ->
      # The identifier (and `week52_high_low`'s required `rank_type`) first, credentials
      # second — `Rest.get_screener/3` checks both before it builds a request. This checked
      # credentials first, so an unknown screener without a credential was answered as a
      # missing one, and the `rank_type` requirement was not enforced at all.
      with :ok <- Rest.validate_screener(name, opts),
           :ok <- authenticated(opts) do
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
  def place_order(credentials, request, opts \\ []) do
    with_injection(fn ->
      # The fake enforces the venue's crypto matrix, its account requirement and its
      # credential requirement, in the same order `Rest.place_order/3` does (account,
      # combination, THEN `post/4` -> `Auth.headers/2`), so a consumer's suite cannot go
      # green on an order the venue would reject.
      with :ok <- fake_account(opts),
           :ok <- fake_combination(request),
           # The real path's own request checks (sizing, required prices, session), so the
           # fake refuses what the venue would. It skipped them, and accepted a limit with
           # no price or a market order sized twice.
           :ok <- Rest.validate_order_request(request),
           :ok <- credentialed(credentials) do
        # Remembered (per process), so the id this issues can be cancelled and read back:
        # the caller's own `client_order_id` when it gave one, as the venue echoes it, and
        # otherwise a new one in the venue's format, as `Rest` generates. A fixed id made
        # two placements share one order.
        {:ok, remember_order(placed_order(request, client_order_id(request)))}
      end
    end)
  end

  # Round-tripped through the real module's own encode then decode — not the caller's atom
  # echoed back — so a fake-based suite exercises the same wire names the real venue would
  # see, and would catch a decoder gap the way the real path does.
  #
  # Built by `Rest.order_from_request/2`, the very code `Rest.place_order/3` builds its answer
  # with: side as `:buy | :sell`, sizes and prices as `Decimal`, the stop price echoed. The
  # fake used to build its own and echo the request as typed, so a `"buy"` side or an integer
  # quantity came back unchanged where the real path normalises both.
  defp placed_order(request, id), do: Rest.order_from_request(id, request)

  defp client_order_id(request) do
    case Map.get(request, :client_order_id) do
      nil -> next_issued(:client)
      given -> given
    end
  end

  defp next_issued(kind) do
    count = Process.get(@issued_key, 0) + 1
    Process.put(@issued_key, count)

    case kind do
      :client -> @issued_prefix <> hex_counter(count, 12)
      :system -> @system_order_prefix <> String.pad_leading(Integer.to_string(count), 4, "0")
    end
  end

  defp hex_counter(count, width) do
    count |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(width, "0")
  end

  @impl true
  def place_orders(credentials, requests, opts) do
    # The venue's two limits, and a per-order result. A fake that answered ok-or-error would
    # let a consumer ship code that believes "the batch failed" when most of it was placed.
    #
    # Every shape check below matches `Rest.place_orders/3`'s own order (account, then size
    # and every entry by index through `Rest.validate_batch_orders/1`), with
    # `credentialed/1` last — right before the `post/4` call it stands in for. The entry
    # checks used to be a local copy that knew only the instrument rule, so the fake
    # accepted `STOP_LOSS`, a `:gtc` entry and a price-less `LIMIT` the real path refuses.
    with :ok <- fake_account(opts),
         :ok <- Rest.validate_batch_orders(requests),
         :ok <- credentialed(credentials) do
      {:ok,
       requests
       |> Enum.with_index()
       |> Enum.map(fn {request, index} -> batch_row(request, index) end)}
    end
  end

  # One row of `batch_orders` as `order-batch-place.md` documents it: every row names the
  # order's `client_order_id`; an accepted one adds the system `order_id`, a refused one an
  # `error_code` and a `message` (this said `code`, a key the venue never sends). The
  # second is refused, because a partial batch is the normal shape. An accepted order is
  # remembered under its `client_order_id`, the id `get_order/3` and `cancel_order/3` take,
  # so a batch's order can be read back and cancelled as a placed one can. The row used to
  # carry `order_id => "batch-N"`, an id nothing accepted back.
  defp batch_row(request, 1) do
    %{
      "client_order_id" => client_order_id(request),
      "error_code" => "INSUFFICIENT_BUYING_POWER",
      "message" => "Insufficient buying power."
    }
  end

  defp batch_row(request, _index) do
    id = client_order_id(request)
    remember_order(placed_order(Map.put_new(request, :time_in_force, :day), id))

    %{"client_order_id" => id, "order_id" => next_issued(:system)}
  end

  # The real validator, not a copy: text and non-empty, or `:account_id_required`.
  defp fake_account(opts) do
    with {:ok, _account_id} <- Rest.validate_account(opts), do: :ok
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
  def cancel_order(credentials, client_order_id, opts \\ []) do
    with_injection(fn ->
      # Account first, credentials second — matching `Rest.cancel_order/3`'s own order.
      with :ok <- fake_account(opts),
           :ok <- Rest.validate_order_id(client_order_id),
           :ok <- credentialed(credentials) do
        case lookup_order(client_order_id) do
          {:ok, order} ->
            remember_order(%{order | status: :cancelled})
            {:ok, :cancelled}

          :error ->
            {:refused, :not_found}
        end
      end
    end)
  end

  @impl true
  def get_order(credentials, client_order_id, opts \\ []) do
    with_injection(fn ->
      # Account first, credentials second — matching `Rest.get_order/3`'s own order.
      with :ok <- fake_account(opts),
           :ok <- Rest.validate_order_id(client_order_id),
           :ok <- credentialed(credentials) do
        case lookup_order(client_order_id) do
          {:ok, order} -> {:ok, order}
          :error -> {:refused, :not_found}
        end
      end
    end)
  end

  # Orders this process placed, by id. An order the fake never issued is `:error`, never
  # invented; the one fixed id (`@default_order_id`) is always known, as it always was.
  @orders_key {__MODULE__, :orders}

  # The statuses `Rest.to_order/1` can produce for an order still working. See
  # `fake_order/0` on why there is no `:open`.
  @open_statuses [:pending, :partially_filled]

  defp remember_order(%Types.Order{id: id} = order) do
    Process.put(@orders_key, Map.put(Process.get(@orders_key, %{}), id, order))
    order
  end

  defp lookup_order(id) do
    case Map.fetch(Process.get(@orders_key, %{}), id) do
      {:ok, _order} = found -> found
      :error when id == @default_order_id -> {:ok, fake_order()}
      :error -> :error
    end
  end

  @impl true
  def get_orders(credentials, opts \\ []) do
    with_injection(fn ->
      # Account, then the history window, credentials last — matching `Rest.get_orders/2`'s
      # own order.
      with :ok <- fake_account(opts),
           :ok <- Rest.validate_orders_window(opts),
           :ok <- credentialed(credentials) do
        # Open by default, history when asked — the venue has two endpoints, not a filter.
        #
        # Orders this process placed are listed too, on the side their status puts them.
        # They were findable by `get_order/3` but absent here, so a place-then-list round
        # trip — the first thing a consumer's reconciliation does — never saw its own order.
        # The fixed order is listed once: if this process cancelled it, its stored copy is it.
        {fixed, placed} =
          Process.get(@orders_key, %{})
          |> Map.pop(@default_order_id)

        placed = placed |> Map.values() |> Enum.sort_by(& &1.id)
        {open, closed} = Enum.split_with(placed, &(&1.status in @open_statuses))

        # The fixed order goes on the side ITS status puts it. It was assumed closed whenever
        # a stored copy existed, so one this process had replaced (still pending) vanished
        # from the open list and was listed as history.
        {fixed_open, fixed_closed} = fixed_order_sides(fixed)

        if Keyword.get(opts, :history, false),
          do: {:ok, fixed_closed ++ closed},
          else: {:ok, fixed_open ++ open}
      end
    end)
  end

  # `{in the open listing, in the history listing}` for the fixed order. Never touched: the
  # canned pending order is open and, as history, a filled one. Stored (cancelled, replaced):
  # wherever its own status puts it, and only there.
  defp fixed_order_sides(nil),
    do: {[fake_order()], [%{fake_order() | status: :filled}]}

  defp fixed_order_sides(%Types.Order{status: status} = order) do
    if status in @open_statuses, do: {[order], []}, else: {[], [order]}
  end

  # **`:pending`, not `:open`.** `order-detail.md:215`'s documented `status` enum is
  # PENDING, SUBMITTED, CANCELLED, FILLED, FAILED, PARTIAL_FILLED — no `WORKING`/`OPEN`
  # member — and `Rest.to_order/1`'s own `status_atom/1` no longer maps anything to
  # `Core.Types.Order`'s `:open` for this reason (see that function's own comment). A fake
  # returning `:open` here would simulate a status the real decode path can never produce,
  # which is exactly the "differently capable" divergence this fake exists to avoid.
  defp fake_order do
    %Types.Order{
      id: @default_order_id,
      symbol: "BTC-USD",
      side: :buy,
      order_type: :limit,
      time_in_force: :gtc,
      quantity: Decimal.new("0.5"),
      filled_quantity: Decimal.new("0"),
      price: Decimal.new("40000"),
      status: :pending,
      provider: :webull
    }
  end

  # Upper-cased on the way in, as the real facade does, so a lower-case subscription gets
  # the same answer here as against the venue. Without it the fake delivered nothing for
  # `btc-usd` while the real package delivered `BTC-USD` (checked 2026-09-28).
  defp canonical_case(symbols) when is_list(symbols),
    do: Enum.map(symbols, fn s -> if is_binary(s), do: String.upcase(s), else: s end)

  defp canonical_case(other), do: other

  # The real `Feed` refuses a symbol list that is not a list of non-empty strings with
  # `{:error, {:invalid_symbols, ...}}` rather than crashing the process every caller shares.
  # This fake answers the same way: it may be less capable than the venue, never differently
  # capable, and a consumer's test that passes `nil` here must see what production returns.
  defp check_symbols(symbols) when is_list(symbols) do
    case invalid_symbols(symbols, []) do
      [] -> :ok
      invalid -> {:error, {:invalid_symbols, invalid |> Enum.reverse() |> Enum.take(5)}}
    end
  end

  defp check_symbols(other), do: {:error, {:invalid_symbols, other}}

  # By hand, as `Feed` does, so an improper list is refused and not a raise.
  defp invalid_symbols([symbol | rest], acc) do
    if is_binary(symbol) and symbol != "",
      do: invalid_symbols(rest, acc),
      else: invalid_symbols(rest, [symbol | acc])
  end

  defp invalid_symbols([], acc), do: acc
  defp invalid_symbols(improper_tail, acc), do: [improper_tail | acc]
end
