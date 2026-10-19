defmodule DpExchange.Webull.FakeFidelityTest do
  @moduledoc """
  The fake refuses what the real path refuses, in the same order and with the same error
  shape - and each rule comes from a public `Rest` validator rather than a copy, so the two
  cannot drift.

  Every case here was a call the fake answered where `Rest` refuses it (or the reverse
  order of two refusals). A consumer's suite that passed against the fake then failed
  against the venue.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Types
  alias DpExchange.Webull.Fake

  @credentials %{app_key: "key", app_secret: "secret"}
  @opts [credentials: @credentials]
  @order_opts [credentials: @credentials, account_id: "acct-1"]
  # `replace_order/4` is told which order it edits; neither option has a default.
  @edit_opts [instrument_type: :equity, order_type: :limit] ++ @order_opts

  defp equity_request(overrides \\ %{}) do
    Map.merge(
      %{
        symbol: "AAPL",
        side: :buy,
        instrument_type: :equity,
        order_type: :limit,
        time_in_force: :day,
        quantity: Decimal.new("1"),
        price: Decimal.new("180")
      },
      overrides
    )
  end

  describe "preview_order/3 checks the order body the real path checks" do
    test "a priced preview of a complete order still works" do
      assert {:ok, %{instrument_type: :equity}} =
               Fake.preview_order(@credentials, equity_request(), @order_opts)
    end

    test "a limit order with no price is refused" do
      assert {:error, {:missing_field, :price}} =
               Fake.preview_order(
                 @credentials,
                 equity_request(%{price: nil}),
                 @order_opts
               )
    end

    test "an order with no size is refused" do
      assert {:error, {:missing_field, :quantity}} =
               Fake.preview_order(
                 @credentials,
                 equity_request(%{quantity: nil}),
                 @order_opts
               )
    end

    test "a request that is not a map is refused, not raised on" do
      for bad <- [nil, [symbol: "AAPL"], "AAPL"] do
        assert {:error, {:invalid_order_request, ^bad}} =
                 Fake.preview_order(@credentials, bad, @order_opts)
      end
    end

    test "the order is refused before credentials are looked at" do
      assert {:error, {:missing_field, :quantity}} =
               Fake.preview_order(%{}, equity_request(%{quantity: nil}), @order_opts)
    end
  end

  describe "replace_order/4 follows Rest's order and reads the order back" do
    test "an empty amendment is judged first, whatever the opts; an unknown type needs a change" do
      # Core group 50: an empty map is `{:invalid_order_request, %{}}`, checked before the
      # instrument and order-type options.
      assert {:error, {:invalid_order_request, %{}}} =
               Fake.replace_order(
                 @credentials,
                 "abc",
                 %{},
                 [instrument_type: :equity, order_type: :bogus] ++ @order_opts
               )

      assert {:error, {:invalid_order_request, %{}}} =
               Fake.replace_order(@credentials, "abc", %{}, @order_opts)

      assert {:error, {:unsupported_order_type, :bogus}} =
               Fake.replace_order(
                 @credentials,
                 "abc",
                 %{quantity: Decimal.new("1")},
                 [instrument_type: :equity, order_type: :bogus] ++ @order_opts
               )
    end

    test "a quantity-only edit applies the quantity and keeps the price" do
      assert {:ok, order} =
               Fake.replace_order(
                 @credentials,
                 # The fixed order every fake knows (its `get_orders/2` row).
                 "5f1e9c0a7b2d4e68a3c4d5e6f7081920",
                 %{quantity: Decimal.new("2")},
                 @edit_opts
               )

      assert Decimal.equal?(order.quantity, Decimal.new("2"))
      assert Decimal.equal?(order.price, Decimal.new("40000"))
    end
  end

  describe "an id replace_order/4 returns is accepted by get_order/3 and cancel_order/3" do
    test "replacing a placed order amends it in place and the amended order reads back" do
      request = equity_request(%{client_order_id: "replace-1"})

      assert {:ok, %Types.Order{id: "replace-1"}} =
               Fake.place_order(@credentials, request, @order_opts)

      assert {:ok, %Types.Order{id: "replace-1"} = replaced} =
               Fake.replace_order(
                 @credentials,
                 "replace-1",
                 %{quantity: Decimal.new("7")},
                 @edit_opts
               )

      assert Decimal.equal?(replaced.quantity, Decimal.new("7"))

      assert {:ok, %Types.Order{symbol: "AAPL", id: "replace-1"} = read} =
               Fake.get_order(@credentials, "replace-1", @order_opts)

      assert Decimal.equal?(read.quantity, Decimal.new("7"))
      assert Decimal.equal?(read.price, Decimal.new("180"))
      assert {:ok, :cancelled} = Fake.cancel_order(@credentials, "replace-1", @order_opts)
    end

    test "an id this process never placed is refused, not invented" do
      assert {:refused, :not_found} =
               Fake.replace_order(
                 @credentials,
                 "replace-unplaced",
                 %{quantity: Decimal.new("2")},
                 @edit_opts
               )

      # Nothing was invented: the id still reads back as unknown.
      assert {:refused, :not_found} =
               Fake.get_order(@credentials, "replace-unplaced", @order_opts)

      assert {:refused, :not_found} =
               Fake.cancel_order(@credentials, "replace-unplaced", @order_opts)
    end

    test "the fixed order can be replaced and then reads back amended" do
      fixed = "5f1e9c0a7b2d4e68a3c4d5e6f7081920"

      assert {:ok, %Types.Order{id: ^fixed}} =
               Fake.replace_order(
                 @credentials,
                 fixed,
                 %{price: Decimal.new("41000")},
                 @edit_opts
               )

      assert {:ok, %Types.Order{id: ^fixed} = read} =
               Fake.get_order(@credentials, fixed, @order_opts)

      assert Decimal.equal?(read.price, Decimal.new("41000"))
    end

    test "a refused replace remembers nothing" do
      assert {:error, {:invalid_order_request, %{}}} =
               Fake.replace_order(@credentials, "replace-refused", %{}, @edit_opts)

      assert {:refused, :not_found} =
               Fake.get_order(@credentials, "replace-refused", @order_opts)
    end
  end

  describe "an order placed under a caller-chosen id can be read back and cancelled" do
    test "the id place_order echoed is known to get_order and cancel_order" do
      request = %{
        symbol: "BTC-USD",
        side: :buy,
        order_type: :limit,
        time_in_force: :gtc,
        quantity: Decimal.new("0.1"),
        price: Decimal.new("40000"),
        client_order_id: "mine-1"
      }

      assert {:ok, %Types.Order{id: "mine-1"}} =
               Fake.place_order(@credentials, request, @order_opts)

      assert {:ok, %Types.Order{id: "mine-1", status: :pending, symbol: "BTC-USD"}} =
               Fake.get_order(@credentials, "mine-1", @order_opts)

      assert {:ok, :cancelled} = Fake.cancel_order(@credentials, "mine-1", @order_opts)

      assert {:ok, %Types.Order{status: :cancelled}} =
               Fake.get_order(@credentials, "mine-1", @order_opts)
    end

    test "get_orders lists a placed order as open, and as history once cancelled" do
      request = %{
        symbol: "BTC-USD",
        side: :buy,
        order_type: :limit,
        time_in_force: :gtc,
        quantity: Decimal.new("0.1"),
        price: Decimal.new("40000"),
        client_order_id: "listed-1"
      }

      assert {:ok, _order} = Fake.place_order(@credentials, request, @order_opts)
      assert {:ok, open} = Fake.get_orders(@credentials, @order_opts)
      assert "listed-1" in Enum.map(open, & &1.id)

      assert {:ok, :cancelled} = Fake.cancel_order(@credentials, "listed-1", @order_opts)
      assert {:ok, still_open} = Fake.get_orders(@credentials, @order_opts)
      refute "listed-1" in Enum.map(still_open, & &1.id)

      assert {:ok, history} = Fake.get_orders(@credentials, [history: true] ++ @order_opts)
      assert %Types.Order{status: :cancelled} = Enum.find(history, &(&1.id == "listed-1"))
    end

    test "an id nobody placed is still refused" do
      assert {:refused, :not_found} = Fake.get_order(@credentials, "never-placed", @order_opts)
      assert {:refused, :not_found} = Fake.cancel_order(@credentials, "never-placed", @order_opts)
    end
  end

  describe "cash activities" do
    @cross_year [start: ~U[2025-12-01 00:00:00Z], end: ~U[2026-01-31 00:00:00Z]]

    test "a cross-year range is refused by both, as Rest refuses it" do
      assert {:error, {:cross_year_range, 2025, 2026}} =
               Fake.get_transfers(@credentials, @cross_year ++ @order_opts)

      assert {:error, {:cross_year_range, 2025, 2026}} =
               Fake.get_transactions(@credentials, @cross_year ++ @order_opts)
    end

    test "the account is checked before the range" do
      assert {:error, {:missing_option, :account_id}} =
               Fake.get_transactions(@credentials, @cross_year ++ [credentials: @credentials])
    end

    test "get_transactions/2 honours activity_types, as a list or the venue's string" do
      assert {:ok, [%{"activity_type" => "FEES"}]} =
               Fake.get_transactions(@credentials, [activity_types: ["FEES"]] ++ @order_opts)

      assert {:ok, rows} =
               Fake.get_transactions(
                 @credentials,
                 [activity_types: "FEES,DIVIDENDS"] ++ @order_opts
               )

      assert Enum.sort(Enum.map(rows, & &1["activity_type"])) == ["DIVIDENDS", "FEES"]
    end
  end

  describe "market data" do
    test "an unserved width is refused before credentials, like Rest" do
      assert {:error, {:unsupported_timeframe, "1w"}} =
               Fake.get_historical_prices("BTC-USD", "1w", [], [])
    end

    test "a bar count over the crypto maximum is refused" do
      assert {:error, {:invalid_option, :limit, 5000}} =
               Fake.get_historical_prices("BTC-USD", "1m", [], [limit: 5000] ++ @opts)
    end

    test "a footprint session outside PRE, RTH and ATH is refused" do
      assert {:error, {:unsupported_session, "XYZ"}} =
               Fake.get_volume_profile("AAPL", "5m", [session: "XYZ"] ++ @opts)

      assert {:ok, [_profile]} = Fake.get_volume_profile("AAPL", "5m", [session: "RTH"] ++ @opts)
    end

    test "a footprint category the endpoint does not serve is refused" do
      assert {:error, {:unsupported_footprint_category, "US_CRYPTO"}} =
               Fake.get_volume_profile("AAPL", "5m", [category: "US_CRYPTO"] ++ @opts)
    end

    test "get_symbols/1 refuses a category it does not list rather than answering crypto" do
      assert {:error, {:unsupported_instrument_category, "US_STOCK"}} =
               Fake.get_symbols([category: "US_STOCK"] ++ @opts)
    end
  end

  describe "reference data" do
    test "a kind that is not a statement is refused, credentials or not" do
      assert {:error, {:unsupported_statement_kind, :company_profile}} =
               Fake.get_financials("AAPL", :company_profile, @opts)

      assert {:error, {:unsupported_statement_kind, :company_profile}} =
               Fake.get_financials("AAPL", :company_profile, [])
    end

    test "corporate events honour :kind, and read both calendars without it" do
      assert {:ok, [%Types.CorporateEvent{kind: :earnings, announced_date: %Date{}}]} =
               Fake.get_corporate_events([symbol: "AAPL", kind: :earnings] ++ @opts)

      assert {:ok, [%{kind: :dividend}]} =
               Fake.get_corporate_events([symbol: "AAPL", kind: :dividend] ++ @opts)

      assert {:ok, events} = Fake.get_corporate_events([symbol: "AAPL"] ++ @opts)
      assert Enum.map(events, & &1.kind) == [:dividend, :earnings]
    end

    test "a kind the real path refuses is refused before credentials" do
      assert {:error, {:unsupported_event_kind, :split}} =
               Fake.get_corporate_events(symbol: "AAPL", kind: :split)
    end

    test "news takes one symbol as a bare string, as Rest does" do
      assert {:ok, [%Types.NewsItem{symbols: ["AAPL"]}]} =
               Fake.get_news([symbols: "AAPL"] ++ @opts)
    end

    test "an unknown screener is refused before credentials" do
      assert {:error, {:unknown_screener, "nope"}} = Fake.get_screener("nope", [])
    end

    test "week52_high_low needs a rank_type, as Rest requires" do
      assert {:error, :rank_type_required} = Fake.get_screener("week52_high_low", @opts)

      assert {:ok, [%Types.ScreenerResult{}]} =
               Fake.get_screener("week52_high_low", [rank_type: "HIGH"] ++ @opts)
    end

    test "update_watchlist/2 refuses membership before credentials" do
      assert {:error, :membership_not_updatable_here} =
               Fake.update_watchlist("wl-1", symbols: ["AAPL"])
    end
  end
end
