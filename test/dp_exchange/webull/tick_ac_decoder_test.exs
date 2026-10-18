defmodule DpExchange.Webull.TickACDecoderTest do
  @moduledoc """
  Decoder robustness against hostile or malformed venue payloads (tick AC). Every test names
  the input, and what the OLD code did with it: a raise in the caller or socket process, or a
  plausible value (a negative size, a map as a pagination key, a 2,000-digit price) delivered
  as though the venue had said something sensible.
  """

  use ExUnit.Case, async: true

  import Bitwise

  alias DpExchange.Core.{Config, Notice}
  alias DpExchange.Core.Types.{Quote, TopOfBook, Trade}
  alias DpExchange.Webull.{Fake, Rest, Socket, Subscription}

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
  @time 1_787_936_147_000
  @huge "1" <> String.duplicate("0", 2_000)

  defp exploding, do: fn _conn -> raise "must not reach the venue" end

  # Request options that answer with `body` as JSON and never retry.
  defp answer(body) do
    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end

    [plug: plug, retry_attempts: 0]
  end

  # --- stream frames ---------------------------------------------------------------------

  defp state,
    do: %{
      subscriber: self(),
      session_id: "s1",
      app_key: "k",
      buffer: <<>>,
      qos2_pending: MapSet.new(),
      connected?: false,
      ping: nil,
      last_heard_at: nil
    }

  defp varint(value) when value < 0x80, do: <<value>>
  defp varint(value), do: <<1::1, band(value, 0x7F)::7, varint(bsr(value, 7))::binary>>

  defp field(number, value) when is_binary(value),
    do: varint(bsl(number, 3) ||| 2) <> varint(byte_size(value)) <> value

  defp publish(topic, payload) do
    body = <<byte_size(topic)::16>> <> topic <> payload
    <<3::4, 0::4>> <> varint(byte_size(body)) <> body
  end

  defp basic, do: field(1, field(1, "BTCUSD"))

  defp deliver(topic, payload) do
    assert {:ok, _state} = Socket.handle_frame({:binary, publish(topic, payload)}, state())
  end

  describe "stream: sizes" do
    test "a tick of negative size is dropped and reported, not delivered as a trade" do
      # Old: `required_decimal/2` read "-5" as a number and a `%Trade{quantity: -5}` went out.
      deliver("tick", basic() <> field(2, "1787936147000") <> field(3, "10") <> field(4, "-5"))

      refute_receive {:dp_exchange, :webull, %Trade{}}, 500

      assert_receive {:dp_exchange, :webull, %Notice{kind: :data_quality} = notice}, 5_000
      assert notice.details.dropped == {:tick, {:non_positive_size, :quantity}}
    end

    test "a snapshot's negative volume is nil with no window, never a negative running total" do
      # Old: `volume: -5` with `volume_window: :running_total`.
      deliver("snapshot", basic() <> field(3, "10") <> field(8, "-5"))

      assert_receive {:dp_exchange, :webull, %Quote{volume: nil, volume_window: nil}}, 5_000
    end

    test "a level's negative size is nil, and the readable side keeps its own" do
      # Old: `ask_size: -4` beside a real ask.
      ask = field(1, "101") <> field(2, "-4")
      bid = field(1, "100") <> field(2, "5")

      deliver("quote", basic() <> field(2, ask) <> field(3, bid))

      assert_receive {:dp_exchange, :webull, %TopOfBook{} = book}, 5_000
      assert Decimal.equal?(book.ask, Decimal.new("101"))
      assert book.ask_size == nil
      assert Decimal.equal?(book.bid_size, Decimal.new("5"))
    end

    test "a price written in two thousand digits is dropped, not parsed and delivered" do
      # Old: exponent 0, so `abs(exp) > 1_000` did not catch it and a 10^2000 price went out.
      deliver("snapshot", basic() <> field(3, @huge))

      refute_receive {:dp_exchange, :webull, %Quote{}}, 500

      assert_receive {:dp_exchange, :webull, %Notice{kind: :data_quality} = notice}, 5_000
      assert notice.details.dropped == {:snapshot, {:invalid_decimal, :price}}
    end
  end

  # --- REST: sizes and numbers -----------------------------------------------------------

  describe "REST: sizes and numbers" do
    test "a tape row of negative size refuses the reply" do
      # Old: `{:ok, [%Trade{quantity: -5}]}`.
      tick = %{"time" => @time, "price" => "10", "volume" => "-5"}
      body = [%{"symbol" => "AAPL", "result" => [tick]}]

      assert {:error, {:non_positive_size, :quantity, "-5"}} =
               Rest.get_trades("AAPL", @credentials, answer(body))
    end

    test "a footprint level of negative size refuses the profile" do
      # Old: the negative size was stored under its price and `point_of_control/1` summed it.
      entry = %{"time" => @time, "buy_detail" => %{"10.0" => "-3"}, "sell_detail" => %{}}
      body = [%{"symbol" => "AAPL", "result" => [entry]}]

      assert {:error, {:non_positive_size, :buy_detail, "-3"}} =
               Rest.get_volume_profile("AAPL", "1m", @credentials, answer(body))
    end

    test "a footprint level with a null size still names the field, as before" do
      entry = %{"time" => @time, "buy_detail" => %{"10.0" => nil}, "sell_detail" => %{}}
      body = [%{"symbol" => "AAPL", "result" => [entry]}]

      assert {:error, {:invalid_decimal, :buy_detail, nil}} =
               Rest.get_volume_profile("AAPL", "1m", @credentials, answer(body))
    end

    test "a snapshot's negative volume is nil, with no window" do
      # Old: `volume: -5, volume_window: :running_total`.
      body = [%{"symbol" => "AAPL", "price" => "10", "volume" => "-5"}]
      opts = [category: "US_STOCK"] ++ answer(body)

      assert {:ok, %Quote{volume: nil, volume_window: nil}} =
               Rest.get_price("AAPL", @credentials, opts)
    end

    test "a top of book's negative sizes are nil, never a negative depth" do
      row = %{"symbol" => "AAPL", "bid" => "9", "ask" => "10"}
      row = Map.merge(row, %{"bid_size" => "-3", "ask_size" => "4"})
      opts = [category: "US_STOCK"] ++ answer([row])

      assert {:ok, %TopOfBook{bid_size: nil, ask_size: ask_size}} =
               Rest.get_top_of_book("AAPL", @credentials, opts)

      assert Decimal.equal?(ask_size, Decimal.new("4"))
    end

    test "a price written in two thousand digits is refused as unreadable" do
      # Old: finite, exponent 0, accepted as a 10^2000 price.
      opts = [category: "US_STOCK"] ++ answer([%{"symbol" => "AAPL", "price" => @huge}])

      assert {:error, {:invalid_decimal, :price, @huge}} =
               Rest.get_price("AAPL", @credentials, opts)
    end

    test "an option strike of zero or less is an unreadable contract" do
      # Old: a chain with a contract at strike 0 (or -5) in its grid.
      for strike <- ["0", "-5"] do
        contract = %{
          "expiration_date" => "2026-03-20",
          "strike_price" => strike,
          "direction" => "CALL",
          "symbol" => "AAPL260320C00000000"
        }

        assert {:error, {:unreadable_option_contract, keys}} =
                 Rest.get_option_chain("AAPL", @credentials, answer(%{"data" => [contract]}))

        assert "strike_price" in keys
      end
    end
  end

  # --- REST: shapes ----------------------------------------------------------------------

  describe "REST: rows and keys that are not what the spec promises" do
    test "a pagination key that is an object is refused, not handed to the caller" do
      # Old: `{:ok, %{pagination_key: %{"a" => 1}}}`; passed back as `opts[:pagination_key]`
      # it raised in `to_string/1` on the next call.
      body = %{"data" => [%{"symbol" => "A"}], "pagination_key" => %{"a" => 1}}

      assert {:error, :unexpected_pagination_key} =
               Rest.list_event_series(@credentials, answer(body))
    end

    test "a page holding a string row is refused" do
      assert {:error, :unexpected_response_shape} =
               Rest.list_event_markets(@credentials, answer(%{"data" => ["x"]}))
    end

    test "an account list holding a string is refused, not returned as an account" do
      # Old: `{:ok, ["x", %{...}]}` against a `[map()]` spec.
      body = %{"data" => ["x", %{"account_id" => "1"}]}

      assert {:error, :unexpected_response_shape} = Rest.get_accounts(@credentials, answer(body))
    end

    test "a cash activity page holding a number is refused" do
      opts = [account_id: @account] ++ answer(%{"data" => [7]})

      assert {:error, :unexpected_response_shape} = Rest.get_transfers(@credentials, opts)
    end

    test "a fundamentals list and the futures and event lists refuse a non-object row" do
      opts = answer(%{"data" => [1]})
      shape = {:error, :unexpected_response_shape}

      assert shape == Rest.get_fundamental(:company_profile, "AAPL", @credentials, opts)
      assert shape == Rest.list_futures_contracts(@credentials, [symbols: "ES"] ++ opts)
      assert shape == Rest.list_futures_product_classes(@credentials, opts)
      assert shape == Rest.list_event_categories(@credentials, opts)
      assert shape == Rest.list_event_events(@credentials, [series_symbol: "S"] ++ opts)
    end

    test "an event tape holding a string is refused" do
      body = [%{"symbol" => "KX", "result" => ["x"]}]

      assert {:error, :unexpected_response_shape} =
               Rest.get_event_trades("KX", @credentials, answer(body))
    end

    test "a crypto bars reply with a group that is not an object is refused, not shortened" do
      # Old: the string was skipped (`_other -> []`) and the call answered `{:ok, []}`.
      assert {:error, :unexpected_response_shape} =
               Rest.get_historical_prices("BTC-USD", "1m", [], @credentials, answer(["junk"]))
    end

    test "a batch answer holding a string is an unconfirmed order, with every id" do
      order = %{
        symbol: "AAPL",
        side: :buy,
        order_type: :market,
        time_in_force: :day,
        quantity: 1,
        support_trading_session: "CORE",
        client_order_id: "ac-batch-1"
      }

      opts = [account_id: @account] ++ answer(%{"batch_orders" => ["x"]})

      assert {:error, {:order_unconfirmed, ["ac-batch-1"], :unexpected_response_shape}} =
               Rest.place_orders(@credentials, [order], opts)
    end
  end

  # --- consumer arguments that reached a raise --------------------------------------------

  describe "options a query string cannot hold are refused, not raised on" do
    test "a fundamentals option that is a map, or a list where one value belongs" do
      # Old: `Protocol.UndefinedError` from `to_string/1`; the list was sent concatenated.
      for bad <- [%{}, {:annual}, ["ANNUAL", "QUARTERLY"]] do
        opts = [type: bad, plug: exploding()]

        assert {:error, {:invalid_option, :type, ^bad}} =
                 Rest.get_fundamental(:balance_sheet, "AAPL", @credentials, opts)
      end
    end

    test "a screener option that is a tuple" do
      opts = [sort_by: {:x}, plug: exploding()]

      assert {:error, {:invalid_option, :sort_by, {:x}}} =
               Rest.get_screener("gainers_losers", @credentials, opts)
    end

    test "a futures symbol list holding a map" do
      opts = [symbols: [%{}], plug: exploding()]

      assert {:error, {:invalid_option, :symbols, [%{}]}} =
               Rest.list_futures_contracts(@credentials, opts)
    end

    test "an event tape limit and an event book depth that are maps" do
      # Old: the query was built before the check, and `put_present/3` raised first.
      assert {:error, {:invalid_option, :limit, %{}}} =
               Rest.get_event_trades("KX", @credentials, limit: %{}, plug: exploding())

      assert {:error, {:invalid_option, :depth, %{}}} =
               Rest.get_event_order_book("KX", @credentials, depth: %{}, plug: exploding())
    end

    test "tape and bar sessions that are not session names" do
      assert {:error, {:invalid_option, :sessions, [%{}]}} =
               Rest.get_trades("AAPL", @credentials, sessions: [%{}], plug: exploding())

      opts = [category: "US_STOCK", sessions: %{}, plug: exploding()]

      assert {:error, {:invalid_option, :sessions, %{}}} =
               Rest.get_historical_prices("AAPL", "1m", [], @credentials, opts)
    end

    test "extended_hours and overnight must be booleans, on the snapshot, top of book and book" do
      # Old: `to_string/1` raised `Protocol.UndefinedError` for a map or tuple, and sent "yes"
      # or "1" as typed for text and numbers: values the venue's booleans do not define.
      bad_flags = [extended_hours: %{}, extended_hours: "yes", overnight: {:x}, overnight: 1]

      for {key, bad} <- bad_flags do
        opts = [{key, bad}, {:category, "US_STOCK"}, {:plug, exploding()}]
        error = {:error, {:invalid_option, key, bad}}

        assert error == Rest.get_price("AAPL", @credentials, opts)
        assert error == Rest.get_top_of_book("AAPL", @credentials, opts)
        assert error == Rest.get_order_book("AAPL", @credentials, opts)
      end
    end

    test "true, false and nil are still accepted for both" do
      body = [%{"symbol" => "AAPL", "price" => "10"}]
      opts = [category: "US_STOCK", extended_hours: true, overnight: nil] ++ answer(body)

      assert {:ok, %Quote{}} = Rest.get_price("AAPL", @credentials, opts)
    end

    test "the fake refuses the same flags" do
      assert {:error, {:invalid_option, :extended_hours, [1]}} =
               Fake.get_price("BTC-USD", extended_hours: [1])

      assert {:error, {:invalid_option, :overnight, %{}}} =
               Fake.get_top_of_book("BTC-USD", overnight: %{})

      assert {:error, {:invalid_option, :overnight, 1}} =
               Fake.get_order_book("AAPL", overnight: 1)
    end

    test "the fake refuses exactly what the real path refuses" do
      assert {:error, {:invalid_option, :sessions, [%{}]}} =
               Fake.get_trades("AAPL", sessions: [%{}])

      assert {:error, {:invalid_option, :sort_by, %{}}} =
               Fake.get_screener("gainers_losers", sort_by: %{})

      assert {:error, {:invalid_option, :type, %{}}} =
               Fake.get_financials("AAPL", :balance_sheet, type: %{})
    end
  end

  # --- subscribe answers -----------------------------------------------------------------

  describe "Subscription: a 417 whose JSON arrived as text" do
    defp subscribe(body) do
      plug = fn conn -> Plug.Conn.resp(conn, 417, body) end

      Subscription.subscribe("session-1", ["BTC-USD"],
        credentials: @credentials,
        plug: plug,
        retry_attempts: 0
      )
    end

    test "INVALID_SESSION is still the answer Feed can act on" do
      # Old: no content type, so the body stayed a string, matched none of the named clauses
      # and became the opaque `:exchange_error` that Feed retries against the dead session.
      message = "Mqtt connection not exist for session:abc123"
      text = Jason.encode!(%{"error_code" => "INVALID_SESSION", "message" => message})

      assert {:error, {:invalid_session, "abc123"}} = subscribe(text)
    end

    test "INVALID_SYMBOL still names the symbols, and the ceiling is still :oversubscribed" do
      message = "The symbols does not exist in the category. [BNBUSD]"
      symbols = Jason.encode!(%{"error_code" => "INVALID_SYMBOL", "message" => message})
      ceiling = Jason.encode!(%{"error_code" => "TOO_MANY_SYMBOLS_SUBSCRIPTION"})

      assert {:error, {:invalid_symbols, ["BNB-USD"]}} = subscribe(symbols)
      assert {:error, :oversubscribed} = subscribe(ceiling)
    end

    test "text that is not an object is the opaque error, with the status" do
      assert {:error, {:exchange_error, :webull, "HTTP 417" <> _rest}} = subscribe("[1, 2]")
      assert {:error, {:exchange_error, :webull, "HTTP 417" <> _rest}} = subscribe("<html>")
    end
  end
end
