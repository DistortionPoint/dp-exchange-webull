defmodule DpExchange.Webull.ContractVocabularyAndFakeParityTest do
  @moduledoc """
  Two families of defect found by reading `Rest` and `Fake` against each other and against
  `dp_exchange_core`'s types.

  The first: values that reached a Core struct outside the type the struct states (a side
  spelled `"buy"`, a quantity that was an integer, a currency that was an object, a position
  with no quantity) or went to the wire as something the page does not type that way. The
  second: calls the fake answered where `Rest` refuses them, or narrowed differently than the
  venue does. Each test says what the old behaviour was.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.{Config, Types}
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
  @opts [credentials: @credentials]
  @account "93IUJ28O9VO2KBGHDHR4H9"
  @order_opts [credentials: @credentials, account_id: @account]

  defp exploding, do: fn _conn -> raise "must not reach the venue" end

  defp responding(body, status \\ 200) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, Jason.encode!(body))
    end
  end

  # Answers every request and reports the query string it was sent.
  defp reporting(body, test_pid) do
    fn conn ->
      send(test_pid, {:query, conn.request_path, URI.decode_query(conn.query_string)})
      responding(body).(conn)
    end
  end

  # A batch entry also names its trading session, which the batch endpoint requires.
  defp batch_entry, do: equity_request(%{support_trading_session: :core})

  defp equity_request(overrides) do
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

  describe "place_order/3 answers in the contract's vocabulary" do
    test "a side spelled as text and sizes spelled as numbers come back as :buy and Decimals" do
      request =
        equity_request(%{
          side: "buy",
          quantity: 5,
          price: "180.5",
          stop_price: nil,
          client_order_id: "abc"
        })

      assert {:ok, %Types.Order{} = order} =
               Rest.place_order(
                 @credentials,
                 request,
                 [account_id: @account, retry_attempts: 0] ++
                   [plug: responding([%{"client_order_id" => "abc"}])]
               )

      # `Core.Types.Order.side` is `:buy | :sell` and its numbers are Decimals; the request's
      # own spelling ("buy", 5, "180.5") used to be echoed as typed.
      assert order.side == :buy
      assert %Decimal{} = order.quantity
      assert Decimal.equal?(order.quantity, Decimal.new(5))
      assert %Decimal{} = order.price
      assert Decimal.equal?(order.price, Decimal.new("180.5"))
      assert order.stop_price == nil

      # What a consumer re-validating the answer would run: `new/1` raises outside the type.
      assert %Types.Order{side: :buy} = Types.Order.new(Map.from_struct(order))
    end

    test "SHORT is refused: capabilities say supports_short_selling is false" do
      # It used to be sent on every instrument and come back as an `%Order{side: nil}`.
      assert {:error, {:invalid_side, :short}} =
               Rest.place_order(
                 @credentials,
                 equity_request(%{side: :short}),
                 [account_id: @account, retry_attempts: 0] ++ [plug: exploding()]
               )

      assert {:error, {:invalid_side, :short}} =
               Fake.place_order(@credentials, equity_request(%{side: :short}), @order_opts)

      assert {:error, {:invalid_side, "SHORT"}} =
               Fake.preview_order(@credentials, equity_request(%{side: "SHORT"}), @order_opts)
    end

    test "the fake builds its order with the same function" do
      request =
        equity_request(%{side: "sell", quantity: 5, price: "180.5", client_order_id: "norm-1"})

      assert {:ok, %Types.Order{} = order} = Fake.place_order(@credentials, request, @order_opts)
      assert order.side == :sell
      assert Decimal.equal?(order.quantity, Decimal.new(5))
      assert Decimal.equal?(order.price, Decimal.new("180.5"))

      assert {:ok, %Types.Order{} = amended} =
               Fake.replace_order(
                 @credentials,
                 "norm-1",
                 %{quantity: 7, price: "181"},
                 [instrument_type: :equity, order_type: :limit] ++ @order_opts
               )

      assert Decimal.equal?(amended.quantity, Decimal.new(7))
      assert Decimal.equal?(amended.price, Decimal.new(181))
    end
  end

  describe "replace_order/4 when the venue accepted it and the read-back failed" do
    defp replace_plug(read_response) do
      fn conn ->
        case conn.request_path do
          "/trading/orders/replace" -> responding([%{"client_order_id" => "abc"}]).(conn)
          "/trading/orders/get" -> read_response.(conn)
        end
      end
    end

    defp replace(plug) do
      Rest.replace_order(@credentials, "abc", %{quantity: 3},
        account_id: @account,
        instrument_type: :equity,
        order_type: :limit,
        plug: plug,
        retry_attempts: 0
      )
    end

    test "a 5xx on the read is not reported as a failed replace" do
      # The read's own `{:error, {:exchange_error, ...}}` used to come back unchanged, which
      # a caller cannot tell from a replace the venue rejected - and retrying it sends it twice.
      assert {:error, {:replace_accepted_unread, "abc", {:exchange_error, :webull, _message}}} =
               replace(replace_plug(responding(%{"msg" => "down"}, 503)))
    end

    test "a refusal on the read is wrapped the same way" do
      assert {:error, {:replace_accepted_unread, "abc", {:venue_error, 403, _body}}} =
               replace(replace_plug(responding(%{"msg" => "forbidden"}, 403)))
    end

    test "a read-back that names another order is wrapped the same way" do
      other = [
        %{
          "client_order_id" => "other",
          "combo_type" => "NORMAL",
          "orders" => [%{"client_order_id" => "other", "status" => "PENDING"}]
        }
      ]

      assert {:error, {:replace_accepted_unread, "abc", :not_in_response}} =
               replace(replace_plug(responding(other)))
    end

    test "a read-back that works is still the order" do
      detail = [
        %{
          "client_order_id" => "abc",
          "combo_type" => "NORMAL",
          "orders" => [%{"client_order_id" => "abc", "status" => "PENDING"}]
        }
      ]

      assert {:ok, %Types.Order{id: "abc"}} = replace(replace_plug(responding(detail)))
    end
  end

  describe "account_id is text, here and in the fake" do
    test "a number, false or an empty string is not an account" do
      for bad <- [123, false, "", :acct] do
        assert {:error, {:missing_option, :account_id}} =
                 Rest.get_balances(@credentials, account_id: bad, plug: exploding())

        assert {:error, {:missing_option, :account_id}} =
                 Fake.get_balances(@credentials, account_id: bad)

        assert {:error, {:missing_option, :account_id}} =
                 Fake.place_orders(@credentials, [batch_entry()], account_id: bad)

        assert {:error, {:missing_option, :account_id}} =
                 Rest.place_orders(@credentials, [batch_entry()],
                   account_id: bad,
                   plug: exploding()
                 )
      end
    end
  end

  describe "activity_types" do
    test "the venue's own comma-joined string is sent as it is" do
      me = self()

      assert {:ok, []} =
               Rest.get_transfers(@credentials,
                 account_id: @account,
                 activity_types: "DEPOSIT,TRANSFER",
                 plug: reporting([], me),
                 retry_attempts: 0
               )

      assert_receive {:query, "/trading/activities/cash-activities/list",
                      %{"activity_types" => "DEPOSIT,TRANSFER"}},
                     5_000
    end

    test "a member that is not text, or a number, is refused before a request" do
      # `Enum.join/2` over a number raised `Protocol.UndefinedError` in the caller's process.
      for bad <- [[1, 2], 5, [], [""], ["DEPOSIT", nil]] do
        assert {:error, {:invalid_activity_types, ^bad}} =
                 Rest.get_transfers(@credentials,
                   account_id: @account,
                   activity_types: bad,
                   plug: exploding()
                 )

        assert {:error, {:invalid_activity_types, ^bad}} =
                 Rest.get_transactions(@credentials,
                   account_id: @account,
                   activity_types: bad,
                   plug: exploding()
                 )

        assert {:error, {:invalid_activity_types, ^bad}} =
                 Fake.get_transfers(@credentials, [activity_types: bad] ++ @order_opts)
      end
    end

    test "the fake filters get_transfers/2 by the venue's string, as it filters a list" do
      assert {:ok, [%{"activity_type" => "DIVIDENDS"}]} =
               Fake.get_transfers(@credentials, [activity_types: "DIVIDENDS"] ++ @order_opts)
    end
  end

  describe "fields the Core type says are text" do
    test "a dividend and an earnings currency that is not text is nil" do
      row = %{"ex_div_date" => "2026-05-08", "currency" => %{"code" => "USD"}}

      assert {:ok, [%Types.CorporateEvent{currency: nil}]} =
               Rest.get_corporate_events(@credentials,
                 symbol: "AAPL",
                 kind: :dividend,
                 plug: responding([row]),
                 retry_attempts: 0
               )

      assert {:ok, [%Types.CorporateEvent{currency: nil}]} =
               Rest.get_corporate_events(@credentials,
                 symbol: "AAPL",
                 kind: :earnings,
                 plug: responding([%{"expected_publish_date" => "2026-02-05", "currency" => 5}]),
                 retry_attempts: 0
               )
    end

    test "a statement currency that is not text is nil, and text is kept" do
      assert {:ok, [%Types.FinancialStatement{currency: nil}]} =
               Rest.get_financials("AAPL", :balance_sheet, @credentials,
                 plug: responding([%{"end_date" => "2025-12-27", "currency" => 840}]),
                 retry_attempts: 0
               )

      assert {:ok, [%Types.FinancialStatement{currency: "USD"}]} =
               Rest.get_financials("AAPL", :balance_sheet, @credentials,
                 plug: responding([%{"end_date" => "2025-12-27", "currency" => "USD"}]),
                 retry_attempts: 0
               )
    end

    test "a filing's id may be a number, and its other text fields are text or nil" do
      envelope = %{
        "symbol" => "AAPL",
        "filings" => [
          %{"id" => 12, "title" => %{"x" => 1}, "url" => "https://example.invalid/f"},
          %{"id" => %{"x" => 1}, "title" => "10-K", "url" => 5}
        ]
      }

      assert {:ok, [first, second]} =
               Rest.get_filings("AAPL", @credentials,
                 plug: responding([envelope]),
                 retry_attempts: 0
               )

      assert %Types.Filing{id: "12", title: nil, url: "https://example.invalid/f"} = first
      assert %Types.Filing{id: nil, title: "10-K", url: nil} = second
    end

    test "an option contract's text fields are text or nil" do
      row = %{
        "symbol" => 5,
        "expiration_date" => "2025-06-20",
        "strike_price" => "150.0",
        "option_type" => "CALL",
        "settlement_method" => %{"x" => 1},
        "expired_cycle" => 1
      }

      assert {:ok, %Types.OptionChain{expiries: expiries}} =
               Rest.get_option_chain("AAPL", @credentials,
                 plug: responding([row]),
                 retry_attempts: 0
               )

      assert %{call: contract} = expiries[~D[2025-06-20]][Decimal.new("150")]
      assert contract.venue_symbol == nil
      assert contract.settlement_type == nil
      assert contract.expiration_type == nil
    end
  end

  describe "watchlists" do
    test "a row whose id is not text refuses the listing, and a name that is not text is nil" do
      body = [
        %{"watchlist_id" => 5, "name" => "numeric id"},
        %{"watchlist_id" => "w1", "name" => %{"x" => 1}}
      ]

      assert {:error, {:missing_required_field, :id}} =
               Rest.list_watchlists(@credentials, plug: responding(body), retry_attempts: 0)

      assert {:ok, [%Types.Watchlist{id: "w1", name: nil}]} =
               Rest.list_watchlists(@credentials,
                 plug: responding(tl(body)),
                 retry_attempts: 0
               )
    end

    test "a member that is not a text symbol refuses the membership read" do
      body = [
        %{
          "watchlist_id" => "w1",
          "instruments" => [%{"symbol" => "AAPL"}, %{"symbol" => 5}, %{"symbol" => %{}}]
        }
      ]

      assert {:error, :unexpected_response_shape} =
               Rest.get_watchlist("w1", @credentials, plug: responding(body), retry_attempts: 0)
    end

    test "a created watchlist whose id is not text is unconfirmed, not returned" do
      # The create was accepted (2xx) but names no usable id: it may exist.
      assert {:error, {:write_unconfirmed, nil, {:missing_required_field, :id}}} =
               Rest.create_watchlist("n", [], @credentials,
                 plug: responding([%{"watchlist_id" => 7}]),
                 retry_attempts: 0
               )
    end

    test "members and sort are checked before anything is created" do
      # Checked by the add that FOLLOWED the create, so the watchlist existed, empty, for a
      # mistake that was knowable from the arguments.
      assert {:error, {:invalid_symbols, [1]}} =
               Rest.create_watchlist("n", [1], @credentials, plug: exploding())

      assert {:error, {:invalid_symbols, ["AAPL", ""]}} =
               Rest.create_watchlist("n", ["AAPL", ""], @credentials, plug: exploding())

      assert {:error, {:invalid_sort, "1"}} =
               Rest.create_watchlist("n", [], @credentials, sort: "1", plug: exploding())

      assert {:error, {:invalid_symbols, [1]}} = Fake.create_watchlist("n", [1], @opts)
      assert {:error, {:invalid_sort, 1.5}} = Fake.create_watchlist("n", [], [sort: 1.5] ++ @opts)
    end

    test "a membership write refuses non-text members, a sort refuses a non-number position" do
      assert {:error, {:invalid_symbols, [:aapl]}} =
               Rest.add_watchlist_instruments("w1", [:aapl], @credentials, plug: exploding())

      assert {:error, {:invalid_symbols, [nil]}} =
               Rest.remove_watchlist_instruments("w1", [nil], @credentials, plug: exploding())

      assert {:error, {:invalid_sorts, %{"AAPL" => "1"}}} =
               Rest.sort_watchlist_instruments("w1", @credentials,
                 sorts: %{"AAPL" => "1"},
                 plug: exploding()
               )
    end

    test "update refuses a sort that is not a whole number, here and in the fake" do
      assert {:error, {:invalid_sort, "2"}} =
               Rest.update_watchlist("w1", @credentials, sort: "2", plug: exploding())

      assert {:error, {:invalid_sort, "2"}} =
               Fake.update_watchlist("w1", [sort: "2"] ++ @opts)
    end
  end

  describe "options the caller set to nil mean the default" do
    test "an extended_hours or overnight of nil is sent as false, not as an empty string" do
      me = self()
      row = [%{"symbol" => "AAPL", "price" => "10.5"}]

      assert {:ok, %Types.Quote{}} =
               Rest.get_price("AAPL", @credentials,
                 category: "US_STOCK",
                 extended_hours: nil,
                 overnight: nil,
                 plug: reporting(row, me),
                 retry_attempts: 0
               )

      assert_receive {:query, "/market-data/stocks/snapshots/list", query}, 5_000
      assert query["extend_hour_required"] == "false"
      assert query["overnight_required"] == "false"
    end

    test "an event book refuses a depth that is not a whole number of levels" do
      assert {:error, {:invalid_option, :depth, 0}} =
               Rest.get_event_order_book("KX-T1", @credentials, depth: 0, plug: exploding())

      assert {:error, {:invalid_option, :depth, "ten"}} =
               Rest.get_event_order_book("KX-T1", @credentials, depth: "ten", plug: exploding())
    end
  end

  describe "the fake refuses what Rest refuses, before credentials" do
    test "get_price/2 and get_top_of_book/2 refuse a category the venue has no snapshot for" do
      assert {:error, {:unsupported_snapshot_category, "BOGUS"}} =
               Fake.get_price("BTC-USD", category: "BOGUS")

      assert {:error, {:unsupported_snapshot_category, "BOGUS"}} =
               Fake.get_top_of_book("BTC-USD", category: "BOGUS")

      assert {:error, {:use_get_event_order_book, "US_EVENT"}} =
               Fake.get_top_of_book("KX-T1", category: "US_EVENT")
    end

    test "a category the venue serves, but not for a crypto pair, is not listed here" do
      # Answering BTC-USD's crypto price for a US_STOCK request was the fake being
      # differently capable: the stock endpoint is a different endpoint.
      assert {:refused, :not_listed} =
               Fake.get_price("BTC-USD", [category: "US_STOCK"] ++ @opts)

      assert {:refused, :not_listed} =
               Fake.get_top_of_book("BTC-USD", [category: "US_OPTION"] ++ @opts)

      assert {:ok, %Types.Quote{}} = Fake.get_price("BTC-USD", @opts)
    end

    test "bars: the range, width and limit of whichever endpoint the category names" do
      range = [start: ~U[2026-01-01 00:00:00Z]]

      assert {:error, {:unsupported_bar_range, :option}} =
               Fake.get_historical_prices(
                 "AAPL260522C00300000",
                 "1m",
                 range,
                 [category: "US_OPTION"] ++ @opts
               )

      assert {:error, {:unsupported_bar_range, :future}} =
               Fake.get_historical_prices("ESZ5", "1m", range, [category: "US_FUTURES"] ++ @opts)

      assert {:error, {:unsupported_bar_range, :event}} =
               Fake.get_historical_prices("KX-T1", "1m", range, [category: "US_EVENT"] ++ @opts)

      # Event contracts stop at the day; equities serve the week.
      assert {:error, {:unsupported_timeframe, "1w"}} =
               Fake.get_historical_prices("KX-T1", "1w", [], [category: "US_EVENT"] ++ @opts)

      assert {:error, {:invalid_option, :limit, 1_651}} =
               Fake.get_historical_prices(
                 "AAPL",
                 "1m",
                 [],
                 [category: "US_STOCK", limit: 1_651] ++ @opts
               )

      assert {:error, {:unsupported_book_category, "US_WARRANT"}} =
               Fake.get_historical_prices(
                 "AAPL",
                 "1d",
                 [],
                 [category: "US_WARRANT"] ++ @opts
               )
    end

    test "bars: a request the equity endpoint accepts is not answered with a crypto bar" do
      assert {:refused, :not_listed} =
               Fake.get_historical_prices("BTC-USD", "1w", [], [category: "US_STOCK"] ++ @opts)

      assert {:ok, [%Types.Candle{}]} =
               Fake.get_historical_prices("BTC-USD", "1m", [], @opts)
    end

    test "order book: futures are served, and the depth is held to the venue's range" do
      assert {:ok, %Types.OrderBook{}} =
               Fake.get_order_book("ESZ5", [category: "US_FUTURES", depth: 10] ++ @opts)

      assert {:error, {:invalid_option, :depth, 11}} =
               Fake.get_order_book("ESZ5", [category: "US_FUTURES", depth: 11] ++ @opts)

      assert {:error, {:invalid_option, :depth, 0}} =
               Fake.get_order_book("AAPL", [depth: 0] ++ @opts)

      assert {:error, {:unsupported_book_category, "US_OPTION"}} =
               Fake.get_order_book("AAPL", [category: "US_OPTION"] ++ @opts)
    end

    test "trades: the category and the limit against that tape's own maximum" do
      assert {:error, {:use_get_event_trades, "US_EVENT"}} =
               Fake.get_trades("KX-T1", [category: "US_EVENT"] ++ @opts)

      assert {:error, {:invalid_option, :limit, 1_001}} =
               Fake.get_trades("AAPL", [limit: 1_001] ++ @opts)

      assert {:error, {:invalid_option, :limit, 1_201}} =
               Fake.get_trades("ESZ5", [category: "US_FUTURES", limit: 1_201] ++ @opts)

      assert {:ok, [_first | _rest]} =
               Fake.get_trades("ESZ5", [category: "US_FUTURES", limit: 1_200] ++ @opts)
    end

    test "financials: a count over the 20 the statement pages state" do
      assert {:error, {:limit_out_of_range, 21, max: 20}} =
               Fake.get_financials("AAPL", :income, [count: 21] ++ @opts)

      assert {:error, {:limit_out_of_range, 21, max: 20}} =
               Fake.get_financials("AAPL", :indicators, [count: 21] ++ @opts)

      assert {:ok, [%Types.FinancialStatement{kind: :income}]} =
               Fake.get_financials("AAPL", :income, [count: 20] ++ @opts)
    end
  end

  describe "the fake narrows what the venue narrows" do
    test "options: :expiry and :strike narrow the chain and the expirations" do
      assert {:ok, %Types.OptionChain{expiries: by_expiry}} =
               Fake.get_option_chain("AAPL", [expiry: ~D[2026-06-19]] ++ @opts)

      assert Map.keys(by_expiry) == [~D[2026-06-19]]

      assert {:ok, %Types.OptionChain{expiries: by_text}} =
               Fake.get_option_chain("AAPL", [expiry: "2026-03-20"] ++ @opts)

      assert Map.keys(by_text) == [~D[2026-03-20]]

      # A strike spelled as the venue spells one ("100.0") is the same strike.
      assert {:ok, %Types.OptionChain{expiries: by_strike}} =
               Fake.get_option_chain("AAPL", [strike: "100.0"] ++ @opts)

      assert Map.keys(by_strike) == [~D[2026-03-20]]

      assert {:ok, %Types.OptionChain{expiries: none}} =
               Fake.get_option_chain("AAPL", [strike: 999] ++ @opts)

      assert none == %{}

      assert {:ok, [~D[2026-06-19]]} =
               Fake.get_option_expirations("AAPL", [expiry: ~D[2026-06-19]] ++ @opts)

      assert {:ok, [~D[2026-03-20], ~D[2026-06-19]]} =
               Fake.get_option_expirations("AAPL", @opts)

      assert {:ok, []} = Fake.get_option_expirations("AAPL", [strike: 999] ++ @opts)
    end

    test "news names a headline and a time, as the venue's itemised news does" do
      assert {:ok, [%Types.NewsItem{headline: "Fixture headline", published_at: %DateTime{}}]} =
               Fake.get_news([symbols: ["AAPL"]] ++ @opts)
    end

    test "news refuses a category or sentiment the real path refuses, before credentials" do
      assert {:error, {:invalid_option, :sentiment, "BULLISH"}} =
               Fake.get_news(symbols: ["AAPL"], sentiment: "BULLISH")

      assert {:error, {:invalid_option, :category, "EU_STOCK"}} =
               Fake.get_news(symbols: ["AAPL"], category: "EU_STOCK")
    end
  end
end
