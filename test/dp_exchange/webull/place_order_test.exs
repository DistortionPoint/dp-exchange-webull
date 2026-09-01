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

  describe "the account the venue requires on every order" do
    test "an order with no account_id is an error, and nothing is sent" do
      # An account is where the money is. A package that looked one up and chose would place
      # a real order against the wrong balance for a caller holding several.
      exploding = fn _conn -> raise "must not call the venue without an account" end

      assert {:error, :account_id_required} = place(limit_request(), plug: exploding)
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
        request =
          limit_request(%{
            order_type: type,
            time_in_force: tif,
            stop_price: Decimal.new("39000")
          })

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

    test "a quantity sizes in units, as QTY", %{plug: plug} do
      assert {:ok, _order} = place(limit_request(), plug: plug, account_id: @account)

      assert_receive {:sent, %{"new_orders" => [leaf]}}
      assert leaf["entrust_type"] == "QTY"
      assert leaf["qty"] == "0.5"
    end

    test "an amount sizes in cash, as AMOUNT", %{plug: plug} do
      request = limit_request(%{amount: Decimal.new("250")}) |> Map.delete(:quantity)

      assert {:ok, _order} = place(request, plug: plug, account_id: @account)

      assert_receive {:sent, %{"new_orders" => [leaf]}}
      assert leaf["entrust_type"] == "AMOUNT"
      assert leaf["amount"] == "250"
    end

    test "neither is an error, not a default" do
      request = limit_request() |> Map.delete(:quantity)
      exploding = fn _conn -> raise "must not call the venue with no size" end

      assert {:error, :missing_order_size} =
               place(request, plug: exploding, account_id: @account)
    end

    test "both at once is ambiguous, and refused" do
      # A caller asking for 0.5 BTC and $250 of BTC is asking for two different orders.
      request = limit_request(%{amount: Decimal.new("250")})
      exploding = fn _conn -> raise "must not call the venue with an ambiguous size" end

      assert {:error, :ambiguous_order_size} =
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

      assert {:error, :cash_sizing_not_supported_for_stop} =
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
      request = limit_request(%{order_type: :market, time_in_force: :ioc})

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

    test "a body with no order row is unreadable" do
      assert {:error, :unexpected_response_shape} =
               place(limit_request(), plug: responding([]), account_id: @account)
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

      assert {:error, :account_id_required} =
               Rest.cancel_order(@credentials, "abc", plug: exploding, retry_attempts: 0)
    end
  end

  describe "reading orders back" do
    defp order_row(overrides \\ %{}) do
      Map.merge(
        %{
          "client_order_id" => "abc",
          "symbol" => "BTCUSD",
          "side" => "BUY",
          "order_type" => "LIMIT",
          "time_in_force" => "GTC",
          "order_status" => "WORKING",
          "qty" => "0.5",
          "filled_qty" => "0.1",
          "limit_price" => "40000",
          "avg_filled_price" => "40010"
        },
        overrides
      )
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
      assert order.status == :open
      assert Decimal.equal?(order.filled_quantity, Decimal.new("0.1"))
      assert order.provider == :webull
    end

    test "a status this package does not recognise is nil, never a guess" do
      assert {:ok, order} =
               Rest.get_order(@credentials, "abc",
                 plug: responding([order_row(%{"order_status" => "SOMETHING_NEW"})]),
                 account_id: @account,
                 retry_attempts: 0
               )

      assert order.status == nil
    end

    test "PARTIAL_FILLED is open, because the rest can still fill" do
      assert {:ok, order} =
               Rest.get_order(@credentials, "abc",
                 plug: responding([order_row(%{"order_status" => "PARTIAL_FILLED"})]),
                 account_id: @account,
                 retry_attempts: 0
               )

      assert order.status == :open
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
end
