defmodule DpExchange.Webull.RestReviewEdgesTest do
  @moduledoc """
  Edges of `Rest` found by reading it end to end: venue input that raised in the caller's
  process, order numbers that went to the wire as typed, an amendment that reported a change
  it never sent, and rows filed under a symbol they did not name. Each test says what the old
  behaviour was.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Config
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

  defp exploding, do: fn _conn -> raise "must not reach the venue" end

  defp responding(body) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end
  end

  defp sse_responding(events) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.resp(
        200,
        Enum.map_join(events, "\n\n", &"event:message\ndata:#{Jason.encode!(&1)}")
      )
    end
  end

  defp equity_order(overrides) do
    Map.merge(
      %{
        symbol: "AAPL",
        side: :buy,
        instrument_type: :equity,
        order_type: :limit,
        time_in_force: :day,
        quantity: Decimal.new("1"),
        price: Decimal.new("10")
      },
      overrides
    )
  end

  defp place(request, extra) do
    Rest.place_order(
      @credentials,
      request,
      [account_id: @account, retry_attempts: 0] ++ extra
    )
  end

  # Answers the place and the read-back with the shapes each documents, and reports the
  # request bodies it saw.
  defp capturing(test_pid) do
    fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:sent, conn.request_path, raw})

      body =
        if conn.request_path =~ "orders/get",
          do: [
            %{
              "combo_type" => "NORMAL",
              "orders" => [%{"client_order_id" => "abc", "status" => "PENDING"}]
            }
          ],
          else: [%{"client_order_id" => "abc"}]

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end
  end

  describe "news frames the venue sends oddly" do
    test "an object where an id belongs falls back to the session id" do
      events = [
        %{"type" => "meta", "args" => %{"convId" => %{"x" => 1}, "sessionId" => "s-1"}},
        %{"type" => "text", "message" => "Hello "},
        %{"type" => "text", "message" => "world"}
      ]

      assert {:ok, [item]} =
               Rest.get_news(@credentials,
                 symbols: ["AAPL"],
                 plug: sse_responding(events),
                 retry_attempts: 0
               )

      assert item.id == "s-1"
      assert item.summary == "Hello world"
    end

    # Tick AJ: a text chunk whose text is not text once raised, then contributed nothing —
    # a summary with a hole in it. It now refuses the read.
    for bad <- [%{"unexpected" => true}, nil] do
      test "a text chunk whose message is #{inspect(bad)} refuses the read" do
        events = [
          %{"type" => "meta", "args" => %{"sessionId" => "s-1"}},
          %{"type" => "text", "message" => "Hello "},
          %{"type" => "text", "message" => unquote(Macro.escape(bad))}
        ]

        assert {:error, :unexpected_response_shape} =
                 Rest.get_news(@credentials,
                   symbols: ["AAPL"],
                   plug: sse_responding(events),
                   retry_attempts: 0
                 )
      end
    end

    test "a stream whose only id is not text or a number has no id, and is refused" do
      events = [
        %{"type" => "meta", "args" => %{"convId" => [1, 2], "sessionId" => %{}}},
        %{"type" => "text", "message" => "x"}
      ]

      assert {:error, {:missing_required_field, :id}} =
               Rest.get_news(@credentials,
                 symbols: ["AAPL"],
                 plug: sse_responding(events),
                 retry_attempts: 0
               )
    end

    test "symbols that are not all text are refused before anything is encoded or sent" do
      for symbols <- [["AAPL", {:not, :text}], ["AAPL", %{}], [""], "", [nil]] do
        assert {:error, :symbols_required} =
                 Rest.get_news(@credentials,
                   symbols: symbols,
                   plug: exploding(),
                   retry_attempts: 0
                 )
      end
    end
  end

  describe "futures contracts need a symbol or a code that names something" do
    test "an empty list and an empty string are not given" do
      for given <- [[symbols: []], [code: ""], [symbols: [], code: "  "]] do
        assert {:error, :symbols_or_code_required} =
                 Rest.list_futures_contracts(
                   @credentials,
                   [plug: exploding(), retry_attempts: 0] ++ given
                 )
      end
    end

    test "a symbol is still enough" do
      assert {:ok, []} =
               Rest.list_futures_contracts(@credentials,
                 symbols: ["ESZ6"],
                 plug: responding([]),
                 retry_attempts: 0
               )
    end
  end

  describe "an auction imbalance row is the requested symbol's" do
    test "a row naming another symbol is not_in_response, not filed under the asked one" do
      row = %{
        "symbol" => "MSFT",
        "imbalance_action_type" => "PRE_OPEN",
        "imbalance_ref_price" => "400.1"
      }

      assert {:error, :not_in_response} =
               Rest.get_auction_imbalance("AAPL", @credentials,
                 auction: :opening,
                 plug: responding(row),
                 retry_attempts: 0
               )
    end

    test "the same symbol in another case is the same symbol, and a row with none is read" do
      named = %{"symbol" => "aapl", "imbalance_ref_price" => "1"}

      assert {:ok, [_one]} =
               Rest.get_auction_imbalance("AAPL", @credentials,
                 auction: :closing,
                 plug: responding(named),
                 retry_attempts: 0
               )

      assert {:ok, [_one]} =
               Rest.get_auction_imbalance("AAPL", @credentials,
                 auction: :closing,
                 plug: responding(%{"imbalance_ref_price" => "1"}),
                 retry_attempts: 0
               )
    end
  end

  describe "order book depth" do
    test "futures state 1 to 10, so anything else is refused before the request" do
      for depth <- [0, 11, "5", 2.5] do
        assert {:error, {:invalid_option, :depth, ^depth}} =
                 Rest.get_order_book("ESZ6", @credentials,
                   category: "US_FUTURES",
                   depth: depth,
                   plug: exploding(),
                   retry_attempts: 0
                 )
      end
    end

    test "a stock book needs a positive whole number" do
      for depth <- [0, -1, "10"] do
        assert {:error, {:invalid_option, :depth, ^depth}} =
                 Rest.get_order_book("AAPL", @credentials,
                   depth: depth,
                   plug: exploding(),
                   retry_attempts: 0
                 )
      end
    end
  end

  describe "rows that are not objects" do
    test "a statement list holding a string is refused, not a statement of nothing" do
      assert {:error, :unexpected_response_shape} =
               Rest.get_financials("AAPL", :balance_sheet, @credentials,
                 plug: responding(%{"data" => ["x"]}),
                 retry_attempts: 0
               )
    end

    test "a calendar holding a number is refused" do
      assert {:error, :unexpected_response_shape} =
               Rest.get_corporate_events(@credentials,
                 symbol: "AAPL",
                 kind: :dividend,
                 plug: responding(%{"data" => [1]}),
                 retry_attempts: 0
               )
    end

    test "a filings list holding a string is refused" do
      assert {:error, :unexpected_response_shape} =
               Rest.get_filings("AAPL", @credentials,
                 plug: responding(%{"symbol" => "AAPL", "filings" => ["x"]}),
                 retry_attempts: 0
               )
    end
  end

  describe "an order's numbers must be numbers above zero" do
    test "zero, negative, NaN, text and containers are refused with no request" do
      for bad <- [0, -1, Decimal.new("NaN"), Decimal.new("Infinity"), "abc", %{}, true] do
        assert {:error, {:invalid_quantity, ^bad}} =
                 place(equity_order(%{quantity: bad}), plug: exploding())
      end

      assert {:error, {:invalid_price, bad}} =
               place(equity_order(%{price: Decimal.new("-0.5")}), plug: exploding())

      assert Decimal.equal?(bad, Decimal.new("-0.5"))
    end

    test "a float is refused: it has already lost digits" do
      assert {:error, {:invalid_quantity, 1.5}} =
               place(equity_order(%{quantity: 1.5}), plug: exploding())

      assert {:error, {:invalid_price, 10.1}} =
               place(equity_order(%{price: 10.1}), plug: exploding())

      assert {:error, {:invalid_price, 1.0e-8}} =
               place(equity_order(%{price: 1.0e-8}), plug: exploding())
    end

    test "the cash amount and the stop trigger are checked too" do
      request = equity_order(%{order_type: :stop, quantity: nil, amount: 0})

      assert {:error, {:invalid_amount, 0}} = place(request, plug: exploding())

      stop = %{order_type: :stop, stop_price: "x"} |> equity_order() |> Map.delete(:price)
      assert {:error, {:invalid_stop_price, "x"}} = place(stop, plug: exploding())

      trail =
        %{order_type: :trailing_stop, trailing_stop_step: 0}
        |> equity_order()
        |> Map.delete(:price)

      assert {:error, {:invalid_trailing_stop_step, 0}} = place(trail, plug: exploding())
    end

    test "a price left on a market order is refused, not silently dropped" do
      request = equity_order(%{order_type: :market, price: "junk"})

      assert {:error, {:unexpected_field, :price}} = place(request, plug: exploding())
    end

    test "prices and quantities go out as strings in full notation" do
      request =
        equity_order(%{
          quantity: "1e-8",
          price: 10,
          order_type: :limit,
          time_in_force: :gtc,
          client_order_id: "abc"
        })

      assert {:ok, _order} = place(request, plug: capturing(self()))

      assert_receive {:sent, "/trading/orders/place", raw}, 5_000
      [leaf] = Jason.decode!(raw)["new_orders"]
      assert leaf["quantity"] == "0.00000001"
      assert leaf["limit_price"] == "10"

      assert {:ok, _order} =
               place(
                 equity_order(%{
                   price: Decimal.new("1E-8"),
                   time_in_force: :gtc,
                   client_order_id: "abc"
                 }),
                 plug: capturing(self())
               )

      assert_receive {:sent, "/trading/orders/place", raw2}, 5_000
      assert [%{"limit_price" => "0.00000001"}] = Jason.decode!(raw2)["new_orders"]
    end

    test "a batch entry is refused by index" do
      entry = %{
        symbol: "AAPL",
        side: :buy,
        order_type: :limit,
        time_in_force: :day,
        quantity: Decimal.new("1"),
        price: Decimal.new("10"),
        instrument_type: :equity,
        support_trading_session: :core
      }

      assert {:error, {:batch_order_rejected, 1, {:invalid_quantity, -1}}} =
               Rest.place_orders(
                 @credentials,
                 [entry, %{entry | quantity: -1}],
                 account_id: @account,
                 plug: exploding(),
                 retry_attempts: 0
               )

      assert {:error, {:batch_order_rejected, 0, {:invalid_quantity, -1}}} =
               Rest.validate_batch_orders([%{entry | quantity: -1}])
    end

    test "the fake refuses what the real path refuses" do
      assert {:error, {:invalid_quantity, 0}} =
               Rest.validate_order_request(equity_order(%{quantity: 0}))

      assert {:error, {:invalid_quantity, 0}} =
               Fake.place_order(@credentials, equity_order(%{quantity: 0}), account_id: @account)
    end
  end

  # `replace_order/4` is told which order it is editing: neither option has a default.
  @edited [instrument_type: :equity, order_type: :limit]

  defp replace(changes, extra) do
    Rest.replace_order(
      @credentials,
      "abc",
      changes,
      [account_id: @account, retry_attempts: 0] ++ @edited ++ extra
    )
  end

  describe "replace_order/4 sends what it says it sent" do
    test "an integer quantity and price go out as the venue's strings" do
      assert {:ok, _order} = replace(%{quantity: 5, price: 10}, plug: capturing(self()))

      assert_receive {:sent, "/trading/orders/replace", raw}, 5_000
      [modification] = Jason.decode!(raw)["modify_orders"]
      assert modification["quantity"] == "5"
      assert modification["limit_price"] == "10"
    end

    test "a change to nothing is no change" do
      assert {:error, :no_order_changes} =
               replace(%{quantity: nil}, plug: exploding())

      assert {:error, :no_order_changes} =
               Fake.replace_order(
                 @credentials,
                 "abc",
                 %{price: nil},
                 [account_id: @account] ++ @edited
               )
    end

    test "an order type or time in force with no wire name is refused, not dropped" do
      assert {:error, {:unsupported_order_type, :bogus}} =
               replace(%{order_type: :bogus}, plug: exploding())

      assert {:error, {:unsupported_time_in_force, :forever}} =
               replace(%{time_in_force: :forever}, plug: exploding())
    end

    test "a quantity that is not above zero is refused" do
      assert {:error, {:invalid_quantity, 0}} =
               replace(%{quantity: 0}, plug: exploding())

      assert {:error, {:invalid_price, "x"}} =
               Rest.validate_replace("abc", %{price: "x"}, @edited)

      assert {:error, {:invalid_price, 1.5}} = replace(%{price: 1.5}, plug: exploding())
    end
  end

  describe "an order id must name an order" do
    test "a reply for another order is not_in_response, not this order" do
      group = %{
        "combo_type" => "NORMAL",
        "orders" => [%{"client_order_id" => "other", "status" => "PENDING"}]
      }

      assert {:error, :not_in_response} =
               Rest.get_order(@credentials, "abc",
                 account_id: @account,
                 plug: responding([group]),
                 retry_attempts: 0
               )

      assert {:ok, %{id: "other"}} =
               Rest.get_order(@credentials, "other",
                 account_id: @account,
                 plug: responding([group]),
                 retry_attempts: 0
               )
    end

    test "a reply for another watchlist is not_in_response; one naming none is still refused" do
      assert {:error, :not_in_response} =
               Rest.get_watchlist("wl-1", @credentials,
                 plug: responding([%{"watchlist_id" => "wl-2", "instruments" => []}]),
                 retry_attempts: 0
               )

      assert {:error, {:missing_required_field, :id}} =
               Rest.get_watchlist("wl-1", @credentials,
                 plug: responding([%{"instruments" => []}]),
                 retry_attempts: 0
               )
    end

    test "the id is checked before the account, and the account before the credentials" do
      assert {:error, {:invalid_order_id, nil}} =
               Rest.cancel_order(@credentials, nil, plug: exploding(), retry_attempts: 0)

      assert {:error, {:missing_option, :account_id}} =
               Rest.cancel_order(@credentials, "abc", plug: exploding(), retry_attempts: 0)

      assert {:error, {:missing_credentials, :webull}} =
               Rest.cancel_order(%{}, "abc",
                 account_id: @account,
                 plug: exploding(),
                 retry_attempts: 0
               )
    end
  end
end
