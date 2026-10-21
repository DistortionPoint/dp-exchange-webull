defmodule DpExchange.Webull.RestIdAndSideShapeTest do
  @moduledoc """
  A field the venue sent in a shape `Core.Types` cannot hold is refused, not handed on.

  `Order.id` is text and a book side is a list. A number where an order's id belongs, or a
  string where a side's levels belong, used to come back inside `{:ok, _}`: an `%Order{}`
  `Order.new/1` refuses, and a book with an empty side that read as "no liquidity".
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

  defp responding(body) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end
  end

  defp group(client_order_id) do
    %{
      "client_order_id" => client_order_id,
      "combo_type" => "NORMAL",
      "orders" => [%{"symbol" => "AAPL", "side" => "BUY", "status" => "SUBMITTED"}]
    }
  end

  describe "get_order/3 and an id that is not text" do
    test "a text id is returned" do
      assert {:ok, order} =
               Rest.get_order(@credentials, "abc",
                 account_id: "acct",
                 plug: responding([group("abc")]),
                 retry_attempts: 0
               )

      assert order.id == "abc"
    end

    test "a numeric client_order_id is refused, not returned as the order's id" do
      assert {:error, {:missing_required_field, :id}} =
               Rest.get_order(@credentials, "12345",
                 account_id: "acct",
                 plug: responding([group(12_345)]),
                 retry_attempts: 0
               )
    end
  end

  describe "place_order/3 and an acknowledgement id that is not text" do
    test "a numeric client_order_id in the answer is unconfirmed, with the id that was sent" do
      request = %{
        symbol: "BTC-USD",
        side: :buy,
        quantity: Decimal.new("0.5"),
        price: Decimal.new("40000"),
        order_type: :limit,
        time_in_force: :gtc,
        client_order_id: "mine-1"
      }

      assert {:error, {:order_unconfirmed, "mine-1", :unexpected_response_shape}} =
               Rest.place_order(@credentials, request,
                 account_id: "acct",
                 plug: responding([%{"client_order_id" => 99}]),
                 retry_attempts: 0
               )
    end
  end

  describe "get_order_book/3 and a side that is not a list" do
    defp book(row) do
      Rest.get_order_book("F", @credentials,
        plug: responding([row]),
        retry_attempts: 0
      )
    end

    test "a side sent as text is refused rather than read as empty" do
      row = %{
        "symbol" => "F",
        "quote_time" => 1_787_936_147_000,
        "bids" => "none",
        "asks" => [%{"price" => "13.91", "size" => "3"}]
      }

      assert {:error, :unexpected_response_shape} = book(row)
    end

    test "an absent or null side is still an empty one" do
      row = %{
        "symbol" => "F",
        "quote_time" => 1_787_936_147_000,
        "bids" => nil,
        "asks" => [%{"price" => "13.91", "size" => "3"}]
      }

      assert {:ok, book} = book(row)
      assert book.bids == []
      assert [{price, size}] = book.asks
      assert Decimal.equal?(price, Decimal.new("13.91"))
      assert Decimal.equal?(size, Decimal.new("3"))
    end
  end

  describe "a watchlist id or name that is not text is an error, not a crash" do
    defp exploding, do: fn _conn -> raise "must not reach the venue" end

    test "Rest refuses it before any request, for every call that addresses one" do
      opts = [plug: exploding(), retry_attempts: 0]

      for bad <- [nil, "", 42, :wl] do
        expected = {:error, {:invalid_watchlist_id, bad}}

        assert expected == Rest.get_watchlist(bad, @credentials, opts)
        assert expected == Rest.update_watchlist(bad, @credentials, opts)
        assert expected == Rest.delete_watchlist(bad, @credentials, opts)
        assert expected == Rest.add_watchlist_instruments(bad, ["AAPL"], @credentials, opts)
      end

      assert {:error, {:invalid_watchlist_name, nil}} ==
               Rest.create_watchlist(nil, ["AAPL"], @credentials, opts)
    end

    test "the Fake refuses the same values, before it looks at credentials" do
      for bad <- [nil, "", 42, :wl] do
        expected = {:error, {:invalid_watchlist_id, bad}}

        assert expected == Fake.get_watchlist(bad, [])
        assert expected == Fake.update_watchlist(bad, name: "x")
        assert expected == Fake.delete_watchlist(bad, [])
      end

      assert {:error, {:invalid_watchlist_name, :nope}} == Fake.create_watchlist(:nope, [], [])
    end
  end
end
