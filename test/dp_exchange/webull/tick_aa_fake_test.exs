defmodule DpExchange.Webull.TickAaFakeTest do
  @moduledoc """
  The fake's lines no other suite ran: the default-argument arities (each must answer
  exactly what its explicit `[]` arity answers, because a consumer calling the short form
  must not meet a different fake), the fail-closed option narrowing, the `:indicators`
  statement shape and an order-type amendment.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Webull.{Environment, Fake}

  @credentials %{app_key: "test-key-not-real", app_secret: "test-secret-not-real"}
  @opts [credentials: @credentials]
  @order_opts [credentials: @credentials, account_id: "93IUJ28O9VO2KBGHDHR4H9"]
  @known_order_id "5f1e9c0a7b2d4e68a3c4d5e6f7081920"

  describe "Environment.resolve/0" do
    test "with no options resolves the process-scoped or default environment" do
      assert Environment.resolve() == Environment.resolve([])
      assert Environment.resolve() in Environment.known()
    end
  end

  describe "default-argument arities answer what the explicit empty-options arity answers" do
    test "market data reads" do
      assert Fake.get_prices(["BTC-USD"]) == Fake.get_prices(["BTC-USD"], [])
      assert Fake.get_top_of_book("BTC-USD") == Fake.get_top_of_book("BTC-USD", [])
      assert Fake.get_order_book("AAPL") == Fake.get_order_book("AAPL", [])
      assert Fake.get_trades("AAPL") == Fake.get_trades("AAPL", [])
      assert Fake.get_volume_profile("AAPL", "5m") == Fake.get_volume_profile("AAPL", "5m", [])
      assert Fake.get_auction_imbalance("AAPL") == Fake.get_auction_imbalance("AAPL", [])
      assert Fake.list_instruments() == Fake.list_instruments([])
    end

    test "unserved wallet and conversion calls refuse as not supported, at the facade's arity" do
      for result <- [
            Fake.request_approved_address("BTC", "BTC", "addr", []),
            Fake.quote_conversion("BTC", "USD", "1", []),
            Fake.get_deposit_address("BTC", "BTC", []),
            Fake.estimate_withdrawal_fee("BTC", "BTC", "1", []),
            Fake.withdraw("BTC", "BTC", "1", "addr", [])
          ] do
        assert result == {:error, :not_supported}
      end
    end

    test "account, watchlist and order calls" do
      assert Fake.update_watchlist("1") == Fake.update_watchlist("1", [])
      assert Fake.preview_order(%{}, %{}) == Fake.preview_order(%{}, %{}, [])
      assert Fake.replace_order(%{}, "abc", %{}) == Fake.replace_order(%{}, "abc", %{}, [])
      assert Fake.place_order(%{}, %{}) == Fake.place_order(%{}, %{}, [])

      assert Fake.cancel_order(%{}, @known_order_id) ==
               Fake.cancel_order(%{}, @known_order_id, [])

      assert Fake.get_order(%{}, @known_order_id) == Fake.get_order(%{}, @known_order_id, [])
      assert Fake.get_orders(%{}) == Fake.get_orders(%{}, [])

      # Every one of these is called with no credentials or an empty request, so each must
      # refuse; two identical `{:ok, _}` answers would otherwise satisfy the equalities above.
      for result <- [
            Fake.get_positions([]),
            Fake.preview_order(%{}, %{}),
            Fake.replace_order(%{}, "abc", %{}),
            Fake.place_order(%{}, %{}),
            Fake.cancel_order(%{}, @known_order_id),
            Fake.get_order(%{}, @known_order_id),
            Fake.get_orders(%{})
          ] do
        assert match?({:error, _reason}, result) or match?({:refused, _reason}, result)
      end
    end
  end

  describe "get_prices/2" do
    test "a category other than crypto is refused, not answered with crypto prices" do
      assert {:error, {:unsupported_category, "US_STOCK"}} =
               Fake.get_prices(["AAPL"], [category: "US_STOCK"] ++ @opts)
    end
  end

  describe "get_financials/3" do
    test ":indicators carries the metrics and no period end" do
      assert {:ok, [statement]} = Fake.get_financials("AAPL", :indicators, @opts)
      assert statement.kind == :indicators
      assert statement.period_end == nil
      assert statement.fiscal_period == "Q4"
      assert statement.line_items["roa"] == "0.2133"
    end
  end

  describe "option chain narrowing fails closed" do
    test "an expiry that is neither a Date nor an ISO string matches nothing" do
      assert {:ok, %{expiries: expiries}} =
               Fake.get_option_chain("AAPL", [expiry: 20_260_320] ++ @opts)

      assert expiries == %{}
    end

    test "a strike that is not a number matches nothing" do
      assert {:ok, %{expiries: expiries}} =
               Fake.get_option_chain("AAPL", [strike: "not-a-number"] ++ @opts)

      assert expiries == %{}
    end
  end

  describe "replace_order/4" do
    test "an order type change comes back on the order as given" do
      assert {:ok, order} =
               Fake.replace_order(
                 @credentials,
                 @known_order_id,
                 %{order_type: :market},
                 [instrument_type: :equity, order_type: :limit] ++ @order_opts
               )

      assert order.order_type == :market
    end
  end
end
