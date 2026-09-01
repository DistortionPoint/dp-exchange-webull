defmodule DpExchange.Webull.DelegationTest do
  @moduledoc """
  Every facade function reaches the venue.

  This is not ceremony. The facade threads credentials and the rate limiter into each call,
  and a function wired to the wrong `Rest` arity — or wired without `with_limiter/1` —
  compiles, type-checks and then either loses the credential or bypasses the limiter. Both
  failures show up as the venue's refusal rather than as a bug here.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Config
  alias DpExchange.Webull

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

  defp base(extra \\ []) do
    Keyword.merge([credentials: @credentials, retry_attempts: 0], extra)
  end

  defp json(body) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end
  end

  describe "market data" do
    test "get_price/2" do
      body = [%{"symbol" => "BTCUSD", "price" => "40000", "last_trade_time" => 1_787_936_147_000}]

      assert {:ok, quote_struct} = Webull.get_price("BTC-USD", base(plug: json(body)))
      assert quote_struct.provider == :webull
    end

    test "get_top_of_book/2" do
      body = [
        %{
          "symbol" => "BTCUSD",
          "bidPrice" => "39990",
          "askPrice" => "40010",
          "quote_time" => 1_787_936_147_000
        }
      ]

      assert {:ok, top} = Webull.get_top_of_book("BTC-USD", base(plug: json(body)))
      assert Decimal.lt?(top.bid, top.ask)
    end

    test "get_historical_prices/4" do
      body = [
        %{
          "result" => [
            %{
              "time" => 1_787_935_740_000,
              "open" => "1",
              "high" => "2",
              "low" => "0.5",
              "close" => "1.5"
            }
          ]
        }
      ]

      assert {:ok, [candle]} =
               Webull.get_historical_prices("BTC-USD", "1m", [], base(plug: json(body)))

      assert candle.timeframe == "1m"
    end

    test "get_symbols/1" do
      body = %{"data" => [%{"symbol" => "BTCUSD"}]}

      assert {:ok, symbols} = Webull.get_symbols(base(plug: json(body)))
      assert is_list(symbols)
    end

    test "get_order_book/2" do
      body = [
        %{
          "symbol" => "F",
          "quote_time" => 1_787_936_147_000,
          "bids" => [%{"price" => "13.90", "size" => "5"}],
          "asks" => [%{"price" => "13.91", "size" => "3"}]
        }
      ]

      assert {:ok, book} = Webull.get_order_book("F", base(plug: json(body)))
      assert book.symbol == "F"
    end

    test "get_volume_profile/3" do
      body = [
        %{
          "symbol" => "AAPL",
          "result" => [%{"time" => 1_787_936_147_000, "total" => "1000", "delta" => "200"}]
        }
      ]

      assert {:ok, [profile]} = Webull.get_volume_profile("AAPL", "5m", base(plug: json(body)))
      assert profile.timeframe == "5m"
    end

    test "get_auction_imbalance/2" do
      body = [%{"symbol" => "AAPL", "paired_shares" => "100", "imbalance_shares" => "5"}]

      assert {:ok, imbalance} =
               Webull.get_auction_imbalance("AAPL", base(auction: :closing, plug: json(body)))

      assert imbalance.auction == :closing
    end
  end

  describe "account and orders" do
    test "get_accounts/2" do
      body = [%{"account_id" => @account, "account_class" => "CRYPTO"}]

      assert {:ok, [account]} = Webull.get_accounts(@credentials, base(plug: json(body)))
      assert account["account_id"] == @account
    end

    test "get_balances/2" do
      body = %{"account_currency_assets" => [%{"currency" => "USD", "cash_balance" => "100"}]}

      assert {:ok, [balance]} =
               Webull.get_balances(@credentials, base(account_id: @account, plug: json(body)))

      assert balance.currency == "USD"
    end

    test "get_positions/1" do
      body = [%{"symbol" => "BTCUSD", "quantity" => "1", "instrument_type" => "CRYPTO"}]

      assert {:ok, [position]} =
               Webull.get_positions(base(account_id: @account, plug: json(body)))

      assert position.side == :long
    end

    test "get_transfers/2" do
      body = [%{"id" => "a1", "activity_type" => "DEPOSIT", "net_amount" => "100"}]

      assert {:ok, [row]} =
               Webull.get_transfers(@credentials, base(account_id: @account, plug: json(body)))

      assert row["activity_type"] == "DEPOSIT"
    end

    test "place_order/3" do
      request = %{
        symbol: "BTC-USD",
        side: :buy,
        quantity: Decimal.new("0.5"),
        price: Decimal.new("40000"),
        order_type: :limit,
        time_in_force: :gtc
      }

      body = [%{"client_order_id" => "c1"}]

      assert {:ok, order} =
               Webull.place_order(
                 @credentials,
                 request,
                 base(account_id: @account, plug: json(body))
               )

      assert order.id == "c1"
    end

    test "preview_order/3" do
      request = %{
        instrument_type: :equity,
        symbol: "AAPL",
        side: :buy,
        quantity: Decimal.new("10"),
        price: Decimal.new("190"),
        order_type: :limit,
        time_in_force: :day
      }

      body = [%{"estimated_cost" => "1900", "estimated_transaction_fee" => "1"}]

      assert {:ok, preview} =
               Webull.preview_order(
                 @credentials,
                 request,
                 base(account_id: @account, plug: json(body))
               )

      assert preview.instrument_type == :equity
    end

    test "cancel_order/3, get_order/3 and get_orders/2" do
      order = [%{"client_order_id" => "abc", "order_status" => "WORKING"}]

      assert {:ok, :cancelled} =
               Webull.cancel_order(
                 @credentials,
                 "abc",
                 base(account_id: @account, plug: json(%{}))
               )

      assert {:ok, read} =
               Webull.get_order(
                 @credentials,
                 "abc",
                 base(account_id: @account, plug: json(order))
               )

      assert read.id == "abc"

      assert {:ok, [_listed]} =
               Webull.get_orders(@credentials, base(account_id: @account, plug: json(order)))
    end

    test "replace_order/4 reads the order back through the facade" do
      me = self()

      plug = fn conn ->
        send(me, {:path, conn.request_path})

        body =
          if conn.request_path =~ "replace",
            do: %{},
            else: [%{"client_order_id" => "abc", "order_status" => "WORKING"}]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end

      assert {:ok, order} =
               Webull.replace_order(@credentials, "abc", %{price: Decimal.new("191")},
                 credentials: @credentials,
                 account_id: @account,
                 plug: plug,
                 retry_attempts: 0
               )

      assert order.id == "abc"
      assert_receive {:path, "/trading/orders/replace"}
      assert_receive {:path, "/trading/orders/get"}
    end
  end
end
