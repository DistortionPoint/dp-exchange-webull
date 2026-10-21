defmodule DpExchange.Webull.TickArRestDocsBTest do
  @moduledoc """
  Tick AR, lens V, second half of `DpExchange.Webull.Rest`: the error tuples its `@doc`s now
  name are the ones the code returns, and the option check that was missing (an option map for
  `:expiry` or `:strike` raised `Protocol.UndefinedError` in the caller's process) is made, by
  the real path and by `DpExchange.Webull.Fake` alike.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Config
  alias DpExchange.Core.Types.Order
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

  @credentials %{app_key: "test-key-not-real", app_secret: "test-secret-not-real"}

  defp responding(body) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end
  end

  defp capturing(body, test_pid) do
    fn conn ->
      send(test_pid, {:request, conn.request_path, conn.query_string})
      responding(body).(conn)
    end
  end

  defp sent(body), do: [plug: responding(body), retry_attempts: 0]

  defp contract(overrides) do
    Map.merge(
      %{
        "symbol" => "AAPL250320C00100000",
        "expiration_date" => "2026-03-20",
        "strike_price" => "100",
        "option_type" => "CALL",
        "multiplier" => "100"
      },
      overrides
    )
  end

  defp batch_entry(overrides \\ %{}) do
    Map.merge(
      %{
        symbol: "AAPL",
        side: :buy,
        order_type: :limit,
        time_in_force: :day,
        quantity: "1",
        price: "10",
        support_trading_session: "CORE"
      },
      overrides
    )
  end

  defp order(overrides) do
    Map.merge(
      %{
        symbol: "AAPL",
        side: :buy,
        order_type: :limit,
        time_in_force: :day,
        quantity: "1",
        price: "10",
        instrument_type: :equity
      },
      overrides
    )
  end

  describe "option chain filters are checked before the query is built" do
    test "a map or a list for :expiry or :strike is refused, not raised, and nothing is sent" do
      for {key, bad} <- [expiry: %{a: 1}, expiry: ["2026-03-20"], strike: %{a: 1}, strike: [1]] do
        opts = [plug: capturing(%{"data" => []}, self()), retry_attempts: 0] ++ [{key, bad}]

        assert {:error, {:invalid_option, ^key, ^bad}} =
                 Rest.get_option_chain("AAPL", @credentials, opts)

        assert {:error, {:invalid_option, ^key, ^bad}} =
                 Rest.get_option_expirations("AAPL", @credentials, opts)
      end

      refute_receive {:request, _path, _query}, 500
    end

    test "the fake refuses exactly what the real path refuses" do
      opts = [credentials: @credentials]

      assert {:error, {:invalid_option, :expiry, %{a: 1}}} =
               Fake.get_option_chain("AAPL", [expiry: %{a: 1}] ++ opts)

      assert {:error, {:invalid_option, :strike, [1]}} =
               Fake.get_option_expirations("AAPL", [strike: [1]] ++ opts)

      assert {:ok, _chain} = Fake.get_option_chain("AAPL", [expiry: ~D[2026-03-20]] ++ opts)
    end

    test "a Date expiry and a Decimal strike still reach the venue as the documented query" do
      opts = [plug: capturing(%{"data" => []}, self()), retry_attempts: 0]

      assert {:ok, _chain} =
               Rest.get_option_chain(
                 "AAPL",
                 @credentials,
                 opts ++ [expiry: ~D[2026-03-20], strike: Decimal.new("150")]
               )

      assert_receive {:request, path, query}, 5_000
      assert path =~ "options/contracts/list"
      assert query =~ "start_date=2026-03-20"
      assert query =~ "strike_price_gte=150"
      assert query =~ "strike_price_lte=150"
    end

    test "two contracts in one cell name both venue symbols; another underlying is refused" do
      rows = [contract(%{"symbol" => "A"}), contract(%{"symbol" => "B"})]

      ambiguous = Rest.get_option_chain("AAPL", @credentials, sent(rows))

      assert {:error, {:ambiguous_option_contract, ~D[2026-03-20], %Decimal{}, :call, symbols}} =
               ambiguous

      assert symbols == ["A", "B"]

      assert {:error, :not_in_response} =
               Rest.get_option_chain(
                 "AAPL",
                 @credentials,
                 sent([contract(%{"underlying_symbol" => "MSFT"})])
               )

      assert {:error, {:unreadable_option_contract, "x"}} =
               Rest.get_option_chain("AAPL", @credentials, sent(["x"]))
    end
  end

  describe "get_fundamental/4 and its siblings: the refusals the doc names" do
    test "count, option type and symbol refusals" do
      assert {:error, {:limit_out_of_range, 21, max: 20}} =
               Rest.get_fundamental(:balance_sheet, "AAPL", @credentials, count: 21)

      assert {:error, {:limit_out_of_range, 6, max: 5}} =
               Rest.get_fundamental(:capital_flows, "AAPL", @credentials, count: 6)

      assert {:error, {:invalid_option, :type, %{}}} =
               Rest.get_fundamental(:balance_sheet, "AAPL", @credentials, type: %{})

      assert {:error, {:invalid_symbol, ""}} =
               Rest.get_fundamental(:company_profile, "", @credentials, [])

      assert {:error, {:unknown_fundamental, :nope}} =
               Rest.get_fundamental(:nope, "AAPL", @credentials, [])
    end

    test "get_financials/4 refuses a kind outside the four" do
      assert {:error, {:unsupported_statement_kind, :company_profile}} =
               Rest.get_financials("AAPL", :company_profile, @credentials, [])
    end

    test "get_corporate_events/2 refuses a missing symbol and an unsupported kind" do
      assert {:error, :symbol_required} = Rest.get_corporate_events(@credentials, [])

      assert {:error, {:unsupported_event_kind, :split}} =
               Rest.get_corporate_events(@credentials, symbol: "AAPL", kind: :split)
    end

    test "get_news/2 refuses missing symbols and a bad filter before a request" do
      assert {:error, :symbols_required} = Rest.get_news(@credentials, [])

      assert {:error, {:invalid_option, :sentiment, "BULLISH"}} =
               Rest.get_news(@credentials, symbols: "AAPL", sentiment: "BULLISH")

      assert {:error, {:invalid_option, :limit, 0}} =
               Rest.get_news(@credentials, symbols: "AAPL", limit: 0)
    end
  end

  describe "event contracts: the shapes the doc names" do
    test "a trade limit over 1200 is {:invalid_option, :limit, n}" do
      assert {:error, {:invalid_option, :limit, 1_201}} =
               Rest.get_event_trades("EVT", @credentials, limit: 1_201)
    end

    test "the order book carries the row's symbol beside the four sides" do
      row = %{
        "symbol" => "EVT",
        "yes_bids" => [],
        "yes_asks" => [],
        "no_bids" => [],
        "no_asks" => [],
        "quote_time" => 1_768_872_168_870
      }

      assert {:ok, book} =
               Rest.get_event_order_book("EVT", @credentials, sent(%{"data" => [row]}))

      assert Enum.sort(Map.keys(book)) == [
               :no_asks,
               :no_bids,
               :quote_time,
               :symbol,
               :yes_asks,
               :yes_bids
             ]

      assert book.symbol == "EVT"
      assert book.quote_time == 1_768_872_168_870

      other = %{row | "symbol" => "OTHER"}

      assert {:error, :not_in_response} =
               Rest.get_event_order_book("EVT", @credentials, sent(%{"data" => [other]}))
    end

    test "a pagination key that is not text refuses the series page" do
      body = %{"data" => [%{"series_symbol" => "S"}], "pagination_key" => 5}

      assert {:error, :unexpected_pagination_key} =
               Rest.list_event_series(@credentials, sent(body))

      ok = %{"data" => [%{"series_symbol" => "S"}], "pagination_key" => "next"}

      assert {:ok, %{rows: [%{"series_symbol" => "S"}], pagination_key: "next"}} =
               Rest.list_event_series(@credentials, sent(ok))
    end
  end

  describe "watchlist instrument writes: the refusals the doc names" do
    test "success false is a refusal, success true is the documented map" do
      refused = %{"data" => [%{"success" => false}]}

      assert {:refused, :watchlist_write_rejected} =
               Rest.add_watchlist_instruments("w1", ["AAPL"], @credentials, sent(refused))

      accepted = %{"data" => [%{"success" => true}]}

      assert {:ok, %{"success" => true}} =
               Rest.add_watchlist_instruments("w1", ["AAPL"], @credentials, sent(accepted))
    end

    test "the checks run symbols, then category, then the watchlist id" do
      assert {:error, :symbols_required} =
               Rest.add_watchlist_instruments("", [], @credentials, [])

      assert {:error, {:invalid_category, "HK_STOCK"}} =
               Rest.remove_watchlist_instruments("", ["AAPL"], @credentials, category: "HK_STOCK")

      assert {:error, {:invalid_watchlist_id, ""}} =
               Rest.add_watchlist_instruments("", ["AAPL"], @credentials, [])
    end

    test "sorting needs a map of symbol to integer position" do
      assert {:error, :sorts_required} = Rest.sort_watchlist_instruments("w1", @credentials, [])

      assert {:error, {:invalid_sorts, %{"AAPL" => 1.5}}} =
               Rest.sort_watchlist_instruments("w1", @credentials, sorts: %{"AAPL" => 1.5})
    end
  end

  describe "place_orders/3 batch: every refusal the doc names" do
    test "size and shape" do
      assert {:error, :empty_batch} = Rest.validate_batch_orders([])
      assert {:error, :invalid_batch} = Rest.validate_batch_orders(nil)
      assert {:error, :invalid_batch} = Rest.validate_batch_orders([batch_entry() | :tail])

      too_many = for index <- 1..51, do: batch_entry(%{client_order_id: "id-#{index}"})
      assert {:error, {:batch_too_large, 51, 50}} = Rest.validate_batch_orders(too_many)

      fifty = for index <- 1..50, do: batch_entry(%{client_order_id: "id-#{index}"})
      assert :ok = Rest.validate_batch_orders(fifty)
    end

    test "entries are judged by index against the batch schema" do
      assert {:error, {:batch_instrument_not_supported, 0, :crypto}} =
               Rest.validate_batch_orders([batch_entry(%{instrument_type: :crypto})])

      assert {:error, {:batch_order_rejected, 1, :not_an_order}} =
               Rest.validate_batch_orders([batch_entry(), "x"])

      assert {:error, {:batch_order_rejected, 0, {:missing_field, :time_in_force}}} =
               Rest.validate_batch_orders([Map.delete(batch_entry(), :time_in_force)])

      assert {:error, {:batch_order_rejected, 0, {:unsupported_batch_time_in_force, :gtc}}} =
               Rest.validate_batch_orders([batch_entry(%{time_in_force: :gtc})])

      assert {:error, {:batch_order_rejected, 0, {:unsupported_batch_order_type, :stop}}} =
               Rest.validate_batch_orders([batch_entry(%{order_type: :stop})])

      assert {:error, {:batch_order_rejected, 0, {:missing_field, :support_trading_session}}} =
               Rest.validate_batch_orders([Map.delete(batch_entry(), :support_trading_session)])

      assert {:error, {:batch_order_rejected, 0, {:unsupported_support_trading_session, "X"}}} =
               Rest.validate_batch_orders([batch_entry(%{support_trading_session: "X"})])
    end

    test "client order ids: over-long, and repeated inside the batch" do
      long = String.duplicate("a", 33)

      assert {:error, {:batch_order_rejected, 0, {:invalid_client_order_id, ^long}}} =
               Rest.validate_batch_orders([batch_entry(%{client_order_id: long})])

      assert {:error, {:batch_order_rejected, 1, {:duplicate_client_order_id, "a"}}} =
               Rest.validate_batch_orders([
                 batch_entry(%{client_order_id: "a"}),
                 batch_entry(%{client_order_id: "a"})
               ])
    end
  end

  describe "place_order/3: the refusals the doc names beyond the headline ones" do
    test "instrument, expiry, cash sizing and event rules" do
      assert {:error, {:unsupported_instrument_type, :bond}} =
               Rest.validate_order_request(order(%{instrument_type: :bond}))

      event = order(%{instrument_type: :event, price: "0.5", symbol: "EVT"})

      assert {:error, {:invalid_expire_date, "20261201"}} =
               Rest.validate_order_request(
                 Map.merge(event, %{time_in_force: :gtd, expire_date: "20261201"})
               )

      assert {:error, {:cash_sizing_not_supported, :futures}} =
               Rest.validate_order_request(
                 order(%{
                   instrument_type: :futures,
                   order_type: :market,
                   quantity: nil,
                   price: nil,
                   amount: "100"
                 })
               )

      cash = Map.merge(event, %{quantity: nil, amount: "10"})

      assert {:error, {:invalid_side, :sell}} =
               Rest.validate_order_request(Map.merge(cash, %{time_in_force: :fok, side: :sell}))

      assert {:error, {:unsupported_order_combination, :amount, :day}} =
               Rest.validate_order_request(cash)

      assert {:error, {:invalid_event_outcome, :maybe}} =
               Rest.validate_order_request(Map.put(event, :event_outcome, :maybe))

      assert :ok = Rest.validate_order_request(Map.put(event, :event_outcome, :yes))
    end

    test "trailing type and session" do
      trailing = order(%{order_type: :trailing_stop, price: nil, trailing_stop_step: "1"})

      assert {:error, {:missing_field, :trailing_type}} = Rest.validate_order_request(trailing)

      assert {:error, {:invalid_trailing_type, :bogus}} =
               Rest.validate_order_request(Map.put(trailing, :trailing_type, :bogus))

      assert {:error, {:invalid_trailing_stop_step, "2"}} =
               Rest.validate_order_request(
                 Map.merge(trailing, %{trailing_type: :percentage, trailing_stop_step: "2"})
               )

      assert {:error, {:unexpected_field, :trailing_type}} =
               Rest.validate_order_request(order(%{trailing_type: :amount}))

      assert {:error, {:unsupported_support_trading_session, "BOGUS"}} =
               Rest.validate_order_request(order(%{support_trading_session: "BOGUS"}))
    end

    test "a 2xx naming a different client_order_id is unconfirmed under the id sent" do
      request = order(%{client_order_id: "mine-1"})
      body = %{"data" => [%{"client_order_id" => "theirs"}]}

      assert {:error, {:order_unconfirmed, "mine-1", :unexpected_response_shape}} =
               Rest.place_order(@credentials, request, [account_id: "1"] ++ sent(body))
    end
  end

  describe "cancel_order/3, get_order/3 and get_orders/2: the refusals the doc names" do
    test "cancel checks the id, then the account" do
      assert {:error, {:invalid_order_id, nil}} =
               Rest.cancel_order(@credentials, nil, account_id: "1")

      assert {:error, {:missing_option, :account_id}} =
               Rest.cancel_order(@credentials, "abc", [])
    end

    test "get_order names what is wrong with the group" do
      leg = %{"status" => "FILLED"}
      opts = [account_id: "1"]
      oco = %{"client_order_id" => "abc", "combo_type" => "OCO", "orders" => [leg, leg]}

      assert {:error, {:missing_required_field, :orders}} =
               Rest.get_order(
                 @credentials,
                 "abc",
                 opts ++ sent(%{"client_order_id" => "abc", "orders" => []})
               )

      assert {:error, {:unsupported_combo_type, "OCO"}} =
               Rest.get_order(@credentials, "abc", opts ++ sent(oco))

      assert {:error, :not_in_response} =
               Rest.get_order(
                 @credentials,
                 "abc",
                 opts ++ sent(%{"client_order_id" => "zzz", "orders" => [leg]})
               )

      assert {:error, :unexpected_response_shape} =
               Rest.get_order(@credentials, "abc", opts ++ sent(%{"data" => [%{"x" => 1}]}))
    end

    test "an unknown venue status is nil on the order, never a guessed one" do
      body = %{"client_order_id" => "abc", "orders" => [%{"status" => "WORKING"}]}

      assert {:ok, %Order{id: "abc", status: nil}} =
               Rest.get_order(@credentials, "abc", [account_id: "1"] ++ sent(body))
    end

    test "an unreadable group refuses the whole listing, naming it" do
      body = %{
        "data" => [
          %{"client_order_id" => "good", "orders" => [%{"status" => "FILLED"}]},
          %{"client_order_id" => "bad", "orders" => []}
        ]
      }

      assert {:error, {:unreadable_orders, ["bad"]}} =
               Rest.get_orders(@credentials, [account_id: "1"] ++ sent(body))
    end

    test "a window asked of the open listing, a bad bound and a reversed window" do
      assert {:error, {:unsupported_option, :since}} =
               Rest.validate_orders_window(since: ~U[2026-01-01 00:00:00Z])

      assert {:error, {:invalid_time, :since, "x"}} =
               Rest.validate_orders_window(history: true, since: "x")

      assert {:error, {:invalid_option, :since, _later}} =
               Rest.validate_orders_window(
                 history: true,
                 since: ~U[2026-02-01 00:00:00Z],
                 until: ~U[2026-01-01 00:00:00Z]
               )
    end
  end
end
