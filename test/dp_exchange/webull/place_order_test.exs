defmodule DpExchange.Webull.PlaceOrderTest do
  @moduledoc """
  Webull states its crypto order rules in prose rather than encoding them in a key name:
  MARKET takes IOC only, LIMIT and STOP_LOSS_LIMIT take DAY or GTC. These assertions are
  about the pairs outside that list, and about the account the venue requires on every order.
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

  defp responding(body) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end
  end

  defp accepted, do: [%{"order_id" => "wb-1", "client_order_id" => "abc"}]

  defp place(request, opts) do
    Rest.place_order(@credentials, request, Keyword.merge([retry_attempts: 0], opts))
  end

  defp limit_request(overrides \\ %{}) do
    Map.merge(
      %{
        symbol: "BTC-USD",
        side: :buy,
        quantity: Decimal.new("0.5"),
        price: Decimal.new("40000"),
        order_type: :limit,
        time_in_force: :gtc
      },
      overrides
    )
  end

  defp unused_price_fields(:market), do: [:price, :stop_price]
  defp unused_price_fields(:limit), do: [:stop_price]
  defp unused_price_fields(:stop_limit), do: []

  describe "the account the venue requires on every order" do
    test "an order with no account_id is an error, and nothing is sent" do
      # An account is where the money is. A package that looked one up and chose would place
      # a real order against the wrong balance for a caller holding several.
      exploding = fn _conn -> raise "must not call the venue without an account" end

      assert {:error, {:missing_option, :account_id}} = place(limit_request(), plug: exploding)
    end

    test "a blank account_id is missing too, and nothing is sent" do
      exploding = fn _conn -> raise "must not call the venue without an account" end

      for blank <- ["", "   ", nil, 42] do
        assert {:error, {:missing_option, :account_id}} =
                 place(limit_request(), plug: exploding, account_id: blank)
      end
    end

    test "the account_id reaches the venue in the body" do
      me = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(me, {:sent, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(accepted()))
      end

      assert {:ok, _order} = place(limit_request(), plug: plug, account_id: @account)
      assert_receive {:sent, %{"account_id" => @account}}
    end
  end

  describe "side and symbol are checked before anything is sent" do
    test "a side the venue has no word for is refused, not upper-cased and sent" do
      exploding = fn _conn -> raise "must not send a side the venue does not list" end

      for bad <- [:bid, :long, :short, "short", "hold", 1, {:buy}] do
        assert {:error, {:invalid_side, ^bad}} =
                 place(limit_request(%{side: bad}), plug: exploding, account_id: @account)
      end

      # An absent side is a missing field, not an invalid one (DV2).
      assert {:error, {:missing_field, :side}} =
               place(limit_request(%{side: nil}), plug: exploding, account_id: @account)
    end

    test "a symbol that is empty or not text is refused" do
      exploding = fn _conn -> raise "must not send an unusable symbol" end

      for bad <- ["", "   ", :btc, 42, nil] do
        assert {:error, {:invalid_symbol, ^bad}} =
                 place(limit_request(%{symbol: bad}), plug: exploding, account_id: @account)
      end
    end

    test "buy and sell are accepted in either case, as atoms or strings" do
      for side <- [:buy, :sell, "buy", "SELL"] do
        assert {:ok, _order} =
                 place(limit_request(%{side: side}),
                   plug: responding(accepted()),
                   account_id: @account
                 )
      end
    end
  end

  describe "a caller's own client_order_id" do
    test "longer than the venue's 32 characters is refused, and nothing is sent" do
      exploding = fn _conn -> raise "must not send an id the venue will refuse" end
      too_long = String.duplicate("a", 33)

      assert {:error, {:invalid_client_order_id, ^too_long}} =
               place(limit_request(%{client_order_id: too_long}),
                 plug: exploding,
                 account_id: @account
               )
    end

    test "empty or not text is refused" do
      exploding = fn _conn -> raise "must not send an invalid id" end

      for bad <- ["", "  ", 42] do
        assert {:error, {:invalid_client_order_id, ^bad}} =
                 place(limit_request(%{client_order_id: bad}),
                   plug: exploding,
                   account_id: @account
                 )
      end
    end

    test "exactly 32 characters is accepted" do
      id = String.duplicate("b", 32)

      assert {:ok, _order} =
               place(limit_request(%{client_order_id: id}),
                 plug: responding([%{"client_order_id" => id}]),
                 account_id: @account
               )
    end
  end

  describe "the type/time-in-force pairs the venue documents for crypto" do
    test "a market GTC is refused — MARKET takes IOC only" do
      exploding = fn _conn -> raise "must not call the venue for an unsupported pair" end

      assert {:error, {:unsupported_order_combination, :market, :gtc}} =
               place(limit_request(%{order_type: :market, time_in_force: :gtc}),
                 plug: exploding,
                 account_id: @account
               )
    end

    test "a limit IOC is refused — LIMIT takes DAY or GTC" do
      exploding = fn _conn -> raise "must not call the venue for an unsupported pair" end

      assert {:error, {:unsupported_order_combination, :limit, :ioc}} =
               place(limit_request(%{time_in_force: :ioc}), plug: exploding, account_id: @account)
    end

    test "a stop-limit IOC is refused" do
      exploding = fn _conn -> raise "must not call the venue for an unsupported pair" end

      assert {:error, {:unsupported_order_combination, :stop_limit, :ioc}} =
               place(limit_request(%{order_type: :stop_limit, time_in_force: :ioc}),
                 plug: exploding,
                 account_id: @account
               )
    end

    test "every documented pair builds and is accepted" do
      for {type, tif} <- [
            {:market, :ioc},
            {:limit, :day},
            {:limit, :gtc},
            {:stop_limit, :day},
            {:stop_limit, :gtc}
          ] do
        # Only the price fields the type uses: a `:price` on a market order, or a
        # `:stop_price` on a limit one, is refused rather than dropped.
        request =
          %{order_type: type, time_in_force: tif, stop_price: Decimal.new("39000")}
          |> limit_request()
          |> Map.drop(unused_price_fields(type))

        assert {:ok, _order} =
                 place(request, plug: responding(accepted()), account_id: @account),
               "#{type}/#{tif} is documented but did not build"
      end
    end
  end

  describe "QTY and AMOUNT are different orders" do
    setup do
      me = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(me, {:sent, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(accepted()))
      end

      {:ok, plug: plug}
    end

    # `common-order-place.md:287,292` names `quantity` and `total_cash_amount` — not
    # `qty`/`amount`, which no page defines and which the venue never read.
    test "a quantity sizes in units, as QTY", %{plug: plug} do
      assert {:ok, _order} = place(limit_request(), plug: plug, account_id: @account)

      assert_receive {:sent, %{"new_orders" => [leaf]}}
      assert leaf["entrust_type"] == "QTY"
      assert leaf["quantity"] == "0.5"
      refute Map.has_key?(leaf, "qty")
    end

    test "an amount sizes in cash, as AMOUNT", %{plug: plug} do
      request = limit_request(%{amount: Decimal.new("250")}) |> Map.delete(:quantity)

      assert {:ok, _order} = place(request, plug: plug, account_id: @account)

      assert_receive {:sent, %{"new_orders" => [leaf]}}
      assert leaf["entrust_type"] == "AMOUNT"
      assert leaf["total_cash_amount"] == "250"
      refute Map.has_key?(leaf, "amount")
    end

    test "neither is an error, not a default" do
      request = limit_request() |> Map.delete(:quantity)
      exploding = fn _conn -> raise "must not call the venue with no size" end

      assert {:error, {:missing_field, :quantity}} =
               place(request, plug: exploding, account_id: @account)
    end

    test "both at once is ambiguous, and refused" do
      # A caller asking for 0.5 BTC and $250 of BTC is asking for two different orders.
      request = limit_request(%{amount: Decimal.new("250")})
      exploding = fn _conn -> raise "must not call the venue with an ambiguous size" end

      assert {:error, {:unexpected_field, :amount}} =
               place(request, plug: exploding, account_id: @account)
    end

    test "cash sizing on a stop-limit is refused, because the venue restricts it by side" do
      # The venue allows AMOUNT on a stop-limit buy and not on a sell. Accepting it on one
      # side invites a surprise on the other, so it is refused outright.
      request =
        limit_request(%{
          order_type: :stop_limit,
          stop_price: Decimal.new("39000"),
          amount: Decimal.new("250")
        })
        |> Map.delete(:quantity)

      exploding = fn _conn -> raise "must not call the venue" end

      assert {:error, {:unexpected_field, :amount}} =
               place(request, plug: exploding, account_id: @account)
    end
  end

  describe "the body the venue receives" do
    setup do
      me = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(me, {:sent, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(accepted()))
      end

      {:ok, plug: plug}
    end

    test "crypto orders are NORMAL, CRYPTO, US", %{plug: plug} do
      assert {:ok, _order} = place(limit_request(), plug: plug, account_id: @account)

      assert_receive {:sent, %{"new_orders" => [leaf]}}
      assert leaf["combo_type"] == "NORMAL"
      assert leaf["instrument_type"] == "CRYPTO"
      assert leaf["market"] == "US"
      assert leaf["side"] == "BUY"
      assert leaf["symbol"] == "BTCUSD"
    end

    test "a market order carries no limit price", %{plug: plug} do
      request = limit_request(%{order_type: :market, time_in_force: :ioc}) |> Map.delete(:price)

      assert {:ok, _order} = place(request, plug: plug, account_id: @account)

      assert_receive {:sent, %{"new_orders" => [leaf]}}
      assert leaf["order_type"] == "MARKET"
      refute Map.has_key?(leaf, "limit_price")
    end

    test "a stop-limit carries both prices", %{plug: plug} do
      request = limit_request(%{order_type: :stop_limit, stop_price: Decimal.new("39000")})

      assert {:ok, _order} = place(request, plug: plug, account_id: @account)

      assert_receive {:sent, %{"new_orders" => [leaf]}}
      assert leaf["order_type"] == "STOP_LOSS_LIMIT"
      assert leaf["limit_price"] == "40000"
      assert leaf["stop_price"] == "39000"
    end

    test "a client_order_id is generated when absent, within the venue's 32-char limit", %{
      plug: plug
    } do
      assert {:ok, _order} = place(limit_request(), plug: plug, account_id: @account)

      assert_receive {:sent, %{"new_orders" => [leaf]}}
      assert String.length(leaf["client_order_id"]) == 32
    end

    test "a caller's own client_order_id is used", %{plug: plug} do
      assert {:ok, _order} =
               place(limit_request(%{client_order_id: "mine-1"}),
                 plug: plug,
                 account_id: @account
               )

      assert_receive {:sent, %{"new_orders" => [%{"client_order_id" => "mine-1"}]}}
    end
  end

  describe "the response" do
    test "an accepted order comes back with the venue's id" do
      assert {:ok, order} =
               place(limit_request(), plug: responding(accepted()), account_id: @account)

      # The client_order_id, not the venue's order_id: this venue's cancel and get both
      # take the client id, so returning the other would hand back an id that round-trips
      # nowhere.
      assert order.id == "abc"
      assert order.status == :pending
      assert order.provider == :webull
      assert order.order_type == :limit
      assert order.time_in_force == :gtc
    end

    test "an accepted row that names no order is unconfirmed, with the id that was sent" do
      # `id: nil` cannot be cancelled or looked up, and the order may be live. The caller
      # gets the id back, as it does for a timeout, so `get_order/3` can settle it.
      assert {:error, {:order_unconfirmed, "mine-1", :unexpected_response_shape}} =
               place(limit_request(%{client_order_id: "mine-1"}),
                 plug: responding([%{"order_id" => "wb-1"}]),
                 account_id: @account
               )
    end

    test "a 2xx with no order row is unconfirmed too, with the generated id that was sent" do
      # `[]`, `{}` and an empty `data` are all "accepted, names nothing": the order may be
      # live, so a bare shape error (which a caller retries into a duplicate) is wrong.
      for body <- [[], %{}, %{"data" => []}, %{"data" => "x"}] do
        assert {:error, {:order_unconfirmed, sent_id, :unexpected_response_shape}} =
                 place(limit_request(), plug: responding(body), account_id: @account)

        assert is_binary(sent_id) and String.length(sent_id) == 32
      end
    end

    test "a stop order's trigger price is on the order it hands back, not just the wire body" do
      # `/orders/place` answers with only the accepted client_order_id, so `to_placed_order/4`
      # echoes `stop_price` from the caller's own request — the same way it already echoed
      # `price` and `quantity`. Missing before this fix: a caller placing a stop-limit order
      # got `stop_price: nil` back from the very call that set it.
      request = limit_request(%{order_type: :stop_limit, stop_price: Decimal.new("39000")})

      assert {:ok, order} =
               place(request, plug: responding(accepted()), account_id: @account)

      assert order.stop_price == Decimal.new("39000")
    end
  end

  describe "the order id this venue actually uses" do
    test "cancel and get both take the client order id, not the venue's" do
      # Webull keys its whole order API on the id the caller supplied. A package returning
      # the venue's own order_id from place_order/3 would hand back something that
      # round-trips nowhere: place, then cancel, and the cancel fails.
      me = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(me, {:sent, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"client_order_id" => "abc"}))
      end

      assert {:ok, :cancelled} =
               Rest.cancel_order(@credentials, "abc",
                 plug: plug,
                 account_id: @account,
                 retry_attempts: 0
               )

      assert_receive {:sent, %{"client_order_id" => "abc", "account_id" => @account}}
    end

    test "cancelling without an account is refused before the call" do
      exploding = fn _conn -> raise "must not call the venue without an account" end

      assert {:error, {:missing_option, :account_id}} =
               Rest.cancel_order(@credentials, "abc", plug: exploding, retry_attempts: 0)
    end
  end

  describe "reading orders back" do
    # `/trading/orders/get` returns a GROUP — `{client_order_id, combo_order_id,
    # combo_type, orders: [...]}` (order-detail.md:163,182) — the leg's own fields live
    # inside `orders`, not on this envelope; `total_quantity`/`filled_quantity`/
    # `filled_price` are the leg's documented names, not `qty`/`filled_qty`/
    # `avg_filled_price`, which no page defines.
    defp order_row(leg_overrides \\ %{}) do
      leg =
        Map.merge(
          %{
            "client_order_id" => "abc",
            "symbol" => "BTCUSD",
            "side" => "BUY",
            "order_type" => "LIMIT",
            "time_in_force" => "GTC",
            "status" => "PENDING",
            "total_quantity" => "0.5",
            "filled_quantity" => "0.1",
            "limit_price" => "40000",
            "filled_price" => "40010"
          },
          leg_overrides
        )

      %{"combo_type" => "NORMAL", "orders" => [leg]}
    end

    test "get_order returns the venue's own view" do
      assert {:ok, order} =
               Rest.get_order(@credentials, "abc",
                 plug: responding([order_row()]),
                 account_id: @account,
                 retry_attempts: 0
               )

      assert order.id == "abc"
      assert order.symbol == "BTC-USD"
      assert order.side == :buy
      assert order.order_type == :limit
      assert order.time_in_force == :gtc
      # PENDING is the closest "not yet filled" status `order-detail.md:215`'s own enum
      # documents on this endpoint — the enum has no `WORKING`/`OPEN` member at all.
      assert order.status == :pending
      assert Decimal.equal?(order.filled_quantity, Decimal.new("0.1"))
      assert Decimal.equal?(order.average_price, Decimal.new("40010"))
      assert order.provider == :webull
    end

    test "a status this package does not recognise is nil, never a guess" do
      assert {:ok, order} =
               Rest.get_order(@credentials, "abc",
                 plug: responding([order_row(%{"status" => "SOMETHING_NEW"})]),
                 account_id: @account,
                 retry_attempts: 0
               )

      assert order.status == nil
    end

    test "PARTIAL_FILLED is :partially_filled, a different claim from :open" do
      assert {:ok, order} =
               Rest.get_order(@credentials, "abc",
                 plug: responding([order_row(%{"status" => "PARTIAL_FILLED"})]),
                 account_id: @account,
                 retry_attempts: 0
               )

      assert order.status == :partially_filled
    end

    test "open and historical orders are different endpoints, not a filter" do
      # Asking for \"orders\" without saying which gets the open ones — the set that can
      # still change.
      me = self()

      plug = fn conn ->
        send(me, {:path, conn.request_path})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!([]))
      end

      assert {:ok, []} =
               Rest.get_orders(@credentials, plug: plug, account_id: @account, retry_attempts: 0)

      assert_receive {:path, open_path}
      assert open_path =~ "open-orders"

      assert {:ok, []} =
               Rest.get_orders(@credentials,
                 history: true,
                 plug: plug,
                 account_id: @account,
                 retry_attempts: 0
               )

      assert_receive {:path, history_path}
      assert history_path =~ "historical-orders"
    end
  end

  test "a normalized or very small quantity is sent in full notation, never scientific" do
    # `Decimal.to_string/1` defaults to SCIENTIFIC, and `to_string/1` on a `%Decimal{}`
    # reaches that same default through `String.Chars`. So a quantity or price carrying an
    # exponent went onto the wire as `"1.5E+2"` or `"1E-8"` — not a number this venue
    # reads, and a different order if it read one at all.
    #
    # An exponent is not exotic: `Decimal.normalize/1`, the ordinary way to strip trailing
    # zeros, turns `150.00` into `1.5E+2`, and anything below a millionth carries one by
    # construction. `option_decimal_param/1` in this module already said `:normal`; the
    # order path did not.
    me = self()

    plug = fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(me, {:sent, Jason.decode!(raw)})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(accepted()))
    end

    request =
      limit_request(%{
        quantity: Decimal.new("0.00000001"),
        price: Decimal.normalize(Decimal.new("150.00"))
      })

    place(request, plug: plug, account_id: @account)

    assert_receive {:sent, body}
    leaf = body |> Map.get("new_orders") |> List.first()

    assert leaf["quantity"] == "0.00000001"
    assert leaf["limit_price"] == "150"
    refute String.contains?(leaf["quantity"], "E")
    refute String.contains?(to_string(leaf["limit_price"]), "E")
  end

  describe "a placement is sent once whatever retry_attempts says" do
    test "a failing placement makes exactly one attempt, carrying a generated id" do
      # `Core.HttpClient` retries anything that is not a 4xx, including a timeout and a
      # connection reset - exactly the failures where the venue may have received and acted
      # on the request. A write is therefore sent once (`send_once/1`) and a doubtful
      # outcome is answered `order_unconfirmed` with the id that was sent, so the caller
      # settles it with `get_order/3` instead of placing a second order.
      me = self()

      plug = fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        decoded = if raw == "", do: %{}, else: Jason.decode!(raw)
        send(me, {:attempt, decoded})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(503, Jason.encode!(%{"msg" => "unavailable"}))
      end

      # The plug runs in this process, so every attempt has sent its message by the time
      # `place/2` returns; nothing here waits on a timer or a spawned process.
      assert {:error, {:order_unconfirmed, sent_id, _reason}} =
               place(limit_request(),
                 plug: plug,
                 account_id: @account,
                 retry_attempts: 3,
                 retry_delay: 1
               )

      bodies = drain_attempts([])
      ids = Enum.map(bodies, &client_order_id_of/1)

      assert ids == [sent_id], "a placement must be sent exactly once: #{inspect(bodies)}"
      assert String.length(sent_id) == 32
    end

    defp client_order_id_of(body) do
      case body do
        %{"new_orders" => [%{"client_order_id" => id} | _rest]} -> id
        %{"client_order_id" => id} -> id
        _other -> nil
      end
    end

    defp drain_attempts(acc) do
      receive do
        {:attempt, body} -> drain_attempts([body | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end
  end
end
