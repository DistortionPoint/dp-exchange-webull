defmodule DpExchange.Webull.TickAROrderSpecsTest do
  @moduledoc """
  Tick AR, lens X, coverage of the vendor order pages: `common-order-place.md`,
  `order-batch-place.md`, `common-order-preview.md`, `common-order-replace.md`,
  `common-order-cancel.md`, `account-position.md` and `account-balance.md`.

  Each test pins one row of the page's enum/limit table that the builder had drifted from:
  a futures trailing stop the page lists, fields the page scopes to one instrument, an option
  order whose `legs` cannot be sent, a replace judged by a narrower matrix than a place, and
  a position or balance figure the venue sent but this package read as "not stated".
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Config
  alias DpExchange.Webull
  alias DpExchange.Webull.{Fake, Rest}

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

  defp exploding(message), do: fn _conn -> raise message end

  defp read_opts(body), do: [plug: responding(body), account_id: @account, retry_attempts: 0]

  defp limit_order(overrides \\ %{}) do
    Map.merge(
      %{
        instrument_type: :equity,
        symbol: "AAPL",
        side: :buy,
        order_type: :limit,
        time_in_force: :day,
        quantity: "1",
        price: "10"
      },
      overrides
    )
  end

  defp trailing_futures(overrides \\ %{}) do
    Map.merge(
      %{
        instrument_type: :futures,
        symbol: "ESZ5",
        side: :buy,
        order_type: :trailing_stop,
        time_in_force: :gtc,
        quantity: "1",
        trailing_type: :amount,
        trailing_stop_step: "2"
      },
      overrides
    )
  end

  describe "common-order-place.md: TRAILING_STOP_LOSS is excluded for options only" do
    test "a futures trailing stop is accepted, by the validator and by the Fake" do
      assert :ok == Rest.validate_order_request(trailing_futures())

      assert {:ok, order} =
               Fake.place_order(@credentials, trailing_futures(), account_id: @account)

      assert order.order_type == :trailing_stop
      assert order.time_in_force == :gtc
    end

    test "and goes to the wire as a FUTURES TRAILING_STOP_LOSS with its type and step" do
      me = self()

      plug = fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(me, {:sent, Jason.decode!(raw)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!([%{"client_order_id" => "fut-trail-1"}]))
      end

      request = trailing_futures(%{client_order_id: "fut-trail-1"})

      assert {:ok, %{id: "fut-trail-1"}} =
               Rest.place_order(@credentials, request,
                 plug: plug,
                 account_id: @account,
                 retry_attempts: 0
               )

      assert_receive {:sent, body}, 5_000
      leaf = body["new_orders"] |> List.first()
      assert leaf["instrument_type"] == "FUTURES"
      assert leaf["order_type"] == "TRAILING_STOP_LOSS"
      assert leaf["trailing_type"] == "AMOUNT"
      assert leaf["trailing_stop_step"] == "2"
      assert leaf["entrust_type"] == "QTY"
    end

    test "a futures order is still BUY/SELL only and QTY only" do
      assert {:error, {:invalid_side, :short}} =
               Rest.validate_order_request(trailing_futures(%{side: :short}))

      assert {:error, {:cash_sizing_not_supported, :futures}} =
               Rest.validate_order_request(
                 trailing_futures(%{
                   order_type: :market,
                   time_in_force: :day,
                   trailing_type: nil,
                   trailing_stop_step: nil,
                   quantity: nil,
                   amount: "100"
                 })
               )
    end

    test "an option trailing stop is still refused, by type, before any option refusal" do
      assert {:error, {:unsupported_order_type, :trailing_stop}} =
               Rest.validate_order_request(trailing_futures(%{instrument_type: :option}))
    end
  end

  describe "common-order-place.md: fields the page scopes to one instrument" do
    test "support_trading_session is for stock orders only" do
      for instrument <- [:crypto, :futures, :event] do
        request = limit_order(%{instrument_type: instrument, support_trading_session: :core})
        refusal = {:error, {:unexpected_field, :support_trading_session}}

        assert refusal == Rest.validate_order_request(request)
        assert refusal == Fake.place_order(@credentials, request, account_id: @account)
      end

      assert :ok ==
               Rest.validate_order_request(limit_order(%{support_trading_session: :night}))
    end

    test "a bad session value is still named as a bad value, on any instrument" do
      assert {:error, {:unsupported_support_trading_session, "BOGUS"}} =
               Rest.validate_order_request(
                 limit_order(%{instrument_type: :crypto, support_trading_session: "BOGUS"})
               )
    end

    test "event_outcome is for event orders only" do
      for instrument <- [:equity, :crypto, :futures] do
        request = limit_order(%{instrument_type: instrument, event_outcome: :yes})
        refusal = {:error, {:unexpected_field, :event_outcome}}

        assert refusal == Rest.validate_order_request(request)
        assert refusal == Fake.place_order(@credentials, request, account_id: @account)
      end

      assert :ok ==
               Rest.validate_order_request(
                 limit_order(%{instrument_type: :event, event_outcome: :no})
               )
    end

    test "the preview refuses them as the place does" do
      assert {:error, {:unexpected_field, :event_outcome}} =
               Rest.preview_order(
                 @credentials,
                 limit_order(%{event_outcome: :yes}),
                 plug: exploding("must not preview"),
                 account_id: @account,
                 retry_attempts: 0
               )

      assert {:error, {:unexpected_field, :event_outcome}} =
               Fake.preview_order(
                 @credentials,
                 limit_order(%{event_outcome: :yes}),
                 account_id: @account
               )
    end
  end

  describe "common-order-preview.md: no cash-size field, so no cash-sized preview" do
    defp cash_order(overrides \\ %{}),
      do: limit_order(Map.merge(%{quantity: nil, amount: "250"}, overrides))

    # An equity limit, an event BUY at FOK (the only event cash shape place accepts) and a
    # futures market: each passes every check but the preview's own.
    defp cash_requests do
      [
        cash_order(),
        cash_order(%{instrument_type: :event, time_in_force: :fok, event_outcome: :yes}),
        cash_order(%{instrument_type: :futures, order_type: :market, price: nil})
      ]
    end

    test "Rest refuses it, naming the instrument, and sends nothing" do
      me = self()

      plug = fn conn ->
        send(me, :request_sent)
        Plug.Conn.resp(conn, 200, "{}")
      end

      opts = [plug: plug, account_id: @account, retry_attempts: 0]

      for request <- cash_requests() do
        {:ok, instrument} = Map.fetch(request, :instrument_type)

        assert {:error, {:cash_sizing_not_supported, ^instrument}} =
                 Rest.preview_order(@credentials, request, opts)
      end

      refute_receive :request_sent, 600
    end

    test "the Fake and the shared validator refuse it identically" do
      for request <- cash_requests() do
        refusal = {:error, {:cash_sizing_not_supported, request.instrument_type}}

        assert refusal == Rest.validate_preview_request(request)
        assert refusal == Fake.preview_order(@credentials, request, account_id: @account)
      end
    end

    test "place is not affected: the same request still validates and is sent as AMOUNT" do
      me = self()

      plug = fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(me, {:sent, Jason.decode!(raw)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!([%{"client_order_id" => "cash-1"}]))
      end

      request = cash_order(%{client_order_id: "cash-1"})
      assert :ok == Rest.validate_order_request(request)

      assert {:ok, %{id: "cash-1"}} =
               Rest.place_order(@credentials, request,
                 plug: plug,
                 account_id: @account,
                 retry_attempts: 0
               )

      assert_receive {:sent, body}, 5_000
      leaf = body["new_orders"] |> List.first()
      assert leaf["entrust_type"] == "AMOUNT"
      assert leaf["total_cash_amount"] == "250"

      assert {:ok, _order} = Fake.place_order(@credentials, request, account_id: @account)
    end

    test "a place-refused cash order keeps place's tuple, and a quantity preview still works" do
      assert {:error, {:cash_sizing_not_supported, :futures}} =
               Rest.validate_preview_request(
                 cash_order(%{
                   instrument_type: :futures,
                   order_type: :market,
                   time_in_force: :day,
                   price: nil
                 })
               )

      assert {:error, {:unexpected_field, :amount}} =
               Rest.validate_preview_request(limit_order(%{amount: "5"}))

      assert :ok == Rest.validate_preview_request(limit_order())

      body = %{"estimated_cost" => "10.5", "estimated_transaction_fee" => "0.1"}

      assert {:ok, %{instrument_type: :equity, estimated_cost: cost}} =
               Rest.preview_order(@credentials, limit_order(), read_opts(body))

      assert Decimal.equal?(cost, Decimal.new("10.5"))

      assert {:ok, %{instrument_type: :equity}} =
               Fake.preview_order(@credentials, limit_order(), account_id: @account)
    end
  end

  describe "common-order-place.md: an option order is named by its legs" do
    defp option_order(overrides \\ %{}),
      do: limit_order(Map.put(overrides, :instrument_type, :option))

    test "an option order is refused whole, by place, preview and the Fake" do
      refusal = {:error, {:unsupported_instrument_type, :option}}

      assert refusal == Rest.validate_order_request(option_order())

      assert refusal ==
               Rest.place_order(@credentials, option_order(),
                 plug: exploding("must not send an option order with no legs"),
                 account_id: @account,
                 retry_attempts: 0
               )

      assert refusal ==
               Rest.preview_order(@credentials, option_order(),
                 plug: exploding("must not preview an option order with no legs"),
                 account_id: @account,
                 retry_attempts: 0
               )

      assert refusal == Fake.place_order(@credentials, option_order(), account_id: @account)
      assert refusal == Fake.preview_order(@credentials, option_order(), account_id: @account)
    end

    test "an earlier error is still the one named" do
      assert {:error, {:unsupported_order_combination, :limit, :ioc}} =
               Rest.validate_order_request(option_order(%{time_in_force: :ioc}))

      assert {:error, {:missing_field, :order_type}} =
               Rest.validate_order_request(Map.delete(option_order(), :order_type))

      assert {:error, {:cash_sizing_not_supported, :option}} =
               Rest.validate_order_request(option_order(%{quantity: nil, amount: "5"}))
    end

    test "capabilities no longer declare an instrument the builder cannot build" do
      assert Rest.order_instrument_types() == [:crypto, :equity, :event, :futures]
      refute :option in Webull.capabilities().supported_instrument_types
    end

    test "an option order cannot be replaced either: the page requires a leg id" do
      refusal = {:error, {:unsupported_instrument_type, :option}}
      opts = [instrument_type: :option, order_type: :limit]

      assert refusal == Rest.validate_replace("id-1", %{quantity: 2}, opts)

      assert refusal ==
               Fake.replace_order(
                 @credentials,
                 "id-1",
                 %{quantity: 2},
                 [account_id: @account] ++ opts
               )
    end
  end

  describe "common-order-replace.md: a replace is judged like a place" do
    defp replace_opts(instrument, order_type),
      do: [instrument_type: instrument, order_type: order_type]

    test "a duration outside the instrument's matrix is refused, in Rest and the Fake" do
      for {instrument, order_type, changes, refusal} <- [
            {:equity, :limit, %{time_in_force: :ioc},
             {:unsupported_order_combination, :limit, :ioc}},
            {:equity, :limit, %{time_in_force: :fok},
             {:unsupported_order_combination, :limit, :fok}},
            {:futures, :stop, %{time_in_force: :ioc},
             {:unsupported_order_combination, :stop, :ioc}}
          ] do
        opts = replace_opts(instrument, order_type)

        assert {:error, refusal} == Rest.validate_replace("id-1", changes, opts)

        assert {:error, refusal} ==
                 Fake.replace_order(
                   @credentials,
                   "id-1",
                   changes,
                   [account_id: @account] ++ opts
                 )
      end
    end

    test "the durations the page lists for the instrument are accepted" do
      for {instrument, tif} <- [equity: :gtc, futures: :day, event: :fok] do
        assert :ok ==
                 Rest.validate_replace(
                   "id-1",
                   %{time_in_force: tif},
                   replace_opts(instrument, :limit)
                 )
      end
    end

    test "GTD cannot be amended: the replace body has nowhere to put an expire_date" do
      for instrument <- [:equity, :event] do
        assert {:error, {:unsupported_time_in_force, :gtd}} =
                 Rest.validate_replace(
                   "id-1",
                   %{time_in_force: :gtd},
                   replace_opts(instrument, :limit)
                 )
      end
    end

    test "a changed order type the instrument does not serve is refused" do
      assert {:error, {:unsupported_order_type, :market}} =
               Rest.validate_replace("id-1", %{order_type: :market}, replace_opts(:event, :limit))

      assert :ok ==
               Rest.validate_replace(
                 "id-1",
                 %{order_type: :market},
                 replace_opts(:equity, :limit)
               )
    end

    test "a refused replace sends nothing" do
      assert {:error, {:unsupported_order_combination, :limit, :ioc}} =
               Rest.replace_order(
                 @credentials,
                 "id-1",
                 %{time_in_force: :ioc},
                 [
                   plug: exploding("must not send a replace the matrix refuses"),
                   account_id: @account,
                   retry_attempts: 0
                 ] ++ replace_opts(:equity, :limit)
               )
    end
  end

  describe "order-batch-place.md: the batch entry and its caps" do
    defp batch_entry(overrides \\ %{}) do
      Map.merge(
        %{
          symbol: "AAPL",
          side: :buy,
          order_type: :limit,
          time_in_force: :day,
          quantity: "1",
          price: "10",
          support_trading_session: :core
        },
        overrides
      )
    end

    test "fifty orders pass and fifty-one are refused, before anything is sent" do
      assert :ok == Rest.validate_batch_orders(List.duplicate(batch_entry(), 50))

      assert {:error, {:batch_too_large, 51, 50}} =
               Rest.validate_batch_orders(List.duplicate(batch_entry(), 51))

      assert {:error, {:batch_too_large, 51, 50}} =
               Fake.place_orders(@credentials, List.duplicate(batch_entry(), 51),
                 account_id: @account
               )
    end

    test "the enums are the page's: MARKET/LIMIT, DAY, equity, BUY/SELL, QTY" do
      for {overrides, refusal} <- [
            {%{order_type: :stop}, {:unsupported_batch_order_type, :stop}},
            {%{order_type: :trailing_stop}, {:unsupported_batch_order_type, :trailing_stop}},
            {%{time_in_force: :gtc}, {:unsupported_batch_time_in_force, :gtc}},
            {%{side: :short}, {:invalid_side, :short}},
            {%{amount: "10", quantity: nil}, {:unexpected_field, :amount}},
            {%{support_trading_session: "EXTENDED"},
             {:unsupported_support_trading_session, "EXTENDED"}}
          ] do
        assert {:error, {:batch_order_rejected, 0, ^refusal}} =
                 Rest.validate_batch_orders([batch_entry(overrides)])
      end

      assert {:error, {:batch_instrument_not_supported, 0, :crypto}} =
               Rest.validate_batch_orders([batch_entry(%{instrument_type: :crypto})])
    end

    test "quantity, session and the order id are required or bounded per row" do
      assert {:error, {:batch_order_rejected, 0, {:missing_field, :quantity}}} =
               Rest.validate_batch_orders([Map.delete(batch_entry(), :quantity)])

      assert {:error, {:batch_order_rejected, 0, {:missing_field, :support_trading_session}}} =
               Rest.validate_batch_orders([Map.delete(batch_entry(), :support_trading_session)])

      too_long = String.duplicate("a", 33)

      assert {:error, {:batch_order_rejected, 0, {:invalid_client_order_id, ^too_long}}} =
               Rest.validate_batch_orders([batch_entry(%{client_order_id: too_long})])

      assert :ok ==
               Rest.validate_batch_orders([
                 batch_entry(%{client_order_id: String.duplicate("a", 32)})
               ])
    end
  end

  describe "common-order-place.md: client_order_id is at most 32 characters" do
    test "thirty-three is refused on place and preview, thirty-two is sent" do
      too_long = String.duplicate("x", 33)

      assert {:error, {:invalid_client_order_id, ^too_long}} =
               Rest.validate_order_request(limit_order(%{client_order_id: too_long}))

      assert {:error, {:invalid_client_order_id, ^too_long}} =
               Rest.validate_preview_request(limit_order(%{client_order_id: too_long}))

      assert :ok ==
               Rest.validate_order_request(
                 limit_order(%{client_order_id: String.duplicate("x", 32)})
               )
    end
  end

  describe "account-balance.md: a figure the venue sent is not 'not stated'" do
    defp balance_row(overrides) do
      %{
        "account_currency_assets" => [
          Map.merge(
            %{"currency" => "USD", "cash_balance" => "10.5", "frozen_amount" => "1"},
            overrides
          )
        ]
      }
    end

    test "an unreadable cash_balance or frozen_amount refuses the reply" do
      for {overrides, field, raw} <- [
            {%{"cash_balance" => "abc"}, :cash_balance, "abc"},
            {%{"cash_balance" => "NaN"}, :cash_balance, "NaN"},
            {%{"frozen_amount" => "1,5"}, :frozen_amount, "1,5"}
          ] do
        assert {:error, {:invalid_decimal, ^field, ^raw}} =
                 Rest.get_balances(@credentials, read_opts(balance_row(overrides)))
      end
    end

    test "an absent or blank cash_balance (EVENTS_CASH) is still an unknown balance" do
      for empty <- [nil, "", "  "] do
        assert {:ok, [balance]} =
                 Rest.get_balances(
                   @credentials,
                   read_opts(balance_row(%{"cash_balance" => empty}))
                 )

        assert balance.balance == nil
        assert Decimal.equal?(balance.hold, Decimal.new("1"))
      end
    end

    test "readable figures, including a JSON number, are read exactly" do
      assert {:ok, [balance]} =
               Rest.get_balances(
                 @credentials,
                 read_opts(balance_row(%{"cash_balance" => 12, "frozen_amount" => "0.0"}))
               )

      assert Decimal.equal?(balance.balance, Decimal.new("12"))
      assert Decimal.equal?(balance.hold, Decimal.new("0"))
    end
  end

  describe "account-position.md: a figure the venue sent is not 'not stated'" do
    defp position_row(overrides) do
      Map.merge(
        %{
          "position_id" => "N4I4SIM8TJF38KN2TAA0QVVNE9",
          "currency" => "USD",
          "quantity" => "2",
          "symbol" => "AAPL",
          "instrument_type" => "EQUITY",
          "option_strategy" => "SINGLE",
          "last_price" => "10.0",
          "cost_price" => "11.12",
          "unrealized_profit_loss" => "0.08"
        },
        overrides
      )
    end

    test "an unreadable cost, mark or open P&L refuses the list" do
      for {field, key} <- [
            {:cost_price, "cost_price"},
            {:last_price, "last_price"},
            {:unrealized_profit_loss, "unrealized_profit_loss"}
          ] do
        assert {:error, {:invalid_decimal, ^field, "abc"}} =
                 Rest.get_positions(
                   @credentials,
                   read_opts([position_row(%{key => "abc"})])
                 )
      end
    end

    test "an absent figure is nil on the position and the rest are read" do
      assert {:ok, [position]} =
               Rest.get_positions(
                 @credentials,
                 read_opts([position_row(%{"last_price" => nil})])
               )

      assert position.mark_price == nil
      assert Decimal.equal?(position.average_cost, Decimal.new("11.12"))
      assert Decimal.equal?(position.unrealised_pnl, Decimal.new("0.08"))
      assert position.side == :long
    end

    test "every documented instrument type maps, and EVENT and multi-leg rows are refused" do
      for {venue, expected} <- [
            {"EQUITY", :equity},
            {"OPTION", :option},
            {"FUTURES", :futures},
            {"CRYPTO", :crypto}
          ] do
        row = position_row(%{"instrument_type" => venue, "symbol" => "BTCUSD"})

        assert {:ok, [%{instrument_type: ^expected}]} =
                 Rest.get_positions(@credentials, read_opts([row]))
      end

      event = position_row(%{"instrument_type" => "EVENT", "event_outcome" => "yes"})

      assert {:error, {:unsupported_position, "AAPL", :event_outcome}} =
               Rest.get_positions(@credentials, read_opts([event]))

      assert {:error, {:unsupported_position, "AAPL", {:option_strategy, "VERTICAL"}}} =
               Rest.get_positions(
                 @credentials,
                 read_opts([position_row(%{"option_strategy" => "VERTICAL"})])
               )
    end
  end

  describe "common-order-cancel.md: the cancel is keyed on client_order_id" do
    test "a blank id is refused before the account and before anything is sent" do
      assert {:error, {:invalid_order_id, "  "}} =
               Rest.cancel_order(
                 @credentials,
                 "  ",
                 plug: exploding("must not cancel a blank id"),
                 account_id: @account,
                 retry_attempts: 0
               )

      assert {:error, {:missing_option, :account_id}} =
               Rest.cancel_order(@credentials, "abc",
                 plug: exploding("must not cancel without an account"),
                 retry_attempts: 0
               )
    end
  end
end
