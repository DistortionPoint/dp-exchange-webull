defmodule DpExchange.Webull.FakeTest do
  @moduledoc """
  The fake is what a consumer's own suite runs against, so a consumer only learns this
  venue's rules if the fake enforces them. These assertions are that it does: the
  credentials gate, the symbols this venue actually lists, the crypto order matrix, and the
  account every order call needs.

  A fake that answered `{:ok, …}` to all of those would let a consuming suite go green on
  calls the real venue rejects — which is the only way a fake can do harm.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Types
  alias DpExchange.Webull.Fake

  @credentials %{app_key: "key", app_secret: "secret"}
  @opts [credentials: @credentials]
  @order_opts [credentials: @credentials, account_id: "93IUJ28O9VO2KBGHDHR4H9"]

  describe "the credentials gate" do
    test "reads refuse without credentials rather than answering" do
      assert {:refused, :missing_credentials} = Fake.get_price("BTC-USD", [])
      assert {:refused, :missing_credentials} = Fake.get_top_of_book("BTC-USD", [])
      assert {:refused, :missing_credentials} = Fake.get_symbols([])

      assert {:refused, :missing_credentials} =
               Fake.get_historical_prices("BTC-USD", "1m", [], [])
    end
  end

  describe "quotes and the book are different questions" do
    test "a price is the last trade, and carries no bid or ask" do
      assert {:ok, %Types.Quote{} = quote_} = Fake.get_price("BTC-USD", @opts)
      assert Decimal.equal?(quote_.price, Decimal.new("77845.79"))
      # This venue publishes no volume. `nil` says so; zero would be a number nobody sent.
      assert quote_.volume == nil
      assert quote_.provider == :webull
      refute Map.has_key?(quote_, :bid)
    end

    test "the book has a bid and an ask, and no price at all" do
      assert {:ok, %Types.TopOfBook{} = book} = Fake.get_top_of_book("BTC-USD", @opts)
      assert Decimal.lt?(book.bid, book.ask)
      refute Map.has_key?(book, :price)
      assert book.observed_at
    end

    test "a symbol this venue does not list is refused, not an empty answer" do
      assert {:refused, :not_listed} = Fake.get_price("DOGE-USD", @opts)
      assert {:refused, :not_listed} = Fake.get_top_of_book("DOGE-USD", @opts)
      assert {:refused, :not_listed} = Fake.get_historical_prices("DOGE-USD", "1m", [], @opts)
    end
  end

  describe "candles" do
    test "a timeframe this venue does not serve is an error, not the nearest one" do
      assert {:error, {:unsupported_timeframe, "1w"}} =
               Fake.get_historical_prices("BTC-USD", "1w", [], @opts)
    end

    test "a served timeframe returns candles" do
      assert {:ok, [%Types.Candle{} = candle]} =
               Fake.get_historical_prices("BTC-USD", "1m", [], @opts)

      assert Types.Candle.coherent?(candle)
    end
  end

  describe "the symbols this venue lists" do
    test "get_symbols returns the fake's catalogue" do
      assert {:ok, symbols} = Fake.get_symbols(@opts)
      assert "BTC-USD" in symbols
    end

    test "the market is open, because this venue's crypto market does not close" do
      assert {:ok, :open} = Fake.market_status([])
    end
  end

  describe "the order matrix the venue states in prose" do
    defp request(overrides) do
      Map.merge(
        %{
          symbol: "BTC-USD",
          side: :buy,
          quantity: Decimal.new("0.5"),
          price: Decimal.new("40000"),
          order_type: :limit,
          time_in_force: :gtc
        },
        overrides
      )
    end

    for {type, tif} <- [
          {:market, :ioc},
          {:limit, :day},
          {:limit, :gtc},
          {:stop_limit, :day},
          {:stop_limit, :gtc}
        ] do
      test "#{type}/#{tif} is accepted" do
        assert {:ok, %Types.Order{}} =
                 Fake.place_order(
                   @credentials,
                   request(%{order_type: unquote(type), time_in_force: unquote(tif)}),
                   @order_opts
                 )
      end
    end

    test "MARKET with anything but IOC is refused" do
      assert {:error, {:unsupported_order_combination, :crypto, :market, :gtc}} =
               Fake.place_order(
                 @credentials,
                 request(%{order_type: :market, time_in_force: :gtc}),
                 @order_opts
               )
    end

    test "an order without an account is an error, as on the real venue" do
      assert {:error, :account_id_required} =
               Fake.place_order(@credentials, request(%{}), credentials: @credentials)
    end
  end

  describe "the order lifecycle round-trips on the id place_order returned" do
    test "cancel takes the id place_order handed back" do
      assert {:ok, order} = Fake.place_order(@credentials, request(%{}), @order_opts)
      assert {:ok, :cancelled} = Fake.cancel_order(@credentials, order.id, @order_opts)
    end

    test "get_order takes the same id" do
      assert {:ok, order} = Fake.place_order(@credentials, request(%{}), @order_opts)
      assert {:ok, read} = Fake.get_order(@credentials, order.id, @order_opts)
      assert read.id == order.id
    end

    test "an id the fake never issued is refused, not invented" do
      assert {:refused, :not_found} = Fake.cancel_order(@credentials, "nope", @order_opts)
      assert {:refused, :not_found} = Fake.get_order(@credentials, "nope", @order_opts)
    end

    test "open and historical are different questions here too" do
      assert {:ok, [open]} = Fake.get_orders(@credentials, @order_opts)
      assert open.status == :open

      assert {:ok, [done]} = Fake.get_orders(@credentials, [history: true] ++ @order_opts)
      assert done.status == :filled
    end

    test "every order call needs an account" do
      only_credentials = [credentials: @credentials]

      assert {:error, :account_id_required} =
               Fake.cancel_order(@credentials, "fake-webull-order-1", only_credentials)

      assert {:error, :account_id_required} =
               Fake.get_order(@credentials, "fake-webull-order-1", only_credentials)

      assert {:error, :account_id_required} = Fake.get_orders(@credentials, only_credentials)
    end
  end

  describe "the streaming surface" do
    test "subscribing and unsubscribing report what is covered" do
      assert :ok = Fake.subscribe(["BTC-USD"], @opts)
      assert Fake.coverage([])["BTC-USD"] == :stream
      assert :ok = Fake.unsubscribe(["BTC-USD"], @opts)
    end
  end

  describe "the fake's account surface" do
    test "balances carry a hold and no available figure, as production does" do
      # The venue publishes five disagreeing "available" numbers. A fake that picked one
      # would teach a consumer to rely on a field that is nil in production.
      assert {:ok, [balance]} = Fake.get_balances(@credentials, @order_opts)

      assert balance.available_balance == nil
      assert Decimal.positive?(balance.hold)
      assert balance.currency == "USD"
    end

    test "accounts span more than one class, because one credential does" do
      assert {:ok, accounts} = Fake.get_accounts(@credentials, [])
      classes = Enum.map(accounts, & &1["account_class"])

      assert "CRYPTO" in classes
      assert "INDIVIDUAL_MARGIN" in classes
    end

    test "a position is SHORT, which is the case a fake must carry" do
      # Direction is in the sign of the quantity and nowhere else on this venue. A fake that
      # only ever returned a long would never exercise the conversion.
      assert {:ok, [position]} = Fake.get_positions(@order_opts)

      assert position.side == :short
      assert Decimal.positive?(position.quantity)
      assert position.liquidation_price == nil
    end

    test "cash activities exclude dividends by default" do
      assert {:ok, [only]} = Fake.get_transfers(@credentials, @order_opts)
      assert only["activity_type"] == "DEPOSIT"

      assert {:ok, both} =
               Fake.get_transfers(
                 @credentials,
                 [activity_types: ~w(DEPOSIT DIVIDENDS)] ++ @order_opts
               )

      assert length(both) == 2
    end

    test "every account call refuses without an account_id" do
      only_credentials = [credentials: @credentials]

      assert {:error, :account_id_required} = Fake.get_balances(@credentials, only_credentials)
      assert {:error, :account_id_required} = Fake.get_positions(only_credentials)
      assert {:error, :account_id_required} = Fake.get_transfers(@credentials, only_credentials)
    end
  end

  describe "the fake's preview and replace" do
    test "crypto is refused, as it is in production" do
      assert {:error, {:preview_not_supported, :crypto}} =
               Fake.preview_order(@credentials, request(%{}), @order_opts)
    end

    test "an equity order is priced" do
      assert {:ok, preview} =
               Fake.preview_order(
                 @credentials,
                 request(%{instrument_type: :equity, symbol: "AAPL", time_in_force: :day}),
                 @order_opts
               )

      assert preview.instrument_type == :equity
      assert Decimal.positive?(preview.estimated_cost)
    end

    test "replacing a crypto order is refused" do
      assert {:error, {:preview_not_supported, :crypto}} =
               Fake.replace_order(
                 @credentials,
                 "abc",
                 %{price: Decimal.new("1")},
                 [instrument_type: :crypto] ++ @order_opts
               )
    end

    test "an empty amendment is refused" do
      assert {:error, :no_order_changes} =
               Fake.replace_order(@credentials, "abc", %{}, @order_opts)
    end

    test "an edit the venue does not allow is refused" do
      assert {:error, {:unsupported_order_edit, :limit, [:side]}} =
               Fake.replace_order(@credentials, "abc", %{side: :sell}, @order_opts)
    end

    test "a price change comes back on the order" do
      assert {:ok, order} =
               Fake.replace_order(
                 @credentials,
                 "abc",
                 %{price: Decimal.new("41000")},
                 @order_opts
               )

      assert order.id == "abc"
      assert Decimal.equal?(order.price, Decimal.new("41000"))
    end
  end

  describe "the fake's microstructure surface" do
    test "a footprint's delta does not reconcile with its totals, on purpose" do
      # A fake where the three always agree would teach a consumer they must. The venue's
      # classifier leaves some prints unattributed.
      assert {:ok, [profile]} = Fake.get_volume_profile("AAPL", "5m", @opts)

      refute Decimal.equal?(profile.delta, Decimal.sub(profile.buy_volume, profile.sell_volume))
      assert Types.VolumeProfile.point_of_control(profile) == "24.21"
    end

    test "a width this endpoint does not serve is an error" do
      assert {:error, {:unsupported_timeframe, "1h"}} =
               Fake.get_volume_profile("AAPL", "1h", @opts)
    end

    test "the overnight session is refused" do
      assert {:error, {:unsupported_session, "OVN"}} =
               Fake.get_volume_profile("AAPL", "5m", [session: "OVN"] ++ @opts)
    end

    test "the imbalance's venue time is older than when it was observed" do
      # Outside an auction window the venue returns the last imbalance. A fake where the
      # two agree would never exercise a consumer's staleness check.
      assert {:ok, imbalance} = Fake.get_auction_imbalance("AAPL", [auction: :closing] ++ @opts)

      assert DateTime.compare(imbalance.observed_at, imbalance.venue_time) == :gt
      assert imbalance.side == "2"
    end

    test "no auction is an error, as it is on the real venue" do
      assert {:error, :auction_required} = Fake.get_auction_imbalance("AAPL", @opts)
    end

    test "an auction the venue does not have is an error" do
      assert {:error, {:unsupported_auction, :midday}} =
               Fake.get_auction_imbalance("AAPL", [auction: :midday] ++ @opts)
    end

    test "the book refuses a crypto pair, which this venue publishes no depth for" do
      assert {:error, {:unsupported_book_category, _category}} =
               Fake.get_order_book("BTC-USD", @opts)
    end

    test "an equity book has levels on both sides" do
      assert {:ok, book} = Fake.get_order_book("F", @opts)

      assert length(book.bids) == 2
      assert length(book.asks) == 2
      assert book.sequence == nil
    end
  end
end
