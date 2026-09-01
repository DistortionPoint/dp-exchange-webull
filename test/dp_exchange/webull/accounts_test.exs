defmodule DpExchange.Webull.AccountsTest do
  @moduledoc """
  Accounts, balances and positions.

  Two assertions carry the weight. **`available_balance` is `nil` and stays `nil`** — the
  venue publishes `frozen_amount`, `held_amount`, `unsettled_cash`, `buying_power` and
  `available_withdrawal`, which are five different numbers, and picking one to call
  "available" would be right for one caller and wrong for the rest.

  And **the side of a position comes from the sign of the quantity**, because that is the
  only place this venue states it. A package assuming `:long` produces a short that is
  exactly backwards with every number in it still plausible.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.{Config, Types}
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

  defp responding(body) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end
  end

  describe "get_accounts/2 — one credential, several asset classes" do
    test "rows come back whole, including the class" do
      # account_class is where this venue's breadth shows: CRYPTO, FUTURES, EVENTS_CASH and
      # the cash and margin classes all reach the same credential. Normalising the row away
      # would lose exactly the field a caller picking an account needs.
      body = [
        %{
          "account_id" => @account,
          "account_number" => "10010048",
          "account_type" => "CASH",
          "account_label" => "Crypto",
          "account_class" => "CRYPTO"
        }
      ]

      assert {:ok, [account]} =
               Rest.get_accounts(@credentials, plug: responding(body), retry_attempts: 0)

      assert account["account_id"] == @account
      assert account["account_class"] == "CRYPTO"
      assert account["account_label"] == "Crypto"
    end

    test "it takes no account_id — the credential decides what it sees" do
      me = self()

      plug = fn conn ->
        send(me, {:query, conn.query_string, conn.request_path})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!([]))
      end

      assert {:ok, []} = Rest.get_accounts(@credentials, plug: plug, retry_attempts: 0)
      assert_receive {:query, query, path}
      assert path == "/trading/accounts/list"
      refute query =~ "account_id"
    end
  end

  describe "get_balances/2 — the available figure this venue does not have one of" do
    defp balance_body(overrides \\ %{}) do
      %{
        "total_asset_currency" => "USD",
        "total_cash_balance" => "485705.0",
        "account_currency_assets" => [
          Map.merge(
            %{
              "currency" => "USD",
              "cash_balance" => "485705.95",
              "settled_cash" => "485705.95",
              "unsettled_cash" => "0.0",
              "market_value" => "0.0",
              "frozen_amount" => "485705",
              "held_amount" => "12.0",
              "buying_power" => "484551",
              "available_withdrawal" => "305587431.94"
            },
            overrides
          )
        ]
      }
    end

    test "balance is cash_balance and hold is frozen_amount" do
      assert {:ok, [balance]} =
               Rest.get_balances(@credentials,
                 plug: responding(balance_body()),
                 account_id: @account,
                 retry_attempts: 0
               )

      assert %Types.Balance{} = balance
      assert balance.currency == "USD"
      assert Decimal.equal?(balance.balance, Decimal.new("485705.95"))
      assert Decimal.equal?(balance.hold, Decimal.new("485705"))
      assert balance.provider == :webull
    end

    test "available_balance is nil, and none of the five candidates is promoted into it" do
      # buying_power, available_withdrawal, settled_cash, cash minus frozen, cash minus held
      # are five different numbers here. Each is "available" to a different caller, and
      # labelling one of them as THE available balance is right once and wrong four times.
      assert {:ok, [balance]} =
               Rest.get_balances(@credentials,
                 plug: responding(balance_body()),
                 account_id: @account,
                 retry_attempts: 0
               )

      assert balance.available_balance == nil
      refute balance.available_balance == Decimal.new("484551")
      refute balance.available_balance == Decimal.new("305587431.94")
    end

    test "the timestamp is when we asked" do
      before = DateTime.utc_now()

      assert {:ok, [balance]} =
               Rest.get_balances(@credentials,
                 plug: responding(balance_body()),
                 account_id: @account,
                 retry_attempts: 0
               )

      assert DateTime.compare(balance.timestamp, before) != :lt
    end

    test "an account with no currency assets is an empty list, not an error" do
      body = %{"total_asset_currency" => "USD", "account_currency_assets" => []}

      assert {:ok, []} =
               Rest.get_balances(@credentials,
                 plug: responding(body),
                 account_id: @account,
                 retry_attempts: 0
               )
    end

    test "a body with no currency assets key is an empty list too" do
      # The venue answered about an account and named no currencies. That is different from
      # an error, and different from a balance of zero.
      assert {:ok, []} =
               Rest.get_balances(@credentials,
                 plug: responding(%{}),
                 account_id: @account,
                 retry_attempts: 0
               )
    end

    test "without an account_id nothing is sent" do
      exploding = fn _conn -> raise "must not read balances without an account" end

      assert {:error, :account_id_required} =
               Rest.get_balances(@credentials, plug: exploding, retry_attempts: 0)
    end
  end

  describe "get_positions/2 — the side the venue never states" do
    defp position_row(overrides \\ %{}) do
      Map.merge(
        %{
          "position_id" => "N4I4SIM8TJF38KN2TAA0QVVNE9",
          "currency" => "USD",
          "quantity" => "1",
          "symbol" => "BTCUSD",
          "instrument_type" => "CRYPTO",
          "last_price" => "40000",
          "cost_price" => "41000",
          "unrealized_profit_loss" => "-1000"
        },
        overrides
      )
    end

    test "a positive quantity is a long, sized positively" do
      assert {:ok, [position]} =
               Rest.get_positions(@credentials,
                 plug: responding([position_row()]),
                 account_id: @account,
                 retry_attempts: 0
               )

      assert %Types.Position{} = position
      assert position.side == :long
      assert Decimal.equal?(position.quantity, Decimal.new("1"))
      assert position.symbol == "BTC-USD"
      assert position.instrument_type == :crypto
    end

    test "a negative quantity is a SHORT, and the quantity comes back positive" do
      # This is the assertion that matters. Direction is in the sign and nowhere else, and a
      # package that assumed :long would report a short that is exactly backwards while
      # every number in it stayed plausible.
      assert {:ok, [position]} =
               Rest.get_positions(@credentials,
                 plug: responding([position_row(%{"quantity" => "-0.4"})]),
                 account_id: @account,
                 retry_attempts: 0
               )

      assert position.side == :short
      assert Decimal.equal?(position.quantity, Decimal.new("0.4"))
      assert Decimal.positive?(position.quantity)
    end

    test "a row with no quantity has no direction either" do
      assert {:ok, [position]} =
               Rest.get_positions(@credentials,
                 plug: responding([position_row(%{"quantity" => nil})]),
                 account_id: @account,
                 retry_attempts: 0
               )

      assert position.side == nil
      assert position.quantity == nil
    end

    test "liquidation price and leverage stay nil, which is not the same as safe" do
      # The venue publishes neither on this endpoint. `nil` here means "not stated"; a
      # caller that needs the number must treat the position as un-assessed.
      assert {:ok, [position]} =
               Rest.get_positions(@credentials,
                 plug: responding([position_row()]),
                 account_id: @account,
                 retry_attempts: 0
               )

      assert position.liquidation_price == nil
      assert position.leverage == nil
    end

    test "the venue's own cost and mark are carried, and the open P&L is not booked" do
      assert {:ok, [position]} =
               Rest.get_positions(@credentials,
                 plug: responding([position_row()]),
                 account_id: @account,
                 retry_attempts: 0
               )

      assert Decimal.equal?(position.average_cost, Decimal.new("41000"))
      assert Decimal.equal?(position.mark_price, Decimal.new("40000"))
      assert Decimal.equal?(position.unrealised_pnl, Decimal.new("-1000"))
      # Marked, not realised. The venue reports only the open figure here.
      assert position.realised_pnl == nil
    end

    for {venue, expected} <- [
          {"EQUITY", :equity},
          {"OPTION", :option},
          {"FUTURES", :futures},
          {"CRYPTO", :crypto},
          {"EVENT", :event}
        ] do
      test "instrument type #{venue} maps to #{expected}" do
        assert {:ok, [position]} =
                 Rest.get_positions(@credentials,
                   plug: responding([position_row(%{"instrument_type" => unquote(venue)})]),
                   account_id: @account,
                   retry_attempts: 0
                 )

        assert position.instrument_type == unquote(expected)
      end
    end

    test "an instrument type this package does not know is nil" do
      assert {:ok, [position]} =
               Rest.get_positions(@credentials,
                 plug: responding([position_row(%{"instrument_type" => "WARRANT"})]),
                 account_id: @account,
                 retry_attempts: 0
               )

      assert position.instrument_type == nil
    end

    test "no positions is an empty list, not an error" do
      assert {:ok, []} =
               Rest.get_positions(@credentials,
                 plug: responding([]),
                 account_id: @account,
                 retry_attempts: 0
               )
    end

    test "without an account_id nothing is sent" do
      exploding = fn _conn -> raise "must not read positions without an account" end

      assert {:error, :account_id_required} =
               Rest.get_positions(@credentials, plug: exploding, retry_attempts: 0)
    end
  end

  describe "cash activities — a dividend is not a deposit" do
    defp activity(overrides \\ %{}) do
      Map.merge(
        %{
          "id" => "a1b2c3d4e5f6g7h8i9j0",
          "account_id" => "93IUJ28O9VO2KBGHDHR4H9",
          "activity_type" => "DEPOSIT",
          "activity_sub_type" => "ACH",
          "currency" => "USD",
          "trade_date" => "2026-08-31",
          "net_amount" => "1500.0",
          "biz_time" => "2026-08-31T10:15:30.691Z"
        },
        overrides
      )
    end

    test "only deposits, withdrawals and transfers are asked for by default" do
      # This endpoint also lists TRADE, FEES, DIVIDENDS, TAX, INTERESTS, CORPORATE_ACTION
      # and more. A dividend and a deposit both credit cash and neither is the other; a
      # caller computing what it put in would count income as contribution.
      me = self()

      plug = fn conn ->
        send(me, {:query, conn.query_string})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!([]))
      end

      assert {:ok, []} =
               Rest.get_transfers(@credentials,
                 plug: plug,
                 account_id: @account,
                 retry_attempts: 0
               )

      assert_receive {:query, query}
      assert query =~ "activity_types=DEPOSIT%2CWITHDRAW%2CTRANSFER"
    end

    test "the filter goes to the venue, not to the page it returned" do
      # Filtering here would silently drop matching rows that were on the next page.
      me = self()

      plug = fn conn ->
        send(me, {:query, conn.query_string})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!([activity(%{"activity_type" => "DIVIDENDS"})]))
      end

      assert {:ok, [row]} =
               Rest.get_transfers(@credentials,
                 activity_types: ["DIVIDENDS"],
                 plug: plug,
                 account_id: @account,
                 retry_attempts: 0
               )

      assert_receive {:query, query}
      assert query =~ "activity_types=DIVIDENDS"
      # The venue answered with what it was asked for, and nothing here second-guessed it.
      assert row["activity_type"] == "DIVIDENDS"
    end

    test "rows come back whole, sub-type included" do
      # activity_sub_type alone has 60-odd values carrying the distinction between an ACH
      # deposit and a wire, and no struct in this contract has anywhere to put them.
      assert {:ok, [row]} =
               Rest.get_transfers(@credentials,
                 plug: responding([activity()]),
                 account_id: @account,
                 retry_attempts: 0
               )

      assert row["activity_sub_type"] == "ACH"
      assert row["net_amount"] == "1500.0"
      assert row["biz_time"] == "2026-08-31T10:15:30.691Z"
    end

    test "a cross-year range is refused before the request" do
      # The venue says cross-year queries are not supported. Sending one and reading the
      # answer would give a real list missing whichever half it dropped.
      exploding = fn _conn -> raise "must not send a cross-year activity range" end

      assert {:error, {:cross_year_range, 2025, 2026}} =
               Rest.get_transfers(@credentials,
                 start: ~U[2025-12-31 00:00:00Z],
                 end: ~U[2026-01-02 00:00:00Z],
                 plug: exploding,
                 account_id: @account,
                 retry_attempts: 0
               )
    end

    test "a range inside one year is sent in the venue's own format" do
      me = self()

      plug = fn conn ->
        send(me, {:query, conn.query_string})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!([]))
      end

      assert {:ok, []} =
               Rest.get_transfers(@credentials,
                 start: ~U[2026-01-05 22:59:59Z],
                 end: ~U[2026-01-06 22:59:59Z],
                 limit: 100,
                 plug: plug,
                 account_id: @account,
                 retry_attempts: 0
               )

      assert_receive {:query, query}
      assert query =~ "start_time=2026-01-05T22%3A59%3A59"
      assert query =~ "page_size=100"
    end

    test "no range means the venue's own 7-day default, not this package's" do
      me = self()

      plug = fn conn ->
        send(me, {:query, conn.query_string})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!([]))
      end

      assert {:ok, []} =
               Rest.get_transfers(@credentials,
                 plug: plug,
                 account_id: @account,
                 retry_attempts: 0
               )

      assert_receive {:query, query}
      refute query =~ "start_time"
      refute query =~ "end_time"
    end

    test "without an account_id nothing is sent" do
      exploding = fn _conn -> raise "must not read activities without an account" end

      assert {:error, :account_id_required} =
               Rest.get_transfers(@credentials, plug: exploding, retry_attempts: 0)
    end
  end
end
