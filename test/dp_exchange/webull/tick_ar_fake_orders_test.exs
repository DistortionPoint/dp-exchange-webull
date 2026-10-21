defmodule DpExchange.Webull.TickArFakeOrdersTest do
  @moduledoc """
  Tick AR, lens X, on `DpExchange.Webull.Fake`'s order lifecycle: a terminal order stays
  terminal, and a refused cancel or replace changes nothing it stored.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Types
  alias DpExchange.Webull.Fake

  @credentials %{app_key: "key", app_secret: "secret"}
  @order_opts [credentials: @credentials, account_id: "acct-1"]
  @edit_opts [instrument_type: :equity, order_type: :limit] ++ @order_opts
  @fixed "5f1e9c0a7b2d4e68a3c4d5e6f7081920"

  defp place(id) do
    request = %{
      symbol: "AAPL",
      side: :buy,
      instrument_type: :equity,
      order_type: :limit,
      time_in_force: :day,
      quantity: Decimal.new("3"),
      price: Decimal.new("180"),
      client_order_id: id
    }

    assert {:ok, %Types.Order{id: ^id}} = Fake.place_order(@credentials, request, @order_opts)
  end

  describe "cancel_order/3 on a terminal order" do
    test "a second cancel is refused and the order stays cancelled" do
      place("ar-cancel-twice")
      assert {:ok, :cancelled} = Fake.cancel_order(@credentials, "ar-cancel-twice", @order_opts)

      assert {:refused, {:order_not_cancellable, :cancelled}} =
               Fake.cancel_order(@credentials, "ar-cancel-twice", @order_opts)

      assert {:ok, %Types.Order{status: :cancelled}} =
               Fake.get_order(@credentials, "ar-cancel-twice", @order_opts)
    end

    test "a cancelled order is listed once, as history, after the refused second cancel" do
      place("ar-listed")
      assert {:ok, :cancelled} = Fake.cancel_order(@credentials, "ar-listed", @order_opts)
      assert {:refused, _reason} = Fake.cancel_order(@credentials, "ar-listed", @order_opts)

      assert {:ok, open} = Fake.get_orders(@credentials, @order_opts)
      refute Enum.any?(open, &(&1.id == "ar-listed"))

      assert {:ok, history} = Fake.get_orders(@credentials, [history: true] ++ @order_opts)
      assert [%Types.Order{status: :cancelled}] = Enum.filter(history, &(&1.id == "ar-listed"))
    end

    test "the fixed order cancels once, then is refused" do
      assert {:ok, :cancelled} = Fake.cancel_order(@credentials, @fixed, @order_opts)

      assert {:refused, {:order_not_cancellable, :cancelled}} =
               Fake.cancel_order(@credentials, @fixed, @order_opts)
    end

    test "a batch-placed order cancels once, then is refused" do
      entry = %{
        symbol: "AAPL",
        side: :buy,
        order_type: :limit,
        time_in_force: :day,
        quantity: Decimal.new("1"),
        price: Decimal.new("180"),
        support_trading_session: :core,
        client_order_id: "ar-batch-1"
      }

      other = %{entry | client_order_id: "ar-batch-2"}

      assert {:ok, [%{"order_id" => _id}, _refused]} =
               Fake.place_orders(@credentials, [entry, other], @order_opts)

      assert {:ok, :cancelled} = Fake.cancel_order(@credentials, "ar-batch-1", @order_opts)

      assert {:refused, {:order_not_cancellable, :cancelled}} =
               Fake.cancel_order(@credentials, "ar-batch-1", @order_opts)
    end
  end

  describe "replace_order/4" do
    test "a cancelled order is not amended, and keeps its own fields" do
      place("ar-replace-cancelled")
      id = "ar-replace-cancelled"
      assert {:ok, :cancelled} = Fake.cancel_order(@credentials, id, @order_opts)

      assert {:refused, {:order_not_replaceable, :cancelled}} =
               Fake.replace_order(
                 @credentials,
                 "ar-replace-cancelled",
                 %{quantity: Decimal.new("9")},
                 @edit_opts
               )

      assert {:ok, %Types.Order{status: :cancelled, quantity: quantity}} =
               Fake.get_order(@credentials, "ar-replace-cancelled", @order_opts)

      assert Decimal.equal?(quantity, Decimal.new("3"))
    end

    test "an order type that is not the stored order's is refused and nothing is stored" do
      place("ar-replace-type")

      assert {:refused, {:order_type_mismatch, :limit, :stop}} =
               Fake.replace_order(
                 @credentials,
                 "ar-replace-type",
                 %{stop_price: Decimal.new("170")},
                 [instrument_type: :equity, order_type: :stop] ++ @order_opts
               )

      assert {:ok, %Types.Order{order_type: :limit, stop_price: nil, status: :pending}} =
               Fake.get_order(@credentials, "ar-replace-type", @order_opts)
    end

    test "a working order is still amended in place and stays working" do
      place("ar-replace-ok")

      assert {:ok, %Types.Order{status: :pending} = amended} =
               Fake.replace_order(
                 @credentials,
                 "ar-replace-ok",
                 %{quantity: Decimal.new("4")},
                 @edit_opts
               )

      assert Decimal.equal?(amended.quantity, Decimal.new("4"))
    end
  end

  describe "every order the Fake answers has a status its fill fits" do
    test "the canned order as history reads it is filled, whole, at its price" do
      assert {:ok, history} = Fake.get_orders(@credentials, [history: true] ++ @order_opts)

      assert %Types.Order{} = filled = Enum.find(history, &(&1.status == :filled))
      assert Decimal.equal?(filled.filled_quantity, filled.quantity)
      assert Decimal.equal?(filled.average_price, filled.price)
    end

    test "open, history and cancelled-after-placing orders all pass the same rules" do
      place("ar-consistent")
      assert {:ok, :cancelled} = Fake.cancel_order(@credentials, "ar-consistent", @order_opts)

      assert {:ok, open} = Fake.get_orders(@credentials, @order_opts)
      assert {:ok, history} = Fake.get_orders(@credentials, [history: true] ++ @order_opts)
      assert open != [] and history != []

      for order <- open ++ history, do: assert_fill_fits(order)
    end
  end

  defp assert_fill_fits(%Types.Order{status: status, quantity: quantity, filled_quantity: nil}) do
    refute status in [:filled, :partially_filled], "#{status} states no filled quantity"
    assert quantity != nil
  end

  defp assert_fill_fits(%Types.Order{status: status, quantity: quantity, filled_quantity: fill}) do
    zero? = Decimal.compare(fill, 0) == :eq
    whole? = Decimal.compare(fill, quantity) != :lt

    case status do
      :filled -> assert whole? and not zero?
      :partially_filled -> assert not zero? and not whole?
      :pending -> refute whole? and not zero?
      _no_fill_rule -> :ok
    end
  end
end
