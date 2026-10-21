defmodule DpExchange.Webull.TickAROrdersTest do
  @moduledoc """
  Tick AR, lens X: what an order read back from the venue is allowed to say.

  A group that lists ONE order can still be a contingent parent, a multi-leg option
  strategy or an event order on one outcome; none of those is a plain order and each is
  refused rather than flattened. A zero `filled_price` is the venue's placeholder for
  "nothing filled", and a cancel acknowledgement that does not name the order is not a
  confirmed cancel.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Config
  alias DpExchange.Webull.Rest

  @moduletag :capture_log

  defmodule PermissiveLimiter do
    @moduledoc false
    @behaviour DpExchange.Core.RateLimitBehaviour

    @impl true
    def acquire(_provider, _weight, _opts), do: :ok
    @impl true
    def check(_provider, _weight, _opts), do: :ok
    @impl true
    def record(_provider, _weight, _opts), do: :ok
  end

  setup do
    Config.put_override(:rate_limit_module, PermissiveLimiter)
    :ok
  end

  @credentials %{app_key: "key", app_secret: "secret"}
  @account "93IUJ28O9VO2KBGHDHR4H9"

  defp leg(overrides) do
    Map.merge(
      %{
        "client_order_id" => "abc",
        "symbol" => "AAPL",
        "instrument_type" => "EQUITY",
        "side" => "BUY",
        "order_type" => "LIMIT",
        "time_in_force" => "DAY",
        "status" => "PENDING",
        "total_quantity" => "10"
      },
      overrides
    )
  end

  defp group(combo, leg_overrides),
    do: %{"client_order_id" => "abc", "combo_type" => combo, "orders" => [leg(leg_overrides)]}

  defp responding(body, status \\ 200) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, Jason.encode!(body))
    end
  end

  defp opts(body, status \\ 200),
    do: [plug: responding(body, status), account_id: @account, retry_attempts: 0]

  defp get(group), do: Rest.get_order(@credentials, "abc", opts([group]))

  describe "a group of one order that is not a plain order" do
    for combo <- ["MASTER", "OTO", "OCO", "OTOCO", "TRIPLE"] do
      test "combo_type #{combo} on a single entry is refused, not read as a lone order" do
        assert {:error, {:unsupported_combo_type, unquote(combo)}} =
                 get(group(unquote(combo), %{}))
      end
    end

    for combo <- ["NORMAL", "STOP_PROFIT", "STOP_LOSS"] do
      test "combo_type #{combo} on a single entry is one order and decodes" do
        assert {:ok, %{id: "abc", status: :pending}} = get(group(unquote(combo), %{}))
      end
    end

    test "a multi-leg option strategy in one entry is refused with its strategy" do
      assert {:error, {:unsupported_option_strategy, "VERTICAL"}} =
               get(group("NORMAL", %{"option_strategy" => "VERTICAL"}))
    end

    test "an entry carrying two contract legs is refused even without a strategy name" do
      legs = [%{"id" => "1", "side" => "BUY"}, %{"id" => "2", "side" => "SELL"}]

      assert {:error, {:unsupported_option_strategy, :multi_leg}} =
               get(group("NORMAL", %{"legs" => legs}))
    end

    test "a SINGLE option order with one leg decodes" do
      assert {:ok, %{status: :pending}} =
               get(
                 group("NORMAL", %{
                   "option_strategy" => "SINGLE",
                   "legs" => [%{"id" => "1", "side" => "BUY"}]
                 })
               )
    end

    test "an event order is refused: yes and no are opposite exposures to one symbol" do
      assert {:error, {:unsupported_order, :event_outcome}} =
               get(group("NORMAL", %{"instrument_type" => "EVENT", "event_outcome" => "no"}))
    end

    test "a list holding one is refused whole, naming the group" do
      good = group("NORMAL", %{"client_order_id" => "ok-1"})

      bad =
        "NORMAL"
        |> group(%{"option_strategy" => "IRON_CONDOR"})
        |> Map.put("client_order_id", "condor-1")

      assert {:error, {:unreadable_orders, ["condor-1"]}} =
               Rest.get_orders(@credentials, opts(%{"data" => [good, bad]}))
    end
  end

  describe "fills" do
    test "a zero filled_price on an unfilled order is no average price" do
      unfilled = group("NORMAL", %{"filled_price" => "0", "filled_quantity" => "0"})

      assert {:ok, order} = get(unfilled)
      assert order.average_price == nil
      assert Decimal.equal?(order.filled_quantity, 0)
    end

    test "a positive filled_price is the average price, as the Decimal the venue wrote" do
      assert {:ok, order} =
               get(group("NORMAL", %{"filled_price" => "100.75", "filled_quantity" => "4"}))

      assert Decimal.equal?(order.average_price, Decimal.new("100.75"))
    end

    test "a negative filled_quantity is no execution" do
      assert {:ok, order} = get(group("NORMAL", %{"filled_quantity" => "-3"}))
      assert order.filled_quantity == nil
    end

    test "a cancelled order that was partly filled keeps what filled" do
      assert {:ok, order} =
               get(
                 group("NORMAL", %{
                   "status" => "CANCELLED",
                   "filled_quantity" => "4",
                   "filled_price" => "100.75"
                 })
               )

      assert order.status == :cancelled
      assert Decimal.equal?(order.filled_quantity, 4)
      assert Decimal.equal?(order.average_price, Decimal.new("100.75"))
    end
  end

  describe "history pagination" do
    test "the second page is read, not dropped" do
      me = self()

      plug = fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        key = conn.query_params["pagination_key"]
        send(me, {:page, key})

        body =
          case key do
            nil ->
              %{
                "data" => [
                  %{group("NORMAL", %{"client_order_id" => "one"}) | "client_order_id" => "one"}
                ],
                "pagination_key" => "p2"
              }

            "p2" ->
              %{
                "data" => [
                  %{group("NORMAL", %{"client_order_id" => "two"}) | "client_order_id" => "two"}
                ]
              }
          end

        responding(body).(conn)
      end

      assert {:ok, orders} =
               Rest.get_orders(@credentials,
                 plug: plug,
                 account_id: @account,
                 history: true,
                 retry_attempts: 0
               )

      assert Enum.map(orders, & &1.id) == ["one", "two"]
      assert_receive {:page, nil}, 5_000
      assert_receive {:page, "p2"}, 5_000
    end

    test "a cursor that never advances is refused, not returned as the whole list" do
      page = %{"data" => [group("NORMAL", %{})], "pagination_key" => "same"}

      assert {:error, :pagination_key_did_not_advance} =
               Rest.get_orders(@credentials, opts(page))
    end
  end

  describe "cancel_order/3 reads the acknowledgement" do
    test "an echo of the order's own id is a cancel" do
      assert {:ok, :cancelled} =
               Rest.cancel_order(@credentials, "abc", opts(%{"client_order_id" => "abc"}))
    end

    test "an echo of another id is unconfirmed, with the id asked for" do
      assert {:error, {:order_unconfirmed, "abc", :unexpected_response_shape}} =
               Rest.cancel_order(@credentials, "abc", opts(%{"client_order_id" => "other"}))
    end

    test "a 2xx that names no order is unconfirmed" do
      assert {:error, {:order_unconfirmed, "abc", :unexpected_response_shape}} =
               Rest.cancel_order(@credentials, "abc", opts(%{}))
    end

    test "a refusal of an order that is already filled is a refusal, never success" do
      body = %{"error_code" => "ORDER_FILLED", "message" => "order already filled"}

      assert {:refused, {:venue_error, 417, _detail}} =
               Rest.cancel_order(@credentials, "abc", opts(body, 417))
    end
  end

  describe "a status and a fill that contradict each other are refused" do
    @contradictions [
      {"FILLED with nothing filled", %{"status" => "FILLED", "filled_quantity" => "0"}},
      {"PARTIAL_FILLED with nothing filled",
       %{"status" => "PARTIAL_FILLED", "filled_quantity" => "0"}},
      {"PARTIAL_FILLED with the whole quantity filled",
       %{"status" => "PARTIAL_FILLED", "filled_quantity" => "10"}},
      {"PENDING with the whole quantity filled",
       %{"status" => "PENDING", "filled_quantity" => "10"}},
      {"FILLED with part of it filled", %{"status" => "FILLED", "filled_quantity" => "4"}}
    ]

    for {name, overrides} <- @contradictions do
      test "#{name} is refused by get_order and refuses the list" do
        overrides = unquote(Macro.escape(overrides))

        assert {:error, :unexpected_response_shape} = get(group("NORMAL", overrides))

        assert {:error, {:unreadable_orders, ["abc"]}} =
                 Rest.get_orders(@credentials, opts(%{"data" => [group("NORMAL", overrides)]}))
      end
    end

    test "consistent fills are read as they are" do
      assert {:ok, %{status: :filled}} =
               get(group("NORMAL", %{"status" => "FILLED", "filled_quantity" => "10"}))

      assert {:ok, %{status: :partially_filled}} =
               get(group("NORMAL", %{"status" => "PARTIAL_FILLED", "filled_quantity" => "4"}))

      assert {:ok, %{status: :pending}} =
               get(group("NORMAL", %{"status" => "PENDING", "filled_quantity" => "0"}))

      assert {:ok, %{status: :filled}} = get(group("NORMAL", %{"status" => "FILLED"}))
    end
  end
end
