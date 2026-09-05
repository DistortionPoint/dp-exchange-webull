defmodule DpExchange.Webull.InstrumentOrdersTest do
  @moduledoc """
  Orders past crypto: the per-instrument matrix, preview, and replace.

  **This venue's order rules differ by instrument type and the differences are not
  cosmetic.** Crypto takes MARKET only with IOC; an equity takes five order types with DAY
  or GTC; an event contract takes LIMIT and nothing else. A package with one matrix would be
  wrong for four of the five, and wrong in the direction that gets an order rejected after
  it was sent.
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

  defp capturing(body, test_pid) do
    fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:sent, Jason.decode!(raw), conn.request_path})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end
  end

  defp equity_request(overrides \\ %{}) do
    Map.merge(
      %{
        instrument_type: :equity,
        symbol: "AAPL",
        side: :buy,
        quantity: Decimal.new("10"),
        price: Decimal.new("190.50"),
        order_type: :limit,
        time_in_force: :day
      },
      overrides
    )
  end

  describe "the matrix is per instrument type" do
    test "an equity limit DAY is accepted where crypto would refuse it" do
      # LIMIT/DAY is in crypto's list too, but TRAILING_STOP_LOSS is not — and a stop order
      # is equity-only. One matrix for all five would be wrong four times.
      me = self()

      assert {:ok, _order} =
               Rest.place_order(@credentials, equity_request(),
                 plug: capturing([%{"client_order_id" => "c1"}], me),
                 account_id: @account,
                 retry_attempts: 0
               )

      assert_receive {:sent, body, _path}
      leaf = body["new_orders"] |> List.first()
      assert leaf["instrument_type"] == "EQUITY"
      assert leaf["order_type"] == "LIMIT"
      assert leaf["time_in_force"] == "DAY"
    end

    test "a trailing stop is an equity order and NOT an option one" do
      # The vendor says trailing stops are "Options not supported". Accepting one on an
      # option would be refused by the venue after the request went out.
      me = self()

      assert {:ok, order} =
               Rest.place_order(
                 @credentials,
                 equity_request(%{order_type: :trailing_stop, time_in_force: :gtc}),
                 plug: capturing([%{"client_order_id" => "c1"}], me),
                 account_id: @account,
                 retry_attempts: 0
               )

      # W1: the venue sends "TRAILING_STOP_LOSS"/"GTC" on the wire (asserted below via
      # `body`) and this package's own decoder used to answer only 3 of its 5 declared
      # order types and TIFs — a trailing-stop order round-tripped to `nil` on both
      # fields despite `capabilities/0` declaring it supported. Assert the decoded
      # struct, not just that a request went out.
      assert order.order_type == :trailing_stop
      assert order.time_in_force == :gtc

      assert_receive {:sent, body, _path}
      leaf = body["new_orders"] |> List.first()
      assert leaf["order_type"] == "TRAILING_STOP_LOSS"
      assert leaf["time_in_force"] == "GTC"

      exploding = fn _conn -> raise "must not send a trailing stop on an option" end

      assert {:error, {:unsupported_order_combination, :option, :trailing_stop, :gtc}} =
               Rest.place_order(
                 @credentials,
                 equity_request(%{
                   instrument_type: :option,
                   order_type: :trailing_stop,
                   time_in_force: :gtc
                 }),
                 plug: exploding,
                 account_id: @account,
                 retry_attempts: 0
               )
    end

    test "an event contract takes LIMIT and nothing else" do
      exploding = fn _conn -> raise "must not send a market order on an event contract" end

      assert {:error, {:unsupported_order_combination, :event, :market, :gtc}} =
               Rest.place_order(
                 @credentials,
                 equity_request(%{
                   instrument_type: :event,
                   order_type: :market,
                   time_in_force: :gtc
                 }),
                 plug: exploding,
                 account_id: @account,
                 retry_attempts: 0
               )
    end

    test "an event contract takes the wider time-in-force list that stocks do not" do
      me = self()

      assert {:ok, _order} =
               Rest.place_order(
                 @credentials,
                 equity_request(%{instrument_type: :event, time_in_force: :fok}),
                 plug: capturing([%{"client_order_id" => "c1"}], me),
                 account_id: @account,
                 retry_attempts: 0
               )

      assert_receive {:sent, body, _path}
      assert body["new_orders"] |> List.first() |> Map.get("time_in_force") == "FOK"

      exploding = fn _conn -> raise "must not send FOK on an equity order" end

      assert {:error, {:unsupported_order_combination, :equity, :limit, :fok}} =
               Rest.place_order(@credentials, equity_request(%{time_in_force: :fok}),
                 plug: exploding,
                 account_id: @account,
                 retry_attempts: 0
               )
    end

    test "an instrument type this package cannot build is an error, not a default" do
      exploding = fn _conn -> raise "must not send an order for an unknown instrument" end

      assert {:error, {:unsupported_instrument_type, :bond}} =
               Rest.place_order(@credentials, equity_request(%{instrument_type: :bond}),
                 plug: exploding,
                 account_id: @account,
                 retry_attempts: 0
               )
    end

    test "a request that does not say is crypto, as it always was" do
      # Changing this default would silently re-route existing callers' orders onto a
      # different market.
      me = self()

      request = %{
        symbol: "BTC-USD",
        side: :buy,
        quantity: Decimal.new("0.5"),
        price: Decimal.new("40000"),
        order_type: :limit,
        time_in_force: :gtc
      }

      assert {:ok, _order} =
               Rest.place_order(@credentials, request,
                 plug: capturing([%{"client_order_id" => "c1"}], me),
                 account_id: @account,
                 retry_attempts: 0
               )

      assert_receive {:sent, body, _path}
      assert body["new_orders"] |> List.first() |> Map.get("instrument_type") == "CRYPTO"
    end
  end

  describe "the symbol only goes through the pair splitter for crypto" do
    test "an equity ticker is sent as-is" do
      # AAPL is already the venue's own identifier. Pushing it through a splitter that hunts
      # for a quote currency would mangle any ticker ending in one.
      me = self()

      assert {:ok, _order} =
               Rest.place_order(@credentials, equity_request(%{symbol: "SOLV"}),
                 plug: capturing([%{"client_order_id" => "c1"}], me),
                 account_id: @account,
                 retry_attempts: 0
               )

      assert_receive {:sent, body, _path}
      assert body["new_orders"] |> List.first() |> Map.get("symbol") == "SOLV"
    end

    test "a crypto pair is still canonicalised to the venue's form" do
      me = self()

      request = %{
        symbol: "BTC-USD",
        side: :buy,
        quantity: Decimal.new("0.5"),
        price: Decimal.new("40000"),
        order_type: :limit,
        time_in_force: :gtc
      }

      assert {:ok, _order} =
               Rest.place_order(@credentials, request,
                 plug: capturing([%{"client_order_id" => "c1"}], me),
                 account_id: @account,
                 retry_attempts: 0
               )

      assert_receive {:sent, body, _path}
      assert body["new_orders"] |> List.first() |> Map.get("symbol") == "BTCUSD"
    end
  end

  describe "cash sizing is not available everywhere" do
    test "AMOUNT is refused on futures and options, naming the instrument" do
      exploding = fn _conn -> raise "must not size a futures order in cash" end

      for instrument <- [:futures, :option] do
        assert {:error, {:cash_sizing_not_supported, ^instrument}} =
                 Rest.place_order(
                   @credentials,
                   equity_request(%{
                     instrument_type: instrument,
                     quantity: nil,
                     amount: Decimal.new("1000")
                   }),
                   plug: exploding,
                   account_id: @account,
                   retry_attempts: 0
                 )
      end
    end

    test "AMOUNT is accepted on an equity order" do
      me = self()

      assert {:ok, _order} =
               Rest.place_order(
                 @credentials,
                 equity_request(%{quantity: nil, amount: Decimal.new("1000")}),
                 plug: capturing([%{"client_order_id" => "c1"}], me),
                 account_id: @account,
                 retry_attempts: 0
               )

      assert_receive {:sent, body, _path}
      leaf = body["new_orders"] |> List.first()
      assert leaf["entrust_type"] == "AMOUNT"
      assert leaf["amount"] == "1000"
    end
  end

  describe "GTD carries a date, and only GTD" do
    test "an expire date is sent with a GTD event order" do
      me = self()

      assert {:ok, _order} =
               Rest.place_order(
                 @credentials,
                 equity_request(%{
                   instrument_type: :event,
                   time_in_force: :gtd,
                   expire_date: "2026-12-01"
                 }),
                 plug: capturing([%{"client_order_id" => "c1"}], me),
                 account_id: @account,
                 retry_attempts: 0
               )

      assert_receive {:sent, body, _path}
      assert body["new_orders"] |> List.first() |> Map.get("expire_date") == "2026-12-01"
    end

    test "a missing GTD date is left missing rather than defaulted" do
      # A date chosen here would be an expiry the caller never asked for.
      me = self()

      assert {:ok, _order} =
               Rest.place_order(
                 @credentials,
                 equity_request(%{instrument_type: :event, time_in_force: :gtd}),
                 plug: capturing([%{"client_order_id" => "c1"}], me),
                 account_id: @account,
                 retry_attempts: 0
               )

      assert_receive {:sent, body, _path}
      refute body["new_orders"] |> List.first() |> Map.has_key?("expire_date")
    end

    test "a DAY order carries no expire date even when one is given" do
      me = self()

      assert {:ok, _order} =
               Rest.place_order(@credentials, equity_request(%{expire_date: "2026-12-01"}),
                 plug: capturing([%{"client_order_id" => "c1"}], me),
                 account_id: @account,
                 retry_attempts: 0
               )

      assert_receive {:sent, body, _path}
      refute body["new_orders"] |> List.first() |> Map.has_key?("expire_date")
    end
  end

  describe "preview_order/3" do
    test "crypto is refused before the request, with the venue's reason" do
      # "For crypto trading, this feature is currently not supported." Sending it anyway
      # returns a business error a caller cannot tell from a rejected order.
      exploding = fn _conn -> raise "must not preview a crypto order" end

      assert {:error, {:preview_not_supported, :crypto}} =
               Rest.preview_order(@credentials, equity_request(%{instrument_type: :crypto}),
                 plug: exploding,
                 account_id: @account,
                 retry_attempts: 0
               )
    end

    test "an equity order comes back with the venue's two figures" do
      me = self()

      body = [%{"estimated_cost" => "1905.00", "estimated_transaction_fee" => "1.02"}]

      assert {:ok, preview} =
               Rest.preview_order(@credentials, equity_request(),
                 plug: capturing(body, me),
                 account_id: @account,
                 retry_attempts: 0
               )

      assert_receive {:sent, _sent, path}
      assert path == "/trading/orders/preview"
      assert Decimal.equal?(preview.estimated_cost, Decimal.new("1905.00"))
      assert Decimal.equal?(preview.estimated_fee, Decimal.new("1.02"))
    end

    test "the instrument comes back, because estimated_cost means different things" do
      # Stocks and options: total consideration. Futures: initial margin. A caller reading
      # one as the other is off by the whole notional.
      body = [%{"estimated_cost" => "2223650.0", "estimated_transaction_fee" => "2.5"}]

      assert {:ok, preview} =
               Rest.preview_order(
                 @credentials,
                 equity_request(%{instrument_type: :futures, order_type: :limit}),
                 plug: fn conn ->
                   conn
                   |> Plug.Conn.put_resp_content_type("application/json")
                   |> Plug.Conn.resp(200, Jason.encode!(body))
                 end,
                 account_id: @account,
                 retry_attempts: 0
               )

      assert preview.instrument_type == :futures
    end

    test "the same request builds the same order body a placement would" do
      # A preview that differs from the order it previews is worse than no preview.
      me = self()

      assert {:ok, _preview} =
               Rest.preview_order(@credentials, equity_request(),
                 plug: capturing([%{"estimated_cost" => "1"}], me),
                 account_id: @account,
                 retry_attempts: 0
               )

      assert_receive {:sent, preview_body, _p1}

      assert {:ok, _order} =
               Rest.place_order(@credentials, equity_request(),
                 plug: capturing([%{"client_order_id" => "c1"}], me),
                 account_id: @account,
                 retry_attempts: 0
               )

      assert_receive {:sent, place_body, _p2}

      previewed = preview_body["new_orders"] |> List.first() |> Map.delete("client_order_id")
      placed = place_body["new_orders"] |> List.first() |> Map.delete("client_order_id")
      assert previewed == placed
    end

    test "a body with no estimated cost is unreadable, not a free order" do
      assert {:error, :unexpected_response_shape} =
               Rest.preview_order(@credentials, equity_request(),
                 plug: fn conn ->
                   conn
                   |> Plug.Conn.put_resp_content_type("application/json")
                   |> Plug.Conn.resp(200, Jason.encode!([%{}]))
                 end,
                 account_id: @account,
                 retry_attempts: 0
               )
    end

    test "without an account_id nothing is sent" do
      exploding = fn _conn -> raise "must not preview without an account" end

      assert {:error, :account_id_required} =
               Rest.preview_order(@credentials, equity_request(),
                 plug: exploding,
                 retry_attempts: 0
               )
    end
  end

  describe "replace_order/4" do
    test "crypto is refused before the request" do
      exploding = fn _conn -> raise "must not amend a crypto order" end

      assert {:error, {:preview_not_supported, :crypto}} =
               Rest.replace_order(@credentials, "abc", %{price: Decimal.new("1")},
                 instrument_type: :crypto,
                 plug: exploding,
                 account_id: @account,
                 retry_attempts: 0
               )
    end

    test "a MARKET order takes quantity and nothing else" do
      # The venue's rule, enforced here rather than discovered from a business error.
      exploding = fn _conn -> raise "must not amend a market order's price" end

      assert {:error, {:unsupported_order_edit, :market, [:price]}} =
               Rest.replace_order(@credentials, "abc", %{price: Decimal.new("1")},
                 order_type: :market,
                 plug: exploding,
                 account_id: @account,
                 retry_attempts: 0
               )
    end

    test "a LIMIT order takes price, quantity and time in force" do
      me = self()

      # The venue's replace answers without an order, so the package reads it back.
      plug = fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(me, {:sent, conn.request_path, raw})

        body =
          if conn.request_path =~ "replace",
            do: %{},
            else: [%{"client_order_id" => "abc", "order_status" => "WORKING"}]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end

      assert {:ok, order} =
               Rest.replace_order(
                 @credentials,
                 "abc",
                 %{price: Decimal.new("191.00"), quantity: Decimal.new("5")},
                 plug: plug,
                 account_id: @account,
                 retry_attempts: 0
               )

      assert_receive {:sent, replace_path, raw}
      assert replace_path == "/trading/orders/replace"
      sent = Jason.decode!(raw)
      assert sent["client_order_id"] == "abc"
      assert sent["limit_price"] == "191.00"
      assert sent["quantity"] == "5"

      # The order was read back, not reported from the request.
      assert_receive {:sent, read_path, _raw2}
      assert read_path == "/trading/orders/get"
      assert order.id == "abc"
    end

    test "a trailing stop takes only its step" do
      exploding = fn _conn -> raise "must not amend a trailing stop's price" end

      assert {:error, {:unsupported_order_edit, :trailing_stop, [:price]}} =
               Rest.replace_order(@credentials, "abc", %{price: Decimal.new("1")},
                 order_type: :trailing_stop,
                 plug: exploding,
                 account_id: @account,
                 retry_attempts: 0
               )
    end

    test "an amendment with nothing in it is refused" do
      # Sending one would have the venue re-accept the order unchanged, which looks like
      # success and achieves nothing.
      exploding = fn _conn -> raise "must not send an empty amendment" end

      assert {:error, :no_order_changes} =
               Rest.replace_order(@credentials, "abc", %{},
                 plug: exploding,
                 account_id: @account,
                 retry_attempts: 0
               )
    end

    test "without an account_id nothing is sent" do
      exploding = fn _conn -> raise "must not amend without an account" end

      assert {:error, :account_id_required} =
               Rest.replace_order(@credentials, "abc", %{price: Decimal.new("1")},
                 plug: exploding,
                 retry_attempts: 0
               )
    end
  end
end
